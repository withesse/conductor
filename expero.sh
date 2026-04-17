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

set -e

EXPERO_VERSION="1.0.0"
COMMAND=${1:-help}

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

# Map (tool, role) → model ID
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
    *) err "Unknown tool: $tool (supported: claude, codex, gemini)"; exit 1 ;;
  esac
}

# ─────────────────────────────────────────
# init: initialize a new Expero project
# ─────────────────────────────────────────
cmd_init() {
  local project=${1:?"project name required"}
  local scenario=${2:-new-product}

  # Resolve absolute path of this script BEFORE any cd. macOS bash 3.2 has
  # no built-in realpath; use dirname/basename + pwd as portable fallback.
  local script_src=""
  if [ -f "$0" ]; then
    script_src="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/$(basename "$0")"
  fi

  info "Initializing Expero project"
  echo "  Project:  $project"
  echo "  Scenario: $scenario"
  echo ""

  mkdir -p "$project/.expero" "$project/.expero/docs/adr" "$project/.expero/docs/specs" "$project/.expero/docs/review"

  case $scenario in
    refactor)           mkdir -p "$project/.expero/docs/refactor" ;;
    legacy-analysis)    mkdir -p "$project/.expero/docs/legacy" "$project/.expero/docs/reverse-adr" ;;
    security-audit)     mkdir -p "$project/.expero/docs/security" ;;
    tech-docs)          mkdir -p "$project/.expero/docs/public" ;;
    multi-service)      mkdir -p "$project/.expero/docs/contracts" ;;
    greenfield-library) mkdir -p "$project/.expero/docs/public" "$project/.expero/docs/security" ;;
  esac

  cd "$project"

  # Generate framework config
  _gen_expero_config "$scenario"
  _gen_claude_md "$project" "$scenario"
  _gen_agents_md
  _gen_roadmap "$scenario"
  _gen_ci_status
  _gen_scripts "$script_src"
  _gen_gitignore

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
  local task_id=$2
  local tool=${3:-claude}

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

  local scenario
  scenario=$(grep "^scenario:" .expero/config.yaml | awk '{print $2}')
  echo "  Scenario: $scenario"
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
    todo=$(_count_matches "| todo "          .expero/docs/roadmap.md)
    inprog=$(_count_matches "| in-progress " .expero/docs/roadmap.md)
    done_=$(_count_matches "| completed "    .expero/docs/roadmap.md)
    blocked=$(_count_matches "| blocked "    .expero/docs/roadmap.md)
    printf "  %-12s %s\n" "todo:" "$todo"
    printf "  %-12s %s\n" "in-progress:" "$inprog"
    printf "  %-12s %s\n" "completed:" "$done_"
    printf "  %-12s %s\n" "blocked:" "$blocked"
    echo ""
  fi

  echo "Stop Signals:"
  local arch_review spec_clar sec_review
  arch_review=$(_count_matches "NEEDS_ARCH_REVIEW"        .expero/docs/roadmap.md)
  spec_clar=$(_count_matches  "NEEDS_SPEC_CLARIFICATION"  .expero/docs/roadmap.md)
  sec_review=$(_count_matches "NEEDS_SECURITY_REVIEW"     .expero/docs/roadmap.md)
  printf "  %-28s %s\n" "NEEDS_ARCH_REVIEW:"        "$arch_review"
  printf "  %-28s %s\n" "NEEDS_SPEC_CLARIFICATION:" "$spec_clar"
  printf "  %-28s %s\n" "NEEDS_SECURITY_REVIEW:"    "$sec_review"

  if [ "$arch_review" -gt 0 ] || [ "$spec_clar" -gt 0 ] || [ "$sec_review" -gt 0 ]; then
    echo ""
    warn "Pending stop signals require attention"
  fi
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
# Helper functions
# ─────────────────────────────────────────

