# Valrec — Copilot Starter Pack

Drop the `.github/` and `docs/` folders into the repo root. Contents:

```
.github/
├── copilot-instructions.md          # repo-wide invariants — loads on EVERY request; keep short
├── instructions/                    # path-scoped — load only when matching files are in play
│   ├── ingestion.instructions.md    #   adapters & assemblers
│   ├── api-application.instructions.md
│   ├── sql.instructions.md
│   ├── frontend.instructions.md
│   └── tests.instructions.md
└── prompts/                         # reusable templates (VS Code: type / in Copilot Chat)
    ├── new-adapter.prompt.md        #   fill layout table → one adapter per run (13 needed)
    ├── new-endpoint.prompt.md       #   vertical API slice with authz + audit + tests
    └── engine-from-fixtures.prompt.md  # tests-are-the-spec pattern for engine logic
docs/specs/                          # reference by #file: in prompts — never paste content
├── break-keys.md
├── carry-forward.md
├── threshold-precedence.md
├── file-manifest.md
├── authz-matrix.md
└── report-dispatch.md
```

## Working rules (token efficiency)
1. **Exemplars before volume.** Hand-review one reference implementation per pattern (first adapter, first handler/endpoint, first grid datasource), then stamp the rest via the prompt templates referencing it.
2. **One slice per chat.** Fresh session per task; long sessions re-send their full history every turn.
3. **Reference, don't paste.** `#file:docs/specs/carry-forward.md` beats paraphrasing it. Paste verbatim only contracts (interfaces, DTOs, DDL) the model must match exactly.
4. **Tests as spec** for correctness-critical logic: commit failing golden-fixture tests yourself, then use `engine-from-fixtures`.
5. **Hand-write or review at 100%:** BreakKeyFactory, threshold precedence resolution, carry-forward rules, the recon SQL, IScopedQueryFilter. Small, catastrophic if subtly wrong.
6. **Targeted edits, not regeneration** when iterating: "in file X, change Y" — never "regenerate the file".
7. Placeholders `{{LIKE_THIS}}` in prompt files must be filled before running. Reference file paths in prompts assume the exemplars exist — update paths after Phase 1 creates them.

## Open items still flagged inside specs (confirm before relying on them)
- MRC errors file semantics (file-manifest.md §6)
- MOR IB vs GT layout parity (file-manifest.md §7)
- RISCO reporting currency / FX treatment
- Corrected-report policy after post-dispatch re-runs (report-dispatch.md)
