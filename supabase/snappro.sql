-- =====================================================================
-- SnapPro — complete database setup
--
-- Paste the WHOLE file into: Supabase > SQL Editor > New query > Run
-- Safe to run on a fresh project, on your current project, and again later.
-- It replaces the older schema.sql and admin-schema.sql.
--
-- Every rule below is enforced by Postgres. Nothing in the website's code
-- can override it: changing the page's JavaScript in a browser cannot let
-- someone read another person's data, fake a rating, or change a price.
-- =====================================================================

create extension if not exists pgcrypto;
create schema if not exists extensions;
do $$ begin
  create extension if not exists pg_net with schema extensions;
exception when others then
  raise notice 'pg_net could not be enabled (%). Invite emails will not send until it is.', sqlerrm;
end $$;

-- =====================================================================
-- 1. TABLES
-- =====================================================================

create table if not exists public.profiles (
  id             uuid primary key references auth.users(id) on delete cascade,
  name           text    not null default 'User',
  role           text    not null default 'customer' check (role in ('customer','photographer')),
  phone          text,
  email          text,
  area           text,
  wallet_balance integer default 0,
  created_at     timestamptz default now()
);
alter table public.profiles
  add column if not exists city    text,
  add column if not exists state   text,
  add column if not exists pincode text;
alter table public.profiles alter column area drop default;

create table if not exists public.photographers (
  id               uuid primary key references public.profiles(id) on delete cascade,
  display_name     text    not null default 'Photographer',
  area             text,
  bio              text    default '',
  categories       text[]  default '{}',
  areas            text[]  default '{}',
  years_exp        integer default 0,
  price_multiplier numeric default 1.0,
  rating           numeric,
  review_count     integer default 0,
  is_online        boolean default true,
  is_verified      boolean default false,
  earnings         integer default 0,
  created_at       timestamptz default now()
);
alter table public.photographers
  add column if not exists display_name text not null default 'Photographer',
  add column if not exists area         text,
  add column if not exists city         text,
  add column if not exists state        text,
  add column if not exists pincode      text,
  add column if not exists portfolio    text[]  not null default '{}',
  add column if not exists jobs_done    integer not null default 0;
alter table public.photographers alter column rating drop default;
alter table public.photographers alter column area drop default;

-- New photographers wait for a staff member to approve them.
alter table public.photographers
  add column if not exists approval_status text,
  add column if not exists approved_at     timestamptz,
  add column if not exists approved_by     uuid,
  add column if not exists review_note     text,
  add column if not exists submitted_at    timestamptz default now();
select set_config('snappro.system', 'on', false);
update public.photographers set approval_status = 'approved', approved_at = coalesce(approved_at, now())
 where approval_status is null;
select set_config('snappro.system', '', false);
alter table public.photographers alter column approval_status set default 'pending';
alter table public.photographers alter column approval_status set not null;
do $$ begin
  alter table public.photographers add constraint photographers_approval_check
    check (approval_status in ('pending','approved','rejected'));
exception when duplicate_object then null; end $$;
create index if not exists idx_photographers_approval on public.photographers(approval_status);
alter table public.photographers alter column years_exp set default 0;

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
alter table public.requests
  add column if not exists customer_name text,
  add column if not exists start_at      timestamptz,
  add column if not exists city          text,
  add column if not exists state         text,
  add column if not exists pincode       text,
  add column if not exists notes         text,
  add column if not exists expires_at    timestamptz;

create table if not exists public.offers (
  id              uuid primary key default gen_random_uuid(),
  request_id      uuid references public.requests(id) on delete cascade,
  photographer_id uuid references public.profiles(id) on delete cascade,
  price           integer not null,
  eta_min         integer default 20,
  note            text,
  created_at      timestamptz default now()
);
alter table public.offers
  add column if not exists eta_min           integer default 20,
  add column if not exists note              text,
  add column if not exists photographer_name text;

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
alter table public.bookings
  add column if not exists offer_id          uuid,
  add column if not exists customer_name     text,
  add column if not exists photographer_name text,
  add column if not exists category          text,
  add column if not exists start_at          timestamptz,
  add column if not exists duration_hrs      integer,
  add column if not exists city              text,
  add column if not exists pincode           text,
  add column if not exists address           text,
  add column if not exists price             integer,
  add column if not exists updated_at        timestamptz default now();

-- payment + payout bookkeeping on each booking
alter table public.bookings
  add column if not exists commission_pct      numeric(5,2),
  add column if not exists commission_amount   integer,
  add column if not exists photographer_amount integer,
  add column if not exists payment_status      text,
  add column if not exists paid_at             timestamptz,
  add column if not exists payout_status       text,
  add column if not exists payout_ref          text,
  add column if not exists payout_at           timestamptz,
  add column if not exists payout_by           uuid,
  add column if not exists cancelled_from      text,      -- status the booking was in when cancelled
  add column if not exists cancelled_by        text,      -- customer / photographer
  -- 25% advance online at booking, the rest online after the shoot
  add column if not exists advance_pct         numeric(5,2),
  add column if not exists advance_amount      integer,
  add column if not exists balance_amount      integer,
  add column if not exists balance_status      text,      -- not_required / pending / due / paid
  add column if not exists balance_paid_at     timestamptz;
-- bookings made before online payments existed were paid directly
select set_config('snappro.system', 'on', false);
update public.bookings set payment_status = 'not_required' where payment_status is null;
update public.bookings set payout_status  = 'not_due'      where payout_status  is null;
select set_config('snappro.system', '', false);
alter table public.bookings alter column payment_status set default 'unpaid';
alter table public.bookings alter column payment_status set not null;
alter table public.bookings alter column payout_status  set default 'not_due';
alter table public.bookings alter column payout_status  set not null;
do $$ begin
  alter table public.bookings add constraint bookings_payment_status_check
    check (payment_status in ('unpaid','paid','refund_due','refund_pending','refunded','partially_refunded','not_required'));
exception when duplicate_object then null; end $$;
do $$ begin
  alter table public.bookings add constraint bookings_payout_status_check
    check (payout_status in ('not_due','due','paid','on_hold'));
exception when duplicate_object then null; end $$;

create table if not exists public.platform_settings (
  key        text primary key,
  value      jsonb not null,
  updated_at timestamptz not null default now()
);
insert into public.platform_settings (key, value) values ('commission_pct', '20')
on conflict (key) do nothing;
insert into public.platform_settings (key, value) values ('advance_pct', '25')
on conflict (key) do nothing;

create table if not exists public.messages (
  id         uuid primary key default gen_random_uuid(),
  booking_id uuid references public.bookings(id) on delete cascade,
  sender_id  uuid references public.profiles(id) on delete cascade,
  content    text not null,
  created_at timestamptz default now()
);

create table if not exists public.reviews (
  id              uuid primary key default gen_random_uuid(),
  booking_id      uuid not null unique references public.bookings(id) on delete cascade,
  photographer_id uuid not null references public.photographers(id) on delete cascade,
  customer_id     uuid not null references public.profiles(id) on delete cascade,
  customer_name   text,
  stars           integer not null check (stars between 1 and 5),
  body            text,
  created_at      timestamptz default now()
);

create table if not exists public.staff (
  id         uuid primary key references auth.users(id) on delete cascade,
  email      text not null unique,
  name       text,
  role       text not null default 'manager' check (role in ('super_admin','admin','manager')),
  status     text not null default 'active'  check (status in ('active','suspended')),
  invited_by uuid,
  created_at timestamptz default now()
);

create table if not exists public.staff_invites (
  id          uuid primary key default gen_random_uuid(),
  email       text not null unique,
  role        text not null default 'manager' check (role in ('super_admin','admin','manager')),
  invited_by  uuid,
  created_at  timestamptz default now(),
  accepted_at timestamptz
);

create index if not exists idx_requests_status   on public.requests(status, expires_at);
create index if not exists idx_requests_customer on public.requests(customer_id);
create index if not exists idx_offers_request    on public.offers(request_id);
create index if not exists idx_offers_pg         on public.offers(photographer_id);
create index if not exists idx_bookings_cust     on public.bookings(customer_id);
create index if not exists idx_bookings_pg       on public.bookings(photographer_id);
create index if not exists idx_messages_booking  on public.messages(booking_id, created_at);
create index if not exists idx_reviews_pg        on public.reviews(photographer_id);
create index if not exists idx_staff_email       on public.staff(lower(email));
create index if not exists idx_invites_email     on public.staff_invites(lower(email));
create index if not exists idx_pg_city           on public.photographers(lower(city));
-- one quote per photographer per request; one live booking per request
create unique index if not exists uniq_offer_per_pg     on public.offers(request_id, photographer_id);
create unique index if not exists uniq_live_booking_req on public.bookings(request_id) where status <> 'cancelled';

-- =====================================================================
-- 2. HELPERS
-- =====================================================================

-- SECURITY DEFINER so policies on staff can call it without recursing.
create or replace function public.staff_role()
returns text language sql stable security definer set search_path = public
as $$ select role from public.staff where id = auth.uid() and status = 'active' limit 1 $$;

create or replace function public.is_staff()
returns boolean language sql stable security definer set search_path = public
as $$ select public.staff_role() is not null $$;

create or replace function public.is_super()
returns boolean language sql stable security definer set search_path = public
as $$ select coalesce(public.staff_role() = 'super_admin', false) $$;

