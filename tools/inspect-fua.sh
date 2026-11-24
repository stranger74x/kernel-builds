#!/usr/bin/env bash
# inspect-fua.sh - look at the KC3000 FUA patch AFTER makepkg -o has applied it.
#
# Usage:  tools/inspect-fua.sh <variant-folder> [output-folder]
#         tools/inspect-fua.sh linux-cachyos-lts
#
# Why: "patch applied cleanly" only means the TEXT matched. This script also
# checks the MEANING (order of lines, free quirk bit, FUA set elsewhere) and
# writes a report with the real code around our change, so a human can read it.
#
# Exit code: 0 = no FAIL (WARN lines still need your eyes), 1 = FAIL, 2 = setup problem.
set -u

variant=${1:?usage: inspect-fua.sh <variant-folder> [output-folder]}
out=${2:-fua-check/$(basename "$variant")}
patch=$variant/nvme-kingston-kc3000-disable-fua.patch
Q=NVME_QUIRK_NO_FUA

src=""
for d in "$variant"/src/linux-*; do
  [ -f "$d/drivers/nvme/host/core.c" ] && { src=$d; break; }
done
[ -n "$src" ]   || { echo "setup: no kernel source in $variant/src (run: makepkg -od)"; exit 2; }
[ -f "$patch" ] || { echo "setup: patch file not found: $patch"; exit 2; }

H=$src/drivers/nvme/host
core=$H/core.c; nvmeh=$H/nvme.h; pci=$H/pci.c
blk=$src/include/linux/blkdev.h

ver=$(awk '/^VERSION =/{v=$3} /^PATCHLEVEL =/{p=$3} /^SUBLEVEL =/{s=$3} /^EXTRAVERSION =/{e=$3} END{print v"."p"."s e}' "$src/Makefile" 2>/dev/null)
[ -n "$ver" ] || ver=unknown

rm -rf "$out"; mkdir -p "$out/post/drivers/nvme/host" "$out/pre/drivers/nvme/host"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fails=0; warns=0
res() {  # res LEVEL "text"
  printf '| %s | %s |\n' "$1" "$2" >> "$tmp/table"
  [ "$1" = FAIL ] && fails=$((fails+1))
  [ "$1" = WARN ] && warns=$((warns+1))
}

# numbered listing of a line range; '+' marks lines our patch added
show() {  # show FILE FROM TO ADDEDLIST
  awk -v a="$2" -v b="$3" -v add="$4" 'BEGIN{n=split(add,A," ");for(i=1;i<=n;i++)m[A[i]]=1}
       NR>=a && NR<=b {printf "%s %5d  %s\n", (NR in m)?"+":" ", NR, $0}' "$1"
}

# ---- keep the 3 files (after) and rebuild the 3 files (before) --------------
for f in core.c nvme.h pci.c; do
  cp "$H/$f" "$out/post/drivers/nvme/host/$f"
  cp "$H/$f" "$out/pre/drivers/nvme/host/$f"
done
if patch -p1 -R -F0 -s -d "$src" --dry-run < "$patch" >/dev/null 2>&1; then
  res PASS "Patch is in the tree exactly (reverse-applies with zero fuzz)."
  patch -p1 -R -F0 -s -d "$out/pre" < "$patch" >/dev/null 2>&1
else
  res FAIL "Patch is NOT in the tree, or makepkg applied it with fuzz. Fix the patch first."
