---
mode: agent
description: One-time prompt — generic streaming StagingWriter (SqlBulkCopy) + column-map contract used by all 13 file types
---
Implement the **generic staging load pipeline**: a single StagingWriter that streams any
adapter's `IAsyncEnumerable<StagedRecord>` into its staging table via SqlBulkCopy, driven
by explicit per-record-type column maps. This is reference-quality shared infrastructure —
every file type flows through it; there will be exactly ONE writer, never per-type writers.

CONTEXT
- Adapter contract + record types: #file:src/Valrec.Application/Ingestion/ISourceAdapter.cs
  and src/Valrec.Infrastructure/Ingestion/Adapters/ (existing 9 adapters)
- Staging DDL: src/Valrec.Infrastructure/Sql/staging/
- Rules: ingestion + sql instructions; #file:docs/specs/file-manifest.md

DESIGN (implement exactly)
1. **Column-map contract** (Application layer):
```csharp
public interface IStagingTableMap
{
    Type RecordType { get; }                          // e.g., typeof(MorPositionStagedRecord)
    string TargetTable { get; }                       // e.g., "staging.MOR_Positions"
    ReloadStrategy Reload { get; }                    // TruncateTable | TruncatePartition
    string? PartitionColumn { get; }                  // "SourceSystem" for RISCO, else null
    IReadOnlyList<(string Column, Func<StagedRecord, object?> Getter)> Columns { get; }
}
```
   One map class per staged record type, next to its adapter. Explicit column lists —
   no reflection-by-convention mapping.
2. **Startup validation** (fail fast, hosted-service check): every ISourceAdapter has a
   registered map for its record type; every map's column list matches the target table's
   actual columns (query INFORMATION_SCHEMA once at startup). Mismatch → throw with a
   precise message; the app must not start with a broken map.
3. **StagingWriter** (Infrastructure):
   - `Task<StagingLoadResult> WriteAsync(IAsyncEnumerable<StagedRecord> records, IStagingTableMap map, AdapterContext ctx, CancellationToken ct)`
   - Pre-load reload per map strategy: TRUNCATE TABLE, or for TruncatePartition resolve
     the partition number for ctx.SourceSystem and TRUNCATE ... WITH (PARTITIONS (n)).
     Reload-first makes retries idempotent by construction.
   - Streaming: wrap the IAsyncEnumerable in a custom DbDataReader (forward-only,
     GetValue via the map's getters) and call SqlBulkCopy.WriteToServerAsync with it.
     Constant memory — never materialize the record set. BatchSize + BulkCopyTimeout
     from configuration (defaults 50_000 / 300s). EnableStreaming = true.
   - FileId and LineNumber flow from records; LoadedAtUtc is the column default.
   - Result: rows written, elapsed, target table — for FileEvent stage counts.
   - Failure mid-copy: let it throw after the reload step; document that retry re-runs
     reload (no partial-load cleanup logic needed).
4. DI: maps registered by assembly scan alongside adapters; writer singleton.

TESTS
- Unit (tests/Valrec.UnitTests/Ingestion/): startup validation failures — missing map,
  column-name mismatch, extra column (use a fake schema provider).
- Integration (tests/Valrec.IntegrationTests/Ingestion/, Testcontainers with real staging
  DDL applied):
  a. MOR_Positions golden fixture → adapter → writer → SELECT back and assert exact values,
     row count = fixture count.
  b. Reload idempotency: write same file twice → row count unchanged, no duplicates.
  c. RISCO partition isolation: load GR-context records, then MOR_GT-context records →
     both present; reload GR partition → GR rows replaced, MOR_GT rows untouched.
  d. Cancellation mid-stream → operation aborts, subsequent reload+retry succeeds.

ACCEPTANCE
- Build zero warnings; unit + integration tests green; architecture tests green
  (contract in Application, implementation in Infrastructure).
- Touch only: Application/Ingestion/ (contract), Infrastructure/Ingestion/Staging/,
  per-record map classes beside their adapters, DI registration, the two test files.

CONSTRAINTS
- ONE writer class. No per-type writer subclasses, no reflection-based auto-mapping,
  no Dapper/EF in this path — raw SqlBulkCopy.
- No new packages. No orchestrator/watcher logic (separate slice). No validation-pass
  SQL (separate slice).
- If any staging table's columns cannot be matched to a record type's properties, STOP
  and list the mismatches instead of guessing.
