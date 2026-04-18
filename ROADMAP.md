# Expero Roadmap

> 版本计划与未实现功能的跟踪。当前实现状态见 [SPEC.md 实现状态](./SPEC.md#实现状态)。

---

## v1.x — 文档对齐与生态集成

不改变核心抽象，聚焦在让文档和实现完全对齐，以及与现代 agent 生态接入。

### v1.1 — 文档清理（已随 v1.0.0 发布）

所有 v1.1 原计划项已在 v1.0.0 发布前一并完成，详见 [CHANGELOG.md](./CHANGELOG.md)：

- [x] `AGENTS.md` 补充 Role 速查（Owns / Reads / Never 矩阵）
- [x] `CLAUDE.md` 模板去占位符，每段改为带 `e.g.` 示例的起点内容
- [x] `CHANGELOG.md`（Keep a Changelog 格式）
- [x] `LICENSE` 文件（CC0 1.0 Universal 全文）
- [x] 清理 `README.md` / `expero.sh` 中的 `your-org` 占位符

### v1.2 — 基础加固 + 数据/代码分离（已发布，Unreleased → 待发 v1.1）

一批从 v2.0 提前落地的基础设施，不破坏 v1.x 兼容：

**基础设施**
- [x] **结构化 Stop Signal 基线**：`.expero/signals/*.json` 与 `status` 解析
      （v2.0.1 的数据层；自动分派与 resolved 归档仍留给 v2.0.1）
- [x] **Artifact Schema 校验器**：`expero.sh validate [path]` 覆盖 SPEC §5.2
      全部 7 种 artifact（v2.0.3 完整交付）
- [x] **init 原子化**：sibling mktemp + mv + EXIT-trap rollback，失败不留半态
- [x] **`set -euo pipefail`** + task-id 字符集校验 + grep 边界修复

**数据/代码分离**（三个 PR 合计 ~2000 行变更，370 个回归测试，字节级不变性验证）
- [x] **roles 抽离**：8 个 role prompt 移到 `roles/*.md`（heredoc → 模板文件 + `__TASK__` 占位符）
- [x] **scenarios 抽离**：8 个 scenario 移到 `scenarios/*.json` + `scenarios/roadmaps/*.md`
- [x] **schemas 抽离**：7 个 artifact schema 移到 `schemas/*.json`
- [x] **自包含项目**：init 复制 roles/ + scenarios/ + schemas/ 到 `.expero/`，项目本身成为有效 install
- [x] **三级资源解析**：`_resource_root()` 支持 cwd / script 同级 / 源 repo 三种布局

新增 role / scenario / artifact type **不再需要修改 `expero.sh`**。架构详见
[docs/ARCHITECTURE.md](./docs/ARCHITECTURE.md)，扩展配方见
[docs/EXTENDING.md](./docs/EXTENDING.md)。全部变更见 [CHANGELOG.md](./CHANGELOG.md#unreleased)。

### v1.3 — 生态集成

- **Superpowers / Skills 集成**：Role prompt 末尾引用推荐的 skill，例如
  - Builder → `systematic-debugging`, `test-driven-development`
  - Sentinel → `security-review`
  - Archaeologist → `codebase-to-course`（类似探索型 skill）
- **MCP 支持**：外部状态源（GitHub issues / Linear / Jira）通过 MCP 服务接入，而非只依赖 `.expero/docs/` 文件。Role 的 `reads` 清单允许包含 MCP resource URI

---

## v2.0 — 从模板生成器到真框架

Major release。目标：把 SPEC 中声明式的部分真正落成结构约束（P3），让违规在结构上不可能发生，而不是靠 prompt 约定。

### 2.0.1 — 结构化 Stop Signal（调度层）

> 数据层 + lifecycle 展示已在 v1.x 落地：signals 目录 + resolved/ 归档、JSON
> schema、`status` 解析 + dispatch 提示。剩余一项：Role prompt 自动引用。

- [x] `.expero/signals/<id>-<type>.json` 与 `status` 解析（v1.2）
- [x] 每个信号按类型分派建议的 Role（`status` 输出中 `→ dispatch to: <role>`，Unreleased）
- [x] 信号解决后归档到 `.expero/signals/resolved/`（`status` 单独计数，Unreleased）
- [ ] Role prompt 自动引用未解决信号（需要 subagent 层基础，与 v2.0.4 合并）

**动机**：P3「结构约束优于 prompt 指令」当前违反——靠文本约定，误写/漏写无法检测。

### 2.0.2 — Quality Gate 执行器（4/5 已在 v1.x 落地）

`expero.sh gate <name> [task-id]` 已可用。4 个基础 gate 已发布：

- [x] **`artifacts_valid`** — 包 `cmd_validate`（v1.2）
- [x] **`adr_compliance <task>`** — 检查 Critic 的 review 文件 Verdict=APPROVED（v1.2）
- [x] **`security_clean`** — 安全汇总 CRITICAL 计数为 0（v1.2，含 dogfood 修复）
- [x] **`ci_passes`** — 跑 `config.yaml` 中 `ci_commands` 列表，任一非零即 fail（Unreleased）
- [x] **`all [task]`** — 元 gate，依次跑全部适用 gate（v1.2，含 ci_passes）
- [ ] **`test_coverage`** — 需要 coverage 工具适配器（Jest/pytest/go test 各一套），延后

**动机**：让 SPEC §4.2 的 Gate 真正成为结构约束，而非 prompt 约定。

**test_coverage 延后原因**：每种语言的 coverage 工具输出格式差异大（Jest JSON / pytest
terminal / go test `-coverprofile`），设计需要决定"从文件读 coverage 数值"还是
"声明 coverage_command 外部调用"。下个 iteration 先出设计 doc 再动手。

### 2.0.3 — Artifact Schema 校验器 ✅ CLOSED（v1.2 交付）

v1.2 已完整落地 `expero.sh validate`，并在后续 refactor 中把 schema 从 bash
case 抽到 `schemas/*.json`，新增 artifact type 不再需要改代码。独立形态工作
归零；与 Quality Gate 的集成并入 2.0.2 的 `artifacts_valid` 条目。

### 2.0.4 — 基于 Agent SDK / subagent 的调度器（Skills 层已在 v1.2 落地，Subagent 设计 doc 已就绪）

**已交付**（v1.2 作为 Phase 2 / 路线 B 的一部分）：
- [x] Claude Code Skills 打包：`.claude-plugin/skills/expero-<role>/`
      × 8，由 `scripts/regen-skills.sh` 从 `roles/*.md` 统一渲染
- [x] Skills-and-CLI 双栖：Codex / Gemini 用户仍用 `expero.sh start`，无回归
- [x] 单一真相源：role prompt 源在 `roles/`，skills 是衍生视图，测试保证两者字节级同步

**v2.0.4 的剩余工作**（真正的 subagent 调度，设计见 [docs/DESIGN-subagent-dispatch.md](./docs/DESIGN-subagent-dispatch.md)）：

**Phase 1 — subagent definitions（准备实施）**
- [ ] 写 `scripts/regen-subagents.sh` 从 `roles/*.md` + `_meta.json` 生成
- [ ] `.claude/agents/expero-<role>.md` × 8（tools / model / permission per role）
- [ ] init 复制到项目 `.claude/agents/`，Claude Code 自动识别
- [ ] 字节级同步测试，同 regen-skills 模式

**Phase 2 — orchestrator（Phase 1 dogfood 后再议）**
- [ ] `.claude/agents/expero-orchestrator.md`：读 roadmap，派发 role，处理 stop signal
- [ ] 主 agent 一句话触发一个 M0-001 的完整 ship 流程
- [ ] 里程碑边界重启进入 orchestrator 内部状态机

**策略**：Strategy C（CLI + Skills + Subagent 三层并存）。Codex / Gemini 用户不受影响。

**动机**：2024 年的手动多终端模式已被原生 subagent 取代。Skills 解决了
「如何让 Claude Code 自动应用 role 方法论」；subagent 解决「如何并行运行
多个 role」——两个问题，两层实现。

---

## 不会加入

明确保持不变的设计选择，即使有用户需求也不会实现：

- **跨会话 Memory 持久化** — 违反 P1「状态通过文件系统传递」。所有需要跨会话保留的信息必须在 `.expero/docs/` 中，不在 Memory。
- **Role 合并成超级 agent** — 反模式 1。Expero 的价值恰恰在分工。
- **跳过 Critic 的 fast-track** — 违反 C1 单一写权限原则。没有 Critic 的实现 = 没有审查。
- **全自动化（无人类协调者）** — §1.3 非目标。Conductor 的判断在 Scenario 选择、Stop Signal 处理、里程碑决策三个时刻不可替代。

---

## 贡献

提议新条目的步骤：

1. 开 issue 描述动机，引用违反了 SPEC 哪个原则 / 哪个反模式
2. 标注目标版本（v1.x 保持兼容 / v2.0 可以破坏兼容）
3. 说明是否需要 SPEC 修订（v2.x 的新能力通常需要同步更新 SPEC）
