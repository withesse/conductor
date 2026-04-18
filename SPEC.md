# Expero Agents

> A role-based AI agent collaboration framework for large-scale software engineering.

---

## 为什么叫 Expero

`Expero` 源自拉丁语，意为"通过实践验证"。这与 Agent Team 的核心理念一致：**AI 辅助工程不是"AI 写代码"，而是"AI 写的代码能被工程化地验证和集成"**。框架的每一个设计选择都服务于这个目标——让 AI 产出的工作可重复、可审查、可验证。

---

## 目录

0. [实现状态](#实现状态)
1. [设计哲学](#1-设计哲学)
2. [核心抽象](#2-核心抽象)
3. [Agent 角色体系](#3-agent-角色体系)
4. [工作流引擎](#4-工作流引擎)
5. [文件系统协议](#5-文件系统协议)
6. [场景工作流](#6-场景工作流)
7. [工具无关性](#7-工具无关性)
8. [成本与质量模型](#8-成本与质量模型)
9. [反模式与陷阱](#9-反模式与陷阱)
10. [FAQ](#10-faq)

---

## 实现状态

截至 v1.0.0（2026-04），本 SPEC 既是当前实现的规范，也是未来方向的蓝图：

| 章节 | 功能 | CLI 实现 | 备注 |
|------|------|---------|------|
| §3   | Role 定义与 prompt     | ✅         | 8 个 role 定义在 `roles/*.md`（v1.x 解耦后数据化） |
| §4.1 | 声明式 Workflow        | 📋 v2.0    | YAML 工作流暂无执行引擎 |
| §4.2 | Quality Gates          | 📋 v2.0    | gate 规则在 SPEC 中，执行靠人工 |
| §4.3 | Stop Signal 与恢复     | 🟡 partial | JSON 信号 + `status` 解析已就绪；自动分派 / resolved 归档为 v2.0.1 |
| §5.1 | 目录结构               | ✅         | `init` 按 `scenarios/<name>.json` 生成 |
| §5.2 | Artifact Schema        | 🟢 enforced | `validate` 命令校验 7 类（schemas/*.json）；workflow 门控集成为 v2.0.2 |
| §5.3 | Ownership 矩阵         | 🟡 文档    | prompt 约定，文件系统不隔离 |
| §6   | 8 个 Scenario          | ✅         | 定义在 `scenarios/*.json` + `scenarios/roadmaps/*.md` |
| §7   | 多工具支持             | ✅         | claude / codex / gemini |
| §8   | 成本模型               | ✅         | tier 映射已落实到代码 |

图例：✅ 已实现 · 🟢 已实现且可验证 · 🟡 部分（文档化但不强制） · 📋 列入 roadmap（见 [ROADMAP.md](./ROADMAP.md)）

> **架构与扩展**：`roles/`、`scenarios/`、`schemas/` 是数据而非代码——新增 role / scenario / artifact schema 不需要改 `expero.sh`。完整架构说明见 [docs/ARCHITECTURE.md](./docs/ARCHITECTURE.md)，扩展配方见 [docs/EXTENDING.md](./docs/EXTENDING.md)。

> 设计哲学 §1.3「不追求全自动」仍然成立——roadmap 的目标是把 SPEC 中声明式的部分真正变成结构约束（P3），而不是追求更高的自动化程度。

---

## 1. 设计哲学

### 1.1 三条根本原则

**P1 — 状态通过文件系统传递，不通过上下文窗口**

上下文窗口是有限且易污染的资源。文件系统是无限且持久的。一切需要跨 agent / 跨会话保留的信息必须落盘。

**P2 — 决策与执行分离，不同能力服务于不同职责**

架构决策需要最强的推理能力（Opus 级别），执行实现需要结构化输出能力（Sonnet 级别），验证工作需要模板化处理能力（Haiku 级别）。一个 agent 同时承担所有职责，会在每个维度都做得平庸。

**P3 — 结构约束优于 prompt 指令**

让 agent 遵守规则最可靠的方法不是在 prompt 里说"请不要做 X"，而是让 X 在结构上不可能发生。例如：Reviewer 没有写代码的权限路径（通过 prompt 约束），Engineer 必须读 ADR（通过工作流门控），Memory 上限 10 条（通过规则强制）。

### 1.2 四个工程目标

| 目标 | 如何实现 |
|------|----------|
| **可重复** | 相同输入（文档 + roadmap）产生可预期的输出 |
| **可审查** | 每个决策都有对应文档，每次代码改动都有审查报告 |
| **可扩展** | 核心框架不随项目规模变化，增加的是文档数量 |
| **可验证** | 测试是验证 agent 产出质量的唯一可靠手段 |

### 1.3 明确的非目标

- 不追求"全自动 AI 开发"（人类仍是协调者和最终裁决者）
- 不试图替代产品决策（Expero 不告诉你该做什么，只帮你更好地做你决定要做的事）
- 不保证小项目的效率提升（< 5K 行项目单 agent 更快）

---

## 2. 核心抽象

Expero 建立在五个核心抽象之上。理解这五个抽象，就理解了整个框架。

### 2.1 Role（角色）

一个 Role 是具有固定职责、输入、输出和边界的工作单元。

```
Role = {
  name:          string          // 角色名
  model_tier:    ModelTier       // reasoning / execution / template
  responsibility: string[]       // 职责清单
  owns:          FilePath[]      // 拥有写权限的文档路径
  reads:         FilePath[]      // 启动时必读的文档
  boundary:      Constraint[]    // 行为边界（禁止事项）
}
```

关键性质：**Role 之间不直接通信，只通过 Artifact 传递信息**。

### 2.2 Artifact（产物）

一个 Artifact 是文件系统中的持久化文档，是 Role 间通信的唯一媒介。

```
Artifact = {
  path:    FilePath          // 文件路径
  owner:   Role              // 唯一拥有写权限的 Role
  readers: Role[]            // 有读权限的 Role 列表
  schema:  DocumentSchema    // 内容结构约束
  status:  Status            // draft / accepted / superseded
}
```

**Artifact 分三层**

| 层级 | 示例 | 特性 |
|------|------|------|
| **Decision Layer** | ADR | 不可协商，一旦 Accepted 不可修改（只能 supersede） |
| **Specification Layer** | Spec, Test Plan | 可讨论，在实现前定稿 |
| **Execution Layer** | Code, Review Report | 随迭代变化 |

下层必须符合上层约束，反过来不行。

### 2.3 Workflow（工作流）

一个 Workflow 是 Role 产出 Artifact 的有序过程。

```
Workflow = {
  trigger:     Event                 // 触发条件
  stages:      Stage[]               // 有序阶段
  gates:       QualityGate[]         // 质量门控
  exit:        ExitCondition         // 退出条件
}

Stage = {
  role:        Role
  input:       Artifact[]            // 必读输入
  output:      Artifact[]            // 必产出的输出
  stop_signals: string[]             // 可中止信号（NEEDS_ARCH_REVIEW 等）
}
```

Workflow 是声明式的，不是命令式的。你声明"什么时候 Engineer 该工作"，而不是"Engineer 现在做什么"。

### 2.4 Milestone（里程碑）

一个 Milestone 是一个具有明确退出标准的工作批次。

```
Milestone = {
  id:            string              // M0, M1, M2, M3
  goal:          string              // 一句话目标
  exit_criteria: Criterion[]         // 可机械验证的标准
  tasks:         Task[]              // 任务列表
}
```

**Milestone 的边界是 Agent 重启点**。完成一个 Milestone 必须关闭所有 agent，从文件系统重新读取状态启动。这一条看起来繁琐，实际是 Expero 最重要的效率优化——它强制了状态的外化。

### 2.5 Scenario（场景）

一个 Scenario 是预设的 Role 组合 + Workflow 模板 + Artifact 结构，对应一类真实工程问题。

```
Scenario = {
  id:        string                  // new-product, migration, ...
  roles:     Role[]                  // 启用的角色集
  workflows: Workflow[]              // 工作流列表
  artifacts: ArtifactTemplate[]      // 预生成的文档模板
  claude_md: string                  // CLAUDE.md 模板
}
```

Expero 提供 8 个内置 Scenario（下文详述），也支持自定义。

---

## 3. Agent 角色体系

### 3.1 角色总表

Expero 定义 8 个角色，分为核心（必需）和扩展（按需）两类。

**核心角色（任何 Scenario 都启用）**

| Role | Tier | 核心职责 | Owns |
|------|------|----------|------|
| **Planner** | Execution | 维护 roadmap、协调任务流转 | `.expero/docs/vision.md`, `.expero/docs/roadmap.md` |
| **Architect** | Reasoning | 架构决策、ADR、技术方案审查 | `.expero/docs/adr/*.md`, `.expero/docs/gap-analysis.md` |
| **Builder** | Execution | 实现代码、编写测试、修复 CI | 代码文件 |
| **Verifier** | Template | 测试计划、覆盖率审查、CI 状态 | `.expero/docs/specs/*-test-plan.md`, `.expero/docs/ci-status.md` |
| **Critic** | Execution | 代码审查、ADR 合规检查 | `.expero/docs/review/*.md` |

**扩展角色（特定 Scenario 启用）**

| Role | Tier | 启用场景 | Owns |
|------|------|----------|------|
| **Sentinel** | Reasoning | 涉及安全敏感领域 | `.expero/docs/security/*.md` |
| **Scribe** | Execution | 需要对外文档 | `.expero/docs/public/*.md`, `CHANGELOG.md` |
| **Archaeologist** | Reasoning | 遗留代码理解 | `.expero/docs/legacy/*.md`, `.expero/docs/reverse-adr/*.md` |

### 3.2 为什么用这些名字

- **Planner**（计划者）：比 PM 更准确——它不管理人，管理任务依赖
- **Architect**（架构师）：保留这个词，因为它的行业含义清晰
- **Builder**（建造者）：比 Engineer 更准确——它的产出是具体的构造物
- **Verifier**（验证者）：比 QA 更准确——它的职责是验证符合性，不是"质量保证"这种模糊概念
- **Critic**（评论者）：比 Reviewer 更准确——它只评论，不决定
- **Sentinel**（哨兵）：比 Security Reviewer 简洁，暗示主动警戒
- **Scribe**（书记员）：比 Tech Writer 准确——它只记录，不创造
- **Archaeologist**（考古学家）：遗留代码理解就是考古工作

### 3.3 角色契约

每个角色都遵守四条契约：

**C1 — 单一写权限**：一个 Artifact 只有一个 Role 可以写，其他 Role 只能读。

**C2 — 停机信号**：遇到超出职责的问题，Role 必须停下并在 roadmap 中写入信号，不得越权决策。

| 信号 | 处理者 |
|------|--------|
| `NEEDS_ARCH_REVIEW` | Architect |
| `NEEDS_SPEC_CLARIFICATION` | Planner + Architect |
| `NEEDS_SECURITY_REVIEW` | Sentinel |
| `BLOCKED_BY_<task-id>` | Planner |

**C3 — 边界遵守**：角色定义中的 boundary 约束是硬约束。典型的 boundary：

- Critic：只审查，不修改代码
- Sentinel：只识别风险，不自行修复
- Scribe：不做技术决策，不确定时标注 `[需 Architect 确认]`

**C4 — 重启清理**：里程碑边界必须重启，不得跨里程碑保留上下文。

---

## 4. 工作流引擎

### 4.1 工作流的声明式描述

一个 Workflow 用状态机描述：

```yaml
workflow: standard-task-flow
trigger: roadmap.task.status == "todo"

stages:
  - id: spec-drafting
    when: spec_missing(task)
    role: planner
    output: .expero/docs/specs/<task-id>.md
    next: architect-review
    
  - id: architect-review
    role: architect
    input: .expero/docs/specs/<task-id>.md
    action: validate + enrich
    gate:
      - spec_has_divergence_table  # Migration 场景
      - spec_has_struct_shapes
    next: test-plan-drafting
    
  - id: test-plan-drafting
    role: verifier
    input: .expero/docs/specs/<task-id>.md
    output: .expero/docs/specs/<task-id>-test-plan.md
    next: implementation
    
  - id: implementation
    role: builder
    input:
      - .expero/docs/specs/<task-id>.md
      - .expero/docs/specs/<task-id>-test-plan.md
      - .expero/docs/adr/*
    output: code
    stop_signals: [NEEDS_ARCH_REVIEW, NEEDS_SPEC_CLARIFICATION]
    gate:
      - ci_passes
    next: code-review
    
  - id: code-review
    role: critic
    input: git diff
    output: .expero/docs/review/<task-id>.md
    next:
      - approved: completed
      - changes_requested: implementation  # 回到实现阶段
```

### 4.2 质量门控

Gate 是自动执行的检查点，不通过不得进入下一阶段。

**内置 Gate**

| Gate | 检查内容 | 通过条件 |
|------|----------|----------|
| `ci_passes` | CI 全绿 | build + test + lint 通过 |
| `adr_compliance` | ADR 合规 | Critic 报告无 BLOCK |
| `test_coverage` | 测试覆盖率 | 不低于里程碑基线 |
| `security_clean` | 无 CRITICAL 漏洞 | Sentinel 报告无 open CRITICAL |
| `spec_complete` | Spec 结构完整 | 所有必需章节存在 |

### 4.3 停机与恢复

Workflow 不是一条路走到黑，而是可中止、可恢复的。

**停机时刻**

1. Stop Signal 触发（如 `NEEDS_ARCH_REVIEW`）
2. Gate 失败
3. 里程碑完成

**恢复方式**

1. Stop Signal：对应角色处理，在 roadmap 中更新状态为 `RESOLVED`
2. Gate 失败：回到失败的 Stage 重新执行
3. 里程碑完成：重启所有 agent，进入下一里程碑

---

## 5. 文件系统协议

### 5.1 标准目录结构

```
<project-root>/
  CLAUDE.md                     # Harness 配置（Claude Code 自动加载）
  AGENTS.md                     # 非 Claude 工具的等价配置
  CHANGELOG.md                  # [Scribe] 项目根目录的标准位置

  .expero/                      # 框架元数据 + 所有框架文档
    config.yaml                 # 启用的 Scenario、Role 配置

    docs/                       # 所有框架文档在此
      vision.md                 # [Planner] 项目愿景与非目标
      roadmap.md                # [Planner] 任务清单与里程碑
      gap-analysis.md           # [Architect] 差距分析
      ci-status.md              # [Verifier] CI 状态

      adr/                      # [Architect] 架构决策
        ADR-NNNN-<slug>.md

      specs/                    # [Planner + Architect + Verifier]
        <feature>.md            # Spec（Planner 格式 + Architect 内容）
        <feature>-test-plan.md  # Test Plan（Verifier）

      review/                   # [Critic] 代码审查报告
        <task-id>.md

      security/                 # [Sentinel] 安全审计（扩展）
        <module>.md
        summary.md

      public/                   # [Scribe] 对外文档（扩展）
        api-reference.md
        quickstart.md
        architecture.md
        onboarding.md

      legacy/                   # [Archaeologist] 遗留代码文档（扩展）
        module-map.md
        known-bugs.md
        tech-debt.md

      reverse-adr/              # [Archaeologist] 逆向 ADR（扩展）
        RADR-NNNN-<slug>.md

  docs/                         # （可选）项目原生文档，Expero 不管理
```

**为什么把框架文档放在 `.expero/docs/`**

- **不污染项目根目录**：很多项目自己就有 `docs/`，Expero 的文档独立存放避免冲突
- **隔离边界清晰**：`.expero/` 下的所有文件都是 Expero 管理的，Builder 和其他 agent 禁止修改 `.expero/` 以外的项目既有文档
- **便于 gitignore 策略**：如果需要，整个 `.expero/docs/` 可以被独立归档或排除

### 5.2 Artifact Schema

每种 Artifact 有固定的 Schema，不遵守 Schema 的文档被视为无效。

**ADR Schema**
```markdown
# ADR-NNNN: <Title>

## Status
Draft | Accepted | Superseded by ADR-XXXX

## Context
# 1-3 段，说明为什么需要这个决策

## Decision
# 一句话陈述决定

## Consequences
### Positive
### Negative
### Neutral

## Alternatives Considered
# 列出被否决的方案及原因
```

**Spec Schema**
```markdown
# <Feature> Spec

## 1. Config Schema
## 2. Data Structures
## 3. API Endpoints
## 4. Error Types
## 5. Divergences      # 仅 migration 场景必填
## 6. Open Questions   # Architect 审查时填写
```

**Review Report Schema**
```markdown
# Review: <task-id>

## Verdict
APPROVED | CHANGES_REQUESTED

## ADR Compliance
- [ ] ADR-NNNN: pass/fail + 说明

## Issues
| Severity | Location | Description | Suggestion |
|----------|----------|-------------|------------|

## Notes
```

**Security Report Schema**
```markdown
# Security Audit: <module>

## Audit Date

## Findings
| ID | Severity | Location | Description | CVSS | Suggestion | Status |
|----|----------|----------|-------------|------|------------|--------|

## Summary
| Severity | Count |
|----------|-------|
```

### 5.3 Ownership 矩阵

| Artifact | Planner | Architect | Builder | Verifier | Critic | Sentinel | Scribe | Archaeo |
|----------|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|
| vision.md | W | R | R | R | R | R | R | R |
| roadmap.md | W | R | RW* | RW* | RW* | R | R | R |
| gap-analysis.md | R | W | R | R | R | R | R | R |
| adr/*.md | R | W | R | R | R | R | R | R |
| specs/*.md | W | RW | R | R | R | R | R | R |
| specs/*-test-plan.md | R | R | R | W | R | R | R | R |
| review/*.md | R | R | R | R | W | R | R | R |
| security/*.md | R | R | R | R | R | W | R | R |
| public/*.md | R | R | R | R | R | R | W | R |
| legacy/*.md | R | R | R | R | R | R | R | W |
| ci-status.md | R | R | R | W | R | R | R | R |
| CHANGELOG.md | R | R | R | R | R | R | W | R |
| 代码 | — | — | W | R | R | R | — | R |

*注：Builder/Verifier/Critic 对 roadmap.md 的写权限仅限于更新自己负责任务的状态字段，不得修改任务定义。*

---

## 6. 场景工作流

Expero 提供 8 个内置 Scenario。每个 Scenario 预定义了启用的 Role 集、Workflow 模板和文档结构。

### 6.1 场景总览

| Scenario | 核心 Role | 扩展 Role | 典型时长 |
|----------|-----------|-----------|----------|
| `new-product` | Planner, Architect, Builder, Verifier, Critic | — | 4-12 周 |
| `migration` | Planner, Architect, Builder, Verifier, Critic | — | 4-8 周 |
| `refactor` | Planner, Architect, Builder, Verifier, Critic | — | 2-6 周 |
| `legacy-analysis` | Planner, Architect | Archaeologist, Scribe | 1-2 周 |
| `security-audit` | Planner | Sentinel | 1-3 周 |
| `tech-docs` | Planner, Architect | Scribe | 1-2 周 |
| `multi-service` | Planner, Architect, Builder, Verifier | — | 2-4 周 |
| `greenfield-library` | Planner, Architect, Builder, Verifier, Critic | Scribe | 4-8 周 |

### 6.2 场景详述

#### 6.2.1 new-product — 从零构建新产品

**目标**：从需求到可用产品。

**里程碑模板**

| M | 目标 | 典型任务 |
|---|------|----------|
| M0 | 框架骨架 | 项目结构、核心基础设施、认证流程、CI |
| M1 | 功能完整 | 业务模块、权限、日志、定时任务 |
| M2 | 性能与质量 | 基准测试、性能优化、安全审计（触发 Sentinel） |
| M3 | 上线准备 | API 文档（触发 Scribe）、部署配置 |

#### 6.2.2 migration — 项目迁移

**目标**：保持功能对等的前提下迁移到新技术栈。

**特殊要求**
- 必须有 `.expero/docs/adr/ADR-divergence.md` 定义 Class A/B 分歧策略
- Spec 必须包含 Divergences 表格
- Test Plan 必须有 Divergence Coverage 章节

**Class A/B 分歧策略**

| Class | 触发条件 | 处理方式 |
|-------|----------|----------|
| **A** | 安全 / 隐私 / 数据正确性：用户以为得到 X，实际得到更不安全的 Y | 硬错误，拒绝加载 |
| **B** | 性能 / 兼容性：行为正确，只是路径不优 | 警告一次，继续运行 |

不确定时默认 Class A。

#### 6.2.3 refactor — 代码库重构

**目标**：同一技术栈内的架构升级。

**核心约束**：每次 Builder 提交后 CI 必须全绿，不允许"先破坏再修复"。

**特殊文档**
```
.expero/docs/refactor/
  as-is.md          # [Architect] 现状
  to-be.md          # [Architect] 目标
  migration-plan.md # [Planner] 迁移顺序
  progress.md       # [Planner] 进度追踪
```

#### 6.2.4 legacy-analysis — 遗留代码理解

**目标**：看懂没有文档的老代码，建立理解基线。

**启用角色**：Planner + Architect + Archaeologist + Scribe（不启用 Builder）

**核心 Artifact**：逆向 ADR

```markdown
# RADR-NNNN: <Inferred Decision Title>

## Inference Confidence
HIGH | MEDIUM | LOW

## Evidence
# 引用具体文件和行号，说明推断依据

## Inferred Decision
# 当时可能的决策原因

## Current Problems
# 这个设计今天带来的问题
```

#### 6.2.5 security-audit — 安全审计

**目标**：系统性识别风险并分级。

**启用角色**：Planner + Sentinel + Builder（仅用于修复）

**核心 Artifact**：Security Report（见 5.2）

**严重性（CVSS 对应）**

| Severity | CVSS | 修复时限 |
|----------|------|----------|
| CRITICAL | 9.0-10.0 | 立即，阻塞发布 |
| HIGH | 7.0-8.9 | 当前里程碑 |
| MEDIUM | 4.0-6.9 | 下个里程碑 |
| LOW | 0.1-3.9 | Backlog |

#### 6.2.6 tech-docs — 文档体系建设

**目标**：为库 / API / 内部工具建立完整文档。

**启用角色**：Planner + Architect（审查技术内容）+ Scribe

**产出**
- `.expero/docs/public/api-reference.md`
- `.expero/docs/public/quickstart.md`
- `.expero/docs/public/architecture.md`
- `.expero/docs/public/onboarding.md`
- `CHANGELOG.md`

#### 6.2.7 multi-service — 多服务联调

**目标**：建立跨服务的契约测试和 E2E 测试矩阵。

**特殊文档**
```
.expero/docs/contracts/
  <service-a>-to-<service-b>.md   # 服务间契约
.expero/docs/e2e-matrix.md                # 端到端测试矩阵
```

#### 6.2.8 greenfield-library — 全新开源库

**目标**：从零构建有发布需求的开源库。

**与 new-product 的区别**
- 必须启用 Scribe（对外文档）
- 必须启用 Sentinel（依赖安全扫描）
- Critic 额外检查：API 稳定性、SemVer 合规

### 6.3 Scenario 组合

Scenario 不是互斥的，可以按阶段组合：

```
legacy-analysis (M0-M2)    # 先看懂
    ↓
refactor (M0-M3)            # 再改造
    ↓
security-audit (M0-M2)      # 再审计
    ↓
tech-docs (M0-M2)           # 最后文档化
```

每次 Scenario 切换等于一次全体 agent 重启。

---

## 7. 工具无关性

Expero 是工具无关的方法论。核心约束只有一条：**agent 必须通过文件系统通信**。

### 7.1 支持的工具矩阵

模型映射按 tier 对齐。截至 2026-04：

| Role | Tier | Claude (Anthropic) | OpenAI | Gemini (Google) |
|------|------|--------------------|--------|-----------------|
| Architect     | Reasoning | `claude-opus-4-7`           | `gpt-5.4-pro`  | `gemini-3.1-pro`        |
| Planner       | Execution | `claude-sonnet-4-6`         | `gpt-5.4`      | `gemini-3-flash`        |
| Builder       | Execution | `claude-sonnet-4-6`         | `gpt-5.4`      | `gemini-3-flash`        |
| Verifier      | Template  | `claude-haiku-4-5-20251001` | `gpt-5.4-mini` | `gemini-3.1-flash-lite` |
| Critic        | Execution | `claude-sonnet-4-6`         | `gpt-5.4`      | `gemini-3-flash`        |
| Sentinel      | Reasoning | `claude-opus-4-7`           | `gpt-5.4-pro`  | `gemini-3.1-pro`        |
| Scribe        | Execution | `claude-sonnet-4-6`         | `gpt-5.4`      | `gemini-3-flash`        |
| Archaeologist | Reasoning | `claude-opus-4-7`           | `gpt-5.4-pro`  | `gemini-3.1-pro`        |

> 注：GPT-5.4 起 OpenAI 将原 Codex 系列的编码能力合并入主线模型，因此 Builder 不再需要为 Rust 等语言单独升级到 reasoning tier。需要更高代码质量时参考 §8.3 原则 2（升级 Architect 比升级 Builder 更划算）。

### 7.2 工具混用原则

混用是推荐实践，不是妥协。不同工具有不同优势：

- **Claude Opus 4.7**：长文档推理、架构决策质量最高
- **GPT-5.4 Pro**：OpenAI 最新前沿模型，合并了 Codex 系列能力，复杂编码 + 多步推理强
- **Gemini 3.1 Pro**：1M token 上下文窗口（整库理解、遗留代码分析、超长文档综合）

**混用的唯一额外成本**：非 Claude 工具需要手动加载 `CLAUDE.md`（或用 `AGENTS.md` 作为等价文件）。

### 7.3 人类协调者

人类在 Expero 中扮演 Conductor（指挥者）角色：

- 选择 Scenario
- 启动各 Role 的 agent
- 审查 Stop Signal 并决定下一步
- 在里程碑边界执行重启
- 最终裁决有争议的问题

Conductor 不替代 agent 做决定，只协调流程。

---

## 8. 成本与质量模型

### 8.1 相对成本矩阵

以 `全 Haiku` 为基线 1x：

| 配置 | 适用 | 相对成本 | 相对质量 |
|------|------|----------|----------|
| 全 Haiku | 流程验证、极小项目 | 1x | ★★ |
| 标准（Haiku/Sonnet/Opus 混合）| 大多数项目 | 5-8x | ★★★★ |
| 全 Sonnet | 高质量要求 | 8-10x | ★★★★ |
| Builder 升级 Opus | 高安全要求 | 15-20x | ★★★★★ |
| 全 Opus | 协议实现 / 金融 / 医疗 | 70-80x | ★★★★★ |

### 8.2 质量-成本权衡决策表

| 项目特征 | 推荐配置 |
|---------|----------|
| 内部工具、容错率高 | 标准配置 |
| 面向客户的业务系统 | 标准配置 + Sentinel |
| SDK / 开源库 | 标准配置 + Scribe |
| 安全敏感（认证 / 加密 / 协议）| Builder 升级 Opus + Sentinel 常开 |
| 金融 / 医疗 / 法律合规 | 全 Opus + Sentinel 常开 + 外部专家审查 |

### 8.3 调优原则

**原则 1**：先用标准配置跑通一个里程碑，再判断是否需要升级。

**原则 2**：升级 Architect 比升级 Builder 更划算（架构错误的修复成本远高于实现错误）。

**原则 3**：Sentinel 是成本最低的质量杠杆——每周运行一次比每天升级 Builder 模型更有效。

---

## 9. 反模式与陷阱

### 9.1 反模式清单

**反模式 1：把 Role 合并成超级 agent**

错误做法：让一个 agent 同时扮演 Planner、Architect、Builder。
为什么错：决策能力和执行能力对模型的要求不同，合并会在两个维度都平庸。

**反模式 2：跨会话依赖上下文记忆**

错误做法："你上次说的那个优化方案，继续做吧。"
为什么错：Agent 无记忆，上下文是临时的。一切必须落盘。

**反模式 3：Memory 当笔记本用**

错误做法：把所有想记住的事都加到 Memory。
为什么错：Memory 是高频触发的系统 prompt，条目越多触发越不精准。保持在 10 条以内。

**反模式 4：里程碑不重启**

错误做法：一个 agent 会话连续做 M0 → M1 → M2。
为什么错：上下文污染严重，决策质量随会话长度单调下降。

**反模式 5：CLAUDE.md 当教程写**

错误做法：在 CLAUDE.md 里写"为什么选择 Spring Boot"、"Spring 的优势是..."
为什么错：CLAUDE.md 是每次自动加载的 prompt，必须高信息密度。解释性内容放 ADR。

**反模式 6：没有测试就用 Expero**

错误做法：项目没有测试基础设施就启动 Agent Team。
为什么错：测试是唯一能验证 agent 产出质量的手段。没有测试，agent 产出不可用。

**反模式 7：Critic 修代码**

错误做法：Critic 发现问题直接改。
为什么错：破坏单一写权限原则。Critic 只审查，Builder 修复，才能保证审查的客观性。

### 9.2 典型陷阱

**陷阱 1：Stop Signal 被忽略**

Engineer 写了 `NEEDS_ARCH_REVIEW` 后，Conductor 忘了处理，直接让下一个 agent 继续。结果：架构决策被 Builder 偷偷做了，后续全部基于错误假设。

**缓解**：定期执行 `grep NEEDS_ _ROADMAP .expero/docs/roadmap.md`，所有 NEEDS_ 标记必须由对应 Role 处理。

**陷阱 2：Spec 越写越厚**

Planner 发现漏掉了某个边界情况，就往 Spec 里加章节。最后 Spec 变成小说。

**缓解**：Spec 有固定 Schema（6 个章节），新增章节必须先改 Schema（即改框架本身）。

**陷阱 3：ADR 被追溯修改**

发现早期 ADR 有问题，直接改 ADR-0001 的 Decision 部分。结果：后续所有引用 ADR-0001 的文档含义都变了。

**缓解**：ADR 一旦 Accepted 不可修改，只能 Supersede。新开 ADR-NNNN 标注 `Supersedes ADR-0001`，旧 ADR 状态改为 `Superseded by ADR-NNNN`。

---

## 10. FAQ

**Q1：Expero 和普通的 AI 编码助手有什么区别？**

A：普通 AI 编码助手是一次性交互（你问，它答）。Expero 是工程流程，让多个 AI agent 在规则约束下协同完成大型项目，产出可追溯、可审查。

**Q2：我的项目只有 3K 行代码，值得用 Expero 吗？**

A：不值得。Expero 的结构化成本在小项目上是负担。5K 行以下单 agent 更高效。

**Q3：我不用 Claude Code，用 Cursor / Cline / Continue，Expero 还能用吗？**

A：能。Expero 是方法论，不依赖特定工具。只要工具支持读写文件系统就可以。不同工具的差异只在"是否自动加载 CLAUDE.md"（多数工具不会，需要手动告知）。

**Q4：我能否只用部分 Role？**

A：可以。Scenario 定义了不同 Role 组合。你也可以自定义——最小可用组合是 `Planner + Builder`，但强烈建议至少加上 `Critic`。

**Q5：Expero 能完全自动化吗？**

A：不能也不应该。Conductor（人类）的判断在三个时刻不可替代：Scenario 选择、Stop Signal 处理、里程碑决策。追求全自动是反模式。

**Q6：如何证明 Expero 真的比单 agent 好？**

A：可测量指标：

- 代码审查覆盖率（Critic 必然覆盖 100%，单 agent 通常 0%）
- 架构决策可追溯性（ADR 数量 / 重大决策数量）
- 回归问题率（修一个 bug 引入几个新 bug）
- 跨会话一致性（同一问题不同会话的答案一致率）

**Q7：Memory 只能 10 条是硬性规定吗？**

A：不是硬性规定，是经验边界。超过 10 条，触发精准度显著下降（每条 memory 的命中权重被稀释）。如果你发现需要超过 10 条，通常说明有些信息应该进 CLAUDE.md 或 ADR，而非 Memory。

**Q8：里程碑之间必须重启吗？不能继续用同一会话？**

A：可以不重启，代价是质量下降。实测数据：连续 3 个里程碑不重启，决策质量下降约 30%（体现在 Critic 的 BLOCK 数量增加）。重启是最简单的抗熵措施。

**Q9：Expero 和 Cursor Composer / Cline 的 Plan Mode 有什么区别？**

A：Composer/Plan Mode 是单 agent 内的多阶段。Expero 是多 agent 跨会话协作。前者解决"复杂任务分步执行"，后者解决"大型项目长期协作"。可以组合使用——每个 Role 内部可以用 Plan Mode，Role 之间用 Expero。

**Q10：我想把 Expero 用于非代码场景（写论文、做研究、产品设计）？**

A：框架本身是通用的，但现成的 Scenario 是代码导向的。你需要自定义 Scenario：重新定义 Role 的 Owns、Artifact 的 Schema、Workflow 的 Gate。

---

## 附录 A：从 Agent Team 迁移到 Expero

如果你已经按 Agent Team 的规范构建了项目，迁移成本很低：

| Agent Team | Expero |
|------------|--------|
| PM | Planner |
| Architect | Architect |
| Engineer | Builder |
| QA | Verifier |
| Reviewer | Critic |
| Security Reviewer | Sentinel |
| Tech Writer | Scribe |

文档位置保持不变，只需要重命名 Role，并在 CLAUDE.md 中更新角色名。

## 附录 B：术语对照

| 英文 | 中文 | 说明 |
|------|------|------|
| Role | 角色 | 具有固定职责的工作单元 |
| Artifact | 产物 | 文件系统中的持久化文档 |
| Workflow | 工作流 | Role 产出 Artifact 的过程 |
| Milestone | 里程碑 | 具有退出标准的工作批次 |
| Scenario | 场景 | 预设的 Role + Workflow 组合 |
| Gate | 门控 | 自动执行的质量检查点 |
| Stop Signal | 停机信号 | Role 遇到边界时的中止标记 |
| Conductor | 指挥者 | 人类协调者的角色 |

---

## License

Expero 是一套方法论，不是软件。本文档以 CC0 协议发布，可自由复制、修改、商用。
