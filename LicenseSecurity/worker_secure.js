const JSON_HEADERS = { "content-type": "application/json; charset=utf-8", "cache-control": "no-store" };
const json = (data, status = 200) => new Response(JSON.stringify(data), { status, headers: JSON_HEADERS });
const now = () => Math.floor(Date.now() / 1000);
const uuid = () => crypto.randomUUID();
const encoder = new TextEncoder();

async function sha256(value) {
  const bytes = typeof value === "string" ? encoder.encode(value) : value;
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  return [...new Uint8Array(digest)].map(x => x.toString(16).padStart(2, "0")).join("");
}
function b64url(bytes) {
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/g, "");
}
function fromB64(value) {
  const normalized = value.replaceAll("-", "+").replaceAll("_", "/");
  const padded = normalized + "=".repeat((4 - normalized.length % 4) % 4);
  const raw = atob(padded);
  return Uint8Array.from(raw, c => c.charCodeAt(0));
}
function validDeviceId(v) { return typeof v === "string" && /^[A-Za-z0-9._:-]{12,128}$/.test(v); }
function validLicenseKey(v) { return typeof v === "string" && v.length >= 12 && v.length <= 160; }
function cors(req, env) {
  const origin = req.headers.get("Origin") || "";
  const requestOrigin = new URL(req.url).origin;
  const allowed = env.ALLOWED_ORIGIN || requestOrigin;
  const h = new Headers();
  if (origin && (allowed === "*" || origin === allowed)) h.set("Access-Control-Allow-Origin", allowed === "*" ? "*" : origin);
  h.set("Access-Control-Allow-Methods", "GET,POST,OPTIONS");
  h.set("Access-Control-Allow-Headers", "Content-Type,Authorization");
  h.set("Vary", "Origin");
  return h;
}
function withCors(response, req, env) {
  const h = new Headers(response.headers);
  cors(req, env).forEach((v, k) => h.set(k, v));
  return new Response(response.body, { status: response.status, headers: h });
}
async function admin(req, env) {
  const header = req.headers.get("Authorization") || "";
  const token = header.startsWith("Bearer ") ? header.slice(7) : "";
  if (!env.ADMIN_TOKEN || !token || token.length !== env.ADMIN_TOKEN.length) return false;
  let diff = 0;
  for (let i = 0; i < token.length; i++) diff |= token.charCodeAt(i) ^ env.ADMIN_TOKEN.charCodeAt(i);
  return diff === 0;
}
async function body(req) { try { return await req.json(); } catch { return null; } }
function adminPage() {
  const html = `<!doctype html><html lang="vi"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>IPA License Admin</title>
<style>body{font:15px system-ui;background:#f4f6fa;color:#172033;margin:0;padding:22px}main{max-width:1100px;margin:auto}section{background:#fff;border:1px solid #dce2ec;border-radius:14px;padding:18px;margin:14px 0}input,button{font:inherit;padding:10px;border:1px solid #cbd3df;border-radius:8px;margin:4px}button{background:#172033;color:white;cursor:pointer}.secondary{background:#fff;color:#172033}.row{display:flex;flex-wrap:wrap;gap:6px}.muted{color:#64748b}.item{border-top:1px solid #e5eaf1;padding:12px 0}code{overflow-wrap:anywhere}pre{white-space:pre-wrap;overflow-wrap:anywhere}.danger{background:#9f1239}</style>
<main><h1>IPA License Admin</h1><p class="muted">Quản lý License, thiết bị, thời hạn và thu hồi quyền truy cập.</p>
<section><h3>Đăng nhập quản trị</h3><input id="token" type="password" placeholder="ADMIN_TOKEN" style="width:min(440px,85%)"><button onclick="login()">Đăng nhập</button><span id="auth"></span></section>
<section><h3>Tạo License</h3><div class="row"><input id="label" placeholder="Tên / ghi chú"><input id="days" type="number" min="1" value="30" placeholder="Số ngày"><input id="max" type="number" min="1" max="100" value="1" placeholder="Số thiết bị"><button onclick="createLicense()">Tạo License</button></div><pre id="created"></pre></section>
<section><div class="row"><h3 style="margin-right:auto">License</h3><button class="secondary" onclick="loadAll()">Làm mới</button></div><div id="licenses">Đăng nhập để tải dữ liệu.</div></section>
<section><h3>Thiết bị</h3><div id="devices">Đăng nhập để tải dữ liệu.</div></section></main>
<script>
let token=sessionStorage.getItem('ipa_admin_token')||'';document.getElementById('token').value=token;
async function api(path,method='GET',data){let r=await fetch(path,{method,headers:{'Authorization':'Bearer '+token,'Content-Type':'application/json'},body:data?JSON.stringify(data):undefined});let j=await r.json().catch(()=>({error:'invalid_response'}));if(!r.ok)throw Error(j.error||r.status);return j}
async function login(){token=document.getElementById('token').value;try{await api('/admin/api/licenses');sessionStorage.setItem('ipa_admin_token',token);document.getElementById('auth').textContent=' Đã xác thực';await loadAll()}catch(e){document.getElementById('auth').textContent=' Lỗi: '+e.message}}
async function createLicense(){try{let j=await api('/admin/api/licenses','POST',{label:document.getElementById('label').value,days:Number(document.getElementById('days').value||30),maxDevices:Number(document.getElementById('max').value||1)});document.getElementById('created').textContent='License Key (chỉ hiển thị lần này): '+j.licenseKey+'\\nHãy sao chép và lưu an toàn.';await loadAll()}catch(e){alert(e.message)}}
async function loadAll(){await Promise.all([loadLicenses(),loadDevices()])}
async function loadLicenses(){try{let j=await api('/admin/api/licenses');let el=document.getElementById('licenses');el.replaceChildren();for(let l of j.licenses){let d=document.createElement('div');d.className='item';let b=document.createElement('b');b.textContent=l.label+' — '+l.status;let p=document.createElement('p');p.className='muted';p.textContent='Hết hạn: '+(l.expires_at?new Date(l.expires_at*1000).toLocaleString():'Không giới hạn')+' | Tối đa: '+l.max_devices+' | Đã liên kết: '+l.device_count;let toggle=document.createElement('button');toggle.textContent=l.status==='active'?'Thu hồi':'Kích hoạt lại';toggle.onclick=()=>licenseAction(l.id,l.status==='active'?'revoke':'activate');d.append(b,p,toggle);el.append(d)}if(!j.licenses.length)el.textContent='Chưa có License.'}catch(e){document.getElementById('licenses').textContent=e.message}}
async function loadDevices(){try{let j=await api('/admin/api/devices');let el=document.getElementById('devices');el.replaceChildren();for(let d of j.devices){let div=document.createElement('div');div.className='item';let title=document.createElement('b');title.textContent=d.device_id+' — '+d.status;let info=document.createElement('p');info.className='muted';info.textContent='License: '+d.label+' | App: '+d.app_version+' | Last seen: '+new Date(d.last_seen*1000).toLocaleString();let b=document.createElement('button');b.textContent=d.status==='blocked'?'Mở khóa':'Khóa';b.onclick=()=>deviceAction(d.device_id,d.status==='blocked'?'unblock':'block');let reset=document.createElement('button');reset.className='secondary';reset.textContent='Gỡ liên kết';reset.onclick=()=>deviceAction(d.device_id,'delete');div.append(title,info,b,reset);el.append(div)}if(!j.devices.length)el.textContent='Chưa có thiết bị.'}catch(e){document.getElementById('devices').textContent=e.message}}
async function deviceAction(id,act){if(!confirm('Xác nhận '+act+' thiết bị này?'))return;try{await api('/admin/api/devices/'+encodeURIComponent(id)+'/'+act,'POST',{});await loadAll()}catch(e){alert(e.message)}}
async function licenseAction(id,act){if(!confirm('Xác nhận '+act+' License này?'))return;try{await api('/admin/api/licenses/'+encodeURIComponent(id)+'/'+act,'POST',{});await loadAll()}catch(e){alert(e.message)}}
if(token)login();
</script></html>`;
  return new Response(html, { headers: { "content-type": "text/html; charset=utf-8", "cache-control": "no-store", "content-security-policy": "default-src 'self'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'self'; base-uri 'none'; frame-ancestors 'none'" } });
}

