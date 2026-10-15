# Dealer Portal (Lovable "Dealers") — Performance Audit & Speed-Up Plan

**Project:** Lovable → Uros' Lovable → **Dealers** (`51258854-583d-48bc-ba00-6c811088a9f5`)
**Stack:** TanStack Start (React 19) on Cloudflare Workers + Lovable Cloud (Supabase Postgres, RLS) + TanStack Query
**Audited at commit:** `ec4cbd5` (2026-10-15)

---

## 1. Summary

The portal is slow because of **how many network trips sit in a line before a page can show anything**. The amount of data isn't the problem.

- The database is tiny: **326 deals, 580 appointments, 29 members, 7 pay items**. Every table except the sync log is under 1.2 MB.
- Even so, opening the Dashboard waits on **3 browser trips plus 11 database trips, one after another**. Appointments, Pay, New Deal and Resources are as bad or worse. New Deal and Resources also wait on calls to the Bank Portal (Lender Hub), which take about 1 s each.
- Nothing is cached between page views. The app re-fetches who you are (`me`) on **every** click, and every server function looks up "who is this user" again from scratch, with 4 database trips, one of them a write.
- No page shows a loading state. Pages read their data with `useSuspenseQuery` and there is no pending component, so after a click the old page sits frozen and then jumps. That makes the slowness feel worse than it is.
- Every row-level-security (RLS) policy calls a security-definer function **for every row** and doesn't wrap `auth.uid()`. A query for 326 deals takes **~30 ms**, and 580 appointments take **~41 ms**. It should be 1–3 ms. This cost grows with every row added, so it will be the next bottleneck after the waterfalls are fixed.

**Fixing these in the order below should bring a normal page change from roughly 1.5–3 s down to under ~300 ms, and often to instant (data already loaded on hover).** It should bring cold loads (first open, PWA launch, refresh) from roughly 3–5 s down to about 1–1.5 s. The ranges are estimates from the trip counts below. Section 8 explains how to measure them before and after.

---

## 2. Evidence

### 2.1 Database facts (queried live)

| Table | Rows | Size | Note |
|---|---|---|---|
| goayvo_sync_log | 6,295 | 7.3 MB | grows forever, no index used (0 idx scans) |
| deals | 326 | 1.1 MB | avg row 1.7 KB (snapshot ~0.9 KB) |
| appointments | 580 | 0.97 MB | |
| members | 29 | 120 KB | **454,862 index scans**: hit on every RLS check |
| ayvo_admins | 6 | 64 KB | **437,664 seq scans**: `is_ayvo_admin()` runs per row |
| dealerships | 6 | 96 KB | **169,564 seq scans**: RLS joins per row |

`pg_stat_statements`, top app queries:

| Query | Calls | Mean |
|---|---|---|
| appointments select (portal) | 689 | **40.7 ms** for ≤580 rows |
| deals select (portal) | 560 | **30.4 ms** for ≤326 rows |
| deals `dealership_id,stage_label` | 125 | 36.4 ms |

Without per-row RLS function calls, those queries would take low single-digit milliseconds.

### 2.2 Network facts (measured from the audit container)

- Supabase REST round trip: **~230 ms** warm, ~520 ms cold. From the Cloudflare edge it is usually lower, but it still applies to *every* trip in a serial chain.
- Bank Portal (`lender-deal-orchestrator.lovable.app`) `/lenders` and `/programs`: **0.9–1.3 s**, and that was just to return a 401.
- Supabase signs JWTs with ES256, so `getClaims()` checks them locally. Auth checks inside server functions are fine. The cost is everything that comes after them.

---

## 3. Where the time goes: request waterfalls

### 3.1 Every page change (`src/routes/_authenticated/route.tsx`)

```
click → beforeLoad
  ① supabase.auth.getUser()            browser → Supabase Auth   (network, every click)
  ② fetchQuery(meQuery, staleTime: 0)  browser → server fn getMe (every click, cache ignored)
        getAdmin(): ayvo_admins by user_id → (miss) → ayvo_admins by email     DB×2 serial
        getViewer(): getAdmin() AGAIN (2 more) → UPDATE members … → SELECT members   DB×4 serial
→ only now does the page component mount and start fetching its data
```

