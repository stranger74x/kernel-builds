#!/usr/bin/env bash
# import-upstream.sh - copy upstream's files for MY variants onto the branch
# `upstream-import` (under cachyos/), as one commit "Import upstream <hash>".
#
# Usage: tools/import-upstream.sh [upstream-commit]     (default: upstream/master)
#
# Why: `upstream-import` only ever contains upstream's own files, nothing of mine.
# When I later run `git merge upstream-import`, git uses the PREVIOUS import as the
# common base by itself, so only real conflicts are left. It also works while my
# working folder is dirty (it uses a temporary extra checkout).
set -eu
DEST=cachyos                      # my repo keeps one folder per distro
VARIANTS="linux-cachyos linux-cachyos-lts"
FILES="PKGBUILD .SRCINFO config"
BRANCH=upstream-import

top=$(git rev-parse --show-toplevel)
cd "$top"
git fetch -q upstream
ref=$(git rev-parse --verify "${1:-upstream/master}^{commit}")
short=${ref:0:8}

if ! git rev-parse -q --verify "refs/heads/$BRANCH" >/dev/null; then   # first run only
  root=$(git commit-tree "$(git hash-object -t tree /dev/null)" -m "Start of the upstream-import branch")
  git branch "$BRANCH" "$root"
fi

tmp=$(mktemp -d)
git worktree add -q "$tmp" "$BRANCH"
cleanup() { cd "$top"; git worktree remove --force "$tmp" 2>/dev/null || true; }
trap cleanup EXIT
cd "$tmp"

for v in $VARIANTS; do
  mkdir -p "$DEST/$v"
  for f in $FILES; do
    git show "$ref:$v/$f" > "$DEST/$v/$f" 2>/dev/null || { echo "upstream $short has no $v/$f - look at what changed upstream"; exit 1; }
  done
done
git show "$ref:LICENSE.md" > "$DEST/LICENSE.md"

git add -A
if git diff --cached --quiet; then echo "Already up to date (upstream $short)."; exit 0; fi
git commit -q -m "Import upstream $short" -m "Upstream commit says: $(git log -1 --format=%s "$ref")"
echo "Imported upstream $short onto $BRANCH."
git log --oneline -2 | sed 's/^/  /'