async function issueChallenge(req, env) {
  const b = await body(req);
  if (!b || !validDeviceId(b.deviceId) || !["register", "verify"].includes(b.action)) return json({ ok: false, error: "invalid_request" }, 400);
  const t = now();
  const recent = await env.DB.prepare("SELECT COUNT(*) AS n FROM license_challenges WHERE device_id=? AND created_at>? ").bind(b.deviceId, t - 60).first();
  if ((recent?.n || 0) >= 12) return json({ ok: false, error: "rate_limited" }, 429);
  const bytes = crypto.getRandomValues(new Uint8Array(32));
  const challenge = b64url(bytes);
  await env.DB.prepare("INSERT INTO license_challenges(id,challenge_hash,device_id,action,created_at,expires_at,consumed_at) VALUES(?,?,?,?,?,?,NULL)")
    .bind(uuid(), await sha256(challenge), b.deviceId, b.action, t, t + 180).run();
  return json({ ok: true, challenge, expiresAt: t + 180 });
}

async function consumeAndVerifyChallenge(env, b, action, publicKeyB64) {
  if (typeof b.challenge !== "string" || typeof b.signature !== "string") return false;
  let keyBytes, signature;
  try { keyBytes = fromB64(publicKeyB64); signature = fromB64(b.signature); } catch { return false; }
  if (keyBytes.length !== 65 || signature.length !== 64) return false;
  const challengeHash = await sha256(b.challenge);
  const row = await env.DB.prepare("SELECT * FROM license_challenges WHERE challenge_hash=? AND device_id=? AND action=?")
    .bind(challengeHash, b.deviceId, action).first();
  if (!row || row.consumed_at !== null || row.expires_at < now()) return false;
  const message = `${b.challenge}\n${action}\n${b.deviceId}\n${b.licenseKey}`;
  let verified = false;
  try {
    const key = await crypto.subtle.importKey("raw", keyBytes, { name: "ECDSA", namedCurve: "P-256" }, false, ["verify"]);
    verified = await crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, key, signature, encoder.encode(message));
  } catch { verified = false; }
  if (!verified) return false;
  const consumed = await env.DB.prepare("UPDATE license_challenges SET consumed_at=? WHERE id=? AND consumed_at IS NULL AND expires_at>=?")
    .bind(now(), row.id, now()).run();
  return (consumed.meta?.changes || 0) === 1;
}

