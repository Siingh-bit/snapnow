// SnapPro — Cashfree webhook receiver (Supabase Edge Function)
//
// URL to give Cashfree:  https://<your-project>.supabase.co/functions/v1/cashfree-webhook
// Deploy with "Verify JWT" turned OFF — Cashfree can't send a Supabase token.
// Authenticity comes from Cashfree's signature instead:
//   expected = base64( HMAC_SHA256( x-webhook-timestamp + rawBody, CASHFREE_SECRET_KEY ) )
//
// Handles PAYMENT_SUCCESS_WEBHOOK, PAYMENT_FAILED_WEBHOOK, PAYMENT_USER_DROPPED_WEBHOOK
// and REFUND_STATUS_WEBHOOK. Every event is applied once (pay_record /
// pay_refund_update keep a unique event key), so Cashfree's retries are harmless.
// Successes are double-checked with Cashfree's Get Order API before a booking
// is confirmed. Card numbers / UPI IDs in the payload are never stored.

const API_VERSION_DEFAULT = "2026-01-01";
const MAX_AGE_MS = 3 * 24 * 3600e3;      // ignore anything older than 3 days (replays)

function config(env) {
  const mode = String(env.CASHFREE_ENVIRONMENT || "sandbox").toLowerCase() === "production" ? "production" : "sandbox";
  return {
    mode,
    appId: env.CASHFREE_APP_ID || "",
    secret: env.CASHFREE_SECRET_KEY || "",
    apiVersion: env.CASHFREE_API_VERSION || API_VERSION_DEFAULT,
    cfBase: mode === "production" ? "https://api.cashfree.com/pg" : "https://sandbox.cashfree.com/pg",
    supabaseUrl: (env.SUPABASE_URL || "").replace(/\/$/, ""),
    serviceKey: env.SUPABASE_SERVICE_ROLE_KEY || "",
  };
}

const enc = new TextEncoder();
async function hmacBase64(secret, message) {
  const key = await crypto.subtle.importKey("raw", enc.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const sig = new Uint8Array(await crypto.subtle.sign("HMAC", key, enc.encode(message)));
  let bin = ""; for (const b of sig) bin += String.fromCharCode(b);
  return btoa(bin);
}
function safeEqual(a, b) {
  if (typeof a !== "string" || typeof b !== "string" || a.length !== b.length) return false;
  let d = 0; for (let i = 0; i < a.length; i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return d === 0;
}
export async function verifySignature(secret, timestamp, rawBody, signature) {
  if (!secret || !timestamp || !signature) return false;
  const expected = await hmacBase64(secret, timestamp + rawBody);
  return safeEqual(expected, signature);
}

async function rpc(cfg, fetchImpl, name, args) {
  const h = { apikey: cfg.serviceKey, "Content-Type": "application/json" };
  if (cfg.serviceKey.startsWith("eyJ")) h.Authorization = "Bearer " + cfg.serviceKey;
  const r = await fetchImpl(cfg.supabaseUrl + "/rest/v1/rpc/" + name, { method: "POST", headers: h, body: JSON.stringify(args) });
  const text = await r.text();
  if (!r.ok) throw new Error("db " + r.status + ": " + text.slice(0, 200));
  return text ? JSON.parse(text) : null;
}
async function cfGetOrder(cfg, fetchImpl, orderId) {
  const r = await fetchImpl(cfg.cfBase + "/orders/" + encodeURIComponent(orderId), {
    headers: { "x-client-id": cfg.appId, "x-client-secret": cfg.secret, "x-api-version": cfg.apiVersion, Accept: "application/json" },
  });
  if (!r.ok) throw new Error("cashfree get order " + r.status);
  return r.json();
}

const ok = (msg) => new Response(JSON.stringify({ ok: true, msg }), { status: 200, headers: { "Content-Type": "application/json" } });
const bad = (status, msg) => new Response(JSON.stringify({ ok: false, msg }), { status, headers: { "Content-Type": "application/json" } });

export async function handler(req, env, fetchImpl) {
  const cfg = config(env);
  if (req.method !== "POST") return bad(405, "POST only");
  if (!cfg.secret || !cfg.supabaseUrl || !cfg.serviceKey) return bad(503, "not configured");

  const raw = await req.text();                                   // exact bytes Cashfree signed
  const ts = req.headers.get("x-webhook-timestamp") || "";
  const sig = req.headers.get("x-webhook-signature") || "";
  if (!(await verifySignature(cfg.secret, ts, raw, sig))) return bad(401, "bad signature");
  const tsNum = Number(ts);
  if (!Number.isFinite(tsNum) || Math.abs(Date.now() - tsNum) > MAX_AGE_MS) return bad(400, "stale");

  let evt;
  try { evt = JSON.parse(raw); } catch (_) { return bad(400, "bad json"); }
  const type = String(evt.type || "");
  const data = evt.data || {};

  try {
    if (type === "PAYMENT_SUCCESS_WEBHOOK" || type === "PAYMENT_FAILED_WEBHOOK" || type === "PAYMENT_USER_DROPPED_WEBHOOK") {
      const orderId = data.order && data.order.order_id;
      const p = data.payment || {};
      if (!orderId) return ok("no order");
      let status = String(p.payment_status || "").toUpperCase();
      if (type === "PAYMENT_SUCCESS_WEBHOOK" || status === "SUCCESS") {
        // trust, but verify: Cashfree must also say the order is PAID
        const order = await cfGetOrder(cfg, fetchImpl, orderId);
        if (String(order.order_status).toUpperCase() !== "PAID") return bad(409, "order not paid yet");
        status = "SUCCESS";
      }
      const res = await rpc(cfg, fetchImpl, "pay_record", {
        p_order_id: String(orderId),
        p_event_key: "wh:" + String(p.cf_payment_id || "") + ":" + status,
        p_status: status,
        p_cf_payment_id: p.cf_payment_id != null ? String(p.cf_payment_id) : null,
        p_amount: p.payment_amount != null ? Number(p.payment_amount) : null,
        p_group: p.payment_group || null,
        p_bank_ref: p.bank_reference && p.bank_reference !== "NA" ? String(p.bank_reference) : null,
        p_message: p.payment_message || (data.error_details && data.error_details.error_description) || null,
        p_event_type: type,
      });
      return ok(res && res.result);
    }
    if (type === "REFUND_STATUS_WEBHOOK") {
      const r = data.refund || {};
      if (!r.refund_id) return ok("no refund id");
      const res = await rpc(cfg, fetchImpl, "pay_refund_update", {
        p_refund_id: String(r.refund_id),
        p_status: String(r.refund_status || ""),
        p_cf_refund_id: r.cf_refund_id != null ? String(r.cf_refund_id) : null,
        p_arn: r.refund_arn || null,
        p_event_key: "wh:refund:" + String(r.cf_refund_id || r.refund_id) + ":" + String(r.refund_status || ""),
      });
      return ok(res && res.result);
    }
    return ok("ignored " + type);                                  // e.g. PAYMENT_CHARGES_WEBHOOK
  } catch (e) {
    console.error("cashfree-webhook:", e && e.message);
    return bad(500, "retry");                                      // non-2xx → Cashfree retries
  }
}

if (typeof Deno !== "undefined" && Deno.serve) {
  Deno.serve((req) => handler(req, Deno.env.toObject(), fetch));
}
