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
    new.commission_pct := null; new.featured_until := null;
  else
    new.commission_pct := old.commission_pct; new.featured_until := old.featured_until;
    new.rating := old.rating; new.review_count := old.review_count;
    new.jobs_done := old.jobs_done; new.earnings := old.earnings;
    if not can_verify then new.is_verified := old.is_verified; end if;
    new.approval_status := old.approval_status; new.approved_at := old.approved_at;
    new.approved_by := old.approved_by; new.review_note := old.review_note; new.submitted_at := old.submitted_at;
  end if;
  new.display_name := left(coalesce(nullif(trim(new.display_name),''), 'Photographer'), 60);
  new.bio := left(coalesce(new.bio,''), 600);
  new.portfolio := coalesce(new.portfolio[1:500], '{}');
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
  -- this photographer's commission (their own rate, or a reward that lowers it)
  select c.pct, c.benefit_id into new.commission_pct, new.commission_benefit_id from public.commission_for(o.photographer_id) c;
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
  -- a customer reward (offer / referral) comes off the advance; SnapPro pays for it out of its commission
  new.discount_amount := 0; new.discount_benefit_id := null;
  select least(d.amount, new.advance_amount - 1, new.commission_amount), d.benefit_id
    into new.discount_amount, new.discount_benefit_id from public.discount_for(r.customer_id, o.price, new.commission_amount) d;
  new.discount_amount := greatest(coalesce(new.discount_amount, 0), 0);
  if new.discount_amount > 0 then
    new.advance_amount    := new.advance_amount - new.discount_amount;
    new.commission_amount := new.commission_amount - new.discount_amount;
    new.total_amount      := o.price - new.discount_amount;
  else new.discount_benefit_id := null; end if;
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
  if new.commission_benefit_id is not null then perform public._use_benefit(new.commission_benefit_id, 1); end if;
  if new.discount_benefit_id is not null then perform public._use_benefit(new.discount_benefit_id, 1); end if;
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
    -- referral rewards that wait for the first completed shoot
    perform public.referral_check(new.customer_id);
    perform public.referral_check(new.photographer_id);
  end if;
  if new.status = 'cancelled' and old.status is distinct from 'cancelled' then
    -- let the customer pick another quote
    update public.requests set status = 'awaiting' where id = new.request_id and status = 'matched';
    -- rewards used on this booking can be used again
    if new.commission_benefit_id is not null then perform public._use_benefit(new.commission_benefit_id, -1); end if;
    if new.discount_benefit_id is not null then perform public._use_benefit(new.discount_benefit_id, -1); end if;
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
  using (customer_id = auth.uid()
         or (status = 'broadcasting' and expires_at > now()
             and exists (select 1 from public.photographers g where g.id = auth.uid() and g.approval_status = 'approved')));
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
-- 7d. PORTFOLIO MEDIA ON AMAZON S3 + YEARLY STORAGE PLANS
--     Photos and videos go straight from the photographer's phone to the
--     S3 bucket using one-time upload links made by the "media" Edge
--     Function. The database keeps the list, the sizes and the limits.
--     Free: 250 MB. Paid plans (yearly, via Razorpay) add more.
--     When a plan ends, anything over the free limit is hidden, and
--     deleted 30 days later unless they renew.
-- =====================================================================

insert into public.platform_settings (key, value) values ('storage_plans',
  '{"free_mb":250,"plans":[{"id":"plus","name":"Plus","gb":1,"price":499},{"id":"pro","name":"Pro","gb":5,"price":1499}]}')
on conflict (key) do nothing;

create table if not exists public.portfolio_media (
  id              uuid primary key default gen_random_uuid(),
  photographer_id uuid not null references public.photographers(id) on delete cascade,
  s3_key          text not null unique,
  url             text not null,
  kind            text not null check (kind in ('image','video')),
  content_type    text,
  bytes           bigint not null default 0,
  status          text not null default 'pending' check (status in ('pending','ready','hidden','deleted')),
  hidden_at       timestamptz,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);
create index if not exists idx_media_pg on public.portfolio_media(photographer_id, status);

create table if not exists public.photographer_storage (
  id          uuid primary key references public.photographers(id) on delete cascade,
  plan        text not null default 'free',
  quota_bytes bigint,
  expires_at  timestamptz,
  reminded_at timestamptz,
  updated_at  timestamptz not null default now()
);

create table if not exists public.storage_orders (
  id                 uuid primary key default gen_random_uuid(),
  order_id           text not null unique,
  photographer_id    uuid not null references public.photographers(id) on delete cascade,
  plan               text not null,
  plan_name          text,
  quota_bytes        bigint not null,
  amount             numeric(12,2) not null check (amount >= 1),
  status             text not null default 'created' check (status in ('created','active','paid','failed','cancelled','terminated')),
  environment        text not null default 'test',
  gateway_order_id   text unique,
  gateway_payment_id text,
  payment_group      text,
  period_start       timestamptz,
  period_end         timestamptz,
  paid_at            timestamptz,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now()
);
alter table public.storage_orders add column if not exists discount_benefit_id uuid;
create index if not exists idx_storage_orders_pg on public.storage_orders(photographer_id);

alter table public.portfolio_media      enable row level security;
alter table public.photographer_storage enable row level security;
alter table public.storage_orders       enable row level security;
drop policy if exists media_public_read on public.portfolio_media;
create policy media_public_read on public.portfolio_media for select using (status = 'ready' or photographer_id = auth.uid() or public.is_staff());
drop policy if exists storage_own_read on public.photographer_storage;
create policy storage_own_read on public.photographer_storage for select to authenticated using (id = auth.uid() or public.is_staff());
drop policy if exists storage_orders_read on public.storage_orders;
create policy storage_orders_read on public.storage_orders for select to authenticated
  using (photographer_id = auth.uid() or coalesce(public.staff_role() in ('super_admin','admin'), false));
revoke insert, update, delete on public.portfolio_media, public.photographer_storage, public.storage_orders from anon, authenticated;

-- free allowance and the plan a photographer is on right now
create or replace function public.storage_free_bytes()
returns bigint language sql stable security definer set search_path = public
as $$ select (coalesce((select (value->>'free_mb')::numeric from public.platform_settings where key = 'storage_plans'), 250) * 1024 * 1024)::bigint $$;
create or replace function public.storage_quota(p_pg uuid)
returns bigint language plpgsql stable security definer set search_path = public
as $$ begin return (select greatest(public.storage_free_bytes(),
          coalesce((select s.quota_bytes from public.photographer_storage s
                     where s.id = p_pg and s.plan <> 'free' and s.expires_at > now()), 0))
        + coalesce((select sum(b.amount * 1073741824)::bigint from public.user_benefits b
                     where b.user_id = p_pg and b.kind = 'storage_bonus' and b.status = 'active'
                       and (b.expires_at is null or b.expires_at > now())), 0)); end $$;
create or replace function public.storage_used(p_pg uuid)
returns bigint language sql stable security definer set search_path = public
as $$ select coalesce(sum(bytes), 0)::bigint from public.portfolio_media
       where photographer_id = p_pg and (status in ('ready','hidden') or (status = 'pending' and created_at > now() - interval '1 hour')) $$;

-- Which uploads show on the profile: oldest first, as many as fit in the
-- current allowance. Older Supabase-hosted photos (from before S3) stay as they are.
create or replace function public.media_sync(p_pg uuid)
returns void language plpgsql security definer set search_path = public
as $$
declare quota bigint := public.storage_quota(p_pg); legacy text[]; vis text[];
begin
  perform set_config('snappro.system', 'on', true);
  with m as (select id, bytes, sum(bytes) over (order by created_at, id) as run
               from public.portfolio_media where photographer_id = p_pg and status in ('ready','hidden'))
  update public.portfolio_media x
     set status = case when m.run <= quota then 'ready' else 'hidden' end,
         hidden_at = case when m.run <= quota then null else coalesce(x.hidden_at, now()) end,
         updated_at = now()
    from m where x.id = m.id
     and x.status is distinct from (case when m.run <= quota then 'ready' else 'hidden' end);
  select coalesce(array_agg(u), '{}') into legacy from (
    select unnest(portfolio) u from public.photographers where id = p_pg) z
   where not exists (select 1 from public.portfolio_media pm where pm.url = z.u);
  select coalesce(array_agg(url order by created_at, id), '{}') into vis
    from public.portfolio_media where photographer_id = p_pg and status = 'ready';
  update public.photographers set portfolio = legacy || vis where id = p_pg;
  perform set_config('snappro.system', '', true);
end $$;

-- 1. A one-time upload slot (server only). Checks the type, size and space left.
create or replace function public.media_begin(p_user uuid, p_kind text, p_type text, p_ext text, p_bytes bigint, p_base_url text)
returns jsonb language plpgsql security definer set search_path = public
as $$
declare quota bigint; used bigint; k text; maxb bigint;
begin
  if not exists (select 1 from public.photographers where id = p_user) then raise exception 'Only photographers can upload portfolio work'; end if;
  if p_kind not in ('image','video') then raise exception 'Upload photos or videos only'; end if;
  if p_kind = 'image' and (p_type not in ('image/jpeg','image/png','image/webp') or p_ext not in ('jpg','png','webp')) then
    raise exception 'Photos must be JPG, PNG or WebP'; end if;
  if p_kind = 'video' and (p_type not in ('video/mp4','video/quicktime','video/webm') or p_ext not in ('mp4','mov','webm')) then
    raise exception 'Videos must be MP4, MOV or WebM'; end if;
  maxb := case when p_kind = 'image' then 15 * 1024 * 1024 else 100 * 1024 * 1024 end;
  if p_bytes is null or p_bytes < 1 then raise exception 'That file is empty'; end if;
  if p_bytes > maxb then raise exception '% are limited to % MB each', case when p_kind = 'image' then 'Photos' else 'Videos' end, maxb / 1024 / 1024; end if;
  quota := public.storage_quota(p_user); used := public.storage_used(p_user);
  if used + p_bytes > quota then
    raise exception 'STORAGE_FULL: Not enough space — % MB free of % MB. Delete something or upgrade your storage.',
      greatest(0, (quota - used) / 1024 / 1024), quota / 1024 / 1024;
  end if;
  k := 'portfolio/' || p_user || '/' || replace(gen_random_uuid()::text, '-', '') || '.' || p_ext;
  insert into public.portfolio_media (photographer_id, s3_key, url, kind, content_type, bytes)
  values (p_user, k, rtrim(p_base_url, '/') || '/' || k, p_kind, p_type, p_bytes);
  return jsonb_build_object('key', k, 'url', rtrim(p_base_url, '/') || '/' || k, 'quota', quota, 'used', used + p_bytes);
end $$;

-- 2. The upload finished: record its real size (from S3) and show it.
create or replace function public.media_confirm(p_user uuid, p_key text, p_bytes bigint)
returns jsonb language plpgsql security definer set search_path = public
as $$
declare m record; quota bigint; used bigint;
begin
  select * into m from public.portfolio_media where s3_key = p_key and photographer_id = p_user for update;
  if not found then raise exception 'Upload not found'; end if;
  if m.status = 'ready' then return jsonb_build_object('result','ready','url', m.url); end if;
  if m.status <> 'pending' then raise exception 'Upload not found'; end if;
  update public.portfolio_media set bytes = coalesce(p_bytes, 0), updated_at = now() where id = m.id;
  quota := public.storage_quota(p_user);
  select coalesce(sum(bytes),0) into used from public.portfolio_media
   where photographer_id = p_user and (status in ('ready','hidden') or id = m.id);
  if p_bytes is null or p_bytes < 1 or used > quota or p_bytes > (case when m.kind = 'image' then 15 else 100 end) * 1024 * 1024 then
    update public.portfolio_media set status = 'deleted', updated_at = now() where id = m.id;
    return jsonb_build_object('result','rejected','delete_key', m.s3_key);
  end if;
  update public.portfolio_media set status = 'ready', updated_at = now() where id = m.id;
  perform public.media_sync(p_user);
  return jsonb_build_object('result','ready','url', m.url, 'kind', m.kind);
end $$;

-- 3. Remove one item (by link). Returns the S3 key to delete, or null for old Supabase photos.
create or replace function public.media_delete(p_user uuid, p_url text)
returns jsonb language plpgsql security definer set search_path = public
as $$
declare m record;
begin
  select * into m from public.portfolio_media where url = p_url and photographer_id = p_user and status <> 'deleted' for update;
  if found then
    update public.portfolio_media set status = 'deleted', updated_at = now() where id = m.id;
    perform public.media_sync(p_user);
    return jsonb_build_object('delete_key', m.s3_key);
  end if;
  perform set_config('snappro.system', 'on', true);
  update public.photographers set portfolio = array_remove(portfolio, p_url) where id = p_user;
  perform set_config('snappro.system', '', true);
  return jsonb_build_object('delete_key', null);
end $$;

-- 4. Files to remove from S3: hidden for 30+ days, or uploads abandoned for a day.
create or replace function public.media_purge_list(p_limit int default 50)
returns jsonb language sql security definer set search_path = public
as $$ select coalesce(jsonb_agg(s3_key), '[]') from (
        select s3_key from public.portfolio_media
         where (status = 'hidden' and hidden_at < now() - interval '30 days')
            or (status = 'pending' and created_at < now() - interval '1 day')
         limit greatest(1, least(p_limit, 500))) z $$;
create or replace function public.media_mark_purged(p_keys text[])
returns int language plpgsql security definer set search_path = public
as $$ declare n int; pgs uuid[];
begin
  select array_agg(distinct photographer_id) into pgs from public.portfolio_media where s3_key = any(p_keys);
  update public.portfolio_media set status = 'deleted', updated_at = now() where s3_key = any(p_keys) and status in ('hidden','pending');
  get diagnostics n = row_count;
  perform public.media_sync(x) from unnest(coalesce(pgs, '{}')) x;
  return n;
end $$;

-- What the photographer sees: used, allowance, plan, end date, plans on offer.
create or replace function public.my_storage()
returns jsonb language plpgsql security definer set search_path = public
as $$
declare me uuid := auth.uid(); s record;
begin
  if me is null or not exists (select 1 from public.photographers where id = me) then return null; end if;
  -- a plan or a free-storage reward that ended since the last daily check: apply it now
  if exists (select 1 from public.photographer_storage where id = me and plan <> 'free' and expires_at <= now())
     or exists (select 1 from public.user_benefits where user_id = me and kind = 'storage_bonus' and status = 'active' and expires_at <= now()) then
    update public.photographer_storage set plan = 'free', quota_bytes = null, updated_at = now() where id = me and plan <> 'free' and expires_at <= now();
    update public.user_benefits set status = 'expired' where user_id = me and kind = 'storage_bonus' and status = 'active' and expires_at <= now();
    perform public.media_sync(me);
  end if;
  select * into s from public.photographer_storage where id = me;
  return jsonb_build_object(
    'used', public.storage_used(me), 'quota', public.storage_quota(me), 'free', public.storage_free_bytes(),
    'plan', case when s.plan is not null and s.plan <> 'free' and s.expires_at > now() then s.plan else 'free' end,
    'expires_at', case when s.plan <> 'free' and s.expires_at > now() then s.expires_at end,
    'ended_at', case when s.plan = 'free' and s.expires_at <= now() then s.expires_at end,
    'hidden', (select count(*) from public.portfolio_media where photographer_id = me and status = 'hidden'),
    'hidden_bytes', (select coalesce(sum(bytes),0) from public.portfolio_media where photographer_id = me and status = 'hidden'),
    'delete_after', (select min(hidden_at) + interval '30 days' from public.portfolio_media where photographer_id = me and status = 'hidden'),
    'plans', (select value->'plans' from public.platform_settings where key = 'storage_plans'),
    'items', (select coalesce(jsonb_agg(jsonb_build_object('url', url, 'kind', kind, 'bytes', bytes, 'status', status) order by created_at), '[]')
                from public.portfolio_media where photographer_id = me and status in ('ready','hidden')));
end $$;

-- ---------- buying storage (yearly, through Razorpay) ----------
create or replace function public.storage_begin(p_user uuid, p_plan text)
returns jsonb language plpgsql security definer set search_path = public
as $$
declare pl jsonb; u record; pr record; open_o jsonb; disc record; amt numeric;
begin
  if not exists (select 1 from public.photographers where id = p_user) then raise exception 'Only photographers can buy storage'; end if;
  select x into pl from public.platform_settings s, jsonb_array_elements(s.value->'plans') x where s.key = 'storage_plans' and x->>'id' = p_plan;
  if pl is null then raise exception 'Unknown plan'; end if;
  select email into u from auth.users where id = p_user;
  select name, phone into pr from public.profiles where id = p_user;
  -- best "storage_discount" reward (percent off)
  select id, amount into disc from public.user_benefits
   where user_id = p_user and kind = 'storage_discount' and status = 'active'
     and (expires_at is null or expires_at > now()) and (uses_left is null or uses_left > 0)
   order by amount desc limit 1;
  amt := greatest(1, round((pl->>'price')::numeric * (100 - coalesce(disc.amount, 0)) / 100.0));
  select coalesce(jsonb_agg(jsonb_build_object('order_id', order_id, 'gateway_order_id', gateway_order_id, 'environment', environment)
                            order by created_at desc), '[]') into open_o
    from public.storage_orders where photographer_id = p_user and plan = p_plan and amount = amt
     and status in ('created','active','failed') and created_at > now() - interval '1 day';
  return jsonb_build_object('plan', p_plan, 'name', pl->>'name', 'amount', amt,
    'list_price', (pl->>'price')::numeric, 'discount_pct', disc.amount, 'discount_benefit_id', disc.id,
    'quota_bytes', ((pl->>'gb')::numeric * 1024 * 1024 * 1024)::bigint, 'gb', pl->'gb',
    'customer_email', u.email, 'customer_name', pr.name, 'customer_phone', pr.phone, 'open_orders', open_o);
end $$;
create or replace function public.storage_create(p_user uuid, p_plan text, p_order_id text, p_env text)
returns uuid language plpgsql security definer set search_path = public
as $$
declare b jsonb := public.storage_begin(p_user, p_plan); oid uuid;
begin
  if p_order_id !~ '^[A-Za-z0-9_-]{3,40}$' then raise exception 'Bad order id'; end if;
  insert into public.storage_orders (order_id, photographer_id, plan, plan_name, quota_bytes, amount, environment, discount_benefit_id)
  values (p_order_id, p_user, p_plan, b->>'name', (b->>'quota_bytes')::bigint, (b->>'amount')::numeric, p_env, nullif(b->>'discount_benefit_id','')::uuid)
  returning id into oid;
  return oid;
end $$;
create or replace function public.storage_set_gateway(p_order_id text, p_gateway_order_id text)
returns void language sql security definer set search_path = public
as $$ update public.storage_orders set gateway_order_id = p_gateway_order_id, status = 'active', updated_at = now() where order_id = p_order_id $$;
create or replace function public.storage_lookup(p_order_id text)
returns jsonb language sql stable security definer set search_path = public
as $$ select to_jsonb(o) from public.storage_orders o where o.order_id = p_order_id or o.gateway_order_id = p_order_id limit 1 $$;

-- A verified payment for a storage order. Safe to call more than once.
create or replace function public.storage_record(p_order_id text, p_event_key text, p_status text,
    p_payment_ref text default null, p_amount numeric default null, p_group text default null)
returns jsonb language plpgsql security definer set search_path = public
as $$
declare o record; s record; n int; st text; start_at timestamptz; ends timestamptz;
begin
  if p_event_key is not null then
    insert into public.payment_events (event_key, order_id, event_type, payment_status, payment_ref)
    values (p_event_key, p_order_id, 'STORAGE', p_status, p_payment_ref) on conflict (event_key) do nothing;
    get diagnostics n = row_count;
    if n = 0 then return jsonb_build_object('result','duplicate_event'); end if;
  end if;
  select * into o from public.storage_orders where order_id = p_order_id or gateway_order_id = p_order_id limit 1 for update;
  if not found then return jsonb_build_object('result','unknown_order'); end if;
  if o.status = 'paid' then return jsonb_build_object('result','already_paid','status','paid','plan',o.plan,'period_end',o.period_end); end if;
  st := case upper(coalesce(p_status,'')) when 'CAPTURED' then 'paid' when 'PAID' then 'paid' when 'SUCCESS' then 'paid'
          when 'FAILED' then 'failed' when 'TERMINATED' then 'terminated' when 'CANCELLED' then 'cancelled' else null end;
  if st is null then return jsonb_build_object('result','pending','status',o.status); end if;
  if st <> 'paid' then
    update public.storage_orders set status = st, gateway_payment_id = coalesce(p_payment_ref, gateway_payment_id), updated_at = now() where id = o.id;
    return jsonb_build_object('result','recorded','status',st);
  end if;
  if p_amount is not null and round(p_amount,2) <> round(o.amount,2) then
    update public.storage_orders set status = 'failed', gateway_payment_id = p_payment_ref, updated_at = now() where id = o.id;
    return jsonb_build_object('result','amount_mismatch','status','failed');
  end if;
  -- renewing the same plan adds a year to whatever is left; a different plan starts today
  select * into s from public.photographer_storage where id = o.photographer_id for update;
  start_at := case when s.plan = o.plan and s.expires_at > now() then s.expires_at else now() end;
  ends := start_at + interval '1 year';
  insert into public.photographer_storage (id, plan, quota_bytes, expires_at, reminded_at, updated_at)
  values (o.photographer_id, o.plan, o.quota_bytes, ends, null, now())
  on conflict (id) do update set plan = excluded.plan, quota_bytes = excluded.quota_bytes, expires_at = excluded.expires_at,
                                 reminded_at = null, updated_at = now();
  update public.storage_orders set status = 'paid', gateway_payment_id = p_payment_ref, payment_group = p_group,
         paid_at = now(), period_start = start_at, period_end = ends, updated_at = now() where id = o.id;
  if o.discount_benefit_id is not null then perform public._use_benefit(o.discount_benefit_id, 1); end if;
  perform public.media_sync(o.photographer_id);
  return jsonb_build_object('result','paid','status','paid','plan',o.plan,'period_end',ends);
end $$;

-- Daily: end lapsed plans (hide what no longer fits) and remind people 7 days before.
create or replace function public.storage_sweep()
returns int language plpgsql security definer set search_path = public
as $$
declare r record; n int := 0;
begin
  for r in select * from public.photographer_storage where plan <> 'free' and expires_at <= now() loop
    update public.photographer_storage set plan = 'free', quota_bytes = null, updated_at = now() where id = r.id;
    perform public.media_sync(r.id); n := n + 1;
  end loop;
  -- rewards that ran out (free storage, featured, discounts)
  for r in update public.user_benefits set status = 'expired' where status = 'active' and expires_at <= now() returning user_id, kind loop
    if r.kind = 'storage_bonus' then perform public.media_sync(r.user_id); end if;
  end loop;
  for r in select s.id, u.email, g.display_name, s.expires_at from public.photographer_storage s
             join auth.users u on u.id = s.id join public.photographers g on g.id = s.id
            where s.plan <> 'free' and s.expires_at between now() and now() + interval '7 days' and s.reminded_at is null loop
    begin
      perform public._send_email(r.email, 'Your SnapPro storage plan ends soon',
        '<p>Hi ' || coalesce(r.display_name,'there') || ',</p><p>Your SnapPro storage plan ends on <b>' ||
        to_char(r.expires_at at time zone 'Asia/Kolkata', 'DD Mon YYYY') ||
        '</b>. Renew it from <b>Profile → Portfolio</b> in the app to keep all your photos and videos on your profile.</p>' ||
        '<p>If it ends, anything over the free 250 MB is hidden and then deleted after 30 days.</p><p>— SnapPro</p>');
    exception when others then null; end;
    update public.photographer_storage set reminded_at = now() where id = r.id;
  end loop;
  return n;
end $$;
do $$ begin
  create extension if not exists pg_cron;
  perform cron.schedule('snappro-storage-sweep', '30 0 * * *', 'select public.storage_sweep()');
exception when others then raise notice 'pg_cron not available — storage_sweep also runs when photographers open their portfolio'; end $$;

-- Super admins can change the storage plans and prices (new purchases only).
create or replace function public.admin_set_storage_plans(p jsonb)
returns jsonb language plpgsql security definer set search_path = public
as $$
declare x jsonb;
begin
  if not public.is_super() then raise exception 'Only a super admin can change storage plans'; end if;
  if (p->>'free_mb')::numeric is null or (p->>'free_mb')::numeric < 10 then raise exception 'Free storage must be at least 10 MB'; end if;
  for x in select * from jsonb_array_elements(coalesce(p->'plans','[]')) loop
    if coalesce(x->>'id','') !~ '^[a-z0-9_-]{2,20}$' or (x->>'gb')::numeric <= 0 or (x->>'price')::numeric < 1 then
      raise exception 'Each plan needs an id, a size in GB and a price of at least ₹1'; end if;
  end loop;
  insert into public.platform_settings (key, value, updated_at) values ('storage_plans', p, now())
  on conflict (key) do update set value = excluded.value, updated_at = now();
  return p;
end $$;

-- Photographers may reorder or remove items in their portfolio list, but
-- only the server adds to it (so uploads always go through the size checks).
create or replace function public.photographer_portfolio_guard()
returns trigger language plpgsql
as $$
begin
  if public.snappro_system() or tg_op <> 'UPDATE' then return new; end if;
  if not (coalesce(new.portfolio,'{}') <@ coalesce(old.portfolio,'{}')) then
    raise exception 'Add photos and videos with the Add button on your Portfolio screen';
  end if;
  return new;
end $$;
drop trigger if exists photographer_portfolio_guard on public.photographers;
create trigger photographer_portfolio_guard before update on public.photographers
  for each row execute function public.photographer_portfolio_guard();

revoke all on function public.media_begin(uuid, text, text, text, bigint, text) from public, anon, authenticated;
revoke all on function public.media_confirm(uuid, text, bigint)                 from public, anon, authenticated;
revoke all on function public.media_delete(uuid, text)                          from public, anon, authenticated;
revoke all on function public.media_purge_list(int)                             from public, anon, authenticated;
revoke all on function public.media_mark_purged(text[])                         from public, anon, authenticated;
revoke all on function public.media_sync(uuid)                                  from public, anon, authenticated;
revoke all on function public.storage_begin(uuid, text)                         from public, anon, authenticated;
revoke all on function public.storage_create(uuid, text, text, text)            from public, anon, authenticated;
revoke all on function public.storage_set_gateway(text, text)                   from public, anon, authenticated;
revoke all on function public.storage_lookup(text)                              from public, anon, authenticated;
revoke all on function public.storage_record(text, text, text, text, numeric, text) from public, anon, authenticated;
revoke all on function public.storage_sweep()                                   from public, anon, authenticated;
grant execute on function public.media_begin(uuid, text, text, text, bigint, text) to service_role;
grant execute on function public.media_confirm(uuid, text, bigint)                 to service_role;
grant execute on function public.media_delete(uuid, text)                          to service_role;
grant execute on function public.media_purge_list(int)                             to service_role;
grant execute on function public.media_mark_purged(text[])                         to service_role;
grant execute on function public.media_sync(uuid)                                  to service_role;
grant execute on function public.storage_begin(uuid, text)                         to service_role;
grant execute on function public.storage_create(uuid, text, text, text)            to service_role;
grant execute on function public.storage_set_gateway(text, text)                   to service_role;
grant execute on function public.storage_lookup(text)                              to service_role;
grant execute on function public.storage_record(text, text, text, text, numeric, text) to service_role;
grant execute on function public.storage_sweep()                                   to service_role;
revoke all on function public.my_storage() from public, anon;
grant execute on function public.my_storage() to authenticated;
revoke all on function public.admin_set_storage_plans(jsonb) from public, anon;
grant execute on function public.admin_set_storage_plans(jsonb) to authenticated;

-- =====================================================================
-- 7e. MEMBER IDS, PER-PHOTOGRAPHER COMMISSION, OFFERS & REFERRALS
--     Every account gets a SnapPro ID (SPC… customers, SPP… photographers)
--     that also works as their referral code. Admins can give one
--     photographer a different commission, create offers for customers
--     and photographers, and set referral rewards. Rewards become
--     "benefits" on the person's account and are applied by the server
--     (booking discounts, lower commission, extra storage, featured badge,
--     storage discounts) — never by the browser.
-- =====================================================================

-- ---------- SnapPro IDs ----------
create sequence if not exists public.member_no_seq start 100001;
grant usage on sequence public.member_no_seq to authenticated, service_role;
alter table public.profiles
  add column if not exists member_no            bigint,
  add column if not exists public_id            text,
  add column if not exists referred_by          uuid,
  add column if not exists referral_at          timestamptz,
  add column if not exists referral_rewarded_at timestamptz;
create unique index if not exists uniq_profiles_member_no on public.profiles(member_no);
create unique index if not exists uniq_profiles_public_id on public.profiles(public_id);

create or replace function public.profile_ids()
returns trigger language plpgsql
as $$
begin
  if not public.snappro_system() then
    if tg_op = 'UPDATE' then
      new.member_no := old.member_no; new.referred_by := old.referred_by;
      new.referral_at := old.referral_at; new.referral_rewarded_at := old.referral_rewarded_at;
    else
      new.member_no := null; new.referred_by := null; new.referral_at := null; new.referral_rewarded_at := null;
    end if;
  end if;
  if new.member_no is null then new.member_no := nextval('public.member_no_seq'); end if;
  new.public_id := case when new.role = 'photographer' then 'SPP' else 'SPC' end || new.member_no;
  return new;
end $$;
drop trigger if exists profile_ids on public.profiles;
create trigger profile_ids before insert or update on public.profiles
  for each row execute function public.profile_ids();
-- give existing accounts an ID, oldest first
do $$ declare r record;
begin
  perform set_config('snappro.system', 'on', true);
  for r in select id from public.profiles where member_no is null order by created_at, id loop
    update public.profiles set member_no = nextval('public.member_no_seq') where id = r.id;
  end loop;
  update public.profiles set role = role where public_id is null;
  perform set_config('snappro.system', '', true);
end $$;

-- ---------- per-photographer commission + featured badge ----------
alter table public.photographers
  add column if not exists commission_pct numeric(5,2),
  add column if not exists featured_until timestamptz;
alter table public.bookings
  add column if not exists commission_benefit_id uuid,
  add column if not exists discount_benefit_id   uuid,
  add column if not exists discount_amount       integer not null default 0;

create or replace function public.admin_set_pg_commission(p_pg uuid, p_pct numeric)
returns numeric language plpgsql security definer set search_path = public
as $$
begin
  if coalesce(public.staff_role() in ('super_admin','admin'), false) is not true then raise exception 'Only admins can change commission'; end if;
  if p_pct is not null and (p_pct < 0 or p_pct > 50) then raise exception 'Commission must be between 0 and 50%%'; end if;
  perform set_config('snappro.system', 'on', true);
  update public.photographers set commission_pct = round(p_pct, 2) where id = p_pg;
  perform set_config('snappro.system', '', true);
  if not found then raise exception 'Photographer not found'; end if;
  return p_pct;
