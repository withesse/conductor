#!/bin/bash
# regen-skills.sh — regenerate .claude-plugin/skills/expero-<role>/SKILL.md
# from roles/<role>.md + roles/_base.md.
#
# Role prompts live in roles/*.md — that's the single source of truth.
# Claude Code Skills are a *rendered view* of those prompts with frontmatter
# the Claude Code runtime needs (name, description). Run this script
# whenever roles/ changes; test-expero.sh verifies skills stay in sync.
#
# Usage:
#   bash scripts/regen-skills.sh            # regenerate into .claude-plugin/
#   bash scripts/regen-skills.sh <out-dir>  # regenerate into <out-dir> (for test)

set -euo pipefail

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT_DIR=${1:-"$REPO_ROOT/.claude-plugin"}
ROLES_DIR="$REPO_ROOT/roles"

if [ ! -d "$ROLES_DIR" ]; then
  echo "roles/ not found at $ROLES_DIR" >&2
  exit 1
fi

# Skill description (English). Claude Code's matcher uses this to decide
# when to load the skill; include the role's trigger conditions and
# keywords. Kept in this script (not in roles/*.md) because these
# descriptions are Claude-Code-specific metadata — if we put them in
# the role prompt, they'd leak into `expero.sh start` output.
_skill_description() {
  case "$1" in
    architect)
      echo "Use when writing Architecture Decision Records (ADRs), making technology choices, evaluating dependencies, or answering 'should we use X or Y' architecture questions inside an Expero Agents project (one with .expero/docs/adr/)." ;;
    planner)
      echo "Use when maintaining a project roadmap, sequencing milestones, defining exit criteria, or coordinating task flow inside an Expero Agents project (one with .expero/docs/roadmap.md)." ;;
    builder)
      echo "Use when implementing code for a specific task in an Expero Agents roadmap, strictly following existing ADRs and specs. Trigger on requests like 'implement M0-001', 'work on task X', or when the user references an Expero task-id." ;;
    verifier)
      echo "Use when writing or updating a test plan for an Expero Agents task, reviewing test coverage, or maintaining ci-status.md. Produces .expero/docs/specs/<task>-test-plan.md." ;;
    critic)
      echo "Use when reviewing code changes against ADRs and specs for an Expero Agents task. Produces .expero/docs/review/<task>.md with APPROVED or CHANGES_REQUESTED verdict. Trigger on 'review task X' or 'check this PR against ADRs'." ;;
    sentinel)
      echo "Use when performing security audit work inside an Expero Agents project: identifying vulnerabilities (auth, injection, crypto, dependencies, rate limits), producing .expero/docs/security/*.md reports with CVSS severity. Trigger on 'security audit', 'find vulnerabilities', 'CVSS'." ;;
    scribe)
      echo "Use when producing public-facing documentation (API reference, quickstart, architecture overview, onboarding, CHANGELOG) for an Expero Agents project. Trigger on 'write docs', 'update README', 'document the API'." ;;
    archaeologist)
      echo "Use when analyzing undocumented legacy code inside an Expero Agents project — producing module maps, known-bugs inventories, tech-debt lists, and reverse ADRs (.expero/docs/reverse-adr/RADR-*.md). Trigger on 'understand this codebase', 'reverse engineer', 'legacy analysis'." ;;
    *)
      echo "Use when acting as the Expero Agents '$1' role." ;;
  esac
}

# Uppercase-first (portable across bash 3.2 and bash 4+). Duplicated
# from expero.sh's _title_case to keep this script self-contained.
_title_case() {
  awk '{print toupper(substr($0,1,1)) substr($0,2)}' <<< "$1"
}

# Per-role default task description (in Chinese, matches role prompt).
# Skills are loaded without a task-id, so we substitute the per-role
# default — the same text expero.sh uses when `start <role>` runs with
# no second argument. Keeps behavior consistent across start and skills.
_default_task() {
  case "$1" in
    architect)     echo "检查 .expero/docs/roadmap.md 中所有 NEEDS_ARCH_REVIEW 标记并处理" ;;
    planner)       echo "检查 roadmap.md，更新里程碑状态，识别 blocked 任务" ;;
    builder)       echo "实现 roadmap 中第一个状态为 todo 的任务" ;;
    verifier)      echo "为所有 completed 任务检查测试计划，补充缺失的" ;;
    critic)        echo "审查用户指定的 task-id（从对话上下文提取）" ;;
    sentinel)      echo "审计指定模块或全量代码库" ;;
    scribe)        echo "生成所有对外文档" ;;
    archaeologist) echo "分析现有代码库，建立理解基线" ;;
    *)             echo "执行该 role 的默认任务" ;;
  esac
}

_render_skill() {
  local role=$1
  local out_file=$2
  local base_file="$ROLES_DIR/_base.md"
  local role_file="$ROLES_DIR/$role.md"

  local role_title desc default_task
  role_title=$(_title_case "$role")
  desc=$(_skill_description "$role")
  default_task=$(_default_task "$role")

  mkdir -p "$(dirname "$out_file")"

  # Emit frontmatter + rendered body. Body = base preamble + role body,
  # with placeholders resolved for the no-task-id invocation pattern
  # (which is how Skills get triggered — no CLI-level task argument).
  {
    printf -- '---\n'
    printf 'name: expero-%s\n' "$role"
    printf 'description: %s\n' "$desc"
    printf -- '---\n\n'
    # Base preamble with role title substituted
    sed "s|__ROLE_TITLE__|$role_title|g" "$base_file"
    printf '\n'
    # Role body with __TASK__ → default task, __TASK_ID__ → <task-id>
    sed -e "s|__TASK__|$default_task|g" \
        -e "s|__TASK_ID__|<task-id>|g" \
        "$role_file"
  } > "$out_file"
}

# List roles = basename(roles/*.md) minus _base.md.
for role_md in "$ROLES_DIR"/*.md; do
  role=$(basename -- "$role_md" .md)
  [ "$role" = "_base" ] && continue
  out="$OUT_DIR/skills/expero-$role/SKILL.md"
  _render_skill "$role" "$out"
  echo "  wrote $out"
done

# plugin.json — static manifest. Rewritten every run so a change here
# propagates without manual edits. Keep fields minimal; Claude Code only
# needs name + description for a plugin index entry.
mkdir -p "$OUT_DIR"
cat > "$OUT_DIR/plugin.json" << 'EOF'
{
  "name": "expero",
  "version": "1.0.0",
  "description": "Expero Agents — 8 role skills for large-project AI collaboration (planner, architect, builder, verifier, critic, sentinel, scribe, archaeologist). Loads when working inside a project with .expero/docs/.",
  "homepage": "https://github.com/withesse/expero-agents"
}
EOF
echo "  wrote $OUT_DIR/plugin.json"
