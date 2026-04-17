# Agents Protocol (for non-Claude tools)

## Mandatory First Steps
1. Read CLAUDE.md
2. Read .expero/docs/roadmap.md
3. Read relevant .expero/docs/adr/ (if exists)

## Shared State Protocol
All state must be written to .expero/docs/. Do not rely on context for persistence.
Task status values: todo / in-progress / completed / blocked.
Complete tasks by updating roadmap.md task status to "completed".

## Stop Conditions
- Architecture issue not covered by ADR: write NEEDS_ARCH_REVIEW in roadmap.md, halt
- Spec ambiguity: write NEEDS_SPEC_CLARIFICATION in roadmap.md, halt
- Security concern: write NEEDS_SECURITY_REVIEW in roadmap.md, halt
