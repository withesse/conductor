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
assert_match "  doc mentions JSON signal form"        "cat '$AGENTS_MD'" "Structured JSON in \\.expero/signals"
assert_match "  doc mentions signals schema"          "cat '$AGENTS_MD'" "signals/README\\.md"

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
echo "== T5c: CLAUDE.md Expero Protocol documents both signal forms =="
# Dogfood finding I: CLAUDE.md was missing the JSON signal form, even
# though AGENTS.md and roles/_base.md had been updated. Protocol section
# must mention .expero/signals/ and reference README.md schema.
for s in new-product security-audit legacy-analysis; do
  claude_md="$TMPDIR/$s/CLAUDE.md"
  assert_match "  $s CLAUDE.md mentions text signal form"    "cat '$claude_md'" "NEEDS_ARCH_REVIEW"
  assert_match "  $s CLAUDE.md mentions JSON signal form"    "cat '$claude_md'" "\\.expero/signals/"
  assert_match "  $s CLAUDE.md references signals README"    "cat '$claude_md'" "signals/README\\.md"
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
echo "== T15b: signals lifecycle — resolved/ archive directory =="
# init creates resolved/ subdir alongside signals/; README documents
# the raise → resolve → archive three-step lifecycle.
for s in $SCENARIOS; do
  assert_zero "  $s has .expero/signals/resolved/" \
      "[ -d '$TMPDIR/$s/.expero/signals/resolved' ]"
done
assert_match "signals README has lifecycle section" \
    "cat '$TMPDIR/new-product/.expero/signals/README.md'" "^## Lifecycle"
assert_match "signals README has dispatch table" \
    "cat '$TMPDIR/new-product/.expero/signals/README.md'" "^## Dispatch"
assert_match "  NEEDS_ARCH_REVIEW → architect" \
    "cat '$TMPDIR/new-product/.expero/signals/README.md'" "NEEDS_ARCH_REVIEW.*architect"
assert_match "  NEEDS_SPEC_CLARIFICATION → planner" \
    "cat '$TMPDIR/new-product/.expero/signals/README.md'" "NEEDS_SPEC_CLARIFICATION.*planner"
assert_match "  NEEDS_SECURITY_REVIEW → sentinel" \
    "cat '$TMPDIR/new-product/.expero/signals/README.md'" "NEEDS_SECURITY_REVIEW.*sentinel"

echo ""
echo "== T15c: status shows dispatch hint + archived count =="
# Reuse the signals project from T16 (which already has a signal)
# but also add a resolved-in-place and an archived one to cover all
# three states.
bash "$EXPERO" init "$TMPDIR/sig-lc" new-product >/dev/null
cat > "$TMPDIR/sig-lc/.expero/signals/M0-001-NEEDS_ARCH_REVIEW.json" << 'S'
{"id":"M0-001","type":"NEEDS_ARCH_REVIEW","raised_by":"builder","raised_at":"2026-04-18T10:00:00Z","description":"x","resolved":false}
S
cat > "$TMPDIR/sig-lc/.expero/signals/M0-002-NEEDS_SEC.json" << 'S'
{"id":"M0-002","type":"NEEDS_SECURITY_REVIEW","raised_by":"builder","raised_at":"2026-04-18T10:00:00Z","description":"y","resolved":false}
S
cat > "$TMPDIR/sig-lc/.expero/signals/M0-003-done.json" << 'S'
{"id":"M0-003","type":"NEEDS_SPEC_CLARIFICATION","raised_by":"builder","raised_at":"2026-04-18T09:00:00Z","description":"z","resolved":true,"resolved_by":"planner","resolved_at":"2026-04-18T11:00:00Z"}
S
cat > "$TMPDIR/sig-lc/.expero/signals/resolved/M0-000-old.json" << 'S'
{"id":"M0-000","type":"NEEDS_ARCH_REVIEW","raised_by":"planner","raised_at":"2026-04-18T08:00:00Z","description":"archived","resolved":true,"resolved_by":"architect","resolved_at":"2026-04-18T09:30:00Z"}
S
sig_out=$(cd "$TMPDIR/sig-lc" && bash expero.sh status 2>&1)
echo "$sig_out" | grep -qE "NEEDS_ARCH_REVIEW:.*1.*→ dispatch to: architect" \
    && pass "status shows 'dispatch to: architect' for arch signal" \
    || fail "status shows 'dispatch to: architect' for arch signal" "(missing)"
echo "$sig_out" | grep -qE "NEEDS_SECURITY_REVIEW:.*1.*→ dispatch to: sentinel" \
    && pass "status shows 'dispatch to: sentinel' for security signal" \
    || fail "status shows 'dispatch to: sentinel' for security signal" "(missing)"
echo "$sig_out" | grep -qE "\(resolved, in-place\):[[:space:]]+1" \
    && pass "status reports 1 resolved in-place" \
    || fail "status reports 1 resolved in-place" "(wrong count)"
echo "$sig_out" | grep -qE "\(archived in resolved/\):[[:space:]]+1" \
    && pass "status reports 1 archived in resolved/" \
    || fail "status reports 1 archived in resolved/" "(wrong count)"