-- Database triggers that legitimately maintain protected fields (ratings,
-- job counts) switch this flag on for the length of one statement.
create or replace function public.commission_pct()
returns numeric language sql stable security definer set search_path = public
as $$ select coalesce((select (value #>> '{}')::numeric from public.platform_settings where key = 'commission_pct'), 20) $$;

create or replace function public.advance_pct()
returns numeric language sql stable security definer set search_path = public
as $$ select coalesce((select (value #>> '{}')::numeric from public.platform_settings where key = 'advance_pct'), 25) $$;

create or replace function public.snappro_system()
returns boolean language sql stable
as $$ select coalesce(current_setting('snappro.system', true), '') = 'on' $$;

-- =====================================================================
-- 3. SIGN-UP AND STAFF INVITES
-- =====================================================================

create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public
as $$
declare inv record;
begin
  insert into public.profiles (id, name, email, phone)
  values (new.id,
          coalesce(new.raw_user_meta_data->>'name', split_part(coalesce(new.email,'user'), '@', 1)),
          new.email, new.phone)
  on conflict (id) do nothing;

  select * into inv from public.staff_invites
   where lower(email) = lower(coalesce(new.email,'')) and accepted_at is null limit 1;
  if found then
    insert into public.staff (id, email, name, role, invited_by)
    values (new.id, lower(new.email), split_part(new.email,'@',1), inv.role, inv.invited_by)
    on conflict (id) do update set role = excluded.role, status = 'active';
    update public.staff_invites set accepted_at = now() where id = inv.id;
  end if;
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- Grants a pending invite to someone who already had an account when invited.
-- Only ever matches the caller's own email.
create or replace function public.claim_staff_invite()
returns text language plpgsql security definer set search_path = public
as $$
declare em text; inv record;
begin
  select lower(email) into em from auth.users where id = auth.uid();
  if em is null then return null; end if;
  select * into inv from public.staff_invites where lower(email) = em and accepted_at is null limit 1;
  if not found then
    return (select role from public.staff where id = auth.uid());
  end if;
  insert into public.staff (id, email, name, role, invited_by)
  values (auth.uid(), em, split_part(em,'@',1), inv.role, inv.invited_by)
  on conflict (id) do update set role = excluded.role, status = 'active';
  update public.staff_invites set accepted_at = now() where id = inv.id;
  return inv.role;
end $$;

-- =====================================================================
-- 4. INTEGRITY TRIGGERS
--    The page sends what the user typed; these decide what is actually
--    stored, so prices, names, ratings and statuses can't be forged.
-- =====================================================================

-- Photographers can edit their profile but never their own rating,
-- job count, earnings or verified badge.
create or replace function public.photographer_guard()
returns trigger language plpgsql
as $$
declare can_verify boolean := coalesce(public.staff_role() in ('super_admin','admin'), false);
begin
  if public.snappro_system() then return new; end if;
  if tg_op = 'INSERT' then
    new.rating := null; new.review_count := 0; new.jobs_done := 0; new.earnings := 0;
    if not can_verify then new.is_verified := false; end if;
    new.approval_status := 'pending'; new.approved_at := null; new.approved_by := null;
    new.review_note := null; new.submitted_at := now();
  else
    new.rating := old.rating; new.review_count := old.review_count;
    new.jobs_done := old.jobs_done; new.earnings := old.earnings;
    if not can_verify then new.is_verified := old.is_verified; end if;
    new.approval_status := old.approval_status; new.approved_at := old.approved_at;
    new.approved_by := old.approved_by; new.review_note := old.review_note; new.submitted_at := old.submitted_at;
  end if;
  new.display_name := left(coalesce(nullif(trim(new.display_name),''), 'Photographer'), 60);
  new.bio := left(coalesce(new.bio,''), 600);
  new.portfolio := coalesce(new.portfolio[1:30], '{}');
  return new;
end $$;
drop trigger if exists photographer_guard on public.photographers;
create trigger photographer_guard before insert or update on public.photographers
  for each row execute function public.photographer_guard();

create or replace function public.request_before_insert()
returns trigger language plpgsql security definer set search_path = public
as $$
begin
  new.customer_id := auth.uid();
  select coalesce(nullif(split_part(trim(name),' ',1),''), 'Customer') into new.customer_name
    from public.profiles where id = auth.uid();
  new.status := 'broadcasting';
  new.created_at := now();
  if new.start_at is null or new.start_at < now() - interval '5 minutes' then
    new.start_at := now() + interval '30 minutes';
  end if;
  new.expires_at := least(coalesce(new.expires_at, now() + interval '2 hours'),
                          new.start_at + interval '1 hour',
                          now() + interval '3 days');
  if new.expires_at <= now() + interval '5 minutes' then
    new.expires_at := now() + interval '30 minutes';
  end if;
  new.duration_hrs := greatest(1, least(coalesce(new.duration_hrs, 2), 12));
  new.budget := greatest(0, least(coalesce(new.budget, 0), 1000000));
  new.notes := left(coalesce(new.notes,''), 800);
  return new;
end $$;
drop trigger if exists request_before_insert on public.requests;
create trigger request_before_insert before insert on public.requests
  for each row execute function public.request_before_insert();

create or replace function public.offer_before_insert()
returns trigger language plpgsql security definer set search_path = public
as $$
declare r record; pname text;
begin
  select display_name into pname from public.photographers where id = auth.uid();
  if pname is null then raise exception 'Only photographers can send quotes'; end if;
  if not exists (select 1 from public.photographers where id = auth.uid() and approval_status = 'approved') then
    raise exception 'Your profile is still being reviewed. You can send quotes once it is approved.';
  end if;
  select * into r from public.requests where id = new.request_id;
  if not found or r.status <> 'broadcasting' or r.expires_at <= now() then
    raise exception 'This request is no longer open';
  end if;
  if r.customer_id = auth.uid() then raise exception 'You can''t quote on your own request'; end if;
  if new.price is null or new.price < 100 or new.price > 1000000 then raise exception 'Enter a valid price'; end if;
  new.photographer_id := auth.uid();
  new.photographer_name := pname;
  new.eta_min := greatest(5, least(coalesce(new.eta_min, 30), 24*60));
  new.note := left(coalesce(new.note,''), 500);
  new.created_at := now();
  return new;
end $$;
drop trigger if exists offer_before_insert on public.offers;
create trigger offer_before_insert before insert on public.offers
  for each row execute function public.offer_before_insert();

-- A booking is built from the real offer and request. The page only
-- chooses which offer and supplies the address.
create or replace function public.booking_before_insert()
returns trigger language plpgsql security definer set search_path = public
as $$
declare o record; r record;
begin
  select * into o from public.offers where id = new.offer_id;
  if not found then raise exception 'That quote is no longer available'; end if;
  select * into r from public.requests where id = o.request_id;
  if not found or r.customer_id is distinct from auth.uid() then raise exception 'That isn''t your request'; end if;
  if r.status not in ('broadcasting','awaiting') then raise exception 'This request is already booked or closed'; end if;
  new.customer_id       := r.customer_id;
  new.photographer_id   := o.photographer_id;
  new.request_id        := r.id;
  new.price             := o.price;
  new.total_amount      := o.price;
  new.payout_amount     := o.price;
  new.category          := r.category;
  new.start_at          := r.start_at;
  new.duration_hrs      := r.duration_hrs;
  new.city              := r.city;
  new.pincode           := r.pincode;
  new.customer_name     := r.customer_name;
  new.photographer_name := o.photographer_name;
  new.address           := left(coalesce(new.address,''), 300);
  -- confirmed only once the payment is verified on the server
  new.status            := 'pending_payment';
  new.payment_status    := 'unpaid';
  new.commission_pct    := public.commission_pct();
  new.commission_amount := round(o.price * new.commission_pct / 100.0);
  new.photographer_amount := o.price - new.commission_amount;
  new.payout_amount     := new.photographer_amount;
  new.payout_status     := 'not_due';
  -- the advance confirms the booking; the balance is paid after the shoot
  new.advance_pct       := public.advance_pct();
  new.advance_amount    := least(o.price, greatest(1, round(o.price * new.advance_pct / 100.0)::int));
  new.balance_amount    := o.price - new.advance_amount;
  new.balance_status    := case when new.balance_amount > 0 then 'pending' else 'not_required' end;
  new.balance_paid_at   := null;
  new.paid_at := null; new.payout_ref := null; new.payout_at := null; new.payout_by := null;
  new.cancelled_from := null; new.cancelled_by := null;
  new.created_at        := now();
  new.updated_at        := now();
  return new;
end $$;
drop trigger if exists booking_before_insert on public.bookings;
create trigger booking_before_insert before insert on public.bookings
  for each row execute function public.booking_before_insert();

create or replace function public.booking_after_insert()
returns trigger language plpgsql security definer set search_path = public
as $$
begin
  update public.requests set status = 'matched' where id = new.request_id;
  return new;
end $$;
drop trigger if exists booking_after_insert on public.bookings;
create trigger booking_after_insert after insert on public.bookings
  for each row execute function public.booking_after_insert();

-- Only status (and, for the customer, the address) can ever change, and
-- only along the real journey: the photographer moves it forward, the
-- customer can only cancel before the shoot starts.
create or replace function public.booking_before_update()
returns trigger language plpgsql
as $$
declare me uuid := auth.uid(); chk public.bookings;
begin
  if public.snappro_system() then return new; end if;
  chk := new; chk.status := old.status; chk.address := old.address; chk.updated_at := old.updated_at;
  if chk is distinct from old then raise exception 'Booking details can''t be changed'; end if;

  if new.status is distinct from old.status then
    if me = old.customer_id then
      if not (new.status = 'cancelled' and old.status in ('pending_payment','confirmed','enroute')) then
        raise exception 'You can only cancel before the shoot starts';
      end if;
    elsif me = old.photographer_id then
      if not ((old.status = 'confirmed' and new.status in ('enroute','cancelled'))
           or (old.status = 'enroute'   and new.status in ('arrived','cancelled'))
           or (old.status = 'arrived'   and new.status = 'shooting')
           or (old.status = 'shooting'  and new.status = 'completed')) then
        raise exception 'That status change isn''t allowed';
      end if;
    else
      raise exception 'Not allowed';
    end if;
  end if;

  if new.address is distinct from old.address then
    if me is distinct from old.customer_id or old.status not in ('pending_payment','confirmed') then
      raise exception 'Only the customer can change the address, before the photographer sets off';
    end if;
    new.address := left(coalesce(new.address,''), 300);
  end if;
  -- money follows the booking: a paid booking that's cancelled is owed a refund,
  -- a paid booking that's completed is owed a payout to the photographer
  if new.status = 'cancelled' and old.status <> 'cancelled' then
    new.cancelled_from := old.status;
    new.cancelled_by := case when me = old.customer_id then 'customer' when me = old.photographer_id then 'photographer' else 'system' end;
    if old.payment_status = 'paid' then new.payment_status := 'refund_due'; end if;
  end if;
  -- the balance can be paid once the shoot has started
  if new.status = 'shooting' and old.status <> 'shooting' and old.balance_status = 'pending' then
    new.balance_status := 'due';
  end if;
  -- the photographer is owed their share once the shoot is done AND fully paid
  if new.status = 'completed' and old.status <> 'completed' and old.payment_status = 'paid'
     and coalesce(new.balance_status, 'not_required') in ('paid','not_required') then
    new.payout_status := 'due';
  end if;
  new.updated_at := now();
  return new;
end $$;
drop trigger if exists booking_before_update on public.bookings;
create trigger booking_before_update before update on public.bookings
  for each row execute function public.booking_before_update();

create or replace function public.booking_after_update()
returns trigger language plpgsql security definer set search_path = public
as $$
begin
  if new.status = 'completed' and old.status is distinct from 'completed' then
    perform set_config('snappro.system', 'on', true);
    update public.photographers
       set jobs_done = jobs_done + 1, earnings = earnings + coalesce(new.photographer_amount, new.price, 0)
     where id = new.photographer_id;
    perform set_config('snappro.system', '', true);
  end if;
  if new.status = 'cancelled' and old.status is distinct from 'cancelled' then
    -- let the customer pick another quote
    update public.requests set status = 'awaiting' where id = new.request_id and status = 'matched';
    if new.payment_status = 'refund_due' then
      update public.payments set refund_status = 'refund_due', updated_at = now()
       where booking_id = new.id and status = 'paid' and refund_status = 'none';
    end if;
  end if;
  return new;
end $$;
drop trigger if exists booking_after_update on public.bookings;
create trigger booking_after_update after update on public.bookings
  for each row execute function public.booking_after_update();

create or replace function public.message_before_insert()
returns trigger language plpgsql
as $$
begin
  new.sender_id := auth.uid();
  new.content := left(trim(coalesce(new.content,'')), 2000);
  if new.content = '' then raise exception 'Message is empty'; end if;
  new.created_at := now();
  return new;
end $$;
drop trigger if exists message_before_insert on public.messages;
create trigger message_before_insert before insert on public.messages
  for each row execute function public.message_before_insert();

create or replace function public.review_before_insert()
returns trigger language plpgsql security definer set search_path = public
as $$
declare b record;
begin
  select * into b from public.bookings where id = new.booking_id;
  if not found or b.customer_id is distinct from auth.uid() then raise exception 'That isn''t your booking'; end if;
  if b.status <> 'completed' then raise exception 'You can leave a review once the shoot is complete'; end if;
  new.customer_id     := b.customer_id;
  new.photographer_id := b.photographer_id;
  new.customer_name   := coalesce(b.customer_name, 'Customer');
  new.body            := left(coalesce(new.body,''), 1000);
  new.created_at      := now();
  return new;
end $$;
drop trigger if exists review_before_insert on public.reviews;
create trigger review_before_insert before insert on public.reviews
  for each row execute function public.review_before_insert();

create or replace function public.review_after_insert()
returns trigger language plpgsql security definer set search_path = public
as $$
begin
  perform set_config('snappro.system', 'on', true);
  update public.photographers p
     set rating = s.avg_stars, review_count = s.n
    from (select round(avg(stars)::numeric, 1) as avg_stars, count(*)::int as n
            from public.reviews where photographer_id = new.photographer_id) s
   where p.id = new.photographer_id;
  perform set_config('snappro.system', '', true);
  return new;
end $$;
drop trigger if exists review_after_insert on public.reviews;
create trigger review_after_insert after insert on public.reviews
  for each row execute function public.review_after_insert();

-- =====================================================================
-- 5. ROW LEVEL SECURITY
-- =====================================================================

alter table public.profiles      enable row level security;
alter table public.photographers enable row level security;
alter table public.requests      enable row level security;
alter table public.offers        enable row level security;
alter table public.bookings      enable row level security;
alter table public.messages      enable row level security;
alter table public.reviews       enable row level security;
alter table public.staff         enable row level security;
alter table public.staff_invites enable row level security;

-- Remove any blanket "allow everything" policy, whatever it was named.
-- Postgres ORs policies together, so one of these would override every rule below.
do $$
declare r record;
begin
  for r in select schemaname, tablename, policyname from pg_policies
            where schemaname = 'public'
              and tablename in ('profiles','photographers','requests','offers','bookings','messages','reviews','staff','staff_invites')
              and coalesce(qual,'true') = 'true' and cmd = 'ALL'
  loop
    execute format('drop policy if exists %I on %I.%I', r.policyname, r.schemaname, r.tablename);
  end loop;
end $$;

-- profiles: private — your own row only (staff admins can read for support)
drop policy if exists profiles_select_own  on public.profiles;
create policy profiles_select_own on public.profiles for select to authenticated using (auth.uid() = id);
drop policy if exists profiles_insert_own  on public.profiles;
create policy profiles_insert_own on public.profiles for insert to authenticated with check (auth.uid() = id);
drop policy if exists profiles_update_own  on public.profiles;
create policy profiles_update_own on public.profiles for update to authenticated using (auth.uid() = id) with check (auth.uid() = id);
drop policy if exists profiles_staff_read  on public.profiles;
create policy profiles_staff_read on public.profiles for select to authenticated
  using (coalesce(public.staff_role() in ('super_admin','admin'), false));

-- photographers: public listing
drop policy if exists photographers_select_all   on public.photographers;
create policy photographers_select_all on public.photographers for select
  using (approval_status = 'approved' or id = auth.uid() or public.is_staff());
drop policy if exists photographers_insert_own   on public.photographers;
create policy photographers_insert_own on public.photographers for insert to authenticated with check (auth.uid() = id);
drop policy if exists photographers_update_own   on public.photographers;
create policy photographers_update_own on public.photographers for update to authenticated using (auth.uid() = id) with check (auth.uid() = id);
drop policy if exists photographers_staff_update on public.photographers;
create policy photographers_staff_update on public.photographers for update to authenticated
  using (coalesce(public.staff_role() in ('super_admin','admin'), false))
  with check (coalesce(public.staff_role() in ('super_admin','admin'), false));

-- requests: yours, plus open ones (city, pincode, budget — never an address)
drop policy if exists requests_select      on public.requests;
create policy requests_select on public.requests for select to authenticated
  using (customer_id = auth.uid() or (status = 'broadcasting' and expires_at > now()));
drop policy if exists requests_insert_own  on public.requests;
create policy requests_insert_own on public.requests for insert to authenticated with check (customer_id = auth.uid());
drop policy if exists requests_update_own  on public.requests;
create policy requests_update_own on public.requests for update to authenticated using (customer_id = auth.uid()) with check (customer_id = auth.uid());
drop policy if exists requests_staff_read  on public.requests;
create policy requests_staff_read on public.requests for select to authenticated using (public.is_staff());

-- offers: the photographer who sent it, and the customer who asked
drop policy if exists offers_select      on public.offers;
create policy offers_select on public.offers for select to authenticated
  using (photographer_id = auth.uid()
         or exists (select 1 from public.requests r where r.id = offers.request_id and r.customer_id = auth.uid()));
drop policy if exists offers_insert_own  on public.offers;
create policy offers_insert_own on public.offers for insert to authenticated with check (photographer_id = auth.uid());
drop policy if exists offers_delete_own  on public.offers;
create policy offers_delete_own on public.offers for delete to authenticated using (photographer_id = auth.uid());
drop policy if exists offers_staff_read  on public.offers;
create policy offers_staff_read on public.offers for select to authenticated using (public.is_staff());

-- bookings: only the two people on it
drop policy if exists bookings_select_party on public.bookings;
create policy bookings_select_party on public.bookings for select to authenticated
  using (customer_id = auth.uid() or (photographer_id = auth.uid() and status <> 'pending_payment'));
drop policy if exists bookings_insert_own   on public.bookings;
create policy bookings_insert_own on public.bookings for insert to authenticated with check (customer_id = auth.uid());
drop policy if exists bookings_update_party on public.bookings;
create policy bookings_update_party on public.bookings for update to authenticated
  using (customer_id = auth.uid() or (photographer_id = auth.uid() and status <> 'pending_payment'))
  with check (customer_id = auth.uid() or photographer_id = auth.uid());
drop policy if exists bookings_staff_read   on public.bookings;
create policy bookings_staff_read on public.bookings for select to authenticated using (public.is_staff());

-- messages: the two people on the booking
drop policy if exists messages_select_party on public.messages;
create policy messages_select_party on public.messages for select to authenticated
  using (exists (select 1 from public.bookings b where b.id = messages.booking_id
                  and (b.customer_id = auth.uid() or b.photographer_id = auth.uid())));
drop policy if exists messages_insert_party on public.messages;
create policy messages_insert_party on public.messages for insert to authenticated
  with check (sender_id = auth.uid()
              and exists (select 1 from public.bookings b where b.id = messages.booking_id
                           and (b.customer_id = auth.uid() or b.photographer_id = auth.uid())
                           and b.status not in ('cancelled','pending_payment')));
drop policy if exists messages_staff_read   on public.messages;
create policy messages_staff_read on public.messages for select to authenticated
  using (coalesce(public.staff_role() in ('super_admin','admin'), false));

-- reviews: public to read; written only by the customer of a completed booking
drop policy if exists reviews_read_all        on public.reviews;
create policy reviews_read_all on public.reviews for select using (true);
drop policy if exists reviews_insert_customer on public.reviews;
create policy reviews_insert_customer on public.reviews for insert to authenticated
  with check (customer_id = auth.uid()
              and exists (select 1 from public.bookings b where b.id = reviews.booking_id
                           and b.customer_id = auth.uid() and b.status = 'completed'));

-- staff
drop policy if exists staff_select       on public.staff;
create policy staff_select on public.staff for select to authenticated using (public.is_staff() or id = auth.uid());
drop policy if exists staff_super_insert on public.staff;
create policy staff_super_insert on public.staff for insert to authenticated with check (public.is_super());
drop policy if exists staff_super_update on public.staff;
create policy staff_super_update on public.staff for update to authenticated using (public.is_super()) with check (public.is_super());
drop policy if exists staff_super_delete on public.staff;
create policy staff_super_delete on public.staff for delete to authenticated using (public.is_super() and id <> auth.uid());
drop policy if exists invites_super_all  on public.staff_invites;
create policy invites_super_all on public.staff_invites for all to authenticated using (public.is_super()) with check (public.is_super());

-- Policies from the old schema.sql that this file replaces under new names
drop policy if exists requests_select_own on public.requests;

-- ---------------------------------------------------------------------
-- OWNER LOCK: the owner account is always an active super admin.
-- Nobody can change its role, suspend it, remove it from the team or
-- delete the account — not other super admins, not the website, and not
-- the SQL editor (these triggers run for every database user).
-- ---------------------------------------------------------------------
create or replace function public.is_owner_email(e text)
returns boolean language sql immutable
as $$ select lower(trim(coalesce(e,''))) in ('prathmeshsingh99@gmail.com') $$;

create or replace function public.staff_owner_lock()
returns trigger language plpgsql
as $$
begin
  if tg_op = 'DELETE' then
    if public.is_owner_email(old.email) then
      raise exception 'The owner account (%) is locked as super admin and can''t be removed', old.email;
    end if;
    return old;
  end if;
  if tg_op = 'UPDATE' and public.is_owner_email(old.email) then
    if new.role is distinct from 'super_admin' or new.status is distinct from 'active'
       or new.id is distinct from old.id or lower(new.email) is distinct from lower(old.email) then
      raise exception 'The owner account (%) is locked as super admin and can''t be changed or suspended', old.email;
    end if;
  end if;
  if tg_op = 'INSERT' and public.is_owner_email(new.email) then
    new.role := 'super_admin'; new.status := 'active';
  end if;
  return new;
end $$;
drop trigger if exists staff_owner_lock on public.staff;
create trigger staff_owner_lock before insert or update or delete on public.staff
  for each row execute function public.staff_owner_lock();

-- an invite for the owner's email can only ever be for super admin
create or replace function public.invite_owner_lock()
returns trigger language plpgsql
as $$
begin
  if public.is_owner_email(new.email) then new.role := 'super_admin'; end if;
  return new;
end $$;
drop trigger if exists invite_owner_lock on public.staff_invites;
create trigger invite_owner_lock before insert or update on public.staff_invites
  for each row execute function public.invite_owner_lock();

-- the owner's login can't be deleted either (it would take the staff row with it)
create or replace function public.auth_owner_lock()
returns trigger language plpgsql
as $$
begin
  if public.is_owner_email(old.email) then
    raise exception 'The owner account (%) can''t be deleted', old.email;
  end if;
  return old;
end $$;
drop trigger if exists auth_owner_lock on auth.users;
create trigger auth_owner_lock before delete on auth.users
  for each row execute function public.auth_owner_lock();

-- =====================================================================
-- 6. PORTFOLIO PHOTOS (Supabase Storage)
--    Anyone can view. A photographer can only add or delete files inside
--    a folder named after their own account id.
-- =====================================================================

insert into storage.buckets (id, name, public)
values ('portfolio', 'portfolio', true)
on conflict (id) do update set public = true;
update storage.buckets
   set file_size_limit = 5242880,
       allowed_mime_types = array['image/jpeg','image/png','image/webp']
 where id = 'portfolio';

drop policy if exists "snappro portfolio read"       on storage.objects;
create policy "snappro portfolio read" on storage.objects for select using (bucket_id = 'portfolio');
drop policy if exists "snappro portfolio upload own" on storage.objects;
create policy "snappro portfolio upload own" on storage.objects for insert to authenticated
  with check (bucket_id = 'portfolio' and (storage.foldername(name))[1] = auth.uid()::text);
drop policy if exists "snappro portfolio delete own" on storage.objects;
create policy "snappro portfolio delete own" on storage.objects for delete to authenticated
  using (bucket_id = 'portfolio' and (storage.foldername(name))[1] = auth.uid()::text);

-- =====================================================================
-- 7. STAFF INVITE EMAILS
--    Sent by the database through Brevo. The Brevo API key lives in
--    Supabase Vault under the name  brevo_api_key  — it never appears in
--    the website, the repository, or this file.
-- =====================================================================

alter table public.staff_invites
  add column if not exists email_request bigint,
  add column if not exists email_sent_at timestamptz;

-- returns the pg_net request id, or null when no Brevo key is saved
drop function if exists public._send_invite_email(text, text);
create or replace function public._send_invite_email(p_email text, p_role text)
returns bigint language plpgsql security definer set search_path = public, extensions
as $$
declare api_key text; role_label text; link text; safe_email text; html text; req bigint;
begin
  begin
    select decrypted_secret into api_key from vault.decrypted_secrets where name = 'brevo_api_key' limit 1;
  exception when others then api_key := null;
  end;
  if coalesce(api_key,'') = '' then
    raise warning 'SnapPro: no brevo_api_key in Vault — invite email to % was not sent', p_email;
    return null;
  end if;

  role_label := case p_role when 'super_admin' then 'Super admin' when 'admin' then 'Admin' else 'Manager' end;
  safe_email := replace(replace(replace(p_email,'&','&amp;'),'<','&lt;'),'>','&gt;');
  link := 'https://snappro.in/admin.html#setup=' ||
          replace(replace(replace(lower(p_email),'%','%25'),'+','%2B'),'@','%40');

  html :=
    '<div style="background:#f4f4f7;padding:32px 16px;font-family:-apple-system,Segoe UI,Roboto,Arial,sans-serif">'
    || '<div style="max-width:480px;margin:0 auto;background:#ffffff;border-radius:14px;padding:32px">'
    || '<div style="font-size:20px;font-weight:800;color:#ff5a1f;margin-bottom:20px">SnapPro</div>'
    || '<h1 style="font-size:20px;color:#111;margin:0 0 12px">You''ve been invited to the SnapPro team</h1>'
    || '<p style="font-size:15px;color:#444;line-height:1.55;margin:0 0 8px">You''ve been given <b>' || role_label
    || '</b> access to SnapPro operations.</p>'
    || '<p style="font-size:15px;color:#444;line-height:1.55;margin:0 0 24px">Set up your account with <b>' || safe_email
    || '</b>: create a password, then enter the 6-digit code we email you.</p>'
    || '<a href="' || link || '" style="display:inline-block;background:#ff5a1f;color:#fff;text-decoration:none;'
    || 'font-weight:700;font-size:15px;padding:13px 22px;border-radius:10px">Set up your account</a>'
    || '<p style="font-size:13px;color:#777;line-height:1.5;margin:24px 0 0">Already have a SnapPro account with this email? '
    || 'Open the link and choose <b>Forgot password?</b> instead.</p>'
    || '<p style="font-size:12px;color:#999;margin:24px 0 0">If you weren''t expecting this, you can ignore this email.</p>'
    || '</div></div>';

  select net.http_post(
    url     := 'https://api.brevo.com/v3/smtp/email',
    body    := jsonb_build_object(
                 'sender',      jsonb_build_object('name','SnapPro','email','noreply@snappro.in'),
                 'to',          jsonb_build_array(jsonb_build_object('email', p_email)),
                 'subject',     'You''re invited to the SnapPro team',
                 'htmlContent', html),
    headers := jsonb_build_object('api-key', api_key, 'content-type','application/json', 'accept','application/json'),
    timeout_milliseconds := 8000) into req;
  return req;
end $$;

-- Sends the email after the invite is saved (an upsert that turns into an
-- update fires only once), then records the request id on the row.
-- pg_net only sends once the transaction commits.
drop trigger if exists staff_invite_email on public.staff_invites;
drop function if exists public.staff_invite_before_write();
create or replace function public.staff_invite_after_write()
returns trigger language plpgsql security definer set search_path = public
as $$
declare req bigint;
begin
  if new.accepted_at is not null then return new; end if;
  if tg_op = 'UPDATE' and old.accepted_at is null and old.role = new.role
     and lower(old.email) = lower(new.email) then return new; end if;
  if exists (select 1 from public.staff where lower(email) = lower(new.email)) then return new; end if;
  req := public._send_invite_email(new.email, new.role);
  update public.staff_invites set email_request = req, email_sent_at = now() where id = new.id;
  return new;
end $$;
create trigger staff_invite_email after insert or update on public.staff_invites
  for each row execute function public.staff_invite_after_write();

create or replace function public.resend_staff_invite(p_id uuid)
returns boolean language plpgsql security definer set search_path = public
as $$
declare inv record; req bigint;
begin
  if not public.is_super() then raise exception 'Only a super admin can resend invites'; end if;
  select * into inv from public.staff_invites where id = p_id and accepted_at is null;
  if not found then return false; end if;
  req := public._send_invite_email(inv.email, inv.role);
  update public.staff_invites set email_request = req, email_sent_at = now() where id = p_id;
  return req is not null;
end $$;

-- Is a Brevo key saved? (super admins only — never returns the key)
create or replace function public.invite_email_ready()
returns boolean language plpgsql security definer set search_path = public
as $$
declare k text;
begin
  if not public.is_super() then return null; end if;
  begin
    select decrypted_secret into k from vault.decrypted_secrets where name = 'brevo_api_key' limit 1;
  exception when others then k := null;
  end;
  return coalesce(k,'') <> '';
end $$;

-- What Brevo said about each pending invite email
create or replace function public.invite_email_status()
returns table(invite_id uuid, status_code int, detail text, pending boolean)
language plpgsql security definer set search_path = public
as $$
begin
  if not public.is_super() then return; end if;
  return query
    select i.id, r.status_code,
           left(coalesce(r.error_msg, r.content::text, ''), 300),
           (i.email_request is not null and r.id is null)
      from public.staff_invites i
      left join net._http_response r on r.id = i.email_request
     where i.accepted_at is null;
end $$;


-- =====================================================================
-- 7b. PHOTOGRAPHER APPROVAL
--     Admins and super admins approve or reject new photographers. The
--     photographer gets an email either way (when a Brevo key is saved).
-- =====================================================================

create or replace function public._send_email(p_to text, p_subject text, p_html text)
returns bigint language plpgsql security definer set search_path = public, extensions
as $$
declare api_key text; req bigint;
begin
  begin
    select decrypted_secret into api_key from vault.decrypted_secrets where name = 'brevo_api_key' limit 1;
  exception when others then api_key := null;
  end;
  if coalesce(api_key,'') = '' or coalesce(p_to,'') = '' then return null; end if;
  select net.http_post(
    url     := 'https://api.brevo.com/v3/smtp/email',
    body    := jsonb_build_object('sender', jsonb_build_object('name','SnapPro','email','noreply@snappro.in'),
                                  'to', jsonb_build_array(jsonb_build_object('email', p_to)),
                                  'subject', p_subject, 'htmlContent', p_html),
    headers := jsonb_build_object('api-key', api_key, 'content-type','application/json', 'accept','application/json'),
    timeout_milliseconds := 8000) into req;
  return req;
end $$;

create or replace function public._email_shell(p_title text, p_body text, p_button text, p_link text)
returns text language sql immutable
as $$
  select '<div style="background:#f4f0e8;padding:32px 16px;font-family:-apple-system,Segoe UI,Roboto,Arial,sans-serif">'
      || '<div style="max-width:480px;margin:0 auto;background:#fffdf8;border:1px solid #ddd5c7;border-radius:10px;padding:32px">'
      || '<div style="font-family:Georgia,serif;font-size:24px;color:#1d1a16;margin-bottom:20px">SnapPro</div>'
      || '<h1 style="font-size:20px;color:#1d1a16;margin:0 0 12px">' || p_title || '</h1>'
      || '<div style="font-size:15px;color:#4a443c;line-height:1.6">' || p_body || '</div>'
      || case when p_button is not null then
           '<a href="' || p_link || '" style="display:inline-block;margin-top:22px;background:#1d1a16;color:#fff;'
        || 'text-decoration:none;font-weight:600;font-size:15px;padding:12px 20px;border-radius:8px">' || p_button || '</a>'
         else '' end
      || '<p style="font-size:12px;color:#9a9184;margin:26px 0 0">Questions? Reply to snappro.support@gmail.com</p>'
      || '</div></div>'
$$;

create or replace function public._esc(t text) returns text language sql immutable
as $$ select replace(replace(replace(replace(coalesce(t,''),'&','&amp;'),'<','&lt;'),'>','&gt;'),'"','&quot;') $$;

create or replace function public.set_photographer_approval(p_id uuid, p_status text, p_note text default null)
returns text language plpgsql security definer set search_path = public
as $$
declare em text; nm text;
begin
  if coalesce(public.staff_role() in ('super_admin','admin'), false) is not true then
    raise exception 'Only admins can approve photographers';
  end if;
  if p_status not in ('approved','rejected','pending') then raise exception 'Unknown status'; end if;
  if p_status = 'rejected' and coalesce(trim(p_note),'') = '' then
    raise exception 'Add a short reason so the photographer knows what to fix';
  end if;
  perform set_config('snappro.system', 'on', true);
  update public.photographers
     set approval_status = p_status,
         approved_at = case when p_status = 'approved' then now() end,
         approved_by = case when p_status = 'approved' then auth.uid() end,
         review_note = case when p_status = 'rejected' then left(trim(p_note), 500) end
   where id = p_id
  returning display_name into nm;
  perform set_config('snappro.system', '', true);
  if nm is null then raise exception 'Photographer not found'; end if;

  select email into em from auth.users where id = p_id;
  if p_status = 'approved' then
    perform public._send_email(em, 'You''re approved on SnapPro',
      public._email_shell('You''re approved, ' || public._esc(split_part(nm,' ',1)) || '.',
        'Your SnapPro profile is live. Customers in your city can now see your work, and you''ll see their shoot requests and can send your own price.',
        'Open SnapPro', 'https://snappro.in/app.html#login'));
  elsif p_status = 'rejected' then
    perform public._send_email(em, 'About your SnapPro profile',
      public._email_shell('We couldn''t approve your profile yet',
        'Thanks for signing up. Before we can approve you, please take a look at this:<br><br><i>'
        || public._esc(p_note) || '</i><br><br>Make the changes in the app and ask for another review.',
        'Open SnapPro', 'https://snappro.in/app.html#login'));
  end if;
  return p_status;
end $$;

-- A rejected photographer who has made changes asks to be looked at again.
create or replace function public.request_photographer_review()
returns text language plpgsql security definer set search_path = public
as $$
declare st text;
begin
  select approval_status into st from public.photographers where id = auth.uid();
  if st is null then raise exception 'No photographer profile'; end if;
  if st <> 'rejected' then return st; end if;
  perform set_config('snappro.system', 'on', true);
  update public.photographers set approval_status = 'pending', submitted_at = now() where id = auth.uid();
  perform set_config('snappro.system', '', true);
  return 'pending';
end $$;

-- =====================================================================
-- 7c. PAYMENTS (Razorpay)
--     Customers pay online in two parts: an advance (25% by default,
--     platform_settings.advance_pct) that confirms the booking, and the
--     balance once the shoot has started. Money settles to the SnapPro
--     merchant account; SnapPro keeps its commission and pays the
--     photographer separately once both parts are paid (payout_status).
--
--     The browser never changes payment state. Only the server functions
--     (Supabase Edge Functions using the service key) call the pay_*
--     functions below, after verifying with Razorpay (payment signature,
--     signed webhook, or Razorpay's own API). No card, CVV, UPI PIN or UPI
--     ID is stored.
--
--     Each part (advance / balance) keeps ONE Razorpay order. Razorpay refuses
--     further payments once an order is paid, so nothing can be paid twice.
--
--     Later, automatic splits: Razorpay Route — create a linked account per
--     photographer, store it in photographers.payout_account_id and add
--     "transfers" when creating the order.
-- =====================================================================

alter table public.photographers add column if not exists payout_account_id text;   -- for future Route split
alter table public.photographers drop column if exists cf_vendor_id;                -- (from the Cashfree version)

create table if not exists public.payments (
  id                  uuid primary key default gen_random_uuid(),
  order_id            text not null unique,                 -- our reference, sent to Razorpay as the receipt
  booking_id          uuid references public.bookings(id) on delete set null,
  customer_id         uuid,
  photographer_id     uuid,
  amount              numeric(12,2) not null check (amount >= 1),
  currency            text not null default 'INR',
  commission_amount   numeric(12,2) not null default 0,
  photographer_amount numeric(12,2) not null default 0,
  status              text not null default 'created',
  provider            text not null default 'razorpay',
  environment         text not null default 'test',
  gateway_order_id    text,                                 -- Razorpay order_…
  gateway_payment_id  text,                                 -- Razorpay pay_…
  payment_group       text,                                 -- upi / card / netbanking / wallet …
  bank_reference      text,                                 -- RRN / UPI transaction id
  payment_message     text,
  paid_at             timestamptz,
  refund_status       text not null default 'none',
  refunded_amount     numeric(12,2) not null default 0,
  is_duplicate        boolean not null default false,       -- a second payment for an already-paid booking
  note                text,
  split_details       jsonb,                                -- future split, not used yet
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);
-- upgrade a database that ran the Cashfree version of this file
do $$ begin
  if exists (select 1 from information_schema.columns where table_schema='public' and table_name='payments' and column_name='cf_order_id') then
    alter table public.payments rename column cf_order_id to gateway_order_id;
  end if;
  if exists (select 1 from information_schema.columns where table_schema='public' and table_name='payments' and column_name='cf_payment_id') then
    alter table public.payments rename column cf_payment_id to gateway_payment_id;
  end if;
end $$;
alter table public.payments
  add column if not exists provider text not null default 'razorpay',
  add column if not exists gateway_order_id text,
  add column if not exists gateway_payment_id text;
alter table public.payments
  add column if not exists stage text not null default 'advance';
alter table public.payments drop constraint if exists payments_stage_check;
alter table public.payments add constraint payments_stage_check check (stage in ('advance','balance'));
alter table public.payments drop column if exists payment_session_id;
alter table public.payments drop column if exists session_expires_at;
alter table public.payments alter column environment set default 'test';
alter table public.payments drop constraint if exists payments_environment_check;
alter table public.payments add constraint payments_environment_check check (environment in ('test','live','sandbox','production'));
alter table public.payments drop constraint if exists payments_status_check;
alter table public.payments add constraint payments_status_check
  check (status in ('created','active','paid','failed','user_dropped','cancelled','expired','terminated'));
alter table public.payments drop constraint if exists payments_refund_status_check;
alter table public.payments add constraint payments_refund_status_check
  check (refund_status in ('none','refund_due','refund_pending','refunded','partially_refunded','refund_failed'));
create index if not exists idx_payments_booking  on public.payments(booking_id);

-- Bookings from before the advance/balance split: anything already paid (or
-- paid directly) was paid in full; unpaid ones switch to the advance.
do $$ begin
  perform set_config('snappro.system', 'on', true);
  update public.bookings
     set advance_pct = public.advance_pct(),
         advance_amount = least(price, greatest(1, round(price * public.advance_pct() / 100.0)::int)),
         balance_amount = price - least(price, greatest(1, round(price * public.advance_pct() / 100.0)::int)),
         balance_status = case when price - least(price, greatest(1, round(price * public.advance_pct() / 100.0)::int)) > 0
                               then 'pending' else 'not_required' end
   where balance_status is null and status = 'pending_payment' and payment_status = 'unpaid' and coalesce(price,0) >= 1;
  update public.bookings
     set advance_amount = coalesce(price,0), balance_amount = 0, balance_status = 'not_required'
   where balance_status is null;
  -- full-amount orders opened for those unpaid bookings are replaced by advance orders
  update public.payments p set status = 'terminated', updated_at = now()
    from public.bookings b
   where b.id = p.booking_id and p.status in ('created','active') and p.stage = 'advance'
     and b.status = 'pending_payment' and p.amount <> b.advance_amount;
  perform set_config('snappro.system', '', true);
end $$;
do $$ begin
  alter table public.bookings add constraint bookings_balance_status_check
    check (balance_status in ('not_required','pending','due','paid'));
exception when duplicate_object then null; end $$;
create index if not exists idx_payments_customer on public.payments(customer_id);
create index if not exists idx_payments_created  on public.payments(created_at desc);
create unique index if not exists uniq_payments_gateway_order on public.payments(gateway_order_id) where gateway_order_id is not null;

-- every webhook / verification we act on, so nothing is processed twice
create table if not exists public.payment_events (
  id             bigserial primary key,
  event_key      text not null unique,
  order_id       text,
  event_type     text,
  payment_status text,
  payment_ref    text,
  received_at    timestamptz not null default now()
);
do $$ begin
  if exists (select 1 from information_schema.columns where table_schema='public' and table_name='payment_events' and column_name='cf_payment_id') then
    alter table public.payment_events rename column cf_payment_id to payment_ref;
  end if;
end $$;

create table if not exists public.refunds (
  id                 uuid primary key default gen_random_uuid(),
  refund_id          text not null unique,                  -- our reference, sent to Razorpay as the receipt
  payment_id         uuid not null references public.payments(id),
  order_id           text not null,
  amount             numeric(12,2) not null check (amount > 0),
  status             text not null default 'requested',
  gateway_refund_id  text,                                  -- Razorpay rfnd_…
  refund_arn         text,
  reason             text,
  requested_by       uuid,
  processed_at       timestamptz,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now()
);
do $$ begin
  if exists (select 1 from information_schema.columns where table_schema='public' and table_name='refunds' and column_name='cf_refund_id') then
    alter table public.refunds rename column cf_refund_id to gateway_refund_id;
  end if;
end $$;
alter table public.refunds add column if not exists gateway_refund_id text;
alter table public.refunds drop constraint if exists refunds_status_check;
alter table public.refunds add constraint refunds_status_check
  check (status in ('requested','pending','pending_approval','onhold','success','cancelled','rejected','failed'));
create index if not exists idx_refunds_payment on public.refunds(payment_id);

-- Where SnapPro sends each photographer's share (kept apart from the public profile)
create table if not exists public.photographer_payout (
  id           uuid primary key references public.photographers(id) on delete cascade,
  upi_id       text check (upi_id is null or upi_id ~ '^[A-Za-z0-9._-]{2,128}@[A-Za-z][A-Za-z0-9.-]{1,64}$'),
  account_name text check (account_name is null or length(account_name) <= 100),
  updated_at   timestamptz not null default now()
);

alter table public.payments            enable row level security;
alter table public.payment_events      enable row level security;
alter table public.refunds             enable row level security;
alter table public.platform_settings   enable row level security;
alter table public.photographer_payout enable row level security;

drop policy if exists payments_customer_read on public.payments;
create policy payments_customer_read on public.payments for select to authenticated using (customer_id = auth.uid());
drop policy if exists payments_staff_read on public.payments;
create policy payments_staff_read on public.payments for select to authenticated
  using (coalesce(public.staff_role() in ('super_admin','admin'), false));
drop policy if exists refunds_staff_read on public.refunds;
create policy refunds_staff_read on public.refunds for select to authenticated
  using (coalesce(public.staff_role() in ('super_admin','admin'), false));
drop policy if exists refunds_customer_read on public.refunds;
create policy refunds_customer_read on public.refunds for select to authenticated
  using (exists (select 1 from public.payments p where p.id = refunds.payment_id and p.customer_id = auth.uid()));
drop policy if exists payment_events_staff_read on public.payment_events;
create policy payment_events_staff_read on public.payment_events for select to authenticated
  using (coalesce(public.staff_role() in ('super_admin','admin'), false));
drop policy if exists settings_read on public.platform_settings;
create policy settings_read on public.platform_settings for select using (true);
drop policy if exists payout_own_read   on public.photographer_payout;
create policy payout_own_read   on public.photographer_payout for select to authenticated using (id = auth.uid());
drop policy if exists payout_own_insert on public.photographer_payout;
create policy payout_own_insert on public.photographer_payout for insert to authenticated with check (id = auth.uid());
drop policy if exists payout_own_update on public.photographer_payout;
create policy payout_own_update on public.photographer_payout for update to authenticated using (id = auth.uid()) with check (id = auth.uid());
drop policy if exists payout_staff_read on public.photographer_payout;
create policy payout_staff_read on public.photographer_payout for select to authenticated
  using (coalesce(public.staff_role() in ('super_admin','admin'), false));
-- no insert/update/delete policies on payment tables: only the functions below write them

-- old Cashfree-era signatures (their parameter names changed)
drop function if exists public.pay_set_session(text, text, text, timestamptz);
drop function if exists public.pay_record(text, text, text, text, numeric, text, text, text, text);
drop function if exists public.pay_refund_update(text, text, text, text, text);

-- Which part of a booking is payable right now, and how much.
create or replace function public._pay_stage(b public.bookings)
returns table(stage text, amount integer, commission numeric, photographer numeric)
language plpgsql stable set search_path = public
as $$
declare adv int := coalesce(b.advance_amount, b.price); adv_comm int := least(coalesce(b.commission_amount,0), adv);
begin
  if b.status = 'pending_payment' and b.payment_status = 'unpaid' then
    return query select 'advance'::text, adv, adv_comm::numeric, (adv - adv_comm)::numeric;
  elsif b.status in ('shooting','completed') and b.balance_status = 'due' and coalesce(b.balance_amount,0) >= 1 then
    return query select 'balance'::text, b.balance_amount,
                        (coalesce(b.commission_amount,0) - adv_comm)::numeric,
                        (b.balance_amount - (coalesce(b.commission_amount,0) - adv_comm))::numeric;
  elsif b.status = 'cancelled' then
    raise exception 'This booking can''t be paid for any more';
  elsif b.balance_status = 'paid' or (b.payment_status = 'paid' and b.balance_status = 'not_required') then
    raise exception 'This booking is already paid';
  elsif b.balance_status = 'pending' then
    raise exception 'The balance can be paid once the shoot starts';
  else
    raise exception 'This booking can''t be paid for any more';
  end if;
end $$;

-- 1. Start a payment for a booking (called by the server with the signed-in customer's id)
create or replace function public.pay_begin(p_booking uuid, p_customer uuid)
returns jsonb language plpgsql security definer set search_path = public
as $$
declare b public.bookings; u record; pr record; open_orders jsonb; st record;
begin
  select * into b from public.bookings where id = p_booking for update;
  if not found or b.customer_id is distinct from p_customer then raise exception 'Booking not found'; end if;
  if coalesce(b.price,0) < 1 then raise exception 'Invalid booking amount'; end if;
  select * into st from public._pay_stage(b);
  select email into u from auth.users where id = p_customer;
  select name, phone into pr from public.profiles where id = p_customer;
  select coalesce(jsonb_agg(jsonb_build_object('order_id', order_id, 'gateway_order_id', gateway_order_id,
                                               'environment', environment, 'status', status, 'amount', amount)
                            order by created_at desc), '[]') into open_orders
    from public.payments where booking_id = p_booking and stage = st.stage and amount = st.amount
     and status in ('created','active','failed','user_dropped','cancelled');
  return jsonb_build_object(
    'booking_id', b.id, 'stage', st.stage, 'amount', st.amount, 'total', b.price, 'currency', 'INR',
    'commission_amount', st.commission, 'photographer_amount', st.photographer,
    'photographer_id', b.photographer_id, 'category', b.category, 'start_at', b.start_at,
    'photographer_name', b.photographer_name,
    'customer_email', u.email, 'customer_name', pr.name, 'customer_phone', pr.phone,
    'open_orders', open_orders);
end $$;

-- 2. Record a new order before calling Razorpay
create or replace function public.pay_create(p_booking uuid, p_customer uuid, p_order_id text, p_env text)
returns uuid language plpgsql security definer set search_path = public
as $$
declare b public.bookings; st record; pid uuid;
begin
  if p_order_id !~ '^[A-Za-z0-9_-]{3,40}$' then raise exception 'Bad order id'; end if;
  select * into b from public.bookings where id = p_booking for update;
  if not found or b.customer_id is distinct from p_customer then raise exception 'Booking not found'; end if;
  select * into st from public._pay_stage(b);
  -- two taps / two tabs at the same moment: only one open order per part
  if exists (select 1 from public.payments where booking_id = b.id and stage = st.stage and amount = st.amount
                and status in ('created','active')) then
    raise exception 'A payment for this booking is already open. Please wait a moment and try again.';
  end if;
  insert into public.payments (order_id, booking_id, customer_id, photographer_id, amount, currency,
                               commission_amount, photographer_amount, provider, environment, stage)
  values (p_order_id, b.id, b.customer_id, b.photographer_id, st.amount, 'INR',
          st.commission, st.photographer, 'razorpay', p_env, st.stage)
  returning id into pid;
  return pid;
end $$;

-- 3. Save the Razorpay order id
create or replace function public.pay_set_gateway(p_order_id text, p_gateway_order_id text)
returns void language plpgsql security definer set search_path = public
as $$
begin
  update public.payments
     set gateway_order_id = p_gateway_order_id,
         status = case when status = 'created' then 'active' else status end, updated_at = now()
   where order_id = p_order_id;
end $$;

-- 4. Apply a verified payment result. Safe to call any number of times.
--    p_order_id may be our reference or Razorpay's order_… id.
--    p_status: SUCCESS / CAPTURED / PAID (success); FAILED; USER_DROPPED;
--    CANCELLED; EXPIRED; TERMINATED; anything else (AUTHORIZED, CREATED …) = not final.
create or replace function public.pay_record(p_order_id text, p_event_key text, p_status text,
    p_payment_ref text default null, p_amount numeric default null, p_group text default null,
    p_bank_ref text default null, p_message text default null, p_event_type text default null)
returns jsonb language plpgsql security definer set search_path = public
as $$
declare pay record; b record; st text; n int;
begin
  if p_event_key is not null then
    insert into public.payment_events (event_key, order_id, event_type, payment_status, payment_ref)
    values (p_event_key, p_order_id, p_event_type, p_status, p_payment_ref)
    on conflict (event_key) do nothing;
    get diagnostics n = row_count;
    if n = 0 then return jsonb_build_object('result','duplicate_event'); end if;
  end if;

  select * into pay from public.payments where order_id = p_order_id or gateway_order_id = p_order_id
   order by (order_id = p_order_id) desc limit 1 for update;
  if not found then return jsonb_build_object('result','unknown_order'); end if;

  st := case upper(coalesce(p_status,''))
          when 'SUCCESS' then 'paid' when 'CAPTURED' then 'paid' when 'PAID' then 'paid'
          when 'FAILED' then 'failed' when 'USER_DROPPED' then 'user_dropped'
          when 'CANCELLED' then 'cancelled' when 'VOID' then 'cancelled'
          when 'EXPIRED' then 'expired' when 'TERMINATED' then 'terminated'
          else null end;

  if pay.status = 'paid' then
    return jsonb_build_object('result','already_paid','booking_id',pay.booking_id,'status','paid','order_id',pay.order_id);
  end if;
  if st is null then
    return jsonb_build_object('result','pending','booking_id',pay.booking_id,'status',pay.status,'order_id',pay.order_id);
  end if;

  if st <> 'paid' then
    update public.payments
       set status = st, gateway_payment_id = coalesce(p_payment_ref, gateway_payment_id),
           payment_group = coalesce(p_group, payment_group), payment_message = left(p_message, 300), updated_at = now()
     where id = pay.id;
    return jsonb_build_object('result','recorded','booking_id',pay.booking_id,'status',st,'order_id',pay.order_id);
  end if;

  -- success
  update public.payments
     set status = 'paid', gateway_payment_id = p_payment_ref, payment_group = p_group,
         bank_reference = left(p_bank_ref, 100), payment_message = left(p_message, 300),
         paid_at = now(), updated_at = now()
   where id = pay.id;

  if p_amount is not null and round(p_amount, 2) <> round(pay.amount, 2) then
    update public.payments set refund_status = 'refund_due', note = 'Amount paid did not match the booking' where id = pay.id;
    return jsonb_build_object('result','amount_mismatch','booking_id',pay.booking_id,'status','paid','order_id',pay.order_id);
  end if;

  select * into b from public.bookings where id = pay.booking_id for update;
  if not found then
    update public.payments set refund_status = 'refund_due', note = 'Booking no longer exists' where id = pay.id;
    return jsonb_build_object('result','orphan','status','paid','order_id',pay.order_id);
  end if;

  perform set_config('snappro.system', 'on', true);
  if pay.stage = 'balance' then
    if b.balance_status = 'paid' then
      update public.payments set is_duplicate = true, refund_status = 'refund_due',
             note = 'Duplicate payment: the balance was already paid' where id = pay.id;
      perform set_config('snappro.system', '', true);
      return jsonb_build_object('result','duplicate_payment','booking_id',b.id,'status','paid','order_id',pay.order_id);
    elsif b.status = 'cancelled' then
      update public.payments set refund_status = 'refund_due', note = 'Balance paid after the booking was cancelled' where id = pay.id;
      perform set_config('snappro.system', '', true);
      return jsonb_build_object('result','paid_after_cancel','booking_id',b.id,'status','paid','order_id',pay.order_id);
    end if;
    update public.bookings
       set balance_status = 'paid', balance_paid_at = now(), updated_at = now(),
           payout_status = case when status = 'completed' and payment_status = 'paid' and payout_status = 'not_due'
                                then 'due' else payout_status end
     where id = b.id;
    perform set_config('snappro.system', '', true);
    return jsonb_build_object('result','balance_paid','booking_id',b.id,'status','paid','order_id',pay.order_id);
  end if;
  if b.payment_status in ('paid','refund_due','refund_pending','refunded','partially_refunded') then
    update public.payments set is_duplicate = true, refund_status = 'refund_due',
           note = 'Duplicate payment: the booking was already paid' where id = pay.id;
    perform set_config('snappro.system', '', true);
    return jsonb_build_object('result','duplicate_payment','booking_id',b.id,'status','paid','order_id',pay.order_id);
  elsif b.status = 'cancelled' then
    update public.bookings set payment_status = 'refund_due', paid_at = now() where id = b.id;
    update public.payments set refund_status = 'refund_due', note = 'Paid after the booking was cancelled' where id = pay.id;
    perform set_config('snappro.system', '', true);
    return jsonb_build_object('result','paid_after_cancel','booking_id',b.id,'status','paid','order_id',pay.order_id);
  else
    update public.bookings set status = 'confirmed', payment_status = 'paid', paid_at = now(), updated_at = now(),
           -- an order opened for the full amount (before the advance existed) covers the balance too
           balance_status = case when pay.amount >= b.price then 'not_required' else balance_status end
     where id = b.id;
    perform set_config('snappro.system', '', true);
    return jsonb_build_object('result','confirmed','booking_id',b.id,'status','paid','order_id',pay.order_id);
  end if;
end $$;

-- 5. Refunds (started by an admin through the server)
create or replace function public.pay_refund_begin(p_payment uuid, p_amount numeric, p_reason text, p_staff uuid)
returns jsonb language plpgsql security definer set search_path = public
as $$
declare pay record; held numeric; rid text;
begin
  if not exists (select 1 from public.staff where id = p_staff and status = 'active' and role in ('super_admin','admin')) then
    raise exception 'Only admins can refund';
  end if;
  select * into pay from public.payments where id = p_payment for update;
  if not found then raise exception 'Payment not found'; end if;
  if pay.status <> 'paid' or pay.gateway_payment_id is null then raise exception 'Only successful payments can be refunded'; end if;
  select coalesce(sum(amount),0) into held from public.refunds
   where payment_id = pay.id and status in ('requested','pending','pending_approval','onhold','success');
  if p_amount is null or p_amount <= 0 then raise exception 'Enter a refund amount'; end if;
  if round(p_amount,2) > round(pay.amount - held, 2) then
    raise exception 'That is more than can be refunded (₹% left)', pay.amount - held;
  end if;
  rid := 'RF_' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 24);
  insert into public.refunds (refund_id, payment_id, order_id, amount, reason, requested_by)
  values (rid, pay.id, pay.order_id, round(p_amount,2), left(coalesce(p_reason,''),100), p_staff);
  update public.payments set refund_status = 'refund_pending', updated_at = now() where id = pay.id;
  perform set_config('snappro.system', 'on', true);
  update public.bookings set payment_status = 'refund_pending'
   where id = pay.booking_id and not pay.is_duplicate and pay.stage = 'advance';
  perform set_config('snappro.system', '', true);
  return jsonb_build_object('refund_id', rid, 'order_id', pay.order_id, 'amount', round(p_amount,2),
                            'gateway_payment_id', pay.gateway_payment_id);
end $$;

-- p_refund_id may be our refund reference (receipt) or Razorpay's rfnd_… id
create or replace function public.pay_refund_update(p_refund_id text, p_status text, p_gateway_refund_id text default null,
                                                    p_arn text default null, p_event_key text default null)
returns jsonb language plpgsql security definer set search_path = public
as $$
declare r record; pay record; st text; n int; total numeric;
begin
  if p_event_key is not null then
    insert into public.payment_events (event_key, order_id, event_type, payment_status)
    values (p_event_key, null, 'REFUND', p_status) on conflict (event_key) do nothing;
    get diagnostics n = row_count;
    if n = 0 then return jsonb_build_object('result','duplicate_event'); end if;
  end if;
  select * into r from public.refunds
   where refund_id = p_refund_id
      or (gateway_refund_id is not null and (gateway_refund_id = p_refund_id or gateway_refund_id = p_gateway_refund_id))
   limit 1 for update;
  if not found then return jsonb_build_object('result','unknown_refund'); end if;
  st := case upper(coalesce(p_status,''))
          when 'SUCCESS' then 'success' when 'PROCESSED' then 'success'
          when 'PENDING' then 'pending' when 'CREATED' then 'pending' when 'PENDING_APPROVAL' then 'pending_approval'
          when 'ONHOLD' then 'onhold' when 'CANCELLED' then 'cancelled' when 'REJECTED' then 'rejected'
          when 'FAILED' then 'failed' else null end;
  if st is null or r.status in ('success','cancelled','rejected','failed') then
    if p_gateway_refund_id is not null and r.gateway_refund_id is null then
      update public.refunds set gateway_refund_id = p_gateway_refund_id where id = r.id;
    end if;
    return jsonb_build_object('result','unchanged','status',r.status);
  end if;
  update public.refunds set status = st, gateway_refund_id = coalesce(p_gateway_refund_id, gateway_refund_id),
         refund_arn = coalesce(p_arn, refund_arn), updated_at = now(),
         processed_at = case when st = 'success' then now() else processed_at end
   where id = r.id;
  select * into pay from public.payments where id = r.payment_id for update;
  select coalesce(sum(amount),0) into total from public.refunds where payment_id = pay.id and status = 'success';
  perform set_config('snappro.system', 'on', true);
  if st = 'success' then
    update public.payments set refunded_amount = total,
           refund_status = case when total >= amount then 'refunded' else 'partially_refunded' end, updated_at = now()
     where id = pay.id;
    update public.bookings set payment_status = case when total >= pay.amount then 'refunded' else 'partially_refunded' end
     where id = pay.booking_id and not pay.is_duplicate and pay.stage = 'advance';
  elsif st in ('cancelled','rejected','failed') then
    update public.payments set refund_status = case when total > 0 then 'partially_refunded' else 'refund_failed' end, updated_at = now()
     where id = pay.id;
    update public.bookings set payment_status = 'refund_due'
     where id = pay.booking_id and payment_status = 'refund_pending' and pay.stage = 'advance';
  end if;
  perform set_config('snappro.system', '', true);
  return jsonb_build_object('result','recorded','status',st);
end $$;

-- Server helpers: who owns an order, and is a user an admin
create or replace function public.pay_lookup(p_order_id text)
returns jsonb language sql stable security definer set search_path = public
as $$ select to_jsonb(x) from (select p.order_id, p.gateway_order_id, p.gateway_payment_id, p.customer_id, p.booking_id,
                                     p.status, p.amount, p.environment, p.refund_status, p.stage,
                                     b.status as booking_status, b.balance_status
                                from public.payments p left join public.bookings b on b.id = p.booking_id
                               where p.order_id = p_order_id or p.gateway_order_id = p_order_id
                               order by (p.order_id = p_order_id) desc limit 1) x $$;
create or replace function public.pay_staff_role(p_user uuid)
returns text language sql stable security definer set search_path = public
as $$ select role from public.staff where id = p_user and status = 'active' $$;

-- 6. Staff: record that a photographer has been paid for a completed shoot
create or replace function public.admin_mark_payout(p_booking uuid, p_ref text)
returns text language plpgsql security definer set search_path = public
as $$
declare b record;
begin
  if coalesce(public.staff_role() in ('super_admin','admin'), false) is not true then raise exception 'Only admins can record payouts'; end if;
  select * into b from public.bookings where id = p_booking for update;
  if not found then raise exception 'Booking not found'; end if;
  if b.payout_status <> 'due' then raise exception 'No payout is due for this booking'; end if;
  if coalesce(trim(p_ref),'') = '' then raise exception 'Add the UPI / bank transfer reference'; end if;
  perform set_config('snappro.system', 'on', true);
  update public.bookings set payout_status = 'paid', payout_ref = left(trim(p_ref),100), payout_at = now(), payout_by = auth.uid()
   where id = b.id;
  perform set_config('snappro.system', '', true);
  return 'paid';
end $$;

-- 7. Super admins can change the commission (applies to new bookings only)
create or replace function public.admin_set_commission(p_pct numeric)
returns numeric language plpgsql security definer set search_path = public
as $$
begin
  if not public.is_super() then raise exception 'Only a super admin can change the commission'; end if;
  if p_pct is null or p_pct < 0 or p_pct > 50 then raise exception 'Commission must be between 0 and 50%%'; end if;
  insert into public.platform_settings (key, value, updated_at) values ('commission_pct', to_jsonb(round(p_pct,2)), now())
  on conflict (key) do update set value = excluded.value, updated_at = now();
  return round(p_pct,2);
end $$;

-- The server functions use the service key; nobody else may call pay_*.
revoke all on function public._pay_stage(public.bookings)            from public, anon, authenticated;
revoke all on function public.pay_begin(uuid, uuid)                    from public, anon, authenticated;
revoke all on function public.pay_create(uuid, uuid, text, text)       from public, anon, authenticated;
revoke all on function public.pay_set_gateway(text, text)              from public, anon, authenticated;
revoke all on function public.pay_record(text, text, text, text, numeric, text, text, text, text) from public, anon, authenticated;
revoke all on function public.pay_refund_begin(uuid, numeric, text, uuid) from public, anon, authenticated;
revoke all on function public.pay_refund_update(text, text, text, text, text) from public, anon, authenticated;
revoke all on function public.pay_lookup(text)                          from public, anon, authenticated;
revoke all on function public.pay_staff_role(uuid)                      from public, anon, authenticated;
grant execute on function public.pay_begin(uuid, uuid)                    to service_role;
grant execute on function public.pay_create(uuid, uuid, text, text)       to service_role;
grant execute on function public.pay_set_gateway(text, text)              to service_role;
grant execute on function public.pay_record(text, text, text, text, numeric, text, text, text, text) to service_role;
grant execute on function public.pay_refund_begin(uuid, numeric, text, uuid) to service_role;
grant execute on function public.pay_refund_update(text, text, text, text, text) to service_role;
grant execute on function public.pay_lookup(text)                          to service_role;
grant execute on function public.pay_staff_role(uuid)                      to service_role;
revoke all on function public.admin_mark_payout(uuid, text)   from public, anon;
revoke all on function public.admin_set_commission(numeric)   from public, anon;
grant execute on function public.admin_mark_payout(uuid, text) to authenticated;
grant execute on function public.admin_set_commission(numeric) to authenticated;
-- nobody writes payment tables directly from the browser
revoke insert, update, delete on public.payments, public.payment_events, public.refunds, public.platform_settings from anon, authenticated;

-- A photographer's own quotes, with what happened to each one:
-- open / chosen (customer picked it, advance not paid yet) / booked / closed.
create or replace function public.my_offers()
returns table(id uuid, request_id uuid, price integer, eta_min integer, note text, created_at timestamptz, state text)
language sql stable security definer set search_path = public
as $$
  select o.id, o.request_id, o.price, o.eta_min, o.note, o.created_at,
         case
           when exists (select 1 from public.bookings b where b.offer_id = o.id and b.status = 'pending_payment') then 'chosen'
           when exists (select 1 from public.bookings b where b.offer_id = o.id and b.status <> 'cancelled') then 'booked'
           when r.status in ('broadcasting','awaiting') then 'open'
           else 'closed'
         end
    from public.offers o left join public.requests r on r.id = o.request_id
   where o.photographer_id = auth.uid()
   order by o.created_at desc
   limit 60
$$;
revoke all on function public.my_offers() from public, anon;
grant execute on function public.my_offers() to authenticated;

-- =====================================================================
-- 8. FUNCTION PERMISSIONS
--    Supabase lets browsers call any public function by default. The
--    email sender is locked away; the rest check the caller themselves.
-- =====================================================================

revoke all on function public._send_invite_email(text, text) from public, anon, authenticated;
revoke all on function public._send_email(text, text, text)   from public, anon, authenticated;
revoke all on function public.set_photographer_approval(uuid, text, text) from public, anon;
revoke all on function public.request_photographer_review()   from public, anon;
grant execute on function public.set_photographer_approval(uuid, text, text) to authenticated;
grant execute on function public.request_photographer_review()   to authenticated;
revoke all on function public.claim_staff_invite()          from public, anon;
revoke all on function public.resend_staff_invite(uuid)     from public, anon;
revoke all on function public.invite_email_ready()         from public, anon;
revoke all on function public.invite_email_status()        from public, anon;
grant execute on function public.claim_staff_invite()      to authenticated;
grant execute on function public.resend_staff_invite(uuid) to authenticated;
grant execute on function public.invite_email_ready()      to authenticated;
grant execute on function public.invite_email_status()     to authenticated;

-- =====================================================================
-- 8b. ADMIN INSIGHTS — visitors, charts, KPIs, user list
--     Visitors are counted with a random ID the site keeps in the
--     browser: no names, emails or IP addresses are stored. Only staff
--     can read any of this.
-- =====================================================================

create table if not exists public.site_visits (
  visitor_id uuid        not null,
  day        date        not null,
  first_at   timestamptz not null default now(),
  last_at    timestamptz not null default now(),
  views      integer     not null default 1,
  user_id    uuid,
  path       text,
  referrer   text,
  device     text,
  primary key (visitor_id, day)
);
create index if not exists idx_site_visits_day on public.site_visits(day);
alter table public.site_visits enable row level security;
drop policy if exists site_visits_staff_read on public.site_visits;
create policy site_visits_staff_read on public.site_visits for select to authenticated using (public.is_staff());

-- Called by the website once per page load. The day is always "today" in
-- India time, whatever the browser says.
create or replace function public.track_visit(p_visitor uuid, p_path text default null,
                                              p_referrer text default null, p_device text default null)
returns void language plpgsql security definer set search_path = public
as $$
declare d date := (now() at time zone 'Asia/Kolkata')::date;
begin
  if p_visitor is null then return; end if;
  insert into public.site_visits (visitor_id, day, user_id, path, referrer, device)
  values (p_visitor, d, auth.uid(), left(p_path, 200), left(p_referrer, 200),
          case when p_device in ('mobile','tablet','desktop') then p_device end)
  on conflict (visitor_id, day) do update
     set views   = least(public.site_visits.views + 1, 10000),
         last_at = now(),
         user_id = coalesce(public.site_visits.user_id, excluded.user_id);
end $$;

create or replace function public._ist(ts timestamptz)
returns date language sql immutable as $$ select (ts at time zone 'Asia/Kolkata')::date $$;

-- One row per day / week / month / year between two dates, zero-filled.
-- Booking values are hidden (null) from managers.
create or replace function public.admin_series(p_from date, p_to date, p_bucket text)
returns table(bucket date, visitors int, signups int, customers int, photographers int,
              requests int, bookings int, completed int, cancelled int,
              booked_value bigint, completed_value bigint)
language plpgsql stable security definer set search_path = public
as $$
declare money boolean := coalesce(public.staff_role() in ('super_admin','admin'), false); t date;
begin
  if not public.is_staff() then return; end if;
  if p_bucket not in ('day','week','month','year') then raise exception 'Unknown period'; end if;
  if p_from is null or p_to is null then raise exception 'Choose a start and end date'; end if;
  if p_to < p_from then t := p_from; p_from := p_to; p_to := t; end if;
  if p_to - p_from > 3700 then raise exception 'Choose a range of 10 years or less'; end if;
  return query
  with b as (
    select g::date as bk
      from generate_series(date_trunc(p_bucket, p_from::timestamp), date_trunc(p_bucket, p_to::timestamp),
                           ('1 ' || p_bucket)::interval) g),
  v as (select date_trunc(p_bucket, s.day::timestamp)::date bk, count(distinct s.visitor_id) n
          from public.site_visits s where s.day between p_from and p_to group by 1),
  u as (select date_trunc(p_bucket, public._ist(p.created_at)::timestamp)::date bk, count(*) n,
               count(*) filter (where p.role = 'customer') c, count(*) filter (where p.role = 'photographer') ph
          from public.profiles p
         where public._ist(p.created_at) between p_from and p_to
           and not exists (select 1 from public.staff st where st.id = p.id)
         group by 1),
  r as (select date_trunc(p_bucket, public._ist(q.created_at)::timestamp)::date bk, count(*) n
          from public.requests q where public._ist(q.created_at) between p_from and p_to group by 1),
  k as (select date_trunc(p_bucket, public._ist(x.created_at)::timestamp)::date bk,
               count(*) filter (where x.status <> 'cancelled') n,
               count(*) filter (where x.status = 'completed') done,
               count(*) filter (where x.status = 'cancelled') canc,
               coalesce(sum(x.price) filter (where x.status <> 'cancelled'), 0) bv,
               coalesce(sum(x.price) filter (where x.status = 'completed'), 0) cv
          from public.bookings x where public._ist(x.created_at) between p_from and p_to group by 1)
  select b.bk, coalesce(v.n,0)::int, coalesce(u.n,0)::int, coalesce(u.c,0)::int, coalesce(u.ph,0)::int,
         coalesce(r.n,0)::int, coalesce(k.n,0)::int, coalesce(k.done,0)::int, coalesce(k.canc,0)::int,
         case when money then coalesce(k.bv,0)::bigint end, case when money then coalesce(k.cv,0)::bigint end
    from b left join v on v.bk = b.bk left join u on u.bk = b.bk
           left join r on r.bk = b.bk left join k on k.bk = b.bk
   order by b.bk;
end $$;

-- Headline numbers for a date range, plus a few "right now" figures.
create or replace function public.admin_kpis(p_from date, p_to date)
returns jsonb language plpgsql stable security definer set search_path = public
as $$
declare money boolean := coalesce(public.staff_role() in ('super_admin','admin'), false);
        res jsonb; today date := public._ist(now());
begin
  if not public.is_staff() then return null; end if;
  with
  vis as (select * from public.site_visits where day between p_from and p_to),
  prof as (select p.* from public.profiles p where not exists (select 1 from public.staff st where st.id = p.id)),
  req as (select * from public.requests where public._ist(created_at) between p_from and p_to),
  firstq as (select r.id, (select min(o.created_at) from public.offers o where o.request_id = r.id) fq,
                    (select count(*) from public.offers o where o.request_id = r.id) nq, r.created_at
               from req r),
  bk as (select * from public.bookings where public._ist(created_at) between p_from and p_to)
  select jsonb_build_object(
    'visitors',            (select count(distinct visitor_id) from vis),
    'returning_visitors',  (select count(*) from (select visitor_id from vis group by 1 having count(*) > 1) z),
    'page_views',          (select coalesce(sum(views),0) from vis),
    'mobile_share',        (select round(100.0 * count(*) filter (where device = 'mobile') / nullif(count(*),0)) from vis),
    'signups',             (select count(*) from prof where public._ist(created_at) between p_from and p_to),
    'signups_customers',   (select count(*) from prof where role = 'customer' and public._ist(created_at) between p_from and p_to),
    'signups_photographers',(select count(*) from prof where role = 'photographer' and public._ist(created_at) between p_from and p_to),
    'total_customers',     (select count(*) from prof where role = 'customer'),
    'total_photographers', (select count(*) from prof where role = 'photographer'),
    'setup_incomplete',    (select count(*) from prof where city is null or pincode is null),
    'requests',            (select count(*) from req),
    'requests_quoted',     (select count(*) from firstq where fq is not null),
    'requests_booked',     (select count(*) from req where status = 'matched'),
    'avg_quotes',          (select round(avg(nq)::numeric, 1) from firstq),
    'median_first_quote_min', (select round(percentile_cont(0.5) within group (order by extract(epoch from fq - created_at) / 60)::numeric)
                                 from firstq where fq is not null),
    'bookings',            (select count(*) from bk where status <> 'cancelled'),
    'completed',           (select count(*) from bk where status = 'completed'),
    'cancelled',           (select count(*) from bk where status = 'cancelled'),
    'booked_value',        case when money then (select coalesce(sum(price),0) from bk where status <> 'cancelled') end,
    'completed_value',     case when money then (select coalesce(sum(price),0) from bk where status = 'completed') end,
    'avg_booking_value',   case when money then (select round(avg(price)) from bk where status <> 'cancelled') end,
    'repeat_customers',    (select count(*) from (select customer_id from public.bookings where status <> 'cancelled'
                                                   group by 1 having count(*) > 1) z),
    'reviews',             (select count(*) from public.reviews where public._ist(created_at) between p_from and p_to),
    'avg_rating',          (select round(avg(stars)::numeric, 1) from public.reviews where public._ist(created_at) between p_from and p_to),
    'messages',            (select count(*) from public.messages where public._ist(created_at) between p_from and p_to),
    'now_visitors_today',  (select count(*) from public.site_visits where day = today),
    'now_photographers_available', (select count(*) from public.photographers where is_online and approval_status = 'approved'),
    'photographers_pending', (select count(*) from public.photographers where approval_status = 'pending'),
    'collected',         case when money then (select coalesce(sum(amount),0) from public.payments
                              where status = 'paid' and public._ist(paid_at) between p_from and p_to) end,
    'commission_earned', case when money then (select coalesce(sum(commission_amount),0) from public.payments
                              where status = 'paid' and not is_duplicate and refund_status in ('none')
                                and public._ist(paid_at) between p_from and p_to) end,
    'refunds_due',       (select count(*) from public.payments where refund_status in ('refund_due','refund_failed')),
    'balances_due',      (select count(*) from public.bookings where balance_status = 'due'),
    'payouts_due',       case when money then (select coalesce(sum(photographer_amount),0) from public.bookings where payout_status = 'due') end,
    'payments_failed',   (select count(*) from public.payments where status in ('failed','user_dropped') and public._ist(created_at) between p_from and p_to),
    'now_open_requests',   (select count(*) from public.requests where status = 'broadcasting' and expires_at > now()),
    'now_upcoming_shoots', (select count(*) from public.bookings where status in ('confirmed','enroute','arrived','shooting')),
    'photographers_with_photos', (select count(*) from public.photographers where coalesce(array_length(portfolio,1),0) > 0),
    'photographers_verified',    (select count(*) from public.photographers where is_verified),
    'top_cities',     (select coalesce(jsonb_agg(z order by z.n desc), '[]') from
                        (select coalesce(city,'—') city, count(*) n from req group by 1 order by 2 desc limit 6) z),
    'top_categories', (select coalesce(jsonb_agg(z order by z.n desc), '[]') from
                        (select category, count(*) n from req group by 1 order by 2 desc limit 6) z),
    'top_referrers',  (select coalesce(jsonb_agg(z order by z.n desc), '[]') from
                        (select coalesce(nullif(referrer,''),'Direct') referrer, count(distinct visitor_id) n from vis group by 1 order by 2 desc limit 6) z)
  ) into res;
  return res;
end $$;

-- Everyone who has an account. Admins and super admins only.
drop function if exists public.admin_users();
create or replace function public.admin_users()
returns table(id uuid, name text, email text, phone text, role text, city text, state text, pincode text,
              joined timestamptz, last_sign_in timestamptz, confirmed boolean, is_staff boolean,
              requests int, bookings int, jobs_done int, rating numeric, review_count int,
              is_verified boolean, is_online boolean, photos int, approval_status text)
language plpgsql stable security definer set search_path = public
as $$
begin
  if coalesce(public.staff_role() in ('super_admin','admin'), false) is not true then return; end if;
  return query
  select u.id, p.name, coalesce(u.email, p.email)::text, coalesce(p.phone, u.phone)::text,
         coalesce(p.role, 'customer'), p.city, p.state, p.pincode,
         coalesce(p.created_at, u.created_at), u.last_sign_in_at, (u.email_confirmed_at is not null),
         exists (select 1 from public.staff st where st.id = u.id),
         (select count(*)::int from public.requests q where q.customer_id = u.id),
         (select count(*)::int from public.bookings b where (b.customer_id = u.id or b.photographer_id = u.id) and b.status <> 'cancelled'),
         g.jobs_done, g.rating, g.review_count, g.is_verified, g.is_online,
         coalesce(array_length(g.portfolio,1), 0), g.approval_status
    from auth.users u
    left join public.profiles p on p.id = u.id
    left join public.photographers g on g.id = u.id
   order by coalesce(p.created_at, u.created_at) desc
   limit 5000;
end $$;

revoke all on function public.track_visit(uuid, text, text, text) from public;
revoke all on function public.admin_series(date, date, text)      from public, anon;
revoke all on function public.admin_kpis(date, date)              from public, anon;
revoke all on function public.admin_users()                       from public, anon;
grant execute on function public.track_visit(uuid, text, text, text) to anon, authenticated;
grant execute on function public.admin_series(date, date, text)      to authenticated;
grant execute on function public.admin_kpis(date, date)              to authenticated;
grant execute on function public.admin_users()                       to authenticated;

-- =====================================================================
-- 9. ONE-OFF CLEAN-UP
-- =====================================================================

do $$
begin
  perform set_config('snappro.system', 'on', true);
  -- ratings may only come from real reviews; clear any placeholder value
  update public.photographers p
     set rating = null, review_count = 0
   where not exists (select 1 from public.reviews r where r.photographer_id = p.id);
  perform set_config('snappro.system', '', true);
end $$;

-- owner: always an active super admin (see OWNER LOCK above)
insert into public.staff_invites (email, role)
select 'prathmeshsingh99@gmail.com', 'super_admin'
 where not exists (select 1 from public.staff where lower(email) = 'prathmeshsingh99@gmail.com')
on conflict (email) do update set role = 'super_admin' where public.staff_invites.role <> 'super_admin';
insert into public.staff (id, email, name, role)
select u.id, lower(u.email), split_part(u.email,'@',1), 'super_admin'
  from auth.users u where lower(u.email) = 'prathmeshsingh99@gmail.com'
on conflict (id) do update set role = 'super_admin', status = 'active';
update public.staff_invites set accepted_at = coalesce(accepted_at, now())
 where lower(email) = 'prathmeshsingh99@gmail.com'
   and exists (select 1 from public.staff where lower(email) = 'prathmeshsingh99@gmail.com');

-- founding super admin (only inserted if it isn't there yet)
insert into public.staff_invites (email, role)
select 'create.saifeestudio@gmail.com', 'super_admin'
 where not exists (select 1 from public.staff where lower(email) = 'create.saifeestudio@gmail.com')
on conflict (email) do nothing;
insert into public.staff (id, email, name, role)
select u.id, lower(u.email), split_part(u.email,'@',1), 'super_admin'
  from auth.users u where lower(u.email) = 'create.saifeestudio@gmail.com'
on conflict (id) do update set role = 'super_admin', status = 'active';
update public.staff_invites set accepted_at = coalesce(accepted_at, now())
 where lower(email) = 'create.saifeestudio@gmail.com'
   and exists (select 1 from public.staff where lower(email) = 'create.saifeestudio@gmail.com');

-- =====================================================================
-- 10. CHECK — every value in the result should read true
-- =====================================================================

select
  (select count(*) = 0 from pg_policies
     where schemaname = 'public' and cmd = 'ALL' and coalesce(qual,'true') = 'true')         as no_open_policies,
  (select bool_and(rowsecurity) from pg_tables
     where schemaname = 'public'
       and tablename in ('profiles','photographers','requests','offers','bookings',
                         'messages','reviews','staff','staff_invites','site_visits',
                         'payments','payment_events','refunds','platform_settings','photographer_payout'))                      as rls_everywhere,
  exists (select 1 from pg_trigger where tgname = 'on_auth_user_created')                  as signup_trigger,
  exists (select 1 from pg_trigger where tgname = 'booking_before_update')                 as booking_guard,
  exists (select 1 from pg_trigger where tgname = 'photographer_guard')                    as rating_guard,
  exists (select 1 from storage.buckets where id = 'portfolio')                            as photo_storage,
  exists (select 1 from pg_extension where extname = 'pg_net')                             as email_sender,
  exists (select 1 from vault.decrypted_secrets where name = 'brevo_api_key')              as brevo_key_saved,
  exists (select 1 from pg_proc where proname = 'pay_record')
    and exists (select 1 from public.platform_settings where key = 'commission_pct')       as payments_ready,
  exists (select 1 from public.staff where lower(email) = 'create.saifeestudio@gmail.com'
            and role = 'super_admin' and status = 'active')                                as you_are_super_admin,
  exists (select 1 from pg_trigger where tgname = 'staff_owner_lock')
    and (exists (select 1 from public.staff where lower(email) = 'prathmeshsingh99@gmail.com'
                   and role = 'super_admin' and status = 'active')
         or exists (select 1 from public.staff_invites where lower(email) = 'prathmeshsingh99@gmail.com'
                   and role = 'super_admin' and accepted_at is null))                     as owner_locked;
