---
mode: agent
description: Implement a vertical API slice (endpoint + handler + validator + tests) following the reference pattern
---
Implement **{{HTTP_METHOD}} /api/v1/{{ROUTE}}** — {{ONE_SENTENCE_GOAL}}.

CONTEXT
- Pattern reference (endpoint + handler + validator + tests): #file:src/Valrec.Api/Endpoints/Justifications/BulkJustifyEndpoint.cs and #file:src/Valrec.Application/Justifications/BulkJustifyHandler.cs and #file:tests/Valrec.IntegrationTests/Justifications/BulkJustifyTests.cs
- Authorization: #file:docs/specs/authz-matrix.md — this endpoint requires role **{{ROLE}}** with scope check on **{{SCOPE_FIELD}}**.
- Domain rules: #file:docs/specs/{{RELEVANT_SPEC}}.md

CONTRACT (implement exactly — do not redesign)
```csharp
// Request/response DTOs (Valrec.Contracts):
{{PASTE_DTOS_VERBATIM}}
```
Success: {{STATUS_CODE_AND_BODY}}. Failures: 400 validation ProblemDetails, 403 out-of-scope, {{OTHER_CODES}}.

ACCEPTANCE
- Integration test: happy path + out-of-scope 403 + validation 400 {{+ DOMAIN_SPECIFIC_CASES}}.
- Authorization matrix test data updated for the new route (all 12 profiles).
- Mutation writes audit.Event (assert in test).

CONSTRAINTS
- Handler depends on Application interfaces only. Scoping via IScopedQueryFilter — never from request body.
- No new packages. No changes to unrelated endpoints.
