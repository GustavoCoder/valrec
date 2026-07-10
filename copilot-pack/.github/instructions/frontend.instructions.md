---
applyTo: "frontend/**"
---
# Frontend (React + TypeScript + AG Grid)

- TypeScript strict; no `any` (use `unknown` + narrowing). API types come from the generated client (`frontend/src/api/generated/`) — never hand-write DTO interfaces.
- Server state: TanStack Query only (no server data in useState/context). Query keys: `[domain, params]` arrays, e.g., `['breaks', { businessDate, system, desk }]`. Mutations invalidate affected keys.
- AG Grid: server-side row model for all recon grids. Grid requests (filter/sort/group/pivot) are sent as-is to `/recon/grid-query` — no client-side aggregation of large datasets.
- Auth: MSAL React; acquire tokens silently via the shared `useApiClient` hook. Never store tokens manually. Do not render controls the user's profile can't use — but remember enforcement is server-side; UI hiding is UX only.
- Notification bar: subscribes to the SignalR `pending` channel; deep links must carry full filter state in the URL (breaks are pre-filtered on landing).
- Components: function components + hooks only. Feature-folder structure (`features/breaks/`, `features/thresholds/`, `features/ops/`, `features/reports/`). Shared UI in `components/`.
- Dates: business dates are `YYYY-MM-DD` strings end-to-end (no Date object for BusinessDate); display formatting via the shared `formatBusinessDate` util (pt-BR aware).
- Carried-forward justification status renders visually distinct from same-day (see `features/breaks/statusBadges.tsx` once created).
