---
mode: agent
description: Implement engine logic to make committed golden-fixture tests pass (tests are the spec)
---
Make the failing tests in **{{TEST_CLASS}}** pass by implementing **{{COMPONENT}}**.

The tests and their fixtures ARE the specification. Do not modify tests or fixtures — if you believe a fixture is wrong, stop and say so instead of changing it.

CONTEXT
- Failing tests: #file:tests/Valrec.IntegrationTests/Engine/{{TEST_CLASS}}.cs
- Fixtures: tests/fixtures/engine/{{FIXTURE_FOLDER}}/
- Rules: #file:docs/specs/{{SPEC}}.md
- Existing engine entry point / SQL location: #file:src/Valrec.Infrastructure/Engine/{{ENTRY_POINT}}

CONSTRAINTS
- Matching/aggregation set-based SQL only (see sql instructions). No row-by-row processing in C#.
- Threshold resolution must stamp ThresholdApplied on every result row.
- Preserve run immutability: new RunId + IsLatest flip; never UPDATE existing recon.Result rows.
- Touch only: {{ALLOWED_FILES}}.

DONE WHEN
- `dotnet test --filter {{TEST_CLASS}}` fully green; no other test regresses.
