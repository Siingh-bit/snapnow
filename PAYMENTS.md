# Payments (Cashfree)

Customers pay the full booking amount online through Cashfree's hosted checkout
(UPI / Google Pay, debit and credit cards, net banking). The money settles to the
SnapPro merchant account. SnapPro keeps its commission (20% by default, stored in
`platform_settings`) and pays the photographer's share manually after the shoot.

## How it fits together

```
app.html  ──(signed-in user's token)──▶  Edge Function "payments"  ──(secret key)──▶  Cashfree API
   ▲                                          │                                         │
   │ return_url: app.html?payment=<order>     ▼                                         │ webhook (signed)
   └──────────── Cashfree checkout ◀── payment_session_id            Edge Function "cashfree-webhook"
                                              │                                         │
                                              └──────────▶  Postgres pay_* functions  ◀─┘
```

- The browser never decides that a booking is paid. Bookings start as
  `pending_payment` and become `confirmed` only inside `pay_record`, which is
  called by the server after Cashfree confirms the payment (signed webhook, or
  the server calling Cashfree's Get Order API).
- `pay_record` and `pay_refund_update` are idempotent: every event has a unique
  key in `payment_events`, rows are locked, a success is never undone, and a
  second payment for an already-paid booking is flagged `refund_due` instead of
  confirming twice.
- No card numbers, CVV, UPI PIN or UPI IDs are stored. We keep the order id,
  Cashfree payment id, payment method type (upi / credit_card …), bank reference,
  amounts, statuses and timestamps.

## Files

| File | What it does |
| --- | --- |
| `supabase/snappro.sql` (section 7c) | `payments`, `payment_events`, `refunds`, `platform_settings`, `photographer_payout` tables; booking payment/payout columns; the `pay_*` functions (server-only) and `admin_mark_payout`, `admin_set_commission` |
| `supabase/functions/payments/index.ts` | `create` (Cashfree order), `status` (verify with Cashfree), `refund`, `refund_check` |
| `supabase/functions/cashfree-webhook/index.ts` | Verifies `x-webhook-signature`, records payment and refund webhooks |
| `app.html` | Pay button, payment result screen, retry, refund status, photographer share and payout details |
| `admin.html` | Payments tab: transactions, refunds, payouts due, commission |

## Secrets (Supabase → Edge Functions → Secrets)

| Name | Value |
| --- | --- |
| `CASHFREE_APP_ID` | App ID from Cashfree (Developers → API Keys) |
| `CASHFREE_SECRET_KEY` | Secret key from the same page |
| `CASHFREE_ENVIRONMENT` | `sandbox` while testing, `production` when live |
| `SANDBOX_TESTERS` | Optional: comma-separated emails allowed to pay in sandbox mode (everyone else sees "payments are being set up") |

`SUPABASE_URL`, `SUPABASE_ANON_KEY` and `SUPABASE_SERVICE_ROLE_KEY` are provided to
Edge Functions automatically. Nothing secret is in the website or this repository.

## Webhook

`https://eafudrjxjtenqoorjzsc.supabase.co/functions/v1/cashfree-webhook`
— deploy this function with JWT verification **off**. Subscribe to payment success,
payment failed, payment user dropped and refund status events.

## Later: automatic split payments

Each payment already stores `commission_amount` and `photographer_amount`, and
photographers have a `cf_vendor_id` column. To move to Cashfree Easy Split, create a
vendor per photographer, store the id in `cf_vendor_id`, and add `order_splits`
(`[{ vendor_id, amount: photographer_amount }]`) when creating the order in
`supabase/functions/payments/index.ts`. Refund splits work the same way.
