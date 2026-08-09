---
mode: agent
description: One-time prompt — add BusinessDate to staging, T+1 cutoff offset + DateFormat to FileWatcher, regenerate the watcher seed, and define business-date-relative cutoff-breach logic
---
Implement four related changes so BusinessDate comes authoritatively from the filename and
cutoffs are expressed relative to the business date (GR feeds arrive T+1). Work against the
REAL schemas in DB `BrazilDataHub_ValRec` (view them first; do not assume columns).

CONTEXT
- Rules: #file:.github/instructions/sql.instructions.md, #file:docs/specs/file-manifest.md
- The ingestion orchestrator (BusinessDate extraction) and StagingWriter (reload scope) are
  the C# consumers of these schema changes.
- DB access via ISqlConnectionFactory.

Before writing DDL, run SELECT TOP 0 * (or query INFORMATION_SCHEMA) on: every staging.*
table, ops.FileWatcher, and one core.* table (to copy BusinessDate's exact type/nullability).
Match that type EXACTLY for the new staging column.

--- CHANGE 1: BusinessDate on all staging tables -------------------------------------------
- Idempotent ALTER (IF COL_LENGTH(...) IS NULL) adding `BusinessDate` to EVERY staging.*
  table — same type/nullability/collation as core.*'s BusinessDate (DATE, NOT NULL expected;
  confirm from core). Add it NOT NULL only if you can backfill/rebuild empty staging safely;
  otherwise add NULLable then a follow-up note. Staging is truncate-reload, so an empty-table
  ALTER is simplest — prefer that.
- Reason: cross-day reprocessing (reprocess a prior day's file while another day is in flight)
  must not mix dates in one staging table.
- Consequence for reload scope (document in code + a comment, adjust StagingWriter):
  * Per-file-type global staging: reload scope becomes (BusinessDate) — DELETE WHERE
    BusinessDate=@d before load, NOT a blanket TRUNCATE (which would wipe other days being
    reprocessed).
  * staging.RISCO (shared, partitioned by SourceSystem): reload scope becomes
    (SourceSystem, BusinessDate) — DELETE WHERE SourceSystem=@s AND BusinessDate=@d.
    Partition-truncate is no longer correct for a single-day reload; keep partitioning for
    query pruning but reload via scoped DELETE.
  * Update the sql/ingestion instruction note about RISCO reload accordingly.

--- CHANGE 2: FileWatcher — cutoff offset + date format ------------------------------------
Idempotent ALTERs on ops.FileWatcher adding:
- `ExpectedCutoffDayOffset TINYINT NOT NULL DEFAULT 0`  -- 0 = same day as BusinessDate,
  1 = T+1 (deadline falls the business day AFTER BusinessDate).
- `DateFormat VARCHAR(20) NOT NULL DEFAULT 'yyyyMMdd'`  -- how to parse the date token
  captured from the filename (e.g. yyyyMMdd; a feed using ddMMyyyy is ambiguous under \d{8}
  so the format must be explicit).
Keep existing ExpectedCutoffTime (TIME) = time-of-day on (BusinessDate + offset).

--- CHANGE 3: regenerate the ops.FileWatcher seed -----------------------------------------
Rewrite the seed MERGE to populate the new columns and use a NAMED date capture group in
every FilenameRegex so the orchestrator extracts BusinessDate from a defined group
(?<bdate>\d{8}) rather than guessing which digit-run is the date.
- GR feeds (BrazilRec, BrazilAttribution, MRCErrors — all System=GR, Division=IB):
  ExpectedCutoffDayOffset = 1, ExpectedCutoffTime = 03:00. (GR runs a day behind.)
- ALL other feeds (MOR IB/GT, APEX, MUREX, and every RISCO_* feed): offset = 0, keep their
  same-day times.
- DateFormat = 'yyyyMMdd' for all unless a real filename proves otherwise (leave a comment).
- Preserve: rows inserted DISABLED (Enabled=0); MERGE natural key (System, Division, FileType);
  the RISCO_* FileType encoding; Version bump + UpdatedAtUtc on update.

--- CHANGE 4: cutoff-breach logic (business-date-relative, calendar-aware) -----------------
- Implement the deadline computation used by cutoff-breach detection:
  Deadline(watcher, businessDate) = add_business_days(businessDate, ExpectedCutoffDayOffset)
                                    at ExpectedCutoffTime, in the feed's timezone,
                                    skipping holidays/weekends per ops.Calendar (CalendarId).
  A GR file for a Friday business date whose T+1 lands on the weekend is not "late" until the
  next business day at 03:00.
- A file is breached if now > Deadline and no Validated FileEvent exists for
  (watcher, businessDate). Expose this as a queryable/service method the ops monitoring
  (file status board) and alerting use — do NOT bury it inline in a job.
- Put the business-day arithmetic in one reusable helper (ops.Calendar-backed); unit-test it.

TESTS
- SQL: post-ALTER, assert BusinessDate exists on every staging.* table with the core-matching
  type; assert the two new FileWatcher columns exist with defaults. Seed re-run is idempotent
  (row counts stable, versions bump on change only).
- Reload scope: StagingWriter integration test — load date D1, then reprocess date D2 for the
  same table/feed, assert D1 rows survive (scoped DELETE, not blanket truncate); reprocess D1
  again, assert D1 replaced and D2 untouched. RISCO variant across two SourceSystems × two dates.
- Cutoff helper unit tests: offset 0 same-day; offset 1 normal weekday; offset 1 where T+1 is
  Saturday -> deadline shifts to Monday; breach true/false around the deadline boundary.

ACCEPTANCE
- Build zero warnings; all tests green; architecture tests green.
- Idempotent: every ALTER and the seed MERGE re-runnable without error.
- Grep: no blanket `TRUNCATE TABLE staging.` remains in the reload path (replaced by
  date-scoped delete) except where a full reset is genuinely intended.

CONSTRAINTS
- Match the REAL column types from the live schema — especially BusinessDate from core.*.
- All DB access via ISqlConnectionFactory. Set-based; parameterized SQL only.
- Do NOT change core.* or the recon/engine schemas. Do NOT alter adapter parsing logic beyond
  where the orchestrator stamps BusinessDate onto staged rows.
- If BusinessDate on core.* is not DATE/NOT NULL as assumed, STOP and report before ALTERing
  staging to match — consistency across staging and core is the point.