end $$;

-- ---------- offers and the benefits they create ----------
create table if not exists public.promo_offers (
  id             uuid primary key default gen_random_uuid(),
  audience       text not null check (audience in ('customer','photographer')),
  kind           text not null check (kind in ('booking_flat','booking_pct','storage_bonus','commission_cut','featured','storage_discount')),
  title          text not null,
  description    text,
  badge          text,
  amount         numeric(12,2) not null default 0,     -- ₹ off / % off / GB / commission %
  max_amount     numeric(12,2),                        -- cap for % discounts
  min_booking    numeric(12,2),                        -- customer offers: minimum booking price
  uses           integer,                              -- how many bookings / purchases it applies to (null = unlimited)
  days           integer,                              -- how long it lasts once someone has it
  code           text unique,                          -- promo code (null = shown in the app to claim)
  is_public      boolean not null default true,        -- show in the app's "Offers" list
  new_users_only boolean not null default false,
  starts_at      timestamptz,
  ends_at        timestamptz,
  max_claims     integer,
  claims         integer not null default 0,
  active         boolean not null default true,
  created_by     uuid,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);
create table if not exists public.user_benefits (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references public.profiles(id) on delete cascade,
  offer_id    uuid references public.promo_offers(id) on delete set null,
  source      text not null default 'offer' check (source in ('offer','code','admin','referral')),
  kind        text not null,
  title       text,
  amount      numeric(12,2) not null default 0,
  max_amount  numeric(12,2),
  min_booking numeric(12,2),
  uses_left   integer,
  expires_at  timestamptz,
  status      text not null default 'active' check (status in ('active','used','expired','revoked')),
  created_at  timestamptz not null default now(),
  used_at     timestamptz
);
create unique index if not exists uniq_benefit_per_offer on public.user_benefits(user_id, offer_id) where offer_id is not null;
create index if not exists idx_benefits_user on public.user_benefits(user_id, status);
alter table public.promo_offers        enable row level security;
alter table public.user_benefits enable row level security;
drop policy if exists promo_offers_staff_read on public.promo_offers;
create policy promo_offers_staff_read on public.promo_offers for select to authenticated using (public.is_staff());
drop policy if exists benefits_read on public.user_benefits;
create policy benefits_read on public.user_benefits for select to authenticated using (user_id = auth.uid() or public.is_staff());
revoke insert, update, delete on public.promo_offers, public.user_benefits from anon, authenticated;

insert into public.platform_settings (key, value) values ('referral_program', '{
  "enabled": false,
  "customer":     {"when": "first_booking",
                   "new_user_reward": {"kind": "booking_flat", "amount": 100, "uses": 1, "days": 90, "title": "₹100 off your first booking"},
                   "referrer_reward": {"kind": "booking_flat", "amount": 100, "uses": 1, "days": 90, "title": "₹100 off — thanks for inviting a friend"}},
  "photographer": {"when": "first_booking",
                   "new_user_reward": {"kind": "storage_bonus", "amount": 1, "days": 90, "title": "1 GB extra storage for 3 months"},
                   "referrer_reward": {"kind": "commission_cut", "amount": 10, "uses": 2, "days": 180, "title": "10% commission on your next 2 bookings"}}
}') on conflict (key) do nothing;

create or replace function public._kind_audience(k text)
returns text language sql immutable as $$
  select case when k in ('booking_flat','booking_pct') then 'customer'
              when k in ('storage_bonus','commission_cut','featured','storage_discount') then 'photographer' end $$;

-- Put a reward on someone's account (server only).
create or replace function public._grant_benefit(p_user uuid, p jsonb, p_source text, p_offer uuid, p_ends timestamptz default null)
returns uuid language plpgsql security definer set search_path = public
as $$
declare k text := p->>'kind'; d int := nullif(p->>'days','')::int; bid uuid; role_ text; exp timestamptz;
begin
  if k is null or k = 'none' then return null; end if;
  select role into role_ from public.profiles where id = p_user;
  if public._kind_audience(k) is distinct from (case when role_ = 'photographer' then 'photographer' else 'customer' end) then return null; end if;
  if k in ('storage_bonus','featured','commission_cut','storage_discount') and not exists (select 1 from public.photographers where id = p_user) then return null; end if;
  exp := case when d is not null then now() + make_interval(days => d) else p_ends end;
  insert into public.user_benefits (user_id, offer_id, source, kind, title, amount, max_amount, min_booking, uses_left, expires_at)
  values (p_user, p_offer, p_source, k, left(coalesce(p->>'title', k), 120), coalesce((p->>'amount')::numeric, 0),
          nullif(p->>'max_amount','')::numeric, nullif(p->>'min_booking','')::numeric,
          case when k in ('storage_bonus','featured') then null else nullif(p->>'uses','')::int end, exp)
  on conflict do nothing
  returning id into bid;
  if bid is null then return null; end if;
  if k = 'featured' then
    perform set_config('snappro.system', 'on', true);
    update public.photographers set featured_until = greatest(coalesce(featured_until, now()), now()) + make_interval(days => coalesce(d, 7)) where id = p_user;
    perform set_config('snappro.system', '', true);
  elsif k = 'storage_bonus' then
    perform public.media_sync(p_user);
  end if;
  return bid;
end $$;

-- Best commission for a photographer right now: an active "commission_cut" reward,
-- else their own rate set by an admin, else the platform rate.
create or replace function public.commission_for(p_pg uuid)
returns table(pct numeric, benefit_id uuid) language plpgsql stable security definer set search_path = public
as $$
declare base numeric; b record;
begin
  select coalesce(g.commission_pct, public.commission_pct()) into base from public.photographers g where g.id = p_pg;
  base := coalesce(base, public.commission_pct());
  select id, amount into b from public.user_benefits
   where user_id = p_pg and kind = 'commission_cut' and status = 'active'
     and (expires_at is null or expires_at > now()) and (uses_left is null or uses_left > 0)
   order by amount asc limit 1;
  if b.id is not null and b.amount < base then return query select b.amount, b.id;
  else return query select base, null::uuid; end if;
end $$;

-- Best booking discount a customer has for this price (capped at SnapPro's commission).
create or replace function public.discount_for(p_customer uuid, p_price numeric, p_cap numeric)
returns table(amount integer, benefit_id uuid) language plpgsql stable security definer set search_path = public
as $$
declare b record; best int := 0; bid uuid; d int;
begin
  for b in select * from public.user_benefits
            where user_id = p_customer and kind in ('booking_flat','booking_pct') and status = 'active'
              and (expires_at is null or expires_at > now()) and (uses_left is null or uses_left > 0)
              and (min_booking is null or p_price >= min_booking) loop
    d := case when b.kind = 'booking_flat' then round(b.amount)
              else least(round(p_price * b.amount / 100.0), coalesce(round(b.max_amount), 1000000)) end;
    d := least(d, greatest(0, floor(p_cap)));
    if d > best then best := d; bid := b.id; end if;
  end loop;
  return query select best, bid;
end $$;

create or replace function public._use_benefit(p_id uuid, p_delta int)
returns void language sql security definer set search_path = public
as $$ update public.user_benefits
         set uses_left = case when uses_left is null then null else greatest(0, uses_left - p_delta) end,
             status = case when uses_left is not null and uses_left - p_delta <= 0 then 'used'
                           when status = 'used' and p_delta < 0 and (expires_at is null or expires_at > now()) then 'active'
                           else status end,
             used_at = case when p_delta > 0 then now() else used_at end
       where id = p_id $$;

-- Claim an offer: by promo code, or by tapping "Claim" on a public offer.
create or replace function public.claim_offer(p_code text default null, p_offer uuid default null)
returns jsonb language plpgsql security definer set search_path = public
as $$
declare me uuid := auth.uid(); o record; pr record; aud text; bid uuid;
begin
  if me is null then raise exception 'Please log in again'; end if;
  select * into pr from public.profiles where id = me;
  aud := case when pr.role = 'photographer' then 'photographer' else 'customer' end;
  if p_code is not null and trim(p_code) <> '' then
    select * into o from public.promo_offers where code = upper(trim(p_code)) for update;
    if not found then
      -- not a promo code? maybe it's a friend's SnapPro ID
      if exists (select 1 from public.profiles where public_id = upper(trim(p_code))) then return public.apply_referral(p_code); end if;
      raise exception 'That code isn''t valid';
    end if;
  else
    select * into o from public.promo_offers where id = p_offer and is_public and code is null for update;
    if not found then raise exception 'Offer not found'; end if;
  end if;
  if not o.active or (o.starts_at is not null and o.starts_at > now()) or (o.ends_at is not null and o.ends_at < now()) then raise exception 'This offer has ended'; end if;
  if o.audience <> aud then raise exception 'This offer is for %s only', case when o.audience = 'photographer' then 'photographer' else 'customer' end; end if;
  if o.max_claims is not null and o.claims >= o.max_claims then raise exception 'This offer has been fully claimed'; end if;
  if exists (select 1 from public.user_benefits where user_id = me and offer_id = o.id) then raise exception 'You already have this offer'; end if;
  if o.new_users_only and (pr.created_at < now() - interval '30 days'
       or exists (select 1 from public.bookings b where (b.customer_id = me or b.photographer_id = me) and b.status <> 'cancelled')) then
    raise exception 'This offer is for new members only';
  end if;
  bid := public._grant_benefit(me, to_jsonb(o), case when p_code is not null then 'code' else 'offer' end, o.id, o.ends_at);
  if bid is null then raise exception 'This offer can''t be added to your account'; end if;
  update public.promo_offers set claims = claims + 1, updated_at = now() where id = o.id;
  return jsonb_build_object('result','claimed','title', o.title, 'kind', o.kind);
end $$;

-- ---------- referrals ----------
create or replace function public.referral_check(p_user uuid)
returns boolean language plpgsql security definer set search_path = public
as $$
declare prog jsonb := (select value from public.platform_settings where key = 'referral_program');
        me record; ref record; mine jsonb; theirs jsonb; ok boolean;
begin
  if prog is null or coalesce((prog->>'enabled')::boolean, false) is not true then return false; end if;
  select * into me from public.profiles where id = p_user;
  if me.referred_by is null or me.referral_rewarded_at is not null then return false; end if;
  select * into ref from public.profiles where id = me.referred_by;
  if not found then return false; end if;
  mine := prog->(case when me.role = 'photographer' then 'photographer' else 'customer' end);
  theirs := prog->(case when ref.role = 'photographer' then 'photographer' else 'customer' end);
  ok := case coalesce(mine->>'when','first_booking')
          when 'signup' then true
          else exists (select 1 from public.bookings b where b.status = 'completed'
                        and (b.customer_id = p_user or b.photographer_id = p_user)) end;
  if not ok then return false; end if;
  perform public._grant_benefit(p_user, mine->'new_user_reward', 'referral', null);
  perform public._grant_benefit(ref.id, theirs->'referrer_reward', 'referral', null);
  perform set_config('snappro.system', 'on', true);
  update public.profiles set referral_rewarded_at = now() where id = p_user;
  perform set_config('snappro.system', '', true);
  return true;
end $$;

create or replace function public.apply_referral(p_code text)
returns jsonb language plpgsql security definer set search_path = public
as $$
declare me uuid := auth.uid(); pr record; ref record;
begin
  if me is null then raise exception 'Please log in again'; end if;
  select * into pr from public.profiles where id = me;
  if pr.referred_by is not null then raise exception 'You''ve already added a referral code'; end if;
  if pr.created_at < now() - interval '14 days' then raise exception 'Referral codes can only be added in your first 14 days'; end if;
  select * into ref from public.profiles where public_id = upper(trim(coalesce(p_code,'')));
  if not found then raise exception 'That code isn''t valid'; end if;
  if ref.id = me then raise exception 'You can''t use your own code'; end if;
  perform set_config('snappro.system', 'on', true);
  update public.profiles set referred_by = ref.id, referral_at = now() where id = me;
  perform set_config('snappro.system', '', true);
  perform public.referral_check(me);
  return jsonb_build_object('result','referred','by', split_part(coalesce(ref.name,'a friend'),' ',1));
end $$;

-- What the app shows on "Offers & rewards" and "Invite friends".
create or replace function public.my_rewards()
returns jsonb language plpgsql security definer set search_path = public
as $$
declare me uuid := auth.uid(); pr record; aud text; prog jsonb := (select value from public.platform_settings where key = 'referral_program');
begin
  if me is null then return null; end if;
  update public.user_benefits set status = 'expired' where user_id = me and status = 'active' and expires_at <= now();
  select * into pr from public.profiles where id = me;
  aud := case when pr.role = 'photographer' then 'photographer' else 'customer' end;
  return jsonb_build_object(
    'public_id', pr.public_id,
    'benefits', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'kind', kind, 'title', title, 'amount', amount, 'max_amount', max_amount,
                   'min_booking', min_booking, 'uses_left', uses_left, 'expires_at', expires_at, 'source', source) order by created_at desc), '[]')
                 from public.user_benefits where user_id = me and status = 'active'),
    'offers', (select coalesce(jsonb_agg(jsonb_build_object('id', o.id, 'kind', o.kind, 'title', o.title, 'description', o.description, 'badge', o.badge,
                 'amount', o.amount, 'max_amount', o.max_amount, 'min_booking', o.min_booking, 'uses', o.uses, 'days', o.days, 'ends_at', o.ends_at,
                 'new_users_only', o.new_users_only) order by o.created_at desc), '[]')
               from public.promo_offers o
              where o.active and o.is_public and o.code is null and o.audience = aud
                and (o.starts_at is null or o.starts_at <= now()) and (o.ends_at is null or o.ends_at > now())
                and (o.max_claims is null or o.claims < o.max_claims)
                and not exists (select 1 from public.user_benefits b where b.user_id = me and b.offer_id = o.id)),
    'commission_pct', case when aud = 'photographer' then (select pct from public.commission_for(me)) end,
    'featured_until', (select featured_until from public.photographers where id = me and featured_until > now()),
    'referral', jsonb_build_object(
       'enabled', coalesce((prog->>'enabled')::boolean, false),
       'my_reward', prog->aud->'referrer_reward', 'friend_reward_customer', prog->'customer'->'new_user_reward',
       'friend_reward_photographer', prog->'photographer'->'new_user_reward', 'when', prog->aud->>'when',
       'can_add_code', pr.referred_by is null and pr.created_at > now() - interval '14 days',
       'invited', (select count(*) from public.profiles x where x.referred_by = me),
       'rewarded', (select count(*) from public.profiles x where x.referred_by = me and x.referral_rewarded_at is not null)));
end $$;

-- ---------- admin ----------
create or replace function public.admin_offer_save(p jsonb)
returns uuid language plpgsql security definer set search_path = public
as $$
declare oid uuid := nullif(p->>'id','')::uuid; k text := p->>'kind'; c text := nullif(upper(trim(coalesce(p->>'code',''))), '');
begin
  if coalesce(public.staff_role() in ('super_admin','admin'), false) is not true then raise exception 'Only admins can manage offers'; end if;
  if public._kind_audience(k) is null then raise exception 'Choose what the offer gives'; end if;
  if public._kind_audience(k) <> p->>'audience' then raise exception 'That kind of offer is for %s', public._kind_audience(k); end if;
  if coalesce(trim(p->>'title'),'') = '' then raise exception 'Give the offer a title'; end if;
  if c is not null and c !~ '^[A-Z0-9_-]{3,20}$' then raise exception 'Promo codes: 3–20 letters or numbers'; end if;
  if c is not null and exists (select 1 from public.profiles where public_id = c) then raise exception 'That code is someone''s SnapPro ID — pick another'; end if;
  if k in ('booking_pct','storage_discount') and ((p->>'amount')::numeric <= 0 or (p->>'amount')::numeric > 100) then raise exception 'Percent must be between 1 and 100'; end if;
  if k = 'commission_cut' and ((p->>'amount')::numeric < 0 or (p->>'amount')::numeric > 50) then raise exception 'Commission must be between 0 and 50%%'; end if;
  if k in ('featured','storage_bonus') and coalesce(nullif(p->>'days','')::int, 0) <= 0 then raise exception 'Say how many days it lasts'; end if;
  if k in ('booking_flat','storage_bonus') and (p->>'amount')::numeric <= 0 then raise exception 'Enter an amount'; end if;
  if oid is null then
    insert into public.promo_offers (audience, kind, title, description, badge, amount, max_amount, min_booking, uses, days, code, is_public,
                               new_users_only, starts_at, ends_at, max_claims, active, created_by)
    values (p->>'audience', k, left(p->>'title',120), left(p->>'description',300), left(nullif(p->>'badge',''),24), coalesce((p->>'amount')::numeric,0),
            nullif(p->>'max_amount','')::numeric, nullif(p->>'min_booking','')::numeric, nullif(p->>'uses','')::int, nullif(p->>'days','')::int,
            c, coalesce((p->>'is_public')::boolean, true), coalesce((p->>'new_users_only')::boolean, false),
            nullif(p->>'starts_at','')::timestamptz, nullif(p->>'ends_at','')::timestamptz, nullif(p->>'max_claims','')::int,
            coalesce((p->>'active')::boolean, true), auth.uid())
    returning id into oid;
  else
    update public.promo_offers set title = left(p->>'title',120), description = left(p->>'description',300), badge = left(nullif(p->>'badge',''),24),
           amount = coalesce((p->>'amount')::numeric,0), max_amount = nullif(p->>'max_amount','')::numeric, min_booking = nullif(p->>'min_booking','')::numeric,
           uses = nullif(p->>'uses','')::int, days = nullif(p->>'days','')::int, code = c, is_public = coalesce((p->>'is_public')::boolean, true),
           new_users_only = coalesce((p->>'new_users_only')::boolean, false), starts_at = nullif(p->>'starts_at','')::timestamptz,
           ends_at = nullif(p->>'ends_at','')::timestamptz, max_claims = nullif(p->>'max_claims','')::int,
           active = coalesce((p->>'active')::boolean, true), updated_at = now()
     where id = oid;
  end if;
  return oid;
end $$;

-- Give an offer to everyone in its audience, or to one person by SnapPro ID.
create or replace function public.admin_offer_grant(p_offer uuid, p_public_id text default null)
returns int language plpgsql security definer set search_path = public
as $$
declare o record; u record; n int := 0;
begin
  if coalesce(public.staff_role() in ('super_admin','admin'), false) is not true then raise exception 'Only admins can give offers'; end if;
  select * into o from public.promo_offers where id = p_offer;
  if not found then raise exception 'Offer not found'; end if;
  for u in select pr.id from public.profiles pr
            where (p_public_id is null or pr.public_id = upper(trim(p_public_id)))
              and (case when pr.role = 'photographer' then 'photographer' else 'customer' end) = o.audience
              and not exists (select 1 from public.staff s where s.id = pr.id) loop
    if public._grant_benefit(u.id, to_jsonb(o), 'admin', o.id, o.ends_at) is not null then n := n + 1; end if;
  end loop;
  if p_public_id is not null and n = 0 then raise exception 'No % with that ID, or they already have it', o.audience; end if;
  update public.promo_offers set claims = claims + n, updated_at = now() where id = o.id;
  return n;
end $$;

create or replace function public.admin_referral_save(p jsonb)
returns jsonb language plpgsql security definer set search_path = public
as $$
begin
  if not public.is_super() then raise exception 'Only a super admin can change the referral program'; end if;
  insert into public.platform_settings (key, value, updated_at) values ('referral_program', p, now())
  on conflict (key) do update set value = excluded.value, updated_at = now();
  return p;
end $$;

-- Everything an admin needs on the Offers tab
create or replace function public.admin_offers_overview()
returns jsonb language plpgsql stable security definer set search_path = public
as $$
begin
  if not public.is_staff() then return null; end if;
  return jsonb_build_object(
    'offers', (select coalesce(jsonb_agg(to_jsonb(o) || jsonb_build_object(
                 'active_benefits', (select count(*) from public.user_benefits b where b.offer_id = o.id and b.status = 'active'),
                 'used', (select count(*) from public.user_benefits b where b.offer_id = o.id and b.status = 'used'))
               order by o.created_at desc), '[]') from public.promo_offers o),
    'referral_program', (select value from public.platform_settings where key = 'referral_program'),
    'referrals', jsonb_build_object(
       'total', (select count(*) from public.profiles where referred_by is not null),
       'rewarded', (select count(*) from public.profiles where referral_rewarded_at is not null),
       'top', (select coalesce(jsonb_agg(z order by z.invited desc), '[]') from (
                 select r.public_id, r.name, r.role, count(*) invited, count(p.referral_rewarded_at) rewarded
                   from public.profiles p join public.profiles r on r.id = p.referred_by group by r.id, r.public_id, r.name, r.role
                  order by count(*) desc limit 20) z)),
    'benefit_totals', (select coalesce(jsonb_agg(z), '[]') from (select kind, source, status, count(*) n from public.user_benefits group by 1,2,3) z),
    'discounts_given', (select coalesce(sum(discount_amount),0) from public.bookings where status <> 'cancelled'),
    'commission_overrides', (select coalesce(jsonb_agg(jsonb_build_object('id', g.id, 'name', g.display_name, 'pct', g.commission_pct)), '[]')
                               from public.photographers g where g.commission_pct is not null)
  );
end $$;

revoke all on function public._grant_benefit(uuid, jsonb, text, uuid, timestamptz) from public, anon, authenticated;
revoke all on function public._use_benefit(uuid, int)                              from public, anon, authenticated;
revoke all on function public.referral_check(uuid)                                 from public, anon, authenticated;
revoke all on function public.commission_for(uuid)                                 from public, anon, authenticated;
revoke all on function public.discount_for(uuid, numeric, numeric)                 from public, anon, authenticated;
revoke all on function public.claim_offer(text, uuid)         from public, anon;
revoke all on function public.apply_referral(text)            from public, anon;
revoke all on function public.my_rewards()                    from public, anon;
revoke all on function public.admin_set_pg_commission(uuid, numeric) from public, anon;
revoke all on function public.admin_offer_save(jsonb)         from public, anon;
revoke all on function public.admin_offer_grant(uuid, text)   from public, anon;
revoke all on function public.admin_referral_save(jsonb)      from public, anon;
revoke all on function public.admin_offers_overview()         from public, anon;
grant execute on function public.claim_offer(text, uuid)         to authenticated;
grant execute on function public.apply_referral(text)            to authenticated;
grant execute on function public.my_rewards()                    to authenticated;
grant execute on function public.admin_set_pg_commission(uuid, numeric) to authenticated;
grant execute on function public.admin_offer_save(jsonb)         to authenticated;
grant execute on function public.admin_offer_grant(uuid, text)   to authenticated;
grant execute on function public.admin_referral_save(jsonb)      to authenticated;
grant execute on function public.admin_offers_overview()         to authenticated;

-- =====================================================================
-- 7f. TRUST & SAFETY
--     • Activity log of everything staff do (approvals, refunds, payouts,
--       commission, offers, suspensions, ID checks, chats opened…)
--     • Suspend / block customers and photographers
--     • Staff can read a booking's chat (every opening is logged)
--     • Photographer ID check: government ID front + back and a face photo,
--       stored in a PRIVATE bucket only staff can open
--     • In-app voice calls: each booking has a secret call channel
-- =====================================================================

-- ---------- activity log ----------
create table if not exists public.admin_audit (
  id          bigserial primary key,
  at          timestamptz not null default now(),
  staff_id    uuid,
  staff_email text,
  staff_role  text,
  action      text not null,
  target_type text,
  target_id   text,
  target_name text,
  details     jsonb
);
create index if not exists idx_audit_at on public.admin_audit(at desc);
alter table public.admin_audit enable row level security;
drop policy if exists audit_read on public.admin_audit;
create policy audit_read on public.admin_audit for select to authenticated
  using (coalesce(public.staff_role() in ('super_admin','admin'), false));
revoke insert, update, delete on public.admin_audit from anon, authenticated;

-- record one staff action (does nothing for non-staff, e.g. a photographer editing their own profile)
create or replace function public._audit(p_action text, p_type text, p_id text, p_name text, p_details jsonb, p_staff uuid default null)
returns void language plpgsql security definer set search_path = public
as $$
declare s record;
begin
  select id, email, role into s from public.staff where id = coalesce(p_staff, auth.uid());
  if not found then return; end if;
  insert into public.admin_audit (staff_id, staff_email, staff_role, action, target_type, target_id, target_name, details)
  values (s.id, s.email, s.role, p_action, p_type, p_id, p_name, p_details);
end $$;
revoke all on function public._audit(text, text, text, text, jsonb, uuid) from public, anon, authenticated;

create or replace function public.audit_photographers()
returns trigger language plpgsql security definer set search_path = public
as $$
begin
  if new.approval_status is distinct from old.approval_status then
    perform public._audit(case new.approval_status when 'approved' then 'Approved photographer' when 'rejected' then 'Did not approve photographer' else 'Photographer back to review' end,
      'photographer', new.id::text, new.display_name, jsonb_build_object('note', new.review_note));
  end if;
  if new.is_verified is distinct from old.is_verified then
    perform public._audit(case when new.is_verified then 'Gave Verified badge' else 'Removed Verified badge' end, 'photographer', new.id::text, new.display_name, null);
  end if;
  if new.commission_pct is distinct from old.commission_pct then
    perform public._audit('Changed photographer commission', 'photographer', new.id::text, new.display_name,
      jsonb_build_object('from', old.commission_pct, 'to', new.commission_pct));
  end if;
  return new;
end $$;
drop trigger if exists audit_photographers on public.photographers;
create trigger audit_photographers after update on public.photographers for each row execute function public.audit_photographers();

create or replace function public.audit_settings()
returns trigger language plpgsql security definer set search_path = public
as $$
begin
  perform public._audit('Changed setting: ' || new.key, 'setting', new.key, new.key,
    jsonb_build_object('from', case when tg_op = 'UPDATE' then old.value end, 'to', new.value));
  return new;
end $$;
drop trigger if exists audit_settings on public.platform_settings;
create trigger audit_settings after insert or update on public.platform_settings for each row execute function public.audit_settings();

create or replace function public.audit_offers()
returns trigger language plpgsql security definer set search_path = public
as $$
begin
  perform public._audit(case when tg_op = 'INSERT' then 'Created offer' when new.active is distinct from old.active then (case when new.active then 'Made offer live' else 'Paused offer' end) else 'Edited offer' end,
    'offer', new.id::text, new.title, jsonb_build_object('kind', new.kind, 'amount', new.amount, 'code', new.code, 'audience', new.audience));
  return new;
end $$;
drop trigger if exists audit_offers on public.promo_offers;
create trigger audit_offers after insert or update on public.promo_offers for each row execute function public.audit_offers();

create or replace function public.audit_benefits()
returns trigger language plpgsql security definer set search_path = public
as $$
begin
  if new.source = 'admin' then
    perform public._audit('Gave reward', 'user', new.user_id::text, (select coalesce(public_id || ' ', '') || coalesce(name,'') from public.profiles where id = new.user_id),
      jsonb_build_object('title', new.title, 'kind', new.kind, 'amount', new.amount));
  end if;
  return new;
end $$;
drop trigger if exists audit_benefits on public.user_benefits;
create trigger audit_benefits after insert on public.user_benefits for each row execute function public.audit_benefits();

create or replace function public.audit_bookings()
returns trigger language plpgsql security definer set search_path = public
as $$
begin
  if new.payout_status = 'paid' and old.payout_status is distinct from 'paid' then
    perform public._audit('Recorded payout', 'booking', new.id::text, 'SP-' || upper(left(new.id::text, 8)) || ' · ' || coalesce(new.photographer_name,''),
      jsonb_build_object('amount', new.photographer_amount, 'reference', new.payout_ref));
  end if;
  return new;
end $$;
drop trigger if exists audit_bookings on public.bookings;
create trigger audit_bookings after update on public.bookings for each row execute function public.audit_bookings();

create or replace function public.audit_refunds()
returns trigger language plpgsql security definer set search_path = public
as $$
begin
  perform public._audit('Started refund', 'payment', new.payment_id::text, new.order_id,
    jsonb_build_object('amount', new.amount, 'reason', new.reason), new.requested_by);
  return new;
end $$;
drop trigger if exists audit_refunds on public.refunds;
create trigger audit_refunds after insert on public.refunds for each row execute function public.audit_refunds();

create or replace function public.audit_staff()
returns trigger language plpgsql security definer set search_path = public
as $$
begin
  if tg_table_name = 'staff' then
    if tg_op = 'DELETE' then perform public._audit('Removed staff member', 'staff', old.id::text, old.email, jsonb_build_object('role', old.role)); return old; end if;
    if tg_op = 'UPDATE' and (new.role is distinct from old.role or new.status is distinct from old.status) then
      perform public._audit(case when new.status is distinct from old.status then (case when new.status = 'suspended' then 'Suspended staff member' else 'Restored staff member' end) else 'Changed staff role' end,
        'staff', new.id::text, new.email, jsonb_build_object('from', old.role, 'to', new.role, 'status', new.status));
    end if;
    return new;
  else
    if tg_op = 'DELETE' then perform public._audit('Cancelled staff invite', 'invite', old.id::text, old.email, null); return old; end if;
    if tg_op = 'INSERT' then perform public._audit('Invited staff member', 'invite', new.id::text, new.email, jsonb_build_object('role', new.role)); end if;
    return new;
  end if;
end $$;
drop trigger if exists audit_staff on public.staff;
create trigger audit_staff after update or delete on public.staff for each row execute function public.audit_staff();
drop trigger if exists audit_invites on public.staff_invites;
create trigger audit_invites after insert or delete on public.staff_invites for each row execute function public.audit_staff();

create or replace function public.admin_audit_log(p_from date default null, p_to date default null, p_limit int default 2000)
returns setof public.admin_audit language plpgsql stable security definer set search_path = public
as $$ begin
  return query select * from public.admin_audit
       where coalesce(public.staff_role() in ('super_admin','admin'), false)
         and (p_from is null or (at at time zone 'Asia/Kolkata')::date >= p_from) and (p_to is null or (at at time zone 'Asia/Kolkata')::date <= p_to)
       order by at desc limit greatest(1, least(p_limit, 10000));
end $$;

-- ---------- suspend / block accounts ----------
alter table public.profiles
  add column if not exists status        text not null default 'active',
  add column if not exists status_reason text,
  add column if not exists status_until  timestamptz,
  add column if not exists status_by     uuid,
  add column if not exists status_at     timestamptz;
do $$ begin
  alter table public.profiles add constraint profiles_status_check check (status in ('active','suspended','blocked'));
exception when duplicate_object then null; end $$;

