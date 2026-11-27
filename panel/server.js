#!/usr/bin/env node
// =====================================================================
//  Panel VPN ACS - Kelola VPN L2TP MikroTik -> VPS GenieACS
//  Tanpa dependensi tambahan (hanya modul bawaan Node.js)
// =====================================================================
"use strict";

const http = require("http");
const https = require("https");
// Banyak VPS punya alamat IPv6 yang tidak bisa dipakai keluar: koneksi ke Telegram/Cloudflare
// gagal bila IPv6 dicoba lebih dulu. Dahulukan IPv4.
try {
  require("dns").setDefaultResultOrder("ipv4first");
} catch (e) {
  // Node lama: abaikan
}
const net = require("net");
const tls = require("tls");
const fs = require("fs");
const path = require("path");
const crypto = require("crypto");
const os = require("os");
const { execFile, spawn } = require("child_process");

// ---------- Konfigurasi ----------
const ROOT = process.env.VPNACS_FSROOT || ""; // hanya untuk pengujian
const PORT = parseInt(process.env.VPNACS_PORT || "8088", 10);
const HOST = process.env.VPNACS_HOST || "0.0.0.0";
// Hanya untuk pengujian (VPNACS_DRYRUN): port pengganti 80/443
const STD_HTTP = parseInt(process.env.VPNACS_STD_HTTP || "18080", 10);
const STD_HTTPS = parseInt(process.env.VPNACS_STD_HTTPS || "18443", 10);
const APP_DIR = __dirname;
const DATA_FILE = ROOT + "/opt/vpn-acs/data.json";
const CHAP_FILE = ROOT + "/etc/ppp/chap-secrets";
const IPSEC_SECRETS = ROOT + "/etc/ipsec.secrets";
const ROUTE_SCRIPT = ROOT + "/etc/ppp/ip-up.d/vpn-acs-routes";
const GENIE_ENV = ROOT + "/opt/genieacs/genieacs.env";
const GENIE_SVC = ROOT + "/etc/systemd/system/genieacs-cwmp.service"; // ExecStart versi patch memuat /opt/genieacs-app/
const DRY_RUN = process.env.VPNACS_DRYRUN === "1"; // tidak menjalankan perintah ip
const HISTORY_FILE = ROOT + "/opt/vpn-acs/history.json";
const ACTIVITY_FILE = ROOT + "/opt/vpn-acs/activity.json";
const CF_INI = ROOT + "/opt/vpn-acs/cloudflare.ini";
const LE_LIVE = ROOT + "/etc/letsencrypt/live";
// Alamat layanan luar (bisa diganti untuk pengujian)
const TG_API = process.env.VPNACS_TG_API || "https://api.telegram.org";
const CF_API = process.env.VPNACS_CF_API || "https://api.cloudflare.com/client/v4";
const IP_TRACE = process.env.VPNACS_IP_TRACE || "https://cloudflare.com/cdn-cgi/trace";
const DOH_URL = process.env.VPNACS_DOH || "https://cloudflare-dns.com/dns-query";
const TICK_MS = parseInt(process.env.VPNACS_TICK_MS || "30000", 10);
const MIN_MS = parseInt(process.env.VPNACS_MIN_MS || "60000", 10); // panjang 1 menit (diperkecil hanya untuk pengujian)
const RETENTION_MS = 90 * 24 * 3600 * 1000; // riwayat & log disimpan 90 hari
const DAY_MS = 24 * 3600 * 1000;
const TIMEZONES = { "Asia/Jakarta": { label: "WIB", off: 7 }, "Asia/Makassar": { label: "WITA", off: 8 }, "Asia/Jayapura": { label: "WIT", off: 9 } };

const VERSION = "2.14.1";
const DEFAULT_BRAND = "VPN ACS";
const DEFAULT_TUNNEL_NET = "192.168.42.0/24";
const XL2TPD_CONF = ROOT + "/etc/xl2tpd/xl2tpd.conf";
const VIRTUAL_POOL = "10.100.0.0/14";
const ACS_PORT = 7547;
const MARK_BEGIN = "# >>> VPN-ACS (dikelola Panel VPN ACS, jangan diedit manual) >>>";
const MARK_END = "# <<< VPN-ACS <<<";
const FWD_AUTO_START = 20001; // port publik otomatis mulai dari sini
const RESERVED_PORTS = new Set([22, 25, 53, 80, 443, 500, 1701, 3000, 3300, 4500, 5432, 7547, 7557, 7567, 8080, 9993, 27017, PORT]);
// ZeroTier (controller di VPS, dikelola dari menu ZeroTier panel)
const ZT_API = process.env.VPNACS_ZT_API || "http://127.0.0.1:9993";
const ZT_TOKEN_FILE = ROOT + "/var/lib/zerotier-one/authtoken.secret";
const ZTNET_DIR = ROOT + "/opt/ztnet";
const WG_IFACE = "wg0";
const WG_DIR = ROOT + "/etc/wireguard";
const WG_CONF = WG_DIR + "/" + WG_IFACE + ".conf";
const WG_IFACE_MT = "wg-acs";
const ZT_IFACE_MT = "zt-acs"; // nama interface ZeroTier di MikroTik
// GenieACS NBI (hanya dibaca, untuk menghitung ONT per router)
const NBI_URL = process.env.VPNACS_NBI || "";
const GENIE_UNITS = [["genieacs-cwmp", "CWMP (ONT melapor)"], ["genieacs-nbi", "NBI (API)"], ["genieacs-fs", "File server"], ["genieacs-ui", "Web UI"]];
const SERVICE_PRESETS = {
  winbox: { label: "Winbox", port: 8291, proto: "tcp" },
  webfig: { label: "WebFig", port: 80, proto: "tcp" },
  api: { label: "API MikroTik", port: 8728, proto: "tcp" },
  ssh: { label: "SSH", port: 22, proto: "tcp" },
  ontweb: { label: "Web ONT", port: 80, proto: "tcp" },
  custom: { label: "Lainnya", port: 0, proto: "tcp" },
};

// ---------- Utilitas IP ----------
function ipToInt(ip) {
  const p = String(ip).trim().split(".");
  if (p.length !== 4) return null;
  let n = 0;
  for (const x of p) {
    if (!/^\d{1,3}$/.test(x)) return null;
    const v = parseInt(x, 10);
    if (v > 255) return null;
    n = n * 256 + v;
  }
  return n;
}
function intToIp(n) {
  return [(n >>> 24) & 255, (n >>> 16) & 255, (n >>> 8) & 255, n & 255].join(".");
}
function parseCidr(cidr) {
  const m = String(cidr || "").trim().match(/^(\d+\.\d+\.\d+\.\d+)\/(\d{1,2})$/);
  if (!m) return null;
  const ip = ipToInt(m[1]);
  const prefix = parseInt(m[2], 10);
  if (ip === null || prefix < 0 || prefix > 32) return null;
  const size = Math.pow(2, 32 - prefix);
  const net = ip - (ip % size);
  return { ip, net, prefix, size, aligned: ip === net, text: intToIp(net) + "/" + prefix };
}
function overlap(a, b) {
  return a.net < b.net + b.size && b.net < a.net + a.size;
}
// Jaringan VPN L2TP: .1 = VPS, separuh awal = IP tetap MikroTik, separuh akhir = pool dinamis xl2tpd
function tunnelCfg(net) {
  const t = parseCidr(net || DEFAULT_TUNNEL_NET);
  const half = t.size / 2;
  return {
    net: t.text,
    cidr: t,
    local: intToIp(t.net + 1),
    first: t.net + (t.size >= 64 ? 10 : 2),
    last: t.net + half - 1,
    poolStart: intToIp(t.net + half),
    poolEnd: intToIp(t.net + t.size - 2),
  };
}
function tun(d) {
  return tunnelCfg((d && d.settings && d.settings.tunnelNet) || DEFAULT_TUNNEL_NET);
}
// ---------- Rentang patch GenieACS (dikelola panel) ----------
// GenieACS memakai IP pengirim untuk Summon hanya bila IP itu ada di rentang ini.
// Panel menulisnya otomatis: rentang otomatis + IP virtual tiap router + rentang tambahan.
const PRIVATE_NETS = ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"];
function isPrivateCidr(c) {
  return PRIVATE_NETS.some((x) => {
    const p = parseCidr(x);
    return c.net >= p.net && c.net + c.size <= p.net + p.size;
  });
}
function cidrCovers(outer, inner) {
  return inner.net >= outer.net && inner.net + inner.size <= outer.net + outer.size;
}
function geniePatched() {
  try {
    return fs.readFileSync(GENIE_SVC, "utf8").split("\n").some((l) => l.startsWith("ExecStart=") && l.includes("/opt/genieacs-app/"));
  } catch (e) {
    return false;
  }
}
// Rentang tambahan dari isian Pengaturan: valid, private, tidak memuat jaringan VPN/ZeroTier
function checkGenieExtra(d, list) {
  const out = [];
  const T = tun(d);
  const z = ztCfg(d);
  const zsub = z ? parseCidr(z.subnet) : null;
  for (const raw of list) {
    const t = String(raw || "").trim();
    if (!t) continue;
    const c = parseCidr(t);
    if (!c) return { error: `Rentang "${t}" tidak valid. Contoh: 172.16.0.0/16` };
    if (!c.aligned) return { error: `Rentang "${t}" harus ditulis dari alamat awalnya. Mungkin maksud Anda ${c.text}` };
    if (c.prefix < 8) return { error: `Rentang ${c.text} terlalu besar (minimal /8).` };
    if (!isPrivateCidr(c)) return { error: `Rentang ${c.text} bukan IP private (10.x, 172.16-31.x, 192.168.x).` };
    if (overlap(c, T.cidr)) return { error: `Rentang ${c.text} memuat jaringan VPN L2TP ${T.net}. Router yang memakai masquerade akan salah alamat.` };
    if (zsub && overlap(c, zsub)) return { error: `Rentang ${c.text} memuat jaringan ZeroTier ${z.subnet}.` };
    if (!out.includes(c.text)) out.push(c.text);
  }
  return { list: out };
}
function genieRanges(d) {
  const pool = parseCidr(VIRTUAL_POOL);
  const list = [pool];
  const extra = [];
  for (const t of (d.settings && d.settings.genieExtra) || []) {
    const c = parseCidr(t);
    if (c && !list.some((x) => cidrCovers(x, c))) {
      list.push(c);
      extra.push(c.text);
    }
  }
  const fromSites = [];
  for (const st of d.sites) {
    const c = parseCidr(st.virtualSubnet);
    if (c && !list.some((x) => cidrCovers(x, c))) {
      list.push(c);
      fromSites.push({ id: st.id, name: st.name, subnet: c.text });
    }
  }
  return { pool: pool.text, extra, fromSites, value: list.map((x) => x.text).join(",") };
}
// Pindahkan isian lama di genieacs.env (misalnya 10.20.0.0/16) menjadi rentang tambahan, sekali saja
function genieMigrate(d) {
  d.settings = d.settings || {};
  if (Array.isArray(d.settings.genieExtra)) return false;
  const cur = readGenieCidr();
  const keep = [];
  if (cur) {
    const pool = parseCidr(VIRTUAL_POOL);
    for (const t of cur.split(",")) {
      const c = parseCidr(t.trim());
      if (!c || cidrCovers(pool, c) || d.sites.some((st) => st.virtualSubnet === c.text)) continue;
      const r = checkGenieExtra(d, [c.text]);
      if (r.list && r.list.length) keep.push(c.text);
    }
  }
  d.settings.genieExtra = keep;
  return true;
}
let GENIE_SYNC_BUSY = false;
// Tulis rentang ke genieacs.env dan restart genieacs-cwmp jika berubah
async function genieSync(d, req) {
  const cur = readGenieCidr();
  if (cur === null) return { skipped: true }; // GenieACS tidak di VPS ini
  if (genieMigrate(d)) saveData(d);
  // GenieACS asli (belum/tidak di-patch): jangan ubah apa pun. genieacs-virtualip.sh
  // me-restart panel setelah memasang patch, sehingga rentang langsung disesuaikan.
  if (!geniePatched()) return { skipped: true, unpatched: true };
  const want = genieRanges(d).value;
  if (cur === want || GENIE_SYNC_BUSY) return { ok: true, changed: false };
  GENIE_SYNC_BUSY = true;
  try {
    let t = fs.readFileSync(GENIE_ENV, "utf8");
    const line = `GENIEACS_CR_USE_REMOTE_ADDRESS=${want}`;
    if (/^GENIEACS_CR_USE_REMOTE_ADDRESS=.*$/m.test(t)) t = t.replace(/^GENIEACS_CR_USE_REMOTE_ADDRESS=.*$/m, line);
    else t = t.replace(/\n?$/, "\n") + line + "\n";
    fs.writeFileSync(GENIE_ENV, t);
    let restarted = false;
    if (geniePatched()) {
      const r = await run("systemctl", ["restart", "genieacs-cwmp"], 30000);
      restarted = r.code === 0;
      if (!restarted) console.error("Restart genieacs-cwmp gagal:", r.out.trim());
    }
    GENIE_CACHE.t = 0;
    logActivity(req || null, "Rentang patch GenieACS diperbarui", `${cur || "(kosong)"} → ${want}`);
    return { ok: true, changed: true, restarted };
  } catch (e) {
    console.error("Gagal menulis genieacs.env:", e.message);
    return { error: "Gagal menulis genieacs.env: " + e.message };
  } finally {
    GENIE_SYNC_BUSY = false;
  }
}
function insideGenie(sub, genieCidr) {
  if (genieCidr === null) return null; // GenieACS tidak ada di VPS ini
  const v = String(genieCidr || "").trim();
  if (!v) return false;
  if (["all", "true", "1", "yes"].includes(v.toLowerCase())) return true;
  const s = parseCidr(sub);
  return v.split(",").some((c) => {
    const g = parseCidr(c.trim());
    return g && s && s.net >= g.net && s.net + s.size <= g.net + g.size;
  });
}

// ---------- Data ----------
function loadData() {
  try {
    return JSON.parse(fs.readFileSync(DATA_FILE, "utf8"));
  } catch (e) {
    return { settings: {}, sites: [] };
  }
}
function saveData(d) {
  fs.mkdirSync(path.dirname(DATA_FILE), { recursive: true });
  const tmp = DATA_FILE + ".tmp";
  fs.writeFileSync(tmp, JSON.stringify(d, null, 2), { mode: 0o600 });
  fs.renameSync(tmp, DATA_FILE);
}
function hashPassword(pw, salt) {
  salt = salt || crypto.randomBytes(16).toString("hex");
  const hash = crypto.scryptSync(String(pw), salt, 64).toString("hex");
  return { salt, hash };
}
function checkPassword(pw, rec) {
  if (!rec || !rec.salt || !rec.hash) return false;
  const h = crypto.scryptSync(String(pw), rec.salt, 64);
  const r = Buffer.from(rec.hash, "hex");
  return h.length === r.length && crypto.timingSafeEqual(h, r);
}
// Password bawaan saat instalasi (tinggal Enter). Panel menampilkan peringatan sampai diganti.
const DEFAULT_ADMIN_PW = "Admin123";
let DEFPW_CACHE = { hash: null, v: false };
function isDefaultPw(d) {
  const rec = d && d.admin;
  if (!rec || !rec.hash) return false;
  if (DEFPW_CACHE.hash !== rec.hash) DEFPW_CACHE = { hash: rec.hash, v: checkPassword(DEFAULT_ADMIN_PW, rec) };
  return DEFPW_CACHE.v;
}
function randomPassword(len) {
  const chars = "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz23456789";
  const bytes = crypto.randomBytes(len);
  let s = "";
  for (let i = 0; i < len; i++) s += chars[bytes[i] % chars.length];
  return s;
}

// ---------- Baca info VPS ----------
function readPsk() {
  try {
    const t = fs.readFileSync(IPSEC_SECRETS, "utf8");
    const m = t.match(/PSK\s+"([^"]*)"/);
    return m ? m[1] : "";
  } catch (e) {
    return "";
  }
}
function readGenieCidr() {
  try {
    const t = fs.readFileSync(GENIE_ENV, "utf8");
    const m = t.match(/^GENIEACS_CR_USE_REMOTE_ADDRESS=(.*)$/m);
    return m ? m[1].trim() : "";
  } catch (e) {
    return null;
  }
}
function readGenieUiPort() {
  try {
    const t = fs.readFileSync(GENIE_ENV, "utf8");
    const m = t.match(/^GENIEACS_UI_PORT=(\d+)/m);
    return m ? parseInt(m[1], 10) : 3000;
  } catch (e) {
    return null; // GenieACS tidak ada di VPS ini
  }
}
// Alamat GenieACS UI: isian manual di Pengaturan, atau otomatis alamat VPS + port UI
function genieUrl(d, publicIp) {
  const manual = d.settings && d.settings.genieUrl;
  if (manual) return manual;
  const port = readGenieUiPort();
  if (port === null || !publicIp) return "";
  return `http://${publicIp}:${port}`;
}
function detectPublicIp() {

  const ifs = os.networkInterfaces();
  for (const name of Object.keys(ifs)) {
    for (const a of ifs[name] || []) {
      if (a.family !== "IPv4" && a.family !== 4) continue;
      if (a.internal) continue;
      const n = ipToInt(a.address);
      const priv =
        (n >>> 24) === 10 ||
        (n >>> 20) === ((172 << 4) | 1) ||
        (n >>> 16) === ((192 << 8) | 168) ||
        (n >>> 22) === ((100 << 2) | 1);
      if (!priv) return a.address;
    }
  }
  return "";
}
function brandOf(d) {
  return (d && d.settings && d.settings.panelName) || DEFAULT_BRAND;
}
// Nama sekarang + nama lama (untuk membersihkan komentar lama di MikroTik)
function brandsOf(d) {
  const list = [brandOf(d)].concat((d && d.settings && d.settings.brandHistory) || [], [DEFAULT_BRAND]);
  return list.filter((n, i) => n && list.indexOf(n) === i);
}
function settings(d) {
  const s = d.settings || {};
  const publicIp = s.publicIp || detectPublicIp();
  return {
    publicIp,
    panelUrl: panelPublicUrl({ publicIp }, d),
    psk: readPsk(),
    genieCidr: readGenieCidr(),
    useIpsec: !!s.useIpsec,
    tun: tun(d),
    zt: ztCfg(d),
    wg: wgCfg(d),
    brand: brandOf(d),
    brands: brandsOf(d),
  };
}

// ---------- Jalankan perintah ----------
function run(cmd, args, timeoutMs) {
  return new Promise((resolve) => {
    if (DRY_RUN && ((cmd === "ip" && (args[0] === "route" || args[0] === "addr")) || cmd === "iptables")) return resolve({ code: 0, out: "" });
    execFile(cmd, args, { timeout: timeoutMs || 15000, maxBuffer: 4 * 1024 * 1024 }, (err, stdout, stderr) => {
      const code = !err ? 0 : err.code === "ENOENT" ? -2 : typeof err.code === "number" ? err.code : 1;
      resolve({ code, out: (stdout || "") + (stderr || "") });
    });
  });
}
async function onlinePeers() {
  // Contoh baris: "7: ppp0    inet 192.168.42.1 peer 192.168.42.10/32 scope global ppp0"
  const r = await run("ip", ["-o", "-4", "addr", "show"]);
  const map = {};
  for (const line of r.out.split("\n")) {
    const m = line.match(/^\d+:\s+(\S+)\s+inet\s+\S+\s+peer\s+(\d+\.\d+\.\d+\.\d+)/);
    if (m) map[m[2]] = m[1];
  }
  return map;
}

// ---------- Tulis berkas VPS ----------
function writeChapSecrets(d) {
  let text = "";
  try {
    text = fs.readFileSync(CHAP_FILE, "utf8");
  } catch (e) {
    text = "";
  }
  const re = new RegExp(escapeRe(MARK_BEGIN) + "[\\s\\S]*?" + escapeRe(MARK_END) + "\\n?", "g");
  text = text.replace(re, "");
  if (text.length && !text.endsWith("\n")) text += "\n";
  let block = MARK_BEGIN + "\n";
  for (const s of d.sites.filter((x) => isL2tp(x))) {
    block += `"${s.username}" l2tpd "${s.password}" ${s.tunnelIp}\n`;
  }
  block += MARK_END + "\n";
  fs.mkdirSync(path.dirname(CHAP_FILE), { recursive: true });
  fs.writeFileSync(CHAP_FILE, text + block, { mode: 0o600 });
}
function writeRouteScript(d) {
  let sh = "#!/bin/sh\n";
  sh += "# Dibuat otomatis oleh Panel VPN ACS - jangan diedit manual.\n";
  sh += "# Menambah route subnet virtual ONT saat L2TP MikroTik tersambung.\n";
  sh += 'case "$IPREMOTE" in\n';
  for (const s of d.sites.filter((x) => isL2tp(x))) {
    sh += `  ${s.tunnelIp}) ip route replace ${s.virtualSubnet} dev "$IFNAME" ;; # ${s.name.replace(/[^\w .-]/g, "")}\n`;
  }
  sh += "esac\nexit 0\n";
  fs.mkdirSync(path.dirname(ROUTE_SCRIPT), { recursive: true });
  fs.writeFileSync(ROUTE_SCRIPT, sh, { mode: 0o755 });
}
function escapeRe(s) {
  return s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}
function isZt(site) {
  return site && site.transport === "zt";
}
function isWg(site) {
  return site && site.transport === "wg";
}
function isL2tp(site) {
  return site && !isZt(site) && !isWg(site);
}
const TR_LABEL = { l2tp: "L2TP", zt: "ZeroTier", wg: "WireGuard" };
const trOf = (s) => (isZt(s) ? "zt" : isWg(s) ? "wg" : "l2tp");
function fwdTarget(site, f) {
  if (f.target === "router") return isZt(site) ? site.ztIp || "0.0.0.0" : isWg(site) ? site.wgIp || "0.0.0.0" : site.tunnelIp;
  const real = parseCidr(site.realSubnet);
  const virt = parseCidr(site.virtualSubnet);
  return intToIp(virt.net + (ipToInt(f.lanIp) - real.net));
}
function fwdProtos(f) {
  return f.proto === "both" ? ["tcp", "udp"] : [f.proto];
}
async function ipt(args) {
  return run("iptables", ["-w"].concat(args));
}
async function applyFirewall(d) {
  // Rantai khusus panel; dibangun ulang penuh setiap ada perubahan
  await ipt(["-t", "nat", "-N", "VPNACS_PRE"]);
  await ipt(["-t", "nat", "-N", "VPNACS_POST"]);
  await ipt(["-N", "VPNACS_FWD"]);
  await ipt(["-t", "nat", "-F", "VPNACS_PRE"]);
  await ipt(["-t", "nat", "-F", "VPNACS_POST"]);
  await ipt(["-F", "VPNACS_FWD"]);
  await ipt(["-A", "VPNACS_FWD", "-m", "conntrack", "--ctstate", "RELATED,ESTABLISHED", "-j", "ACCEPT"]);
  for (const site of d.sites) {
    const oif = isZt(site) ? "zt+" : isWg(site) ? WG_IFACE : "ppp+";
    if (isZt(site) && !site.ztIp) continue; // router ZeroTier belum bergabung
    if (isWg(site) && !site.wgIp) continue;
    for (const f of site.forwards || []) {
      const target = fwdTarget(site, f);
      for (const p of fwdProtos(f)) {
        const c = ["-m", "comment", "--comment", `vpnacs ${site.username} ${f.label}`.slice(0, 250)];
        await ipt(["-t", "nat", "-A", "VPNACS_PRE", "-p", p, "-m", "addrtype", "--dst-type", "LOCAL", "--dport", String(f.publicPort), "-j", "DNAT", "--to-destination", `${target}:${f.targetPort}`].concat(c));
        await ipt(["-t", "nat", "-A", "VPNACS_POST", "-o", oif, "-p", p, "-d", target, "--dport", String(f.targetPort), "-j", "MASQUERADE"].concat(c));
        await ipt(["-A", "VPNACS_FWD", "-o", oif, "-p", p, "-d", target, "--dport", String(f.targetPort), "-j", "ACCEPT"].concat(c));
      }
    }
  }
  const jumps = [
    ["-t", "nat", "PREROUTING", "VPNACS_PRE"],
    ["-t", "nat", "POSTROUTING", "VPNACS_POST"],
    ["-t", "filter", "FORWARD", "VPNACS_FWD"],
  ];
  for (const [, table, chain, target] of jumps) {
    const chk = await ipt(["-t", table, "-C", chain, "-j", target]);
    if (chk.code !== 0) await ipt(["-t", table, "-I", chain, "1", "-j", target]);
  }
  try {
    if (!DRY_RUN) fs.writeFileSync(ROOT + "/proc/sys/net/ipv4/ip_forward", "1");
  } catch (e) {
    // abaikan
  }
}
// Samakan "local ip" dan "ip range" di xl2tpd.conf dengan jaringan VPN panel.
// Mengembalikan true jika berkas berubah.
function syncXl2tpd(d) {
  let text;
  try {
    text = fs.readFileSync(XL2TPD_CONF, "utf8");
  } catch (e) {
    return false;
  }
  const t = tun(d);
  let out = text.replace(/^(\s*local ip\s*=\s*).*$/m, `$1${t.local}`);
  out = out.replace(/^(\s*ip range\s*=\s*).*$/m, `$1${t.poolStart}-${t.poolEnd}`);
  if (out === text) return false;
  fs.writeFileSync(XL2TPD_CONF, out);
  return true;
}
async function restartXl2tpd() {
  await run("systemctl", ["restart", "xl2tpd"]);
}
async function applyAll(d, removedSubnets) {
  writeChapSecrets(d);
  writeRouteScript(d);
  await applyFirewall(d);
  for (const sub of removedSubnets || []) await run("ip", ["route", "del", sub]);
  const peers = await onlinePeers();
  for (const s of d.sites.filter((x) => isL2tp(x))) {
    const ifc = peers[s.tunnelIp];
    if (ifc) await run("ip", ["route", "replace", s.virtualSubnet, "dev", ifc]);
  }
  await ensureLoAddr(d);
  await genieSync(d);
  if (ztCfg(d)) {
    const r = await syncZtRoutes(d);
    if (r.error) console.error("Sinkron route ZeroTier gagal:", r.error);
  }
  if (wgCfg(d)) {
    const r = await wgApply(d);
    if (r.error) console.error("Sinkron WireGuard gagal:", r.error);
  }
}

// ---------- Alokasi ----------
// Akun L2TP yang dibuat manual (di luar blok panel) supaya tidak bentrok
function manualChapEntries() {
  let text = "";
  try {
    text = fs.readFileSync(CHAP_FILE, "utf8");
  } catch (e) {
    return { users: new Set(), ips: new Set() };
  }
  const re = new RegExp(escapeRe(MARK_BEGIN) + "[\\s\\S]*?" + escapeRe(MARK_END), "g");
  text = text.replace(re, "");
  const users = new Set();
  const ips = new Set();
  for (const line of text.split("\n")) {
    const t = line.trim();
    if (!t || t.startsWith("#")) continue;
    const m = t.match(/^"?([^"\s]+)"?\s+\S+\s+"?[^"]*"?\s+"?([\d.]+)?"?/);
    if (m) {
      users.add(m[1]);
      if (m[2]) ips.add(m[2]);
    }
  }
  return { users, ips };
}
function allocTunnelIp(d, exceptId) {
  const used = new Set(d.sites.filter((s) => s.id !== exceptId).map((s) => s.tunnelIp));
  for (const ip of manualChapEntries().ips) used.add(ip);
  const t = tun(d);
  for (let n = t.first; n <= t.last; n++) {
    const ip = intToIp(n);
    if (!used.has(ip)) return ip;
  }
  return null;
}
function allocVirtual(d, prefix, exceptId) {
  const pool = parseCidr(VIRTUAL_POOL);
  const size = Math.pow(2, 32 - prefix);
  const used = d.sites.filter((s) => s.id !== exceptId).map((s) => parseCidr(s.virtualSubnet));
  for (const s of d.sites) used.push(parseCidr(s.realSubnet));
  // Mulai dari blok kedua supaya 10.100.0.x tidak dipakai
  for (let net = pool.net + size; net + size <= pool.net + pool.size; net += size) {
    const cand = { net, size };
    if (!used.some((u) => overlap(u, cand))) return intToIp(net) + "/" + prefix;
  }
  return null;
}

// ---------- Script MikroTik ----------
// Baris hapus aturan lama: nama panel sekarang + semua nama sebelumnya
function cleanupLines(st, kind) {
  const names = st.brands || [st.brand];
  if (kind === "route") return names.map((n) => `/ip route remove [find where comment="${n}"]`);
  return names.map((n) => `/ip firewall ${kind} remove [find where comment~"^${n} - "]`);
}
// Kunci acak per router ZeroTier: script MikroTik memakainya untuk melapor Node ID ke panel
function ensureJoinKey(site) {
  if (!isZt(site) || site.joinKey) return false;
  site.joinKey = crypto.randomBytes(12).toString("hex");
  return true;
}
// Alamat panel yang bisa dijangkau MikroTik lewat internet
function panelPublicUrl(st, d) {
  const cf = d && d.settings && d.settings.cloudflare;
  const std = STD_ON;
  if (cf && cf.https && cf.domain) return std ? `https://${cf.domain}${portSfx("https")}` : `https://${cf.domain}:${PORT}`;
  return st.publicIp ? (std ? `http://${st.publicIp}${portSfx("http")}` : `http://${st.publicIp}:${PORT}`) : "";
}
function mikrotikScriptZt(s, st) {
  const c = st.brand;
  const z = st.zt || {};
  const nw = z.nwid || "NETWORK_ID";
  const vps = z.vpsIp || "IP_ZEROTIER_VPS";
  return [
    `# ================================================================`,
    `#  ${c} (ZeroTier) - ${s.name}`,
    `#  Syarat: RouterOS v7 dengan paket zerotier (router ARM/ARM64).`,
    `#  Paste semua baris ini di Winbox > New Terminal, lalu Enter.`,
    `#  Aman dijalankan ulang (pengaturan lama "${c}" dihapus dulu).`,
    `# ================================================================`,
    ``,
    `# 1) Gabung ke jaringan ZeroTier VPS (${nw})`,
    `/zerotier enable zt1`,
    `/zerotier interface remove [find where name="${ZT_IFACE_MT}"]`,
    `/zerotier interface add name=${ZT_IFACE_MT} network=${nw} instance=zt1 allow-managed=yes disabled=no comment="${c}"`,
    ``,
    `# 2) Route ke VPS ACS (URL ACS ONT tetap http://${st.tun.local}:${ACS_PORT})`,
    ...cleanupLines(st, "route"),
    `/ip route add dst-address=${st.tun.local}/32 gateway=${vps} comment="${c}"`,
    ``,
    `# 3) IP virtual ONT (NETMAP) - ONT ${s.realSubnet} terlihat di VPS sebagai ${s.virtualSubnet}`,
    ...cleanupLines(st, "nat"),
    `/ip firewall nat add chain=srcnat src-address=${s.realSubnet} dst-address=${st.tun.local} action=netmap to-addresses=${s.virtualSubnet} comment="${c} - ONT ke IP virtual"`,
    `/ip firewall nat add chain=dstnat in-interface=${ZT_IFACE_MT} dst-address=${s.virtualSubnet} action=netmap to-addresses=${s.realSubnet} comment="${c} - IP virtual ke ONT"`,
    `/ip firewall nat move [find where comment="${c} - IP virtual ke ONT"] destination=0`,
    `/ip firewall nat move [find where comment="${c} - ONT ke IP virtual"] destination=0`,
    ``,
    `# 4) Izinkan lalu lintas ACS <-> ONT`,
    ...cleanupLines(st, "filter"),
    `/ip firewall filter add chain=forward in-interface=${ZT_IFACE_MT} dst-address=${s.realSubnet} action=accept comment="${c} - ACS ke ONT"`,
    `/ip firewall filter add chain=forward src-address=${s.realSubnet} out-interface=${ZT_IFACE_MT} action=accept comment="${c} - ONT ke ACS"`,
    `/ip firewall filter add chain=input in-interface=${ZT_IFACE_MT} src-address=${vps} action=accept comment="${c} - remote dari VPS"`,
    `/ip firewall filter move [find where comment="${c} - ONT ke ACS"] destination=0`,
    `/ip firewall filter move [find where comment="${c} - ACS ke ONT"] destination=0`,
    `/ip firewall filter move [find where comment="${c} - remote dari VPS"] destination=0`,
    ``,
    ...(s.joinKey && st.panelUrl
      ? [
          `# 5) Laporkan Node ID router ini ke panel, supaya router langsung dipilih otomatis`,
          `:do { :delay 3s; :local nid [:pick [/zerotier get [find where name="zt1"] identity] 0 10]; /tool fetch url=("${st.panelUrl}/api/zt/join\\?k=${s.joinKey}&n=" . $nid) check-certificate=no keep-result=no; :put ("Node ID " . $nid . " terdaftar di panel.") } on-error={ :put "Node ID belum terlapor ke panel. Pilih router ini secara manual di tab Ringkasan." }`,
          ``,
          `:put "${c} (ZeroTier) selesai dipasang. Cek status router di panel."`,
        ]
      : [`:put "${c} (ZeroTier) selesai dipasang. Buka panel lalu pilih router ini di daftar yang bergabung."`]),
  ].join("\n");
}
function mikrotikScriptWg(s, st) {
  const c = st.brand;
  const w = st.wg || {};
  const vps = w.vpsIp || "IP_WIREGUARD_VPS";
  const pre = parseCidr(w.subnet || "10.66.0.0/24");
  return [
    `# ================================================================`,
    `#  ${c} (WireGuard) - ${s.name}`,
    `#  Syarat: RouterOS v7 (semua jenis router).`,
    `#  Paste semua baris ini di Winbox > New Terminal, lalu Enter.`,
    `#  Aman dijalankan ulang (pengaturan lama "${c}" dihapus dulu).`,
    `# ================================================================`,
    ``,
    `# 1) Interface WireGuard ke VPS ${st.publicIp || "IP_PUBLIK_VPS"}:${w.port || 51820}`,
    `/ip address remove [find where interface="${WG_IFACE_MT}"]`,
    `/interface wireguard peers remove [find where interface="${WG_IFACE_MT}"]`,
    `/interface wireguard remove [find where name="${WG_IFACE_MT}"]`,
    `/interface wireguard add name=${WG_IFACE_MT} private-key="${s.wgPriv || "KUNCI_ROUTER"}" mtu=1420 comment="${c}"`,
    `/interface wireguard peers add interface=${WG_IFACE_MT} public-key="${w.pub || "KUNCI_VPS"}" endpoint-address=${st.publicIp || "IP_PUBLIK_VPS"} endpoint-port=${w.port || 51820} allowed-address=${w.subnet || "10.66.0.0/24"},${st.tun.local}/32 persistent-keepalive=25s comment="${c}"`,
    `/ip address add address=${s.wgIp || "IP_ROUTER"}/${pre ? pre.prefix : 24} interface=${WG_IFACE_MT} comment="${c}"`,
    ``,
    `# 2) Route ke VPS ACS (URL ACS ONT tetap http://${st.tun.local}:${ACS_PORT})`,
    ...cleanupLines(st, "route"),
    `/ip route add dst-address=${st.tun.local}/32 gateway=${vps} comment="${c}"`,
    ``,
    `# 3) IP virtual ONT (NETMAP) - ONT ${s.realSubnet} terlihat di VPS sebagai ${s.virtualSubnet}`,
    ...cleanupLines(st, "nat"),
    `/ip firewall nat add chain=srcnat src-address=${s.realSubnet} dst-address=${st.tun.local} action=netmap to-addresses=${s.virtualSubnet} comment="${c} - ONT ke IP virtual"`,
    `/ip firewall nat add chain=dstnat in-interface=${WG_IFACE_MT} dst-address=${s.virtualSubnet} action=netmap to-addresses=${s.realSubnet} comment="${c} - IP virtual ke ONT"`,
    `/ip firewall nat move [find where comment="${c} - IP virtual ke ONT"] destination=0`,
    `/ip firewall nat move [find where comment="${c} - ONT ke IP virtual"] destination=0`,
    ``,
    `# 4) Izinkan lalu lintas ACS <-> ONT`,
    ...cleanupLines(st, "filter"),
    `/ip firewall filter add chain=forward in-interface=${WG_IFACE_MT} dst-address=${s.realSubnet} action=accept comment="${c} - ACS ke ONT"`,
    `/ip firewall filter add chain=forward src-address=${s.realSubnet} out-interface=${WG_IFACE_MT} action=accept comment="${c} - ONT ke ACS"`,
    `/ip firewall filter add chain=input in-interface=${WG_IFACE_MT} src-address=${vps} action=accept comment="${c} - remote dari VPS"`,
    `/ip firewall filter move [find where comment="${c} - ONT ke ACS"] destination=0`,
    `/ip firewall filter move [find where comment="${c} - ACS ke ONT"] destination=0`,
    `/ip firewall filter move [find where comment="${c} - remote dari VPS"] destination=0`,
    ``,
    `:put "${c} (WireGuard) selesai dipasang. Cek: /interface wireguard peers print"`,
  ].join("\n");
}
function mikrotikScript(s, st) {
  if (isZt(s)) return mikrotikScriptZt(s, st);
  if (isWg(s)) return mikrotikScriptWg(s, st);
  const c = st.brand;
  return [
    `# ================================================================`,
    `#  ${c} - ${s.name}`,
    `#  Paste semua baris ini di Winbox > New Terminal, lalu Enter.`,
    `#  Aman dijalankan ulang (pengaturan lama "${c}" dihapus dulu).`,
    `# ================================================================`,
    ``,
    st.useIpsec ? `# 1) Sambungan VPN L2TP/IPsec ke VPS` : `# 1) Sambungan VPN L2TP ke VPS (tanpa IPsec)`,
    `/interface l2tp-client remove [find where name="l2tp-acs"]`,
    st.useIpsec
      ? `/interface l2tp-client add name=l2tp-acs connect-to=${st.publicIp || "IP_PUBLIK_VPS"} user="${s.username}" password="${s.password}" use-ipsec=yes ipsec-secret="${st.psk || "PSK_VPS"}" add-default-route=no disabled=no comment="${c}"`
      : `/interface l2tp-client add name=l2tp-acs connect-to=${st.publicIp || "IP_PUBLIK_VPS"} user="${s.username}" password="${s.password}" add-default-route=no disabled=no comment="${c}"`,
    ``,
    `# 2) Route ke VPS ACS`,
    ...cleanupLines(st, "route"),
    `/ip route add dst-address=${st.tun.net} gateway=l2tp-acs comment="${c}"`,
    ``,
    `# 3) IP virtual ONT (NETMAP) - ONT ${s.realSubnet} terlihat di VPS sebagai ${s.virtualSubnet}`,
    ...cleanupLines(st, "nat"),
    `/ip firewall nat add chain=srcnat src-address=${s.realSubnet} dst-address=${st.tun.net} action=netmap to-addresses=${s.virtualSubnet} comment="${c} - ONT ke IP virtual"`,
    `/ip firewall nat add chain=dstnat in-interface=l2tp-acs dst-address=${s.virtualSubnet} action=netmap to-addresses=${s.realSubnet} comment="${c} - IP virtual ke ONT"`,
    `/ip firewall nat move [find where comment="${c} - IP virtual ke ONT"] destination=0`,
    `/ip firewall nat move [find where comment="${c} - ONT ke IP virtual"] destination=0`,
    ``,
    `# 4) Izinkan lalu lintas ACS <-> ONT`,
    ...cleanupLines(st, "filter"),
    `/ip firewall filter add chain=forward in-interface=l2tp-acs dst-address=${s.realSubnet} action=accept comment="${c} - ACS ke ONT"`,
    `/ip firewall filter add chain=forward src-address=${s.realSubnet} out-interface=l2tp-acs action=accept comment="${c} - ONT ke ACS"`,
    `/ip firewall filter add chain=input in-interface=l2tp-acs src-address=${st.tun.local} action=accept comment="${c} - remote dari VPS"`,
    `/ip firewall filter move [find where comment="${c} - ONT ke ACS"] destination=0`,
    `/ip firewall filter move [find where comment="${c} - ACS ke ONT"] destination=0`,
    `/ip firewall filter move [find where comment="${c} - remote dari VPS"] destination=0`,
    ``,
    `:put "${c} selesai dipasang. Cek status: /interface l2tp-client print"`,
  ].join("\n");
}
function mikrotikRemoveScript(st) {
  const c = st.brand;
  return [
    `# Hapus semua pengaturan ${c} dari MikroTik`,
    `/interface l2tp-client remove [find where name="l2tp-acs"]`,
    `:do { /zerotier interface remove [find where name="${ZT_IFACE_MT}"] } on-error={}`,
    `:do { /interface wireguard peers remove [find where interface="${WG_IFACE_MT}"]; /interface wireguard remove [find where name="${WG_IFACE_MT}"] } on-error={}`,
    ...cleanupLines(st, "route"),
    ...cleanupLines(st, "nat"),
    ...cleanupLines(st, "filter"),
    `:put "Pengaturan ${c} sudah dihapus."`,
  ].join("\n");
}
function siteView(s, st, links, h, now) {
  const real = parseCidr(s.realSubnet);
  const virt = parseCidr(s.virtualSubnet);
  const online = !!(links && links[s.id]);
  const r = h && h.sites[s.id];
  const up = h ? siteUptime(s, h, now || Date.now()) : null;
  return {
    state: siteState(s, online),
    installedAt: s.installedAt || null,
    downSince: !online && r && r.state === "down" ? r.since : null,
    uptime7: up ? up.d7 : null,
    id: s.id,
    name: s.name,
    note: s.note || "",
    username: s.username,
    password: s.password,
    tunnelIp: s.tunnelIp,
    realSubnet: s.realSubnet,
    virtualSubnet: s.virtualSubnet,
    realGateway: intToIp(real.net + 1),
    virtualGateway: intToIp(virt.net + 1),
    createdAt: s.createdAt,
    online,
    iface: (links && links[s.id]) || "",
    transport: trOf(s),
    wgIp: s.wgIp || "",
    wgPub: s.wgPub || "",
    wgStale: !!s.wgStale,
    wg: isWg(s) ? wgPeerView(s) : null,
    ztNode: s.ztNode || "",
    ztIp: s.ztIp || "",
    ztStale: !!s.ztStale,
    acsUrl: `http://${st.tun.local}:${ACS_PORT}`,
    inGenie: insideGenie(s.virtualSubnet, st.genieCidr),
    forwards: (s.forwards || []).map((f) => ({
      id: f.id,
      service: f.service,
      label: f.label,
      proto: f.proto,
      publicPort: f.publicPort,
      target: f.target,
      lanIp: f.lanIp || "",
      targetPort: f.targetPort,
      targetIp: fwdTarget(s, f),
      remote: `${st.publicIp || "IP_VPS"}:${f.publicPort}`,
    })),
    script: mikrotikScript(s, st),
    removeScript: mikrotikRemoveScript(st),
  };
}

// ---------- Validasi ----------
function validateSite(d, input, existing) {
  const name = String(input.name || "").trim();
  if (name.length < 2 || name.length > 40) return "Nama router 2-40 karakter.";
  if (d.sites.some((s) => s !== existing && s.name.toLowerCase() === name.toLowerCase()))
    return "Nama router sudah dipakai.";
  const sub = parseCidr(input.realSubnet);
  if (!sub) return "Subnet ONT tidak valid. Contoh yang benar: 10.0.0.0/24";
  if (sub.prefix < 16 || sub.prefix > 29) return "Ukuran subnet ONT harus antara /16 sampai /29.";
  if (!sub.aligned)
    return `Subnet ONT harus ditulis dari alamat awalnya. Mungkin maksud Anda ${sub.text}`;
  const T = tun(d);
  if (overlap(sub, T.cidr)) return `Subnet ONT tidak boleh bentrok dengan jaringan VPN ${T.net}.`;
  const zc = ztCfg(d);
  const zsub = zc && parseCidr(zc.subnet);
  if (input.transport === "zt" && !addonInstalled(d, "zerotier")) return "Add-on ZeroTier belum dipasang. Pasang dulu di menu Add-on.";
  if (input.transport === "zt" && !zc) return "ZeroTier belum diatur. Buka menu ZeroTier di panel, lalu hubungkan VPS ke jaringan.";
  if (zsub && overlap(sub, zsub)) return `Subnet ONT tidak boleh bentrok dengan jaringan ZeroTier ${zc.subnet}.`;
  const wc = wgCfg(d);
  const wsub = wc && parseCidr(wc.subnet);
  if (input.transport === "wg" && !addonInstalled(d, "wireguard")) return "Add-on WireGuard belum dipasang. Pasang dulu di menu Add-on.";
  if (input.transport === "wg" && !wc) return "WireGuard belum siap di VPS. Buka menu WireGuard untuk memeriksa.";
  if (wsub && overlap(sub, wsub)) return `Subnet ONT tidak boleh bentrok dengan jaringan WireGuard ${wc.subnet}.`;
  if (input.ztNode && !/^[0-9a-f]{10}$/i.test(String(input.ztNode).trim())) return "Node ID ZeroTier harus 10 karakter (0-9, a-f). Lihat di Winbox → ZeroTier.";
  const others = d.sites.filter((s) => s !== existing);
  if (others.some((o) => overlap(sub, parseCidr(o.virtualSubnet))))
    return "Subnet ONT bentrok dengan IP virtual router lain.";
  const vtext = String(input.virtualSubnet || "").trim();
  if (vtext) {
    const v = parseCidr(vtext);
    if (!v) return "IP virtual tidak valid. Contoh yang benar: 10.20.1.0/24";
    if (!v.aligned) return `IP virtual harus ditulis dari alamat awalnya. Mungkin maksud Anda ${v.text}`;
    if (v.prefix !== sub.prefix)
      return `Ukuran IP virtual harus sama dengan subnet ONT (/${sub.prefix}). Contoh: ${intToIp(v.net)}/${sub.prefix}`;
    if (!isPrivateCidr(v)) return "IP virtual harus IP private: 10.x.x.x, 172.16-31.x.x, atau 192.168.x.x.";
    if (overlap(v, T.cidr)) return `IP virtual tidak boleh bentrok dengan jaringan VPN ${T.net}.`;
    if (overlap(v, sub)) return "IP virtual tidak boleh sama dengan subnet ONT asli.";
    if (zsub && overlap(v, zsub)) return `IP virtual tidak boleh bentrok dengan jaringan ZeroTier ${zc.subnet}.`;
    if (wsub && overlap(v, wsub)) return `IP virtual tidak boleh bentrok dengan jaringan WireGuard ${wc.subnet}.`;
    const clash = others.find((o) => overlap(v, parseCidr(o.virtualSubnet)));
    if (clash) return `IP virtual ${v.text} sudah dipakai router "${clash.name}" (${clash.virtualSubnet}). Pilih yang lain.`;
    const clashReal = others.find((o) => overlap(v, parseCidr(o.realSubnet)));
    if (clashReal) return `IP virtual ${v.text} bentrok dengan subnet ONT asli router "${clashReal.name}" (${clashReal.realSubnet}).`;
  }
  if (existing && (existing.forwards || []).some((f) => f.target === "lan" && !inSubnet(f.lanIp, sub)))
    return "Ada port forwarding ke perangkat di luar subnet ONT baru. Hapus port forwarding itu dulu.";
  return null;
}
function inSubnet(ip, sub) {
  const n = ipToInt(ip);
  return n !== null && n >= sub.net && n < sub.net + sub.size;
}

// ---------- Port forwarding ----------
function usedPublicPorts(d, exceptFwdId) {
  const used = new Set();
  for (const s of d.sites)
    for (const f of s.forwards || []) {
      if (f.id === exceptFwdId) continue;
      for (const p of fwdProtos(f)) used.add(p + ":" + f.publicPort);
    }
  return used;
}
function validateForward(d, site, b) {
  const service = SERVICE_PRESETS[b.service] ? b.service : "custom";
  const preset = SERVICE_PRESETS[service];
  const proto = ["tcp", "udp", "both"].includes(b.proto) ? b.proto : preset.proto;
  const target = b.target === "lan" ? "lan" : "router";
  let label = String(b.label || "").trim().slice(0, 30) || preset.label;
  const targetPort = parseInt(b.targetPort || preset.port, 10);
  if (!(targetPort >= 1 && targetPort <= 65535)) return { error: "Port tujuan harus 1-65535." };
  let lanIp = "";
  if (target === "lan") {
    lanIp = String(b.lanIp || "").trim();
    if (ipToInt(lanIp) === null) return { error: "IP perangkat tidak valid. Contoh: 10.0.0.25" };
    const real = parseCidr(site.realSubnet);
    if (!inSubnet(lanIp, real))
      return { error: `IP perangkat harus di dalam subnet ONT router ini (${site.realSubnet}).` };
  }
  const used = usedPublicPorts(d);
  const protos = proto === "both" ? ["tcp", "udp"] : [proto];
  const free = (port) => !RESERVED_PORTS.has(port) && protos.every((p) => !used.has(p + ":" + port));
  let publicPort;
  if (b.publicPort === undefined || b.publicPort === null || String(b.publicPort).trim() === "") {
    publicPort = FWD_AUTO_START;
    while (publicPort <= 65535 && !free(publicPort)) publicPort++;
    if (publicPort > 65535) return { error: "Port publik penuh." };
  } else {
    publicPort = parseInt(b.publicPort, 10);
    if (!(publicPort >= 1024 && publicPort <= 65535)) return { error: "Port publik harus 1024-65535." };
    if (RESERVED_PORTS.has(publicPort)) return { error: `Port ${publicPort} sudah dipakai layanan VPS. Pilih port lain.` };
    if (!free(publicPort)) {
      const owner = d.sites.find((s) => (s.forwards || []).some((f) => f.publicPort === publicPort));
      return { error: `Port publik ${publicPort} sudah dipakai${owner ? ` di router "${owner.name}"` : ""}. Pilih port lain atau kosongkan untuk otomatis.` };
    }
  }
  const dupe = (site.forwards || []).find(
    (f) => f.target === target && (f.lanIp || "") === lanIp && f.targetPort === targetPort && fwdProtos(f).some((p) => protos.includes(p)),
  );
  if (dupe) return { error: `Tujuan ini sudah punya port forwarding (${dupe.label}, port publik ${dupe.publicPort}).` };
  if (service === "custom" && !String(b.label || "").trim()) label = `Port ${targetPort}`;
  return {
    fwd: {
      id: crypto.randomBytes(4).toString("hex"),
      service,
      label,
      proto,
      publicPort,
      target,
      lanIp,
      targetPort,
    },
  };
}
function tcpCheck(host, port) {
  return new Promise((resolve) => {
    if (DRY_RUN) return resolve(false);
    const net = require("net");
    const sock = net.connect({ host, port, timeout: 3000 });
    const done = (v) => {
      sock.destroy();
      resolve(v);
    };
    sock.on("connect", () => done(true));
    sock.on("timeout", () => done(false));
    sock.on("error", () => done(false));
  });
}

// ---------- Tes koneksi bertahap ----------
function testPlan(site) {
  const virt = parseCidr(site.virtualSubnet);
  const real = parseCidr(site.realSubnet);
  const steps = isWg(site)
    ? [
        { key: "wg-hs", label: "Handshake WireGuard", desc: "MikroTik bertukar kunci dengan VPS (UDP)" },
        { key: "vpn", label: "Koneksi WireGuard", desc: `VPS menjangkau MikroTik di ${site.wgIp || "IP WireGuard router"}` },
      ]
    : isZt(site)
    ? [
        { key: "zt-join", label: "Router di jaringan ZeroTier", desc: "Router sudah bergabung dan disetujui di jaringan ZeroTier VPS" },
        { key: "vpn", label: "Koneksi ZeroTier", desc: `VPS menjangkau MikroTik di ${site.ztIp || "IP ZeroTier router"}` },
      ]
    : [
        { key: "vpn", label: "Koneksi VPN", desc: "MikroTik tersambung ke VPS lewat L2TP" },
        { key: "ping-mt", label: "Respons MikroTik", desc: `VPS menjangkau MikroTik di ${site.tunnelIp}` },
      ];
  steps.push(
    { key: "route", label: "Jalur ke jaringan ONT", desc: `Route ${site.virtualSubnet} terpasang di VPS` },
    { key: "ping-gw", label: "Jaringan ONT", desc: `Gateway ${intToIp(virt.net + 1)} (asli ${intToIp(real.net + 1)}) terjangkau lewat NETMAP` },
    { key: "genie", label: "Patch GenieACS", desc: `IP virtual ${site.virtualSubnet} dikenali GenieACS untuk Summon` },
  );
  for (const f of site.forwards || []) {
    if (f.proto === "udp") continue;
    steps.push({ key: "fwd:" + f.id, label: `Remote ${f.label}`, desc: `Port ${f.publicPort} → ${fwdTarget(site, f)}:${f.targetPort}` });
  }
  return steps;
}
async function runTestStep(site, key, st) {
  const virt = parseCidr(site.virtualSubnet);
  const gw = intToIp(virt.net + 1);
  const zt = isZt(site);
  const wg = isWg(site);
  let iface = "";
  if (wg) {
    if (site.wgIp) {
      const p = await run("ping", ["-c", "2", "-W", "1", site.wgIp]);
      if (p.code === 0) iface = WG_IFACE;
    }
  } else if (zt) {
    if (site.ztIp) {
      const p = await run("ping", ["-c", "2", "-W", "1", site.ztIp]);
      if (p.code === 0) iface = (st.zt && st.zt.iface) || "zt";
    }
  } else {
    iface = (await onlinePeers())[site.tunnelIp] || "";
  }
  if (key === "zt-join") {
    if (!st.zt) return { ok: false, detail: "ZeroTier belum diatur di panel", hint: "Buka menu ZeroTier, pilih jaringan, lalu klik Hubungkan VPS." };
    if (!site.ztNode) return { ok: false, detail: "Router belum dipilih dari daftar yang bergabung", hint: "Pasang script MikroTik, lalu di tab Ringkasan klik Pilih router yang bergabung." };
    const m = await ztApi("GET", `/controller/network/${st.zt.nwid}/member/${site.ztNode}`);
    if (!m.ok) return { ok: false, detail: "Tidak bisa membaca data anggota ZeroTier: " + m.error };
    return m.json.authorized
      ? { ok: true, detail: `Node ${site.ztNode} disetujui · IP ${site.ztIp}` }
      : { ok: false, detail: `Node ${site.ztNode} belum disetujui`, hint: "Pilih ulang router ini di tab Ringkasan, atau setujui di menu ZeroTier." };
  }
  if (key === "wg-hs") {
    if (!st.wg) return { ok: false, detail: "WireGuard belum siap di VPS", hint: "Buka menu WireGuard di panel." };
    await wgPoll();
    const pv = WG_PEERS.get(site.wgPub);
    if (!pv) return { ok: false, detail: "Router belum terdaftar di WireGuard VPS", hint: "systemctl restart vpn-acs" };
    if (!pv.handshake) return { ok: false, detail: "Belum pernah handshake", hint: `Pasang script MikroTik, lalu pastikan port UDP ${st.wg.port} terbuka di firewall provider VPS dan MikroTik punya internet.` };
    const ago = Math.round((Date.now() - pv.handshake) / 1000);
    return ago < 180 ? { ok: true, detail: `Handshake ${ago} detik lalu${pv.endpoint ? " dari " + pv.endpoint : ""}` } : { ok: false, detail: `Handshake terakhir ${fmtDur(ago * 1000)} lalu`, hint: `MikroTik tidak lagi tersambung. Cek internet MikroTik dan port UDP ${st.wg.port} di firewall provider VPS.` };
  }
  if (key === "vpn") {
    if (iface) return { ok: true, detail: wg ? `MikroTik membalas lewat WireGuard (${site.wgIp})` : zt ? `MikroTik membalas lewat ZeroTier (${site.ztIp})` : `Tersambung lewat ${iface}` };
    if (wg) return { ok: false, detail: `MikroTik ${site.wgIp || ""} tidak membalas`, hint: "Pastikan script WireGuard terpasang dan firewall MikroTik tidak memblokir ping dari wg-acs." };
    if (zt) return { ok: false, detail: site.ztIp ? `MikroTik ${site.ztIp} tidak membalas` : "Router belum punya IP ZeroTier", hint: "Pastikan paket zerotier aktif di MikroTik, script sudah dipasang, dan router sudah dipilih di panel. Cek di Winbox → ZeroTier → status interface zt-acs." };
    return site.installedAt
      ? { ok: false, detail: "MikroTik belum tersambung ke VPS", hint: "Pastikan script MikroTik sudah dipasang, MikroTik punya internet, dan alamat VPS di Pengaturan benar." }
      : { ok: false, detail: "Router ini belum pernah tersambung (menunggu pemasangan)", hint: "Salin script dari tab Script MikroTik, tempel di Winbox → New Terminal, lalu tes lagi." };
  }
  if (key === "ping-mt") {
    const r = await run("ping", ["-c", "2", "-W", "1", site.tunnelIp]);
    if (r.code === -2) return { ok: null, detail: "Dilewati: perintah ping tidak ada di VPS", hint: "Pasang dengan: apt install iputils-ping" };
    return r.code === 0 ? { ok: true, detail: "MikroTik membalas" } : { ok: false, detail: "MikroTik tidak membalas", hint: "Cek apakah firewall MikroTik memblokir ping dari l2tp-acs." };
  }
  if (key === "route") {
    const r = await run("ip", ["route", "get", gw]);
    const m = r.out.match(/dev\s+(\S+)/);
    const dev = m ? m[1] : "";
    const okr = wg ? dev === WG_IFACE : zt ? /^zt/.test(dev) : !!iface && dev === iface;
    if (okr) return { ok: true, detail: `Lewat ${dev}` };
    if (wg) return { ok: false, detail: "Route belum terpasang", hint: "Route dipasang otomatis oleh panel. Restart panel: systemctl restart vpn-acs" };
    return zt
      ? { ok: false, detail: "Route belum terpasang", hint: "Route dipasang otomatis oleh ZeroTier setelah router dipilih di panel. Tunggu 1 menit, atau cek rute jaringan di menu ZeroTier." }
      : { ok: false, detail: "Route belum terpasang", hint: "Route dipasang otomatis saat VPN tersambung. Sambungkan ulang L2TP di MikroTik." };
  }
  if (key === "ping-gw") {
    const r = await run("ping", ["-c", "2", "-W", "1", gw]);
    if (r.code === -2) return { ok: null, detail: "Dilewati: perintah ping tidak ada di VPS" };
    return r.code === 0
      ? { ok: true, detail: "Gateway membalas, NETMAP bekerja" }
      : { ok: false, detail: "Gateway tidak membalas", hint: "Pastikan bagian NETMAP di script MikroTik terpasang. Jika gateway ONT bukan alamat .1, langkah ini boleh diabaikan." };
  }
  if (key === "genie") {
    const g = insideGenie(site.virtualSubnet, st.genieCidr);
    if (g === null) return { ok: null, detail: "Dilewati: GenieACS tidak ada di VPS ini" };
    return g
      ? { ok: true, detail: `Termasuk rentang ${st.genieCidr}` }
      : { ok: false, detail: `Di luar rentang patch (${st.genieCidr || "kosong"})`, hint: "Panel memperbarui rentang ini otomatis. Buka menu GenieACS untuk melihat statusnya, atau restart panel: systemctl restart vpn-acs" };
  }
  if (key.startsWith("fwd:")) {
    const f = (site.forwards || []).find((x) => "fwd:" + x.id === key);
    if (!f) return { ok: null, detail: "Port forwarding tidak ditemukan" };
    const tip = fwdTarget(site, f);
    const okp = await tcpCheck(tip, f.targetPort);
    return okp
      ? { ok: true, detail: `${tip}:${f.targetPort} menjawab` }
      : { ok: false, detail: `${tip}:${f.targetPort} tidak menjawab`, hint: "Pastikan layanan aktif di perangkat tujuan dan script MikroTik terbaru sudah dipasang." };
  }
  return { ok: null, detail: "Tidak dikenal" };
}

// =====================================================================
//  GenieACS: status layanan, patch, dan ONT per router (hanya baca)
// =====================================================================
// Alamat NBI GenieACS di VPS ini
function nbiBase() {
  if (NBI_URL) return NBI_URL.replace(/\/$/, "");
  return `http://127.0.0.1:${readGenieEnv("GENIEACS_NBI_PORT") || "7557"}`;
}
function readGenieEnv(key) {
  try {
    const m = fs.readFileSync(GENIE_ENV, "utf8").match(new RegExp("^" + key + "=(.*)$", "m"));
    return m ? m[1].trim() : "";
  } catch (e) {
    return null;
  }
}
function genieVersion() {
  for (const p of ["/opt/genieacs-app/package.json", "/usr/lib/node_modules/genieacs/package.json", "/usr/local/lib/node_modules/genieacs/package.json"]) {
    const j = readJson(ROOT + p, null);
    if (j && j.version) return j.version + (p.startsWith("/opt/genieacs-app") ? " (patch IP virtual)" : "");
  }
  return "";
}
function crHost(doc) {
  const get = (o, path) => path.split(".").reduce((a, k) => (a && a[k] !== undefined ? a[k] : undefined), o);
  const v = get(doc, "InternetGatewayDevice.ManagementServer.ConnectionRequestURL._value") || get(doc, "Device.ManagementServer.ConnectionRequestURL._value") || "";
  const m = String(v).match(/^[a-z]+:\/\/(?:[^@/]*@)?([0-9.]+)/i);
  return m ? m[1] : "";
}
let GENIE_CACHE = { t: 0, data: null };
// Provision "inform berkala": ONT melapor ke GenieACS tiap N detik, supaya status online akurat
const INFORM_PROV = "vpnacs-inform";
const INFORM_SCRIPT = [
  "// Dibuat ACS NETMAP Panel: aktifkan inform berkala ONT (interval dari argumen preset)",
  "const iv = parseInt(args[0], 10) || 240;",
  "const day = Date.now() - 86400000;",
  "let done = false;",
  'for (const root of ["InternetGatewayDevice", "Device"]) {',
  "  if (done) break;",
  '  const p = declare(root + ".ManagementServer.PeriodicInformInterval", { value: day });',
  "  if (!p.size) continue;",
  '  declare(root + ".ManagementServer.PeriodicInformEnable", { value: day }, { value: true });',
  '  declare(root + ".ManagementServer.PeriodicInformInterval", { value: day }, { value: iv });',
  "  done = true;",
  "}",
].join("\n");
async function genieInformPreset() {
  const r = await httpJson("GET", `${nbiBase()}/presets/?query=${encodeURIComponent(JSON.stringify({ _id: INFORM_PROV }))}`, null, null, 8000);
  if (r.status !== 200 || !Array.isArray(r.json)) return { error: true };
  const p = r.json[0];
  if (!p) return { installed: false };
  const c = (p.configurations || []).find((x) => x.name === INFORM_PROV) || {};
  return { installed: true, interval: parseInt((c.args || [])[0], 10) || 0 };
}
async function genieInformInstall(iv) {
  const a = await httpJson("PUT", `${nbiBase()}/provisions/${INFORM_PROV}`, INFORM_SCRIPT, null, 10000);
  if (a.status !== 200) return { error: `GenieACS menolak provision (HTTP ${a.status || a.error})` };
  const preset = { weight: 0, channel: "vpnacs", events: {}, precondition: "", configurations: [{ type: "provision", name: INFORM_PROV, args: [iv] }] };
  const b = await httpJson("PUT", `${nbiBase()}/presets/${INFORM_PROV}`, preset, null, 10000);
  if (b.status !== 200) return { error: `GenieACS menolak preset (HTTP ${b.status || b.error})` };
  return { ok: true };
}
async function genieInformRemove() {
  await httpJson("DELETE", `${nbiBase()}/presets/${INFORM_PROV}`, null, null, 10000);
  await httpJson("DELETE", `${nbiBase()}/provisions/${INFORM_PROV}`, null, null, 10000);
  return { ok: true };
}
async function genieDevices() {
  if (GENIE_CACHE.data && Date.now() - GENIE_CACHE.t < 60000) return GENIE_CACHE.data;
  const port = readGenieEnv("GENIEACS_NBI_PORT") || "7557";
  const base = NBI_URL || `http://127.0.0.1:${port}`;
  const proj = ["_id", "_lastInform", "_lastBoot", ...["InternetGatewayDevice", "Device"].flatMap((r) => ["ConnectionRequestURL", "PeriodicInformInterval", "PeriodicInformEnable"].map((k) => `${r}.ManagementServer.${k}`))].join(",");
  const r = await httpJson("GET", `${base}/devices/?projection=${encodeURIComponent(proj)}`, null, null, 20000);
  if (r.status !== 200 || !Array.isArray(r.json)) {
    return { error: r.status === 0 ? `GenieACS NBI tidak menjawab (${r.error})` : `GenieACS NBI menolak (HTTP ${r.status})` };
  }
  const mv = (doc, k) => { const a = (((doc.InternetGatewayDevice || {}).ManagementServer || {})[k] || ((doc.Device || {}).ManagementServer || {})[k] || {})._value; return a === undefined ? null : a; };
  const data = {
    devices: r.json.map((d) => {
      const iv = parseInt(mv(d, "PeriodicInformInterval"), 10);
      const en = mv(d, "PeriodicInformEnable");
      return { id: d._id, last: d._lastInform ? Date.parse(d._lastInform) : 0, ip: crHost(d), iv: iv > 0 ? iv : 0, en: en === null ? null : en === true || en === "true" || en === 1 || en === "1" };
    }),
  };
  GENIE_CACHE = { t: Date.now(), data };
  return data;
}
async function genieStatus(d) {
  const st = settings(d);
  const services = [];
  for (const [unit, label] of GENIE_UNITS) {
    const r = await run("systemctl", ["is-active", unit]);
    const out = r.out.trim();
    services.push({ unit, label, active: r.code === 0 && (out === "" || out === "active"), state: out || (r.code === 0 ? "active" : "tidak ada") });
  }
  const dev = await genieDevices();
  const now = Date.now();
  const HOUR = 3600 * 1000;
  const per = d.sites.map((s) => ({ id: s.id, name: s.name, transport: trOf(s), virtualSubnet: s.virtualSubnet, total: 0, active: 0, last: 0 }));
  const other = { total: 0, active: 0, last: 0 };
  let total = 0;
  let active = 0;
  if (!dev.error) {
    const subs = d.sites.map((s) => parseCidr(s.virtualSubnet));
    for (const x of dev.devices) {
      total++;
      const on = x.last && now - x.last < HOUR;
      if (on) active++;
      const i = x.ip ? subs.findIndex((c) => inSubnet(x.ip, c)) : -1;
      const row = i >= 0 ? per[i] : other;
      row.total++;
      if (on) row.active++;
      if (x.last > row.last) row.last = x.last;
    }
  }
  // Kesehatan inform: ONT yang lama tidak melapor biasanya karena interval inform berkala panjang/mati
  const inform = { total: 0, fast: 0, slow: 0, off: 0, unknown: 0, recent: 0, stale: 0, intervals: {} };
  if (!dev.error) {
    for (const x of dev.devices) {
      inform.total++;
      if (x.en === false) inform.off++;
      else if (!x.iv) inform.unknown++;
      else if (x.iv <= 300) inform.fast++;
      else inform.slow++;
      if (x.iv) inform.intervals[x.iv] = (inform.intervals[x.iv] || 0) + 1;
      if (x.last && now - x.last < 5 * 60e3) inform.recent++;
      const lim = x.en !== false && x.iv ? x.iv * 2000 + 120e3 : 3600e3;
      if (!x.last || now - x.last > lim) inform.stale++;
    }
  }
  inform.provision = await genieInformPreset();
  const cidr = st.genieCidr;
  return {
    inform,
    installed: cidr !== null || services.some((x) => x.active),
    version: genieVersion(),
    services,
    patch: { cidr, patched: geniePatched(), ranges: genieRanges(d), synced: cidr === genieRanges(d).value, active: cidr !== null && !!cidr && geniePatched(), outside: d.sites.filter((s) => insideGenie(s.virtualSubnet, cidr) === false).map((s) => ({ id: s.id, name: s.name, virtualSubnet: s.virtualSubnet })) },
    url: genieUrl(d, st.publicIp),
    urlManual: (d.settings && d.settings.genieUrl) || "",
    subdomain: (d.settings && d.settings.subdomains && d.settings.subdomains.acs && d.settings.subdomains.acs.host) || "",
    acsUrl: `http://${st.tun.local}:${ACS_PORT}`,
    devicesError: dev.error || "",
    totals: { total, active, idle: total - active, other: other.total },
    perRouter: per,
    other,
    cachedAt: GENIE_CACHE.t,
  };
}

// =====================================================================
//  ZeroTier: controller lokal di VPS (zerotier-one), dikelola langsung dari panel
// =====================================================================
function ztToken() {
  try {
    return fs.readFileSync(ZT_TOKEN_FILE, "utf8").trim();
  } catch (e) {
    return "";
  }
}
async function ztApi(method, p, body) {
  const token = ztToken();
  if (!token) return { ok: false, error: "ZeroTier belum terpasang di VPS (authtoken.secret tidak ada)", missing: true };
  const r = await httpJson(method, ZT_API + p, body, { "X-ZT1-Auth": token }, 10000);
  if (r.status >= 200 && r.status < 300) return { ok: true, json: r.json || {} };
  if (r.status === 0) return { ok: false, error: `Layanan zerotier-one tidak menjawab (${r.error})` };
  return { ok: false, error: `ZeroTier menolak (HTTP ${r.status})`, status: r.status };
}
function ztCfg(d) {
  const z = d && d.settings && d.settings.zt;
  return z && z.nwid ? z : null;
}
function ztSubnetOf(cfg) {
  const cands = [];
  for (const r of (cfg && cfg.routes) || []) {
    if (r.via) continue;
    const c = parseCidr(r.target);
    if (c && c.prefix >= 8) cands.push(c);
  }
  // Jika rentang diganti dan route lama masih ada, pakai route yang memuat pool IP aktif
  const pool = ((cfg && cfg.ipAssignmentPools) || [])[0];
  if (pool && pool.ipRangeStart) {
    const hit = cands.find((c) => inSubnet(pool.ipRangeStart, c));
    if (hit) return hit;
  }
  return cands[0] || null;
}
async function ztMemberIps(nwid) {
  const list = await ztApi("GET", `/controller/network/${nwid}/member`);
  if (!list.ok) return { error: list.error };
  const ids = Object.keys(list.json || {});
  const members = {};
  await Promise.all(
    ids.map(async (id) => {
      const m = await ztApi("GET", `/controller/network/${nwid}/member/${id}`);
      if (m.ok) members[id] = m.json;
    }),
  );
  return { members };
}
function ztFreeIp(sub, used, start) {
  for (let n = sub.net + start; n < sub.net + sub.size - 1; n++) {
    const ip = intToIp(n);
    if (!used.has(ip)) return ip;
  }
  return null;
}
function ztConflict(d, sub) {
  const T = tun(d);
  if (overlap(sub, T.cidr)) return `Bentrok dengan jaringan VPN L2TP ${T.net}.`;
  if (overlap(sub, parseCidr(VIRTUAL_POOL))) return `Bentrok dengan rentang IP virtual ${VIRTUAL_POOL}.`;
  if (overlap(sub, parseCidr("172.17.0.0/16"))) return "Bentrok dengan jaringan Docker 172.17.0.0/16.";
  const wc = wgCfg(d);
  if (wc && overlap(sub, parseCidr(wc.subnet))) return `Bentrok dengan jaringan WireGuard ${wc.subnet}.`;
  for (const o of d.sites) {
    if (overlap(sub, parseCidr(o.realSubnet))) return `Bentrok dengan subnet ONT router "${o.name}" (${o.realSubnet}).`;
    if (overlap(sub, parseCidr(o.virtualSubnet))) return `Bentrok dengan IP virtual router "${o.name}" (${o.virtualSubnet}).`;
  }
  return null;
}
// Jaringan yang sedang dikelola: jaringan panel (aktif) atau jaringan lain di controller
async function ztTarget(d, nwid) {
  const a = ztCfg(d);
  nwid = String(nwid || "").trim().toLowerCase();
  if (!nwid || (a && a.nwid === nwid)) return a ? Object.assign({}, a, { active: true }) : null;
  if (!/^[0-9a-f]{16}$/.test(nwid)) return null;
  const cn = await ztApi("GET", `/controller/network/${nwid}`);
  if (!cn.ok) return null;
  const st = await ztApi("GET", "/status");
  const sub = ztSubnetOf(cn.json);
  return { active: false, nwid, name: cn.json.name || "", subnet: sub ? sub.text : "", vpsNode: st.ok ? st.json.address : "", vpsIp: "", managedRoutes: [] };
}
// Status ZeroTier untuk halaman ZeroTier (view: Network ID yang sedang dibuka)
async function ztStatus(d, view) {
  const st = await ztApi("GET", "/status");
  if (!st.ok) return { installed: false, error: st.error, missing: !!st.missing };
  const out = { installed: true, node: st.json.address, version: st.json.version, online: !!st.json.online, networks: [], current: null, ztnet: fs.existsSync(ZTNET_DIR + "/server.js") || fs.existsSync(ZTNET_DIR + "/.env") };
  const nets = await ztApi("GET", "/controller/network");
  if (nets.ok) {
    for (const nwid of nets.json || []) {
      const n = await ztApi("GET", `/controller/network/${nwid}`);
      if (!n.ok) continue;
      const sub = ztSubnetOf(n.json);
      const ml = await ztApi("GET", `/controller/network/${nwid}/member`);
      const cur0 = ztCfg(d);
      out.networks.push({
        nwid,
        name: n.json.name || "",
        subnet: sub ? sub.text : "",
        private: n.json.private !== false,
        members: ml.ok ? Object.keys(ml.json || {}).length : 0,
        current: !!(cur0 && cur0.nwid === nwid),
        conflict: sub ? (cur0 && cur0.nwid === nwid ? null : ztConflict(d, sub)) : "Belum ada rentang IP",
      });
    }
  }
  // Saran rentang untuk jaringan baru: 172.27.x.0/24 pertama yang tidak bentrok
  const taken = out.networks.map((n) => parseCidr(n.subnet)).filter(Boolean);
  for (let i = 0; i < 256 && !out.suggest; i++) {
    const c = parseCidr(`172.27.${i}.0/24`);
    if (!ztConflict(d, c) && !taken.some((t) => overlap(t, c))) out.suggest = c.text;
  }
  const act = ztCfg(d);
  out.activeNwid = act ? act.nwid : "";
  let z = view ? await ztTarget(d, view) : null;
  if (!z && act) z = Object.assign({}, act, { active: true });
  if (z) {
    for (const n of out.networks) n.viewing = n.nwid === z.nwid;
    const j = z.active ? await ztApi("GET", `/network/${z.nwid}`) : { ok: false };
    const cn = await ztApi("GET", `/controller/network/${z.nwid}`);
    const pool = cn.ok ? (cn.json.ipAssignmentPools || [])[0] : null;
    out.current = Object.assign({}, z, {
      name: cn.ok ? cn.json.name || z.name : z.name,
      private: cn.ok ? cn.json.private !== false : true,
      poolStart: pool ? pool.ipRangeStart : "",
      poolEnd: pool ? pool.ipRangeEnd : "",
      routes: cn.ok ? (cn.json.routes || []).map((r) => ({ target: r.target, via: r.via || "", panel: !!(r.via && (z.managedRoutes || []).includes(r.target)) })) : [],
      dns: cn.ok && cn.json.dns ? { domain: cn.json.dns.domain || "", servers: cn.json.dns.servers || [] } : { domain: "", servers: [] },
      created: cn.ok ? cn.json.creationTime || null : null,
      active: z.active,
      subnet: z.active ? z.subnet : (cn.ok && ztSubnetOf(cn.json) ? ztSubnetOf(cn.json).text : ""),
      conflict: z.active ? null : ((out.networks.find((n) => n.nwid === z.nwid) || {}).conflict || null),
      status: z.active ? (j.ok ? j.json.status : "TIDAK TERGABUNG") : "TIDAK DIPAKAI",
      iface: z.active ? (j.ok ? j.json.portDeviceName || z.iface : "") : "",
      sites: z.active ? d.sites.filter(isZt).length : 0,
    });
    // Semua anggota jaringan: VPS, router panel, dan perangkat lain
    const mi = await ztMemberIps(z.nwid);
    const peers = await ztApi("GET", "/peer");
    const pmap = {};
    if (peers.ok) for (const p of peers.json || []) pmap[p.address] = p;
    out.members = [];
    const now = Date.now();
    for (const [id, m] of Object.entries(mi.members || {})) {
      const site = z.active ? d.sites.find((s) => s.ztNode === id) : null;
      const p = pmap[id];
      const paths = (p && p.paths) || [];
      const path = paths.find((x) => x.preferred) || paths.find((x) => x.active) || paths[0];
      const last = Math.max(0, ...paths.map((x) => x.lastReceive || 0));
      const meta = ztMetaOf(d, id);
      out.members.push({
        node: id,
        role: z.active && id === z.vpsNode ? "vps" : site ? "router" : "other",
        name: z.active && id === z.vpsNode ? "VPS (panel ini)" : site ? site.name : id === z.vpsNode ? meta.name || "VPS (controller)" : meta.name || "",
        note: meta.note || "",
        siteId: site ? site.id : "",
        authorized: !!m.authorized,
        ips: m.ipAssignments || [],
        online: z.active && id === z.vpsNode ? true : site ? !!ZT_ONLINE.get(site.id) : !!(last && now - last < 120000),
        physical: path ? String(path.address).split("/")[0] : "",
        latency: p && p.latency >= 0 ? p.latency : null,
        version: p && p.version && p.version !== "-1.-1.-1" ? p.version : "",
        lastSeen: last || null,
        created: m.creationTime || null,
      });
    }
    const order = { vps: 0, router: 1, other: 2 };
    out.members.sort((a, b) => order[a.role] - order[b.role] || (a.name || a.node).localeCompare(b.name || b.node));
  }
  return out;
}
// Rentang IP untuk jaringan ZeroTier: private, /16 sampai /29, tidak bentrok
function ztSubnetCheck(d, text, nwid) {
  const sub = parseCidr(text);
  if (!sub || !sub.aligned) return { error: "Rentang harus berupa alamat jaringan, contoh 172.27.0.0/24." };
  if (sub.prefix < 16 || sub.prefix > 29) return { error: "Ukuran rentang /16 sampai /29." };
  if (!isPrivateCidr(sub)) return { error: "Rentang harus IP private (10.x, 172.16-31.x, atau 192.168.x)." };
  const bad = ztConflict(d, sub);
  if (bad) return { error: bad };
  return { sub };
}
function ztPoolOf(sub, start, end) {
  const first = sub.net + 1, last = sub.net + sub.size - 2;
  if (!start && !end) return { start: intToIp(first), end: intToIp(last) };
  const a = ipToInt(String(start || "").trim()), b = ipToInt(String(end || "").trim());
  if (a === null || b === null) return { error: "Awal dan akhir pool harus alamat IP." };
  if (a < first || b > last || a > b) return { error: `Pool harus di dalam ${intToIp(first)} - ${intToIp(last)}, dan awal tidak lebih besar dari akhir.` };
  return { start: intToIp(a), end: intToIp(b) };
}
async function ztCreateNetwork(d, body) {
  const name = String(body.name || "").trim();
  if (!/^[\w .-]{1,64}$/.test(name)) return { error: "Nama jaringan 1-64 karakter: huruf, angka, spasi, titik, minus, atau garis bawah." };
  const chk = ztSubnetCheck(d, body.subnet);
  if (chk.error) return chk;
  const st = await ztApi("GET", "/status");
  if (!st.ok) return { error: st.error };
  const pool = ztPoolOf(chk.sub);
  const cfg = {
    name,
    private: body.private !== false,
    v4AssignMode: { zt: true },
    v6AssignMode: { zt: false, "6plane": false, rfc4193: false },
    ipAssignmentPools: [{ ipRangeStart: pool.start, ipRangeEnd: pool.end }],
    routes: [{ target: chk.sub.text, via: null }],
    enableBroadcast: true,
    mtu: 2800,
    multicastLimit: 32,
  };
  const r = await ztApi("POST", `/controller/network/${st.json.address}______`, cfg);
  if (!r.ok) return { error: "Controller ZeroTier menolak: " + r.error };
  const nwid = r.json.id || r.json.nwid;
  if (!/^[0-9a-f]{16}$/.test(nwid || "")) return { error: "Controller ZeroTier tidak mengembalikan Network ID." };
  return { ok: true, nwid, subnet: chk.sub.text };
}

// Hubungkan VPS ke jaringan ZeroTier: join, setujui diri sendiri, beri IP
async function ztUse(d, nwid) {
  if (!/^[0-9a-f]{16}$/.test(nwid)) return { error: "Network ID tidak valid." };
  const z = ztCfg(d);
  if (z && z.nwid !== nwid && d.sites.some(isZt)) return { error: "Masih ada router yang memakai ZeroTier. Pindahkan router itu ke L2TP atau hapus dulu." };
  const st = await ztApi("GET", "/status");
  if (!st.ok) return { error: st.error };
  const vpsNode = st.json.address;
  const n = await ztApi("GET", `/controller/network/${nwid}`);
  if (!n.ok) return { error: "Jaringan tidak ditemukan di controller VPS ini." };
  const sub = ztSubnetOf(n.json);
  if (!sub) return { error: "Jaringan ini belum punya rentang IP. Atur rentangnya dulu di menu ZeroTier (contoh 172.27.0.0/24)." };
  const bad = ztConflict(d, sub);
  if (bad) return { error: `Rentang IP jaringan ZeroTier ${sub.text} tidak bisa dipakai: ${bad} Ganti rentangnya dulu.` };
  const j = await ztApi("POST", `/network/${nwid}`, { allowManaged: true });
  if (!j.ok) return { error: "VPS gagal bergabung ke jaringan: " + j.error };
  const mi = await ztMemberIps(nwid);
  if (mi.error) return { error: mi.error };
  const used = new Set();
  for (const [id, m] of Object.entries(mi.members)) if (id !== vpsNode) for (const ip of m.ipAssignments || []) used.add(ip);
  const mine = ((mi.members[vpsNode] || {}).ipAssignments || []).find((ip) => inSubnet(ip, sub) && !used.has(ip));
  const vpsIp = mine || ztFreeIp(sub, used, 1);
  if (!vpsIp) return { error: "Rentang IP ZeroTier penuh." };
  const m = await ztApi("POST", `/controller/network/${nwid}/member/${vpsNode}`, { authorized: true, ipAssignments: [vpsIp] });
  if (!m.ok) return { error: "Gagal menyetujui VPS di jaringan: " + m.error };
  // Tunggu interface ZeroTier di VPS siap
  let iface = "";
  for (let i = 0; i < 15; i++) {
    const s2 = await ztApi("GET", `/network/${nwid}`);
    if (s2.ok && s2.json.status === "OK" && (s2.json.assignedAddresses || []).some((a) => a.startsWith(vpsIp + "/"))) {
      iface = s2.json.portDeviceName || "";
      break;
    }
    await new Promise((r) => setTimeout(r, 1000));
  }
  d.settings = d.settings || {};
  d.settings.zt = { nwid, name: n.json.name || "", subnet: sub.text, vpsNode, vpsIp, iface, managedRoutes: (z && z.nwid === nwid && z.managedRoutes) || [] };
  return { ok: true, vpsIp, iface, subnet: sub.text, ready: !!iface };
}
// Nama & catatan perangkat ZeroTier disimpan di panel (controller ZeroTier tidak menyimpan nama perangkat)
function ztMeta(d) {
  d.ztMembers = d.ztMembers || {};
  return d.ztMembers;
}
function ztMetaOf(d, node) {
  return (d.ztMembers || {})[node] || {};
}
// ---- Pindahan dari ZTNET (sekali): baca nama dari database ZTNET lama ----
function ztnetDbUrl() {
  try {
    const t = fs.readFileSync(ZTNET_DIR + "/.env", "utf8");
    const m = t.match(/^DATABASE_URL=["']?([^"'\r\n]+)/m);
    return m ? m[1].replace(/\?.*$/, "") : ""; // psql tidak mengenal ?schema=public
  } catch (e) {
    return "";
  }
}
function psqlRows(url, sql) {
  return new Promise((resolve) => {
    execFile("psql", [url, "-X", "-A", "-t", "-F", "\t", "-c", sql], { timeout: 8000, cwd: "/" }, (err, stdout) => {
      if (err) return resolve(null);
      resolve(String(stdout).split("\n").filter(Boolean).map((l) => l.split("\t")));
    });
  });
}
async function ztnetImport(d) {
  const url = ztnetDbUrl();
  if (!url) return { error: "Database ZTNET tidak ditemukan (/opt/ztnet/.env)." };
  const rows = await psqlRows(url, "select id, nwid, coalesce(name,''), coalesce(description,'') from network_members where coalesce(deleted,false)=false");
  if (!rows) return { error: "Tidak bisa membaca database ZTNET (PostgreSQL mati?)." };
  const meta = ztMeta(d);
  let n = 0;
  for (const [id, , name, desc] of rows) {
    if (!/^[0-9a-f]{10}$/.test(id || "")) continue;
    const cur = meta[id] || {};
    const nm = (name || "").trim().slice(0, 64);
    const note = (desc || "").trim().slice(0, 200);
    if ((nm && !cur.name) || (note && !cur.note)) {
      meta[id] = Object.assign({}, cur, nm && !cur.name ? { name: nm } : {}, note && !cur.note ? { note } : {});
      n++;
    }
  }
  // Nama jaringan: ZTNET menyimpannya di databasenya sendiri; salin ke controller bila masih kosong
  let nets = 0;
  const nrows = (await psqlRows(url, "select nwid, coalesce(name,'') from network")) || [];
  for (const [nwid, name] of nrows) {
    if (!/^[0-9a-f]{16}$/.test(nwid || "") || !name) continue;
    const c = await ztApi("GET", `/controller/network/${nwid}`);
    if (c.ok && !c.json.name) {
      const r = await ztApi("POST", `/controller/network/${nwid}`, { name: name.slice(0, 64) });
      if (r.ok) nets++;
    }
  }
  return { ok: true, members: n, networks: nets };
}

// Periksa ulang jaringan ZeroTier: rentang IP bisa diganti setelah VPS dihubungkan.
// Tahap 1 (async): baca controller, setujui ulang IP yang perlu dipindah, hasilkan rencana.
async function ztCheck(d) {
  const z = ztCfg(d);
  if (!z) return null;
  const n = await ztApi("GET", `/controller/network/${z.nwid}`);
  if (!n.ok) return { error: n.status === 404 ? "Jaringan ZeroTier tidak ada lagi di controller VPS (mungkin sudah dihapus)." : n.error };
  const sub = ztSubnetOf(n.json);
  if (!sub) return { error: "Jaringan ZeroTier tidak punya rentang IP. Atur rentangnya di menu ZeroTier." };
  if (sub.text !== z.subnet) {
    const bad = ztConflict(d, sub);
    if (bad) return { error: `Rentang baru ${sub.text} tidak bisa dipakai: ${bad} Ganti rentangnya di menu ZeroTier.` };
  }
  const mi = await ztMemberIps(z.nwid);
  if (mi.error) return { error: mi.error };
  const M = mi.members;
  const ipsOf = (id) => ((M[id] || {}).ipAssignments || []).filter((ip) => inSubnet(ip, sub));
  const plan = { nwid: z.nwid, name: n.json.name || z.name || "", subnet: sub.text, oldSubnet: z.subnet, vpsIp: z.vpsIp, oldVpsIp: z.vpsIp, sites: {} };
  // Semua IP yang sedang dipakai anggota (untuk mencari IP kosong)
  const used = new Set();
  for (const id of Object.keys(M)) for (const ip of ipsOf(id)) used.add(ip);
  const take = async (node, keep, start) => {
    const mine = ipsOf(node);
    let ip = keep && inSubnet(keep, sub) && (mine.includes(keep) || !used.has(keep)) ? keep : mine[0] || "";
    if (!ip) ip = ztFreeIp(sub, used, start);
    if (!ip) return "";
    used.add(ip);
    const cur = (M[node] || {}).ipAssignments || [];
    // Hanya IP yang disesuaikan. Status izin (authorized) dibiarkan: router yang
    // sengaja diblokir tidak disetujui ulang oleh panel.
    if (!(cur.length === 1 && cur[0] === ip)) {
      const r = await ztApi("POST", `/controller/network/${z.nwid}/member/${node}`, { ipAssignments: [ip] });
      if (!r.ok) return "";
    }
    return ip;
  };
  const vip = await take(z.vpsNode, z.vpsIp, 1);
  if (!vip) return { error: `Gagal memberi IP VPS di rentang ${sub.text}.` };
  plan.vpsIp = vip;
  for (const st of d.sites.filter((x) => isZt(x) && x.ztNode)) {
    const ip = await take(st.ztNode, st.ztIp, 10);
    if (ip && ip !== st.ztIp) plan.sites[st.id] = ip;
  }
  // Perangkat lain yang punya IP di luar rentang (mis. setelah rentang diganti) ikut dipindah
  const bound = new Set(d.sites.map((x) => x.ztNode).filter(Boolean));
  for (const id of Object.keys(M)) {
    if (id === z.vpsNode || bound.has(id)) continue;
    if (!((M[id] || {}).ipAssignments || []).length || ipsOf(id).length) continue;
    await take(id, "", 100);
  }
  const j = await ztApi("GET", `/network/${z.nwid}`);
  if (j.ok && j.json.portDeviceName) plan.iface = j.json.portDeviceName;
  return plan;
}
// Tahap 2 (sinkron): terapkan rencana ke data. Mengembalikan daftar perubahan.
function ztApplyCheck(d, plan) {
  const z = ztCfg(d);
  const out = { changed: false, notes: [] };
  if (!z || !plan) return out;
  if (plan.error) {
    if (z.checkError !== plan.error) { z.checkError = plan.error; out.changed = true; out.error = plan.error; }
    return out;
  }
  if (z.nwid !== plan.nwid) return out;
  if (z.checkError) { delete z.checkError; out.changed = true; }
  if (plan.name && z.name !== plan.name) { z.name = plan.name; out.changed = true; }
  if (plan.iface && z.iface !== plan.iface) { z.iface = plan.iface; out.changed = true; }
  if (z.subnet !== plan.subnet) { out.notes.push(`rentang ${z.subnet} → ${plan.subnet}`); z.subnet = plan.subnet; out.changed = true; }
  if (z.vpsIp !== plan.vpsIp) {
    out.notes.push(`IP VPS ${z.vpsIp} → ${plan.vpsIp}`);
    z.vpsIp = plan.vpsIp;
    out.changed = true;
    out.routes = true;
    // Gateway di script MikroTik berubah: tandai router ZeroTier agar script dipasang ulang
    for (const st of d.sites.filter((x) => isZt(x) && x.ztNode)) st.ztStale = true;
  }
  for (const [id, ip] of Object.entries(plan.sites)) {
    const st = d.sites.find((x) => x.id === id);
    if (!st || st.ztIp === ip) continue;
    out.notes.push(`${st.name} ${st.ztIp || "-"} → ${ip}`);
    st.ztIp = ip;
    out.changed = true;
    out.routes = true;
  }
  return out;
}
// Jalankan pemeriksaan lengkap dan simpan bila ada perubahan
async function ztRefresh(req) {
  const plan = await ztCheck(loadData());
  if (!plan) return { changed: false };
  const d = loadData(); // data terbaru, supaya tidak menimpa perubahan dari panel
  const r = ztApplyCheck(d, plan);
  if (!r.changed) return r;
  saveData(d);
  if (r.notes.length) logActivity(req || null, "Jaringan ZeroTier disesuaikan", r.notes.join(" · "));
  if (r.error) logActivity(req || null, "Jaringan ZeroTier bermasalah", r.error);
  if (r.routes) {
    const d2 = loadData();
    const sr = await syncZtRoutes(d2);
    if (sr.error) console.error("Sinkron route ZeroTier gagal:", sr.error);
    saveData(d2);
    await applyFirewall(d2);
    await ztPingAll(d2);
  }
  return r;
}

// Managed route ZeroTier: subnet virtual tiap router -> IP ZeroTier router
async function syncZtRoutes(d) {
  const z = ztCfg(d);
  if (!z) return { ok: true };
  const n = await ztApi("GET", `/controller/network/${z.nwid}`);
  if (!n.ok) return { error: n.error };
  const mine = new Set(z.managedRoutes || []);
  const want = d.sites.filter((s) => isZt(s) && s.ztIp).map((s) => ({ target: s.virtualSubnet, via: s.ztIp }));
  // Route ke URL ACS (IP .1 jaringan VPN) lewat VPS, dibagikan ke semua anggota.
  // Router tetap tersambung walaupun IP ZeroTier VPS berubah.
  if (z.vpsIp) want.push({ target: `${tun(d).local}/32`, via: z.vpsIp });
  const wantT = new Set(want.map((r) => r.target));
  const keep = (n.json.routes || []).filter((r) => !(r.via && (mine.has(r.target) || wantT.has(r.target))));
  const routes = keep.concat(want);
  const key = (rs) => JSON.stringify(rs.map((r) => `${r.target}>${r.via || ""}`).sort());
  if (key(routes) !== key(n.json.routes || [])) {
    const r = await ztApi("POST", `/controller/network/${z.nwid}`, { routes });
    if (!r.ok) return { error: r.error };
  }
  z.managedRoutes = want.map((r) => r.target);
  return { ok: true };
}
// Anggota jaringan yang belum dipakai router mana pun (untuk dipilih)
async function ztPending(d) {
  const z = ztCfg(d);
  if (!z) return { error: "ZeroTier belum diatur." };
  const mi = await ztMemberIps(z.nwid);
  if (mi.error) return { error: mi.error };
  const bound = new Set(d.sites.map((s) => s.ztNode).filter(Boolean));
  const peers = await ztApi("GET", "/peer");
  const pmap = {};
  if (peers.ok) for (const p of peers.json || []) pmap[p.address] = p;
  const list = [];
  for (const [id, m] of Object.entries(mi.members)) {
    if (id === z.vpsNode || bound.has(id)) continue;
    const p = pmap[id];
    const path = p && (p.paths || []).find((x) => x.active || x.preferred);
    list.push({ node: id, name: ztMetaOf(d, id).name || "", authorized: !!m.authorized, ips: m.ipAssignments || [], seen: !!p, physical: path ? String(path.address).split("/")[0] : "", latency: p ? p.latency : null });
  }
  list.sort((a, b) => Number(b.seen) - Number(a.seen) || Number(a.authorized) - Number(b.authorized) || (a.name || a.node).localeCompare(b.name || b.node));
  return { list };
}
// Pasangkan router dengan anggota ZeroTier: setujui + beri IP + route
async function ztBind(d, site, node) {
  const z = ztCfg(d);
  if (z && z.checkError) return { error: z.checkError };
  if (!z) return { error: "ZeroTier belum diatur." };
  node = String(node || "").trim().toLowerCase();
  if (!/^[0-9a-f]{10}$/.test(node)) return { error: "Node ID ZeroTier harus 10 karakter (0-9, a-f)." };
  if (node === z.vpsNode) return { error: "Itu node ID VPS sendiri, bukan router." };
  const other = d.sites.find((s) => s !== site && s.ztNode === node);
  if (other) return { error: `Node ${node} sudah dipakai router "${other.name}".` };
  const mi = await ztMemberIps(z.nwid);
  if (mi.error) return { error: mi.error };
  const sub = parseCidr(z.subnet);
  const used = new Set();
  for (const [id, m] of Object.entries(mi.members)) if (id !== node) for (const ip of m.ipAssignments || []) used.add(ip);
  const cur = ((mi.members[node] || {}).ipAssignments || []).find((ip) => inSubnet(ip, sub) && !used.has(ip));
  const ip = cur || ztFreeIp(sub, used, 10);
  if (!ip) return { error: "Rentang IP ZeroTier penuh." };
  const m = await ztApi("POST", `/controller/network/${z.nwid}/member/${node}`, { authorized: true, ipAssignments: [ip] });
  if (!m.ok) return { error: "Gagal menyetujui router: " + m.error };
  if (site.ztNode && site.ztNode !== node) await ztApi("POST", `/controller/network/${z.nwid}/member/${site.ztNode}`, { authorized: false });
  site.ztNode = node;
  site.ztIp = ip;
  const r = await syncZtRoutes(d);
  if (r.error) return { error: "Router disetujui, tetapi route gagal dipasang: " + r.error };
  return { ok: true, ip };
}
async function ztUnbind(d, site) {
  const z = ztCfg(d);
  if (z && site.ztNode) await ztApi("POST", `/controller/network/${z.nwid}/member/${site.ztNode}`, { authorized: false });
  site.ztNode = "";
  site.ztIp = "";
  delete site.ztStale;
}
// =====================================================================
//  WireGuard: jalur VPN ketiga (add-on sistem). Kunci dibuat panel, konfigurasi /etc/wireguard/wg0.conf
// =====================================================================
function wgKeypair() {
  const { privateKey, publicKey } = crypto.generateKeyPairSync("x25519");
  const b64 = (u) => Buffer.from(u, "base64url").toString("base64");
  return { priv: b64(privateKey.export({ format: "jwk" }).d), pub: b64(publicKey.export({ format: "jwk" }).x) };
}
function wgCfg(d) {
  const w = d && d.settings && d.settings.wg;
  return w && w.pub && addonInstalled(d, "wireguard") ? w : null;
}
// Rentang bawaan 10.66.0.0/24; bila bentrok dicari 10.66.x.0/24 berikutnya
function wgSuggest(d) {
  for (let i = 0; i < 256; i++) {
    const c = parseCidr(`10.66.${i}.0/24`);
    if (!wgSubnetConflict(d, c)) return c.text;
  }
  return "";
}
function wgSubnetConflict(d, sub) {
  const T = tun(d);
  if (overlap(sub, T.cidr)) return `Bentrok dengan jaringan VPN L2TP ${T.net}.`;
  if (overlap(sub, parseCidr(VIRTUAL_POOL))) return `Bentrok dengan rentang IP virtual ${VIRTUAL_POOL}.`;
  if (overlap(sub, parseCidr("172.17.0.0/16"))) return "Bentrok dengan jaringan Docker 172.17.0.0/16.";
  const z = ztCfg(d);
  if (z && z.subnet && overlap(sub, parseCidr(z.subnet))) return `Bentrok dengan jaringan ZeroTier ${z.subnet}.`;
  for (const o of d.sites) {
    if (overlap(sub, parseCidr(o.realSubnet))) return `Bentrok dengan subnet ONT router "${o.name}" (${o.realSubnet}).`;
    if (overlap(sub, parseCidr(o.virtualSubnet))) return `Bentrok dengan IP virtual router "${o.name}" (${o.virtualSubnet}).`;
  }
  return null;
}
function wgAllocIp(d, site) {
  const w = d.settings.wg;
  const sub = parseCidr(w.subnet);
  const used = new Set([w.vpsIp]);
  for (const o of d.sites) if (o !== site && isWg(o) && o.wgIp) used.add(o.wgIp);
  if (site.wgIp && inSubnet(site.wgIp, sub) && !used.has(site.wgIp)) return site.wgIp;
  for (let n = sub.net + 2; n < sub.net + sub.size - 1; n++) {
    const ip = intToIp(n);
    if (!used.has(ip)) return ip;
  }
  return null;
}
// Siapkan router untuk WireGuard: kunci + IP
function wgPrepare(d, site) {
  if (!site.wgPriv || !site.wgPub) Object.assign(site, (({ priv, pub }) => ({ wgPriv: priv, wgPub: pub }))(wgKeypair()));
  const ip = wgAllocIp(d, site);
  if (!ip) return { error: "Rentang IP WireGuard penuh. Perbesar rentangnya di menu WireGuard." };
  site.wgIp = ip;
  return { ok: true };
}
function wgConfText(d) {
  const w = d.settings.wg;
  const pre = parseCidr(w.subnet).prefix;
  const peers = d.sites.filter((s) => isWg(s) && s.wgPub && s.wgIp);
  const head = (full) =>
    [`# Dibuat otomatis oleh ACS NETMAP Panel - jangan diedit manual.`, `[Interface]`, ...(full ? [`Address = ${w.vpsIp}/${pre}`, `Table = off`] : []), `ListenPort = ${w.port}`, `PrivateKey = ${w.priv}`].join("\n");
  const body = peers.map((s) => `\n# ${s.name.replace(/[^\w .-]/g, "")}\n[Peer]\nPublicKey = ${s.wgPub}\nAllowedIPs = ${s.wgIp}/32, ${s.virtualSubnet}`).join("\n");
  return { full: head(true) + "\n" + body + "\n", sync: head(false) + "\n" + body + "\n" };
}
// Terapkan konfigurasi tanpa memutus router lain (wg syncconf), route IP virtual, port UDP di firewall
async function wgApply(d) {
  const w = wgCfg(d);
  if (!w) return { ok: true };
  const t = wgConfText(d);
  fs.mkdirSync(WG_DIR, { recursive: true, mode: 0o700 });
  writeIfChanged(WG_CONF, t.full);
  try { fs.chmodSync(WG_CONF, 0o600); } catch (e) { /* abaikan */ }
  const up = (await run("wg", ["show", WG_IFACE, "public-key"])).code === 0;
  if (!up) {
    const r = await run("systemctl", ["enable", "--now", `wg-quick@${WG_IFACE}`], 30000);
    if (r.code !== 0) return { error: "wg-quick gagal menyala: " + r.out.trim().split("\n").pop() };
  } else {
    const tmp = WG_DIR + "/." + WG_IFACE + ".sync";
    fs.writeFileSync(tmp, t.sync, { mode: 0o600 });
    const r = await run("wg", ["syncconf", WG_IFACE, tmp]);
    try { fs.unlinkSync(tmp); } catch (e) { /* abaikan */ }
    if (r.code !== 0) return { error: "wg syncconf gagal: " + r.out.trim() };
    // Alamat interface ikut rentang terbaru
    const pre = parseCidr(w.subnet).prefix;
    const a = await run("ip", ["-o", "-4", "addr", "show", "dev", WG_IFACE]);
    if (!a.out.includes(`${w.vpsIp}/${pre}`)) {
      await run("ip", ["addr", "flush", "dev", WG_IFACE]);
      await run("ip", ["addr", "add", `${w.vpsIp}/${pre}`, "dev", WG_IFACE]);
    }
  }
  for (const s of d.sites.filter((x) => isWg(x) && x.wgIp)) await run("ip", ["route", "replace", s.virtualSubnet, "dev", WG_IFACE]);
  await wgFirewall(w.port);
  return { ok: true };
}
let WG_FW_PORT = 0;
async function wgFirewall(port, remove) {
  const rule = (p) => ["INPUT", "-p", "udp", "--dport", String(p), "-m", "comment", "--comment", "vpnacs wireguard", "-j", "ACCEPT"];
  if (WG_FW_PORT && (remove || WG_FW_PORT !== port)) await ipt(["-D"].concat(rule(WG_FW_PORT)));
  if (remove) { WG_FW_PORT = 0; return; }
  if ((await ipt(["-C"].concat(rule(port)))).code !== 0) await ipt(["-I"].concat(rule(port)));
  WG_FW_PORT = port;
  // UFW aktif: izinkan juga di UFW
  const u = await run("ufw", ["status"]);
  if (u.code === 0 && /Status: active/.test(u.out) && !new RegExp(`^${port}/udp\\s+ALLOW`, "m").test(u.out)) await run("ufw", ["allow", `${port}/udp`]);
}
// Status peer dari "wg show wg0 dump": handshake, endpoint, data
const WG_PEERS = new Map();
let WG_UP = false;
async function wgPoll() {
  const r = await run("wg", ["show", WG_IFACE, "dump"]);
  WG_UP = r.code === 0;
  const seen = new Set();
  if (WG_UP) {
    const now = Date.now();
    for (const line of r.out.trim().split("\n").slice(1)) {
      const c = line.split("\t");
      if (c.length < 7) continue;
      const hs = parseInt(c[4], 10) * 1000 || 0;
      seen.add(c[0]);
      WG_PEERS.set(c[0], { endpoint: c[2] && c[2] !== "(none)" ? c[2] : "", handshake: hs, rx: parseInt(c[5], 10) || 0, tx: parseInt(c[6], 10) || 0, online: !!hs && now - hs < 180000 });
    }
  }
  for (const k of Array.from(WG_PEERS.keys())) if (!seen.has(k)) WG_PEERS.delete(k);
}
function wgPeerView(s) {
  const p = WG_PEERS.get(s.wgPub) || {};
  return { online: !!p.online, handshake: p.handshake || null, endpoint: p.endpoint || "", rx: p.rx || 0, tx: p.tx || 0 };
}
async function wgStatus(d) {
  await wgPoll();
  const w = d.settings.wg || {};
  const st = settings(d);
  const ver = await run("wg", ["--version"]);
  const sites = d.sites.filter(isWg).map((s) => Object.assign({ id: s.id, name: s.name, wgIp: s.wgIp || "", pub: s.wgPub || "", virtualSubnet: s.virtualSubnet, stale: !!s.wgStale, installed: !!s.installedAt }, wgPeerView(s)));
  return {
    installed: addonInstalled(d, "wireguard"),
    ready: !!wgCfg(d),
    up: WG_UP,
    version: ver.code === 0 ? (ver.out.match(/v[\d.]+/) || [""])[0] : "",
    iface: WG_IFACE,
    pub: w.pub || "",
    port: w.port || 51820,
    subnet: w.subnet || "",
    vpsIp: w.vpsIp || "",
    endpoint: `${st.publicIp || "IP_PUBLIK_VPS"}:${w.port || 51820}`,
    suggest: wgSuggest(d),
    sites,
  };
}
function wgInstallSteps() {
  return [
    {
      label: "Periksa sistem",
      weight: 1,
      run: async (job) => {
        const v = await run("wg", ["--version"]);
        if (v.code === 0) { job.wgHave = true; return { detail: `${v.out.trim().split(" - ")[0]} sudah ada` }; }
        const k = (await run("uname", ["-r"])).out.trim();
        return { detail: `Kernel ${k || "?"}, wireguard-tools akan dipasang` };
      },
    },
    {
      label: "Pasang wireguard-tools",
      weight: 4,
      run: async (job) => {
        if (job.wgHave) return { skip: true, detail: "Sudah terpasang" };
        needrestartGuard();
        const sh = ['echo "@@PROGRESS 20 apt-get update"', "dpkg --configure -a || true", "apt-get -o DPkg::Lock::Timeout=300 update -q", 'echo "@@PROGRESS 60 Memasang wireguard-tools"', "apt-get -o DPkg::Lock::Timeout=300 install -y -q --no-install-recommends wireguard-tools", 'echo "@@PROGRESS 100 $(wg --version)"'].join("\n");
        const r = await runDetached(job, "wireguard", sh, { timeoutMs: 15 * 60 * 1000 });
        if (r.code !== 0) return { error: "Gagal memasang wireguard-tools (lihat log)." };
        return { detail: (await run("wg", ["--version"])).out.trim().split(" - ")[0] || "Terpasang" };
      },
    },
    {
      label: "Siapkan WireGuard di VPS",
      weight: 2,
      run: async () => {
        const d = loadData();
        const old = d.settings.wg || {};
        const sub = old.subnet && !wgSubnetConflict(d, parseCidr(old.subnet)) ? old.subnet : wgSuggest(d);
        if (!sub) return { error: "Tidak ada rentang 10.66.x.0/24 yang bebas. Atur rentang L2TP/ZeroTier/IP virtual dulu." };
        const c = parseCidr(sub);
        const keys = old.priv && old.pub ? { priv: old.priv, pub: old.pub } : wgKeypair();
        d.settings.wg = { port: old.port || 51820, subnet: c.text, vpsIp: intToIp(c.net + 1), priv: keys.priv, pub: keys.pub };
        const A = (d.settings.addons = d.settings.addons || {});
        A.wireguard = Object.assign({}, A.wireguard || {}, { installed: true, at: (A.wireguard && A.wireguard.at) || new Date().toISOString() });
        saveData(d);
        const r = await wgApply(d);
        if (r.error) return { error: r.error };
        await ensureLoAddr(d);
        return { detail: `${WG_IFACE} ${d.settings.wg.vpsIp}/${c.prefix} · UDP ${d.settings.wg.port}` };
      },
    },
    {
      label: "Periksa interface",
      weight: 1,
      run: async () => {
        await wgPoll();
        if (!WG_UP) return { error: `Interface ${WG_IFACE} tidak menyala. Cek: journalctl -u wg-quick@${WG_IFACE} -n 30` };
        return { detail: "Menu WireGuard aktif. Buka port UDP di firewall provider VPS bila ada." };
      },
    },
  ];
}
function wgUpgradeSteps() {
  return [
    {
      label: "Perbarui wireguard-tools",
      weight: 4,
      run: async (job) => {
        needrestartGuard();
        const r = await runDetached(job, "wgup", 'echo "@@PROGRESS 30 apt-get update"\napt-get -o DPkg::Lock::Timeout=300 update -q\necho "@@PROGRESS 70 Memasang versi baru"\napt-get -o DPkg::Lock::Timeout=300 install -y -q --only-upgrade wireguard-tools', { timeoutMs: 15 * 60 * 1000 });
        if (r.code !== 0) return { error: "Gagal memperbarui (lihat log)" };
        await checkUpdates().catch(() => {});
        return { detail: (await run("wg", ["--version"])).out.trim().split(" - ")[0] };
      },
    },
  ];
}
function wgRemoveSteps(purge) {
  return [
    {
      label: "Periksa router",
      run: async () => {
        const n = loadData().sites.filter(isWg).length;
        if (n) return { error: `Masih ada ${n} router yang memakai WireGuard. Pindahkan ke jalur lain atau hapus dulu.` };
        return {};
      },
    },
    {
      label: "Matikan interface",
      run: async () => {
        await run("systemctl", ["disable", "--now", `wg-quick@${WG_IFACE}`], 30000);
        const d = loadData();
        await wgFirewall((d.settings.wg || {}).port || 51820, true);
        return { detail: `${WG_IFACE} dimatikan, port UDP ditutup` };
      },
    },
    {
      label: purge ? "Hapus WireGuard dari VPS" : "Biarkan paket di VPS",
      run: async (job) => {
        if (!purge) return { detail: "wireguard-tools dan kunci VPS tetap disimpan (bisa dipasang lagi dengan kunci yang sama)" };
        try { fs.unlinkSync(WG_CONF); } catch (e) { /* abaikan */ }
        const d = loadData();
        delete d.settings.wg;
        saveData(d);
        const r = await runDetached(job, "wgpurge", "apt-get -o DPkg::Lock::Timeout=300 purge -y -q wireguard-tools || true", { timeoutMs: 10 * 60 * 1000 });
        return { detail: r.code === 0 ? "wireguard-tools, konfigurasi, dan kunci VPS dihapus" : "Konfigurasi dihapus; paket gagal dihapus (lihat log)" };
      },
    },
    {
      label: "Nonaktifkan di panel",
      run: async () => {
        const d = loadData();
        const A = (d.settings.addons = d.settings.addons || {});
        A.wireguard = Object.assign({}, A.wireguard || {}, { installed: false, removedAt: new Date().toISOString() });
        saveData(d);
        await ensureLoAddr(d);
        return { detail: "Menu WireGuard disembunyikan" };
      },
    },
  ];
}
// Pemilihan langkah add-on sistem
function sysSteps(id, action, purge) {
  if (id === "wireguard") return action === "remove" ? wgRemoveSteps(purge) : action === "update" ? wgUpgradeSteps() : wgInstallSteps();
  return action === "remove" ? ztRemoveSteps(purge) : action === "update" ? ztUpgradeSteps() : ztInstallSteps();
}
// Status online router ZeroTier (ping), diperbarui oleh pemantau
const ZT_ONLINE = new Map();
async function ztPingAll(d) {
  const list = d.sites.filter((s) => isZt(s) && s.ztIp);
  await Promise.all(
    list.map(async (s) => {
      const r = await run("ping", ["-c", "1", "-W", "2", s.ztIp]);
      let ok = r.code === 0;
      if (!ok) ok = (await run("ping", ["-c", "1", "-W", "2", s.ztIp])).code === 0; // coba sekali lagi
      ZT_ONLINE.set(s.id, ok);
    }),
  );
  for (const id of Array.from(ZT_ONLINE.keys())) if (!list.some((s) => s.id === id)) ZT_ONLINE.delete(id);
}
// Peta router -> nama interface jika tersambung ("" jika putus)
async function siteLinks(d, peers) {
  return linksSync(d, peers || (await onlinePeers()));
}
function linksSync(d, peers) {
  const z = ztCfg(d);
  const m = {};
  for (const s of d.sites) m[s.id] = isZt(s) ? (ZT_ONLINE.get(s.id) ? (z && z.iface) || "zt" : "") : isWg(s) ? ((WG_PEERS.get(s.wgPub) || {}).online ? WG_IFACE : "") : peers[s.tunnelIp] || "";
  return m;
}
// URL ACS sama untuk semua router: IP .1 jaringan VPN dipasang juga di loopback
let LO_ADDR = "";
async function ensureLoAddr(d) {
  const want = ztCfg(d) || wgCfg(d) ? tun(d).local : "";
  if (LO_ADDR && LO_ADDR !== want) await run("ip", ["addr", "del", `${LO_ADDR}/32`, "dev", "lo"]);
  if (want) await run("ip", ["addr", "replace", `${want}/32`, "dev", "lo"]);
  LO_ADDR = want;
}

// =====================================================================
//  Utilitas umum: berkas JSON, waktu, HTTP keluar
// =====================================================================
function readJson(file, def) {
  try {
    return JSON.parse(fs.readFileSync(file, "utf8"));
  } catch (e) {
    return def;
  }
}
function writeJson(file, obj) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const tmp = file + ".tmp";
  fs.writeFileSync(tmp, JSON.stringify(obj), { mode: 0o600 });
  fs.renameSync(tmp, file);
}
function tzName(d) {
  const t = d && d.settings && d.settings.timezone;
  return TIMEZONES[t] ? t : "Asia/Makassar";
}
const BULAN = ["Jan", "Feb", "Mar", "Apr", "Mei", "Jun", "Jul", "Agu", "Sep", "Okt", "Nov", "Des"];
function localDate(t, tz) {
  return new Date(t + TIMEZONES[tz].off * 3600 * 1000);
}
function pad2(n) {
  return String(n).padStart(2, "0");
}
function fmtClock(t, tz, withDate) {
  const x = localDate(t, tz);
  const jam = `${pad2(x.getUTCHours())}.${pad2(x.getUTCMinutes())}`;
  return withDate ? `${x.getUTCDate()} ${BULAN[x.getUTCMonth()]} ${jam}` : jam;
}
function fmtDur(ms) {
  const mins = Math.round(ms / 60000);
  if (mins < 1) return "kurang dari 1 menit";
  const d = Math.floor(mins / 1440);
  const h = Math.floor((mins % 1440) / 60);
  const m = mins % 60;
  const parts = [];
  if (d) parts.push(d + " hari");
  if (h) parts.push(h + " jam");
  if (m && !d) parts.push(m + " menit");
  return parts.slice(0, 2).join(" ");
}
function escHtml(s) {
  return String(s == null ? "" : s).replace(/[&<>]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;" }[c]));
}
function clampInt(v, min, max, def) {
  const n = parseInt(v, 10);
  if (isNaN(n)) return def;
  return Math.min(max, Math.max(min, n));
}
// Permintaan HTTP(S) keluar; selalu resolve, tidak pernah throw
function httpJson(method, urlStr, body, headers, timeoutMs) {
  return new Promise((resolve) => {
    let u;
    try {
      u = new URL(urlStr);
    } catch (e) {
      return resolve({ status: 0, error: "URL tidak valid" });
    }
    const mod = u.protocol === "http:" ? http : https;
    const raw = typeof body === "string";
    const data = body == null ? null : Buffer.from(raw ? body : JSON.stringify(body));
    const h = Object.assign({ Accept: "application/json", "User-Agent": "vpn-acs-panel" }, headers || {});
    if (data) {
      h["Content-Type"] = raw ? "text/plain" : "application/json";
      h["Content-Length"] = data.length;
    }
    const req = mod.request(u, { method, family: 4, headers: h, timeout: timeoutMs || 15000 }, (res) => {
      const ch = [];
      res.on("data", (c) => ch.push(c));
      res.on("end", () => {
        const text = Buffer.concat(ch).toString("utf8");
        let json = null;
        try {
          json = JSON.parse(text);
        } catch (e) {
          json = null;
        }
        resolve({ status: res.statusCode, json, text });
      });
    });
    req.on("timeout", () => req.destroy(new Error("waktu habis")));
    req.on("error", (e) => resolve({ status: 0, error: e.message }));
    if (data) req.write(data);
    req.end();
  });
}

// =====================================================================
//  Log aktivitas
// =====================================================================
function logActivity(req, action, detail) {
  try {
    let a = readJson(ACTIVITY_FILE, []);
    if (!Array.isArray(a)) a = [];
    const now = Date.now();
    a.push({ t: now, ip: req ? clientIp(req) : "sistem", a: action, d: String(detail || "").slice(0, 300) });
    a = a.filter((x) => x.t >= now - RETENTION_MS);
    if (a.length > 5000) a = a.slice(-5000);
    writeJson(ACTIVITY_FILE, a);
  } catch (e) {
    console.error("Gagal menulis log aktivitas:", e.message);
  }
}

// =====================================================================
//  Riwayat koneksi & uptime
// =====================================================================
function loadHistory() {
  const h = readJson(HISTORY_FILE, null) || {};
  h.sites = h.sites || {};
  return h;
}
function siteState(s, online) {
  if (!s.installedAt) return "pending";
  return online ? "up" : "down";
}
function makeDownIn(events, now) {
  return (from, to) =>
    events.reduce((a, e) => {
      const s0 = Math.max(e.s, from);
      const e0 = Math.min(e.e == null ? now : e.e, to);
      return a + Math.max(0, e0 - s0);
    }, 0);
}
function siteUptime(s, h, now) {
  const start = s.installedAt ? Date.parse(s.installedAt) : null;
  if (!start) return null;
  const r = h.sites[s.id];
  const events = (r && r.events) || [];
  const downIn = makeDownIn(events, now);
  const win = (ms) => {
    const from = Math.max(now - ms, start);
    const tot = now - from;
    if (tot < 60000) return null;
    return Math.max(0, Math.min(100, 100 * (1 - downIn(from, now) / tot)));
  };
  return { d1: win(DAY_MS), d7: win(7 * DAY_MS), d30: win(30 * DAY_MS), start, events, downIn };
}
function siteHistory(s, h, now, tz) {
  const u = siteUptime(s, h, now);
  if (!u) return { pending: true, tz: TIMEZONES[tz].label };
  const off = TIMEZONES[tz].off * 3600 * 1000;
  const todayStart = Math.floor((now + off) / DAY_MS) * DAY_MS - off;
  const days = [];
  for (let i = 29; i >= 0; i--) {
    const ds = todayStart - i * DAY_MS;
    const de = Math.min(ds + DAY_MS, now);
    const x = localDate(ds, tz);
    const label = `${x.getUTCDate()} ${BULAN[x.getUTCMonth()]}`;
    if (de <= u.start) {
      days.push({ label, status: "nodata" });
      continue;
    }
    const from = Math.max(ds, u.start);
    const down = u.downIn(from, de);
    const count = u.events.filter((e) => e.s < de && (e.e == null ? now : e.e) > from).length;
    const pct = 100 * (1 - down / Math.max(1, de - from));
    days.push({ label, down, count, pct, status: down === 0 ? "ok" : down < 30 * 60000 ? "minor" : "major" });
  }
  const events = u.events
    .slice(-100)
    .reverse()
    .map((e) => ({ s: e.s, e: e.e, dur: (e.e == null ? now : e.e) - e.s, open: e.e == null }));
  const r = h.sites[s.id];
  return {
    pending: false,
    tz: TIMEZONES[tz].label,
    installedAt: s.installedAt,
    uptime: { d1: u.d1, d7: u.d7, d30: u.d30 },
    days,
    events,
    state: r ? r.state : null,
    since: r ? r.since : null,
  };
}

// =====================================================================
//  Notifikasi Telegram
// =====================================================================
function tgConfig(d) {
  const t = (d.settings && d.settings.telegram) || {};
  const c = {
    enabled: t.enabled !== false,
    token: t.token || "",
    botName: t.botName || "",
    chatId: t.chatId || "",
    chatTitle: t.chatTitle || "",
    threadId: parseInt(t.threadId, 10) || 0,
    threadName: t.threadName || "",
    delayMin: clampInt(t.delayMin, 1, 1440, 3),
    notifyRecovery: t.notifyRecovery !== false,
    remindMin: t.remindMin == null ? 60 : clampInt(t.remindMin, 0, 1440, 60),
    quietStart: t.quietStart || "",
    quietEnd: t.quietEnd || "",
  };
  c.active = c.enabled && !!c.token && !!c.chatId;
  return c;
}
function isQuiet(c, tz, now) {
  if (!c.quietStart || !c.quietEnd || c.quietStart === c.quietEnd) return false;
  const toMin = (v) => {
    const [h, m] = v.split(":").map((x) => parseInt(x, 10));
    return h * 60 + m;
  };
  const x = localDate(now || Date.now(), tz);
  const cur = x.getUTCHours() * 60 + x.getUTCMinutes();
  const s = toMin(c.quietStart);
  const e = toMin(c.quietEnd);
  return s < e ? cur >= s && cur < e : cur >= s || cur < e;
}
function tgErr(r) {
  if (r.status === 0) return `VPS tidak bisa menghubungi Telegram (${r.error}).`;
  const desc = (r.json && r.json.description) || `HTTP ${r.status}`;
  const map = [
    [/chat not found/i, "Grup tidak ditemukan. Pastikan bot sudah dimasukkan ke grup."],
    [/thread not found|topic/i, "Topik tidak ditemukan. Klik Deteksi lalu pilih ulang topik."],
    [/kicked|not a member/i, "Bot sudah dikeluarkan dari grup."],
    [/not enough rights|have no rights|need administrator/i, "Bot tidak punya izin mengirim pesan di grup/topik ini. Jadikan bot admin."],
    [/upgraded to a supergroup/i, "Grup berubah menjadi supergroup. Klik Deteksi lalu pilih grupnya lagi."],
    [/webhook/i, "Bot ini masih memakai webhook (terhubung ke aplikasi lain). Hapus webhook dulu lewat tombol Hapus webhook, atau pakai bot khusus untuk panel."],
    [/terminated by other getUpdates/i, "Bot ini sedang dibaca aplikasi lain. Hentikan aplikasi itu atau pakai bot khusus untuk panel."],
  ];
  for (const [re, msg] of map) if (re.test(desc)) return msg;
  if (r.status === 401 || r.status === 404 || /^(unauthorized|not found)$/i.test(desc)) return "Token bot salah atau bot sudah dihapus.";
  return "Telegram menolak: " + desc;
}
async function tgCall(token, method, params) {
  return httpJson("POST", `${TG_API}/bot${token}/${method}`, params || {}, null, 20000);
}
async function tgSend(c, text, silent) {
  const params = { chat_id: c.chatId, text, parse_mode: "HTML", disable_web_page_preview: true, disable_notification: !!silent };
  if (c.threadId) params.message_thread_id = c.threadId;
  const r = await tgCall(c.token, "sendMessage", params);
  if (r.json && r.json.ok) return { ok: true };
  return { ok: false, error: tgErr(r), fatal: r.status >= 400 && r.status < 500 && r.status !== 429 };
}
const TG_STATUS = { lastOk: 0, lastError: "", lastErrorAt: 0 };
const tgQueue = [];
let tgBusy = false;
function tgEnqueue(text) {
  tgQueue.push({ text, created: Date.now() });
  while (tgQueue.length > 50) tgQueue.shift();
}
async function tgFlush() {
  if (tgBusy) return;
  tgBusy = true;
  try {
    while (tgQueue.length) {
      const d = loadData();
      const c = tgConfig(d);
      if (!c.active) {
        tgQueue.length = 0;
        break;
      }
      const it = tgQueue[0];
      const r = await tgSend(c, it.text, isQuiet(c, tzName(d)));
      if (r.ok) {
        tgQueue.shift();
        TG_STATUS.lastOk = Date.now();
        TG_STATUS.lastError = "";
        continue;
      }
      if (TG_STATUS.lastError !== r.error) logActivity(null, "Notifikasi Telegram gagal", r.error);
      TG_STATUS.lastError = r.error;
      TG_STATUS.lastErrorAt = Date.now();
      console.error("Telegram gagal:", r.error);
      // Pesan yang ditolak permanen atau sudah lebih dari 1 jam dibuang; lainnya dicoba lagi nanti
      if (r.fatal || Date.now() - it.created > 3600 * 1000) {
        tgQueue.shift();
        continue;
      }
      break;
    }
  } finally {
    tgBusy = false;
  }
}
function siteLabel(s) {
  return `<b>${escHtml(s.name)}</b>${s.note ? ` <i>(${escHtml(s.note)})</i>` : ""}`;
}
function listLines(items, fn) {
  const max = 30;
  const lines = items.slice(0, max).map(fn);
  if (items.length > max) lines.push(`… dan ${items.length - max} router lainnya`);
  return lines.join("\n");
}
function msgDown(list, now, tz) {
  if (list.length === 1) {
    const x = list[0];
    return `🔴 <b>VPN TERPUTUS</b>\n${siteLabel(x.s)}\nPutus sejak ${fmtClock(x.since, tz, true)} (${fmtDur(now - x.since)})`;
  }
  return `🔴 <b>${list.length} VPN TERPUTUS</b>\n` + listLines(list, (x) => `• ${siteLabel(x.s)} — sejak ${fmtClock(x.since, tz)}`);
}
function msgUp(list) {
  if (list.length === 1) {
    const x = list[0];
    return `✅ <b>VPN TERSAMBUNG LAGI</b>\n${siteLabel(x.s)}\nSempat putus ${fmtDur(x.dur)}`;
  }
  return `✅ <b>${list.length} VPN TERSAMBUNG LAGI</b>\n` + listLines(list, (x) => `• ${siteLabel(x.s)} — putus ${fmtDur(x.dur)}`);
}
function msgRemind(list, now) {
  return `⏰ <b>MASIH TERPUTUS</b>\n` + listLines(list, (x) => `• ${siteLabel(x.s)} — sudah ${fmtDur(now - x.since)}`);
}

// =====================================================================
//  Pemantau: cek status VPN berkala -> riwayat + notifikasi
// =====================================================================
let monitorBusy = false;
let ztRefreshAt = 0;
async function monitorTick() {
  if (monitorBusy) return;
  monitorBusy = true;
  try {
    if (Date.now() - ztRefreshAt >= 5 * 60 * 1000) {
      ztRefreshAt = Date.now();
      if (ztCfg(loadData())) await ztRefresh(null).catch((e) => console.error("Pemeriksaan ZeroTier gagal:", e.message));
      await genieSync(loadData()).catch((e) => console.error("Sinkron rentang GenieACS gagal:", e.message));
    }
    await ztPingAll(loadData());
    if (wgCfg(loadData())) await wgPoll();
    const peers = await onlinePeers();
    // Mulai di sini semua sinkron (tidak ada await) supaya tidak menimpa perubahan dari panel
    const now = Date.now();
    const d = loadData();
    const h = loadHistory();
    const tz = tzName(d);
    const c = tgConfig(d);
    const delay = c.delayMin * MIN_MS;
    const remind = c.remindMin * MIN_MS;
    let dataChanged = false;
    const downList = [];
    const upList = [];
    const remindList = [];
    const ids = new Set();
    const links = linksSync(d, peers);
    for (const s of d.sites) {
      ids.add(s.id);
      const online = !!links[s.id];
      if (!s.installedAt) {
        // Belum pernah tersambung = menunggu pemasangan: tidak dicatat, tidak dikirim notifikasi
        if (!online) continue;
        s.installedAt = new Date(now).toISOString();
        dataChanged = true;
        logActivity(null, "Router tersambung pertama kali", s.name);
      }
      let r = h.sites[s.id];
      if (!r) {
        r = h.sites[s.id] = { state: online ? "up" : "down", since: now, events: [], alerted: false, lastRemind: 0 };
        if (!online) r.events.push({ s: now, e: null });
      } else if (online && r.state === "down") {
        const ev = r.events[r.events.length - 1];
        if (ev && ev.e == null) ev.e = now;
        if (r.alerted) upList.push({ s, dur: now - r.since });
        r.state = "up";
        r.since = now;
        r.alerted = false;
        r.lastRemind = 0;
      } else if (!online && r.state === "up") {
        r.state = "down";
        r.since = now;
        r.alerted = false;
        r.events.push({ s: now, e: null });
      }
      if (r.state === "down" && c.active) {
        if (!r.alerted && now - r.since >= delay) {
          downList.push({ s, since: r.since });
          r.alerted = true;
          r.lastRemind = now;
        } else if (r.alerted && remind > 0 && now - (r.lastRemind || r.since) >= remind) {
          remindList.push({ s, since: r.since });
          r.lastRemind = now;
        }
      }
    }
    for (const id of Object.keys(h.sites)) if (!ids.has(id)) delete h.sites[id];
    const cutoff = now - RETENTION_MS;
    for (const r of Object.values(h.sites)) r.events = (r.events || []).filter((e) => e.e == null || e.e >= cutoff);
    h.lastTick = now;
    writeJson(HISTORY_FILE, h);
    if (dataChanged) saveData(d);
    if (c.active) {
      if (downList.length) tgEnqueue(msgDown(downList, now, tz));
      if (upList.length && c.notifyRecovery) tgEnqueue(msgUp(upList));
      if (remindList.length) tgEnqueue(msgRemind(remindList, now));
    }
  } catch (e) {
    console.error("Pemantau gagal:", e.message);
  } finally {
    monitorBusy = false;
  }
  tgFlush();
}

// Baca grup & topik yang pernah dilihat bot (dari getUpdates)
async function tgDetect(token) {
  const me = await tgCall(token, "getMe", {});
  if (!(me.json && me.json.ok)) return { error: tgErr(me) };
  const up = await tgCall(token, "getUpdates", { limit: 100, timeout: 0 });
  if (!(up.json && up.json.ok)) return { error: tgErr(up), webhook: up.status === 409 && /webhook/i.test((up.json && up.json.description) || "") };
  const chats = new Map();
  const gone = new Set();
  for (const u of up.json.result || []) {
    const m = u.message || u.edited_message;
    const cm = u.my_chat_member;
    const chat = (m && m.chat) || (cm && cm.chat);
    if (!chat || !["group", "supergroup"].includes(chat.type)) continue;
    const id = String(chat.id);
    if (m && m.migrate_to_chat_id) gone.add(id);
    let c = chats.get(id);
    if (!c) {
      c = { id, title: chat.title || id, isForum: !!chat.is_forum, topics: new Map(), removed: false };
      chats.set(id, c);
    }
    c.title = chat.title || c.title;
    if (chat.is_forum) c.isForum = true;
    if (cm) c.removed = ["left", "kicked"].includes(cm.new_chat_member && cm.new_chat_member.status);
    else if (m) c.removed = false;
    if (m && m.is_topic_message && m.message_thread_id) {
      const tid = m.message_thread_id;
      const nm =
        (m.forum_topic_created && m.forum_topic_created.name) ||
        (m.forum_topic_edited && m.forum_topic_edited.name) ||
        (m.reply_to_message && m.reply_to_message.forum_topic_created && m.reply_to_message.forum_topic_created.name) ||
        "";
      if (nm || !c.topics.has(tid)) c.topics.set(tid, nm || c.topics.get(tid) || `Topik #${tid}`);
    }
  }
  const list = [];
  for (const c of chats.values()) {
    if (gone.has(c.id) || c.removed) continue;
    list.push({ id: c.id, title: c.title, isForum: c.isForum, topics: Array.from(c.topics, ([id, name]) => ({ id, name })) });
  }
  return { bot: { username: me.json.result.username, name: me.json.result.first_name }, chats: list };
}

// =====================================================================
//  Cloudflare DNS + HTTPS (bertahap, gagal = dibatalkan)
// =====================================================================
function isHostname(v) {
  return /^(?=.{1,253}$)([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$/.test(v);
}
function certPaths(domain) {
  const base = `${LE_LIVE}/${domain}`;
  return { cert: `${base}/fullchain.pem`, key: `${base}/privkey.pem` };
}
function certExpiry(domain) {
  try {
    const x = new crypto.X509Certificate(fs.readFileSync(certPaths(domain).cert));
    return Date.parse(x.validTo);
  } catch (e) {
    return null;
  }
}
let CF_JOB = null;
function cfSteps(withHttps) {
  const s = [
    { key: "token", label: "Cek token", desc: "Token Cloudflare valid dan aktif" },
    { key: "zone", label: "Cek domain", desc: "Domain terdaftar dan aktif di akun Cloudflare" },
    { key: "perm", label: "Cek izin DNS", desc: "Token boleh membaca DNS domain ini" },
    { key: "ip", label: "IP publik VPS", desc: "Mendeteksi IP publik VPS ini" },
    { key: "dns", label: "Record DNS", desc: "Membuat / memperbarui record A (DNS only, awan abu-abu)" },
    { key: "resolve", label: "Cek ulang domain", desc: "Domain sudah mengarah ke IP VPS" },
  ];
  if (withHttps) s.push({ key: "cert", label: "Sertifikat HTTPS", desc: "Menerbitkan sertifikat Let's Encrypt (bisa 1–2 menit)" });
  s.push({ key: "apply", label: "Terapkan", desc: withHttps ? "Alamat VPS diganti ke domain dan panel pindah ke HTTPS" : "Alamat VPS diganti ke domain" });
  return s;
}
async function cfApi(job, method, p, body) {
  const r = await httpJson(method, CF_API + p, body, { Authorization: "Bearer " + job.token }, 20000);
  const j = r.json || {};
  return { ok: !!j.success, result: j.result, errors: j.errors || [], status: r.status, error: r.error };
}
function cfErr(r) {
  if (r.status === 0) return `VPS tidak bisa menghubungi Cloudflare (${r.error}).`;
  const e = (r.errors || []).map((x) => (x.code ? `${x.message} [${x.code}]` : x.message)).join("; ");
  return e || `HTTP ${r.status}`;
}
function cfPermErr(r) {
  return r.status === 403 || (r.errors || []).some((x) => [10000, 9109, 1000].includes(x.code));
}
async function dohLookup(domain) {
  const r = await httpJson("GET", `${DOH_URL}?name=${encodeURIComponent(domain)}&type=A`, null, { Accept: "application/dns-json" }, 10000);
  const ans = ((r.json && r.json.Answer) || []).filter((a) => a.type === 1).map((a) => a.data);
  return { ok: r.status === 200, ips: ans, error: r.error };
}
async function cfRunStep(job, key) {
  const c = job.ctx;
  if (key === "token") {
    const r = await cfApi(job, "GET", "/user/tokens/verify");
    if (r.ok) {
      if (r.result && r.result.status !== "active") return { ok: false, detail: `Token tidak aktif (status: ${r.result.status})`, hint: "Aktifkan token di Cloudflare → My Profile → API Tokens, atau buat token baru." };
      return { ok: true, detail: "Token aktif" };
    }
    // Token milik akun (bukan profil) tidak bisa dicek di /user; coba langsung baca zona
    const z = await cfApi(job, "GET", "/zones?per_page=1");
    if (z.ok) return { ok: true, detail: "Token valid" };
    return {
      ok: false,
      detail: "Token ditolak Cloudflare: " + cfErr(r),
      hint: 'Buat token di Cloudflare → My Profile → API Tokens → Create Token → template "Edit zone DNS" → tambahkan izin Zone → Zone → Read → Zone Resources: pilih domain Anda. Salin token-nya (bukan Global API Key).',
    };
  }
  if (key === "zone") {
    const labels = job.domain.split(".");
    let zone = null;
    let lastErr = null;
    for (let i = 0; i <= labels.length - 2 && !zone; i++) {
      const name = labels.slice(i).join(".");
      const r = await cfApi(job, "GET", `/zones?name=${encodeURIComponent(name)}`);
      if (r.ok && Array.isArray(r.result) && r.result.length) zone = r.result[0];
      else if (!r.ok) lastErr = r;
    }
    if (!zone)
      return {
        ok: false,
        detail: lastErr && cfPermErr(lastErr) ? `Token tidak boleh membaca domain ini (${cfErr(lastErr)})` : "Domain tidak ditemukan di akun Cloudflare ini",
        hint: "Edit token di Cloudflare: Permissions harus berisi Zone → Zone → Read dan Zone → DNS → Edit, dan Zone Resources → Include → Specific zone → domain Anda. Klik Update token, tunggu 1 menit, lalu coba lagi.",
      };
    if (zone.status !== "active")
      return { ok: false, detail: `Domain belum aktif di Cloudflare (status: ${zone.status})`, hint: "Ganti nameserver domain (di tempat Anda membeli domain) ke nameserver Cloudflare, lalu tunggu sampai statusnya Active." };
    c.zone = { id: zone.id, name: zone.name };
    return { ok: true, detail: `Zona ${zone.name} aktif` };
  }
  if (key === "perm") {
    const r = await cfApi(job, "GET", `/zones/${c.zone.id}/dns_records?name=${encodeURIComponent(job.domain)}&per_page=100`);
    if (!r.ok)
      return {
        ok: false,
        detail: cfPermErr(r) ? "Token tidak punya izin DNS untuk domain ini" : "Gagal membaca DNS: " + cfErr(r),
        hint: "Edit token di Cloudflare: Permissions → Zone → DNS → Edit, untuk domain ini.",
      };
    c.records = r.result || [];
    return { ok: true, detail: c.records.length ? `Bisa membaca DNS · ${c.records.length} record untuk ${job.domain}` : `Bisa membaca DNS · ${job.domain} belum punya record` };
  }
  if (key === "ip") {
    const r = await httpJson("GET", IP_TRACE, null, { Accept: "text/plain" }, 10000);
    const m = (r.text || "").match(/^ip=(\d+\.\d+\.\d+\.\d+)$/m);
    let ip = m ? m[1] : "";
    if (!ip) ip = detectPublicIp();
    if (!ip) return { ok: false, detail: "IP publik VPS tidak terdeteksi", hint: "Pastikan VPS terhubung ke internet." };
    c.ip = ip;
    return { ok: true, detail: `IP VPS: ${ip}` };
  }
  if (key === "dns") {
    const recs = c.records || [];
    const cname = recs.find((x) => x.type === "CNAME");
    if (cname) return { ok: false, detail: `Sudah ada record CNAME untuk ${job.domain}`, hint: "Hapus record CNAME itu di dashboard Cloudflare, atau pakai subdomain lain." };
    const as = recs.filter((x) => x.type === "A");
    if (as.length > 1) return { ok: false, detail: `Ada ${as.length} record A untuk ${job.domain}`, hint: "Sisakan satu record A saja di dashboard Cloudflare, atau pakai subdomain lain." };
    const warn = recs.some((x) => x.type === "AAAA") ? " · Perhatian: ada record AAAA, pastikan juga mengarah ke VPS ini" : "";
    const permHint = "Edit token di Cloudflare: Permissions → Zone → DNS → Edit.";
    if (as.length === 1) {
      const a = as[0];
      c.recordId = a.id;
      if (a.content === c.ip && !a.proxied) return { ok: true, detail: `Record A sudah benar (${job.domain} → ${c.ip}), tidak diubah` + warn };
      const r = await cfApi(job, "PATCH", `/zones/${c.zone.id}/dns_records/${a.id}`, { content: c.ip, proxied: false });
      if (!r.ok) return { ok: false, detail: (cfPermErr(r) ? "Token tidak punya izin mengubah DNS" : "Gagal memperbarui record: ") + (cfPermErr(r) ? "" : cfErr(r)), hint: permHint };
      c.prev = { id: a.id, content: a.content, proxied: !!a.proxied };
      return { ok: true, detail: `Record A diperbarui: ${a.content}${a.proxied ? " (proxied)" : ""} → ${c.ip} (DNS only)` + warn };
    }
    const r = await cfApi(job, "POST", `/zones/${c.zone.id}/dns_records`, { type: "A", name: job.domain, content: c.ip, ttl: 1, proxied: false });
    if (!r.ok) return { ok: false, detail: (cfPermErr(r) ? "Token tidak punya izin mengubah DNS" : "Gagal membuat record: ") + (cfPermErr(r) ? "" : cfErr(r)), hint: permHint };
    c.created = r.result.id;
    c.recordId = r.result.id;
    return { ok: true, detail: `Record A dibuat: ${job.domain} → ${c.ip} (DNS only)` + warn };
  }
  if (key === "resolve") {
    const until = Date.now() + 30000;
    let last = null;
    while (Date.now() < until) {
      last = await dohLookup(job.domain);
      if (last.ips.includes(c.ip)) return { ok: true, detail: `${job.domain} → ${c.ip}` };
      await new Promise((z) => setTimeout(z, 3000));
    }
    return {
      ok: false,
      detail: last && last.ips.length ? `${job.domain} masih mengarah ke ${last.ips.join(", ")}` : `${job.domain} belum bisa ditemukan di DNS`,
      hint: "DNS belum menyebar. Tunggu beberapa menit lalu coba lagi.",
    };
  }
  if (key === "cert") {
    const v = await run("certbot", ["--version"]);
    if (v.code === -2) return { ok: false, detail: "certbot belum terpasang di VPS", hint: "Jalankan ulang: cd /root/acs-netmap-panel && git pull && bash install-vpn-acs.sh" };
    try {
      c.prevIni = fs.existsSync(CF_INI) ? fs.readFileSync(CF_INI, "utf8") : null;
      fs.mkdirSync(path.dirname(CF_INI), { recursive: true });
      fs.writeFileSync(CF_INI, `dns_cloudflare_api_token = ${job.token}\n`, { mode: 0o600 });
      fs.chmodSync(CF_INI, 0o600);
      c.iniWritten = true;
    } catch (e) {
      return { ok: false, detail: "Gagal menulis berkas token: " + e.message };
    }
    const r = await run(
      "certbot",
      ["certonly", "--non-interactive", "--agree-tos", "--register-unsafely-without-email", "--keep-until-expiring", "--dns-cloudflare", "--dns-cloudflare-credentials", CF_INI, "--dns-cloudflare-propagation-seconds", "30", "--cert-name", job.domain, "-d", job.domain],
      300000,
    );
    if (r.code !== 0) {
      const tail = r.out.trim().split("\n").filter(Boolean).slice(-3).join(" ").slice(0, 300);
      return { ok: false, detail: "Sertifikat gagal terbit" + (tail ? `: ${tail}` : ""), hint: "Pastikan token punya izin DNS Edit. Let's Encrypt membatasi 5 kali gagal per jam, jadi tunggu sebentar sebelum mencoba lagi." };
    }
    try {
      const p = certPaths(job.domain);
      tls.createSecureContext({ cert: fs.readFileSync(p.cert), key: fs.readFileSync(p.key) });
    } catch (e) {
      return { ok: false, detail: "Berkas sertifikat tidak bisa dibaca: " + e.message };
    }
    const exp = certExpiry(job.domain);
    return { ok: true, detail: exp ? `Sertifikat berlaku sampai ${fmtClock(exp, job.tz, true)}, diperpanjang otomatis` : "Sertifikat terbit" };
  }
  if (key === "apply") {
    const d = loadData();
    d.settings = d.settings || {};
    const s = d.settings;
    const before = s.publicIp || "";
    if (!s.cloudflare) s.publicIpBeforeCf = before;
    const hadHttps = !!(s.cloudflare && s.cloudflare.https);
    s.publicIp = job.domain;
    s.cloudflare = { domain: job.domain, zoneId: c.zone.id, zoneName: c.zone.name, recordId: c.recordId, ip: c.ip, https: job.https, token: job.token, appliedAt: new Date().toISOString() };
    if (job.https) {
      try {
        await httpsEnable(job.domain);
      } catch (e) {
        return { ok: false, detail: "Panel gagal memakai sertifikat: " + e.message };
      }
    } else if (hadHttps) httpsDisable();
    saveData(d);
    return {
      ok: true,
      detail: `Alamat VPS sekarang ${job.domain}` + (job.https ? ` · Panel: https://${job.domain}:${PORT}` : ""),
      url: job.https ? `https://${job.domain}:${PORT}/` : null,
    };
  }
  return { ok: null, detail: "Langkah tidak dikenal" };
}
async function cfRollback(job) {
  const c = job.ctx;
  const notes = [];
  try {
    if (c.created) {
      const r = await cfApi(job, "DELETE", `/zones/${c.zone.id}/dns_records/${c.created}`);
      notes.push(r.ok ? "record DNS yang baru dibuat sudah dihapus" : "record DNS gagal dihapus otomatis, hapus manual di Cloudflare");
    } else if (c.prev) {
      const r = await cfApi(job, "PATCH", `/zones/${c.zone.id}/dns_records/${c.prev.id}`, { content: c.prev.content, proxied: c.prev.proxied });
      notes.push(r.ok ? "record DNS dikembalikan seperti semula" : "record DNS gagal dikembalikan otomatis, cek di Cloudflare");
    }
  } catch (e) {
    notes.push("pembatalan DNS gagal: " + e.message);
  }
  try {
    if (c.iniWritten) {
      if (c.prevIni == null) fs.unlinkSync(CF_INI);
      else fs.writeFileSync(CF_INI, c.prevIni, { mode: 0o600 });
    }
  } catch (e) {
    // abaikan
  }
  job.done = true;
  return notes;
}

// ---------- Subdomain layanan (GenieACS + aplikasi add-on yang terpasang) ----------
const SUB_DEF = { "panel-acs": "ont", bilingku: "billing" };
function subServices(d) {
  d = d || loadData();
  const out = { acs: { label: "GenieACS", port: () => readGenieUiPort() || 3000, def: "acs", stdOnly: false } };
  for (const [id, a] of Object.entries(ADDONS)) {
    if (a.kind !== "aplikasi" || !addonInstalled(d, id)) continue;
    // Aplikasi hanya mendengar di 127.0.0.1, jadi subdomainnya dilayani panel lewat port web (80/443)
    out[id] = { label: a.name, port: () => a.port, def: SUB_DEF[id] || id, stdOnly: true, addon: true };
  }
  return out;
}
// Alamat aplikasi add-on: subdomain sendiri bila diatur, selain itu path di alamat panel
function addonUrl(d, id) {
  const x = ((d.settings || {}).subdomains || {})[id];
  if (x && x.host && STD_ON) return subUrl(id, x.host);
  return "";
}
function subUrl(svc, host) {
  if (STD_ON && HTTPS_ON) return `https://${host}${portSfx("https")}`;
  if (STD_ON) return `http://${host}${portSfx("http")}`;
  const S = subServices()[svc];
  return S && !S.stdOnly ? `http://${host}:${S.port()}` : `http://${host}`;
}
// Buat / perbarui record A (DNS only) untuk satu nama host
async function cfUpsertA(job, host, ip) {
  const zone = job.ctx.zone;
  const r0 = await cfApi(job, "GET", `/zones/${zone.id}/dns_records?name=${encodeURIComponent(host)}&per_page=100`);
  if (!r0.ok) return { ok: false, detail: "Gagal membaca DNS: " + cfErr(r0), hint: "Pastikan token masih punya izin Zone → DNS → Edit." };
  const recs = r0.result || [];
  if (recs.find((x) => x.type === "CNAME")) return { ok: false, detail: `Sudah ada record CNAME untuk ${host}`, hint: "Hapus record CNAME itu di Cloudflare, atau pakai nama subdomain lain." };
  const as = recs.filter((x) => x.type === "A");
  if (as.length > 1) return { ok: false, detail: `Ada ${as.length} record A untuk ${host}`, hint: "Sisakan satu record A di Cloudflare, atau pakai nama subdomain lain." };
  if (as.length === 1) {
    const a = as[0];
    if (a.content === ip && !a.proxied) return { ok: true, detail: `${host} sudah mengarah ke ${ip}, tidak diubah`, recordId: a.id };
    const r = await cfApi(job, "PATCH", `/zones/${zone.id}/dns_records/${a.id}`, { content: ip, proxied: false });
    if (!r.ok) return { ok: false, detail: "Gagal memperbarui record: " + cfErr(r), hint: "Pastikan token punya izin Zone → DNS → Edit." };
    return { ok: true, detail: `Record A diperbarui: ${host} → ${ip} (DNS only)`, recordId: a.id, prev: { id: a.id, content: a.content, proxied: !!a.proxied } };
  }
  const r = await cfApi(job, "POST", `/zones/${zone.id}/dns_records`, { type: "A", name: host, content: ip, ttl: 1, proxied: false });
  if (!r.ok) return { ok: false, detail: "Gagal membuat record: " + cfErr(r), hint: "Pastikan token punya izin Zone → DNS → Edit." };
  return { ok: true, detail: `Record A dibuat: ${host} → ${ip} (DNS only)`, recordId: r.result.id, created: r.result.id };
}
function cfSubSteps(subs) {
  const SUB_SERVICES = subServices();
  const steps = [
    { key: "token", label: "Cek token", desc: "Token Cloudflare yang tersimpan masih aktif" },
    { key: "ip", label: "IP publik VPS", desc: "Mendeteksi IP publik VPS ini" },
  ];
  for (const svc of Object.keys(SUB_SERVICES)) {
    const host = subs[svc];
    if (!host) continue;
    const L = SUB_SERVICES[svc].label;
    steps.push({ key: "sdns:" + svc, label: `Record ${L}`, desc: `Membuat / memperbarui ${host} (DNS only)` });
    steps.push({ key: "sres:" + svc, label: `Cek ${host}`, desc: `${host} sudah mengarah ke IP VPS` });
  }
  steps.push({ key: "scert", label: "Sertifikat HTTPS", desc: "Sertifikat mencakup semua subdomain (bila HTTPS aktif)" });
  steps.push({ key: "sapply", label: "Terapkan", desc: "Link di dashboard memakai subdomain baru" });
  return steps;
}
async function cfRunSubStep(job, key) {
  const c = job.ctx;
  if (key === "token" || key === "ip") return cfRunStep(job, key);
  if (key.startsWith("sdns:")) {
    const svc = key.slice(5);
    const r = await cfUpsertA(job, job.subs[svc], c.ip);
    c.subRes = c.subRes || {};
    c.subRes[svc] = r;
    return r;
  }
  if (key.startsWith("sres:")) {
    const host = job.subs[key.slice(5)];
    const until = Date.now() + 30000;
    let last = null;
    while (Date.now() < until) {
      last = await dohLookup(host);
      if (last.ips.includes(c.ip)) return { ok: true, detail: `${host} → ${c.ip}` };
      await new Promise((z) => setTimeout(z, 3000));
    }
    return { ok: false, detail: last && last.ips.length ? `${host} masih mengarah ke ${last.ips.join(", ")}` : `${host} belum bisa ditemukan di DNS`, hint: "DNS belum menyebar. Tunggu beberapa menit lalu coba lagi." };
  }
  if (key === "scert") {
    const d = loadData();
    const cf = d.settings.cloudflare;
    const hosts = Object.values(job.subs).filter(Boolean);
    if (!(cf && cf.https && HTTPS_ON) || !hosts.length) return { ok: null, detail: "Dilewati: panel tidak memakai HTTPS" };
    const r = await certExpand(cf.domain, hosts);
    if (r.error) return { ok: false, detail: r.error, hint: "Coba lagi beberapa menit lagi." };
    return { ok: true, detail: `Sertifikat mencakup ${[cf.domain].concat(hosts).join(", ")}` };
  }
  if (key === "sapply") {
    const d = loadData();
    const SUB_SERVICES = subServices(d);
    const s = (d.settings = d.settings || {});
    const old = s.subdomains || {};
    const next = {};
    const notes = [];
    for (const svc of Object.keys(SUB_SERVICES)) {
      const host = job.subs[svc];
      const prev = old[svc];
      if (host) {
        const r = (c.subRes || {})[svc] || {};
        const sameHost = prev && prev.host === host;
        next[svc] = { host, recordId: r.recordId || (prev && prev.recordId) || "", created: !!r.created || !!(sameHost && prev.created) };
        if (svc === "acs") s.genieUrl = subUrl(svc, host);
        notes.push(`${SUB_SERVICES[svc].label}: ${subUrl(svc, host)}`);
      } else if (prev) {
        if (svc === "acs" && s.genieUrl === subUrl(svc, prev.host)) s.genieUrl = "";
        notes.push(`${SUB_SERVICES[svc].label}: subdomain dimatikan`);
      }
      // Record lama buatan panel yang tidak dipakai lagi dihapus
      if (prev && prev.created && prev.recordId && prev.host !== host) {
        const del = await cfApi(job, "DELETE", `/zones/${c.zone.id}/dns_records/${prev.recordId}`);
        notes.push(del.ok ? `record ${prev.host} dihapus` : `record ${prev.host} gagal dihapus (hapus manual di Cloudflare)`);
      }
    }
    s.subdomains = next;
    saveData(d);
    return { ok: true, detail: notes.join(" · ") };
  }
  return { ok: null, detail: "Langkah tidak dikenal" };
}
async function cfRollbackSub(job) {
  const c = job.ctx;
  const notes = [];
  for (const r of Object.values(c.subRes || {})) {
    try {
      if (r.created) {
        const x = await cfApi(job, "DELETE", `/zones/${c.zone.id}/dns_records/${r.created}`);
        notes.push(x.ok ? "record baru dihapus lagi" : "record baru gagal dihapus, cek di Cloudflare");
      } else if (r.prev) {
        const x = await cfApi(job, "PATCH", `/zones/${c.zone.id}/dns_records/${r.prev.id}`, { content: r.prev.content, proxied: r.prev.proxied });
        notes.push(x.ok ? "record dikembalikan" : "record gagal dikembalikan, cek di Cloudflare");
      }
    } catch (e) {
      notes.push("pembatalan DNS gagal: " + e.message);
    }
  }
  job.done = true;
  return notes;
}

// =====================================================================
//  Pembaruan: panel (repo GitHub) dan add-on (git / apt)
// =====================================================================
const UPDATE_REPO = process.env.VPNACS_UPDATE_REPO || "suwazed-cmyk/acs-netmap-panel";
const UPDATE_RAW = process.env.VPNACS_UPDATE_RAW || `https://raw.githubusercontent.com/${UPDATE_REPO}/main/panel/server.js`;
const SOURCE_DIR_FILE = path.dirname(DATA_FILE) + "/source-dir";
const UPDATE_FILE = path.dirname(DATA_FILE) + "/update-cache.json";
let UPDATES = null;
try {
  UPDATES = JSON.parse(fs.readFileSync(UPDATE_FILE, "utf8"));
} catch (e) {
  UPDATES = null;
}
function verCmp(a, b) {
  const pa = String(a).split(".").map((x) => parseInt(x, 10) || 0), pb = String(b).split(".").map((x) => parseInt(x, 10) || 0);
  for (let i = 0; i < 3; i++) if ((pa[i] || 0) !== (pb[i] || 0)) return (pa[i] || 0) > (pb[i] || 0) ? 1 : -1;
  return 0;
}
// Folder repo tempat installer dijalankan (ditulis install-vpn-acs.sh)
function sourceDir() {
  try {
    const d = fs.readFileSync(SOURCE_DIR_FILE, "utf8").trim();
    return d && fs.existsSync(d + "/install-vpn-acs.sh") ? d : "";
  } catch (e) {
    return "";
  }
}
async function checkPanelUpdate() {
  const out = { current: VERSION, latest: "", available: false, error: "", notes: "", date: "" };
  // raw.githubusercontent.com menyimpan salinan /main sampai ±5 menit. Ambil dulu commit terbaru lewat API,
  // lalu baca berkas pada commit itu (alamatnya unik per commit, jadi selalu versi terbaru).
  let rawUrl = UPDATE_RAW;
  let commit = null;
  if (!process.env.VPNACS_UPDATE_RAW) {
    const c = await httpJson("GET", `https://api.github.com/repos/${UPDATE_REPO}/commits/main`, null, { Accept: "application/vnd.github+json" }, 15000);
    if (c.json && c.json.sha) {
      commit = c.json;
      rawUrl = `https://raw.githubusercontent.com/${UPDATE_REPO}/${c.json.sha}/panel/server.js`;
    }
  }
  const r = await httpJson("GET", rawUrl, null, { Range: "bytes=0-6000", Accept: "text/plain" }, 15000);
  const m = r.text && r.text.match(/const VERSION = "([\d.]+)"/);
  if (!m) {
    out.error = r.status ? `GitHub menjawab HTTP ${r.status}` : `Tidak bisa menghubungi GitHub (${r.error || "?"})`;
    return out;
  }
  out.latest = m[1];
  out.available = verCmp(out.latest, VERSION) > 0;
  if (out.available) {
    const c = commit ? { json: commit } : await httpJson("GET", `https://api.github.com/repos/${UPDATE_REPO}/commits/main`, null, {}, 15000);
    if (c.json && c.json.commit) {
      out.notes = String(c.json.commit.message || "").split("\n")[0].slice(0, 160);
      out.date = (c.json.commit.committer && c.json.commit.committer.date) || "";
    }
  }
  return out;
}
async function checkAddonUpdate(id) {
  const a = ADDONS[id];
  if (a.kind === "aplikasi") {
    const dir = addonDir(id);
    if (!fs.existsSync(dir + "/.git")) return { available: false };
    const f = await run("git", ["-C", dir, "fetch", "-q", "origin"], 30000);
    if (f.code !== 0) return { available: false, error: "git fetch gagal" };
    const n = await run("git", ["-C", dir, "rev-list", "--count", "HEAD..@{u}"]);
    const behind = parseInt(n.out.trim(), 10) || 0;
    const cur = (await run("git", ["-C", dir, "log", "-1", "--format=%h %cs"])).out.trim();
    if (!behind) return { available: false, current: cur };
    const up = (await run("git", ["-C", dir, "log", "-1", "--format=%h %cs|%s", "@{u}"])).out.trim().split("|");
    return { available: true, behind, current: cur, latest: up[0] || "", notes: (up[1] || "").slice(0, 160) };
  }
  // Add-on sistem: versi paket terpasang vs versi yang tersedia di apt
  const pol = await run("apt-cache", ["policy", id === "wireguard" ? "wireguard-tools" : "zerotier-one"]);
  const inst = (pol.out.match(/Installed:\s*(\S+)/) || [])[1] || "";
  const cand = (pol.out.match(/Candidate:\s*(\S+)/) || [])[1] || "";
  if (!inst || inst === "(none)" || !cand || cand === "(none)") return { available: false };
  return { available: inst !== cand, current: inst, latest: cand };
}
async function checkUpdates() {
  const d = loadData();
  const out = { checkedAt: Date.now(), panel: await checkPanelUpdate(), addons: {} };
  for (const id of Object.keys(ADDONS)) {
    if (!addonInstalled(d, id)) continue;
    try {
      out.addons[id] = await checkAddonUpdate(id);
    } catch (e) {
      out.addons[id] = { available: false, error: e.message };
    }
  }
  UPDATES = out;
  try {
    fs.writeFileSync(UPDATE_FILE, JSON.stringify(out));
  } catch (e) {
    // abaikan
  }
  return out;
}
function updateSummary() {
  const U = UPDATES || {};
  const addons = Object.entries(U.addons || {}).filter(([, x]) => x && x.available).map(([id]) => id);
  return { checkedAt: U.checkedAt || 0, panel: !!(U.panel && U.panel.available), latest: (U.panel && U.panel.latest) || "", addons };
}
// Perbarui panel: git pull di folder repo lalu jalankan ulang installer (panel ikut di-restart)
function selfUpdateSteps() {
  return [
    {
      label: "Periksa folder repo",
      run: async (job) => {
        const src = sourceDir();
        if (!src) return { error: "Folder repo tidak diketahui. Perbarui sekali lewat SSH: cd /root/acs-netmap-panel && git pull && bash install-vpn-acs.sh" };
        job.src = src;
        const st = await run("git", ["-C", src, "status", "--porcelain", "--untracked-files=no"]);
        if (st.out.trim()) jobLog("Berkas yang diubah manual di repo:\n" + st.out.trim());
        return { detail: src };
      },
    },
    {
      label: "Unduh versi terbaru",
      weight: 2,
      run: async (job) => {
        const src = job.src || sourceDir();
        const r = await runStream("git", ["-C", src, "pull", "--ff-only"], { timeoutMs: 5 * 60 * 1000 });
        if (r.code !== 0) return { error: `git pull gagal (lihat log). Jika ada berkas yang diubah manual, kembalikan dulu: cd ${src} && git checkout -- .` };
        const h = await run("git", ["-C", src, "log", "-1", "--format=%h %cs"]);
        return { detail: "Versi " + h.out.trim() };
      },
    },
    {
      label: "Pasang ulang panel",
      weight: 4,
      run: async (job) => {
        const src = job.src || sourceDir();
        // Panel ikut di-restart oleh installer; proses tetap jalan dan panel menyambung lagi setelah menyala
        const r = await runDetached(job, "selfupdate", `cd '${src.replace(/'/g, "")}' && bash install-vpn-acs.sh`, { timeoutMs: 20 * 60 * 1000 });
        if (r.code !== 0) return { error: "Installer gagal (lihat log)." };
        return { detail: "Installer selesai" };
      },
    },
    {
      label: "Selesai",
      run: async () => {
        await checkUpdates().catch(() => {});
        return { detail: `Panel versi ${VERSION}. Muat ulang halaman (Ctrl+F5).` };
      },
    },
  ];
}

// =====================================================================
//  HTTPS panel: satu port untuk http & https
//  - HTTPS aktif: koneksi TLS diteruskan ke router https internal,
//    permintaan http biasa diarahkan (301) ke https://domain:PORT
// =====================================================================
let httpsServer = null;
let httpsPort = 0;
let HTTPS_ON = false;
let HTTPS_DOMAIN = "";
let certMtime = 0;
const PROXY_IPS = new Map(); // port lokal proxy -> IP asli klien
function httpsEnable(domain) {
  return new Promise((resolve, reject) => {
    try {
      const p = certPaths(domain);
      const opts = { cert: fs.readFileSync(p.cert), key: fs.readFileSync(p.key) };
      certMtime = fs.statSync(p.cert).mtimeMs;
      if (httpsServer) {
        httpsServer.setSecureContext(opts);
        HTTPS_ON = true;
        HTTPS_DOMAIN = domain;
        return resolve();
      }
      httpsServer = https.createServer(opts, appHandler);
      httpsServer.on("upgrade", onUpgrade);
      httpsServer.on("error", reject);
      httpsServer.listen(0, "127.0.0.1", () => {
        httpsPort = httpsServer.address().port;
        HTTPS_ON = true;
        HTTPS_DOMAIN = domain;
        resolve();
      });
    } catch (e) {
      reject(e);
    }
  });
}
function httpsDisable() {
  HTTPS_ON = false;
}
function certReloadCheck() {
  if (!HTTPS_ON) return;
  try {
    const m = fs.statSync(certPaths(HTTPS_DOMAIN).cert).mtimeMs;
    if (m !== certMtime) {
      console.log("Sertifikat diperbarui, memuat ulang");
      httpsEnable(HTTPS_DOMAIN).catch((e) => console.error("Muat ulang sertifikat gagal:", e.message));
    }
  } catch (e) {
    // abaikan
  }
}
function frontHandler(sock) {
  sock.on("error", () => {});
  if (!HTTPS_ON) return httpServer.emit("connection", sock);
  // Permintaan dari dalam VPS sendiri (add-on, script cek) tidak dialihkan ke https
  const ra = String(sock.remoteAddress || "").replace(/^::ffff:/, "");
  if (ra === "127.0.0.1" || ra === "::1") return peekLocal(sock);
  sock.setTimeout(20000, () => sock.destroy());
  sock.once("data", (buf) => {
    sock.setTimeout(0);
    if (buf[0] !== 0x16) {
      const m = buf.toString("latin1").match(/^[A-Z]+ (\S+) HTTP/);
      const p = m && m[1].startsWith("/") ? m[1] : "/";
      // Laporan Node ID dari script MikroTik tetap dilayani lewat http biasa
      if (p.startsWith("/api/zt/join") || p.startsWith("/.well-known/acme-challenge/")) {
        sock.unshift(buf);
        return httpServer.emit("connection", sock);
      }
      const host = hostOf(buf.toString("latin1"));
      const base = STD_ON ? `https://${host && isOurHost(host) ? host : HTTPS_DOMAIN}${portSfx("https")}` : `https://${HTTPS_DOMAIN}:${PORT}`;
      sock.end(`HTTP/1.1 301 Moved Permanently\r\nLocation: ${base}${p}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n`);
      return;
    }
    pipeTls(sock, buf);
  });
}

// Koneksi lokal: TLS tetap diteruskan ke https, http biasa dilayani langsung
function peekLocal(sock) {
  sock.once("data", (buf) => {
    if (buf[0] === 0x16) return pipeTls(sock, buf);
    sock.unshift(buf);
    httpServer.emit("connection", sock);
  });
}

// =====================================================================
//  Add-on
//  - sistem   : ZeroTier (memasang zerotier-one di VPS, fitur ada di dalam panel)
//  - aplikasi : Panel ACS, Bilingku (aplikasi PHP terpisah dari repo sendiri,
//               berjalan di 127.0.0.1 dan dibuka lewat path panel, mis. /acs)
// =====================================================================
const ADDON_ROOT = ROOT + "/opt/addons";
const SCRIPTS_DIR = ROOT + "/opt/vpn-acs/scripts";
const SYSTEMD_DIR = ROOT + "/etc/systemd/system";
const ADDONS = {
  zerotier: {
    kind: "sistem",
    name: "ZeroTier",
    icon: "hub",
    color: "amber",
    tagline: "Jalur VPN kedua untuk router RouterOS v7 ARM/ARM64, dikelola langsung dari panel.",
    features: ["Controller ZeroTier di VPS, tanpa web tambahan", "Buat jaringan, atur rentang IP, pool, dan DNS", "Setujui perangkat, ubah IP, beri nama, QR untuk HP", "Rute IP virtual router dibuat otomatis"],
    desc: "Router RouterOS v7 (ARM/ARM64) tersambung lewat ZeroTier selain L2TP. Memasang ZeroTier (controller) di VPS; jaringan, subnet, dan perangkat diatur langsung dari menu ZeroTier di panel.",
    note: "Ringan: hanya paket zerotier-one (±10 MB), terpasang dalam hitungan detik.",
  },
  wireguard: {
    kind: "sistem",
    name: "WireGuard",
    icon: "bolt",
    color: "violet",
    tagline: "Jalur VPN ketiga yang ringan dan cepat untuk semua router RouterOS v7.",
    features: ["Semua jenis RouterOS v7 (ARM, MIPS, x86)", "Kunci dibuat panel, script MikroTik tinggal tempel", "Status handshake, endpoint, dan data per router", "IP virtual, port forwarding, dan tes koneksi sama seperti L2TP"],
    desc: "Router RouterOS v7 tersambung ke VPS lewat WireGuard (UDP). Lebih ringan dan cepat dari L2TP, cocok untuk koneksi yang kurang stabil. Rentang IP, port, dan router diatur dari menu WireGuard di panel.",
    note: "Ringan: hanya paket wireguard-tools (modul WireGuard sudah ada di kernel Ubuntu 22.04).",
  },
  "panel-acs": {
    kind: "aplikasi",
    name: "Panel ACS",
    icon: "box",
    color: "blue",
    tagline: "Monitoring ONT dari GenieACS lengkap dengan history redaman.",
    features: ["ONT dikelompokkan otomatis per router (IP virtual)", "History redaman RX (grafik 24 jam–90 hari)", "Nama pelanggan & label lewat tag GenieACS", "Ubah WiFi, reboot, faults · Node.js, tanpa PHP"],
    desc: "Monitoring ONT dari GenieACS: dashboard, daftar & detail ONT, redaman RX dengan history grafik, ubah WiFi, reboot, faults. ONT dikelompokkan otomatis per router panel dari IP virtual; nama pelanggan dan label disimpan sebagai tag GenieACS. Berjalan dengan Node.js (tanpa PHP).",
    repo: process.env.VPNACS_REPO_PANEL_ACS || "https://github.com/suwazed-cmyk/panel-acs.git",
    port: 8091,
    path: "/acs",
    db: "data/panel-acs.db",
    nbi: true,
    timer: { unit: "collect", script: "bin/collect.php", every: "*:0/15", desc: "Pencatat redaman ONT" },
  },
  bilingku: {
    kind: "aplikasi",
    name: "Bilingku",
    icon: "wallet",
    color: "teal",
    tagline: "Billing PPPoE & Hotspot MikroTik: paket, tagihan, isolir, voucher.",
    features: ["Pelanggan PPPoE, paket, dan jatuh tempo", "Isolir otomatis & halaman pemberitahuan", "Voucher hotspot dan laporan penjualan", "Router dari panel (L2TP/ZeroTier/WireGuard) · Node.js, tanpa PHP"],
    desc: "Billing PPPoE & Hotspot MikroTik: paket, jatuh tempo, isolir otomatis, pembayaran, voucher, laporan. Router bisa diambil dari panel, API lewat VPN. Berjalan dengan Node.js (tanpa PHP); data versi PHP langsung terbaca.",
    repo: process.env.VPNACS_REPO_BILINGKU || "https://github.com/suwazed-cmyk/bilingku.git",
    port: 8092,
    path: "/billing",
    db: "data/bilingku.db",
  },
};
const RESERVED_PATHS = ["/api", "/index.html", "/.well-known"];
function addonState(d, id) {
  const a = ((d.settings || {}).addons || {})[id] || {};
  return a;
}
function addonInstalled(d, id) {
  return !!addonState(d, id).installed;
}
function addonPath(d, id) {
  return addonState(d, id).path || (ADDONS[id] && ADDONS[id].path) || "";
}
function addonDir(id) {
  return `${ADDON_ROOT}/${id}`;
}
function addonRoutes() {
  const d = loadData();
  const out = [];
  for (const [id, a] of Object.entries(ADDONS)) {
    if (a.kind !== "aplikasi" || !addonInstalled(d, id)) continue;
    out.push({ id, path: addonPath(d, id), port: a.port });
  }
  return out;
}
// Panel versi lama yang sudah memakai ZeroTier: add-on ZeroTier dianggap terpasang
function addonsMigrate(d) {
  d.settings = d.settings || {};
  const A = (d.settings.addons = d.settings.addons || {});
  let ch = false;
  if (!A.zerotier && (ztCfg(d) || d.sites.some(isZt) || fs.existsSync(ZTNET_DIR))) {
    A.zerotier = { installed: true, at: new Date().toISOString(), auto: true };
    ch = true;
  }
  if (!d.settings.addonKey) {
    d.settings.addonKey = crypto.randomBytes(24).toString("hex");
    ch = true;
  }
  return ch;
}
// Proses install/update/lepas berjalan di latar belakang; browser memantau lewat /api/addons/job
const JOB_FILE = path.dirname(DATA_FILE) + "/addon-job.json";
let ADDON_JOB = null;
function jobSave() {
  if (!ADDON_JOB) return;
  try {
    const j = Object.assign({}, ADDON_JOB);
    delete j.req;
    fs.writeFileSync(JOB_FILE + ".tmp", JSON.stringify(j));
    fs.renameSync(JOB_FILE + ".tmp", JOB_FILE);
  } catch (e) {
    // abaikan
  }
}
// Saat panel menyala: proses yang terputus ditandai gagal agar tidak terlihat macet
function jobRestore() {
  // log proses lama (lebih dari 7 hari) dibersihkan
  try {
    for (const f of fs.readdirSync(JOB_DIR)) {
      const fp = JOB_DIR + "/" + f;
      if (Date.now() - fs.statSync(fp).mtimeMs > 7 * 86400 * 1000) fs.unlinkSync(fp);
    }
  } catch (e) {
    // belum ada
  }
  try {
    const j = JSON.parse(fs.readFileSync(JOB_FILE, "utf8"));
    if (!j || !j.steps) return;
    if (!j.done && j.detached && ((ADDONS[j.addon] && (j.action === "install" || j.action === "update")) || j.action === "selfupdate")) {
      const ad = ADDONS[j.addon];
      const steps = j.action === "selfupdate" ? selfUpdateSteps() : ad.kind === "aplikasi" ? phpInstallSteps(j.addon, null, { update: j.action === "update" }) : sysSteps(j.addon, j.action);
      j.resume = true;
      j.log = (j.log || []).concat(["", "== Panel ter-restart, menyambung lagi ke proses yang berjalan"]);
      logActivity(null, `${j.title} dilanjutkan`, "Panel ter-restart, proses dilanjutkan");
      runJob(j, steps).catch((e) => {
        j.done = true;
        j.error = e.message;
      });
      return;
    }
    if (!j.done) {
      const i = Math.max(0, Math.min(j.cur || 0, j.steps.length - 1));
      j.steps[i].state = "bad";
      j.steps[i].detail = "Terputus";
      j.done = true;
      j.ok = false;
      j.interrupted = true;
      j.error = "Panel ter-restart saat proses berjalan (biasanya karena pembaruan paket sistem atau install ulang panel). Klik tombol yang sama lagi: langkah yang sudah selesai akan dilewati.";
      j.log = (j.log || []).concat(["", "== Panel ter-restart, proses terputus"]);
      j.finished = Date.now();
      logActivity(null, `${j.title} terputus`, "Panel ter-restart saat proses berjalan");
    }
    ADDON_JOB = j;
    jobSave();
  } catch (e) {
    // belum ada
  }
}
function jobLog(line) {
  if (!ADDON_JOB) return;
  const t = String(line).replace(/\x1b\[[0-9;?]*[A-Za-z]/g, "").replace(/[\r\b]/g, "").trimEnd();
  if (!t) return;
  // animasi putar installer ("[\]" "[|]" ...) tidak dicatat
  if (/^\s*\[[-|\\/]\]\s*$/.test(t)) return;
  ADDON_JOB.log.push(t);
  ADDON_JOB.lastOut = Date.now();
  if (ADDON_JOB.log.length > 400) ADDON_JOB.log.splice(0, ADDON_JOB.log.length - 400);
}
// Jalankan perintah, alirkan keluaran ke log. Baris "@@PROGRESS n" menggeser progres langkah.
function runStream(cmd, args, opts) {
  return new Promise((resolve) => {
    let p;
    try {
      p = spawn(cmd, args, Object.assign({ env: Object.assign({}, process.env, { DEBIAN_FRONTEND: "noninteractive", LC_ALL: "C.UTF-8", NEEDRESTART_SUSPEND: "1", NEEDRESTART_MODE: "l" }) }, opts || {}));
    } catch (e) {
      jobLog(e.message);
      return resolve({ code: -2 });
    }
    let buf = "";
    const onData = (chunk) => {
      buf += chunk.toString();
      const lines = buf.split("\n");
      buf = lines.pop();
      for (const l of lines) {
        const m = l.match(/@@PROGRESS\s+(\d+)(?:\s+(.*))?/);
        if (m && ADDON_JOB) {
          ADDON_JOB.sub = Math.min(100, parseInt(m[1], 10)) / 100;
          if (m[2]) ADDON_JOB.detail = m[2].trim();
        } else jobLog(l);
      }
    };
    p.stdout && p.stdout.on("data", onData);
    p.stderr && p.stderr.on("data", onData);
    const timer = opts && opts.timeoutMs ? setTimeout(() => { jobLog("Waktu habis, proses dihentikan."); p.kill("SIGKILL"); }, opts.timeoutMs) : null;
    p.on("error", (e) => jobLog(e.code === "ENOENT" ? `Perintah ${cmd} tidak ditemukan` : e.message));
    p.on("close", (code) => {
      if (timer) clearTimeout(timer);
      if (buf) jobLog(buf);
      resolve({ code: code === null ? 1 : code });
    });
  });
}
// needrestart (apt) jangan me-restart panel, VPN, GenieACS, dan add-on. Installer resmi ZTNET bahkan
// mengubah needrestart menjadi restart otomatis, sehingga panel ikut mati di tengah pemasangan.
const NEEDRESTART_CONF = ROOT + "/etc/needrestart/conf.d/vpn-acs.conf";
function needrestartGuard() {
  try {
    if (!fs.existsSync(path.dirname(path.dirname(NEEDRESTART_CONF)))) return;
    const re = ["vpn-acs", "xl2tpd", "(strongswan|ipsec)[^.]*", "genieacs-[^.]*", "addon-[^.]*", "vpnacs-job-[^.]*", "ztnet", "zerotier-one", "wg-quick@[^.]*", "postgresql[^.]*"];
    const text =
      "# Ditulis ACS NETMAP Panel: needrestart (apt) tidak memunculkan dialog dan tidak me-restart layanan otomatis,\n" +
      "# supaya pemasangan dari panel tidak tertahan dialog \"Pending kernel upgrade\" atau mematikan panel/VPN.\n" +
      "$nrconf{restart} = 'l';\n$nrconf{kernelhints} = 0;\n$nrconf{ucodehint} = 0;\n" +
      re.map((x) => `$nrconf{override_rc}->{qr(^${x}\\.service$)} = 0;`).join("\n") +
      "\n";
    writeIfChanged(NEEDRESTART_CONF, text);
  } catch (e) {
    console.error("needrestart:", e.message);
  }
}
// Jalankan perintah panjang sebagai layanan systemd terpisah: tetap berjalan walau panel di-restart,
// dan panel bisa menyambung lagi ke prosesnya. Keluaran ditulis ke berkas log lalu dibaca bertahap.
const JOB_DIR = path.dirname(DATA_FILE) + "/jobs";
// Dialog terminal (whiptail/dialog) yang muncul di dalam proses pemasangan tidak bisa dijawab dari panel.
// Pemberitahuan (msgbox, mis. "Pending kernel upgrade") ditutup otomatis; dialog lain dicatat di log.
const DIALOG_SEEN = new Set();
async function closeDialogs(unit) {
  const r = await run("pgrep", ["-x", "whiptail|dialog"]);
  for (const pid of r.out.split(/\s+/).filter(Boolean)) {
    let cg = "";
    let args = [];
    try {
      cg = fs.readFileSync(`/proc/${pid}/cgroup`, "utf8");
      args = fs.readFileSync(`/proc/${pid}/cmdline`, "utf8").split("\0");
    } catch (e) {
      continue;
    }
    if (!cg.includes(unit)) continue;
    const ti = args.indexOf("--title");
    const title = ti >= 0 ? args[ti + 1] : args.slice(1, 4).join(" ");
    if (args.includes("--msgbox")) {
      try {
        process.kill(parseInt(pid, 10), "SIGTERM");
        jobLog(`Pemberitahuan sistem "${title}" ditutup otomatis (seperti menekan OK).`);
      } catch (e) {
        // sudah selesai
      }
    } else if (!DIALOG_SEEN.has(pid)) {
      DIALOG_SEEN.add(pid);
      jobLog(`PERHATIAN: installer menunggu jawaban di dialog "${title}". Jawab lewat SSH atau hentikan dengan: pkill ${args[0].split("/").pop()}`);
      if (ADDON_JOB) ADDON_JOB.detail = `Menunggu jawaban dialog "${title}"`;
    }
  }
}
function runDetached(job, key, command, opts) {
  opts = opts || {};
  if (!process.env.VPNACS_FORCE_DETACH && (DRY_RUN || !fs.existsSync("/run/systemd/system"))) return runStream("bash", ["-c", command], opts);
  return new Promise((resolve) => {
    (async () => {
      const det = (job.detached = job.detached || {});
      let cur = det[key];
      const unitActive = async (u) => /^(active|activating|deactivating)$/.test((await run("systemctl", ["is-active", u])).out.trim());
      if (!cur || (!(await unitActive(cur.unit)) && !fs.existsSync(cur.log))) {
        fs.mkdirSync(JOB_DIR, { recursive: true });
        const unit = `vpnacs-job-${job.id}-${key}`;
        const log = `${JOB_DIR}/${unit}.log`;
        fs.writeFileSync(log, "");
        const wrapped = `(\n${command}\n)\nrc=$?\necho "@@EXIT $rc"`;
        const env = { DEBIAN_FRONTEND: "noninteractive", LC_ALL: "C.UTF-8", NEEDRESTART_SUSPEND: "1", NEEDRESTART_MODE: "l", TERM: "xterm", HOME: "/root", PATH: "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" };
        const args = ["--unit=" + unit, "--collect", "--quiet", "-p", "Nice=5", "-p", "OOMScoreAdjust=300", "-p", `StandardOutput=append:${log}`, "-p", `StandardError=append:${log}`];
        for (const [k, v] of Object.entries(env)) args.push("--setenv=" + k + "=" + v);
        if (opts.cwd) args.push("--working-directory=" + opts.cwd);
        args.push("/bin/bash", "-c", wrapped);
        const r = await run("systemd-run", args, 30000);
        if (r.code !== 0) {
          jobLog("systemd-run gagal: " + r.out.trim() + " — dijalankan langsung");
          return resolve(await runStream("bash", ["-c", command], opts));
        }
        cur = det[key] = { unit, log, offset: 0 };
        jobSave();
      } else jobLog(`Menyambung lagi ke proses ${cur.unit} yang masih berjalan`);
      const started = Date.now();
      let buf = "";
      let exit = null;
      let idle = 0;
      while (exit === null) {
        await new Promise((z) => setTimeout(z, 1000));
        let chunk = "";
        try {
          const fd = fs.openSync(cur.log, "r");
          const size = fs.fstatSync(fd).size;
          if (size > cur.offset) {
            const b = Buffer.alloc(Math.min(size - cur.offset, 1024 * 1024));
            fs.readSync(fd, b, 0, b.length, cur.offset);
            cur.offset += b.length;
            chunk = b.toString();
          }
          fs.closeSync(fd);
        } catch (e) {
          // berkas belum ada
        }
        if (chunk) {
          buf += chunk;
          const lines = buf.split(/\r?\n|\r/);
          buf = lines.pop();
          for (const l of lines) {
            const m = l.match(/@@PROGRESS\s+(\d+)(?:\s+(.*))?/);
            const e = l.match(/^@@EXIT (\d+)/);
            if (e) exit = parseInt(e[1], 10);
            else if (m && ADDON_JOB) {
              ADDON_JOB.sub = Math.min(100, parseInt(m[1], 10)) / 100;
              if (m[2]) ADDON_JOB.detail = m[2].trim();
            } else {
              jobLog(l);
              // pesan installer -> progres (hanya maju, tidak mundur)
              for (const [re, pct, text] of opts.map || []) {
                const mm = l.match(re);
                if (mm && ADDON_JOB) {
                  if (pct / 100 >= (ADDON_JOB.sub || 0)) ADDON_JOB.sub = pct / 100;
                  ADDON_JOB.detail = typeof text === "function" ? text(mm) : text;
                  break;
                }
              }
            }
          }
        }
        if (idle % 10 === 9) await closeDialogs(cur.unit);
        if (exit !== null) break;
        // proses sudah berhenti tanpa penanda keluar: anggap gagal
        if (++idle % 5 === 0 && !(await unitActive(cur.unit))) {
          await new Promise((z) => setTimeout(z, 1500));
          try {
            if (/@@EXIT (\d+)/.test(fs.readFileSync(cur.log, "utf8").slice(-200))) continue;
          } catch (e) {
            // abaikan
          }
          jobLog("Proses berhenti tanpa hasil (mungkin kehabisan memori). Cek: journalctl -u " + cur.unit);
          exit = 1;
        }
        if (opts.timeoutMs && Date.now() - started > opts.timeoutMs) {
          jobLog("Waktu habis, proses dihentikan.");
          await run("systemctl", ["stop", cur.unit]);
          exit = 1;
        }
      }
      if (buf && !/^@@EXIT/.test(buf)) jobLog(buf);
      resolve({ code: exit });
    })().catch((e) => {
      jobLog(e.message);
      resolve({ code: 1 });
    });
  });
}
async function runJob(job, steps) {
  ADDON_JOB = job;
  const resume = !!job.resume;
  delete job.resume;
  job.started = job.started || Date.now();
  job.lastOut = Date.now();
  const from = resume ? Math.max(0, Math.min(job.cur || 0, steps.length - 1)) : 0;
  const old = resume && Array.isArray(job.steps) ? job.steps : [];
  job.steps = steps.map((x, i) => (i < from && old[i] ? old[i] : { label: x.label, state: "wait", detail: "" }));
  const total = steps.reduce((a, x) => a + (x.weight || 1), 0);
  let doneW = steps.slice(0, from).reduce((a, x) => a + (x.weight || 1), 0);
  const tick = setInterval(() => {
    const cur = steps[job.cur] || { weight: 0 };
    job.pct = Math.min(99, Math.round(((doneW + (cur.weight || 1) * (job.sub || 0)) / total) * 100));
  }, 300);
  const saver = setInterval(jobSave, 2000);
  for (let i = from; i < steps.length; i++) {
    job.cur = i;
    job.sub = 0;
    job.detail = "";
    job.steps[i].state = "run";
    jobLog(`== ${steps[i].label}`);
    let r;
    try {
      r = await steps[i].run(job);
    } catch (e) {
      r = { error: e.message };
    }
    if (r && r.error) {
      job.steps[i].state = "bad";
      job.steps[i].detail = r.error;
      job.error = r.error;
      jobLog("GAGAL: " + r.error);
      break;
    }
    job.steps[i].state = r && r.skip ? "skip" : "ok";
    job.steps[i].detail = (r && r.detail) || "";
    doneW += steps[i].weight || 1;
  }
  clearInterval(tick);
  clearInterval(saver);
  job.done = true;
  job.ok = !job.error;
  job.pct = job.ok ? 100 : Math.round((doneW / total) * 100);
  job.finished = Date.now();
  logActivity(job.req || null, `${job.title} ${job.ok ? "berhasil" : "gagal"}`, job.ok ? "" : job.error);
  delete job.req;
  jobSave();
}
// ---------- Pemeriksaan add-on: apakah terpasang dan berjalan dengan benar ----------
function httpCode(opts) {
  return new Promise((resolve) => {
    const rq = http.request(Object.assign({ host: "127.0.0.1", method: "GET", timeout: 5000 }, opts), (r) => {
      r.resume();
      resolve(r.statusCode);
    });
    rq.on("error", () => resolve(0));
    rq.on("timeout", () => {
      rq.destroy();
      resolve(0);
    });
    rq.end();
  });
}
async function addonCheck(id) {
  const a = ADDONS[id];
  const d = loadData();
  const out = [];
  const add = (label, ok, detail, hint) => out.push({ label, ok, detail: detail || "", hint: hint || "" });
  if (id === "wireguard") {
    const v = await run("wg", ["--version"]);
    add("wireguard-tools", v.code === 0, v.code === 0 ? v.out.trim().split(" - ")[0] : "tidak ada", v.code === 0 ? "" : "apt-get install -y wireguard-tools");
    const sv = (await run("systemctl", ["is-active", `wg-quick@${WG_IFACE}`])).out.trim();
    add(`Layanan wg-quick@${WG_IFACE}`, sv === "active", sv || "tidak ada", sv === "active" ? "" : `journalctl -u wg-quick@${WG_IFACE} -n 30`);
    await wgPoll();
    const w = d.settings.wg || {};
    add("Interface " + WG_IFACE, WG_UP, WG_UP ? `${w.vpsIp || "-"} · UDP ${w.port || 51820}` : "tidak menyala", WG_UP ? "" : `systemctl restart wg-quick@${WG_IFACE}`);
    const n = d.sites.filter(isWg);
    const on = n.filter((s) => (WG_PEERS.get(s.wgPub) || {}).online).length;
    add("Router WireGuard", n.length ? on === n.length || null : null, n.length ? `${on} dari ${n.length} tersambung` : "Belum ada router memakai WireGuard", n.length && on < n.length ? `Pastikan port UDP ${w.port || 51820} terbuka di firewall provider VPS` : "");
    return out;
  }
  if (a.kind === "sistem") {
    const z1 = (await run("systemctl", ["is-active", "zerotier-one"])).out.trim();
    add("Layanan zerotier-one", z1 === "active", z1 || "tidak ada", z1 === "active" ? "" : "systemctl restart zerotier-one");
    const st = await ztApi("GET", "/status");
    add("API ZeroTier di VPS", !!st.ok, st.ok ? `Node ${st.json.address} · ${st.json.online ? "online" : "offline"}` : st.error, st.ok ? "" : "Cek: zerotier-cli info");
    if (st.ok && st.json && !st.json.online) out[out.length - 1].ok = null;
    const ctl = await ztApi("GET", "/controller/network");
    add("Controller jaringan", !!ctl.ok, ctl.ok ? `${(ctl.json || []).length} jaringan tersimpan` : ctl.error, ctl.ok ? "" : "systemctl restart zerotier-one");
    if (fs.existsSync(ZTNET_DIR)) add("ZTNET lama", null, "Masih terpasang dan tidak dipakai panel", "Menu ZeroTier → Pindahkan dari ZTNET");
    const zt = d.settings.zt || {};
    if (zt.nwid) {
      const n = await ztApi("GET", `/network/${zt.nwid}`);
      add("Jaringan terhubung", !!(n.ok && n.json && n.json.status === "OK"), n.ok ? `${zt.name || zt.nwid} · status ${n.json.status} · IP VPS ${(n.json.assignedAddresses || []).join(", ") || "-"}` : n.error, "Menu ZeroTier → Hubungkan VPS");
    } else add("Jaringan terhubung", null, "Belum ada jaringan yang dihubungkan", "Menu ZeroTier → Buat jaringan");
    return out;
  }
  const dir = addonDir(id);
  const isNode = isNodeApp(id);
  const okDir = fs.existsSync(dir + (isNode ? "/server.js" : "/index.php"));
  const ver = okDir ? (await run("git", ["-C", dir, "log", "-1", "--format=%h %cs"])).out.trim() : "";
  add("Berkas aplikasi", okDir, okDir ? `${dir}${ver ? " · versi " + ver : ""}${isNode ? " · Node.js" : " · PHP"}` : `${dir} tidak lengkap`, okDir ? "" : "Klik Perbarui atau Install ulang");
  let phpOk = false;
  if (isNode) {
    const nb = await addonNodeBin();
    const nv = nb ? (await run(nb, ["-v"])).out.trim() : "";
    add("Node.js untuk add-on", !!nb, nb ? `${nv} · ${nb}` : "Node.js 22.13+ tidak ditemukan", nb ? "" : "Klik Perbarui (Node 22 dipasang otomatis)");
  } else {
    const php = await run("php", ["-r", 'echo PHP_VERSION; foreach (["pdo_sqlite","curl","mbstring"] as $e) if (!extension_loaded($e)) echo " -", $e;']);
    phpOk = php.code === 0 && !/ -/.test(php.out);
    add("PHP", phpOk, php.code === 0 ? "PHP " + php.out.trim().replace(/ -/g, " kurang: ") : "PHP tidak ditemukan", phpOk ? "" : "apt-get install -y php-cli php-sqlite3 php-curl php-mbstring");
  }
  const svc = (await run("systemctl", ["is-active", `addon-${id}`])).out.trim();
  add(`Layanan addon-${id}`, svc === "active", svc || "tidak ada", svc === "active" ? "" : `journalctl -u addon-${id} -n 50`);
  if (a.timer && !isNode) {
    const t = (await run("systemctl", ["is-active", `addon-${id}-${a.timer.unit}.timer`])).out.trim();
    add(a.timer.desc || "Tugas berkala", t === "active", t === "active" ? `Berjalan (${a.timer.every})` : t || "tidak ada", t === "active" ? "" : `systemctl enable --now addon-${id}-${a.timer.unit}.timer`);
  }
  const c1 = await httpCode({ port: a.port, path: "/" });
  add(`Aplikasi menjawab (port ${a.port})`, c1 > 0 && c1 < 500, c1 ? `HTTP ${c1}` : "Tidak menjawab", c1 > 0 && c1 < 500 ? "" : `journalctl -u addon-${id} -n 50`);
  const pth = addonPath(d, id);
  const c2 = await httpCode({ port: a.port, path: "/", headers: { "X-Forwarded-Prefix": pth, "X-Forwarded-Proto": "http" } });
  const route = proxyPathTarget(pth + "/");
  const viaOk = !!route && c2 > 0 && c2 < 500;
  add(`Alamat ${pth}/ di panel`, viaOk, !route ? "Belum terdaftar di panel" : viaOk ? `Diteruskan ke port ${route.port}` : `Diteruskan ke port ${route.port}, tetapi aplikasi tidak menjawab`, !route ? "Klik Perbarui" : viaOk ? "" : `systemctl restart addon-${id}`);
  const w = await run("runuser", ["-u", "www-data", "--", "test", "-w", dir + "/data"]);
  add("Folder data bisa ditulis", w.code === 0, w.code === 0 ? dir + "/data" : "Tidak bisa ditulis oleh www-data", w.code === 0 ? "" : `chown -R www-data:www-data ${dir}/data`);
  if (a.db && !isNode) {
    const q = await run("runuser", ["-u", "www-data", "--", "php", "-r", '$p=new PDO("sqlite:".$argv[1]); echo $p->query("PRAGMA quick_check")->fetchColumn(), " ", round(filesize($argv[1])/1024), " KB";', dir + "/" + a.db]);
    const dbOk = q.code === 0 && /^ok /.test(q.out.trim());
    add("Database SQLite", fs.existsSync(dir + "/" + a.db) ? dbOk : null, fs.existsSync(dir + "/" + a.db) ? (dbOk ? `Sehat · ${q.out.trim().slice(3)}` : q.out.trim().slice(0, 200)) : "Belum dibuat (dibuat saat aplikasi pertama dibuka)", dbOk ? "" : "Klik Perbarui untuk menyiapkan ulang data");
  }
  let link = null;
  try {
    link = JSON.parse(fs.readFileSync(dir + "/data/panel-link.json", "utf8"));
  } catch (e) {
    // belum ada
  }
  const linkOk = !!(link && link.key === d.settings.addonKey && link.prefix === pth);
  add("Penghubung ke panel utama", linkOk, link ? (linkOk ? "Kunci dan alamat cocok" : "Kunci atau alamat tidak cocok") : "panel-link.json tidak ada", linkOk ? "" : "Klik Perbarui");
  if (link && (isNode || phpOk)) {
    // Uji jalur yang sama dengan aplikasi: alamat lokal panel + kunci add-on
    const api = await httpJson("GET", String(link.url).replace(/\/$/, "") + "/api/addon/routers", null, { "X-Addon-Key": link.key }, 8000);
    const apiOk = api.status === 200 && api.json && Array.isArray(api.json.routers);
    add("Aplikasi membaca router panel", apiOk, apiOk ? `${api.json.routers.length} router terbaca` : `Gagal (${api.status ? "HTTP " + api.status : api.error})`, apiOk ? "" : "Klik Perbarui, lalu restart panel: systemctl restart vpn-acs");
  }
  if (a.nbi) {
    const nb = nbiBase();
    let u;
    try {
      u = new URL(nb + "/devices/?projection=_id&limit=1");
    } catch (e) {
      u = null;
    }
    const c3 = u ? await httpCode({ host: u.hostname, port: u.port || 80, path: u.pathname + u.search }) : 0;
    add("GenieACS NBI", c3 === 200, c3 ? `${nb} · HTTP ${c3}` : `${nb} tidak menjawab`, c3 === 200 ? "" : "systemctl restart genieacs-nbi");
  }
  return out;
}
function writeIfChanged(file, text, mode) {
  try {
    if (fs.readFileSync(file, "utf8") === text) return false;
  } catch (e) {
    // belum ada
  }
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, text, mode ? { mode } : undefined);
  return true;
}
// ---------- Runtime Node.js untuk add-on aplikasi (node:sqlite butuh Node 22.13+) ----------
const ADDON_NODE_DIR = () => ADDON_ROOT + "/.node";
function isNodeApp(id) {
  return fs.existsSync(addonDir(id) + "/server.js");
}
async function nodeVer(bin) {
  const r = await run(bin, ["-v"]);
  const m = r.out.match(/v(\d+)\.(\d+)/);
  return m ? [+m[1], +m[2]] : null;
}
const nodeOk = (v) => !!v && (v[0] > 22 || (v[0] === 22 && v[1] >= 13));
async function addonNodeBin() {
  for (const b of [process.execPath, ADDON_NODE_DIR() + "/bin/node"]) if (fs.existsSync(b) && nodeOk(await nodeVer(b))) return b;
  return "";
}
function nodeUnits(id, bin) {
  const a = ADDONS[id];
  const dir = addonDir(id);
  return {
    [`addon-${id}.service`]: `[Unit]
Description=Add-on ${a.name} (ACS NETMAP Panel, Node.js)
After=network.target

[Service]
User=www-data
Group=www-data
WorkingDirectory=${dir}
Environment=PORT=${a.port} HOST=127.0.0.1 DATA_DIR=${dir}/data NODE_ENV=production
ExecStart=${bin} --disable-warning=ExperimentalWarning ${dir}/server.js
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
`,
  };
}
function phpUnits(id) {
  const a = ADDONS[id];
  const dir = addonDir(id);
  const units = {};
  units[`addon-${id}.service`] = `[Unit]
Description=Add-on ${a.name} (ACS NETMAP Panel)
After=network.target

[Service]
User=www-data
Group=www-data
WorkingDirectory=${dir}
Environment=PHP_CLI_SERVER_WORKERS=4
ExecStart=/usr/bin/php -d variables_order=EGPCS -S 127.0.0.1:${a.port} -t ${dir} ${dir}/router.php
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
`;
  if (a.timer) {
    units[`addon-${id}-${a.timer.unit}.service`] = `[Unit]
Description=${a.timer.desc} (add-on ${a.name})

[Service]
Type=oneshot
User=www-data
Group=www-data
WorkingDirectory=${dir}
ExecStart=/usr/bin/php ${dir}/${a.timer.script}
`;
    units[`addon-${id}-${a.timer.unit}.timer`] = `[Unit]
Description=${a.timer.desc} (add-on ${a.name})

[Timer]
OnCalendar=${a.timer.every}
Persistent=true

[Install]
WantedBy=timers.target
`;
  }
  return units;
}
// Pastikan ada Node.js 22.13+ untuk add-on; bila Node sistem lebih lama, Node 22 LTS resmi
// dipasang terpisah di /opt/addons/.node (Node milik GenieACS/panel tidak diubah)
async function nodeRuntimeStep(job) {
  const have = await addonNodeBin();
  if (have) return { skip: true, detail: `Node.js ${(await run(have, ["-v"])).out.trim()} sudah ada` };
  const dir = ADDON_NODE_DIR();
  fs.mkdirSync(ADDON_ROOT, { recursive: true });
  const sh = [
    "set -e",
    'A="$(uname -m)"; case "$A" in x86_64) A=x64 ;; aarch64) A=arm64 ;; armv7l) A=armv7l ;; *) echo "Arsitektur $A tidak didukung"; exit 13 ;; esac',
    'U="https://nodejs.org/dist/latest-v22.x"',
    'echo "@@PROGRESS 10 Mencari Node.js 22 LTS"',
    'SUM="$(curl -fsSL --retry 3 "$U/SHASUMS256.txt")"',
    'F="$(printf "%s\n" "$SUM" | awk -v f="linux-$A.tar.xz" \'$2 ~ f"$" {print $2; exit}\')"',
    '[ -n "$F" ] || { echo "Berkas Node.js untuk $A tidak ditemukan"; exit 14; }',
    'echo "@@PROGRESS 25 Mengunduh $F"',
    'T="$(mktemp -d)"; curl -fsSL --retry 3 -o "$T/$F" "$U/$F"',
    'echo "@@PROGRESS 70 Memeriksa checksum"',
    '(cd "$T" && printf "%s\n" "$SUM" | grep " $F\$" | sha256sum -c -)',
    'echo "@@PROGRESS 85 Membuka arsip"',
    `rm -rf "${dir}.new"; mkdir -p "${dir}.new"; tar -xJf "$T/$F" -C "${dir}.new" --strip-components=1`,
    `rm -rf "${dir}"; mv "${dir}.new" "${dir}"; rm -rf "$T"`,
    `echo "@@PROGRESS 100 Node.js $(${dir}/bin/node -v) siap"`,
  ].join("\n");
  const r = await runDetached(job, "nodejs", sh, { timeoutMs: 20 * 60 * 1000 });
  if (r.code !== 0) return { error: "Gagal memasang Node.js 22 untuk add-on (lihat log). Cek koneksi VPS ke nodejs.org." };
  const bin = await addonNodeBin();
  return bin ? { detail: `Node.js ${(await run(bin, ["-v"])).out.trim()} dipasang di ${dir}` } : { error: "Node.js terpasang tetapi tidak bisa dijalankan" };
}
function phpInstallSteps(id, req, opts) {
  const a = ADDONS[id];
  const dir = addonDir(id);
  const update = opts && opts.update;
  const steps = [];
  steps.push({
    label: "Periksa sistem",
    weight: 1,
    run: async () => {
      const d = loadData();
      if (!d.settings.addonKey) return { error: "Kunci add-on belum ada, restart panel lalu coba lagi" };
      const r = await run("df", ["-Pm", ROOT || "/"]);
      const free = parseInt((r.out.split("\n")[1] || "").split(/\s+/)[3], 10);
      if (free && free < 500) return { error: `Ruang disk tinggal ${free} MB (minimal 500 MB)` };
      return { detail: free ? `Disk kosong ${Math.round(free / 1024)} GB` : "" };
    },
  });
  steps.push({
    label: update ? "Unduh versi terbaru" : "Unduh aplikasi",
    weight: 2,
    run: async () => {
      if (fs.existsSync(dir + "/.git")) {
        const r = await runStream("git", ["-C", dir, "pull", "--ff-only"], { timeoutMs: 5 * 60 * 1000 });
        if (r.code !== 0) return { error: "git pull gagal (lihat log). Jika ada berkas yang diubah manual, kembalikan dulu." };
      } else {
        if (fs.existsSync(dir) && fs.readdirSync(dir).filter((x) => x !== "data").length) return { error: `Folder ${dir} sudah ada tetapi bukan hasil unduhan add-on. Pindahkan dulu.` };
        fs.mkdirSync(ADDON_ROOT, { recursive: true });
        const tmp = `${ADDON_ROOT}/.${id}-${Date.now()}`;
        const r = await runStream("git", ["clone", "--depth", "1", a.repo, tmp], { timeoutMs: 5 * 60 * 1000 });
        if (r.code !== 0) return { error: `Gagal mengunduh ${a.repo} (lihat log). Jika repo privat, VPS butuh akses ke repo itu.` };
        // folder data lama (jika ada) dipertahankan
        if (fs.existsSync(dir + "/data")) fs.renameSync(dir + "/data", tmp + "/data.keep");
        fs.rmSync(dir, { recursive: true, force: true });
        fs.renameSync(tmp, dir);
        if (fs.existsSync(dir + "/data.keep")) {
          fs.rmSync(dir + "/data", { recursive: true, force: true });
          fs.renameSync(dir + "/data.keep", dir + "/data");
        }
      }
      const h = await run("git", ["-C", dir, "log", "-1", "--format=%h %cs"]);
      return { detail: h.out.trim() ? `Versi ${h.out.trim()}` : "" };
    },
  });
  steps.push({
    label: "Siapkan runtime",
    weight: 4,
    run: async (job) => {
      if (isNodeApp(id)) return nodeRuntimeStep(job);
      const chk = await run("php", ["-r", 'echo PHP_VERSION, " ", (extension_loaded("pdo_sqlite") && extension_loaded("curl") && extension_loaded("mbstring")) ? "lengkap" : "kurang";']);
      if (chk.code === 0 && /lengkap/.test(chk.out)) return { skip: true, detail: `PHP ${chk.out.split(" ")[0]} sudah ada` };
      needrestartGuard();
      job.detail = "memasang PHP lewat apt";
      job.sub = 0.05;
      // dpkg --configure -a memulihkan paket setengah terpasang (mis. proses sebelumnya terputus);
      // apt menunggu bila sedang dipakai proses lain (update otomatis Ubuntu)
      const sh = [
        "echo '@@PROGRESS 5 memeriksa paket'",
        "dpkg --configure -a",
        "echo '@@PROGRESS 15 apt-get update'",
        "apt-get -o DPkg::Lock::Timeout=300 update -q || exit 11",
        "echo '@@PROGRESS 45 apt-get install php'",
        "apt-get -o DPkg::Lock::Timeout=300 install -y -q php-cli php-sqlite3 php-curl php-mbstring php-xml || exit 12",
        "echo '@@PROGRESS 100 PHP terpasang'",
      ].join("\n");
      const i = await runDetached(job, "php", sh, { timeoutMs: 30 * 60 * 1000 });
      if (i.code === 11) return { error: "apt-get update gagal (lihat log). Cek koneksi internet VPS, lalu coba lagi." };
      if (i.code !== 0) return { error: "Gagal memasang PHP (lihat log). Jika apt sedang dipakai proses lain, tunggu beberapa menit lalu coba lagi." };
      const v = await run("php", ["-r", "echo PHP_VERSION;"]);
      return { detail: `PHP ${v.out.trim()} terpasang` };
    },
  });
  steps.push({
    label: "Siapkan data",
    weight: 1,
    run: async () => {
      const d = loadData();
      fs.mkdirSync(dir + "/data", { recursive: true });
      // Penghubung ke panel utama: alamat lokal + kunci rahasia (hanya dari 127.0.0.1)
      writeIfChanged(dir + "/data/panel-link.json", JSON.stringify({ url: `http://127.0.0.1:${PORT}`, key: d.settings.addonKey, prefix: addonPath(d, id), nbi: nbiBase() }, null, 2), 0o640);
      await run("chown", ["-R", "www-data:www-data", dir + "/data"]);
      await run("chmod", ["750", dir + "/data"]);
      if (!isNodeApp(id) && fs.existsSync(dir + "/bin/setup.php")) {
        const r = await runStream("runuser", ["-u", "www-data", "--", "php", dir + "/bin/setup.php"], { timeoutMs: 5 * 60 * 1000, cwd: dir });
        if (r.code !== 0) return { error: "Setup database gagal (lihat log)" };
      }
      return { detail: "Database siap" };
    },
  });
  steps.push({
    label: "Pasang layanan",
    weight: 1,
    run: async () => {
      let units;
      if (isNodeApp(id)) {
        const bin = await addonNodeBin();
        if (!bin) return { error: "Node.js 22.13+ untuk add-on tidak ditemukan" };
        units = nodeUnits(id, bin);
        // Versi PHP lama: hapus timer pencatat (versi Node.js mencatat sendiri)
        for (const n of Object.keys(phpUnits(id))) {
          if (units[n]) continue;
          await run("systemctl", ["disable", "--now", n]);
          try { fs.unlinkSync(`${SYSTEMD_DIR}/${n}`); } catch (e) { /* tidak ada */ }
        }
      } else units = phpUnits(id);
      for (const [n, t] of Object.entries(units)) writeIfChanged(`${SYSTEMD_DIR}/${n}`, t);
      await run("systemctl", ["daemon-reload"]);
      // Layanan oneshot milik timer tidak diaktifkan langsung; timer yang menjalankannya
      const oneshot = a.timer ? `addon-${id}-${a.timer.unit}.service` : "";
      const started = [];
      for (const n of Object.keys(units)) {
        if (n === oneshot) continue;
        await run("systemctl", ["enable", n]);
        const r = await run("systemctl", ["restart", n]);
        if (r.code !== 0 && !DRY_RUN) return { error: `Gagal menjalankan ${n}: ${r.out.trim().slice(0, 200)}` };
        started.push(n);
      }
      return { detail: started.join(", ") };
    },
  });
  steps.push({
    label: "Uji aplikasi",
    weight: 1,
    run: async () => {
      for (let i = 0; i < 15; i++) {
        const code = await new Promise((resolve) => {
          const rq = http.get({ host: "127.0.0.1", port: a.port, path: "/", timeout: 3000 }, (r) => {
            r.resume();
            resolve(r.statusCode);
          });
          rq.on("error", () => resolve(0));
          rq.on("timeout", () => {
            rq.destroy();
            resolve(0);
          });
        });
        if (code && code < 500) return { detail: `Aplikasi menjawab (HTTP ${code})` };
        await new Promise((z) => setTimeout(z, 1000));
      }
      return { error: `Aplikasi tidak menjawab di port ${a.port}. Cek: journalctl -u addon-${id} -n 50` };
    },
  });
  steps.push({
    label: "Aktifkan di panel",
    weight: 1,
    run: async () => {
      const d = loadData();
      const A = (d.settings.addons = d.settings.addons || {});
      A[id] = Object.assign({}, A[id] || {}, { installed: true, path: addonPath(d, id), at: (A[id] && A[id].at) || new Date().toISOString(), updatedAt: new Date().toISOString() });
      saveData(d);
      return { detail: `Dibuka di ${addonPath(d, id)}/` };
    },
  });
  return steps;
}
function phpRemoveSteps(id, purge) {
  const a = ADDONS[id];
  const dir = addonDir(id);
  return [
    {
      label: "Hentikan layanan",
      run: async () => {
        for (const n of Object.keys(phpUnits(id))) {
          await run("systemctl", ["disable", "--now", n]);
          try {
            fs.unlinkSync(`${SYSTEMD_DIR}/${n}`);
          } catch (e) {
            // sudah tidak ada
          }
        }
        await run("systemctl", ["daemon-reload"]);
        return {};
      },
    },
    {
      label: purge ? "Hapus aplikasi dan data" : "Simpan data",
      run: async () => {
        if (purge) {
          fs.rmSync(dir, { recursive: true, force: true });
          return { detail: `${dir} dihapus` };
        }
        return { detail: `Data tetap di ${dir}/data (dipakai lagi jika dipasang ulang)` };
      },
    },
    {
      label: "Nonaktifkan di panel",
      run: async () => {
        const d = loadData();
        const A = (d.settings.addons = d.settings.addons || {});
        A[id] = Object.assign({}, A[id] || {}, { installed: false, removedAt: new Date().toISOString() });
        saveData(d);
        return { detail: `${a.name} dilepas` };
      },
    },
  ];
}
function ztInstallSteps() {
  return [
    {
      label: "Periksa sistem",
      weight: 1,
      run: async (job) => {
        const v = await run("zerotier-cli", ["-v"]);
        if (v.code === 0 && v.out.trim()) {
          job.ztHave = true;
          return { detail: `ZeroTier ${v.out.trim()} sudah ada` };
        }
        const a = (await run("dpkg", ["--print-architecture"])).out.trim();
        if (!DRY_RUN && !["amd64", "arm64"].includes(a)) return { error: `Arsitektur ${a || "?"} belum didukung (hanya amd64 dan arm64).` };
        return { detail: `Sistem ${a || "?"}, ZeroTier akan dipasang` };
      },
    },
    {
      label: "Pasang ZeroTier",
      weight: 4,
      run: async (job) => {
        if (job.ztHave) return { skip: true, detail: "Sudah terpasang" };
        needrestartGuard();
        // Repo apt resmi ZeroTier (download.zerotier.com/debian/<codename>), sama seperti install.zerotier.com.
        // Bila repo untuk versi sistem ini belum ada, dipakai repo versi terdekat; bila tetap gagal, installer resmi.
        const sh = [
          "set -e",
          '. /etc/os-release; CODE="${VERSION_CODENAME:-${UBUNTU_CODENAME:-jammy}}"',
          'REPO="http://download.zerotier.com/debian"',
          'echo "@@PROGRESS 5 Memeriksa repo ZeroTier untuk $CODE"',
          'ok_repo() { [ "$(curl -s -o /dev/null -m 15 -w "%{http_code}" "$REPO/$1/dists/$1/InRelease")" = "200" ]; }',
          'if ! ok_repo "$CODE"; then for c in noble jammy bookworm bullseye focal; do if ok_repo "$c"; then echo "Repo $CODE belum ada, memakai $c"; CODE="$c"; break; fi; done; fi',
          'echo "@@PROGRESS 15 Memasang kunci repo"',
          "mkdir -p /usr/share/keyrings",
          "dpkg --configure -a || true",
          "command -v gpg >/dev/null || apt-get -o DPkg::Lock::Timeout=300 install -y -q gnupg",
          'curl -fsSL --retry 3 "https://raw.githubusercontent.com/zerotier/ZeroTierOne/main/doc/contact%40zerotier.com.gpg" | gpg --dearmor --yes -o /usr/share/keyrings/zerotier.gpg',
          'echo "deb [signed-by=/usr/share/keyrings/zerotier.gpg] $REPO/$CODE $CODE main" > /etc/apt/sources.list.d/zerotier.list',
          'echo "@@PROGRESS 35 apt-get update"',
          'if ! apt-get -o DPkg::Lock::Timeout=300 update -q || ! { echo "@@PROGRESS 60 Memasang zerotier-one"; apt-get -o DPkg::Lock::Timeout=300 install -y -q zerotier-one; }; then',
          '  echo "Repo apt gagal, mencoba installer resmi install.zerotier.com"',
          "  rm -f /etc/apt/sources.list.d/zerotier.list",
          '  echo "@@PROGRESS 60 Installer resmi ZeroTier"',
          "  curl -fsSL --retry 3 https://install.zerotier.com | bash",
          "fi",
          'echo "@@PROGRESS 85 Menyalakan layanan"',
          "systemctl enable --now zerotier-one",
          "for i in $(seq 1 30); do [ -f /var/lib/zerotier-one/identity.secret ] && break; sleep 1; done",
          "[ -f /var/lib/zerotier-one/identity.secret ]",
          'echo "@@PROGRESS 100 ZeroTier terpasang: $(zerotier-cli -v 2>/dev/null)"',
        ].join("\n");
        const r = await runDetached(job, "zerotier", sh, { timeoutMs: 15 * 60 * 1000 });
        if (r.code !== 0) return { error: "Gagal memasang ZeroTier (lihat log). Cek koneksi VPS ke download.zerotier.com dan raw.githubusercontent.com, lalu coba lagi." };
        const v = await run("zerotier-cli", ["-v"]);
        return { detail: `ZeroTier ${v.out.trim() || ""} terpasang` };
      },
    },
    {
      label: "Periksa controller",
      weight: 1,
      run: async () => {
        let st;
        for (let i = 0; i < 10; i++) {
          st = await ztApi("GET", "/status");
          if (st.ok) break;
          await new Promise((z) => setTimeout(z, 1000));
        }
        if (!st.ok) return { error: "ZeroTier di VPS belum menjawab: " + st.error };
        const c = await ztApi("GET", "/controller");
        if (!c.ok) return { error: "Fitur controller ZeroTier tidak menjawab: " + c.error };
        return { detail: `Node ${st.json.address} · versi ${st.json.version}` };
      },
    },
    {
      label: "Aktifkan di panel",
      weight: 1,
      run: async () => {
        const d = loadData();
        const A = (d.settings.addons = d.settings.addons || {});
        A.zerotier = Object.assign({}, A.zerotier || {}, { installed: true, at: new Date().toISOString() });
        saveData(d);
        return { detail: "Menu ZeroTier aktif. Buat jaringan di menu ZeroTier." };
      },
    },
  ];
}
// Perbarui ZeroTier lewat apt (repo resmi ZeroTier)
function ztUpgradeSteps() {
  return [
    {
      label: "Perbarui ZeroTier",
      weight: 4,
      run: async (job) => {
        needrestartGuard();
        const before = (await run("zerotier-cli", ["-v"])).out.trim();
        const r = await runDetached(job, "ztup", 'echo "@@PROGRESS 20 apt-get update"\napt-get -o DPkg::Lock::Timeout=300 update -q\necho "@@PROGRESS 60 Memasang versi baru"\napt-get -o DPkg::Lock::Timeout=300 install -y -q --only-upgrade zerotier-one\nsystemctl restart zerotier-one', { timeoutMs: 15 * 60 * 1000 });
        if (r.code !== 0) return { error: "Gagal memperbarui ZeroTier (lihat log)" };
        await new Promise((z) => setTimeout(z, 3000));
        const after = (await run("zerotier-cli", ["-v"])).out.trim();
        return { detail: before === after ? `Sudah versi terbaru (${after})` : `${before} → ${after}` };
      },
    },
    {
      label: "Periksa controller",
      run: async () => {
        const st = await ztApi("GET", "/status");
        if (!st.ok) return { error: "ZeroTier belum menjawab: " + st.error };
        await checkUpdates().catch(() => {});
        return { detail: `Node ${st.json.address} · versi ${st.json.version}` };
      },
    },
  ];
}
// Pindahan dari ZTNET: salin nama perangkat ke panel, lalu lepas ZTNET (opsional PostgreSQL)
function ztnetRemoveSteps(dropDb) {
  return [
    {
      label: "Salin nama dari ZTNET",
      run: async () => {
        if (!fs.existsSync(ZTNET_DIR + "/.env")) return { skip: true, detail: "ZTNET tidak ditemukan" };
        const d = loadData();
        const r = await ztnetImport(d);
        if (r.error) return { error: r.error + " Nyalakan PostgreSQL lalu coba lagi, atau lepas ZTNET tanpa menyalin nama lewat SSH." };
        saveData(d);
        return { detail: `${r.members} nama perangkat disalin${r.networks ? `, ${r.networks} nama jaringan` : ""}` };
      },
    },
    {
      label: "Hapus layanan ZTNET",
      run: async () => {
        const dbUrl = ztnetDbUrl();
        await run("systemctl", ["disable", "--now", "ztnet"]);
        for (const f of [SYSTEMD_DIR + "/ztnet.service.d", SYSTEMD_DIR + "/ztnet.service"]) {
          try {
            fs.rmSync(f, { recursive: true, force: true });
          } catch (e) {
            // abaikan
          }
        }
        await run("systemctl", ["daemon-reload"]);
        fs.rmSync(ZTNET_DIR, { recursive: true, force: true });
        fs.rmSync(ZTNET_DIR + ".lama", { recursive: true, force: true });
        try {
          fs.unlinkSync(ROOT + "/usr/local/bin/ztmkworld");
        } catch (e) {
          // abaikan
        }
        const d = loadData();
        let ch = false;
        if (d.settings.ztnetUrl !== undefined) { delete d.settings.ztnetUrl; ch = true; }
        if (d.settings.subdomains && d.settings.subdomains.zt) { delete d.settings.subdomains.zt; ch = true; }
        if (dbUrl) d.settings.ztnetDbUrl = dbUrl;
        saveData(d);
        return { detail: "Layanan ztnet dan folder /opt/ztnet dihapus. Jaringan ZeroTier tetap utuh." + (ch ? " Link & subdomain ZTNET dihapus dari panel." : "") };
      },
    },
    {
      label: dropDb ? "Hapus database ZTNET" : "Biarkan database",
      weight: 2,
      run: async (job) => {
        const d = loadData();
        const url = d.settings.ztnetDbUrl || "";
        delete d.settings.ztnetDbUrl;
        saveData(d);
        if (!dropDb) return { skip: true, detail: "PostgreSQL dan database ztnet tetap ada" };
        const m = url.match(/^postgres(?:ql)?:\/\/([^:]+):[^@]*@[^/]+\/([\w]+)/);
        const user = m ? m[1] : "ztnet", db = m ? m[2] : "ztnet";
        if (!/^\w+$/.test(user) || !/^\w+$/.test(db)) return { error: "Nama database tidak wajar, dilewati." };
        const sh = [
          `runuser -u postgres -- psql -qc 'DROP DATABASE IF EXISTS "${db}"' || true`,
          `runuser -u postgres -- psql -qc 'DROP ROLE IF EXISTS "${user}"' || true`,
          // PostgreSQL dihapus hanya bila tidak ada database lain yang dipakai
          `OTHER="$(runuser -u postgres -- psql -tAc "select count(*) from pg_database where datname not in ('postgres','template0','template1')" 2>/dev/null || echo 1)"`,
          'if [ "$OTHER" = "0" ]; then echo "@@PROGRESS 50 Menghapus PostgreSQL"; systemctl disable --now postgresql || true; apt-get -o DPkg::Lock::Timeout=300 purge -y -q "postgresql*" && apt-get autoremove -y -q; echo "PostgreSQL dihapus"; else echo "PostgreSQL dipakai database lain ($OTHER), tidak dihapus"; fi',
        ].join("\n");
        const r = await runDetached(job, "pg", sh, { timeoutMs: 15 * 60 * 1000 });
        if (r.code !== 0) return { error: "Gagal menghapus database (lihat log)" };
        const removed = (job.log || []).some((l) => /PostgreSQL dihapus/.test(l));
        return { detail: removed ? "Database ztnet dan PostgreSQL dihapus" : "Database ztnet dihapus (PostgreSQL tetap karena dipakai database lain)" };
      },
    },
  ];
}
function ztRemoveSteps(purge) {
  return [
    {
      label: "Periksa router",
      run: async () => {
        const d = loadData();
        const n = d.sites.filter(isZt).length;
        if (n) return { error: `Masih ada ${n} router yang memakai ZeroTier. Pindahkan ke L2TP atau hapus dulu.` };
        return {};
      },
    },
    {
      label: "Lepas jaringan dari panel",
      run: async () => {
        const d = loadData();
        const z = ztCfg(d);
        if (!z) return { skip: true, detail: "Tidak ada jaringan terhubung" };
        await ztApi("DELETE", `/network/${z.nwid}`);
        delete d.settings.zt;
        saveData(d);
        await ensureLoAddr(d);
        return { detail: `VPS keluar dari ${z.name || z.nwid}` };
      },
    },
    {
      label: purge ? "Hapus ZeroTier dari VPS" : "Biarkan ZeroTier di VPS",
      run: async (job) => {
        if (!purge) return { detail: "ZeroTier tetap terpasang; jaringan di controller tetap tersimpan" };
        if (fs.existsSync(ZTNET_DIR)) {
          await run("systemctl", ["disable", "--now", "ztnet"]);
          fs.rmSync(ZTNET_DIR, { recursive: true, force: true });
        }
        const r = await runDetached(job, "ztpurge", "systemctl disable --now zerotier-one || true\napt-get -o DPkg::Lock::Timeout=300 purge -y -q zerotier-one\nrm -rf /var/lib/zerotier-one /etc/apt/sources.list.d/zerotier.list /usr/share/keyrings/zerotier.gpg", { timeoutMs: 10 * 60 * 1000 });
        if (r.code !== 0) return { error: "Gagal menghapus ZeroTier (lihat log)" };
        return { detail: "ZeroTier dan semua jaringannya dihapus dari VPS" };
      },
    },
    {
      label: "Nonaktifkan di panel",
      run: async () => {
        const d = loadData();
        const A = (d.settings.addons = d.settings.addons || {});
        A.zerotier = Object.assign({}, A.zerotier || {}, { installed: false, removedAt: new Date().toISOString() });
        saveData(d);
        return { detail: "Menu ZeroTier disembunyikan" };
      },
    },
  ];
}
async function addonList(d) {
  const out = [];
  for (const [id, a] of Object.entries(ADDONS)) {
    const st = addonState(d, id);
    const x = { id, kind: a.kind, name: a.name, icon: a.icon, color: a.color || "blue", tagline: a.tagline || "", features: a.features || [], desc: a.desc, note: a.note || "", installed: !!st.installed, at: st.at || null, updatedAt: st.updatedAt || null };
    if (a.kind === "aplikasi") {
      x.path = addonPath(d, id);
      x.url = addonUrl(d, id);
      x.repo = a.repo.replace(/\.git$/, "");
      x.port = a.port;
      const dir = addonDir(id);
      x.hasData = fs.existsSync(dir + "/data");
      if (st.installed) {
        const r = await run("systemctl", ["is-active", `addon-${id}`]);
        x.running = r.out.trim() === "active" || (DRY_RUN && r.code === 0);
        const g = await run("git", ["-C", dir, "log", "-1", "--format=%h %cs"]);
        x.version = g.code === 0 ? g.out.trim() : "";
      }
    } else {
      x.ztnet = fs.existsSync(ZTNET_DIR + "/.env");
      x.routers = d.sites.filter(id === "wireguard" ? isWg : isZt).length;
    }
    const up = UPDATES && UPDATES.addons && UPDATES.addons[id];
    if (st.installed && up && up.available) x.update = { latest: up.latest || "", behind: up.behind || 0, notes: up.notes || "" };
    out.push(x);
  }
  return out;
}

// =====================================================================
//  Port standar 80/443 (opsional) dan reverse proxy
//  - 80 : http. Jika HTTPS aktif dialihkan ke https, kecuali laporan MikroTik
//  - 443: https (hanya jika HTTPS aktif), memakai server https internal yang sama
//  - Subdomain layanan (acs.) diteruskan ke GenieACS UI di VPS
//  - Path add-on (mis. /acs, /billing) diteruskan ke aplikasi add-on di 127.0.0.1
//  Port 8088 tetap hidup sebagai cadangan.
// =====================================================================
let STD_ON = false;
let STD_ERR = "";
let std80 = null;
let std443 = null;
function hostOf(head) {
  const m = String(head).match(/\r\nhost:\s*([^\r\n:]+)/i);
  return m ? m[1].trim().toLowerCase() : "";
}
function reqHost(req) {
  return String(req.headers.host || "").replace(/:\d+$/, "").trim().toLowerCase();
}
// Host milik panel: domain panel dan subdomain layanannya
function isOurHost(h) {
  if (!h) return false;
  const d = loadData();
  const s = d.settings || {};
  if (s.cloudflare && s.cloudflare.domain === h) return true;
  return Object.values(s.subdomains || {}).some((x) => x && x.host === h);
}
// Subdomain yang diteruskan: host -> port lokal
function proxyHostTarget(h) {
  if (!STD_ON || !h) return 0;
  const subs = (loadData().settings || {}).subdomains || {};
  const S = subServices();
  for (const [svc, x] of Object.entries(subs)) if (x && x.host === h && S[svc]) return S[svc].port();
  return 0;
}
// Path add-on: "/acs/..." -> { port, prefix }
function proxyPathTarget(pathname) {
  for (const a of addonRoutes()) {
    if (pathname === a.path || pathname.startsWith(a.path + "/")) return a;
  }
  return null;
}
function proxyRequest(req, res, port, prefix) {
  let pathPart = req.url;
  if (prefix) {
    if (pathPart === prefix) {
      res.writeHead(301, { Location: prefix + "/" });
      return res.end();
    }
    pathPart = pathPart.slice(prefix.length) || "/";
  }
  const headers = Object.assign({}, req.headers);
  const proto = req.socket.encrypted ? "https" : "http";
  headers["x-forwarded-for"] = clientIp(req);
  headers["x-forwarded-proto"] = proto;
  headers["x-forwarded-host"] = req.headers.host || "";
  if (prefix) headers["x-forwarded-prefix"] = prefix;
  const up = http.request({ host: "127.0.0.1", port, method: req.method, path: pathPart, headers }, (r) => {
    const h = Object.assign({}, r.headers);
    // Alihkan Location absolut ke path add-on
    if (prefix && h.location && h.location.startsWith("/")) h.location = prefix + h.location;
    res.writeHead(r.statusCode || 502, h);
    r.pipe(res);
  });
  up.on("error", (e) => {
    if (!res.headersSent) res.writeHead(502, { "Content-Type": "text/html; charset=utf-8" });
    res.end(`<!doctype html><meta charset="utf-8"><title>Layanan tidak menjawab</title><body style="font-family:system-ui;padding:40px;color:#334"><h2>Layanan belum berjalan</h2><p>Aplikasi di port ${port} tidak menjawab (${String(e.code || e.message)}).</p><p>Cek di VPS: <code>systemctl status</code> layanan add-on atau aplikasinya.</p></body>`);
  });
  req.pipe(up);
}
function proxyUpgrade(req, sock, head, port, prefix) {
  const up = net.connect({ host: "127.0.0.1", port }, () => {
    let pathPart = req.url;
    if (prefix && pathPart.startsWith(prefix)) pathPart = pathPart.slice(prefix.length) || "/";
    const lines = [`${req.method} ${pathPart} HTTP/${req.httpVersion}`];
    for (let i = 0; i < req.rawHeaders.length; i += 2) lines.push(`${req.rawHeaders[i]}: ${req.rawHeaders[i + 1]}`);
    up.write(lines.join("\r\n") + "\r\n\r\n");
    if (head && head.length) up.write(head);
    sock.pipe(up);
    up.pipe(sock);
  });
  up.on("error", () => sock.destroy());
  sock.on("error", () => up.destroy());
}
function onUpgrade(req, sock, head) {
  const port = proxyHostTarget(reqHost(req));
  if (port) return proxyUpgrade(req, sock, head, port, "");
  const a = proxyPathTarget(new URL(req.url, "http://x").pathname);
  if (a) return proxyUpgrade(req, sock, head, a.port, a.path);
  sock.destroy();
}
// Kirim koneksi TLS ke server https internal (dipakai port 443 dan 8088)
function pipeTls(sock, buf) {
  sock.pause();
  const remote = sock.remoteAddress;
  let key = 0;
  const up = net.connect({ host: "127.0.0.1", port: httpsPort }, () => {
    key = up.localPort;
    PROXY_IPS.set(key, remote);
    up.write(buf);
    sock.pipe(up);
    up.pipe(sock);
    sock.resume();
  });
  up.on("error", () => sock.destroy());
  up.on("close", () => {
    if (key) PROXY_IPS.delete(key);
    sock.destroy();
  });
  sock.on("close", () => up.destroy());
}
function handler80(sock) {
  sock.on("error", () => {});
  if (!HTTPS_ON) return httpServer.emit("connection", sock);
  sock.setTimeout(20000, () => sock.destroy());
  sock.once("data", (buf) => {
    sock.setTimeout(0);
    const head = buf.toString("latin1");
    const m = head.match(/^[A-Z]+ (\S+) HTTP/);
    const p = m && m[1].startsWith("/") ? m[1] : "/";
    const host = hostOf(head);
    // Laporan MikroTik dan verifikasi Let's Encrypt tetap http; akses lewat IP juga tetap http
    if (p.startsWith("/api/zt/join") || p.startsWith("/.well-known/acme-challenge/") || !isOurHost(host)) {
      sock.unshift(buf);
      return httpServer.emit("connection", sock);
    }
    sock.end(`HTTP/1.1 301 Moved Permanently\r\nLocation: https://${host}${portSfx("https")}${p}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n`);
  });
}
function handler443(sock) {
  sock.on("error", () => {});
  if (!HTTPS_ON) return sock.destroy();
  sock.once("data", (buf) => {
    if (buf[0] !== 0x16) return sock.destroy();
    pipeTls(sock, buf);
  });
}
function listenPort(port, fn) {
  return new Promise((resolve) => {
    const srv = net.createServer(fn);
    srv.once("error", (e) => resolve({ error: e.code === "EADDRINUSE" ? `Port ${port} sudah dipakai aplikasi lain` : e.code === "EACCES" ? `Tidak punya izin membuka port ${port}` : e.message }));
    srv.listen(port, HOST, () => resolve({ srv }));
  });
}
// Port "alamat tanpa port": bawaan 80 (http) dan 443 (https), bisa diganti di Pengaturan
const stdDef = (k) => (DRY_RUN ? (k === "https" ? STD_HTTPS : STD_HTTP) : k === "https" ? 443 : 80);
function stdConf(d) {
  const s = (d && d.settings) || {};
  return { http: parseInt(s.stdHttp, 10) || stdDef("http"), https: parseInt(s.stdHttps, 10) || stdDef("https") };
}
let STD_PORTS = { http: 0, https: 0 }; // port yang sedang dipakai
// ":port" di alamat bila bukan port standar
const portSfx = (k) => (STD_PORTS[k] && STD_PORTS[k] !== stdDef(k) ? `:${STD_PORTS[k]}` : "");
function stdPortCheck(d, http, https) {
  for (const [k, v] of [["HTTP", http], ["HTTPS", https]]) {
    if (!Number.isInteger(v) || v < 1 || v > 65535) return `Port ${k} harus angka 1-65535.`;
    if (v === PORT) return `Port ${v} dipakai panel sendiri (cadangan).`;
    const special = [22, 25, 53, 500, 1701, 3000, 4500, 5432, 7547, 7557, 7567, 9993, 27017];
    if (special.includes(v)) return `Port ${v} dipakai layanan lain di VPS (SSH, VPN, GenieACS, database, atau ZeroTier).`;
    if (v >= FWD_AUTO_START && v < FWD_AUTO_START + 5000 && usedPublicPorts(d).has(v)) return `Port ${v} sudah dipakai port forwarding router.`;
  }
  if (http === https) return "Port HTTP dan HTTPS tidak boleh sama.";
  return null;
}
// Port 80/443 aktif secara bawaan; hanya mati bila admin mematikannya di Pengaturan
function stdWanted(d) {
  return !(d && d.settings && d.settings.stdPorts === false);
}
async function stdPortsStart(ports) {
  if (STD_ON) return { ok: true };
  const P = ports || stdConf(loadData());
  const a = await listenPort(P.http, handler80);
  if (a.error) return { error: a.error };
  const b = await listenPort(P.https, handler443);
  if (b.error) {
    a.srv.close();
    return { error: b.error };
  }
  std80 = a.srv;
  std443 = b.srv;
  STD_PORTS = { http: P.http, https: P.https };
  STD_ON = true;
  STD_ERR = "";
  return { ok: true };
}
function stdPortsStop() {
  if (std80) std80.close();
  if (std443) std443.close();
  std80 = std443 = null;
  STD_PORTS = { http: 0, https: 0 };
  STD_ON = false;
}
// Cek port 80/443 bisa dipakai, tanpa mengubah apa pun
async function stdPortsProbe(ports) {
  const P = ports || stdConf(loadData());
  const out = [];
  for (const port of [P.http, P.https]) {
    if (STD_ON && (port === STD_PORTS.http || port === STD_PORTS.https)) continue; // sedang dipakai panel sendiri
    const r = await listenPort(port, () => {});
    if (r.error) out.push(r.error);
    else await new Promise((z) => r.srv.close(z));
  }
  return out.length ? { error: out.join("; ") } : { ok: true };
}

// Terbitkan ulang sertifikat agar mencakup subdomain layanan (lewat Cloudflare DNS)
async function certExpand(domain, hosts) {
  if (!fs.existsSync(CF_INI)) return { error: "Token Cloudflare untuk sertifikat tidak ditemukan. Aktifkan ulang HTTPS di Domain & HTTPS." };
  const args = ["certonly", "--non-interactive", "--agree-tos", "--register-unsafely-without-email", "--dns-cloudflare", "--dns-cloudflare-credentials", CF_INI, "--dns-cloudflare-propagation-seconds", "30", "--cert-name", domain, "--expand", "-d", domain];
  for (const h of hosts) args.push("-d", h);
  const r = await runStream("certbot", args, { timeoutMs: 6 * 60 * 1000 });
  if (r.code !== 0) return { error: "Sertifikat gagal diperluas (lihat log). Let's Encrypt membatasi 5 kali gagal per jam." };
  await httpsEnable(domain);
  return { ok: true };
}
// Perbarui link GenieACS yang dibuat dari subdomain sesuai mode port
async function refreshSubUrls(d) {
  const s = d.settings || {};
  const notes = [];
  for (const [svc, x] of Object.entries(s.subdomains || {})) {
    if (!x || !x.host || !subServices(d)[svc]) continue;
    const want = subUrl(svc, x.host);
    if (svc === "acs") s.genieUrl = want;
    notes.push(want);
  }
  return notes;
}
function stdOnSteps(want) {
  // want: { http, https } port baru (opsional); bawaan dari pengaturan
  const P = want || stdConf(loadData());
  return [
    {
      label: `Periksa port ${P.http} dan ${P.https}`,
      run: async () => {
        const r = await stdPortsProbe(P);
        if (r.error) return { error: r.error + ". Hentikan aplikasi itu (mis. nginx/apache) atau pilih port lain." };
        return { detail: "Port bisa dipakai" };
      },
    },
    {
      label: "Sertifikat untuk subdomain",
      weight: 3,
      run: async () => {
        const d = loadData();
        const cf = d.settings.cloudflare;
        const SV = subServices(d);
        const hosts = Object.entries(d.settings.subdomains || {}).filter(([k, x]) => SV[k] && x && x.host).map(([, x]) => x.host);
        if (!(cf && cf.https && HTTPS_ON) || !hosts.length) return { skip: true, detail: "Tidak diperlukan" };
        const r = await certExpand(cf.domain, hosts);
        if (r.error) return r;
        return { detail: `Sertifikat mencakup ${[cf.domain].concat(hosts).join(", ")}` };
      },
    },
    {
      label: `Aktifkan port ${P.http} dan ${P.https}`,
      run: async () => {
        const old = STD_ON ? Object.assign({}, STD_PORTS) : null;
        if (STD_ON && (STD_PORTS.http !== P.http || STD_PORTS.https !== P.https)) stdPortsStop();
        let r = await stdPortsStart(P);
        if (r.error) {
          if (old) await stdPortsStart(old); // kembali ke port lama
          return r;
        }
        const d = loadData();
        d.settings.stdPorts = true;
        if (P.http === stdDef("http")) delete d.settings.stdHttp; else d.settings.stdHttp = P.http;
        if (P.https === stdDef("https")) delete d.settings.stdHttps; else d.settings.stdHttps = P.https;
        STD_ERR = "";
        const notes = await refreshSubUrls(d);
        saveData(d);
        return { detail: "Panel: " + panelPublicUrl(settings(d), d) + (notes.length ? " · " + notes.join(" · ") : "") };
      },
    },
  ];
}
function stdOffSteps() {
  return [
    {
      label: "Matikan port 80 dan 443",
      run: async () => {
        stdPortsStop();
        const d = loadData();
        d.settings.stdPorts = false;
        const notes = await refreshSubUrls(d);
        saveData(d);
        return { detail: `Panel kembali di port ${PORT}` + (notes.length ? " · " + notes.join(" · ") : "") };
      },
    },
  ];
}

// ---------- Kesehatan VPS ----------
const HEALTH_STATE = path.dirname(DATA_FILE) + "/health-state.json";
let CPU_PREV = null, CPU_PCT = null;
function cpuSample() {
  try {
    const l = fs.readFileSync("/proc/stat", "utf8").split("\n")[0].trim().split(/\s+/).slice(1).map(Number);
    const idle = l[3] + (l[4] || 0), total = l.reduce((a, b) => a + b, 0);
    if (CPU_PREV && total > CPU_PREV.total) CPU_PCT = Math.round((1 - (idle - CPU_PREV.idle) / (total - CPU_PREV.total)) * 1000) / 10;
    CPU_PREV = { idle, total };
  } catch (e) {
    // bukan Linux
  }
}
cpuSample();
setInterval(cpuSample, 30 * 1000).unref();
function healthConf(d) {
  const x = ((d || loadData()).settings || {}).health || {};
  return {
    enabled: x.enabled !== false,
    days: clampInt(x.days, 1, 30, 7),
    time: /^([01]\d|2[0-3]):[0-5]\d$/.test(x.time || "") ? x.time : "08:00",
    alerts: x.alerts !== false,
  };
}
function healthStateLoad() {
  try { return JSON.parse(fs.readFileSync(HEALTH_STATE, "utf8")); } catch (e) { return { lastSent: 0, alerts: {} }; }
}
function healthStateSave(x) {
  try { fs.writeFileSync(HEALTH_STATE, JSON.stringify(x)); } catch (e) { /* abaikan */ }
}
async function unitInfo(unit) {
  const r = await run("systemctl", ["show", "-p", "LoadState", "-p", "ActiveState", "--value", unit], 8000);
  const [load, act] = r.out.trim().split("\n");
  return { loaded: load === "loaded", active: act === "active" };
}
async function vpsHealth(d) {
  d = d || loadData();
  const out = { at: Date.now(), cores: os.cpus().length || 1, load: os.loadavg().map((x) => Math.round(x * 100) / 100), cpu: CPU_PCT, uptime: Math.round(os.uptime() * 1000) };
  try {
    const m = {};
    for (const l of fs.readFileSync("/proc/meminfo", "utf8").split("\n")) { const x = l.match(/^(\w+):\s+(\d+)/); if (x) m[x[1]] = parseInt(x[2], 10) * 1024; }
    out.mem = { total: m.MemTotal || 0, used: (m.MemTotal || 0) - (m.MemAvailable || m.MemFree || 0) };
    out.swap = { total: m.SwapTotal || 0, used: (m.SwapTotal || 0) - (m.SwapFree || 0) };
  } catch (e) {
    out.mem = { total: os.totalmem(), used: os.totalmem() - os.freemem() };
    out.swap = { total: 0, used: 0 };
  }
  out.mem.pct = out.mem.total ? Math.round((out.mem.used / out.mem.total) * 100) : 0;
  out.swap.pct = out.swap.total ? Math.round((out.swap.used / out.swap.total) * 100) : 0;
  const df = await run("df", ["-kP", "/"], 8000);
  const dl = df.out.trim().split("\n")[1];
  if (dl) {
    const c = dl.split(/\s+/);
    out.disk = { mount: c[5] || "/", total: parseInt(c[1], 10) * 1024, used: parseInt(c[2], 10) * 1024 };
    out.disk.pct = out.disk.total ? Math.round((out.disk.used / out.disk.total) * 100) : 0;
  }
  // Layanan: inti panel + yang terpasang
  const units = [["vpn-acs", "Panel"], ["xl2tpd", "VPN L2TP"], ...GENIE_UNITS.map(([u, l]) => [u, "GenieACS " + l.replace(/\s*\(.*\)/, "")]), ["mongod", "MongoDB"]];
  // IPsec hanya ditampilkan bila dipakai (libreswan: ipsec, strongSwan: strongswan-starter / strongswan)
  if (d.settings && d.settings.useIpsec) {
    for (const u of ["ipsec", "strongswan-starter", "strongswan"]) {
      if ((await unitInfo(u)).loaded) { units.splice(2, 0, [u, "IPsec"]); break; }
    }
  }
  if (addonInstalled(d, "zerotier")) units.push(["zerotier-one", "ZeroTier"]);
  if (ADDONS.wireguard && addonInstalled(d, "wireguard")) units.push([`wg-quick@${WG_IFACE}`, "WireGuard"]);
  for (const [id, a] of Object.entries(ADDONS)) if (a.kind === "aplikasi" && addonInstalled(d, id)) units.push([`addon-${id}`, a.name]);
  out.services = [];
  for (const [unit, label] of units) {
    const u = DRY_RUN && unit === "vpn-acs" ? { loaded: true, active: true } : await unitInfo(unit);
    if (!u.loaded && (unit === "mongod" || unit.startsWith("genieacs"))) continue; // GenieACS dipasang terpisah
    out.services.push({ unit, label, active: u.active });
  }
  // Router
  const h = loadHistory();
  out.routers = { up: 0, down: 0, pending: 0 };
  for (const x of d.sites) {
    if (!x.installedAt) out.routers.pending++;
    else if (h.sites[x.id] && h.sites[x.id].state === "down") out.routers.down++;
    else out.routers.up++;
  }
  return out;
}
const fmtBytes = (b) => (b >= 1024 ** 3 ? (b / 1024 ** 3).toFixed(1).replace(".", ",") + " GB" : Math.round(b / 1024 ** 2) + " MB");
function healthNext(d, from) {
  const c = healthConf(d);
  const st = healthStateLoad();
  const tz = tzName(d);
  const [hh, mm] = c.time.split(":").map(Number);
  // Laporan berikutnya: tanggal laporan terakhir + N hari pada jam kirim (zona panel).
  // Belum pernah terkirim: jam kirim berikutnya mulai sekarang.
  const at = (base, addDays) => {
    const L = localDate(base, tz);
    const off = L.getTime() - base;
    return Date.UTC(L.getUTCFullYear(), L.getUTCMonth(), L.getUTCDate() + addDays, hh, mm) - off;
  };
  if (st.lastSent && !from) return at(st.lastSent, c.days);
  const now = from || Date.now();
  const t = at(now, 0);
  return t > now ? t : at(now, 1);
}
function healthMsg(d, x, kind) {
  const tz = tzName(d);
  const down = x.services.filter((v) => !v.active);
  const lines = [
    kind === "test" ? "🖥️ <b>LAPORAN KESEHATAN VPS</b> (uji kirim)" : "🖥️ <b>LAPORAN KESEHATAN VPS</b>",
    `${brandOf(d)} · ${fmtClock(x.at, tz, true)}`,
    "",
    `CPU ${x.cpu == null ? "—" : String(x.cpu).replace(".", ",") + "%"} · beban ${x.load[0].toFixed(2).replace(".", ",")} (${x.cores} inti)`,
    `RAM ${fmtBytes(x.mem.used)} / ${fmtBytes(x.mem.total)} (${x.mem.pct}%)${x.mem.pct >= 90 ? " ⚠️" : ""}`,
    x.swap.total ? `Swap ${fmtBytes(x.swap.used)} / ${fmtBytes(x.swap.total)} (${x.swap.pct}%)` : "Swap tidak ada",
    x.disk ? `Disk ${fmtBytes(x.disk.used)} / ${fmtBytes(x.disk.total)} (${x.disk.pct}%)${x.disk.pct >= 90 ? " ⚠️" : ""}` : "Disk —",
    `Uptime ${fmtDur(x.uptime)}`,
    "",
    down.length ? `❌ Layanan mati: ${down.map((v) => v.label).join(", ")}` : `✅ Semua layanan berjalan (${x.services.length})`,
    `Router: ${x.routers.up} tersambung · ${x.routers.down} terputus${x.routers.pending ? ` · ${x.routers.pending} menunggu` : ""}`,
  ];
  const c = healthConf(d);
  if (kind !== "test" && c.enabled) lines.push("", `Laporan berikutnya ${fmtClock(Date.now() + c.days * 86400e3, tz, true).replace(/\d\d[.:]\d\d$/, c.time.replace(":", "."))}`);
  return lines.join("\n");
}
// Dipanggil tiap menit: laporan terjadwal + peringatan disk/RAM/layanan (maks. 1x per 6 jam per masalah)
let HEALTH_BUSY = false;
async function healthTick() {
  if (HEALTH_BUSY) return;
  HEALTH_BUSY = true;
  try {
    const d = loadData();
    const tg = tgConfig(d);
    const c = healthConf(d);
    if (!tg.active || (!c.enabled && !c.alerts)) return;
    const st = healthStateLoad();
    st.alerts = st.alerts || {};
    const now = Date.now();
    let x = null;
    if (c.enabled) {
      if (!st.lastSent) { st.lastSent = 0; st.firstDue = st.firstDue || healthNext(d, now); }
      const due = st.lastSent ? healthNext(d) : st.firstDue;
      if (now >= due) {
        x = await vpsHealth(d);
        tgEnqueue(healthMsg(d, x));
        st.lastSent = now;
        delete st.firstDue;
        logActivity(null, "Laporan kesehatan VPS dikirim", `CPU ${x.cpu == null ? "-" : x.cpu + "%"} · RAM ${x.mem.pct}% · disk ${x.disk ? x.disk.pct + "%" : "-"}`);
      }
    }
    if (c.alerts && (!st.lastCheck || now - st.lastCheck >= 5 * 60e3)) {
      st.lastCheck = now;
      x = x || (await vpsHealth(d));
      const probs = {};
      if (x.disk && x.disk.pct >= 90) probs.disk = `Disk ${x.disk.pct}% (${fmtBytes(x.disk.used)} / ${fmtBytes(x.disk.total)})`;
      if (x.mem.pct >= 90) probs.ram = `RAM ${x.mem.pct}% (${fmtBytes(x.mem.used)} / ${fmtBytes(x.mem.total)})`;
      for (const v of x.services) if (!v.active) probs["svc:" + v.unit] = `Layanan ${v.label} mati (${v.unit})`;
      const fresh = [], again = [], fixed = [];
      for (const [k, t] of Object.entries(probs)) {
        const a = st.alerts[k];
        if (!a) { fresh.push(t); st.alerts[k] = { since: now, last: now }; }
        else if (now - a.last >= 6 * 3600e3) { again.push(t); a.last = now; }
      }
      for (const k of Object.keys(st.alerts)) if (!probs[k]) { fixed.push(k.startsWith("svc:") ? `Layanan ${(x.services.find((v) => "svc:" + v.unit === k) || { label: k.slice(4) }).label} berjalan lagi` : k === "disk" ? "Disk di bawah 90% lagi" : "RAM di bawah 90% lagi"); delete st.alerts[k]; }
      if (fresh.length || again.length) tgEnqueue(`⚠️ <b>PERINGATAN VPS</b>\n${[...fresh, ...again].map((t) => "• " + t).join("\n")}\n${brandOf(d)} · ${fmtClock(now, tzName(d), true)}`);
      if (fixed.length) tgEnqueue(`✅ <b>VPS NORMAL LAGI</b>\n${fixed.map((t) => "• " + t).join("\n")}`);
      if (fresh.length) logActivity(null, "Peringatan VPS", fresh.join(" · "));
    }
    healthStateSave(st);
    tgFlush();
  } catch (e) {
    console.error("Cek kesehatan VPS gagal:", e.message);
  } finally {
    HEALTH_BUSY = false;
  }
}

// ---------- Sesi & keamanan login ----------
// Sesi disimpan ke berkas (hanya hash token) agar tidak logout saat panel di-restart.
// Sesi berakhir bila pengguna diam (tanpa klik/ketik/pindah halaman) melewati batas di Pengaturan → Keamanan.
const SESSION_FILE = path.dirname(DATA_FILE) + "/sessions.json";
const BLOCK_FILE = path.dirname(DATA_FILE) + "/login-block.json";
const IDLE_CHOICES = [15, 30, 60, 240, 720];
const BLOCK_STEPS = [5 * 60e3, 30 * 60e3, 24 * 3600e3]; // blokir bertingkat
const sessions = new Map(); // hash token -> { created, last, seen, ip, ua }
const tokHash = (t) => crypto.createHash("sha256").update(String(t)).digest("hex");
function secConf(d) {
  const x = ((d || loadData()).settings || {}).security || {};
  const idleMin = IDLE_CHOICES.includes(parseInt(x.idleMin, 10)) ? parseInt(x.idleMin, 10) : 60;
  return { idleMin, notifyBlock: x.notifyBlock !== false };
}
let IDLE_MS = secConf().idleMin * 60e3;
let sessSaveTimer = null;
function sessionsSave(now) {
  const write = () => {
    sessSaveTimer = null;
    try {
      const o = {};
      const n = Date.now();
      for (const [k, v] of sessions) if (n - v.last <= IDLE_MS) o[k] = v;
      fs.writeFileSync(SESSION_FILE + ".tmp", JSON.stringify(o), { mode: 0o600 });
      fs.renameSync(SESSION_FILE + ".tmp", SESSION_FILE);
    } catch (e) {
      // abaikan
    }
  };
  if (now) return write();
  if (!sessSaveTimer) sessSaveTimer = setTimeout(write, 30 * 1000);
}
function sessionsLoad() {
  try {
    const o = JSON.parse(fs.readFileSync(SESSION_FILE, "utf8"));
    const n = Date.now();
    for (const [k, v] of Object.entries(o)) {
      if (!/^[a-f0-9]{64}$/.test(k)) continue;
      // format lama: angka waktu kedaluwarsa
      const r = typeof v === "number" ? (v > n ? { created: n, last: n, seen: n, ip: "", ua: "" } : null) : v;
      if (r && n - (r.last || 0) <= IDLE_MS) sessions.set(k, r);
    }
  } catch (e) {
    // belum ada
  }
}
sessionsLoad();
function newSession(req) {
  const t = crypto.randomBytes(32).toString("hex");
  const n = Date.now();
  sessions.set(tokHash(t), { created: n, last: n, seen: n, ip: clientIp(req), ua: String(req.headers["user-agent"] || "").slice(0, 300) });
  sessionsSave(true);
  return t;
}
function getCookie(req, name) {
  const h = req.headers.cookie || "";
  for (const part of h.split(";")) {
    const i = part.indexOf("=");
    if (i > 0 && part.slice(0, i).trim() === name) return decodeURIComponent(part.slice(i + 1).trim());
  }
  return "";
}
// Header X-Idle (detik sejak aktivitas terakhir di browser) dikirim halaman panel.
// Penyegaran otomatis membawa nilai idle yang terus bertambah, jadi tidak memperpanjang sesi.
function authed(req) {
  const t = getCookie(req, "vpnacs");
  const k = t && tokHash(t);
  const r = k && sessions.get(k);
  if (!r) return false;
  const n = Date.now();
  const hdr = req.headers["x-idle"];
  const idle = hdr === undefined ? 0 : Math.max(0, parseInt(hdr, 10) || 0);
  const act = Math.min(n, n - idle * 1000);
  if (act > r.last) r.last = act;
  if (n - r.last > IDLE_MS) {
    sessions.delete(k);
    sessionsSave();
    return false;
  }
  r.seen = n;
  r.ip = clientIp(req) || r.ip;
  req.sessKey = k;
  sessionsSave();
  return true;
}
// Ringkas user-agent: "Chrome · Windows"
function uaLabel(ua) {
  ua = String(ua || "");
  const b = /Edg\//.test(ua) ? "Edge" : /OPR\/|Opera/.test(ua) ? "Opera" : /SamsungBrowser/.test(ua) ? "Samsung Internet" : /Firefox\//.test(ua) ? "Firefox" : /Chrome\//.test(ua) ? "Chrome" : /Safari\//.test(ua) ? "Safari" : /curl\//.test(ua) ? "curl" : "Browser";
  const o = /Android/.test(ua) ? "Android" : /iPhone|iPad/.test(ua) ? "iPhone/iPad" : /Windows/.test(ua) ? "Windows" : /Mac OS X/.test(ua) ? "macOS" : /Linux/.test(ua) ? "Linux" : "";
  return o ? `${b} · ${o}` : b;
}
function sessionList(req) {
  const n = Date.now();
  const out = [];
  for (const [k, r] of sessions) {
    if (n - r.last > IDLE_MS) continue;
    out.push({ id: k.slice(0, 16), device: uaLabel(r.ua), mobile: /Android|iPhone|iPad|Mobile/.test(r.ua || ""), ip: r.ip || "", created: r.created || null, last: r.last, seen: r.seen || r.last, current: k === req.sessKey });
  }
  return out.sort((a, b) => b.current - a.current || b.seen - a.seen);
}
function sessionsDrop(keep, idPrefix) {
  let n = 0;
  for (const k of [...sessions.keys()]) {
    if (k === keep) continue;
    if (idPrefix && !k.startsWith(idPrefix)) continue;
    sessions.delete(k);
    n++;
  }
  sessionsSave(true);
  return n;
}
// Blokir salah password bertingkat, disimpan ke berkas agar tetap berlaku setelah restart
const loginFails = new Map(); // ip -> { n, level, until, last }
try {
  const o = JSON.parse(fs.readFileSync(BLOCK_FILE, "utf8"));
  for (const [ip, v] of Object.entries(o)) if (v && typeof v === "object") loginFails.set(ip, v);
} catch (e) {
  // belum ada
}
function blockSave() {
  try {
    const o = {};
    const n = Date.now();
    for (const [ip, v] of loginFails) if (v.until > n || n - (v.last || 0) < 24 * 3600e3) o[ip] = v;
    fs.writeFileSync(BLOCK_FILE + ".tmp", JSON.stringify(o), { mode: 0o600 });
    fs.renameSync(BLOCK_FILE + ".tmp", BLOCK_FILE);
  } catch (e) {
    // abaikan
  }
}
function blockList() {
  const n = Date.now();
  return [...loginFails.entries()].filter(([, v]) => v.until > n).map(([ip, v]) => ({ ip, until: v.until, level: v.level || 1, total: v.total || 0 })).sort((a, b) => b.until - a.until);
}
function clientIp(req) {
  let ip = req.socket.remoteAddress || "";
  if (req.socket.encrypted && PROXY_IPS.has(req.socket.remotePort)) ip = PROXY_IPS.get(req.socket.remotePort);
  return ip.replace(/^::ffff:/, "");
}
function cookieFlags(req) {
  return "HttpOnly; SameSite=Strict; Path=/" + (req.socket.encrypted ? "; Secure" : "");
}

// ---------- HTTP ----------
function send(res, code, obj, headers) {
  const body = typeof obj === "string" ? obj : JSON.stringify(obj);
  res.writeHead(code, Object.assign({
    "Content-Type": typeof obj === "string" ? "text/plain; charset=utf-8" : "application/json; charset=utf-8",
    "Cache-Control": "no-store",
    "X-Content-Type-Options": "nosniff",
    "X-Frame-Options": "DENY",
  }, headers || {}));
  res.end(body);
}
function readBody(req) {
  return new Promise((resolve, reject) => {
    let size = 0;
    const chunks = [];
    req.on("data", (c) => {
      size += c.length;
      if (size > 64 * 1024) {
        reject(new Error("too large"));
        req.destroy();
      } else chunks.push(c);
    });
    req.on("end", () => {
      try {
        const t = Buffer.concat(chunks).toString("utf8");
        resolve(t ? JSON.parse(t) : {});
      } catch (e) {
        reject(e);
      }
    });
    req.on("error", reject);
  });
}

let INDEX_HTML = "";
function indexHtml() {
  if (!INDEX_HTML || process.env.VPNACS_DEV === "1")
    INDEX_HTML = fs.readFileSync(path.join(APP_DIR, "public", "index.html"), "utf8");
  return INDEX_HTML;
}

async function handleApi(req, res, url) {
  const method = req.method;
  const p = url.pathname;

  if (method !== "GET" && !(req.headers["content-type"] || "").includes("application/json"))
    return send(res, 415, { error: "Content-Type harus application/json" });
  let body = {};
  if (method !== "GET") {
    try {
      body = await readBody(req);
    } catch (e) {
      return send(res, 400, { error: "Data yang dikirim tidak valid." });
    }
  }

  // --- Login ---
  if (p === "/api/login" && method === "POST") {
    const ip = clientIp(req);
    const now = Date.now();
    const f = loginFails.get(ip) || { n: 0, level: 0, until: 0, last: 0, total: 0 };
    if (f.until > now) {
      const sec = Math.ceil((f.until - now) / 1000);
      return send(res, 429, { error: `Terlalu banyak percobaan. Coba lagi dalam ${sec >= 3600 ? Math.ceil(sec / 3600) + " jam" : sec >= 60 ? Math.ceil(sec / 60) + " menit" : sec + " detik"}.` });
    }
    // Tingkat blokir turun lagi bila 24 jam tanpa percobaan salah
    if (f.last && now - f.last > 24 * 3600e3) { f.level = 0; f.n = 0; }
    const d = loadData();
    if (!checkPassword(body.password || "", d.admin)) {
      f.n += 1;
      f.total = (f.total || 0) + 1;
      f.last = now;
      if (f.n >= 5) {
        const dur = BLOCK_STEPS[Math.min(f.level || 0, BLOCK_STEPS.length - 1)];
        f.level = Math.min((f.level || 0) + 1, BLOCK_STEPS.length);
        f.until = now + dur;
        f.n = 0;
        const lama = fmtDur(dur);
        logActivity(req, "Login diblokir", `${ip} · 5 kali salah password, diblokir ${lama} (tingkat ${f.level})`);
        if (secConf(d).notifyBlock && tgConfig(d).active) {
          tgEnqueue(`🛡️ <b>LOGIN PANEL DIBLOKIR</b>\nIP <code>${ip}</code> salah password 5 kali.\nDiblokir ${lama} (tingkat ${f.level} dari 3) · total ${f.total} percobaan salah.\n${brandOf(d)} · ${fmtClock(now, tzName(d), true)}`);
          tgFlush();
        }
      } else logActivity(req, "Login gagal", "Password salah");
      loginFails.set(ip, f);
      blockSave();
      await new Promise((r) => setTimeout(r, 800));
      return send(res, 401, { error: "Password salah." });
    }
    if (loginFails.has(ip)) {
      // Login berhasil: hitungan salah direset, tingkat blokir tetap diingat 24 jam
      f.n = 0;
      loginFails.set(ip, f);
      blockSave();
    }
    const t = newSession(req);
    logActivity(req, "Login berhasil", uaLabel(req.headers["user-agent"]));
    return send(res, 200, { ok: true }, { "Set-Cookie": `vpnacs=${t}; ${cookieFlags(req)}; Max-Age=${30 * 86400}` });
  }
  if (p === "/api/logout" && method === "POST") {
    if (authed(req)) logActivity(req, "Logout", "");
    sessions.delete(tokHash(getCookie(req, "vpnacs")));
    sessionsSave(true);
    return send(res, 200, { ok: true }, { "Set-Cookie": `vpnacs=; ${cookieFlags(req)}; Max-Age=0` });
  }
  if (p === "/api/me" && method === "GET") return send(res, 200, { loggedIn: authed(req), panelName: brandOf(loadData()) });
  // Tanda aktivitas dari browser (klik/ketik) dan sisa waktu sesi
  if (p === "/api/session" && (method === "GET" || method === "POST")) {
    if (!authed(req)) return send(res, 401, { error: "Sesi berakhir. Silakan login lagi." });
    const r = sessions.get(req.sessKey);
    return send(res, 200, { idleMs: IDLE_MS, remainMs: Math.max(0, IDLE_MS - (Date.now() - r.last)) });
  }
  // Jalur data untuk add-on (hanya dari dalam VPS, wajib kunci add-on)
  if (p.startsWith("/api/addon/")) {
    const ip = (req.socket.remoteAddress || "").replace(/^::ffff:/, "");
    const d = loadData();
    const key = String(req.headers["x-addon-key"] || "");
    const ok = (ip === "127.0.0.1" || ip === "::1") && d.settings && d.settings.addonKey && key.length === d.settings.addonKey.length && crypto.timingSafeEqual(Buffer.from(key), Buffer.from(d.settings.addonKey));
    if (!ok) return send(res, 403, { error: "Akses ditolak" });
    if (p === "/api/addon/routers" && method === "GET") {
      const st = settings(d);
      const links = await siteLinks(d);
      const h = loadHistory();
      const now = Date.now();
      return send(res, 200, {
        panel: { name: st.brand, version: VERSION, url: panelPublicUrl(st, d), tunnelLocal: st.tun.local, ztVpsIp: st.zt ? st.zt.vpsIp : "" },
        routers: d.sites.map((x) => {
          const v = siteView(x, st, links, h, now);
          return {
            id: x.id,
            name: x.name,
            note: x.note || "",
            transport: trOf(x),
            address: isZt(x) ? x.ztIp || "" : isWg(x) ? x.wgIp || "" : x.tunnelIp,
            vpsAddress: isZt(x) ? (st.zt ? st.zt.vpsIp : "") : isWg(x) ? (st.wg ? st.wg.vpsIp : "") : st.tun.local,
            realSubnet: x.realSubnet,
            virtualSubnet: x.virtualSubnet,
            state: v.state,
            online: v.state === "up",
            downSince: v.downSince,
            uptime: v.uptime || null,
            panelLink: `#/router/${x.id}`,
          };
        }),
      });
    }
    return send(res, 404, { error: "Tidak ditemukan." });
  }
  // Dipanggil script MikroTik (tanpa login): router ZeroTier melapor Node ID-nya memakai kunci per router
  if (p === "/api/zt/join" && method === "GET") {
    const k = String(url.searchParams.get("k") || "");
    const n = String(url.searchParams.get("n") || "").trim().toLowerCase();
    if (!/^[0-9a-f]{24}$/.test(k) || !/^[0-9a-f]{10}$/.test(n)) return send(res, 400, "Permintaan tidak valid");
    const d = loadData();
    const site = d.sites.find((x) => isZt(x) && x.joinKey && x.joinKey.length === k.length && crypto.timingSafeEqual(Buffer.from(x.joinKey), Buffer.from(k)));
    if (!site) return send(res, 404, "Router tidak ditemukan");
    if (site.ztNode === n && site.ztIp) return send(res, 200, `OK ${site.ztIp}`);
    const before = site.ztNode;
    const r = await ztBind(d, site, n);
    if (r.error) {
      logActivity(req, "Router ZeroTier gagal terdaftar otomatis", `${site.name} · node ${n} · ${r.error}`);
      return send(res, 409, r.error);
    }
    saveData(d);
    logActivity(req, "Router ZeroTier terdaftar otomatis", `${site.name} · node ${n}${before && before !== n ? ` (sebelumnya ${before})` : ""} · IP ${site.ztIp}`);
    await applyFirewall(d);
    ztPingAll(d).catch(() => {});
    return send(res, 200, `OK ${site.ztIp}`);
  }

  if (!authed(req)) return send(res, 401, { error: "Silakan login dulu." });

  // --- Ringkasan ---
  if (p === "/api/overview" && method === "GET") {
    const d = loadData();
    const st = settings(d);
    const links = await siteLinks(d);
    const h = loadHistory();
    const now = Date.now();
    const tg = tgConfig(d);
    const cf = (d.settings && d.settings.cloudflare) || null;
    const tz = tzName(d);
    return send(res, 200, {
      settings: {
        publicIp: st.publicIp,
        pskSet: !!st.psk,
        psk: st.psk,
        useIpsec: st.useIpsec,
        genieCidr: st.genieCidr,
        virtualPool: VIRTUAL_POOL,
        acsUrl: `http://${st.tun.local}:${ACS_PORT}`,
        defaultPassword: isDefaultPw(d),
        genieUrl: genieUrl(d, st.publicIp),
        genieUrlManual: (d.settings && d.settings.genieUrl) || "",
        zt: st.zt ? { nwid: st.zt.nwid, name: st.zt.name, subnet: st.zt.subnet, vpsIp: st.zt.vpsIp, iface: st.zt.iface, checkError: st.zt.checkError || "" } : null,
        wg: st.wg ? { subnet: st.wg.subnet, vpsIp: st.wg.vpsIp, port: st.wg.port, pub: st.wg.pub, up: WG_UP } : null,
        tunnelNet: st.tun.net,
        tunnelLocal: st.tun.local,
        tunnelStatic: `${intToIp(st.tun.first)} - ${intToIp(st.tun.last)}`,
        tunnelPool: `${st.tun.poolStart} - ${st.tun.poolEnd}`,
        tunnelMax: st.tun.last - st.tun.first + 1,
        presets: SERVICE_PRESETS,
        autoPortStart: FWD_AUTO_START,
        reservedPorts: Array.from(RESERVED_PORTS),
        port: PORT,
        stdPorts: { enabled: stdWanted(d), active: STD_ON, error: STD_ERR, http: STD_ON ? STD_PORTS.http : stdConf(d).http, https: STD_ON ? STD_PORTS.https : stdConf(d).https, defHttp: stdDef("http"), defHttps: stdDef("https") },
        panelUrl: panelPublicUrl(st, d),
        addons: Object.fromEntries(Object.entries(ADDONS).map(([id, a]) => [id, { installed: addonInstalled(d, id), kind: a.kind, name: a.name, icon: a.icon, color: a.color || "blue", tagline: a.tagline || "", path: a.kind === "aplikasi" ? addonPath(d, id) : "", url: a.kind === "aplikasi" ? addonUrl(d, id) : "" }])),
        version: VERSION,
        updates: updateSummary(),
        panelName: st.brand,
        brandHistory: st.brands.filter((n) => n !== st.brand),
        timezone: tz,
        timezones: Object.entries(TIMEZONES).map(([id, v]) => ({ id, label: v.label })),
        telegram: {
          enabled: tg.enabled,
          active: tg.active,
          tokenSet: !!tg.token,
          tokenMask: tg.token ? tg.token.split(":")[0] + ":••••" + tg.token.slice(-4) : "",
          botName: tg.botName,
          chatId: tg.chatId,
          chatTitle: tg.chatTitle,
          threadId: tg.threadId,
          threadName: tg.threadName,
          delayMin: tg.delayMin,
          notifyRecovery: tg.notifyRecovery,
          remindMin: tg.remindMin,
          quietStart: tg.quietStart,
          quietEnd: tg.quietEnd,
          lastOk: TG_STATUS.lastOk,
          lastError: TG_STATUS.lastError,
          lastErrorAt: TG_STATUS.lastErrorAt,
        },
        cloudflare: cf
          ? { domain: cf.domain, zoneName: cf.zoneName, ip: cf.ip, https: !!cf.https, subdomains: d.settings.subdomains || {}, subServices: Object.entries(subServices(d)).map(([k, x]) => ({ key: k, label: x.label, def: x.def, port: x.stdOnly ? 0 : x.port(), addon: !!x.addon })), stdActive: STD_ON, httpsActive: HTTPS_ON, appliedAt: cf.appliedAt, certExpiry: cf.https ? certExpiry(cf.domain) : null, publicIpBefore: d.settings.publicIpBeforeCf || "" }
          : null,
      },
      sites: d.sites.map((s) => {
        const v = siteView(s, st, links, h, now);
        // Ringkasan uptime untuk dashboard
        const hs = siteHistory(s, h, now, tz);
        if (!hs.pending) {
          v.uptime = hs.uptime;
          v.days = hs.days.map((x) => x.status);
          v.incidents30 = hs.events.filter((e) => e.s >= now - 30 * DAY_MS).length;
        }
        return v;
      }),
    });
  }

  // --- Log aktivitas ---
  if (p === "/api/activity" && method === "GET") {
    const q = String(url.searchParams.get("q") || "").trim().toLowerCase();
    let a = readJson(ACTIVITY_FILE, []);
    if (!Array.isArray(a)) a = [];
    a = a.slice().reverse();
    if (q) a = a.filter((x) => [x.a, x.d, x.ip].join(" ").toLowerCase().includes(q));
    return send(res, 200, { total: a.length, items: a.slice(0, 300), tz: TIMEZONES[tzName(loadData())].label });
  }

  // --- Telegram ---
  if (p.startsWith("/api/telegram/") && method === "POST") {
    const d = loadData();
    const saved = tgConfig(d);
    const token = String(body.token || "").trim() || saved.token;
    if (!token) return send(res, 400, { error: "Isi token bot dulu." });
    if (!/^\d{5,}:[A-Za-z0-9_-]{30,}$/.test(token)) return send(res, 400, { error: "Format token salah. Contoh: 123456789:AAH…  (salin dari @BotFather)" });
    if (p === "/api/telegram/detect") {
      const r = await tgDetect(token);
      if (r.error) return send(res, 400, { error: r.error, webhook: !!r.webhook });
      return send(res, 200, r);
    }
    if (p === "/api/telegram/webhook") {
      const r = await tgCall(token, "getWebhookInfo", {});
      if (!(r.json && r.json.ok)) return send(res, 400, { error: tgErr(r) });
      const w = r.json.result || {};
      return send(res, 200, { url: w.url || "", pending: w.pending_update_count || 0, lastError: w.last_error_message || "" });
    }
    if (p === "/api/telegram/delete-webhook") {
      const info = await tgCall(token, "getWebhookInfo", {});
      const oldUrl = (info.json && info.json.ok && info.json.result && info.json.result.url) || "";
      const r = await tgCall(token, "deleteWebhook", { drop_pending_updates: false });
      if (!(r.json && r.json.ok)) return send(res, 400, { error: tgErr(r) });
      logActivity(req, "Webhook bot Telegram dihapus", oldUrl ? `Sebelumnya: ${oldUrl.replace(/(bot)?\d{5,}:[A-Za-z0-9_-]{30,}/g, "•••")}` : "Tidak ada webhook aktif");
      return send(res, 200, { ok: true, oldUrl });
    }
    if (p === "/api/telegram/test") {
      const chatId = String(body.chatId || saved.chatId || "").trim();
      if (!chatId) return send(res, 400, { error: "Pilih grup dulu (klik Deteksi grup & topik)." });
      const c = { token, chatId, threadId: parseInt(body.threadId, 10) || 0 };
      const tz = tzName(d);
      const r = await tgSend(c, `✅ <b>Tes notifikasi</b>\n${escHtml(brandOf(d))} terhubung. Notifikasi VPN terputus akan dikirim ke sini.\n<i>${fmtClock(Date.now(), tz, true)} ${TIMEZONES[tz].label}</i>`, false);
      if (!r.ok) return send(res, 400, { error: r.error });
      logActivity(req, "Tes notifikasi Telegram", body.chatTitle || chatId);
      return send(res, 200, { ok: true });
    }
  }
  if (p === "/api/telegram" && method === "PUT") {
    const d = loadData();
    d.settings = d.settings || {};
    const old = d.settings.telegram || {};
    const t = Object.assign({}, old);
    if (body.clear) {
      delete d.settings.telegram;
      saveData(d);
      tgQueue.length = 0;
      logActivity(req, "Telegram dihapus", "Token dan grup dihapus dari panel");
      return send(res, 200, { ok: true });
    }
    const token = String(body.token || "").trim();
    if (token) {
      if (!/^\d{5,}:[A-Za-z0-9_-]{30,}$/.test(token)) return send(res, 400, { error: "Format token salah. Contoh: 123456789:AAH…  (salin dari @BotFather)" });
      t.token = token;
    }
    if (body.botName !== undefined) t.botName = String(body.botName || "").slice(0, 64);
    if (body.chatId !== undefined) {
      const cid = String(body.chatId || "").trim();
      if (cid && !/^-?\d+$/.test(cid)) return send(res, 400, { error: "ID grup tidak valid." });
      t.chatId = cid;
      t.chatTitle = String(body.chatTitle || "").slice(0, 128);
      t.threadId = parseInt(body.threadId, 10) || 0;
      t.threadName = t.threadId ? String(body.threadName || "").slice(0, 128) : "";
    }
    const hm = (v) => v === "" || /^([01]\d|2[0-3]):[0-5]\d$/.test(v);
    const qs = String(body.quietStart || "");
    const qe = String(body.quietEnd || "");
    if (!hm(qs) || !hm(qe)) return send(res, 400, { error: "Jam tenang harus berformat JJ:MM, contoh 23:00." });
    if (!!qs !== !!qe) return send(res, 400, { error: "Isi jam mulai dan jam selesai jam tenang, atau kosongkan keduanya." });
    const delay = parseInt(body.delayMin, 10);
    if (!(delay >= 1 && delay <= 1440)) return send(res, 400, { error: "Jeda sebelum lapor harus 1–1440 menit." });
    const remind = parseInt(body.remindMin, 10);
    if (!(remind === 0 || (remind >= 10 && remind <= 1440))) return send(res, 400, { error: "Pengingat harus 0 (mati) atau 10–1440 menit." });
    t.enabled = body.enabled !== false;
    t.delayMin = delay;
    t.remindMin = remind;
    t.notifyRecovery = body.notifyRecovery !== false;
    t.quietStart = qs;
    t.quietEnd = qe;
    if (t.enabled && !t.token) return send(res, 400, { error: "Isi token bot dulu." });
    if (t.enabled && !t.chatId) return send(res, 400, { error: "Pilih grup tujuan dulu (klik Deteksi grup & topik)." });
    if (body.timezone !== undefined && TIMEZONES[body.timezone]) d.settings.timezone = body.timezone;
    d.settings.telegram = t;
    saveData(d);
    logActivity(req, "Pengaturan Telegram disimpan", `${t.enabled ? "Aktif" : "Nonaktif"} · ${t.chatTitle || t.chatId || "-"}${t.threadName ? " / " + t.threadName : ""} · jeda ${t.delayMin} menit`);
    return send(res, 200, { ok: true });
  }

  // --- Cloudflare ---
  if (p === "/api/cloudflare/start" && method === "POST") {
    const d = loadData();
    const saved = (d.settings && d.settings.cloudflare) || {};
    const domain = String(body.domain || "").trim().toLowerCase().replace(/\.$/, "");
    if (!isHostname(domain)) return send(res, 400, { error: "Domain tidak valid. Contoh: vpn.domainanda.com" });
    const token = String(body.token || "").trim() || saved.token || "";
    if (!token) return send(res, 400, { error: "Isi API token Cloudflare." });
    if (!/^[A-Za-z0-9_-]{20,}$/.test(token)) return send(res, 400, { error: "Format token tidak valid. Pakai API Token (bukan Global API Key)." });
    if (CF_JOB && !CF_JOB.done) await (CF_JOB.kind === "sub" ? cfRollbackSub(CF_JOB) : cfRollback(CF_JOB));
    CF_JOB = { id: crypto.randomBytes(8).toString("hex"), domain, token, https: body.https !== false, tz: tzName(d), steps: cfSteps(body.https !== false), idx: 0, ctx: {}, created: Date.now(), done: false };
    return send(res, 200, { jobId: CF_JOB.id, steps: CF_JOB.steps });
  }
  if (p === "/api/cloudflare/subs" && method === "POST") {
    const d = loadData();
    const cf = d.settings && d.settings.cloudflare;
    if (!cf || !cf.token || !cf.zoneId) return send(res, 400, { error: "Hubungkan domain Cloudflare dulu." });
    const subs = {};
    const SUB_SERVICES = subServices(d);
    for (const svc of Object.keys(SUB_SERVICES)) {
      const label = String((body[svc] === undefined ? "" : body[svc]) || "").trim().toLowerCase();
      if (!label) continue;
      if (!/^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$/.test(label)) return send(res, 400, { error: `Nama subdomain ${SUB_SERVICES[svc].label} tidak valid. Pakai huruf kecil, angka, atau tanda minus, contoh: ${SUB_SERVICES[svc].def}` });
      const host = `${label}.${cf.zoneName}`;
      if (host === cf.domain) return send(res, 400, { error: `${host} sudah dipakai panel. Pilih nama lain.` });
      if (Object.values(subs).includes(host)) return send(res, 400, { error: `Subdomain ${host} dipakai dua kali. Pilih nama yang berbeda.` });
      if (SUB_SERVICES[svc].stdOnly && !STD_ON) return send(res, 400, { error: `Subdomain ${SUB_SERVICES[svc].label} butuh Alamat panel (port web) aktif di Pengaturan → Umum.` });
      subs[svc] = host;
    }
    if (CF_JOB && !CF_JOB.done) await (CF_JOB.kind === "sub" ? cfRollbackSub(CF_JOB) : cfRollback(CF_JOB));
    CF_JOB = { id: crypto.randomBytes(8).toString("hex"), kind: "sub", domain: cf.zoneName, token: cf.token, subs, tz: tzName(d), steps: cfSubSteps(subs), idx: 0, ctx: { zone: { id: cf.zoneId, name: cf.zoneName } }, created: Date.now(), done: false };
    return send(res, 200, { jobId: CF_JOB.id, steps: CF_JOB.steps });
  }
  if (p === "/api/cloudflare/step" && method === "POST") {
    const job = CF_JOB;
    if (!job || job.id !== body.jobId || job.done) return send(res, 400, { error: "Proses sudah berakhir. Mulai ulang." });
    const step = job.steps[job.idx];
    if (!step || step.key !== body.key) return send(res, 400, { error: "Urutan langkah tidak sesuai." });
    let r;
    try {
      r = job.kind === "sub" ? await cfRunSubStep(job, step.key) : await cfRunStep(job, step.key);
    } catch (e) {
      r = { ok: false, detail: "Terjadi kesalahan: " + e.message };
    }
    if (r.ok === false) {
      const notes = job.kind === "sub" ? await cfRollbackSub(job) : await cfRollback(job);
      r.rolledBack = true;
      r.rollbackNote = "Dibatalkan, pengaturan tetap seperti semula" + (notes.length ? ` (${notes.join(", ")})` : "") + ".";
      logActivity(req, "Cloudflare gagal", `${job.domain}: ${step.label} — ${r.detail}`);
    } else {
      job.idx++;
      if (step.key === "apply") {
        job.done = true;
        logActivity(req, "Cloudflare diterapkan", `${job.domain} → ${job.ctx.ip}${job.https ? " + HTTPS" : ""}`);
      }
      if (step.key === "sapply") {
        job.done = true;
        logActivity(req, "Subdomain layanan diterapkan", r.detail);
      }
    }
    return send(res, 200, Object.assign({ key: step.key }, r));
  }
  if (p === "/api/cloudflare/cancel" && method === "POST") {
    if (CF_JOB && CF_JOB.id === body.jobId && !CF_JOB.done) await (CF_JOB.kind === "sub" ? cfRollbackSub(CF_JOB) : cfRollback(CF_JOB));
    return send(res, 200, { ok: true });
  }
  if (p === "/api/cloudflare/remove" && method === "POST") {
    const d = loadData();
    const s = d.settings || {};
    if (!s.cloudflare) return send(res, 400, { error: "Cloudflare belum dipakai." });
    const dom = s.cloudflare.domain;
    s.publicIp = s.publicIpBeforeCf && s.publicIpBeforeCf !== dom ? s.publicIpBeforeCf : "";
    delete s.cloudflare;
    delete s.publicIpBeforeCf;
    d.settings = s;
    saveData(d);
    httpsDisable();
    try {
      fs.unlinkSync(CF_INI);
    } catch (e) {
      // abaikan
    }
    logActivity(req, "Cloudflare dilepas", `${dom} tidak dipakai lagi, kembali ke ${s.publicIp || "IP otomatis"}`);
    return send(res, 200, { ok: true });
  }

  // --- GenieACS ---
  if (p === "/api/genie/ranges" && method === "PUT") {
    const d = loadData();
    const raw = Array.isArray(body.extra) ? body.extra : String(body.extra || "").split(/[\s,;]+/);
    const r = checkGenieExtra(d, raw);
    if (r.error) return send(res, 400, { error: r.error });
    d.settings = d.settings || {};
    const before = (d.settings.genieExtra || []).join(", ") || "(kosong)";
    d.settings.genieExtra = r.list;
    saveData(d);
    logActivity(req, "Rentang tambahan GenieACS diubah", `${before} → ${r.list.join(", ") || "(kosong)"}`);
    const s2 = await genieSync(d, req);
    if (s2.error) return send(res, 500, { error: s2.error });
    return send(res, 200, { ok: true, value: genieRanges(d).value, changed: !!s2.changed, restarted: !!s2.restarted, skipped: !!s2.skipped });
  }
  if (p === "/api/genie/inform" && method === "POST") {
    if (body.remove) {
      await genieInformRemove();
      logActivity(req, "Inform berkala ONT dihapus", "preset " + INFORM_PROV);
      return send(res, 200, { ok: true });
    }
    const iv = parseInt(body.interval, 10);
    if (![120, 240, 300, 600].includes(iv)) return send(res, 400, { error: "Pilih interval 120, 240, 300, atau 600 detik." });
    const r = await genieInformInstall(iv);
    if (r.error) return send(res, 400, { error: r.error });
    GENIE_CACHE.t = 0;
    logActivity(req, "Inform berkala ONT dipasang", `tiap ${iv} detik (provision ${INFORM_PROV})`);
    return send(res, 200, { ok: true });
  }
  if (p === "/api/genie" && method === "GET") {
    if (url.searchParams.get("refresh") === "1") GENIE_CACHE.t = 0;
    return send(res, 200, await genieStatus(loadData()));
  }

  // --- ZeroTier ---
  if (p === "/api/zt" && method === "GET") {
    await ztRefresh(req).catch((e) => console.error("Pemeriksaan ZeroTier gagal:", e.message));
    return send(res, 200, await ztStatus(loadData(), url.searchParams.get("nwid")));
  }
  // --- Add-on ---
  if (p === "/api/addons" && method === "GET") {
    const d = loadData();
    return send(res, 200, { list: await addonList(d), job: ADDON_JOB && !ADDON_JOB.done ? { id: ADDON_JOB.id, addon: ADDON_JOB.addon, title: ADDON_JOB.title } : null });
  }
  if (p === "/api/addons/job" && method === "GET") {
    if (!ADDON_JOB) return send(res, 200, { job: null });
    const j = ADDON_JOB;
    const now = Date.now();
    return send(res, 200, { job: { id: j.id, addon: j.addon, action: j.action || "", title: j.title, pct: j.pct || 0, cur: j.cur, detail: j.detail || "", steps: j.steps, log: (j.log || []).slice(-120), done: !!j.done, ok: !!j.ok, error: j.error || "", interrupted: !!j.interrupted, elapsed: Math.round(((j.done ? j.finished || now : now) - (j.started || now)) / 1000), quiet: j.done ? 0 : Math.round((now - (j.lastOut || now)) / 1000) } });
  }
  const am = p.match(/^\/api\/addons\/([a-z-]+)(?:\/(install|update|remove|check))?$/);
  if (am && ADDONS[am[1]]) {
    const id = am[1];
    const a = ADDONS[id];
    const action = am[2];
    if (action === "check" && method === "GET") {
      if (!addonInstalled(loadData(), id)) return send(res, 400, { error: `${a.name} belum dipasang.` });
      const checks = await addonCheck(id);
      const bad = checks.filter((x) => x.ok === false).length, warn = checks.filter((x) => x.ok === null).length;
      return send(res, 200, { name: a.name, checks, ok: !bad, bad, warn });
    }
    if (!action && method === "PUT") {
      if (a.kind !== "aplikasi") return send(res, 400, { error: "Add-on ini tidak punya alamat sendiri." });
      const v = "/" + String(body.path || "").trim().replace(/^\/+|\/+$/g, "").toLowerCase();
      if (!/^\/[a-z0-9][a-z0-9-]{1,29}$/.test(v)) return send(res, 400, { error: "Alamat 2-30 karakter: huruf kecil, angka, atau minus. Contoh: /acs" });
      if (RESERVED_PATHS.some((r) => v === r || v.startsWith(r + "/"))) return send(res, 400, { error: "Alamat itu dipakai panel." });
      const d = loadData();
      for (const [oid, oa] of Object.entries(ADDONS)) if (oid !== id && oa.kind === "aplikasi" && addonPath(d, oid) === v) return send(res, 400, { error: `Alamat ${v} sudah dipakai ${oa.name}.` });
      const A = (d.settings.addons = d.settings.addons || {});
      const before = addonPath(d, id);
      A[id] = Object.assign({}, A[id] || {}, { path: v });
      saveData(d);
      try {
        const f = addonDir(id) + "/data/panel-link.json";
        if (fs.existsSync(f)) {
          const j = JSON.parse(fs.readFileSync(f, "utf8"));
          j.prefix = v;
          fs.writeFileSync(f, JSON.stringify(j, null, 2));
        }
      } catch (e) {
        // abaikan
      }
      logActivity(req, `Alamat add-on ${a.name} diubah`, `${before} → ${v}`);
      return send(res, 200, { ok: true, path: v });
    }
    if (action && method === "POST") {
      if (ADDON_JOB && !ADDON_JOB.done) return send(res, 409, { error: `Masih ada proses berjalan: ${ADDON_JOB.title}. Tunggu sampai selesai.` });
      const d = loadData();
      let steps;
      let label;
      if (action === "install" || action === "update") {
        if (action === "update" && !addonInstalled(d, id)) return send(res, 400, { error: "Add-on belum terpasang." });
        steps = a.kind === "aplikasi" ? phpInstallSteps(id, req, { update: action === "update" }) : sysSteps(id, action);
        label = action === "install" ? "dipasang" : "diperbarui";
      } else if (action === "remove") {
        steps = a.kind === "aplikasi" ? phpRemoveSteps(id, !!body.purge) : sysSteps(id, "remove", !!body.purge);
        label = "dilepas";
      } else return send(res, 405, { error: "Pakai GET untuk pemeriksaan." });
      const job = { id: crypto.randomBytes(6).toString("hex"), addon: id, action, title: `Add-on ${a.name} ${label}`, log: [], steps: [], pct: 0, req, created: Date.now() };
      runJob(job, steps).catch((e) => {
        job.done = true;
        job.error = e.message;
      });
      return send(res, 200, { ok: true, id: job.id });
    }
  }
  // --- Pembaruan ---
  if (p === "/api/updates" && method === "GET") {
    if (url.searchParams.get("refresh") === "1" || !UPDATES) await checkUpdates();
    return send(res, 200, Object.assign({}, UPDATES, { canSelfUpdate: !!sourceDir(), version: VERSION }));
  }
  if (p === "/api/updates/panel" && method === "POST") {
    if (ADDON_JOB && !ADDON_JOB.done) return send(res, 409, { error: `Masih ada proses berjalan: ${ADDON_JOB.title}. Tunggu sampai selesai.` });
    if (!sourceDir()) return send(res, 400, { error: "Folder repo tidak diketahui. Perbarui sekali lewat SSH: cd /root/acs-netmap-panel && git pull && bash install-vpn-acs.sh" });
    const job = { id: crypto.randomBytes(6).toString("hex"), addon: "", action: "selfupdate", title: "Panel diperbarui", log: [], steps: [], pct: 0, req, created: Date.now() };
    runJob(job, selfUpdateSteps()).catch((e) => {
      job.done = true;
      job.error = e.message;
    });
    return send(res, 200, { ok: true, id: job.id });
  }
  // --- Port standar 80/443 ---
  if (p === "/api/stdports" && method === "POST") {
    if (ADDON_JOB && !ADDON_JOB.done) return send(res, 409, { error: `Masih ada proses berjalan: ${ADDON_JOB.title}. Tunggu sampai selesai.` });
    const on = !!body.enable;
    let want = null;
    if (on && (body.http !== undefined || body.https !== undefined)) {
      const d0 = loadData();
      const cur = stdConf(d0);
      want = { http: body.http === undefined || body.http === "" ? cur.http : parseInt(body.http, 10), https: body.https === undefined || body.https === "" ? cur.https : parseInt(body.https, 10) };
      const bad = stdPortCheck(d0, want.http, want.https);
      if (bad) return send(res, 400, { error: bad });
    }
    const tt = want ? `Port panel ${want.http}/${want.https}` : "Port standar";
    const job = { id: crypto.randomBytes(6).toString("hex"), addon: "", action: on ? "on" : "off", title: on ? `${tt} diaktifkan` : "Port standar dimatikan", log: [], steps: [], pct: 0, req, created: Date.now() };
    runJob(job, on ? stdOnSteps(want) : stdOffSteps()).catch((e) => {
      job.done = true;
      job.error = e.message;
    });
    return send(res, 200, { ok: true, id: job.id });
  }
  if (p === "/api/zt/free" && method === "GET") {
    await ztRefresh(req).catch(() => {});
    const r = await ztPending(loadData());
    if (r.error) return send(res, 400, { error: r.error });
    return send(res, 200, r);
  }
  if (p === "/api/zt/use" && method === "POST") {
    const d = loadData();
    const r = await ztUse(d, String(body.nwid || "").trim().toLowerCase());
    if (r.error) {
      logActivity(req, "ZeroTier gagal dihubungkan", r.error);
      return send(res, 400, { error: r.error });
    }
    saveData(d);
    await applyAll(d);
    saveData(d);
    logActivity(req, "ZeroTier dihubungkan", `Jaringan ${d.settings.zt.name || d.settings.zt.nwid} (${r.subnet}) · IP VPS ${r.vpsIp}`);
    return send(res, 200, r);
  }
  // Buat jaringan baru di controller VPS (opsional langsung dihubungkan)
  if (p === "/api/zt/networks" && method === "POST") {
    const d = loadData();
    const r = await ztCreateNetwork(d, body);
    if (r.error) return send(res, 400, { error: r.error });
    logActivity(req, "Jaringan ZeroTier dibuat", `${String(body.name || "").trim()} · ${r.subnet} · ${r.nwid}`);
    if (body.connect && !ztCfg(d)) {
      const u = await ztUse(d, r.nwid);
      if (u.error) return send(res, 200, { ok: true, nwid: r.nwid, connectError: u.error });
      saveData(d);
      await applyAll(d);
      saveData(d);
      logActivity(req, "ZeroTier dihubungkan", `Jaringan ${d.settings.zt.name || r.nwid} (${u.subnet}) · IP VPS ${u.vpsIp}`);
      return send(res, 200, { ok: true, nwid: r.nwid, connected: true, vpsIp: u.vpsIp, ready: u.ready });
    }
    return send(res, 200, { ok: true, nwid: r.nwid });
  }
  // Hapus jaringan dari controller (jaringan aktif: VPS dilepas dulu, tanpa router ZeroTier)
  const zn = p.match(/^\/api\/zt\/networks\/([0-9a-f]{16})$/);
  if (zn && method === "DELETE") {
    const nwid = zn[1];
    const d = loadData();
    const z = ztCfg(d);
    if (z && z.nwid === nwid) {
      const n = d.sites.filter(isZt).length;
      if (n) return send(res, 400, { error: `Jaringan ini dipakai ${n} router. Pindahkan router itu ke L2TP atau hapus dulu.` });
      await ztApi("DELETE", `/network/${nwid}`);
      delete d.settings.zt;
      saveData(d);
      await ensureLoAddr(d);
    }
    const c = await ztApi("GET", `/controller/network/${nwid}`);
    const r = await ztApi("DELETE", `/controller/network/${nwid}`);
    if (!r.ok && r.status !== 404) return send(res, 500, { error: "Controller ZeroTier menolak: " + r.error });
    logActivity(req, "Jaringan ZeroTier dihapus", `${(c.ok && c.json.name) || nwid} (${nwid})`);
    return send(res, 200, { ok: true });
  }
  // Ubah jaringan (jaringan panel atau jaringan lain di controller): nama, akses, rentang IP, pool, DNS
  if (p === "/api/zt/network" && method === "PUT") {
    const d = loadData();
    const z = await ztTarget(d, body.nwid);
    if (!z) return send(res, 400, { error: body.nwid ? "Jaringan tidak ditemukan di controller." : "ZeroTier belum dihubungkan." });
    const cur = await ztApi("GET", `/controller/network/${z.nwid}`);
    if (!cur.ok) return send(res, 500, { error: "Tidak bisa membaca jaringan: " + cur.error });
    const C = cur.json;
    const upd = {};
    const changes = [];
    if (body.name !== undefined) {
      const name = String(body.name || "").trim();
      if (!/^[\w .-]{1,64}$/.test(name)) return send(res, 400, { error: "Nama jaringan 1-64 karakter: huruf, angka, spasi, titik, minus, atau garis bawah." });
      if ((C.name || "") !== name) { upd.name = name; changes.push(`nama ${C.name || "-"} → ${name}`); }
    }
    if (body.private !== undefined) {
      const priv = body.private !== false;
      if ((C.private !== false) !== priv) { upd.private = priv; changes.push(priv ? "akses → private" : "akses → PUBLIC"); }
    }
    let sub = parseCidr(z.subnet);
    if (body.subnet !== undefined && String(body.subnet).trim() !== z.subnet) {
      // rentang lama tidak dihitung bentrok dengan dirinya sendiri
      const chk = ztSubnetCheck(d, String(body.subnet).trim());
      if (chk.error) return send(res, 400, { error: chk.error });
      sub = chk.sub;
      upd.routes = (C.routes || []).filter((r) => r.via).concat([{ target: sub.text, via: null }]);
      changes.push(`rentang ${z.subnet || "-"} → ${sub.text}`);
    }
    if (!sub && (body.poolStart || body.poolEnd)) return send(res, 400, { error: "Isi rentang IP jaringan dulu." });
    if (sub && (body.poolStart !== undefined || body.poolEnd !== undefined || upd.routes)) {
      const pool = ztPoolOf(sub, body.poolStart, body.poolEnd);
      if (pool.error) return send(res, 400, { error: pool.error });
      const old = (C.ipAssignmentPools || [])[0] || {};
      if (old.ipRangeStart !== pool.start || old.ipRangeEnd !== pool.end) {
        upd.ipAssignmentPools = [{ ipRangeStart: pool.start, ipRangeEnd: pool.end }];
        upd.v4AssignMode = { zt: true };
        changes.push(`pool ${pool.start} - ${pool.end}`);
      }
    }
    if (body.dns !== undefined) {
      const dom = String((body.dns && body.dns.domain) || "").trim().toLowerCase();
      const servers = String((body.dns && body.dns.servers) || "").split(/[\s,]+/).map((x) => x.trim()).filter(Boolean);
      if (dom && !/^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*$/.test(dom)) return send(res, 400, { error: "Domain DNS tidak valid, contoh: zt.lokal" });
      for (const x of servers) if (ipToInt(x) === null) return send(res, 400, { error: `Server DNS ${x} bukan alamat IPv4.` });
      if (servers.length && !dom) return send(res, 400, { error: "Isi domain DNS bila mengisi server DNS." });
      const od = C.dns || {};
      if ((od.domain || "") !== dom || JSON.stringify(od.servers || []) !== JSON.stringify(servers)) {
        upd.dns = { domain: dom, servers };
        changes.push(dom ? `DNS ${dom} (${servers.join(", ") || "-"})` : "DNS dikosongkan");
      }
    }
    if (!Object.keys(upd).length) return send(res, 200, { ok: true, changed: false });
    const r = await ztApi("POST", `/controller/network/${z.nwid}`, upd);
    if (!r.ok) return send(res, 500, { error: "Gagal menyimpan ke controller ZeroTier: " + r.error });
    const d2 = loadData();
    if (z.active && upd.name && d2.settings && d2.settings.zt) { d2.settings.zt.name = upd.name; saveData(d2); }
    logActivity(req, "Jaringan ZeroTier diubah", `${C.name || z.nwid} · ${changes.join(" · ")}`);
    // Rentang/pool jaringan panel berubah: IP VPS, router, perangkat lain, dan route disesuaikan otomatis
    let adj = null;
    if (z.active && (upd.routes || upd.ipAssignmentPools)) adj = await ztRefresh(req).catch((e) => ({ error: e.message }));
    return send(res, 200, { ok: true, changed: true, notes: (adj && adj.notes) || [], error: (adj && adj.error) || "" });
  }
  // Pindahan dari ZTNET: salin nama, lalu lepas ZTNET (proses berjalan di latar belakang)
  if (p === "/api/zt/ztnet-remove" && method === "POST") {
    if (ADDON_JOB && !ADDON_JOB.done) return send(res, 409, { error: `Masih ada proses berjalan: ${ADDON_JOB.title}. Tunggu sampai selesai.` });
    const job = { id: crypto.randomBytes(6).toString("hex"), addon: "zerotier", action: "ztnet", title: "ZTNET dilepas", log: [], steps: [], pct: 0, req, created: Date.now() };
    runJob(job, ztnetRemoveSteps(!!body.dropDb)).catch((e) => {
      job.done = true;
      job.error = e.message;
    });
    return send(res, 200, { ok: true, id: job.id });
  }
  // Setujui / cabut izin anggota dan ubah IP-nya
  const zm = p.match(/^\/api\/zt\/member\/([0-9a-f]{10})$/);
  if (zm && method === "DELETE") {
    const node = zm[1];
    const d = loadData();
    const z = await ztTarget(d, url.searchParams.get("nwid"));
    if (!z) return send(res, 400, { error: "Jaringan ZeroTier tidak ditemukan." });
    if (z.active && node === z.vpsNode) return send(res, 400, { error: "VPS tidak bisa dihapus dari jaringan." });
    const site = z.active ? d.sites.find((x) => x.ztNode === node) : null;
    if (site) return send(res, 400, { error: `Perangkat ini dipakai router "${site.name}". Lepas dulu dari router itu.` });
    const r = await ztApi("DELETE", `/controller/network/${z.nwid}/member/${node}`);
    if (!r.ok && r.status !== 404) return send(res, 500, { error: "Controller ZeroTier menolak: " + r.error });
    const nm = ztMetaOf(d, node).name;
    if (d.ztMembers) delete d.ztMembers[node];
    saveData(d);
    logActivity(req, "Perangkat ZeroTier dihapus", `${nm ? nm + " · " : ""}${node}`);
    return send(res, 200, { ok: true });
  }
  if (zm && method === "POST") {
    const node = zm[1];
    const d = loadData();
    const z = await ztTarget(d, url.searchParams.get("nwid") || body.nwid);
    if (!z) return send(res, 400, { error: "Jaringan ZeroTier tidak ditemukan." });
    if (z.active && node === z.vpsNode) return send(res, 400, { error: "Izin dan IP VPS diatur otomatis oleh panel." });
    const site = z.active ? d.sites.find((x) => isZt(x) && x.ztNode === node) : null;
    const mi = await ztMemberIps(z.nwid);
    if (mi.error) return send(res, 500, { error: mi.error });
    const m = mi.members[node];
    if (!m) return send(res, 404, { error: "Perangkat tidak ada di jaringan ini." });
    const upd = {};
    const notes = [];
    // Nama & catatan disimpan di panel (bukan di controller)
    let metaCh = false;
    if (body.name !== undefined || body.note !== undefined) {
      const meta = ztMeta(d);
      const curm = meta[node] || {};
      const nm = body.name !== undefined ? String(body.name || "").trim().slice(0, 64) : curm.name || "";
      const nt = body.note !== undefined ? String(body.note || "").trim().slice(0, 200) : curm.note || "";
      if (nm !== (curm.name || "") || nt !== (curm.note || "")) {
        if (nm !== (curm.name || "")) notes.push(`nama ${curm.name || "-"} → ${nm || "-"}`);
        if (nt !== (curm.note || "")) notes.push("catatan diubah");
        if (nm || nt) meta[node] = Object.assign({}, curm, { name: nm, note: nt });
        else delete meta[node];
        metaCh = true;
      }
    }
    if (typeof body.authorized === "boolean" && body.authorized !== !!m.authorized) {
      upd.authorized = body.authorized;
      notes.push(body.authorized ? "disetujui" : "izin dicabut");
      // Disetujui tapi belum punya IP: langsung beri IP kosong di rentang (tidak menunggu controller)
      if (body.authorized && body.ip === undefined && !(m.ipAssignments || []).length) {
        const sub = parseCidr(z.subnet);
        const used = new Set();
        for (const o of Object.values(mi.members)) for (const ip of o.ipAssignments || []) used.add(ip);
        const ip = sub && ztFreeIp(sub, used, 100);
        if (ip) {
          upd.ipAssignments = [ip];
          notes.push(`IP ${ip}`);
        }
      }
    }
    if (body.ip !== undefined) {
      const ip = String(body.ip || "").trim();
      const sub = parseCidr(z.subnet);
      if (!sub) return send(res, 400, { error: "Jaringan ini belum punya rentang IP. Atur di Pengaturan jaringan dulu." });
      const n = ipToInt(ip);
      if (n === null || !inSubnet(ip, sub)) return send(res, 400, { error: `IP harus di dalam rentang ${z.subnet}.` });
      if (n === sub.net || n === sub.net + sub.size - 1) return send(res, 400, { error: "IP itu alamat jaringan/broadcast, pilih yang lain." });
      if (ip === z.vpsIp) return send(res, 400, { error: "IP itu dipakai VPS." });
      for (const [id, o] of Object.entries(mi.members)) if (id !== node && (o.ipAssignments || []).includes(ip)) return send(res, 400, { error: `IP ${ip} sudah dipakai perangkat ${id}.` });
      if (!((m.ipAssignments || []).length === 1 && m.ipAssignments[0] === ip)) {
        upd.ipAssignments = [ip];
        notes.push(`IP ${(m.ipAssignments || []).join(", ") || "-"} → ${ip}`);
      }
    }
    if (!Object.keys(upd).length) {
      if (metaCh) {
        saveData(d);
        logActivity(req, "Perangkat ZeroTier diubah", `${node} · ${notes.join(" · ")}`);
      }
      return send(res, 200, { ok: true, changed: metaCh });
    }
    if (metaCh) saveData(d);
    const r = await ztApi("POST", `/controller/network/${z.nwid}/member/${node}`, upd);
    if (!r.ok) return send(res, 500, { error: "Gagal menyimpan ke controller ZeroTier: " + r.error });
    if (site && upd.ipAssignments) {
      site.ztIp = upd.ipAssignments[0];
      const sr = await syncZtRoutes(d);
      if (sr.error) console.error("Sinkron route ZeroTier gagal:", sr.error);
      saveData(d);
      await applyFirewall(d);
    }
    ztPingAll(loadData()).catch(() => {});
    logActivity(req, "Anggota ZeroTier diubah", `${site ? site.name : node} · ${notes.join(" · ")}`);
    return send(res, 200, { ok: true, changed: true });
  }
  if (p === "/api/zt/leave" && method === "POST") {
    const d = loadData();
    const z = ztCfg(d);
    if (!z) return send(res, 400, { error: "ZeroTier belum dihubungkan." });
    const n = d.sites.filter(isZt).length;
    if (n) return send(res, 400, { error: `Masih ada ${n} router yang memakai ZeroTier. Pindahkan ke L2TP atau hapus dulu.` });
    await ztApi("DELETE", `/network/${z.nwid}`);
    delete d.settings.zt;
    saveData(d);
    await ensureLoAddr(d);
    logActivity(req, "ZeroTier dilepas", `VPS keluar dari jaringan ${z.name || z.nwid}`);
    return send(res, 200, { ok: true });
  }

  // --- Tambah router ---
  if (p === "/api/sites" && method === "POST") {
    const d = loadData();
    const err = validateSite(d, body, null);
    if (err) return send(res, 400, { error: err });
    const sub = parseCidr(body.realSubnet);
    const tunnelIp = allocTunnelIp(d);
    if (!tunnelIp) {
      const T = tun(d);
      return send(res, 400, { error: `Slot VPN penuh (maksimal ${T.last - T.first + 1} router untuk ${T.net}). Perbesar jaringan VPN di Pengaturan.` });
    }
    const custom = String(body.virtualSubnet || "").trim();
    const virtualSubnet = custom ? parseCidr(custom).text : allocVirtual(d, sub.prefix);
    if (!virtualSubnet) return send(res, 400, { error: "Rentang IP virtual otomatis penuh. Isi IP virtual secara manual." });
    let base = String(body.name).toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "").slice(0, 20) || "router";
    let username = "acs-" + base;
    let i = 2;
    const manualUsers = manualChapEntries().users;
    while (d.sites.some((s) => s.username === username) || manualUsers.has(username)) username = `acs-${base}-${i++}`;
    const site = {
      id: crypto.randomBytes(6).toString("hex"),
      name: String(body.name).trim(),
      note: String(body.note || "").trim().slice(0, 120),
      username,
      password: randomPassword(16),
      tunnelIp,
      realSubnet: sub.text,
      virtualSubnet,
      forwards: [],
      createdAt: new Date().toISOString(),
      installedAt: null,
      transport: ["zt", "wg"].includes(body.transport) ? body.transport : "l2tp",
      ztNode: "",
      ztIp: "",
    };
    ensureJoinKey(site);
    if (isWg(site)) {
      const r = wgPrepare(d, site);
      if (r.error) return send(res, 400, { error: r.error });
    }
    d.sites.push(site);
    saveData(d);
    logActivity(req, "Router ditambah", `${site.name} · ${TR_LABEL[trOf(site)]}${isWg(site) ? " " + site.wgIp : ""} · ONT ${site.realSubnet} → virtual ${site.virtualSubnet}`);
    let bindError = "";
    if (isZt(site) && String(body.ztNode || "").trim()) {
      const r = await ztBind(d, site, body.ztNode);
      if (r.error) bindError = r.error;
      else logActivity(req, "Router ZeroTier disetujui", `${site.name} · node ${site.ztNode} · IP ${site.ztIp}`);
      saveData(d);
    }
    await applyAll(d);
    const st = settings(d);
    return send(res, 200, { ok: true, site: siteView(site, st, await siteLinks(d), loadHistory()), bindError });
  }

  // --- Port forwarding ---
  const mf = p.match(/^\/api\/sites\/([a-f0-9]{12})\/forwards(\/([a-f0-9]{8}))?$/);
  if (mf) {
    const d = loadData();
    const site = d.sites.find((s) => s.id === mf[1]);
    if (!site) return send(res, 404, { error: "Router tidak ditemukan." });
    site.forwards = site.forwards || [];
    if (!mf[3] && method === "POST") {
      const r = validateForward(d, site, body);
      if (r.error) return send(res, 400, { error: r.error });
      site.forwards.push(r.fwd);
      saveData(d);
      logActivity(req, "Remote ditambah", `${site.name}: ${r.fwd.label} · port publik ${r.fwd.publicPort} → ${fwdTarget(site, r.fwd)}:${r.fwd.targetPort}`);
      await applyAll(d);
      return send(res, 200, { ok: true });
    }
    if (mf[3] && method === "DELETE") {
      const f = site.forwards.find((x) => x.id === mf[3]);
      if (!f) return send(res, 404, { error: "Port forwarding tidak ditemukan." });
      site.forwards = site.forwards.filter((x) => x.id !== mf[3]);
      saveData(d);
      logActivity(req, "Remote dihapus", `${site.name}: ${f.label} · port publik ${f.publicPort}`);
      await applyAll(d);
      return send(res, 200, { ok: true });
    }
  }

  // --- Ubah / hapus / tes / riwayat router ---
  const m = p.match(/^\/api\/sites\/([a-f0-9]{12})(\/(test|test-plan|test-step|reset-password|history|zt-pending|zt-bind|zt-script-done|wg-rekey|wg-script-done))?$/);
  if (m) {
    const d = loadData();
    const site = d.sites.find((s) => s.id === m[1]);
    if (!site) return send(res, 404, { error: "Router tidak ditemukan." });
    const action = m[3];

    if (!action && method === "PUT") {
      const err = validateSite(d, body, site);
      if (err) return send(res, 400, { error: err });
      const sub = parseCidr(body.realSubnet);
      const removed = [];
      const custom = String(body.virtualSubnet || "").trim();
      let newVirt = site.virtualSubnet;
      if (custom) newVirt = parseCidr(custom).text;
      else if (sub.prefix !== parseCidr(site.virtualSubnet).prefix) {
        newVirt = allocVirtual(d, sub.prefix, site.id);
        if (!newVirt) return send(res, 400, { error: "Rentang IP virtual otomatis penuh. Isi IP virtual secara manual." });
      }
      const changes = [];
      const newName = String(body.name).trim();
      if (newName !== site.name) changes.push(`nama ${site.name} → ${newName}`);
      if (sub.text !== site.realSubnet) changes.push(`subnet ONT ${site.realSubnet} → ${sub.text}`);
      if (newVirt !== site.virtualSubnet) {
        changes.push(`IP virtual ${site.virtualSubnet} → ${newVirt}`);
        removed.push(site.virtualSubnet);
        site.virtualSubnet = newVirt;
      }
      const newNote = String(body.note || "").trim().slice(0, 120);
      if (newNote !== (site.note || "")) changes.push("catatan");
      site.name = newName;
      site.note = newNote;
      site.realSubnet = sub.text;
      // Ganti jalur L2TP <-> ZeroTier
      let bindError = "";
      if (["zt", "l2tp", "wg"].includes(body.transport)) {
        const was = trOf(site);
        if (body.transport !== was) {
          changes.push(`jalur ${TR_LABEL[was]} → ${TR_LABEL[body.transport]}`);
          if (was === "zt") {
            await ztUnbind(d, site);
            ZT_ONLINE.delete(site.id);
          }
          site.transport = body.transport;
          ensureJoinKey(site);
          if (isWg(site)) {
            const r = wgPrepare(d, site);
            if (r.error) return send(res, 400, { error: r.error });
            changes.push(`IP WireGuard ${site.wgIp}`);
          }
          delete site.wgStale;
        }
      }
      const node = String(body.ztNode || "").trim().toLowerCase();
      if (isZt(site) && node && node !== site.ztNode) {
        const r = await ztBind(d, site, node);
        if (r.error) bindError = r.error;
        else changes.push(`node ZeroTier ${node}`);
      }
      saveData(d);
      logActivity(req, "Router diubah", `${site.name}${changes.length ? ": " + changes.join(", ") : " (tanpa perubahan)"}`);
      await applyAll(d, removed);
      saveData(d);
      return send(res, 200, { ok: true, bindError });
    }
    if (!action && method === "DELETE") {
      if (isZt(site)) {
        await ztUnbind(d, site);
        ZT_ONLINE.delete(site.id);
      }
      d.sites = d.sites.filter((s) => s.id !== site.id);
      saveData(d);
      logActivity(req, "Router dihapus", `${site.name} · ${site.virtualSubnet}`);
      await applyAll(d, [site.virtualSubnet]);
      return send(res, 200, { ok: true });
    }
    if (action === "reset-password" && method === "POST") {
      site.password = randomPassword(16);
      saveData(d);
      logActivity(req, "Password VPN diganti", site.name);
      await applyAll(d);
      return send(res, 200, { ok: true });
    }
    if (action === "zt-pending" && method === "GET") {
      await ztRefresh(req).catch(() => {});
      const r = await ztPending(loadData());
      if (r.error) return send(res, 400, { error: r.error });
      return send(res, 200, r);
    }
    if (action === "wg-rekey" && method === "POST") {
      if (!isWg(site)) return send(res, 400, { error: "Router ini tidak memakai WireGuard." });
      Object.assign(site, (({ priv, pub }) => ({ wgPriv: priv, wgPub: pub }))(wgKeypair()));
      site.wgStale = true;
      saveData(d);
      logActivity(req, "Kunci WireGuard router dibuat ulang", site.name);
      await applyAll(d);
      return send(res, 200, { ok: true });
    }
    if (action === "wg-script-done" && method === "POST") {
      delete site.wgStale;
      saveData(d);
      logActivity(req, "Script WireGuard dipasang ulang", site.name);
      return send(res, 200, { ok: true });
    }
    if (action === "zt-script-done" && method === "POST") {
      delete site.ztStale;
      saveData(d);
      logActivity(req, "Script ZeroTier dipasang ulang", site.name);
      return send(res, 200, { ok: true });
    }
    if (action === "zt-bind" && method === "POST") {
      if (!isZt(site)) return send(res, 400, { error: "Router ini memakai L2TP." });
      await ztRefresh(req).catch(() => {});
      const d2 = loadData();
      const s2 = d2.sites.find((x) => x.id === site.id);
      if (!s2) return send(res, 404, { error: "Router tidak ditemukan." });
      const r = await ztBind(d2, s2, body.node);
      if (r.error) return send(res, 400, { error: r.error });
      saveData(d2);
      logActivity(req, "Router ZeroTier disetujui", `${s2.name} · node ${s2.ztNode} · IP ${s2.ztIp}`);
      await applyFirewall(d2);
      ztPingAll(d2).catch(() => {});
      return send(res, 200, { ok: true, ip: r.ip });
    }
    if (action === "history" && method === "GET") {
      return send(res, 200, siteHistory(site, loadHistory(), Date.now(), tzName(d)));
    }
    if (action === "test-plan" && method === "GET") {
      return send(res, 200, { steps: testPlan(site) });
    }
    if (action === "test-step" && method === "POST") {
      const step = testPlan(site).find((x) => x.key === body.key);
      if (!step) return send(res, 400, { error: "Langkah tes tidak dikenal." });
      const r = await runTestStep(site, step.key, settings(d));
      return send(res, 200, Object.assign({ key: step.key }, r));
    }
    if (action === "test" && method === "POST") {
      const st = settings(d);
      const links = await siteLinks(d);
      const result = { online: !!links[site.id], iface: links[site.id] || "", steps: [] };
      for (const step of testPlan(site)) {
        const r = await runTestStep(site, step.key, st);
        result.steps.push({ label: step.label, ok: r.ok, detail: r.detail });
      }
      return send(res, 200, result);
    }
  }

  // --- Pengaturan ---
  // --- WireGuard ---
  if (p === "/api/wg" && method === "GET") {
    return send(res, 200, await wgStatus(loadData()));
  }
  if (p === "/api/wg" && method === "PUT") {
    const d = loadData();
    const w = wgCfg(d);
    if (!w) return send(res, 400, { error: "WireGuard belum terpasang." });
    const ch = [];
    let stale = false;
    if (body.port !== undefined) {
      const port = parseInt(body.port, 10);
      if (!(port >= 1024 && port <= 65535)) return send(res, 400, { error: "Port UDP 1024 sampai 65535." });
      if ([PORT, 1701, 500, 4500, 9993, ACS_PORT].includes(port)) return send(res, 400, { error: `Port ${port} sudah dipakai layanan lain di VPS.` });
      if (port !== w.port) { ch.push(`port UDP ${w.port} → ${port}`); w.port = port; stale = true; }
    }
    if (body.subnet !== undefined && String(body.subnet).trim() !== w.subnet) {
      const sub = parseCidr(String(body.subnet).trim());
      if (!sub || !sub.aligned) return send(res, 400, { error: "Rentang harus berupa alamat jaringan, contoh 10.66.0.0/24." });
      if (sub.prefix < 16 || sub.prefix > 28) return send(res, 400, { error: "Ukuran rentang /16 sampai /28." });
      if (!isPrivateCidr(sub)) return send(res, 400, { error: "Rentang harus IP private." });
      const bad = wgSubnetConflict(d, sub);
      if (bad) return send(res, 400, { error: bad });
      const oldSub = parseCidr(w.subnet);
      ch.push(`rentang ${w.subnet} → ${sub.text}`);
      w.subnet = sub.text;
      w.vpsIp = intToIp(sub.net + 1);
      // IP router dipindah dengan urutan yang sama bila muat
      for (const o of d.sites.filter(isWg)) {
        const off = o.wgIp ? ipToInt(o.wgIp) - oldSub.net : 0;
        o.wgIp = off > 1 && off < sub.size - 1 ? intToIp(sub.net + off) : "";
      }
      for (const o of d.sites.filter(isWg)) if (!o.wgIp) o.wgIp = wgAllocIp(d, o) || "";
      stale = true;
    }
    if (!ch.length) return send(res, 200, { ok: true, changed: false });
    const n = d.sites.filter(isWg).length;
    if (stale) for (const o of d.sites.filter(isWg)) o.wgStale = true;
    saveData(d);
    const r = await wgApply(d);
    await genieSync(d).catch(() => {});
    logActivity(req, "WireGuard diubah", ch.join(" · ") + (n ? ` · ${n} router perlu pasang ulang script` : ""));
    return send(res, 200, { ok: true, changed: true, stale: n, error: r.error || "" });
  }
  // --- Kesehatan VPS ---
  if (p === "/api/health" && method === "GET") {
    const d = loadData();
    const c = healthConf(d);
    const st = healthStateLoad();
    return send(res, 200, Object.assign(await vpsHealth(d), { conf: c, lastSent: st.lastSent || null, next: c.enabled ? (st.lastSent ? healthNext(d) : st.firstDue || healthNext(d)) : null, tgActive: tgConfig(d).active, problems: Object.keys(st.alerts || {}) }));
  }
  if (p === "/api/health" && method === "PUT") {
    const d = loadData();
    const old = healthConf(d);
    const h = (d.settings.health = Object.assign({}, d.settings.health || {}));
    if (body.enabled !== undefined) h.enabled = body.enabled !== false;
    if (body.alerts !== undefined) h.alerts = body.alerts !== false;
    if (body.days !== undefined) {
      const v = parseInt(body.days, 10);
      if (!(v >= 1 && v <= 30)) return send(res, 400, { error: "Interval 1 sampai 30 hari." });
      h.days = v;
    }
    if (body.time !== undefined) {
      if (!/^([01]\d|2[0-3]):[0-5]\d$/.test(String(body.time))) return send(res, 400, { error: "Jam kirim tidak valid, contoh 08:00." });
      h.time = String(body.time);
    }
    saveData(d);
    const c = healthConf(d);
    // jadwal pertama dihitung ulang bila interval/jam berubah dan belum pernah terkirim
    const st = healthStateLoad();
    if (!st.lastSent || old.time !== c.time) { delete st.firstDue; if (!st.lastSent) st.firstDue = healthNext(d, Date.now()); healthStateSave(st); }
    const ch = [];
    if (old.enabled !== c.enabled) ch.push(c.enabled ? "laporan aktif" : "laporan mati");
    if (old.days !== c.days || old.time !== c.time) ch.push(`tiap ${c.days} hari jam ${c.time}`);
    if (old.alerts !== c.alerts) ch.push(c.alerts ? "peringatan aktif" : "peringatan mati");
    if (ch.length) logActivity(req, "Laporan kesehatan VPS diubah", ch.join(" · "));
    return send(res, 200, { ok: true, next: c.enabled ? (st.lastSent ? healthNext(d) : st.firstDue) : null });
  }
  if (p === "/api/health/send" && method === "POST") {
    const d = loadData();
    const tg = tgConfig(d);
    if (!tg.active) return send(res, 400, { error: "Telegram belum diatur atau nonaktif." });
    const x = await vpsHealth(d);
    const r = await tgSend(tg, healthMsg(d, x, "test"));
    if (!r.ok) return send(res, 400, { error: r.error });
    logActivity(req, "Laporan kesehatan VPS dikirim (uji)", "");
    return send(res, 200, { ok: true });
  }
  // --- Keamanan: batas diam, IP diblokir, sesi aktif ---
  if (p === "/api/security" && method === "GET") {
    const c = secConf();
    return send(res, 200, { idleMin: c.idleMin, idleChoices: IDLE_CHOICES, notifyBlock: c.notifyBlock, blockSteps: BLOCK_STEPS, blocked: blockList(), sessions: sessionList(req) });
  }
  if (p === "/api/security" && method === "PUT") {
    const d = loadData();
    d.settings.security = d.settings.security || {};
    const ch = [];
    if (body.idleMin !== undefined) {
      const v = parseInt(body.idleMin, 10);
      if (!IDLE_CHOICES.includes(v)) return send(res, 400, { error: "Pilihan batas diam tidak valid." });
      if (secConf(d).idleMin !== v) ch.push(`logout otomatis setelah diam ${fmtDur(v * 60e3)}`);
      d.settings.security.idleMin = v;
      IDLE_MS = v * 60e3;
    }
    if (body.notifyBlock !== undefined) {
      const v = body.notifyBlock !== false;
      if (secConf(d).notifyBlock !== v) ch.push(v ? "notifikasi blokir login aktif" : "notifikasi blokir login mati");
      d.settings.security.notifyBlock = v;
    }
    saveData(d);
    if (ch.length) logActivity(req, "Pengaturan keamanan diubah", ch.join(" · "));
    return send(res, 200, { ok: true });
  }
  if (p === "/api/security/unblock" && method === "POST") {
    const ip = String(body.ip || "");
    if (!loginFails.has(ip)) return send(res, 404, { error: "IP itu tidak sedang diblokir." });
    loginFails.delete(ip);
    blockSave();
    logActivity(req, "Blokir login dibuka", ip);
    return send(res, 200, { ok: true });
  }
  if (p === "/api/sessions/others" && method === "DELETE") {
    const n = sessionsDrop(req.sessKey);
    logActivity(req, "Sesi lain dikeluarkan", `${n} perangkat`);
    return send(res, 200, { ok: true, count: n });
  }
  const sm = p.match(/^\/api\/sessions\/([a-f0-9]{16})$/);
  if (sm && method === "DELETE") {
    if (req.sessKey && req.sessKey.startsWith(sm[1])) return send(res, 400, { error: "Ini sesi Anda sendiri. Pakai tombol Keluar." });
    const n = sessionsDrop(req.sessKey, sm[1]);
    if (!n) return send(res, 404, { error: "Sesi tidak ditemukan." });
    logActivity(req, "Sesi dikeluarkan", sm[1]);
    return send(res, 200, { ok: true });
  }
  if (p === "/api/settings" && method === "PUT") {
    const d = loadData();
    d.settings = d.settings || {};
    const logs = [];
    if (body.publicIp !== undefined) {
      const v = String(body.publicIp).trim().toLowerCase();
      if (v && ipToInt(v) === null && !isHostname(v))
        return send(res, 400, { error: "Alamat VPS tidak valid. Isi IP publik (103.20.30.40) atau domain (vpn.domain.com)." });
      if (v !== (d.settings.publicIp || "")) logs.push(["Alamat VPS diubah", `${d.settings.publicIp || "(otomatis)"} → ${v || "(otomatis)"}`]);
      d.settings.publicIp = v;
    }
    if (body.genieUrl !== undefined) {
      const g = String(body.genieUrl || "").trim().replace(/\/+$/, "");
      if (g && !/^https?:\/\/[^\s/]+(:\d+)?(\/\S*)?$/i.test(g)) return send(res, 400, { error: "Alamat GenieACS harus diawali http:// atau https://, contoh http://acs.domain.com:3000" });
      if (g !== (d.settings.genieUrl || "")) logs.push(["Alamat GenieACS diubah", g || "(otomatis)"]);
      d.settings.genieUrl = g;
    }
    if (body.panelName !== undefined) {
      const n = String(body.panelName || "").trim().replace(/\s+/g, " ") || DEFAULT_BRAND;
      if (!/^[A-Za-z0-9][A-Za-z0-9 _-]{1,29}$/.test(n)) return send(res, 400, { error: "Nama panel 2-30 karakter: huruf, angka, spasi, tanda minus (-) atau garis bawah (_)." });
      const old = brandOf(d);
      if (n !== old) {
        const hist = [old].concat(d.settings.brandHistory || []).filter((x, i, a) => x && x !== n && a.indexOf(x) === i).slice(0, 10);
        d.settings.brandHistory = hist;
        d.settings.panelName = n;
        logs.push(["Nama panel diubah", `${old} → ${n}`]);
      }
    }
    if (body.useIpsec !== undefined && !!body.useIpsec !== !!d.settings.useIpsec) {
      logs.push(["IPsec " + (body.useIpsec ? "diaktifkan" : "dimatikan"), ""]);
      d.settings.useIpsec = !!body.useIpsec;
    }
    if (body.timezone !== undefined && TIMEZONES[body.timezone] && body.timezone !== tzName(d)) {
      logs.push(["Zona waktu diubah", TIMEZONES[body.timezone].label]);
      d.settings.timezone = body.timezone;
    }
    let tunnelChanged = false;
    if (body.tunnelNet !== undefined && String(body.tunnelNet).trim() !== tun(d).net) {
      const t = parseCidr(body.tunnelNet);
      if (!t) return send(res, 400, { error: "Jaringan VPN tidak valid. Contoh: 172.31.0.0/24" });
      if (!t.aligned) return send(res, 400, { error: `Tulis dari alamat awalnya. Mungkin maksud Anda ${t.text}` });
      if (t.prefix < 16 || t.prefix > 28) return send(res, 400, { error: "Ukuran jaringan VPN harus antara /16 sampai /28." });
      const priv = [parseCidr("10.0.0.0/8"), parseCidr("172.16.0.0/12"), parseCidr("192.168.0.0/16"), parseCidr("100.64.0.0/10")];
      if (!priv.some((x) => t.net >= x.net && t.net + t.size <= x.net + x.size))
        return send(res, 400, { error: "Jaringan VPN harus memakai IP privat (10.x, 172.16-31.x, 192.168.x, atau 100.64-127.x)." });
      if (overlap(t, parseCidr(VIRTUAL_POOL))) return send(res, 400, { error: `Bentrok dengan rentang IP virtual otomatis ${VIRTUAL_POOL}.` });
      const ztc = ztCfg(d);
      if (ztc && overlap(t, parseCidr(ztc.subnet))) return send(res, 400, { error: `Bentrok dengan jaringan ZeroTier ${ztc.subnet}.` });
      for (const o of d.sites) {
        if (overlap(t, parseCidr(o.realSubnet))) return send(res, 400, { error: `Bentrok dengan subnet ONT router "${o.name}" (${o.realSubnet}).` });
        if (overlap(t, parseCidr(o.virtualSubnet))) return send(res, 400, { error: `Bentrok dengan IP virtual router "${o.name}" (${o.virtualSubnet}).` });
      }
      const nt = tunnelCfg(t.text);
      const slots = nt.last - nt.first + 1;
      if (d.sites.length > slots) return send(res, 400, { error: `Terlalu kecil: hanya ${slots} slot, padahal ada ${d.sites.length} router.` });
      // Pertahankan nomor host lama jika masih muat, sisanya diberi nomor baru
      const oldT = tun(d);
      const used = new Set();
      const pending = [];
      for (const site of d.sites) {
        const cand = t.net + (ipToInt(site.tunnelIp) - oldT.cidr.net);
        if (cand >= nt.first && cand <= nt.last && !used.has(cand)) {
          used.add(cand);
          site.tunnelIp = intToIp(cand);
        } else pending.push(site);
      }
      for (const site of pending) {
        let n = nt.first;
        while (used.has(n)) n++;
        used.add(n);
        site.tunnelIp = intToIp(n);
      }
      logs.push(["Jaringan VPN diganti", `${oldT.net} → ${t.text}`]);
      d.settings.tunnelNet = t.text;
      tunnelChanged = true;
    }
    if (body.newPassword !== undefined) {
      if (!checkPassword(body.oldPassword || "", d.admin)) return send(res, 400, { error: "Password lama salah." });
      if (String(body.newPassword).length < 8) return send(res, 400, { error: "Password baru minimal 8 karakter." });
      if (String(body.newPassword) === DEFAULT_ADMIN_PW) return send(res, 400, { error: "Gunakan password selain password bawaan." });
      d.admin = hashPassword(body.newPassword);
      const out = sessionsDrop(req.sessKey);
      logs.push(["Password admin diganti", out ? `${out} sesi lain dikeluarkan` : ""]);
    }
    saveData(d);
    for (const [a, x] of logs) logActivity(req, a, x);
    if (tunnelChanged) {
      syncXl2tpd(d);
      await applyAll(d);
      await restartXl2tpd();
      return send(res, 200, { ok: true, tunnelChanged: true });
    }
    return send(res, 200, { ok: true });
  }

  return send(res, 404, { error: "Tidak ditemukan." });
}

async function appHandler(req, res) {
  try {
    const url = new URL(req.url, "http://localhost");
    const hp = proxyHostTarget(reqHost(req));
    if (hp) return proxyRequest(req, res, hp, "");
    const ap = proxyPathTarget(url.pathname);
    if (ap) return proxyRequest(req, res, ap.port, ap.path);
    if (url.pathname.startsWith("/api/")) return await handleApi(req, res, url);
    if (url.pathname === "/" || url.pathname === "/index.html") {
      const h = {
        "Content-Type": "text/html; charset=utf-8",
        "Cache-Control": "no-store",
        "X-Frame-Options": "DENY",
        "X-Content-Type-Options": "nosniff",
      };
      if (req.socket.encrypted) h["Strict-Transport-Security"] = "max-age=86400";
      res.writeHead(200, h);
      return res.end(indexHtml());
    }
    send(res, 404, "Tidak ditemukan");
  } catch (e) {
    console.error(e);
    send(res, 500, { error: "Terjadi kesalahan di server: " + e.message });
  }
}
const httpServer = http.createServer(appHandler);

if (process.argv[2] === "--set-password") {
  const pw = process.argv[3] || "";
  if (pw.length < 8) {
    console.error("Password minimal 8 karakter.");
    process.exit(1);
  }
  const d = loadData();
  d.admin = hashPassword(pw);
  saveData(d);
  console.log("Password admin disimpan.");
  process.exit(0);
} else if (process.argv[2] === "--genie-inform") {
  // Dipakai install.sh: pasang provision "inform berkala" ke GenieACS (dilewati bila sudah ada)
  (async () => {
    const iv = Math.min(3600, Math.max(60, parseInt(process.argv[3], 10) || 300));
    for (let i = 0; i < 20; i++) {
      const cur = await genieInformPreset();
      if (!cur.error) {
        if (cur.installed) { console.log("Inform berkala sudah ada" + (cur.interval ? ` (tiap ${cur.interval} detik)` : "") + ", dilewati."); process.exit(0); }
        const r = await genieInformInstall(iv);
        if (r.ok) { console.log(`Inform berkala dipasang: tiap ${iv} detik (provision ${INFORM_PROV}).`); process.exit(0); }
        console.error(r.error); process.exit(1);
      }
      await new Promise((ok) => setTimeout(ok, 3000));
    }
    console.error("GenieACS NBI tidak menjawab di " + nbiBase());
    process.exit(1);
  })();
} else {
  // Sinkronkan berkas saat panel dinyalakan
  (async () => {
    const d = loadData();
    if (!d.admin) console.error("Password admin belum diset. Jalankan: node server.js --set-password PASSWORD");
    // Router dari versi lama dianggap sudah terpasang (bukan "menunggu pemasangan")
    if (!d.v2) {
      for (const s of d.sites || []) if (s.installedAt === undefined) s.installedAt = s.createdAt || new Date().toISOString();
      d.v2 = true;
      saveData(d);
    }
    let keys = false;
    for (const st of d.sites || []) if (ensureJoinKey(st)) keys = true;
    const m1 = genieMigrate(d);
    const m2 = addonsMigrate(d);
    if (m1 || m2 || keys) saveData(d);
    const gs = await genieSync(d);
    if (gs.changed) console.log("Rentang patch GenieACS disesuaikan dengan IP virtual di panel");
    const cf = d.settings && d.settings.cloudflare;
    if (cf && cf.https) {
      try {
        await httpsEnable(cf.domain);
        console.log(`HTTPS aktif untuk ${cf.domain}`);
      } catch (e) {
        console.error("HTTPS tidak bisa diaktifkan, panel tetap http:", e.message);
      }
    }
    try {
      if (syncXl2tpd(d)) {
        console.log("xl2tpd.conf disesuaikan dengan jaringan VPN panel, restart xl2tpd");
        await restartXl2tpd();
      }
      await applyAll(d);
    } catch (e) {
      console.error("Gagal sinkron awal:", e.message);
    }
    setTimeout(monitorTick, Math.min(5000, TICK_MS));
    setInterval(monitorTick, TICK_MS);
  })();
  setInterval(async () => {
    // Pasang ulang aturan firewall panel jika terhapus (mis. iptables dimuat ulang saat boot)
    try {
      const chk = await ipt(["-t", "nat", "-C", "PREROUTING", "-j", "VPNACS_PRE"]);
      const chk2 = await ipt(["-C", "FORWARD", "-j", "VPNACS_FWD"]);
      if (chk.code !== 0 || chk2.code !== 0) {
        console.log("Aturan firewall panel hilang, memasang ulang");
        await applyFirewall(loadData());
      }
    } catch (e) {
      console.error("Cek firewall gagal:", e.message);
    }
    // Proses Cloudflare yang ditinggal lebih dari 10 menit dibatalkan
    if (CF_JOB && !CF_JOB.done && Date.now() - CF_JOB.created > 10 * 60 * 1000) {
      await (CF_JOB.kind === "sub" ? cfRollbackSub(CF_JOB) : cfRollback(CF_JOB));
      logActivity(null, "Cloudflare dibatalkan", `${CF_JOB.domain}: proses ditinggal lebih dari 10 menit`);
    }
  }, 60 * 1000);
  setInterval(certReloadCheck, 3600 * 1000);
  setTimeout(healthTick, 90 * 1000);
  setInterval(healthTick, 60 * 1000);
  setTimeout(() => checkUpdates().catch(() => {}), 2 * 60 * 1000);
  setInterval(() => checkUpdates().catch(() => {}), 12 * 3600 * 1000);
  needrestartGuard();
  jobRestore();
  httpServer.on("upgrade", onUpgrade);
  const front = net.createServer(frontHandler);
  front.listen(PORT, HOST, () => console.log(`Panel VPN ACS berjalan di port ${PORT}`));
  if (stdWanted(loadData())) {
    stdPortsStart().then((r) => {
      if (r.error) {
        STD_ERR = r.error;
        logActivity(null, "Port standar gagal", r.error + ". Panel tetap di port " + PORT);
        console.error("Port standar tidak bisa dipakai:", r.error, "- panel tetap di port", PORT);
      } else console.log(`Panel juga berjalan di port ${STD_PORTS.http} dan ${STD_PORTS.https}`);
    });
  }
}
