# Roadmap (Java Backend — enterprise multi-module)

> Template for an enterprise Spring Boot stack: Java 17+, multi-module
> Maven, MyBatis-Plus, multi-tenant RBAC, modular business domains.
> Tailor M1 tasks to your specific business domain; M0 should stay
> close to this template.

## M0 — Skeleton (goal: empty app boots, CI green)

| ID | Task | Status | Owner | Depends | Commit |
|----|------|--------|-------|---------|--------|
| M0-001 | Maven multi-module scaffold (bom / infra / system / main-app) | todo | builder | — | |
| M0-002 | Spring Boot 3 / Java 17 boot class + application.yml | todo | builder | M0-001 | |
| M0-003 | MySQL connection via MyBatis-Plus; Flyway migration v1 | todo | builder | M0-002 | |
| M0-004 | Redis connection (Lettuce) + health indicator | todo | builder | M0-002 | |
| M0-005 | Global exception handler + unified `CommonResult<T>` DTO | todo | builder | M0-002 | |
| M0-006 | Logback + request/trace-id filter | todo | builder | M0-002 | |
| M0-007 | Maven CI: verify + jacoco + spotless | todo | builder | M0-005 | |
| M0-008 | Smoke test: `mvn spring-boot:run` + `/actuator/health` returns UP | todo | verifier | M0-007 | |

**M0 Exit Criteria**
- [ ] `mvn -B -q clean verify` passes
- [ ] `mvn spring-boot:run` boots with no stack traces
- [ ] `/actuator/health` returns `{"status":"UP"}`
- [ ] `gate all` green (artifacts_valid + ci_passes; others pass-by-default)
- [ ] No business logic yet — this is pure infrastructure

---

## M1 — Security & Multi-tenancy (goal: login + RBAC + tenant isolation)

| ID | Task | Status | Owner | Depends | Commit |
|----|------|--------|-------|---------|--------|
| M1-001 | User / Role / Permission entities + tenant_id column | todo | architect | M0 done | |
| M1-002 | JWT token issuer + parser (HS256 rotate-able secret) | todo | builder | M1-001 | |
| M1-003 | Spring Security 6 config (stateless, JWT filter) | todo | builder | M1-002 | |
| M1-004 | Login endpoint `POST /auth/login` + refresh | todo | builder | M1-003 | |
| M1-005 | `@PreAuthorize` method security with permission strings | todo | builder | M1-003 | |
| M1-006 | Tenant context ThreadLocal + MyBatis-Plus interceptor (WHERE tenant_id = ?) | todo | builder | M1-001 | |
| M1-007 | Row-level data permission (dept tree, self / self+sub / all) | todo | builder | M1-005 | |
| M1-008 | Test plan: login happy path + 5 auth edge cases | todo | verifier | M1-004 | |
| M1-009 | Security audit: token leakage, tenant bypass paths | todo | sentinel | M1-007 | |

**M1 Exit Criteria**
- [ ] Login with wrong password → 401, locked after 5 tries
- [ ] Access `/api/**` without token → 401
- [ ] User A from tenant 1 cannot read tenant 2 data (integration test)
- [ ] All queries on multi-tenant tables auto-inject tenant_id
- [ ] Sentinel report shows 0 CRITICAL findings
- [ ] `gate pr M1-009` passes

---

## M2 — Common Infrastructure (goal: reusable cross-cutting modules)

| ID | Task | Status | Owner | Depends | Commit |
|----|------|--------|-------|---------|--------|
| M2-001 | Dict module (types + items + caching) | todo | builder | M1 done | |
| M2-002 | System config module (key/value with tenant override) | todo | builder | M1 done | |
| M2-003 | File service (local / S3-compatible abstraction) | todo | builder | M1 done | |
| M2-004 | Notification: email (SMTP) + SMS (pluggable provider) | todo | builder | M1 done | |
| M2-005 | Scheduled jobs: Quartz persistent + admin UI endpoints | todo | builder | M1 done | |
| M2-006 | Operation log (AOP + mybatis-plus persist) | todo | builder | M1 done | |
| M2-007 | API audit log (request/response, bodies stripped of PII) | todo | builder | M2-006 | |
| M2-008 | Cache abstraction (Redis + local Caffeine L1) | todo | architect | M1 done | |
| M2-009 | Test plan: each M2 module's public API | todo | verifier | M2-007 | |

