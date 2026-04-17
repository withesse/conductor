# examples/demo-new-product

Expero Agents project (scenario: **new-product**).

## Roles Enabled
- planner, architect, builder, verifier, critic

## Project Context
<!-- Fill in: tech stack, architecture, module map -->

## Architecture Rules
<!-- Fill in after ADRs are written -->

## Extension Points
<!-- Fill in: how to add new modules / APIs -->

## Build Commands
<!-- Fill in: build / test / lint / deploy commands -->

## Key ADRs
<!-- Will be populated as ADRs are written -->

## Expero Protocol
All framework state lives in `.expero/docs/`. Never rely on conversation context for persistence.
Status values: `todo` / `in-progress` / `completed` / `blocked`.
Stop signals: `NEEDS_ARCH_REVIEW`, `NEEDS_SPEC_CLARIFICATION`, `NEEDS_SECURITY_REVIEW`.
