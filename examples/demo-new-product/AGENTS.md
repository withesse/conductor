# Agents Protocol (for non-Claude tools)

This file is the equivalent of CLAUDE.md for tools that do not auto-load
a harness config (Codex, Gemini CLI, Continue, Aider, etc.). Load it
manually at session start.

## Mandatory First Steps
1. Read CLAUDE.md
2. Read .expero/docs/roadmap.md
3. Read relevant .expero/docs/adr/ (if exists)

## Shared State Protocol
All state must be written to .expero/docs/. Do not rely on context for
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

When a role hits an issue outside its authority, it MUST halt and write
a stop signal into the Notes column (last column) of its row in
.expero/docs/roadmap.md. Example:

    | M0-001 | Auth flow | in-progress | builder | — | NEEDS_ARCH_REVIEW: JWT library undecided |

Valid signals (must be UPPERCASE with underscores):

- NEEDS_ARCH_REVIEW         — architecture question not covered by any ADR
- NEEDS_SPEC_CLARIFICATION  — spec ambiguity blocks implementation
- NEEDS_SECURITY_REVIEW     — security-relevant change requires Sentinel
- BLOCKED_BY_<task-id>      — cannot proceed until another task completes

The Conductor (human) detects pending signals via:

    bash expero.sh status
    # or manually:
    grep -E 'NEEDS_|BLOCKED_BY_' .expero/docs/roadmap.md

Resolution: the responsible role (Architect for NEEDS_ARCH_REVIEW, etc.)
handles the issue, replaces the signal with the keyword suffix _RESOLVED
(e.g. ARCH_RESOLVED), and the original role resumes.
