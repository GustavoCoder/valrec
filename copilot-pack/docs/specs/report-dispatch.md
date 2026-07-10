# Spec: EOD Report Config, Gate & Dispatch

## ReportConfig (Trader-managed, versioned + audited)
Fields: `Desks[]` (explicit scope, validated ⊆ creator's access at save/edit), `Recipients[]`, `Cc[]`, `SubjectTemplate` (tokens: `{BusinessDate}`, `{Desk}`, `{GPN}`, `{OwnerName}`), `ScheduleTime` + `TimeZone` + `CalendarId`, `OwnerGPNs[]` (distribution list), `Visualizations`, `Format (pdf|html)`, `Enabled`, `CreatedBy`.

GPN → email via Microsoft Graph (employeeId lookup): validated at config save (unresolvable → warning), cached with daily refresh, re-validated at dispatch (failure → ops alert, dispatch record Failed, others unaffected).

## Content
Rendered **once** per config per business date, scoped to the config's `Desks[]`. Every GPN receives the **identical** file in an individually addressed email (To = owner's resolved email + Recipients; Cc as configured). No per-owner content filtering.

## Completeness gate (hard block)
Dispatch is blocked while ANY desk in `Desks[]` has `Pending` breaks for the business date.
- Blocked attempt → 409 + manifest of pending breaks (which desk, which series, who last touched).
- Escalation notification to that desk's Traders + BusinessManager.
- Gate re-arms on justification events; dispatches automatically at completeness. Every gate decision audited.
- Force-release: RiskManager only, policy-gated (default disabled), mandatory comment; release path stamped on the report record.
- Post-dispatch re-run creating new Pending breaks → original marked Superseded; corrected report gated and dispatched with a "corrected" banner. [Confirm with risk managers.]

## Dispatch mechanics
- `rpt.ReportDispatch` per (ConfigId, BusinessDate, GPN): Status ∈ Sent|Failed|Blocked|Retrying, AttemptCount, MessageId.
- Retry is per-GPN: one bounced mailbox never re-sends to the others.
- Scheduled trigger: per config ScheduleTime, timezone + holiday-calendar aware. On-demand trigger available.
- Owner-validity check at dispatch: creator no longer holds a valid Trader profile → config disabled + ops alert (no silent orphan sends).
