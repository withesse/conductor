#!/bin/bash
# Expero Agents — Universal Bootstrap
#
# Usage:
#   bash expero.sh init <project-name> <scenario>
#   bash expero.sh start <role> [task-id]
#   bash expero.sh status
#   bash expero.sh restart
#
# Scenarios:
#   new-product          从零构建新产品
#   migration            项目迁移
#   refactor             代码库重构
#   legacy-analysis      遗留代码理解
#   security-audit       安全审计
#   tech-docs            文档体系建设
#   multi-service        多服务联调
#   greenfield-library   全新开源库
#
# Roles:
#   architect, planner, builder, verifier, critic
#   sentinel, scribe, archaeologist
#
# Examples:
#   bash expero.sh init my-app new-product
#   bash expero.sh start architect
#   bash expero.sh start builder M0-001
#   bash expero.sh status
#   bash expero.sh restart

set -euo pipefail

EXPERO_VERSION="1.0.0"
COMMAND=${1:-help}

# Resolve the absolute path of this script at load time, before any cd.
# macOS bash 3.2 has no built-in realpath. Several helpers (_resource_root,
# cmd_init's script-copy step) depend on this; resolving lazily after a cd
# gives relative paths that point at the staging dir instead of the source.
_EXPERO_SRC="${BASH_SOURCE[0]:-$0}"
if [ -n "$_EXPERO_SRC" ] && [ -f "$_EXPERO_SRC" ]; then
  EXPERO_SCRIPT_PATH="$(cd "$(dirname -- "$_EXPERO_SRC")" 2>/dev/null && pwd)/$(basename -- "$_EXPERO_SRC")"
else
  EXPERO_SCRIPT_PATH=""
fi
unset _EXPERO_SRC

# ─────────────────────────────────────────
# Color output
# ─────────────────────────────────────────
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

info()  { echo -e "${BLUE}ℹ${NC}  $1"; }
ok()    { echo -e "${GREEN}✓${NC}  $1"; }
warn()  { echo -e "${YELLOW}⚠${NC}  $1"; }
err()   { echo -e "${RED}✗${NC}  $1" >&2; }

# ─────────────────────────────────────────
# Model configuration
# ─────────────────────────────────────────
# Claude (Anthropic)
MODEL_CLAUDE_REASONING="claude-opus-4-7"
MODEL_CLAUDE_EXECUTION="claude-sonnet-4-6"
MODEL_CLAUDE_TEMPLATE="claude-haiku-4-5-20251001"

# OpenAI (GPT-5.4 series; Codex capabilities merged into mainline from 5.4)
MODEL_OPENAI_REASONING="gpt-5.4-pro"
MODEL_OPENAI_EXECUTION="gpt-5.4"
MODEL_OPENAI_TEMPLATE="gpt-5.4-mini"

# Gemini (Google, 3.x series)
MODEL_GEMINI_REASONING="gemini-3.1-pro"
MODEL_GEMINI_EXECUTION="gemini-3-flash"
MODEL_GEMINI_TEMPLATE="gemini-3.1-flash-lite"

# Map role → tier
tier_for_role() {
  case "$1" in
    architect|sentinel|archaeologist) echo "reasoning" ;;
    planner|builder|critic|scribe)    echo "execution" ;;
    verifier)                          echo "template" ;;
    *) err "Unknown role: $1"; exit 1 ;;
  esac
}

# Map (tool, role) → model ID. Validates role first, then tool, so error
# messages distinguish the two failure modes instead of both saying
# "unknown tool/role".
model_for_role() {
  local role=$1
  local tool=${2:-claude}
  local tier
  tier=$(tier_for_role "$role")
  case "$tool:$tier" in
    claude:reasoning) echo "$MODEL_CLAUDE_REASONING" ;;
    claude:execution) echo "$MODEL_CLAUDE_EXECUTION" ;;
    claude:template)  echo "$MODEL_CLAUDE_TEMPLATE" ;;
    codex:reasoning)  echo "$MODEL_OPENAI_REASONING" ;;
    codex:execution)  echo "$MODEL_OPENAI_EXECUTION" ;;
    codex:template)   echo "$MODEL_OPENAI_TEMPLATE" ;;
    gemini:reasoning) echo "$MODEL_GEMINI_REASONING" ;;
    gemini:execution) echo "$MODEL_GEMINI_EXECUTION" ;;
    gemini:template)  echo "$MODEL_GEMINI_TEMPLATE" ;;
    *) err "Unknown tool: '$tool' for role '$role' (supported: claude, codex, gemini)"; exit 1 ;;
  esac
}

# ─────────────────────────────────────────
# init: initialize a new Expero project
# ─────────────────────────────────────────
cmd_init() {
  local project=${1:?"project name required"}
  local scenario=${2:-new-product}

  # Reject an existing target before doing anything else. init is
  # initialization, not merge — overwriting a populated directory is
  # almost always a bug (e.g. typo in project name).
  if [ -e "$project" ]; then
    err "Target '$project' already exists; init refuses to overwrite"
    exit 1
  fi

  # Validate scenario up-front so we don't create a staging dir for an
  # unknown scenario only to fail mid-way. Validity = scenarios/<name>.json
  # exists at the current resource root.
  local _root
  _root=$(_resource_root)
  if [ ! -f "$_root/scenarios/$scenario.json" ]; then
    err "Unknown scenario: '$scenario' (run 'bash $0 help' for the list)"
    exit 1
  fi

  # Script source already resolved at load time into EXPERO_SCRIPT_PATH
  # (see top of file). We pass it to _gen_scripts for the in-project copy.
  local script_src=${EXPERO_SCRIPT_PATH:-}
  local parent project_name target
  parent=$(cd "$(dirname -- "$project")" 2>/dev/null && pwd) || parent=""
  project_name=$(basename -- "$project")
  if [ -z "$parent" ] || [ -z "$project_name" ]; then
    err "Cannot resolve target path for '$project'"
    exit 1
  fi
  target="$parent/$project_name"

  info "Initializing Expero project"
  echo "  Project:  $project"
  echo "  Scenario: $scenario"
  echo ""

  # Atomic-init: stage all generation in a sibling temp dir, then rename
  # into place. Staging lives next to the target so `mv` is guaranteed
  # same-filesystem (and therefore atomic). On any failure — generator
  # error, SIGINT, disk full — the EXIT trap removes staging; the target
  # path is never partially created. Ref: SPEC §1 principle of
  # "repeatable, auditable" state.
  local staging
  staging=$(mktemp -d "$parent/.expero-init.XXXXXX")
  trap 'rm -rf -- "$staging"' EXIT

  mkdir -p "$staging/.expero" "$staging/.expero/docs/adr" "$staging/.expero/docs/specs" "$staging/.expero/docs/review" "$staging/.expero/signals"

  # Scenario-specific extra dirs (empty for scenarios that don't need
  # any). Source is scenarios/<name>.json → "extra_dirs" array.
  local _d
  while IFS= read -r _d; do
    [ -z "$_d" ] && continue
    mkdir -p "$staging/$_d"
  done < <(_json_get_array "$_root/scenarios/$scenario.json" extra_dirs)

  cd "$staging"

  # Generate framework config
  _gen_expero_config "$scenario"
  _gen_claude_md "$project_name" "$scenario"
  _gen_agents_md
  _gen_roadmap "$scenario"
  _gen_ci_status
  _gen_changelog
  _gen_signals_readme
  _gen_scripts "$script_src"
  _gen_gitignore

  # Return to parent before mv so we're not standing inside the dir we
  # rename (which would confuse some shells' pwd tracking).
  cd "$parent"
  mv -- "$staging" "$target"
  trap - EXIT

  echo ""
  ok "Expero project initialized"
  echo ""
  echo "Next steps:"
  echo "  cd $project"
  # Suggest the scenario's first active role (the natural entry point
  # for that scenario — architect for new-product, sentinel for
  # security-audit, archaeologist for legacy-analysis, etc.).
  local first_role
  first_role=$(_json_get_array "$target/.expero/scenarios/$scenario.json" active_roles | head -1)
  echo "  bash expero.sh start ${first_role:-architect}"
  echo "  bash expero.sh status"
}

