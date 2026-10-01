// SnapPro — payments (Supabase Edge Function)
//
// Actions (POST JSON, signed-in user's Supabase token in Authorization):
//   { action: "create", booking_id }        customer → Cashfree order + payment_session_id
//   { action: "status", order_id }          customer → verify with Cashfree, update booking
//   { action: "refund", payment_id, amount, reason }   admin / super admin only
//   { action: "refund_check", refund_id, order_id }    admin / super admin only
//
// Secrets (Supabase → Edge Functions → Secrets), never in the website:
//   CASHFREE_APP_ID, CASHFREE_SECRET_KEY, CASHFREE_ENVIRONMENT ("sandbox" | "production")
// Optional: SITE_URL (default https://snappro.in), ALLOWED_ORIGINS, CASHFREE_API_VERSION,
//   SANDBOX_TESTERS — comma-separated emails allowed to pay while CASHFREE_ENVIRONMENT is
//   "sandbox". Protects the live site: real customers can't "pay" with test cards.
// Supabase provides SUPABASE_URL, SUPABASE_ANON_KEY and SUPABASE_SERVICE_ROLE_KEY automatically.
//
// The amount always comes from the database, never from the browser. Payment
// state only changes through the pay_* database functions, which are
// idempotent and lock the payment and booking rows.

const API_VERSION_DEFAULT = "2026-01-01";

export function config(env) {
  const mode = String(env.CASHFREE_ENVIRONMENT || "sandbox").toLowerCase() === "production" ? "production" : "sandbox";
  return {
    mode,
    appId: env.CASHFREE_APP_ID || "",
    secret: env.CASHFREE_SECRET_KEY || "",
    apiVersion: env.CASHFREE_API_VERSION || API_VERSION_DEFAULT,
    cfBase: mode === "production" ? "https://api.cashfree.com/pg" : "https://sandbox.cashfree.com/pg",
    supabaseUrl: (env.SUPABASE_URL || "").replace(/\/$/, ""),
    serviceKey: env.SUPABASE_SERVICE_ROLE_KEY || "",
    anonKey: env.SUPABASE_ANON_KEY || env.SUPABASE_SERVICE_ROLE_KEY || "",
    siteUrl: (env.SITE_URL || "https://snappro.in").replace(/\/$/, ""),
    origins: String(env.ALLOWED_ORIGINS || "https://snappro.in,https://www.snappro.in").split(",").map((s) => s.trim()).filter(Boolean),
    testers: String(env.SANDBOX_TESTERS || "").split(",").map((s) => s.trim().toLowerCase()).filter(Boolean),
  };
}

class HttpError extends Error {
  status = 500;
  cf = null;
  cfStatus = 0;
  constructor(status, message) { super(message); this.status = status; }
}

function cors(req, cfg) {
  const origin = req.headers.get("origin") || "";
  const allow = cfg.origins.includes(origin) ? origin : cfg.origins[0];
  return {
    "Access-Control-Allow-Origin": allow,
    "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Vary": "Origin",
  };
}
function json(body, status, headers) {
  return new Response(JSON.stringify(body), { status, headers: { ...headers, "Content-Type": "application/json" } });
}

// ---------- Supabase (service key, server only) ----------
function sbHeaders(cfg) {
  const h = { apikey: cfg.serviceKey, "Content-Type": "application/json" };
  if (cfg.serviceKey.startsWith("eyJ")) h.Authorization = "Bearer " + cfg.serviceKey;   // legacy service_role JWT
  return h;
}
export async function rpc(cfg, fetchImpl, name, args) {
  const r = await fetchImpl(cfg.supabaseUrl + "/rest/v1/rpc/" + name, { method: "POST", headers: sbHeaders(cfg), body: JSON.stringify(args) });
  const text = await r.text();
  let data = null; try { data = text ? JSON.parse(text) : null; } catch (_) { data = text; }
  if (!r.ok) {
    const msg = (data && (data.message || data.error)) || ("Database error " + r.status);
    throw new HttpError(r.status >= 500 ? 500 : 400, msg);
  }
  return data;
}
async function currentUser(cfg, fetchImpl, req) {
  const auth = req.headers.get("authorization") || "";
  const token = auth.replace(/^Bearer\s+/i, "");
  if (!token || token === cfg.anonKey) throw new HttpError(401, "Please log in again.");
  const r = await fetchImpl(cfg.supabaseUrl + "/auth/v1/user", { headers: { apikey: cfg.anonKey, Authorization: "Bearer " + token } });
  if (!r.ok) throw new HttpError(401, "Please log in again.");
  const u = await r.json();
  if (!u || !u.id) throw new HttpError(401, "Please log in again.");
  return u;
}

