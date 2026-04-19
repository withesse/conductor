# Design — MCP Integration (v1.3)

> Status: **proposed**, not implemented. Biggest remaining non-v2.0
> scope from ROADMAP. MCP = Model Context Protocol, Anthropic's
> standard for LLM-to-external-system integration.
>
> This doc exists to lock in the shape BEFORE writing any of the ~500
> LOC that a real MCP server + client touches.

---

## Two directions, each valuable independently

### Direction 1 — Conductor **as MCP server**

Expose `.conductor/docs/` as MCP resources so that Claude Code (or any
MCP-aware client) can query project state without knowing Conductor's
file layout.

```
Client query:
  mcp.list_resources()  → [
    "conductor://adr/",           # list of ADRs
    "conductor://roadmap",        # current roadmap.md
    "conductor://signals/",       # unresolved signals
    "conductor://specs/",         # specs
    "conductor://review/<task>",  # reviews by task-id
    ...
  ]

  mcp.read_resource("conductor://adr/ADR-0001")
  → Returns ADR markdown content
```

**Why useful**
- Claude Code skills/subagents could load ADRs via MCP instead of
  hard-coded paths → looser coupling to Conductor's directory layout.
- External tools (dashboards, CI, report generators) can read Conductor
  state without shelling out to `bash conductor.sh status`.
- Cross-project queries (read from two Conductor projects simultaneously)
  become natural.

**Implementation shape**
- Python (FastMCP) or Node (MCP SDK) — neither is already a dep. Pick
  Python since most Conductor users have it available; FastMCP's
  decorator style stays terse.
- `scripts/conductor-mcp-server.py` — ~150 LOC. Reads `.conductor/docs/`
  and emits resources.
- No new dependency *at CLI level* — the MCP server is opt-in, runs
  only when user enables it in `.claude/settings.json`.
- Frontmatter sync: server regenerated with each git commit (or on
  first request). State in `.conductor/docs/` is source of truth; the
  server is a read-only view.

### Direction 2 — Conductor **as MCP client**

Roles can declare MCP URIs in their "reads" list (SPEC §2.1), so a
role starts its session with external state already in context.

```yaml
# roles/_meta.json addition (proposal)
"builder/reads": [
  "file:.conductor/docs/specs/__TASK_ID__.md",
  "file:.conductor/docs/adr/",
  "mcp:github://issues?task_id=__TASK_ID__",   # external: GH issue
  "mcp:linear://ticket/__TASK_ID__"
]
```

**Why useful**
- Decouples Conductor from "state lives in files". Team using Linear
  for tickets → builder reads the Linear issue, not a copy in
  `.conductor/docs/`.
- Multi-source: builder can cross-reference the spec (file) with
  the issue thread (MCP) in the same session.
- Aligns with the SPEC's §2.1 "reads list" being flexible.

**Implementation shape**
- `_build_prompt` (CLI): expand `mcp:<uri>` → `[MCP fetch: <uri>]`
  placeholder that the agent CLI tools know to resolve. For Claude
  Code, the MCP client is already built in — subagents can be given
  MCP access via their `tools:` list.
- Subagents + Skills: add `mcp: <server>` frontmatter field, wired
  into Claude Code's existing MCP client.
- CLI fallback: if `mcp:` URIs are in the reads list and the tool is
  Codex/Gemini (no MCP client), the CLI prints a warning and
  continues with file-only reads.

---

## Scope recommendation

**Ship Direction 1 first** (server). Reasons:
1. **Less-invasive**: doesn't change role prompts, doesn't change
   CLI semantics. It's a sidecar process Claude Code can opt into.
2. **Immediate value**: Claude Code users get cross-project queries
   and structured access to Conductor state.
3. **Testable**: MCP server's behavior is deterministic (file → MCP
   response), easy to regression-test.

**Defer Direction 2** (client) to v1.4 or later. Reasons:
1. **Changes role prompts** — every role.md might need
   `reads: [mcp:...]` section, invalidating byte-regression on
   existing SKILL.md / .claude/agents/.
2. **Multi-tool headache**: Codex/Gemini MCP support varies; CLI
   fallback adds branching. Direction 1 is Claude-Code-native only,
   simpler story.
3. **Role prompts already reference `.conductor/docs/` by path** — no
   user pain yet. Client-mode MCP is an optimization, not a gap.

---

## Direction 1 — detailed design

### Resource URI scheme

`conductor://<category>/<identifier>`

| URI | Returns |
|---|---|
| `conductor://config` | `.conductor/config.yaml` (scenario, version, model tiers) |
| `conductor://roadmap` | `.conductor/docs/roadmap.md` |
| `conductor://ci-status` | `.conductor/docs/ci-status.md` |
| `conductor://adr/` | List of ADR IDs + titles |
| `conductor://adr/ADR-NNNN` | Full ADR markdown |
| `conductor://specs/` | List of spec files |
| `conductor://specs/<task-id>` | Spec markdown |
| `conductor://specs/<task-id>/test-plan` | Test plan markdown |
| `conductor://review/<task-id>` | Review markdown + verdict (extracted) |
| `conductor://security/summary` | Security summary parsed for CVSS counts |
| `conductor://security/<module>` | Per-module security report |
| `conductor://signals/` | List of unresolved signals |
| `conductor://signals/<id>-<type>` | Single signal JSON |
| `conductor://signals/resolved/` | Archived signals |
| `conductor://scenarios/` | List of scenario names + descriptions |
| `conductor://roles/` | List of role names + tier + short description |

