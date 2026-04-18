# Claude Code Subagents

> Expero ships 8 Claude Code subagent definitions. The main agent can
> `Task(expero-<role>, prompt="...")` to dispatch any role in a
> separate context window.

This is the **Phase 1** of the v2.0.4 subagent plan (see
[DESIGN-subagent-dispatch.md](./DESIGN-subagent-dispatch.md)). Phase 2
— an orchestrator that reads the roadmap and chains role dispatches
automatically — is a separate effort.

Codex / Gemini / Aider users: subagents are **Claude-Code-specific**.
Your `bash expero.sh start <role>` workflow is unchanged.

---

## What this gives you

When you open Claude Code in a generated project, the main agent can
delegate role work to a subagent:

```
You: "Architect, what should we use for auth?"
Main agent: [invokes Task(expero-architect, "evaluate auth options")]
           → Architect subagent spins up in its own context,
             reads existing ADRs, writes a new one, returns summary.
Main agent: "Architect proposed ADR-0003 (Clerk over Auth0).
            Summary: Clerk's free tier covers MVP; migration path
            to Auth0 is clean if we outgrow it."
```

The subagent's context window is **isolated** from the main session.
That means:
- No prompt pollution (architect doesn't see 5000 tokens of Builder's
  prior work)
- Tool whitelist per role (architect can't run shell; builder can)
- Model pinned to the role's tier (architect = opus, verifier = haiku)

Parallelism works too:

```
You: "Review and test M0-001 in parallel."
Main agent: [Task(expero-critic, "review M0-001")]
           [Task(expero-verifier, "test plan for M0-001")]
            ← both run concurrently, each in its own context
```

---

## The three-layer mental model

Expero now renders each role in **three shapes**, all from `roles/*.md`:

| Layer | When to use | Tool-agnostic? |
|---|---|---|
| **CLI `start`** | Long dedicated session (hours), non-Claude tool, or you want to control terminal multiplexing | ✅ claude/codex/gemini |
| **Skills** | Main agent should **switch perspective** mid-conversation (stays in the same context) | ❌ Claude Code only |
| **Subagents** | Role work should run in a **separate context** (parallelism, isolation, or model-tier switching) | ❌ Claude Code only |

Three valid ways to ship the same role. Pick based on your session
shape:

- **"I need 5 agents running all day"** → CLI `start` in 5 terminals
- **"Let me act as Architect for a minute"** → Skill triggers on
  description
- **"Ship M0-001 — dispatch the roles in parallel"** → Subagents via
  Task tool

These compose: a project can use all three without conflict.

---

## Install / activation

Subagents are installed **per-project** at `.claude/agents/expero-*.md`.
They're auto-discovered by Claude Code when launched from the project
directory — no settings change needed.

`bash expero.sh init <project> <scenario>` copies 8 files:

```
<project>/.claude/agents/expero-architect.md
<project>/.claude/agents/expero-planner.md
<project>/.claude/agents/expero-builder.md
<project>/.claude/agents/expero-verifier.md
<project>/.claude/agents/expero-critic.md
<project>/.claude/agents/expero-sentinel.md
<project>/.claude/agents/expero-scribe.md
<project>/.claude/agents/expero-archaeologist.md
```

Each has frontmatter:

```yaml
---
name: expero-architect
description: Use when writing Architecture Decision Records…
model: claude-opus-4-7
tools: Read, Write, Edit, Grep, Glob
---
```

The body is the same role prompt that `start` and Skills use (rendered
from `roles/_base.md` + `roles/<role>.md`). `__TASK__` is resolved to
"as specified in the message from the main agent" — the subagent
expects the Task tool's `prompt:` argument to carry the task details.

---

## Tool whitelist rationale

| Role | Tools | Reasoning |
|---|---|---|
| architect | Read, Write, Edit, Grep, Glob | Writes ADRs, reads code. No shell. |
| planner | Read, Write, Edit, Grep, Glob | Maintains roadmap. No shell. |
| verifier | Read, Write, Edit, Grep, Glob | Writes test *plans*, not tests. No shell. |
| scribe | Read, Write, Edit, Grep, Glob | Writes docs. No shell. |
| builder | Read, Write, Edit, Grep, Glob, **Bash** | Runs tests, commits. Needs shell. |
| critic | Read, Write, Edit, Grep, Glob, **Bash** | `git diff HEAD~1`. Needs shell. |
| sentinel | Read, Write, Edit, Grep, Glob, **Bash** | Runs vuln scanners. Needs shell. |
| archaeologist | Read, Write, Edit, Grep, Glob, **Bash** | Extensive file traversal / grep. |

Four "scribes" (read/write only) and four "doers" (can shell out). The
split is by whether the role produces *code changes* (doers) vs
*documents* (scribes).

---

## Single source of truth (again)

Subagents are rendered from `roles/*.md` + `roles/_meta.json`. Never
edit `.claude/agents/expero-*.md` directly — your change will be
overwritten on the next regen.

To change a role:

```bash
# 1. Edit the role prompt
vim roles/architect.md

# 2. Regenerate subagent (and skills, if the change affects those too)
bash scripts/regen-subagents.sh
bash scripts/regen-skills.sh

# 3. Commit all of it
git add roles/architect.md .claude/agents/expero-architect.md \
        .claude-plugin/skills/expero-architect/SKILL.md
git commit
```

`test-expero.sh` fails if any of the three renderings drift from
`roles/*.md` — byte-level regression across CLI / Skills / Subagents.

---

## Adding a new role

Follow [EXTENDING.md](./EXTENDING.md) Recipe 1, then:

1. Add a tier + tool whitelist for the role. Pick:
   - Tier: via `roles/_meta.json` → `<role>/tier` (reasoning / execution / template)
   - Tools: edit `_tools_for_role()` in `scripts/regen-subagents.sh` —
     decide scribe (no Bash) vs doer (with Bash).

2. Run `bash scripts/regen-subagents.sh` — generates
   `.claude/agents/expero-<your-role>.md`.

3. Commit the new subagent md alongside the role.md + its
   description in `_meta.json`.

Adding a role is now: one role.md + three entries in _meta.json + one
line in `_tools_for_role` (if doer vs scribe isn't obvious from the
default). CLI help, Skills, and Subagents all pick it up automatically.

---

## Phase 2 — orchestrator (not shipped)

Tracked for v2.0.4. Adds `.claude/agents/expero-orchestrator.md` that
reads `.expero/docs/roadmap.md`, identifies the next task, dispatches
the appropriate role sequence, handles stop signals by re-dispatching
to the right handler role.

Until Phase 2 ships, the main agent is the orchestrator — you tell it
what to dispatch.

---

## Further reading

- [ARCHITECTURE.md](./ARCHITECTURE.md) — full file layout
- [SKILLS.md](./SKILLS.md) — Skills (mid-session role switching)
- [EXTENDING.md](./EXTENDING.md) — adding roles / scenarios / schemas
- [DESIGN-subagent-dispatch.md](./DESIGN-subagent-dispatch.md) — why
  Strategy C, Phase-1 scope, Phase-2 plan
- [SPEC.md](../SPEC.md) — role model (Role / Artifact / Workflow)