-- people can't change their own status (extends the SnapPro ID guard)
create or replace function public.profile_status_guard()
returns trigger language plpgsql
as $$
begin
  if public.snappro_system() then return new; end if;
  if tg_op = 'INSERT' then new.status := 'active'; new.status_reason := null; new.status_until := null; new.status_by := null; new.status_at := null;
  else new.status := old.status; new.status_reason := old.status_reason; new.status_until := old.status_until; new.status_by := old.status_by; new.status_at := old.status_at; end if;
  return new;
end $$;
drop trigger if exists profile_status_guard on public.profiles;
create trigger profile_status_guard before insert or update on public.profiles for each row execute function public.profile_status_guard();

create or replace function public.is_blocked(p_user uuid)
returns boolean language sql stable security definer set search_path = public
as $$ select exists (select 1 from public.profiles where id = p_user and status in ('suspended','blocked')
                       and (status = 'blocked' or status_until is null or status_until > now())) $$;
-- (who can see open requests is set in 8f, once blocking between people exists)
create or replace function public._check_not_blocked()
returns void language plpgsql stable security definer set search_path = public
as $$ begin
  if public.is_blocked(auth.uid()) then raise exception 'Your account is suspended. Contact snappro.support@gmail.com if you think this is a mistake.'; end if;
end $$;

-- every way of acting on SnapPro checks the account first
create or replace function public.block_guard()
returns trigger language plpgsql security definer set search_path = public
as $$ begin
  perform public._check_not_blocked();
  if tg_table_name = 'bookings' then
    if public.is_blocked((select photographer_id from public.offers where id = (to_jsonb(new)->>'offer_id')::uuid)) then
      raise exception 'This photographer isn''t available any more. Please pick another quote.';
    end if;
  end if;
  return new;
end $$;
drop trigger if exists block_guard on public.requests;
create trigger block_guard before insert on public.requests for each row execute function public.block_guard();
drop trigger if exists block_guard on public.offers;
create trigger block_guard before insert on public.offers for each row execute function public.block_guard();
drop trigger if exists block_guard on public.bookings;
create trigger block_guard before insert on public.bookings for each row execute function public.block_guard();
drop trigger if exists block_guard on public.messages;
create trigger block_guard before insert on public.messages for each row execute function public.block_guard();
drop trigger if exists block_guard on public.reviews;
create trigger block_guard before insert on public.reviews for each row execute function public.block_guard();

-- suspended photographers disappear from search
drop policy if exists photographers_select_all on public.photographers;
create policy photographers_select_all on public.photographers for select
  using ((approval_status = 'approved' and not public.is_blocked(id)) or id = auth.uid() or public.is_staff());

create or replace function public.admin_set_user_status(p_user uuid, p_status text, p_reason text default null, p_days int default null)
returns text language plpgsql security definer set search_path = public
as $$
declare nm text;
begin
  if coalesce(public.staff_role() in ('super_admin','admin'), false) is not true then raise exception 'Only admins can suspend accounts'; end if;
  if p_status not in ('active','suspended','blocked') then raise exception 'Unknown status'; end if;
  if exists (select 1 from public.staff where id = p_user) then raise exception 'Use the Team tab for staff accounts'; end if;
  if p_status <> 'active' and coalesce(trim(p_reason),'') = '' then raise exception 'Add a reason'; end if;
  perform set_config('snappro.system', 'on', true);
  update public.profiles set status = p_status, status_reason = case when p_status = 'active' then null else left(trim(p_reason), 300) end,
         status_until = case when p_status = 'suspended' and p_days is not null then now() + make_interval(days => p_days) end,
         status_by = auth.uid(), status_at = now()
   where id = p_user returning coalesce(public_id || ' ', '') || coalesce(name, '') into nm;
  perform set_config('snappro.system', '', true);
  if nm is null then raise exception 'Account not found'; end if;
  perform public._audit(case p_status when 'active' then 'Restored account' when 'blocked' then 'Blocked account' else 'Suspended account' end,
    'user', p_user::text, nm, jsonb_build_object('reason', p_reason, 'days', p_days));
  return p_status;
end $$;

-- the app asks this at start-up to show a "suspended" screen
create or replace function public.my_status()
returns jsonb language sql stable security definer set search_path = public
as $$ select jsonb_build_object('status', case when public.is_blocked(id) then status else 'active' end,
                                'reason', status_reason, 'until', status_until)
       from public.profiles where id = auth.uid() $$;

-- ---------- staff reading a booking's chat (for disputes / fraud) ----------
create or replace function public.admin_chat(p_booking uuid)
returns jsonb language plpgsql security definer set search_path = public
as $$
declare b record;
begin
  if coalesce(public.staff_role() in ('super_admin','admin'), false) is not true then raise exception 'Only admins can read chats'; end if;
  select * into b from public.bookings where id = p_booking;
  if not found then raise exception 'Booking not found'; end if;
  perform public._audit('Opened chat', 'booking', b.id::text, 'SP-' || upper(left(b.id::text, 8)) || ' · ' || coalesce(b.customer_name,'') || ' ↔ ' || coalesce(b.photographer_name,''), null);
  return jsonb_build_object('customer_id', b.customer_id, 'photographer_id', b.photographer_id,
    'customer', b.customer_name, 'photographer', b.photographer_name,
    'messages', (select coalesce(jsonb_agg(jsonb_build_object('at', m.created_at, 'from',
                   case when m.sender_id = b.customer_id then 'customer' when m.sender_id = b.photographer_id then 'photographer' else 'other' end,
                   'text', m.content) order by m.created_at), '[]') from public.messages m where m.booking_id = b.id));
end $$;

-- ---------- photographer ID check (government ID + face photo) ----------
create table if not exists public.photographer_kyc (
  id           uuid primary key references public.photographers(id) on delete cascade,
  id_type      text check (id_type in ('aadhaar','pan','driving_licence','passport')),
  id_last4     text,
  front_path   text,
  back_path    text,
  selfie_path  text,
  status       text not null default 'not_submitted' check (status in ('not_submitted','submitted','verified','rejected')),
  note         text,
  submitted_at timestamptz,
  reviewed_by  uuid,
  reviewed_at  timestamptz
);
alter table public.photographer_kyc enable row level security;
drop policy if exists kyc_own_read on public.photographer_kyc;
create policy kyc_own_read on public.photographer_kyc for select to authenticated
  using (id = auth.uid() or coalesce(public.staff_role() in ('super_admin','admin'), false));
revoke insert, update, delete on public.photographer_kyc from anon, authenticated;

-- private bucket: photographers upload into their own folder; only admins can open the files
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('kyc', 'kyc', false, 5242880, array['image/jpeg','image/png','image/webp'])
on conflict (id) do update set public = false, file_size_limit = 5242880, allowed_mime_types = array['image/jpeg','image/png','image/webp'];
drop policy if exists "snappro kyc upload own" on storage.objects;
create policy "snappro kyc upload own" on storage.objects for insert to authenticated
  with check (bucket_id = 'kyc' and (storage.foldername(name))[1] = auth.uid()::text);
drop policy if exists "snappro kyc admin read" on storage.objects;
create policy "snappro kyc admin read" on storage.objects for select to authenticated
  using (bucket_id = 'kyc' and coalesce(public.staff_role() in ('super_admin','admin'), false));

create or replace function public.submit_kyc(p_type text, p_last4 text, p_front text, p_back text, p_selfie text)
returns text language plpgsql security definer set search_path = public
as $$
declare me uuid := auth.uid(); pre text := me::text || '/';
begin
  if not exists (select 1 from public.photographers where id = me) then raise exception 'Only photographers verify their ID'; end if;
  perform public._check_not_blocked();
  if p_type not in ('aadhaar','pan','driving_licence','passport') then raise exception 'Choose your ID type'; end if;
  if p_front is null or left(p_front, length(pre)) <> pre or p_selfie is null or left(p_selfie, length(pre)) <> pre then raise exception 'Add the ID photo and your face photo'; end if;
  if p_type <> 'pan' and (p_back is null or left(p_back, length(pre)) <> pre) then raise exception 'Add the back of your ID too'; end if;
  if p_last4 is not null and p_last4 !~ '^[A-Za-z0-9]{4}$' then raise exception 'Enter the last 4 characters of the ID number'; end if;
  insert into public.photographer_kyc (id, id_type, id_last4, front_path, back_path, selfie_path, status, note, submitted_at, reviewed_by, reviewed_at)
  values (me, p_type, upper(p_last4), p_front, p_back, p_selfie, 'submitted', null, now(), null, null)
  on conflict (id) do update set id_type = excluded.id_type, id_last4 = excluded.id_last4, front_path = excluded.front_path,
     back_path = excluded.back_path, selfie_path = excluded.selfie_path, status = 'submitted', note = null,
     submitted_at = now(), reviewed_by = null, reviewed_at = null;
  return 'submitted';
end $$;

create or replace function public.kyc_review(p_pg uuid, p_status text, p_note text default null)
returns text language plpgsql security definer set search_path = public
as $$
declare k record; nm text; em text;
begin
  if coalesce(public.staff_role() in ('super_admin','admin'), false) is not true then raise exception 'Only admins can review IDs'; end if;
  if p_status not in ('verified','rejected') then raise exception 'Unknown status'; end if;
  if p_status = 'rejected' and coalesce(trim(p_note),'') = '' then raise exception 'Say what needs re-doing (e.g. the photo is blurry)'; end if;
  update public.photographer_kyc set status = p_status, note = case when p_status = 'rejected' then left(trim(p_note), 300) end,
         reviewed_by = auth.uid(), reviewed_at = now() where id = p_pg returning * into k;
  if not found then raise exception 'No ID submitted yet'; end if;
  select display_name into nm from public.photographers where id = p_pg;
  perform public._audit(case when p_status = 'verified' then 'Verified photographer ID' else 'Asked for new ID photos' end, 'photographer', p_pg::text, nm,
    jsonb_build_object('id_type', k.id_type, 'note', p_note));
  if p_status = 'rejected' then
    select email into em from auth.users where id = p_pg;
    begin
      perform public._send_email(em, 'Please re-do your SnapPro ID check',
        public._email_shell('One more step, ' || public._esc(split_part(coalesce(nm,''),' ',1)) || '.',
          'We couldn''t verify your ID: ' || public._esc(p_note) || ' Please open SnapPro and capture your ID and face photo again.',
          'Open SnapPro', 'https://snappro.in/app.html#login'));
    exception when others then null; end;
  end if;
  return p_status;
end $$;

-- ---------- in-app voice calls ----------
-- each booking gets a secret channel name; only the two people on it can read it
alter table public.bookings add column if not exists call_token uuid not null default gen_random_uuid();
insert into public.platform_settings (key, value) values ('call_ice_servers',
  '[{"urls":["stun:stun.l.google.com:19302","stun:stun1.l.google.com:19302"]}]') on conflict (key) do nothing;
-- ICE servers (STUN/TURN) for people with a live booking — not public
create or replace function public.call_config()
returns jsonb language sql stable security definer set search_path = public
as $$ select case when exists (select 1 from public.bookings b where (b.customer_id = auth.uid() or b.photographer_id = auth.uid())
                                  and b.status in ('confirmed','enroute','arrived','shooting','completed'))
                  then (select value from public.platform_settings where key = 'call_ice_servers') end $$;
-- keep TURN passwords out of the public settings read
drop policy if exists settings_read on public.platform_settings;
create policy settings_read on public.platform_settings for select using (key <> 'call_ice_servers');
drop policy if exists settings_staff_read on public.platform_settings;
create policy settings_staff_read on public.platform_settings for select to authenticated using (public.is_staff());
-- (the private call channel rules are set in 8f, once blocking between people exists)

revoke all on function public.admin_audit_log(date, date, int)   from public, anon;
revoke all on function public.admin_set_user_status(uuid, text, text, int) from public, anon;
revoke all on function public.my_status()                        from public, anon;
revoke all on function public.admin_chat(uuid)                   from public, anon;
revoke all on function public.submit_kyc(text, text, text, text, text) from public, anon;
revoke all on function public.kyc_review(uuid, text, text)       from public, anon;
revoke all on function public.call_config()                      from public, anon;
grant execute on function public.admin_audit_log(date, date, int)   to authenticated;
grant execute on function public.admin_set_user_status(uuid, text, text, int) to authenticated;
grant execute on function public.my_status()                        to authenticated;
grant execute on function public.admin_chat(uuid)                   to authenticated;
grant execute on function public.submit_kyc(text, text, text, text, text) to authenticated;
grant execute on function public.kyc_review(uuid, text, text)       to authenticated;
grant execute on function public.call_config()                      to authenticated;

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
              is_verified boolean, is_online boolean, photos int, approval_status text, public_id text, commission_pct numeric,
              account_status text, status_reason text, status_until timestamptz, kyc_status text)
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
         coalesce(array_length(g.portfolio,1), 0), g.approval_status, p.public_id, g.commission_pct,
         case when public.is_blocked(u.id) then p.status else 'active' end, p.status_reason, p.status_until,
         (select k.status from public.photographer_kyc k where k.id = u.id)
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
-- 8c. ADMIN DRILL-DOWNS AND REPORTS
--     Every number on the admin overview can be opened to see the rows
--     behind it. Staff only. Managers never see money, emails or phones.
--     Chat message text is never shown — only how many were sent.
-- =====================================================================

-- The rows behind one number. p_arg narrows some lists (a city, a shoot type…).
create or replace function public.admin_detail(p_kind text, p_from date default null, p_to date default null, p_arg text default null)
returns jsonb language plpgsql stable security definer set search_path = public
as $$
declare
  money boolean := coalesce(public.staff_role() in ('super_admin','admin'), false);
  f date := coalesce(p_from, '2000-01-01'::date);
  t date := coalesce(p_to, public._ist(now()));
  res jsonb;
begin
  if not public.is_staff() then raise exception 'Staff only'; end if;
  if not money and p_kind in ('payouts_paid','booking_value','collected','commission','payouts_due','refunds_due','refunds',
                              'payments_failed','balances_due','customers','top_customers','signups',
                              'signups_customers','signups_photographers','repeat_customers','setup_incomplete') then
    raise exception 'Only admins can see this';
  end if;

  if p_kind in ('visitors','visitors_today','referrer','device') then
    select coalesce(jsonb_agg(to_jsonb(z) order by z.last_at desc), '[]') into res from (
      select s.day, s.first_at, s.last_at, s.views, s.device, s.path, coalesce(nullif(s.referrer,''),'Direct') as referrer,
             p.name as signed_in_as, p.role
        from public.site_visits s left join public.profiles p on p.id = s.user_id
       where (case when p_kind = 'visitors_today' then s.day = public._ist(now()) else s.day between f and t end)
         and (p_kind <> 'referrer' or coalesce(nullif(s.referrer,''),'Direct') = p_arg)
         and (p_kind <> 'device' or s.device = p_arg)
       order by s.last_at desc limit 2000) z;

  elsif p_kind = 'returning_visitors' then
    select coalesce(jsonb_agg(to_jsonb(z) order by z.days desc), '[]') into res from (
      select count(*)::int as days, sum(s.views)::int as views, min(s.day) as first_day, max(s.day) as last_day,
             max(p.name) as signed_in_as
        from public.site_visits s left join public.profiles p on p.id = s.user_id
       where s.day between f and t group by s.visitor_id having count(*) > 1 limit 2000) z;

  elsif p_kind in ('available_pgs','photographers','pending_pgs','pgs_with_photos','pgs_verified','pgs_city') then
    select coalesce(jsonb_agg(to_jsonb(z) order by z.jobs_done desc, z.name), '[]') into res from (
      select g.id, pr.public_id as snappro_id, g.display_name as name, case when money then u.email end as email, case when money then pr.phone end as phone,
             g.city, g.state, array_to_string(g.categories, ', ') as shoot_types, g.approval_status as approval,
             g.is_online as available, g.is_verified as verified, g.jobs_done, g.rating, g.review_count as reviews,
             coalesce(g.commission_pct, public.commission_pct()) as commission_pct,
             coalesce(array_length(g.portfolio,1),0) as photos, case when money then g.earnings end as earnings,
             (select count(*) from public.offers o where o.photographer_id = g.id)::int as quotes_sent,
             g.created_at as joined, g.approved_at
        from public.photographers g left join auth.users u on u.id = g.id left join public.profiles pr on pr.id = g.id
       where case p_kind when 'available_pgs' then g.is_online and g.approval_status = 'approved'
                         when 'pending_pgs' then g.approval_status = 'pending'
                         when 'pgs_with_photos' then coalesce(array_length(g.portfolio,1),0) > 0
                         when 'pgs_verified' then g.is_verified
                         when 'pgs_city' then lower(coalesce(g.city,'')) = lower(coalesce(p_arg,''))
                         else true end
       limit 2000) z;

  elsif p_kind in ('requests','requests_quoted','requests_booked','open_requests','city','category') then
    select coalesce(jsonb_agg(to_jsonb(z) order by z.posted desc), '[]') into res from (
      select r.id, r.created_at as posted, r.customer_name as customer, r.category, r.city, r.pincode, r.start_at as shoot_time,
             r.duration_hrs as hours, r.budget, r.status, r.expires_at as closes,
             (select count(*) from public.offers o where o.request_id = r.id)::int as quotes,
             (select round(extract(epoch from min(o.created_at) - r.created_at) / 60) from public.offers o where o.request_id = r.id) as first_quote_min,
             (select min(o.price) from public.offers o where o.request_id = r.id) as lowest_quote,
             (select b.price from public.bookings b where b.request_id = r.id and b.status <> 'cancelled' limit 1) as booked_price
        from public.requests r
       where case when p_kind = 'open_requests' then r.status = 'broadcasting' and r.expires_at > now()
                  else public._ist(r.created_at) between f and t end
         and (p_kind <> 'requests_quoted' or exists (select 1 from public.offers o where o.request_id = r.id))
         and (p_kind <> 'requests_booked' or r.status = 'matched')
         and (p_kind <> 'city' or lower(coalesce(r.city,'')) = lower(coalesce(p_arg,'')))
         and (p_kind <> 'category' or r.category = p_arg)
       limit 2000) z;

  elsif p_kind = 'quotes' then
    select coalesce(jsonb_agg(to_jsonb(z) order by z.sent desc), '[]') into res from (
      select o.created_at as sent, o.photographer_name as photographer, r.customer_name as customer, r.category, r.city,
             o.price, r.budget, round(extract(epoch from o.created_at - r.created_at) / 60) as minutes_after_post,
             case when exists (select 1 from public.bookings b where b.offer_id = o.id and b.status not in ('cancelled','pending_payment')) then 'booked'
                  when exists (select 1 from public.bookings b where b.offer_id = o.id and b.status = 'pending_payment') then 'chosen, unpaid'
                  when r.status in ('broadcasting','awaiting') then 'open' else 'not chosen' end as outcome
        from public.offers o join public.requests r on r.id = o.request_id
       where public._ist(o.created_at) between f and t limit 2000) z;

  elsif p_kind in ('bookings','completed','cancelled','booking_value','upcoming_shoots','balances_due','payouts_due','payouts_paid','status') then
    select coalesce(jsonb_agg(to_jsonb(z) order by z.shoot_time desc), '[]') into res from (
      select b.id, b.created_at as booked_at, b.start_at as shoot_time, b.customer_name as customer, b.photographer_name as photographer,
             b.category, b.city, b.status, b.cancelled_by, b.cancelled_from,
             case when money then b.price end as price,
             case when money then b.payment_status end as payment,
             case when money then b.balance_status end as balance,
             case when money then b.commission_amount end as commission,
             case when money then b.photographer_amount end as photographer_share,
             case when money then b.payout_status end as payout,
             case when money and p_kind = 'payouts_paid' then b.payout_ref end as payout_ref,
             case when money and p_kind = 'payouts_paid' then b.payout_at end as paid_out_at,
             case when money and p_kind = 'payouts_due' then (select x.upi_id from public.photographer_payout x where x.id = b.photographer_id) end as pay_to_upi,
             (select count(*) from public.messages m where m.booking_id = b.id)::int as messages,
             (select v.stars from public.reviews v where v.booking_id = b.id) as rating
        from public.bookings b
       where case p_kind
               when 'upcoming_shoots' then b.status in ('confirmed','enroute','arrived','shooting')
               when 'balances_due'    then b.balance_status = 'due'
               when 'payouts_due'     then b.payout_status = 'due'
               when 'payouts_paid'    then b.payout_status = 'paid' and public._ist(b.payout_at) between f and t
               else public._ist(b.created_at) between f and t end
         and (p_kind <> 'completed' or b.status = 'completed')
         and (p_kind <> 'cancelled' or b.status = 'cancelled')
         and (p_kind <> 'booking_value' or b.status <> 'cancelled')
         and (p_kind <> 'status' or b.status = p_arg)
       limit 2000) z;

  elsif p_kind in ('collected','commission','payments_failed','refunds_due','method') then
    select coalesce(jsonb_agg(to_jsonb(z) order by z.at desc), '[]') into res from (
      select coalesce(p.paid_at, p.created_at) as at, p.order_id, p.booking_id, b.customer_name as customer, b.photographer_name as photographer,
             p.stage, p.amount, p.commission_amount as commission, p.photographer_amount as photographer_share,
             p.payment_group as method, p.status, p.refund_status as refund, p.refunded_amount as refunded,
             p.gateway_payment_id as razorpay_id, p.environment, p.note
        from public.payments p left join public.bookings b on b.id = p.booking_id
       where case p_kind
               when 'refunds_due' then p.refund_status in ('refund_due','refund_failed')
               when 'payments_failed' then p.status in ('failed','user_dropped') and public._ist(p.created_at) between f and t
               else p.status = 'paid' and public._ist(p.paid_at) between f and t end
         and (p_kind <> 'commission' or (not p.is_duplicate and p.refund_status = 'none'))
         and (p_kind <> 'method' or coalesce(p.payment_group,'other') = p_arg)
       limit 2000) z;

  elsif p_kind = 'refunds' then
    select coalesce(jsonb_agg(to_jsonb(z) order by z.requested desc), '[]') into res from (
      select r.created_at as requested, r.processed_at as done, r.amount, r.status, r.reason, b.customer_name as customer,
             b.photographer_name as photographer, s.email as started_by, r.gateway_refund_id as razorpay_refund, r.refund_arn as arn
        from public.refunds r join public.payments p on p.id = r.payment_id left join public.bookings b on b.id = p.booking_id
        left join public.staff s on s.id = r.requested_by
       where public._ist(r.created_at) between f and t limit 2000) z;

  elsif p_kind in ('signups','signups_customers','signups_photographers','customers','repeat_customers','setup_incomplete','top_customers') then
    select coalesce(jsonb_agg(to_jsonb(z) order by z.joined desc), '[]') into res from (
      select pr.public_id as snappro_id, pr.name, u.email, coalesce(pr.phone, u.phone) as phone, pr.role, pr.city, pr.state, pr.pincode,
             coalesce(pr.created_at, u.created_at) as joined, u.last_sign_in_at as last_sign_in, (u.email_confirmed_at is not null) as email_confirmed,
             (select count(*) from public.requests q where q.customer_id = pr.id)::int as requests,
             (select count(*) from public.bookings b where b.customer_id = pr.id and b.status <> 'cancelled')::int as bookings,
             (select coalesce(sum(p.amount),0) from public.payments p where p.customer_id = pr.id and p.status = 'paid'
                 and p.refund_status not in ('refunded')) as paid_online
        from public.profiles pr join auth.users u on u.id = pr.id
       where not exists (select 1 from public.staff st where st.id = pr.id)
         and case p_kind
               when 'signups' then public._ist(pr.created_at) between f and t
               when 'signups_customers' then pr.role = 'customer' and public._ist(pr.created_at) between f and t
               when 'signups_photographers' then pr.role = 'photographer' and public._ist(pr.created_at) between f and t
               when 'customers' then pr.role = 'customer'
               when 'top_customers' then pr.role = 'customer'
               when 'repeat_customers' then (select count(*) from public.bookings b where b.customer_id = pr.id and b.status <> 'cancelled') > 1
               when 'setup_incomplete' then pr.city is null or pr.pincode is null
               else true end
       limit 2000) z;

  elsif p_kind = 'reviews' then
    select coalesce(jsonb_agg(to_jsonb(z) order by z.posted desc), '[]') into res from (
      select v.created_at as posted, v.customer_name as customer, g.display_name as photographer, v.stars, v.body as comment, b.category
        from public.reviews v left join public.photographers g on g.id = v.photographer_id left join public.bookings b on b.id = v.booking_id
       where public._ist(v.created_at) between f and t and (p_arg is null or v.stars = p_arg::int) limit 2000) z;

  elsif p_kind = 'messages' then
    select coalesce(jsonb_agg(to_jsonb(z) order by z.last_message desc), '[]') into res from (
      select b.id as booking_id, b.customer_name as customer, b.photographer_name as photographer, b.category, b.status,
             count(m.*)::int as messages, count(*) filter (where m.sender_id = b.customer_id)::int as from_customer,
             count(*) filter (where m.sender_id = b.photographer_id)::int as from_photographer, max(m.created_at) as last_message
        from public.messages m join public.bookings b on b.id = m.booking_id
       where public._ist(m.created_at) between f and t group by b.id limit 2000) z;

  else
    raise exception 'Unknown report %', p_kind;
  end if;
  return res;
end $$;

