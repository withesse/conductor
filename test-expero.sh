#!/bin/bash
# test-expero.sh — Regression tests for expero.sh
#
# Usage: bash test-expero.sh
# Exit code: 0 if all pass, 1 if any fail.

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
EXPERO="$SCRIPT_DIR/expero.sh"
TMPDIR=$(mktemp -d -t expero-test.XXXXXX)
trap 'rm -rf "$TMPDIR"' EXIT

if [ ! -f "$EXPERO" ]; then
  echo "expero.sh not found at $EXPERO" >&2
  exit 2
fi

PASS=0
FAIL=0

# Colors (disabled if stdout is not a TTY)
if [ -t 1 ]; then
  GREEN='\033[0;32m'; RED='\033[0;31m'; DIM='\033[2m'; NC='\033[0m'
else
  GREEN=''; RED=''; DIM=''; NC=''
fi

pass() { echo -e "  ${GREEN}✓${NC} $1"; PASS=$((PASS+1)); }
fail() { echo -e "  ${RED}✗${NC} $1 ${DIM}$2${NC}"; FAIL=$((FAIL+1)); }

assert_zero()    { local n=$1 c=$2 rc; eval "$c" >/dev/null 2>&1; rc=$?; [ "$rc" -eq 0 ] && pass "$n" || fail "$n" "(rc=$rc)"; }
assert_nonzero() { local n=$1 c=$2 rc; eval "$c" >/dev/null 2>&1; rc=$?; [ "$rc" -ne 0 ] && pass "$n" || fail "$n" "(rc=$rc)"; }
assert_match()   { local n=$1 c=$2 p=$3 o; o=$(eval "$c" 2>&1); echo "$o" | grep -qE -- "$p" && pass "$n" || fail "$n" "(no match for /$p/)"; }
assert_eq()      { local n=$1 a=$2 e=$3; [ "$a" = "$e" ] && pass "$n" || fail "$n" "(got '$a' want '$e')"; }

# Call functions from expero.sh in an isolated bash subshell. The dispatch
# guard inside expero.sh skips main when sourced, so it's safe.
resolve_model() {
  bash -c "source '$EXPERO' >/dev/null 2>&1 && model_for_role '$1' '$2'" 2>/dev/null
}

SCENARIOS="new-product migration refactor legacy-analysis security-audit tech-docs multi-service greenfield-library"

echo "== T1: help command =="
assert_zero  "help exits 0"         "bash '$EXPERO' help"
assert_match "help lists scenarios" "bash '$EXPERO' help" "Scenarios:"
assert_match "help lists tools"     "bash '$EXPERO' help" "gemini"

echo ""
echo "== T2: init generates expected files for every scenario =="
for s in $SCENARIOS; do
  assert_zero "init $s succeeds"         "bash '$EXPERO' init '$TMPDIR/$s' '$s'"
  assert_zero "  config.yaml generated"  "[ -f '$TMPDIR/$s/.expero/config.yaml' ]"
  assert_zero "  roadmap.md generated"   "[ -f '$TMPDIR/$s/.expero/docs/roadmap.md' ]"
  assert_zero "  CLAUDE.md generated"    "[ -f '$TMPDIR/$s/CLAUDE.md' ]"
  assert_zero "  expero.sh bootstrapped" "[ -x '$TMPDIR/$s/expero.sh' ]"
done

echo ""
echo "== T3: config.yaml embeds correct model IDs =="
for s in $SCENARIOS; do
  assert_match "  reasoning ($s)" "cat '$TMPDIR/$s/.expero/config.yaml'" "reasoning:[[:space:]]+claude-opus-4-7"
  assert_match "  execution ($s)" "cat '$TMPDIR/$s/.expero/config.yaml'" "execution:[[:space:]]+claude-sonnet-4-6"
  assert_match "  template  ($s)" "cat '$TMPDIR/$s/.expero/config.yaml'" "template:[[:space:]]+claude-haiku-4-5"
done

echo ""
echo "== T4: scenario-specific extension lists =="
assert_match "legacy-analysis has archaeologist"    "cat '$TMPDIR/legacy-analysis/.expero/config.yaml'"    "- archaeologist"
assert_match "legacy-analysis has scribe"           "cat '$TMPDIR/legacy-analysis/.expero/config.yaml'"    "- scribe"
assert_match "security-audit has sentinel"          "cat '$TMPDIR/security-audit/.expero/config.yaml'"     "- sentinel"
assert_match "tech-docs has scribe"                 "cat '$TMPDIR/tech-docs/.expero/config.yaml'"          "- scribe"
assert_match "greenfield-library has scribe"        "cat '$TMPDIR/greenfield-library/.expero/config.yaml'" "- scribe"
assert_match "greenfield-library has sentinel"      "cat '$TMPDIR/greenfield-library/.expero/config.yaml'" "- sentinel"

