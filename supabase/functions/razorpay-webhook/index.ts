// SnapPro — Razorpay webhook receiver (Supabase Edge Function)
//
// URL to give Razorpay:  https://<your-project>.supabase.co/functions/v1/razorpay-webhook
// Deploy with "Verify JWT" turned OFF — Razorpay can't send a Supabase token.
// Authenticity comes from Razorpay's signature instead:
//   X-Razorpay-Signature = hex( HMAC_SHA256( rawBody, RAZORPAY_WEBHOOK_SECRET ) )
//
// Events: payment.captured, payment.authorized, payment.failed, order.paid,
//         refund.processed, refund.failed (others are acknowledged and ignored).
// Each event is applied once (x-razorpay-event-id → unique key in payment_events).
// Successes are re-checked with Razorpay's API before a booking is confirmed.
// Card numbers / UPI IDs in the payload are never stored.
//
// Secrets: RAZORPAY_WEBHOOK_SECRET (the secret you type when creating the webhook),
//          RAZORPAY_KEY_ID, RAZORPAY_KEY_SECRET (to double-check with Razorpay).

const MAX_AGE_S = 3 * 24 * 3600;      // ignore anything older than 3 days (replays)

function config(env) {
  return {
    keyId: env.RAZORPAY_KEY_ID || "",
    secret: env.RAZORPAY_KEY_SECRET || "",
    webhookSecret: env.RAZORPAY_WEBHOOK_SECRET || "",
    api: "https://api.razorpay.com/v1",
    supabaseUrl: (env.SUPABASE_URL || "").replace(/\/$/, ""),
    serviceKey: env.SUPABASE_SERVICE_ROLE_KEY || "",
  };
}

const enc = new TextEncoder();
async function hmacHex(secret, message) {
  const key = await crypto.subtle.importKey("raw", enc.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const sig = new Uint8Array(await crypto.subtle.sign("HMAC", key, enc.encode(message)));
  return Array.from(sig, (b) => b.toString(16).padStart(2, "0")).join("");
}
function safeEqual(a, b) {
  if (typeof a !== "string" || typeof b !== "string" || a.length !== b.length) return false;
  let d = 0; for (let i = 0; i < a.length; i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return d === 0;
}
export async function verifySignature(secret, rawBody, signature) {
  if (!secret || !signature) return false;
  return safeEqual(await hmacHex(secret, rawBody), signature);
}

async function rpc(cfg, fetchImpl, name, args) {
  const h = { apikey: cfg.serviceKey, "Content-Type": "application/json" };
  if (cfg.serviceKey.startsWith("eyJ")) h.Authorization = "Bearer " + cfg.serviceKey;
  const r = await fetchImpl(cfg.supabaseUrl + "/rest/v1/rpc/" + name, { method: "POST", headers: h, body: JSON.stringify(args) });
  const text = await r.text();
  if (!r.ok) throw new Error("db " + r.status + ": " + text.slice(0, 200));
  return text ? JSON.parse(text) : null;
}
async function rzp(cfg, fetchImpl, method, path, body) {
  const r = await fetchImpl(cfg.api + path, {
    method,
    headers: { Authorization: "Basic " + btoa(cfg.keyId + ":" + cfg.secret), "Content-Type": "application/json" },
    body: body ? JSON.stringify(body) : undefined,
  });
  if (!r.ok) throw new Error("razorpay " + method + " " + path + " " + r.status);
  return r.json();
}
function bankRef(p) {
  const a = (p && p.acquirer_data) || {};
  return a.rrn || a.upi_transaction_id || a.bank_transaction_id || a.auth_code || null;
}

const ok = (msg) => new Response(JSON.stringify({ ok: true, msg }), { status: 200, headers: { "Content-Type": "application/json" } });
const bad = (status, msg) => new Response(JSON.stringify({ ok: false, msg }), { status, headers: { "Content-Type": "application/json" } });

export async function handler(req, env, fetchImpl) {
  const cfg = config(env);
  if (req.method !== "POST") return bad(405, "POST only");
  if (!cfg.webhookSecret || !cfg.supabaseUrl || !cfg.serviceKey) return bad(503, "not configured");

  const raw = await req.text();                                     // exact bytes Razorpay signed
  const sig = req.headers.get("x-razorpay-signature") || "";
  if (!(await verifySignature(cfg.webhookSecret, raw, sig))) return bad(401, "bad signature");

  let evt;
  try { evt = JSON.parse(raw); } catch (_) { return bad(400, "bad json"); }
  if (typeof evt.created_at === "number" && Math.abs(Date.now() / 1000 - evt.created_at) > MAX_AGE_S) return bad(400, "stale");
  const eventId = req.headers.get("x-razorpay-event-id") || "";
  const type = String(evt.event || "");
  const pl = evt.payload || {};
  const key = "rzp:" + (eventId || (type + ":" + ((pl.payment && pl.payment.entity && pl.payment.entity.id) || (pl.refund && pl.refund.entity && pl.refund.entity.id) || "")));

  try {
    if (type === "payment.captured" || type === "payment.authorized" || type === "payment.failed" || type === "order.paid") {
      let p = pl.payment && pl.payment.entity;
      if (!p || !p.order_id) return ok("no payment");
      let status = "FAILED";
      if (type !== "payment.failed") {
        if (!cfg.keyId || !cfg.secret) return bad(503, "keys not configured");
        // trust, but verify: ask Razorpay for the payment itself
        p = await rzp(cfg, fetchImpl, "GET", "/payments/" + encodeURIComponent(p.id));
        if (p.status === "authorized") {
          try { p = await rzp(cfg, fetchImpl, "POST", "/payments/" + encodeURIComponent(p.id) + "/capture", { amount: p.amount, currency: p.currency || "INR" }); }
          catch (_) { p = await rzp(cfg, fetchImpl, "GET", "/payments/" + encodeURIComponent(p.id)); }
        }
        if (p.status !== "captured") return bad(409, "not captured yet");    // non-2xx → Razorpay retries
        status = "CAPTURED";
      }
      const res = await rpc(cfg, fetchImpl, "pay_record", {
        p_order_id: String(p.order_id), p_event_key: key, p_status: status,
        p_payment_ref: String(p.id), p_amount: typeof p.amount === "number" ? p.amount / 100 : null,
        p_group: p.method || null, p_bank_ref: bankRef(p),
        p_message: p.error_description || null, p_event_type: type,
      });
      return ok(res && res.result);
    }
    if (type === "refund.processed" || type === "refund.failed") {
      const r = pl.refund && pl.refund.entity;
      if (!r || !r.id) return ok("no refund");
      const res = await rpc(cfg, fetchImpl, "pay_refund_update", {
        p_refund_id: String(r.receipt || r.id), p_status: type === "refund.processed" ? "PROCESSED" : "FAILED",
        p_gateway_refund_id: String(r.id), p_arn: (r.acquirer_data && r.acquirer_data.arn) || null, p_event_key: key,
      });
      return ok(res && res.result);
    }
    return ok("ignored " + type);
  } catch (e) {
    console.error("razorpay-webhook:", e && e.message);
    return bad(500, "retry");                                      // non-2xx → Razorpay retries
  }
}

if (typeof Deno !== "undefined" && Deno.serve) {
  Deno.serve((req) => handler(req, Deno.env.toObject(), fetch));
}
