---
applyTo: "**/Migrations/**,**/Sql/**,**/*.sql"
---
# SQL & migrations

- Schemas: `staging` (per file type, truncate-reload), `core` (canonical), `recon`, `just`, `thr`, `ops`, `rpt`, `audit`.
- **`staging.RISCO` is a single shared table** for all five RISCO feeds (identical layout), with a `SourceSystem VARCHAR(20)` discriminator (`GR | MOR_IB | MOR_GT | APEX | MUREX`) populated from watcher config, never parsed from file content. Table is **partitioned by SourceSystem**; per-system reload uses `TRUNCATE TABLE staging.RISCO WITH (PARTITIONS (...))` — never DELETE, never full-table truncate. Global-side staging tables (MOR, GR, APEX, MUREX file types) remain separate per file type: layouts genuinely differ.
- Canonical positions are **two separate tables** — `core.GlobalPosition` (lean) and `core.LocalPosition` (rich, many local-only columns). The two sides carry genuinely different attributes; do not merge into one table with nullable columns. Both share the matching spine `(BusinessDate, System, Division, MatchingKey, ResolvedMatchKey)` and both are clustered columnstore. The engine's position match targets the view `core.PositionMatchable` (common spine + ResolvedMatchKey projected from both).
- `ResolvedMatchKey` is computed at assembly (phase 2) via `match.MatchRule`, never in the engine; raw `MatchingKey` is retained alongside it for audit. Matching is product-dependent — see docs/specs/matching-rules.md.
- `core.CanonicalMeasure` is **one unified table**, side-discriminated (`Side G|L`), tall/narrow: `SourceMeasure` + `CanonicalMeasure` (both stored), `Dimension`, `Value`, `Currency`, `Unit`, `FxRateApplied`. `PositionKey` links a measure to its position WITHIN a side only — never join measures global-to-local on PositionKey. Clustered columnstore.
- `ref.MeasureNameMap` (source→canonical measure name) and `ref.ProductClassMap` (source→canonical Product, incl. MM-OPEN/MM-SIG) resolve at assembly; unmapped values are hard failures, never silent pass-through. Orphan-measure check (measure with no matching position on the natural key) fails assembly.
- `recon.Result`: clustered columnstore index; partition-aligned by BusinessDate if partitioning is introduced.
- Recon/matching/aggregation: set-based only. FULL OUTER JOIN for global-vs-local matching. No cursors, no WHILE loops, no scalar UDFs in hot paths.
- Staging load: `SqlBulkCopy` targets, minimal indexes on staging (add after load if needed).
- All object names two-part (`schema.Table`). Explicit column lists — never `SELECT *` in application SQL.
- Money/measures: `DECIMAL(28,8)` unless the spec says otherwise. Never FLOAT for financial values.
- Dates: `BusinessDate` is `DATE`, timestamps are `DATETIME2(3)` in UTC.
- Filtered unique indexes for conditional uniqueness (e.g., one IsLatest=1 per recon unit/date).
- Migrations: EF Core migrations for CRUD schemas; hand-written idempotent scripts (checked into `Sql/`) for columnstore/partitioning/staging DDL. Every migration reversible or explicitly marked irreversible with a comment.