- `getUser()` always calls Supabase Auth over the network. `getSession()` reads the token already stored in the browser.
- `staleTime: 0` throws away the 60 s `staleTime` set on `meQuery`.
- `getMe` runs `getViewer` and `getAdmin` side by side, but `getViewer` calls `getAdmin` again inside itself, so the admin lookup happens twice.
- `getViewer` runs an **UPDATE on `members`** on every call: the "claim invited member rows" step. It is a write on the hot path and it almost never changes anything.

### 3.2 Every server function (`src/lib/portal.server.ts` → `requireViewer`)

Every data call (`getDashboard`, `listDeals`, `getDeal`, `getPay`, `getTeam`, `getAppointments`, `getSettings`, every action…) starts with `requireViewer()`. That is **4 serial DB trips** (admin by user id → admin by email → member-claim UPDATE → member+dealership SELECT) before any real work begins. Nothing is cached per user or per request.

### 3.3 Page by page

| Page | Server function | Serial DB trips | Other blockers |
|---|---|---|---|
| Dashboard | `getDashboard` | 4 (viewer) + 1 (deals/pay/invites ‖) + 1 (work_orders) + 1 (rep_dashboards) = **7** | Ships up to 500 full deal rows (with `intake`, `sale`, `flags`, `recipients` JSON) and all pay rows to the browser, only to count and sum them |
| Deals | `listDeals` | 4 + 1 = **5** | Up to **2,000** deals with JSON columns plus every submission payload; filtering is done in the browser |
| Deal detail | `getDeal` | 4 + 1 (deal) + 1 (notes/uploads/members ‖) + 1 (pay/ledger ‖) = **7** | pay/ledger could run alongside notes |
| Appointments | `getAppointments` | 1 (disposition) + 4 (viewer) + 3 (rep "person" lookups, serial) + 1 (data) = **9** | Up to 5,000 appointments + 2,000 events, ~41 ms query from RLS |
| Pay | `getPay` | 4 + 1 + 1 (ledger) + 1 (deal names) = **7** | Up to 5,000 pay rows + 5,000 ledger rows |
| New Deal | `getNewDealContext` | 4 + 1 (members) + 1 (financing_options) | **2 Bank Portal HTTP calls (~1 s)**, then **one AVL HTTP call per lender** (serial after); 10 s timeouts; "cache" lives in one Worker isolate, so it misses often |
| Resources | `getResources` | 4 + 1 + Bank Portal | same Bank Portal cost as New Deal |
| Every page | `getNotifications` | 1 | polls every 60 s |

**Dashboard total on a click:** 1 Supabase Auth trip + 2 browser→server trips + **11 serial DB trips**, with nothing shown on screen in the meantime.

### 3.4 Front-end amplifiers

- `src/router.tsx`: `new QueryClient()` with **no default `staleTime`**. All data counts as stale immediately and refetches on every mount and every window focus. On phones that means every time the user switches back to the app.
- No `defaultPreload: "intent"`. Nothing is preloaded when the user hovers or touches a link, even though `defaultPreloadStaleTime: 0` is set.
- **No route `loader`s.** Data fetching only starts once the page component renders, which is after `beforeLoad` and after its code chunk has downloaded.
- **No `pendingComponent` or skeletons.** The suspense query freezes the old screen or shows a blank area.
- `ssr: false` on the whole `/_authenticated` tree. A hard refresh or PWA launch does HTML → JS → hydrate → `getUser` → `getMe` → page data, all one after another.
- Google Fonts stylesheet (Manrope 5 weights + JetBrains Mono 2 weights) blocks rendering. It is an extra DNS/TLS trip to two origins before text paints.
- The service worker caches only icons and the offline page. Hashed JS and CSS (`/assets/*`) download again from the network on every PWA launch.

---

## 4. The plan

The phases are ordered by **impact per hour of effort**. Phases 1–2 are the big user-visible win and are low risk. Each item has a ready-to-paste prompt for the Lovable agent in §7.

### Phase 1 — Stop re-checking identity on every click (front end, ~½ day, biggest perceived win)

1. **`_authenticated/route.tsx` `beforeLoad`:**
   - Replace `supabase.auth.getUser()` with `supabase.auth.getSession()`. It reads the local token and makes no network call. The server still checks the JWT on every server function, so security doesn't change.
   - Use `context.queryClient.ensureQueryData(meQuery)` instead of `fetchQuery({...meQuery, staleTime: 0})`. `me` then comes from cache for 5 minutes. Raise `meQuery.staleTime` to `5 * 60_000`.
   - Keep the `onAuthStateChange` → `invalidateQueries` in `__root.tsx`. It already clears `me` on sign-in and sign-out. Also invalidate `me` after admin actions that change selection or "view as" (dealership picker, act-as toggle).