### Tool-style MCP endpoints (beyond resources)

```
conductor.status()                    → Full status summary (same as CLI)
conductor.validate(path?)             → Run validate gate
conductor.gate(name, task_id?)        → Run any gate, return verdict + output
conductor.resolve_signal(id, type,    → Mark signal resolved + archive
                    resolved_by,
                    resolved_at)
```

These let an MCP client *mutate* Conductor state, not just read it.
Gate at least one `write` endpoint behind a `--mutable` server flag
so read-only dashboards can't accidentally close signals.

### Implementation file layout

```
scripts/
  conductor-mcp-server.py        # new, ~150 LOC
  conductor-mcp-server.md        # how to register in .claude/settings.json
.claude/
  settings.json.example       # shows the plugin entry for the server
```

### Registration (user-facing)

User adds to `.claude/settings.json`:

```json
{
  "mcpServers": {
    "conductor": {
      "command": "python",
      "args": ["scripts/conductor-mcp-server.py", "--project", "."]
    }
  }
}
```

After restart, Claude Code sees `conductor://*` resources and can pass
them to subagents.

### Dependencies

- **FastMCP** (Python) or MCP SDK — required for the server.
- **Python 3.11+** — already a widely-available dep, not adding new.
- No effect on the CLI — Codex/Gemini users unaffected.

---

## Open questions

1. **Where does the server run?**
   - Spawned per-session by Claude Code (via `"command":` in settings)?
     Clean but slow-start.
   - Long-running daemon? Complicates development; adds port
     management.
   - Recommend per-session spawn for v1.3; daemon if we see startup
     cost become painful.

2. **Cache coherence**: if the MCP server reads `roadmap.md` and
   agents write to it during the same session, does the server need
   to re-read on every query?
   - Yes. File read is cheap. Skip caching to avoid staleness bugs.

3. **Multi-project queries**: server takes `--project <path>`; what
   if a query wants to span two projects?
   - Deferred. Single-project server is enough for v1.3. Cross-project
     can run two server instances with different URIs.

4. **Security**: MCP server can read `.conductor/signals/*.json`
   including free-text `description`. Is that a PII / secrets risk?
   - No change from current state — same content is already in the
     filesystem. Server is a *read* of existing content, not a
     disclosure expansion.

5. **Ownership**: new sections in SPEC.md §5.3 for MCP resources?
   - Yes. MCP server is read-only by default; if `--mutable` is on,
     tool-style endpoints (resolve_signal, gate, validate) act on
     behalf of the Conductor role. No new role created.

---

## Non-goals for v1.3

- Not implementing Direction 2 (Conductor as MCP client). Defer to v1.4.
- Not integrating external MCP servers (GitHub issues, Linear) into
  role prompts. Defer to v1.4 with Direction 2.
- Not building a Node/TypeScript alternative server (FastMCP only).
  Adding a second impl is maintenance overhead.
- Not building an MCP proxy that forwards across projects.

---

## Implementation estimate

- `scripts/conductor-mcp-server.py`: ~150 LOC
- Resource handlers for 10 URI categories: ~15 LOC each × 10 = ~150 LOC
- Tool endpoints (status, validate, gate, resolve_signal): ~100 LOC
- Tests (Python pytest — new test file): ~100 LOC
- Docs (docs/MCP.md install + usage): ~100 LOC
- CHANGELOG / ROADMAP updates: ~20 LOC

**Total: ~620 LOC, one PR, estimate 5-6 hours.**

Larger than previous additions because it introduces a new runtime
(Python) and a new protocol surface. Worth it — MCP is the industry
pattern for LLM-system integration in 2026 and this is the cleanest
way to make Conductor first-class in that ecosystem.

---

## Decision sought (before implementation)

1. **Confirm "server first, client later"** scoping (v1.3 vs v1.4).
2. **Confirm Python/FastMCP** as the impl language (vs Node MCP SDK).
3. **Confirm `--mutable` flag** for write endpoints (or drop and only
   expose read endpoints in v1.3).

Once these three ACKs, implementation is straightforward.

---

## Non-goals (to head off scope creep)

- **A web UI for Conductor state** — MCP gives structured access; UIs
  can be built on top, but not by us.
- **MCP as replacement for `.conductor/docs/`** — file system remains
  the source of truth; MCP is a view.
- **Bidirectional sync with Linear/GitHub** — way out of v1.x scope.
  Read-only integration via Direction 2 is the line.

Referenced from ROADMAP.md §v1.3.