# Dispatch hints must NOT leak when count = 0 (avoid noise on clean state)
echo "$sig_out" | grep -qE "NEEDS_SPEC_CLARIFICATION:[[:space:]]+0.*→" \
    && fail "no dispatch hint when count=0" "(leaked)" \
    || pass "no dispatch hint when count=0"

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
echo "$sig_status" | grep -qE "resolved, in-place.*1"          && pass "1 resolved signal counted"        || fail "1 resolved signal counted"        "(miscount)"
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
echo "== T23: scenarios/ directory + JSON schema =="
SCEN_DIR="$SCRIPT_DIR/scenarios"
assert_zero  "scenarios/ dir exists"           "[ -d '$SCEN_DIR' ]"
assert_zero  "scenarios/roadmaps/ dir exists"  "[ -d '$SCEN_DIR/roadmaps' ]"
for s in $SCENARIOS; do
  assert_zero "  scenarios/$s.json exists"   "[ -f '$SCEN_DIR/$s.json' ]"
  # every JSON must declare name, active_roles, extension_roles,
  # extra_dirs, roadmap_template — guards against schema drift.
  for field in '"name":' '"active_roles":' '"extension_roles":' '"extra_dirs":' '"roadmap_template":'; do
    assert_match "  $s.json has $field" "cat '$SCEN_DIR/$s.json'" "$field"
  done
done

echo ""
echo "== T24: _json_get_array parses scenario arrays =="
read_array() {
  bash -c "source '$EXPERO' >/dev/null 2>&1 && _json_get_array '$1' '$2'" 2>/dev/null
}
assert_eq "new-product active_roles count"       "$(read_array "$SCEN_DIR/new-product.json" active_roles | wc -l | tr -d ' ')" "5"
assert_eq "new-product extension_roles empty"    "$(read_array "$SCEN_DIR/new-product.json" extension_roles | wc -l | tr -d ' ')" "0"
assert_eq "legacy-analysis extension_roles cnt"  "$(read_array "$SCEN_DIR/legacy-analysis.json" extension_roles | wc -l | tr -d ' ')" "2"
assert_eq "security-audit active first=planner"  "$(read_array "$SCEN_DIR/security-audit.json" active_roles | head -1)" "planner"
assert_eq "security-audit active second=sentinel" "$(read_array "$SCEN_DIR/security-audit.json" active_roles | sed -n '2p')" "sentinel"
assert_eq "greenfield-library extra_dirs cnt"    "$(read_array "$SCEN_DIR/greenfield-library.json" extra_dirs | wc -l | tr -d ' ')" "2"

echo ""
echo "== T25: init copies scenarios/ into .expero/scenarios/ =="
assert_zero "  .expero/scenarios/ exists"             "[ -d '$TMPDIR/roles-copy/.expero/scenarios' ]"
assert_zero "  .expero/scenarios/roadmaps/ exists"    "[ -d '$TMPDIR/roles-copy/.expero/scenarios/roadmaps' ]"
for s in $SCENARIOS; do
  assert_zero "  .expero/scenarios/$s.json copied"   "[ -f '$TMPDIR/roles-copy/.expero/scenarios/$s.json' ]"
done
assert_zero "  .expero/scenarios/roadmaps/new-product.md copied" \
    "[ -f '$TMPDIR/roles-copy/.expero/scenarios/roadmaps/new-product.md' ]"

echo ""
echo "== T26: roadmap.md byte-regression for all scenarios =="
# After refactor-to-JSON, every init must produce byte-identical roadmap.md
# as the hand-written scenarios/roadmaps/*.md expects. Guards against
# accidental trailing newline drift, placeholder substitution bugs, etc.
for s in $SCENARIOS; do
  bash "$EXPERO" init "$TMPDIR/byte-$s" "$s" >/dev/null 2>&1
  roadmap_rel=$(awk -F'"' '/"roadmap_template":/{print $4; exit}' "$SCEN_DIR/$s.json")
  src_template="$SCEN_DIR/$roadmap_rel"
  gen_roadmap="$TMPDIR/byte-$s/.expero/docs/roadmap.md"
  if cmp -s "$src_template" "$gen_roadmap"; then
    pass "  $s: roadmap.md == template $(basename "$roadmap_rel")"
  else
    fail "  $s: roadmap.md == template" "(bytes differ — see diff below)"
    diff "$src_template" "$gen_roadmap" | head -10
  fi
done

echo ""
echo "== T26b: schemas/ directory + JSON format =="
SCHEMA_DIR="$SCRIPT_DIR/schemas"
assert_zero "schemas/ dir exists"   "[ -d '$SCHEMA_DIR' ]"
for t in adr radr spec test-plan review security security-summary; do
  assert_zero "  schemas/$t.json exists"      "[ -f '$SCHEMA_DIR/$t.json' ]"
  for field in '"name":' '"description":' '"required_patterns":'; do
    assert_match "  $t.json has $field" "cat '$SCHEMA_DIR/$t.json'" "$field"
  done
done

echo ""
echo "== T26c: _json_get_array handles multi-line arrays with [ and ] in items =="
# Regression: the v1.0 single-line parser mis-matched [0-9] in ADR patterns.
# Multi-line + per-line quote extraction must pass through brackets verbatim.
adr_patterns=$(bash -c "source '$EXPERO' >/dev/null 2>&1 && _json_get_array '$SCHEMA_DIR/adr.json' required_patterns")
assert_eq "adr pattern count is 6"                       "$(echo "$adr_patterns" | wc -l | tr -d ' ')" "6"
assert_eq "adr first pattern preserves [0-9]+"           "$(echo "$adr_patterns" | head -1)" "^# ADR-[0-9]+:"
spec_patterns=$(bash -c "source '$EXPERO' >/dev/null 2>&1 && _json_get_array '$SCHEMA_DIR/spec.json' required_patterns")
assert_eq "spec pattern count is 5"                      "$(echo "$spec_patterns" | wc -l | tr -d ' ')" "5"
assert_eq "spec preserves [.] literal dot"               "$(echo "$spec_patterns" | sed -n '2p')" "^## 1[.] Config Schema"
testplan_patterns=$(bash -c "source '$EXPERO' >/dev/null 2>&1 && _json_get_array '$SCHEMA_DIR/test-plan.json' required_patterns")
assert_eq "test-plan preserves [|] literal pipe"         "$(echo "$testplan_patterns" | sed -n '2p')" "[|][[:space:]]*ID[[:space:]]*[|]"

