# Updating the patched kernels: the routine

## The branches (and why)
- `main`  = what gets built. Pushing to it starts the builds.
- `test`  = where the cheap cloud check runs. Merging `test` into `main` is my approval.
- `upstream-import` = only upstream's own files (under `cachyos/`), one commit per sync.
  Never edit it by hand. Why: git then knows exactly what upstream changed since the last
  import, so a merge shows only real conflicts.

Rule: `main` only moves with `git merge --ff-only test`.
Why: the commit I checked is then exactly the commit that gets built.

## Every update
1. Start clean:
       git switch test && git reset --hard main
2. Get upstream's new files (safe even with a dirty folder):
       make import
3. Merge them (conflicts only in my PKGBUILDs; `git mergetool` opens meld):
       git merge upstream-import
4. In each variant folder:
       updpkgsums && makepkg --printsrcinfo > .SRCINFO
5. Cloud check, 10-15 min (pushes `test`, waits, downloads the reports):
       make check
6. Read `fua-check-remote/<variant>/report.md`. Section 3 (core.c) deserves real attention.
7. Approve and build:
       git switch main && git merge --ff-only test && git push
8. Packages -> `/srv/pacman-yerel`, `repo-add`.

## Good to know
- What did I change compared to upstream?
      git diff upstream-import main -- cachyos/linux-cachyos/PKGBUILD
- Abandoned an attempt? Next time push with `git push --force-with-lease`.
- Early warning without the cloud (seconds): `bash tools/check-fua-patch 7.3.6 6.18.65`
- After booting a new kernel: `cat /sys/block/nvme*n1/queue/fua`  (0 for the KC3000).
- If upstream adds or removes a file in a variant, `make import` stops and says so.
  Then edit the FILES line in tools/import-upstream.sh.
- GitHub's "Run workflow" button only shows workflows that exist on the default branch;
  pushing `test` always works.
- `updpkgsums` downloads the kernel and patches into the variant folder. `.gitignore` hides them;
  delete them whenever you like (they are ~150 MB per kernel version).
