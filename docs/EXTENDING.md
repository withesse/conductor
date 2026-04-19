# Extending Conductor

> Three recipes: add a role, add a scenario, add an artifact schema.

Before reading, skim [ARCHITECTURE.md](./ARCHITECTURE.md) for the file
layout. All extensions below are **data-only** — you don't touch
`conductor.sh`.

---

## Recipe 1 — Add a new role

Use when: you want a new agent persona with its own prompt (e.g. `devrel`
for community docs, `performance-engineer` for profiling work).

### Steps

1. **Write the role prompt** at `roles/<name>.md`. Two placeholders are
   substituted at `start` time:

   - `__TASK__` — either the task-id passed to `start`, or a default
     description (declared in step 3).
   - `__TASK_ID__` — either the task-id verbatim, or the literal
     `<task-id>` string (used in file-path references).

   Minimum template:

   ```markdown
   # Role: DevRel

   你的职责：社区回应、用户反馈整理、对外沟通节奏

   本次任务：__TASK__

   你的产出：
   - .conductor/docs/community/<topic>.md

   规则：
   - 不修改代码
   - 技术内容不确定时标注 [需 Architect 确认]
   ```

2. **Declare the model tier** in `conductor.sh`'s `tier_for_role()`. Choose
   one of `reasoning` / `execution` / `template`:

   ```bash
   tier_for_role() {
     case "$1" in
       architect|sentinel|archaeologist) echo "reasoning" ;;
       planner|builder|critic|scribe|devrel) echo "execution" ;;
       #                               ^^^^^^ add here
       verifier)                          echo "template" ;;
       ...
   ```

3. **Add a default task description** in `_default_task_for_role()`:

   ```bash
   _default_task_for_role() {
     case "$1" in
       ...
       devrel)  echo "整理最近 7 天的 issues / discussions，归类并建议回应顺序" ;;
       critic)  echo "" ;;    # keep empty if task-id is required
       ...
   ```

   Leave empty if you want `start <role>` without a task-id to error out
   (like `critic` does).

4. **Enable the role in at least one scenario**. Open the scenario JSON
   that should activate this role and add it to `active_roles[]` and
   (if appropriate) `extension_roles[]`:

   ```json
   {
     "name": "greenfield-library",
     "active_roles": ["planner", ..., "devrel"],
     "extension_roles": ["scribe", "sentinel", "devrel"],
     ...
   }
   ```

5. **Update `AGENTS.md`'s Role Quick Reference table** (the one copied
   by `_gen_agents_md`). Add a row with Owns / Reads / Never.

6. **Add a regression assertion** in `test-conductor.sh`:

   ```bash
   # Under T19
   assert_zero "  roles/devrel.md exists" "[ -f '$ROLES_DIR/devrel.md' ]"
   # Under T8 (model_for_role matrix)
   check devrel claude "claude-sonnet-4-6"
   check devrel codex  "gpt-5.4"
   check devrel gemini "gemini-3-flash"
   ```

7. Run `bash test-conductor.sh` — expect all assertions (including your new
   ones) to pass.

### Why these five steps (and not fewer)

`roles/*.md` is the *prompt*. `tier_for_role` is the *model selection*.
`_default_task_for_role` is the *CLI contract* (what `start <role>`
without args means). Scenarios are the *activation gate*. `AGENTS.md` is
the *ownership contract* agents rely on. Missing any of the five
produces a role that either can't be invoked, runs on the wrong model,
is invisible to scenarios, or violates ownership boundaries without
warning.

---

## Recipe 2 — Add a new scenario

Use when: your project archetype doesn't fit any of the 8 existing
scenarios (e.g. `data-pipeline`, `plugin-ecosystem`, `compliance-audit`).

### Steps

1. **Write the scenario JSON** at `scenarios/<name>.json`:

   ```json
   {
     "name": "data-pipeline",
     "description": "Batch/stream data pipeline build",
     "active_roles": ["planner", "architect", "builder", "verifier", "critic"],
     "extension_roles": [],
     "extra_dirs": [".conductor/docs/schemas", ".conductor/docs/dataflows"],
     "roadmap_template": "roadmaps/data-pipeline.md"
   }
   ```

   Fields:
   - `active_roles` — ordered list shown in `CLAUDE.md` "Roles Enabled"
   - `extension_roles` — additions to `config.yaml`'s `roles.extensions:`
     block, beyond the universal five
   - `extra_dirs` — scenario-specific subdirectories created under
     `.conductor/` at init time (full path, not just basename)
   - `roadmap_template` — relative path under `scenarios/` pointing to
     the roadmap markdown to copy into `.conductor/docs/roadmap.md`

