#!/usr/bin/env bash
# The local CI gate, and the authoritative one: this script, not GitHub, decides whether a change is
# good. .github/workflows/ci.yml is retained only as the record of what the gate mirrors - it no
# longer triggers on push or on pull request (workflow_dispatch only), so a check there says nothing
# about a commit. This runs the three checks the workflow lists, from the repo root whatever the
# caller's cwd:
#   a. luacheck hypr/switcher.lua     (respects this repo's .luacheckrc)
#   b. qmlformat Service.qml          (grammar parse only; a syntax error exits non-zero)
#   c. plugin manifest: the jq assertions at the core of `omarchy plugin validate` (schemaVersion 1,
#      id shape, id not in the reserved omarchy.* namespace, non-empty name and version,
#      kinds == ["service"], entryPoints.service == "Service.qml"), then that Service.qml exists and
#      that the plugin folder contains no symlinks.
# Every step runs even if an earlier one failed; the exit status is non-zero if any step FAILED.
#
# A check whose tool is not installed reports SKIP - never a silent pass - and prints the exact
# install command. --strict promotes SKIP to FAIL, which is the merge rule. luacheck must be built
# against Lua 5.4: a Lua 5.5 build dies on first require, so the install hint pins the version.
#
#   bash scripts/ci-local.sh [--strict]
#
# Merge rule: a PR merges only after `bash scripts/ci-local.sh --strict` exits 0. See "CI is the
# local gate" in README.md.
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

# luacheck has to run on Lua 5.4: a rockspec built against the machine's default Lua 5.5 dies on
# first require ("attempt to assign to const variable 'field_name'"), so the tree is pinned.
# The hint is printed for the user to paste, so $HOME must stay literal.
# shellcheck disable=SC2016
LUACHECK_INSTALL='luarocks --lua-version=5.4 --tree="$HOME/.luarocks54" install luacheck 1.2.0 && ln -sfn "$HOME/.luarocks54/bin/luacheck" "$HOME/.local/bin/luacheck"'
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
  if [ "$rc" -eq 0 ]; then
    detail="$(grep -E '^Total:' "$SCRATCH/a.log" | tail -n1)"
    [ -n "$detail" ] && echo "    $detail"
    record "a. lua lint" PASS "${detail:-luacheck passed}"
  else
    # Never quote luacheck's own "Total:" line as the detail of a FAILURE: a guard that fired on an
    # exit-0 run still leaves "Total: 0 warnings / 0 errors" in the log, and that reads like a pass.
    detail="$(grep -m1 -E '^(FAIL:|luacheck reported problems)' "$SCRATCH/a.log")"
    record "a. lua lint" FAIL "${detail:-luacheck failed (exit $rc)}"
  fi
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
  # qmlformat prints the formatted document. Empty output, a usage/help dump, or output that does not
  # look like a QML document means it never parsed Service.qml - which is a FAIL, not a pass.
  [ -s "$log" ] || { echo "FAIL: qmlformat produced no output, so it did not parse Service.qml"; return 1; }
  if grep -qE '^[[:space:]]*[Uu]sage:' "$log"; then
    echo "FAIL: qmlformat printed a usage string instead of a formatted document, so it parsed nothing:"
    head -n 3 "$log" | sed 's/^/    /'
    return 1
  fi
  # A formatted QML document opens with an import statement or the root object ("Item {"), and it is
  # far larger than any diagnostic; both have to hold before an exit 0 counts as a parse.
  first_code="$(grep -vE '^[[:space:]]*(//|$)' "$log" | head -n 1)"
  case "$first_code" in
    import\ *|[A-Za-z_][A-Za-z0-9_.]*[[:space:]]*\{*) : ;;
    *)
      echo "FAIL: qmlformat output does not begin like a QML document, so it did not parse Service.qml"
      echo "      first line of output: ${first_code:-<no code line>}"
      return 1
      ;;
  esac
  bytes="$(wc -c <"$log")"
  if [ "$bytes" -lt 256 ] || ! grep -q '{' "$log"; then
    echo "FAIL: qmlformat output is $bytes bytes and has no object body, too small to be formatted Service.qml"
    return 1
  fi
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

# One final line whatever went wrong, naming FAILURES FIRST and then skips. Blaming only the skips
# sends a triager off to install luacheck while a real failure sits in the same run.
names_by() {
  local want="$1" out="" i
  for i in "${!NAMES[@]}"; do
    [ "${RESULTS[$i]}" = "$want" ] || continue
    out="${out:+$out, }${NAMES[$i]}"
  done
  printf '%s' "$out"
}

strict_skip=0
[ "$STRICT" -eq 1 ] && [ "$skipped" -gt 0 ] && strict_skip=1

if [ "$ANY_FAIL" -ne 0 ] || [ "$failed" -ne 0 ] || [ "$strict_skip" -eq 1 ]; then
  line="ci-local: FAILED ($failed failed, $skipped skipped"
  [ "$strict_skip" -eq 1 ] && line="$line; --strict: a SKIP counts as a failure"
  line="$line)"
  failed_names="$(names_by FAIL)"
  skipped_names="$(names_by SKIP)"
  [ -n "$failed_names" ] && line="$line - failed: $failed_names"
  [ -n "$skipped_names" ] && line="$line - skipped: $skipped_names"
  echo "$line"
  exit 1
fi
if [ "$skipped" -gt 0 ]; then
  echo "ci-local: PASS (degraded: $skipped step(s) skipped - not a merge signal; re-run with --strict once the tools are installed)"
else
  echo "ci-local: ALL PASS"
fi
exit 0
