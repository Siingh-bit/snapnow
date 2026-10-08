# Payments (Razorpay)

Customers pay online through Razorpay Checkout (UPI / Google Pay, debit and credit cards,
net banking) in two parts:

1. **Advance** — 25% of the price (`platform_settings.advance_pct`) when they book. This
   confirms the booking.
2. **Balance** — the remaining 75%, payable in the app once the photographer starts the shoot
   (`balance_status` goes `pending` → `due` → `paid`).

The money settles to the SnapPro Razorpay account. SnapPro keeps its commission (20% by
default, `platform_settings.commission_pct`, taken from the advance) and pays the
photographer's share manually once the shoot is complete **and** the balance is paid.

## How it fits together

```
app.html ──(user's token)──▶ Edge Function "payments" ──(key id + secret)──▶ Razorpay API
   │  ▲                           │   creates one Razorpay order per booking
   │  └── order_id, public key ───┘
   ▼
Razorpay Checkout ──success: payment_id + signature──▶ "payments" (verify) ─┐
                                                                            ├─▶ Postgres pay_* functions
Razorpay ──signed webhook──▶ Edge Function "razorpay-webhook" ──────────────┘
```

- The browser never decides that a booking is paid. Bookings start as `pending_payment`
  and become `confirmed` only inside `pay_record`, after the server has
  1. checked the Checkout signature `HMAC_SHA256(order_id + "|" + payment_id, key_secret)`
     using the order id stored in our database, **and**
  2. fetched the payment from Razorpay and seen `captured` for this order and amount
     (it captures `authorized` payments itself if auto-capture is off),
  — or after a webhook whose `X-Razorpay-Signature` matches and whose payment Razorpay
  confirms.
- One Razorpay order per part (advance / balance). Retries re-use it, and Razorpay refuses
  payments on a paid order, so nothing can be paid twice. If it ever happens anyway (e.g.
  switching keys), the extra payment is flagged "refund due". `payments.stage` records which
  part each payment was.
- `pay_record` / `pay_refund_update` are idempotent: each event has a unique key in
  `payment_events` (Razorpay's `x-razorpay-event-id`), rows are locked, and a success is
  never undone.
- No card numbers, CVV, UPI PIN or UPI IDs are stored — only order/payment ids, method
  type, RRN, amounts, statuses and timestamps.

## Files

| File | What it does |
| --- | --- |
| `supabase/snappro.sql` (section 7c) | `payments`, `payment_events`, `refunds`, `platform_settings`, `photographer_payout`; booking payment/payout/cancellation columns; server-only `pay_*` functions; `admin_mark_payout`, `admin_set_commission` |
| `supabase/functions/payments/index.ts` | `create`, `verify`, `status`, `refund`, `refund_check` |
| `supabase/functions/razorpay-webhook/index.ts` | Verifies the webhook signature and records payment and refund events |
| `app.html` | Pay button → Razorpay Checkout, result screen, retry, refund status, photographer share and payout details |
| `admin.html` | Payments tab: transactions, refunds (with policy-suggested amount), payouts due, commission |
| `terms.html`, `privacy.html`, `refunds.html`, `delivery.html`, `contact.html` | Policy pages Razorpay checks during activation |

## Secrets (Supabase → Edge Functions → Secrets)

| Name | Value |
| --- | --- |
| `RAZORPAY_KEY_ID` | `rzp_test_…` while testing, `rzp_live_…` when live (test/live mode is detected from this) |
| `RAZORPAY_KEY_SECRET` | The matching key secret |
| `RAZORPAY_WEBHOOK_SECRET` | The secret you type when creating the webhook in Razorpay |
| `TEST_MODE_TESTERS` | Optional: comma-separated emails allowed to pay with test keys (everyone else sees "payments are being set up") |

`SUPABASE_URL`, `SUPABASE_ANON_KEY` and `SUPABASE_SERVICE_ROLE_KEY` are provided to Edge
Functions automatically. Nothing secret is in the website or this repository.

## Webhook

`https://eafudrjxjtenqoorjzsc.supabase.co/functions/v1/razorpay-webhook` — deploy with JWT
verification **off**. Events: `payment.captured`, `payment.failed`, `order.paid`,
`payment.authorized`, `refund.processed`, `refund.failed`.

## Refund policy (as implemented)

Bookings can only be cancelled before the shoot starts, so cancellation refunds apply to the
advance: full, except a customer cancelling after the photographer has set off (50%).
Refunds are started by an admin from the Payments tab; the suggested amount follows the policy.

## Later: automatic split payments

Each payment stores `commission_amount` and `photographer_amount`, and photographers have
a `payout_account_id` column. To move to Razorpay Route, create a linked account per
photographer, store its id in `payout_account_id`, and add
`transfers: [{ account, amount: photographer_amount * 100, currency: "INR" }]` when creating
the order in `supabase/functions/payments/index.ts`.