echo ""
echo "== T26d: init copies schemas/ into .expero/schemas/ =="
for t in adr radr spec test-plan review security security-summary; do
  assert_zero "  .expero/schemas/$t.json copied"  "[ -f '$TMPDIR/roles-copy/.expero/schemas/$t.json' ]"
done

echo ""
echo "== T26e: help is dynamic + project-aware =="
# Outside a project: help must list every scenario from scenarios/*.json
# (not from a hardcoded block). Descriptions come from each JSON's
# "description" field — regression guards against drift where help
# silently stops reflecting reality.
help_out=$(bash "$EXPERO" help)
for s in $SCENARIOS; do
  echo "$help_out" | grep -qE "^  $s " && pass "  help lists scenario '$s'" \
      || fail "  help lists scenario '$s'" "(missing)"
done
echo "$help_out" | grep -qE "Build a new product from scratch" \
    && pass "  help shows new-product description from JSON" \
    || fail "  help shows new-product description from JSON" "(missing)"
echo "$help_out" | grep -qE "Systematic security review" \
    && pass "  help shows security-audit description from JSON" \
    || fail "  help shows security-audit description from JSON" "(missing)"
echo "$help_out" | grep -qE "^## Current project" && \
    fail "  help outside project omits 'Current project' block" "(leaked)" || \
    pass "  help outside project omits 'Current project' block"
# Inside a project: help adds a "Current project" block with scenario + active_roles
assert_match "help inside project has Current section" \
    "cd '$TMPDIR/new-product' && bash '$EXPERO' help" \
    "Current project:"
assert_match "  Current scenario shown" \
    "cd '$TMPDIR/new-product' && bash '$EXPERO' help" \
    "scenario:[[:space:]]+new-product"
assert_match "  Active roles shown (planner)" \
    "cd '$TMPDIR/new-product' && bash '$EXPERO' help" \
    "active roles:.*planner"

echo ""
echo "== T26f: start warns when role not in scenario's active_roles =="
# security-audit has active_roles = [planner, sentinel, builder].
# Starting architect there must warn (not fail — user override allowed).
bash "$EXPERO" init "$TMPDIR/warn-scen" security-audit >/dev/null
warn_out=$(cd "$TMPDIR/warn-scen" && bash expero.sh start architect 2>&1 </dev/null | head -5)
echo "$warn_out" | grep -qE "not in scenario 'security-audit'" \
    && pass "start warns on non-active role" \
    || fail "start warns on non-active role" "(no warning)"
# Starting an active role must NOT warn
ok_out=$(cd "$TMPDIR/warn-scen" && bash expero.sh start planner 2>&1 </dev/null | head -3)
echo "$ok_out" | grep -qE "not in scenario" \
    && fail "start silent on active role" "(spurious warning)" \
    || pass "start silent on active role"

echo ""
echo "== T26g: start critic without task-id fails before 'Starting' message =="
# Regression: F19. The misleading 'Starting critic' info line used to
# print before the task-id check fired inside _build_prompt. Now the
# check is up-front and the error is the first line.
critic_out=$(cd "$TMPDIR/new-product" && bash expero.sh start critic 2>&1 </dev/null)
first_line=$(echo "$critic_out" | grep -E "Starting|Critic requires" | head -1)
echo "$first_line" | grep -qE "Critic requires" \
    && pass "critic error precedes 'Starting' line" \
    || fail "critic error precedes 'Starting' line" "(got: '$first_line')"

echo ""
echo "== T26h: restart warns on pending stop signals =="
bash "$EXPERO" init "$TMPDIR/restart-sig" new-product >/dev/null
# Clean restart — no warn about signals
clean_out=$(cd "$TMPDIR/restart-sig" && bash expero.sh restart 2>&1)
echo "$clean_out" | grep -qE "Pending stop signals at milestone" \
    && fail "restart silent on clean state" "(spurious warning)" \
    || pass "restart silent on clean state"
# Inject a text marker — restart should warn
echo "| M9-001 | probe | todo | builder | — | NEEDS_ARCH_REVIEW |" \
    >> "$TMPDIR/restart-sig/.expero/docs/roadmap.md"
dirty_out=$(cd "$TMPDIR/restart-sig" && bash expero.sh restart 2>&1)
echo "$dirty_out" | grep -qE "Pending stop signals at milestone" \
    && pass "restart warns on text marker" \
    || fail "restart warns on text marker" "(no warning)"
# Exit code still 0 — warning, not error
assert_zero "restart with signals exits 0 (warning, not error)" \
    "cd '$TMPDIR/restart-sig' && bash expero.sh restart"

echo ""
echo "== T26i: restart Next steps uses scenario's active_roles =="
# security-audit scenario — Next steps must NOT mention 'critic' (which
# isn't in active_roles) but MUST mention 'sentinel'.
sec_restart=$(cd "$TMPDIR/warn-scen" && bash expero.sh restart 2>&1)
echo "$sec_restart" | grep -qE "start sentinel" \
    && pass "restart suggests sentinel for security-audit" \
    || fail "restart suggests sentinel for security-audit" "(missing)"
echo "$sec_restart" | grep -qE "start critic" \
    && fail "restart omits critic for security-audit" "(leaked)" \
    || pass "restart omits critic for security-audit"

echo ""
echo "== T26j: init 'Next steps' uses scenario's first active role =="
sec_init=$(bash "$EXPERO" init "$TMPDIR/init-next" security-audit 2>&1)
echo "$sec_init" | grep -qE "bash expero.sh start planner" \
    && pass "init suggests planner (first active_role) for security-audit" \
    || fail "init suggests planner for security-audit" "(wrong/missing)"