# Count files matching a shell glob, optionally excluding those whose name
# contains a substring. Uses shell globbing (safe with spaces / newlines),
# never parses `ls` output. Returns 0 if the glob does not match anything.
_count_files() {
  local label=$1
  local pattern=$2
  local exclude=$3
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

_build_prompt() {
  local role=$1
  local task_id=$2

  local base="你是 ${role^}。

Expero Agents 协作框架规则：
1. 所有状态通过 .expero/docs/ 文件系统传递，禁止依赖上下文
2. 严格遵守 .expero/docs/adr/ 中的所有 ADR
3. 遇到边界问题立即停下，在 roadmap.md 备注列写 Stop Signal
4. 任务状态值：todo / in-progress / completed / blocked

启动时必读：
- CLAUDE.md
- .expero/docs/roadmap.md
- .expero/docs/adr/（如存在）"

  case "$role" in
    architect)
      echo "$base

你的职责：架构决策、ADR、差距分析、技术方案审查

本次任务：${task_id:-检查 .expero/docs/roadmap.md 中所有 NEEDS_ARCH_REVIEW 标记并处理}

你的产出：
- .expero/docs/adr/ADR-NNNN-<kebab-case>.md（新增 ADR）
- .expero/docs/gap-analysis.md（差距分析，如适用）

规则：
- ADR 一旦 Accepted 不可修改，只能 Supersede
- 新增依赖时评估：体积影响 / 安全性 / 维护状态
- 完成后更新 roadmap.md 中对应 NEEDS_ARCH_REVIEW 为 ARCH_RESOLVED"
      ;;

    planner)
      echo "$base

你的职责：维护 roadmap、排列优先级、撰写里程碑退出标准、协调任务流转

本次任务：${task_id:-检查 roadmap.md，更新里程碑状态，识别 blocked 任务}

你的产出：
- .expero/docs/vision.md（项目愿景，仅启动时）
- .expero/docs/roadmap.md（持续维护）
- .expero/docs/specs/<feature>.md（spec 格式，技术内容由 Architect 审查）

规则：
- 不做技术决策，技术问题备注写 NEEDS_ARCH_REVIEW
- 每个里程碑必须有可机械验证的退出标准
- 任务状态只能是：todo / in-progress / completed / blocked"
      ;;

    builder)
      echo "$base

你的职责：实现代码、编写测试、修复 CI

本次任务：${task_id:-实现 roadmap 中第一个状态为 todo 的任务}

读取必需：
- .expero/docs/specs/${task_id:-<task-id>}.md（如存在）

规则：
- 严格遵守所有 ADR
- 遇到 ADR 未覆盖的架构问题：roadmap 备注写 NEEDS_ARCH_REVIEW，停下
- 遇到 spec 不明确：roadmap 备注写 NEEDS_SPEC_CLARIFICATION，停下
- 禁止越权修改其他 Role 的文档
- 完成后：1) CI 通过 2) 更新 roadmap.md 任务状态为 completed + 填入 commit hash"
      ;;

    verifier)
      echo "$base

你的职责：测试计划、覆盖率审查、CI 状态维护

本次任务：${task_id:-为所有 completed 任务检查测试计划，补充缺失的}

你的产出：
- .expero/docs/specs/<task-id>-test-plan.md
- .expero/docs/ci-status.md（持续维护）

测试计划必须包含：
- 单元测试用例表格：| ID | 场景 | 预期结果 |
- 集成测试描述（标注是否需要 Docker / 外部服务）
- 分歧覆盖（仅 migration 场景）：Class A 的 reject 测试 / Class B 的 warn 测试

规则：
- 只写测试计划，不写测试代码（代码由 Builder 实现）
- 不做功能决策，不确定时在 ci-status.md 标注 [需 Planner 确认]"
      ;;

    critic)
      echo "$base

你的职责：代码审查、ADR 合规检查

本次任务：审查 ${task_id:?'任务 ID 必填'}

执行：git diff HEAD~1

读取必需：
- .expero/docs/adr/（全部）
- .expero/docs/specs/${task_id}*.md

你的产出：.expero/docs/review/${task_id}.md

审查维度（固定顺序）：
1. ADR 合规：逐条检查每份 ADR 的 Decision 章节
2. Spec 覆盖：数据结构 / 错误类型 / API 端点完整性
3. 分歧处理（migration 场景）：Class A 硬拒绝 / Class B warn 日志
4. 测试完整性：test-plan 用例是否全部有实现
5. 副作用：是否影响 spec 未提及的模块

报告格式：
# Review: ${task_id}

## Verdict
APPROVED | CHANGES_REQUESTED

## ADR Compliance
- [ ] ADR-NNNN: pass/fail + 说明

