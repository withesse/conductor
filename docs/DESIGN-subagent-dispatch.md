# Design — Subagent Dispatch (v2.0.4)

> Status: **proposed**, not implemented. The biggest architectural
> decision remaining for Conductor — whether (and how) to replace the
> multi-terminal CLI pattern with Claude Code subagents.
>
> This document exists to force an explicit decision before code is
> written. Writing subagents first and then asking "should we have?"
> would be a large, expensive mistake.

---

## What "subagent dispatch" means

Claude Code's Task tool can invoke an agent defined at
`.claude/agents/<role>.md` in a **separate context window** with its
own tools, prompt, and model. The main agent waits, receives the
subagent's final message, and continues.

In Conductor terms: instead of the human opening 5 terminals
(architect, planner, builder, verifier, critic) and piping state
through `.conductor/docs/`, **one main agent** calls Task(subagent=architect)
and Task(subagent=builder) as part of a normal conversation. State
still flows through `.conductor/docs/` — subagents write files the main
agent later reads — but the human is no longer the terminal multiplexer.

**Concrete change for users**:

```
# Today (v1.x)
$ bash conductor.sh start architect         # terminal 1
$ bash conductor.sh start planner            # terminal 2
$ bash conductor.sh start builder M0-001    # terminal 3
  ...
$ bash conductor.sh restart                 # human checklist, close terminals

# v2.0.4 (proposed)
$ claude
> "Ship M0-001 end-to-end."
Main agent:
  Task(architect)  → writes ADR, returns summary
  Task(planner)    → writes spec, returns summary
  Task(builder M0-001) → writes code + tests, returns summary
  Task(verifier M0-001) → writes test plan, returns summary
  Task(critic M0-001)   → writes review, returns verdict
Main agent: "APPROVED. Here's what shipped."
```

One human turn replaces 5-8 terminal sessions.

---

## Three strategies

### Strategy A — **Keep CLI as canonical, skip subagents**

Status quo. `start` + multi-terminal remains the model. Claude Code
Skills already let Claude Code users get role-switching in one session
(see SKILLS.md), which is "subagent-lite" — same context window, but
the role prompt is swapped in based on conversation triggers.

**Pros**
- Zero new code. Zero migration cost.
- Tool-agnostic (claude/codex/gemini) preserved.
- Skills already ship the role prompts in a CC-native way.

**Cons**
- No true parallelism: one agent handling multiple roles in one
  session risks context pollution ("acting as Architect" seeps into
  Builder work).
- Doesn't use Claude Code's Task tool at all.
- Humans remain the orchestrator.

### Strategy B — **Full subagent model, deprecate multi-terminal**

Replace `bash conductor.sh start <role>` with
`.claude/agents/conductor-<role>.md` subagent definitions. Add a main
"conductor-orchestrator" agent that knows when to dispatch each role.
Codex / Gemini users lose most of the framework — what remains is
`init` + `validate` + `gate`. CLI `start` becomes a legacy shim or
gets removed.