echo ""
echo "== T26k: validate reports skipped count in success line =="
bash "$EXPERO" init "$TMPDIR/vskip" new-product >/dev/null
# Non-matching file in adr/ — will be skipped
echo "# random notes" > "$TMPDIR/vskip/.expero/docs/adr/notes.md"
vskip_out=$(cd "$TMPDIR/vskip" && bash expero.sh validate 2>&1)
echo "$vskip_out" | grep -qE "All classified artifacts valid \(1 skipped" \
    && pass "validate OK line shows skipped count" \
    || fail "validate OK line shows skipped count" "(missing)"

echo ""
echo "== T26l: roles/_base.md documents signals + .expero/signals/ =="
BASE_MD="$SCRIPT_DIR/roles/_base.md"
assert_match "  _base.md mentions .expero/signals"        "cat '$BASE_MD'" "\\.expero/signals"
assert_match "  _base.md mentions Stop Signal text form"  "cat '$BASE_MD'" "NEEDS_ARCH_REVIEW"

echo ""
echo "== T26m: gate command — artifacts_valid =="
bash "$EXPERO" init "$TMPDIR/gate-arts" new-product >/dev/null
# Empty project: no artifacts → pass
assert_zero "gate artifacts_valid passes on empty project" \
    "cd '$TMPDIR/gate-arts' && bash expero.sh gate artifacts_valid"
# Add a valid ADR
cat > "$TMPDIR/gate-arts/.expero/docs/adr/ADR-0001.md" << 'ADR'
# ADR-0001: Good
## Status
Accepted
## Context
x
## Decision
y
## Consequences
### Positive
### Negative
### Neutral
## Alternatives Considered
z
ADR
assert_zero "gate artifacts_valid passes with valid ADR" \
    "cd '$TMPDIR/gate-arts' && bash expero.sh gate artifacts_valid"
# Add a malformed ADR
cat > "$TMPDIR/gate-arts/.expero/docs/adr/ADR-0002.md" << 'BAD'
# ADR-0002: Bad
## Status
Draft
BAD
assert_nonzero "gate artifacts_valid fails with invalid ADR" \
    "cd '$TMPDIR/gate-arts' && bash expero.sh gate artifacts_valid"
assert_match   "  output includes ✗ FAIL banner" \
    "cd '$TMPDIR/gate-arts' && bash expero.sh gate artifacts_valid" \
    "✗ FAIL"

echo ""
echo "== T26n: gate command — adr_compliance =="
bash "$EXPERO" init "$TMPDIR/gate-adr" new-product >/dev/null
# Missing task-id
assert_nonzero "gate adr_compliance without task-id fails" \
    "cd '$TMPDIR/gate-adr' && bash expero.sh gate adr_compliance"
# No review yet → fail
assert_nonzero "gate adr_compliance fails when review missing" \
    "cd '$TMPDIR/gate-adr' && bash expero.sh gate adr_compliance M0-001"
# APPROVED review → pass
cat > "$TMPDIR/gate-adr/.expero/docs/review/M0-001.md" << 'RV'
# Review: M0-001

## Verdict
APPROVED

## ADR Compliance
- [x] ADR-0001

## Issues
| Severity | Location | Description | Suggestion |
RV
assert_zero "gate adr_compliance passes with APPROVED review" \
    "cd '$TMPDIR/gate-adr' && bash expero.sh gate adr_compliance M0-001"
# CHANGES_REQUESTED → fail
cat > "$TMPDIR/gate-adr/.expero/docs/review/M0-002.md" << 'RV'
# Review: M0-002

## Verdict
CHANGES_REQUESTED

## ADR Compliance

## Issues
| Severity | Location | Description | Suggestion |
RV
assert_nonzero "gate adr_compliance fails with CHANGES_REQUESTED" \
    "cd '$TMPDIR/gate-adr' && bash expero.sh gate adr_compliance M0-002"
assert_match   "  output mentions required APPROVED" \
    "cd '$TMPDIR/gate-adr' && bash expero.sh gate adr_compliance M0-002" \
    "required: APPROVED"

echo ""
echo "== T26o: gate command — security_clean =="
bash "$EXPERO" init "$TMPDIR/gate-sec" security-audit >/dev/null
# No summary file → gate passes by default
assert_zero "gate security_clean passes when summary absent" \
    "cd '$TMPDIR/gate-sec' && bash expero.sh gate security_clean"
# Summary without CRITICAL row → pass
cat > "$TMPDIR/gate-sec/.expero/docs/security/summary.md" << 'SEC'
# Security Audit Summary
| Severity | Count |
|----------|-------|
| HIGH | 2 |
| MEDIUM | 4 |
SEC
assert_zero "gate security_clean passes without CRITICAL row" \
    "cd '$TMPDIR/gate-sec' && bash expero.sh gate security_clean"
# Summary with CRITICAL → fail
cat > "$TMPDIR/gate-sec/.expero/docs/security/summary.md" << 'SEC'
# Security Audit Summary
| Severity | Count |
|----------|-------|
| CRITICAL | 2 |
SEC
assert_nonzero "gate security_clean fails on CRITICAL row" \
    "cd '$TMPDIR/gate-sec' && bash expero.sh gate security_clean"
assert_match   "  output shows CRITICAL count" \
    "cd '$TMPDIR/gate-sec' && bash expero.sh gate security_clean" \
    "2 CRITICAL finding"

# Regression for dogfood finding D/E: "| CRITICAL | 0 |" means zero
# findings (clean summary), gate MUST pass. The pre-fix version
# incorrectly failed because it matched rows containing CRITICAL
# without parsing the count column.
cat > "$TMPDIR/gate-sec/.expero/docs/security/summary.md" << 'SEC'
# Security Audit Summary
| Severity | Count |
|----------|-------|
| CRITICAL | 0 |
| HIGH | 3 |
| MEDIUM | 5 |
SEC
assert_zero "gate security_clean passes with '| CRITICAL | 0 |'" \
    "cd '$TMPDIR/gate-sec' && bash expero.sh gate security_clean"