**M2 Exit Criteria**
- [ ] Each M2 module's API documented in `.conductor/docs/modules/<module>.md`
- [ ] Integration tests cover tenant isolation for every module
- [ ] `gate all` green
- [ ] Coverage ≥ threshold (recommend 60% for infrastructure)

---

## M3 — Code Generator (optional; skip if reusing an existing one)

| ID | Task | Status | Owner | Depends | Commit |
|----|------|--------|-------|---------|--------|
| M3-001 | Read db schema → TableInfo / ColumnInfo model | todo | architect | M2 done | |
| M3-002 | Freemarker templates: Entity / Mapper / Service / Controller / VO | todo | builder | M3-001 | |
| M3-003 | CLI: `mvn generator:gen -Dtable=sys_user` | todo | builder | M3-002 | |
| M3-004 | Front-end scaffold output (optional) | todo | builder | M3-003 | |

**M3 Exit Criteria**
- [ ] One table → full CRUD generated, compiles, tests pass

> **Skip this milestone** if you start from an existing scaffold that
> already ships a mature code generator. Record an ADR
> `ARCH_RESOLVED: use-existing-generator` and move to M4.

---

## M4 — Business Modules (each module = separate milestone group)

One business module = one milestone sub-group. Template for each:

| ID | Task | Status | Owner | Depends | Commit |
|----|------|--------|-------|---------|--------|
| M4-<mod>-001 | Domain model + ER diagram (to `.conductor/docs/modules/<mod>.md`) | todo | architect | — | |
| M4-<mod>-002 | Flyway migration for the module's tables | todo | builder | M4-<mod>-001 | |
| M4-<mod>-003 | Entities + Mappers (codegen or hand-written) | todo | builder | M4-<mod>-002 | |
| M4-<mod>-004 | Service layer with business logic | todo | builder | M4-<mod>-003 | |
| M4-<mod>-005 | Controller + OpenAPI annotations | todo | builder | M4-<mod>-004 | |
| M4-<mod>-006 | Unit + integration tests (≥70% coverage for biz code) | todo | verifier | M4-<mod>-005 | |
| M4-<mod>-007 | API contract doc in `.conductor/docs/api-contracts/<mod>.md` | todo | scribe | M4-<mod>-005 | |
| M4-<mod>-008 | Code review | todo | critic | M4-<mod>-007 | |

**Typical business module types** (pick per need):
- `mall` (product / order / cart / coupon / pay)
- `member` (profile / points / level / social login)
- `pay` (wallet / payment channels / refund)
- `crm` (customer / contract / business opportunity)
- `bpm` (Flowable workflow + form designer)
- `report` (custom reports + export)
- `ai` (LLM proxy / prompt library / cost tracking)

Do NOT start more than 2 modules in parallel. Finish, stabilize, move on.

**M4 Exit Criteria (per module)**
- [ ] `gate pr M4-<mod>-008` green (artifacts + review APPROVED + CI)
- [ ] Module-specific test plan executed
- [ ] `.conductor/docs/api-contracts/<mod>.md` exists and validates

---

## M5 — Release Preparation (goal: production deployable)

| ID | Task | Status | Owner | Depends | Commit |
|----|------|--------|-------|---------|--------|
| M5-001 | Dockerfile + docker-compose (app + mysql + redis) | todo | builder | all biz done | |
| M5-002 | Nacos config center integration | todo | builder | M5-001 | |
| M5-003 | Observability: Micrometer + Prometheus + Grafana dashboard | todo | builder | M5-001 | |
| M5-004 | Full security audit (OWASP ASVS L1) | todo | sentinel | M5-003 | |
| M5-005 | Load test: k6/gatling against main endpoints | todo | verifier | M5-003 | |
| M5-006 | Operations runbook (`docs/public/operations.md`) | todo | scribe | M5-005 | |
| M5-007 | Release checklist + go-live rehearsal | todo | planner | M5-006 | |

**M5 Exit Criteria**
- [ ] `gate all` green (all 5/5 gates pass)
- [ ] Load test: p99 < 500ms at expected traffic
- [ ] Sentinel: 0 CRITICAL / ≤ 5 HIGH with mitigations documented
- [ ] Deploy to staging, smoke test green
- [ ] Go-live approval from conductor (you)

---

## Backlog

Things explicitly deferred:
- Advanced BPM features (user-defined forms, gateway listeners)
- Multi-region deployment
- Full i18n (Chinese/English minimum for v1, other langs Backlog)
- Mobile API dedicated endpoints
- Admin SPA frontend (tracked as a separate project)

Add items here as you discover them; don't inflate M1-M5.