2. **`router.tsx` QueryClient defaults:**
   ```ts
   new QueryClient({ defaultOptions: { queries: {
     staleTime: 30_000, gcTime: 10 * 60_000,
     refetchOnWindowFocus: false, retry: 1,
   }}})
   ```
   Pages that need to stay fresher (Appointments, Notifications) can set their own `staleTime` or `refetchInterval`. Turning focus refetch off stops refetch storms on phones.
3. **Router preloading & pending UI:**
   ```ts
   createRouter({ …, defaultPreload: "intent", defaultPreloadStaleTime: 0,
     defaultPendingComponent: PageSkeleton, defaultPendingMs: 150, defaultPendingMinMs: 300 })
   ```
   (`defaultPreloadStaleTime: 0` is correct *only* when TanStack Query owns the caching, which is what step 4 sets up.)
4. **Add a `loader` to every authenticated route** so data starts loading while the route's code chunk downloads, and on hover/touch:
   ```ts
   loader: ({ context }) => context.queryClient.ensureQueryData({ queryKey: ["real","dashboard"], queryFn: () => realSource.dashboard() })
   ```
   Do the same for deals, deal (`$dealId`), appointments, pay, team, resources, settings, work-orders, calendar, documents, and new deal (`newDealContext`). Pages keep their `useSuspenseQuery` with the **same query key**, so they read straight from the cache.
5. **Skeletons:** add a shared `PageSkeleton` (header bar + 3 card placeholders using the existing `ui/skeleton.tsx`) and wrap the `<Outlet/>` in `AppShell` with `<Suspense fallback={<PageSkeleton/>}>`. The sidebar and nav then stay on screen and only the content area shows the skeleton.

**Expected result:** page changes drop from 3 browser hops + 11 DB trips to **1 browser hop + 7 DB trips** before Phase 2 even starts. After the first view, revisits and hover-preloaded pages appear **instantly** from cache and refresh in the background.

### Phase 2 — One trip to resolve "who am I", and parallel queries (server, ~1 day)

1. **Single SQL function for the viewer.** Create `public.portal_viewer()` (SECURITY DEFINER, STABLE, `search_path=public`). It returns one JSON object with the admin row (by `user_id`, falling back to email from `auth.jwt()`), the selected dealership, any view-as member, and the active member row joined to its dealership. `getViewer`/`getAdmin` become **one** `supabase.rpc("portal_viewer")` call: 4 serial trips → 1.
2. **Move the member-claim `UPDATE` out of the hot path.** Run it once in `recordAuthEvent("auth.signed_in")`, which already runs at sign-in, and as a fallback only when `portal_viewer()` returns no member.
3. **Remove the duplicate `getAdmin` in `getMe`.** Use the admin object that `getViewer` already resolved.
4. **Memoize the viewer per request.** Have a `withViewer` middleware put `viewer` into the server-function `context`, so helper functions such as `requireDeal`/`requireAppointment` never look it up again.
5. **Parallelize what's left:**
   - `getDashboard`: put `work_orders` and `rep_dashboards` into the same `Promise.all` as deals/pay/invites (3 serial steps → 1).
   - `getDeal`: run notes/uploads/members **and** pay/ledger in a single `Promise.all` after the deal check.
   - `getPay`: fetch the ledger alongside items/members. Get deal names through a PostgREST embed (`pay_items.select("…, deals(customer_name)")`) instead of a second round trip.
   - `getAppointments`: run `loadDispositionOptions()` in parallel with the viewer. Collapse the three "person" lookups (`me`, `sib`, `own`) into one `members` query or a small `portal_person()` SQL function.
6. **Send less data:**
   - Dashboard: add an RPC `portal_dashboard_summary(dealership_id)` that returns stage counts, pay sums by status, the "needs action" list (≤20) and "recently moved" (≤6). Stop shipping 500 deals plus all pay rows to count them.
   - Deals list: select only the columns the list renders (drop `intake`/`sale`/`recipients` unless shown). Page server-side at 50–100 rows with a `deals.updated_at` cursor and server-side search/stage filter. Lower the 2,000-row cap.
   - Pay: limit to the last 12 months by default with "load older".
   - Appointments: drop the `snapshot` blob from the list query if the card doesn't need all of it, or move the fields the card uses into real columns.

