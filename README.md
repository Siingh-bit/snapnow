# SnapNow

**On-demand photographer booking — a photographer at your door in minutes.**

Blinkit and Swiggy Instamart made 10-minute grocery delivery normal. SnapNow applies the same
model to photography: you post a shoot, every matching photographer nearby gets pinged, they
accept with their own price and ETA, and you pick one. Instead of DMing five photographers on
Instagram and waiting a day for replies, you get competing offers in under a minute.

> **Status:** working front-end prototype. Single self-contained HTML file, no build step,
> no server, no dependencies. All state lives in `localStorage`.

---

## Try it

Open `index.html` in any modern browser. That's it.

Or serve it locally:

```bash
python3 -m http.server 8000
# then visit http://localhost:8000
```

---

## The core loop

1. **Post a request** — pick urgency (right now / 1h / 3h / later today / tomorrow / custom date),
   category, duration, area, budget and deliverables.
2. **Broadcast** — the request goes out to every photographer whose specialities match, in that area.
3. **Offers arrive live** — photographers accept over the next few seconds, each with their own
   price, ETA and a short pitch. You watch them land on a radar view.
4. **Compare and book** — sort by best match / cheapest / fastest / top rated, open portfolios and
   reviews, then pay.
5. **Track and chat** — the photographer moves through confirmed → on the way → arrived → shooting
   → delivered, with a live map and in-app messaging.
6. **Rate** — reviews feed back into the photographer's public rating.

Pricing uses surge multipliers by urgency tier (1.6× for *right now*, 0.9× for a scheduled date),
adjusted for the photographer's own rate, rating and distance.

---

## Accounts

The app opens on a welcome screen asking **how you'll use it**:

| Account type | What you get |
|---|---|
| **Customer** | Post requests, browse portfolios, compare offers, pay, chat, track, rate |
| **Photographer** | Online/offline toggle, job alerts with countdown, custom quoting, job pipeline, earnings, editable portfolio |
| **Admin** | GMV, take rate, fill rate, offers per request, demand by category, supply coverage map |

Both signup paths run through phone + OTP. Signing up as a photographer creates a **real record in
the marketplace** — your new profile is discoverable in Explore, gets pinged by matching requests,
quotes its own prices and can be booked by a customer account on the same device.

Admin sits behind a separate console login at the bottom of the welcome screen.

---

## Features

**Customer**
- Urgency-tiered request builder with live surge pricing
- 12 shoot categories, deliverable selection, budget slider
- Live matching radar + map of who's being pinged
- Offer comparison with four sort modes
- Portfolio, reviews with rating histogram, packages, gear
- Escrow-style checkout — platform fee, GST, travel, four payment methods
- Wallet with balance guard
- 5-stage arrival tracker with live map
- In-app chat with quick replies
- Star ratings that move the photographer's real rating

**Photographer**
- Online/offline availability toggle
- Incoming job alerts with a response countdown
- Quote builder — set your own price and ETA, see your 85% payout
- Pass on jobs you don't want
- Job pipeline with status advancement
- Earnings dashboard with a 7-day chart and payout history
- Editable portfolio and profile

**Admin**
- GMV, platform revenue, fill rate, offers per request
- Supply health and coverage map
- Demand by category
- All requests and bookings

---

## How it's built

One file. No framework, no bundler, no dependencies, no network calls.

- **Rendering** — plain functions returning HTML strings, with a small router over
  `role → tab` plus a navigation stack for pushed screens
- **State** — a single `S` object serialised to `localStorage` under `snapnow.v2`
- **Imagery** — portfolio "photos" and avatars are deterministic CSS gradients seeded from an FNV-1a
  hash of the photographer's ID, so they're stable across renders and work fully offline
- **Maps** — hand-drawn SVG street grids with positioned pins; no map SDK or API key
- **Simulation** — rival photographers accept on staggered timers so the matching flow feels alive.
  Photographers attached to a real account never auto-accept on your behalf.

---

## Demo shortcuts

Things that are deliberately faked, and would need a real backend:

- **Auth is not real.** The OTP is generated client-side and everything lives in `localStorage`,
  so anyone can "log in" as anyone. This is the first thing to replace.
- **Competing photographers are simulated** on timers rather than being real users.
- **Payments are mocked** — no gateway, no actual escrow.
- **"Simulate next step"** on a booking fast-forwards the photographer through the arrival journey
  so you can see the whole flow in seconds.
- ID verification and portfolio review are auto-approved at signup.

---

## What a production build would need

- Real auth (phone OTP via an SMS provider, JWT sessions)
- Backend + database — Postgres for accounts, requests, offers, bookings, chats
- Real push notifications (FCM/APNs) for the broadcast — this is the heart of the product
- WebSockets for live offers and chat
- Payment gateway with genuine escrow and split payouts
- Real maps and geospatial matching (PostGIS radius queries)
- Photo storage and delivery (S3 + CDN), gallery links
- KYC for photographer onboarding
- Trust and safety — disputes, no-show handling, refunds

---

## Testing

The prototype was verified with JSDOM by driving the real DOM event handlers: full booking loop on
both sides, both signup paths, login/logout and session persistence, every tab in every role,
request expiry and rebroadcast, cancellation, wallet guards and input escaping.

---

## Licence

MIT — see [LICENSE](LICENSE).
