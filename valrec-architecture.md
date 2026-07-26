# Valuation Reconciliation (Valrec) — Web Migration Architecture & Implementation Plan

## 1. Context & Goals

Migrate the current Excel/macro-based valuation reconciliation workflow to a web application backed by a C#/.NET backend. The system ingests EOD files from global systems (MOR, GR) and their local counterparts from RISCO (e.g., RISCO_GR), aggregates and matches positions, compares measures against business-defined thresholds (% or absolute, varying by product/underlying), and surfaces breaks for review, justification, and reporting.

**Systems in scope** — recon unit = `(System, Division, BusinessDate)`:

| Recon unit | Mandatory global files | Optional | Local counterpart |
|---|---|---|---|
| GR (Geronimo) – IB | BrazilRec, BrazilAttribution | MRC errors | RISCO_GR |
| MOR – IB | Positions, Measures, FXRates | — | RISCO_MOR (IB) |
| MOR – GT | Positions, Measures, FXRates | — | RISCO_MOR (GT) |
| APEX – GT | 1 file | — | RISCO_APEX |
| MUREX – GT | 1 file | — | RISCO_MUREX |

RISCO sends one file per global system. Global layouts differ per system; MOR–IB and MOR–GT share adapters/assembler with separate watcher + manifest configs (layout parity to be confirmed).

**Non-functional goals:** robustness (auditability, idempotent re-runs), scalability (file sizes and desk coverage will grow), performance (grid interactions < 1s, recon runs bounded and observable), and a UX that matches or exceeds the Excel pivot experience.

---

## 2. High-Level Architecture

```
 ┌─────────────┐   files    ┌──────────────────────────────────────────┐
 │ MOR / GR /  │ ─────────► │            Valrec.Workers                │
 │ RISCO drops │            │  File watcher → Adapter → SqlBulkCopy    │
 └─────────────┘            │  ManifestCompletionTracker → assembler   │
                            │  → enqueue recon run                     │
                            └───────────────┬──────────────────────────┘
                                            │ Hangfire jobs
                                            ▼
                            ┌──────────────────────────────────────────┐
                            │        Recon Engine (set-based SQL)      │
                            │  staging → canonical → match → breaks    │
                            │  threshold evaluation → versioned RunId  │
                            └───────────────┬──────────────────────────┘
                                            │
        ┌───────────────────────────────────┼──────────────────────────┐
        ▼                                   ▼                          ▼
 ┌──────────────┐                 ┌──────────────────┐        ┌────────────────┐
 │ Valrec.Api   │ ◄── SignalR ──► │  React + AG Grid │        │ Report job     │
 │ (REST, OIDC) │                 │  (pivots, views) │        │ (QuestPDF+SMTP)│
 └──────────────┘                 └──────────────────┘        └────────────────┘
```

**Style: modular monolith.** One deployable API + one worker service, with strict internal module boundaries (Ingestion, Recon, Thresholds, Justifications, Reporting, Identity). Rationale: cohesive domain, batch-heavy workload, small team; boundaries enforced by architecture tests allow later extraction if a module needs independent scaling.

---

## 3. Solution Structure

```
Valrec.sln
├── src/
│   ├── Valrec.Domain
│   │     Entities, value objects (BreakKey, ThresholdScope, Measure),
│   │     domain events, threshold precedence rules. No dependencies.
│   ├── Valrec.Application
│   │     Use-case handlers (CQRS-style, MediatR optional), FluentValidation,
│   │     authorization policies, port interfaces (ISourceAdapter, IReportRenderer).
│   ├── Valrec.Infrastructure
│   │     EF Core (workflow/CRUD) + Dapper (hot reads), SqlBulkCopy pipeline,
│   │     file adapters, Hangfire storage, email (SMTP/Graph), QuestPDF renderer.
│   ├── Valrec.Contracts
│   │     API DTOs + enums. Source for TypeScript client codegen (NSwag/Kiota).
│   ├── Valrec.Api
│   │     ASP.NET Core, controllers/minimal APIs, SignalR hubs, output caching,
│   │     OIDC (corporate IdP), ProblemDetails error handling, health checks.
│   └── Valrec.Workers
│         Hangfire server: file watchers, recon runs, report generation, email.
├── tests/
│   ├── Valrec.UnitTests           (domain + application, no I/O)
│   ├── Valrec.IntegrationTests    (Testcontainers SQL Server; full pipeline)
│   └── Valrec.ArchitectureTests   (NetArchTest: layer/module dependency rules)
└── frontend/
      React 18 + TypeScript, Vite, TanStack Query, AG Grid Enterprise,
      generated API client, SignalR client, Recharts for report previews.
```

### Library choices