-- Everything about one booking, for the booking detail panel.
create or replace function public.admin_booking(p_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public
as $$
declare money boolean := coalesce(public.staff_role() in ('super_admin','admin'), false); b public.bookings; res jsonb;
begin
  if not public.is_staff() then raise exception 'Staff only'; end if;
  select * into b from public.bookings where id = p_id;
  if not found then raise exception 'Booking not found'; end if;
  res := jsonb_build_object(
    'booking', to_jsonb(b) - case when money then '{}'::text[] else array['price','total_amount','payout_amount','commission_amount',
              'photographer_amount','payment_status','payout_ref','payout_by','commission_pct','advance_amount','balance_amount'] end,
    'request', (select to_jsonb(r) from public.requests r where r.id = b.request_id),
    'quotes', (select coalesce(jsonb_agg(jsonb_build_object('photographer', o.photographer_name, 'price', o.price, 'sent', o.created_at,
                 'chosen', o.id = b.offer_id) order by o.created_at), '[]') from public.offers o where o.request_id = b.request_id),
    'messages', (select count(*) from public.messages m where m.booking_id = b.id),
    'last_message', (select max(created_at) from public.messages m where m.booking_id = b.id),
    'review', (select jsonb_build_object('stars', v.stars, 'comment', v.body, 'posted', v.created_at) from public.reviews v where v.booking_id = b.id),
    'customer', (select jsonb_build_object('name', pr.name, 'id', pr.public_id, 'email', case when money then pr.email end, 'phone', case when money then pr.phone end)
                   from public.profiles pr where pr.id = b.customer_id),
    'photographer', (select jsonb_build_object('name', g.display_name, 'id', (select public_id from public.profiles where id = g.id), 'email', case when money then u.email end,
                       'upi', case when money then x.upi_id end, 'rating', g.rating, 'jobs', g.jobs_done)
                   from public.photographers g left join auth.users u on u.id = g.id left join public.photographer_payout x on x.id = g.id where g.id = b.photographer_id),
    'payments', case when money then (select coalesce(jsonb_agg(jsonb_build_object('stage', p.stage, 'amount', p.amount, 'status', p.status,
                   'method', p.payment_group, 'at', coalesce(p.paid_at, p.created_at), 'razorpay_id', p.gateway_payment_id,
                   'refund', p.refund_status, 'refunded', p.refunded_amount) order by p.created_at), '[]')
                   from public.payments p where p.booking_id = b.id) end
  );
  return res;
end $$;

-- Charts and breakdowns for a date range.
create or replace function public.admin_report(p_from date, p_to date, p_bucket text default 'day')
returns jsonb language plpgsql stable security definer set search_path = public
as $$
declare money boolean := coalesce(public.staff_role() in ('super_admin','admin'), false); res jsonb;
begin
  if not public.is_staff() then return null; end if;
  if p_bucket not in ('day','week','month','year') then raise exception 'Unknown period'; end if;
  with
  req as (select * from public.requests where public._ist(created_at) between p_from and p_to),
  bk  as (select * from public.bookings where public._ist(created_at) between p_from and p_to),
  pay as (select * from public.payments where status = 'paid' and public._ist(paid_at) between p_from and p_to),
  buckets as (select g::date as bk from generate_series(date_trunc(p_bucket, p_from::timestamp), date_trunc(p_bucket, p_to::timestamp), ('1 ' || p_bucket)::interval) g)
  select jsonb_build_object(
    'funnel', jsonb_build_object(
      'visitors',   (select count(distinct visitor_id) from public.site_visits where day between p_from and p_to),
      'signups',    (select count(*) from public.profiles pr where public._ist(pr.created_at) between p_from and p_to
                       and not exists (select 1 from public.staff st where st.id = pr.id)),
      'requests',   (select count(*) from req),
      'quoted',     (select count(*) from req where exists (select 1 from public.offers o where o.request_id = req.id)),
      'chosen',     (select count(distinct request_id) from public.bookings b where b.request_id in (select id from req)),
      'paid',       (select count(distinct request_id) from public.bookings b where b.request_id in (select id from req)
                       and b.payment_status in ('paid','refund_due','refund_pending','refunded','partially_refunded','not_required')),
      'completed',  (select count(*) from public.bookings b where b.request_id in (select id from req) and b.status = 'completed'),
      'reviewed',   (select count(*) from public.reviews v join public.bookings b on b.id = v.booking_id where b.request_id in (select id from req))),
    'by_status',  (select coalesce(jsonb_agg(z order by z.n desc), '[]') from (select status, count(*) n from bk group by 1) z),
    'cancellations', (select coalesce(jsonb_agg(z order by z.n desc), '[]') from
                      (select coalesce(cancelled_by,'unknown') as by, coalesce(cancelled_from,'unknown') as stage, count(*) n
                         from bk where status = 'cancelled' group by 1,2) z),
    'categories', (select coalesce(jsonb_agg(z order by z.requests desc), '[]') from
                   (select r.category, count(*) requests,
                           count(*) filter (where exists (select 1 from public.offers o where o.request_id = r.id)) quoted,
                           count(*) filter (where r.status = 'matched') booked,
                           round(avg(r.budget)) avg_budget,
                           case when money then (select coalesce(sum(b.price),0) from public.bookings b where b.request_id in
                             (select id from req r2 where r2.category = r.category) and b.status <> 'cancelled') end as value
                      from req r group by r.category) z),
    'cities',     (select coalesce(jsonb_agg(z order by z.requests desc), '[]') from
                   (select coalesce(r.city,'—') city, count(*) requests,
                           count(*) filter (where r.status = 'matched') booked,
                           count(*) filter (where not exists (select 1 from public.offers o where o.request_id = r.id)) no_quote,
                           (select count(*) from public.photographers g where lower(coalesce(g.city,'')) = lower(coalesce(r.city,'')) and g.approval_status = 'approved') photographers,
                           case when money then (select coalesce(sum(b.price),0) from public.bookings b where b.request_id in
                             (select id from req r2 where coalesce(r2.city,'—') = coalesce(r.city,'—')) and b.status <> 'cancelled') end as value
                      from req r group by coalesce(r.city,'—'), r.city) z),
    'by_hour',    (select coalesce(jsonb_agg(z order by z.h), '[]') from
                   (select extract(hour from start_at at time zone 'Asia/Kolkata')::int h, count(*) n from req where start_at is not null group by 1) z),
    'by_weekday', (select coalesce(jsonb_agg(z order by z.d), '[]') from
                   (select extract(isodow from start_at at time zone 'Asia/Kolkata')::int d, count(*) n from req where start_at is not null group by 1) z),
    'quote_speed', (select coalesce(jsonb_agg(z order by z.o), '[]') from
                   (select case when m is null then 5 when m < 15 then 1 when m < 60 then 2 when m < 180 then 3 else 4 end o,
                           case when m is null then 'No quote' when m < 15 then 'Under 15 min' when m < 60 then '15–60 min'
                                when m < 180 then '1–3 hours' else 'Over 3 hours' end label, count(*) n
                      from (select (select extract(epoch from min(o.created_at) - r.created_at) / 60 from public.offers o where o.request_id = r.id) m from req r) q
                     group by 1,2) z),
    'prices',     jsonb_build_object(
                    'avg_budget', (select round(avg(budget)) from req),
                    'avg_quote',  (select round(avg(o.price)) from public.offers o where public._ist(o.created_at) between p_from and p_to),
                    'avg_booked', case when money then (select round(avg(price)) from bk where status <> 'cancelled') end,
                    'quotes_over_budget', (select count(*) from public.offers o join public.requests r on r.id = o.request_id
                                             where public._ist(o.created_at) between p_from and p_to and o.price > r.budget),
                    'quotes', (select count(*) from public.offers o where public._ist(o.created_at) between p_from and p_to)),
    'devices',    (select coalesce(jsonb_agg(z order by z.n desc), '[]') from
                   (select coalesce(device,'unknown') device, count(distinct visitor_id) n from public.site_visits where day between p_from and p_to group by 1) z),
    'pages',      (select coalesce(jsonb_agg(z order by z.n desc), '[]') from
                   (select coalesce(nullif(path,''),'/') path, sum(views)::int n from public.site_visits where day between p_from and p_to group by 1 order by 2 desc limit 10) z),
    'ratings',    (select coalesce(jsonb_agg(z order by z.stars desc), '[]') from
                   (select stars, count(*) n from public.reviews where public._ist(created_at) between p_from and p_to group by 1) z),
    'top_photographers', (select coalesce(jsonb_agg(z order by z.completed desc, z.quotes desc), '[]') from
                   (select g.display_name as name, g.city,
                           (select count(*) from public.offers o where o.photographer_id = g.id and public._ist(o.created_at) between p_from and p_to) quotes,
                           (select count(*) from bk where bk.photographer_id = g.id and bk.status <> 'cancelled') booked,
                           (select count(*) from bk where bk.photographer_id = g.id and bk.status = 'completed') completed,
                           case when money then (select coalesce(sum(bk.photographer_amount),0) from bk where bk.photographer_id = g.id and bk.status = 'completed') end earned,
                           g.rating, g.review_count reviews
                      from public.photographers g where g.approval_status = 'approved' order by 4 desc, 3 desc limit 15) z),
    'top_customers', case when money then (select coalesce(jsonb_agg(z order by z.spent desc), '[]') from
                   (select max(b.customer_name) as name, count(*) bookings, sum(b.price) spent
                      from bk b where b.status <> 'cancelled' group by b.customer_id order by 3 desc limit 15) z) end,
    'methods',    case when money then (select coalesce(jsonb_agg(z order by z.amount desc), '[]') from
                   (select coalesce(payment_group,'other') method, count(*) n, sum(amount) amount from pay group by 1) z) end,
    'money_series', case when money then (select coalesce(jsonb_agg(z order by z.bucket), '[]') from
                   (select b.bk as bucket,
                           coalesce((select sum(amount) from pay where date_trunc(p_bucket, public._ist(pay.paid_at)::timestamp)::date = b.bk), 0) collected,
                           coalesce((select sum(commission_amount) from pay where not is_duplicate and refund_status = 'none'
                                       and date_trunc(p_bucket, public._ist(pay.paid_at)::timestamp)::date = b.bk), 0) commission,
                           coalesce((select sum(r.amount) from public.refunds r where r.status = 'success'
                                       and date_trunc(p_bucket, public._ist(coalesce(r.processed_at, r.created_at))::timestamp)::date = b.bk), 0) refunded,
                           coalesce((select sum(x.photographer_amount) from public.bookings x where x.payout_status = 'paid' and x.payout_at is not null
                                       and date_trunc(p_bucket, public._ist(x.payout_at)::timestamp)::date = b.bk), 0) paid_out
                      from buckets b) z) end,
    'money',      case when money then jsonb_build_object(
                    'advances', (select coalesce(sum(amount),0) from pay where stage = 'advance'),
                    'balances', (select coalesce(sum(amount),0) from pay where stage = 'balance'),
                    'refunded', (select coalesce(sum(amount),0) from public.refunds where status = 'success' and public._ist(created_at) between p_from and p_to),
                    'paid_out', (select coalesce(sum(photographer_amount),0) from public.bookings where payout_status = 'paid' and public._ist(payout_at) between p_from and p_to),
                    'balances_due_amount', (select coalesce(sum(balance_amount),0) from public.bookings where balance_status = 'due'),
                    'balances_due', (select count(*) from public.bookings where balance_status = 'due'),
                    'unpaid_bookings', (select count(*) from public.bookings where status = 'pending_payment'),
                    'failed', (select count(*) from public.payments where status in ('failed','user_dropped') and public._ist(created_at) between p_from and p_to),
                    'test_payments', (select count(*) from pay where environment = 'test')) end
  ) into res;
  return res;
end $$;

revoke all on function public.admin_detail(text, date, date, text) from public, anon;
revoke all on function public.admin_booking(uuid)                 from public, anon;
revoke all on function public.admin_report(date, date, text)      from public, anon;
grant execute on function public.admin_detail(text, date, date, text) to authenticated;
grant execute on function public.admin_booking(uuid)                 to authenticated;
grant execute on function public.admin_report(date, date, text)      to authenticated;

-- >>> 8d departments
-- =====================================================================
-- 8d. LEADS, MARKETING, FINANCE, OPERATIONS, CUSTOMERS, TRUST,
--     TIMELINE & REFERRALS — what each admin department sees
--     Visitors are still anonymous (a random browser ID). Only staff can
--     read any of this; money is hidden from managers.
-- =====================================================================

-- ---------- 1. where people come from ----------
create or replace function public._channel(p_src text, p_med text, p_ref text, p_code text)
returns text language sql immutable as $$
  select case
    when nullif(p_code,'') is not null then 'Referral'
    when coalesce(p_src,'') in ('android_app','app_install') then 'Android app'
    when coalesce(p_med,'') ~* '^(cpc|ppc|paid|paid[_ -]?social|paid[_ -]?search|ads?|display|banner|cpm|cpv)$' then 'Paid ads'
    when coalesce(p_med,'') ~* '(e-?mail|newsletter)' or coalesce(p_src,'') ~* '(e-?mail|newsletter|brevo|mailchimp)'
      or coalesce(p_ref,'') ~* '(^|\.)(mail\.|outlook\.|com\.google\.android\.gm)' then 'Email'
    when coalesce(p_src,'') || ' ' || coalesce(p_ref,'') ~* '(chatgpt|openai|perplexity|claude\.ai|gemini\.google|bard\.google|copilot|you\.com|phind|meta\.ai|deepseek|grok)' then 'AI assistants'
    when coalesce(p_med,'') ~* '^(organic|seo)$'
      or coalesce(p_src,'') || ' ' || coalesce(p_ref,'') ~* '(google|bing|yahoo|duckduckgo|yandex|ecosia|baidu|search\.brave|startpage)' then 'Search'
    when coalesce(p_med,'') ~* 'social'
      or coalesce(p_src,'') || ' ' || coalesce(p_ref,'') ~* '(instagram|facebook|(^|[ .])fb([ .]|$)|t\.co|twitter|(^| )x\.com|linkedin|lnkd|youtube|youtu\.be|whatsapp|wa\.me|pinterest|reddit|snapchat|telegram|t\.me|threads|quora|sharechat|moj)' then 'Social'
    when coalesce(p_med,'') ~* '(qr|offline|print|poster|flyer|sms)' then 'Offline / QR / SMS'
    when nullif(p_src,'') is not null then 'Other campaigns'
    when nullif(p_ref,'') is not null then 'Other websites'
    else 'Direct' end $$;

alter table public.site_visits
  add column if not exists utm_source   text,
  add column if not exists utm_medium   text,
  add column if not exists utm_campaign text,
  add column if not exists utm_term     text,
  add column if not exists utm_content  text,
  add column if not exists ref_code     text,
  add column if not exists channel      text,
  add column if not exists paths        text[] not null default '{}',
  add column if not exists other_users  uuid[] not null default '{}';
create index if not exists idx_site_visits_user on public.site_visits(user_id);
create index if not exists idx_site_visits_ref  on public.site_visits(ref_code) where ref_code is not null;
update public.site_visits set channel = public._channel(null, null, referrer, null) where channel is null;
update public.site_visits set paths = array[path] where paths = '{}' and path is not null;

alter table public.profiles
  add column if not exists acq           jsonb,
  add column if not exists channel       text,
  add column if not exists visitor_id    uuid,
  add column if not exists last_seen_at  timestamptz,
  add column if not exists referral_flag text;

-- people can't edit their own source, last-seen or referral flag
create or replace function public.profile_growth_guard()
returns trigger language plpgsql as $$
begin
  if not public.snappro_system() then
    if tg_op = 'UPDATE' then
      new.acq := old.acq; new.channel := old.channel; new.visitor_id := old.visitor_id;
      new.last_seen_at := old.last_seen_at; new.referral_flag := old.referral_flag;
    else
      new.acq := null; new.channel := null; new.visitor_id := null; new.last_seen_at := null; new.referral_flag := null;
    end if;
  end if;
  return new;
end $$;
drop trigger if exists profile_growth_guard on public.profiles;
create trigger profile_growth_guard before insert or update on public.profiles
  for each row execute function public.profile_growth_guard();

drop function if exists public.track_visit(uuid, text, text, text);
create or replace function public.track_visit(p_visitor uuid, p_path text default null, p_referrer text default null,
                                              p_device text default null, p_utm jsonb default null)
returns void language plpgsql security definer set search_path = public
as $$
declare d date := (now() at time zone 'Asia/Kolkata')::date;
        u jsonb := case when p_utm is not null and jsonb_typeof(p_utm) = 'object' and pg_column_size(p_utm) < 4000 then p_utm else '{}'::jsonb end;
        s text  := left(nullif(trim(lower(u->>'source')),''), 80);
        m text  := left(nullif(trim(lower(u->>'medium')),''), 80);
        c text  := left(nullif(trim(u->>'campaign'),''), 120);
        tm text := left(nullif(trim(u->>'term'),''), 120);
        ct text := left(nullif(trim(u->>'content'),''), 120);
        r text  := upper(left(nullif(trim(u->>'ref'),''), 20));
        pth text := left(nullif(p_path,''), 200);
        rf text := left(nullif(lower(p_referrer),''), 200);
begin
  if p_visitor is null then return; end if;
  if r is not null and r !~ '^SP[CP][0-9]{4,}$' then r := null; end if;
  insert into public.site_visits (visitor_id, day, user_id, path, referrer, device, utm_source, utm_medium, utm_campaign,
                                  utm_term, utm_content, ref_code, channel, paths)
  values (p_visitor, d, auth.uid(), pth, rf, case when p_device in ('mobile','tablet','desktop') then p_device end,
          s, m, c, tm, ct, r, public._channel(s, m, rf, r), case when pth is null then '{}'::text[] else array[pth] end)
  on conflict (visitor_id, day) do update
     set views        = least(public.site_visits.views + 1, 10000),
         last_at      = now(),
         user_id      = coalesce(public.site_visits.user_id, excluded.user_id),
         other_users  = case when excluded.user_id is null or excluded.user_id = public.site_visits.user_id or public.site_visits.user_id is null
                               or excluded.user_id = any(public.site_visits.other_users) or cardinality(public.site_visits.other_users) >= 20
                             then public.site_visits.other_users else public.site_visits.other_users || excluded.user_id end,
         referrer     = coalesce(public.site_visits.referrer, excluded.referrer),
         utm_source   = coalesce(public.site_visits.utm_source, excluded.utm_source),
         utm_medium   = coalesce(public.site_visits.utm_medium, excluded.utm_medium),
         utm_campaign = coalesce(public.site_visits.utm_campaign, excluded.utm_campaign),
         utm_term     = coalesce(public.site_visits.utm_term, excluded.utm_term),
         utm_content  = coalesce(public.site_visits.utm_content, excluded.utm_content),
         ref_code     = coalesce(public.site_visits.ref_code, excluded.ref_code),
         channel      = case when public.site_visits.channel is null or (public.site_visits.channel = 'Direct' and excluded.channel <> 'Direct')
                             then excluded.channel else public.site_visits.channel end,
         paths        = case when excluded.path is null or cardinality(public.site_visits.paths) >= 60
                               or public.site_visits.paths[cardinality(public.site_visits.paths)] = excluded.path
                             then public.site_visits.paths else public.site_visits.paths || excluded.path end;
  if auth.uid() is not null then
    perform set_config('snappro.system', 'on', true);
    update public.profiles set last_seen_at = now()
     where id = auth.uid() and (last_seen_at is null or last_seen_at < now() - interval '2 minutes');
    perform set_config('snappro.system', '', true);
  end if;
end $$;
revoke all on function public.track_visit(uuid, text, text, text, jsonb) from public;
grant execute on function public.track_visit(uuid, text, text, text, jsonb) to anon, authenticated;

create or replace function public._clean_touch(j jsonb)
returns jsonb language sql immutable as $$
  select case when j is null or jsonb_typeof(j) <> 'object' then null else jsonb_strip_nulls(jsonb_build_object(
    'source',   left(nullif(trim(lower(j->>'source')),''), 80),
    'medium',   left(nullif(trim(lower(j->>'medium')),''), 80),
    'campaign', left(nullif(trim(j->>'campaign'),''), 120),
    'term',     left(nullif(trim(j->>'term'),''), 120),
    'content',  left(nullif(trim(j->>'content'),''), 120),
    'referrer', left(nullif(trim(lower(j->>'referrer')),''), 200),
    'landing',  left(nullif(trim(j->>'landing'),''), 200),
    'ref',      left(nullif(trim(upper(j->>'ref')),''), 20),
    'shoot',    left(nullif(trim(j->>'shoot'),''), 30),
    'ads_click', case when coalesce(j->>'gclid', j->>'fbclid', j->>'ads_click') is not null then true end,
    'at',       left(nullif(trim(j->>'at'),''), 40))) end $$;

-- the app sends where this person first (and last) came from, once, after sign-up
create or replace function public.set_my_source(p jsonb)
returns text language plpgsql security definer set search_path = public
as $$
declare me uuid := auth.uid(); pr record; f jsonb; l jsonb; v uuid; ch text; dev text;
begin
  if me is null then return null; end if;
  if p is null or jsonb_typeof(p) <> 'object' or pg_column_size(p) > 8000 then return null; end if;
  select * into pr from public.profiles where id = me;
  if not found or pr.acq is not null then return pr.channel; end if;
  begin v := nullif(p->>'visitor','')::uuid; exception when others then v := null; end;
  f := public._clean_touch(p->'first'); l := public._clean_touch(p->'last');
  dev := case when p->>'device' in ('mobile','tablet','desktop') then p->>'device' end;
  -- nothing from the browser? use the first recorded visit of this browser
  if (f is null or f = '{}'::jsonb) and v is not null then
    select jsonb_strip_nulls(jsonb_build_object('source', s.utm_source, 'medium', s.utm_medium, 'campaign', s.utm_campaign,
             'term', s.utm_term, 'content', s.utm_content, 'referrer', s.referrer, 'landing', s.path, 'ref', s.ref_code, 'at', s.first_at::text))
      into f from public.site_visits s where s.visitor_id = v order by s.day limit 1;
  end if;
  ch := public._channel(f->>'source', f->>'medium', f->>'referrer', f->>'ref');
  perform set_config('snappro.system', 'on', true);
  update public.profiles set acq = jsonb_strip_nulls(jsonb_build_object('first', f, 'last', l, 'device', dev, 'visitor', v, 'set_at', now())),
                             channel = ch, visitor_id = v
   where id = me;
  perform set_config('snappro.system', '', true);
  if v is not null then update public.site_visits set user_id = me where visitor_id = v and user_id is null; end if;
  return ch;
end $$;
revoke all on function public.set_my_source(jsonb) from public, anon;
grant execute on function public.set_my_source(jsonb) to authenticated;

-- the channel a lead counts under (a friend's code always wins)
create or replace function public._lead_channel(p_ref uuid, p_channel text)
returns text language sql immutable as $$
  select case when p_ref is not null then 'Referral' else coalesce(p_channel, 'Unknown (before tracking)') end $$;

-- ---------- 2. everything that happens, minute by minute ----------
create table if not exists public.event_log (
  id        bigserial primary key,
  at        timestamptz not null default now(),
  kind      text not null,
  entity    text,
  entity_id uuid,
  user_id   uuid,
  other_id  uuid,
  city      text,
  category  text,
  amount    numeric(12,2),
  info      jsonb
);
create index if not exists idx_event_at    on public.event_log(at desc);
create index if not exists idx_event_user  on public.event_log(user_id, at desc);
create index if not exists idx_event_other on public.event_log(other_id, at desc);
create index if not exists idx_event_ent   on public.event_log(entity_id);
create index if not exists idx_event_kind  on public.event_log(kind, at desc);
alter table public.event_log enable row level security;
drop policy if exists event_staff_read on public.event_log;
create policy event_staff_read on public.event_log for select to authenticated using (public.is_staff());
revoke insert, update, delete on public.event_log from anon, authenticated;

-- never lets logging break the real action
create or replace function public._ev(p_kind text, p_entity text, p_entity_id uuid, p_user uuid, p_other uuid,
                                      p_city text, p_cat text, p_amount numeric, p_info jsonb)
returns void language plpgsql security definer set search_path = public
as $$
begin
  insert into public.event_log (kind, entity, entity_id, user_id, other_id, city, category, amount, info)
  values (p_kind, p_entity, p_entity_id, p_user, p_other, p_city, p_cat, p_amount,
          case when auth.uid() is not null and auth.uid() is distinct from p_user then coalesce(p_info, '{}'::jsonb) || jsonb_build_object('by', auth.uid()) else p_info end);
exception when others then null;
end $$;
revoke all on function public._ev(text, text, uuid, uuid, uuid, text, text, numeric, jsonb) from public, anon, authenticated;

create or replace function public.ev_profiles()
returns trigger language plpgsql security definer set search_path = public
as $$
begin
  if tg_op = 'INSERT' then
    perform public._ev('signup', 'profile', new.id, new.id, null, new.city, null, null, jsonb_build_object('role', new.role));
    return new;
  end if;
  if old.city is null and new.city is not null then
    perform public._ev('profile_setup', 'profile', new.id, new.id, null, new.city, null, null, jsonb_build_object('role', new.role)); end if;
  if new.role is distinct from old.role then
    perform public._ev('role_change', 'profile', new.id, new.id, null, new.city, null, null, jsonb_build_object('from', old.role, 'to', new.role)); end if;
  if new.status is distinct from old.status then
    perform public._ev('account_' || new.status, 'profile', new.id, new.id, null, new.city, null, null,
                       jsonb_build_object('reason', new.status_reason, 'until', new.status_until)); end if;
  if new.referred_by is distinct from old.referred_by and new.referred_by is not null then
    perform public._ev('referral_joined', 'profile', new.id, new.id, new.referred_by, new.city, null, null, null); end if;
  if new.referral_rewarded_at is distinct from old.referral_rewarded_at and new.referral_rewarded_at is not null then
    perform public._ev('referral_rewarded', 'profile', new.id, new.id, new.referred_by, new.city, null, null, null); end if;
  if new.channel is distinct from old.channel and old.channel is null then
    perform public._ev('source_recorded', 'profile', new.id, new.id, null, new.city, null, null,
                       jsonb_build_object('channel', new.channel, 'source', new.acq->'first'->>'source', 'landing', new.acq->'first'->>'landing')); end if;
  return new;
end $$;
drop trigger if exists ev_profiles on public.profiles;
create trigger ev_profiles after insert or update on public.profiles for each row execute function public.ev_profiles();

create or replace function public.ev_photographers()
returns trigger language plpgsql security definer set search_path = public
as $$
begin
  if tg_op = 'INSERT' then
    perform public._ev('pg_profile_created', 'photographer', new.id, new.id, null, new.city, null, null, null); return new; end if;
  if new.approval_status is distinct from old.approval_status then
    perform public._ev('pg_' || new.approval_status, 'photographer', new.id, new.id, null, new.city, null, null, jsonb_build_object('note', new.review_note)); end if;
  if new.is_online is distinct from old.is_online then
    perform public._ev(case when new.is_online then 'pg_online' else 'pg_offline' end, 'photographer', new.id, new.id, null, new.city, null, null, null); end if;
  if new.is_verified is distinct from old.is_verified then
    perform public._ev(case when new.is_verified then 'pg_badge_on' else 'pg_badge_off' end, 'photographer', new.id, new.id, null, new.city, null, null, null); end if;
  return new;
end $$;
drop trigger if exists ev_photographers on public.photographers;
create trigger ev_photographers after insert or update on public.photographers for each row execute function public.ev_photographers();

create or replace function public.ev_requests()
returns trigger language plpgsql security definer set search_path = public
as $$
begin
  if tg_op = 'INSERT' then
    perform public._ev('request_posted', 'request', new.id, new.customer_id, null, new.city, new.category, new.budget,
                       jsonb_build_object('urgency', new.urgency, 'hours', new.duration_hrs, 'start_at', new.start_at)); return new; end if;
  if new.status is distinct from old.status then
    perform public._ev('request_' || coalesce(new.status,'updated'), 'request', new.id, new.customer_id, null, new.city, new.category, null,
                       jsonb_build_object('from', old.status)); end if;
  return new;
end $$;
drop trigger if exists ev_requests on public.requests;
create trigger ev_requests after insert or update on public.requests for each row execute function public.ev_requests();

create or replace function public.ev_offers()
returns trigger language plpgsql security definer set search_path = public
as $$
declare r record;
begin
  select customer_id, city, category into r from public.requests where id = new.request_id;
  perform public._ev('quote_sent', 'request', new.request_id, new.photographer_id, r.customer_id, r.city, r.category, new.price,
                     jsonb_build_object('quote', new.id, 'eta_min', new.eta_min));
  return new;
end $$;
drop trigger if exists ev_offers on public.offers;
create trigger ev_offers after insert on public.offers for each row execute function public.ev_offers();

create or replace function public.ev_bookings()
returns trigger language plpgsql security definer set search_path = public
as $$
begin
  if tg_op = 'INSERT' then
    perform public._ev('booking_created', 'booking', new.id, new.customer_id, new.photographer_id, new.city, new.category, new.total_amount,
                       jsonb_build_object('status', new.status, 'start_at', new.start_at, 'discount', new.discount_amount)); return new; end if;
  if new.status is distinct from old.status then
    perform public._ev('booking_' || coalesce(new.status,'updated'), 'booking', new.id, new.customer_id, new.photographer_id, new.city, new.category, new.total_amount,
                       jsonb_build_object('from', old.status, 'cancelled_by', case when new.status = 'cancelled' then new.cancelled_by end)); end if;
  if new.balance_status is distinct from old.balance_status and new.balance_status in ('due','paid') then
    perform public._ev('balance_' || new.balance_status, 'booking', new.id, new.customer_id, new.photographer_id, new.city, new.category, new.balance_amount, null); end if;
  if new.payout_status is distinct from old.payout_status then
    perform public._ev('payout_' || new.payout_status, 'booking', new.id, new.photographer_id, new.customer_id, new.city, new.category, new.photographer_amount,
                       jsonb_build_object('ref', new.payout_ref)); end if;
  return new;
end $$;
drop trigger if exists ev_bookings on public.bookings;
create trigger ev_bookings after insert or update on public.bookings for each row execute function public.ev_bookings();

create or replace function public.ev_payments()
returns trigger language plpgsql security definer set search_path = public
as $$
begin
  if tg_op = 'INSERT' or new.status is distinct from old.status then
    perform public._ev('payment_' || case when tg_op = 'INSERT' and new.status = 'created' then 'started' else new.status end,
                       'booking', new.booking_id, new.customer_id, new.photographer_id, null, null, new.amount,
                       jsonb_build_object('stage', new.stage, 'method', new.payment_group, 'order', new.order_id, 'env', new.environment,
                                          'message', left(new.payment_message, 200)));
  end if;
  return new;
end $$;
drop trigger if exists ev_payments on public.payments;
create trigger ev_payments after insert or update on public.payments for each row execute function public.ev_payments();

create or replace function public.ev_refunds()
returns trigger language plpgsql security definer set search_path = public
as $$
declare p record;
begin
  if tg_op = 'INSERT' or new.status is distinct from old.status then
    select booking_id, customer_id, photographer_id into p from public.payments where id = new.payment_id;
    perform public._ev('refund_' || new.status, 'booking', p.booking_id, p.customer_id, p.photographer_id, null, null, new.amount,
                       jsonb_build_object('refund', new.refund_id, 'reason', left(new.reason, 200)));
  end if;
  return new;
end $$;
drop trigger if exists ev_refunds on public.refunds;
create trigger ev_refunds after insert or update on public.refunds for each row execute function public.ev_refunds();

create or replace function public.ev_reviews()
returns trigger language plpgsql security definer set search_path = public
as $$
begin
  perform public._ev('review_posted', 'booking', new.booking_id, new.customer_id, new.photographer_id, null, null, new.stars, null);
  return new;
end $$;
drop trigger if exists ev_reviews on public.reviews;
create trigger ev_reviews after insert on public.reviews for each row execute function public.ev_reviews();

create or replace function public.ev_kyc()
returns trigger language plpgsql security definer set search_path = public
as $$
begin
  if (tg_op = 'INSERT' and new.status <> 'not_submitted') or (tg_op = 'UPDATE' and new.status is distinct from old.status) then
    perform public._ev('kyc_' || new.status, 'photographer', new.id, new.id, null, null, null, null, jsonb_build_object('id_type', new.id_type, 'note', new.note)); end if;
  return new;
end $$;
drop trigger if exists ev_kyc on public.photographer_kyc;
create trigger ev_kyc after insert or update on public.photographer_kyc for each row execute function public.ev_kyc();

create or replace function public.ev_storage()
returns trigger language plpgsql security definer set search_path = public
as $$
begin
  if tg_op = 'INSERT' or new.status is distinct from old.status then
    perform public._ev('storage_' || new.status, 'photographer', new.photographer_id, new.photographer_id, null, null, null, new.amount,
                       jsonb_build_object('plan', coalesce(new.plan_name, new.plan), 'order', new.order_id)); end if;
  return new;
end $$;
drop trigger if exists ev_storage on public.storage_orders;
create trigger ev_storage after insert or update on public.storage_orders for each row execute function public.ev_storage();

create or replace function public.ev_benefits()
returns trigger language plpgsql security definer set search_path = public
as $$
begin
  if tg_op = 'INSERT' then
    perform public._ev('reward_given', 'reward', new.id, new.user_id, null, null, null, new.amount,
                       jsonb_build_object('title', new.title, 'kind', new.kind, 'source', new.source));
  elsif new.status is distinct from old.status then
    perform public._ev('reward_' || new.status, 'reward', new.id, new.user_id, null, null, null, new.amount,
                       jsonb_build_object('title', new.title, 'kind', new.kind, 'source', new.source)); end if;
  return new;
end $$;
drop trigger if exists ev_benefits on public.user_benefits;
create trigger ev_benefits after insert or update on public.user_benefits for each row execute function public.ev_benefits();

create or replace function public.ev_messages()
returns trigger language plpgsql security definer set search_path = public
as $$
declare b record;
begin
  select customer_id, photographer_id into b from public.bookings where id = new.booking_id;
  perform public._ev('chat_message', 'booking', new.booking_id, new.sender_id,
                     case when new.sender_id = b.customer_id then b.photographer_id else b.customer_id end, null, null, null, null);
  return new;
end $$;
drop trigger if exists ev_messages on public.messages;
create trigger ev_messages after insert on public.messages for each row execute function public.ev_messages();

-- one-time history from before the log existed
do $$ begin
  if not exists (select 1 from public.event_log) then
    insert into public.event_log (at, kind, entity, entity_id, user_id, other_id, city, category, amount, info)
    select coalesce(created_at, now()), 'signup'::text, 'profile'::text, id, id, null::uuid, city, null::text, null::numeric, jsonb_build_object('role', role, 'backfill', true) from public.profiles
    union all select coalesce(created_at, now()), 'request_posted', 'request', id, customer_id, null::uuid, city, category, budget, jsonb_build_object('backfill', true) from public.requests
    union all select coalesce(o.created_at, now()), 'quote_sent', 'request', o.request_id, o.photographer_id, r.customer_id, r.city, r.category, o.price, jsonb_build_object('backfill', true)
                from public.offers o left join public.requests r on r.id = o.request_id
    union all select coalesce(created_at, now()), 'booking_created', 'booking', id, customer_id, photographer_id, city, category, total_amount, jsonb_build_object('backfill', true) from public.bookings
    union all select paid_at, 'payment_paid', 'booking', booking_id, customer_id, photographer_id, null::text, null::text, amount, jsonb_build_object('stage', stage, 'backfill', true) from public.payments where paid_at is not null
    union all select coalesce(created_at, now()), 'review_posted', 'booking', booking_id, customer_id, photographer_id, null::text, null::text, stars, jsonb_build_object('backfill', true) from public.reviews;
  end if;
end $$;

-- grouping used by the Timeline filters
create or replace function public._ev_group(k text)
returns text language sql immutable as $$
  select case
    when k in ('signup','profile_setup','role_change','source_recorded','user_reported','user_blocked','user_unblocked') or k like 'account_%' then 'accounts'
    when k like 'referral_%' then 'referrals'
    when k like 'pg_%' or k like 'kyc_%' then 'photographers'
    when k like 'request_%' or k = 'quote_sent' then 'requests'
    when k like 'booking_%' or k like 'balance_%' then 'bookings'
    when k like 'payment_%' or k like 'refund_%' or k like 'payout_%' or k like 'storage_%' then 'money'
    when k = 'review_posted' then 'reviews'
    when k = 'chat_message' then 'chat'
    when k like 'reward_%' then 'rewards'
    when k like 'admin:%' then 'admin'
    else 'other' end $$;

-- ---------- 3. helpers ----------
create or replace function public._money_ok() returns boolean language sql stable security definer set search_path = public
as $$ select coalesce(public.staff_role() in ('super_admin','admin'), false) $$;
create or replace function public._median(v numeric[]) returns numeric language sql immutable as $$
  select percentile_cont(0.5) within group (order by x) from unnest(v) x where x is not null $$;

-- ---------- 4. LEADS ----------
create or replace function public.admin_leads(p_from date, p_to date)
returns jsonb language plpgsql security definer set search_path = public
as $$
declare money boolean := public._money_ok(); f date := coalesce(p_from, public._ist(now()) - 29); t date := coalesce(p_to, public._ist(now())); res jsonb;
begin
  if not public.is_staff() then raise exception 'Staff only'; end if;
  with L as (
    select p.id, p.public_id, p.name, p.role, p.email, p.phone, p.city, p.state, p.created_at, p.last_seen_at, p.status,
           public._lead_channel(p.referred_by, p.channel) channel,
           p.acq->'first'->>'source' src, p.acq->'first'->>'medium' med, p.acq->'first'->>'campaign' camp,
           p.acq->'first'->>'term' term, p.acq->'first'->>'content' content,
           p.acq->'first'->>'landing' landing, p.acq->'first'->>'referrer' referrer, p.acq->'first'->>'shoot' shoot,
           coalesce((p.acq->'first'->>'ads_click')::boolean, false) ads_click, p.acq->>'device' device,
           p.acq->'last'->>'source' last_src, p.acq->'last'->>'landing' last_landing,
           r.public_id ref_id, r.name ref_name,
           g.approval_status, k.status kyc,
           (select count(*) from public.requests q where q.customer_id = p.id) reqs,
           (select count(*) from public.requests q where q.customer_id = p.id and exists (select 1 from public.offers o where o.request_id = q.id)) quoted,
           (select count(*) from public.offers o where o.photographer_id = p.id) quotes_sent,
           (select count(*) from public.bookings b where (b.customer_id = p.id or b.photographer_id = p.id) and b.status <> 'pending_payment') booked,
           (select count(*) from public.bookings b where (b.customer_id = p.id or b.photographer_id = p.id) and b.status = 'completed') completed,
           (select coalesce(sum(b.total_amount),0) from public.bookings b where b.customer_id = p.id and b.status not in ('pending_payment','cancelled')) spend,
           (select coalesce(sum(b.photographer_amount),0) from public.bookings b where b.photographer_id = p.id and b.status = 'completed') earned,
           (select min(q.created_at) from public.requests q where q.customer_id = p.id) first_request_at,
           (select min(b.created_at) from public.bookings b where (b.customer_id = p.id or b.photographer_id = p.id) and b.status <> 'pending_payment') first_booking_at
      from public.profiles p
      left join public.profiles r on r.id = p.referred_by
      left join public.photographers g on g.id = p.id
      left join public.photographer_kyc k on k.id = p.id
     where public._ist(p.created_at) between f and t
       and not exists (select 1 from public.staff s where s.id = p.id)
  ), S as (
    select L.*, case when role = 'photographer' then
        case when completed > 0 then '7 Completed a shoot' when booked > 0 then '6 Got a booking' when quotes_sent > 0 then '5 Sending quotes'
             when approval_status = 'approved' and kyc = 'verified' then '4 Approved & ID verified' when approval_status = 'approved' then '3 Approved'
             when approval_status = 'rejected' then '0 Not approved' when approval_status = 'pending' then '2 Waiting for approval' else '1 Signed up' end
      else
        case when completed >= 2 then '7 Repeat customer' when completed = 1 then '6 Completed a shoot' when booked > 0 then '5 Booked'
             when quoted > 0 then '4 Got quotes' when reqs > 0 then '3 Posted a shoot' when city is not null then '2 Set up profile' else '1 Signed up' end end stage
      from L
  ), V as (
    select coalesce(channel, 'Direct') channel, count(distinct visitor_id) visitors from public.site_visits where day between f and t group by 1
  )
  select jsonb_build_object(
    'range', jsonb_build_object('from', f, 'to', t),
    'money', money,
    'kpis', jsonb_build_object(
      'leads', (select count(*) from S),
      'customers', (select count(*) from S where role = 'customer'),
      'photographers', (select count(*) from S where role = 'photographer'),
      'visitors', (select count(distinct visitor_id) from public.site_visits where day between f and t),
      'posted', (select count(*) from S where reqs > 0),
      'booked', (select count(*) from S where booked > 0),
      'completed', (select count(*) from S where completed > 0),
      'hot', (select count(*) from S where role = 'customer' and quoted > 0 and booked = 0),
      'cold', (select count(*) from S where role = 'customer' and reqs = 0 and created_at < now() - interval '2 days'),
      'pg_waiting', (select count(*) from S where stage = '2 Waiting for approval'),
      'tracked', (select count(*) from S where channel not like 'Unknown%'),
      'median_hours_to_request', (select round(public._median(array_agg(extract(epoch from first_request_at - created_at) / 3600))::numeric, 1) from S where first_request_at is not null),
      'median_hours_to_booking', (select round(public._median(array_agg(extract(epoch from first_booking_at - created_at) / 3600))::numeric, 1) from S where first_booking_at is not null),
      'value', case when money then (select coalesce(sum(spend),0) from S) end),
    'by_channel', (select coalesce(jsonb_agg(z order by z.leads desc), '[]') from (
        select c.channel, coalesce(v.visitors, 0) visitors, coalesce(x.leads, 0) leads, coalesce(x.customers, 0) customers,
               coalesce(x.photographers, 0) photographers, coalesce(x.posted, 0) posted, coalesce(x.booked, 0) booked,
               coalesce(x.completed, 0) completed, case when money then coalesce(x.value, 0) end value
          from (select channel from S union select channel from V) c
          left join V v on v.channel = c.channel
          left join (select channel, count(*) leads, count(*) filter (where role = 'customer') customers, count(*) filter (where role = 'photographer') photographers,
                            count(*) filter (where reqs > 0) posted, count(*) filter (where booked > 0) booked, count(*) filter (where completed > 0) completed,
                            sum(spend) value from S group by 1) x on x.channel = c.channel) z),
    'by_campaign', (select coalesce(jsonb_agg(z order by z.leads desc), '[]') from (
        select coalesce(src, '(none)') source, coalesce(med, '(none)') medium, coalesce(camp, '(none)') campaign, count(*) leads,
               count(*) filter (where booked > 0) booked, case when money then sum(spend) end value
          from S where src is not null or med is not null or camp is not null group by 1,2,3 limit 200) z),
    'by_landing', (select coalesce(jsonb_agg(z order by z.leads desc), '[]') from (
        select coalesce(landing, '(unknown)') landing, count(*) leads, count(*) filter (where booked > 0) booked from S group by 1 limit 200) z),
    'by_referrer', (select coalesce(jsonb_agg(z order by z.leads desc), '[]') from (
        select coalesce(referrer, '(none / direct)') referrer, count(*) leads, count(*) filter (where booked > 0) booked from S group by 1 limit 100) z),
    'by_city', (select coalesce(jsonb_agg(z order by z.leads desc), '[]') from (
        select coalesce(city, '(not set)') city, count(*) leads, count(*) filter (where role = 'customer') customers,
               count(*) filter (where role = 'photographer') photographers, count(*) filter (where booked > 0) booked from S group by 1) z),
    'by_device', (select coalesce(jsonb_agg(z order by z.leads desc), '[]') from (select coalesce(device, '(unknown)') device, count(*) leads from S group by 1) z),
    'by_interest', (select coalesce(jsonb_agg(z order by z.leads desc), '[]') from (select shoot, count(*) leads, count(*) filter (where booked > 0) booked from S where shoot is not null group by 1) z),
    'stages', (select coalesce(jsonb_agg(z order by z.role, z.stage), '[]') from (select role, stage, count(*) n from S group by 1,2) z),
    'daily', (select coalesce(jsonb_agg(z order by z.day), '[]') from (select public._ist(created_at) as day, channel, count(*) n from S group by 1,2) z),
    'list', (select coalesce(jsonb_agg(jsonb_build_object(
        'id', id, 'public_id', public_id, 'name', name, 'role', role,
        'email', case when money then email end, 'phone', case when money then phone end,
        'city', city, 'state', state, 'created_at', created_at, 'last_seen_at', last_seen_at, 'status', status,
        'channel', channel, 'source', src, 'medium', med, 'campaign', camp, 'term', term, 'content', content,
        'landing', landing, 'referrer', referrer, 'shoot', shoot, 'ads_click', ads_click, 'device', device,
        'last_source', last_src, 'last_landing', last_landing, 'ref_id', ref_id, 'ref_name', ref_name,
        'stage', substr(stage, 3), 'stage_no', left(stage, 1)::int,
        'requests', reqs, 'quoted', quoted, 'quotes_sent', quotes_sent, 'booked', booked, 'completed', completed,
        'spend', case when money then spend end, 'earned', case when money then earned end,
        'first_request_at', first_request_at, 'first_booking_at', first_booking_at) order by created_at desc), '[]')
      from (select * from S order by created_at desc limit 3000) z)
  ) into res;
  return res;
end $$;

-- ---------- 5. MARKETING ----------
create or replace function public.admin_marketing(p_from date, p_to date, p_bucket text default 'day')
returns jsonb language plpgsql security definer set search_path = public
as $$
declare money boolean := public._money_ok(); f date := coalesce(p_from, public._ist(now()) - 29); t date := coalesce(p_to, public._ist(now()));
        bkt text := case when p_bucket in ('day','week','month','year') then p_bucket else 'day' end; res jsonb;
begin
  if not public.is_staff() then raise exception 'Staff only'; end if;
  with V as (select * from public.site_visits where day between f and t),
       P as (select p.*, public._lead_channel(p.referred_by, p.channel) ch from public.profiles p
              where public._ist(p.created_at) between f and t and not exists (select 1 from public.staff s where s.id = p.id)),
       B as (select b.*, public._lead_channel(c.referred_by, c.channel) ch, c.acq cacq
               from public.bookings b join public.profiles c on c.id = b.customer_id
              where public._ist(b.created_at) between f and t and b.status <> 'pending_payment')
  select jsonb_build_object(
    'range', jsonb_build_object('from', f, 'to', t, 'bucket', bkt), 'money', money,
    'kpis', jsonb_build_object(
      'visitors', (select count(distinct visitor_id) from V),
      'views', (select coalesce(sum(views),0) from V),
      'new_visitors', (select count(distinct v.visitor_id) from V v where not exists (select 1 from public.site_visits o where o.visitor_id = v.visitor_id and o.day < f)),
      'returning', (select count(*) from (select visitor_id from V group by 1 having count(*) > 1) z),
      'signups', (select count(*) from P),
      'bookings', (select count(*) from B),
      'pages_per_visit', (select round(avg(views)::numeric, 1) from V),
      'seo_visitors', (select count(distinct visitor_id) from V where path ~ '(photographers|photography-prices|guides|how-it-works|faq|about)'),
      'ai_visitors', (select count(distinct visitor_id) from V where channel = 'AI assistants'),
      'search_visitors', (select count(distinct visitor_id) from V where channel = 'Search'),
      'social_visitors', (select count(distinct visitor_id) from V where channel = 'Social'),
      'ref_link_opens', (select count(distinct visitor_id) from V where ref_code is not null),
      'discounts', case when money then (select coalesce(sum(discount_amount),0) from B where status <> 'cancelled') end,
      'discounted_bookings', (select count(*) from B where discount_amount > 0)),
    'channels', (select coalesce(jsonb_agg(z order by z.visitors desc), '[]') from (
        select c.ch channel, coalesce(v.visitors,0) visitors, coalesce(v.views,0) views, coalesce(v.mobile,0) mobile,
               coalesce(p.n,0) signups, coalesce(b.n,0) bookings, case when money then coalesce(b.value,0) end value
          from (select coalesce(channel,'Direct') ch from V union select ch from P union select ch from B) c
          left join (select coalesce(channel,'Direct') ch, count(distinct visitor_id) visitors, sum(views) views,
                            count(distinct visitor_id) filter (where device = 'mobile') mobile from V group by 1) v on v.ch = c.ch
          left join (select ch, count(*) n from P group by 1) p on p.ch = c.ch
          left join (select ch, count(*) n, sum(total_amount) value from B where status <> 'cancelled' group by 1) b on b.ch = c.ch) z),
    'series', (select coalesce(jsonb_agg(z order by z.bucket), '[]') from (
        select date_trunc(bkt, day::timestamp)::date bucket, coalesce(channel,'Direct') channel, count(distinct visitor_id) n from V group by 1,2) z),
    'campaigns', (select coalesce(jsonb_agg(z order by z.visitors desc), '[]') from (
        select coalesce(v.utm_source,'(none)') source, coalesce(v.utm_medium,'(none)') medium, coalesce(v.utm_campaign,'(none)') campaign,
               count(distinct v.visitor_id) visitors, sum(v.views) views,
               (select count(*) from P where coalesce(P.acq->'first'->>'source','(none)') = coalesce(v.utm_source,'(none)')
                                         and coalesce(P.acq->'first'->>'campaign','(none)') = coalesce(v.utm_campaign,'(none)')) signups
          from V v where v.utm_source is not null or v.utm_campaign is not null group by v.utm_source, v.utm_medium, v.utm_campaign limit 200) z),
    'terms', (select coalesce(jsonb_agg(z order by z.visitors desc), '[]') from (
        select utm_term term, count(distinct visitor_id) visitors from V where utm_term is not null group by 1 limit 100) z),
    'landing', (select coalesce(jsonb_agg(z order by z.visitors desc), '[]') from (
        select v.path, count(distinct v.visitor_id) visitors, sum(v.views) views,
               (select count(*) from P where P.acq->'first'->>'landing' = v.path) signups
          from V v where v.path is not null group by v.path limit 300) z),
    'pages', (select coalesce(jsonb_agg(z order by z.visitors desc), '[]') from (
        select x path, count(distinct v.visitor_id) visitors from V v, unnest(v.paths) x group by 1 limit 400) z),
    'referrers', (select coalesce(jsonb_agg(z order by z.visitors desc), '[]') from (
        select referrer, coalesce(channel,'Other websites') channel, count(distinct visitor_id) visitors, sum(views) views from V where referrer is not null group by 1,2 limit 200) z),
    'devices', (select coalesce(jsonb_agg(z order by z.visitors desc), '[]') from (
        select coalesce(device,'unknown') device, count(distinct visitor_id) visitors from V group by 1) z),
    'interest', (select coalesce(jsonb_agg(z order by z.n desc), '[]') from (
        select acq->'first'->>'shoot' shoot, count(*) n from P where acq->'first'->>'shoot' is not null group by 1) z),
    'hours', (select coalesce(jsonb_agg(z order by z.h), '[]') from (
        select extract(hour from first_at at time zone 'Asia/Kolkata')::int h, count(*) n from V group by 1) z),
    'referral', jsonb_build_object(
        'opens', (select count(distinct visitor_id) from V where ref_code is not null),
        'joined', (select count(*) from public.profiles where public._ist(referral_at) between f and t),
        'rewarded', (select count(*) from public.profiles where public._ist(referral_rewarded_at) between f and t),
        'rewards_given', (select count(*) from public.user_benefits where source = 'referral' and public._ist(created_at) between f and t),
        'rewards_used', (select count(*) from public.user_benefits where source = 'referral' and public._ist(used_at) between f and t)),
    'offers', (select coalesce(jsonb_agg(z order by z.claimed desc), '[]') from (
        select o.id, o.title, o.code, o.audience, o.kind, o.active,
               (select count(*) from public.user_benefits u where u.offer_id = o.id and public._ist(u.created_at) between f and t) claimed,
               (select count(*) from public.user_benefits u where u.offer_id = o.id and public._ist(u.used_at) between f and t) used,
               (select count(*) from public.bookings b join public.user_benefits u on u.id = b.discount_benefit_id
                 where u.offer_id = o.id and public._ist(b.created_at) between f and t and b.status not in ('pending_payment','cancelled')) bookings,
               case when money then (select coalesce(sum(b.discount_amount),0) from public.bookings b join public.user_benefits u on u.id = b.discount_benefit_id
                 where u.offer_id = o.id and public._ist(b.created_at) between f and t and b.status not in ('pending_payment','cancelled')) end discount
          from public.promo_offers o) z)
  ) into res;
  return res;
end $$;

-- ---------- 6. FINANCE ----------
create or replace function public.admin_finance(p_from date, p_to date, p_bucket text default 'day')
returns jsonb language plpgsql security definer set search_path = public
as $$
declare f date := coalesce(p_from, public._ist(now()) - 29); t date := coalesce(p_to, public._ist(now()));
        bkt text := case when p_bucket in ('day','week','month','year') then p_bucket else 'day' end; res jsonb;
begin
  if not public._money_ok() then raise exception 'Only admins can see finance'; end if;
  with Bk as (select * from public.bookings where public._ist(created_at) between f and t and status <> 'pending_payment'),
       Done0 as (select b.*, coalesce((select max(e.at) from public.event_log e where e.entity_id = b.id and e.kind = 'booking_completed'), b.start_at, b.created_at) done_at
                   from public.bookings b where b.status = 'completed'),
       Done as (select * from Done0 where public._ist(done_at) between f and t),
       Pay as (select * from public.payments where status = 'paid' and public._ist(paid_at) between f and t),
       Rf as (select * from public.refunds where status = 'success' and public._ist(coalesce(processed_at, updated_at)) between f and t),
       St as (select * from public.storage_orders where status in ('paid','active','terminated') and paid_at is not null and public._ist(paid_at) between f and t),
       Po as (select * from public.bookings where payout_status = 'paid' and public._ist(payout_at) between f and t)
  select jsonb_build_object(
    'range', jsonb_build_object('from', f, 'to', t, 'bucket', bkt),
    'kpis', jsonb_build_object(
      'gmv', (select coalesce(sum(coalesce(price, total_amount)),0) from Bk where status <> 'cancelled'),
      'net_gmv', (select coalesce(sum(total_amount),0) from Bk where status <> 'cancelled'),
      'bookings', (select count(*) from Bk where status <> 'cancelled'),
      'avg_booking', (select round(avg(total_amount)) from Bk where status <> 'cancelled'),
      'completed_value', (select coalesce(sum(total_amount),0) from Done),
      'completed', (select count(*) from Done),
      'collected', (select coalesce(sum(amount),0) from Pay),
      'collected_advance', (select coalesce(sum(amount),0) from Pay where stage = 'advance'),
      'collected_balance', (select coalesce(sum(amount),0) from Pay where stage = 'balance'),
      'collected_live', (select coalesce(sum(amount),0) from Pay where environment in ('live','production')),
      'collected_test', (select coalesce(sum(amount),0) from Pay where environment not in ('live','production')),
      'payments', (select count(*) from Pay),
      'refunded', (select coalesce(sum(amount),0) from Rf),
      'refunds', (select count(*) from Rf),
      'commission', (select coalesce(sum(commission_amount),0) from Done),
      'commission_booked', (select coalesce(sum(commission_amount),0) from Bk where status <> 'cancelled'),
      'discounts', (select coalesce(sum(discount_amount),0) from Bk where status <> 'cancelled'),
      'storage_revenue', (select coalesce(sum(amount),0) from St),
      'storage_orders', (select count(*) from St),
      'revenue', (select coalesce(sum(commission_amount),0) from Done) + (select coalesce(sum(amount),0) from St),
      'payouts_paid', (select coalesce(sum(photographer_amount),0) from Po),
      'payouts_paid_n', (select count(*) from Po),
      'payouts_due', (select coalesce(sum(photographer_amount),0) from public.bookings where payout_status = 'due'),
      'payouts_due_n', (select count(*) from public.bookings where payout_status = 'due'),
      'payouts_on_hold', (select coalesce(sum(photographer_amount),0) from public.bookings where payout_status = 'on_hold'),
      'balances_due', (select coalesce(sum(balance_amount),0) from public.bookings where balance_status = 'due' and status <> 'cancelled'),
      'balances_due_n', (select count(*) from public.bookings where balance_status = 'due' and status <> 'cancelled'),
      'balances_pending', (select coalesce(sum(balance_amount),0) from public.bookings where balance_status = 'pending' and status not in ('cancelled','pending_payment')),
      'refunds_to_do', (select count(*) from public.bookings where payment_status in ('refund_due','refund_pending')),
      'refunds_failed', (select count(*) from public.refunds where status = 'failed'),
      'failed_payments', (select count(*) from public.payments where status = 'failed' and public._ist(created_at) between f and t),
      'failed_amount', (select coalesce(sum(amount),0) from public.payments where status = 'failed' and public._ist(created_at) between f and t),
      'abandoned', (select count(*) from public.payments where status = 'created' and created_at < now() - interval '30 minutes' and public._ist(created_at) between f and t),
      'duplicates', (select count(*) from public.payments where is_duplicate and public._ist(created_at) between f and t),
      'cancelled_value', (select coalesce(sum(total_amount),0) from Bk where status = 'cancelled'),
      'take_rate', (select case when sum(total_amount) > 0 then round(100.0 * sum(commission_amount) / sum(total_amount), 1) end from Done)),
    'series', (select coalesce(jsonb_agg(z order by z.bucket), '[]') from (
        select g::date bucket,
          (select coalesce(sum(coalesce(price,total_amount)),0) from Bk where status <> 'cancelled' and date_trunc(bkt, created_at at time zone 'Asia/Kolkata') = g) gmv,
          (select coalesce(sum(amount),0) from Pay where stage = 'advance' and date_trunc(bkt, paid_at at time zone 'Asia/Kolkata') = g) advance,
          (select coalesce(sum(amount),0) from Pay where stage = 'balance' and date_trunc(bkt, paid_at at time zone 'Asia/Kolkata') = g) balance,
          (select coalesce(sum(amount),0) from Rf where date_trunc(bkt, coalesce(processed_at, updated_at) at time zone 'Asia/Kolkata') = g) refunded,
          (select coalesce(sum(commission_amount),0) from Done where date_trunc(bkt, done_at at time zone 'Asia/Kolkata') = g) commission,
          (select coalesce(sum(amount),0) from St where date_trunc(bkt, paid_at at time zone 'Asia/Kolkata') = g) storage,
          (select coalesce(sum(photographer_amount),0) from Po where date_trunc(bkt, payout_at at time zone 'Asia/Kolkata') = g) payouts,
          (select coalesce(sum(discount_amount),0) from Bk where status <> 'cancelled' and date_trunc(bkt, created_at at time zone 'Asia/Kolkata') = g) discounts
        from generate_series(date_trunc(bkt, f::timestamp), date_trunc(bkt, t::timestamp), ('1 ' || bkt)::interval) g) z),
    'pnl', (select coalesce(jsonb_agg(z order by z.month desc), '[]') from (
        select date_trunc('month', g)::date as month,
          (select coalesce(sum(coalesce(price,total_amount)),0) from public.bookings where status not in ('pending_payment','cancelled') and date_trunc('month', created_at at time zone 'Asia/Kolkata') = g) gmv,
          (select coalesce(sum(amount),0) from public.payments where status = 'paid' and date_trunc('month', paid_at at time zone 'Asia/Kolkata') = g) collected,
          (select coalesce(sum(amount),0) from public.refunds where status = 'success' and date_trunc('month', coalesce(processed_at, updated_at) at time zone 'Asia/Kolkata') = g) refunded,
          (select coalesce(sum(commission_amount),0) from Done0 where date_trunc('month', done_at at time zone 'Asia/Kolkata') = g) commission,
          (select coalesce(sum(amount),0) from public.storage_orders where paid_at is not null and status in ('paid','active','terminated') and date_trunc('month', paid_at at time zone 'Asia/Kolkata') = g) storage,
          (select coalesce(sum(discount_amount),0) from public.bookings where status not in ('pending_payment','cancelled') and date_trunc('month', created_at at time zone 'Asia/Kolkata') = g) discounts,
          (select coalesce(sum(photographer_amount),0) from public.bookings where payout_status = 'paid' and date_trunc('month', payout_at at time zone 'Asia/Kolkata') = g) payouts
        from generate_series(date_trunc('month', now() at time zone 'Asia/Kolkata') - interval '11 months', date_trunc('month', now() at time zone 'Asia/Kolkata'), interval '1 month') g) z),
    'by_method', (select coalesce(jsonb_agg(z order by z.amount desc), '[]') from (
        select coalesce(payment_group,'unknown') method, count(*) n, sum(amount) amount from Pay group by 1) z),
    'by_category', (select coalesce(jsonb_agg(z order by z.gmv desc), '[]') from (
        select coalesce(category,'—') category, count(*) n, sum(total_amount) gmv, sum(commission_amount) commission from Bk where status <> 'cancelled' group by 1) z),
    'by_city', (select coalesce(jsonb_agg(z order by z.gmv desc), '[]') from (
        select coalesce(city,'—') city, count(*) n, sum(total_amount) gmv, sum(commission_amount) commission from Bk where status <> 'cancelled' group by 1) z),
    'by_plan', (select coalesce(jsonb_agg(z order by z.amount desc), '[]') from (
        select coalesce(plan_name, plan) plan, count(*) n, sum(amount) amount from St group by 1) z),
    'top_photographers', (select coalesce(jsonb_agg(z order by z.earned desc), '[]') from (
        select b.photographer_id id, max(b.photographer_name) name, (select public_id from public.profiles where id = b.photographer_id) public_id,
               count(*) shoots, sum(b.photographer_amount) earned, sum(b.commission_amount) commission
          from Done b group by b.photographer_id order by 5 desc limit 25) z),
    'top_customers', (select coalesce(jsonb_agg(z order by z.spend desc), '[]') from (
        select b.customer_id id, max(b.customer_name) name, (select public_id from public.profiles where id = b.customer_id) public_id,
               count(*) bookings, sum(b.total_amount) spend
          from Bk b where b.status <> 'cancelled' group by b.customer_id order by 5 desc limit 25) z),
    'ledger', (select coalesce(jsonb_agg(z order by z.at desc), '[]') from (
        select * from (
          select p.paid_at at, 'Payment in' as type, p.stage as detail, p.amount, 'in' dir, p.status, p.order_id ref, p.gateway_payment_id gateway,
                 p.payment_group method, p.environment env, p.booking_id, c.public_id who_id, c.name who
            from Pay p left join public.profiles c on c.id = p.customer_id
          union all
          select coalesce(r.processed_at, r.updated_at), 'Refund out', left(coalesce(r.reason,''),80), r.amount, 'out', r.status, r.refund_id, r.gateway_refund_id,
                 null, null, p.booking_id, c.public_id, c.name
            from Rf r join public.payments p on p.id = r.payment_id left join public.profiles c on c.id = p.customer_id
          union all
          select s.paid_at, 'Storage plan in', coalesce(s.plan_name, s.plan), s.amount, 'in', s.status, s.order_id, s.gateway_payment_id,
                 s.payment_group, s.environment, null, c.public_id, c.name
            from St s left join public.profiles c on c.id = s.photographer_id
          union all
          select b.payout_at, 'Payout to photographer', null, b.photographer_amount, 'out', 'paid', b.payout_ref, null, 'upi', null, b.id, c.public_id, c.name
            from Po b left join public.profiles c on c.id = b.photographer_id
        ) u order by at desc limit 3000) z)
  ) into res;
  return res;
end $$;

-- ---------- 7. OPERATIONS ----------
create or replace function public.admin_ops(p_from date, p_to date)
returns jsonb language plpgsql security definer set search_path = public
as $$
declare money boolean := public._money_ok(); f date := coalesce(p_from, public._ist(now()) - 29); t date := coalesce(p_to, public._ist(now())); res jsonb;
        today date := public._ist(now());
begin
  if not public.is_staff() then raise exception 'Staff only'; end if;
  with R as (select r.*, (select min(o.created_at) from public.offers o where o.request_id = r.id) first_quote,
                         (select count(*) from public.offers o where o.request_id = r.id) quotes,
                         (select min(b.created_at) from public.bookings b where b.request_id = r.id) booked_at
               from public.requests r where public._ist(r.created_at) between f and t),
       Bk as (select * from public.bookings where public._ist(created_at) between f and t)
  select jsonb_build_object(
    'range', jsonb_build_object('from', f, 'to', t), 'money', money,
    'live', jsonb_build_object(
      'open_requests', (select coalesce(jsonb_agg(z order by z.created_at), '[]') from (
          select r.id, r.customer_name, r.city, r.category, r.urgency, r.budget, r.created_at, r.start_at, r.expires_at,
                 (select count(*) from public.offers o where o.request_id = r.id) quotes,
                 round(extract(epoch from now() - r.created_at) / 60) minutes_open,
                 (select count(*) from public.photographers g where g.approval_status = 'approved' and lower(g.city) = lower(r.city)
                     and r.category = any(g.categories)) matching_pgs
            from public.requests r where r.status in ('broadcasting','awaiting') and (r.expires_at is null or r.expires_at > now())) z),
      'shoots_today', (select coalesce(jsonb_agg(z order by z.start_at), '[]') from (
          select id, customer_name, photographer_name, category, city, status, start_at, duration_hrs, balance_status
            from public.bookings where public._ist(start_at) = today and status not in ('cancelled','pending_payment')) z),
      'upcoming', (select coalesce(jsonb_agg(z order by z.start_at), '[]') from (
          select id, customer_name, photographer_name, category, city, status, start_at, duration_hrs
            from public.bookings where start_at > now() and public._ist(start_at) <= today + 7 and status in ('confirmed','enroute','arrived')) z),
      'in_progress', (select coalesce(jsonb_agg(z order by z.start_at), '[]') from (
          select id, customer_name, photographer_name, category, city, status, start_at, updated_at, balance_status
            from public.bookings where status in ('enroute','arrived','shooting')) z),
      'late', (select coalesce(jsonb_agg(z order by z.start_at), '[]') from (
          select id, customer_name, photographer_name, category, city, status, start_at, round(extract(epoch from now() - start_at) / 60) minutes_late
            from public.bookings where (status = 'confirmed' and start_at < now() - interval '15 minutes')
                                    or (status = 'enroute' and start_at < now() - interval '30 minutes')) z),
      'stuck_shooting', (select coalesce(jsonb_agg(z), '[]') from (
          select id, customer_name, photographer_name, start_at, duration_hrs, status from public.bookings
           where status = 'shooting' and start_at + make_interval(hours => coalesce(duration_hrs, 2) + 3) < now()) z),
      'abandoned_checkouts', (select coalesce(jsonb_agg(z order by z.created_at desc), '[]') from (
          select id, customer_name, photographer_name, category, city, created_at, case when money then advance_amount end advance_amount
            from public.bookings where status = 'pending_payment' and created_at < now() - interval '20 minutes' and created_at > now() - interval '7 days') z),
      'balances_due', (select coalesce(jsonb_agg(z), '[]') from (
          select id, customer_name, photographer_name, start_at, case when money then balance_amount end balance_amount
            from public.bookings where balance_status = 'due' and status <> 'cancelled') z),
      'approvals', (select coalesce(jsonb_agg(z order by z.submitted_at), '[]') from (
          select g.id, g.display_name, g.city, g.submitted_at, cardinality(g.portfolio) photos, k.status kyc,
                 round(extract(epoch from now() - g.submitted_at) / 3600, 1) hours_waiting
            from public.photographers g left join public.photographer_kyc k on k.id = g.id where g.approval_status = 'pending') z),
      'kyc_waiting', (select count(*) from public.photographer_kyc where status = 'submitted'),
      'payouts_due', (select count(*) from public.bookings where payout_status = 'due'),
      'refunds_to_do', (select count(*) from public.bookings where payment_status in ('refund_due','refund_pending')),
      'online_by_city', (select coalesce(jsonb_agg(z order by z.online desc), '[]') from (
          select coalesce(city,'—') city, count(*) filter (where is_online) online, count(*) approved
            from public.photographers where approval_status = 'approved' group by 1) z)),
    'kpis', jsonb_build_object(
      'requests', (select count(*) from R),
      'quoted', (select count(*) from R where quotes > 0),
      'booked', (select count(*) from R where booked_at is not null),
      'expired', (select count(*) from R where status = 'expired'),
      'cancelled', (select count(*) from R where status = 'cancelled'),
      'no_quote', (select count(*) from R where quotes = 0 and status in ('expired','cancelled')),
      'avg_quotes', (select round(avg(quotes)::numeric, 1) from R),
      'median_first_quote_min', (select round(public._median(array_agg(extract(epoch from first_quote - created_at) / 60))::numeric) from R where first_quote is not null),
      'median_to_book_min', (select round(public._median(array_agg(extract(epoch from booked_at - created_at) / 60))::numeric) from R where booked_at is not null),
      'bookings', (select count(*) from Bk where status <> 'pending_payment'),
      'completed', (select count(*) from Bk where status = 'completed'),
      'cancelled_bookings', (select count(*) from Bk where status = 'cancelled'),
      'cancelled_by_customer', (select count(*) from Bk where status = 'cancelled' and cancelled_by = 'customer'),
      'cancelled_by_photographer', (select count(*) from Bk where status = 'cancelled' and cancelled_by = 'photographer'),
      'abandoned', (select count(*) from Bk where status = 'pending_payment' and created_at < now() - interval '20 minutes'),
      'avg_rating', (select round(avg(stars)::numeric, 2) from public.reviews where public._ist(created_at) between f and t),
      'reviews', (select count(*) from public.reviews where public._ist(created_at) between f and t),
      'messages', (select count(*) from public.messages where public._ist(created_at) between f and t)),
    'cancellations', (select coalesce(jsonb_agg(z order by z.n desc), '[]') from (
        select coalesce(cancelled_by,'unknown') who, coalesce(cancelled_from,'unknown') stage, count(*) n from Bk where status = 'cancelled' group by 1,2) z),
    'supply_demand', (select coalesce(jsonb_agg(z order by z.requests desc), '[]') from (
        select c.city, coalesce(r.n,0) requests, coalesce(r.unquoted,0) unquoted, coalesce(r.booked,0) booked,
               coalesce(g.approved,0) photographers, coalesce(g.online,0) online
          from (select lower(city) k, min(city) city from (select city from R union all select city from public.photographers where approval_status = 'approved') u
                 where city is not null group by 1) c
          left join (select lower(city) k, count(*) n, count(*) filter (where quotes = 0) unquoted, count(*) filter (where booked_at is not null) booked from R group by 1) r on r.k = c.k
          left join (select lower(city) k, count(*) approved, count(*) filter (where is_online) online from public.photographers where approval_status = 'approved' group by 1) g on g.k = c.k) z),
    'by_category', (select coalesce(jsonb_agg(z order by z.requests desc), '[]') from (
        select coalesce(category,'—') category, count(*) requests, count(*) filter (where quotes > 0) quoted, count(*) filter (where booked_at is not null) booked,
               round(avg(budget)) avg_budget,
               (select round(avg(o.price)) from public.offers o join R r2 on r2.id = o.request_id where coalesce(r2.category,'—') = coalesce(R.category,'—')) avg_quote,
               (select count(*) from public.photographers g where g.approval_status = 'approved' and R.category = any(g.categories)) photographers
          from R group by category) z),
    'by_urgency', (select coalesce(jsonb_agg(z order by z.n desc), '[]') from (
        select coalesce(urgency,'—') urgency, count(*) n, count(*) filter (where booked_at is not null) booked from R group by 1) z),
    'heatmap', (select coalesce(jsonb_agg(z), '[]') from (
        select extract(isodow from created_at at time zone 'Asia/Kolkata')::int dow, extract(hour from created_at at time zone 'Asia/Kolkata')::int h, count(*) n
          from R group by 1,2) z),
    'shoot_heatmap', (select coalesce(jsonb_agg(z), '[]') from (
        select extract(isodow from start_at at time zone 'Asia/Kolkata')::int dow, extract(hour from start_at at time zone 'Asia/Kolkata')::int h, count(*) n
          from Bk where start_at is not null and status <> 'pending_payment' group by 1,2) z),
    'photographers', (select coalesce(jsonb_agg(z order by z.quotes desc, z.name), '[]') from (
        select g.id, g.display_name name, p.public_id, g.city, g.is_online, g.rating, g.review_count, g.jobs_done, k.status kyc,
               (select count(*) from public.offers o where o.photographer_id = g.id and public._ist(o.created_at) between f and t) quotes,
               (select count(*) from Bk b where b.photographer_id = g.id and b.status <> 'pending_payment') wins,
               (select count(*) from Bk b where b.photographer_id = g.id and b.status = 'completed') completed,
               (select count(*) from Bk b where b.photographer_id = g.id and b.status = 'cancelled' and b.cancelled_by = 'photographer') cancelled,
               (select round(public._median(array_agg(extract(epoch from o.created_at - r.created_at) / 60))::numeric)
                  from public.offers o join public.requests r on r.id = o.request_id
                 where o.photographer_id = g.id and public._ist(o.created_at) between f and t) median_quote_min,
               (select max(e.at) from public.event_log e where e.user_id = g.id and e.kind = 'pg_online') last_online,
               p.last_seen_at,
               case when money then (select coalesce(sum(b.photographer_amount),0) from Bk b where b.photographer_id = g.id and b.status = 'completed') end earned
          from public.photographers g join public.profiles p on p.id = g.id left join public.photographer_kyc k on k.id = g.id
         where g.approval_status = 'approved') z)
  ) into res;
  return res;
end $$;

-- ---------- 8. CUSTOMERS (CRM) ----------
create or replace function public.admin_customers()
returns jsonb language plpgsql security definer set search_path = public
as $$
declare money boolean := public._money_ok(); res jsonb;
begin
  if not public.is_staff() then raise exception 'Staff only'; end if;
  with C as (
    select p.id, p.public_id, p.name, p.email, p.phone, p.city, p.created_at, p.last_seen_at, p.status,
           public._lead_channel(p.referred_by, p.channel) channel,
           (select count(*) from public.requests r where r.customer_id = p.id) requests,
           (select count(*) from public.bookings b where b.customer_id = p.id and b.status <> 'pending_payment') bookings,
           (select count(*) from public.bookings b where b.customer_id = p.id and b.status = 'completed') completed,
           (select count(*) from public.bookings b where b.customer_id = p.id and b.status = 'cancelled') cancelled,
           (select coalesce(sum(b.total_amount),0) from public.bookings b where b.customer_id = p.id and b.status not in ('pending_payment','cancelled')) spend,
           (select max(b.created_at) from public.bookings b where b.customer_id = p.id and b.status <> 'pending_payment') last_booking,
           (select min(b.created_at) from public.bookings b where b.customer_id = p.id and b.status <> 'pending_payment') first_booking,
           (select count(*) from public.profiles x where x.referred_by = p.id) referred,
           (select round(avg(v.stars)::numeric,1) from public.reviews v where v.customer_id = p.id) avg_stars_given
      from public.profiles p where p.role = 'customer' and not exists (select 1 from public.staff s where s.id = p.id)
  ), S as (
    select C.*, case when status <> 'active' then 'Suspended / blocked'
                     when completed >= 2 then 'Repeat'
                     when bookings > 0 and last_booking < now() - interval '90 days' then 'Dormant (90+ days)'
                     when bookings > 0 then 'Active'
                     when requests > 0 then 'Posted, never booked'
                     when created_at > now() - interval '7 days' then 'New (this week)'
                     else 'Signed up, never posted' end segment from C
  )
  select jsonb_build_object('money', money,
    'segments', (select coalesce(jsonb_agg(z order by z.n desc), '[]') from (select segment, count(*) n, case when money then sum(spend) end spend from S group by 1) z),
    'kpis', jsonb_build_object(
       'customers', (select count(*) from S),
       'with_booking', (select count(*) from S where bookings > 0),
       'repeat', (select count(*) from S where completed >= 2),
       'repeat_rate', (select case when count(*) filter (where completed >= 1) > 0 then round(100.0 * count(*) filter (where completed >= 2) / count(*) filter (where completed >= 1)) end from S),
       'avg_ltv', case when money then (select round(avg(spend)) from S where bookings > 0) end,
       'avg_bookings', (select round(avg(bookings)::numeric, 2) from S where bookings > 0),
       'active_30', (select count(*) from S where last_seen_at > now() - interval '30 days'),
       'referrers', (select count(*) from S where referred > 0)),
    'ltv_buckets', case when money then (select coalesce(jsonb_agg(z order by z.ord), '[]') from (
        select case when spend = 0 then 0 when spend < 5000 then 1 when spend < 15000 then 2 when spend < 50000 then 3 else 4 end ord,
               case when spend = 0 then '₹0' when spend < 5000 then 'Under ₹5k' when spend < 15000 then '₹5k–15k' when spend < 50000 then '₹15k–50k' else '₹50k+' end bucket,
               count(*) n from S group by 1,2) z) end,
    'cohorts', (select coalesce(jsonb_agg(z order by z.cohort desc), '[]') from (
        select co.cohort::date cohort, co.size,
               (select jsonb_agg((select count(distinct b.customer_id) from public.bookings b join S s2 on s2.id = b.customer_id
                                   where date_trunc('month', s2.created_at at time zone 'Asia/Kolkata') = co.cohort
                                     and b.status <> 'pending_payment'
                                     and date_trunc('month', b.created_at at time zone 'Asia/Kolkata') = co.cohort + make_interval(months => k)) order by k)
                  from generate_series(0, 11) k
                 where co.cohort + make_interval(months => k) <= date_trunc('month', now() at time zone 'Asia/Kolkata')) months
          from (select date_trunc('month', created_at at time zone 'Asia/Kolkata') cohort, count(*) size
                  from S where created_at > now() - interval '12 months' group by 1) co) z),
    'cities', (select coalesce(jsonb_agg(z order by z.n desc), '[]') from (select coalesce(city,'(not set)') city, count(*) n, count(*) filter (where bookings > 0) booked,
                  case when money then sum(spend) end spend from S group by 1) z),
    'list', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'public_id', public_id, 'name', name,
                'email', case when money then email end, 'phone', case when money then phone end, 'city', city, 'created_at', created_at,
                'last_seen_at', last_seen_at, 'status', status, 'channel', channel, 'segment', segment, 'requests', requests, 'bookings', bookings,
                'completed', completed, 'cancelled', cancelled, 'spend', case when money then spend end, 'last_booking', last_booking,
                'first_booking', first_booking, 'referred', referred, 'avg_stars_given', avg_stars_given) order by created_at desc), '[]')
             from (select * from S order by created_at desc limit 5000) z)
  ) into res;
  return res;