**Expected result:** every server function does **1 viewer trip + 1 parallel data trip** (2 total, down from 5–9). That should save roughly 0.3–0.8 s per page from the edge alone. Payloads shrink by about 5–20×.

### Phase 3 — Make RLS cheap (database migration, ~½ day)

These are standard Supabase RLS performance fixes.

1. **Wrap auth calls so Postgres evaluates them once per query, not per row:**
   `auth.uid()` → `(select auth.uid())` inside every helper function and policy.
   Policies `is_ayvo_admin()` → `(select public.is_ayvo_admin())`.
2. **Stop the self-join in `can_see_deal(id)` / `can_see_pay_item(id)`.** Today the policy on `deals` passes `id`, and the function looks the deal up again in `deals` for every row. Change the signature to take the row's columns:
   `can_see_deal(dealership_id, recipients, owner_member_id, owner_rep_id)`. Better still, inline it as:
   ```sql
   using (
     dealership_id in (select m.dealership_id from members m join dealerships d on d.id=m.dealership_id
                       where m.user_id = (select auth.uid()) and m.status='active' and d.status<>'archived')
     and public.recipient_match(recipients, …)
   )
   ```
   so Postgres can use the `deals_dealership_idx` index.
3. **Add the missing indexes** for queries the app actually runs:
   ```sql
   create index on deals (dealership_id, updated_at desc);
   create index on members (user_id, status);
   create index on pay_items (dealership_id, pay_date desc);
   create index on pay_items (deal_id);
   create index on rep_ledger_entries (deal_id);
   create index on deal_notes (deal_id, created_at);
   create index on deal_documents (deal_id, created_at desc);
   create index on deal_submissions (dealership_id, status, updated_at desc);
   create index on deal_submissions (member_id);
   create index on goayvo_outbox (ref_type, ref_id, created_at desc);
   create index on goayvo_outbox (dealership_id, (body->>'deal_id'), created_at desc);
   create index on appointments (deal_id);
   ```
4. **Housekeeping:** add a daily cron to delete `goayvo_sync_log` rows older than 30 days, and `VACUUM ANALYZE` afterwards. Make the GoAyvo sync upsert **only changed rows** (compare a hash/`updated_at`). Today it rewrites all deals and appointments on every pull: 5,801 appointment and 4,472 deal upserts so far. That churns the tables and pushes useful data out of the cache.

**Expected result:** the deals and appointments queries should drop from 30–41 ms to about 1–5 ms, and stay flat as the dealership count grows into the thousands of rows.

### Phase 4 — Take third-party APIs off the page-load path (~½–1 day)

1. **Lender Hub and AVL:** store the Bank Portal catalog **in our own database**. Add a `lender_hub_cache` table refreshed by a pg_cron job every 10 minutes, and/or a webhook from the Bank Portal on change. `getNewDealContext` and `getResources` then read one row, with no outbound HTTP while the page loads. The current in-memory 10-minute cache lives in a single Worker isolate, so most requests miss it.
2. Fetch **AVL per lender only when that lender is selected** in the New Deal form, using a separate small server function. Keep the `fresh: true` check on **submit** only.
3. `recordAuthEvent` → `hr-access refreshAccess()` currently blocks sign-in. Run it in the background (`waitUntil` / fire-and-forget) so login isn't held up by the HR app.
4. Outbox `enqueueEvent` calls inside actions (notes, proposal, change order…) wait for GoAyvo to answer before returning. For actions where the UI already shows "Sending to Ayvo…", return immediately after the outbox row is written and let the existing retry cron and `getSubmissionStatus` polling deliver it. **Keep `submitDeal` synchronous**, because it needs GoAyvo's 400/409 answer.

### Phase 5 — Front-end weight & PWA cold start (~½ day)

