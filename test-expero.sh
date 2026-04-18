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
  assert_zero "  AGENTS.md generated"    "[ -f '$TMPDIR/$s/AGENTS.md' ]"
  assert_zero "  expero.sh bootstrapped" "[ -x '$TMPDIR/$s/expero.sh' ]"
done

echo ""
echo "== T2b: AGENTS.md covers Role Quick Reference + Stop Signal Syntax =="
# Only need to check one scenario — _gen_agents_md does not branch on scenario.
AGENTS_MD="$TMPDIR/new-product/AGENTS.md"
assert_match "  Role Quick Reference section present" "cat '$AGENTS_MD'" "^## Role Quick Reference"
assert_match "  Stop Signal Syntax section present"   "cat '$AGENTS_MD'" "^## Stop Signal Syntax"
assert_match "  table lists 8 roles (planner)"        "cat '$AGENTS_MD'" "\\| planner +\\|"
assert_match "  table lists 8 roles (archaeologist)"  "cat '$AGENTS_MD'" "\\| archaeologist +\\|"
assert_match "  doc mentions NEEDS_ARCH_REVIEW"       "cat '$AGENTS_MD'" "NEEDS_ARCH_REVIEW"
assert_match "  doc mentions BLOCKED_BY_"             "cat '$AGENTS_MD'" "BLOCKED_BY_"

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
echo "== T10: CHANGELOG.md + .expero/signals generated by init =="
for s in $SCENARIOS; do
  assert_zero  "  CHANGELOG.md ($s)"        "[ -f '$TMPDIR/$s/CHANGELOG.md' ]"
  assert_zero  "  signals dir ($s)"         "[ -d '$TMPDIR/$s/.expero/signals' ]"
  assert_zero  "  signals README ($s)"      "[ -f '$TMPDIR/$s/.expero/signals/README.md' ]"
done
assert_match "CHANGELOG has Unreleased"    "cat '$TMPDIR/new-product/CHANGELOG.md'" "^## \\[Unreleased\\]"
assert_match "CHANGELOG has Keep a Changelog link" "cat '$TMPDIR/new-product/CHANGELOG.md'" "keepachangelog"
assert_match "signals README has schema"   "cat '$TMPDIR/new-product/.expero/signals/README.md'" "NEEDS_ARCH_REVIEW"

echo ""
echo "== T11: init refuses to overwrite existing target =="
# Re-init into an already-populated path must fail AND leave contents intact.
existing_config_before=$(cat "$TMPDIR/new-product/.expero/config.yaml")
assert_nonzero "init refuses existing target" "bash '$EXPERO' init '$TMPDIR/new-product' 'new-product'"
existing_config_after=$(cat "$TMPDIR/new-product/.expero/config.yaml")
assert_eq      "existing config.yaml untouched" "$existing_config_after" "$existing_config_before"

echo ""
echo "== T12: init rejects unknown scenario, no partial dir left =="
assert_nonzero "unknown scenario rejected" "bash '$EXPERO' init '$TMPDIR/bogus-scenario' 'no-such-scenario'"
assert_nonzero "no partial dir created"    "[ -e '$TMPDIR/bogus-scenario' ]"

echo ""
echo "== T13: start rejects task-id with shell metacharacters =="
cd "$TMPDIR/new-product"
assert_nonzero "start rejects ';' in task-id"     "bash '$EXPERO' start builder 'M0-001; rm -rf /' claude"
assert_nonzero "start rejects backtick in task-id" "bash '$EXPERO' start builder 'M0-\`id\`' claude"
assert_nonzero "start rejects space in task-id"   "bash '$EXPERO' start builder 'M0 001' claude"
# Note: can't assert_zero on valid task-id because it would invoke 'claude'
# binary which isn't guaranteed to be installed in the test env.
cd "$SCRIPT_DIR"

