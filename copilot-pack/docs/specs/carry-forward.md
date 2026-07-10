# Spec: Justification Carry-Forward

Goal: a break persisting across days is justified **once**, never daily.

## Status model
`recon.Break.JustificationStatus : Pending | Justified | JustifiedCarriedForward`

- Position breaks and over-threshold measure breaks are created `Pending`.
- Within-threshold diffs are informational: no status, never require justification.
- Creating a justification (attached to SeriesKey) sets today's instance to `Justified`.
- Deleting/expiring the justification reverts affected instances to `Pending`.

## Carry-forward step (runs after break generation in every recon run)
For each `Pending` instance whose SeriesKey has an `Active` justification, set `JustifiedCarriedForward` referencing the originating justification — **unless** any stop rule below applies.

## Stop rules (evaluated in order; any match → stays Pending)
1. **Continuity gap**: the series was inactive (break absent) for more than `GapToleranceBusinessDays` (config, default 0) before reappearing. Reappearance = new event → Pending; the old justification is marked `Superseded`.
2. **Materiality guard** (only if `TolerancePct` set on the justification or its category): current |magnitude| deviates from `MagnitudeAtJustification` by more than TolerancePct → Pending, flagged `RequalificationRequired: MagnitudeChanged`.
3. **Explicit expiry**: `ValidUntil < BusinessDate` → justification status `Expired`, instance Pending.

## Completeness predicate (drives notification bar + report gate)
```
IsComplete(businessDate, system, desk) := COUNT(breaks WHERE JustificationStatus = Pending) = 0
```
`Justified` and `JustifiedCarriedForward` both count as complete.

## Required test scenarios
a) Break persists 3 consecutive days, justified day 1 → days 2-3 CarriedForward.
b) Break resolves day 2, reappears day 4, gap tolerance 0 → day 4 Pending.
c) Same as (b) with gap tolerance 2 → day 4 CarriedForward.
d) Magnitude at justification 50,000; day 3 magnitude 5,000,000; tolerance 20% → day 3 Pending + flag.
e) ValidUntil = month-end; first business day next month → Pending, justification Expired.
f) Intra-day re-run reproduces same breaks → statuses unchanged.
