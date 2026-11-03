// SnapPro — phone notifications (Web Push) — Supabase Edge Function "push"
//
// The database calls this (POST, header x-push-secret) whenever notifications are waiting in
// public.push_outbox. It takes them with push_take(), encrypts each one for every phone the
// person has (RFC 8291, aes128gcm), signs the request with the VAPID key (RFC 8292), sends it
// to Google/Mozilla/Apple/Microsoft's push service, then reports back with push_done().
//
// Deploy with "Verify JWT" OFF (the database authenticates with the shared secret instead).
// Secrets (Supabase → Edge Functions → Secrets), never in the website:
//   VAPID_PUBLIC_KEY, VAPID_PRIVATE_KEY  — made with SnapPro-Push-Keys.html
//   PUSH_HOOK_SECRET                     — the same value saved in Vault as push_hook_secret
//   optional: VAPID_SUBJECT (default mailto:snappro.support@gmail.com)
//   FIREBASE_SERVICE_ACCOUNT — the whole JSON key file of a Firebase service account (Firebase →
//     Project settings → Service accounts → Generate new private key). Used to send to the
//     SnapPro Android app 1.2+ through Firebase Cloud Messaging (subscriptions saved as "fcm:<token>").

export function config(env) {
  return {
    pub: env.VAPID_PUBLIC_KEY || "", priv: env.VAPID_PRIVATE_KEY || "",
    subject: env.VAPID_SUBJECT || "mailto:snappro.support@gmail.com",
    hook: env.PUSH_HOOK_SECRET || "",
    supabaseUrl: (env.SUPABASE_URL || "").replace(/\/$/, ""),
    serviceKey: env.SUPABASE_SERVICE_ROLE_KEY || "",
    fcm: parseServiceAccount(env.FIREBASE_SERVICE_ACCOUNT),
  };
}
function parseServiceAccount(raw) {
  try {
    const j = JSON.parse(raw || "");
    return j && j.client_email && j.private_key && j.project_id ? j : null;
  } catch (_) { return null; }
}
const enc = new TextEncoder();
const subtle = () => globalThis.crypto.subtle;
export const b64u = (buf) => { let s = ""; const b = new Uint8Array(buf); for (let i = 0; i < b.length; i++) s += String.fromCharCode(b[i]);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, ""); };
export const unb64u = (s) => { s = String(s).replace(/-/g, "+").replace(/_/g, "/"); while (s.length % 4) s += "=";
  const bin = atob(s), out = new Uint8Array(bin.length); for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i); return out; };
const cat = (...parts) => { const n = parts.reduce((t, p) => t + p.length, 0), out = new Uint8Array(n); let o = 0; for (const p of parts) { out.set(p, o); o += p.length; } return out; };
async function hmac(key, data) { const k = await subtle().importKey("raw", key, { name: "HMAC", hash: "SHA-256" }, false, ["sign"]); return new Uint8Array(await subtle().sign("HMAC", k, data)); }
const hkdfExpand = async (prk, info, len) => (await hmac(prk, cat(info, new Uint8Array([1])))).slice(0, len);

// ---------- RFC 8291: encrypt one message for one phone ----------
export async function encryptPayload(payload, p256dh, auth, test) {
  const uaPub = unb64u(p256dh), authSecret = unb64u(auth);
  const eph = test && test.eph ? test.eph : await subtle().generateKey({ name: "ECDH", namedCurve: "P-256" }, true, ["deriveBits"]);
  const asPub = new Uint8Array(await subtle().exportKey("raw", eph.publicKey));
  const uaKey = await subtle().importKey("raw", uaPub, { name: "ECDH", namedCurve: "P-256" }, false, []);
  const shared = new Uint8Array(await subtle().deriveBits({ name: "ECDH", public: uaKey }, eph.privateKey, 256));
  const salt = test && test.salt ? test.salt : globalThis.crypto.getRandomValues(new Uint8Array(16));
  const prkKey = await hmac(authSecret, shared);
  const ikm = await hkdfExpand(prkKey, cat(enc.encode("WebPush: info\0"), uaPub, asPub), 32);
  const prk = await hmac(salt, ikm);
  const cek = await hkdfExpand(prk, enc.encode("Content-Encoding: aes128gcm\0"), 16);
  const nonce = await hkdfExpand(prk, enc.encode("Content-Encoding: nonce\0"), 12);
  const key = await subtle().importKey("raw", cek, { name: "AES-GCM" }, false, ["encrypt"]);
  const plain = cat(enc.encode(payload), new Uint8Array([2]));                      // 0x02 = last (only) record
  const ct = new Uint8Array(await subtle().encrypt({ name: "AES-GCM", iv: nonce }, key, plain));
  const header = new Uint8Array(21 + asPub.length);
  header.set(salt, 0); new DataView(header.buffer).setUint32(16, 4096); header[20] = asPub.length; header.set(asPub, 21);
  return cat(header, ct);
}

