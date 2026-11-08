#!/bin/sh
# Points this clone at the tracked hooks. The path is absolute on purpose: a relative
# core.hooksPath is resolved against the current directory, so committing from a
# subdirectory would silently skip the hook.
#
# core.hooksPath is shared by every worktree of a clone, so it must point at the main
# checkout, never at a worktree: run from a worktree, --show-toplevel would point every
# worktree at that one, and removing it would silently disable the hook everywhere. The
# hook itself runs in whichever worktree commits (it uses --show-toplevel there).
set -e
common="$(git rev-parse --path-format=absolute --git-common-dir)"
root="$(dirname "$common")"
if [ ! -f "$root/scripts/git-hooks/pre-commit" ]; then
    echo "no scripts/git-hooks/pre-commit in the main checkout ($root)" >&2
    exit 1
fi
chmod +x "$root/scripts/git-hooks/pre-commit"
git -C "$root" config core.hooksPath "$root/scripts/git-hooks"
echo "hooks installed: $(git -C "$root" config core.hooksPath)"
