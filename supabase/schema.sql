-- =====================================================================
-- SnapPro — database schema + Row Level Security
-- Paste the whole file into: Supabase dashboard > SQL Editor > New query > Run
-- Safe to run more than once.
--
-- Security model:
--   profiles      = private. Holds phone/email/wallet. You can only see YOUR row.
--   photographers = public marketplace listing. No PII. Anyone can browse.
--   requests      = your own, plus any request still open for bids.
--   offers        = visible to the photographer who made it and the customer who owns the request.
--   bookings      = visible only to the two people on the booking.
--   messages      = visible only to the two people on that booking.
-- =====================================================================

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------- tables

create table if not exists public.profiles (
  id             uuid primary key references auth.users(id) on delete cascade,
  name           text    not null default 'User',
  role           text    not null default 'customer' check (role in ('customer','photographer')),
  phone          text,
  email          text,
  area           text    default 'Indiranagar',
  wallet_balance integer default 0,
  created_at     timestamptz default now()
);

-- public listing: deliberately duplicates name + area so browsing
-- photographers never requires reading anybody's private profile row
create table if not exists public.photographers (
  id               uuid primary key references public.profiles(id) on delete cascade,
  display_name     text    not null default 'Photographer',
  area             text    default 'Indiranagar',
  bio              text    default '',
  categories       text[]  default '{}',
  areas            text[]  default '{}',
  years_exp        integer default 2,
  price_multiplier numeric default 1.0,
  rating           numeric default 4.8,
  review_count     integer default 0,
  is_online        boolean default true,
  is_verified      boolean default false,
  earnings         integer default 0,
  created_at       timestamptz default now()
);

create table if not exists public.requests (
  id           uuid primary key default gen_random_uuid(),
  customer_id  uuid references public.profiles(id) on delete cascade,
  category     text,
  urgency      text,
  duration_hrs integer default 2,
  area         text,
  budget       integer default 3000,
  deliverables text[]  default '{}',
  status       text    default 'broadcasting',
  created_at   timestamptz default now()
);

create table if not exists public.offers (
  id              uuid primary key default gen_random_uuid(),
  request_id      uuid references public.requests(id) on delete cascade,
  photographer_id uuid references public.profiles(id) on delete cascade,
  price           integer not null,
  eta_min         integer default 20,
  note            text,
  created_at      timestamptz default now()
);

create table if not exists public.bookings (
  id              uuid primary key default gen_random_uuid(),
  request_id      uuid references public.requests(id) on delete set null,
  customer_id     uuid references public.profiles(id) on delete cascade,
  photographer_id uuid references public.profiles(id) on delete cascade,
  total_amount    integer default 0,
  payout_amount   integer default 0,
  status          text    default 'confirmed',
  created_at      timestamptz default now()
);

create table if not exists public.messages (
  id         uuid primary key default gen_random_uuid(),
  booking_id uuid references public.bookings(id) on delete cascade,
  sender_id  uuid references public.profiles(id) on delete cascade,
  content    text not null,
  created_at timestamptz default now()
);

create index if not exists idx_requests_status  on public.requests(status);
create index if not exists idx_offers_request   on public.offers(request_id);
create index if not exists idx_bookings_cust    on public.bookings(customer_id);
create index if not exists idx_bookings_pg      on public.bookings(photographer_id);
create index if not exists idx_messages_booking on public.messages(booking_id);

