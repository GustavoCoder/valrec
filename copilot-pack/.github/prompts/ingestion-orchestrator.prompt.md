---
mode: agent
description: One-time prompt — ingestion orchestrator: watcher → adapter → staging → validation → FileEvent, in Valrec.Workers
---
Implement the **ingestion orchestrator** in Valrec.Workers: detects arriving files per
watcher configuration, drives them through adapter → StagingWriter → validation, records
every stage in ops.FileEvent, and hands completed files to the manifest tracker port.

CONTEXT
- Components to compose (do not modify them): existing adapters, StagingWriter + maps,
  ISqlConnectionFactory (all connections via the factory — account name from configuration).
- Rules: #file:docs/specs/file-manifest.md, ingestion + sql instructions.
- Config tables: ops.FileWatcher (System, Division, FileType, Folder, FilenameRegex,
  ExpectedCutoffTime, CalendarId, Enabled, Version), ops.FileEvent.

DESIGN
1. **Watcher loop** (BackgroundService): POLLING scan of each enabled watcher's folder on a
   configurable interval (default 30s) — no FileSystemWatcher (unreliable on network shares).
   Watcher configs loaded from ops.FileWatcher and hot-reloaded: re-read on a configurable
   interval (default 60s); version change applies without restart.
2. **Detection → claim**: filename matches watcher regex → atomically claim by moving the
   file to a `processing/` subfolder (move fails if another worker instance claimed it —
   that is the concurrency control; treat cross-process move failure as "already claimed",
   log debug, skip). Create ops.FileEvent row (Status=Received) with watcher identity,
   original filename, size.
3. **Idempotency**: compute SHA-256 of content. Same (watcher, hash) already Loaded →
   mark event Duplicate, archive the file, stop. Same filename but different hash →
   proceed normally and set RedeliveryOfFileId on the event (the manifest tracker decides
   re-run semantics — not this orchestrator).
4. **Parse + load**: resolve the single adapter where CanHandle(descriptor) is true
   (zero or >1 matches → Rejected with diagnostic). Build AdapterContext (FileId, recon
   unit, culture config). Stream adapter → StagingWriter. Record StagedRowCount and
   DeclaredRowCount on the event.
5. **Validation pass** (set-based SQL against the staging table, via the connection
   factory): staged count vs DeclaredRowCount; mandatory-field NULL check; duplicate
   business-key check (keys per layout spec). Any failure → Status=Rejected, move file
   to `deadletter/`, write a diagnostic report file beside it (rule violated + up to 100
   offending line numbers), raise a structured log event for alerting. All pass →
   Status=Validated, then Loaded; move file to `archive/{yyyy-MM}/`.
6. **Handoff**: on Loaded, call `IManifestCompletionTracker.NotifyFileLoadedAsync(fileEvent, ct)`.
   Define this port in Application and register a LOGGING-ONLY stub implementation —
   the real tracker is separate, hand-written work. Do NOT implement completion logic
   or recon enqueueing.
7. **Concurrency**: bounded parallelism across files (configurable, default 4); a single
   file is processed by exactly one flow. Per-file cancellation linked to host shutdown;
   a file mid-processing at shutdown is safe to reprocess (claim + reload-first writer
   make the flow idempotent).
8. **Observability**: one log scope per FileId (all lines correlated); metrics counters:
   files received/loaded/rejected/duplicate, rows staged, per-stage duration. Cutoff
   breach detection is NOT this component (ops alerting slice) — but FileEvent timestamps
   must make it computable.

TESTS (tests/Valrec.IntegrationTests/Ingestion/OrchestratorTests.cs, Testcontainers +
temp directories)
a. Happy path: drop valid MOR positions fixture → event walks Received→Validated→Loaded,
   staged rows match, file archived, tracker stub invoked once.
b. Regex non-match ignored; disabled watcher ignored.
c. Malformed file exceeding error threshold → Rejected, dead-letter + diagnostic file
   written, tracker NOT invoked.
d. Trailer mismatch → Rejected with count detail.
e. Identical re-delivery → Duplicate, no re-staging, tracker not invoked.
f. Changed re-delivery → processed, RedeliveryOfFileId set.
g. Two files for different recon units processed concurrently → both Loaded, no cross-talk.
h. Hot-reload: watcher config version bump (e.g., regex change) applied without restart.

ACCEPTANCE
- Build zero warnings; all tests green; architecture tests green.
- Touch only: Workers/ (orchestrator + hosting), Application/Ingestion/ (tracker port +
  small orchestration ports), Infrastructure/Ingestion/ (validation SQL, FileEvent
  repository), the test file + fixtures.

CONSTRAINTS
- All DB access through ISqlConnectionFactory. Validation is set-based SQL — no
  row-by-row C# validation loops.
- No Hangfire jobs here (the loop is a BackgroundService; recon enqueueing belongs to
  the tracker). No manifest/completion logic. No cutoff alerting.
- No new packages.
- If FileEvent's current schema lacks a column this design needs (e.g., RedeliveryOfFileId,
  Duplicate status), STOP and propose the exact ALTER script for review instead of
  silently extending.
