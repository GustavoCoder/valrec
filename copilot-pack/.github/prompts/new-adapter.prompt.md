---
mode: agent
description: Implement a new file-type ingestion adapter following the reference pattern
---
Implement the ingestion adapter for **{{SYSTEM}}.{{FILE_TYPE}}**.

CONTEXT
- Pattern reference (follow structure, style, error handling exactly): #file:src/Valrec.Infrastructure/Ingestion/Adapters/MorPositionsAdapter.cs and #file:tests/Valrec.UnitTests/Ingestion/MorPositionsAdapterTests.cs
- Interface: #file:src/Valrec.Application/Ingestion/ISourceAdapter.cs
- Rules: #file:docs/specs/file-manifest.md

LAYOUT ({{DELIMITER}}-delimited, encoding {{ENCODING}}, decimal separator {{DECIMAL_SEP}}, date format {{DATE_FORMAT}})
| Pos | Field | Type | Nullable | Notes |
|---|---|---|---|---|
| 1 | {{...}} | {{...}} | {{...}} | {{...}} |
<!-- complete the field table; include header/trailer format if present -->

EDGE CASES
- {{e.g., trailing optional columns, quoted fields containing the delimiter, thousands separators}}

ACCEPTANCE
- New golden fixture in tests/fixtures/{{system}}/ with expected staged rows asserted exactly.
- Tests for: valid file, malformed line (collected, not thrown), header/trailer count mismatch (rejected), comma-decimal parsing.
- No changes outside: the new adapter file, its test file, its fixture folder, DI registration.

CONSTRAINTS
- Streaming only (IAsyncEnumerable + yield); no ReadToEnd.
- No cross-file logic, no FX, no business rules (assembler's job).
- No new packages.
