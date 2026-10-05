// SnapPro — payments (Supabase Edge Function), Razorpay
//
// Actions (POST JSON, signed-in user's Supabase token in Authorization):
//   { action: "create", booking_id }                    customer → Razorpay order for Checkout
//   { action: "verify", order_id, razorpay_payment_id, razorpay_order_id, razorpay_signature }
//                                                        customer → after Checkout's success handler
//   { action: "status", order_id }                       customer → ask Razorpay what happened
//   { action: "refund", payment_id, amount, reason }     admin / super admin only
//   { action: "refund_check", refund_id, gateway_refund_id }   admin / super admin only
//
// Secrets (Supabase → Edge Functions → Secrets), never in the website:
//   RAZORPAY_KEY_ID      rzp_test_… while testing, rzp_live_… when live
//   RAZORPAY_KEY_SECRET  the matching secret
// Optional: TEST_MODE_TESTERS — comma-separated emails allowed to pay while using
//   test keys (protects the live site: real customers can't "pay" in test mode),
//   SITE_URL, ALLOWED_ORIGINS.
// Supabase provides SUPABASE_URL, SUPABASE_ANON_KEY and SUPABASE_SERVICE_ROLE_KEY.
//
// The amount always comes from the database, never from the browser. Payment
// state only changes through the pay_* database functions (idempotent, row-locked).
// A booking only becomes "paid" after the payment signature checks out AND
// Razorpay's own API says the payment is captured for this order and amount.

export function config(env) {
  const keyId = env.RAZORPAY_KEY_ID || "";
  return {
    keyId,
    secret: env.RAZORPAY_KEY_SECRET || "",
    mode: keyId.startsWith("rzp_live_") ? "live" : "test",
    api: "https://api.razorpay.com/v1",
    supabaseUrl: (env.SUPABASE_URL || "").replace(/\/$/, ""),
    serviceKey: env.SUPABASE_SERVICE_ROLE_KEY || "",
    anonKey: env.SUPABASE_ANON_KEY || env.SUPABASE_SERVICE_ROLE_KEY || "",
    siteUrl: (env.SITE_URL || "https://snappro.in").replace(/\/$/, ""),
    origins: String(env.ALLOWED_ORIGINS || "https://snappro.in,https://www.snappro.in").split(",").map((s) => s.trim()).filter(Boolean),
    testers: String(env.TEST_MODE_TESTERS || "").split(",").map((s) => s.trim().toLowerCase()).filter(Boolean),
  };
}

class HttpError extends Error {
  status = 500;
  constructor(status, message) { super(message); this.status = status; }
}

function cors(req, cfg) {
  const origin = req.headers.get("origin") || "";
  return {
    "Access-Control-Allow-Origin": cfg.origins.includes(origin) ? origin : cfg.origins[0],
    "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Vary": "Origin",
  };
}
const json = (body, status, headers) => new Response(JSON.stringify(body), { status, headers: { ...headers, "Content-Type": "application/json" } });

// ---------- Supabase (service key, server only) ----------
export async function rpc(cfg, fetchImpl, name, args) {
  const h = { apikey: cfg.serviceKey, "Content-Type": "application/json" };
  if (cfg.serviceKey.startsWith("eyJ")) h.Authorization = "Bearer " + cfg.serviceKey;   // legacy service_role JWT
  const r = await fetchImpl(cfg.supabaseUrl + "/rest/v1/rpc/" + name, { method: "POST", headers: h, body: JSON.stringify(args) });
  const text = await r.text();
  let data = null; try { data = text ? JSON.parse(text) : null; } catch (_) { data = text; }
  if (!r.ok) throw new HttpError(r.status >= 500 ? 500 : 400, (data && (data.message || data.error)) || ("Database error " + r.status));
  return data;
}
async function currentUser(cfg, fetchImpl, req) {
  const token = (req.headers.get("authorization") || "").replace(/^Bearer\s+/i, "");
  if (!token || token === cfg.anonKey) throw new HttpError(401, "Please log in again.");
  const r = await fetchImpl(cfg.supabaseUrl + "/auth/v1/user", { headers: { apikey: cfg.anonKey, Authorization: "Bearer " + token } });
  if (!r.ok) throw new HttpError(401, "Please log in again.");
  const u = await r.json();
  if (!u || !u.id) throw new HttpError(401, "Please log in again.");
  return u;
}

