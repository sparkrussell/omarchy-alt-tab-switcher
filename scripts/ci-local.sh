#!/usr/bin/env bash
# The local CI gate. GitHub Actions is disabled at the repository level for this repo, so this script
# is the authoritative gate. It runs the three checks .github/workflows/ci.yml still lists (that file
# is kept only as the record of what the gate mirrors), from the repo root whatever the caller's cwd:
#   a. luacheck hypr/switcher.lua     (respects this repo's .luacheckrc)
#   b. qmlformat Service.qml          (grammar parse only; a syntax error exits non-zero)
#   c. plugin manifest: the jq assertions at the core of `omarchy plugin validate` (schemaVersion 1,
#      id shape, id not in the reserved omarchy.* namespace, non-empty name and version,
#      kinds == ["service"], entryPoints.service == "Service.qml"), then that Service.qml exists and
#      that the plugin folder contains no symlinks.
# Every step runs even if an earlier one failed; the exit status is non-zero if any step FAILED.
#
# A check whose tool is not installed reports SKIP - never a silent pass - and prints the exact
# install command. --strict promotes SKIP to FAIL, which is the merge rule once the tools exist.
#
#   bash scripts/ci-local.sh [--strict]
#
# Merge rule: a PR merges only after `bash scripts/ci-local.sh --strict` exits 0 on a machine with
# jq, luacheck and qmlformat installed. See "CI is the local gate" in README.md.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || { echo "ci-local: cannot resolve the repo root from ${BASH_SOURCE[0]}" >&2; exit 2; }
[ -f "$ROOT/manifest.json" ] || {
  echo "ci-local: $ROOT does not look like the omarchy-alt-tab-switcher checkout (no manifest.json at its root)" >&2
  exit 2
}
cd "$ROOT" || { echo "ci-local: cannot enter $ROOT" >&2; exit 2; }

STRICT=0
for arg in "$@"; do
  case "$arg" in
    --strict) STRICT=1 ;;
    -h|--help) sed -n '2,/^set -u/{/^set -u/!s/^# \{0,1\}//p}' "$0"; exit 0 ;;
    *) echo "ci-local: unknown flag: $arg" >&2; exit 2 ;;
  esac
done

# /tmp is not where scratch belongs on this machine; use a fresh dir under $HOME and remove it on exit.
SCRATCH="$HOME/tmp-ci-local-$$"
mkdir -p "$SCRATCH" || { echo "ci-local: cannot create $SCRATCH" >&2; exit 2; }
export TMPDIR="$SCRATCH"
cleanup() { rm -rf "$SCRATCH"; }
trap cleanup EXIT
trap 'echo "ci-local: interrupted" >&2; exit 130' INT TERM

# CI_LOCAL_SKIP only means something to the pre-push hook; do not let it reach the steps.
unset CI_LOCAL_SKIP

LUACHECK_INSTALL='sudo pacman -S --needed lua luarocks && sudo luarocks install luacheck 1.2.0'
QMLFORMAT_INSTALL='sudo pacman -S --needed qt6-declarative'
JQ_INSTALL='sudo pacman -S --needed jq'

# qmlformat is not on PATH on every install; Qt 6 puts it under /usr/lib/qt6/bin.
QMLFORMAT=""
if command -v qmlformat >/dev/null 2>&1; then
  QMLFORMAT="$(command -v qmlformat)"
elif [ -x /usr/lib/qt6/bin/qmlformat ]; then
  QMLFORMAT=/usr/lib/qt6/bin/qmlformat
fi

