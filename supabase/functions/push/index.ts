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

export function config(env) {
  return {
    pub: env.VAPID_PUBLIC_KEY || "", priv: env.VAPID_PRIVATE_KEY || "",
    subject: env.VAPID_SUBJECT || "mailto:snappro.support@gmail.com",
    hook: env.PUSH_HOOK_SECRET || "",
    supabaseUrl: (env.SUPABASE_URL || "").replace(/\/$/, ""),
    serviceKey: env.SUPABASE_SERVICE_ROLE_KEY || "",
  };
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
  if (!cfg.pub || !cfg.priv || !cfg.supabaseUrl || !cfg.serviceKey) return json({ error: "Notifications aren't set up yet." }, 503);
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
