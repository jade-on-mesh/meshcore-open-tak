#!/usr/bin/env bash
# Teach git's rerere ("reuse recorded resolution") every conflict resolution
# already made in this repository's merge commits, so the upstream sync can
# replay them when the same conflict comes back, instead of stopping.
#
# For each merge commit (newest first, up to $1, default 60) reachable from
# the given refs: redo the merge; if it conflicts, record the conflict, then
# take the committed result as its resolution. Leaves the work tree as it was.
#
#   .github/scripts/rerere-train.sh [max-merges] [refs...]
set -uo pipefail
max="${1:-60}"; shift || true
refs=("$@"); [ ${#refs[@]} -eq 0 ] && refs=(HEAD)

git config rerere.enabled true
git config rerere.autoupdate true
orig=$(git symbolic-ref -q --short HEAD || git rev-parse HEAD)
learned=0

for c in $(git rev-list --merges --max-count="$max" "${refs[@]}"); do
  parents=($(git rev-parse "$c^@"))
  [ ${#parents[@]} -ge 2 ] || continue
  git checkout -q --detach "${parents[0]}" 2>/dev/null || continue
  if git merge -q --no-edit --no-ff "${parents[@]:1}" >/dev/null 2>&1; then
    git reset -q --hard "${parents[0]}"
    continue
  fi
  # Conflicted: rerere has the preimage now; the merge commit is the answer.
  if [ -n "$(git ls-files -u)" ]; then
    git checkout -q "$c" -- . 2>/dev/null && git rerere >/dev/null 2>&1 && learned=$((learned + 1))
  fi
  git reset -q --hard "${parents[0]}"
done

git checkout -q "$orig"
echo "rerere: learned from $learned conflicted merge(s); $(ls .git/rr-cache 2>/dev/null | wc -l) resolution(s) on record"