// ---------- Razorpay ----------
export async function rzp(cfg, fetchImpl, method, path, body) {
  const r = await fetchImpl(cfg.api + path, {
    method,
    headers: { Authorization: "Basic " + btoa(cfg.keyId + ":" + cfg.secret), "Content-Type": "application/json" },
    body: body ? JSON.stringify(body) : undefined,
  });
  const text = await r.text();
  let data = null; try { data = text ? JSON.parse(text) : null; } catch (_) { data = { error: { description: text } }; }
  if (!r.ok) {
    const e = new HttpError(r.status === 404 ? 404 : 502, (data && data.error && data.error.description) || ("Razorpay error " + r.status));
    e.rzpStatus = r.status;
    throw e;
  }
  return data;
}
const enc = new TextEncoder();
export async function hmacHex(secret, message) {
  const key = await crypto.subtle.importKey("raw", enc.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const sig = new Uint8Array(await crypto.subtle.sign("HMAC", key, enc.encode(message)));
  return Array.from(sig, (b) => b.toString(16).padStart(2, "0")).join("");
}
function safeEqual(a, b) {
  if (typeof a !== "string" || typeof b !== "string" || a.length !== b.length) return false;
  let d = 0; for (let i = 0; i < a.length; i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return d === 0;
}
const isUuid = (v) => typeof v === "string" && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(v);
const isRef = (v) => typeof v === "string" && /^[A-Za-z0-9_-]{3,45}$/.test(v);
function newOrderRef() {
  const d = new Date(Date.now() + 5.5 * 3600e3).toISOString().slice(2, 10).replace(/-/g, "");
  return "SP" + d + "_" + crypto.randomUUID().replace(/-/g, "").slice(0, 14);      // e.g. SP261005_3f9a0c1d2b7e44
}
function indianMobile(v) {
  let d = String(v || "").replace(/\D/g, "");
  if (d.length === 12 && d.startsWith("91")) d = d.slice(2);
  if (d.length === 11 && d.startsWith("0")) d = d.slice(1);
  return /^[6-9]\d{9}$/.test(d) ? d : null;
}
function bankRef(p) {
  const a = (p && p.acquirer_data) || {};
  return a.rrn || a.upi_transaction_id || a.bank_transaction_id || a.auth_code || null;
}

// Record a Razorpay payment entity. Captures it first if it's only authorized.
export async function applyPayment(cfg, fetchImpl, gatewayOrderId, p, eventKey, eventType) {
  if (!p || p.order_id !== gatewayOrderId) return { result: "mismatch" };
  let pay = p;
  if (pay.status === "authorized") {
    try { pay = await rzp(cfg, fetchImpl, "POST", "/payments/" + encodeURIComponent(p.id) + "/capture", { amount: p.amount, currency: p.currency || "INR" }); }
    catch (_) { pay = await rzp(cfg, fetchImpl, "GET", "/payments/" + encodeURIComponent(p.id)); }   // captured meanwhile?
  }
  const st = pay.status === "captured" ? "CAPTURED" : pay.status === "failed" ? "FAILED" : String(pay.status || "").toUpperCase();
  return rpc(cfg, fetchImpl, "pay_record", {
    p_order_id: gatewayOrderId, p_event_key: eventKey || ("verify:" + pay.id + ":" + st), p_status: st,
    p_payment_ref: pay.id, p_amount: typeof pay.amount === "number" ? pay.amount / 100 : null,
    p_group: pay.method || null, p_bank_ref: bankRef(pay),
    p_message: pay.error_description || null, p_event_type: eventType || "VERIFY",
  });
}

// Ask Razorpay what happened to an order and record it (idempotent).
export async function verifyOrder(cfg, fetchImpl, gatewayOrderId) {
  let list;
  try { list = await rzp(cfg, fetchImpl, "GET", "/orders/" + encodeURIComponent(gatewayOrderId) + "/payments"); }
  catch (e) { if (e.status === 404) return { result: "not_found" }; throw e; }
  const items = (list && Array.isArray(list.items)) ? list.items : [];
  const good = items.find((p) => p.status === "captured") || items.find((p) => p.status === "authorized");
  if (good) return applyPayment(cfg, fetchImpl, gatewayOrderId, good);
  const latest = items.slice().sort((a, b) => (b.created_at || 0) - (a.created_at || 0))[0];
  if (latest && latest.status === "failed") {
    const res = await applyPayment(cfg, fetchImpl, gatewayOrderId, latest);
    return res && res.result === "duplicate_event" ? { result: "recorded", status: "failed" } : res;
  }
  return { result: "pending", status: "active" };
}

// ---------- actions ----------
async function createOrder(cfg, fetchImpl, user, body) {
  if (!isUuid(body.booking_id)) throw new HttpError(400, "Missing booking");
  if (cfg.mode === "test" && cfg.testers.length && !cfg.testers.includes(String(user.email || "").toLowerCase())) {
    throw new HttpError(503, "Online payments are being set up and will be ready very soon. Please try again later.");
  }
  const info = await rpc(cfg, fetchImpl, "pay_begin", { p_booking: body.booking_id, p_customer: user.id });
  const phone = indianMobile(info.customer_phone);
  if (!phone) throw new HttpError(400, "Add a valid 10-digit mobile number to pay.");
  const checkout = (orderRef, gatewayOrderId) => ({
    order_id: orderRef, gateway_order_id: gatewayOrderId, key_id: cfg.keyId, mode: cfg.mode,
    amount: Math.round(Number(info.amount) * 100), currency: "INR",
    name: "SnapPro", description: ("Photography with " + (info.photographer_name || "your photographer")).slice(0, 255),
    prefill: { name: String(info.customer_name || "").slice(0, 100), email: info.customer_email || "", contact: "+91" + phone },
    notes: { booking_id: String(info.booking_id) },
  });

  // One Razorpay order per booking: re-use it (Razorpay accepts retries on the
  // same order and refuses payments once it's paid), so a booking can't be paid twice.
  let reuse = null;
  for (const o of info.open_orders || []) {
    if (o.gateway_order_id && o.environment === cfg.mode) {
      const v = await verifyOrder(cfg, fetchImpl, o.gateway_order_id);
      if (v && (v.result === "confirmed" || v.result === "already_paid" || v.status === "paid")) {
        return { status: "paid", booking_id: info.booking_id, order_id: o.order_id };
      }
      if (!reuse && v && v.result !== "not_found") { reuse = o; continue; }
    }
    // other keys (test ↔ live) or never reached Razorpay: retire it
    await rpc(cfg, fetchImpl, "pay_record", { p_order_id: o.order_id, p_event_key: null, p_status: "TERMINATED" });
  }
  if (reuse) return { ...checkout(reuse.order_id, reuse.gateway_order_id), reused: true };

  const ref = newOrderRef();
  await rpc(cfg, fetchImpl, "pay_create", { p_booking: info.booking_id, p_customer: user.id, p_order_id: ref, p_env: cfg.mode });
  let order;
  try {
    order = await rzp(cfg, fetchImpl, "POST", "/orders", {
      amount: Math.round(Number(info.amount) * 100), currency: "INR", receipt: ref,
      notes: { booking_id: String(info.booking_id), customer_id: String(user.id) },
    });
  } catch (_) {
    await rpc(cfg, fetchImpl, "pay_record", { p_order_id: ref, p_event_key: null, p_status: "TERMINATED" }).catch(() => {});
    throw new HttpError(502, "We couldn't start the payment. Please try again in a moment.");
  }
  if (!order || !order.id) throw new HttpError(502, "We couldn't start the payment. Please try again.");
  await rpc(cfg, fetchImpl, "pay_set_gateway", { p_order_id: ref, p_gateway_order_id: order.id });
  return checkout(ref, order.id);
}

async function owned(cfg, fetchImpl, user, ref) {
  if (!isRef(ref)) throw new HttpError(400, "Missing order");
  const p = await rpc(cfg, fetchImpl, "pay_lookup", { p_order_id: ref });
  if (!p || p.customer_id !== user.id) throw new HttpError(404, "Payment not found");
  return p;
}
async function result(cfg, fetchImpl, ref) {
  const now = await rpc(cfg, fetchImpl, "pay_lookup", { p_order_id: ref });
  return { order_id: now.order_id, status: now.status, booking_id: now.booking_id, booking_status: now.booking_status, amount: now.amount, refund_status: now.refund_status };
}

async function verifyCheckout(cfg, fetchImpl, user, body) {
  const p = await owned(cfg, fetchImpl, user, body.order_id);
  const payId = String(body.razorpay_payment_id || "");
  if (!/^pay_[A-Za-z0-9]+$/.test(payId) || !p.gateway_order_id) throw new HttpError(400, "Payment could not be verified.");
  // signature = HMAC_SHA256(order_id + "|" + payment_id, key_secret), using OUR stored order id
  const expected = await hmacHex(cfg.secret, p.gateway_order_id + "|" + payId);
  if (!safeEqual(expected, String(body.razorpay_signature || ""))) throw new HttpError(400, "Payment could not be verified.");
  if (p.status !== "paid") {
    const pay = await rzp(cfg, fetchImpl, "GET", "/payments/" + encodeURIComponent(payId));
    if (pay.order_id !== p.gateway_order_id) throw new HttpError(400, "Payment could not be verified.");
    await applyPayment(cfg, fetchImpl, p.gateway_order_id, pay);
  }
  return result(cfg, fetchImpl, p.order_id);
}

async function orderStatus(cfg, fetchImpl, user, body) {
  const p = await owned(cfg, fetchImpl, user, body.order_id);
  if (p.status !== "paid" && p.gateway_order_id) await verifyOrder(cfg, fetchImpl, p.gateway_order_id);
  return result(cfg, fetchImpl, p.order_id);
}

async function requireAdmin(cfg, fetchImpl, user) {
  const role = await rpc(cfg, fetchImpl, "pay_staff_role", { p_user: user.id });
  if (role !== "super_admin" && role !== "admin") throw new HttpError(403, "Only admins can do that.");
}

async function refund(cfg, fetchImpl, user, body) {
  await requireAdmin(cfg, fetchImpl, user);
  if (!isUuid(body.payment_id)) throw new HttpError(400, "Missing payment");
  const amount = Math.round(Number(body.amount) * 100) / 100;
  if (!(amount > 0)) throw new HttpError(400, "Enter a refund amount");
  const reason = String(body.reason || "Refund").replace(/[^\w .,'()-]/g, " ").trim().slice(0, 100) || "Refund";
  const r = await rpc(cfg, fetchImpl, "pay_refund_begin", { p_payment: body.payment_id, p_amount: amount, p_reason: reason, p_staff: user.id });
  try {
    const res = await rzp(cfg, fetchImpl, "POST", "/payments/" + encodeURIComponent(r.gateway_payment_id) + "/refund", {
      amount: Math.round(Number(r.amount) * 100), speed: "normal", receipt: r.refund_id,
      notes: { reason, order_id: r.order_id },
    });
    const out = await rpc(cfg, fetchImpl, "pay_refund_update", {
      p_refund_id: r.refund_id, p_status: res.status || "pending", p_gateway_refund_id: res.id || null, p_arn: null, p_event_key: null,
    });
    return { refund_id: r.refund_id, status: (out && out.status) || "pending" };
  } catch (e) {
    await rpc(cfg, fetchImpl, "pay_refund_update", { p_refund_id: r.refund_id, p_status: "FAILED", p_gateway_refund_id: null, p_arn: null, p_event_key: null }).catch(() => {});
    throw new HttpError(502, "Razorpay didn't accept the refund: " + (e.message || "unknown error"));
  }
}

async function refundCheck(cfg, fetchImpl, user, body) {
  await requireAdmin(cfg, fetchImpl, user);
  const gid = String(body.gateway_refund_id || "");
  if (!/^rfnd_[A-Za-z0-9]+$/.test(gid)) throw new HttpError(400, "This refund hasn't reached Razorpay yet.");
  const res = await rzp(cfg, fetchImpl, "GET", "/refunds/" + encodeURIComponent(gid));
  const out = await rpc(cfg, fetchImpl, "pay_refund_update", {
    p_refund_id: isRef(body.refund_id) ? body.refund_id : gid, p_status: res.status, p_gateway_refund_id: gid,
    p_arn: (res.acquirer_data && res.acquirer_data.arn) || null, p_event_key: null,
  });
  return { refund_id: body.refund_id, status: (out && out.status) || String(res.status || "") };
}

export async function handler(req, env, fetchImpl) {
  const cfg = config(env);
  const headers = cors(req, cfg);
  if (req.method === "OPTIONS") return new Response("ok", { headers });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405, headers);
  try {
    if (!cfg.keyId || !cfg.secret) throw new HttpError(503, "Payments aren't set up yet.");
    if (!cfg.supabaseUrl || !cfg.serviceKey) throw new HttpError(503, "Server is missing its Supabase settings.");
    let body = {};
    try { body = await req.json(); } catch (_) { throw new HttpError(400, "Bad request"); }
    const user = await currentUser(cfg, fetchImpl, req);
    let out;
    if (body.action === "create") out = await createOrder(cfg, fetchImpl, user, body);
    else if (body.action === "verify") out = await verifyCheckout(cfg, fetchImpl, user, body);
    else if (body.action === "status") out = await orderStatus(cfg, fetchImpl, user, body);
    else if (body.action === "refund") out = await refund(cfg, fetchImpl, user, body);
    else if (body.action === "refund_check") out = await refundCheck(cfg, fetchImpl, user, body);
    else throw new HttpError(400, "Unknown action");
    return json(out, 200, headers);
  } catch (e) {
    const status = e instanceof HttpError ? e.status : 500;
    if (status >= 500) console.error("payments:", e && e.message);
    return json({ error: e instanceof HttpError ? e.message : "Something went wrong. Please try again." }, status, headers);
  }
}

// Supabase Edge Runtime entry point
if (typeof Deno !== "undefined" && Deno.serve) {
  Deno.serve((req) => handler(req, Deno.env.toObject(), fetch));
}