echo ""
echo "== T14: status grep boundary — 'todo' in task title not miscounted =="
# Fresh init (independent of T7 which injects into $TMPDIR/new-product).
# Append a row whose *title* contains 'todo' but whose status is 'completed'.
# Pre-fix: `grep -F "| todo "` matches the title substring and miscounts.
# Post-fix: regex with pipe-boundary anchors only matches the Status column.
bash "$EXPERO" init "$TMPDIR/boundary" new-product >/dev/null
echo "| M0-888 | cleanup todo list | completed | builder | — | abc123 |" \
    >> "$TMPDIR/boundary/.expero/docs/roadmap.md"
boundary_status=$(cd "$TMPDIR/boundary" && bash expero.sh status 2>&1)
# Initial is 7 todo; after adding a *completed* row that contains "todo"
# in its title, todo count must remain 7 (not 8).
echo "$boundary_status" | grep -qE "todo:[[:space:]]+7"       && pass "todo count ignores title text" || fail "todo count ignores title text" "(got non-7)"
echo "$boundary_status" | grep -qE "completed:[[:space:]]+1"  && pass "completed count is 1"          || fail "completed count is 1"          "(missing)"

echo ""
echo "== T15: validate command =="
cp -r "$TMPDIR/new-product" "$TMPDIR/validate-empty"
# Empty project: no artifacts → warn + exit 0
assert_zero     "validate on empty project exits 0"       "cd '$TMPDIR/validate-empty' && bash expero.sh validate"
assert_match    "validate warns on empty"                 "cd '$TMPDIR/validate-empty' && bash expero.sh validate" "No artifacts"

cp -r "$TMPDIR/new-product" "$TMPDIR/validate-ok"
cat > "$TMPDIR/validate-ok/.expero/docs/adr/ADR-0001-test.md" << 'ADR_EOF'
# ADR-0001: Use X

## Status
Accepted

## Context
Foo.

## Decision
Bar.

## Consequences
### Positive
### Negative
### Neutral

## Alternatives Considered
Baz.
ADR_EOF
assert_zero     "validate on valid ADR exits 0"           "cd '$TMPDIR/validate-ok' && bash expero.sh validate"
assert_match    "validate reports passed"                 "cd '$TMPDIR/validate-ok' && bash expero.sh validate" "Passed:[[:space:]]+1"

cp -r "$TMPDIR/validate-ok" "$TMPDIR/validate-bad"
cat > "$TMPDIR/validate-bad/.expero/docs/adr/ADR-0002-incomplete.md" << 'ADR_EOF'
# ADR-0002: Missing most sections

## Status
Draft
ADR_EOF
assert_nonzero  "validate on invalid ADR exits non-zero"  "cd '$TMPDIR/validate-bad' && bash expero.sh validate"
assert_match    "validate lists missing sections"         "cd '$TMPDIR/validate-bad' && bash expero.sh validate" "missing: .*Context"

assert_zero     "validate single-file on valid ADR"       "cd '$TMPDIR/validate-ok' && bash expero.sh validate .expero/docs/adr/ADR-0001-test.md"
assert_nonzero  "validate single-file nonexistent fails"  "cd '$TMPDIR/validate-ok' && bash expero.sh validate nope.md"

# validate must fail outside an Expero project
mkdir -p "$TMPDIR/non-expero"
assert_nonzero  "validate outside Expero project fails"   "cd '$TMPDIR/non-expero' && bash '$EXPERO' validate"

