#!/bin/bash
# test-conductor.sh — Regression tests for conductor.sh
#
# Usage: bash test-conductor.sh
# Exit code: 0 if all pass, 1 if any fail.

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
CONDUCTOR="$SCRIPT_DIR/conductor.sh"
TMPDIR=$(mktemp -d -t conductor-test.XXXXXX)
trap 'rm -rf "$TMPDIR"' EXIT

if [ ! -f "$CONDUCTOR" ]; then
  echo "conductor.sh not found at $CONDUCTOR" >&2
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

# Call functions from conductor.sh in an isolated bash subshell. The dispatch
# guard inside conductor.sh skips main when sourced, so it's safe.
resolve_model() {
  bash -c "source '$CONDUCTOR' >/dev/null 2>&1 && model_for_role '$1' '$2'" 2>/dev/null
}

SCENARIOS="new-product migration refactor legacy-analysis security-audit tech-docs multi-service greenfield-library"

echo "== T1: help command =="
assert_zero  "help exits 0"         "bash '$CONDUCTOR' help"
assert_match "help lists scenarios" "bash '$CONDUCTOR' help" "Scenarios:"
assert_match "help lists tools"     "bash '$CONDUCTOR' help" "gemini"

echo ""
echo "== T2: init generates expected files for every scenario =="
for s in $SCENARIOS; do
  assert_zero "init $s succeeds"         "bash '$CONDUCTOR' init '$TMPDIR/$s' '$s'"
  assert_zero "  config.yaml generated"  "[ -f '$TMPDIR/$s/.conductor/config.yaml' ]"
  assert_zero "  roadmap.md generated"   "[ -f '$TMPDIR/$s/.conductor/docs/roadmap.md' ]"
  assert_zero "  CLAUDE.md generated"    "[ -f '$TMPDIR/$s/CLAUDE.md' ]"
  assert_zero "  AGENTS.md generated"    "[ -f '$TMPDIR/$s/AGENTS.md' ]"
  assert_zero "  conductor.sh bootstrapped" "[ -x '$TMPDIR/$s/conductor.sh' ]"
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
assert_match "  doc mentions JSON signal form"        "cat '$AGENTS_MD'" "Structured JSON in \\.conductor/signals"
assert_match "  doc mentions signals schema"          "cat '$AGENTS_MD'" "signals/README\\.md"

echo ""
echo "== T3: config.yaml embeds correct model IDs =="
for s in $SCENARIOS; do
  assert_match "  reasoning ($s)" "cat '$TMPDIR/$s/.conductor/config.yaml'" "reasoning:[[:space:]]+claude-opus-4-7"
  assert_match "  execution ($s)" "cat '$TMPDIR/$s/.conductor/config.yaml'" "execution:[[:space:]]+claude-sonnet-4-6"
  assert_match "  template  ($s)" "cat '$TMPDIR/$s/.conductor/config.yaml'" "template:[[:space:]]+claude-haiku-4-5"
done

echo ""
echo "== T4: scenario-specific extension lists =="
assert_match "legacy-analysis has archaeologist"    "cat '$TMPDIR/legacy-analysis/.conductor/config.yaml'"    "- archaeologist"
assert_match "legacy-analysis has scribe"           "cat '$TMPDIR/legacy-analysis/.conductor/config.yaml'"    "- scribe"
assert_match "security-audit has sentinel"          "cat '$TMPDIR/security-audit/.conductor/config.yaml'"     "- sentinel"
assert_match "tech-docs has scribe"                 "cat '$TMPDIR/tech-docs/.conductor/config.yaml'"          "- scribe"
assert_match "greenfield-library has scribe"        "cat '$TMPDIR/greenfield-library/.conductor/config.yaml'" "- scribe"
assert_match "greenfield-library has sentinel"      "cat '$TMPDIR/greenfield-library/.conductor/config.yaml'" "- sentinel"

# Heredoc regression guard: no leaked bash fragments should ever appear
# in config.yaml (e.g. `echo "..."`, `case ...)`, `esac`).
for s in $SCENARIOS; do
  if grep -qE '(^[[:space:]]*echo )|(^esac)|(^[[:space:]]*[a-z-]+\)[[:space:]]+echo )' "$TMPDIR/$s/.conductor/config.yaml"; then
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
REQUIRED_SECTIONS="Project Context|Architecture Rules|Build Commands|Extension Points|Key ADRs|Conductor Protocol"
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
echo "== T5c: CLAUDE.md Conductor Protocol documents both signal forms =="
# Dogfood finding I: CLAUDE.md was missing the JSON signal form, even
# though AGENTS.md and roles/_base.md had been updated. Protocol section
# must mention .conductor/signals/ and reference README.md schema.
for s in new-product security-audit legacy-analysis; do
  claude_md="$TMPDIR/$s/CLAUDE.md"
  assert_match "  $s CLAUDE.md mentions text signal form"    "cat '$claude_md'" "NEEDS_ARCH_REVIEW"
  assert_match "  $s CLAUDE.md mentions JSON signal form"    "cat '$claude_md'" "\\.conductor/signals/"
  assert_match "  $s CLAUDE.md references signals README"    "cat '$claude_md'" "signals/README\\.md"
done

echo ""
echo "== T6: status reports correct initial task counts =="
new_product_status=$(cd "$TMPDIR/new-product" && bash conductor.sh status 2>&1)
echo "$new_product_status" | grep -qE "todo:[[:space:]]+7"    && pass "new-product todo: 7"    || fail "new-product todo: 7"    "(missing)"
echo "$new_product_status" | grep -qE "blocked:[[:space:]]+0" && pass "new-product blocked: 0" || fail "new-product blocked: 0" "(missing)"

echo ""
echo "== T7: stop signal detection (inject and re-check) =="
echo "| M0-999 | arch review probe | todo | builder | — | NEEDS_ARCH_REVIEW |" \
    >> "$TMPDIR/new-product/.conductor/docs/roadmap.md"
injected_status=$(cd "$TMPDIR/new-product" && bash conductor.sh status 2>&1)
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
assert_nonzero "restart fails without CLAUDE.md" "bash '$CONDUCTOR' restart"
popd >/dev/null

echo ""
echo "== T10: CHANGELOG.md + .conductor/signals generated by init =="
for s in $SCENARIOS; do
  assert_zero  "  CHANGELOG.md ($s)"        "[ -f '$TMPDIR/$s/CHANGELOG.md' ]"
  assert_zero  "  signals dir ($s)"         "[ -d '$TMPDIR/$s/.conductor/signals' ]"
  assert_zero  "  signals README ($s)"      "[ -f '$TMPDIR/$s/.conductor/signals/README.md' ]"
done
assert_match "CHANGELOG has Unreleased"    "cat '$TMPDIR/new-product/CHANGELOG.md'" "^## \\[Unreleased\\]"
assert_match "CHANGELOG has Keep a Changelog link" "cat '$TMPDIR/new-product/CHANGELOG.md'" "keepachangelog"
assert_match "signals README has schema"   "cat '$TMPDIR/new-product/.conductor/signals/README.md'" "NEEDS_ARCH_REVIEW"

echo ""
echo "== T11: init refuses to overwrite existing target =="
# Re-init into an already-populated path must fail AND leave contents intact.
existing_config_before=$(cat "$TMPDIR/new-product/.conductor/config.yaml")
assert_nonzero "init refuses existing target" "bash '$CONDUCTOR' init '$TMPDIR/new-product' 'new-product'"
existing_config_after=$(cat "$TMPDIR/new-product/.conductor/config.yaml")
assert_eq      "existing config.yaml untouched" "$existing_config_after" "$existing_config_before"

echo ""
echo "== T12: init rejects unknown scenario, no partial dir left =="
assert_nonzero "unknown scenario rejected" "bash '$CONDUCTOR' init '$TMPDIR/bogus-scenario' 'no-such-scenario'"
assert_nonzero "no partial dir created"    "[ -e '$TMPDIR/bogus-scenario' ]"

echo ""
echo "== T13: start rejects task-id with shell metacharacters =="
cd "$TMPDIR/new-product"
assert_nonzero "start rejects ';' in task-id"     "bash '$CONDUCTOR' start builder 'M0-001; rm -rf /' claude"
assert_nonzero "start rejects backtick in task-id" "bash '$CONDUCTOR' start builder 'M0-\`id\`' claude"
assert_nonzero "start rejects space in task-id"   "bash '$CONDUCTOR' start builder 'M0 001' claude"
# Note: can't assert_zero on valid task-id because it would invoke 'claude'
# binary which isn't guaranteed to be installed in the test env.
cd "$SCRIPT_DIR"

