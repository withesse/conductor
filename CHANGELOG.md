# Changelog

All notable changes to Expero Agents are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and the project adheres to Semantic Versioning.

## [Unreleased]

### Added
- `expero.sh gate <name> [task-id]` — Quality Gate executor (SPEC §4.2).
  Three built-in gates shipped, plus a meta-gate:
  - `artifacts_valid` — every classified artifact passes its schema.
    Delegates to `cmd_validate` in a subshell so nested `exit 1`
    doesn't escape the harness.
  - `adr_compliance <task>` — Critic's review at
    `.expero/docs/review/<task>.md` exists and its `## Verdict`
    section contains `APPROVED` (not `CHANGES_REQUESTED`, not missing).
  - `security_clean` — security summary contains zero
    `| CRITICAL |` rows. Passes-by-default when no summary exists
    (no audit run yet).
  - `all [task]` — runs every applicable built-in gate, tallies
    pass/fail, exits non-zero on any failure. Reports counts in the
    summary line.
  Gates are exit-code-first (designed for `&& deploy` in CI) with
  short human-readable details. Two gates (`ci_passes`, `test_coverage`)
  intentionally deferred to v2.0.2 — see ROADMAP for rationale.
- `help` becomes data-driven and project-aware: Scenarios and Roles
  sections now read from `scenarios/*.json` (description field) and
  `roles/*.md` respectively. Adding a new scenario or role causes it
  to appear in `help` automatically, fulfilling EXTENDING.md's promise.
  When run inside a project, `help` additionally shows a `Current
  project` block with scenario name and active_roles.
