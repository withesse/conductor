#!/bin/bash
# regen-subagents.sh — regenerate .claude/agents/conductor-<role>.md from
# roles/<role>.md + roles/_base.md + roles/_meta.json.
#
# Subagents are Claude Code's native parallel-dispatch primitive: the
# main agent calls Task(subagent=conductor-builder, prompt="ship M0-001")
# and the subagent runs in its own context window with the role's
# system prompt and tool whitelist.
#
# Source of truth is roles/*.md (same as CLI `start` prompts and
# Skills plugin). Run this script whenever roles/_base.md, roles/*.md,
# or roles/_meta.json changes. Test-conductor.sh verifies
# .claude/agents/*.md stays byte-identical to a fresh regen.
#
# Usage:
#   bash scripts/regen-subagents.sh            # writes into .claude/agents/
#   bash scripts/regen-subagents.sh <out-dir>  # writes into <out-dir>/agents/

set -euo pipefail

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT_DIR=${1:-"$REPO_ROOT/.claude"}
ROLES_DIR="$REPO_ROOT/roles"

if [ ! -d "$ROLES_DIR" ]; then
  echo "roles/ not found at $ROLES_DIR" >&2
  exit 1
fi

# Model mapping (duplicated from conductor.sh MODEL_CLAUDE_* constants so
# this script stays standalone — see _meta.json for tier-per-role).
_model_for_tier() {
  case "$1" in
    reasoning) echo "claude-opus-4-7" ;;
    execution) echo "claude-sonnet-4-6" ;;
    template)  echo "claude-haiku-4-5-20251001" ;;
    *)         echo "inherit" ;;
  esac
}

# Tool whitelist per role. Scribes (architect / planner / scribe /
# verifier) don't need Bash — they only read and write docs. Doers
# (builder / critic / sentinel / archaeologist) do need Bash for:
# builder = running tests + git, critic = git diff, sentinel = running
# scanners, archaeologist = extensive grep / file ops that benefit
# from shell. Keeping the list tight reduces subagent blast radius.
_tools_for_role() {
  case "$1" in
    architect|planner|scribe|verifier)
      echo "Read, Write, Edit, Grep, Glob" ;;
    builder|critic|sentinel|archaeologist)
      echo "Read, Write, Edit, Grep, Glob, Bash" ;;
    *)
      echo "Read, Write, Edit, Grep, Glob" ;;
  esac
}

_meta_get() {
  local role=$1
  local field=$2
  local meta="$REPO_ROOT/roles/_meta.json"
  [ -f "$meta" ] || return
  awk -v k="$role/$field" '
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
  ' "$meta"
}

_title_case() {
  awk '{print toupper(substr($0,1,1)) substr($0,2)}' <<< "$1"
}

# Subagents get a fixed system prompt — can't interpolate per-invocation
# like `conductor.sh start` does. __TASK__ is resolved to "as specified by
# the invoker" text since the Task tool's prompt argument carries the
# actual task info. __TASK_ID__ stays a literal placeholder.
_subagent_task_text() {
  echo "as specified in the message from the main agent"
}

_render_subagent() {
  local role=$1
  local out_file=$2
  local base_file="$ROLES_DIR/_base.md"
  local role_file="$ROLES_DIR/$role.md"

  local role_title desc tier model tools task_text
  role_title=$(_title_case "$role")
  desc=$(_meta_get "$role" long)
  [ -z "$desc" ] && desc="Conductor $role_title role"
  tier=$(_meta_get "$role" tier)
  model=$(_model_for_tier "$tier")
  tools=$(_tools_for_role "$role")
  task_text=$(_subagent_task_text)

  mkdir -p "$(dirname "$out_file")"

  {
    printf -- '---\n'
    printf 'name: conductor-%s\n' "$role"
    printf 'description: %s\n' "$desc"
    printf 'model: %s\n' "$model"
    printf 'tools: %s\n' "$tools"
    printf -- '---\n\n'
    # Preamble + role body. Subagent version of __TASK__ references the
    # invoker's message (since the system prompt is fixed); __TASK_ID__
    # stays a literal placeholder the role prompt references.
    sed "s|__ROLE_TITLE__|$role_title|g" "$base_file"
    printf '\n'
    sed -e "s|__TASK__|$task_text|g" \
        -e "s|__TASK_ID__|<task-id>|g" \
        "$role_file"
  } > "$out_file"
}

for role_md in "$ROLES_DIR"/*.md; do
  role=$(basename -- "$role_md" .md)
  [ "$role" = "_base" ] && continue
  out="$OUT_DIR/agents/conductor-$role.md"
  _render_subagent "$role" "$out"
  echo "  wrote $out"
done

# Non-role subagents live at subagents/conductor-<name>.md and are copied
# as-is (not templated). Use this for meta-agents (like conductor-orchestrator)
# whose prompts don't fit the role template — their frontmatter tools,
# system-prompt structure, and body are hand-curated.
SUBAGENTS_SRC="$REPO_ROOT/subagents"
if [ -d "$SUBAGENTS_SRC" ]; then
  for src in "$SUBAGENTS_SRC"/conductor-*.md; do
    [ -e "$src" ] || continue
    dst="$OUT_DIR/agents/$(basename -- "$src")"
    mkdir -p "$(dirname "$dst")"
    cp "$src" "$dst"
    echo "  wrote $dst (passthrough)"
  done
fi