echo ""
echo "== T14: status grep boundary — 'todo' in task title not miscounted =="
# Fresh init (independent of T7 which injects into $TMPDIR/new-product).
# Append a row whose *title* contains 'todo' but whose status is 'completed'.
# Pre-fix: `grep -F "| todo "` matches the title substring and miscounts.
# Post-fix: regex with pipe-boundary anchors only matches the Status column.
bash "$CONDUCTOR" init "$TMPDIR/boundary" new-product >/dev/null
echo "| M0-888 | cleanup todo list | completed | builder | — | abc123 |" \
    >> "$TMPDIR/boundary/.conductor/docs/roadmap.md"
boundary_status=$(cd "$TMPDIR/boundary" && bash conductor.sh status 2>&1)
# Initial is 7 todo; after adding a *completed* row that contains "todo"
# in its title, todo count must remain 7 (not 8).
echo "$boundary_status" | grep -qE "todo:[[:space:]]+7"       && pass "todo count ignores title text" || fail "todo count ignores title text" "(got non-7)"
echo "$boundary_status" | grep -qE "completed:[[:space:]]+1"  && pass "completed count is 1"          || fail "completed count is 1"          "(missing)"

echo ""
echo "== T15: validate command =="
cp -r "$TMPDIR/new-product" "$TMPDIR/validate-empty"
# Empty project: no artifacts → warn + exit 0
assert_zero     "validate on empty project exits 0"       "cd '$TMPDIR/validate-empty' && bash conductor.sh validate"
assert_match    "validate warns on empty"                 "cd '$TMPDIR/validate-empty' && bash conductor.sh validate" "No artifacts"

cp -r "$TMPDIR/new-product" "$TMPDIR/validate-ok"
cat > "$TMPDIR/validate-ok/.conductor/docs/adr/ADR-0001-test.md" << 'ADR_EOF'
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
assert_zero     "validate on valid ADR exits 0"           "cd '$TMPDIR/validate-ok' && bash conductor.sh validate"
assert_match    "validate reports passed"                 "cd '$TMPDIR/validate-ok' && bash conductor.sh validate" "Passed:[[:space:]]+1"

cp -r "$TMPDIR/validate-ok" "$TMPDIR/validate-bad"
cat > "$TMPDIR/validate-bad/.conductor/docs/adr/ADR-0002-incomplete.md" << 'ADR_EOF'
# ADR-0002: Missing most sections

## Status
Draft
ADR_EOF
assert_nonzero  "validate on invalid ADR exits non-zero"  "cd '$TMPDIR/validate-bad' && bash conductor.sh validate"
assert_match    "validate lists missing sections"         "cd '$TMPDIR/validate-bad' && bash conductor.sh validate" "missing: .*Context"

assert_zero     "validate single-file on valid ADR"       "cd '$TMPDIR/validate-ok' && bash conductor.sh validate .conductor/docs/adr/ADR-0001-test.md"
assert_nonzero  "validate single-file nonexistent fails"  "cd '$TMPDIR/validate-ok' && bash conductor.sh validate nope.md"

# validate must fail outside an Conductor project
mkdir -p "$TMPDIR/non-conductor"
assert_nonzero  "validate outside Conductor project fails"   "cd '$TMPDIR/non-conductor' && bash '$CONDUCTOR' validate"

echo ""
echo "== T15b: signals lifecycle — resolved/ archive directory =="
# init creates resolved/ subdir alongside signals/; README documents
# the raise → resolve → archive three-step lifecycle.
for s in $SCENARIOS; do
  assert_zero "  $s has .conductor/signals/resolved/" \
      "[ -d '$TMPDIR/$s/.conductor/signals/resolved' ]"
done
assert_match "signals README has lifecycle section" \
    "cat '$TMPDIR/new-product/.conductor/signals/README.md'" "^## Lifecycle"
assert_match "signals README has dispatch table" \
    "cat '$TMPDIR/new-product/.conductor/signals/README.md'" "^## Dispatch"
assert_match "  NEEDS_ARCH_REVIEW → architect" \
    "cat '$TMPDIR/new-product/.conductor/signals/README.md'" "NEEDS_ARCH_REVIEW.*architect"
assert_match "  NEEDS_SPEC_CLARIFICATION → planner" \
    "cat '$TMPDIR/new-product/.conductor/signals/README.md'" "NEEDS_SPEC_CLARIFICATION.*planner"
assert_match "  NEEDS_SECURITY_REVIEW → sentinel" \
    "cat '$TMPDIR/new-product/.conductor/signals/README.md'" "NEEDS_SECURITY_REVIEW.*sentinel"

echo ""
echo "== T15c: status shows dispatch hint + archived count =="
# Reuse the signals project from T16 (which already has a signal)
# but also add a resolved-in-place and an archived one to cover all
# three states.
bash "$CONDUCTOR" init "$TMPDIR/sig-lc" new-product >/dev/null
cat > "$TMPDIR/sig-lc/.conductor/signals/M0-001-NEEDS_ARCH_REVIEW.json" << 'S'
{"id":"M0-001","type":"NEEDS_ARCH_REVIEW","raised_by":"builder","raised_at":"2026-04-18T10:00:00Z","description":"x","resolved":false}
S
cat > "$TMPDIR/sig-lc/.conductor/signals/M0-002-NEEDS_SEC.json" << 'S'
{"id":"M0-002","type":"NEEDS_SECURITY_REVIEW","raised_by":"builder","raised_at":"2026-04-18T10:00:00Z","description":"y","resolved":false}
S
cat > "$TMPDIR/sig-lc/.conductor/signals/M0-003-done.json" << 'S'
{"id":"M0-003","type":"NEEDS_SPEC_CLARIFICATION","raised_by":"builder","raised_at":"2026-04-18T09:00:00Z","description":"z","resolved":true,"resolved_by":"planner","resolved_at":"2026-04-18T11:00:00Z"}
S
cat > "$TMPDIR/sig-lc/.conductor/signals/resolved/M0-000-old.json" << 'S'
{"id":"M0-000","type":"NEEDS_ARCH_REVIEW","raised_by":"planner","raised_at":"2026-04-18T08:00:00Z","description":"archived","resolved":true,"resolved_by":"architect","resolved_at":"2026-04-18T09:30:00Z"}
S
sig_out=$(cd "$TMPDIR/sig-lc" && bash conductor.sh status 2>&1)
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
echo "== T16: structured signals (.conductor/signals/*.json) parsed by status =="
cp -r "$TMPDIR/new-product" "$TMPDIR/signals"
cat > "$TMPDIR/signals/.conductor/signals/M0-003-NEEDS_ARCH_REVIEW.json" << 'SIG_EOF'
{
  "id": "M0-003",
  "type": "NEEDS_ARCH_REVIEW",
  "raised_by": "builder",
  "raised_at": "2026-04-17T12:00:00Z",
  "description": "JWT library undecided",
  "resolved": false
}
SIG_EOF
cat > "$TMPDIR/signals/.conductor/signals/M0-004-resolved.json" << 'SIG_EOF'
{
  "id": "M0-004",
  "type": "NEEDS_SPEC_CLARIFICATION",
  "raised_by": "builder",
  "raised_at": "2026-04-17T11:00:00Z",
  "description": "Done",
  "resolved": true
}
SIG_EOF
sig_status=$(cd "$TMPDIR/signals" && bash conductor.sh status 2>&1)
echo "$sig_status" | grep -qE 'Stop Signals \(\.conductor/signals' && pass "structured signal section rendered" || fail "structured signal section rendered" "(missing header)"
echo "$sig_status" | awk '/Stop Signals \(\.conductor\/signals/,0' | grep -qE "NEEDS_ARCH_REVIEW:[[:space:]]+1" \
    && pass "1 unresolved NEEDS_ARCH_REVIEW counted" || fail "1 unresolved NEEDS_ARCH_REVIEW counted" "(miscount)"
echo "$sig_status" | grep -qE "resolved, in-place.*1"          && pass "1 resolved signal counted"        || fail "1 resolved signal counted"        "(miscount)"
echo "$sig_status" | grep -qE "Pending stop signals"           && pass "warning triggered by structured signal" || fail "warning triggered by structured signal" "(missing)"