echo ""
echo "== T16: structured signals (.expero/signals/*.json) parsed by status =="
cp -r "$TMPDIR/new-product" "$TMPDIR/signals"
cat > "$TMPDIR/signals/.expero/signals/M0-003-NEEDS_ARCH_REVIEW.json" << 'SIG_EOF'
{
  "id": "M0-003",
  "type": "NEEDS_ARCH_REVIEW",
  "raised_by": "builder",
  "raised_at": "2026-04-17T12:00:00Z",
  "description": "JWT library undecided",
  "resolved": false
}
SIG_EOF
cat > "$TMPDIR/signals/.expero/signals/M0-004-resolved.json" << 'SIG_EOF'
{
  "id": "M0-004",
  "type": "NEEDS_SPEC_CLARIFICATION",
  "raised_by": "builder",
  "raised_at": "2026-04-17T11:00:00Z",
  "description": "Done",
  "resolved": true
}
SIG_EOF
sig_status=$(cd "$TMPDIR/signals" && bash expero.sh status 2>&1)
echo "$sig_status" | grep -qE 'Stop Signals \(\.expero/signals' && pass "structured signal section rendered" || fail "structured signal section rendered" "(missing header)"
echo "$sig_status" | awk '/Stop Signals \(\.expero\/signals/,0' | grep -qE "NEEDS_ARCH_REVIEW:[[:space:]]+1" \
    && pass "1 unresolved NEEDS_ARCH_REVIEW counted" || fail "1 unresolved NEEDS_ARCH_REVIEW counted" "(miscount)"
echo "$sig_status" | grep -qE "resolved, informational.*1"     && pass "1 resolved signal counted"        || fail "1 resolved signal counted"        "(miscount)"
echo "$sig_status" | grep -qE "Pending stop signals"           && pass "warning triggered by structured signal" || fail "warning triggered by structured signal" "(missing)"

echo ""
echo "== T17: set -u robustness — every command accepts minimal args =="
# With set -euo pipefail, missing-arg code paths must not crash on unbound
# variables. Each command must either run or emit a clean error — never
# bash's "unbound variable" message.
assert_zero     "help works"                              "bash '$EXPERO' help"
assert_match    "init missing args reports required"      "bash '$EXPERO' init 2>&1 || true" "project name required"
# 'status' / 'restart' in bare dir must error cleanly (not 'unbound variable')
cd "$TMPDIR/bare"
status_err=$(bash "$EXPERO" status 2>&1 || true)
echo "$status_err" | grep -qi "unbound variable" \
    && fail "status in bare dir leaks set -u error" "(got: $status_err)" \
    || pass "status in bare dir errors cleanly"
restart_err=$(bash "$EXPERO" restart 2>&1 || true)
echo "$restart_err" | grep -qi "unbound variable" \
    && fail "restart in bare dir leaks set -u error" "(got: $restart_err)" \
    || pass "restart in bare dir errors cleanly"
cd "$SCRIPT_DIR"

echo ""
echo "== T18: help mentions 'validate' command and task-id safety =="
assert_match "help lists validate"     "bash '$EXPERO' help" "validate "
assert_match "help warns about task-id" "bash '$EXPERO' help" "task-id.*embedded"

echo ""
echo "== T19: role templates extracted to roles/*.md =="
ROLES_DIR="$SCRIPT_DIR/roles"
assert_zero "roles/ directory exists"       "[ -d '$ROLES_DIR' ]"
assert_zero "roles/_base.md exists"         "[ -f '$ROLES_DIR/_base.md' ]"
for r in architect planner builder verifier critic sentinel scribe archaeologist; do
  assert_zero "  roles/$r.md exists"        "[ -f '$ROLES_DIR/$r.md' ]"
done
# Templates must reference the __TASK__ or __TASK_ID__ placeholder so
# substitution actually has something to work with.
for r in architect planner builder verifier sentinel scribe archaeologist; do
  assert_match "  $r template has __TASK__"     "cat '$ROLES_DIR/$r.md'" "__TASK__"
done
assert_match "  critic template has __TASK_ID__" "cat '$ROLES_DIR/critic.md'" "__TASK_ID__"
assert_match "  builder template has __TASK_ID__ for file ref" "cat '$ROLES_DIR/builder.md'" "specs/__TASK_ID__\\.md"

echo ""
echo "== T20: init copies roles/ into .expero/roles/ =="
bash "$EXPERO" init "$TMPDIR/roles-copy" new-product >/dev/null
assert_zero  "  .expero/roles/ created"         "[ -d '$TMPDIR/roles-copy/.expero/roles' ]"
assert_zero  "  _base.md copied"                "[ -f '$TMPDIR/roles-copy/.expero/roles/_base.md' ]"
for r in architect planner builder verifier critic sentinel scribe archaeologist; do
  assert_zero "  $r.md copied"                  "[ -f '$TMPDIR/roles-copy/.expero/roles/$r.md' ]"