// ---------- Cashfree ----------
export async function cf(cfg, fetchImpl, method, path, body, extraHeaders) {
  const r = await fetchImpl(cfg.cfBase + path, {
    method,
    headers: {
      "x-client-id": cfg.appId, "x-client-secret": cfg.secret, "x-api-version": cfg.apiVersion,
      "Content-Type": "application/json", Accept: "application/json", ...(extraHeaders || {}),
    },
    body: body ? JSON.stringify(body) : undefined,
  });
  const text = await r.text();
  let data = null; try { data = text ? JSON.parse(text) : null; } catch (_) { data = { message: text }; }
  if (!r.ok) {
    const e = new HttpError(r.status === 404 ? 404 : 502, (data && data.message) || ("Payment provider error " + r.status));
    e.cf = data; e.cfStatus = r.status;
    throw e;
  }
  return data;
}

const isUuid = (v) => typeof v === "string" && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(v);
const isOrderId = (v) => typeof v === "string" && /^[A-Za-z0-9_-]{3,45}$/.test(v);
function newOrderId() {
  const d = new Date(Date.now() + 5.5 * 3600e3).toISOString().slice(2, 10).replace(/-/g, "");
  const rand = crypto.randomUUID().replace(/-/g, "").slice(0, 14);
  return "SP" + d + "_" + rand;                                  // e.g. SP261001_3f9a0c1d2b7e44
}
function indianMobile(v) {
  let d = String(v || "").replace(/\D/g, "");
  if (d.length === 12 && d.startsWith("91")) d = d.slice(2);
  if (d.length === 11 && d.startsWith("0")) d = d.slice(1);
  return /^[6-9]\d{9}$/.test(d) ? d : null;
}

// Ask Cashfree what really happened to an order and record it (idempotent).
export async function verifyOrder(cfg, fetchImpl, orderId) {
  let order;
  try { order = await cf(cfg, fetchImpl, "GET", "/orders/" + encodeURIComponent(orderId)); }
  catch (e) { if (e.status === 404) return { result: "not_found" }; throw e; }
  const status = String(order.order_status || "").toUpperCase();
  let payments = [];
  try { payments = await cf(cfg, fetchImpl, "GET", "/orders/" + encodeURIComponent(orderId) + "/payments"); } catch (_) { payments = []; }
  if (!Array.isArray(payments)) payments = [];
  const ok = payments.find((p) => String(p.payment_status).toUpperCase() === "SUCCESS");
  if (status === "PAID" && ok) {
    return rpc(cfg, fetchImpl, "pay_record", {
      p_order_id: orderId, p_event_key: "verify:" + ok.cf_payment_id + ":SUCCESS", p_status: "SUCCESS",
      p_cf_payment_id: String(ok.cf_payment_id), p_amount: Number(ok.payment_amount), p_group: ok.payment_group || null,
      p_bank_ref: ok.bank_reference || null, p_message: ok.payment_message || null, p_event_type: "VERIFY",
    });
  }
  if (status === "EXPIRED" || status === "TERMINATED") {
    return rpc(cfg, fetchImpl, "pay_record", { p_order_id: orderId, p_event_key: null, p_status: status });
  }
  // still ACTIVE: report the latest attempt, if any
  const latest = payments.slice().sort((a, b) => String(b.payment_completion_time || b.payment_time || "").localeCompare(String(a.payment_completion_time || a.payment_time || "")))[0];
  if (latest && ["FAILED", "USER_DROPPED", "CANCELLED", "VOID"].includes(String(latest.payment_status).toUpperCase())) {
    const st = String(latest.payment_status).toUpperCase();
    const res = await rpc(cfg, fetchImpl, "pay_record", {
      p_order_id: orderId, p_event_key: "verify:" + latest.cf_payment_id + ":" + st, p_status: st,
      p_cf_payment_id: String(latest.cf_payment_id), p_amount: null, p_group: latest.payment_group || null,
      p_bank_ref: null, p_message: latest.payment_message || null, p_event_type: "VERIFY",
    });
    return res && res.result === "duplicate_event" ? { result: "recorded", status: st === "USER_DROPPED" ? "user_dropped" : st === "FAILED" ? "failed" : "cancelled" } : res;
  }
  return { result: "pending", status: "active" };
}

