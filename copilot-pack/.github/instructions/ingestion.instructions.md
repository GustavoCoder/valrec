---
applyTo: "src/Valrec.Infrastructure/Ingestion/**"
---
# Ingestion: adapters & assemblers

## Adapters (one per file type)
- Implement `ISourceAdapter` (Application layer): `System`, `FileType`, `CanHandle(FileDescriptor)`, `IAsyncEnumerable<StagedRecord> ReadAsync(Stream, CancellationToken)`.
- **RISCO exception: exactly ONE `RiscoAdapter`** serves all five feeds (RISCO_GR, RISCO_MOR_IB, RISCO_MOR_GT, RISCO_APEX, RISCO_MUREX — identical layout). `SourceSystem` is stamped on every record from `AdapterContext` (watcher config), never parsed or inferred from file content. Never create per-system RISCO adapters or per-system RISCO staging tables.
- Adapters are dumb per-file parsers. NO cross-file logic, NO FX conversion, NO business rules — that belongs in assemblers.
- Stream, never buffer: read line-by-line / record-by-record, `yield return`. Constant memory regardless of file size. Never `ReadToEnd()`.
- Culture: Brazilian files may use comma decimal separators and dd/MM/yyyy dates. Parse with explicit `CultureInfo` per adapter config — never `CultureInfo.CurrentCulture`.
- Malformed record → collect into a bounded error list (with line number and raw content); do not throw on first error. Threshold of errors → file rejected to dead-letter with the diagnostic list.
- Trailer/header row counts: expose declared count so the validation pass can compare vs staged rows.

## Assemblers (one per system)
- Run only after `ManifestCompletionTracker` signals all mandatory files validated.
- Cross-file joins are set-based SQL over staging tables, not in-memory C# joins.
- Assembly is pipeline **phase 2**; the recon engine is phase 3. Assemblers produce canonical data only — they do NOT link global to local or compare (that is the engine's job). Each side canonicalizes independently.
- **Output contract**: global-side assemblers write `core.GlobalPosition`; local-side (RISCO) writes `core.LocalPosition`; both write `core.CanonicalMeasure` (side-discriminated). Multi-file systems map files to tables (MOR positions file → positions, measures file → measures); single-file systems (APEX, MUREX, RISCO) split their one file across position + measure tables.
- **Match-key resolution**: compute `ResolvedMatchKey` via the shared `MatchKeyResolver` reading `match.MatchRule` for (System, Product, Side) — see docs/specs/matching-rules.md. Never resolve match keys in the engine.
- **Product classification**: resolve Product via `ref.ProductClassMap` before match-key resolution (the rule keys on Product). MM-OPEN vs MM-SIG comes from the global MatchingKey `OP` marker — encode as an explicit token match, not `LIKE '%OP%'`.
- **Measure names**: resolve source → canonical via `ref.MeasureNameMap` (per System); store BOTH SourceMeasure and CanonicalMeasure. Unmapped name = assembly failure with offending names listed.
- Integrity check before commit: every CanonicalMeasure matches a position on the natural key; orphans = assembly failure. Unmapped product or measure = hard failure.
- MOR: measures joined to positions; FX from MOR's own FXRates staging table (never external); rate stamped on measure rows.
- GR: BrazilRec + BrazilAttribution combined; MRC errors (optional file) applied per `docs/specs/file-manifest.md`.

## Testing
- Every adapter gets a golden-file test: anonymized sample in `tests/fixtures/{system}/`, expected staged rows asserted exactly.
- Include fixtures for: comma decimals, empty optional columns, malformed line, header/trailer count mismatch.