| Concern | Choice | Notes |
|---|---|---|
| ORM / data access | EF Core + Dapper | EF for thresholds/justifications/workflow; Dapper for grid read paths |
| Bulk load | SqlBulkCopy over `IAsyncEnumerable` | Constant memory, streams file → staging |
| Jobs | Hangfire | Dashboard, retries, idempotent enqueue keys |
| Realtime | SignalR | Run progress, break count refresh |
| Validation | FluentValidation | On commands/DTOs |
| PDF | QuestPDF | Code-first, fast, no headless browser dependency |
| Resilience | Polly | File I/O, email, external calls |
| Observability | Serilog + OpenTelemetry | Traces per RunId; metrics: rows/s, breaks, run duration |
| AuthN/Z | OIDC + policy-based authorization | Claims: roles, desks[], divisions[] |
| Frontend grid | AG Grid Enterprise (server-side row model) | Pivot/group/filter server-side |

**Frontend (decided):** React + TypeScript with AG Grid Enterprise (server-side row model). Authentication via **Microsoft Entra ID**: MSAL React (auth code + PKCE) on the frontend; `Microsoft.Identity.Web` JWT bearer validation on the API. Authorization via **one Entra security group per profile** (12 profiles — see §7 Authorization model) mapped app-side to (Role, Scope); only ~12 groups, so no token overage concerns.

---

## 4. Data Model (core tables)

```
staging.{System}_{FileType}          -- raw per-layout columns, FileId FK, truncate-reload
                                     --   (e.g., MOR_Positions, MOR_Measures, MOR_FXRates,
                                     --    GR_BrazilRec, GR_BrazilAttribution, RISCO_MOR...)
core.GlobalPosition                  -- lean global side: BusinessDate, System, Division,
                                     --   PositionKey, MatchingKey, ResolvedMatchKey, BookId,
                                     --   BookName, InstrumentId, ISIN, MaturityDate, Amount,
                                     --   Product, ProductType, Notional, UnderlyingPrice,
                                     --   InstrumentType, FileId (clustered columnstore)
core.LocalPosition                   -- rich local side: adds SubBook, LocalBookId,
                                     --   SourceSystem, SecurityCode, PricingClass, AssetName,
                                     --   PositionType, Currency, TransactionId, FixingDate,
                                     --   ErrorMessage, SourceErrorMessage, ... + same
                                     --   matching spine (MatchingKey, ResolvedMatchKey,
                                     --   BookId, ISIN, MaturityDate, Amount, Notional)
                                     --   (clustered columnstore). Separate table — the two
                                     --   sides carry genuinely different attributes.
core.PositionMatchable (view)        -- projects the common matching spine + ResolvedMatchKey
                                     --   from both position tables; the engine's position
                                     --   join targets this view.
core.CanonicalMeasure                -- unified, side-discriminated, tall/narrow:
                                     --   BusinessDate, System, Division, Side(G/L), PositionKey,
                                     --   SourceMeasure, CanonicalMeasure, Dimension, Underlying,
                                     --   Value, Currency, Unit, FxRateApplied, FileId
                                     --   (clustered columnstore). PositionKey links measures
                                     --   to their position WITHIN a side (not across sides).
ref.MeasureNameMap                   -- System, SourceMeasure → CanonicalMeasure
                                     --   (config-as-data, audited; unmapped = hard failure)
ref.ProductClassMap                  -- System, Side, SourceProductValue → canonical Product
                                     --   (incl. MM-OPEN/MM-SIG via global MatchingKey marker)
match.MatchRule                      -- System, Product, Side(G/L), ColumnOrder[] projected
                                     --   into ResolvedMatchKey; audited (see matching-rules.md)
recon.Run                            -- RunId, BusinessDate, System, Version, Status,
                                     --   TriggeredBy, StartedAt, CompletedAt, IsLatest
recon.Result                         -- RunId, matching dims, GlobalValue, LocalValue,
                                     --   Diff, DiffPct, ThresholdApplied, Status(OK/Break)
recon.Break                          -- InstanceKey, SeriesKey, RunId, classification
                                     --   (PositionBreak | MeasureBreak), severity,
                                     --   JustificationStatus, magnitude at detection
recon.BreakSeries                    -- SeriesKey, FirstSeenDate, LastSeenDate,
                                     --   ConsecutiveDays, IsActive
just.Justification                   -- SeriesKey, Reason, Category, CreatedBy, CreatedAt,
                                     --   MagnitudeAtJustification, TolerancePct?,
                                     --   ValidUntil?, Status(Active|Expired|Superseded),
                                     --   rowversion
thr.Threshold                        -- Scope (Division, Desk, Product, Underlying — nullable
                                     --   for wildcards), Type (Pct|Abs), Value,
                                     --   EffectiveFrom/To, Status, Version
thr.ThresholdApproval                -- ThresholdId, State machine log, Actor, Comment
audit.Event                          -- append-only: who/what/when/before/after (JSON)
rpt.ReportConfig                     -- Desks[] (explicit scope, subset of creator's access
                                     --   at save time), Recipients[], Cc[], SubjectTemplate,
                                     --   ScheduleTime + TimeZone, CalendarId,
                                     --   OwnerGPNs[] (distribution list), Visualizations (JSON),
                                     --   Format (pdf|html), Enabled, CreatedBy, Version (audited)
rpt.ReportDispatch                   -- ConfigId, BusinessDate, GPN, ResolvedEmail,
                                     --   GateResult, Status (Sent|Failed|Blocked|Retrying),
                                     --   AttemptCount, MessageId, Timestamps
ops.JobSchedule                      -- JobName, CronExpression, Enabled, TimeZone,
                                     --   Version, UpdatedBy/At (audited)
ops.FileWatcher                      -- System, Division, FileType, Side(G/L), Folder,
                                     --   FilenameRegex, ExpectedCutoffTime, CalendarId,
                                     --   Enabled, Version
ops.FileManifest                     -- ReconUnit (System, Division), mandatory FileTypes[],
                                     --   optional FileTypes[], OnLateOptional
                                     --   (Ignore | TriggerRerun), Version (audited)
ops.Calendar                         -- CalendarId, holiday dates per system/region
ops.FileEvent                        -- FileId, Watcher, Status (Received|Validated|
                                     --   Rejected|Loaded), SourceRowCount, StagedRowCount,
                                     --   LoadedRowCount, Hash, Timestamps, ErrorDetail
```

