// SnapPro — portfolio media on Amazon S3 + yearly storage plans (Supabase Edge Function)
//
// Actions (POST JSON, signed-in photographer's Supabase token in Authorization):
//   { action: "sign", kind: "image"|"video", type, bytes }   → one-time S3 upload link (10 minutes)
//   { action: "confirm", key }                                → checks the real size on S3, shows it on the profile
//   { action: "delete", url }                                 → removes it from the profile and from S3
//   { action: "buy", plan }                                   → Razorpay order for a yearly storage plan
//   { action: "verify_buy", order_id, razorpay_payment_id, razorpay_order_id, razorpay_signature }
//   { action: "buy_status", order_id }
//   { action: "purge" }                                       → admins: delete files whose 30 days are up
//
// Secrets (Supabase → Edge Functions → Secrets), never in the website:
//   AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY  — IAM user limited to snappro-portfolio/portfolio/*
//   S3_BUCKET, S3_REGION                      — e.g. snappro-portfolio, ap-southeast-2
//   RAZORPAY_KEY_ID, RAZORPAY_KEY_SECRET      — same as the payments function
//   optional: TEST_MODE_TESTERS, ALLOWED_ORIGINS, MEDIA_PUBLIC_BASE (e.g. a CloudFront address later)
//
// Sizes and limits are decided in the database (media_begin / media_confirm), and the real
// file size is read back from S3 before anything appears on a profile.

export function config(env) {
  const bucket = env.S3_BUCKET || "", region = env.S3_REGION || "";
  const keyId = env.RAZORPAY_KEY_ID || "";
  return {
    awsKey: env.AWS_ACCESS_KEY_ID || "", awsSecret: env.AWS_SECRET_ACCESS_KEY || "", bucket, region,
    host: bucket && region ? bucket + ".s3." + region + ".amazonaws.com" : "",
    publicBase: (env.MEDIA_PUBLIC_BASE || (bucket && region ? "https://" + bucket + ".s3." + region + ".amazonaws.com" : "")).replace(/\/$/, ""),
    rzpKey: keyId, rzpSecret: env.RAZORPAY_KEY_SECRET || "", mode: keyId.startsWith("rzp_live_") ? "live" : "test",
    rzpApi: "https://api.razorpay.com/v1",
    supabaseUrl: (env.SUPABASE_URL || "").replace(/\/$/, ""),
    serviceKey: env.SUPABASE_SERVICE_ROLE_KEY || "",
    anonKey: env.SUPABASE_ANON_KEY || env.SUPABASE_SERVICE_ROLE_KEY || "",
    origins: String(env.ALLOWED_ORIGINS || "https://snappro.in,https://www.snappro.in").split(",").map((s) => s.trim()).filter(Boolean),
    testers: String(env.TEST_MODE_TESTERS || "").split(",").map((s) => s.trim().toLowerCase()).filter(Boolean),
  };
}

class HttpError extends Error { status = 500; constructor(status, message) { super(message); this.status = status; } }
function cors(req, cfg) {
  const origin = req.headers.get("origin") || "";
  return { "Access-Control-Allow-Origin": cfg.origins.includes(origin) ? origin : cfg.origins[0],
           "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info",
           "Access-Control-Allow-Methods": "POST, OPTIONS", "Vary": "Origin" };
}
const json = (body, status, headers) => new Response(JSON.stringify(body), { status, headers: { ...headers, "Content-Type": "application/json" } });