end $$;

-- ---------- 9. TRUST & SUPPORT ----------
create or replace function public.admin_trust()
returns jsonb language plpgsql security definer set search_path = public
as $$
declare money boolean := public._money_ok(); res jsonb;
begin
  if not public.is_staff() then raise exception 'Staff only'; end if;
  select jsonb_build_object('money', money,
    'restricted', (select coalesce(jsonb_agg(z order by z.status_at desc nulls last), '[]') from (
        select id, public_id, name, role, status, status_reason, status_until, status_at from public.profiles where status <> 'active') z),
    'kyc', (select coalesce(jsonb_object_agg(status, n), '{}') from (select status, count(*) n from public.photographer_kyc group by 1) z),
    'kyc_missing', (select count(*) from public.photographers g where g.approval_status = 'approved'
                      and not exists (select 1 from public.photographer_kyc k where k.id = g.id and k.status = 'verified')),
    'low_reviews', (select coalesce(jsonb_agg(z order by z.created_at desc), '[]') from (
        select v.booking_id, v.stars, v.body, v.created_at, v.customer_name, g.display_name photographer, v.photographer_id
          from public.reviews v left join public.photographers g on g.id = v.photographer_id
         where v.stars <= 2 and v.created_at > now() - interval '365 days') z),
    'pg_cancellers', (select coalesce(jsonb_agg(z order by z.n desc), '[]') from (
        select b.photographer_id id, max(b.photographer_name) name, count(*) n from public.bookings b
         where b.status = 'cancelled' and b.cancelled_by = 'photographer' and b.created_at > now() - interval '180 days' group by 1 having count(*) >= 2) z),
    'customer_cancellers', (select coalesce(jsonb_agg(z order by z.n desc), '[]') from (
        select b.customer_id id, max(b.customer_name) name, count(*) n from public.bookings b
         where b.status = 'cancelled' and b.cancelled_by = 'customer' and b.created_at > now() - interval '180 days' group by 1 having count(*) >= 3) z),
    'failed_refunds', case when money then (select coalesce(jsonb_agg(z), '[]') from (
        select r.refund_id, r.amount, r.reason, r.created_at, p.booking_id from public.refunds r join public.payments p on p.id = r.payment_id where r.status = 'failed') z) end,
    'duplicate_payments', case when money then (select coalesce(jsonb_agg(z), '[]') from (
        select order_id, amount, booking_id, paid_at, refund_status from public.payments where is_duplicate) z) end,
    'referral_flags', (select coalesce(jsonb_agg(z), '[]') from (
        select p.id, p.public_id, p.name, p.referral_flag, r.public_id ref_id, r.name ref_name from public.profiles p
          left join public.profiles r on r.id = p.referred_by where p.referral_flag is not null) z),
    'chat_reads', (select count(*) from public.admin_audit where action ilike '%chat%' and at > now() - interval '30 days'),
    'reports_open', (select count(*) from public.user_reports where status in ('open','reviewing')),
    'reports', case when money then (select coalesce(jsonb_agg(z order by z.created_at desc), '[]') from (
        select r.id, r.created_at, r.status, r.reason, r.details, r.context, r.snapshot, r.booking_id, r.action_note, r.handled_at,
               (select s.email from public.staff s where s.id = r.handled_by) handled_by,
               r.reporter_id, rp.name reporter, rp.public_id reporter_pid,
               r.reported_id, coalesce(g.display_name, tp.name) reported, tp.public_id reported_pid, tp.role reported_role, tp.status reported_status,
               (select count(*) from public.user_reports x where x.reported_id = r.reported_id) reports_against,
               (select count(*) from public.user_blocks x where x.blocked_id = r.reported_id) blocked_by
          from public.user_reports r join public.profiles rp on rp.id = r.reporter_id join public.profiles tp on tp.id = r.reported_id
          left join public.photographers g on g.id = r.reported_id
         order by (r.status in ('open','reviewing')) desc, r.created_at desc limit 1000) z) end,
    'blocked_often', (select coalesce(jsonb_agg(z order by z.n desc), '[]') from (
        select b.blocked_id id, coalesce(g.display_name, p.name) name, p.public_id, p.role, p.status, count(*) n, max(b.created_at) last_at
          from public.user_blocks b join public.profiles p on p.id = b.blocked_id left join public.photographers g on g.id = b.blocked_id
         group by 1, 2, 3, 4, 5 having count(*) >= 2) z),
    'deletions', case when money then (select coalesce(jsonb_agg(z order by z.deleted_at desc), '[]') from (
        select deleted_at, user_id, public_id, role, via, reason, login_closed from public.account_deletions order by deleted_at desc limit 1000) z) end,
    'staff_actions', (select coalesce(jsonb_agg(z order by z.n desc), '[]') from (
        select coalesce(staff_email,'?') staff, count(*) n, max(at) last_at from public.admin_audit where at > now() - interval '30 days' group by 1) z)
  ) into res;
  return res;
