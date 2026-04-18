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
  echo "  bash expero.sh start architect"
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

  local model
  model=$(model_for_role "$role" "$tool")

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
  if [ -d ".expero/signals" ]; then
    local s_unresolved_arch=0 s_unresolved_spec=0 s_unresolved_sec=0 s_unresolved_blocked=0 s_unresolved_other=0
    local sig
    for sig in .expero/signals/*.json; do
      [ -e "$sig" ] || continue
      local stype sresolved
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

  echo ""
  if [ "$all_ok" = true ]; then
    ok "Document check passed"
    echo ""
    echo "Next steps:"
    echo "  1. Close all agent terminals"
    echo "  2. Start new terminals for next milestone:"
    echo "     bash expero.sh start architect"
    echo "     bash expero.sh start planner"
    echo "     bash expero.sh start builder <task-id>"
    echo "     bash expero.sh start verifier <task-id>"
    echo "     bash expero.sh start critic <task-id>"
  else
    err "Fix missing documents before restarting agents"
    exit 1
  fi
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
  ok "All artifacts valid"
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
Stop signals: \`NEEDS_ARCH_REVIEW\`, \`NEEDS_SPEC_CLARIFICATION\`, \`NEEDS_SECURITY_REVIEW\`.
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

When a role hits an issue outside its authority, it MUST halt and write
a stop signal into the Notes column (last column) of its row in
.expero/docs/roadmap.md. Example:

    | M0-001 | Auth flow | in-progress | builder | — | NEEDS_ARCH_REVIEW: JWT library undecided |

Valid signals (must be UPPERCASE with underscores):

- NEEDS_ARCH_REVIEW         — architecture question not covered by any ADR
- NEEDS_SPEC_CLARIFICATION  — spec ambiguity blocks implementation
- NEEDS_SECURITY_REVIEW     — security-relevant change requires Sentinel
- BLOCKED_BY_<task-id>      — cannot proceed until another task completes

The Conductor (human) detects pending signals via:

    bash expero.sh status
    # or manually:
    grep -E 'NEEDS_|BLOCKED_BY_' .expero/docs/roadmap.md

Resolution: the responsible role (Architect for NEEDS_ARCH_REVIEW, etc.)
handles the issue, replaces the signal with the keyword suffix _RESOLVED
(e.g. ARCH_RESOLVED), and the original role resumes.
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
  cat << EOF
Expero Agents v$EXPERO_VERSION

Commands:
  init <name> <scenario>    Initialize a new project
  start <role> [task-id]    Launch an agent
  status                    Show project state
  validate [path]           Check artifacts against SPEC §5.2 schemas
  restart                   Milestone boundary checklist
  help                      Show this help

Scenarios:
  new-product          Build a new product from scratch
  migration            Migrate to new language/framework
  refactor             Refactor existing codebase
  legacy-analysis      Understand legacy code
  security-audit       Systematic security review
  tech-docs            Build documentation system
  multi-service        Multi-service integration
  greenfield-library   New open-source library

Roles (with default tier):
  architect     Architecture decisions, ADRs          (reasoning)
  planner       Roadmap, task coordination            (execution)
  builder       Code implementation                   (execution)
  verifier      Test plans, CI status                 (template)
  critic        Code review                           (execution)
  sentinel      Security audit                        (reasoning)
  scribe        Public documentation                  (execution)
  archaeologist Legacy code analysis                  (reasoning)

Tools (3rd arg to 'start'):
  claude (default)   Anthropic Claude Code
  codex              OpenAI Codex / GPT-5.4 series
  gemini             Google Gemini CLI / 3.x series

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
    [A-Za-z0-9._-]. Shell metacharacters (\$, \`, |, <, >, &, ;, spaces)
    are not interpreted but may pollute prompt context.
  - 'validate' checks all .expero/docs/**/*.md against SPEC §5.2 schemas;
    exits non-zero if any artifact is malformed.

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
    help|-h|--help) cmd_help ;;
    *) err "Unknown command: $COMMAND"; echo ""; cmd_help; exit 1 ;;
  esac
fi
