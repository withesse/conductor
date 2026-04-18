# Architecture

> How Expero Agents is laid out, and why.

This document describes the **physical layout** of the codebase after v1.2's
data/code separation. For the conceptual model (roles, artifacts, workflow),
see [SPEC.md](../SPEC.md). For how to extend the system, see
[EXTENDING.md](./EXTENDING.md).

---

## One-line summary

> `expero.sh` is a scaffolding script. `roles/`, `scenarios/`, `schemas/` are
> data. Every generated project carries its own copy of the data so it can
> operate independently of the source repo.

---

## Source repo layout

```
expero-agents/
├── expero.sh                   # CLI + generators + dispatch
├── test-expero.sh              # 370-assertion regression suite
│
├── roles/                      # Role prompts (data)
│   ├── _base.md                # Shared preamble for all roles
│   ├── architect.md            # Individual role prompt templates
│   ├── planner.md              # …with __TASK__ / __TASK_ID__ placeholders
│   ├── builder.md
│   ├── verifier.md
│   ├── critic.md
│   ├── sentinel.md
│   ├── scribe.md
│   └── archaeologist.md
│
├── scenarios/                  # Scenario definitions (data)
│   ├── new-product.json        # { active_roles, extension_roles,
│   ├── migration.json          #   extra_dirs, roadmap_template }
│   ├── refactor.json
│   ├── legacy-analysis.json
│   ├── security-audit.json
│   ├── tech-docs.json
│   ├── multi-service.json
│   ├── greenfield-library.json
│   └── roadmaps/               # Roadmap templates referenced by JSON
│       ├── new-product.md      # (greenfield-library.json also points here)
│       ├── migration.md
│       ├── refactor.md
│       ├── legacy-analysis.md
│       ├── security-audit.md
│       ├── tech-docs.md
│       └── multi-service.md
│
├── schemas/                    # Artifact schemas (data)
│   ├── adr.json                # { required_patterns: [...ERE...] }
│   ├── radr.json
│   ├── spec.json
│   ├── test-plan.json
│   ├── review.json
│   ├── security.json
│   └── security-summary.json
│
├── SPEC.md                     # Framework specification
├── README.md                   # Entry point
├── ROADMAP.md                  # Version plan
├── CHANGELOG.md                # Release notes
├── LICENSE                     # CC0 1.0
└── examples/                   # Snapshot of a default init output
    └── demo-new-product/
```

### Why the split

| Concern | Before v1.2 | After v1.2 |
|---|---|---|
| Add a new role | Edit `_build_prompt()` heredoc | Drop a file in `roles/` |
| Add a new scenario | Edit 3 `case` statements | Drop JSON + md in `scenarios/` |
| Add a new artifact schema | Edit `_validate_artifact()` case | Drop JSON in `schemas/` |
| Change a role prompt | Multi-line heredoc with bash escaping | Plain markdown diff |
| Reuse a roadmap template | Couldn't | Multiple scenarios can reference one template (`greenfield-library.json` → `new-product.md`) |

---

## Generated project layout

After `bash expero.sh init my-app new-product`:

```
my-app/
├── expero.sh                   # Copy of the source script
├── CLAUDE.md                   # Harness config (auto-loaded by Claude Code)
├── AGENTS.md                   # Same, for non-Claude tools
├── CHANGELOG.md                # Scribe-owned (SPEC §5.3)
├── .gitignore
│
├── .expero/
│   ├── config.yaml             # version, scenario, model tiers
│   │
│   ├── docs/                   # Where agents write Artifacts
│   │   ├── roadmap.md          # Copied from scenarios/roadmaps/*.md
│   │   ├── ci-status.md
│   │   ├── adr/                # [architect]
│   │   ├── specs/              # [planner + architect + verifier]
│   │   ├── review/             # [critic]
│   │   ├── security/           # [sentinel]    (only if scenario enables)
│   │   ├── public/             # [scribe]      (ditto)
│   │   ├── legacy/             # [archaeologist] (legacy-analysis only)
│   │   └── reverse-adr/        # [archaeologist] (legacy-analysis only)
│   │
│   ├── signals/                # Structured stop signals (v1.2)
│   │   ├── README.md           # Signal schema + lifecycle
│   │   └── *.json              # Per-signal files (created by agents)
│   │
│   ├── roles/                  # Copy of source roles/
│   ├── scenarios/              # Copy of source scenarios/
│   │   └── roadmaps/
│   └── schemas/                # Copy of source schemas/
```

The presence of `.expero/roles/`, `.expero/scenarios/`, `.expero/schemas/`
inside a project makes that project a **valid install** — you can run
`bash expero.sh init sub-project new-product` from inside it without the
original source repo being reachable.

---

## Resource resolution (`_resource_root`)

`expero.sh` looks up `roles/` / `scenarios/` / `schemas/` via a three-level
lookup, in order:

```
1. Current working directory has .expero/roles/    → use .expero/
   (agent running `start`, `status`, `validate` from inside a project)

2. Script's sibling has .expero/roles/             → use $script_dir/.expero/
   (sub-init launched from inside a detached project — project copied
    somewhere without its source repo)

3. Script's sibling has roles/ directly            → use $script_dir/
   (running from a clone of the source repo)
```

If none match, `expero.sh` refuses to start. This resolver is the reason a
generated project works the same whether invoked from its own directory, from
above it, or from anywhere (as long as `EXPERO_SCRIPT_PATH` is correctly
resolved at load time — which happens before any `cd`).

---

## Atomic init

`cmd_init` stages all generation in a **sibling** `mktemp` directory (same
filesystem as the target, so `mv` is guaranteed atomic) and commits via
`mv` only after every generator succeeds:

```
init my-app new-product
  │
  ├─ mktemp -d /parent/.expero-init.XXXXXX  ← staging
  ├─ mkdir -p staging/.expero/{docs/*, signals, …}
  ├─ cd staging
  ├─ _gen_expero_config                     ← reads scenarios/*.json
  ├─ _gen_claude_md
  ├─ _gen_agents_md
  ├─ _gen_roadmap                           ← cp scenarios/roadmaps/*.md
  ├─ _gen_ci_status
  ├─ _gen_changelog
  ├─ _gen_signals_readme
  ├─ _gen_scripts                           ← copies expero.sh + roles/
  │                                           + scenarios/ + schemas/
  ├─ _gen_gitignore
  ├─ cd parent
  └─ mv staging my-app                      ← atomic commit
```

On any failure (generator error, SIGINT, disk full), an `EXIT` trap removes
staging and the target path is never partially created.

---

## Template substitution model

Role prompts use two placeholders that `_build_prompt` substitutes at
`start` time:

| Placeholder | Meaning | Fallback when `task-id` missing |
|---|---|---|
| `__TASK__` | Human-readable task description | Per-role default (e.g. "检查所有 NEEDS_ARCH_REVIEW 标记") |
| `__TASK_ID__` | Literal task-id string | `<task-id>` placeholder (so file paths like `specs/<task-id>.md` render naturally) |

**Example** (roles/builder.md):

```markdown
# Role: Builder
本次任务：__TASK__

读取必需：
- .expero/docs/specs/__TASK_ID__.md（如存在）
```

Rendered with `start builder M0-001`:

```markdown
本次任务：M0-001

读取必需：
- .expero/docs/specs/M0-001.md（如存在）
```

Rendered with `start builder` (no task-id):

```markdown
本次任务：实现 roadmap 中第一个状态为 todo 的任务

读取必需：
- .expero/docs/specs/<task-id>.md（如存在）
```

**Critic is the exception** — task-id is required, and `_build_prompt`
errors out if missing.

---

## Custom JSON parser

`expero.sh` includes a minimal awk-based JSON reader (no `jq` dependency):

- `_json_get_string FILE KEY` — extract `"key": "value"`
- `_json_get_bool FILE KEY` — extract `"key": true|false`
- `_json_get_array FILE KEY` — extract `"key": [...]`, one item per line;
  supports both single-line (`["a", "b"]`) and multi-line arrays

**Array format rule**: if items contain `[` or `]` (e.g. ERE patterns like
`[0-9]+` in `schemas/*.json`), use multi-line format. The parser's
single-line path cannot distinguish outer `[]` from inner `[]`; the
multi-line path reads one quoted string per line and is immune.

---

## Test layout

`test-expero.sh` contains 370 assertions across 29 groups:

- **T1–T9** — original v1.0 coverage (help, init, scenarios, status, start)
- **T10–T18** — v1.2 basics (changelog, signals, init atomicity, validate)
- **T19–T22** — role extraction regression (PR1)
- **T23–T27** — scenario extraction regression (PR2) — includes **byte-level
  regression** comparing generated `roadmap.md` / `config.yaml` / `CLAUDE.md`
  against pre-refactor baseline
- **T26b–T26d** — schema extraction regression (PR3) — includes parser
  regression for `[0-9]` / `[.]` / `[|]` in ERE patterns

Run: `bash test-expero.sh`. All assertions must pass before any commit.

---

## What's deliberately not in `expero.sh`

- **Role dispatch logic** — each `start` invocation is a plain shell
  `exec`, no orchestration. See [SPEC §4](../SPEC.md) for why.
- **Artifact enforcement beyond schema validation** — `validate` checks
  *structure*, not *content*. Semantic review is the Critic role's job.
- **Signal auto-dispatch** — `status` reports unresolved signals, but the
  Conductor (human) decides which role handles them. Automated dispatch
  is tracked for v2.0.1.

---

## Further reading

- [SPEC.md](../SPEC.md) — conceptual model (Role, Artifact, Workflow, …)
- [EXTENDING.md](./EXTENDING.md) — how to add a role / scenario / schema
- [ROADMAP.md](../ROADMAP.md) — what's coming in v1.3 / v2.0