# ─────────────────────────────────────────
# start: launch an agent
# ─────────────────────────────────────────
cmd_start() {
  local role=${1:?"role required"}
  local task_id=${2:-}
  local tool=${3:-claude}

  # Gate task-id to a safe charset. It's embedded in the prompt verbatim,
  # and shell metacharacters — while never *executed* by the agent —
  # confuse humans reading logs and break grep-based roadmap edits.
  if [ -n "$task_id" ] && ! [[ "$task_id" =~ ^[A-Za-z0-9._-]+$ ]]; then
    err "Invalid task-id: '$task_id' (allowed: letters, digits, '.', '_', '-')"
    exit 1
  fi

  # Critic hard-requires a task-id. Check up-front so the user sees the
  # real error instead of a misleading "Starting critic..." line followed
  # by the real error from _build_prompt.
  if [ "$role" = "critic" ] && [ -z "$task_id" ]; then
    err "Critic requires a task-id (second argument to 'start')"
    exit 1
  fi

  local model
  model=$(model_for_role "$role" "$tool")

  # Warn (don't fail) when the role is outside the current scenario's
  # active_roles. Keeps the door open for override ("I know what I'm
  # doing — let me call Architect in a security-audit") while surfacing
  # the scenario-boundary mismatch. No check when not inside a project.
  local current_scen
  current_scen=$(_current_scenario)
  if [ -n "$current_scen" ]; then
    local in_scenario=0 r
    while IFS= read -r r; do
      [ "$r" = "$role" ] && { in_scenario=1; break; }
    done < <(_active_roles_for_scenario "$current_scen")
    if [ "$in_scenario" -eq 0 ]; then
      warn "Role '$role' is not in scenario '$current_scen' active_roles — proceeding anyway"
    fi
  fi

  info "Starting $role (model: $model, tool: $tool)"

  local prompt
  prompt=$(_build_prompt "$role" "$task_id")

  case "$tool" in
    claude) claude --model "$model" "$prompt" ;;
    codex)  codex --approval-mode auto-edit --model "$model" "$prompt" ;;
    gemini) gemini --model "$model" --yolo --prompt "$prompt" ;;
    *)      err "Unknown tool: $tool (supported: claude, codex, gemini)"; exit 1 ;;
  esac
}