1. **Fonts:** self-host Manrope (400/600/700 only) and JetBrains Mono (500) as `woff2` in `/public/fonts`, add `<link rel="preload" as="font" crossorigin>`, and use `font-display: swap`. Drop the Google Fonts `<link>`s and preconnects.
2. **Service worker:** add a cache-first rule for `/assets/*`. These files are content-hashed and immutable, so this is safe. Repeat PWA launches then load JS/CSS from disk. Never cache `/_serverFn`, `/api`, or HTML (as today). Bump `CACHE` to `ayvo-shell-v2`.
3. **Bundle:** confirm route auto code-splitting is on in `@lovable.dev/vite-tanstack-config` (`autoCodeSplitting: true`). Lazy-load heavy pieces: `recharts`, `pdf-lib` (onboarding agreement only), `react-day-picker`/calendar views, `embla-carousel`. Delete unused shadcn components and Radix packages (menubar, navigation-menu, context-menu, hover-card, resizable, carousel, aspect-ratio…) if nothing imports them. Run `vite build` and check chunk sizes; target an initial JS of 200 KB gzip or less.
4. **Optional, later:** turn on SSR for the authenticated shell with cookie-based Supabase auth, so a hard refresh returns HTML that already has data. That is a bigger change, so do it only if cold-load times still fall short after Phases 1–4.

### Phase 6 — Live updates instead of polling (optional, ~½ day)

- Subscribe to Supabase Realtime on `notifications` (per user) and on `deals`/`appointments` (per dealership, through RLS). Use events to `invalidateQueries` the matching keys. Then the 60 s notification poll can go, and the longer `staleTime`s from Phase 1 never show stale data.

---

## 5. Expected impact (estimates)

| Scenario | Today | After Ph 1 | After Ph 1–3 | After Ph 1–5 |
|---|---|---|---|---|
| Click to a page not visited yet | ~1.5–3 s, frozen screen | ~1–1.5 s, skeleton shows immediately | **~250–400 ms** | ~250–400 ms |
| Click to a page visited or hovered | ~1.5–3 s | **instant** (cache) + background refresh | instant | instant |
| New Deal / Resources | ~2.5–5 s | ~2–4 s | ~1.5–3 s | **~300–500 ms** |
| Hard refresh / PWA launch | ~3–5 s | ~2.5–3.5 s | ~1.5–2 s | **~1–1.5 s** |
| DB time, deals/appointments list | 30–41 ms | same | **1–5 ms** | 1–5 ms |

---

## 6. Rollout order & safety

1. **Phase 1** first. It is purely front end, can't break data access, and makes the biggest difference to how fast the app feels.
2. **Phase 3** (RLS/indexes) next, as one migration. Before shipping, verify RLS behaviour with the existing tests in `src/test/visibility.test.ts`, `admin-view-as.test.ts`, and `role-pure-nav.test.ts`. Also spot-check as a rep, a manager, an admin, and an admin "viewing as" a rep.
3. **Phase 2** server refactor (viewer RPC + parallelization + slimmer payloads). Keep the return shapes the same so pages don't change.
4. **Phase 4**, then **Phase 5**, then **Phase 6**.

Ship each phase as its own Lovable change so it can be reverted on its own.

---

## 7. Ready-to-paste Lovable prompts

> **Prompt 1: navigation speed (Phase 1)**
> Performance pass, no visual or behaviour changes. (1) In `src/routes/_authenticated/route.tsx` `beforeLoad`, replace `supabase.auth.getUser()` with `supabase.auth.getSession()` (redirect to /auth if no session), and replace `fetchQuery({ ...meQuery, staleTime: 0 })` with `ensureQueryData(meQuery)`. Set `meQuery.staleTime` to 5 minutes, and invalidate `["me"]` after the admin dealership picker, act-as toggle and view-as actions. (2) In `src/router.tsx`, give the QueryClient defaults `staleTime: 30_000, gcTime: 600_000, refetchOnWindowFocus: false, retry: 1`, and set `defaultPreload: "intent"`, `defaultPendingComponent: PageSkeleton`, `defaultPendingMs: 150`, `defaultPendingMinMs: 300`. (3) Add a `loader` to every route under `_authenticated` that calls `context.queryClient.ensureQueryData` with the exact same queryKey and queryFn the page's `useSuspenseQuery` uses (`["real", "<name>", …]` with `realSource`). (4) Create `src/components/PageSkeleton.tsx` with the existing Skeleton component and wrap the `<main>` children in `AppShell` with `<Suspense fallback={<PageSkeleton/>}>`. Keep the AppointmentsPage `staleTime` at 15 s.