### Break keys — two levels (critical design point)
```
InstanceKey = SHA256(BusinessDate | System | Desk | Product | Underlying | PositionKey | MeasureName)
SeriesKey   = SHA256(              System | Desk | Product | Underlying | PositionKey | MeasureName)
```
- **InstanceKey** identifies a break on a specific day (uniqueness within a run/date).
- **SeriesKey** identifies the recurring break across days. **Justifications attach to the SeriesKey**, so a break persisting for several days is justified once and carried forward — the user never re-justifies daily.
- Re-runs within a day regenerate identical keys, so justifications also survive intra-day re-runs and re-attach automatically.
- The series carries `FirstSeenDate`, `LastSeenDate`, `ConsecutiveDays` for aging visibility.

### Threshold precedence
Most-specific scope wins: `(Desk, Product, Underlying)` > `(Desk, Product)` > `(Division, Product)` > `(Division)` > global default. Resolve at recon time into `recon.Result.ThresholdApplied` so every result records *which* threshold judged it — essential for audit and for explaining breaks to users.

### Run versioning
Runs are immutable. A re-run creates `Version = max+1` and flips `IsLatest`. All read APIs default to `IsLatest` but accept an explicit RunId for historical comparison ("what did this look like before the re-run?").

---

## 5. Ingestion Pipeline

1. **Watcher** (Workers) monitors drop folders (or MQ/SFTP event) per `(System, Division, FileType)` — the watcher definition includes the file type dimension.
2. **Adapter** per *file type* implements:
   ```csharp
   public interface ISourceAdapter
   {
       string System { get; }
       string FileType { get; }              // e.g., MOR.Positions, GR.BrazilRec, RISCO.MOR
       bool CanHandle(FileDescriptor file);
       IAsyncEnumerable<StagedRecord> ReadAsync(Stream s, CancellationToken ct);
   }
   ```
   Layout differences are absorbed here; adapters are dumb per-file parsers. MOR–IB and MOR–GT reuse the same adapters with different watcher/manifest configs.