// ---------- actions ----------
async function createOrder(cfg, fetchImpl, user, body) {
  if (!isUuid(body.booking_id)) throw new HttpError(400, "Missing booking");
  if (cfg.mode === "sandbox" && cfg.testers.length && !cfg.testers.includes(String(user.email || "").toLowerCase())) {
    throw new HttpError(503, "Online payments are being set up and will be ready very soon. Please try again later.");
  }
  const info = await rpc(cfg, fetchImpl, "pay_begin", { p_booking: body.booking_id, p_customer: user.id });

  // An unfinished checkout for this booking? Re-use it if still fresh, otherwise
  // close it so the customer can't end up paying twice.
  for (const o of info.open_orders || []) {
    const fresh = o.payment_session_id && o.environment === cfg.mode && o.session_expires_at &&
                  Date.parse(o.session_expires_at) - Date.now() > 5 * 60e3;
    const v = await verifyOrder(cfg, fetchImpl, o.order_id);
    if (v && (v.result === "confirmed" || v.result === "already_paid" || v.status === "paid")) {
      return { status: "paid", booking_id: info.booking_id, order_id: o.order_id };
    }
    if (fresh && v && v.status !== "expired" && v.status !== "terminated") {
      // same checkout is still open at Cashfree (maybe after a failed try): let them retry it
      return { order_id: o.order_id, payment_session_id: o.payment_session_id, mode: cfg.mode, reused: true };
    }
    // stale: close it at Cashfree so it can never be paid, then forget it
    try { await cf(cfg, fetchImpl, "PATCH", "/orders/" + encodeURIComponent(o.order_id), { order_status: "TERMINATED" }); } catch (_) { /* already closed or never created */ }
    await rpc(cfg, fetchImpl, "pay_record", { p_order_id: o.order_id, p_event_key: null, p_status: "TERMINATED" });
  }

  const phone = indianMobile(info.customer_phone);
  if (!phone) throw new HttpError(400, "Add a valid 10-digit mobile number to pay.");
  const orderId = newOrderId();
  await rpc(cfg, fetchImpl, "pay_create", { p_booking: info.booking_id, p_customer: user.id, p_order_id: orderId, p_env: cfg.mode });

  const when = info.start_at ? new Date(Date.parse(info.start_at) + 5.5 * 3600e3).toISOString().slice(0, 16).replace("T", " ") : "";
  const name = String(info.customer_name || "").trim();
  const orderReq = {
    order_id: orderId,
    order_amount: Number(info.amount),
    order_currency: "INR",
    customer_details: {
      customer_id: user.id.replace(/-/g, ""),
      customer_phone: phone,
      ...(info.customer_email ? { customer_email: String(info.customer_email).slice(0, 100) } : {}),
      ...(name.length >= 3 ? { customer_name: name.slice(0, 100) } : {}),
    },
    order_meta: {
      return_url: cfg.siteUrl + "/app.html?payment=" + orderId,
      notify_url: cfg.supabaseUrl + "/functions/v1/cashfree-webhook",
      payment_methods: "upi,cc,dc,nb",
    },
    order_expiry_time: new Date(Date.now() + 30 * 60e3).toISOString(),
    order_note: ("SnapPro booking " + String(info.booking_id).slice(0, 8)).slice(0, 200),
    order_tags: {
      booking_id: String(info.booking_id),
      checkout_context: ("Photography with " + (info.photographer_name || "your photographer") + (when ? ", " + when : "")).slice(0, 100),
    },
  };
  let order;
  try {
    order = await cf(cfg, fetchImpl, "POST", "/orders", orderReq, { "x-idempotency-key": crypto.randomUUID() });
  } catch (e) {
    await rpc(cfg, fetchImpl, "pay_record", { p_order_id: orderId, p_event_key: null, p_status: "TERMINATED" }).catch(() => {});
    throw new HttpError(502, "We couldn't start the payment. Please try again in a moment.");
  }
  if (!order || !order.payment_session_id) throw new HttpError(502, "We couldn't start the payment. Please try again.");
  await rpc(cfg, fetchImpl, "pay_set_session", {
    p_order_id: orderId, p_cf_order_id: String(order.cf_order_id || ""), p_session: order.payment_session_id,
    p_expires: order.order_expiry_time || orderReq.order_expiry_time,
  });
  return { order_id: orderId, payment_session_id: order.payment_session_id, mode: cfg.mode };
}

