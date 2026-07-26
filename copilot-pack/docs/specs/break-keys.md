# Spec: Break Keys

Two-level identity for breaks. Cross-side identity uses **ResolvedMatchKey** (the key both
sides were actually matched on — see matching-rules.md), never raw MatchingKey and never
PositionKey (which is side-local and not comparable across sides).

```
InstanceKey = SHA256(BusinessDate | System | Division | Desk | Product | Underlying | ResolvedMatchKey | CanonicalMeasure | Dimension)
SeriesKey   = SHA256(              System | Division | Desk | Product | Underlying | ResolvedMatchKey | CanonicalMeasure | Dimension)
```

Rules:
1. Field order and delimiter (`|`) are fixed. Fields canonicalized before hashing: trimmed, upper-cased, dates as `yyyy-MM-dd`, null components (e.g. absent Dimension) as the literal `~NULL~`.
2. For position breaks (existence mismatch, no measure involved), `CanonicalMeasure = ~POSITION~` and `Dimension = ~NULL~`.
3. `InstanceKey` identifies a break on a specific day; unique per (RunId, InstanceKey).
4. `SeriesKey` identifies the recurring break across days. **Justifications attach to SeriesKey only.**
5. Re-runs within a day regenerate identical keys → justifications survive intra-day re-runs automatically.
6. `recon.BreakSeries` tracks per SeriesKey: `FirstSeenDate`, `LastSeenDate`, `ConsecutiveDays`, `IsActive`. Updated in each run's post-processing.
7. Keys computed in one place (`Valrec.Domain.BreakKeyFactory`) and never re-implemented elsewhere. Any change to composition is a breaking change requiring a data migration plan.

Golden test vectors (must not change without migration):
```
Measure break:
Input : 2026-07-10 | MOR | IB | DERIV_SOLUTIONS | FX_FORWARD | USD | MK789 | PV | ~NULL~
SeriesKey = SHA256("MOR|IB|DERIV_SOLUTIONS|FX_FORWARD|USD|MK789|PV|~NULL~")

Position break (existence mismatch):
Input : 2026-07-10 | MOR | IB | DERIV_SOLUTIONS | FX_FORWARD | USD | MK789 | ~POSITION~ | ~NULL~
SeriesKey = SHA256("MOR|IB|DERIV_SOLUTIONS|FX_FORWARD|USD|MK789|~POSITION~|~NULL~")
```