-- ------------------------------------------------- auto-create profile row
-- Without this, a user signs up but has no profile, and every insert that
-- references profiles(id) fails with a foreign key error.

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer set search_path = public
as $$
begin
  insert into public.profiles (id, name, email, phone)
  values (
    new.id,
    coalesce(new.raw_user_meta_data->>'name', split_part(coalesce(new.email,'user'), '@', 1)),
    new.email,
    new.phone
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ---------------------------------------------------------------- enable RLS
-- With RLS on and no policy, everything is denied. Policies below grant back
-- exactly what each user should reach. Never turn RLS off to "make it work" —
-- the publishable key is in the page source, so that would make every row
-- in every table readable and writable by anyone on the internet.

alter table public.profiles      enable row level security;
alter table public.photographers enable row level security;
alter table public.requests      enable row level security;
alter table public.offers        enable row level security;
alter table public.bookings      enable row level security;
alter table public.messages      enable row level security;

-- ------------------------------------------- remove wide-open legacy policies
-- IMPORTANT: Postgres combines permissive policies with OR. A leftover
-- "Allow all" policy using (true) overrides every strict policy below it,
-- so these must be dropped by name or the locks that follow do nothing.

drop policy if exists "Allow all profiles"      on public.profiles;
drop policy if exists "Allow all photographers" on public.photographers;
drop policy if exists "Allow all requests"      on public.requests;
drop policy if exists "Allow all offers"        on public.offers;
drop policy if exists "Allow all bookings"      on public.bookings;
drop policy if exists "Allow all messages"      on public.messages;

-- catch any other blanket policy regardless of what it was named
do $$
declare r record;
begin
  for r in
    select schemaname, tablename, policyname
      from pg_policies
     where schemaname = 'public'
       and tablename in ('profiles','photographers','requests','offers','bookings','messages')
       and coalesce(qual, 'true') = 'true'
       and cmd = 'ALL'
  loop
    execute format('drop policy if exists %I on %I.%I', r.policyname, r.schemaname, r.tablename);
    raise notice 'dropped blanket policy % on %', r.policyname, r.tablename;
  end loop;
end $$;

-- ---------------------------------------------------------------- profiles
drop policy if exists profiles_select_own on public.profiles;
create policy profiles_select_own on public.profiles
  for select to authenticated using (auth.uid() = id);

drop policy if exists profiles_insert_own on public.profiles;
create policy profiles_insert_own on public.profiles
  for insert to authenticated with check (auth.uid() = id);

drop policy if exists profiles_update_own on public.profiles;
create policy profiles_update_own on public.profiles
  for update to authenticated using (auth.uid() = id) with check (auth.uid() = id);

-- ------------------------------------------------------------ photographers
drop policy if exists photographers_select_all on public.photographers;
create policy photographers_select_all on public.photographers
  for select using (true);

drop policy if exists photographers_insert_own on public.photographers;
create policy photographers_insert_own on public.photographers
  for insert to authenticated with check (auth.uid() = id);

drop policy if exists photographers_update_own on public.photographers;
create policy photographers_update_own on public.photographers
  for update to authenticated using (auth.uid() = id) with check (auth.uid() = id);

-- ---------------------------------------------------------------- requests
drop policy if exists requests_select on public.requests;
create policy requests_select on public.requests
  for select to authenticated
  using (customer_id = auth.uid() or status = 'broadcasting');

drop policy if exists requests_insert_own on public.requests;
create policy requests_insert_own on public.requests
  for insert to authenticated with check (customer_id = auth.uid());

drop policy if exists requests_update_own on public.requests;
create policy requests_update_own on public.requests
  for update to authenticated using (customer_id = auth.uid());

-- ------------------------------------------------------------------ offers
drop policy if exists offers_select on public.offers;
create policy offers_select on public.offers
  for select to authenticated
  using (
    photographer_id = auth.uid()
    or exists (select 1 from public.requests r
               where r.id = offers.request_id and r.customer_id = auth.uid())
  );

drop policy if exists offers_insert_own on public.offers;
create policy offers_insert_own on public.offers
  for insert to authenticated with check (photographer_id = auth.uid());

drop policy if exists offers_delete_own on public.offers;
create policy offers_delete_own on public.offers
  for delete to authenticated using (photographer_id = auth.uid());

-- ---------------------------------------------------------------- bookings
drop policy if exists bookings_select_party on public.bookings;
create policy bookings_select_party on public.bookings
  for select to authenticated
  using (customer_id = auth.uid() or photographer_id = auth.uid());

drop policy if exists bookings_insert_own on public.bookings;
create policy bookings_insert_own on public.bookings
  for insert to authenticated with check (customer_id = auth.uid());

drop policy if exists bookings_update_party on public.bookings;
create policy bookings_update_party on public.bookings
  for update to authenticated
  using (customer_id = auth.uid() or photographer_id = auth.uid());

-- ---------------------------------------------------------------- messages
drop policy if exists messages_select_party on public.messages;
create policy messages_select_party on public.messages
  for select to authenticated
  using (
    exists (select 1 from public.bookings b
            where b.id = messages.booking_id
              and (b.customer_id = auth.uid() or b.photographer_id = auth.uid()))
  );

drop policy if exists messages_insert_party on public.messages;
create policy messages_insert_party on public.messages
  for insert to authenticated
  with check (
    sender_id = auth.uid()
    and exists (select 1 from public.bookings b
                where b.id = messages.booking_id
                  and (b.customer_id = auth.uid() or b.photographer_id = auth.uid()))
  );

-- ---------------------------------------------------------------- verify
-- Expect: rls_on = true everywhere, policies >= 2 on every table,
-- blanket_policies = 0 everywhere, and trigger_ok = true on the last row.

select t.tablename,
       t.rowsecurity as rls_on,
       (select count(*) from pg_policies p
         where p.schemaname='public' and p.tablename=t.tablename) as policies,
       (select count(*) from pg_policies p
         where p.schemaname='public' and p.tablename=t.tablename
           and coalesce(p.qual,'true')='true' and p.cmd='ALL')      as blanket_policies,
       exists (select 1 from pg_trigger
                where tgrelid='auth.users'::regclass
                  and tgname='on_auth_user_created')                as trigger_ok
from pg_tables t
where t.schemaname='public'
order by t.tablename;
