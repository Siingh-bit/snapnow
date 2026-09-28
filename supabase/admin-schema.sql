-- =====================================================================
-- SnapPro — staff accounts, roles and invites
-- Paste into: Supabase dashboard > SQL Editor > New query > Run
-- Safe to run more than once.
--
-- How access works:
--   1. Someone can only reach the admin area if they have a row in staff.
--   2. A staff row is only created when their email matches a pending invite.
--   3. Only a super_admin can create invites or change roles.
--   4. Every rule below is enforced by Postgres, not by the page. Editing
--      the JavaScript in the browser cannot grant anybody access.
-- =====================================================================

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------- tables

create table if not exists public.staff (
  id         uuid primary key references auth.users(id) on delete cascade,
  email      text not null unique,
  name       text,
  role       text not null default 'manager'
             check (role in ('super_admin','admin','manager')),
  status     text not null default 'active'
             check (status in ('active','suspended')),
  invited_by uuid,
  created_at timestamptz default now()
);

create table if not exists public.staff_invites (
  id          uuid primary key default gen_random_uuid(),
  email       text not null unique,
  role        text not null default 'manager'
              check (role in ('super_admin','admin','manager')),
  invited_by  uuid,
  created_at  timestamptz default now(),
  accepted_at timestamptz
);

create index if not exists idx_staff_email   on public.staff(lower(email));
create index if not exists idx_invites_email on public.staff_invites(lower(email));

-- ------------------------------------------------------- role lookup
-- SECURITY DEFINER so it can read staff without triggering the staff
-- policies that call it — without this the policies recurse infinitely.

create or replace function public.staff_role()
returns text
language sql
stable
security definer
set search_path = public
as $$
  select role from public.staff
   where id = auth.uid() and status = 'active'
   limit 1
$$;

create or replace function public.is_staff()
returns boolean
language sql stable security definer set search_path = public
as $$ select public.staff_role() is not null $$;

create or replace function public.is_super()
returns boolean
language sql stable security definer set search_path = public
as $$ select public.staff_role() = 'super_admin' $$;

-- ------------------------------------------- claim invite on first sign-in
-- Runs when a new auth user appears. Creates the customer profile as before,
-- and additionally promotes them to staff if their email was invited.

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer set search_path = public
as $$
declare inv record;
begin
  insert into public.profiles (id, name, email, phone)
  values (
    new.id,
    coalesce(new.raw_user_meta_data->>'name', split_part(coalesce(new.email,'user'), '@', 1)),
    new.email,
    new.phone
  )
  on conflict (id) do nothing;

  select * into inv
    from public.staff_invites
   where lower(email) = lower(coalesce(new.email,''))
     and accepted_at is null
   limit 1;

  if found then
    insert into public.staff (id, email, name, role, invited_by)
    values (new.id, lower(new.email),
            coalesce(new.raw_user_meta_data->>'name', split_part(new.email,'@',1)),
            inv.role, inv.invited_by)
    on conflict (id) do update set role = excluded.role, status = 'active';

    update public.staff_invites set accepted_at = now() where id = inv.id;
  end if;

  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ---------------------------------------------------------------- RLS

alter table public.staff         enable row level security;
alter table public.staff_invites enable row level security;

-- staff: any active staff member can see the team; only super_admin edits
drop policy if exists staff_select on public.staff;
create policy staff_select on public.staff
  for select to authenticated using (public.is_staff() or id = auth.uid());

drop policy if exists staff_super_insert on public.staff;
create policy staff_super_insert on public.staff
  for insert to authenticated with check (public.is_super());

drop policy if exists staff_super_update on public.staff;
create policy staff_super_update on public.staff
  for update to authenticated using (public.is_super()) with check (public.is_super());

drop policy if exists staff_super_delete on public.staff;
create policy staff_super_delete on public.staff
  for delete to authenticated using (public.is_super() and id <> auth.uid());

-- invites: super_admin only, in every direction
drop policy if exists invites_super_all on public.staff_invites;
create policy invites_super_all on public.staff_invites
  for all to authenticated using (public.is_super()) with check (public.is_super());

-- ------------------------------------------- staff read access to the app
-- These sit alongside the existing customer policies. Postgres ORs
-- permissive policies together, so customers keep exactly what they had
-- and staff additionally get an operations-wide view.

drop policy if exists profiles_staff_read on public.profiles;
create policy profiles_staff_read on public.profiles
  for select to authenticated
  using (public.staff_role() in ('super_admin','admin'));

drop policy if exists requests_staff_read on public.requests;
create policy requests_staff_read on public.requests
  for select to authenticated using (public.is_staff());

drop policy if exists offers_staff_read on public.offers;
create policy offers_staff_read on public.offers
  for select to authenticated using (public.is_staff());

drop policy if exists bookings_staff_read on public.bookings;
create policy bookings_staff_read on public.bookings
  for select to authenticated using (public.is_staff());

-- messages stay private to the two people on the booking, except for the
-- two highest roles, who may need them for dispute handling
drop policy if exists messages_staff_read on public.messages;
create policy messages_staff_read on public.messages
  for select to authenticated
  using (public.staff_role() in ('super_admin','admin'));

-- ------------------------------------------------------- seed the founder
-- Creates the first invite. Nobody is an admin until they sign in with this
-- address and Supabase verifies a code sent to it. No password is stored
-- here, and none is stored anywhere in the site's source.

insert into public.staff_invites (email, role)
values ('create.saifeestudio@gmail.com', 'super_admin')
on conflict (email) do update set role = 'super_admin', accepted_at = null;

-- If that account already signed in as a customer earlier, promote it now.
insert into public.staff (id, email, name, role)
select u.id, lower(u.email), split_part(u.email,'@',1), 'super_admin'
  from auth.users u
 where lower(u.email) = 'create.saifeestudio@gmail.com'
on conflict (id) do update set role = 'super_admin', status = 'active';

-- ---------------------------------------------------------------- verify
select
  (select count(*) from public.staff)                              as staff_rows,
  (select count(*) from public.staff_invites where accepted_at is null) as pending_invites,
  (select count(*) from pg_policies
     where schemaname='public' and tablename in ('staff','staff_invites')) as staff_policies,
  exists (select 1 from pg_proc where proname='staff_role')        as role_fn_ok,
  exists (select 1 from pg_trigger
           where tgrelid='auth.users'::regclass
             and tgname='on_auth_user_created')                    as trigger_ok;
