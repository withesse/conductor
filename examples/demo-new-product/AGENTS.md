# Agents Protocol (for non-Claude tools)

This file is the equivalent of CLAUDE.md for tools that do not auto-load
a harness config (Codex, Gemini CLI, Continue, Aider, etc.). Load it
manually at session start.

## Mandatory First Steps
1. Read CLAUDE.md
2. Read .conductor/docs/roadmap.md
3. Read relevant .conductor/docs/adr/ (if exists)

## Shared State Protocol
All state must be written to .conductor/docs/. Do not rely on context for
persistence. Task status values: todo / in-progress / completed / blocked.
Complete tasks by updating roadmap.md task status to "completed".

## Role Quick Reference

Every role has a fixed set of files it may write (Owns), must read on
start (Reads), and must never touch (Never). Violating these boundaries
is a structural error, not a style issue.

| Role          | Owns (write)                              | Reads (start-up)                      | Never                          |
|---------------|-------------------------------------------|---------------------------------------|--------------------------------|
| planner       | vision.md, roadmap.md, specs/*.md         | adr/*                                 | code                           |
| architect     | adr/*, gap-analysis.md                    | roadmap.md                            | code, reviews                  |
| builder       | code; roadmap status field for own task   | adr/*, specs/*, specs/*-test-plan.md  | other roles' docs              |
| verifier      | specs/*-test-plan.md, ci-status.md        | specs/*, code                         | non-test code                  |
| critic        | review/*.md                               | adr/*, specs/*, git diff              | code                           |
| sentinel      | security/*.md                             | code, adr/*                           | code                           |
| scribe        | public/*.md, CHANGELOG.md                 | adr/*, specs/*, code (public API)     | technical decisions            |
| archaeologist | legacy/*.md, reverse-adr/*                | code                                  | code modifications             |

Full ownership matrix: see SPEC.md §5.3.

## Stop Signal Syntax

When a role hits an issue outside its authority, it MUST halt and record
a stop signal. Two forms are supported — pick one, or record both for
belt-and-braces.

### Form A: Text marker in roadmap.md (always supported)

Append the signal keyword to the Notes column (last column) of the row:

    | M0-001 | Auth flow | in-progress | builder | — | NEEDS_ARCH_REVIEW: JWT library undecided |

Valid signals (UPPERCASE with underscores):

- NEEDS_ARCH_REVIEW         — architecture question not covered by any ADR
- NEEDS_SPEC_CLARIFICATION  — spec ambiguity blocks implementation
- NEEDS_SECURITY_REVIEW     — security-relevant change requires Sentinel
- BLOCKED_BY_<task-id>      — cannot proceed until another task completes

### Form B: Structured JSON in .conductor/signals/ (preferred for rich context)

Create `.conductor/signals/<task-id>-<TYPE>.json`:

    {
      "id":          "M0-001",
      "type":        "NEEDS_ARCH_REVIEW",
      "raised_by":   "builder",
      "raised_at":   "2026-04-17T12:00:00Z",
      "description": "JWT library choice not covered by any ADR",
      "resolved":    false,
      "resolved_by": null,
      "resolved_at": null
    }

Full schema in `.conductor/signals/README.md`. Structured signals survive
roadmap edits, carry a full description and timestamp, and are counted
separately in `status`.

### Detection + resolution

    bash conductor.sh status                    # groups both forms
    bash conductor.sh restart                   # warns at milestone boundary

Resolution:
- Text: replace `NEEDS_ARCH_REVIEW` with `ARCH_RESOLVED` (etc.) in the row.
- JSON: set `"resolved": true` + fill `resolved_by` / `resolved_at`.

The Conductor (human) routes signals to the responsible role:
Architect for NEEDS_ARCH_REVIEW, Planner for NEEDS_SPEC_CLARIFICATION,
Sentinel for NEEDS_SECURITY_REVIEW.
