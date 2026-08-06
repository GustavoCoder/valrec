---
mode: agent
description: One-time EXEMPLAR prompt — MOR assembler (phase 2). The reference pattern the other 4 assemblers imitate. Use Opus/Sonnet; hand-review fully.
---
Implement the **MOR assembler** — pipeline phase 2 for the MOR system. This is the FIRST
assembler and the reference pattern four more (GR, APEX, MUREX, RISCO) will imitate:
prioritize clarity and a clean, reusable shape over cleverness. Every structural decision
here gets copied.

SCOPE: assemble ONLY. Read MOR staging tables, write canonical rows. Do NOT link global to
local, do NOT compare, do NOT touch the recon engine — that is phase 3.

CONTEXT
- Canonical/ref/match DDL: src/Valrec.Infrastructure/Sql/core|ref|match/
- Specs (authoritative): #file:docs/specs/matching-rules.md, #file:docs/specs/break-keys.md,
  #file:docs/specs/file-manifest.md
- Rules: #file:.github/instructions/ingestion.instructions.md and sql instructions
- DB access: ISqlConnectionFactory (all connections via the factory).

INPUTS (MOR staging, populated by ingestion)
- staging.MOR_Positions, staging.MOR_Measures, staging.MOR_FXRates.
- MOR is global-side → writes core.GlobalPosition + core.CanonicalMeasure (Side='G').
  (RISCO_MOR local side is a SEPARATE assembler — not this one.)

DESIGN — define these shared abstractions (they become the assembler pattern)
1. `IAssembler` (Application): `string System { get; }`,
   `Task<AssemblyResult> AssembleAsync(AssemblyContext ctx, CancellationToken ct)` where ctx
   carries BusinessDate, Division, the canonical version, connection account.
2. Shared building blocks in Infrastructure, reused by all assemblers:
   - `IProductClassifier` — resolves (System, Side, sourceValue) → canonical Product via
     ref.ProductClassMap. Includes the MOR MM rule: money-market position → MM-OPEN if the
     global MatchingKey carries the OP token (explicit positional/delimited match per
     matching-rules.md, NOT LIKE '%OP%'), else MM-SIG. Unmapped → throw with the value listed.
   - `IMatchKeyResolver` — builds ResolvedMatchKey from match.MatchRule ColumnOrder for
     (System, Product, Side), concatenating canonicalized columns (trim, upper, '|'-join,
     ~NULL~). Missing rule → throw.
   - `IMeasureNameResolver` — source → canonical via ref.MeasureNameMap; unmapped → throw
     with names listed. Stores BOTH SourceMeasure and CanonicalMeasure.
3. Work is **set-based SQL** over staging (INSERT ... SELECT into core), not row-by-row C#.
   The classifier/resolver logic that can't be expressed in SQL should be applied via a
   join to the ref/match tables (they ARE the lookup) — prefer a SQL join to the mapping
   tables over pulling rows into C#. Reserve C# for orchestration and the OP-token predicate
   if it can't be expressed cleanly in SQL (document which).

MOR-SPECIFIC STEPS
- Positions: staging.MOR_Positions → core.GlobalPosition. Classify Product, resolve
  ResolvedMatchKey (needs Product first). Keep raw MatchingKey.
- Measures: staging.MOR_Measures joined to positions; resolve CanonicalMeasure; apply FX
  from staging.MOR_FXRates (MOR's own rates — never external); stamp FxRateApplied and the
  resulting Currency/Unit on each measure row. Write core.CanonicalMeasure Side='G'.
- Integrity (fail the whole assembly, transactional — no partial canonical state):
  every CanonicalMeasure PositionKey matches a GlobalPosition PositionKey; no unmapped
  product; no unmapped measure; no unresolved match key. On failure: throw with a precise
  diagnostic (counts + sample offending keys), roll back, write nothing.
- Idempotent per (BusinessDate, System, Division, canonical version): re-running replaces
  that slice cleanly (delete-that-slice-then-insert within the transaction).

TESTS (tests/Valrec.IntegrationTests/Assembly/MorAssemblerTests.cs, Testcontainers with
core+ref+match DDL and seed rules applied; seed the ref maps the tests need)
a. Happy path: staged MOR fixtures (positions+measures+fx) → expected GlobalPosition and
   CanonicalMeasure rows asserted exactly (values, ResolvedMatchKey, FxRateApplied).
b. MM-OPEN vs MM-SIG: one position with OP-marked MatchingKey → MM-OPEN + composite
   ResolvedMatchKey; one without → MM-SIG + its ResolvedMatchKey. Plus a SIG key with an
   incidental "OP" elsewhere → still MM-SIG (the naive-contains trap).
c. FX applied correctly: measure value × rate = stamped canonical value; rate recorded.
d. Unmapped product → assembly throws, nothing written (assert core tables empty for slice).
e. Unmapped measure name → throws, nothing written.
f. Orphan measure (no matching position) → throws, nothing written.
g. Idempotency: assemble twice → identical canonical rows, no duplicates.
h. Multi-product batch: NDF (SecurityCode rule) + FX Forward (TransactionId rule) +
   Futures (composite) in one run → each gets the correct ResolvedMatchKey shape.

ACCEPTANCE
- Build zero warnings; all tests green; architecture tests green (IAssembler + resolver
  ports in Application, implementations in Infrastructure).
- Touch only: Application/Assembly/ (ports), Infrastructure/Assembly/ (MOR assembler +
  shared classifier/resolver), DI registration, the test file + fixtures.

CONSTRAINTS
- Set-based SQL for the bulk work; no row-by-row canonicalization loops.
- No linking/comparison logic. No new packages. All DB access via ISqlConnectionFactory.
- The classifier/resolver abstractions must be MOR-agnostic (the other assemblers reuse
  them) — no MOR hardcoding inside them beyond what config/ref tables drive.
- If a spec and the staged sample data disagree (a product value not in ProductClassMap,
  a measure name not in MeasureNameMap, an OP-token format that doesn't match the sample),
  STOP and list the discrepancies instead of guessing or silently widening a rule.