assert_match "  output says no CRITICAL findings" \
    "cd '$TMPDIR/gate-sec' && bash expero.sh gate security_clean" \
    "No CRITICAL findings"

# Multi-row CRITICAL: rare but should sum. This also guards against
# regex backsliding to "just count lines matching CRITICAL".
cat > "$TMPDIR/gate-sec/.expero/docs/security/summary.md" << 'SEC'
# Security Audit Summary
| Severity | Count |
|----------|-------|
| CRITICAL | 3 |
| CRITICAL | 2 |
SEC
assert_match "gate reports sum when multiple CRITICAL rows" \
    "cd '$TMPDIR/gate-sec' && bash expero.sh gate security_clean" \
    "5 CRITICAL finding"

echo ""
echo "== T26o-b: gate command — ci_passes =="
bash "$EXPERO" init "$TMPDIR/gate-ci" new-product >/dev/null
# No ci_commands field configured → pass-by-default
assert_zero "gate ci_passes passes when no ci_commands configured" \
    "cd '$TMPDIR/gate-ci' && bash expero.sh gate ci_passes"
assert_match "  output states 'pass by default'" \
    "cd '$TMPDIR/gate-ci' && bash expero.sh gate ci_passes" \
    "No ci_commands configured"
# Generated config.yaml already has an empty `ci_commands:` block — confirm.
assert_match "  init writes ci_commands: placeholder" \
    "cat '$TMPDIR/gate-ci/.expero/config.yaml'" \
    "^ci_commands:\$"
# Single passing command
cat >> "$TMPDIR/gate-ci/.expero/config.yaml" << 'CFG'
  - "echo hello"
CFG
assert_zero "gate ci_passes passes with a trivially passing command" \
    "cd '$TMPDIR/gate-ci' && bash expero.sh gate ci_passes"
# Multi-command all passing
cat >> "$TMPDIR/gate-ci/.expero/config.yaml" << 'CFG'
  - "true"
  - "ls /"
CFG
assert_zero "gate ci_passes passes when every command exits 0" \
    "cd '$TMPDIR/gate-ci' && bash expero.sh gate ci_passes"
# Inject a failing command at end — gate should fail
cat >> "$TMPDIR/gate-ci/.expero/config.yaml" << 'CFG'
  - "echo boom; exit 17"
CFG
assert_nonzero "gate ci_passes fails on first non-zero exit" \
    "cd '$TMPDIR/gate-ci' && bash expero.sh gate ci_passes"
assert_match "  output shows failing exit code" \
    "cd '$TMPDIR/gate-ci' && bash expero.sh gate ci_passes" \
    "exit 17"
assert_match "  output surfaces command output tail" \
    "cd '$TMPDIR/gate-ci' && bash expero.sh gate ci_passes" \
    "boom"

# Regression: YAML parser must handle quoted + unquoted items + strip
# whitespace. Rebuild config to exercise the parser specifically.
bash "$EXPERO" init "$TMPDIR/gate-ci-mix" new-product >/dev/null
cat >> "$TMPDIR/gate-ci-mix/.expero/config.yaml" << 'CFG'
  - "echo quoted"
  - echo unquoted
  -   "echo extra-space"
CFG
assert_zero "gate ci_passes parses mixed quoting" \
    "cd '$TMPDIR/gate-ci-mix' && bash expero.sh gate ci_passes"

echo ""
echo "== T26o-c: gate command — test_coverage =="
bash "$EXPERO" init "$TMPDIR/gate-cov" new-product >/dev/null
COV="$TMPDIR/gate-cov"

# No threshold → pass by default
assert_zero "gate test_coverage passes when no threshold configured" \
    "cd '$COV' && bash expero.sh gate test_coverage"
assert_match "  output says pass-by-default" \
    "cd '$COV' && bash expero.sh gate test_coverage" \
    "No coverage_threshold configured"

# Threshold set but file/format missing → fail (config error)
cat >> "$COV/.expero/config.yaml" << 'CFG'
coverage_threshold: 80
CFG
assert_nonzero "gate test_coverage fails when file/format missing" \
    "cd '$COV' && bash expero.sh gate test_coverage"

# ---- jest-json-summary: multi-line pretty-printed ----
mkdir -p "$COV/coverage"
cat > "$COV/coverage/jest.json" << 'FIX'
{
  "total": {
    "lines": { "total": 1000, "covered": 875, "skipped": 0, "pct": 87.5 },
    "statements": { "total": 1000, "covered": 850, "skipped": 0, "pct": 85 },
    "branches": { "total": 300, "covered": 240, "skipped": 0, "pct": 80 },
    "functions": { "total": 200, "covered": 190, "skipped": 0, "pct": 95 }
  }
}
FIX
# Rewrite config so only one coverage_threshold line exists.
bash "$EXPERO" init "$COV-jest" new-product >/dev/null
cat > "$COV-jest/coverage/jest.json" << 'FIX'
{
  "total": {
    "lines": { "total": 1000, "covered": 875, "skipped": 0, "pct": 87.5 },
    "statements": { "total": 1000, "covered": 850, "skipped": 0, "pct": 85 },
    "branches": { "total": 300, "covered": 240, "skipped": 0, "pct": 80 },
    "functions": { "total": 200, "covered": 190, "skipped": 0, "pct": 95 }
  }
}
FIX
mkdir -p "$COV-jest/coverage"
mv "$COV-jest/coverage/jest.json" "$COV-jest/coverage/jest.json"
cat >> "$COV-jest/.expero/config.yaml" << CFG
coverage_file: "coverage/jest.json"
coverage_format: "jest-json-summary"
coverage_threshold: 80
coverage_metric: "lines"
CFG
mkdir -p "$COV-jest/coverage"
cat > "$COV-jest/coverage/jest.json" << 'FIX'
{
  "total": {
    "lines": { "total": 1000, "covered": 875, "skipped": 0, "pct": 87.5 },
    "statements": { "total": 1000, "covered": 850, "skipped": 0, "pct": 85 },
    "branches": { "total": 300, "covered": 240, "skipped": 0, "pct": 80 },
    "functions": { "total": 200, "covered": 190, "skipped": 0, "pct": 95 }
  }
}
FIX
assert_zero "jest: threshold 80 measured 87.5 lines → PASS" \
    "cd '$COV-jest' && bash expero.sh gate test_coverage"