echo ""
echo "== T17: set -u robustness — every command accepts minimal args =="
# With set -euo pipefail, missing-arg code paths must not crash on unbound
# variables. Each command must either run or emit a clean error — never
# bash's "unbound variable" message.
assert_zero     "help works"                              "bash '$CONDUCTOR' help"
assert_match    "init missing args reports required"      "bash '$CONDUCTOR' init 2>&1 || true" "project name required"
# 'status' / 'restart' in bare dir must error cleanly (not 'unbound variable')
cd "$TMPDIR/bare"
status_err=$(bash "$CONDUCTOR" status 2>&1 || true)
echo "$status_err" | grep -qi "unbound variable" \
    && fail "status in bare dir leaks set -u error" "(got: $status_err)" \
    || pass "status in bare dir errors cleanly"
restart_err=$(bash "$CONDUCTOR" restart 2>&1 || true)
echo "$restart_err" | grep -qi "unbound variable" \
    && fail "restart in bare dir leaks set -u error" "(got: $restart_err)" \
    || pass "restart in bare dir errors cleanly"
cd "$SCRIPT_DIR"

echo ""
echo "== T18: help mentions 'validate' command and task-id safety =="
assert_match "help lists validate"     "bash '$CONDUCTOR' help" "validate "
assert_match "help warns about task-id" "bash '$CONDUCTOR' help" "task-id.*embedded"

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
echo "== T20: init copies roles/ into .conductor/roles/ =="
bash "$CONDUCTOR" init "$TMPDIR/roles-copy" new-product >/dev/null
assert_zero  "  .conductor/roles/ created"         "[ -d '$TMPDIR/roles-copy/.conductor/roles' ]"
assert_zero  "  _base.md copied"                "[ -f '$TMPDIR/roles-copy/.conductor/roles/_base.md' ]"
for r in architect planner builder verifier critic sentinel scribe archaeologist; do
  assert_zero "  $r.md copied"                  "[ -f '$TMPDIR/roles-copy/.conductor/roles/$r.md' ]"
done

echo ""
echo "== T21: _build_prompt renders with substitutions =="
# Helper: source conductor.sh in a subshell, call _build_prompt from the
# project dir. The dispatch guard inside conductor.sh skips main when sourced.
build_prompt() {
  local proj=$1 role=$2 task=$3
  bash -c "cd '$proj' && source '$CONDUCTOR' >/dev/null 2>&1 && _build_prompt '$role' '$task'" 2>/dev/null
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
critic_rc=$(bash -c "cd '$TMPDIR/roles-copy' && source '$CONDUCTOR' >/dev/null 2>&1 && _build_prompt critic ''" 2>/dev/null; echo $?)
assert_eq "critic requires task-id (rc != 0)" "$critic_rc" "1"

# Critic with task-id → task-id appears in both the "本次任务 审查" line and the review path
critic_out=$(build_prompt "$TMPDIR/roles-copy" critic M1-042)
echo "$critic_out" | grep -qE "本次任务：审查 M1-042" \
    && pass "critic: task-id in 审查 line" || fail "critic: task-id in 审查 line" "(not found)"
echo "$critic_out" | grep -qE "review/M1-042\\.md" \
    && pass "critic: task-id in review path" || fail "critic: review path" "(not found)"

# Unknown role → fail cleanly
unknown_rc=$(bash -c "cd '$TMPDIR/roles-copy' && source '$CONDUCTOR' >/dev/null 2>&1 && _build_prompt nonesuch ''" 2>/dev/null; echo $?)
assert_eq "unknown role rejected (rc != 0)" "$unknown_rc" "1"

echo ""
echo "== T22: project is self-contained (roles resolver picks .conductor/roles) =="
# Regression: running conductor.sh from inside a generated project must NOT
# require the source repo. Move the project to a different parent so any
# accidental absolute-path leak becomes visible.
cp -r "$TMPDIR/roles-copy" "$TMPDIR/detached"
detached_out=$(bash -c "cd '$TMPDIR/detached' && source ./conductor.sh >/dev/null 2>&1 && _build_prompt architect M0-001" 2>/dev/null)
echo "$detached_out" | grep -qE "本次任务：M0-001" \
    && pass "detached project renders prompt from .conductor/roles" \
    || fail "detached project renders prompt from .conductor/roles" "(empty or wrong)"

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
  bash -c "source '$CONDUCTOR' >/dev/null 2>&1 && _json_get_array '$1' '$2'" 2>/dev/null
}
assert_eq "new-product active_roles count"       "$(read_array "$SCEN_DIR/new-product.json" active_roles | wc -l | tr -d ' ')" "5"
assert_eq "new-product extension_roles empty"    "$(read_array "$SCEN_DIR/new-product.json" extension_roles | wc -l | tr -d ' ')" "0"
assert_eq "legacy-analysis extension_roles cnt"  "$(read_array "$SCEN_DIR/legacy-analysis.json" extension_roles | wc -l | tr -d ' ')" "2"
assert_eq "security-audit active first=planner"  "$(read_array "$SCEN_DIR/security-audit.json" active_roles | head -1)" "planner"
assert_eq "security-audit active second=sentinel" "$(read_array "$SCEN_DIR/security-audit.json" active_roles | sed -n '2p')" "sentinel"
assert_eq "greenfield-library extra_dirs cnt"    "$(read_array "$SCEN_DIR/greenfield-library.json" extra_dirs | wc -l | tr -d ' ')" "2"

echo ""
echo "== T25: init copies scenarios/ into .conductor/scenarios/ =="
assert_zero "  .conductor/scenarios/ exists"             "[ -d '$TMPDIR/roles-copy/.conductor/scenarios' ]"
assert_zero "  .conductor/scenarios/roadmaps/ exists"    "[ -d '$TMPDIR/roles-copy/.conductor/scenarios/roadmaps' ]"
for s in $SCENARIOS; do
  assert_zero "  .conductor/scenarios/$s.json copied"   "[ -f '$TMPDIR/roles-copy/.conductor/scenarios/$s.json' ]"
done
assert_zero "  .conductor/scenarios/roadmaps/new-product.md copied" \
    "[ -f '$TMPDIR/roles-copy/.conductor/scenarios/roadmaps/new-product.md' ]"

echo ""
echo "== T26: roadmap.md byte-regression for all scenarios =="
# After refactor-to-JSON, every init must produce byte-identical roadmap.md
# as the hand-written scenarios/roadmaps/*.md expects. Guards against
# accidental trailing newline drift, placeholder substitution bugs, etc.
for s in $SCENARIOS; do
  bash "$CONDUCTOR" init "$TMPDIR/byte-$s" "$s" >/dev/null 2>&1
  roadmap_rel=$(awk -F'"' '/"roadmap_template":/{print $4; exit}' "$SCEN_DIR/$s.json")
  src_template="$SCEN_DIR/$roadmap_rel"
  gen_roadmap="$TMPDIR/byte-$s/.conductor/docs/roadmap.md"
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
adr_patterns=$(bash -c "source '$CONDUCTOR' >/dev/null 2>&1 && _json_get_array '$SCHEMA_DIR/adr.json' required_patterns")
assert_eq "adr pattern count is 6"                       "$(echo "$adr_patterns" | wc -l | tr -d ' ')" "6"
assert_eq "adr first pattern preserves [0-9]+"           "$(echo "$adr_patterns" | head -1)" "^# ADR-[0-9]+:"
spec_patterns=$(bash -c "source '$CONDUCTOR' >/dev/null 2>&1 && _json_get_array '$SCHEMA_DIR/spec.json' required_patterns")
assert_eq "spec pattern count is 5"                      "$(echo "$spec_patterns" | wc -l | tr -d ' ')" "5"
assert_eq "spec preserves [.] literal dot"               "$(echo "$spec_patterns" | sed -n '2p')" "^## 1[.] Config Schema"
testplan_patterns=$(bash -c "source '$CONDUCTOR' >/dev/null 2>&1 && _json_get_array '$SCHEMA_DIR/test-plan.json' required_patterns")
assert_eq "test-plan preserves [|] literal pipe"         "$(echo "$testplan_patterns" | sed -n '2p')" "[|][[:space:]]*ID[[:space:]]*[|]"

