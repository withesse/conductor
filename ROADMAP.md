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

### v1.2 — 生态集成

- **Superpowers / Skills 集成**：Role prompt 末尾引用推荐的 skill，例如
  - Builder → `systematic-debugging`, `test-driven-development`
  - Sentinel → `security-review`
  - Archaeologist → `codebase-to-course`（类似探索型 skill）
- **MCP 支持**：外部状态源（GitHub issues / Linear / Jira）通过 MCP 服务接入，而非只依赖 `.expero/docs/` 文件。Role 的 `reads` 清单允许包含 MCP resource URI

---

## v2.0 — 从模板生成器到真框架

Major release。目标：把 SPEC 中声明式的部分真正落成结构约束（P3），让违规在结构上不可能发生，而不是靠 prompt 约定。

### 2.0.1 — 结构化 Stop Signal

将当前的 `grep NEEDS_*` 文本约定替换为 `.expero/signals/<id>.json`：

```json
{
  "type": "NEEDS_ARCH_REVIEW",
  "task": "M0-001",
  "raised_by": "builder",
  "raised_at": "2026-04-17T10:00:00Z",
  "context": "..."
}
```

- `expero.sh status` 自动解析信号目录
- 每个信号按类型分派建议的 Role
- 信号被解决后移到 `.expero/signals/resolved/`，保留审计轨迹

**动机**：P3「结构约束优于 prompt 指令」当前违反——靠文本约定，误写/漏写无法检测。

### 2.0.2 — Quality Gate 执行器

新增 `expero.sh gate <name> <task-id>`：

- `ci_passes` — 从 `config.yaml` 读 `ci_commands` 列表，执行并检查 exit code
- `adr_compliance` — 解析 `.expero/docs/review/<task>.md` 的 `Verdict` 字段
- `test_coverage` — 调用项目配置的 coverage 工具，对比里程碑基线
- `security_clean` — 检查 `.expero/docs/security/summary.md` 无 CRITICAL

**动机**：让 SPEC §4.2 的 Gate 真正成为结构约束，而非 prompt 约定。

### 2.0.3 — Artifact Schema 校验

新增 `expero.sh validate <path>`：用内置 Schema 校验 ADR / Spec / Review / Security Report 的文档结构。校验失败的文档不被视为有效 Artifact，后续 workflow 门控会失败。

### 2.0.4 — 基于 Agent SDK / subagent 的调度器

用 Claude Code subagent 或 Anthropic Agent SDK 重写 `cmd_start`：

- Role 变成 `.claude/agents/<role>.md`（subagent 定义）
- 主 agent 通过 Task 工具调度 Role，不再需要人类手动管 5-8 个终端
- Stop signal 通过 subagent 返回值 + 文件系统双写
- 里程碑边界重启成为内部机制（不再依赖人工关开终端）

**动机**：2024 年的手动多终端模式已被原生 subagent 取代。原有「Role 之间通过文件系统通信」的设计反而是 subagent 的天然实现。

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