- `start` now warns (doesn't fail) when the role is not in the current
  scenario's `active_roles`. Surfaces scenario-boundary mismatches
  without removing the Conductor's ability to override.
- `restart` now warns on pending stop signals at milestone boundary
  (roadmap.md text markers + unresolved `.expero/signals/*.json`),
  reporting per-form counts. Warning only — does not block restart.
- `restart` "Next steps" lists the current scenario's `active_roles`
  instead of the hardcoded universal-five sequence. Correctly suggests
  `start sentinel` for security-audit instead of the nonexistent
  `start critic`, for example.
- `init` "Next steps" suggests the scenario's first `active_role`
  instead of always `architect`.
- `status` emits a dedup note when a signal is recorded in both forms
  for the same (task-id, type) pair, preventing the "I have twice as
  many outstanding issues as I actually do" misreading.
- `status` hint: when `.expero/signals/` is absent (pre-v1.2 projects),
  points users at `signals/README.md`.
- `validate` success message now states how many files were skipped
  for lacking a schema: "All classified artifacts valid (N skipped)".
- `roles/_base.md` preamble now tells every role to check
  `.expero/signals/*.json` at start, and documents both text and JSON
  signal forms (pick one, both is fine).
- AGENTS.md Stop Signal section now documents the structured JSON
  form (Form B) alongside the existing text-marker form (Form A).
  Previously only Form A was documented, despite JSON signals being a
  v1.2 feature.

### Changed
- `cmd_start` validates `critic` requires task-id up-front. Previously
  the misleading "Starting critic…" info line printed before
  `_build_prompt` surfaced the real error. Now the error is the first
  line and no tool is invoked.
- `docs/ARCHITECTURE.md` — describes the post-refactor layout:
  `expero.sh` = scaffolding, `roles/` + `scenarios/` + `schemas/` =
  declarative data, `.expero/*` = self-contained project copy. Covers
  the three-level `_resource_root` resolver, atomic init, template
  substitution, and the custom JSON parser's array format rules.
- `docs/EXTENDING.md` — three cookbook recipes: add a role, add a
  scenario, add an artifact schema. Each lists every file to edit and
  every test assertion to add; "add a scenario" is now data-only (no
  `expero.sh` edit).
- `schemas/` top-level directory: 7 artifact schemas as JSON
  (`adr.json`, `radr.json`, `spec.json`, `test-plan.json`, `review.json`,
  `security.json`, `security-summary.json`). Each declares `name`,
  `description`, `applies_to`, and `required_patterns[]` (ERE patterns
  checked by `validate`). Replaces the 80-line `case` block inside
  `_validate_artifact()` — adding a new artifact type no longer requires
  shell changes. Patterns use `[.]` / `[|]` character classes instead
  of `\.` / `\|` for parser friendliness.
- `init` copies `schemas/` into `.expero/schemas/`, completing the
  roles/ + scenarios/ + schemas/ self-containment trio.
- `_json_get_array` now handles both single-line and multi-line array
  formats. Multi-line is required for arrays whose items contain `[`
  or `]` (ERE patterns); single-line still works for simple string
  arrays (scenarios/*.json).
- `scenarios/` top-level directory: 8 scenario definitions as JSON
  (`new-product.json`, `migration.json`, …) plus `scenarios/roadmaps/`
  holding 7 roadmap templates as plain Markdown. Previously hardcoded
  as a 170-line `case` + heredoc block inside `_gen_roadmap()` plus
  smaller case branches in `_gen_expero_config()` and `_gen_claude_md()`.
  All three generators now read scenario data from JSON.
- Each `scenarios/<name>.json` declares: `name`, `description`,
  `active_roles[]` (display-ordered list for `CLAUDE.md`),
  `extension_roles[]` (config.yaml extensions beyond the universal five),
  `extra_dirs[]` (scenario-specific `.expero/docs/` subdirs to create),
  and `roadmap_template` (path to a markdown file in
  `scenarios/roadmaps/`). `greenfield-library.json` explicitly shares
  `new-product.md` as its template — the coupling is now visible.
- `_json_get_array` helper: single-line array parser in awk, zero
  external dependencies (no `jq`). Consistent with existing
  `_json_get_string`/`_json_get_bool`.
- `EXPERO_SCRIPT_PATH` global: absolute path to `expero.sh`, resolved
  once at load time before any `cd`. Replaces ad-hoc `$0` resolution
  inside `cmd_init` and enables `_resource_root()` to work correctly
  after staging-dir `cd`.
- `init` copies `scenarios/` (and `roadmaps/`) into
  `.expero/scenarios/`, mirroring the roles/ copy pattern. A generated
  project is now itself a valid "install": you can `cd myproject && bash
  expero.sh init subproject new-product` without the source repo.
- `_resource_root()` learned a third lookup path: `EXPERO_SCRIPT_PATH`'s
  sibling `.expero/roles/` (project-copy install) alongside the existing
  project-cwd and source-repo branches.
- `roles/` top-level directory holding the 8 role prompts as plain
  Markdown (`architect.md`, `planner.md`, …, `archaeologist.md`) plus a
  shared `_base.md` preamble. Previously hardcoded as bash heredocs
  inside `_build_prompt()`; now editable without touching shell code
  and diff-reviewable without heredoc-escaping noise. Uses `__TASK__`
  and `__TASK_ID__` placeholders for per-invocation substitution.
- `init` copies the source `roles/` directory into the generated
  project at `.expero/roles/`. Projects are now self-contained: running
  `expero.sh start <role>` no longer requires the source repo to be
  reachable.
- `_resource_root()` helper: locates `roles/` by preferring project-local
  `.expero/roles/` before falling back to the script's source directory.
  Makes it possible to override role prompts per-project without forking
  the shared script.
- `expero.sh validate [path]` — artifact schema validator covering the 7
  artifact types declared in SPEC §5.2 (ADR, reverse ADR, spec,
  test-plan, review, security report, security summary). Reports
  missing sections per file, exits non-zero on any failure.
- Structured stop signals at `.expero/signals/*.json` — JSON-based
  alternative to roadmap text markers. `status` scans the directory,
  groups unresolved signals by type, and counts resolved ones as
  informational. Schema documented in the generated
  `.expero/signals/README.md`. Backwards-compatible with the existing
  roadmap text markers (both detectors run).
- `CHANGELOG.md` is now generated by `init` (Scribe owns it per
  SPEC §5.3); previously missing from the scaffold.
- `init` prints `validate` in next-steps guidance; `help` documents
  the `task-id` charset contract and the new `validate` command.
- Regression tests: +55 assertions (T10–T18) covering CHANGELOG
  generation, signals dir, refuse-overwrite, unknown-scenario rejection,
  task-id validation, grep-boundary miscount, validate exit codes,
  structured-signal parsing, set-u robustness, and help-line content.

### Changed
- `_validate_artifact()` reads required section patterns from
  `schemas/<type>.json` instead of a hardcoded bash `case`. Missing
  schema file now produces a dedicated error rather than silently
  passing with zero patterns.
- Scenario validation in `init` moved from a hardcoded `case` branch to
  file-existence check (`scenarios/<name>.json`). Adding a new scenario
  no longer requires editing `expero.sh`.
- `_gen_roadmap()` shrunk from 166 lines (9-way `case` + 7 heredocs) to
  a 15-line `cp` of the JSON-declared template file. Byte-for-byte
  identical output for all 8 scenarios verified by new T26.
- `_gen_expero_config()` and `_gen_claude_md()` build their
  scenario-specific blocks by iterating JSON arrays instead of per-case
  fallthrough.
- `expero.sh` now runs under `set -euo pipefail` (was `set -e`).
  Undefined-variable access is now an error, not a silent empty string.
- `init` is atomic: generation stages in a sibling `mktemp` dir on the
  same filesystem and commits via `mv`. On any failure (generator
  error, SIGINT, disk full) the EXIT trap removes staging, leaving the
  target path untouched. Previously partial failures left a
  half-initialized project that subsequent `init` runs couldn't recover.
- `init` refuses an existing target and rejects unknown scenarios before
  any filesystem side effect.
- `start` rejects `task-id` values containing shell metacharacters.
  Allowed charset: `[A-Za-z0-9._-]+`. Prevents prompt-context pollution
  and downstream grep/path breakage.
- `model_for_role` error messages distinguish "unknown role" from
  "unknown tool" and include the role name in the tool-error case.
- Task-status counting in `status` uses pipe-boundary regex
  (`\|[[:space:]]+todo[[:space:]]+\|`) instead of `grep -F "| todo "`.
  Prevents miscounting roadmap rows whose task *title* contains a
  status keyword (e.g. "cleanup todo list" marked `completed`).
- `scenario` extraction in `status` uses a single `awk` call instead of
  `grep | awk`, making it pipefail-safe.

### Fixed
- With `set -u`, `cmd_start`, `_count_files`, and `_build_prompt` no
  longer abort on optional arguments; they use explicit `${N:-}`
  defaults.
- Role-name title-casing in the role preamble ("你是 Architect。") now
  uses a portable `awk`-based helper. The previous `${role^}` bash-4
  expansion silently no-op'd under macOS's default bash 3.2, shipping
  lowercase role names in the prompt header; this path was never
  covered by the test suite and only surfaced on real `start` invocations.

## [1.0.0] — 2026-04-17

Initial public release.

### Added
- `SPEC.md` — full framework specification (10 sections, 5 core
  abstractions, 8 roles, 8 scenarios, implementation status matrix)
- `README.md` — methodology overview, quick start, mixing examples
- `expero.sh` — CLI bootstrap: `init`, `start`, `status`, `restart`, `help`
- Multi-tool support in `expero.sh start`:
  - claude (Claude 4.7 / 4.6 / 4.5)
  - codex (OpenAI GPT-5.4 / 5.4-pro / 5.4-mini)
  - gemini (Gemini 3.1 Pro / 3 Flash / 3.1 Flash-Lite)
- Role-to-tier mapping (Reasoning / Execution / Template) applied
  consistently across all three providers
- `test-expero.sh` — regression test suite (156 assertions across 9
  groups, including heredoc-leak and template-stub regression guards)
- `ROADMAP.md` — v1.1 doc cleanup, v1.2 ecosystem integration (Skills,
  MCP), v2.0 structural enforcement (JSON stop signals, gate executor,
  schema validator, subagent-based scheduler), explicit non-goals
- Eight scenario templates: `new-product`, `migration`, `refactor`,
  `legacy-analysis`, `security-audit`, `tech-docs`, `multi-service`,
  `greenfield-library`
- `examples/demo-new-product/` — snapshot of a default `new-product`
  init output
- Generated `CLAUDE.md` ships with concrete starter content (stack /
  build commands / architecture-rule placeholders) instead of bare
  `<!-- Fill in -->` comments
- Generated `AGENTS.md` includes an 8-row Role Quick Reference table
  (Owns / Reads / Never) and a Stop Signal Syntax section for non-Claude
  tools (Codex, Gemini CLI, Aider, etc.)
- `LICENSE` — CC0 1.0 Universal Public Domain Dedication

[Unreleased]: https://github.com/withesse/expero-agents/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/withesse/expero-agents/releases/tag/v1.0.0