async function orderStatus(cfg, fetchImpl, user, body) {
  if (!isOrderId(body.order_id)) throw new HttpError(400, "Missing order");
  const p = await rpc(cfg, fetchImpl, "pay_lookup", { p_order_id: body.order_id });
  if (!p || p.customer_id !== user.id) throw new HttpError(404, "Payment not found");
  if (p.status !== "paid") await verifyOrder(cfg, fetchImpl, body.order_id);
  const now = await rpc(cfg, fetchImpl, "pay_lookup", { p_order_id: body.order_id });
  return { order_id: now.order_id, status: now.status, booking_id: now.booking_id, booking_status: now.booking_status, amount: now.amount, refund_status: now.refund_status };
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
    const res = await cf(cfg, fetchImpl, "POST", "/orders/" + encodeURIComponent(r.order_id) + "/refunds",
      { refund_amount: r.amount, refund_id: r.refund_id, refund_note: reason.length >= 3 ? reason : "Refund" },
      { "x-idempotency-key": crypto.randomUUID() });
    const out = await rpc(cfg, fetchImpl, "pay_refund_update", {
      p_refund_id: r.refund_id, p_status: res.refund_status || "PENDING", p_cf_refund_id: res.cf_refund_id ? String(res.cf_refund_id) : null,
      p_arn: res.refund_arn || null, p_event_key: null,
    });
    return { refund_id: r.refund_id, status: (out && out.status) || "pending" };
  } catch (e) {
    await rpc(cfg, fetchImpl, "pay_refund_update", { p_refund_id: r.refund_id, p_status: "FAILED", p_cf_refund_id: null, p_arn: null, p_event_key: null }).catch(() => {});
    throw new HttpError(502, "Cashfree didn't accept the refund: " + (e.message || "unknown error"));
  }
}

async function refundCheck(cfg, fetchImpl, user, body) {
  await requireAdmin(cfg, fetchImpl, user);
  if (!isOrderId(body.order_id) || !isOrderId(body.refund_id)) throw new HttpError(400, "Missing refund");
  const res = await cf(cfg, fetchImpl, "GET", "/orders/" + encodeURIComponent(body.order_id) + "/refunds/" + encodeURIComponent(body.refund_id));
  const out = await rpc(cfg, fetchImpl, "pay_refund_update", {
    p_refund_id: body.refund_id, p_status: res.refund_status, p_cf_refund_id: res.cf_refund_id ? String(res.cf_refund_id) : null,
    p_arn: res.refund_arn || null, p_event_key: null,
  });
  return { refund_id: body.refund_id, status: (out && out.status) || String(res.refund_status || "").toLowerCase() };
}

export async function handler(req, env, fetchImpl) {
  const cfg = config(env);
  const headers = cors(req, cfg);
  if (req.method === "OPTIONS") return new Response("ok", { headers });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405, headers);
  try {
    if (!cfg.appId || !cfg.secret) throw new HttpError(503, "Payments aren't set up yet.");
    if (!cfg.supabaseUrl || !cfg.serviceKey) throw new HttpError(503, "Server is missing its Supabase settings.");
    let body = {};
    try { body = await req.json(); } catch (_) { throw new HttpError(400, "Bad request"); }
    const user = await currentUser(cfg, fetchImpl, req);
    let out;
    if (body.action === "create") out = await createOrder(cfg, fetchImpl, user, body);
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
