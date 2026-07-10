---
applyTo: "src/Valrec.Infrastructure/Ingestion/**"
---
# Ingestion: adapters & assemblers

## Adapters (one per file type)
- Implement `ISourceAdapter` (Application layer): `System`, `FileType`, `CanHandle(FileDescriptor)`, `IAsyncEnumerable<StagedRecord> ReadAsync(Stream, CancellationToken)`.
- Adapters are dumb per-file parsers. NO cross-file logic, NO FX conversion, NO business rules — that belongs in assemblers.
- Stream, never buffer: read line-by-line / record-by-record, `yield return`. Constant memory regardless of file size. Never `ReadToEnd()`.
- Culture: Brazilian files may use comma decimal separators and dd/MM/yyyy dates. Parse with explicit `CultureInfo` per adapter config — never `CultureInfo.CurrentCulture`.
- Malformed record → collect into a bounded error list (with line number and raw content); do not throw on first error. Threshold of errors → file rejected to dead-letter with the diagnostic list.
- Trailer/header row counts: expose declared count so the validation pass can compare vs staged rows.

## Assemblers (one per system)
- Run only after `ManifestCompletionTracker` signals all mandatory files validated.
- Cross-file joins are set-based SQL over staging tables, not in-memory C# joins.
- MOR: measures joined to positions; FX conversion uses MOR's own FXRates staging table (never an external source). Stamp the applied rate on canonical rows.
- GR: BrazilRec + BrazilAttribution combined; MRC errors (optional file) applied per `docs/specs/file-manifest.md`.
- Output: canonical rows into `core.CanonicalPosition` with `(BusinessDate, System, Division, Side)` stamped.

## Testing
- Every adapter gets a golden-file test: anonymized sample in `tests/fixtures/{system}/`, expected staged rows asserted exactly.
- Include fixtures for: comma decimals, empty optional columns, malformed line, header/trailer count mismatch.