echo ""
echo "== T26d: init copies schemas/ into .conductor/schemas/ =="
for t in adr radr spec test-plan review security security-summary; do
  assert_zero "  .conductor/schemas/$t.json copied"  "[ -f '$TMPDIR/roles-copy/.conductor/schemas/$t.json' ]"
done

echo ""
echo "== T26e: help is dynamic + project-aware =="
# Outside a project: help must list every scenario from scenarios/*.json
# (not from a hardcoded block). Descriptions come from each JSON's
# "description" field — regression guards against drift where help
# silently stops reflecting reality.
help_out=$(bash "$CONDUCTOR" help)
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
    "cd '$TMPDIR/new-product' && bash '$CONDUCTOR' help" \
    "Current project:"
assert_match "  Current scenario shown" \
    "cd '$TMPDIR/new-product' && bash '$CONDUCTOR' help" \
    "scenario:[[:space:]]+new-product"
assert_match "  Active roles shown (planner)" \
    "cd '$TMPDIR/new-product' && bash '$CONDUCTOR' help" \
    "active roles:.*planner"

echo ""
echo "== T26f: start warns when role not in scenario's active_roles =="
# security-audit has active_roles = [planner, sentinel, builder].
# Starting architect there must warn (not fail — user override allowed).
bash "$CONDUCTOR" init "$TMPDIR/warn-scen" security-audit >/dev/null
warn_out=$(cd "$TMPDIR/warn-scen" && bash conductor.sh start architect 2>&1 </dev/null | head -5)
echo "$warn_out" | grep -qE "not in scenario 'security-audit'" \
    && pass "start warns on non-active role" \
    || fail "start warns on non-active role" "(no warning)"
# Starting an active role must NOT warn
ok_out=$(cd "$TMPDIR/warn-scen" && bash conductor.sh start planner 2>&1 </dev/null | head -3)
echo "$ok_out" | grep -qE "not in scenario" \
    && fail "start silent on active role" "(spurious warning)" \
    || pass "start silent on active role"

echo ""
echo "== T26g: start critic without task-id fails before 'Starting' message =="
# Regression: F19. The misleading 'Starting critic' info line used to
# print before the task-id check fired inside _build_prompt. Now the
# check is up-front and the error is the first line.
critic_out=$(cd "$TMPDIR/new-product" && bash conductor.sh start critic 2>&1 </dev/null)
first_line=$(echo "$critic_out" | grep -E "Starting|Critic requires" | head -1)
echo "$first_line" | grep -qE "Critic requires" \
    && pass "critic error precedes 'Starting' line" \
    || fail "critic error precedes 'Starting' line" "(got: '$first_line')"

echo ""
echo "== T26h: restart warns on pending stop signals =="
bash "$CONDUCTOR" init "$TMPDIR/restart-sig" new-product >/dev/null
# Clean restart — no warn about signals
clean_out=$(cd "$TMPDIR/restart-sig" && bash conductor.sh restart 2>&1)
echo "$clean_out" | grep -qE "Pending stop signals at milestone" \
    && fail "restart silent on clean state" "(spurious warning)" \
    || pass "restart silent on clean state"
# Inject a text marker — restart should warn
echo "| M9-001 | probe | todo | builder | — | NEEDS_ARCH_REVIEW |" \
    >> "$TMPDIR/restart-sig/.conductor/docs/roadmap.md"
dirty_out=$(cd "$TMPDIR/restart-sig" && bash conductor.sh restart 2>&1)
echo "$dirty_out" | grep -qE "Pending stop signals at milestone" \
    && pass "restart warns on text marker" \
    || fail "restart warns on text marker" "(no warning)"
# Exit code still 0 — warning, not error
assert_zero "restart with signals exits 0 (warning, not error)" \
    "cd '$TMPDIR/restart-sig' && bash conductor.sh restart"

echo ""
echo "== T26i: restart Next steps uses scenario's active_roles =="
# security-audit scenario — Next steps must NOT mention 'critic' (which
# isn't in active_roles) but MUST mention 'sentinel'.
sec_restart=$(cd "$TMPDIR/warn-scen" && bash conductor.sh restart 2>&1)
echo "$sec_restart" | grep -qE "start sentinel" \
    && pass "restart suggests sentinel for security-audit" \
    || fail "restart suggests sentinel for security-audit" "(missing)"
echo "$sec_restart" | grep -qE "start critic" \
    && fail "restart omits critic for security-audit" "(leaked)" \
    || pass "restart omits critic for security-audit"

echo ""
echo "== T26j: init 'Next steps' uses scenario's first active role =="
sec_init=$(bash "$CONDUCTOR" init "$TMPDIR/init-next" security-audit 2>&1)
echo "$sec_init" | grep -qE "bash conductor.sh start planner" \
    && pass "init suggests planner (first active_role) for security-audit" \
    || fail "init suggests planner for security-audit" "(wrong/missing)"

echo ""
echo "== T26k: validate reports skipped count in success line =="
bash "$CONDUCTOR" init "$TMPDIR/vskip" new-product >/dev/null
# Non-matching file in adr/ — will be skipped
echo "# random notes" > "$TMPDIR/vskip/.conductor/docs/adr/notes.md"
vskip_out=$(cd "$TMPDIR/vskip" && bash conductor.sh validate 2>&1)
echo "$vskip_out" | grep -qE "All classified artifacts valid \(1 skipped" \
    && pass "validate OK line shows skipped count" \
    || fail "validate OK line shows skipped count" "(missing)"

echo ""
echo "== T26l: roles/_base.md documents signals + .conductor/signals/ =="
BASE_MD="$SCRIPT_DIR/roles/_base.md"
assert_match "  _base.md mentions .conductor/signals"        "cat '$BASE_MD'" "\\.conductor/signals"
assert_match "  _base.md mentions Stop Signal text form"  "cat '$BASE_MD'" "NEEDS_ARCH_REVIEW"

echo ""
echo "== T26m: gate command — artifacts_valid =="
bash "$CONDUCTOR" init "$TMPDIR/gate-arts" new-product >/dev/null
# Empty project: no artifacts → pass
assert_zero "gate artifacts_valid passes on empty project" \
    "cd '$TMPDIR/gate-arts' && bash conductor.sh gate artifacts_valid"
# Add a valid ADR
cat > "$TMPDIR/gate-arts/.conductor/docs/adr/ADR-0001.md" << 'ADR'
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
    "cd '$TMPDIR/gate-arts' && bash conductor.sh gate artifacts_valid"
# Add a malformed ADR
cat > "$TMPDIR/gate-arts/.conductor/docs/adr/ADR-0002.md" << 'BAD'
# ADR-0002: Bad
## Status
Draft
BAD
assert_nonzero "gate artifacts_valid fails with invalid ADR" \
    "cd '$TMPDIR/gate-arts' && bash conductor.sh gate artifacts_valid"
assert_match   "  output includes ✗ FAIL banner" \
    "cd '$TMPDIR/gate-arts' && bash conductor.sh gate artifacts_valid" \
    "✗ FAIL"

echo ""
echo "== T26n: gate command — adr_compliance =="
bash "$CONDUCTOR" init "$TMPDIR/gate-adr" new-product >/dev/null
# Missing task-id
assert_nonzero "gate adr_compliance without task-id fails" \
    "cd '$TMPDIR/gate-adr' && bash conductor.sh gate adr_compliance"
# No review yet → fail
assert_nonzero "gate adr_compliance fails when review missing" \
    "cd '$TMPDIR/gate-adr' && bash conductor.sh gate adr_compliance M0-001"
# APPROVED review → pass
cat > "$TMPDIR/gate-adr/.conductor/docs/review/M0-001.md" << 'RV'
# Review: M0-001

## Verdict
APPROVED

## ADR Compliance
- [x] ADR-0001

## Issues
| Severity | Location | Description | Suggestion |
RV
assert_zero "gate adr_compliance passes with APPROVED review" \
    "cd '$TMPDIR/gate-adr' && bash conductor.sh gate adr_compliance M0-001"
# CHANGES_REQUESTED → fail
cat > "$TMPDIR/gate-adr/.conductor/docs/review/M0-002.md" << 'RV'
# Review: M0-002

## Verdict
CHANGES_REQUESTED

## ADR Compliance

## Issues
| Severity | Location | Description | Suggestion |
RV
assert_nonzero "gate adr_compliance fails with CHANGES_REQUESTED" \
    "cd '$TMPDIR/gate-adr' && bash conductor.sh gate adr_compliance M0-002"
