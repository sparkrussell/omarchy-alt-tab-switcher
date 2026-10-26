#!/usr/bin/env bash
# Opt-in installer for the pre-push hook that runs the local CI gate.
#
#   bash scripts/install-git-hooks.sh [--uninstall]
#
# Writes <hooks dir>/pre-push, where the hooks dir comes from `git rev-parse --git-path hooks`
# (so it works from a linked worktree; all worktrees of one clone share it). Nothing global is
# touched: no git config is changed.
#
# The hook runs scripts/ci-local.sh once per distinct pushed commit (checked out into a temporary
# detached worktree under $HOME, so the state of the working tree does not matter) and blocks the push
# when the gate fails. It gates by the REMOTE ref (so `git push origin HEAD` is gated) and skips
# deletions and tag pushes.
#
# The hook passes no flags by default, so a SKIP does not block a push. Set CI_LOCAL_STRICT=1 to make
# the hook run `scripts/ci-local.sh --strict` - then a missing tool blocks the push too, which is the
# documented merge rule. The bypass is explicit and loud (git's own --no-verify also skips hooks,
# silently; do not use it):
#   CI_LOCAL_STRICT=1 git push
#   CI_LOCAL_SKIP=1 git push
#
# Re-running is a no-op. A different pre-push hook already there is kept as pre-push.bak-<timestamp>.
# --uninstall removes the hook, but only when this script wrote it.
set -u

