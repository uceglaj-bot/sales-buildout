# Dealer Portal Speed-Up — Progress Log

Plan: [dealer-portal-performance-plan.md](./dealer-portal-performance-plan.md)
Lovable project: Dealers (`51258854-583d-48bc-ba00-6c811088a9f5`)

| # | Phase | Status | Lovable commit | Notes |
|---|---|---|---|---|
| 1 | Navigation: auth check, cache, preload, loaders, skeletons | **done** | `bc22124` | 329/329 tests pass; all 13 loader keys verified to match page keys |
| 2 | RLS + indexes migration (plan Phase 3) | in progress | — | new rules proven equivalent: 116 simulated scenarios, 18,363 rows, 0 mismatches |
| 3 | Single viewer RPC + parallel queries (plan Phase 2) | pending | — | |
| 4 | Dashboard summary + lean lists (plan Phase 2.6) | pending | — | |
| 5 | Lender Hub off hot path (plan Phase 4) | pending | — | |
| 6 | Fonts, SW asset cache, bundle (plan Phase 5) | pending | — | |

## Baseline (before any change, 2026-10-15)

- appointments list query: 40.7 ms mean (689 calls) · deals list query: 30.4 ms mean (560 calls)
- Dashboard click: 1 Supabase Auth call + 2 server-function calls + 11 serial DB trips

## Issues found along the way

_(addressed before continuing the plan)_

- Another person is actively editing the project in Lovable at the same time (Google Calendar, appointment cards). Each phase re-reads current code before changes.
- **No dealer is linked to a login yet**: 0 of 29 members have a `user_id`; all are `invited`. Only the 4 Ayvo admins can use the portal today. Dealer-visibility rules were therefore validated by simulating each member (rep / manager / manager+ledger capability / two dealerships) inside a rolled-back transaction.
- Phase 1 note: NewDealPage uses `useQuery` (not suspense), so its loader only warms the cache. That's fine.
- Pre-existing: query keys don't include the dealership id. Admin dealership switching calls `invalidateQueries()`, which refetches, but the old dealership's cached data can flash briefly. Follow-up: clear `["real"]` queries on switch.