3. **Stream → SqlBulkCopy** into per-file-type staging (batched, e.g., 50k rows), constant memory.
4. **Validation pass** (set-based in SQL): row counts vs file header, mandatory fields, duplicate keys → reject file to dead-letter with a diagnostic report rather than partially loading.
5. **ManifestCompletionTracker** (DB-backed, restart-safe): `ops.FileManifest` defines, per recon unit, the mandatory file types (global set + RISCO counterpart) and optionals. Recon is enqueued only when **all mandatory files have landed and validated**. Optional files never block; a late-arriving optional triggers behavior per manifest config (`OnLateOptional: Ignore | TriggerRerun`, default TriggerRerun — cheap and safe under run versioning).
6. **Assembly / canonicalization step** (per system, per side, runs at manifest completion — this is pipeline phase 2). Each side canonicalizes independently (global doesn't wait for local). Produces `core.GlobalPosition` / `core.LocalPosition` + `core.CanonicalMeasure`, and within it:
   - classifies Product via `ref.ProductClassMap` (incl. MM-OPEN/MM-SIG from the global MatchingKey `OP` marker);
   - resolves `ResolvedMatchKey` via `match.MatchRule` (shared `MatchKeyResolver`, never in the engine);
   - normalizes measure names via `ref.MeasureNameMap` (both SourceMeasure and CanonicalMeasure stored) and applies FX/unit normalization — MOR FX from MOR's own FXRates file, rate stamped on measure rows;
   - GR combines BrazilRec + BrazilAttribution, applies MRC errors per its functional role [semantics TBC];
   - integrity check before commit: every CanonicalMeasure matches a position on the natural key (no orphans); unmapped product or measure name → hard failure.
   Canonical output is versioned per (BusinessDate, System, FileVersion) so re-runs record which canonical versions they compared.
7. **Idempotency**: file hash recorded; re-delivered identical files are no-ops; changed re-deliveries trigger a versioned re-run of the affected recon unit.

**Pipeline phases** (distinct triggers, distinct grains): **(1) Ingest** — file → typed staging, per file, on arrival. **(2) Canonicalize + resolve** — staging → canonical positions/measures with product classification, match-key resolution, measure/FX/unit normalization, per system per side, at manifest completion. **(3) Link + compare** — the recon engine (§6), per recon-unit pair, when both sides are canonical. The split lets phase 3 (volatile: thresholds, matching tolerance) re-run cheaply against stable phase-2 canonical data without re-parsing files, and makes the canonical layer inspectable for break investigation and the Excel parallel-run gate.

---

## 6. Recon Engine

- Runs on already-canonicalized data (phase 3 of the pipeline). ResolvedMatchKey was computed in phase 2, so the engine's join is uniform regardless of product-specific matching logic. Set-based SQL over columnstore, orchestrated by a C# job:
  1. Position matching: FULL OUTER JOIN global vs local via `core.PositionMatchable` on `(BusinessDate, System, Division, ResolvedMatchKey)` → matched pairs, global-only, local-only (position breaks). [Grain 1:1 pending SecurityCode-product cardinality check — see matching-rules.md; non-unique keys require pre-aggregation.]
  2. Measure comparison: for each matched pair, pull global measures via the global position's PositionKey and local measures via the local position's PositionKey (measures link to positions WITHIN a side), then align the two measure sets on `CanonicalMeasure` + `Dimension`. The two sides' measures meet only through the matched position pair — never joined global-to-local on PositionKey directly. Resolve threshold via precedence; compute Diff/DiffPct (unit/currency-aware); classify OK vs MeasureBreak. A CanonicalMeasure present on one side only for a matched pair is a one-sided measure break.
  3. Persist results + breaks under new RunId; flip IsLatest; re-attach justifications by SeriesKey; publish SignalR progress + completion event.
- Target: full run for one system/date in low minutes even at tens of millions of staged rows; measure and budget this in Phase 7 load tests.

---

## 6b. Operations Module (IT Support)

Operational configuration is **data, not deployment**: job schedules and watcher definitions live in `ops.*` tables, are versioned and audited, and are hot-reloaded by the Workers service (config poll or cache-invalidation ping) so IT changes take effect without redeploys.

**Capabilities (ITSupport role):**
- **Job schedule management**: edit cron expressions per job (ingestion sweeps, recon triggers, EOD report). UI shows the next N computed fire times before save; changes audited with before/after.
- **File watcher management**: CRUD on watcher definitions (system, folder, filename regex, expected cutoff, holiday calendar, enabled flag). Regex changes require passing a **test panel** — the UI runs the proposed pattern against the last N real filenames received and shows matches/misses — before the save button activates. This is the primary defense against the silent-failure mode where files arrive but nothing matches.
- **Monitoring dashboard**, three boards:
  1. *File status board* — per recon unit and business date, each expected file type (from ops.FileManifest + calendar): expected vs received vs validated vs loaded; mandatory vs optional distinguished; cutoff breaches highlighted and alerted.
  2. *Run board* — timeline of recon runs (status, duration, version, trigger source: scheduled/manual/re-delivery), drill-in to error detail and Hangfire job.
  3. *Data quality strip* — per file: source header row count vs staged vs loaded vs canonical rows; any stage-to-stage leakage flagged.
- **Dead-letter management**: rejected files with diagnostic report, and a *reprocess* action (re-enqueue after fix) with audit.
- **Guardrails**: ITSupport has no access to recon results, thresholds, or justifications — strict separation of duties. Ingestion *reprocess* (IT-owned, fixes failed file loads) is distinct from recon *re-run* (Trader-owned). All ops config changes are direct-apply with full audit (maker-checker optional here; can be enabled for prod watcher changes if the control environment requires it).

---

## 6c. Mandatory Justification Workflow & Notification Bar

**Enforcement model.** Every break requiring action carries a first-class status:

```
recon.Break.JustificationStatus : Pending | Justified | JustifiedCarriedForward
```

- Position breaks (global-only / local-only) and measure breaks exceeding threshold → created as `Pending`.
- Within-threshold differences are informational and never require justification.
- Justifying (single or bulk) attaches an active justification to the **SeriesKey** and flips today's instance to `Justified`; deleting/expiring reverts affected instances to `Pending`.

**Carry-forward (multi-day breaks).** After each run generates breaks, a carry-forward step auto-marks any Pending instance whose SeriesKey holds an active justification as `JustifiedCarriedForward`, referencing the originating justification — **users justify once, not daily**. Rules governing when carry-forward stops:

1. *Continuity*: applies while the break persists continuously. If the break resolves and reappears after more than N business days (configurable gap tolerance, default N=0), the reappearance is treated as a new event → `Pending`.
2. *Materiality guard* (optional per justification or per category): carry-forward applies only while the break magnitude stays within a tolerance band of `MagnitudeAtJustification`; beyond it, the instance reverts to `Pending` flagged "re-justification required — magnitude changed."
3. *Explicit expiry*: `ValidUntil` reopens the series after that date even if the break persists (e.g., "justified through month-end pending system fix").

Carried-forward status is visually distinct from same-day justification in the grid and in reports, and break aging (`ConsecutiveDays`, aged > N highlighted) is surfaced in the workbench and the EOD summary.

**Completeness predicate** (drives everything downstream):
```
IsComplete(businessDate, system, desk) := COUNT(breaks WHERE Status = Pending) = 0
```
Exposed via `GET /recon/completeness?businessDate&system&desk` and shown as a KPI on the workbench.

**Notification bar.**
- Persistent UI element showing a badge with the user's total pending count (scoped to their desks).
- Expanding lists pending items grouped by business date / system / desk; each entry **deep-links into the workbench pre-filtered** to exactly those breaks.
- Counts pushed via SignalR: recomputed on run completion and on every justification create/delete event.
- Escalation reminders as report cutoff approaches (configurable, e.g., T-60 and T-30 min) to analysts and the desk's BusinessManager, via notification bar + email.

**EOD report gate.**
- The report job's first step is the completeness check for every desk in the report's scope.
- If any desk is incomplete: **the report is not sent.** An escalation notification lists exactly which breaks are pending and who owns them; the gate decision is audited.
- The job re-arms on justification events (or short-interval recheck) and dispatches automatically the moment completeness is reached — no manual re-trigger needed.
- Optional (policy-gated, default off): `RiskManager` force-release with mandatory documented override reason, for exceptional days. Every release path (auto on completeness / forced) is stamped on the report record.

```
POST /reports/dispatch                 → 409 Conflict + pending-breaks manifest if incomplete
POST /reports/{id}/force-release       (RiskManager policy, comment required)
GET  /recon/completeness?businessDate&system&desk
GET  /notifications/pending            (badge/panel datasource; SignalR channel for push)
```

---

## 7. API Design

Versioned under `/api/v1`. All reads scoped by the caller's desk/division claims via a query-layer filter (never UI-only). ProblemDetails for errors. Cursor/keyset pagination on large lists.

```
# Results & breaks
GET  /recon/results?businessDate&system&desk&page&sort        (grid datasource endpoint,
GET  /recon/breaks?businessDate&system&desk&status&severity    supports AG Grid server-side
POST /recon/grid-query                                         pivot/group requests)

# Runs
POST /recon/runs { businessDate, system }        → 202 Accepted + runId (idempotent enqueue)
GET  /recon/runs/{runId}                          → status, progress, stats
GET  /recon/runs?businessDate&system              → run history (versions)

# Justifications
POST /justifications/bulk
     { selection: { breakKeys: [...] } | { filter: {...} },  # explicit or filter-based
       reason, category, validUntil? }
     → returns affected count; optimistic concurrency via rowversion
GET  /justifications?seriesKey | ?businessDate&desk
DELETE /justifications/{id}                       (with audit)

# Thresholds (maker-checker)
GET    /thresholds?division&desk&product          (scoped)
POST   /thresholds                                 → Draft
PUT    /thresholds/{id}                            → Draft (new version)
POST   /thresholds/{id}/submit                     → PendingApproval
POST   /thresholds/{id}/approve | /reject          (RiskManager policy; comment required on reject)
GET    /thresholds/pending-approval                (risk manager inbox)

# Operations (ITSupport policy)
GET/PUT /ops/jobs                                  (schedules; PUT returns next N fire times)
GET/POST/PUT/DELETE /ops/watchers                  (watcher CRUD)
POST /ops/watchers/test { regex }                  → matches/misses vs recent real filenames
GET  /ops/monitor/files?businessDate&system        (expected vs received vs loaded + row counts)
GET  /ops/monitor/runs?businessDate&system         (run timeline + status + errors)
GET  /ops/deadletter                                POST /ops/deadletter/{fileId}/reprocess

# Reporting (Trader policy for config + dispatch)
GET/POST/PUT /reports/configs                      (Desks[] scope ⊆ creator's access; recipients,
                                                    cc, subject template, schedule, GPN list)
POST /reports/configs/validate-gpns { gpns[] }     → Graph resolution result (email | unresolvable)
POST /reports/dispatch { configId, businessDate }  → 202; render once, one email per GPN
                                                   → 409 + pending-breaks manifest if any desk
                                                     in config scope is incomplete
GET  /reports/dispatches?businessDate&configId     (per-GPN status: sent/failed/blocked/retrying)
POST /reports/dispatches/{id}/retry                (single-GPN retry, no duplicate fan-out)
POST /reports/{id}/force-release                   (RiskManager policy, comment required)
GET  /recon/completeness?businessDate&system&desk
```

### Authorization model

**Identity:** Microsoft Entra ID. **One security group per profile** (12 groups), resolved app-side via a mapping table `GroupId → (Role, ScopeType, ScopeValue)`:

| Entra group | Role | Scope |
|---|---|---|
| valrec-trader-ib-derivatives-solutions | Trader | Desk: IB / Derivatives & Solutions |
| valrec-trader-ib-execution-services | Trader | Desk: IB / Execution Services |
| valrec-trader-gt | Trader | Desk: GT |
| valrec-read-ib-derivatives-solutions | Read | Desk: IB / Derivatives & Solutions |
| valrec-read-ib-execution-services | Read | Desk: IB / Execution Services |
| valrec-read-gt | Read | Desk: GT |
| valrec-bm-ib-derivatives-solutions | BusinessManager | Desk: IB / Derivatives & Solutions |
| valrec-bm-ib-execution-services | BusinessManager | Desk: IB / Execution Services |
| valrec-bm-gt | BusinessManager | Desk: GT |
| valrec-riskmanager-ib | RiskManager | **Division: IB** (covers both IB desks) |
| valrec-riskmanager-gt | RiskManager | Division: GT |
| valrec-itsupport | ITSupport | Global (ops only) |

Data rows carry `Division` + `Desk`. Scoping filter: division-scoped users see all desks within their division; desk-scoped users see only their desk. Adding a desk later = new groups + mapping rows, no code change. A user may hold multiple profiles (union of scopes/permissions).

**Permission matrix:**

| Capability | Trader | Read | BusinessManager | RiskManager | ITSupport |
|---|---|---|---|---|---|
| View recons/breaks (scoped) | ✓ | ✓ | ✓ | ✓ | — |
| View thresholds | ✓ | ✓ | ✓ | ✓ | — |
| View justifications | ✓ | ✓ | ✓ | ✓ | — |
| Justification CRUD (incl. bulk) | ✓ | — | — | — | — |
| Threshold CRUD / submit (maker) | — | — | ✓ | — | — |
| Threshold approve/reject (checker) | — | — | — | ✓ | — |
| Force recon re-run | ✓ | — | — | — | — |
| Trigger/send EOD report | ✓ | — | — | — | — |
| Report force-release override | — | — | — | ✓ (policy-gated, default off) | — |
| Ops config (job cron, watcher regex) | — | — | — | — | ✓ |
| Monitoring dashboards / dead-letter view | — | — | — | — | ✓ |
| Dead-letter reprocess (failed ingestion) | — | — | — | — | ✓ |

Notes:
- Traders view thresholds (read-only, confirmed); only BusinessManagers create/edit them (maker), only RiskManagers approve (checker) — separation of duties is structural (different roles), plus submitter ≠ approver enforced.
- Ingestion *reprocess* (IT) vs recon *re-run* (Trader) are distinct actions with distinct owners — reprocess fixes a failed file load; re-run recomputes reconciliation on loaded data.
- Self-consistency: the Trader is both justification maker and report sender, and the completeness gate prevents dispatching their own desk's report with pending items.
- All policies enforced at the query/command layer (never UI-only); authorization matrix covered by an automated test suite enumerating profile × endpoint.

---

## 8. Frontend & UX

- **Break workbench** as the home screen: KPI strip (total breaks, by severity, by system), AG Grid with server-side pivot replicating the Excel views, saved/shared view configurations (replaces macros).
- **Bulk justification flow**: select rows *or* "select all matching current filter" → side panel with reason/category → preview affected count → confirm. Undo window (soft delete) for safety.
- **Run console**: trigger re-run, live progress via SignalR, run history with version diff ("what changed between v1 and v2").
- **Threshold admin**: scoped editor for managers; approval inbox for risk managers with before/after diff view.
- **Report configuration**: per-desk config editor (recipients, cc, subject template with token preview, schedule time, owner GPN list with live Graph validation, visualization picker with HTML preview) + a dispatch monitor showing per-GPN send status with retry.
- Accessibility & performance: virtualized grids only, keyset pagination, skeleton loading, optimistic updates for justifications.

---

## 9. Cross-Cutting Concerns

- **Audit**: every mutation (justify, threshold change, re-run trigger) appended to `audit.Event` with actor, before/after. Non-negotiable in a risk-adjacent tool.
- **Observability**: trace per RunId end-to-end (file → staging → recon → API). Metrics: ingestion rows/s, run duration, break counts, API p95. Alerts on missing files by cutoff time.
- **Resilience**: Polly retry with jitter on I/O; Hangfire automatic retries with capped attempts → dead-letter + alert.
- **Security**: OIDC, HTTPS only, no credentials in code/config (Key Vault / corporate secret store), parameterized SQL everywhere, scoped reads at the data layer.
- **Testing**: golden-file tests per adapter (real anonymized samples), recon engine tested against hand-computed fixtures, contract tests on the API, Playwright smoke tests on the workbench.

---

## 10. Implementation Plan & Task Breakdown

### Phase 0 — Decisions & scaffolding (1 wk)
- [ ] Confirm frontend stack (React+AG Grid vs Blazor) and AG Grid Enterprise licensing
- [ ] Confirm IdP integration (Azure AD / ADFS) and group→claim mapping for desks/divisions
- [ ] Repo, solution skeleton, CI/CD (build, tests, static analysis), environments (dev/uat/prod)
- [ ] Architecture tests wired (layer rules fail the build)

### Phase 1 — Foundations (2–3 wks)
- [ ] Database schema v1 (staging, canonical, recon, thresholds, justifications, audit) + migrations
- [ ] Entra ID integration: app registrations (SPA + API), MSAL React, Microsoft.Identity.Web, 12 profile groups + GroupId→(Role,Scope) mapping table, policy framework, query-layer scoping filter (desk vs division scope)
- [ ] Authorization matrix test suite: automated profile × endpoint coverage (12 profiles, allow/deny per route)
- [ ] Hangfire setup + dashboard (secured), Serilog/OTel plumbing, health checks
- [ ] Contracts project + TypeScript client generation pipeline

### Phase 2 — Ingestion (3–4 wks)
- [ ] `ISourceAdapter` per file type — global: GR.BrazilRec, GR.BrazilAttribution, GR.MRCErrors, MOR.Positions, MOR.Measures, MOR.FXRates, APEX, MUREX; local: RISCO×5 (per global system)
- [ ] Streaming SqlBulkCopy pipeline + batching + backpressure; per-file-type staging tables
- [ ] File validation pass + dead-letter handling + diagnostic report
- [ ] ManifestCompletionTracker (DB-backed) driven by ops.FileManifest; OnLateOptional behavior; idempotency by file hash
- [ ] Assembly step per system: MOR position+measure join with FXRates conversion; GR BrazilRec+Attribution combine + MRC errors application; APEX/MUREX single-file normalization; RISCO normalization
- [ ] Golden-file tests per adapter + per assembler (anonymized real samples)
- [ ] ops.* config tables + hot-reload of watcher/schedule/manifest config in Workers
- [ ] FileEvent tracking with per-stage row counts (source header vs staged vs loaded)

### Phase 3 — Recon engine (3–4 wks)
- [ ] Canonical aggregation to matching grain
- [ ] Matching (full outer join) + position-break classification
- [ ] Threshold resolution with precedence + measure-break classification
- [ ] Versioned runs (IsLatest flip), Instance/Series key generation, BreakSeries aging (FirstSeen/ConsecutiveDays)
- [ ] Carry-forward step: auto-justify persisting breaks from active series justifications (continuity, materiality guard, ValidUntil rules)
- [ ] Re-run job + `POST /recon/runs` (202 + status resource) + SignalR progress
- [ ] Engine fixtures: hand-computed golden datasets, boundary cases (exactly-at-threshold), carry-forward scenarios (persisting, gap-reappearance, magnitude jump, expiry)

### Phase 4 — Read APIs & workbench UI (3–4 wks)
- [ ] Grid datasource endpoint supporting AG Grid server-side pivot/group/filter
- [ ] Results/breaks/run-history endpoints, keyset pagination, output caching for reference data
- [ ] Break workbench: KPI strip, pivot grid, saved views (create/share)
- [ ] Run console UI (trigger, progress, version diff)

### Phase 5 — Justifications & thresholds (2–3 wks)
- [ ] Bulk justification endpoint (IDs + filter-based), rowversion concurrency, audit
- [ ] JustificationStatus lifecycle (Pending/Justified/CarriedForward), completeness endpoint + workbench KPI, carried-forward visual distinction + aging column in grid
- [ ] Notification bar: pending datasource + SignalR push on run completion / justification events, deep links to pre-filtered workbench
- [ ] Escalation reminders at configurable offsets before report cutoff
- [ ] Justification UI flow (selection → preview count → confirm → undo window)
- [ ] Threshold CRUD with effective dating + versioning
- [ ] Maker-checker state machine + approval inbox + separation-of-duties policy
- [ ] Threshold admin UI with before/after diff

### Phase 5b — Operations console (1–2 wks, parallelizable with Phase 5)
- [ ] Ops APIs: job schedules (with next-fire-times preview), watcher CRUD, regex test endpoint
- [ ] Monitoring dashboard: file status board, run board, data quality strip
- [ ] Dead-letter view + reprocess action
- [ ] Cutoff-breach alerting (email/Teams) driven by watcher config + calendar
- [ ] ITSupport policy + authorization matrix tests (no business-data access)

### Phase 6 — Reporting (2–3 wks)
- [ ] Visualization catalog (breaks by desk, trends, top offenders, threshold utilization)
- [ ] ReportConfig CRUD + UI (explicit Desks[] scope validated against creator's access, recipients, cc, subject template with tokens, schedule time/timezone/calendar, GPN distribution list, visualizations, format) — versioned + audited
- [ ] GPN→email resolution via Microsoft Graph (employeeId lookup), validation at config save, cached with daily refresh, dispatch-time re-validation with ops alert on failure
- [ ] Fan-out: render report **once** per config (content scoped to config Desks[], identical for all GPNs) → send N individually addressed emails; ReportDispatch record per GPN with per-GPN retry (no duplicate sends on partial failure)
- [ ] Owner-validity check at dispatch: disable config + ops alert if creator no longer holds a valid Trader profile
- [ ] Scheduled dispatch per config (timezone + holiday calendar aware) + on-demand trigger
- [ ] Completeness gate across **all desks in config scope**: block dispatch on any pending justifications, escalation manifest, auto-release on completeness, audit of gate decisions
- [ ] Force-release path (RiskManager policy, comment required, default disabled)
- [ ] Dispatch monitor view (per-GPN status per business date) + retry action

### Phase 7 — Hardening & migration (2–3 wks)
- [ ] Load tests with production-scale files; tune indexes/batch sizes; run-duration budget
- [ ] Security review (authz matrix test suite), penetration checklist
- [ ] **Parallel run vs Excel process for a full month-end cycle — outputs must tie out**
- [ ] Discrepancy log + sign-off with business/risk managers
- [ ] User training, runbooks, on-call playbook, cutover + Excel decommission plan

### Rough total: ~19–25 weeks for a 2–3 dev team; phases 4/5/5b parallelizable with 3+.

---

## 11. Key Risks & Mitigations

| Risk | Mitigation |
|---|---|
| Users reject grid vs Excel pivots | AG Grid server-side pivot + saved views; involve power users from Phase 4 demos |
| Recon output differs from legacy | Parallel run acceptance gate; golden fixtures; discrepancy log with sign-off |
| Layout drift in source files | Adapter-level schema validation; dead-letter with diagnostics; versioned adapters |
| Re-runs orphaning justifications | Stable BreakKey design; re-attach logic tested explicitly |
| Threshold changes applied silently | Maker-checker + effective dating + `ThresholdApplied` stamped on every result |
| Missing EOD files | Cutoff-time alerting on expected-vs-received per file type (manifest-driven) |
| FX inconsistency creates phantom breaks | Convert MOR data with MOR's own FXRates file; confirm RISCO reporting currency; FX applied in assembly step, stamped on canonical rows |
| Partial manifest at cutoff (e.g., 2 of 3 MOR files) | Recon never runs on partial data; file board shows exactly which type is missing; escalation alert |
| Report gate blocks indefinitely (analyst absent, disputed break) | Escalation chain to BusinessManager; policy-gated RiskManager force-release with documented override |
| Carried-forward justifications go stale ("permanent wallpaper") | Materiality guard, optional ValidUntil, aging highlights in reports, periodic aged-break review view for risk managers |
