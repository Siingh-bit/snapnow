# SnapPro

Book a photographer near you. Live at **[snappro.in](https://snappro.in)**.

Customers post a shoot (when, what, where, budget). Photographers in that city who shoot that
kind of work see it and send their own quote. The customer compares quotes, portfolios and
reviews, books one with a 25% advance through Razorpay, pays the balance in the app once the
shoot starts, and they chat in the app. SnapPro keeps a
commission and pays the photographer their share after the shoot. See [PAYMENTS.md](PAYMENTS.md).

## What's in this repository

The website files are grouped into folders so the project is easy to find your way around.
When you push to `main`, `tools/build_site.py` lays them out flat again, so **every web address stays the same**
(e.g. `site/city-pages/birthday-photographers/birthday-photographers-in-pune/` is published as
`snappro.in/birthday-photographers-in-pune/`). To see exactly what gets published: `python3 tools/build_site.py` → `dist/`.

| Path | What it is | Published at |
| --- | --- | --- |
| `site/main/` | `index.html` (home page), `app.html` (customer and photographer app), `admin.html` (staff console), `sw.js`, `site.webmanifest`, `offline.html`, `.well-known/assetlinks.json` (links the Android app to snappro.in) | `/` |
| `site/seo-and-ai/` | `sitemap.xml`, `robots.txt`, `llms.txt`, `llms-full.txt` (for AI assistants), the IndexNow key | `/` |
| `site/images/` | Icons, favicons, `og.png` (share image) | `/` |
| `site/legal/` | `terms.html`, `privacy.html`, `refunds.html`, `delivery.html`, `contact.html`, `delete-account.html`, `photographer-agreement.html` | `/` |
| `site/pages/` | About, FAQ, guides, how it works, photography prices, for photographers | `/<page>/` |
| `site/city-pages/<type>/` | One folder per shoot type (wedding, birthday, …), holding the type's page and every city page for it | `/<page>/` |
| `supabase/snappro.sql` | Complete database set-up: tables, security rules, triggers, payments, payouts. Safe to run again. | not published |
| `supabase/functions/` | Server functions (Supabase Edge Functions): Razorpay payments and webhooks, portfolio media on S3, `push` | not published |
| `tools/build_site.py` | Builds the public site from `site/` (used by the deploy) | not published |
| `.github/workflows/deploy.yml` | Builds the site and uploads it to Hostinger on every push to `main` | not published |

## How it works

- **Accounts** — email and password, confirmed with a 6-digit code (Supabase Auth, emails sent
  through Brevo from noreply@snappro.in).
- **Google sign-in** — "Continue with Google" (Supabase Auth, Google provider); new people pick customer or photographer first.
- **Notifications** — quotes, bookings, booking updates, messages, calls and new requests reach the phone even when the app is
  closed (Web Push). The database queues them (`push_outbox`), the `push` Edge Function sends them. Keys: VAPID pair + hook
  secret, made once with SnapPro-Push-Keys.html (kept off the website).
- **Travel range** — photographers choose their city only, nearby cities (Delhi NCR, Mumbai area, Chandigarh tricity,
  Hyderabad, Kolkata — else their state) or anywhere in India; customers see who travels to them.
- **Report & block** — in chats, profiles, quotes, requests and reviews; staff handle reports in Admin → Trust & support.
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