MARK="# ci-local pre-push hook"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 2
cd "$ROOT" || exit 2
HOOKS="$(git rev-parse --git-path hooks 2>/dev/null)" || { echo "install-git-hooks: $ROOT is not a git checkout" >&2; exit 2; }
case "$HOOKS" in /*) ;; *) HOOKS="$ROOT/$HOOKS" ;; esac
HOOK="$HOOKS/pre-push"

hook_body() {
  cat <<'HOOK'
#!/bin/sh
# ci-local pre-push hook
# Installed by scripts/install-git-hooks.sh; remove with: bash scripts/install-git-hooks.sh --uninstall
# git feeds one line per pushed ref on stdin: <local ref> <local sha> <remote ref> <remote sha>
# The gate is run on the PUSHED COMMITS, each checked out into a temporary detached worktree, so the
# state of the working tree (dirty, wrong branch, untracked files) never decides the result.
pairs=""
while read -r local_ref local_sha remote_ref remote_sha; do
  # Decide by the REMOTE ref: the local ref is "HEAD" or a sha for `git push origin HEAD`.
  case "$remote_ref" in refs/heads/*) ;; *) continue ;; esac   # branches only (no tags, no notes)
  case "$local_sha" in *[!0]*) ;; *) continue ;; esac          # all zeros = branch deletion
  pairs="$pairs$local_sha $remote_ref
"
done
[ -n "$pairs" ] || exit 0

if [ "${CI_LOCAL_SKIP:-}" = "1" ]; then
  echo "" >&2
  echo "!!! WARNING: CI_LOCAL_SKIP=1 - the local CI gate (scripts/ci-local.sh) was NOT run for this push. !!!" >&2
  echo "!!! scripts/ci-local.sh is the authoritative gate, so NOTHING checked this push. Run it before merging. !!!" >&2
  echo "" >&2
  exit 0
fi

root=$(git rev-parse --show-toplevel 2>/dev/null)
[ -n "$root" ] && cd "$root" || { echo "pre-push: cannot find the repo root; push blocked. (Bypass: CI_LOCAL_SKIP=1 git push)" >&2; exit 1; }

created=""
cleanup() {
  printf '%s' "$created" | while IFS= read -r d; do
    [ -n "$d" ] || continue
    git -C "$root" worktree remove --force "$d" >/dev/null 2>&1
    rm -rf "$d"
  done
  git -C "$root" worktree prune >/dev/null 2>&1
}
trap cleanup EXIT
trap 'exit 130' INT TERM HUP

failed=0
for sha in $(printf '%s' "$pairs" | awk '!seen[$1]++ {print $1}'); do
  refs=$(printf '%s' "$pairs" | awk -v s="$sha" '$1 == s {printf " %s", $2}')
  short=$(printf '%s' "$sha" | cut -c1-9)
  echo "pre-push: local CI gate on pushed commit $short (to$refs) ..." >&2
  wt=$(mktemp -d "$HOME/tmp-prepush-XXXXXX") || { echo "pre-push: cannot create a temp dir under \$HOME; push blocked." >&2; exit 1; }
  created="$created$wt
"
  if ! git worktree add -q --detach "$wt" "$sha" >/dev/null 2>&1; then
    echo "pre-push: cannot check out $short into a temporary worktree; push blocked." >&2
    failed=1
    continue
  fi
  if [ ! -f "$wt/scripts/ci-local.sh" ]; then
    echo "pre-push: commit $short has no scripts/ci-local.sh (an older commit?); push blocked. (Bypass: CI_LOCAL_SKIP=1 git push)" >&2
    failed=1
    continue
  fi
  # git exports repository variables to hooks; the gate runs its own commands, so do not leak them.
  # CI_LOCAL_STRICT=1 adds --strict so a SKIP blocks the push as well. The expansion yields either
  # exactly "--strict" or nothing, so the variable's value is never word-split into the command.
  if ( unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_PREFIX GIT_COMMON_DIR; cd "$wt" && bash scripts/ci-local.sh ${CI_LOCAL_STRICT:+--strict} </dev/null >&2 ); then
    :
  else
    echo "pre-push: the local CI gate FAILED on commit $short." >&2
    failed=1
  fi
done

if [ "$failed" -ne 0 ]; then
  echo "" >&2
  echo "pre-push: push blocked. Fix it and push again." >&2
  echo "          (Explicit bypass, which warns loudly: CI_LOCAL_SKIP=1 git push)" >&2
  exit 1
fi
exit 0
HOOK
}

if [ "${1:-}" = "--uninstall" ]; then
  if [ ! -e "$HOOK" ]; then echo "install-git-hooks: no pre-push hook at $HOOK; nothing to remove."; exit 0; fi
  if grep -qF "$MARK" "$HOOK"; then
    rm -f "$HOOK" && echo "install-git-hooks: removed $HOOK"
  else
    echo "install-git-hooks: $HOOK was not written by this script; left in place."
  fi
  ls "$HOOKS"/pre-push.bak-* >/dev/null 2>&1 && echo "install-git-hooks: earlier hook backups remain in $HOOKS (pre-push.bak-*); restore one by hand if you want it back."
  exit 0
fi
[ $# -eq 0 ] || { echo "usage: bash scripts/install-git-hooks.sh [--uninstall]" >&2; exit 2; }

mkdir -p "$HOOKS" || exit 2
NEW="$(mktemp "$HOOKS/.pre-push.new.XXXXXX")" || exit 2
trap 'rm -f "$NEW"' EXIT
hook_body >"$NEW"
chmod 0755 "$NEW"

if [ -e "$HOOK" ]; then
  if cmp -s "$NEW" "$HOOK"; then
    chmod 0755 "$HOOK"
    echo "install-git-hooks: pre-push hook already installed at $HOOK (no change)."
    exit 0
  fi
  if ! grep -qF "$MARK" "$HOOK"; then
    BAK="$HOOK.bak-$(date +%Y%m%d-%H%M%S)"
    mv "$HOOK" "$BAK" || exit 2
    echo "install-git-hooks: an existing, different pre-push hook was moved to $BAK (it is no longer run; chain it by hand if you need it)."
  else
    echo "install-git-hooks: updating this script's earlier pre-push hook."
  fi
fi
mv "$NEW" "$HOOK" || exit 2
echo "install-git-hooks: installed $HOOK"
echo "  git push now runs scripts/ci-local.sh first and blocks on failure. A SKIP does not block unless"
echo "  you push with CI_LOCAL_STRICT=1. Bypass (loud): CI_LOCAL_SKIP=1 git push"