> **Prompt 2: RLS & indexes (Phase 3)**
> Write one migration that makes RLS cheap without changing who can see what. In every helper function (`can_see_pay`, `can_see_ledger`, `is_member_of`, `is_manager_of`, `is_ayvo_admin`, `is_any_member`, `is_any_manager`), replace `auth.uid()` with `(select auth.uid())`. In every policy, wrap helper calls that don't use row columns, e.g. `(select public.is_ayvo_admin())`. Rewrite `can_see_deal` and `can_see_pay_item` so they take the row's columns (dealership_id, recipients, owner member/rep ids) instead of looking the row up again by id, and update the `deals`/`pay_items` policies to match. Add these indexes: [paste the list from §4 Phase 3]. Add a daily pg_cron job that deletes goayvo_sync_log rows older than 30 days. Run the visibility, admin-view-as and role-pure-nav tests and make sure they pass.

> **Prompt 3: single viewer lookup + parallel queries (Phase 2)**
> Create a SQL function `public.portal_viewer()` (security definer, stable) that returns, in one call, the caller's ayvo_admins row (by user_id, else by the email in auth.jwt()), the selected dealership and view-as member for admins, or the caller's first active member row with its non-archived dealership. Rewrite `getAdmin`/`getViewer` in `src/lib/portal.server.ts` to use that single RPC, with the same return types. Move the "claim invited member rows by email" UPDATE into `recordAuthEvent("auth.signed_in")`, and run it only as a fallback when no member is found. In `getMe`, reuse the admin from `getViewer` instead of calling `getAdmin` again. Then parallelize: in `getDashboard`, put work_orders and rep_dashboards into the existing Promise.all; in `getDeal`, run pay/ledger together with notes/uploads/members; in `getPay`, fetch the ledger in parallel and embed `deals(customer_name)` instead of a second query; in `getAppointments`, load disposition options in parallel with the viewer and collapse the three member lookups into one query. Keep every function's return shape the same.

> **Prompt 4: Dashboard summary & lean lists (Phase 2.6)**
> Add an RPC `portal_dashboard_summary()` that returns stage counts, pay sums by status (pending/approved/paid in the last 30 days), up to 20 "needs action" deals and the 6 most recently moved deals for the viewer's scope. Use it in `getDashboard` instead of returning all deals and pay rows, and keep the DashboardPage UI the same. In `listDeals`, select only the columns DealsPage renders, and add server-side paging (50 per page, cursor on updated_at), search and stage filters.

> **Prompt 5: Lender Hub off the hot path (Phase 4)**
> Add a table `lender_hub_cache (id text pk, payload jsonb, updated_at timestamptz)` and a pg_cron job (every 10 min) that calls a new protected route to refresh it from the Bank Portal `/lenders` and `/programs`. Change `loadLenderHub()` to read that row (fall back to a live fetch only if the row is missing). Load AVL per lender lazily, through a new `getAvl({ lender })` server function, when the user picks a lender in New Deal; keep `fresh: true` on submit only. Make `refreshAccess()` in `recordAuthEvent` non-blocking.

> **Prompt 6: fonts, service worker, bundle (Phase 5)**
> Self-host Manrope (400, 600, 700) and JetBrains Mono (500) as woff2 in /public/fonts, preload them, and remove the Google Fonts links. In `public/sw.js`, add a cache-first strategy for same-origin `/assets/*` (hashed, immutable) and bump the cache name to `ayvo-shell-v2`; still never cache navigations, /_serverFn or /api. Lazy-load recharts, pdf-lib and the calendar views with `React.lazy`. Remove shadcn ui components and Radix packages that nothing imports.

---

## 8. How to measure (do this before Phase 1 to get a baseline)

1. **Server timing:** add a tiny wrapper middleware that logs `fn name, total ms, viewer ms, db ms`, and sets a `Server-Timing` response header on server functions. Then compare before and after in Chrome DevTools → Network → Timing.
2. **Client:** log `performance.now()` from link click to first contentful paint of the page content (`router.subscribe("onResolved")`), and send it to the existing error-capture endpoint or the console.
3. **DB:** reset with `select pg_stat_statements_reset();` before testing, then re-read the top-query table in §2.1 after each phase.
4. **Targets:** p75 page change (warm) < 300 ms · p75 page change (cold) < 800 ms · hard refresh / PWA launch < 1.5 s on 4G · no server function > 2 DB round trips before returning.