// ---------- RFC 8292: VAPID signature for one push service ----------
export async function vapidHeader(cfg, endpoint) {
  const pub = unb64u(cfg.pub);
  if (pub.length !== 65 || pub[0] !== 4) throw new Error("VAPID_PUBLIC_KEY looks wrong");
  const jwk = { kty: "EC", crv: "P-256", d: cfg.priv, x: b64u(pub.slice(1, 33)), y: b64u(pub.slice(33, 65)), ext: true };
  const key = await subtle().importKey("jwk", jwk, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
  const head = b64u(enc.encode(JSON.stringify({ typ: "JWT", alg: "ES256" })));
  const body = b64u(enc.encode(JSON.stringify({ aud: new URL(endpoint).origin, exp: Math.floor(Date.now() / 1000) + 12 * 3600, sub: cfg.subject })));
  const sig = new Uint8Array(await subtle().sign({ name: "ECDSA", hash: "SHA-256" }, key, enc.encode(head + "." + body)));
  return "vapid t=" + head + "." + body + "." + b64u(sig) + ", k=" + cfg.pub;
}

const ALLOWED = /^https:\/\/(fcm\.googleapis\.com|android\.googleapis\.com|[a-z0-9.-]+\.push\.services\.mozilla\.com|web\.push\.apple\.com|[a-z0-9.-]+\.push\.apple\.com|[a-z0-9.-]+\.notify\.windows\.com)\//i;
export async function sendOne(cfg, fetchImpl, sub, msg) {
  if (String(sub.endpoint).startsWith("fcm:")) return sendFcm(cfg, fetchImpl, sub, msg);
  if (!ALLOWED.test(sub.endpoint)) return "gone";
  const urgent = msg.kind === "call" || msg.kind === "message";
  const payload = JSON.stringify({ title: msg.title, body: msg.body || "", url: msg.url || "/app.html", tag: msg.tag || "", kind: msg.kind });
  try {
    const r = await fetchImpl(sub.endpoint, { method: "POST", headers: {
      "Authorization": await vapidHeader(cfg, sub.endpoint), "Content-Encoding": "aes128gcm", "Content-Type": "application/octet-stream",
      "TTL": msg.kind === "call" ? "60" : "86400", "Urgency": urgent ? "high" : "normal" },
      body: await encryptPayload(payload, sub.p256dh, sub.auth) });
    if (r.status === 404 || r.status === 410) return "gone";
    return r.status >= 200 && r.status < 300 ? "ok" : "bad";
  } catch (_) { return "bad"; }
}

/* ---------- Firebase Cloud Messaging (HTTP v1) for the Android app ---------- */
let fcmAuth = null;                                   // { token, exp, email }
const unb64 = (s) => { const b = atob(s); const u = new Uint8Array(b.length); for (let i = 0; i < b.length; i++) u[i] = b.charCodeAt(i); return u; };
export async function fcmAccessToken(cfg, fetchImpl) {
  const sa = cfg.fcm;
  if (fcmAuth && fcmAuth.email === sa.client_email && fcmAuth.exp > Date.now() + 60_000) return fcmAuth.token;
  const now = Math.floor(Date.now() / 1000), aud = sa.token_uri || "https://oauth2.googleapis.com/token";
  const head = b64u(enc.encode(JSON.stringify({ alg: "RS256", typ: "JWT" })));
  const claim = b64u(enc.encode(JSON.stringify({ iss: sa.client_email, scope: "https://www.googleapis.com/auth/firebase.messaging", aud, iat: now, exp: now + 3600 })));
  const der = unb64(String(sa.private_key).replace(/-----[^-]+-----/g, "").replace(/\\n/g, "").replace(/\s+/g, ""));
  const key = await subtle().importKey("pkcs8", der, { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" }, false, ["sign"]);
  const sig = b64u(await subtle().sign("RSASSA-PKCS1-v1_5", key, enc.encode(head + "." + claim)));
  const r = await fetchImpl(aud, { method: "POST", headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: "grant_type=" + encodeURIComponent("urn:ietf:params:oauth:grant-type:jwt-bearer") + "&assertion=" + head + "." + claim + "." + sig });
  const j = await r.json().catch(() => ({}));
  if (!r.ok || !j.access_token) throw new Error("Firebase sign-in failed (" + r.status + ")");
  fcmAuth = { token: j.access_token, exp: Date.now() + (Number(j.expires_in) || 3600) * 1000, email: sa.client_email };
  return fcmAuth.token;
}
export async function sendFcm(cfg, fetchImpl, sub, msg) {
  if (!cfg.fcm) return "bad";
  const token = sub.endpoint.slice(4), call = msg.kind === "call", urgent = call || msg.kind === "message";
  const message = {
    token,
    notification: { title: msg.title, body: msg.body || "" },
    data: { url: msg.url || "/app.html", tag: msg.tag || "", kind: msg.kind || "" },
    android: {
      priority: urgent ? "HIGH" : "NORMAL",
      ttl: call ? "60s" : "86400s",
      notification: { channel_id: call ? "calls" : "general", icon: "ic_notification_icon", color: "#1D1A16", default_sound: true,
                      ...(msg.tag ? { tag: msg.tag } : {}) },
    },
  };
  try {
    let tok = await fcmAccessToken(cfg, fetchImpl);
    const send = () => fetchImpl("https://fcm.googleapis.com/v1/projects/" + encodeURIComponent(cfg.fcm.project_id) + "/messages:send", {
      method: "POST", headers: { Authorization: "Bearer " + tok, "Content-Type": "application/json" }, body: JSON.stringify({ message }) });
    let r = await send();
    if (r.status === 401) { fcmAuth = null; tok = await fcmAccessToken(cfg, fetchImpl); r = await send(); }
    if (r.ok) return "ok";
    const t = await r.text();
    if (r.status === 404 || /UNREGISTERED|registration-token-not-registered/i.test(t)) return "gone";
    if (r.status === 400 && /INVALID_ARGUMENT/.test(t) && /token/i.test(t)) return "gone";
    console.error("fcm:", r.status, t.slice(0, 200));
    return "bad";
  } catch (e) { console.error("fcm:", e && e.message); return "bad"; }
}

async function rpc(cfg, fetchImpl, name, args) {
  const h = { apikey: cfg.serviceKey, "Content-Type": "application/json" };
  if (cfg.serviceKey.startsWith("eyJ")) h.Authorization = "Bearer " + cfg.serviceKey;
  const r = await fetchImpl(cfg.supabaseUrl + "/rest/v1/rpc/" + name, { method: "POST", headers: h, body: JSON.stringify(args) });
  const t = await r.text(); if (!r.ok) throw new Error("Database error " + r.status + ": " + t.slice(0, 200));
  return t ? JSON.parse(t) : null;
}
function same(a, b) { if (a.length !== b.length) return false; let d = 0; for (let i = 0; i < a.length; i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i); return d === 0; }
const json = (body, status) => new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });

export async function handler(req, env, fetchImpl) {
  const cfg = config(env);
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);
  if (!cfg.hook || !same(req.headers.get("x-push-secret") || "", cfg.hook)) return json({ error: "Not allowed" }, 401);
  if (!((cfg.pub && cfg.priv) || cfg.fcm) || !cfg.supabaseUrl || !cfg.serviceKey) return json({ error: "Notifications aren't set up yet." }, 503);
  let sent = 0, gone = 0;
  try {
    for (let round = 0; round < 5; round++) {
      const rows = await rpc(cfg, fetchImpl, "push_take", { p_limit: 200 }) || [];
      if (!rows.length) break;
      const res = { outbox: [], ok: [], gone: [], bad: [] };
      const jobs = [];
      for (const m of rows) { const o = { id: m.id, sent: 0, failed: 0 }; res.outbox.push(o);
        for (const s of (m.subs || [])) jobs.push(async () => { const st = await sendOne(cfg, fetchImpl, s, m);
          if (st === "ok") { o.sent++; res.ok.push(s.endpoint); } else { o.failed++; (st === "gone" ? res.gone : res.bad).push(s.endpoint); } }); }
      for (let i = 0; i < jobs.length; i += 20) await Promise.all(jobs.slice(i, i + 20).map((f) => f()));
      await rpc(cfg, fetchImpl, "push_done", { p_results: res });
      sent += res.ok.length; gone += res.gone.length;
    }
    return json({ sent, gone }, 200);
  } catch (e) {
    console.error("push:", e && e.message);
    return json({ error: "Something went wrong" }, 500);
  }
}

if (typeof Deno !== "undefined" && Deno.serve) {
  Deno.serve((req) => handler(req, Deno.env.toObject(), fetch));
}