# ─────────────────────────────────────────
# status: show project state
# ─────────────────────────────────────────
cmd_status() {
  info "Expero Project Status"
  echo ""

  if [ ! -f ".expero/config.yaml" ]; then
    err "Not an Expero project (missing .expero/config.yaml)"
    exit 1
  fi

  # awk alone (no grep | awk pipeline) is pipefail-safe: no upstream to fail.
  local scenario
  scenario=$(awk '/^scenario:/{print $2; exit}' .expero/config.yaml)
  echo "  Scenario: ${scenario:-unknown}"
  echo ""

  echo "Documents:"
  _count_files "ADR" ".expero/docs/adr/*.md"
  _count_files "Specs" ".expero/docs/specs/*.md" "-test-plan"
  _count_files "Test Plans" ".expero/docs/specs/*-test-plan.md"
  _count_files "Reviews" ".expero/docs/review/*.md"
  [ -d ".expero/docs/security" ] && _count_files "Security Reports" ".expero/docs/security/*.md"
  [ -d ".expero/docs/public" ] && _count_files "Public Docs" ".expero/docs/public/*.md"
  [ -d ".expero/docs/legacy" ] && _count_files "Legacy Docs" ".expero/docs/legacy/*.md"
  [ -d ".expero/docs/reverse-adr" ] && _count_files "Reverse ADRs" ".expero/docs/reverse-adr/*.md"
  echo ""

  if [ -f ".expero/docs/roadmap.md" ]; then
    echo "Task Status:"
    local todo inprog done_ blocked
    # Regex with pipe-boundary anchors: ensures "| todo |" matches the
    # Status *column* of a roadmap row, not a task title that happens to
    # contain the word "todo".
    todo=$(_count_matches_re   "\|[[:space:]]+todo[[:space:]]+\|"         .expero/docs/roadmap.md)
    inprog=$(_count_matches_re "\|[[:space:]]+in-progress[[:space:]]+\|"  .expero/docs/roadmap.md)
    done_=$(_count_matches_re  "\|[[:space:]]+completed[[:space:]]+\|"    .expero/docs/roadmap.md)
    blocked=$(_count_matches_re "\|[[:space:]]+blocked[[:space:]]+\|"     .expero/docs/roadmap.md)
    printf "  %-12s %s\n" "todo:" "$todo"
    printf "  %-12s %s\n" "in-progress:" "$inprog"
    printf "  %-12s %s\n" "completed:" "$done_"
    printf "  %-12s %s\n" "blocked:" "$blocked"
    echo ""
  fi

  echo "Stop Signals (roadmap.md text markers):"
  local arch_review spec_clar sec_review
  arch_review=$(_count_matches "NEEDS_ARCH_REVIEW"        .expero/docs/roadmap.md)
  spec_clar=$(_count_matches  "NEEDS_SPEC_CLARIFICATION"  .expero/docs/roadmap.md)
  sec_review=$(_count_matches "NEEDS_SECURITY_REVIEW"     .expero/docs/roadmap.md)
  printf "  %-28s %s\n" "NEEDS_ARCH_REVIEW:"        "$arch_review"
  printf "  %-28s %s\n" "NEEDS_SPEC_CLARIFICATION:" "$spec_clar"
  printf "  %-28s %s\n" "NEEDS_SECURITY_REVIEW:"    "$sec_review"

  # Structured signals: .expero/signals/*.json, parsed without jq.
  # Format documented in .expero/signals/README.md.
  local unresolved_struct=0 resolved_struct=0
  local dup_pairs=0
  if [ -d ".expero/signals" ]; then
    local s_unresolved_arch=0 s_unresolved_spec=0 s_unresolved_sec=0 s_unresolved_blocked=0 s_unresolved_other=0
    local sig
    for sig in .expero/signals/*.json; do
      [ -e "$sig" ] || continue
      local sid stype sresolved
      sid=$(_json_get_string "$sig" id)
      stype=$(_json_get_string "$sig" type)
      sresolved=$(_json_get_bool "$sig" resolved)
      if [ "$sresolved" = "true" ]; then
        resolved_struct=$((resolved_struct + 1))
        continue
      fi
      unresolved_struct=$((unresolved_struct + 1))
      case "$stype" in
        NEEDS_ARCH_REVIEW)        s_unresolved_arch=$((s_unresolved_arch + 1)) ;;
        NEEDS_SPEC_CLARIFICATION) s_unresolved_spec=$((s_unresolved_spec + 1)) ;;
        NEEDS_SECURITY_REVIEW)    s_unresolved_sec=$((s_unresolved_sec + 1)) ;;
        BLOCKED_BY_*)             s_unresolved_blocked=$((s_unresolved_blocked + 1)) ;;
        *)                        s_unresolved_other=$((s_unresolved_other + 1)) ;;
      esac
      # Overlap detection: does roadmap.md contain a line that has BOTH
      # this signal's task-id AND this signal's type? Used for the
      # dedup hint below. Only counted for unresolved signals.
      if [ -n "$sid" ] && [ -n "$stype" ] && [ -f .expero/docs/roadmap.md ]; then
        if grep -qE -- "\|[[:space:]]*${sid}[[:space:]]*\|.*${stype}" .expero/docs/roadmap.md 2>/dev/null; then
          dup_pairs=$((dup_pairs + 1))
        fi
      fi
    done
    if [ "$unresolved_struct" -gt 0 ] || [ "$resolved_struct" -gt 0 ]; then
      echo ""
      echo "Stop Signals (.expero/signals/*.json):"
      printf "  %-28s %s\n" "NEEDS_ARCH_REVIEW:"        "$s_unresolved_arch"
      printf "  %-28s %s\n" "NEEDS_SPEC_CLARIFICATION:" "$s_unresolved_spec"
      printf "  %-28s %s\n" "NEEDS_SECURITY_REVIEW:"    "$s_unresolved_sec"
      printf "  %-28s %s\n" "BLOCKED_BY_*:"             "$s_unresolved_blocked"
      [ "$s_unresolved_other" -gt 0 ] && printf "  %-28s %s\n" "other:" "$s_unresolved_other"
      printf "  %-28s %s\n" "(resolved, informational):" "$resolved_struct"
    fi
  else
    # Signals directory absent (pre-v1.2 project). Emit a hint so users
    # know the feature exists.
    local total_text=$((arch_review + spec_clar + sec_review))
    if [ "$total_text" -eq 0 ]; then
      echo "  (no structured signals; see .expero/signals/README.md)"
    fi
  fi

  # If any unresolved signal exists as both a text marker and a JSON
  # file for the same (task-id, type), call that out. Not a bug, just
  # something users should know so they don't think they have twice as
  # many outstanding issues as they actually do.
  if [ "$dup_pairs" -gt 0 ]; then
    echo ""
    printf "  %s\n" "note: $dup_pairs signal(s) recorded in both forms (same task-id + type)"
  fi

  if [ "$arch_review" -gt 0 ] || [ "$spec_clar" -gt 0 ] || [ "$sec_review" -gt 0 ] || [ "$unresolved_struct" -gt 0 ]; then
    echo ""
    warn "Pending stop signals require attention"
  fi
}

# Minimal JSON field extractor. Handles simple "key": "value" / "key": bool
# pairs — enough for signal files which have flat string/boolean fields.
# Returns empty string if key not found. No nested-object support.
_json_get_string() {
  local file=$1
  local key=$2
  [ -f "$file" ] || { echo ""; return; }
  # sed -n '/pat/p' followed by sed to strip wrapping. Using awk for a
  # single-pass implementation that's bash-3.2 compatible.
  awk -v k="$key" '
    {
      pat = "\"" k "\"[[:space:]]*:[[:space:]]*\"([^\"]*)\""
      if (match($0, pat)) {
        s = substr($0, RSTART, RLENGTH)
        sub(/^"[^"]*"[[:space:]]*:[[:space:]]*"/, "", s)
        sub(/"$/, "", s)
        print s
        exit
      }
    }
  ' "$file"
}

_json_get_bool() {
  local file=$1
  local key=$2
  [ -f "$file" ] || { echo ""; return; }
  awk -v k="$key" '
    {
      pat = "\"" k "\"[[:space:]]*:[[:space:]]*(true|false)"
      if (match($0, pat)) {
        s = substr($0, RSTART, RLENGTH)
        if (s ~ /true/)  { print "true";  exit }
        if (s ~ /false/) { print "false"; exit }
      }
    }
  ' "$file"
}

# Extract a JSON array of strings, one item per output line. Supports
# two formats:
#   1) Single-line:  "key": ["a", "b", "c"]
#      Array items must not themselves contain [ or ] (which would fool
#      the bracket matcher).
#   2) Multi-line:   "key": [
#                      "item-1",
#                      "item[with]brackets",
#                      ...
#                    ]
#      Robust against items containing [ or ] because we parse line by
#      line and each line carries at most one `"..."` string.
# Empty arrays return empty output. Missing keys return empty output.
# No dependency on jq or other JSON parsers.
# Extract a YAML block-sequence list under a top-level key. Example:
#   ci_commands:
#     - "npm test"
#     - npm run lint
# _yaml_get_list config.yaml ci_commands  →  prints each item on its own
# line, with surrounding quotes stripped. Whitespace is significant
# (items must be indented; unindented line ends the block). No support
# for nested keys or flow-style `[a, b]` — this is a "poor-man's YAML"
# reader scoped to the shapes we actually generate.
_yaml_get_list() {
  local file=$1
  local key=$2
  [ -f "$file" ] || return
  awk -v k="$key" '
    BEGIN { active = 0 }
    # Block terminator: first line without leading whitespace after we
    # started collecting. Empty lines stay inside the block.
    active && /^[^[:space:]]/ { exit }
    active && /^[[:space:]]+-[[:space:]]+/ {
      item = $0
      sub(/^[[:space:]]+-[[:space:]]+/, "", item)
      # Strip wrapping quotes and trailing spaces.
      gsub(/[[:space:]]+$/, "", item)
      sub(/^"/, "", item); sub(/"$/, "", item)
      sub(/^\x27/, "", item); sub(/\x27$/, "", item)
      if (length(item) > 0) print item
      next
    }
    { if ($0 == k":") active = 1 }
  ' "$file"
}

_json_get_array() {
  local file=$1
  local key=$2
  [ -f "$file" ] || return
  awk -v k="$key" '
    BEGIN { active = 0 }
    # End marker: a line whose only non-whitespace is ] (optionally , at end)
    active && /^[[:space:]]*\][,]?[[:space:]]*$/ { exit }
    # Inside the array: emit the first quoted string on the line, if any
    active {
      if (match($0, /"[^"]*"/)) {
        item = substr($0, RSTART + 1, RLENGTH - 2)
        if (length(item) > 0) print item
      }
      next
    }
    # Look for "<key>": [ — may be end-of-line (multi-line array) or
    # may have content + closing ] on the same line (single-line array).
    {
      pat = "\"" k "\"[[:space:]]*:[[:space:]]*\\["
      if (match($0, pat)) {
        tail = substr($0, RSTART + RLENGTH)
        # Single-line: strip closing ] and trailing chars, then emit
        # each "..." item from the remainder. Works for items without
        # embedded [ or ] (scenarios/*.json is hand-formatted this way).
        if (match(tail, /\]/)) {
          tail = substr(tail, 1, RSTART - 1)
          while (match(tail, /"[^"]*"/)) {
            item = substr(tail, RSTART + 1, RLENGTH - 2)
            if (length(item) > 0) print item
            tail = substr(tail, RSTART + RLENGTH)
          }
          exit
        }
        # Multi-line: start capturing subsequent lines
        active = 1
      }
    }
  ' "$file"
}

# ─────────────────────────────────────────
# restart: milestone boundary operation
# ─────────────────────────────────────────
cmd_restart() {
  info "Milestone boundary checklist"
  echo ""

  local required=("CLAUDE.md" ".expero/docs/roadmap.md" ".expero/docs/ci-status.md")
  local all_ok=true

  echo "Required files:"
  for f in "${required[@]}"; do
    if [ -f "$f" ]; then
      echo "  ✓ $f"
    else
      echo "  ✗ $f (missing)"
      all_ok=false
    fi
  done

  if [ "$all_ok" != true ]; then
    echo ""
    err "Fix missing documents before restarting agents"
    exit 1
  fi

  # Warn on unresolved stop signals. A milestone boundary with pending
  # NEEDS_ARCH_REVIEW / NEEDS_SPEC_CLARIFICATION / NEEDS_SECURITY_REVIEW
  # usually means the signals should be addressed before moving on — but
  # the Conductor gets the final call, so this is a warning, not a block.
  local text_signals struct_signals total_pending
  text_signals=$(_count_matches "NEEDS_ARCH_REVIEW"       .expero/docs/roadmap.md)
  text_signals=$((text_signals + $(_count_matches "NEEDS_SPEC_CLARIFICATION" .expero/docs/roadmap.md)))
  text_signals=$((text_signals + $(_count_matches "NEEDS_SECURITY_REVIEW"    .expero/docs/roadmap.md)))
  struct_signals=$(_count_unresolved_struct_signals)
  total_pending=$((text_signals + struct_signals))

  echo ""
  if [ "$total_pending" -gt 0 ]; then
    warn "Pending stop signals at milestone boundary:"
    [ "$text_signals"   -gt 0 ] && echo "    roadmap.md text markers:    $text_signals"
    [ "$struct_signals" -gt 0 ] && echo "    .expero/signals/*.json:     $struct_signals"
    echo "    Consider resolving before restarting. Run 'bash expero.sh status' for details."
    echo ""
  fi

  ok "Document check passed"
  echo ""
  echo "Next steps:"
  echo "  1. Close all agent terminals"
  echo "  2. Start new terminals for next milestone:"

  # Suggest start commands for the scenario's active_roles. Falls back
  # to a generic hint when we can't read the scenario (e.g. corrupted
  # config.yaml). Critic and task-bearing roles get a <task-id>
  # placeholder; others get the bare role name.
  local current_scen r
  current_scen=$(_current_scenario)
  if [ -n "$current_scen" ]; then
    while IFS= read -r r; do
      [ -z "$r" ] && continue
      case "$r" in
        critic|builder|verifier) echo "     bash expero.sh start $r <task-id>" ;;
        *)                       echo "     bash expero.sh start $r" ;;
      esac
    done < <(_active_roles_for_scenario "$current_scen")
  else
    echo "     bash expero.sh start <role> [task-id]"
  fi
}

# Count unresolved structured signals (.expero/signals/*.json with
# "resolved": false). Used by cmd_restart and cmd_status. Emits a single
# integer on stdout.
_count_unresolved_struct_signals() {
  local n=0 sig
  [ -d ".expero/signals" ] || { echo 0; return; }
  for sig in .expero/signals/*.json; do
    [ -e "$sig" ] || continue
    local resolved
    resolved=$(_json_get_bool "$sig" resolved)
    [ "$resolved" = "true" ] || n=$((n + 1))
  done
  echo "$n"
}

# ─────────────────────────────────────────
# validate: check artifacts against SPEC §5.2 schemas
# ─────────────────────────────────────────
cmd_validate() {
  local target=${1:-}

  if [ ! -f ".expero/config.yaml" ]; then
    err "Not an Expero project (missing .expero/config.yaml)"
    exit 1
  fi

  info "Validating artifacts (SPEC §5.2)"
  echo ""

  local files=()
  if [ -n "$target" ]; then
    if [ ! -f "$target" ]; then
      err "File not found: $target"
      exit 1
    fi
    files+=("$target")
  else
    # No nullglob: if a directory has no matches, $p stays literal and is
    # filtered by [ -e ]. Keeps bash-3.2 macOS compatibility.
    local p
    for p in \
      .expero/docs/adr/*.md \
      .expero/docs/reverse-adr/*.md \
      .expero/docs/specs/*.md \
      .expero/docs/review/*.md \
      .expero/docs/security/*.md; do
      [ -e "$p" ] || continue
      files+=("$p")
    done
  fi

  if [ "${#files[@]}" -eq 0 ]; then
    warn "No artifacts found to validate"
    return 0
  fi

  local passed=0 failed=0 skipped=0
  local f type
  for f in "${files[@]}"; do
    type=$(_classify_artifact "$f")
    if [ -z "$type" ]; then
      echo "  - $f (skipped: no schema for this path)"
      skipped=$((skipped + 1))
      continue
    fi
    if _validate_artifact "$f" "$type"; then
      passed=$((passed + 1))
    else
      failed=$((failed + 1))
    fi
  done

  echo ""
  printf "  %-10s %d\n" "Passed:"  "$passed"
  printf "  %-10s %d\n" "Failed:"  "$failed"
  printf "  %-10s %d\n" "Skipped:" "$skipped"

  if [ "$failed" -gt 0 ]; then
    echo ""
    err "Artifact validation failed ($failed invalid)"
    exit 1
  fi
  echo ""
  if [ "$skipped" -gt 0 ]; then
    ok "All classified artifacts valid ($skipped skipped — no schema for that path)"
  else
    ok "All artifacts valid"
  fi
}

# ─────────────────────────────────────────
# gate: SPEC §4.2 Quality Gate executor
# ─────────────────────────────────────────
# Gates are structural checkpoints that must pass before a milestone
# can close. Each is a cheap, deterministic, exit-code-first check that
# fits into CI pipelines (`bash expero.sh gate X && deploy`).
#
# Implemented in v1.x:
#   - artifacts_valid  (delegates to `validate`)
#   - adr_compliance   (reads Critic's review for this task)
#   - security_clean   (no CRITICAL in security summary)
#   - all              (meta-gate: runs all applicable)
#
# Deferred to v2.0.2 (see ROADMAP):
#   - ci_passes        (needs config.yaml `ci_commands` schema)
#   - test_coverage    (needs a coverage tool adapter)
cmd_gate() {
  local gate_name=${1:?"gate name required"}
  local task_id=${2:-}

  if [ ! -f ".expero/config.yaml" ]; then
    err "Not an Expero project (missing .expero/config.yaml)"
    exit 1
  fi

  case "$gate_name" in
    artifacts_valid)
      _gate_run "artifacts_valid" "" _gate_artifacts_valid
      ;;
    adr_compliance)
      if [ -z "$task_id" ]; then
        err "Gate 'adr_compliance' requires a task-id (e.g. 'gate adr_compliance M0-001')"
        exit 1
      fi
      _gate_run "adr_compliance" "$task_id" _gate_adr_compliance "$task_id"
      ;;
    security_clean)
      _gate_run "security_clean" "" _gate_security_clean
      ;;
    ci_passes)
      _gate_run "ci_passes" "" _gate_ci_passes
      ;;
    all)
      _gate_all "$task_id"
      ;;
    *)
      err "Unknown gate: '$gate_name' (available: artifacts_valid, adr_compliance, security_clean, ci_passes, all)"
      exit 1
      ;;
  esac
}

# Run one gate function and render a pass/fail banner. The gate function
# should print any details on its own (1-3 short lines) and return
# 0 on pass / non-zero on fail.
_gate_run() {
  local name=$1
  local task=$2
  local fn=$3
  shift 3
  local label="$name"
  [ -n "$task" ] && label="$name (task: $task)"
  echo "Gate: $label"
  local rc=0
  "$fn" "$@" || rc=$?
  if [ "$rc" -eq 0 ]; then
    printf "  ${GREEN}✓ PASS${NC}\n"
    return 0
  fi
  printf "  ${RED}✗ FAIL${NC}\n"
  return 1
}

# Meta-gate. Runs every applicable built-in gate, tallies pass/fail, and
# exits non-zero on any failure. `adr_compliance` is only applicable
# when a task-id is supplied.
_gate_all() {
  local task_id=$1
  local passed=0 failed=0
  info "Running all applicable gates${task_id:+ for task: $task_id}"
  echo ""

  if _gate_run "artifacts_valid" "" _gate_artifacts_valid; then
    passed=$((passed + 1))
  else
    failed=$((failed + 1))
  fi
  echo ""

  if [ -n "$task_id" ]; then
    if _gate_run "adr_compliance" "$task_id" _gate_adr_compliance "$task_id"; then
      passed=$((passed + 1))
    else
      failed=$((failed + 1))
    fi
    echo ""
  fi

  if _gate_run "security_clean" "" _gate_security_clean; then
    passed=$((passed + 1))
  else
    failed=$((failed + 1))
  fi
  echo ""

  if _gate_run "ci_passes" "" _gate_ci_passes; then
    passed=$((passed + 1))
  else
    failed=$((failed + 1))
  fi
  echo ""

  local total=$((passed + failed))
  if [ "$failed" -eq 0 ]; then
    ok "All $total gates passed"
    return 0
  fi
  err "$failed of $total gates failed"
  exit 1
}

# ─────────── individual gate implementations ───────────

# Pass when every artifact under .expero/docs/**/*.md that has a schema
# (see _classify_artifact) conforms to its required_patterns. Wraps
# cmd_validate in a subshell so its `exit 1` stays local and doesn't
# short-circuit the gate harness.
_gate_artifacts_valid() {
  local output rc=0
  output=$(cmd_validate 2>&1) || rc=$?
  if [ "$rc" -eq 0 ]; then
    # Extract the summary line for visibility.
    echo "$output" | grep -E "^(Passed|Failed|Skipped):|All (classified )?artifacts" | sed 's/^/  /'
    return 0
  fi
  # Show failing files only; suppress the per-check verbose log to keep
  # the gate line readable.
  echo "$output" | grep -E "(✗|missing:)" | sed 's/^/  /' | head -20
  return 1
}

# Pass when the Critic's review for this task exists and its Verdict
# is APPROVED. The review template (see roles/critic.md) puts the
# verdict on the line immediately after "## Verdict".
_gate_adr_compliance() {
  local task_id=$1
  local review=".expero/docs/review/$task_id.md"
  if [ ! -f "$review" ]; then
    echo "  Review file not found: $review"
    echo "  (Critic hasn't reviewed this task yet)"
    return 1
  fi
  local verdict
  verdict=$(awk '/^## Verdict/{getline; print; exit}' "$review" | tr -d '[:space:]')
  echo "  Review: $review"
  if [ "$verdict" = "APPROVED" ]; then
    echo "  Verdict: APPROVED"
    return 0
  fi
  echo "  Verdict: ${verdict:-<missing>} (required: APPROVED)"
  return 1
}

# Pass when every command under config.yaml's `ci_commands:` block
# exits 0. Commands run sequentially in the project root; the first
# failing command is reported with its last 10 lines of output and the
# gate stops (no need to also see downstream failures cascading). Absent
# or empty `ci_commands:` = pass-by-default — "no CI configured" is not
# the gate's problem to diagnose.
_gate_ci_passes() {
  local config=".expero/config.yaml"
  if [ ! -f "$config" ]; then
    echo "  No config.yaml — gate passes by default"
    return 0
  fi
  local commands=()
  local line
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    commands+=("$line")
  done < <(_yaml_get_list "$config" ci_commands)

  if [ "${#commands[@]}" -eq 0 ]; then
    echo "  No ci_commands configured in $config — gate passes by default"
    echo "  (add 'ci_commands:' block with shell commands to enable)"
    return 0
  fi

  local cmd rc=0 out
  for cmd in "${commands[@]}"; do
    echo "  \$ $cmd"
    # Capture output so we can surface only the last few lines on fail.
    # Run in a subshell so `cd` or env changes don't leak between
    # commands and so `set -e` inside the script doesn't kill us.
    if out=$(bash -c "$cmd" 2>&1); then
      echo "    ✓ exit 0"
    else
      rc=$?
      echo "    ✗ exit $rc"
      echo "    --- tail of output ---"
      echo "$out" | tail -10 | sed 's/^/    /'
      return 1
    fi
  done
  return 0
}

# Pass when the security summary exists and lists zero CRITICAL
# findings. Passes-by-default when the summary is absent — that means
# no sentinel audit has been run yet, which is a planner signal, not a
# security failure. A milestone with pending security work should use
# the ROADMAP's roadmap.md markers, not this gate.
_gate_security_clean() {
  local summary=".expero/docs/security/summary.md"
  if [ ! -f "$summary" ]; then
    echo "  No security summary present — gate passes by default"
    echo "  (run Sentinel to populate .expero/docs/security/summary.md)"
    return 0
  fi
  # Scan each CRITICAL row and sum the numeric Count column. SPEC §5.2
  # summary template is `| Severity | Count |` so the first numeric
  # field after "CRITICAL" is the count. Rows without a parseable count
  # (e.g. "| CRITICAL | see table below |") are treated as 0 — we
  # trust the Sentinel's summary as authoritative, not the wording.
  #
  # Pre-v1.1 bug: the earlier version counted *rows matching CRITICAL*,
  # which incorrectly failed "| CRITICAL | 0 |" (a correctly-filled
  # clean summary). Dogfood finding D/E.
  local total
  total=$(awk -F'|' '
    /\|[[:space:]]*CRITICAL[[:space:]]*\|/ {
      found=0
      for (i=1; i<=NF; i++) {
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", $i)
        if (found && $i ~ /^[0-9]+$/) { sum += $i; break }
        if ($i == "CRITICAL") found=1
      }
    }
    END { print sum + 0 }
  ' "$summary")

  if [ "$total" -eq 0 ]; then
    echo "  No CRITICAL findings in $summary"
    return 0
  fi
  echo "  $total CRITICAL finding(s) in $summary"
  return 1
}

# Classify an artifact path to a schema key. Empty = no schema registered.
_classify_artifact() {
  local f=$1
  case "$f" in
    */adr/ADR-*.md)             echo adr ;;
    */reverse-adr/RADR-*.md)    echo radr ;;
    */specs/*-test-plan.md)     echo test-plan ;;
    */specs/*.md)               echo spec ;;
    */review/*.md)              echo review ;;
    */security/summary.md)      echo security-summary ;;
    */security/*.md)            echo security ;;
    *)                          echo "" ;;
  esac
}

# Check an artifact file against a set of required ERE patterns loaded
# from schemas/<type>.json. Returns 0 on pass, 1 on fail; prints a ✓/✗
# line and per-error details.
#
# Schema JSON format (SPEC §5.2):
#   { "name": "...", "description": "...",
#     "required_patterns": ["pat1", "pat2", ...] }
#
# Patterns use ERE. For portability across JSON parsers (ours, jq,
# future YAML-ified variants), write literal `|` as `[|]` and literal
# `.` as `[.]` rather than `\|` / `\.`.
_validate_artifact() {
  local f=$1
  local type=$2
  local root schema
  root=$(_resource_root)
  schema="$root/schemas/$type.json"

  if [ ! -f "$schema" ]; then
    printf "  ${RED}✗${NC} %s (%s)\n" "$f" "$type"
    printf "      missing schema file: %s\n" "$schema"
    return 1
  fi

  local missing=() p
  while IFS= read -r p; do
    [ -z "$p" ] && continue
    if ! grep -qE -- "$p" "$f" 2>/dev/null; then
      missing+=("$p")
    fi
  done < <(_json_get_array "$schema" required_patterns)

  if [ "${#missing[@]}" -eq 0 ]; then
    printf "  ${GREEN}✓${NC} %s (%s)\n" "$f" "$type"
    return 0
  else
    printf "  ${RED}✗${NC} %s (%s)\n" "$f" "$type"
    local m
    for m in "${missing[@]}"; do
      printf "      missing: %s\n" "$m"
    done
    return 1
  fi
}

# ─────────────────────────────────────────
# Helper functions
# ─────────────────────────────────────────

# Count files matching a shell glob, optionally excluding those whose name
# contains a substring. Uses shell globbing (safe with spaces / newlines),
# never parses `ls` output. Returns 0 if the glob does not match anything.
_count_files() {
  local label=$1
  local pattern=$2
  local exclude=${3:-}
  local count=0
  local f
  # shellcheck disable=SC2086
  for f in $pattern; do
    [ -e "$f" ] || continue
    [ -n "$exclude" ] && [[ "$f" == *"$exclude"* ]] && continue
    count=$((count + 1))
  done
  printf "  %-20s %s\n" "$label:" "$count"
}

# Count lines matching a fixed string in a file. Returns 0 if file is
# missing or pattern not found. Always emits a single integer on stdout.
_count_matches() {
  local pattern=$1
  local file=$2
  [ -f "$file" ] || { echo 0; return; }
  local n
  n=$(grep -cF -- "$pattern" "$file" 2>/dev/null) || n=0
  echo "${n:-0}"
}

# Same as _count_matches but uses extended regex. Use for patterns that
# need boundary anchors (e.g. "\| todo \|" to avoid matching "| todoable |").
_count_matches_re() {
  local pattern=$1
  local file=$2
  [ -f "$file" ] || { echo 0; return; }
  local n
  n=$(grep -cE -- "$pattern" "$file" 2>/dev/null) || n=0
  echo "${n:-0}"
}

# Locate the directory that holds role/scenario/schema resources. Prefer
# the project-local .expero/ (created by init, so self-contained when
# expero.sh is copied into a project), fall back to the source repo layout
# (directory that contains this script). Fails hard if neither is present.
_resource_root() {
  # 1. Current working directory is a project (has .expero/roles/).
  #    This branch serves `start`, `status`, `validate` from a project
  #    and also `init` when it reaches resource lookup before `cd` to
  #    staging.
  if [ -d ".expero/roles" ]; then
    echo ".expero"
    return
  fi
  # After cd into init staging, cwd no longer matches — fall back to
  # locations relative to the script itself.
  local script_dir=""
  if [ -n "${EXPERO_SCRIPT_PATH:-}" ]; then
    script_dir=$(dirname -- "$EXPERO_SCRIPT_PATH")
  fi
  # 2. Script lives at the root of a generated project (copied expero.sh
  #    next to .expero/). Used by sub-inits launched from inside a
  #    detached project that lost the source repo.
  if [ -n "$script_dir" ] && [ -d "$script_dir/.expero/roles" ]; then
    echo "$script_dir/.expero"
    return
  fi
  # 3. Script lives in the source repo (roles/ and scenarios/ at the
  #    top level, no .expero/ sibling).
  if [ -n "$script_dir" ] && [ -d "$script_dir/roles" ]; then
    echo "$script_dir"
    return
  fi
  err "Cannot locate roles/ (tried .expero/roles, ${script_dir:-<unresolved>}/.expero/roles, ${script_dir:-<unresolved>}/roles)"
  exit 1
}

# Uppercase-first of a lowercase string. Portable replacement for bash 4
# `${var^}`, which silently no-ops on macOS bash 3.2 (the previous code
# shipped a broken "你是 builder。" header there).
_title_case() {
  awk '{print toupper(substr($0,1,1)) substr($0,2)}' <<< "$1"
}

# Per-role default task description. Used when the caller does not pass
# a task-id. Critic has no default — it hard-requires a task-id.
_default_task_for_role() {
  case "$1" in
    architect)     echo "检查 .expero/docs/roadmap.md 中所有 NEEDS_ARCH_REVIEW 标记并处理" ;;
    planner)       echo "检查 roadmap.md，更新里程碑状态，识别 blocked 任务" ;;
    builder)       echo "实现 roadmap 中第一个状态为 todo 的任务" ;;
    verifier)      echo "为所有 completed 任务检查测试计划，补充缺失的" ;;
    sentinel)      echo "审计指定模块或全量代码库" ;;
    scribe)        echo "生成所有对外文档" ;;
    archaeologist) echo "分析现有代码库，建立理解基线" ;;
    critic)        echo "" ;;    # no default: task-id required
    *)             echo "" ;;
  esac
}

_build_prompt() {
  local role=$1
  local task_id=${2:-}
  local root
  root=$(_resource_root)

  local role_file="$root/roles/$role.md"
  local base_file="$root/roles/_base.md"
  if [ ! -f "$role_file" ]; then
    err "Unknown role: $role (no such file: $role_file)"
    exit 1
  fi
  if [ ! -f "$base_file" ]; then
    err "Missing base template: $base_file"
    exit 1
  fi

  # Resolve the two template placeholders:
  #   __TASK__     — description of *this* invocation (task-id or default)
  #   __TASK_ID__  — literal task-id (or `<task-id>` when none, so docs
  #                  paths show as `specs/<task-id>.md` instead of `specs/.md`)
  local task_desc
  if [ -n "$task_id" ]; then
    # Critic's template renders "审查 __TASK_ID__", so the desc for
    # critic just IS the task-id; for everyone else, desc = task-id too.
    task_desc=$task_id
  else
    if [ "$role" = "critic" ]; then
      err "Critic requires a task-id (second argument to 'start')"
      exit 1
    fi
    task_desc=$(_default_task_for_role "$role")
  fi
  local task_id_safe=${task_id:-<task-id>}

  local role_title
  role_title=$(_title_case "$role")

  # Render base (shared preamble) then role body. Using sed with | as
  # delimiter; task-id is already validated to [A-Za-z0-9._-] in
  # cmd_start, and our default descriptions contain no | either.
  sed "s|__ROLE_TITLE__|$role_title|g" "$base_file"
  echo ""
  sed -e "s|__TASK__|$task_desc|g" \
      -e "s|__TASK_ID__|$task_id_safe|g" \
      "$role_file"
}

# ─────────────────────────────────────────
# File generators
# ─────────────────────────────────────────

_gen_expero_config() {
  local scenario=$1
  local scenario_json
  scenario_json=$(_scenario_file "$scenario")

  # Build the extensions YAML block from extension_roles[] in the
  # scenario JSON. Indentation is 4 spaces to match the surrounding
  # `roles.extensions:` structure.
  local extensions=""
  local r
  while IFS= read -r r; do
    [ -z "$r" ] && continue
    if [ -z "$extensions" ]; then
      extensions="    - $r"
    else
      extensions="$extensions"$'\n'"    - $r"
    fi
  done < <(_json_get_array "$scenario_json" extension_roles)

  cat > .expero/config.yaml << EOF
version: $EXPERO_VERSION
scenario: $scenario
created: $(date -u +"%Y-%m-%dT%H:%M:%SZ")

roles:
  core:
    - planner
    - architect
    - builder
    - verifier
    - critic
  extensions:
$extensions

model_mapping:
  reasoning:  $MODEL_CLAUDE_REASONING
  execution:  $MODEL_CLAUDE_EXECUTION
  template:   $MODEL_CLAUDE_TEMPLATE

# Commands run by \`bash expero.sh gate ci_passes\`. Each item is a
# shell command executed in the project root; any non-zero exit fails
# the gate. Absent / empty = gate passes by default (no CI configured).
#
# Example:
#   ci_commands:
#     - "npm test"
#     - "npm run lint"
#     - "npm run typecheck"
ci_commands:
EOF
}

# Resolve the scenario JSON file path. Prefers project-local
# .expero/scenarios/ (when running from inside a project that was already
# initialized), falls back to source repo's scenarios/. Errors if missing.
_scenario_file() {
  local name=$1
  local root
  root=$(_resource_root)
  local f="$root/scenarios/$name.json"
  if [ ! -f "$f" ]; then
    err "Unknown scenario: '$name' (no such file: $f)"
    exit 1
  fi
  echo "$f"
}

# List scenario names known to the current install (basename of
# scenarios/*.json minus the .json). Used by help and validation.
_list_scenarios() {
  local root
  root=$(_resource_root) 2>/dev/null || { echo ""; return; }
  local f
  for f in "$root"/scenarios/*.json; do
    [ -e "$f" ] || continue
    local base
    base=$(basename -- "$f" .json)
    echo "$base"
  done
}

# List role names known to the current install (basename of roles/*.md
# minus the .md, excluding the _base shared preamble).
_list_roles() {
  local root
  root=$(_resource_root) 2>/dev/null || { echo ""; return; }
  local f
  for f in "$root"/roles/*.md; do
    [ -e "$f" ] || continue
    local base
    base=$(basename -- "$f" .md)
    [ "$base" = "_base" ] && continue
    echo "$base"
  done
}

# Short English description for each role, shown in `help`. Kept as a
# bash case rather than a JSON field because role descriptions are part
# of the CLI UX contract — they change rarely and centralizing them here
# avoids invented formats (frontmatter, separate description files).
_description_for_role() {
  case "$1" in
    architect)     echo "Architecture decisions, ADRs" ;;
    planner)       echo "Roadmap, task coordination" ;;
    builder)       echo "Code implementation" ;;
    verifier)      echo "Test plans, CI status" ;;
    critic)        echo "Code review" ;;
    sentinel)      echo "Security audit" ;;
    scribe)        echo "Public documentation" ;;
    archaeologist) echo "Legacy code analysis" ;;
    *)             echo "(no description)" ;;
  esac
}

# Read the scenario name of the *current* project, or empty if not in a
# project. Used by help, restart, and start to become project-aware.
_current_scenario() {
  [ -f ".expero/config.yaml" ] || { echo ""; return; }
  awk '/^scenario:/{print $2; exit}' .expero/config.yaml
}

# Read the active_roles[] of a scenario (comma-separated for display
# use, newline-separated for iteration). Two wrappers for clarity.
_active_roles_for_scenario() {
  local scenario=$1
  local root f
  root=$(_resource_root) 2>/dev/null || return
  f="$root/scenarios/$scenario.json"
  [ -f "$f" ] || return
  _json_get_array "$f" active_roles
}

_gen_claude_md() {
  local project=$1
  local scenario=$2
  local scenario_json
  scenario_json=$(_scenario_file "$scenario")

  # Build "- role1, role2, …" from active_roles[] in the scenario JSON.
  # active_roles is the *display-ordered* list for CLAUDE.md, distinct
  # from config.yaml's extension_roles (which omits the universal five).
  local roles_line="-"
  local r first=1
  while IFS= read -r r; do
    [ -z "$r" ] && continue
    if [ "$first" -eq 1 ]; then
      roles_line="- $r"
      first=0
    else
      roles_line="$roles_line, $r"
    fi
  done < <(_json_get_array "$scenario_json" active_roles)

  cat > CLAUDE.md << EOF
# $project

Expero Agents project (scenario: **$scenario**).

## Roles Enabled
$roles_line

## Project Context

<!-- Replace these stubs with real values before starting any role. -->

- **Language / Stack**: e.g. \`TypeScript + Node 20 + Postgres 16\`
- **Primary module layout**: e.g. \`apps/api\`, \`apps/web\`, \`packages/shared\`
- **Deployment target**: e.g. \`Vercel / Fly.io / self-hosted Docker\`
- **External services**: e.g. \`Stripe, Auth0, SendGrid\`

## Architecture Rules

<!-- Summarize the load-bearing ADRs here (max 5-7 bullets). -->
<!-- Full rationale lives in \`.expero/docs/adr/\`. This section is for quick agent recall. -->

- _No ADRs accepted yet. Architect will populate this after M0._

## Build Commands

<!-- Replace stubs with the exact commands agents should run. Used by Verifier and Critic. -->

- Build:    \`<e.g. npm run build>\`
- Test:     \`<e.g. npm test>\`
- Lint:     \`<e.g. npm run lint>\`
- Coverage: \`<e.g. npm run test:coverage>\`
- Deploy:   \`<filled in at M3>\`

## Extension Points

<!-- Document where new modules / APIs / features plug in. Update as architecture evolves. -->

- _TBD after M0 scaffold._

## Key ADRs

See \`.expero/docs/adr/\`. ADRs load in numeric order; Superseded entries stop applying.

## Expero Protocol

All framework state lives in \`.expero/docs/\`. Never rely on conversation context for persistence.
Status values: \`todo\` / \`in-progress\` / \`completed\` / \`blocked\`.

Stop signals — pick one form (both is fine):
- **Text**: in the Notes column of \`.expero/docs/roadmap.md\`: \`NEEDS_ARCH_REVIEW\`, \`NEEDS_SPEC_CLARIFICATION\`, \`NEEDS_SECURITY_REVIEW\`, \`BLOCKED_BY_<task-id>\`
- **Structured**: JSON at \`.expero/signals/<task-id>-<TYPE>.json\` (schema in \`.expero/signals/README.md\`; gets counted separately by \`bash expero.sh status\`).
EOF
}

_gen_agents_md() {
  cat > AGENTS.md << 'EOF'
# Agents Protocol (for non-Claude tools)

This file is the equivalent of CLAUDE.md for tools that do not auto-load
a harness config (Codex, Gemini CLI, Continue, Aider, etc.). Load it
manually at session start.

## Mandatory First Steps
1. Read CLAUDE.md
2. Read .expero/docs/roadmap.md
3. Read relevant .expero/docs/adr/ (if exists)

## Shared State Protocol
All state must be written to .expero/docs/. Do not rely on context for
persistence. Task status values: todo / in-progress / completed / blocked.
Complete tasks by updating roadmap.md task status to "completed".

## Role Quick Reference

Every role has a fixed set of files it may write (Owns), must read on
start (Reads), and must never touch (Never). Violating these boundaries
is a structural error, not a style issue.

| Role          | Owns (write)                              | Reads (start-up)                      | Never                          |
|---------------|-------------------------------------------|---------------------------------------|--------------------------------|
| planner       | vision.md, roadmap.md, specs/*.md         | adr/*                                 | code                           |
| architect     | adr/*, gap-analysis.md                    | roadmap.md                            | code, reviews                  |
| builder       | code; roadmap status field for own task   | adr/*, specs/*, specs/*-test-plan.md  | other roles' docs              |
| verifier      | specs/*-test-plan.md, ci-status.md        | specs/*, code                         | non-test code                  |
| critic        | review/*.md                               | adr/*, specs/*, git diff              | code                           |
| sentinel      | security/*.md                             | code, adr/*                           | code                           |
| scribe        | public/*.md, CHANGELOG.md                 | adr/*, specs/*, code (public API)     | technical decisions            |
| archaeologist | legacy/*.md, reverse-adr/*                | code                                  | code modifications             |

Full ownership matrix: see SPEC.md §5.3.

## Stop Signal Syntax

When a role hits an issue outside its authority, it MUST halt and record
a stop signal. Two forms are supported — pick one, or record both for
belt-and-braces.

### Form A: Text marker in roadmap.md (always supported)

Append the signal keyword to the Notes column (last column) of the row:

    | M0-001 | Auth flow | in-progress | builder | — | NEEDS_ARCH_REVIEW: JWT library undecided |

Valid signals (UPPERCASE with underscores):

- NEEDS_ARCH_REVIEW         — architecture question not covered by any ADR
- NEEDS_SPEC_CLARIFICATION  — spec ambiguity blocks implementation
- NEEDS_SECURITY_REVIEW     — security-relevant change requires Sentinel
- BLOCKED_BY_<task-id>      — cannot proceed until another task completes

### Form B: Structured JSON in .expero/signals/ (preferred for rich context)

Create `.expero/signals/<task-id>-<TYPE>.json`:

    {
      "id":          "M0-001",
      "type":        "NEEDS_ARCH_REVIEW",
      "raised_by":   "builder",
      "raised_at":   "2026-04-17T12:00:00Z",
      "description": "JWT library choice not covered by any ADR",
      "resolved":    false,
      "resolved_by": null,
      "resolved_at": null
    }

Full schema in `.expero/signals/README.md`. Structured signals survive
roadmap edits, carry a full description and timestamp, and are counted
separately in `status`.

### Detection + resolution

    bash expero.sh status                    # groups both forms
    bash expero.sh restart                   # warns at milestone boundary

Resolution:
- Text: replace `NEEDS_ARCH_REVIEW` with `ARCH_RESOLVED` (etc.) in the row.
- JSON: set `"resolved": true` + fill `resolved_by` / `resolved_at`.

The Conductor (human) routes signals to the responsible role:
Architect for NEEDS_ARCH_REVIEW, Planner for NEEDS_SPEC_CLARIFICATION,
Sentinel for NEEDS_SECURITY_REVIEW.
EOF
}

_gen_roadmap() {
  local scenario=$1
  local scenario_json root template_rel template_abs
  scenario_json=$(_scenario_file "$scenario")
  root=$(_resource_root)
  template_rel=$(_json_get_string "$scenario_json" roadmap_template)
  if [ -z "$template_rel" ]; then
    err "Scenario '$scenario' has no roadmap_template field"
    exit 1
  fi
  template_abs="$root/scenarios/$template_rel"
  if [ ! -f "$template_abs" ]; then
    err "Roadmap template not found: $template_abs"
    exit 1
  fi
  cp "$template_abs" .expero/docs/roadmap.md
}

_gen_ci_status() {
  cat > .expero/docs/ci-status.md << 'EOF'
# CI Status

| Task ID | Test Status | Last Run | Notes |
|---------|-------------|----------|-------|

## CI Jobs
| Job | Status | Command |
|-----|--------|---------|
| build | ⬜ | — |
| test  | ⬜ | — |
| lint  | ⬜ | — |
| integration | ⬜ | — |
EOF
}

_gen_scripts() {
  # Copy the bootstrap script AND its sidecar resources (roles/…) into
  # the new project so the generated tree is self-contained: users can
  # run `bash expero.sh start <role>` without the source repo present.
  # Caller must pass the absolute path resolved BEFORE any cd (see cmd_init).
  local script_path=$1
  [ -n "$script_path" ] && [ -f "$script_path" ] || return 0

  if [ "$script_path" != "$(pwd)/expero.sh" ]; then
    cp "$script_path" expero.sh
    chmod +x expero.sh
  fi

  # Copy sidecar resources into .expero/ so the new project is itself a
  # valid "install" — a sub-init launched from inside it can resolve
  # roles/scenarios without the source repo present. Source layout may be
  # either a source checkout (top-level roles/) or another project copy
  # (.expero/roles/), so we try both.
  local src_root resource_src
  src_root=$(dirname -- "$script_path")
  if   [ -d "$src_root/roles" ];          then resource_src="$src_root"
  elif [ -d "$src_root/.expero/roles" ];  then resource_src="$src_root/.expero"
  else return 0
  fi

  mkdir -p .expero/roles
  cp "$resource_src/roles"/*.md .expero/roles/

  if [ -d "$resource_src/scenarios" ]; then
    mkdir -p .expero/scenarios/roadmaps
    cp "$resource_src/scenarios"/*.json .expero/scenarios/
    if [ -d "$resource_src/scenarios/roadmaps" ]; then
      cp "$resource_src/scenarios/roadmaps"/*.md .expero/scenarios/roadmaps/
    fi
  fi

  if [ -d "$resource_src/schemas" ]; then
    mkdir -p .expero/schemas
    cp "$resource_src/schemas"/*.json .expero/schemas/
  fi
}

_gen_signals_readme() {
  # Structured stop signals live in .expero/signals/*.json (see cmd_status).
  # This README documents the schema so Conductor tooling and agents agree
  # on the contract without re-reading expero.sh.
  cat > .expero/signals/README.md << 'EOF'
# Stop Signals

Structured alternative to the text markers in `roadmap.md`. Any role that
hits a boundary issue (`NEEDS_ARCH_REVIEW`, `NEEDS_SPEC_CLARIFICATION`,
`NEEDS_SECURITY_REVIEW`, `BLOCKED_BY_<id>`) may additionally drop a JSON
file here. `bash expero.sh status` scans this directory and groups
unresolved signals by type.

## File naming

`.expero/signals/<task-id>-<type>.json`

Example: `.expero/signals/M0-003-NEEDS_ARCH_REVIEW.json`

## Schema

```json
{
  "id":          "M0-003",
  "type":        "NEEDS_ARCH_REVIEW",
  "raised_by":   "builder",
  "raised_at":   "2026-04-17T12:00:00Z",
  "description": "JWT library choice not covered by any ADR",
  "resolved":    false,
  "resolved_by": null,
  "resolved_at": null
}
```

Resolution: set `resolved: true`, fill `resolved_by` + `resolved_at`.
`status` treats resolved signals as informational; unresolved signals
trigger a warning.

## Backwards compatibility

The roadmap-text markers (`NEEDS_ARCH_REVIEW` literal in the Notes
column) still work. Structured signals are additive, not a replacement.
EOF
}

_gen_changelog() {
  # Scribe owns CHANGELOG.md (see SPEC §5.3). Generate a minimal
  # Keep-a-Changelog-format placeholder so `[ -f CHANGELOG.md ]` is true
  # from day one and Scribe has a concrete starting point.
  cat > CHANGELOG.md << 'EOF'
# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- _Scribe will populate this from completed roadmap tasks at release time._

### Changed
### Deprecated
### Removed
### Fixed
### Security
EOF
}

_gen_gitignore() {
  cat > .gitignore << 'EOF'
# Environment
.env
.env.local
.env.*.local

# IDE
.idea/
.vscode/
*.swp

# OS
.DS_Store

# Language-specific (uncomment as needed)
# target/          # Rust
# node_modules/    # Node.js
# dist/
# .gradle/         # Java/Gradle
# build/
# __pycache__/     # Python
# *.pyc
EOF
}

# ─────────────────────────────────────────
# help
# ─────────────────────────────────────────
cmd_help() {
  echo "Expero Agents v$EXPERO_VERSION"
  echo ""
  echo "Commands:"
  echo "  init <name> <scenario>    Initialize a new project"
  echo "  start <role> [task-id]    Launch an agent"
  echo "  status                    Show project state"
  echo "  validate [path]           Check artifacts against SPEC §5.2 schemas"
  echo "  gate <name> [task-id]     Run a Quality Gate (SPEC §4.2)"
  echo "  restart                   Milestone boundary checklist"
  echo "  help                      Show this help"
  echo ""

  echo "Gates:"
  echo "  artifacts_valid           All artifacts conform to their schema"
  echo "  adr_compliance <task>     Critic review exists and Verdict=APPROVED"
  echo "  security_clean            No CRITICAL findings in security summary"
  echo "  ci_passes                 Every command under ci_commands: exits 0"
  echo "  all [task]                Meta-gate: runs all applicable above"
  echo ""

  # Scenarios — dynamic from scenarios/*.json. Adding a scenario file
  # causes it to appear here automatically (EXTENDING.md promise).
  echo "Scenarios:"
  local s
  while IFS= read -r s; do
    [ -z "$s" ] && continue
    local desc root
    root=$(_resource_root 2>/dev/null) || root=""
    desc=$(_json_get_string "$root/scenarios/$s.json" description)
    printf "  %-20s %s\n" "$s" "${desc:-(no description)}"
  done < <(_list_scenarios)
  echo ""

  # Roles — dynamic from roles/*.md. Tier + description still live in
  # bash functions; role description is part of the CLI UX contract.
  echo "Roles (with default tier):"
  local r
  while IFS= read -r r; do
    [ -z "$r" ] && continue
    local tier desc
    tier=$(tier_for_role "$r" 2>/dev/null) || tier="?"
    desc=$(_description_for_role "$r")
    printf "  %-14s %-38s (%s)\n" "$r" "$desc" "$tier"
  done < <(_list_roles)
  echo ""

  echo "Tools (3rd arg to 'start'):"
  echo "  claude (default)   Anthropic Claude Code"
  echo "  codex              OpenAI Codex / GPT-5.4 series"
  echo "  gemini             Google Gemini CLI / 3.x series"
  echo ""

  # Project-aware block: if we're inside an initialized project, surface
  # the current scenario + its active_roles. Lets users see at a glance
  # which roles `start` will not warn about in this context.
  local current
  current=$(_current_scenario)
  if [ -n "$current" ]; then
    echo "Current project:"
    printf "  %-20s %s\n" "scenario:" "$current"
    local roles_line first=1 r2
    roles_line=""
    while IFS= read -r r2; do
      [ -z "$r2" ] && continue
      if [ "$first" -eq 1 ]; then
        roles_line="$r2"; first=0
      else
        roles_line="$roles_line, $r2"
      fi
    done < <(_active_roles_for_scenario "$current")
    printf "  %-20s %s\n" "active roles:" "${roles_line:-(none declared)}"
    echo ""
  fi

  cat << 'EOF'
Examples:
  bash expero.sh init my-app new-product
  bash expero.sh start architect
  bash expero.sh start builder M0-001
  bash expero.sh start builder M0-001 codex
  bash expero.sh start archaeologist legacy-M0-001 gemini
  bash expero.sh status
  bash expero.sh validate
  bash expero.sh restart

Notes:
  - <task-id> is embedded verbatim into the agent prompt; restrict it to
    [A-Za-z0-9._-]. Shell metacharacters ($, `, |, <, >, &, ;, spaces)
    are not interpreted but may pollute prompt context.
  - 'validate' checks all .expero/docs/**/*.md against SPEC §5.2 schemas;
    exits non-zero if any artifact is malformed.
  - Starting a role outside the current scenario's active_roles is
    allowed but prints a warning.

Documentation: https://github.com/withesse/expero-agents
EOF
}

# ─────────────────────────────────────────
# Dispatch
# ─────────────────────────────────────────
# Skip dispatch when sourced (lets test-expero.sh call functions directly).
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
  case "$COMMAND" in
    init)     shift; cmd_init "$@" ;;
    start)    shift; cmd_start "$@" ;;
    status)   cmd_status ;;
    restart)  cmd_restart ;;
    validate) shift; cmd_validate "${1:-}" ;;
    gate)     shift; cmd_gate "$@" ;;
    help|-h|--help) cmd_help ;;
    *) err "Unknown command: $COMMAND"; echo ""; cmd_help; exit 1 ;;
  esac
fi