assert_match "  jest output reports correct measured value" \
    "cd '$COV-jest' && bash expero.sh gate test_coverage" \
    "Measured:[[:space:]]+87.5%"
# Metric switch picks different pct (branches=80, at threshold edge = PASS)
sed -i.bak 's/coverage_metric: "lines"/coverage_metric: "branches"/' "$COV-jest/.expero/config.yaml"
assert_zero "jest: metric=branches at threshold edge → PASS" \
    "cd '$COV-jest' && bash expero.sh gate test_coverage"
# Raise threshold above every pct → FAIL
sed -i.bak 's/coverage_threshold: 80/coverage_threshold: 99/' "$COV-jest/.expero/config.yaml"
assert_nonzero "jest: threshold above measured → FAIL" \
    "cd '$COV-jest' && bash expero.sh gate test_coverage"

# ---- pytest-coverage-json ----
bash "$EXPERO" init "$COV-py" new-product >/dev/null
mkdir -p "$COV-py/cov"
cat > "$COV-py/cov/py.json" << 'FIX'
{
  "meta": {"format": 2},
  "totals": {
    "covered_lines": 870,
    "num_statements": 1000,
    "percent_covered": 87.0,
    "missing_lines": 130
  }
}
FIX
cat >> "$COV-py/.expero/config.yaml" << CFG
coverage_file: "cov/py.json"
coverage_format: "pytest-coverage-json"
coverage_threshold: 85
CFG
assert_zero "pytest: 87 ≥ 85 → PASS" \
    "cd '$COV-py' && bash expero.sh gate test_coverage"
sed -i.bak 's/coverage_threshold: 85/coverage_threshold: 90/' "$COV-py/.expero/config.yaml"
assert_nonzero "pytest: 87 < 90 → FAIL" \
    "cd '$COV-py' && bash expero.sh gate test_coverage"

# ---- go-cover-func ----
bash "$EXPERO" init "$COV-go" new-product >/dev/null
mkdir -p "$COV-go/cov"
cat > "$COV-go/cov/go.txt" << 'FIX'
github.com/foo/bar/a.go:5:		doA			100.0%
github.com/foo/bar/b.go:12:		doB			75.0%
total:							(statements)	87.5%
FIX
cat >> "$COV-go/.expero/config.yaml" << CFG
coverage_file: "cov/go.txt"
coverage_format: "go-cover-func"
coverage_threshold: 80
CFG
assert_zero "go: 87.5 ≥ 80 → PASS" \
    "cd '$COV-go' && bash expero.sh gate test_coverage"
assert_match "  go: reports total pct" \
    "cd '$COV-go' && bash expero.sh gate test_coverage" \
    "Measured:[[:space:]]+87.5%"

# ---- lcov-summary ----
bash "$EXPERO" init "$COV-lcov" new-product >/dev/null
mkdir -p "$COV-lcov/cov"
cat > "$COV-lcov/cov/lcov.txt" << 'FIX'
Summary coverage rate:
  lines......: 87.5% (700 of 800 lines)
  functions..: 92.1% (210 of 228 functions)
  branches...: 81.3% (130 of 160 branches)
FIX
cat >> "$COV-lcov/.expero/config.yaml" << CFG
coverage_file: "cov/lcov.txt"
coverage_format: "lcov-summary"
coverage_threshold: 80
coverage_metric: "lines"
CFG
assert_zero "lcov: lines 87.5 ≥ 80 → PASS" \
    "cd '$COV-lcov' && bash expero.sh gate test_coverage"
sed -i.bak 's/coverage_metric: "lines"/coverage_metric: "branches"/' "$COV-lcov/.expero/config.yaml"
assert_zero "lcov: branches 81.3 ≥ 80 → PASS" \
    "cd '$COV-lcov' && bash expero.sh gate test_coverage"

# Unknown format → explicit error
bash "$EXPERO" init "$COV-bad" new-product >/dev/null
cat >> "$COV-bad/.expero/config.yaml" << CFG
coverage_file: "cov.json"
coverage_format: "not-a-real-format"
coverage_threshold: 80
CFG
echo "{}" > "$COV-bad/cov.json"
assert_nonzero "unknown coverage_format → FAIL" \
    "cd '$COV-bad' && bash expero.sh gate test_coverage"
assert_match "  error lists supported formats" \
    "cd '$COV-bad' && bash expero.sh gate test_coverage" \
    "jest-json-summary, pytest-coverage-json"

echo ""
echo "== T26p: gate all meta-gate =="
bash "$EXPERO" init "$TMPDIR/gate-all" new-product >/dev/null
# Fresh project: no artifacts, no review, no security → passes
assert_zero "gate all passes on fresh project (no task)" \
    "cd '$TMPDIR/gate-all' && bash expero.sh gate all"
# Add approved review for M0-001
cat > "$TMPDIR/gate-all/.expero/docs/review/M0-001.md" << 'RV'
# Review: M0-001
## Verdict
APPROVED
## ADR Compliance
## Issues
RV
assert_zero "gate all with task-id passes when every check passes" \
    "cd '$TMPDIR/gate-all' && bash expero.sh gate all M0-001"
