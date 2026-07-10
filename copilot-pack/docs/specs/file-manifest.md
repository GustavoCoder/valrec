# Spec: File Manifests & Recon Triggering

Recon unit = `(System, Division)` per BusinessDate.

| Recon unit | Mandatory global files | Optional | Local |
|---|---|---|---|
| GR – IB | BrazilRec, BrazilAttribution | MRCErrors | RISCO_GR |
| MOR – IB | Positions, Measures, FXRates | — | RISCO_MOR_IB |
| MOR – GT | Positions, Measures, FXRates | — | RISCO_MOR_GT |
| APEX – GT | ApexFile | — | RISCO_APEX |
| MUREX – GT | MurexFile | — | RISCO_MUREX |

## Rules
1. Manifests are config-as-data (`ops.FileManifest`), hot-reloaded by Workers. IT Support edits them; changes audited.
2. Recon for a unit/date is enqueued **only** when every mandatory file (global set + RISCO counterpart) is Received AND Validated. State is DB-backed (restart-safe), transition-checked so double-arrival can't double-enqueue.
3. Optional files never block. Late-arriving optional after a run started: behavior per manifest `OnLateOptional ∈ {Ignore, TriggerRerun}`, default `TriggerRerun` (safe under run versioning).
4. File identity = hash. Identical re-delivery = no-op. Changed re-delivery of any mandatory file = versioned re-run of the unit/date.
5. Validation per file: staged row count vs header/trailer declared count, mandatory fields non-null, duplicate business keys. Any failure → whole file to dead-letter with diagnostic report; never partially load.
6. Assembly (post-completion, per system): MOR joins Positions+Measures and applies FX from MOR's own FXRates file (rate stamped on canonical rows); GR combines BrazilRec+BrazilAttribution and applies MRCErrors [semantics TBC with file owner]; APEX/MUREX/RISCO normalize single files.
7. Adapters shared where layouts match: MOR–IB and MOR–GT use the same adapters/assembler with distinct watcher + manifest configs [layout parity TBC].
8. Cutoff alerting: each `(unit, FileType)` has `ExpectedCutoffTime` + holiday calendar; breach → ops alert showing exactly which file types are missing.