assert_match   "  output mentions required APPROVED" \
    "cd '$TMPDIR/gate-adr' && bash conductor.sh gate adr_compliance M0-002" \
    "required: APPROVED"

echo ""
echo "== T26o: gate command — security_clean =="
bash "$CONDUCTOR" init "$TMPDIR/gate-sec" security-audit >/dev/null
# No summary file → gate passes by default
assert_zero "gate security_clean passes when summary absent" \
    "cd '$TMPDIR/gate-sec' && bash conductor.sh gate security_clean"
# Summary without CRITICAL row → pass
cat > "$TMPDIR/gate-sec/.conductor/docs/security/summary.md" << 'SEC'
# Security Audit Summary
| Severity | Count |
|----------|-------|
| HIGH | 2 |
| MEDIUM | 4 |
SEC
assert_zero "gate security_clean passes without CRITICAL row" \
    "cd '$TMPDIR/gate-sec' && bash conductor.sh gate security_clean"
# Summary with CRITICAL → fail
cat > "$TMPDIR/gate-sec/.conductor/docs/security/summary.md" << 'SEC'
# Security Audit Summary
| Severity | Count |
|----------|-------|
| CRITICAL | 2 |
SEC
assert_nonzero "gate security_clean fails on CRITICAL row" \
    "cd '$TMPDIR/gate-sec' && bash conductor.sh gate security_clean"
assert_match   "  output shows CRITICAL count" \
    "cd '$TMPDIR/gate-sec' && bash conductor.sh gate security_clean" \
    "2 CRITICAL finding"

# Regression for dogfood finding D/E: "| CRITICAL | 0 |" means zero
# findings (clean summary), gate MUST pass. The pre-fix version
# incorrectly failed because it matched rows containing CRITICAL
# without parsing the count column.
cat > "$TMPDIR/gate-sec/.conductor/docs/security/summary.md" << 'SEC'
# Security Audit Summary
| Severity | Count |
|----------|-------|
| CRITICAL | 0 |
| HIGH | 3 |
| MEDIUM | 5 |
SEC
assert_zero "gate security_clean passes with '| CRITICAL | 0 |'" \
    "cd '$TMPDIR/gate-sec' && bash conductor.sh gate security_clean"
assert_match "  output says no CRITICAL findings" \
    "cd '$TMPDIR/gate-sec' && bash conductor.sh gate security_clean" \
    "No CRITICAL findings"

# Multi-row CRITICAL: rare but should sum. This also guards against
# regex backsliding to "just count lines matching CRITICAL".
cat > "$TMPDIR/gate-sec/.conductor/docs/security/summary.md" << 'SEC'
# Security Audit Summary
| Severity | Count |
|----------|-------|
| CRITICAL | 3 |
| CRITICAL | 2 |
SEC
assert_match "gate reports sum when multiple CRITICAL rows" \
    "cd '$TMPDIR/gate-sec' && bash conductor.sh gate security_clean" \
    "5 CRITICAL finding"

echo ""
echo "== T26o-b: gate command — ci_passes =="
bash "$CONDUCTOR" init "$TMPDIR/gate-ci" new-product >/dev/null
# No ci_commands field configured → pass-by-default
assert_zero "gate ci_passes passes when no ci_commands configured" \
    "cd '$TMPDIR/gate-ci' && bash conductor.sh gate ci_passes"
assert_match "  output states 'pass by default'" \
    "cd '$TMPDIR/gate-ci' && bash conductor.sh gate ci_passes" \
    "No ci_commands configured"
# Generated config.yaml already has an empty `ci_commands:` block — confirm.
assert_match "  init writes ci_commands: placeholder" \
    "cat '$TMPDIR/gate-ci/.conductor/config.yaml'" \
    "^ci_commands:\$"
# Single passing command
cat >> "$TMPDIR/gate-ci/.conductor/config.yaml" << 'CFG'
  - "echo hello"
CFG
assert_zero "gate ci_passes passes with a trivially passing command" \
    "cd '$TMPDIR/gate-ci' && bash conductor.sh gate ci_passes"
# Multi-command all passing
cat >> "$TMPDIR/gate-ci/.conductor/config.yaml" << 'CFG'
  - "true"
  - "ls /"
CFG
assert_zero "gate ci_passes passes when every command exits 0" \
    "cd '$TMPDIR/gate-ci' && bash conductor.sh gate ci_passes"
# Inject a failing command at end — gate should fail
cat >> "$TMPDIR/gate-ci/.conductor/config.yaml" << 'CFG'
  - "echo boom; exit 17"
CFG
assert_nonzero "gate ci_passes fails on first non-zero exit" \
    "cd '$TMPDIR/gate-ci' && bash conductor.sh gate ci_passes"
assert_match "  output shows failing exit code" \
    "cd '$TMPDIR/gate-ci' && bash conductor.sh gate ci_passes" \
    "exit 17"
assert_match "  output surfaces command output tail" \
    "cd '$TMPDIR/gate-ci' && bash conductor.sh gate ci_passes" \
    "boom"

# Regression: YAML parser must handle quoted + unquoted items + strip
# whitespace. Rebuild config to exercise the parser specifically.
bash "$CONDUCTOR" init "$TMPDIR/gate-ci-mix" new-product >/dev/null
cat >> "$TMPDIR/gate-ci-mix/.conductor/config.yaml" << 'CFG'
  - "echo quoted"
  - echo unquoted
  -   "echo extra-space"
CFG
assert_zero "gate ci_passes parses mixed quoting" \
    "cd '$TMPDIR/gate-ci-mix' && bash conductor.sh gate ci_passes"

echo ""
echo "== T26o-c: gate command — test_coverage =="
bash "$CONDUCTOR" init "$TMPDIR/gate-cov" new-product >/dev/null
COV="$TMPDIR/gate-cov"

# No threshold → pass by default
assert_zero "gate test_coverage passes when no threshold configured" \
    "cd '$COV' && bash conductor.sh gate test_coverage"
assert_match "  output says pass-by-default" \
    "cd '$COV' && bash conductor.sh gate test_coverage" \
    "No coverage_threshold configured"

# Threshold set but file/format missing → fail (config error)
cat >> "$COV/.conductor/config.yaml" << 'CFG'
coverage_threshold: 80
CFG
assert_nonzero "gate test_coverage fails when file/format missing" \
    "cd '$COV' && bash conductor.sh gate test_coverage"

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
bash "$CONDUCTOR" init "$COV-jest" new-product >/dev/null
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
cat >> "$COV-jest/.conductor/config.yaml" << CFG
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
    "cd '$COV-jest' && bash conductor.sh gate test_coverage"
assert_match "  jest output reports correct measured value" \
    "cd '$COV-jest' && bash conductor.sh gate test_coverage" \
    "Measured:[[:space:]]+87.5%"
# Metric switch picks different pct (branches=80, at threshold edge = PASS)
sed -i.bak 's/coverage_metric: "lines"/coverage_metric: "branches"/' "$COV-jest/.conductor/config.yaml"
assert_zero "jest: metric=branches at threshold edge → PASS" \
    "cd '$COV-jest' && bash conductor.sh gate test_coverage"
# Raise threshold above every pct → FAIL
sed -i.bak 's/coverage_threshold: 80/coverage_threshold: 99/' "$COV-jest/.conductor/config.yaml"
assert_nonzero "jest: threshold above measured → FAIL" \
    "cd '$COV-jest' && bash conductor.sh gate test_coverage"

# ---- pytest-coverage-json ----
bash "$CONDUCTOR" init "$COV-py" new-product >/dev/null
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
cat >> "$COV-py/.conductor/config.yaml" << CFG
coverage_file: "cov/py.json"
coverage_format: "pytest-coverage-json"
coverage_threshold: 85
CFG
assert_zero "pytest: 87 ≥ 85 → PASS" \
    "cd '$COV-py' && bash conductor.sh gate test_coverage"
sed -i.bak 's/coverage_threshold: 85/coverage_threshold: 90/' "$COV-py/.conductor/config.yaml"
assert_nonzero "pytest: 87 < 90 → FAIL" \
    "cd '$COV-py' && bash conductor.sh gate test_coverage"