fi
added() { diff --old-line-format= --unchanged-line-format= --new-line-format='%dn
' "$out/pre/drivers/nvme/host/$1" "$out/post/drivers/nvme/host/$1" | tr '\n' ' '; }
add_h=$(added nvme.h); add_c=$(added core.c); add_p=$(added pci.c)

# ---- 1. quirk bit (nvme.h) ---------------------------------------------------
{
echo '## 1. Quirk definition (nvme.h) - small change'
echo
block=$(sed -n '/^enum nvme_quirks {/,/^};/p' "$nvmeh")
nh=$(grep -nE "^[[:space:]]*$Q[[:space:]]*=" "$nvmeh" | head -1 | cut -d: -f1)
if [ -z "$block" ]; then
  res FAIL "enum nvme_quirks not found in nvme.h (upstream moved or renamed it)."
elif [ -z "$nh" ]; then
  res FAIL "$Q is not defined in nvme.h."
else
  bits=$(printf '%s\n' "$block" | grep -oE '1 ?<< ?[0-9]+' | grep -oE '[0-9]+$')
  ours=$(printf '%s\n' "$block" | grep "$Q" | grep -oE '<< ?[0-9]+' | grep -oE '[0-9]+$' | head -1)
  dups=$(printf '%s\n' "$bits" | sort -n | uniq -d | tr '\n' ' ')
  nenum=$(printf '%s\n' "$block" | grep -cE '^[[:space:]]*NVME_QUIRK_[A-Z0-9_]+[[:space:]]*=')
  nbits=$(printf '%s\n' "$bits" | grep -c .)
  other_max=$(printf '%s\n' "$bits" | grep -vx "$ours" | sort -n | tail -1)
  if [ -n "$dups" ]; then
    res FAIL "Quirk bit collision: bit(s) $dups used twice in enum nvme_quirks."
  else
    res PASS "Quirk bit $ours is unique (upstream's highest other bit: $other_max)."
  fi
  [ -n "$other_max" ] && [ "$other_max" -ge $((ours-3)) ] && res WARN "Upstream bits are getting close to ours ($other_max vs $ours). Pick a higher bit soon."
  [ "$nenum" != "$nbits" ] && res WARN "Could not read every quirk value ($nenum names, $nbits numbers). Look at the list below."
  echo '```c'; show "$nvmeh" $((nh>8?nh-8:1)) $((nh+8)) "$add_h"; echo '```'
fi
echo
} > "$tmp/s1"

# ---- 2. PCI table (pci.c) ----------------------------------------------------
{
echo '## 2. PCI ID table (pci.c) - small change'
echo
cnt=$(grep -cE 'PCI_DEVICE\(0x2646, *0x5013\)' "$pci")
np=$(grep -nE 'PCI_DEVICE\(0x2646, *0x5013\)' "$pci" | head -1 | cut -d: -f1)
if [ "$cnt" = 0 ]; then
  res FAIL "KC3000 entry (0x2646:0x5013) not found in pci.c."
else
  [ "$cnt" -gt 1 ] && res FAIL "KC3000 entry appears $cnt times in pci.c (duplicate)."
  if sed -n "${np},$((np+3))p" "$pci" | grep -q "$Q"; then
    res PASS "KC3000 entry (0x2646:0x5013) carries $Q."
  else
    res FAIL "KC3000 entry exists but does NOT carry $Q."
  fi
  echo '```c'; show "$pci" $((np-4)) $((np+5)) "$add_p"; echo '```'
fi
echo
} > "$tmp/s2"

# ---- 3. the logic (core.c) - the part that deserves real attention --------
{
echo '## 3. The logic (core.c) - READ THIS ONE'
echo
nc=$(grep -n "$Q" "$core" | head -1 | cut -d: -f1)
if [ -z "$nc" ]; then
  res FAIL "$Q is not used in core.c: nothing turns FUA off."
else
  fs=$(awk -v n="$nc" 'NR<=n && /^[a-z_][^;]*\(/ {s=NR} END{print s+0}' "$core")
  fe=$(awk -v n="$nc" 'NR>n && /^}/ {print NR; exit}' "$core")
  fname=$(sed -n "${fs}p" "$core" | grep -oE '[a-z_0-9]+\(' | head -1 | tr -d '(')
  clear=$((nc+1))
  if ! sed -n "${clear}p" "$core" | grep -q 'BLK_FEAT_FUA'; then
    res WARN "Line after the quirk test does not clear BLK_FEAT_FUA. Read the code below."
  fi
  grants=$(awk -v s="$fs" -v e="$fe" 'NR>=s && NR<=e && /BLK_FEAT_FUA/ && /\|=/ {print NR}' "$core" | tr '\n' ' ')
  commit=$(awk -v n="$nc" -v e="$fe" 'NR>n && NR<=e && /queue_limits_(commit_update|set)/ {print NR; exit}' "$core")
  if [ -z "$grants" ]; then
    res WARN "No line in $fname() grants FUA any more. FUA may now be set somewhere else: check by hand."
  else
    late=""; for g in $grants; do [ "$g" -gt "$clear" ] && late="$late $g"; done
    if [ -n "$late" ]; then
      res FAIL "FUA is granted AFTER our clear (line$late vs $clear). Patch applies but would do nothing."
    else
      res PASS "In $fname(): FUA is granted (line $(echo $grants)) BEFORE our clear (line $clear)."
    fi
  fi
  if [ -z "$commit" ]; then
    res WARN "No queue_limits_commit_update/set found after our clear in $fname(). Check the end of the function."
  else
    res PASS "Our clear comes before the limits are committed (line $commit)."
  fi
  echo "Function \`$fname()\`, lines $fs-$fe. \`+\` = added by our patch. Check three things:"
  echo "(a) FUA is granted, (b) our clear is AFTER that, (c) limits are committed AFTER our clear."
  echo
  echo '```c'; show "$core" "$fs" "$fe" "$add_c"; echo '```'
fi
echo
} > "$tmp/s3"

# ---- 4. other places in the nvme driver that talk about FUA ----------------
{
echo '## 4. Every FUA mention in drivers/nvme/host'
echo
echo '```'
( cd "$src" && grep -rnE --include='*.c' --include='*.h' 'BLK_FEAT_FUA|REQ_FUA|NVME_QUIRK_NO_FUA' drivers/nvme/host )
echo '```'
echo
} > "$tmp/s4"
nfiles=$(cd "$src" && grep -rlE --include='*.c' --include='*.h' 'BLK_FEAT_FUA' drivers/nvme/host | wc -l)
rejs=$(find "$H" -name '*.rej' | wc -l); origs=$(find "$H" -name '*.orig' | wc -l)
[ "$rejs" -gt 0 ]  && res FAIL "$rejs .rej file(s) in drivers/nvme/host: a patch hunk was rejected."
[ "$origs" -gt 0 ] && res INFO "$origs .orig backup(s) in drivers/nvme/host: some patch applied with an offset or fuzz (CachyOS's own patches too). Harmless, but ours must show PASS above."
[ "$nfiles" -gt 1 ] && res WARN "BLK_FEAT_FUA is now used in $nfiles nvme files (was only core.c). See section 4."

# ---- 5. kernel-side facts --------------------------------------------------
if grep -q 'define BLK_FEAT_FUA' "$blk" 2>/dev/null; then
  res PASS "BLK_FEAT_FUA still exists in include/linux/blkdev.h."
else
  res FAIL "BLK_FEAT_FUA is gone from include/linux/blkdev.h (block layer changed)."
fi
if grep -q 'nvme_quirk_name' "$nvmeh"; then
  if grep -q "case $Q" "$nvmeh"; then
    res INFO "nvme_quirk_name() knows our quirk."
  else
    res INFO "nvme_quirk_name() has no case for our quirk: only a compiler warning (same as your earlier builds)."
  fi
fi
if [ -f "$src/.config" ] && grep -q '^CONFIG_WERROR=y' "$src/.config"; then
  res WARN "CONFIG_WERROR=y: the missing nvme_quirk_name() case could turn a warning into a build error."
fi

# ---- unified diff of what our patch did, wide context for core.c -----------
{
  diff -U8  "$out/pre/drivers/nvme/host/nvme.h" "$out/post/drivers/nvme/host/nvme.h"
  diff -U6  "$out/pre/drivers/nvme/host/pci.c"  "$out/post/drivers/nvme/host/pci.c"
  diff -U40 "$out/pre/drivers/nvme/host/core.c" "$out/post/drivers/nvme/host/core.c"
} > "$out/fua.diff"

# ---- assemble the report ---------------------------------------------------
verdict="OK"; [ "$warns" -gt 0 ] && verdict="OK, but $warns WARN to read"; [ "$fails" -gt 0 ] && verdict="FAILED ($fails)"
{
  echo "# KC3000 FUA patch check: $(basename "$variant"), kernel $ver"
  echo
  echo "**Verdict: $verdict**"
  echo
  echo '| result | check |'; echo '|---|---|'; cat "$tmp/table"; echo
  cat "$tmp/s3" "$tmp/s1" "$tmp/s2" "$tmp/s4"
  echo '## After you boot the new kernel'
  echo
  echo '```'
  echo 'cat /sys/block/nvme*n1/queue/fua      # must print 0 for the KC3000'
  echo '```'
  echo
  echo "Full before/after diff: fua.diff. Whole patched files: post/."
} > "$out/report.md"

echo "[$(basename "$variant") $ver] $verdict  ->  $out/report.md"
grep -E '^\| (FAIL|WARN) ' "$tmp/table"
[ "$fails" -gt 0 ] && exit 1
exit 0
