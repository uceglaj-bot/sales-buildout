# Dealer Portal Speed-Up — Progress Log

Plan: [dealer-portal-performance-plan.md](./dealer-portal-performance-plan.md)
Lovable project: Dealers (`51258854-583d-48bc-ba00-6c811088a9f5`)

| # | Phase | Status | Lovable commit | Notes |
|---|---|---|---|---|
| 1 | Navigation: auth check, cache, preload, loaders, skeletons | **done** | `bc22124` | 329/329 tests pass; all 13 loader keys verified to match page keys |
| 2 | RLS + indexes migration (plan Phase 3) | **done** | `0de3c06` (migration 0022) | new rules proven equivalent: 116 simulated scenarios, 18,363 rows, 0 mismatches. Dry run (rolled back): admin deals+appointments 279 ms → 15 ms, same 326 deals. Post-apply live check through real RLS as `authenticated`: 87 scenarios, 0 mismatches. 329/329 tests pass |
| 1b | Fix: stale data on admin dealership switch; cache reset only on real user change | **done** | `e8a83e5`, `369031e` | 329/329 tests pass |
| 3 | Single viewer RPC + parallel queries (plan Phase 2) | **done** | `14071f1` (migration 0023) | Caller lookup: 4 serial DB trips → 1 RPC (~1 ms warm, 48 ms cold, timed live for each admin). Dashboard 3 serial steps → 1; deal sheet 2 → 1; pay 3 → 2; appointments up to 9 → 3–4. 333/333 tests pass (4 new), typecheck clean. Anon cannot call the RPC |
| 4 | Dashboard summary + lean lists (plan Phase 2.6) | **done** | `a9932c6` | getDashboard response 188,149 → 1,823 bytes (−99%); listDeals 203,619 → 135,759 bytes (−33%), measured on the largest dealership. Summary verified against the old in-browser math (new test). DashboardPage markup reviewed: unchanged. Viewer-mutation fix included. 337/337 tests pass, typecheck clean |
| 5 | Lender Hub off hot path (plan Phase 4) | in progress | — | |
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
- First migration attempt was rejected by Postgres (`uuid = uuid[]`): `= any((select fn()))` reads as a subquery, not an array. Fixed with explicit `::uuid[]` / `::text[]` casts; nothing had been applied (the migration rolled back as a whole).
- Supabase re-emits SIGNED_IN on tab focus. The cache now resets only when the signed-in user actually changes, so switching back to the app no longer reloads everything.
- Phase 2 side effect (flagged by Lovable): `requireAppointment` mutates the viewer in place for a rep acting on another dealership's appointment. Because the viewer is now memoized per request, the change sticks for the rest of that one call (never across requests). Harmless today (one appointment per call), but it will be fixed in the next code change by cloning instead of mutating.
- `pay_items.deal_id` has no foreign key to `deals`, so deal names can't be embedded. They still come from one extra read after the pay items load.
- Live (published) app is `ayvo-deal-buddy.lovable.app`, which is still the old build until Publish. Sign-in page: TTFB 0.8–1.8 s, 13 JS/CSS files, **233 kB compressed** (826 kB raw). Checked the client bundle for server secrets/server-only code: none (the 58 kB `portal.functions` chunk is the Supabase client library).
