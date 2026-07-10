---
applyTo: "**/Migrations/**,**/Sql/**,**/*.sql"
---
# SQL & migrations

- Schemas: `staging` (per file type, truncate-reload), `core` (canonical), `recon`, `just`, `thr`, `ops`, `rpt`, `audit`.
- `core.CanonicalPosition` and `recon.Result`: clustered columnstore index; partition-aligned by BusinessDate if partitioning is introduced.
- Recon/matching/aggregation: set-based only. FULL OUTER JOIN for global-vs-local matching. No cursors, no WHILE loops, no scalar UDFs in hot paths.
- Staging load: `SqlBulkCopy` targets, minimal indexes on staging (add after load if needed).
- All object names two-part (`schema.Table`). Explicit column lists — never `SELECT *` in application SQL.
- Money/measures: `DECIMAL(28,8)` unless the spec says otherwise. Never FLOAT for financial values.
- Dates: `BusinessDate` is `DATE`, timestamps are `DATETIME2(3)` in UTC.
- Filtered unique indexes for conditional uniqueness (e.g., one IsLatest=1 per recon unit/date).
- Migrations: EF Core migrations for CRUD schemas; hand-written idempotent scripts (checked into `Sql/`) for columnstore/partitioning/staging DDL. Every migration reversible or explicitly marked irreversible with a comment.
