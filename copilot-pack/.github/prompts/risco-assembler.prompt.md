---
mode: agent
description: RISCO assembler (phase 2, local side). Follows the MOR exemplar but writes core.LocalPosition and resolves local-side (asymmetric) match keys. Review carefully — not a mechanical stamp.
---
Implement the **RISCO assembler** — pipeline phase 2 for the local (RISCO) side, serving all
five RISCO feeds (RISCO_GR, RISCO_MOR_IB, RISCO_MOR_GT, RISCO_APEX, RISCO_MUREX). ONE
assembler, parameterized by feed — mirrors the single shared RiscoAdapter / staging.RISCO.

SCOPE: assemble ONLY. Read staging, write canonical rows. No linking to the global side, no
comparison — that is the recon engine (phase 3).

CONTEXT
- Reference pattern (follow its structure, shared abstractions, error handling, test style
  EXACTLY): #file:src/Valrec.Infrastructure/Assembly/MorAssembler.cs and
  #file:tests/Valrec.IntegrationTests/Assembly/MorAssemblerTests.cs
- Reuse the shared abstractions the MOR exemplar defined — IProductClassifier,
  IMatchKeyResolver, IMeasureNameResolver — do NOT reimplement them.
- Specs: #file:docs/specs/matching-rules.md, #file:docs/specs/break-keys.md,
  #file:docs/specs/file-manifest.md
- DB access via ISqlConnectionFactory.

INPUT / OUTPUT (this is what differs from MOR)
- Input: staging.RISCO (shared table, partitioned by SourceSystem). The feed being
  assembled is identified by SourceSystem (GR | MOR_IB | MOR_GT | APEX | MUREX), carried on
  AssemblyContext — process ONE SourceSystem partition per invocation.
- Output: core.LocalPosition (Side='L') + core.CanonicalMeasure (Side='L').
  RISCO is the LOCAL side — it writes LocalPosition, NOT GlobalPosition.

LOCAL-SIDE SPECIFICS (the parts the global MOR exemplar did not exercise — review these)
- Match-key resolution uses the LOCAL column-lists from match.MatchRule (Side='L'). These
  are the asymmetric targets: e.g. NDF -> SecurityCode, OTC/FX/XCCY/MM-SIG -> TransactionId,
  Listed/Futures/MM-OPEN -> composite [ISIN|BookId] or [MatchingKey|BookId], MUREX Bonds/Notes
  -> [SecurityCode|BookId]. The IMatchKeyResolver already reads these from config — verify it
  produces the local ResolvedMatchKey that will align to the global side's key for the same trade.
- Product classification: local source values come from PricingClass / PositionType (not
  global ProductType). ref.ProductClassMap Side='L' must map them to the SAME canonical
  Product names the global side uses (so the two sides match). MM-OPEN vs MM-SIG on the LOCAL
  side is determined by SourceSystem/booking origin (Open vs SIG), NOT the OP-token (that
  marker is a global-MatchingKey rule). Confirm the local MM classification path.
- LocalPosition carries the rich local-only columns (SubBook, LocalBookId, SecurityCode,
  PricingClass, AssetName, PositionType, Currency, TransactionId, FixingDate, ErrorMessage,
  SourceErrorMessage). Map them through; they are investigation context, not matching inputs.
- Error columns: carry ErrorMessage / SourceErrorMessage into LocalPosition as-is. Do NOT
  filter error-flagged rows out here — whether they participate in recon is an engine rule,
  not an assembly rule. [If file-manifest.md later defines an exclusion rule, it applies in
  the engine, not here.]

SAME AS MOR (reuse the exemplar's approach)
- Measure names via IMeasureNameResolver (System per feed's global counterpart, Side='L');
  store both SourceMeasure and CanonicalMeasure; unmapped -> throw.
- Set-based SQL (INSERT..SELECT with joins to ref/match tables); no row-by-row loops.
- Integrity, transactional, fail-whole-assembly: orphan measures, unmapped product, unmapped
  measure, unresolved match key -> throw with precise diagnostic, roll back, write nothing.
- Idempotent per (BusinessDate, SourceSystem, canonical version): delete-that-slice-then-insert.

TESTS (tests/Valrec.IntegrationTests/Assembly/RiscoAssemblerTests.cs, Testcontainers +
core/ref/match DDL + seeded rules/maps)
a. Happy path per feed: staged RISCO_MOR_IB fixture -> expected LocalPosition +
   CanonicalMeasure (Side='L') asserted exactly, incl. local ResolvedMatchKey.
b. Asymmetric key alignment: for an NDF trade, the local ResolvedMatchKey (from SecurityCode)
   equals the value the global MOR assembler produces for the same trade (from its MatchingKey)
   — assert the two keys are identical so they will match in the engine. Repeat for one
   TransactionId-based product (e.g. FX Forward / OTC).
c. Composite local key ordering (MUREX Bonds [SecurityCode|BookId]) built in the correct order.
d. Local MM-OPEN vs MM-SIG classified from booking origin, not OP-token.
e. Rich local columns (SecurityCode, TransactionId, ErrorMessage, etc.) carried through.
f. Unmapped product / unmapped measure / orphan measure -> throws, nothing written.
g. Idempotency: assemble same partition twice -> identical rows, no duplicates.
h. Feed isolation: assembling RISCO_GR does not touch RISCO_MOR_GT rows already present.

ACCEPTANCE
- Build zero warnings; all tests green; architecture tests green.
- Touch only: Infrastructure/Assembly/ (RISCO assembler; reuse existing shared abstractions),
  DI registration, the test file + fixtures. Do NOT modify the shared IProductClassifier/
  IMatchKeyResolver/IMeasureNameResolver contracts — if RISCO needs something they don't
  offer, STOP and propose the change rather than editing them unilaterally.

CONSTRAINTS
- Writes LocalPosition (Side='L'), never GlobalPosition. Reuses MOR's shared abstractions.
- Set-based SQL. No new packages. All DB access via ISqlConnectionFactory.
- Test (b) is the point of this whole component — if local and global ResolvedMatchKeys do
  NOT align for a matched trade, STOP and report; that is a matching-rules or ProductClassMap
  discrepancy to fix in config, not something to paper over in code.