# Heredoc regression guard: no leaked bash fragments should ever appear
# in config.yaml (e.g. `echo "..."`, `case ...)`, `esac`).
for s in $SCENARIOS; do
  if grep -qE '(^[[:space:]]*echo )|(^esac)|(^[[:space:]]*[a-z-]+\)[[:space:]]+echo )' "$TMPDIR/$s/.expero/config.yaml"; then
    fail "config.yaml has no leaked shell fragments ($s)" "(found bash body)"
  else
    pass "config.yaml has no leaked shell fragments ($s)"
  fi
done

echo ""
echo "== T5: CLAUDE.md 'Roles Enabled' line is populated =="
for s in $SCENARIOS; do
  line=$(awk '/^## Roles Enabled/{getline; print}' "$TMPDIR/$s/CLAUDE.md")
  if [ -n "$line" ] && echo "$line" | grep -qE "(planner|sentinel|archaeologist)"; then
    pass "  $s → $line"
  else
    fail "  $s non-empty roles line" "(got: '$line')"
  fi
done

echo ""
echo "== T5b: CLAUDE.md template sections carry concrete guidance =="
# Guard against future template regressions that strip sections back to bare
# placeholders. Each required section must exist and include at least one
# example token ("e.g." or "TBD" or "filled in") beyond plain <!-- comments -->.
REQUIRED_SECTIONS="Project Context|Architecture Rules|Build Commands|Extension Points|Key ADRs|Expero Protocol"
for s in $SCENARIOS; do
  claude_md="$TMPDIR/$s/CLAUDE.md"
  for section in "Project Context" "Build Commands" "Key ADRs"; do
    if ! grep -qE "^## ${section}$" "$claude_md"; then
      fail "  $s has ## $section"    "(missing section)"
      continue
    fi
    # pull lines until the next '## '
    body=$(awk "/^## ${section}\$/{flag=1; next} /^## /{flag=0} flag" "$claude_md")
    if [ -z "$body" ] || ! echo "$body" | grep -qE "(e\.g\.|TBD|Replace|See |numeric order)"; then
      fail "  $s '$section' body has concrete guidance" "(body too thin)"
    else
      pass "  $s '$section' has guidance"
    fi
  done
done

echo ""
echo "== T6: status reports correct initial task counts =="
new_product_status=$(cd "$TMPDIR/new-product" && bash expero.sh status 2>&1)
echo "$new_product_status" | grep -qE "todo:[[:space:]]+7"    && pass "new-product todo: 7"    || fail "new-product todo: 7"    "(missing)"
echo "$new_product_status" | grep -qE "blocked:[[:space:]]+0" && pass "new-product blocked: 0" || fail "new-product blocked: 0" "(missing)"

echo ""
echo "== T7: stop signal detection (inject and re-check) =="
echo "| M0-999 | arch review probe | todo | builder | — | NEEDS_ARCH_REVIEW |" \
    >> "$TMPDIR/new-product/.expero/docs/roadmap.md"
injected_status=$(cd "$TMPDIR/new-product" && bash expero.sh status 2>&1)
echo "$injected_status" | grep -qE "NEEDS_ARCH_REVIEW:[[:space:]]+1" && pass "arch review signal picked up" || fail "arch review signal picked up" "(missing)"
echo "$injected_status" | grep -qE "Pending stop signals"             && pass "warning printed"              || fail "warning printed"              "(missing)"

echo ""
echo "== T8: model_for_role resolves 24 (role × tool) combos =="
check() { assert_eq "$2 + $1" "$(resolve_model "$1" "$2")" "$3"; }
for r in architect sentinel archaeologist; do
  check "$r" claude "claude-opus-4-7"
  check "$r" codex  "gpt-5.4-pro"
  check "$r" gemini "gemini-3.1-pro"
done
for r in planner builder critic scribe; do
  check "$r" claude "claude-sonnet-4-6"
  check "$r" codex  "gpt-5.4"
  check "$r" gemini "gemini-3-flash"
done
check verifier claude "claude-haiku-4-5-20251001"
check verifier codex  "gpt-5.4-mini"
check verifier gemini "gemini-3.1-flash-lite"

echo ""
echo "== T9: restart exits non-zero in bare directory =="
mkdir -p "$TMPDIR/bare"
pushd "$TMPDIR/bare" >/dev/null
assert_nonzero "restart fails without CLAUDE.md" "bash '$EXPERO' restart"
popd >/dev/null

echo ""
echo "─────────────────────────────────────────"
TOTAL=$((PASS + FAIL))
if [ "$FAIL" -eq 0 ]; then
  echo -e "${GREEN}All ${TOTAL} tests passed.${NC}"
  exit 0
else
  echo -e "${RED}${FAIL} failed${NC}, ${PASS} passed (${TOTAL} total)"
  exit 1
fi