async function registerDevice(req, env) {
  const b = await body(req);
  if (!b || !validDeviceId(b.deviceId) || !validLicenseKey(b.licenseKey) || typeof b.publicKey !== "string") return json({ ok: false, error: "invalid_request" }, 400);
  const keyHash = await sha256(b.licenseKey);
  const license = await env.DB.prepare("SELECT * FROM licenses WHERE key_hash=?").bind(keyHash).first();
  if (!license || license.status !== "active") return json({ ok: false, error: "license_invalid" }, 403);
  if (license.expires_at && license.expires_at < now()) return json({ ok: false, error: "license_expired" }, 403);
  const valid = await consumeAndVerifyChallenge(env, b, "register", b.publicKey);
  if (!valid) return json({ ok: false, error: "challenge_or_signature_invalid" }, 403);
  const existing = await env.DB.prepare("SELECT * FROM devices WHERE id=?").bind(b.deviceId).first();
  if (existing && existing.license_id !== license.id) return json({ ok: false, error: "device_already_bound" }, 403);
  if (existing?.status === "blocked") return json({ ok: false, error: "device_blocked" }, 403);
  if (existing?.public_key && existing.public_key !== b.publicKey) return json({ ok: false, error: "device_key_mismatch" }, 403);
  const t = now();
  if (!existing) {
    const count = await env.DB.prepare("SELECT COUNT(*) AS n FROM devices WHERE license_id=? AND status='active'").bind(license.id).first();
    if ((count?.n || 0) >= license.max_devices) return json({ ok: false, error: "device_limit_reached" }, 403);
    await env.DB.prepare("INSERT INTO devices(id,license_id,status,app_version,first_seen,last_seen,public_key) VALUES(?,?,'active',?,?,?,?)")
      .bind(b.deviceId, license.id, String(b.appVersion || "").slice(0, 40), t, t, b.publicKey).run();
  } else {
    await env.DB.prepare("UPDATE devices SET last_seen=?,app_version=?,public_key=COALESCE(public_key,?) WHERE id=? AND license_id=?")
      .bind(t, String(b.appVersion || "").slice(0, 40), b.publicKey, b.deviceId, license.id).run();
  }
  return json({ ok: true, status: "active", expiresAt: license.expires_at, label: license.label, deviceId: b.deviceId });
}

async function verifyDevice(req, env) {
  const b = await body(req);
  if (!b || !validDeviceId(b.deviceId) || !validLicenseKey(b.licenseKey)) return json({ ok: false, error: "invalid_request" }, 400);
  const keyHash = await sha256(b.licenseKey);
  const row = await env.DB.prepare(`SELECT l.id AS license_id,l.status AS license_status,l.label,l.expires_at,d.status AS device_status,d.public_key
    FROM licenses l JOIN devices d ON d.license_id=l.id WHERE l.key_hash=? AND d.id=?`)
    .bind(keyHash, b.deviceId).first();
  if (!row) return json({ ok: false, error: "device_not_registered" }, 403);
  if (row.license_status !== "active") return json({ ok: false, error: "license_invalid" }, 403);
  if (row.expires_at && row.expires_at < now()) return json({ ok: false, error: "license_expired" }, 403);
  if (row.device_status !== "active") return json({ ok: false, error: "device_blocked" }, 403);
  if (!row.public_key) return json({ ok: false, error: "device_key_missing_reactivate" }, 403);
  const valid = await consumeAndVerifyChallenge(env, b, "verify", row.public_key);
  if (!valid) return json({ ok: false, error: "challenge_or_signature_invalid" }, 403);
  await env.DB.prepare("UPDATE devices SET last_seen=?,app_version=? WHERE id=?").bind(now(), String(b.appVersion || "").slice(0, 40), b.deviceId).run();
  return json({ ok: true, status: "active", expiresAt: row.expires_at, label: row.label });
}