end $$;

-- ---------- 10. TIMELINE (every event, newest first) ----------
create or replace function public.admin_timeline(p_from timestamptz, p_to timestamptz, p_group text default null, p_user uuid default null, p_limit int default 1000)
returns jsonb language plpgsql security definer set search_path = public
as $$
declare money boolean := public._money_ok(); res jsonb; lim int := least(greatest(coalesce(p_limit, 1000), 1), 5000);
begin
  if not public.is_staff() then raise exception 'Staff only'; end if;
  select coalesce(jsonb_agg(z order by z.at desc), '[]') into res from (
    select * from (
      select e.id, e.at, e.kind, public._ev_group(e.kind) grp, e.entity, e.entity_id, e.user_id, u.public_id user_pid, u.name user_name, u.role user_role,
             e.other_id, o.public_id other_pid, o.name other_name, e.city, e.category,
             case when not money and public._ev_group(e.kind) = 'money' then null else e.amount end amount, e.info
        from public.event_log e left join public.profiles u on u.id = e.user_id left join public.profiles o on o.id = e.other_id
       where e.at between coalesce(p_from, now() - interval '1 day') and coalesce(p_to, now())
         and (p_group is null or p_group = '' or public._ev_group(e.kind) = p_group)
         and (p_user is null or e.user_id = p_user or e.other_id = p_user)
      union all
      select -a.id, a.at, 'admin:' || a.action, 'admin', a.target_type, null, a.staff_id, null, a.staff_email, a.staff_role,
             null, a.target_id, a.target_name, null, null, null, a.details
        from public.admin_audit a
       where money and a.at between coalesce(p_from, now() - interval '1 day') and coalesce(p_to, now())
         and (p_group is null or p_group = '' or p_group = 'admin')
         and (p_user is null or a.target_id = p_user::text)
    ) u order by at desc limit lim) z;
  return res;
end $$;

-- ---------- 11. ONE PERSON, EVERYTHING ----------
create or replace function public.admin_user_360(p_key text)
returns jsonb language plpgsql security definer set search_path = public
as $$
declare money boolean := public._money_ok(); uid uuid; pr record; res jsonb; k text := trim(coalesce(p_key,''));
begin
  if not public.is_staff() then raise exception 'Staff only'; end if;
  begin uid := k::uuid; exception when others then uid := null; end;
  if uid is null then select id into uid from public.profiles where public_id = upper(k) or lower(email) = lower(k) or phone = k limit 1; end if;
  select * into pr from public.profiles where id = uid;
  if not found then raise exception 'No one found for "%"', k; end if;
  perform public._audit('Opened full profile', 'user', uid::text, pr.name, null);
  select jsonb_build_object('money', money,
    'profile', jsonb_build_object('id', pr.id, 'public_id', pr.public_id, 'member_no', pr.member_no, 'name', pr.name, 'role', pr.role,
        'email', case when money then pr.email end, 'phone', case when money then pr.phone end,
        'city', pr.city, 'state', pr.state, 'pincode', pr.pincode, 'created_at', pr.created_at, 'last_seen_at', pr.last_seen_at,
        'status', pr.status, 'status_reason', pr.status_reason, 'status_until', pr.status_until,
        'channel', public._lead_channel(pr.referred_by, pr.channel), 'acq', pr.acq,
        'referred_by', (select jsonb_build_object('id', r.id, 'public_id', r.public_id, 'name', r.name) from public.profiles r where r.id = pr.referred_by),
        'referral_at', pr.referral_at, 'referral_rewarded_at', pr.referral_rewarded_at, 'referral_flag', pr.referral_flag),
    'photographer', (select jsonb_build_object('display_name', g.display_name, 'approval_status', g.approval_status, 'approved_at', g.approved_at,
        'is_online', g.is_online, 'is_verified', g.is_verified, 'rating', g.rating, 'review_count', g.review_count, 'jobs_done', g.jobs_done,
        'categories', g.categories, 'city', g.city, 'years_exp', g.years_exp, 'photos', cardinality(g.portfolio), 'commission_pct', g.commission_pct,
        'featured_until', g.featured_until, 'travel', g.travel, 'kyc', (select k.status from public.photographer_kyc k where k.id = g.id),
        'storage_quota', case when money then public.storage_quota(g.id) end) from public.photographers g where g.id = uid),
    'requests', (select coalesce(jsonb_agg(z order by z.created_at desc), '[]') from (
        select r.id, r.category, r.city, r.status, r.budget, r.urgency, r.start_at, r.created_at, (select count(*) from public.offers o where o.request_id = r.id) quotes
          from public.requests r where r.customer_id = uid limit 200) z),
    'quotes', (select coalesce(jsonb_agg(z order by z.created_at desc), '[]') from (
        select o.request_id, o.price, o.created_at, r.category, r.city, r.status request_status,
               exists (select 1 from public.bookings b where b.offer_id = o.id) won
          from public.offers o join public.requests r on r.id = o.request_id where o.photographer_id = uid limit 300) z),
    'bookings', (select coalesce(jsonb_agg(z order by z.created_at desc), '[]') from (
        select b.id, b.status, b.category, b.city, b.start_at, b.created_at, b.customer_name, b.photographer_name,
               case when money then b.total_amount end total_amount, case when money then b.commission_amount end commission_amount,
               case when money then b.photographer_amount end photographer_amount, case when money then b.discount_amount end discount_amount,
               b.payment_status, b.balance_status, b.payout_status, b.cancelled_by,
               (select count(*) from public.messages m where m.booking_id = b.id) messages,
               (select v.stars from public.reviews v where v.booking_id = b.id) stars
          from public.bookings b where b.customer_id = uid or b.photographer_id = uid limit 300) z),
    'payments', case when money then (select coalesce(jsonb_agg(z order by z.created_at desc), '[]') from (
        select p.order_id, p.stage, p.amount, p.status, p.payment_group, p.environment, p.paid_at, p.created_at, p.refund_status, p.refunded_amount, p.booking_id
          from public.payments p where p.customer_id = uid limit 300) z) end,
    'storage_orders', case when money then (select coalesce(jsonb_agg(z order by z.created_at desc), '[]') from (
        select order_id, coalesce(plan_name, plan) plan, amount, status, period_start, period_end, paid_at, created_at
          from public.storage_orders where photographer_id = uid) z) end,
    'rewards', (select coalesce(jsonb_agg(z order by z.created_at desc), '[]') from (
        select title, kind, source, amount, status, uses_left, expires_at, created_at, used_at from public.user_benefits where user_id = uid) z),
    'referred', (select coalesce(jsonb_agg(z order by z.referral_at desc), '[]') from (
        select id, public_id, name, role, created_at, referral_at, referral_rewarded_at, referral_flag from public.profiles where referred_by = uid) z),
    'reviews_given', (select coalesce(jsonb_agg(z), '[]') from (select booking_id, stars, body, created_at from public.reviews where customer_id = uid) z),
    'reviews_received', (select coalesce(jsonb_agg(z), '[]') from (select booking_id, stars, body, created_at, customer_name from public.reviews where photographer_id = uid) z),
    'visits', (select coalesce(jsonb_agg(z order by z.day desc), '[]') from (
        select day, first_at, last_at, views, device, channel, referrer, utm_source, utm_medium, utm_campaign, ref_code, paths
          from public.site_visits where user_id = uid or (pr.visitor_id is not null and visitor_id = pr.visitor_id) order by day desc limit 200) z),
    'timeline', (select coalesce(jsonb_agg(z order by z.at desc), '[]') from (
        select e.at, e.kind, e.entity, e.entity_id, e.city, e.category, case when not money and public._ev_group(e.kind) = 'money' then null else e.amount end amount,
               e.info, o.name other_name, o.public_id other_pid
          from public.event_log e left join public.profiles o on o.id = case when e.user_id = uid then e.other_id else e.user_id end
         where e.user_id = uid or e.other_id = uid order by e.at desc limit 1000) z),
    'blocked_by', (select count(*) from public.user_blocks where blocked_id = uid),
    'blocks_made', (select count(*) from public.user_blocks where blocker_id = uid),
    'reports', case when money then (select coalesce(jsonb_agg(z order by z.created_at desc), '[]') from (
        select r.id, r.created_at, case when r.reported_id = uid then 'about them' else 'made by them' end direction,
               r.reason, r.context, r.details, r.snapshot, r.status, r.action_note, r.booking_id,
               o.id other_id, o.name other_name, o.public_id other_pid
          from public.user_reports r join public.profiles o on o.id = case when r.reported_id = uid then r.reporter_id else r.reported_id end
         where r.reported_id = uid or r.reporter_id = uid limit 300) z) end,
    'admin_actions', case when money then (select coalesce(jsonb_agg(z order by z.at desc), '[]') from (
        select at, staff_email, action, details from public.admin_audit where target_id = uid::text order by at desc limit 200) z) end
  ) into res;
  return res;
end $$;


-- did two accounts use the same browser?
create or replace function public._same_browser(a uuid, b uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles x join public.profiles y on y.visitor_id = x.visitor_id where x.id = a and y.id = b)
      or exists (select 1 from public.site_visits s where (s.user_id = a or a = any(s.other_users)) and (s.user_id = b or b = any(s.other_users)))
      or exists (select 1 from public.site_visits s1 join public.site_visits s2 on s2.visitor_id = s1.visitor_id
                  where (s1.user_id = a or a = any(s1.other_users)) and (s2.user_id = b or b = any(s2.other_users)))
$$;
revoke all on function public._same_browser(uuid, uuid) from public, anon, authenticated;

-- ---------- 12. REFERRALS (more options + full tracking) ----------
-- extra program options (all optional):
--   "code_days": days a new member has to add a friend's code (default 14)
--   "block_same_device": hold rewards when both accounts used the same browser (default true)
--   per audience: "enabled" (default true), "max_rewards" (rewards per inviter, empty = no limit),
--                 "min_booking" (smallest qualifying first shoot, ₹)
create or replace function public.referral_check(p_user uuid)
returns boolean language plpgsql security definer set search_path = public
as $$
declare prog jsonb := (select value from public.platform_settings where key = 'referral_program');
        me record; ref record; mine jsonb; theirs jsonb; ok boolean; cap int; given int; minb numeric;
begin
  if prog is null or coalesce((prog->>'enabled')::boolean, false) is not true then return false; end if;
  select * into me from public.profiles where id = p_user;
  if me.referred_by is null or me.referral_rewarded_at is not null then return false; end if;
  select * into ref from public.profiles where id = me.referred_by;
  if not found then return false; end if;
  mine := prog->(case when me.role = 'photographer' then 'photographer' else 'customer' end);
  theirs := prog->(case when ref.role = 'photographer' then 'photographer' else 'customer' end);
  if coalesce((mine->>'enabled')::boolean, true) is not true then return false; end if;
  minb := coalesce(nullif(mine->>'min_booking','')::numeric, 0);
  ok := case coalesce(mine->>'when','first_booking')
          when 'signup' then true
          else exists (select 1 from public.bookings b where b.status = 'completed' and coalesce(b.price, b.total_amount, 0) >= minb
                        and (b.customer_id = p_user or b.photographer_id = p_user)) end;
  if not ok then return false; end if;
  if me.referral_flag is not null then return false; end if;            -- held for an admin to look at
  if coalesce((prog->>'block_same_device')::boolean, true)
     and public._same_browser(p_user, ref.id) then
    perform set_config('snappro.system', 'on', true);
    update public.profiles set referral_flag = 'Same browser as the inviter' where id = p_user;
    perform set_config('snappro.system', '', true);
    return false;
  end if;
  perform public._grant_benefit(p_user, mine->'new_user_reward', 'referral', null);
  cap := nullif(theirs->>'max_rewards','')::int;
  given := (select count(*) from public.profiles x where x.referred_by = ref.id and x.referral_rewarded_at is not null);
  if (cap is null or given < cap) and coalesce((theirs->>'enabled')::boolean, true) then
    perform public._grant_benefit(ref.id, theirs->'referrer_reward', 'referral', null);
  end if;
  perform set_config('snappro.system', 'on', true);
  update public.profiles set referral_rewarded_at = now() where id = p_user;
  perform set_config('snappro.system', '', true);
  return true;
end $$;
revoke all on function public.referral_check(uuid) from public, anon, authenticated;

create or replace function public.apply_referral(p_code text)
returns jsonb language plpgsql security definer set search_path = public
as $$
declare me uuid := auth.uid(); pr record; ref record; days int;
        prog jsonb := (select value from public.platform_settings where key = 'referral_program');
begin
  if me is null then raise exception 'Please log in again'; end if;
  days := coalesce(nullif(prog->>'code_days','')::int, 14);
  select * into pr from public.profiles where id = me;
  if pr.referred_by is not null then raise exception 'You''ve already added a referral code'; end if;
  if pr.created_at < now() - make_interval(days => days) then raise exception 'Referral codes can only be added in your first % days', days; end if;
  select * into ref from public.profiles where public_id = upper(trim(coalesce(p_code,'')));
  if not found then raise exception 'That code isn''t valid'; end if;
  if ref.id = me then raise exception 'You can''t use your own code'; end if;
  if ref.referred_by = me then raise exception 'You invited this person, so you can''t use their code'; end if;
  perform set_config('snappro.system', 'on', true);
  update public.profiles set referred_by = ref.id, referral_at = now() where id = me;
  perform set_config('snappro.system', '', true);
  perform public.referral_check(me);
  return jsonb_build_object('result','referred','by', split_part(coalesce(ref.name,'a friend'),' ',1));
end $$;
revoke all on function public.apply_referral(text) from public, anon;
grant execute on function public.apply_referral(text) to authenticated;