# ---- go-cover-func ----
bash "$CONDUCTOR" init "$COV-go" new-product >/dev/null
mkdir -p "$COV-go/cov"
cat > "$COV-go/cov/go.txt" << 'FIX'
github.com/foo/bar/a.go:5:		doA			100.0%
github.com/foo/bar/b.go:12:		doB			75.0%
total:							(statements)	87.5%
FIX
cat >> "$COV-go/.conductor/config.yaml" << CFG
coverage_file: "cov/go.txt"
coverage_format: "go-cover-func"
coverage_threshold: 80
CFG
assert_zero "go: 87.5 ≥ 80 → PASS" \
    "cd '$COV-go' && bash conductor.sh gate test_coverage"
assert_match "  go: reports total pct" \
    "cd '$COV-go' && bash conductor.sh gate test_coverage" \
    "Measured:[[:space:]]+87.5%"

# ---- lcov-summary ----
bash "$CONDUCTOR" init "$COV-lcov" new-product >/dev/null
mkdir -p "$COV-lcov/cov"
cat > "$COV-lcov/cov/lcov.txt" << 'FIX'
Summary coverage rate:
  lines......: 87.5% (700 of 800 lines)
  functions..: 92.1% (210 of 228 functions)
  branches...: 81.3% (130 of 160 branches)
FIX
cat >> "$COV-lcov/.conductor/config.yaml" << CFG
coverage_file: "cov/lcov.txt"
coverage_format: "lcov-summary"
coverage_threshold: 80
coverage_metric: "lines"
CFG
assert_zero "lcov: lines 87.5 ≥ 80 → PASS" \
    "cd '$COV-lcov' && bash conductor.sh gate test_coverage"
sed -i.bak 's/coverage_metric: "lines"/coverage_metric: "branches"/' "$COV-lcov/.conductor/config.yaml"
assert_zero "lcov: branches 81.3 ≥ 80 → PASS" \
    "cd '$COV-lcov' && bash conductor.sh gate test_coverage"

# Unknown format → explicit error
bash "$CONDUCTOR" init "$COV-bad" new-product >/dev/null
cat >> "$COV-bad/.conductor/config.yaml" << CFG
coverage_file: "cov.json"
coverage_format: "not-a-real-format"
coverage_threshold: 80
CFG
echo "{}" > "$COV-bad/cov.json"
assert_nonzero "unknown coverage_format → FAIL" \
    "cd '$COV-bad' && bash conductor.sh gate test_coverage"
assert_match "  error lists supported formats" \
    "cd '$COV-bad' && bash conductor.sh gate test_coverage" \
    "jest-json-summary, pytest-coverage-json"

echo ""
echo "== T26p: gate all meta-gate =="
bash "$CONDUCTOR" init "$TMPDIR/gate-all" new-product >/dev/null
# Fresh project: no artifacts, no review, no security → passes
assert_zero "gate all passes on fresh project (no task)" \
    "cd '$TMPDIR/gate-all' && bash conductor.sh gate all"
# Add approved review for M0-001
cat > "$TMPDIR/gate-all/.conductor/docs/review/M0-001.md" << 'RV'
# Review: M0-001
## Verdict
APPROVED
## ADR Compliance
## Issues
RV
assert_zero "gate all with task-id passes when every check passes" \
    "cd '$TMPDIR/gate-all' && bash conductor.sh gate all M0-001"
assert_match "  summary line reports all N gates passed" \
    "cd '$TMPDIR/gate-all' && bash conductor.sh gate all M0-001" \
    "All 5 gates passed"
# Break artifacts_valid → all should fail
cat > "$TMPDIR/gate-all/.conductor/docs/adr/ADR-bad.md" << 'BAD'
# ADR-bad: missing sections
## Status
Draft
BAD
assert_nonzero "gate all fails when any gate fails" \
    "cd '$TMPDIR/gate-all' && bash conductor.sh gate all M0-001"
assert_match   "  summary reports failure count" \
    "cd '$TMPDIR/gate-all' && bash conductor.sh gate all M0-001" \
    "1 of 5 gates failed"

echo ""
echo "== T26o-d: gate pr composite =="
bash "$CONDUCTOR" init "$TMPDIR/gate-pr" new-product >/dev/null
# pr requires task-id
assert_nonzero "gate pr without task-id fails" \
    "cd '$TMPDIR/gate-pr' && bash conductor.sh gate pr"
# pr without review → fails (adr_compliance branch)
assert_nonzero "gate pr fails when review missing" \
    "cd '$TMPDIR/gate-pr' && bash conductor.sh gate pr M0-001"
# pr with approved review + clean artifacts + no ci_commands → pass
cat > "$TMPDIR/gate-pr/.conductor/docs/review/M0-001.md" << 'RV'
# Review: M0-001
## Verdict
APPROVED
## ADR Compliance
## Issues
RV
assert_zero "gate pr passes when all 3 components pass" \
    "cd '$TMPDIR/gate-pr' && bash conductor.sh gate pr M0-001"
assert_match "  pr success says '3 gates'" \
    "cd '$TMPDIR/gate-pr' && bash conductor.sh gate pr M0-001" \
    "PR ready: all 3 gates passed"
# pr does NOT run security or coverage — even if they'd fail, pr should
# still pass so long as the 3 core gates pass. Prove it by adding a
# security summary with CRITICAL findings:
mkdir -p "$TMPDIR/gate-pr/.conductor/docs/security"
cat > "$TMPDIR/gate-pr/.conductor/docs/security/summary.md" << 'SEC'
# Security Summary
| Severity | Count |
|----------|-------|
| CRITICAL | 5 |
SEC
assert_zero "gate pr ignores security_clean (pr scope is narrower)" \
    "cd '$TMPDIR/gate-pr' && bash conductor.sh gate pr M0-001"
# But gate all should now fail
assert_nonzero "gate all still catches the CRITICAL" \
    "cd '$TMPDIR/gate-pr' && bash conductor.sh gate all M0-001"

echo ""
echo "== T26q: gate unknown name fails + help lists gates =="
assert_nonzero "gate unknown_gate exits non-zero" \
    "cd '$TMPDIR/gate-all' && bash conductor.sh gate unknown_gate"
assert_match "help lists gate command"      "bash '$CONDUCTOR' help" "gate <name>"
assert_match "help lists artifacts_valid"   "bash '$CONDUCTOR' help" "artifacts_valid"
assert_match "help lists adr_compliance"    "bash '$CONDUCTOR' help" "adr_compliance"
assert_match "help lists security_clean"    "bash '$CONDUCTOR' help" "security_clean"
assert_match "help lists ci_passes"         "bash '$CONDUCTOR' help" "ci_passes"
assert_match "help lists test_coverage"     "bash '$CONDUCTOR' help" "test_coverage"
assert_match "help lists pr composite gate" "bash '$CONDUCTOR' help" "^  pr <task>"
assert_match "help lists all meta-gate"     "bash '$CONDUCTOR' help" "^  all "

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
  bash -c "source '$CONDUCTOR' >/dev/null 2>&1 && tier_for_role '$1'" 2>/dev/null
}
resolve_desc() {
  bash -c "source '$CONDUCTOR' >/dev/null 2>&1 && _description_for_role '$1'" 2>/dev/null
}
assert_eq "tier_for_role architect reads 'reasoning' from meta" "$(resolve_tier architect)" "reasoning"
assert_eq "tier_for_role verifier reads 'template' from meta"   "$(resolve_tier verifier)"  "template"
assert_eq "_description_for_role planner short"                  "$(resolve_desc planner)"   "Roadmap, task coordination"
assert_eq "_description_for_role sentinel short"                 "$(resolve_desc sentinel)"  "Security audit"

# init must copy _meta.json into .conductor/roles/
bash "$CONDUCTOR" init "$TMPDIR/meta-copy" new-product >/dev/null
assert_zero "init copies _meta.json" "[ -f '$TMPDIR/meta-copy/.conductor/roles/_meta.json' ]"
# Detached project can resolve metadata via _resource_root
assert_eq "detached project resolves tier via meta" \
    "$(bash -c "cd '$TMPDIR/meta-copy' && source ./conductor.sh >/dev/null 2>&1 && tier_for_role sentinel" 2>/dev/null)" \
    "reasoning"

