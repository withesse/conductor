# demo-new-product

Conductor project (scenario: **new-product**).

## Roles Enabled
- planner, architect, builder, verifier, critic

## Project Context

<!-- Replace these stubs with real values before starting any role. -->

- **Language / Stack**: e.g. `TypeScript + Node 20 + Postgres 16`
- **Primary module layout**: e.g. `apps/api`, `apps/web`, `packages/shared`
- **Deployment target**: e.g. `Vercel / Fly.io / self-hosted Docker`
- **External services**: e.g. `Stripe, Auth0, SendGrid`

## Architecture Rules

<!-- Summarize the load-bearing ADRs here (max 5-7 bullets). -->
<!-- Full rationale lives in `.conductor/docs/adr/`. This section is for quick agent recall. -->

- _No ADRs accepted yet. Architect will populate this after M0._

## Build Commands

<!-- Replace stubs with the exact commands agents should run. Used by Verifier and Critic. -->

- Build:    `<e.g. npm run build>`
- Test:     `<e.g. npm test>`
- Lint:     `<e.g. npm run lint>`
- Coverage: `<e.g. npm run test:coverage>`
- Deploy:   `<filled in at M3>`

## Extension Points

<!-- Document where new modules / APIs / features plug in. Update as architecture evolves. -->

- _TBD after M0 scaffold._

## Key ADRs

See `.conductor/docs/adr/`. ADRs load in numeric order; Superseded entries stop applying.

## Conductor Protocol

All framework state lives in `.conductor/docs/`. Never rely on conversation context for persistence.
Status values: `todo` / `in-progress` / `completed` / `blocked`.

Stop signals — pick one form (both is fine):
- **Text**: in the Notes column of `.conductor/docs/roadmap.md`: `NEEDS_ARCH_REVIEW`, `NEEDS_SPEC_CLARIFICATION`, `NEEDS_SECURITY_REVIEW`, `BLOCKED_BY_<task-id>`
- **Structured**: JSON at `.conductor/signals/<task-id>-<TYPE>.json` (schema in `.conductor/signals/README.md`; gets counted separately by `bash conductor.sh status`).