-- my invite page: everyone I invited, where they are, what I earned
create or replace function public.my_referrals()
returns jsonb language plpgsql security definer set search_path = public
as $$
declare me uuid := auth.uid(); pr record; prog jsonb := (select value from public.platform_settings where key = 'referral_program'); aud text; days int;
begin
  if me is null then return null; end if;
  select * into pr from public.profiles where id = me;
  aud := case when pr.role = 'photographer' then 'photographer' else 'customer' end;
  days := coalesce(nullif(prog->>'code_days','')::int, 14);
  return jsonb_build_object(
    'code', pr.public_id,
    'enabled', coalesce((prog->>'enabled')::boolean, false) and coalesce((prog->aud->>'enabled')::boolean, true),
    'program', jsonb_build_object('when_customer', prog->'customer'->>'when', 'when_photographer', prog->'photographer'->>'when',
        'my_reward', prog->aud->'referrer_reward', 'friend_customer', prog->'customer'->'new_user_reward',
        'friend_photographer', prog->'photographer'->'new_user_reward', 'max_rewards', prog->aud->'max_rewards',
        'min_customer', prog->'customer'->'min_booking', 'min_photographer', prog->'photographer'->'min_booking', 'code_days', days,
        'customer_on', coalesce((prog->'customer'->>'enabled')::boolean, true), 'photographer_on', coalesce((prog->'photographer'->>'enabled')::boolean, true)),
    'opens', (select count(distinct visitor_id) from public.site_visits where ref_code = pr.public_id),
    'opens_7d', (select count(distinct visitor_id) from public.site_visits where ref_code = pr.public_id and day > public._ist(now()) - 7),
    'friends', (select coalesce(jsonb_agg(z order by z.joined desc), '[]') from (
        select split_part(coalesce(x.name,'Friend'),' ',1) || coalesce(' ' || left(nullif(split_part(x.name,' ',2),''),1) || '.', '') name,
               x.role, x.referral_at joined, x.referral_rewarded_at rewarded_at,
               case when x.referral_rewarded_at is not null then 'rewarded'
                    when x.referral_flag is not null then 'checking'
                    when exists (select 1 from public.bookings b where (b.customer_id = x.id or b.photographer_id = x.id) and b.status = 'completed') then 'completed'
                    when exists (select 1 from public.bookings b where (b.customer_id = x.id or b.photographer_id = x.id) and b.status not in ('pending_payment','cancelled')) then 'booked'
                    when x.role = 'photographer' and exists (select 1 from public.photographers g where g.id = x.id and g.approval_status = 'approved') then 'approved'
                    when x.city is not null then 'set_up'
                    else 'joined' end status
          from public.profiles x where x.referred_by = me) z),
    'rewards', (select coalesce(jsonb_agg(z order by z.created_at desc), '[]') from (
        select title, kind, amount, status, uses_left, expires_at, created_at, used_at from public.user_benefits where user_id = me and source = 'referral') z),
    'invited_by', (select jsonb_build_object('name', split_part(coalesce(r.name,'a friend'),' ',1), 'code', r.public_id) from public.profiles r where r.id = pr.referred_by),
    'can_add_code', pr.referred_by is null and pr.created_at > now() - make_interval(days => days),
    'code_deadline', case when pr.referred_by is null then pr.created_at + make_interval(days => days) end);
end $$;
revoke all on function public.my_referrals() from public, anon;
grant execute on function public.my_referrals() to authenticated;

-- admin: every referral, every code, every click
create or replace function public.admin_referrals(p_from date, p_to date)
returns jsonb language plpgsql security definer set search_path = public
as $$
declare money boolean := public._money_ok(); f date := coalesce(p_from, public._ist(now()) - 29); t date := coalesce(p_to, public._ist(now())); res jsonb;
begin
  if not public.is_staff() then raise exception 'Staff only'; end if;
  with Rf as (
    select x.id, x.public_id, x.name, x.role, x.city, x.created_at, x.referral_at, x.referral_rewarded_at, x.referral_flag,
           r.id ref_id, r.public_id ref_pid, r.name ref_name, r.role ref_role,
           (select count(*) from public.bookings b where (b.customer_id = x.id or b.photographer_id = x.id) and b.status not in ('pending_payment','cancelled')) bookings,
           (select count(*) from public.bookings b where (b.customer_id = x.id or b.photographer_id = x.id) and b.status = 'completed') completed,
           (select coalesce(sum(b.total_amount),0) from public.bookings b where b.customer_id = x.id and b.status not in ('pending_payment','cancelled')) spend,
           public._same_browser(x.id, r.id) same_device
      from public.profiles x join public.profiles r on r.id = x.referred_by
     where public._ist(x.referral_at) between f and t
  )
  select jsonb_build_object('money', money, 'range', jsonb_build_object('from', f, 'to', t),
    'program', (select value from public.platform_settings where key = 'referral_program'),
    'kpis', jsonb_build_object(
      'opens', (select count(distinct visitor_id) from public.site_visits where ref_code is not null and day between f and t),
      'joined', (select count(*) from Rf),
      'customers', (select count(*) from Rf where role = 'customer'),
      'photographers', (select count(*) from Rf where role = 'photographer'),
      'booked', (select count(*) from Rf where bookings > 0),
      'completed', (select count(*) from Rf where completed > 0),
      'rewarded', (select count(*) from Rf where referral_rewarded_at is not null),
      'flagged', (select count(*) from public.profiles where referral_flag is not null),
      'inviters', (select count(distinct ref_id) from Rf),
      'rewards_given', (select count(*) from public.user_benefits where source = 'referral' and public._ist(created_at) between f and t),
      'rewards_used', (select count(*) from public.user_benefits where source = 'referral' and status = 'used' and public._ist(created_at) between f and t),
      'discount_cost', case when money then (select coalesce(sum(b.discount_amount),0) from public.bookings b join public.user_benefits u on u.id = b.discount_benefit_id
                          where u.source = 'referral' and b.status not in ('pending_payment','cancelled') and public._ist(b.created_at) between f and t) end,
      'referred_spend', case when money then (select coalesce(sum(spend),0) from Rf) end),
    'series', (select coalesce(jsonb_agg(z order by z.day), '[]') from (
        select d::date as day,
               (select count(distinct visitor_id) from public.site_visits where ref_code is not null and day = d::date) opens,
               (select count(*) from Rf where public._ist(referral_at) = d::date) joined,
               (select count(*) from public.profiles where public._ist(referral_rewarded_at) = d::date) rewarded
          from generate_series(f::timestamp, t::timestamp, interval '1 day') d) z),
    'inviters', (select coalesce(jsonb_agg(z order by z.joined desc, z.opens desc), '[]') from (
        select p.id, p.public_id, p.name, p.role,
               (select count(distinct visitor_id) from public.site_visits s where s.ref_code = p.public_id and s.day between f and t) opens,
               (select count(*) from Rf where Rf.ref_id = p.id) joined,
               (select count(*) from Rf where Rf.ref_id = p.id and Rf.completed > 0) completed,
               (select count(*) from Rf where Rf.ref_id = p.id and Rf.referral_rewarded_at is not null) rewarded,
               (select count(*) from public.profiles x where x.referred_by = p.id) joined_all_time,
               case when money then (select coalesce(sum(spend),0) from Rf where Rf.ref_id = p.id) end spend
          from public.profiles p
         where exists (select 1 from Rf where Rf.ref_id = p.id)
            or exists (select 1 from public.site_visits s where s.ref_code = p.public_id and s.day between f and t)
         limit 500) z),
    'list', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'public_id', public_id, 'name', name, 'role', role, 'city', city,
               'joined_at', created_at, 'referral_at', referral_at, 'rewarded_at', referral_rewarded_at, 'flag', referral_flag,
               'ref_id', ref_id, 'ref_pid', ref_pid, 'ref_name', ref_name, 'ref_role', ref_role, 'bookings', bookings, 'completed', completed,
               'spend', case when money then spend end, 'same_device', same_device,
               'status', case when referral_rewarded_at is not null then 'Rewarded' when referral_flag is not null then 'Held for review'
                              when completed > 0 then 'Completed a shoot' when bookings > 0 then 'Booked' else 'Joined' end) order by referral_at desc), '[]') from Rf)
  ) into res;
  return res;
end $$;

-- admin actions on one referral: reward now, hold, clear the hold, remove the link
create or replace function public.admin_referral_action(p_user uuid, p_action text)
returns text language plpgsql security definer set search_path = public
as $$
declare me record; ref record; prog jsonb := (select value from public.platform_settings where key = 'referral_program'); mine jsonb; theirs jsonb;
begin
  if not public._money_ok() then raise exception 'Only admins can change referrals'; end if;
  select * into me from public.profiles where id = p_user;
  if not found or me.referred_by is null then raise exception 'This person didn''t join with a code'; end if;
  select * into ref from public.profiles where id = me.referred_by;
  perform set_config('snappro.system', 'on', true);
  if p_action = 'hold' then
    update public.profiles set referral_flag = 'Held by admin' where id = p_user;
  elsif p_action = 'clear' then
    update public.profiles set referral_flag = null where id = p_user;
    perform set_config('snappro.system', '', true);
    perform public.referral_check(p_user);
    perform set_config('snappro.system', 'on', true);
  elsif p_action = 'remove' then
    if me.referral_rewarded_at is not null then raise exception 'Rewards were already given — this can''t be removed'; end if;
    update public.profiles set referred_by = null, referral_at = null, referral_flag = null where id = p_user;
  elsif p_action = 'reward' then
    if me.referral_rewarded_at is not null then raise exception 'Already rewarded'; end if;
    mine := prog->(case when me.role = 'photographer' then 'photographer' else 'customer' end);
    theirs := prog->(case when ref.role = 'photographer' then 'photographer' else 'customer' end);
    perform public._grant_benefit(p_user, mine->'new_user_reward', 'referral', null);
    perform public._grant_benefit(ref.id, theirs->'referrer_reward', 'referral', null);
    update public.profiles set referral_rewarded_at = now(), referral_flag = null where id = p_user;
  else
    raise exception 'Unknown action';
  end if;
  perform set_config('snappro.system', '', true);
  perform public._audit(case p_action when 'hold' then 'Held referral reward' when 'clear' then 'Cleared referral hold'
                                      when 'remove' then 'Removed referral link' else 'Gave referral reward' end,
                        'user', p_user::text, me.name, jsonb_build_object('inviter', ref.public_id));
  return 'ok';
end $$;

revoke all on function public._channel(text, text, text, text)       from public;
revoke all on function public._lead_channel(uuid, text)              from public;
revoke all on function public._money_ok()                             from public, anon, authenticated;
revoke all on function public.admin_leads(date, date)                 from public, anon;
revoke all on function public.admin_marketing(date, date, text)       from public, anon;
revoke all on function public.admin_finance(date, date, text)         from public, anon;
revoke all on function public.admin_ops(date, date)                   from public, anon;
revoke all on function public.admin_customers()                       from public, anon;
revoke all on function public.admin_trust()                           from public, anon;
revoke all on function public.admin_timeline(timestamptz, timestamptz, text, uuid, int) from public, anon;
revoke all on function public.admin_user_360(text)                    from public, anon;
revoke all on function public.admin_referrals(date, date)             from public, anon;
revoke all on function public.admin_referral_action(uuid, text)       from public, anon;
grant execute on function public._channel(text, text, text, text)     to anon, authenticated;
grant execute on function public._lead_channel(uuid, text)            to authenticated;
grant execute on function public.admin_leads(date, date)              to authenticated;
grant execute on function public.admin_marketing(date, date, text)    to authenticated;
grant execute on function public.admin_finance(date, date, text)      to authenticated;
grant execute on function public.admin_ops(date, date)                to authenticated;
grant execute on function public.admin_customers()                    to authenticated;
grant execute on function public.admin_trust()                        to authenticated;
grant execute on function public.admin_timeline(timestamptz, timestamptz, text, uuid, int) to authenticated;
grant execute on function public.admin_user_360(text)                 to authenticated;
grant execute on function public.admin_referrals(date, date)          to authenticated;
grant execute on function public.admin_referral_action(uuid, text)    to authenticated;
-- <<< 8d departments

-- >>> 8e deletion
-- =====================================================================
-- 8e. ACCOUNT DELETION (required by Google Play)
--     People delete their own account from the app (or ask by email).
--     Personal details are erased straight away. Booking, payment and
--     tax records stay (without the name, email or phone) because the
--     law requires them. Not allowed while a shoot is under way or
--     money is still owed either way.
-- =====================================================================

create table if not exists public.account_deletions (
  id           bigserial primary key,
  user_id      uuid not null,
  public_id    text,
  role         text,
  reason       text,
  via          text not null default 'app',            -- app / admin
  deleted_at   timestamptz not null default now(),
  deleted_by   uuid,
  login_closed boolean not null default false           -- false = remove the login in Supabase → Authentication → Users
);
create index if not exists idx_deletions_at on public.account_deletions(deleted_at desc);
alter table public.account_deletions enable row level security;
drop policy if exists deletions_staff_read on public.account_deletions;
create policy deletions_staff_read on public.account_deletions for select to authenticated
  using (coalesce(public.staff_role() in ('super_admin','admin'), false));
revoke insert, update, delete on public.account_deletions from anon, authenticated;

-- people may remove their own ID-check photos (the app does this when the account is deleted)
drop policy if exists "snappro kyc delete own" on storage.objects;
create policy "snappro kyc delete own" on storage.objects for delete to authenticated
  using (bucket_id = 'kyc' and (storage.foldername(name))[1] = auth.uid()::text);
drop policy if exists "snappro kyc admin delete" on storage.objects;
create policy "snappro kyc admin delete" on storage.objects for delete to authenticated
  using (bucket_id = 'kyc' and coalesce(public.staff_role() in ('super_admin','admin'), false));

-- what stops a deletion right now (empty list = OK)
create or replace function public._deletion_blockers(p_user uuid)
returns jsonb language sql stable security definer set search_path = public
as $$
  select coalesce(jsonb_agg(x), '[]') from (
    select 'You have a shoot that is booked or under way. Finish or cancel it first.' x
     where exists (select 1 from public.bookings b where (b.customer_id = p_user or b.photographer_id = p_user)
                     and b.status in ('confirmed','enroute','arrived','shooting'))
    union all
    select 'You still owe the balance for a shoot. Please pay it first.'
     where exists (select 1 from public.bookings b where b.customer_id = p_user and b.balance_status = 'due' and b.status <> 'cancelled')
    union all
    select 'SnapPro still has to pay you for a shoot. We''ll send it first, then you can delete your account.'
     where exists (select 1 from public.bookings b where b.photographer_id = p_user and b.payout_status in ('due','on_hold'))
    union all
    select 'A refund to you is still being processed. Please wait for it to finish.'
     where exists (select 1 from public.bookings b where b.customer_id = p_user and b.payment_status in ('refund_due','refund_pending'))
    union all
    select 'Staff accounts are removed from the Team tab of the admin console.'
     where exists (select 1 from public.staff s where s.id = p_user)
  ) z $$;
revoke all on function public._deletion_blockers(uuid) from public, anon, authenticated;

create or replace function public.account_deletion_check()
returns jsonb language plpgsql stable security definer set search_path = public
as $$
declare me uuid := auth.uid();
begin
  if me is null then raise exception 'Please log in again'; end if;
  return jsonb_build_object('blockers', public._deletion_blockers(me));
end $$;

-- erase one person's personal details (server only)
create or replace function public._erase_account(p_user uuid, p_reason text, p_via text, p_by uuid)
returns jsonb language plpgsql security definer set search_path = public
as $$
declare pr record; files jsonb; closed boolean := false;
begin
  select * into pr from public.profiles where id = p_user;
  if not found then raise exception 'Account not found'; end if;
  if pr.name = 'Deleted user' and pr.status = 'blocked' then raise exception 'This account was already deleted'; end if;
  files := jsonb_build_object(
    'kyc', (select coalesce(jsonb_agg(x), '[]') from (select unnest(array[k.front_path, k.back_path, k.selfie_path]) x from public.photographer_kyc k where k.id = p_user) z where x is not null),
    'portfolio_bucket', (select coalesce(to_jsonb(g.portfolio), '[]') from public.photographers g where g.id = p_user));

  perform set_config('snappro.system', 'on', true);
  update public.profiles set name = 'Deleted user', phone = null, email = null, area = null, pincode = null,
         acq = null, visitor_id = null, referral_flag = null,
         status = 'blocked', status_reason = 'Account deleted', status_until = null, status_at = now()
   where id = p_user;
  update public.photographers set display_name = 'Deleted photographer', bio = '', portfolio = '{}', categories = '{}',
         areas = '{}', is_online = false, is_verified = false, approval_status = 'rejected', review_note = 'Account deleted'
   where id = p_user;
  update public.portfolio_media set status = 'hidden', hidden_at = now() - interval '31 days', updated_at = now()
   where photographer_id = p_user and status in ('ready','pending','hidden');          -- removed from S3 on the next clean-up
  delete from public.photographer_payout where id = p_user;
  delete from public.photographer_kyc where id = p_user;
  update public.user_benefits set status = 'revoked' where user_id = p_user and status = 'active';
  update public.requests set status = 'cancelled' where customer_id = p_user and status in ('broadcasting','awaiting');
  update public.requests set customer_name = 'Deleted user', notes = null where customer_id = p_user;
  update public.bookings set customer_name = 'Deleted user', address = null where customer_id = p_user;
  update public.bookings set photographer_name = 'Deleted photographer' where photographer_id = p_user;
  update public.reviews set customer_name = 'Deleted user' where customer_id = p_user;
  update public.offers set photographer_name = 'Deleted photographer' where photographer_id = p_user;
  update public.site_visits set user_id = null where user_id = p_user;
  delete from public.push_subscriptions where user_id = p_user;          -- stop notifications to their phones
  perform set_config('snappro.system', '', true);

  -- close the login: free the email and stop sign-in (skipped quietly if the database doesn't allow it)
  begin
    update auth.users set email = 'deleted-' || p_user || '@deleted.snappro.in', phone = null,
           raw_user_meta_data = '{}'::jsonb where id = p_user;
    begin execute 'update auth.users set banned_until = ''infinity'' where id = $1' using p_user; exception when others then null; end;
    closed := true;
  exception when others then closed := false; end;

  insert into public.account_deletions (user_id, public_id, role, reason, via, deleted_by, login_closed)
  values (p_user, pr.public_id, pr.role, left(p_reason, 500), p_via, p_by, closed);
  perform public._ev('account_deleted', 'profile', p_user, p_user, null, pr.city, null, null,
                     jsonb_build_object('via', p_via, 'reason', left(p_reason, 200)));
  return jsonb_build_object('result', 'deleted', 'files', files, 'login_closed', closed);
end $$;
revoke all on function public._erase_account(uuid, text, text, uuid) from public, anon, authenticated;

-- the person themselves, from the app
create or replace function public.delete_my_account(p_confirm text, p_reason text default null)
returns jsonb language plpgsql security definer set search_path = public
as $$
declare me uuid := auth.uid(); b jsonb;
begin
  if me is null then raise exception 'Please log in again'; end if;
  if upper(trim(coalesce(p_confirm, ''))) <> 'DELETE' then raise exception 'Type DELETE to confirm'; end if;
  b := public._deletion_blockers(me);
  if jsonb_array_length(b) > 0 then raise exception '%', b->>0; end if;
  return public._erase_account(me, p_reason, 'app', me);
end $$;

-- an admin, for someone who asked by email
create or replace function public.admin_delete_account(p_user uuid, p_reason text)
returns jsonb language plpgsql security definer set search_path = public
as $$
declare b jsonb; r jsonb; pr record;
begin
  if not public._money_ok() then raise exception 'Only admins can delete accounts'; end if;
  if coalesce(trim(p_reason), '') = '' then raise exception 'Write why (for example: asked by email on 12 Oct)'; end if;
  b := public._deletion_blockers(p_user);
  if jsonb_array_length(b) > 0 then raise exception 'Can''t delete yet: %', b->>0; end if;
  select public_id, name into pr from public.profiles where id = p_user;
  r := public._erase_account(p_user, p_reason, 'admin', auth.uid());
  perform public._audit('Deleted account', 'user', p_user::text, coalesce(pr.public_id, '') || ' ' || coalesce(pr.name, ''), jsonb_build_object('reason', p_reason));
  return r;
end $$;

create or replace function public.admin_deletions()
returns jsonb language sql stable security definer set search_path = public
as $$ select case when public._money_ok() then (select coalesce(jsonb_agg(d order by d.deleted_at desc), '[]') from public.account_deletions d) end $$;

revoke all on function public.account_deletion_check()               from public, anon;
revoke all on function public.delete_my_account(text, text)          from public, anon;
revoke all on function public.admin_delete_account(uuid, text)       from public, anon;
revoke all on function public.admin_deletions()                      from public, anon;
grant execute on function public.account_deletion_check()            to authenticated;
grant execute on function public.delete_my_account(text, text)       to authenticated;
grant execute on function public.admin_delete_account(uuid, text)    to authenticated;
grant execute on function public.admin_deletions()                   to authenticated;
-- <<< 8e deletion

-- >>> 8f moderation
-- =====================================================================
-- 8f. REPORT & BLOCK (required by Google Play for apps where people
--     message each other)
--     • Anyone can report a photographer or customer: their profile, a
--       quote, a shoot request, a review or a booking's chat. A copy of
--       what was reported is kept, so staff see it even if it's edited.
--       Staff get an email and handle it in Admin → Trust & support.
--     • Blocking works both ways: the two people stop seeing each
--       other's requests and quotes, and can't message, call or book
--       each other. It doesn't cancel a shoot that's already booked.
-- =====================================================================

create table if not exists public.user_blocks (
  blocker_id uuid not null references public.profiles(id) on delete cascade,
  blocked_id uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (blocker_id, blocked_id),
  constraint user_blocks_not_self check (blocker_id <> blocked_id)
);
create index if not exists idx_blocks_blocked on public.user_blocks(blocked_id);
alter table public.user_blocks enable row level security;
drop policy if exists blocks_own_read on public.user_blocks;
create policy blocks_own_read on public.user_blocks for select to authenticated using (blocker_id = auth.uid());
revoke insert, update, delete on public.user_blocks from anon, authenticated;

create table if not exists public.user_reports (
  id          bigserial primary key,
  reporter_id uuid not null references public.profiles(id) on delete cascade,
  reported_id uuid not null references public.profiles(id) on delete cascade,
  reason      text not null check (reason in ('spam','abuse','inappropriate','fake','fraud','safety','other')),
  details     text,
  context     text not null default 'profile' check (context in ('profile','quote','request','review','booking')),
  context_id  text,
  snapshot    text,                 -- what was reported, as it was at the time
  booking_id  uuid,
  status      text not null default 'open' check (status in ('open','reviewing','resolved','dismissed')),
  action_note text,
  handled_by  uuid,
  handled_at  timestamptz,
  created_at  timestamptz not null default now()
);
create index if not exists idx_reports_status   on public.user_reports(status, created_at desc);
create index if not exists idx_reports_reported on public.user_reports(reported_id);
create index if not exists idx_reports_reporter on public.user_reports(reporter_id, created_at desc);
alter table public.user_reports enable row level security;
drop policy if exists reports_own_read on public.user_reports;
create policy reports_own_read on public.user_reports for select to authenticated using (reporter_id = auth.uid());
revoke insert, update, delete on public.user_reports from anon, authenticated;

-- has either of these two blocked the other? (server only)
create or replace function public._blocked_pair(a uuid, b uuid)
returns boolean language sql stable security definer set search_path = public
as $$ select a is not null and b is not null and exists (select 1 from public.user_blocks
          where (blocker_id = a and blocked_id = b) or (blocker_id = b and blocked_id = a)) $$;
revoke all on function public._blocked_pair(uuid, uuid) from public, anon, authenticated;
-- the same question about the signed-in person and someone else (used by the access rules)
create or replace function public.blocked_with(p_other uuid)
returns boolean language sql stable security definer set search_path = public
as $$ select public._blocked_pair(auth.uid(), p_other) $$;
revoke all on function public.blocked_with(uuid) from public, anon;
grant execute on function public.blocked_with(uuid) to authenticated;

-- open requests: approved photographers who aren't suspended, and who haven't blocked (or been blocked by) the customer
drop policy if exists requests_select on public.requests;
create policy requests_select on public.requests for select to authenticated
  using (customer_id = auth.uid()
         or (status = 'broadcasting' and expires_at > now()
             and exists (select 1 from public.photographers g where g.id = auth.uid() and g.approval_status = 'approved')
             and not public.is_blocked(auth.uid())
             and not public.blocked_with(customer_id)));
-- quotes: customers don't see quotes from someone either of them has blocked
drop policy if exists offers_select on public.offers;
create policy offers_select on public.offers for select to authenticated
  using (photographer_id = auth.uid()
         or (exists (select 1 from public.requests r where r.id = offers.request_id and r.customer_id = auth.uid())
             and not public.blocked_with(offers.photographer_id)));

-- no quotes, bookings or messages between two people when one has blocked the other
create or replace function public.pair_guard()
returns trigger language plpgsql security definer set search_path = public
as $$
declare me uuid := auth.uid(); other uuid; b record;
begin
  if me is null then return new; end if;
  if tg_table_name = 'offers' then
    select customer_id into other from public.requests where id = new.request_id;
    if public._blocked_pair(me, other) then raise exception 'This request isn''t available any more.'; end if;
  elsif tg_table_name = 'bookings' then
    select photographer_id into other from public.offers where id = new.offer_id;
    if exists (select 1 from public.user_blocks where blocker_id = me and blocked_id = other) then
      raise exception 'You blocked this photographer. Unblock them in Profile → Blocked people to book them.'; end if;
    if public._blocked_pair(me, other) then raise exception 'This photographer isn''t available. Please pick another quote.'; end if;
  elsif tg_table_name = 'messages' then
    select customer_id, photographer_id into b from public.bookings where id = new.booking_id;
    other := case when b.customer_id = me then b.photographer_id else b.customer_id end;
    if exists (select 1 from public.user_blocks where blocker_id = me and blocked_id = other) then
      raise exception 'You blocked this person. Unblock them to send messages.'; end if;
    if public._blocked_pair(me, other) then raise exception 'You can''t send messages in this chat.'; end if;
  end if;
  return new;
end $$;
drop trigger if exists pair_guard on public.offers;
create trigger pair_guard before insert on public.offers for each row execute function public.pair_guard();
drop trigger if exists pair_guard on public.bookings;
create trigger pair_guard before insert on public.bookings for each row execute function public.pair_guard();
drop trigger if exists pair_guard on public.messages;
create trigger pair_guard before insert on public.messages for each row execute function public.pair_guard();

-- private Realtime channels "call:<token>" for in-app calls: only the booking's two people may join
-- (skipped if Realtime isn't available). Calls between people who blocked each other are stopped in
-- the app, and call_notify() won't ring them.
do $$ begin
  execute 'drop policy if exists "snappro call parties read" on realtime.messages';
  execute 'create policy "snappro call parties read" on realtime.messages for select to authenticated using (
             exists (select 1 from public.bookings b where ''call:'' || b.call_token::text = realtime.topic()
                      and (b.customer_id = auth.uid() or b.photographer_id = auth.uid())))';
  execute 'drop policy if exists "snappro call parties send" on realtime.messages';
  execute 'create policy "snappro call parties send" on realtime.messages for insert to authenticated with check (
             exists (select 1 from public.bookings b where ''call:'' || b.call_token::text = realtime.topic()
                      and (b.customer_id = auth.uid() or b.photographer_id = auth.uid())))';
exception when others then raise notice 'Realtime policies skipped: %', sqlerrm; end $$;

-- block or unblock someone
create or replace function public.block_user(p_user uuid, p_block boolean default true)
returns jsonb language plpgsql security definer set search_path = public
as $$
declare me uuid := auth.uid(); city text;
begin
  if me is null then raise exception 'Please log in again'; end if;
  if p_user is null or p_user = me then raise exception 'You can''t block yourself'; end if;
  if not exists (select 1 from public.profiles where id = p_user) then raise exception 'Account not found'; end if;
  select p.city into city from public.profiles p where p.id = me;
  if coalesce(p_block, true) then
    if exists (select 1 from public.staff where id = p_user) then raise exception 'You can''t block the SnapPro team. Write to snappro.support@gmail.com instead.'; end if;
    insert into public.user_blocks (blocker_id, blocked_id) values (me, p_user) on conflict do nothing;
    if found then perform public._ev('user_blocked', 'profile', p_user, me, p_user, city, null, null, null); end if;
  else
    delete from public.user_blocks where blocker_id = me and blocked_id = p_user;
    if found then perform public._ev('user_unblocked', 'profile', p_user, me, p_user, city, null, null, null); end if;
  end if;
  return jsonb_build_object('blocked', coalesce(p_block, true));
end $$;

-- the people I've blocked
create or replace function public.my_blocks()
returns jsonb language sql stable security definer set search_path = public
as $$ select coalesce(jsonb_agg(jsonb_build_object('id', b.blocked_id, 'name', coalesce(g.display_name, p.name, 'SnapPro user'),
                                                   'role', p.role, 'at', b.created_at) order by b.created_at desc), '[]')
         from public.user_blocks b join public.profiles p on p.id = b.blocked_id
         left join public.photographers g on g.id = b.blocked_id
        where b.blocker_id = auth.uid() $$;

-- report someone (and optionally block them in the same step)
create or replace function public.report_user(p_user uuid, p_reason text, p_details text default null,
                                              p_context text default 'profile', p_context_id text default null, p_block boolean default false)
returns jsonb language plpgsql security definer set search_path = public
as $$
declare me uuid := auth.uid(); ctx text := coalesce(nullif(trim(p_context), ''), 'profile'); cid uuid;
        snap text; bk uuid; det text := nullif(left(trim(coalesce(p_details, '')), 1000), ''); rid bigint; r record; city text;
