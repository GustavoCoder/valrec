---
mode: agent
description: One-time prompt — generate all staging table DDL from the reviewed layout specs
---
Generate the staging schema DDL under **src/Valrec.Infrastructure/Sql/staging/** — one
.sql file per table plus one `000_schema.sql` (schema + partition objects). Follow the
sql instructions strictly.

CONTEXT
- Layout specs (authoritative for columns/types): docs/specs/layouts/ — all files.
  Global-side: mor-positions, mor-measures, mor-fxrates, gr-brazilrec,
  gr-brazilattribution, gr-mrcerrors, apex, murex. Local: risco (single spec, shared layout).
- Rules: #file:.github/instructions/sql.instructions.md and #file:docs/specs/file-manifest.md

TABLES
Global-side: one table per file type — staging.MOR_Positions, staging.MOR_Measures,
staging.MOR_FXRates, staging.GR_BrazilRec, staging.GR_BrazilAttribution,
staging.GR_MRCErrors, staging.APEX_File, staging.MUREX_File.
Local: single **staging.RISCO** shared table per the sql instructions:
- SourceSystem VARCHAR(20) NOT NULL discriminator (GR | MOR_IB | MOR_GT | APEX | MUREX)
- Partition function + scheme on SourceSystem (RANGE with the five boundary values),
  table created ON the partition scheme, so reloads can use
  TRUNCATE TABLE staging.RISCO WITH (PARTITIONS (n)).

EVERY TABLE
- Typed columns exactly per the spec's field table (adapter parses; staging stores typed).
  DECIMAL(28,8) for measures/amounts unless the spec says otherwise; DATE for business
  dates; NULL-ability per spec.
- Plus: FileId INT NOT NULL, LineNumber INT NOT NULL, LoadedAtUtc DATETIME2(3) NOT NULL
  DEFAULT SYSUTCDATETIME().
- Minimal indexing: no indexes beyond what the partition scheme requires (heaps are fine
  for truncate-reload staging).
- Idempotent: IF NOT EXISTS guards on schema, partition function/scheme, and every table.
  Re-runnable without error.

ALSO GENERATE
- A checksum-style summary comment atop each file: source spec filename + column count,
  so drift between spec and DDL is visible in review.

CONSTRAINTS
- Do not generate core/recon/ops schemas (separate work). No EF migrations — plain SQL only.
- If a spec is missing a type or nullability for any field, STOP and list the gaps
  instead of assuming.