**Pros**
- One human turn → multi-role ship. Biggest UX leap available.
- Each subagent has its own context (Architect doesn't need to
  remember Builder's 5000-token spec discussion).
- Task tool's native parallelism: verifier and critic can run
  concurrently on a completed task.
- Cleanest alignment with 2026's actual agent-dispatch primitives.

**Cons**
- **Claude-Code-only.** Codex / Gemini users lose `start` →
  they're reduced to using `roles/*.md` as plain prompts. That's a
  regression.
- Main orchestrator agent needs careful prompt engineering — it's
  the coordination layer Conductor previously outsourced to humans.
- File ownership enforcement still only at prompt level (subagents
  *could* violate ownership, same as today).
- Subagents are opinionated: each has its own model config, tools
  whitelist, permissions. Another layer of metadata to maintain.

### Strategy C — **Hybrid: CLI + subagent parallel, users pick**

Ship `.claude/agents/conductor-<role>.md` alongside the existing
`start` CLI. Users (or automation) decide per-task whether to open a
terminal or let the main agent dispatch. `roles/*.md` remains the
source of truth; subagents are a third rendering (alongside CLI
prompts and SKILL.md files).

**Pros**
- Codex / Gemini users unaffected (same as current Skills packaging).
- Claude Code users get subagent parallelism when they want it,
  manual terminals when they don't.
- Incremental: can ship one subagent at a time (start with Builder,
  add Critic, etc.) and test adoption.

**Cons**
- **Three renderings** of role prompts: CLI (via `_build_prompt`),
  Skill (via regen-skills.sh), Subagent (new, via
  regen-subagents.sh). Drift risk tripled.
- More code surface to test.
- Confusing mental model: "what's the difference between Skill and
  Subagent when both trigger on 'write an ADR'?"

---

## Recommendation: **Strategy C with phased rollout**

Reasoning:
1. Pure A stops short of the strategic value. Subagents are 2026's
   agent primitive; not using them leaves capability on the table.
2. Pure B sacrifices the tool-agnostic positioning that's one of
   Conductor's three differentiators (see README). That's the wrong
   trade — multi-tool support is a moat.
3. C preserves both. Extra renderings are testable (we already do
   byte-regression on Skills ↔ roles). Mental-model confusion is a
   docs problem, not a technical one.

### Mental model (to be written into docs/SKILLS.md / new docs/SUBAGENTS.md)

| I want to… | Use |
|---|---|
| Run role work in a **separate context window** (no pollution) | Subagent |
| Have main agent **switch perspective** mid-conversation | Skill |
| Open a **dedicated session** for a long-running task (hours) | CLI `start` |
| Run role in **Codex / Gemini** | CLI `start` |

Three valid answers per situation. "Skills and Subagents overlap" is
the cost of supporting three environments.

### Phase-1 scope (what to ship first)

1. **Subagent definitions**: `.claude/agents/conductor-<role>.md` × 8,
   generated by a new `scripts/regen-subagents.sh` from `roles/*.md`
   + `_meta.json`. Same pattern as regen-skills.sh; differs only in
   frontmatter fields (subagents need `tools:`, `model:`, etc.).
2. **`init` copies subagent definitions** into `.claude/agents/` in
   the generated project (sibling of `.conductor/`). Claude Code picks
   up `.claude/agents/` automatically when launched from the project
   directory.
3. **Byte-regression test**: `regen-subagents` output == committed
   `.claude/agents/`.
4. **Non-goal: no orchestrator agent yet.** Main agent can Task()
   individual roles directly. The "one sentence ships a milestone"
   experience is Phase-2 (when we have a purpose-built
   conductor-orchestrator agent).

### Phase-2 scope (the real UX leap)

- Orchestrator agent `.claude/agents/conductor-orchestrator.md` that
  reads roadmap.md, picks the next task, dispatches the appropriate
  role sequence, handles stop signals by re-dispatching to the right
  handler role.
- Stop signal → subagent dispatch: orchestrator reads
  `.conductor/signals/<id>-NEEDS_ARCH_REVIEW.json` and
  `Task(architect)` to resolve it. Closes the last open item in
  ROADMAP 2.0.1.

---

## Open questions

1. **Do we ship Phase-1 without Phase-2?** Yes — Phase-1 gives
   users "Task tool works out of the box" without locking us into a
   specific orchestration model. Users can experiment.

2. **What's each subagent's `tools:` list?** Proposed initial:
   - architect / planner / scribe: `Read, Write, Edit, Grep` (no Bash)
   - builder / verifier / critic / sentinel / archaeologist: `Read, Write, Edit, Grep, Bash`
   (Critic reads git diff; Builder runs tests; Sentinel runs scanners;
   Archaeologist greps extensively.)

3. **Model pinning per subagent?** Use tier from `_meta.json`, map
   to claude-opus-4-7 / sonnet-4-6 / haiku-4-5 at regen time. Users
   can override in their own subagent file if copied out.

4. **Permissions**: subagents default to conservative (no network
   tools, no external APIs) unless the role clearly needs them (e.g.
   sentinel might want a CVE-DB fetch). Decide per role in the
   regen script's metadata.

5. **Do we remove `start` after Phase-2 lands?** No. Codex and
   Gemini users keep it. Document it as "the tool-agnostic fallback".

---

## What happens to Skills after Subagents?

Skills remain useful for the **"switch perspective mid-conversation"**
case (the user didn't pre-commit to using the Task tool). Skills +
Subagents coexist:

- Skill triggers on description → main agent adopts the role's
  worldview for a few turns
- Subagent triggers on Task() call → separate context, clean return

Different UX shapes, both valuable, both rendered from `roles/*.md`.

---

## Implementation estimate

- `scripts/regen-subagents.sh`: ~120 lines (similar to regen-skills.sh)
- `.claude/agents/conductor-<role>.md` × 8: generated, ~40 lines each
- `_gen_scripts` wiring to copy subagents on init: ~15 lines
- Byte-regression test: ~20 lines
- Docs: new `docs/SUBAGENTS.md` (~100 lines) + updates to
  ARCHITECTURE.md / EXTENDING.md / CHANGELOG / ROADMAP / README

**Total Phase-1: ~400 lines, one PR, estimate ~4 hours.**

Phase-2 (orchestrator) is a separate effort, probably another
half-day, needs its own design doc before starting.

---

## Strategic note

The reason to do this at all: **Claude Code's Task tool is the 2026
primitive for "agent that launches other agents"**. Frameworks that
don't use it will eventually feel like they're fighting the tool.
Conductor's "manual multi-terminal" model was right in 2024, shakier
in 2025, and will feel dated by end-2026 if we don't move.

But moving doesn't mean abandoning multi-tool support. Strategy C
gets us there without giving up the moat.

---

## Decision sought

Before writing any code for v2.0.4:

1. **Confirm Strategy C** (or pick A / B with reasoning).
2. **Confirm Phase-1 scope** (subagent definitions only, no
   orchestrator).
3. **Defer Phase-2 until after Phase-1 dogfood**.

Once these three are ACK'd, implementation is mechanical and matches
the regen-skills.sh pattern closely.

---

## Non-goals

- Not replacing `start` CLI.
- Not requiring Claude Code — Codex/Gemini users continue unaffected.
- Not building the orchestrator in Phase-1.
- Not handling multi-project Task() (subagents scope to the current
  project's `.conductor/docs/`).

---

## Next steps (when ready to implement Phase-1)

1. Decide Strategy (C recommended).
2. Ship Phase-1 as one PR: regen script + 8 subagent files + init
   wiring + tests + docs/SUBAGENTS.md.
3. Dogfood: open Claude Code in a generated project, try `"Ship
   M0-001"` — does main agent correctly Task() the roles?
4. Based on dogfood, decide whether Phase-2 (orchestrator) needs
   its own design doc or can proceed directly.

Referenced from ROADMAP.md §2.0.4.