DEGRADED=0
if ! command -v luacheck >/dev/null 2>&1; then DEGRADED=1; fi
if [ -z "$QMLFORMAT" ]; then DEGRADED=1; fi
if [ "$DEGRADED" -eq 1 ]; then
  echo "WARN: degraded gate - a tool is missing, so at least one step will SKIP instead of checking anything:"
  command -v luacheck >/dev/null 2>&1 || echo "WARN:   luacheck not installed (step a)  install: $LUACHECK_INSTALL"
  [ -n "$QMLFORMAT" ] || echo "WARN:   qmlformat not installed (step b)  install: $QMLFORMAT_INSTALL"
  echo "WARN: a SKIP is not a pass. Use --strict to make this run fail until the tools are installed."
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "WARN: jq not installed: step c has nothing to validate the manifest with and will FAIL  (install: $JQ_INSTALL)"
fi

NAMES=() RESULTS=() DETAILS=()
ANY_FAIL=0

# run_step <name> <log> <command...>: runs the command, keeps its output in <log>, prints PASS/FAIL.
# Sets STEP_RC. On failure it shows the telling lines and the log tail so the cause is visible.
run_step() {
  local name="$1" log="$2"
  shift 2
  echo
  echo "=== $name"
  "$@" >"$log" 2>&1
  STEP_RC=$?
  if [ "$STEP_RC" -eq 0 ]; then
    echo "--- PASS: $name"
  else
    ANY_FAIL=1
    echo "--- FAIL: $name (exit $STEP_RC)"
    grep -E 'false|null|FAIL|error|Error|does not exist|symlink|WARNING' "$log" | head -20 | sed 's/^/    /'
    echo "    ... last lines of output:"
    tail -n 15 "$log" | sed 's/^/    | /'
  fi
}

# skip_step <short name> <heading> <tool> <install command>: a missing tool is SKIP, loudly, never a pass.
skip_step() {
  echo
  echo "=== $2"
  echo "--- SKIP: $3 is not installed, so nothing was checked"
  echo "    install: $4"
  record "$1" SKIP "$3 not installed"
}

record() { NAMES+=("$1"); RESULTS+=("$2"); DETAILS+=("$3"); }

# --- a. Lua lint -------------------------------------------------------------------------------
# An exit 0 that did not actually lint switcher.lua is not a pass, so the check proves itself.
step_lua() {
  local log="$SCRATCH/a.raw.log"
  luacheck hypr/switcher.lua >"$log" 2>&1 || { cat "$log"; echo "luacheck reported problems above"; return 1; }
  cat "$log"
  grep -q 'hypr/switcher.lua' "$log" || { echo "FAIL: luacheck exited 0 without linting hypr/switcher.lua"; return 1; }
  grep -qE '^Total: .* in [1-9][0-9]* files?' "$log" || { echo "FAIL: luacheck printed no summary line, so it linted no file"; return 1; }
  return 0
}

if command -v luacheck >/dev/null 2>&1; then
  run_step "a. Lua lint (luacheck hypr/switcher.lua)" "$SCRATCH/a.log" step_lua
  rc=$STEP_RC
  detail="$(grep -E '^Total:' "$SCRATCH/a.log" | tail -n1)"
  [ -n "$detail" ] && [ "$rc" -eq 0 ] && echo "    $detail"
  record "a. lua lint" "$([ "$rc" -eq 0 ] && echo PASS || echo FAIL)" "${detail:-luacheck failed}"
else
  skip_step "a. lua lint" "a. Lua lint (luacheck)" luacheck "$LUACHECK_INSTALL"
fi

# --- b. QML parse check ------------------------------------------------------------------------
# qmlformat 6.x exits non-zero and prints nothing on a grammar error, so say what happened.
step_qml() {
  local log="$SCRATCH/b.raw.log"
  if "$QMLFORMAT" Service.qml >"$log" 2>&1; then
    cat "$log"
  else
    rc=$?
    cat "$log"
    echo "qmlformat could not parse Service.qml (exit $rc). This Qt version prints no diagnostic for a"
    echo "grammar error; reproduce it directly with: $QMLFORMAT Service.qml"
    return "$rc"
  fi
  # qmlformat prints the formatted document: no output means it parsed nothing, which is not a pass.
  [ -s "$log" ] || { echo "FAIL: qmlformat produced no output, so it did not parse Service.qml"; return 1; }
  return 0
}