async function handle(req, env) {
  const url = new URL(req.url), path = url.pathname, method = req.method;
  if (method === "OPTIONS") return new Response(null, { status: 204 });
  if (path === "/health" && method === "GET") return json({ ok: true, service: env.APP_NAME || "IPA Device API", api: "v2-secure" });
  if (path === "/admin" && method === "GET") return adminPage();
  if (path === "/v1/device/register" || path === "/v1/device/verify") return json({ ok: false, error: "legacy_api_disabled" }, 410);
  if (path === "/v2/challenge" && method === "POST") return issueChallenge(req, env);
  if (path === "/v2/device/register" && method === "POST") return registerDevice(req, env);
  if (path === "/v2/device/verify" && method === "POST") return verifyDevice(req, env);

  if (path.startsWith("/admin/api/")) {
    if (!(await admin(req, env))) return json({ error: "unauthorized" }, 401);
    if (path === "/admin/api/devices" && method === "GET") {
      const { results } = await env.DB.prepare(`SELECT d.id AS device_id,d.status,d.app_version,d.first_seen,d.last_seen,l.id AS license_id,l.label,l.status AS license_status,l.expires_at
        FROM devices d JOIN licenses l ON l.id=d.license_id ORDER BY d.last_seen DESC LIMIT 500`).all();
      return json({ devices: results });
    }
    if (path === "/admin/api/licenses" && method === "GET") {
      const { results } = await env.DB.prepare(`SELECT l.id,l.label,l.status,l.expires_at,l.max_devices,l.created_at,
        (SELECT COUNT(*) FROM devices d WHERE d.license_id=l.id AND d.status='active') AS device_count
        FROM licenses l ORDER BY l.created_at DESC LIMIT 500`).all();
      return json({ licenses: results });
    }
    if (path === "/admin/api/licenses" && method === "POST") {
      const b = await body(req), days = Math.max(1, Math.min(3650, Number(b?.days) || 30));
      const maxDevices = Math.max(1, Math.min(100, Number(b?.maxDevices) || 1));
      const raw = "IPA-" + crypto.randomUUID().toUpperCase().replaceAll("-", "").slice(0, 20);
      const id = uuid(), exp = now() + days * 86400;
      await env.DB.prepare("INSERT INTO licenses(id,key_hash,label,status,expires_at,max_devices,created_at) VALUES(?,?,?,'active',?,?,?)")
        .bind(id, await sha256(raw), String(b?.label || "").slice(0, 100), exp, maxDevices, now()).run();
      return json({ ok: true, licenseKey: raw, expiresAt: exp, maxDevices });
    }
    const deviceMatch = path.match(/^\/admin\/api\/devices\/([^/]+)\/(block|unblock|delete)$/);
    if (deviceMatch && method === "POST") {
      const deviceId = decodeURIComponent(deviceMatch[1]), action = deviceMatch[2];
      if (action === "delete") await env.DB.prepare("DELETE FROM devices WHERE id=?").bind(deviceId).run();
      else await env.DB.prepare("UPDATE devices SET status=? WHERE id=?").bind(action === "block" ? "blocked" : "active", deviceId).run();
      return json({ ok: true });
    }
    const licenseMatch = path.match(/^\/admin\/api\/licenses\/([^/]+)\/(revoke|activate)$/);
    if (licenseMatch && method === "POST") {
      const id = decodeURIComponent(licenseMatch[1]), action = licenseMatch[2];
      await env.DB.prepare("UPDATE licenses SET status=? WHERE id=?").bind(action === "revoke" ? "blocked" : "active", id).run();
      return json({ ok: true });
    }
    return json({ error: "not_found" }, 404);
  }
  return json({ error: "not_found" }, 404);
}

export default {
  async fetch(req, env) {
    try { return withCors(await handle(req, env), req, env); }
    catch (e) { console.error("license-worker-error", e); return withCors(json({ ok: false, error: "internal_error" }, 500), req, env); }
  }
};
