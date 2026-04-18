# Stop Signals

Structured alternative to the text markers in `roadmap.md`. Any role that
hits a boundary issue (`NEEDS_ARCH_REVIEW`, `NEEDS_SPEC_CLARIFICATION`,
`NEEDS_SECURITY_REVIEW`, `BLOCKED_BY_<id>`) may additionally drop a JSON
file here. `bash expero.sh status` scans this directory and groups
unresolved signals by type.

## File naming

`.expero/signals/<task-id>-<type>.json`

Example: `.expero/signals/M0-003-NEEDS_ARCH_REVIEW.json`

## Schema

```json
{
  "id":          "M0-003",
  "type":        "NEEDS_ARCH_REVIEW",
  "raised_by":   "builder",
  "raised_at":   "2026-04-17T12:00:00Z",
  "description": "JWT library choice not covered by any ADR",
  "resolved":    false,
  "resolved_by": null,
  "resolved_at": null
}
```

## Dispatch (which role handles which type)

When the Conductor sees a pending signal, these are the default
handlers. `status` surfaces them in its output when counts are > 0.

| Signal type | Handler role | Typical resolution |
|---|---|---|
| `NEEDS_ARCH_REVIEW` | architect | New ADR created; roadmap note replaced with `ARCH_RESOLVED` |
| `NEEDS_SPEC_CLARIFICATION` | planner | Spec updated; signal marked resolved |
| `NEEDS_SECURITY_REVIEW` | sentinel | Security report filed under `.expero/docs/security/` |
| `BLOCKED_BY_<task-id>` | (self-resolves when dependency completes) | Update when blocker finishes |

## Lifecycle

```
  raise           resolve            archive
  ─────           ───────            ────────
  .expero/   →    .expero/      →    .expero/
  signals/        signals/           signals/
  <id>.json       <id>.json          resolved/<id>.json
                  (resolved:true)    (full audit trail)
```

1. **Raise** — role writes `<task-id>-<type>.json` with `resolved: false`.
2. **Resolve** — handler role edits the file: `resolved: true`,
   fills `resolved_by` + `resolved_at` (UTC, ISO-8601). The file stays
   in `signals/` for status to show as "(resolved, in-place)".
3. **Archive** (optional but recommended) — move the file to
   `signals/resolved/` once the milestone closes. Keeps live
   `signals/` focused on active work while preserving audit history.

`status` counts all three states separately:
- unresolved signals trigger a warning banner
- `(resolved, in-place)` = resolved but not yet archived
- `(archived in resolved/)` = completed audit trail

## Backwards compatibility

The roadmap-text markers (`NEEDS_ARCH_REVIEW` literal in the Notes
column) still work. Structured signals are additive, not a replacement.
If a signal is recorded in both forms for the same (task-id, type),
`status` detects the overlap and notes it (avoids double-counting).
