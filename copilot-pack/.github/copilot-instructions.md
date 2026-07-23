# Valrec — Repository Instructions

Valuation reconciliation system: ingests EOD files from global systems (GR, MOR×2, APEX, MUREX) and local RISCO counterparts, reconciles positions/measures against thresholds, manages break justifications and EOD report dispatch.

## Stack
- Backend: C# / .NET 8, ASP.NET Core, EF Core (CRUD/workflow) + Dapper (hot read paths), Hangfire (jobs), SignalR, FluentValidation, Polly, Serilog + OpenTelemetry, QuestPDF.
- Database: SQL Server. Recon/matching logic is set-based SQL over columnstore tables — never row-by-row in C#.
- Frontend: React 18 + TypeScript (strict), Vite, TanStack Query, AG Grid Enterprise (server-side row model), MSAL React.
- Auth: Microsoft Entra ID. `Microsoft.Identity.Web` on the API.

## Solution layout & dependency rules
```
Valrec.Domain        → no dependencies
Valrec.Application   → Domain only
Valrec.Infrastructure→ Application, Domain
Valrec.Contracts     → no dependencies (DTOs only)
Valrec.Api           → Application, Contracts
Valrec.Workers       → Application, Infrastructure
```
Never violate these (enforced by architecture tests). Interfaces (ports) live in Application; implementations in Infrastructure.

## Non-negotiable invariants
- Every mutation writes to `audit.Event` (actor, before/after JSON, timestamp). No exceptions.
- All data reads are scoped: apply the desk/division scoping filter from `IScopedQueryFilter`. Authorization is enforced server-side (policies), never UI-only.
- Recon runs are immutable and versioned (`RunId`, `IsLatest`). Never UPDATE recon results — new version.
- Justifications attach to `SeriesKey`, never `RunId` or `InstanceKey`.
- Parameterized SQL only. No string-concatenated SQL anywhere.
- SQL Server credentials come from HashiCorp Vault at runtime via `ISqlConnectionFactory` — never embed credentials in connection strings, appsettings, or user secrets. All DB access (EF, Dapper, SqlBulkCopy, Hangfire) obtains connections through the factory. Never log credentials or Vault tokens.
- Async end-to-end: no `.Result`/`.Wait()`; `CancellationToken` on every async signature.
- Optimistic concurrency (`rowversion`) on user-editable entities.

## Conventions
- Nullable reference types enabled; treat warnings as errors.
- Handlers: one file per use case, `{Verb}{Noun}Handler` (e.g., `SubmitThresholdHandler`).
- Tests: xUnit + FluentAssertions + NSubstitute; Testcontainers for SQL Server integration tests. Test name: `Method_Scenario_ExpectedOutcome`.
- API errors: RFC 7807 ProblemDetails. Success with resource creation → 201 + location; async job accepted → 202 + status resource.
- Do not add NuGet/npm packages without being explicitly asked.

Detailed specs live in `docs/specs/` — reference them, don't guess domain rules.
