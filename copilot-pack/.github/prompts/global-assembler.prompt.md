---
mode: agent
description: Template — global-side assembler (GR / APEX / MUREX) imitating the MOR exemplar. Fill {{...}} per system. Cheaper models OK.
---
Implement the **{{SYSTEM}} assembler** — pipeline phase 2, global side. Follow the MOR
exemplar's structure exactly; this is a variation on a proven pattern, not a new design.

> NOT for RISCO (local side — separate risco-assembler prompt) and NOT for MOR (the exemplar
> itself). This template is for the remaining GLOBAL-side systems: GR, APEX, MUREX.

SCOPE: assemble ONLY — read staging, write canonical. No linking, no comparison (engine job).

CONTEXT
- Reference pattern (structure, shared abstractions, error handling, tests — imitate EXACTLY):
  #file:src/Valrec.Infrastructure/Assembly/MorAssembler.cs and
  #file:tests/Valrec.IntegrationTests/Assembly/MorAssemblerTests.cs
- Reuse the shared abstractions MOR defined — IProductClassifier, IMatchKeyResolver,
  IMeasureNameResolver. Do NOT reimplement or modify them.
- Specs: #file:docs/specs/matching-rules.md, #file:docs/specs/break-keys.md,
  #file:docs/specs/file-manifest.md. DB access via ISqlConnectionFactory.

INPUT / OUTPUT
- Input staging table(s): {{STAGING_TABLES}}
  (APEX -> staging.APEX_File; MUREX -> staging.MUREX_File; GR -> staging.GR_BrazilRec +
   staging.GR_BrazilAttribution [+ staging.GR_MRCErrors optional].)
- Output: core.GlobalPosition (Side='G') + core.CanonicalMeasure (Side='G').

SYSTEM-SPECIFIC NOTES
- Products & rules for {{SYSTEM}} (from matching-rules.md):
  {{PRODUCTS_AND_RULES}}
  e.g. GR: Listed [ISIN|BookId], OTC->TransactionId, NDF->SecurityCode, Flex Options->ISIN.
       APEX: all products identity (global MatchingKey = local MatchingKey).
       MUREX: Bonds/Notes [MatchingKey|BookId] (global) , XCCY->MatchingKey.
- Match-key resolution uses Side='G' column-lists via the shared IMatchKeyResolver.
- Product classification: {{SYSTEM}} source product values via ref.ProductClassMap Side='G'.
- Multi-file assembly ({{SYSTEM}}=GR only): combine BrazilRec + BrazilAttribution to build
  positions + measures. Apply MRCErrors (optional file) per file-manifest.md IF its semantics
  are defined; if still [TBC], leave a clearly-marked application point and a failing/skipped
  test, and do NOT invent behavior.
- Single-file assembly (APEX, MUREX): the one file splits into position rows + measure rows.
- FX/unit: {{FX_NOTE}} (only apply FX if {{SYSTEM}} carries rates or the spec defines a source;
  otherwise measures carry their native Currency/Unit with FxRateApplied NULL).

SAME AS MOR (reuse exemplar approach)
- Measure names via IMeasureNameResolver (System='{{SYSTEM}}', Side='G'); store both names;
  unmapped -> throw.
- Set-based SQL; integrity checks transactional and fail-whole-assembly (orphan measure,
  unmapped product/measure, unresolved match key -> throw, roll back, write nothing).
- Idempotent per (BusinessDate, System, Division, canonical version).

TESTS (tests/Valrec.IntegrationTests/Assembly/{{SYSTEM}}AssemblerTests.cs)
Mirror the MOR test set, adapted to {{SYSTEM}}'s products:
- Happy path with exact-value assertions (positions + measures, Side='G', ResolvedMatchKey).
- One test per distinct rule shape {{SYSTEM}} has (identity / single / composite).
- Unmapped product, unmapped measure, orphan measure -> throws, nothing written.
- Idempotency.
- {{SYSTEM}}=GR: BrazilRec+Attribution combine produces expected rows; MRCErrors handling
  per its [TBC/defined] status.

ACCEPTANCE
- Build zero warnings; tests green; architecture tests green.
- Touch only: Infrastructure/Assembly/ ({{SYSTEM}} assembler), DI registration, the test
  file + fixtures. Do NOT modify shared abstractions — if one is insufficient, STOP and propose.

CONSTRAINTS
- Writes GlobalPosition (Side='G'). Reuses MOR's shared abstractions. Set-based SQL.
- No new packages. All DB access via ISqlConnectionFactory.
- If a {{SYSTEM}} source product/measure value isn't in the ref maps, or a spec detail is
  [TBC] (e.g. MRC semantics), STOP and list it — do not guess or silently widen a rule.
