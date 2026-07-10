# Spec: Threshold Resolution & Precedence

Thresholds define acceptable deviation between global and local values. Type: `Pct` or `Abs`. Scope columns (nullable = wildcard): `Division`, `Desk`, `Product`, `Underlying`.

## Precedence — most specific scope wins
Specificity = count of non-null scope columns; ties broken by fixed column priority `Underlying > Product > Desk > Division`.

Resolution order (first match wins):
1. (Desk, Product, Underlying)
2. (Desk, Product)
3. (Desk)
4. (Division, Product, Underlying)
5. (Division, Product)
6. (Division)
7. Global default (all null) — must always exist; seeded, cannot be deleted.

## Rules
- Only thresholds with `Status = Approved` and `EffectiveFrom <= BusinessDate < EffectiveTo` participate in resolution.
- Resolution happens at recon time; the winning `ThresholdId` + value is stamped on every `recon.Result` row (`ThresholdApplied`) — results are self-explanatory and auditable.
- Break condition: `Pct` → `ABS(DiffPct) > Value`; `Abs` → `ABS(Diff) > Value`. Exactly equal to threshold is NOT a break.
- Re-runs resolve against thresholds effective on the BusinessDate being reconciled — not the run date.

## Maker-checker lifecycle
`Draft → PendingApproval → Approved | Rejected`
- Maker: BusinessManager, scoped to their desks. Checker: RiskManager, scoped to their division. Submitter ≠ approver (enforced).
- Edits to an Approved threshold create a new version in Draft; the approved version stays effective until the new one is approved with its own EffectiveFrom.
- Every transition audited with actor + comment (comment mandatory on Reject).
