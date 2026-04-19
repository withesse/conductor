# Claude Code Skills

> Conductor ships as a Claude Code plugin. Install once, get 8 role skills
> that activate automatically when relevant.

For Codex / Gemini / Aider users: Skills are **Claude-Code-specific**.
You can continue using `bash conductor.sh start <role> <task> <tool>` — the
role prompts are identical (both forms render from `roles/*.md`). This
document only applies if you're using Claude Code.

---

## What you get

Eight skills under the `conductor-` namespace:

| Skill | Triggers on |
|-------|-------------|
| `conductor-architect` | Writing ADRs, tech choices, dependency evaluation |
| `conductor-planner` | Maintaining roadmap, sequencing milestones |
| `conductor-builder` | Implementing a specific task from a Conductor roadmap |
| `conductor-verifier` | Writing test plans, CI status maintenance |
| `conductor-critic` | Reviewing code against ADRs for a specific task |
| `conductor-sentinel` | Security audit (vulnerabilities, CVSS) |
| `conductor-scribe` | Public docs (API reference, quickstart, CHANGELOG) |
| `conductor-archaeologist` | Legacy code analysis, reverse ADRs |

Each skill loads when Claude Code's description matcher picks it based
on the user's request, the file paths open in context, and the
conversation so far.

---

## Install

```bash
# 1. Clone this repo (or add it as a submodule to your workspace)
git clone https://github.com/withesse/conductor ~/.claude/plugins/conductor

# 2. Add the plugin to Claude Code settings.json
#    (~/.claude/settings.json or project-level .claude/settings.json)
{
  "plugins": [
    "~/.claude/plugins/conductor"
  ]
}
```

Restart Claude Code; verify skills appear:

```
/skills
# Should list conductor-architect, conductor-planner, …
```

---

## How skills complement the CLI

The Conductor repo ships **both** a CLI and a Skills plugin. They do not
overlap — choose based on what Claude Code runtime gives you:

| You want to… | Use |
|---|---|
| Scaffold a new project | `bash conductor.sh init my-app <scenario>` |
| Launch a fresh session as a role (any tool) | `bash conductor.sh start <role> [task]` |
| Have Claude Code auto-activate the right role mid-conversation | Skills |
| Get project state at a glance | `bash conductor.sh status` |
| Validate artifacts / run a Quality Gate | `bash conductor.sh validate` / `bash conductor.sh gate` |

**Typical Claude Code workflow**:

```
$ bash conductor.sh init my-app new-product         # CLI: scaffold
$ cd my-app && claude                             # enter Claude Code
# inside Claude Code:
You: "We need to decide between Postgres and MySQL for user data."
Claude: [conductor-architect skill activates]
        "I'm acting as Architect. Let me first check .conductor/docs/adr/
         for any existing database decisions…"
```

No explicit `start` command — the skill's description matched the user's
question, Claude Code loaded it, and the conversation continues with
the role's rules in effect.

---

## Single source of truth

Skills are **rendered from** `roles/*.md`. Never edit
`.claude-plugin/skills/*/SKILL.md` directly — your change will be
overwritten next time someone runs regen.

To change a role prompt:

```bash
# 1. Edit the role
vim roles/architect.md

# 2. Regenerate skills
bash scripts/regen-skills.sh

# 3. Commit both
git add roles/architect.md .claude-plugin/skills/conductor-architect/
git commit
```

`test-conductor.sh` fails if skills drift from roles — same discipline as
the byte-level regression for scenarios.

---

## Adding a new role

Follow [EXTENDING.md](./EXTENDING.md)'s Recipe 1, then:

1. Add a description case in `scripts/regen-skills.sh`'s
   `_skill_description()` function — Claude Code uses this to decide
   when to activate your skill.
2. Run `bash scripts/regen-skills.sh` — emits
   `.claude-plugin/skills/conductor-<your-role>/SKILL.md` automatically.
3. Commit the new SKILL.md alongside the role.md.

The regen script auto-picks up any `roles/*.md` that isn't `_base.md`.

---

## What's not here

- **Subagents** (`.claude/agents/<role>.md`, dispatched via the Task
  tool) — tracked for v2.0.4. Skills are the "methodology" layer;
  subagents are the "parallel execution" layer. Skills alone let one
  main agent switch between role perspectives; subagents let multiple
  roles run concurrently in isolated contexts.
- **Custom slash commands** — v1.x focus is the role layer. If
  `/ship-task M0-001` semantics emerge as valuable, add them later.

---

## Further reading

- [ARCHITECTURE.md](./ARCHITECTURE.md) — file layout of the whole project
- [EXTENDING.md](./EXTENDING.md) — adding roles / scenarios / schemas
- [SPEC.md](../SPEC.md) — the underlying role model (Role / Artifact / Workflow)