2. **Write the roadmap template** at `scenarios/roadmaps/<name>.md`:

   ```markdown
   # Roadmap (Data Pipeline)

   ## M0 — Source Discovery

   | ID | Task | Status | Owner | Depends | Commit |
   |----|------|--------|-------|---------|--------|
   | M0-001 | Source systems inventory | todo | architect | — | |
   | M0-002 | Sample data profiling | todo | builder | M0-001 | |
   ...

   **M0 Exit Criteria**
   - [ ] All sources catalogued with schemas
   - [ ] Sample data pulled and profiled

   ---

   ## M1 — Transformation Layer
   ## M2 — Orchestration
   ```

   To share a roadmap with an existing scenario, point
   `roadmap_template` at that scenario's file — `greenfield-library.json`
   does this with `"roadmap_template": "roadmaps/new-product.md"`.

3. **Add regression assertions** in `test-conductor.sh`:

   ```bash
   # Extend the SCENARIOS variable
   SCENARIOS="new-product migration ... data-pipeline"
   ```

   The existing T2, T3, T4, T10, T23, T26 groups auto-cover any scenario
   listed in `$SCENARIOS`, including byte-level regression against the
   template you just authored.

4. Run `bash test-conductor.sh` — expect all assertions to pass.

### What you don't need to do

No `case` statement to extend. No `_gen_roadmap` branch to add. No
`_gen_conductor_config` / `_gen_claude_md` editing. The data-driven
generators handle everything from the JSON.

---

## Recipe 3 — Add a new artifact schema

Use when: a role needs to produce a new artifact type whose structure
`validate` should check (e.g. `runbook`, `postmortem`, `threat-model`).

### Steps

1. **Write the schema JSON** at `schemas/<type>.json`:

   ```json
   {
     "name": "runbook",
     "description": "Operational runbook for a service",
     "applies_to": ".conductor/docs/runbooks/<service>.md",
     "required_patterns": [
       "^# Runbook:",
       "^## Service",
       "^## Dependencies",
       "^## Common Failures",
       "^## Escalation"
     ]
   }
   ```

2. **Format patterns carefully**:
   - ERE syntax (passed to `grep -E`)
   - Use `[.]` for literal `.`, `[|]` for literal `|` — the JSON parser
     handles these correctly in multi-line array format (which the
     template above already uses)
   - `^` anchors to line start; use it to require section headings

3. **Register the path pattern** in `_classify_artifact()` (this *is* a
   bash change — the only one in this recipe, and it's a one-liner):

   ```bash
   _classify_artifact() {
     local f=$1
     case "$f" in
       */adr/ADR-*.md)             echo adr ;;
       */runbooks/*.md)            echo runbook ;;
       #                                  ^^^^^^^^ add here
       ...
     esac
   }
   ```

4. **Add assertions** in `test-conductor.sh` under T26b/c/d:

   ```bash
   # T26b
   assert_zero "  schemas/runbook.json exists" "[ -f '$SCHEMA_DIR/runbook.json' ]"

   # Good-case / bad-case validation under T15
   cat > "$TMPDIR/validate-ok/.conductor/docs/runbooks/svc-a.md" << 'RB_EOF'
   # Runbook: svc-a
   ## Service
   ## Dependencies
   ## Common Failures
   ## Escalation
   RB_EOF
   assert_zero "validate passes on valid runbook" \
       "cd '$TMPDIR/validate-ok' && bash conductor.sh validate"
   ```

5. Run `bash test-conductor.sh`.

### Why one bash line is needed

`_classify_artifact` maps a *path* to a *schema name*. The mapping
depends on naming conventions you control (e.g. `runbooks/*.md`), not on
the schema itself. This is the one piece of logic that can't live in
pure data. Everything else — the patterns, the severity, the human
description — comes from the JSON.

---

## Writing good patterns

ERE patterns for `required_patterns[]` need to balance strictness against
agent flexibility.

**Do:**
- Anchor section headings: `^## Status` ensures it's a top-level section
- Use character classes for metacharacters: `[.]` not `\.`, `[|]` not `\|`
- Allow alternatives: `(APPROVED|CHANGES_REQUESTED)` rather than two
  separate patterns (which would both need to match)

**Don't:**
- Over-specify prose: `^## Status: Accepted` would fail on "Draft" or
  "Superseded"
- Require specific list items: `- ADR-0001` won't exist in a template
- Use backreferences, lookaheads, etc. — grep ERE doesn't support them

---

## Promotion path

If your extension would benefit other Conductor users, the contribution flow:

1. Open a PR with the new role / scenario / schema JSON and markdown.
2. Extend `test-conductor.sh` with assertions that lock in the new
   artifact's structure.
3. Update `AGENTS.md`'s Role Quick Reference (for new roles) or SPEC.md's
   §5.2 / §6 (for new schemas / scenarios).

If it's project-specific, just drop the file into your project's
`.conductor/roles/` or `.conductor/scenarios/` — `_resource_root()` prefers
project-local resources over the shared source repo.

---

## Further reading

- [ARCHITECTURE.md](./ARCHITECTURE.md) — file layout, resolver logic, atomic init
- [SPEC.md](../SPEC.md) §5.2 — artifact schemas (conceptual)
- [SPEC.md](../SPEC.md) §6 — scenario catalogue (conceptual)