begin
  if me is null then raise exception 'Please log in again'; end if;
  perform public._check_not_blocked();
  if p_user is null or p_user = me then raise exception 'You can''t report yourself'; end if;
  if not exists (select 1 from public.profiles where id = p_user) then raise exception 'Account not found'; end if;
  if p_reason is null or p_reason not in ('spam','abuse','inappropriate','fake','fraud','safety','other') then raise exception 'Choose what''s wrong'; end if;
  if p_reason = 'other' and det is null then raise exception 'Tell us what happened'; end if;
  if ctx not in ('profile','quote','request','review','booking') then raise exception 'That can''t be reported'; end if;
  if ctx <> 'profile' then
    begin cid := p_context_id::uuid; exception when others then raise exception 'That can''t be reported'; end;
    if cid is null then raise exception 'That can''t be reported'; end if;
  end if;

  if ctx = 'profile' then
    select nullif(g.bio, '') into snap from public.photographers g where g.id = p_user;
  elsif ctx = 'quote' then          -- a quote sent to one of my requests
    select o.price, o.note into r from public.offers o join public.requests q on q.id = o.request_id
     where o.id = cid and o.photographer_id = p_user and q.customer_id = me;
    if not found then raise exception 'That can''t be reported'; end if;
    snap := 'Quote ₹' || r.price || coalesce(' — ' || nullif(r.note, ''), '');
  elsif ctx = 'request' then        -- a request a photographer could see
    select q.notes, q.category, q.city into r from public.requests q where q.id = cid and q.customer_id = p_user;
    if not found or not exists (select 1 from public.photographers g where g.id = me) then raise exception 'That can''t be reported'; end if;
    snap := coalesce(r.category, '') || ' shoot in ' || coalesce(r.city, '') || coalesce(' — ' || nullif(r.notes, ''), '');
  elsif ctx = 'review' then         -- reviews are public
    select v.stars, v.body, v.booking_id into r from public.reviews v where v.id = cid and v.customer_id = p_user;
    if not found then raise exception 'That can''t be reported'; end if;
    snap := repeat('★', r.stars) || coalesce(' — ' || nullif(r.body, ''), ''); bk := r.booking_id;
  elsif ctx = 'booking' then        -- a booking between us; keep the latest messages from both sides
    if not exists (select 1 from public.bookings b where b.id = cid
                    and ((b.customer_id = me and b.photographer_id = p_user) or (b.photographer_id = me and b.customer_id = p_user))) then
      raise exception 'That can''t be reported'; end if;
    bk := cid;
    select string_agg(case when m.sender_id = p_user then 'Them: ' else 'Me: ' end || m.content, E'\n' order by m.created_at) into snap
      from (select * from public.messages where booking_id = cid order by created_at desc limit 30) m;
  end if;

  if (select count(*) from public.user_reports where reporter_id = me and created_at > now() - interval '1 day') >= 10 then
    raise exception 'You''ve sent a lot of reports today. Please email snappro.support@gmail.com and we''ll help.'; end if;

  select id into rid from public.user_reports
   where reporter_id = me and reported_id = p_user and context = ctx and coalesce(context_id, '') = coalesce(cid::text, '')
     and status in ('open','reviewing') limit 1;
  if rid is null then
    insert into public.user_reports (reporter_id, reported_id, reason, details, context, context_id, snapshot, booking_id)
    values (me, p_user, p_reason, det, ctx, cid::text, left(snap, 4000), bk) returning id into rid;
    select p.city into city from public.profiles p where p.id = me;
    perform public._ev('user_reported', 'profile', p_user, me, p_user, city, null, null, jsonb_build_object('reason', p_reason, 'context', ctx, 'report', rid));
    begin
      perform public._send_email('snappro.support@gmail.com', 'New report on SnapPro (#' || rid || ')',
        public._email_shell('Someone reported a ' || coalesce((select role from public.profiles where id = p_user), 'member') || '.',
          'Reason: ' || public._esc(p_reason) || '. Report #' || rid || '. Open Admin → Trust &amp; support to look into it.',
          'Open admin', 'https://snappro.in/admin.html'));
    exception when others then null; end;
  end if;
  if coalesce(p_block, false) then perform public.block_user(p_user, true); end if;
  return jsonb_build_object('result', 'reported', 'id', rid, 'blocked', coalesce(p_block, false));
end $$;

-- staff: mark a report as being looked at, resolved or dismissed
create or replace function public.admin_report_action(p_id bigint, p_status text, p_note text default null)
returns text language plpgsql security definer set search_path = public
as $$
declare r record; nm text;
begin
  if not public._money_ok() then raise exception 'Only admins can handle reports'; end if;
  if p_status not in ('open','reviewing','resolved','dismissed') then raise exception 'Unknown status'; end if;
  update public.user_reports set status = p_status, action_note = coalesce(nullif(left(trim(coalesce(p_note, '')), 500), ''), action_note),
         handled_by = auth.uid(), handled_at = now()
   where id = p_id returning * into r;
  if not found then raise exception 'Report not found'; end if;
  select coalesce(public_id || ' ', '') || coalesce(name, '') into nm from public.profiles where id = r.reported_id;
  perform public._audit('Report #' || p_id || ': ' || p_status, 'user', r.reported_id::text, nm, jsonb_build_object('reason', r.reason, 'note', p_note));
  return p_status;
end $$;

revoke all on function public.pair_guard()                                      from public, anon, authenticated;
revoke all on function public.block_user(uuid, boolean)                         from public, anon;
revoke all on function public.my_blocks()                                       from public, anon;
revoke all on function public.report_user(uuid, text, text, text, text, boolean) from public, anon;
revoke all on function public.admin_report_action(bigint, text, text)           from public, anon;
grant execute on function public.block_user(uuid, boolean)                      to authenticated;
grant execute on function public.my_blocks()                                    to authenticated;
grant execute on function public.report_user(uuid, text, text, text, text, boolean) to authenticated;
grant execute on function public.admin_report_action(bigint, text, text)        to authenticated;
-- <<< 8f moderation

-- >>> 8g travel
-- =====================================================================
-- 8g. PHOTOGRAPHERS WHO TRAVEL
--     Each photographer says how far they'll go for a shoot:
--       city     — only their own city (everyone starts here)
--       nearby   — their metro area (e.g. all of Delhi NCR), or their state
--       anywhere — anywhere in India
--     A customer in Noida then sees Delhi photographers who travel to
--     NCR, and those photographers see (and are alerted about) Noida
--     requests. The same areas are listed in the app (v3_data.js REGIONS).
-- =====================================================================

alter table public.photographers add column if not exists travel text not null default 'city';
do $$ begin
  alter table public.photographers add constraint photographers_travel_check check (travel in ('city','nearby','anywhere'));
exception when duplicate_object then null; end $$;

-- the metro area a city belongs to, or its state
create or replace function public._region(p_city text, p_state text)
returns text language sql immutable
as $$ select case
    when lower(trim(coalesce(p_city, ''))) in ('delhi','new delhi','noida','greater noida','gurugram','gurgaon','ghaziabad','faridabad','sonipat') then 'ncr'
    when lower(trim(coalesce(p_city, ''))) in ('mumbai','thane','navi mumbai','kalyan','vasai-virar','panvel') then 'mumbai'
    when lower(trim(coalesce(p_city, ''))) in ('chandigarh','mohali','panchkula') then 'tricity'
    when lower(trim(coalesce(p_city, ''))) in ('hyderabad','secunderabad') then 'hyderabad'
    when lower(trim(coalesce(p_city, ''))) in ('kolkata','howrah') then 'kolkata'
    else 'state:' || lower(trim(coalesce(p_state, ''))) end $$;

-- will a photographer (travel, city, state) take a shoot in this city?
create or replace function public._pg_covers(p_travel text, p_city text, p_state text, r_city text, r_state text)
returns boolean language sql immutable
as $$ select case coalesce(p_travel, 'city')
    when 'anywhere' then true
    when 'nearby' then lower(trim(coalesce(p_city, ''))) = lower(trim(coalesce(r_city, '')))
                       or public._region(p_city, p_state) = public._region(r_city, r_state)
    else r_city is null or p_city is null or lower(trim(p_city)) = lower(trim(r_city)) end $$;
-- <<< 8g travel

-- >>> 8h notifications
-- =====================================================================
-- 8h. PHONE NOTIFICATIONS (web push) — even when SnapPro is closed
--     • Each phone/browser that allows notifications saves a "push
--       subscription" here (only to Google, Mozilla, Apple or Microsoft
--       push servers).
--     • Things that matter to someone (a new quote, being booked, the
--       photographer on the way, a message, a call, a new request near a
--       photographer…) are turned into notifications from the event log.
--     • The Edge Function "push" sends them, signed with the VAPID key.
--       The database wakes it up with a secret kept in Vault
--       (push_hook_secret); nothing secret is in the website.
-- =====================================================================

create table if not exists public.push_subscriptions (
  id         bigserial primary key,
  user_id    uuid not null references public.profiles(id) on delete cascade,
  endpoint   text not null unique,
  p256dh     text not null,
  auth       text not null,
  device     text,
  created_at timestamptz not null default now(),
  last_ok_at timestamptz,
  fails      int not null default 0
);
create index if not exists idx_push_subs_user on public.push_subscriptions(user_id);
-- what the phone itself reported back (proves a notification reached the phone and was shown)
alter table public.push_subscriptions
  add column if not exists last_received_at timestamptz,
  add column if not exists last_shown_ok    boolean,
  add column if not exists last_error       text,
  add column if not exists sw_version       text,
  add column if not exists permission       text;
alter table public.push_subscriptions enable row level security;
drop policy if exists push_subs_own on public.push_subscriptions;
create policy push_subs_own on public.push_subscriptions for select to authenticated using (user_id = auth.uid());
revoke insert, update, delete on public.push_subscriptions from anon, authenticated;

create table if not exists public.push_outbox (
  id         bigserial primary key,
  user_id    uuid not null references public.profiles(id) on delete cascade,
  kind       text not null,
  title      text not null,
  body       text,
  url        text,
  tag        text,
  created_at timestamptz not null default now(),
  taken_at   timestamptz,
  sent       int,                 -- phones it reached
  failed     int
);
create index if not exists idx_push_outbox_todo on public.push_outbox(created_at) where taken_at is null;
alter table public.push_outbox enable row level security;
revoke all on public.push_outbox from anon, authenticated;

insert into public.platform_settings (key, value) values ('push_function_url', '"https://eafudrjxjtenqoorjzsc.supabase.co/functions/v1/push"')
on conflict (key) do nothing;
-- the public half of the VAPID key goes in 'push_public_key' (see SnapPro-Push-Keys.html on the Desktop)

-- this phone wants notifications
create or replace function public.push_subscribe(p_endpoint text, p_p256dh text, p_auth text, p_device text default null)
returns text language plpgsql security definer set search_path = public
as $$
declare me uuid := auth.uid(); host text;
begin
  if me is null then raise exception 'Please log in again'; end if;
  host := lower(substring(coalesce(p_endpoint, '') from '^https://([^/:]+)/'));
  if host is null or not (host = 'fcm.googleapis.com' or host = 'android.googleapis.com' or host like '%.push.services.mozilla.com'
                          or host = 'web.push.apple.com' or host like '%.push.apple.com' or host like '%.notify.windows.com') then
    raise exception 'This browser''s notification service isn''t supported';
  end if;
  if length(p_endpoint) > 1000 or coalesce(p_p256dh, '') !~ '^[A-Za-z0-9_-]{80,100}$' or coalesce(p_auth, '') !~ '^[A-Za-z0-9_-]{16,30}$' then
    raise exception 'Notification keys look wrong';
  end if;
  insert into public.push_subscriptions (user_id, endpoint, p256dh, auth, device)
  values (me, p_endpoint, p_p256dh, p_auth, left(p_device, 80))
  on conflict (endpoint) do update set user_id = me, p256dh = excluded.p256dh, auth = excluded.auth, device = excluded.device, fails = 0;
  -- keep the newest 5 phones per person
  delete from public.push_subscriptions where user_id = me and id not in
    (select id from public.push_subscriptions where user_id = me order by created_at desc limit 5);
  return 'on';
end $$;

create or replace function public.push_unsubscribe(p_endpoint text)
returns text language sql security definer set search_path = public
as $$ delete from public.push_subscriptions where endpoint = p_endpoint and user_id = auth.uid(); select 'off'::text $$;

-- queue one notification (only for people with notifications on, never to the person who did it)
create or replace function public._push(p_user uuid, p_kind text, p_title text, p_body text, p_url text, p_tag text)
returns void language plpgsql security definer set search_path = public
as $$
begin
  if p_user is null or p_user = auth.uid() then return; end if;
  if not exists (select 1 from public.push_subscriptions where user_id = p_user) then return; end if;
  insert into public.push_outbox (user_id, kind, title, body, url, tag)
  values (p_user, p_kind, left(p_title, 120), left(p_body, 240), coalesce(p_url, '/app.html'), left(p_tag, 60));
end $$;

create or replace function public._cat_name(c text) returns text language sql immutable
as $$ select case coalesce(c, '') when 'event' then 'event' when 'realestate' then 'real estate' when 'street' then 'candid'
                  when '' then 'photo' else replace(c, '_', ' ') end $$;
create or replace function public._when(t timestamptz) returns text language sql stable
as $$ select to_char(t at time zone 'Asia/Kolkata', 'Dy DD Mon, FMHH12:MI AM') $$;
create or replace function public._first(p uuid) returns text language sql stable security definer set search_path = public
as $$ select coalesce(nullif(split_part(trim(coalesce((select display_name from public.photographers where id = p),
                                                       (select name from public.profiles where id = p), '')), ' ', 1), ''), 'Someone') $$;

-- turn events into notifications
create or replace function public._push_for_event(e public.event_log)
returns void language plpgsql security definer set search_path = public
as $$
declare b record; r record; who text; n int := 0; link text;
begin
  if e.kind = 'quote_sent' then
    perform public._push(e.other_id, 'quote', 'New quote: ₹' || to_char(e.amount, 'FM99,99,99,999'),
      public._first(e.user_id) || ' sent a quote for your ' || public._cat_name(e.category) || ' shoot. Tap to compare.',
      '/app.html?open=request&id=' || e.entity_id, 'req-' || e.entity_id);

  elsif e.kind = 'request_posted' then                    -- photographers who'd take it and are available
    select * into r from public.requests where id = e.entity_id;
    if not found then return; end if;
    for b in select g.id from public.photographers g join public.profiles p on p.id = g.id
              where g.approval_status = 'approved' and g.is_online and g.id <> r.customer_id
                and not public.is_blocked(g.id) and not public._blocked_pair(g.id, r.customer_id)
                and (cardinality(coalesce(g.categories, '{}')) = 0 or r.category = any(g.categories))
                and public._pg_covers(g.travel, coalesce(g.city, p.city), coalesce(g.state, p.state), r.city, r.state)
                and exists (select 1 from public.push_subscriptions s where s.user_id = g.id)
              limit 300 loop
      perform public._push(b.id, 'request', 'New ' || public._cat_name(r.category) || ' shoot in ' || coalesce(r.city, 'your area'),
        'Budget ₹' || to_char(r.budget, 'FM99,99,99,999') || ' · ' || public._when(r.start_at) || '. Send your price before it closes.',
        '/app.html?open=quote&id=' || r.id, 'req-' || r.id);
    end loop;

  elsif e.kind like 'booking_%' and e.entity = 'booking' then
    select * into b from public.bookings where id = e.entity_id;
    if not found then return; end if;
    link := '/app.html?open=booking&id=' || b.id;
    if e.kind = 'booking_confirmed' then
      perform public._push(b.photographer_id, 'booking', 'You''re booked!',
        public._first(b.customer_id) || ' booked you for a ' || public._cat_name(b.category) || ' shoot on ' || public._when(b.start_at) || '.', link, 'bk-' || b.id);
    elsif e.kind in ('booking_enroute','booking_arrived','booking_shooting','booking_completed') then
      who := public._first(b.photographer_id);
      perform public._push(b.customer_id, 'booking',
        case e.kind when 'booking_enroute' then who || ' is on the way' when 'booking_arrived' then who || ' has arrived'
                    when 'booking_shooting' then 'Your shoot has started' else 'Your shoot is complete' end,
        case e.kind when 'booking_completed' then 'Tap to rate ' || who || ' and see your booking.'
                    when 'booking_shooting' then 'You can pay the balance in the app.' else 'Tap to see your booking.' end, link, 'bk-' || b.id);
    elsif e.kind = 'booking_cancelled' then
      if coalesce(e.info->>'cancelled_by', '') <> 'customer' then
        perform public._push(b.customer_id, 'booking', 'Booking cancelled', public._first(b.photographer_id) || ' cancelled your ' || public._cat_name(b.category) || ' shoot. Your advance comes back to you.', link, 'bk-' || b.id); end if;
      if coalesce(e.info->>'cancelled_by', '') <> 'photographer' and b.status <> 'pending_payment' then
        perform public._push(b.photographer_id, 'booking', 'Booking cancelled', public._first(b.customer_id) || ' cancelled the ' || public._cat_name(b.category) || ' shoot on ' || public._when(b.start_at) || '.', link, 'bk-' || b.id); end if;
    end if;

  elsif e.kind = 'chat_message' then
    select m.content into who from public.messages m where m.booking_id = e.entity_id and m.sender_id = e.user_id order by m.created_at desc limit 1;
    perform public._push(e.other_id, 'message', public._first(e.user_id), coalesce(who, 'New message'),
      '/app.html?open=chat&id=' || e.entity_id, 'chat-' || e.entity_id);

  elsif e.kind = 'balance_due' then
    perform public._push(e.user_id, 'payment', 'Balance due: ₹' || to_char(e.amount, 'FM99,99,99,999'), 'Pay the rest of your booking in SnapPro — no cash needed.',
      '/app.html?open=booking&id=' || e.entity_id, 'bk-' || e.entity_id);
  elsif e.kind = 'payout_paid' then
    perform public._push(e.user_id, 'payment', '₹' || to_char(e.amount, 'FM99,99,99,999') || ' sent to you', 'Your payout for a completed shoot is on its way to your UPI.',
      '/app.html?open=booking&id=' || e.entity_id, 'pay-' || e.entity_id);
  elsif e.kind = 'review_posted' then
    perform public._push(e.other_id, 'review', 'New review: ' || repeat('★', greatest(1, least(5, e.amount::int))), public._first(e.user_id) || ' rated your shoot.',
      '/app.html?open=reviews', 'rev-' || e.entity_id);
  elsif e.kind in ('pg_approved','pg_rejected','kyc_rejected') then
    perform public._push(e.user_id, 'account',
      case e.kind when 'pg_approved' then 'You''re approved on SnapPro' when 'pg_rejected' then 'Your profile needs a change' else 'Please re-do your ID check' end,
      case e.kind when 'pg_approved' then 'Customers can see your profile now. Turn on Available to get requests.' else 'Open SnapPro to see what to fix.' end,
      '/app.html', 'acct');
  end if;
end $$;

create or replace function public.push_from_event()
returns trigger language plpgsql security definer set search_path = public
as $$ begin
  begin perform public._push_for_event(new); exception when others then null; end;   -- never block the real action
  return new;
end $$;
drop trigger if exists push_from_event on public.event_log;
create trigger push_from_event after insert on public.event_log for each row execute function public.push_from_event();

-- wake the "push" Edge Function (skipped quietly until the secret is set up)
create or replace function public.push_kick()
returns trigger language plpgsql security definer set search_path = public, extensions
as $$
declare secret text; url text;
begin
  begin select decrypted_secret into secret from vault.decrypted_secrets where name = 'push_hook_secret' limit 1;
  exception when others then secret := null; end;
  if coalesce(secret, '') = '' then return null; end if;
  select value #>> '{}' into url from public.platform_settings where key = 'push_function_url';
  begin
    perform net.http_post(url := url, body := '{}'::jsonb,
      headers := jsonb_build_object('content-type', 'application/json', 'x-push-secret', secret), timeout_milliseconds := 8000);
  exception when others then null; end;
  return null;
end $$;
drop trigger if exists push_kick on public.push_outbox;
create trigger push_kick after insert on public.push_outbox for each statement execute function public.push_kick();

-- someone is calling: ring the other phone even if SnapPro is closed
create or replace function public.call_notify(p_booking uuid)
returns text language plpgsql security definer set search_path = public
as $$
declare b record; me uuid := auth.uid(); other uuid;
begin
  select * into b from public.bookings where id = p_booking and (customer_id = me or photographer_id = me);
  if not found then raise exception 'That isn''t your booking'; end if;
  other := case when b.customer_id = me then b.photographer_id else b.customer_id end;
  if public._blocked_pair(me, other) or public.is_blocked(me) then return 'off'; end if;
  if exists (select 1 from public.push_outbox where user_id = other and tag = 'call-' || b.id and created_at > now() - interval '30 seconds') then return 'sent'; end if;
  perform public._push(other, 'call', '📞 ' || public._first(me) || ' is calling', 'SnapPro voice call — tap to answer',
    '/app.html?open=chat&id=' || b.id, 'call-' || b.id);
  return 'sent';
end $$;

-- the phone's service worker reports each notification it received and whether it could show it.
-- Only works for someone who knows the phone's secret push address; it only records a timestamp.
create or replace function public.push_ack(p_endpoint text, p_ok boolean, p_err text default null, p_ver text default null, p_perm text default null)
returns void language sql security definer set search_path = public
as $$ update public.push_subscriptions set last_received_at = now(), last_shown_ok = p_ok, last_error = left(p_err, 300),
          sw_version = left(p_ver, 20), permission = left(p_perm, 20)
     where endpoint = p_endpoint $$;
revoke all on function public.push_ack(text, boolean, text, text, text) from public;
grant execute on function public.push_ack(text, boolean, text, text, text) to anon, authenticated;
-- my phones and what they last reported (for the in-app test)
create or replace function public.my_push_status()
returns jsonb language sql stable security definer set search_path = public
as $$ select coalesce(jsonb_agg(jsonb_build_object('device', device, 'created_at', created_at, 'last_ok_at', last_ok_at,
            'last_received_at', last_received_at, 'last_shown_ok', last_shown_ok, 'last_error', last_error, 'sw_version', sw_version, 'endpoint_tail', right(endpoint, 12))), '[]')
     from public.push_subscriptions where user_id = auth.uid() $$;
revoke all on function public.my_push_status() from public, anon;
grant execute on function public.my_push_status() to authenticated;

-- "Send me a test notification" (Profile → Notifications): checks the whole chain on this phone
create or replace function public.push_test()
returns jsonb language plpgsql security definer set search_path = public
as $$
declare me uuid := auth.uid(); n int;
begin
  if me is null then raise exception 'Please log in again'; end if;
  select count(*) into n from public.push_subscriptions where user_id = me;
  if n = 0 then return jsonb_build_object('phones', 0); end if;
  if exists (select 1 from public.push_outbox where user_id = me and kind = 'test' and created_at > now() - interval '20 seconds') then
    raise exception 'Wait a few seconds before sending another test'; end if;
  insert into public.push_outbox (user_id, kind, title, body, url, tag)
  values (me, 'test', 'SnapPro notifications are working ✅', 'You''ll hear about quotes, bookings, messages and calls here.', '/app.html', 'test');
  return jsonb_build_object('phones', n);
end $$;
revoke all on function public.push_test() from public, anon;
grant execute on function public.push_test() to authenticated;

-- staff: is the notification chain healthy? (phones saved, what was sent, what the push function answered)
create or replace function public.admin_push_health()
returns jsonb language plpgsql security definer set search_path = public, extensions
as $$
declare res jsonb; hook boolean; resp jsonb;
begin
  if not public._money_ok() then raise exception 'Only admins'; end if;
  begin select exists (select 1 from vault.decrypted_secrets where name = 'push_hook_secret') into hook; exception when others then hook := null; end;
  begin
    select coalesce(jsonb_agg(z order by z.created desc), '[]') into resp from (
      select status_code, left(coalesce(content, error_msg, ''), 200) answer, created from net._http_response
       where created > now() - interval '1 day' and (content like '%"sent"%' or content like '%Notifications%' or content like '%Not allowed%' or content like '%went wrong%')
       order by created desc limit 15) z;
  exception when others then resp := null; end;
  select jsonb_build_object(
    'public_key_set', exists (select 1 from public.platform_settings where key = 'push_public_key'),
    'hook_secret_set', hook,
    'phones', (select count(*) from public.push_subscriptions),
    'people_with_notifications', (select count(distinct user_id) from public.push_subscriptions),
    'queued_last_day', (select count(*) from public.push_outbox where created_at > now() - interval '1 day'),
    'waiting', (select count(*) from public.push_outbox where taken_at is null and created_at > now() - interval '1 hour'),
    'delivered_last_day', (select coalesce(sum(sent), 0) from public.push_outbox where created_at > now() - interval '1 day'),
    'failed_last_day', (select coalesce(sum(failed), 0) from public.push_outbox where created_at > now() - interval '1 day'),
    'phones_list', (select coalesce(jsonb_agg(z order by z.created_at desc), '[]') from (
        select p.public_id, s.device, s.created_at, s.last_ok_at, s.last_received_at, s.last_shown_ok, s.last_error, s.sw_version, s.permission
          from public.push_subscriptions s left join public.profiles p on p.id = s.user_id order by s.created_at desc limit 50) z),
    'recent', (select coalesce(jsonb_agg(z order by z.created_at desc), '[]') from (
        select o.created_at, o.kind, o.title, o.taken_at is not null taken, o.sent, o.failed, p.public_id
          from public.push_outbox o left join public.profiles p on p.id = o.user_id order by o.id desc limit 15) z),
    'function_answers', resp) into res;
  return res;
end $$;
revoke all on function public.admin_push_health() from public, anon;
grant execute on function public.admin_push_health() to authenticated;

-- the Edge Function takes what's waiting (with the phones to send to), and reports back
create or replace function public.push_take(p_limit int default 200)
returns jsonb language plpgsql security definer set search_path = public
as $$
declare res jsonb;
begin
  delete from public.push_outbox where created_at < now() - interval '7 days';
  with t as (
    update public.push_outbox o set taken_at = now()
     where o.id in (select id from public.push_outbox where taken_at is null and created_at > now() - interval '1 hour'
                     order by id limit least(greatest(coalesce(p_limit, 200), 1), 1000) for update skip locked)
    returning o.*)
  select coalesce(jsonb_agg(jsonb_build_object('id', t.id, 'kind', t.kind, 'title', t.title, 'body', t.body, 'url', t.url, 'tag', t.tag,
           'subs', (select coalesce(jsonb_agg(jsonb_build_object('endpoint', s.endpoint, 'p256dh', s.p256dh, 'auth', s.auth)), '[]')
                      from public.push_subscriptions s where s.user_id = t.user_id))), '[]') into res from t;
  return res;
end $$;
create or replace function public.push_done(p_results jsonb)
returns void language plpgsql security definer set search_path = public
as $$
begin
  update public.push_outbox o set sent = (x->>'sent')::int, failed = (x->>'failed')::int
    from jsonb_array_elements(coalesce(p_results->'outbox', '[]')) x where o.id = (x->>'id')::bigint;
  delete from public.push_subscriptions where endpoint in (select jsonb_array_elements_text(coalesce(p_results->'gone', '[]')));
  update public.push_subscriptions set last_ok_at = now(), fails = 0 where endpoint in (select jsonb_array_elements_text(coalesce(p_results->'ok', '[]')));
  update public.push_subscriptions set fails = fails + 1 where endpoint in (select jsonb_array_elements_text(coalesce(p_results->'bad', '[]')));
  delete from public.push_subscriptions where fails >= 10;
end $$;

revoke all on function public._push(uuid, text, text, text, text, text)        from public, anon, authenticated;
revoke all on function public._push_for_event(public.event_log)               from public, anon, authenticated;
revoke all on function public.push_from_event()                               from public, anon, authenticated;
revoke all on function public.push_kick()                                      from public, anon, authenticated;
revoke all on function public._first(uuid)                                     from public, anon, authenticated;
revoke all on function public.push_take(int)                                   from public, anon, authenticated;
revoke all on function public.push_done(jsonb)                                 from public, anon, authenticated;
revoke all on function public.push_subscribe(text, text, text, text)           from public, anon;
revoke all on function public.push_unsubscribe(text)                           from public, anon;
revoke all on function public.call_notify(uuid)                                from public, anon;
grant execute on function public.push_take(int)                                to service_role;
grant execute on function public.push_done(jsonb)                              to service_role;
grant execute on function public.push_subscribe(text, text, text, text)        to authenticated;
grant execute on function public.push_unsubscribe(text)                        to authenticated;
grant execute on function public.call_notify(uuid)                             to authenticated;
-- <<< 8h notifications

-- >>> 8i admin tools
-- =====================================================================
-- 8i. ADMIN CONSOLE HELPERS
--     • Any booking reference shown in the console ("SP-1A2B3C4D") can be
--       clicked: this turns it back into the booking.
--     • The Commission page: standard rate, every photographer's rate,
--       and who changed what.
-- =====================================================================

create or replace function public.admin_find_booking(p_ref text)
returns uuid language sql stable security definer set search_path = public
as $$ select b.id from public.bookings b
       where public.is_staff()
         and upper(left(b.id::text, 8)) = upper(regexp_replace(coalesce(p_ref, ''), '^SP-', '', 'i'))
       order by b.created_at desc limit 1 $$;

create or replace function public.admin_commission_overview()
returns jsonb language plpgsql stable security definer set search_path = public
as $$
declare res jsonb;
begin
  if not public._money_ok() then raise exception 'Only admins can see commission'; end if;
  select jsonb_build_object(
    'standard', (select (value #>> '{}')::numeric from public.platform_settings where key = 'commission_pct'),
    'can_change_standard', public.is_super(),
    'photographers', (select coalesce(jsonb_agg(z order by z.custom desc, z.name), '[]') from (
        select g.id, p.public_id, g.display_name name, g.city, g.approval_status, g.jobs_done, g.commission_pct,
               g.commission_pct is not null custom,
               (select coalesce(sum(b.commission_amount), 0) from public.bookings b where b.photographer_id = g.id and b.status = 'completed') commission_earned,
               (select coalesce(sum(b.total_amount), 0) from public.bookings b where b.photographer_id = g.id and b.status = 'completed') booking_value,
               (select count(*) from public.user_benefits u where u.user_id = g.id and u.kind = 'commission_cut' and u.status = 'active') active_rewards
          from public.photographers g join public.profiles p on p.id = g.id
         where p.name is distinct from 'Deleted user') z),
    'history', (select coalesce(jsonb_agg(z order by z.at desc), '[]') from (
        select at, staff_email, action, target_id, target_name, details from public.admin_audit
         where action ilike '%commission%' or (action ilike 'Changed setting%' and target_id = 'commission_pct')
         order by at desc limit 200) z)
  ) into res;
  return res;
end $$;

revoke all on function public.admin_find_booking(text)      from public, anon;
revoke all on function public.admin_commission_overview()   from public, anon;
grant execute on function public.admin_find_booking(text)    to authenticated;
grant execute on function public.admin_commission_overview() to authenticated;
-- <<< 8i admin tools

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
                   and role = 'super_admin' and accepted_at is null))                     as owner_locked,
  exists (select 1 from pg_proc where proname = 'media_begin')
    and exists (select 1 from public.platform_settings where key = 'storage_plans')      as media_storage_ready,
  exists (select 1 from pg_proc where proname = 'claim_offer')
    and not exists (select 1 from public.profiles where public_id is null)               as offers_and_ids_ready,
  exists (select 1 from pg_proc where proname = 'submit_kyc')
    and exists (select 1 from storage.buckets where id = 'kyc' and not public)           as safety_ready,
  exists (select 1 from pg_proc where proname = 'admin_leads')
    and exists (select 1 from pg_trigger where tgname = 'ev_bookings')                   as departments_ready,
  exists (select 1 from pg_proc where proname = 'delete_my_account')                   as deletion_ready,
  exists (select 1 from pg_proc where proname = 'report_user')
    and exists (select 1 from pg_trigger where tgname = 'pair_guard')                    as moderation_ready,
  exists (select 1 from information_schema.columns where table_name = 'photographers' and column_name = 'travel')   as travel_ready,
  exists (select 1 from pg_trigger where tgname = 'push_from_event')   as notifications_ready,
  exists (select 1 from pg_proc where proname = 'admin_commission_overview')   as admin_tools_ready;
