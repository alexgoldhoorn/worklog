#!/bin/sh
# Points this clone at the tracked hooks. The path is absolute on purpose: a relative
# core.hooksPath is resolved against the current directory, so committing from a
# subdirectory would silently skip the hook.
set -e
root="$(git rev-parse --show-toplevel)"
chmod +x "$root/scripts/git-hooks/pre-commit"
git -C "$root" config core.hooksPath "$root/scripts/git-hooks"
echo "hooks installed: $(git -C "$root" config core.hooksPath)"