# Regression: editing a description in _meta.json should change both help
# AND the next regen of the Skills plugin. Simulate by checking the
# long descriptions in the committed SKILL.md files match the meta source.
for r in architect sentinel archaeologist; do
  meta_long=$(bash -c "source '$CONDUCTOR' >/dev/null 2>&1 && _json_get_string '$META' '$r/long'" 2>/dev/null)
  skill_desc=$(grep -E "^description: " "$SCRIPT_DIR/.claude-plugin/skills/conductor-$r/SKILL.md" | sed 's/^description: //')
  if [ "$meta_long" = "$skill_desc" ]; then
    pass "  conductor-$r SKILL description matches _meta.json"
  else
    fail "  conductor-$r SKILL description matches _meta.json" "(run regen-skills.sh)"
  fi
done

echo ""
echo "== T26r: Claude Code Skills plugin exists =="
PLUGIN_DIR="$SCRIPT_DIR/.claude-plugin"
assert_zero "  plugin.json exists"             "[ -f '$PLUGIN_DIR/plugin.json' ]"
assert_match "  plugin.json has name 'conductor'" "cat '$PLUGIN_DIR/plugin.json'" '"name":[[:space:]]*"conductor"'
for role in architect planner builder verifier critic sentinel scribe archaeologist; do
  assert_zero "  skills/conductor-$role/SKILL.md exists" \
      "[ -f '$PLUGIN_DIR/skills/conductor-$role/SKILL.md' ]"
  assert_match "  conductor-$role has frontmatter name" \
      "cat '$PLUGIN_DIR/skills/conductor-$role/SKILL.md'" "^name: conductor-$role\$"
  assert_match "  conductor-$role has frontmatter description" \
      "cat '$PLUGIN_DIR/skills/conductor-$role/SKILL.md'" "^description: "
done
assert_match "  architect description triggers on ADR" \
    "cat '$PLUGIN_DIR/skills/conductor-architect/SKILL.md'" "Architecture Decision Records"
assert_match "  critic description triggers on review" \
    "cat '$PLUGIN_DIR/skills/conductor-critic/SKILL.md'" "review"
assert_match "  sentinel description triggers on security" \
    "cat '$PLUGIN_DIR/skills/conductor-sentinel/SKILL.md'" "security audit"

echo ""
echo "== T26s: Skills stay in sync with roles/*.md =="
# Run regen to a temp dir, compare byte-for-byte against committed
# .claude-plugin/. Any drift (role edit without running regen-skills)
# fails the test — same discipline as scenarios/roadmaps byte-regression.
SKILLS_TMP="$TMPDIR/skills-regen"
bash "$SCRIPT_DIR/scripts/regen-skills.sh" "$SKILLS_TMP" >/dev/null
for role in architect planner builder verifier critic sentinel scribe archaeologist; do
  committed="$PLUGIN_DIR/skills/conductor-$role/SKILL.md"
  regenned="$SKILLS_TMP/skills/conductor-$role/SKILL.md"
  if cmp -s "$committed" "$regenned"; then
    pass "  conductor-$role SKILL.md up-to-date"
  else
    fail "  conductor-$role SKILL.md up-to-date" "(run 'bash scripts/regen-skills.sh')"
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
  assert_zero "  agents/conductor-$r.md exists" "[ -f '$AGENTS_DIR/conductor-$r.md' ]"
  for field in "^name: conductor-$r\$" "^description: " "^model: " "^tools: "; do
    assert_match "  conductor-$r frontmatter has '$field'" \
        "cat '$AGENTS_DIR/conductor-$r.md'" "$field"
  done
done
# Tier-based model mapping
assert_match "  conductor-architect uses opus (reasoning tier)" \
    "cat '$AGENTS_DIR/conductor-architect.md'" "^model: claude-opus-4-7\$"
assert_match "  conductor-planner uses sonnet (execution tier)" \
    "cat '$AGENTS_DIR/conductor-planner.md'" "^model: claude-sonnet-4-6\$"
assert_match "  conductor-verifier uses haiku (template tier)" \
    "cat '$AGENTS_DIR/conductor-verifier.md'" "^model: claude-haiku-4-5"
# Tool whitelist: scribes (no Bash) vs doers (with Bash)
assert_match "  conductor-architect tools OMIT Bash" \
    "cat '$AGENTS_DIR/conductor-architect.md'" "^tools: Read, Write, Edit, Grep, Glob\$"
assert_match "  conductor-builder tools INCLUDE Bash" \
    "cat '$AGENTS_DIR/conductor-builder.md'" "^tools: Read, Write, Edit, Grep, Glob, Bash\$"

echo ""
echo "== T26t-b: orchestrator source lives at subagents/ =="
# After the source-pattern refactor: subagents/conductor-orchestrator.md is
# the hand-curated source; regen-subagents.sh passes it through to
# .claude/agents/ unchanged. Guard that both exist + bytes match.
SRC_ORCH="$SCRIPT_DIR/subagents/conductor-orchestrator.md"
DST_ORCH="$SCRIPT_DIR/.claude/agents/conductor-orchestrator.md"
assert_zero "subagents/conductor-orchestrator.md source exists" "[ -f '$SRC_ORCH' ]"
assert_zero "  .claude/agents/conductor-orchestrator.md generated exists" "[ -f '$DST_ORCH' ]"
if cmp -s "$SRC_ORCH" "$DST_ORCH"; then
  pass "  orchestrator source ↔ .claude/agents/ byte-identical"
else
  fail "  orchestrator source ↔ .claude/agents/ byte-identical" "(run regen-subagents)"
fi

echo ""
echo "== T26t-c: restart includes gate snapshot =="
bash "$CONDUCTOR" init "$TMPDIR/restart-snap" new-product >/dev/null
snap_out=$(cd "$TMPDIR/restart-snap" && bash conductor.sh restart 2>&1)
echo "$snap_out" | grep -qE "Gate snapshot" \
    && pass "restart output includes 'Gate snapshot' section" \
    || fail "restart output includes 'Gate snapshot' section" "(missing)"
echo "$snap_out" | grep -qE "gates passed|gates failed" \
    && pass "restart shows gate all tally" \
    || fail "restart shows gate all tally" "(missing)"
echo "$snap_out" | grep -qE "Orchestrated" \
    && pass "restart next-steps offers orchestrator option" \
    || fail "restart next-steps offers orchestrator option" "(missing)"

echo ""
echo "== T26u-b: orchestrator subagent (Phase 2) =="
# Orchestrator is hand-written (not regen'd from roles/) because it's a
# meta-agent that dispatches other subagents, not a role that does work.
# Guard: must exist, have frontmatter, reference every role it can
# dispatch, explicitly list the signal→role mapping.
ORCH="$AGENTS_DIR/conductor-orchestrator.md"
assert_zero ".claude/agents/conductor-orchestrator.md exists" "[ -f '$ORCH' ]"
assert_match "  orchestrator has name frontmatter"   "cat '$ORCH'" "^name: conductor-orchestrator\$"
assert_match "  orchestrator has description"        "cat '$ORCH'" "^description: "
assert_match "  orchestrator has Task tool enabled"  "cat '$ORCH'" "^tools:.*Task"
assert_match "  orchestrator uses reasoning model"   "cat '$ORCH'" "^model: claude-opus"
# Drift guard: orchestrator must reference every role it's expected
# to dispatch. If someone adds a 9th role without updating the
# orchestrator, this test points at it.
for r in planner architect builder verifier critic sentinel scribe archaeologist; do
  assert_match "  orchestrator references conductor-$r" \
      "cat '$ORCH'" "conductor-$r"
done
# Signal → role dispatch table must be present (regression for ROADMAP 2.0.1 close)
for signal_pair in "NEEDS_ARCH_REVIEW.*architect" "NEEDS_SPEC_CLARIFICATION.*planner" "NEEDS_SECURITY_REVIEW.*sentinel" "BLOCKED_BY_"; do
  assert_match "  orchestrator maps $signal_pair" \
      "cat '$ORCH'" "$signal_pair"
done

echo ""
echo "== T26u-c: init copies orchestrator into project =="
bash "$CONDUCTOR" init "$TMPDIR/orch-copy" new-product >/dev/null
assert_zero "  .claude/agents/conductor-orchestrator.md copied" \
    "[ -f '$TMPDIR/orch-copy/.claude/agents/conductor-orchestrator.md' ]"

