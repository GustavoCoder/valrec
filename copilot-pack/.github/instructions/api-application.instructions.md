---
applyTo: "src/Valrec.Api/**,src/Valrec.Application/**"
---
# API & Application layer

## Endpoints
- Route prefix `/api/v1`. DTOs from `Valrec.Contracts` only — never expose Domain entities.
- Every endpoint declares an authorization policy. Policies combine role + scope per `docs/specs/authz-matrix.md`. No `[AllowAnonymous]` except health checks.
- List endpoints: keyset pagination (cursor on stable sort key), never OFFSET on large tables. Max page size enforced server-side.
- Long-running operations (recon re-run, report dispatch): return `202 Accepted` + status resource URL. Idempotent enqueue key = natural key of the operation (e.g., businessDate+system).
- Validation: FluentValidation validator per command/query, registered by assembly scan. Validation failure → 400 ProblemDetails with field errors.

## Handlers
- One handler per use case. Constructor injection; depend on Application interfaces, never Infrastructure types.
- Mutations: (1) authorize scope, (2) validate, (3) mutate inside a transaction, (4) write audit.Event, (5) publish domain event if the notification bar / gate needs recomputation.
- Queries feeding AG Grid: Dapper against read models; accept the grid request DTO (filter/sort/group/pivot) and translate to parameterized SQL via the query builder in `Infrastructure/Grid/` — do not hand-roll SQL string concatenation.

## Scoping (critical)
- Every query touching recon/threshold/justification data goes through `IScopedQueryFilter.Apply(query, userScopes)`:
  desk-scoped user → `row.Desk ∈ scopes`; division-scoped user → `row.Division ∈ scopes`.
- Never trust desk/division values from the request body; derive scope from the authenticated principal.