if [ -n "$QMLFORMAT" ]; then
  run_step "b. QML parse check ($QMLFORMAT Service.qml)" "$SCRATCH/b.log" step_qml
  rc=$STEP_RC
  if [ "$rc" -eq 0 ]; then
    detail="$("$QMLFORMAT" --version 2>/dev/null || echo qmlformat) parsed Service.qml"
    echo "    $detail"
  else
    detail="parse error"
  fi
  record "b. qml parse" "$([ "$rc" -eq 0 ] && echo PASS || echo FAIL)" "$detail"
else
  skip_step "b. qml parse" "b. QML parse check (qmlformat)" qmlformat "$QMLFORMAT_INSTALL"
fi

# --- c. Plugin manifest ------------------------------------------------------------------------
# Mirrors the workflow's jq -e expression, then the two checks `omarchy plugin validate` also makes.
step_manifest() {
  if ! command -v jq >/dev/null 2>&1; then
    echo "FAIL: jq is not installed, so manifest.json cannot be validated at all."
    echo "      install: $JQ_INSTALL"
    return 1
  fi
  jq -e '.schemaVersion == 1
    and (.id | test("^[A-Za-z0-9][A-Za-z0-9._-]*$")) and (.id | startswith("omarchy.") | not)
    and (.name | length > 0) and (.version | length > 0)
    and (.kinds == ["service"]) and (.entryPoints.service == "Service.qml")' manifest.json \
    || { echo "manifest.json failed an omarchy plugin validate assertion (false/null above is the failing field)"; return 1; }
  test -f Service.qml || { echo "FAIL: entryPoints.service points at Service.qml, which does not exist"; return 1; }
  links="$(find . -name .git -prune -o -type l -print)"
  [ -z "$links" ] || { echo "FAIL: symlinks are not allowed in the plugin folder:"; printf '%s\n' "$links"; return 1; }
  echo "manifest OK: $(jq -r '"\(.id) v\(.version) kinds=\(.kinds | join(",")) service=\(.entryPoints.service)"' manifest.json)"
}

run_step "c. Plugin manifest (omarchy plugin validate core)" "$SCRATCH/c.log" step_manifest
rc=$STEP_RC
if [ "$rc" -eq 0 ]; then
  detail="$(tail -n1 "$SCRATCH/c.log")"
  echo "    $detail"
else
  detail="failed (see the output above)"
fi
record "c. manifest" "$([ "$rc" -eq 0 ] && echo PASS || echo FAIL)" "$detail"

# --- summary -----------------------------------------------------------------------------------
echo
dirty=""; [ -n "$(git -C "$ROOT" status --porcelain 2>/dev/null)" ] && dirty=" + uncommitted changes"
echo "=== SUMMARY (head $(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo '?')$dirty)"
passed=0 failed=0 skipped=0
for i in "${!NAMES[@]}"; do
  printf '  %-12s %-5s %s\n' "${NAMES[$i]}" "${RESULTS[$i]}" "${DETAILS[$i]}"
  case "${RESULTS[$i]}" in
    PASS) passed=$((passed + 1)) ;;
    FAIL) failed=$((failed + 1)) ;;
    SKIP) skipped=$((skipped + 1)) ;;
  esac
done
echo "  steps: $passed passed, $failed failed, $skipped skipped"

if [ "$STRICT" -eq 1 ] && [ "$skipped" -gt 0 ]; then
  echo "ci-local: FAILED (--strict: $skipped skipped step(s) count as failed; install the missing tools)"
  exit 1
fi
if [ "$ANY_FAIL" -ne 0 ] || [ "$failed" -ne 0 ]; then
  echo "ci-local: FAILED"
  exit 1
fi
if [ "$skipped" -gt 0 ]; then
  echo "ci-local: PASS (degraded: $skipped step(s) skipped - not a merge signal; re-run with --strict once the tools are installed)"
else
  echo "ci-local: ALL PASS"
fi
exit 0
