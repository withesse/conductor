# Design — `gate test_coverage`

> Status: **proposed**, not yet implemented. Last of SPEC §4.2's five
> built-in gates. Deferred from v1.x because coverage tool output
> formats vary too widely to pick a single parser blindly.

---

## Goal

A fifth Quality Gate that fails a milestone when test coverage drops
below a declared threshold. Fits the existing gate contract:
exit-code-first, runs in CI, short human-readable detail on fail.

```bash
$ bash conductor.sh gate test_coverage
Gate: test_coverage
  Threshold: 80%
  Measured:  76.4% (line) in coverage/coverage-summary.json
  ✗ FAIL
```

---

## Three candidate strategies

### Strategy A — "Verifier writes the number"

Verifier role maintains `.conductor/docs/ci-status.md` with a line like:

    coverage: 76.4%

The gate greps that line. No external tool, no config schema beyond
the existing `coverage_threshold`.

**Pros**
- Zero config — just run Verifier, they write the number.
- Plays into Conductor's "state lives in `.conductor/docs/`" philosophy.
- Language-agnostic.

**Cons**
- Relies on Verifier being honest / current. Stale number passes gate.
- No source-of-truth enforcement — anyone can edit the file.
- Breaks the "gate is a deterministic check" contract: the check
  validates a human-written claim, not an independent measurement.

### Strategy B — "Run a coverage_command, parse its output"

Extend `config.yaml`:

```yaml
coverage_command: "npm test -- --coverage --coverageReporters=json-summary"
coverage_file: "coverage/coverage-summary.json"
coverage_metric: "total.lines.pct"
coverage_threshold: 80
```

Gate runs the command, then reads the metric from the output file at a
JSONPath-like location.

**Pros**
- Deterministic: the measurement is the output, not a human claim.
- Aligns with `ci_passes`'s "run a command" pattern.
- Works across languages (Jest, pytest --cov, go cover → JSON, cargo
  tarpaulin, etc. all have JSON/structured outputs).

**Cons**
- Four config fields to document and maintain.
- `coverage_metric` JSONPath parsing in bash is awk-heavy (nested keys).
- Some tools emit LCOV or XML, not JSON — need fallback strategy.

### Strategy C — "Delegate to the CI, just check the output file"

User's own CI produces coverage artifacts somewhere. The gate just
checks a threshold against a declared file + format.

```yaml
coverage_file: "coverage/coverage-summary.json"
coverage_format: "jest-json-summary"   # or "lcov", "go-cover", "cobertura"
coverage_threshold: 80
```

Each `coverage_format` is a small bash parser the gate knows how to
invoke. User runs their own `npm test --coverage` (or lets `ci_passes`
run it), then `gate test_coverage` just reads the file.

**Pros**
- Separation of concerns: `ci_passes` runs tests, `test_coverage`
  reads artifacts. Composable.
- No double-execution of the test suite.
- Adding a new language = adding a parser case, not a new gate.

**Cons**
- Per-format parsers accrete inside the project (5-6 small awks).
- User must know their CI produces the declared file.

---

## Recommendation: **Strategy C, with C→B as fallback**

C is closest to existing gate semantics (read a file, apply a check).
If the user hasn't configured `coverage_file`, fall back to B semantics
(run a `coverage_command`). If neither is configured → pass-by-default,
same as `ci_passes` / `security_clean`.

### Proposed `config.yaml` schema

```yaml
# Existing
ci_commands:
  - "npm test -- --coverage"

# New, all optional
coverage_file: "coverage/coverage-summary.json"
coverage_format: "jest-json-summary"   # see "Formats" below
coverage_threshold: 80                  # percentage, 0-100
coverage_metric: "lines"                # lines | statements | branches | functions
                                        # (default: lines)
```

### Supported `coverage_format` values (phase-1 scope)

| Format | Source | Parser target |
|---|---|---|
| `jest-json-summary` | Jest / Vitest `--coverageReporters=json-summary` | `total.<metric>.pct` |
| `pytest-coverage-json` | `pytest --cov --cov-report=json` | `totals.percent_covered` |
| `go-cover-func` | `go test -coverprofile=c.out && go tool cover -func=c.out` (last line `total:`) | parse `XX.X%` |
| `lcov-summary` | LCOV `.info` file; run through `lcov --summary` | parse `lines......: XX.X%` |

Four parsers, ~10 lines of awk each. Add more as needed (ccov, simplecov, etc.).

### Gate behavior

```
1. If coverage_threshold unset → pass by default
   ("No coverage threshold configured — gate passes by default")

2. If coverage_file + coverage_format set:
   - Parse file at format-specific path, extract metric
   - Compare to threshold
   - Pass if ≥, fail if <

3. Else if coverage_command set (Strategy B fallback):
   - Run command, capture output
   - Grep for "Total: XX.X%" or similar (per format)
   - Compare to threshold

4. On parse failure (file exists but unreadable):
   - Fail with clear error: "Could not parse <file> as <format>"
   - Never silently pass — parse errors mask regressions
```

---

## Open questions (decide before implementation)

1. **Default threshold**: none, or a conservative 60%? I lean **none**
   (explicit opt-in per gate philosophy).

2. **Trend vs. absolute**: should the gate also fail on a *drop* from
   previous coverage, not just below-threshold? Feature creep. **v2.0
   consideration**, not v1.x.

3. **Per-file coverage**: some tools let you require 100% on critical
   paths (e.g. `src/auth/`). Out of scope — this gate is project-level.

4. **When `ci_passes` runs the test suite AND produces the coverage
   file, do we make `test_coverage` depend on `ci_passes` in the
   meta-gate?** Proposal: `gate all` runs `ci_passes` first; if it
   passes, `test_coverage` runs. If `ci_passes` fails, `test_coverage`
   is skipped (reported as N/A). This matches user intuition: "if
   tests didn't pass, coverage is meaningless".

---

## Implementation estimate

- `_yaml_get_string` helper (already have for scenario JSON; extend for YAML): ~15 lines
- `_gate_test_coverage` dispatch: ~40 lines
- 4 format parsers: ~40 lines total
- Dispatch + help + `gate all` integration: ~10 lines
- Tests: ~50 lines × 4 formats = ~200 lines
- Docs (CHANGELOG, ROADMAP, SPEC §4.2 → 5/5): ~15 lines

**Total: ~300 lines, one PR, estimate 3-4 hours.**

Smaller than `ci_passes` per format but larger overall because of the
format matrix. Could ship jest + pytest first (covers 80% of
greenfield-library / new-product projects), add others incrementally.

---

## Non-goals

- **Coverage diffing across commits** — git-log / baseline comparison.
  This gate is "am I above the threshold right now", not "did coverage
  regress from main".
- **Uploading coverage reports** — codecov.io / coveralls integration
  is a CI concern, not a gate.
- **Language-specific edge cases** (e.g. Go's `-coverpkg=./...` vs
  `./...`) — documented in the format's parser comment, not handled
  by the gate.

---

## Next steps (when ready to implement)

1. Add `_yaml_get_string` helper (we have `_yaml_get_list`, need scalar).
2. Add `_gate_test_coverage` + format parser functions.
3. Extend `_gen_conductor_config` with commented coverage fields.
4. Wire to dispatch + `gate all` + help.
5. Tests for all 4 formats + pass/fail paths + parse-error behavior.
6. Update SPEC §4.2 status matrix to 5/5 (🟢 complete).
7. Update ROADMAP 2.0.2 to fully closed.

Referenced from ROADMAP.md §2.0.2 deferred list.