done

echo ""
echo "== T21: _build_prompt renders with substitutions =="
# Helper: source expero.sh in a subshell, call _build_prompt from the
# project dir. The dispatch guard inside expero.sh skips main when sourced.
build_prompt() {
  local proj=$1 role=$2 task=$3
  bash -c "cd '$proj' && source '$EXPERO' >/dev/null 2>&1 && _build_prompt '$role' '$task'" 2>/dev/null
}

# Architect with explicit task-id → the literal id appears in "本次任务"
architect_out=$(build_prompt "$TMPDIR/roles-copy" architect M0-001)
echo "$architect_out" | grep -qE "本次任务：M0-001"   && pass "architect: task-id substituted into 本次任务" || fail "architect: task-id substituted" "(not found)"
echo "$architect_out" | grep -qE "^你是 Architect。$" && pass "architect: title-cased role name in base"   || fail "architect: title-cased role"    "(not found)"
echo "$architect_out" | grep -qE "ADR-NNNN"           && pass "architect: role-body content rendered"    || fail "architect: role-body"           "(not found)"
# Regression guard: bash 3.2 would leave `${role^}` literally or lowercase.
# Under any supported bash the first-letter must be upper and body lower.
echo "$architect_out" | grep -qE "你是 architect" && fail "architect: title-case regressed" "(lowercase leaked)" || pass "architect: title-case intact"

# Builder with no task-id → default description + <task-id> literal for path
builder_out=$(build_prompt "$TMPDIR/roles-copy" builder "")
echo "$builder_out" | grep -qE "本次任务：实现 roadmap 中第一个状态为 todo 的任务" \
    && pass "builder: default task description used" || fail "builder: default task" "(wrong)"
echo "$builder_out" | grep -qE "specs/<task-id>\\.md" \
    && pass "builder: __TASK_ID__ empty case → <task-id> literal" || fail "builder: literal <task-id> fallback" "(not found)"

# Critic without task-id → must fail
critic_rc=$(bash -c "cd '$TMPDIR/roles-copy' && source '$EXPERO' >/dev/null 2>&1 && _build_prompt critic ''" 2>/dev/null; echo $?)
assert_eq "critic requires task-id (rc != 0)" "$critic_rc" "1"

# Critic with task-id → task-id appears in both the "本次任务 审查" line and the review path
critic_out=$(build_prompt "$TMPDIR/roles-copy" critic M1-042)
echo "$critic_out" | grep -qE "本次任务：审查 M1-042" \
    && pass "critic: task-id in 审查 line" || fail "critic: task-id in 审查 line" "(not found)"
echo "$critic_out" | grep -qE "review/M1-042\\.md" \
    && pass "critic: task-id in review path" || fail "critic: review path" "(not found)"

# Unknown role → fail cleanly
unknown_rc=$(bash -c "cd '$TMPDIR/roles-copy' && source '$EXPERO' >/dev/null 2>&1 && _build_prompt nonesuch ''" 2>/dev/null; echo $?)
assert_eq "unknown role rejected (rc != 0)" "$unknown_rc" "1"

echo ""
echo "== T22: project is self-contained (roles resolver picks .expero/roles) =="
# Regression: running expero.sh from inside a generated project must NOT
# require the source repo. Move the project to a different parent so any
# accidental absolute-path leak becomes visible.
cp -r "$TMPDIR/roles-copy" "$TMPDIR/detached"
detached_out=$(bash -c "cd '$TMPDIR/detached' && source ./expero.sh >/dev/null 2>&1 && _build_prompt architect M0-001" 2>/dev/null)
echo "$detached_out" | grep -qE "本次任务：M0-001" \
    && pass "detached project renders prompt from .expero/roles" \
    || fail "detached project renders prompt from .expero/roles" "(empty or wrong)"

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