## Issues
| Severity | Location | Description | Suggestion |
| BLOCK    | file:line | ... | ... |
| WARN     | file:line | ... | ... |

Verdict = CHANGES_REQUESTED 时：
- 把 roadmap.md 中该任务状态改回 in-progress

规则：只审查，不修改代码。"
      ;;

    sentinel)
      echo "$base

你的职责：安全审计、漏洞识别、风险评估

本次任务：${task_id:-审计指定模块或全量代码库}

你的产出：
- .expero/docs/security/<module>.md（模块报告）
- .expero/docs/security/summary.md（汇总，含 CVSS 评分）

审计维度（按顺序）：
1. 认证授权：JWT 验签 / 权限绕过路径 / Token 隔离
2. 注入攻击：SQL 注入 / 命令注入 / 路径遍历
3. 敏感信息：硬编码密钥 / 日志泄漏 / 响应泄漏内部信息
4. 加密：弱哈希算法 / 不安全随机数
5. 依赖安全：已知 CVE
6. 速率限制：登录暴力破解 / API 滥用防护

严重性（CVSS）：
CRITICAL  9.0-10.0  立即修复，阻塞发布
HIGH      7.0-8.9   当前里程碑
MEDIUM    4.0-6.9   下个里程碑
LOW       0.1-3.9   Backlog

规则：
- 只识别和评估，不修改代码
- CRITICAL 漏洞：立即在 .expero/docs/roadmap.md 创建阻塞任务（状态 blocked）"
      ;;

    scribe)
      echo "$base

你的职责：对外文档、API 参考、CHANGELOG

本次任务：${task_id:-生成所有对外文档}

读取必需：
- .expero/docs/adr/（全部）
- .expero/docs/specs/（全部）
- 代码中的接口定义

你的产出（按需）：
- .expero/docs/public/api-reference.md   # API 参考
- .expero/docs/public/quickstart.md      # 快速上手
- .expero/docs/public/architecture.md    # 架构说明
- .expero/docs/public/onboarding.md      # 新人指南
- CHANGELOG.md                   # 基于 roadmap.md 的版本记录

规则：
- 不做技术决策，不修改代码
- 技术内容不确定时标注 [需 Architect 确认]
- 目标读者明确：api-reference → 集成方 / quickstart → 新用户 / onboarding → 新成员"
      ;;

    archaeologist)
      echo "$base

你的职责：遗留代码理解、逆向 ADR、技术债梳理

本次任务：${task_id:-分析现有代码库，建立理解基线}

你的产出：
- .expero/docs/legacy/module-map.md     # 模块关系图
- .expero/docs/legacy/known-bugs.md     # 已知问题（标注 [SECURITY] / [BUG-CRITICAL]）
- .expero/docs/legacy/tech-debt.md      # 技术债清单
- .expero/docs/reverse-adr/RADR-NNNN-<slug>.md  # 推断的设计决策

逆向 ADR 格式：
# RADR-NNNN: <推断的决策标题>

## Inference Confidence
HIGH | MEDIUM | LOW

## Evidence
# 引用具体文件和行号

## Inferred Decision
# 当时可能的决策原因

## Current Problems
# 今天带来的问题

规则：
- 不修改代码
- 置信度 LOW 的推断必须明确标注
- 发现安全问题立即在 known-bugs.md 标注 [SECURITY]"
      ;;

    *)
      err "Unknown role: $role"
      exit 1
      ;;
  esac
}

# ─────────────────────────────────────────
# File generators
# ─────────────────────────────────────────

_gen_expero_config() {
  local scenario=$1

  # Compute scenario-specific extension list BEFORE the heredoc.
  # Embedding `$(case ...)` inside a heredoc confuses bash's paren matcher
  # on some versions and produces literal text in the output.
  local extensions=""
  case $scenario in
    legacy-analysis)    extensions=$'    - archaeologist\n    - scribe' ;;
    security-audit)     extensions=$'    - sentinel' ;;
    tech-docs)          extensions=$'    - scribe' ;;
    greenfield-library) extensions=$'    - scribe\n    - sentinel' ;;
  esac

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

