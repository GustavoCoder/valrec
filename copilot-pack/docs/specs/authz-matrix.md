# Spec: Authorization Matrix

Identity: Entra ID. One security group per profile, mapped app-side: `GroupId → (Role, ScopeType, ScopeValue)`. A user may hold multiple profiles (union of permissions/scopes).

## Profiles (12)
| Group | Role | Scope |
|---|---|---|
| valrec-trader-ib-derivatives-solutions | Trader | Desk IB/D&S |
| valrec-trader-ib-execution-services | Trader | Desk IB/ExecServices |
| valrec-trader-gt | Trader | Desk GT |
| valrec-read-ib-derivatives-solutions | Read | Desk IB/D&S |
| valrec-read-ib-execution-services | Read | Desk IB/ExecServices |
| valrec-read-gt | Read | Desk GT |
| valrec-bm-ib-derivatives-solutions | BusinessManager | Desk IB/D&S |
| valrec-bm-ib-execution-services | BusinessManager | Desk IB/ExecServices |
| valrec-bm-gt | BusinessManager | Desk GT |
| valrec-riskmanager-ib | RiskManager | Division IB (both desks) |
| valrec-riskmanager-gt | RiskManager | Division GT |
| valrec-itsupport | ITSupport | Global, ops only |

## Scoping
Rows carry Division + Desk. Desk scope → `row.Desk = scope`. Division scope → `row.Division = scope`. Enforced via `IScopedQueryFilter` on every query — never UI-only. Scope derived from the principal, never from request body.

## Permissions
| Capability | Trader | Read | BM | RM | IT |
|---|---|---|---|---|---|
| View recons/breaks/thresholds/justifications (scoped) | ✓ | ✓ | ✓ | ✓ | — |
| Justification CRUD (incl. bulk) | ✓ | — | — | — | — |
| Threshold CRUD/submit (maker) | — | — | ✓ | — | — |
| Threshold approve/reject (checker) | — | — | — | ✓ | — |
| Force recon re-run | ✓ | — | — | — | — |
| Report config CRUD + dispatch | ✓ | — | — | — | — |
| Report force-release (policy-gated, default off) | — | — | — | ✓ | — |
| Ops config (jobs, watchers, manifests) | — | — | — | — | ✓ |
| Monitoring dashboards | — | — | — | — | ✓ |
| Dead-letter view + reprocess | — | — | — | — | ✓ |

Invariants: threshold submitter ≠ approver. ITSupport has zero access to business data (recons, thresholds, justifications). Traders' threshold access is read-only.