assert_match "  summary line reports all N gates passed" \
    "cd '$TMPDIR/gate-all' && bash expero.sh gate all M0-001" \
    "All 5 gates passed"
# Break artifacts_valid → all should fail
cat > "$TMPDIR/gate-all/.expero/docs/adr/ADR-bad.md" << 'BAD'
# ADR-bad: missing sections
## Status
Draft
BAD
assert_nonzero "gate all fails when any gate fails" \
    "cd '$TMPDIR/gate-all' && bash expero.sh gate all M0-001"
assert_match   "  summary reports failure count" \
    "cd '$TMPDIR/gate-all' && bash expero.sh gate all M0-001" \
    "1 of 5 gates failed"

echo ""
echo "== T26q: gate unknown name fails + help lists gates =="
assert_nonzero "gate unknown_gate exits non-zero" \
    "cd '$TMPDIR/gate-all' && bash expero.sh gate unknown_gate"
assert_match "help lists gate command"      "bash '$EXPERO' help" "gate <name>"
assert_match "help lists artifacts_valid"   "bash '$EXPERO' help" "artifacts_valid"
assert_match "help lists adr_compliance"    "bash '$EXPERO' help" "adr_compliance"
assert_match "help lists security_clean"    "bash '$EXPERO' help" "security_clean"
assert_match "help lists ci_passes"         "bash '$EXPERO' help" "ci_passes"
assert_match "help lists test_coverage"     "bash '$EXPERO' help" "test_coverage"
assert_match "help lists all meta-gate"     "bash '$EXPERO' help" "^  all "

echo ""
echo "== T26q-b: roles/_meta.json is the single source of truth =="
META="$SCRIPT_DIR/roles/_meta.json"
assert_zero "roles/_meta.json exists" "[ -f '$META' ]"
# Each of the 8 roles has all 3 fields
for r in architect planner builder verifier critic sentinel scribe archaeologist; do
  for f in tier short long; do
    assert_match "  $r/$f present in _meta.json" "cat '$META'" "\"$r/$f\""
  done
done
# tier_for_role + _description_for_role read from meta (indirectly via _meta_get)
resolve_tier() {
  bash -c "source '$EXPERO' >/dev/null 2>&1 && tier_for_role '$1'" 2>/dev/null
}
resolve_desc() {
  bash -c "source '$EXPERO' >/dev/null 2>&1 && _description_for_role '$1'" 2>/dev/null
}
assert_eq "tier_for_role architect reads 'reasoning' from meta" "$(resolve_tier architect)" "reasoning"
assert_eq "tier_for_role verifier reads 'template' from meta"   "$(resolve_tier verifier)"  "template"
assert_eq "_description_for_role planner short"                  "$(resolve_desc planner)"   "Roadmap, task coordination"
assert_eq "_description_for_role sentinel short"                 "$(resolve_desc sentinel)"  "Security audit"

# init must copy _meta.json into .expero/roles/
bash "$EXPERO" init "$TMPDIR/meta-copy" new-product >/dev/null
assert_zero "init copies _meta.json" "[ -f '$TMPDIR/meta-copy/.expero/roles/_meta.json' ]"
# Detached project can resolve metadata via _resource_root
assert_eq "detached project resolves tier via meta" \
    "$(bash -c "cd '$TMPDIR/meta-copy' && source ./expero.sh >/dev/null 2>&1 && tier_for_role sentinel" 2>/dev/null)" \
    "reasoning"

# Regression: editing a description in _meta.json should change both help
# AND the next regen of the Skills plugin. Simulate by checking the
# long descriptions in the committed SKILL.md files match the meta source.
for r in architect sentinel archaeologist; do
  meta_long=$(bash -c "source '$EXPERO' >/dev/null 2>&1 && _json_get_string '$META' '$r/long'" 2>/dev/null)
  skill_desc=$(grep -E "^description: " "$SCRIPT_DIR/.claude-plugin/skills/expero-$r/SKILL.md" | sed 's/^description: //')
  if [ "$meta_long" = "$skill_desc" ]; then
    pass "  expero-$r SKILL description matches _meta.json"
  else
    fail "  expero-$r SKILL description matches _meta.json" "(run regen-skills.sh)"
  fi
done

echo ""
echo "== T26r: Claude Code Skills plugin exists =="
PLUGIN_DIR="$SCRIPT_DIR/.claude-plugin"
assert_zero "  plugin.json exists"             "[ -f '$PLUGIN_DIR/plugin.json' ]"
assert_match "  plugin.json has name 'expero'" "cat '$PLUGIN_DIR/plugin.json'" '"name":[[:space:]]*"expero"'
for role in architect planner builder verifier critic sentinel scribe archaeologist; do
  assert_zero "  skills/expero-$role/SKILL.md exists" \
      "[ -f '$PLUGIN_DIR/skills/expero-$role/SKILL.md' ]"
  assert_match "  expero-$role has frontmatter name" \
      "cat '$PLUGIN_DIR/skills/expero-$role/SKILL.md'" "^name: expero-$role\$"
  assert_match "  expero-$role has frontmatter description" \
      "cat '$PLUGIN_DIR/skills/expero-$role/SKILL.md'" "^description: "
done
assert_match "  architect description triggers on ADR" \
    "cat '$PLUGIN_DIR/skills/expero-architect/SKILL.md'" "Architecture Decision Records"
assert_match "  critic description triggers on review" \
    "cat '$PLUGIN_DIR/skills/expero-critic/SKILL.md'" "review"
assert_match "  sentinel description triggers on security" \
    "cat '$PLUGIN_DIR/skills/expero-sentinel/SKILL.md'" "security audit"

