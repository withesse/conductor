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

Resolution: set `resolved: true`, fill `resolved_by` + `resolved_at`.
`status` treats resolved signals as informational; unresolved signals
trigger a warning.

## Backwards compatibility

The roadmap-text markers (`NEEDS_ARCH_REVIEW` literal in the Notes
column) still work. Structured signals are additive, not a replacement.