echo ""
echo "== T26v: subagents stay in sync with roles/*.md =="
SUBAGENTS_TMP="$TMPDIR/subagents-regen"
bash "$SCRIPT_DIR/scripts/regen-subagents.sh" "$SUBAGENTS_TMP" >/dev/null
for r in architect planner builder verifier critic sentinel scribe archaeologist; do
  committed="$AGENTS_DIR/conductor-$r.md"
  regenned="$SUBAGENTS_TMP/agents/conductor-$r.md"
  if cmp -s "$committed" "$regenned"; then
    pass "  conductor-$r subagent up-to-date"
  else
    fail "  conductor-$r subagent up-to-date" "(run 'bash scripts/regen-subagents.sh')"
  fi
done

echo ""
echo "== T26w: init copies .claude/agents/conductor-*.md into project =="
bash "$CONDUCTOR" init "$TMPDIR/sa-copy" new-product >/dev/null
for r in architect planner builder verifier critic sentinel scribe archaeologist; do
  assert_zero "  .claude/agents/conductor-$r.md copied" \
      "[ -f '$TMPDIR/sa-copy/.claude/agents/conductor-$r.md' ]"
done
# Detached project can also distribute subagents on sub-init
cp -r "$TMPDIR/sa-copy" "$TMPDIR/sa-detached"
assert_zero "detached project sub-init succeeds" \
    "cd '$TMPDIR/sa-detached' && bash conductor.sh init sub-a migration"
assert_zero "  sub-project has conductor-builder.md" \
    "[ -f '$TMPDIR/sa-detached/sub-a/.claude/agents/conductor-builder.md' ]"

echo ""
echo "== T28: --quiet flag suppresses info/ok/warn but not errors =="
bash "$CONDUCTOR" init "$TMPDIR/quiet" new-product >/dev/null
assert_match "help without --quiet shows banner" \
    "bash '$CONDUCTOR' help" "Commands:"
assert_zero "init --quiet succeeds"  "bash '$CONDUCTOR' --quiet init '$TMPDIR/quiet-init' new-product"
assert_zero "  --quiet init produced files" "[ -f '$TMPDIR/quiet-init/conductor.sh' ]"
assert_nonzero "status --quiet outside project fails" \
    "cd '$TMPDIR/bare' && bash '$CONDUCTOR' --quiet status"
err_out=$(cd "$TMPDIR/bare" && bash "$CONDUCTOR" --quiet status 2>&1 || true)
echo "$err_out" | grep -qE "Not a Conductor project" \
    && pass "  --quiet still prints errors on stderr" \
    || fail "  --quiet still prints errors on stderr" "(suppressed wrongly)"

echo ""
echo "== T29: resume command =="
mkdir -p "$TMPDIR/no-proj"
assert_nonzero "resume outside project fails" \
    "cd '$TMPDIR/no-proj' && bash '$CONDUCTOR' resume"

bash "$CONDUCTOR" init "$TMPDIR/resume-clean" new-product >/dev/null
clean_out=$(cd "$TMPDIR/resume-clean" && bash conductor.sh resume 2>&1)
echo "$clean_out" | grep -qE "No in-progress tasks found" \
    && pass "resume reports no in-progress on clean project" \
    || fail "resume reports no in-progress on clean project" "(missing)"
echo "$clean_out" | grep -qE "Suggested next" \
    && pass "resume always prints Suggested next section" \
    || fail "resume always prints Suggested next section" "(missing)"

bash "$CONDUCTOR" init "$TMPDIR/resume-work" new-product >/dev/null
sed -i '' 's/| M0-001 | Project scaffold | todo | builder/| M0-001 | Project scaffold | in-progress | builder/' \
    "$TMPDIR/resume-work/.conductor/docs/roadmap.md"
cat > "$TMPDIR/resume-work/.conductor/signals/M0-001-NEEDS_ARCH_REVIEW.json" << 'SIG'
{"id":"M0-001","type":"NEEDS_ARCH_REVIEW","raised_by":"builder","raised_at":"2026-04-19T10:00:00Z","description":"x","resolved":false}
SIG
work_out=$(cd "$TMPDIR/resume-work" && bash conductor.sh resume 2>&1)
echo "$work_out" | grep -qE "Last in-progress task" \
    && pass "resume shows last in-progress task" \
    || fail "resume shows last in-progress task" "(missing)"
echo "$work_out" | grep -qE "ID:.*M0-001" \
    && pass "resume extracts task-id correctly" \
    || fail "resume extracts task-id correctly" "(missing)"
echo "$work_out" | grep -qE "start architect.*resolve arch" \
    && pass "resume suggests architect for open arch signal" \
    || fail "resume suggests architect for open arch signal" "(missing)"

echo ""
echo "== T30: doctor command =="
assert_nonzero "doctor outside project fails" \
    "cd '$TMPDIR/no-proj' && bash '$CONDUCTOR' doctor"
bash "$CONDUCTOR" init "$TMPDIR/doctor-clean" new-product >/dev/null
assert_zero "doctor passes on clean project" \
    "cd '$TMPDIR/doctor-clean' && bash conductor.sh doctor"
assert_match "doctor says Project is healthy when clean" \
    "cd '$TMPDIR/doctor-clean' && bash conductor.sh doctor" \
    "Project is healthy"

bash "$CONDUCTOR" init "$TMPDIR/doctor-warn" new-product >/dev/null
sed -i '' 's/| M0-001 | Project scaffold | todo | builder/| M0-001 | Project scaffold | completed | builder/' \
    "$TMPDIR/doctor-warn/.conductor/docs/roadmap.md"
warn_out=$(cd "$TMPDIR/doctor-warn" && bash conductor.sh doctor 2>&1)
echo "$warn_out" | grep -qE "M0-001 marked completed but no commit hash" \
    && pass "doctor flags completed task without commit hash" \
    || fail "doctor flags completed task without commit hash" "(missing)"
assert_zero "doctor exits 0 on warnings-only" \
    "cd '$TMPDIR/doctor-warn' && bash conductor.sh doctor"

echo "# random" > "$TMPDIR/doctor-warn/.conductor/docs/specs/M0-ORPHAN.md"
orphan_out=$(cd "$TMPDIR/doctor-warn" && bash conductor.sh doctor 2>&1)
echo "$orphan_out" | grep -qE "M0-ORPHAN.*no matching task" \
    && pass "doctor flags orphan spec" \
    || fail "doctor flags orphan spec" "(missing)"

bash "$CONDUCTOR" init "$TMPDIR/doctor-fail" new-product >/dev/null
cat > "$TMPDIR/doctor-fail/.conductor/docs/adr/ADR-0001.md" << 'ADR'
# ADR-0001: Test
## Status
Superseded by ADR-9999
## Context
x
## Decision
y
## Consequences
## Alternatives Considered
z
ADR
assert_nonzero "doctor fails on broken ADR chain" \
    "cd '$TMPDIR/doctor-fail' && bash conductor.sh doctor"
assert_match "doctor output names the missing ADR" \
    "cd '$TMPDIR/doctor-fail' && bash conductor.sh doctor" \
    "references ADR-9999 but it doesn't exist"

bash "$CONDUCTOR" init "$TMPDIR/doctor-missing" new-product >/dev/null
rm "$TMPDIR/doctor-missing/.conductor/docs/ci-status.md"
assert_nonzero "doctor fails when required file missing" \
    "cd '$TMPDIR/doctor-missing' && bash conductor.sh doctor"

echo ""
echo "== T31: help lists new commands =="
assert_match "help lists resume" "bash '$CONDUCTOR' help" "^  resume"
assert_match "help lists doctor" "bash '$CONDUCTOR' help" "^  doctor"
assert_match "help lists --quiet" "bash '$CONDUCTOR' help" "^  --quiet"

echo ""
echo "== T27: detached project can init a sub-project using .conductor/scenarios =="
# When conductor.sh is copied into a project, that project becomes a valid
# "install": the copy must be able to init another sub-project without
# reaching back to the source repo. Simulates: user copied conductor/
# somewhere and lost the source directory.
cp -r "$TMPDIR/roles-copy" "$TMPDIR/detached-init"
# Remove any stale CONDUCTOR_SCRIPT_PATH-derived absolute refs by running
# the copied script directly, not via $CONDUCTOR.
assert_zero "detached project can init sub-project" \
    "cd '$TMPDIR/detached-init' && bash conductor.sh init sub-proj migration"
assert_zero "  sub-proj has roadmap.md"    "[ -f '$TMPDIR/detached-init/sub-proj/.conductor/docs/roadmap.md' ]"
assert_zero "  sub-proj has scenarios/"    "[ -d '$TMPDIR/detached-init/sub-proj/.conductor/scenarios' ]"

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
