---
applyTo: "tests/**"
---
# Tests

- xUnit + FluentAssertions + NSubstitute. Naming: `Method_Scenario_ExpectedOutcome`.
- Unit tests (Domain/Application): no I/O, no Testcontainers. Fast.
- Integration tests: Testcontainers SQL Server; one container per collection fixture, respawn/clean between tests. Real SQL — recon engine correctness is only provable against the real engine.
- Golden fixtures: inputs and expected outputs live in `tests/fixtures/` as files, not inline strings, when > ~20 lines. Assert exact equality on recon outputs (row-level), not just counts.
- Engine fixtures must cover: exactly-at-threshold boundary (not a break), one-tick-over (break), position-only breaks (global-only / local-only), threshold precedence (most-specific wins), and every carry-forward scenario in `docs/specs/carry-forward.md`.
- Authorization matrix tests: data-driven theory enumerating profile × endpoint from `docs/specs/authz-matrix.md`; assert both allow AND deny sides. A new endpoint without matrix coverage should fail the completeness test.
- Do not mock the database in tests of set-based SQL logic — that tests nothing.
