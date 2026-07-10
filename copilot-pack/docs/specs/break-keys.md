# Spec: Break Keys

Two-level identity for breaks.

```
InstanceKey = SHA256(BusinessDate | System | Division | Desk | Product | Underlying | PositionKey | MeasureName)
SeriesKey   = SHA256(              System | Division | Desk | Product | Underlying | PositionKey | MeasureName)
```

Rules:
1. Field order and delimiter (`|`) are fixed. Fields are canonicalized before hashing: trimmed, upper-cased, dates as `yyyy-MM-dd`, null components as the literal `~NULL~`.
2. For position breaks (no measure involved), `MeasureName = ~POSITION~`.
3. `InstanceKey` identifies a break on a specific day; unique per (RunId, InstanceKey).
4. `SeriesKey` identifies the recurring break across days. **Justifications attach to SeriesKey only.**
5. Re-runs within a day regenerate identical keys → justifications survive intra-day re-runs automatically.
6. `recon.BreakSeries` tracks per SeriesKey: `FirstSeenDate`, `LastSeenDate`, `ConsecutiveDays`, `IsActive`. Updated as part of each run's post-processing.
7. Keys are computed in one place (`Valrec.Domain.BreakKeyFactory`) and never re-implemented elsewhere. Any change to composition is a breaking change requiring a data migration plan.

Golden test vectors (must not change without migration):
```
Input : 2026-07-10 | MOR | IB | DERIV_SOLUTIONS | SWAP | CDI | POS123 | PV
InstanceKey = SHA256("2026-07-10|MOR|IB|DERIV_SOLUTIONS|SWAP|CDI|POS123|PV")
SeriesKey   = SHA256("MOR|IB|DERIV_SOLUTIONS|SWAP|CDI|POS123|PV")
```
