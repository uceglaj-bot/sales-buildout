-- Dealer portal: RLS performance. Same visibility, evaluated once per query instead of once per row.
-- Validated against live data before shipping: 116 simulated user scenarios (each member as rep, manager,
-- manager with dealer.manager capability, and two-dealership user), 18,363 visible rows, 0 mismatches.

-- ---------- Caller's access, computed once per statement via (select fn()) ----------
create or replace function public.my_dealerships() returns uuid[]
language sql stable security definer set search_path = public as $$
  select coalesce(array_agg(m.dealership_id), '{}') from members m join dealerships d on d.id = m.dealership_id
  where m.user_id = (select auth.uid()) and m.status = 'active' and d.status <> 'archived'
$$;

create or replace function public.my_manager_dealerships() returns uuid[]
language sql stable security definer set search_path = public as $$
  select coalesce(array_agg(m.dealership_id), '{}') from members m join dealerships d on d.id = m.dealership_id
  where m.user_id = (select auth.uid()) and m.status = 'active' and d.status <> 'archived' and m.role = 'manager'
$$;

create or replace function public.my_ledger_manager_dealerships() returns uuid[]
language sql stable security definer set search_path = public as $$
  select coalesce(array_agg(m.dealership_id), '{}') from members m join dealerships d on d.id = m.dealership_id
  where m.user_id = (select auth.uid()) and m.status = 'active' and d.status <> 'archived'
    and m.role = 'manager' and 'dealer.manager' = any(m.capabilities)
$$;

-- "<dealership_id>:<member_id>" for each active membership.
create or replace function public.my_member_keys() returns text[]
language sql stable security definer set search_path = public as $$
  select coalesce(array_agg(m.dealership_id::text || ':' || m.id::text), '{}') from members m join dealerships d on d.id = m.dealership_id
  where m.user_id = (select auth.uid()) and m.status = 'active' and d.status <> 'archived'
$$;

-- "<dealership_id>:<goayvo_rep_id>" for each active membership with a rep id.
create or replace function public.my_rep_keys() returns text[]
language sql stable security definer set search_path = public as $$
  select coalesce(array_agg(m.dealership_id::text || ':' || m.goayvo_rep_id), '{}') from members m join dealerships d on d.id = m.dealership_id
  where m.user_id = (select auth.uid()) and m.status = 'active' and d.status <> 'archived' and m.goayvo_rep_id is not null
$$;

-- Same rule as recipient_match(), against the caller's precomputed access. Pure function (no table reads).
create or replace function public.recipients_visible(_dealership_id uuid, _recipients jsonb, _owner_member uuid, _owner_rep text,
  _mgr uuid[], _member_keys text[], _rep_keys text[]) returns boolean
language sql immutable set search_path = public as $$
  select coalesce(case
    when _recipients is null or jsonb_typeof(_recipients) <> 'array' or jsonb_array_length(_recipients) = 0 then
      _dealership_id = any(_mgr)
      or (_dealership_id::text || ':' || _owner_member::text) = any(_member_keys)
      or (_dealership_id::text || ':' || _owner_rep) = any(_rep_keys)
    else exists (
      select 1 from jsonb_array_elements(_recipients) r
      where (r->>'role' = 'rep' and (_dealership_id::text || ':' || (r->>'goayvo_rep_id')) = any(_rep_keys))
         or (r->>'role' = 'manager' and _dealership_id = any(_mgr)))
  end, false)
$$;

-- ---------- Policies (SELECT only; all writes go through the service role) ----------
-- Ayvo admin policies: evaluate is_ayvo_admin() once per statement.
do $$
declare p record;
begin
  for p in select tablename, policyname from pg_policies
           where schemaname = 'public' and cmd = 'SELECT' and qual = 'is_ayvo_admin()' loop
    execute format('alter policy %I on public.%I using ((select public.is_ayvo_admin()))', p.policyname, p.tablename);
  end loop;
end $$;

alter policy "scoped deal read" on public.deals using (
  public.recipients_visible(dealership_id, recipients, owner_member_id, owner_rep_id,
    (select public.my_manager_dealerships()), (select public.my_member_keys()), (select public.my_rep_keys())));

alter policy "scoped pay read" on public.pay_items using (
  public.recipients_visible(dealership_id, recipients, member_id, rep_id,
    (select public.my_manager_dealerships()), (select public.my_member_keys()), (select public.my_rep_keys())));

alter policy "members see own or managed appointments" on public.appointments using (
  dealership_id = any((select public.my_manager_dealerships())::uuid[])
  or (dealership_id::text || ':' || member_id::text) = any((select public.my_member_keys())::text[])
  or (dealership_id::text || ':' || rep_id) = any((select public.my_rep_keys())::text[]));