_gen_claude_md() {
  local project=$1
  local scenario=$2

  # Compute roles line BEFORE heredoc (same reason as _gen_expero_config).
  local roles_line
  case $scenario in
    new-product|migration|refactor|multi-service)
      roles_line="- planner, architect, builder, verifier, critic" ;;
    legacy-analysis)
      roles_line="- planner, architect, archaeologist, scribe" ;;
    security-audit)
      roles_line="- planner, sentinel, builder" ;;
    tech-docs)
      roles_line="- planner, architect, scribe" ;;
    greenfield-library)
      roles_line="- planner, architect, builder, verifier, critic, scribe, sentinel" ;;
    *)
      roles_line="- planner, architect, builder, verifier, critic" ;;
  esac

  cat > CLAUDE.md << EOF
# $project

Expero Agents project (scenario: **$scenario**).

## Roles Enabled
$roles_line

## Project Context
<!-- Fill in: tech stack, architecture, module map -->

## Architecture Rules
<!-- Fill in after ADRs are written -->

## Extension Points
<!-- Fill in: how to add new modules / APIs -->

## Build Commands
<!-- Fill in: build / test / lint / deploy commands -->

## Key ADRs
<!-- Will be populated as ADRs are written -->

## Expero Protocol
All framework state lives in \`.expero/docs/\`. Never rely on conversation context for persistence.
Status values: \`todo\` / \`in-progress\` / \`completed\` / \`blocked\`.
Stop signals: \`NEEDS_ARCH_REVIEW\`, \`NEEDS_SPEC_CLARIFICATION\`, \`NEEDS_SECURITY_REVIEW\`.
EOF
}

_gen_agents_md() {
  cat > AGENTS.md << 'EOF'
# Agents Protocol (for non-Claude tools)

## Mandatory First Steps
1. Read CLAUDE.md
2. Read .expero/docs/roadmap.md
3. Read relevant .expero/docs/adr/ (if exists)

## Shared State Protocol
All state must be written to .expero/docs/. Do not rely on context for persistence.
Task status values: todo / in-progress / completed / blocked.
Complete tasks by updating roadmap.md task status to "completed".

## Stop Conditions
- Architecture issue not covered by ADR: write NEEDS_ARCH_REVIEW in roadmap.md, halt
- Spec ambiguity: write NEEDS_SPEC_CLARIFICATION in roadmap.md, halt
- Security concern: write NEEDS_SECURITY_REVIEW in roadmap.md, halt
EOF
}

_gen_roadmap() {
  local scenario=$1

  case $scenario in
    new-product|greenfield-library)
      cat > .expero/docs/roadmap.md << 'EOF'
# Roadmap

## M0 — Skeleton (goal: core flow works, CI green)

| ID | Task | Status | Owner | Depends | Commit |
|----|------|--------|-------|---------|--------|
| M0-001 | Project scaffold | todo | builder | — | |
| M0-002 | Core infrastructure (DB/Cache/Logging) | todo | builder | M0-001 | |
| M0-003 | Authentication flow | todo | builder | M0-002 | |
| M0-004 | User/Role/Permission CRUD | todo | builder | M0-003 | |
| M0-005 | Unit tests for core paths | todo | verifier | M0-003 | |
| M0-006 | CI configuration | todo | builder | M0-005 | |

**M0 Exit Criteria**
- [ ] Build succeeds without warnings
- [ ] End-to-end flow (login → protected endpoint) works
- [ ] CI all green

---

## M1 — Feature Complete

| ID | Task | Status | Owner | Depends | Commit |
|----|------|--------|-------|---------|--------|
| M1-001 | [Business module 1] | todo | builder | M0 done | |

---

## M2 — Performance & Quality
## M3 — Release Preparation

## Backlog
EOF
      ;;

    migration)
      cat > .expero/docs/roadmap.md << 'EOF'
# Roadmap (Migration)

## M0 — Skeleton

| ID | Task | Status | Owner | Depends | Commit |
|----|------|--------|-------|---------|--------|
| M0-001 | Project scaffold | todo | builder | — | |
| M0-002 | Core infrastructure | todo | builder | M0-001 | |
| M0-003 | Auth migration | todo | builder | M0-002 | |
| M0-004 | Tests + CI | todo | verifier | M0-003 | |

**M0 Exit Criteria**
- [ ] Auth flow behavioral-equivalent to source (per ADR-divergence)
- [ ] CI all green

---

## M1 — Module Migration
## M2 — New Language/Framework Features
## M3 — Frontend/Deployment
EOF
      ;;

    refactor)
      cat > .expero/docs/roadmap.md << 'EOF'
# Roadmap (Refactor)

## M0 — Current State Analysis

| ID | Task | Status | Owner | Depends | Commit |
|----|------|--------|-------|---------|--------|
| M0-001 | As-is architecture analysis | todo | architect | — | |
| M0-002 | Target architecture + ADR | todo | architect | M0-001 | |
| M0-003 | Test coverage baseline | todo | verifier | M0-001 | |
| M0-004 | Migration plan | todo | planner | M0-002 | |

---

## M1 — Boundary Cleanup
## M2 — Core Module Refactor
## M3 — Validation
EOF
      ;;

    legacy-analysis)
      cat > .expero/docs/roadmap.md << 'EOF'
# Roadmap (Legacy Analysis)

## M0 — Code Reading

| ID | Task | Status | Owner | Depends | Commit |
|----|------|--------|-------|---------|--------|
| M0-001 | Module relationship map | todo | archaeologist | — | |
| M0-002 | Known bugs inventory | todo | archaeologist | M0-001 | |
| M0-003 | Tech debt inventory | todo | archaeologist | M0-001 | |
| M0-004 | Reverse ADRs | todo | archaeologist | M0-002 | |

---

## M1 — Documentation
## M2 — Next Steps Decision
EOF
      ;;

    security-audit)
      cat > .expero/docs/roadmap.md << 'EOF'
# Roadmap (Security Audit)

## M0 — Vulnerability Identification

| ID | Task | Status | Owner | Depends | Commit |
|----|------|--------|-------|---------|--------|
| M0-001 | Auth module audit | todo | sentinel | — | |
| M0-002 | Data access audit | todo | sentinel | — | |
| M0-003 | Sensitive data audit | todo | sentinel | — | |
| M0-004 | Dependency scan | todo | sentinel | — | |
| M0-005 | Summary report | todo | sentinel | M0-004 | |

---

## M1 — CRITICAL/HIGH Fixes
## M2 — MEDIUM Fixes + Hardening
EOF
      ;;

    tech-docs)
      cat > .expero/docs/roadmap.md << 'EOF'
# Roadmap (Tech Docs)

## M0 — Inventory

| ID | Task | Status | Owner | Depends | Commit |
|----|------|--------|-------|---------|--------|
| M0-001 | Existing docs inventory | todo | scribe | — | |
| M0-002 | API endpoint list | todo | architect | — | |
| M0-003 | Documentation architecture | todo | planner | M0-002 | |

---

## M1 — Core Documents
## M2 — Complete Documentation System
EOF
      ;;

    multi-service)
      cat > .expero/docs/roadmap.md << 'EOF'
# Roadmap (Multi-Service)

## M0 — Contract Discovery

| ID | Task | Status | Owner | Depends | Commit |
|----|------|--------|-------|---------|--------|
| M0-001 | Service call chain diagram | todo | architect | — | |
| M0-002 | Inter-service contracts | todo | architect | M0-001 | |
| M0-003 | Test matrix | todo | planner | M0-002 | |

---

## M1 — Contract Tests
## M2 — E2E Tests
EOF
      ;;
  esac
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
  # Copy the bootstrap script into the new project so users can run it
  # in-tree without keeping the source tree around. Caller must pass the
  # absolute path resolved BEFORE any cd (see cmd_init).
  local script_path=$1
  if [ -n "$script_path" ] && [ -f "$script_path" ] && [ "$script_path" != "$(pwd)/expero.sh" ]; then
    cp "$script_path" expero.sh
    chmod +x expero.sh
  fi
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
  bash expero.sh restart

Documentation: https://github.com/your-org/expero-agents
EOF
}

# ─────────────────────────────────────────
# Dispatch
# ─────────────────────────────────────────
case "$COMMAND" in
  init)    shift; cmd_init "$@" ;;
  start)   shift; cmd_start "$@" ;;
  status)  cmd_status ;;
  restart) cmd_restart ;;
  help|-h|--help) cmd_help ;;
  *) err "Unknown command: $COMMAND"; echo ""; cmd_help; exit 1 ;;
esac
