# Expero Agents

> A role-based AI agent collaboration framework for large-scale software engineering.

[![Version](https://img.shields.io/badge/version-1.0.0-blue)]() [![License](https://img.shields.io/badge/license-CC0-green)]()

---

## 什么是 Expero

Expero 是一套用于大型软件工程项目的多 AI agent 协作框架。它不是一个软件，是一套**方法论 + 模板 + CLI 工具**。

核心理念：AI 辅助工程不是"AI 写代码"，而是"**AI 写的代码能被工程化地验证和集成**"。

## 为什么需要 Expero

当项目规模超过 10K 行代码时，单个 AI agent 会遇到这些问题：

- 上下文窗口装不下整个项目
- 长会话中决策质量单调下降
- 架构决策、代码实现、质量验证需要不同的思维模式
- 跨会话的一致性难以保证

Expero 通过**多 agent 分工 + 文件系统传递状态 + 结构化文档**解决这些问题。

## 快速开始

### 安装

```bash
curl -O https://raw.githubusercontent.com/withesse/expero-agents/main/expero.sh
chmod +x expero.sh
```

### 初始化项目

```bash
bash expero.sh init my-app new-product
cd my-app
```

### 启动 Agent

```bash
# Architect：做架构决策
bash expero.sh start architect

# Planner：规划里程碑
bash expero.sh start planner

# Builder：实现第一个任务
bash expero.sh start builder M0-001

# Verifier：写测试计划
bash expero.sh start verifier M0-001

# Critic：代码审查
bash expero.sh start critic M0-001
```

### 查看状态

```bash
bash expero.sh status
```

### 里程碑边界重启

```bash
bash expero.sh restart
```

## 核心概念

### 五个抽象

```
Role       →  具有固定职责的工作单元
Artifact   →  文件系统中的持久化文档（Role 间通信的唯一媒介）
Workflow   →  Role 产出 Artifact 的过程
Milestone  →  具有退出标准的工作批次
Scenario   →  预设的 Role + Workflow 组合
```

### 八个 Role

**核心（任何 Scenario 启用）**
- `architect`   架构决策
- `planner`     任务协调
- `builder`     代码实现
- `verifier`    测试验证
- `critic`      代码审查

**扩展（按需启用）**
- `sentinel`       安全审计
- `scribe`         对外文档
- `archaeologist`  遗留代码分析

### 八个 Scenario

| Scenario | 用途 |
|----------|------|
| `new-product`        | 从零构建新产品 |
| `migration`          | 项目迁移（语言 / 框架） |
| `refactor`           | 代码库重构 |
| `legacy-analysis`    | 遗留代码理解 |
| `security-audit`     | 安全审计 |
| `tech-docs`          | 文档体系建设 |
| `multi-service`      | 多服务联调 |
| `greenfield-library` | 全新开源库 |

## 文件系统协议

Expero 的核心约束：**所有状态通过文件系统传递，不通过上下文窗口**。

```
project/
  CLAUDE.md                   # Harness 配置（自动加载）
  AGENTS.md                   # 非 Claude 工具的等价配置
  CHANGELOG.md                # [scribe] 项目根目录

  .expero/
    config.yaml               # 框架配置
    docs/                     # 所有框架文档
      vision.md               # [planner] 愿景
      roadmap.md              # [planner] 任务清单
      gap-analysis.md         # [architect] 差距分析
      ci-status.md            # [verifier] CI 状态

      adr/                    # [architect] 架构决策
      specs/                  # [planner + architect + verifier]
      review/                 # [critic] 代码审查
      security/               # [sentinel] 安全报告
      public/                 # [scribe] 对外文档
      legacy/                 # [archaeologist] 遗留文档
      reverse-adr/            # [archaeologist] 逆向 ADR

  docs/                       # （可选）项目原生文档，Expero 不管理
```

**关键设计**：所有框架文档放在 `.expero/docs/` 下，与项目原生的 `docs/` 完全隔离。这样：

- 不污染已有项目
- 边界清晰（agent 禁止修改 `.expero/` 以外的既有文档）
- 需要时整个 `.expero/` 可独立归档

## 工作流示例

```
 ┌─────────────────────────────────────────────┐
 │  Planner: 写 vision.md, roadmap.md          │
 └──────────────────┬──────────────────────────┘
                    ↓
 ┌─────────────────────────────────────────────┐
 │  Architect: 产出 ADRs, gap-analysis         │
 └──────────────────┬──────────────────────────┘
                    ↓
 ┌─────────────────────────────────────────────┐
 │  Planner: 基于 ADR 细化 specs               │
 └──────────────────┬──────────────────────────┘
                    ↓
 ┌─────────────────────────────────────────────┐
 │  Verifier: 写 test-plan                     │
 └──────────────────┬──────────────────────────┘
                    ↓
 ┌─────────────────────────────────────────────┐
 │  Builder: 实现代码（遵守 ADR）              │
 │  ├─ 遇到问题 → NEEDS_ARCH_REVIEW (停)       │
 │  └─ 完成 → 更新 roadmap.md                  │
 └──────────────────┬──────────────────────────┘
                    ↓
 ┌─────────────────────────────────────────────┐
 │  Critic: 代码审查                           │
 │  ├─ APPROVED → 合并                         │
 │  └─ CHANGES_REQUESTED → 回到 Builder        │
 └─────────────────────────────────────────────┘
                    ↓
              里程碑完成
                    ↓
          关闭所有 agent → 重启
```

## 工具支持

Expero 是工具无关的。支持矩阵：

| Role | Claude Code | OpenAI | Gemini |
|------|-------------|--------|--------|
| architect     | Opus 4.7   | gpt-5.4-pro  | Gemini 3.1 Pro        |
| planner       | Sonnet 4.6 | gpt-5.4      | Gemini 3 Flash        |
| builder       | Sonnet 4.6 | gpt-5.4      | Gemini 3 Flash        |
| verifier      | Haiku 4.5  | gpt-5.4-mini | Gemini 3.1 Flash-Lite |
| critic        | Sonnet 4.6 | gpt-5.4      | Gemini 3 Flash        |

> GPT-5.4 已合并原 Codex 系列的编码能力，不再需要为 Rust 单独升级到 reasoning tier。完整映射见 [SPEC §7.1](./SPEC.md#71-支持的工具矩阵)。

混用示例：

```bash
# Claude Code 做架构和审查
bash expero.sh start architect
bash expero.sh start critic M0-001

# OpenAI 做实现
bash expero.sh start builder M0-001 codex

# Gemini 做大上下文遗留代码分析（1M token 窗口）
bash expero.sh start archaeologist legacy-M0-001 gemini
```

## 成本模型

以 `全 Haiku` 为 1x：

| 配置 | 相对成本 | 适用场景 |
|------|----------|----------|
| 全 Haiku | 1x | 流程验证 |
| 标准混合 | 5-8x | 多数项目（推荐） |
| 全 Sonnet | 8-10x | 高质量要求 |
| Builder 升 Opus | 15-20x | 高安全要求 |
| 全 Opus | 70-80x | 协议/金融/医疗 |

## 何时不用 Expero

- 项目规模 < 5K 行（单 agent 更快）
- 探索性原型（结构化流程是负担）
- 没有测试基础设施（无法验证 agent 产出）
- 需要实时交互决策（UI 设计、产品方向）

## 反模式

框架最重要的不是告诉你做什么，而是明确不要做什么：

- ❌ 把 Role 合并成超级 agent
- ❌ 跨会话依赖上下文记忆
- ❌ Memory 当笔记本用
- ❌ 里程碑不重启
- ❌ CLAUDE.md 当教程写
- ❌ 没有测试就用 Expero
- ❌ Critic 修代码

详见 [SPEC.md §9](./SPEC.md)。

## 文档

- [SPEC.md](./SPEC.md) — 完整框架规范
- [expero.sh](./expero.sh) — CLI 工具
- [examples/](./examples/) — 各场景的 init 输出样例

## 开发与测试

`expero.sh` 自带回归测试，修改 CLI 后请先跑一遍：

```bash
bash test-expero.sh
```

测试覆盖：help 命令、8 个 scenario 的 `init`、`config.yaml` 模型 ID、extensions 列表、`CLAUDE.md` 角色行、`status` 任务计数、stop signal 检测、`model_for_role` 24 种（3 工具 × 8 role）组合、`restart` 错误处理。

## FAQ

**Q: Expero 和 Cursor Composer / Cline Plan Mode 有什么区别？**
A: 前者是单 agent 内的多阶段执行，后者是多 agent 跨会话协作。可组合使用。

**Q: 我不用 Claude Code，能用 Expero 吗？**
A: 能。Expero 是方法论，只要工具支持读写文件系统就可以。

**Q: 只用 Planner + Builder 两个 Role 可以吗？**
A: 可以，但强烈建议加 Critic。没有审查的代码等于没有审查的代码。

**Q: 如何迁移已有的 Agent Team 项目？**
A: 只需要重命名 Role：PM → Planner, Engineer → Builder, QA → Verifier, Reviewer → Critic。文档位置不变。

## License

CC0 — 可自由复制、修改、商用。

## 致谢

Expero 的设计基于以下实践经验：

- [mihomo-rust 项目的 Agent Team 实践](https://maxlv.net/blog/porting-mihomo-to-rust-with-claude/)
- Claude Code 的多 agent 支持
- 开源社区对结构化 AI 协作的探索

---

**"通过实践验证"——这是 Expero 的名字，也是它的方法论。**