alter policy "dealers read own dashboard" on public.rep_dashboards using (
  dealership_id = any((select public.my_manager_dealerships())::uuid[])
  or (dealership_id::text || ':' || member_id::text) = any((select public.my_member_keys())::text[])
  or (dealership_id::text || ':' || rep_id) = any((select public.my_rep_keys())::text[]));

alter policy "members see own or managed calendar events" on public.calendar_events using (
  dealership_id = any((select public.my_manager_dealerships())::uuid[])
  or (dealership_id::text || ':' || member_id::text) = any((select public.my_member_keys())::text[]));

alter policy "managers all, reps own or unassigned work orders" on public.work_orders using (
  dealership_id = any((select public.my_manager_dealerships())::uuid[])
  or (dealership_id::text || ':' || member_id::text) = any((select public.my_member_keys())::text[])
  or (member_id is null and dealership_id = any((select public.my_dealerships())::uuid[])));

alter policy "own ledger or capable manager" on public.rep_ledger_entries using (
  dealership_id = any((select public.my_ledger_manager_dealerships())::uuid[])
  or (dealership_id::text || ':' || member_id::text) = any((select public.my_member_keys())::text[])
  or (dealership_id::text || ':' || rep_id) = any((select public.my_rep_keys())::text[]));

alter policy "members read teammates" on public.members using (
  (dealership_id = any((select public.my_dealerships())::uuid[]) and status <> 'removed') or user_id = (select auth.uid()));

alter policy "members read own dealership" on public.dealerships using (id = any((select public.my_dealerships())::uuid[]));

alter policy "own or managed submissions" on public.deal_submissions using (
  dealership_id = any((select public.my_manager_dealerships())::uuid[])
  or (dealership_id = any((select public.my_dealerships())::uuid[])
      and member_id in (select m.id from public.members m where m.user_id = (select auth.uid()))));

alter policy "managers read dealership docs" on public.dealership_documents using (dealership_id = any((select public.my_manager_dealerships())::uuid[]));
alter policy "managers read onboarding" on public.dealership_onboarding using (dealership_id = any((select public.my_manager_dealerships())::uuid[]));
alter policy "managers read invites" on public.invites using (dealership_id = any((select public.my_manager_dealerships())::uuid[]));

alter policy "members read their dealership financing" on public.financing_options using (
  ((dealership_id is null) and ((select public.is_any_member()) or (select public.is_ayvo_admin())))
  or ((dealership_id is not null) and (dealership_id = any((select public.my_dealerships())::uuid[]) or (select public.is_ayvo_admin()))));

alter policy "members read resources" on public.resources using (
  active and (((audience = 'all') and (select public.is_any_member())) or ((audience = 'managers') and (select public.is_any_manager()))));

-- user_id = auth.uid() → evaluated once.
alter policy "own admin row" on public.ayvo_admins using (user_id = (select auth.uid()));
alter policy "applicant reads own application" on public.dealer_applications using (user_id = (select auth.uid()));
alter policy "own prefs" on public.notification_prefs using (user_id = (select auth.uid()));
alter policy "own notifications" on public.notifications using (user_id = (select auth.uid()));
alter policy "own push subscriptions" on public.push_subscriptions using (user_id = (select auth.uid()));
alter policy "own outbox rows" on public.goayvo_outbox using (actor_user_id = (select auth.uid()));

-- ---------- Indexes for the queries the app runs ----------
create index if not exists deals_dealership_updated_idx on public.deals (dealership_id, updated_at desc);
create index if not exists members_user_status_idx on public.members (user_id, status);
create index if not exists pay_items_dealership_paydate_idx on public.pay_items (dealership_id, pay_date desc);
create index if not exists pay_items_deal_idx on public.pay_items (deal_id);
create index if not exists rep_ledger_deal_idx on public.rep_ledger_entries (deal_id);
create index if not exists deal_notes_deal_idx on public.deal_notes (deal_id, created_at);
create index if not exists deal_documents_deal_idx on public.deal_documents (deal_id, created_at desc);
create index if not exists deal_submissions_dealership_status_idx on public.deal_submissions (dealership_id, status, updated_at desc);
create index if not exists deal_submissions_member_idx on public.deal_submissions (member_id);
create index if not exists goayvo_outbox_ref_idx on public.goayvo_outbox (ref_type, ref_id, created_at desc);
create index if not exists goayvo_outbox_deal_idx on public.goayvo_outbox (dealership_id, (body->>'deal_id'), created_at desc);
create index if not exists appointments_deal_idx on public.appointments (deal_id);
create index if not exists goayvo_sync_log_created_idx on public.goayvo_sync_log (created_at);

-- ---------- Housekeeping: keep 30 days of sync log ----------
select cron.schedule('prune-goayvo-sync-log', '17 3 * * *',
  $$delete from public.goayvo_sync_log where created_at < now() - interval '30 days'$$);