echo ""
echo "== T26s: Skills stay in sync with roles/*.md =="
# Run regen to a temp dir, compare byte-for-byte against committed
# .claude-plugin/. Any drift (role edit without running regen-skills)
# fails the test — same discipline as scenarios/roadmaps byte-regression.
SKILLS_TMP="$TMPDIR/skills-regen"
bash "$SCRIPT_DIR/scripts/regen-skills.sh" "$SKILLS_TMP" >/dev/null
for role in architect planner builder verifier critic sentinel scribe archaeologist; do
  committed="$PLUGIN_DIR/skills/expero-$role/SKILL.md"
  regenned="$SKILLS_TMP/skills/expero-$role/SKILL.md"
  if cmp -s "$committed" "$regenned"; then
    pass "  expero-$role SKILL.md up-to-date"
  else
    fail "  expero-$role SKILL.md up-to-date" "(run 'bash scripts/regen-skills.sh')"
  fi
done
if cmp -s "$PLUGIN_DIR/plugin.json" "$SKILLS_TMP/plugin.json"; then
  pass "  plugin.json up-to-date"
else
  fail "  plugin.json up-to-date" "(run 'bash scripts/regen-skills.sh')"
fi

echo ""
echo "== T26t: regen-skills script is self-contained (runs from any cwd) =="
# Guard: the script resolves repo root via $(dirname $0)/.., so it must
# work whether invoked from the repo or from elsewhere with an abs path.
assert_zero "regen-skills runs from /tmp via abs path" \
    "cd '$TMPDIR' && bash '$SCRIPT_DIR/scripts/regen-skills.sh' '$TMPDIR/skills-check' >/dev/null"

echo ""
echo "== T26u: Claude Code subagents generated + committed =="
AGENTS_DIR="$SCRIPT_DIR/.claude/agents"
assert_zero ".claude/agents/ dir exists" "[ -d '$AGENTS_DIR' ]"
for r in architect planner builder verifier critic sentinel scribe archaeologist; do
  assert_zero "  agents/expero-$r.md exists" "[ -f '$AGENTS_DIR/expero-$r.md' ]"
  for field in "^name: expero-$r\$" "^description: " "^model: " "^tools: "; do
    assert_match "  expero-$r frontmatter has '$field'" \
        "cat '$AGENTS_DIR/expero-$r.md'" "$field"
  done
done
# Tier-based model mapping
assert_match "  expero-architect uses opus (reasoning tier)" \
    "cat '$AGENTS_DIR/expero-architect.md'" "^model: claude-opus-4-7\$"
assert_match "  expero-planner uses sonnet (execution tier)" \
    "cat '$AGENTS_DIR/expero-planner.md'" "^model: claude-sonnet-4-6\$"
assert_match "  expero-verifier uses haiku (template tier)" \
    "cat '$AGENTS_DIR/expero-verifier.md'" "^model: claude-haiku-4-5"
# Tool whitelist: scribes (no Bash) vs doers (with Bash)
assert_match "  expero-architect tools OMIT Bash" \
    "cat '$AGENTS_DIR/expero-architect.md'" "^tools: Read, Write, Edit, Grep, Glob\$"
assert_match "  expero-builder tools INCLUDE Bash" \
    "cat '$AGENTS_DIR/expero-builder.md'" "^tools: Read, Write, Edit, Grep, Glob, Bash\$"

echo ""
echo "== T26v: subagents stay in sync with roles/*.md =="
SUBAGENTS_TMP="$TMPDIR/subagents-regen"
bash "$SCRIPT_DIR/scripts/regen-subagents.sh" "$SUBAGENTS_TMP" >/dev/null
for r in architect planner builder verifier critic sentinel scribe archaeologist; do
  committed="$AGENTS_DIR/expero-$r.md"
  regenned="$SUBAGENTS_TMP/agents/expero-$r.md"
  if cmp -s "$committed" "$regenned"; then
    pass "  expero-$r subagent up-to-date"
  else
    fail "  expero-$r subagent up-to-date" "(run 'bash scripts/regen-subagents.sh')"
  fi
done

echo ""
echo "== T26w: init copies .claude/agents/expero-*.md into project =="
bash "$EXPERO" init "$TMPDIR/sa-copy" new-product >/dev/null
for r in architect planner builder verifier critic sentinel scribe archaeologist; do
  assert_zero "  .claude/agents/expero-$r.md copied" \
      "[ -f '$TMPDIR/sa-copy/.claude/agents/expero-$r.md' ]"
done
# Detached project can also distribute subagents on sub-init
cp -r "$TMPDIR/sa-copy" "$TMPDIR/sa-detached"
assert_zero "detached project sub-init succeeds" \
    "cd '$TMPDIR/sa-detached' && bash expero.sh init sub-a migration"
assert_zero "  sub-project has expero-builder.md" \
    "[ -f '$TMPDIR/sa-detached/sub-a/.claude/agents/expero-builder.md' ]"

echo ""
echo "== T27: detached project can init a sub-project using .expero/scenarios =="
# When expero.sh is copied into a project, that project becomes a valid
# "install": the copy must be able to init another sub-project without
# reaching back to the source repo. Simulates: user copied expero-agents/
# somewhere and lost the source directory.
cp -r "$TMPDIR/roles-copy" "$TMPDIR/detached-init"
# Remove any stale EXPERO_SCRIPT_PATH-derived absolute refs by running
# the copied script directly, not via $EXPERO.
assert_zero "detached project can init sub-project" \
    "cd '$TMPDIR/detached-init' && bash expero.sh init sub-proj migration"
assert_zero "  sub-proj has roadmap.md"    "[ -f '$TMPDIR/detached-init/sub-proj/.expero/docs/roadmap.md' ]"
assert_zero "  sub-proj has scenarios/"    "[ -d '$TMPDIR/detached-init/sub-proj/.expero/scenarios' ]"

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