// ---------- Supabase ----------
async function rpc(cfg, fetchImpl, name, args) {
  const h = { apikey: cfg.serviceKey, "Content-Type": "application/json" };
  if (cfg.serviceKey.startsWith("eyJ")) h.Authorization = "Bearer " + cfg.serviceKey;
  const r = await fetchImpl(cfg.supabaseUrl + "/rest/v1/rpc/" + name, { method: "POST", headers: h, body: JSON.stringify(args) });
  const text = await r.text();
  let data = null; try { data = text ? JSON.parse(text) : null; } catch (_) { data = text; }
  if (!r.ok) {
    const msg = String((data && (data.message || data.error)) || ("Database error " + r.status)).replace(/^STORAGE_FULL:\s*/, "");
    throw new HttpError(r.status >= 500 ? 500 : 400, msg);
  }
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

// ---------- AWS Signature V4 (no SDK needed) ----------
const enc = new TextEncoder();
const hex = (buf) => Array.from(new Uint8Array(buf), (b) => b.toString(16).padStart(2, "0")).join("");
async function sha256Hex(s) { return hex(await crypto.subtle.digest("SHA-256", enc.encode(s))); }
async function hmac(key, msg) {
  const k = await crypto.subtle.importKey("raw", typeof key === "string" ? enc.encode(key) : key, { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  return new Uint8Array(await crypto.subtle.sign("HMAC", k, enc.encode(msg)));
}
const rfc3986 = (s) => encodeURIComponent(s).replace(/[!'()*]/g, (c) => "%" + c.charCodeAt(0).toString(16).toUpperCase());
const encodeKey = (key) => key.split("/").map(rfc3986).join("/");
function amzDates(now) {
  const iso = new Date(now).toISOString().replace(/[-:]/g, "").replace(/\.\d{3}/, "");   // 20261011T174500Z
  return { amz: iso, day: iso.slice(0, 8) };
}
async function signingKey(cfg, day) {
  const kDate = await hmac("AWS4" + cfg.awsSecret, day);
  const kRegion = await hmac(kDate, cfg.region);
  const kService = await hmac(kRegion, "s3");
  return hmac(kService, "aws4_request");
}
// A pre-signed PUT link: the browser uploads straight to S3 with exactly this Content-Type.
export async function presignPut(cfg, key, contentType, expires = 600, now = Date.now()) {
  const { amz, day } = amzDates(now);
  const scope = day + "/" + cfg.region + "/s3/aws4_request";
  const q = { "X-Amz-Algorithm": "AWS4-HMAC-SHA256", "X-Amz-Credential": cfg.awsKey + "/" + scope, "X-Amz-Date": amz,
              "X-Amz-Expires": String(expires), "X-Amz-SignedHeaders": "content-type;host" };
  const qs = Object.keys(q).sort().map((k) => rfc3986(k) + "=" + rfc3986(q[k])).join("&");
  const path = "/" + encodeKey(key);
  const canonical = ["PUT", path, qs, "content-type:" + contentType + "\nhost:" + cfg.host + "\n", "content-type;host", "UNSIGNED-PAYLOAD"].join("\n");
  const sts = ["AWS4-HMAC-SHA256", amz, scope, await sha256Hex(canonical)].join("\n");
  const sig = hex(await hmac(await signingKey(cfg, day), sts));
  return "https://" + cfg.host + path + "?" + qs + "&X-Amz-Signature=" + sig;
}
// A signed server-side request (HEAD / DELETE) to S3.
export async function s3Request(cfg, fetchImpl, method, key, now = Date.now()) {
  const { amz, day } = amzDates(now);
  const scope = day + "/" + cfg.region + "/s3/aws4_request";
  const payload = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";       // sha256("")
  const path = "/" + encodeKey(key);
  const canonical = [method, path, "", "host:" + cfg.host + "\nx-amz-content-sha256:" + payload + "\nx-amz-date:" + amz + "\n",
                     "host;x-amz-content-sha256;x-amz-date", payload].join("\n");
  const sts = ["AWS4-HMAC-SHA256", amz, scope, await sha256Hex(canonical)].join("\n");
  const sig = hex(await hmac(await signingKey(cfg, day), sts));
  return fetchImpl("https://" + cfg.host + path, { method, headers: {
    "x-amz-content-sha256": payload, "x-amz-date": amz,
    Authorization: "AWS4-HMAC-SHA256 Credential=" + cfg.awsKey + "/" + scope + ", SignedHeaders=host;x-amz-content-sha256;x-amz-date, Signature=" + sig } });
}
async function s3Delete(cfg, fetchImpl, key) {
  try { const r = await s3Request(cfg, fetchImpl, "DELETE", key); return r.ok || r.status === 404; } catch (_) { return false; }
}
// Clean up a few files whose 30 days are up (runs alongside normal requests).
async function purgeSome(cfg, fetchImpl, limit) {
  const keys = await rpc(cfg, fetchImpl, "media_purge_list", { p_limit: limit });
  const done = [];
  for (const k of keys || []) if (await s3Delete(cfg, fetchImpl, k)) done.push(k);
  if (done.length) await rpc(cfg, fetchImpl, "media_mark_purged", { p_keys: done });
  return done.length;
}

// ---------- media actions ----------
const TYPES = { "image/jpeg": ["image", "jpg"], "image/png": ["image", "png"], "image/webp": ["image", "webp"],
                "video/mp4": ["video", "mp4"], "video/quicktime": ["video", "mov"], "video/webm": ["video", "webm"] };
async function sign(cfg, fetchImpl, user, body) {
  const t = TYPES[String(body.type || "").toLowerCase()];
  if (!t) throw new HttpError(400, "Upload JPG, PNG or WebP photos, or MP4, MOV or WebM videos.");
  const bytes = Math.floor(Number(body.bytes));
  if (!(bytes > 0)) throw new HttpError(400, "That file is empty.");
  const slot = await rpc(cfg, fetchImpl, "media_begin", { p_user: user.id, p_kind: t[0], p_type: String(body.type).toLowerCase(), p_ext: t[1], p_bytes: bytes, p_base_url: cfg.publicBase });
  return { key: slot.key, url: slot.url, kind: t[0], upload_url: await presignPut(cfg, slot.key, String(body.type).toLowerCase()),
           headers: { "Content-Type": String(body.type).toLowerCase() }, used: slot.used, quota: slot.quota };
}
async function confirm(cfg, fetchImpl, user, body) {
  const key = String(body.key || "");
  if (!key.startsWith("portfolio/" + user.id + "/") || key.includes("..")) throw new HttpError(400, "Upload not found.");
  const head = await s3Request(cfg, fetchImpl, "HEAD", key);
  if (!head.ok) throw new HttpError(400, "The upload didn't reach storage. Please try again.");
  const size = Number(head.headers.get("content-length") || 0);
  const res = await rpc(cfg, fetchImpl, "media_confirm", { p_user: user.id, p_key: key, p_bytes: size });
  if (res && res.result === "rejected") {
    await s3Delete(cfg, fetchImpl, key);
    throw new HttpError(400, "That file is bigger than the space you have left. Delete something or upgrade your storage.");
  }
  purgeSome(cfg, fetchImpl, 10).catch(() => {});
  return { url: res.url, kind: res.kind };
}
async function remove(cfg, fetchImpl, user, body) {
  const url = String(body.url || "");
  if (!url) throw new HttpError(400, "Missing item.");
  const res = await rpc(cfg, fetchImpl, "media_delete", { p_user: user.id, p_url: url });
  if (res && res.delete_key) await s3Delete(cfg, fetchImpl, res.delete_key);
  return { removed: true };
}

// ---------- buying storage (Razorpay) ----------
async function rzp(cfg, fetchImpl, method, path, body) {
  const r = await fetchImpl(cfg.rzpApi + path, { method, headers: { Authorization: "Basic " + btoa(cfg.rzpKey + ":" + cfg.rzpSecret), "Content-Type": "application/json" },
                                                 body: body ? JSON.stringify(body) : undefined });
  const text = await r.text();
  let data = null; try { data = text ? JSON.parse(text) : null; } catch (_) { data = { error: { description: text } }; }
  if (!r.ok) throw new HttpError(r.status === 404 ? 404 : 502, (data && data.error && data.error.description) || ("Razorpay error " + r.status));
  return data;
}
const safeEqual = (a, b) => { if (typeof a !== "string" || typeof b !== "string" || a.length !== b.length) return false; let d = 0; for (let i = 0; i < a.length; i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i); return d === 0; };
const indianMobile = (v) => { let d = String(v || "").replace(/\D/g, ""); if (d.length === 12 && d.startsWith("91")) d = d.slice(2); if (d.length === 11 && d.startsWith("0")) d = d.slice(1); return /^[6-9]\d{9}$/.test(d) ? d : null; };
async function recordPayment(cfg, fetchImpl, gatewayOrderId, p) {
  if (!p || p.order_id !== gatewayOrderId) return { result: "mismatch" };
  let pay = p;
  if (pay.status === "authorized") {
    try { pay = await rzp(cfg, fetchImpl, "POST", "/payments/" + encodeURIComponent(p.id) + "/capture", { amount: p.amount, currency: p.currency || "INR" }); }
    catch (_) { pay = await rzp(cfg, fetchImpl, "GET", "/payments/" + encodeURIComponent(p.id)); }
  }
  const st = pay.status === "captured" ? "CAPTURED" : pay.status === "failed" ? "FAILED" : String(pay.status || "").toUpperCase();
  return rpc(cfg, fetchImpl, "storage_record", { p_order_id: gatewayOrderId, p_event_key: "verify:" + pay.id + ":" + st, p_status: st,
    p_payment_ref: pay.id, p_amount: typeof pay.amount === "number" ? pay.amount / 100 : null, p_group: pay.method || null });
}
async function buy(cfg, fetchImpl, user, body) {
  if (!cfg.rzpKey || !cfg.rzpSecret) throw new HttpError(503, "Payments aren't set up yet.");
  if (cfg.mode === "test" && cfg.testers.length && !cfg.testers.includes(String(user.email || "").toLowerCase()))
    throw new HttpError(503, "Online payments are being set up and will be ready very soon. Please try again later.");
  const plan = String(body.plan || "");
  if (!/^[a-z0-9_-]{2,20}$/.test(plan)) throw new HttpError(400, "Choose a plan.");
  const info = await rpc(cfg, fetchImpl, "storage_begin", { p_user: user.id, p_plan: plan });
  const phone = indianMobile(info.customer_phone);
  const checkout = (ref, gid) => ({ order_id: ref, gateway_order_id: gid, key_id: cfg.rzpKey, mode: cfg.mode,
    amount: Math.round(Number(info.amount) * 100), currency: "INR", name: "SnapPro",
    description: ("SnapPro storage — " + info.name + " (" + info.gb + " GB, 1 year)").slice(0, 255),
    prefill: { name: String(info.customer_name || "").slice(0, 100), email: info.customer_email || "", contact: phone ? "+91" + phone : "" },
    notes: { purpose: "storage", plan } });
  for (const o of info.open_orders || []) {
    if (o.gateway_order_id && o.environment === cfg.mode) return { ...checkout(o.order_id, o.gateway_order_id), reused: true };
  }
  const d = new Date(Date.now() + 5.5 * 3600e3).toISOString().slice(2, 10).replace(/-/g, "");
  const ref = "ST" + d + "_" + crypto.randomUUID().replace(/-/g, "").slice(0, 14);
  await rpc(cfg, fetchImpl, "storage_create", { p_user: user.id, p_plan: plan, p_order_id: ref, p_env: cfg.mode });
  let order;
  try {
    order = await rzp(cfg, fetchImpl, "POST", "/orders", { amount: Math.round(Number(info.amount) * 100), currency: "INR", receipt: ref,
      notes: { purpose: "storage", plan, photographer_id: String(user.id) } });
  } catch (_) {
    await rpc(cfg, fetchImpl, "storage_record", { p_order_id: ref, p_event_key: null, p_status: "TERMINATED" }).catch(() => {});
    throw new HttpError(502, "We couldn't start the payment. Please try again in a moment.");
  }
  await rpc(cfg, fetchImpl, "storage_set_gateway", { p_order_id: ref, p_gateway_order_id: order.id });
  return checkout(ref, order.id);
}
async function ownOrder(cfg, fetchImpl, user, ref) {
  if (!/^[A-Za-z0-9_-]{3,45}$/.test(String(ref || ""))) throw new HttpError(400, "Missing order");
  const o = await rpc(cfg, fetchImpl, "storage_lookup", { p_order_id: ref });
  if (!o || o.photographer_id !== user.id) throw new HttpError(404, "Order not found");
  return o;
}
async function verifyBuy(cfg, fetchImpl, user, body) {
  const o = await ownOrder(cfg, fetchImpl, user, body.order_id);
  const payId = String(body.razorpay_payment_id || "");
  if (!/^pay_[A-Za-z0-9]+$/.test(payId) || !o.gateway_order_id) throw new HttpError(400, "Payment could not be verified.");
  const expected = hex(await hmac(cfg.rzpSecret, o.gateway_order_id + "|" + payId));
  if (!safeEqual(expected, String(body.razorpay_signature || ""))) throw new HttpError(400, "Payment could not be verified.");
  if (o.status !== "paid") {
    const pay = await rzp(cfg, fetchImpl, "GET", "/payments/" + encodeURIComponent(payId));
    if (pay.order_id !== o.gateway_order_id) throw new HttpError(400, "Payment could not be verified.");
    await recordPayment(cfg, fetchImpl, o.gateway_order_id, pay);
  }
  const now = await rpc(cfg, fetchImpl, "storage_lookup", { p_order_id: o.order_id });
  return { order_id: now.order_id, status: now.status, plan: now.plan, period_end: now.period_end };
}
async function buyStatus(cfg, fetchImpl, user, body) {
  const o = await ownOrder(cfg, fetchImpl, user, body.order_id);
  if (o.status !== "paid" && o.gateway_order_id) {
    const list = await rzp(cfg, fetchImpl, "GET", "/orders/" + encodeURIComponent(o.gateway_order_id) + "/payments").catch(() => null);
    const items = (list && list.items) || [];
    const good = items.find((p) => p.status === "captured") || items.find((p) => p.status === "authorized");
    if (good) await recordPayment(cfg, fetchImpl, o.gateway_order_id, good);
  }
  const now = await rpc(cfg, fetchImpl, "storage_lookup", { p_order_id: o.order_id });
  return { order_id: now.order_id, status: now.status, plan: now.plan, period_end: now.period_end };
}
async function purge(cfg, fetchImpl, user) {
  const role = await rpc(cfg, fetchImpl, "pay_staff_role", { p_user: user.id });
  if (role !== "super_admin" && role !== "admin") throw new HttpError(403, "Only admins can do that.");
  await rpc(cfg, fetchImpl, "storage_sweep", {});
  return { deleted: await purgeSome(cfg, fetchImpl, 200) };
}

export async function handler(req, env, fetchImpl) {
  const cfg = config(env);
  const headers = cors(req, cfg);
  if (req.method === "OPTIONS") return new Response("ok", { headers });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405, headers);
  try {
    if (!cfg.supabaseUrl || !cfg.serviceKey) throw new HttpError(503, "Server is missing its Supabase settings.");
    let body = {};
    try { body = await req.json(); } catch (_) { throw new HttpError(400, "Bad request"); }
    const user = await currentUser(cfg, fetchImpl, req);
    const a = body.action;
    if ((a === "sign" || a === "confirm" || a === "delete" || a === "purge") && (!cfg.awsKey || !cfg.awsSecret || !cfg.host))
      throw new HttpError(503, "Photo storage isn't set up yet.");
    let out;
    if (a === "sign") out = await sign(cfg, fetchImpl, user, body);
    else if (a === "confirm") out = await confirm(cfg, fetchImpl, user, body);
    else if (a === "delete") out = await remove(cfg, fetchImpl, user, body);
    else if (a === "buy") out = await buy(cfg, fetchImpl, user, body);
    else if (a === "verify_buy") out = await verifyBuy(cfg, fetchImpl, user, body);
    else if (a === "buy_status") out = await buyStatus(cfg, fetchImpl, user, body);
    else if (a === "purge") out = await purge(cfg, fetchImpl, user);
    else throw new HttpError(400, "Unknown action");
    return json(out, 200, headers);
  } catch (e) {
    const status = e instanceof HttpError ? e.status : 500;
    if (status >= 500) console.error("media:", e && e.message);
    return json({ error: e instanceof HttpError ? e.message : "Something went wrong. Please try again." }, status, headers);
  }
}

if (typeof Deno !== "undefined" && Deno.serve) {
  Deno.serve((req) => handler(req, Deno.env.toObject(), fetch));
}
