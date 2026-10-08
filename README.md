# SnapPro

Book a photographer near you. Live at **[snappro.in](https://snappro.in)**.

Customers post a shoot (when, what, where, budget). Photographers in that city who shoot that
kind of work see it and send their own quote. The customer compares quotes, portfolios and
reviews, books one with a 25% advance through Razorpay, pays the balance in the app once the
shoot starts, and they chat in the app. SnapPro keeps a
commission and pays the photographer their share after the shoot. See [PAYMENTS.md](PAYMENTS.md).

## What's in this repository

| Path | What it is |
| --- | --- |
| `index.html` | The home page at snappro.in: what SnapPro is, with sign-up and log-in links |
| `app.html` | The app for customers and photographers (opens at `#signup`, `#join` or `#login`) |
| `admin.html` | Staff console at snappro.in/admin.html (super admin, admin, manager) |
| `supabase/snappro.sql` | Complete database set-up: tables, security rules, triggers, storage, invite emails, payments. Safe to run again. |
| `supabase/functions/` | Server functions (Supabase Edge Functions) for Razorpay payments and webhooks |
| `terms.html`, `privacy.html`, `refunds.html`, `delivery.html`, `contact.html` | Policy pages |
| `.github/workflows/deploy.yml` | Uploads the site to Hostinger on every push to `main` |

## How it works

- **Accounts** — email and password, confirmed with a 6-digit code (Supabase Auth, emails sent
  through Brevo from noreply@snappro.in).
- **Data** — everything lives in Supabase. Row-level security means people only see their own
  requests, quotes, bookings and messages; open requests are visible to photographers until they
  close. Prices, ratings and booking status are enforced in the database, not the browser.
- **Location** — city (with suggestions as you type), pincode and state. The pincode is checked
  against India Post and fills in the state automatically.
- **Payments** — Razorpay Checkout: 25% advance to book, balance after the shoot starts;
  bookings are confirmed only after the server verifies the advance. Secrets live in Supabase Edge Function secrets. Details in PAYMENTS.md.
- **Photographer approval** — new photographers stay "in review" until an admin approves them.
- **Ratings** — only from reviews of completed bookings. New photographers show as "New".
- **Portfolio photos** — uploaded to the Supabase Storage bucket `portfolio`, resized in the
  browser first.
- **Admin dashboard** — live KPIs and charts (booking value, unique visitors, sign-ups, requests,
  bookings) by day, week, month, year or a custom range, plus a list of every account. Visitors
  are counted with a random ID kept in the browser; no names, emails or IP addresses are stored.
- **Staff invites** — a super admin invites someone by email and picks their role; the database
  sends the invite through the Brevo API. The Brevo key is stored in Supabase Vault as
  `brevo_api_key` and never appears in this repository.

## Deploying

Push to `main`. The GitHub Action uploads the HTML pages to Hostinger. The
`supabase/` folder is not uploaded; run `supabase/snappro.sql` in the Supabase SQL Editor when it
changes.
