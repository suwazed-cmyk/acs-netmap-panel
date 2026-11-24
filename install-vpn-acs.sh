#!/bin/bash
# =====================================================================
#  Installer Panel VPN ACS
#  Panel web untuk membuat akun VPN L2TP MikroTik -> VPS GenieACS,
#  script MikroTik siap salin (IP virtual / NETMAP), dan port forwarding
#  untuk remote MikroTik / perangkat lokasi lewat IP publik VPS.
#
#  Syarat: vpnsetup.sh (L2TP/IPsec) dan genie.sh sudah terpasang di VPS.
#
#  Pemakaian (sebagai root):
#    bash install-vpn-acs.sh              -> pasang / perbarui panel
#    bash install-vpn-acs.sh password     -> ganti password admin panel
#    bash install-vpn-acs.sh uninstall    -> hapus panel (akun VPN tetap)
# =====================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PANEL_PORT="8088"
# yes = izinkan L2TP biasa tanpa IPsec (seperti tunnel pada umumnya)
ALLOW_PLAIN_L2TP="yes"
APP_DIR="/opt/vpn-acs"
SERVICE="/etc/systemd/system/vpn-acs.service"
XL2TPD_CONF="/etc/xl2tpd/xl2tpd.conf"

set -euo pipefail
GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'
ok()   { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[PERHATIAN]${NC} $*"; }
fail() { echo -e "${RED}[GAGAL]${NC} $*"; exit 1; }

[ "$(id -u)" -eq 0 ] || fail "Jalankan sebagai root"
NODE_BIN="$(command -v node || true)"
[ -n "$NODE_BIN" ] || fail "Node.js tidak ditemukan. Jalankan genie.sh dulu."

DEFAULT_ADMIN_PW="Admin123"
ask_password() {
  local p1 p2
  while true; do
    read -r -s -p "Password admin panel (Enter = ${DEFAULT_ADMIN_PW}): " p1; echo
    if [ -z "$p1" ]; then p1="$DEFAULT_ADMIN_PW"; break; fi
    [ ${#p1} -ge 8 ] || { echo "Minimal 8 karakter, coba lagi (atau Enter untuk password bawaan)."; continue; }
    read -r -s -p "Ulangi password: " p2; echo
    [ "$p1" = "$p2" ] || { echo "Tidak sama, coba lagi."; continue; }
    break
  done
  "$NODE_BIN" "$APP_DIR/server.js" --set-password "$p1"
  if [ "$p1" = "$DEFAULT_ADMIN_PW" ]; then
    warn "Memakai password bawaan ${DEFAULT_ADMIN_PW}. Segera ganti di Pengaturan panel."
  fi
}

if [ "${1:-}" = "password" ]; then
  [ -f "$APP_DIR/server.js" ] || fail "Panel belum terpasang"
  ask_password
  systemctl restart vpn-acs
  ok "Password admin diganti"
  exit 0
fi

if [ "${1:-}" = "uninstall" ]; then
  systemctl disable --now vpn-acs 2>/dev/null || true
  rm -f "$SERVICE"
  systemctl daemon-reload
  rm -rf "$APP_DIR"
  for t in "nat PREROUTING VPNACS_PRE" "nat POSTROUTING VPNACS_POST" "filter FORWARD VPNACS_FWD"; do
    set -- $t
    while iptables -t "$1" -D "$2" -j "$3" 2>/dev/null; do :; done
    iptables -t "$1" -F "$3" 2>/dev/null || true
    iptables -t "$1" -X "$3" 2>/dev/null || true
  done
  warn "Panel dan semua port forwarding dihapus. Akun VPN di /etc/ppp/chap-secrets dan /etc/ppp/ip-up.d/vpn-acs-routes tetap ada."
  exit 0
fi

# ---------- Alat yang dibutuhkan ----------
command -v iptables >/dev/null 2>&1 || fail "iptables tidak ditemukan. Pasang dulu: apt install iptables"
if ! command -v ping >/dev/null 2>&1; then
  apt-get install -y -qq iputils-ping >/dev/null 2>&1 && ok "ping terpasang (untuk Tes Koneksi)" || warn "Gagal memasang ping, Tes Koneksi melewati langkah ping"
fi
# certbot + plugin Cloudflare: untuk HTTPS panel (menu Pengaturan > Domain & HTTPS)
if ! command -v certbot >/dev/null 2>&1 || ! dpkg -s python3-certbot-dns-cloudflare >/dev/null 2>&1; then
  echo "Memasang certbot (untuk HTTPS panel)..."
  if DEBIAN_FRONTEND=noninteractive apt-get install -y -qq certbot python3-certbot-dns-cloudflare >/dev/null 2>&1 || \
     { apt-get update -qq >/dev/null 2>&1 && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq certbot python3-certbot-dns-cloudflare >/dev/null 2>&1; }; then
    ok "certbot terpasang (HTTPS panel siap dipakai)"
  else
    warn "Gagal memasang certbot. Domain Cloudflare tetap bisa dipakai, tetapi HTTPS panel tidak."
  fi
else
  ok "certbot sudah ada"
fi
sysctl -qw net.ipv4.ip_forward=1 || true
grep -qs '^net.ipv4.ip_forward *= *1' /etc/sysctl.conf /etc/sysctl.d/*.conf || echo 'net.ipv4.ip_forward = 1' > /etc/sysctl.d/99-vpn-acs.conf
ok "IP forwarding aktif (dibutuhkan port forwarding)"

# ---------- Cek server VPN ----------
[ -f /etc/ppp/chap-secrets ] || warn "/etc/ppp/chap-secrets tidak ada. Pasang VPN dengan vpnsetup.sh dulu."
[ -f /etc/ipsec.secrets ] || warn "/etc/ipsec.secrets tidak ada. PSK tidak bisa dibaca otomatis."

# ---------- Jaringan VPN ----------
# "local ip" dan "ip range" di /etc/xl2tpd/xl2tpd.conf diatur otomatis oleh panel
# (separuh awal subnet = IP tetap MikroTik, separuh akhir = pool dinamis).
[ -f "$XL2TPD_CONF" ] || warn "$XL2TPD_CONF tidak ditemukan. Pasang VPN dengan vpnsetup.sh dulu."

# ---------- Izinkan L2TP tanpa IPsec ----------
# vpnsetup.sh (hwdsl2) memblokir L2TP yang tidak memakai IPsec.
# Aturan ACCEPT ditaruh paling atas agar L2TP biasa bisa masuk.
IPT_RULE="-p udp --dport 1701 -m comment --comment vpn-acs-l2tp -j ACCEPT"
persist_rule() {
  local f="$1"
  [ -f "$f" ] || return 0
  grep -q "vpn-acs-l2tp" "$f" && return 0
  awk -v rule="-A INPUT $IPT_RULE" '
    /^\*filter/ { infilter=1 }
    infilter && !done && /^-A INPUT / { print rule; done=1 }
    infilter && !done && /^COMMIT/ { print rule; done=1 }
    /^COMMIT/ { infilter=0 }
    { print }
  ' "$f" > "$f.tmp" && cat "$f.tmp" > "$f" && rm -f "$f.tmp"
  ok "Aturan L2TP disimpan permanen di $f"
}
if [ "$ALLOW_PLAIN_L2TP" = "yes" ]; then
  if command -v iptables >/dev/null 2>&1; then
    iptables -C INPUT $IPT_RULE 2>/dev/null || iptables -I INPUT 1 $IPT_RULE
    persist_rule /etc/iptables.rules
    persist_rule /etc/iptables/rules.v4
    ok "Port UDP 1701 dibuka untuk L2TP tanpa IPsec"
  else
    warn "iptables tidak ditemukan, lewati pembukaan port 1701"
  fi
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw allow 1701/udp >/dev/null && ok "ufw: 1701/udp diizinkan"
  fi
fi

if [ -f /etc/ppp/ip-up.d/add-routes ]; then
  warn "Ditemukan /etc/ppp/ip-up.d/add-routes (script route lama)."
  warn "Panel memakai /etc/ppp/ip-up.d/vpn-acs-routes. Hapus script lama jika MikroTik-nya sudah dipindah ke panel:"
  warn "  rm /etc/ppp/ip-up.d/add-routes"
fi

# ---------- Tulis aplikasi ----------
mkdir -p "$APP_DIR/public"
cat > "$APP_DIR/server.js" <<'SERVEREOF'
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

const VERSION = "2.1.2";
const DEFAULT_BRAND = "VPN ACS";
const DEFAULT_TUNNEL_NET = "192.168.42.0/24";
const XL2TPD_CONF = ROOT + "/etc/xl2tpd/xl2tpd.conf";
const VIRTUAL_POOL = "10.100.0.0/14";
const ACS_PORT = 7547;
const MARK_BEGIN = "# >>> VPN-ACS (dikelola Panel VPN ACS, jangan diedit manual) >>>";
const MARK_END = "# <<< VPN-ACS <<<";
const SESSION_TTL = 12 * 3600 * 1000;
const FWD_AUTO_START = 20001; // port publik otomatis mulai dari sini
const RESERVED_PORTS = new Set([22, 25, 53, 80, 443, 500, 1701, 3000, 3300, 4500, 5432, 7547, 7557, 7567, 8080, 9993, 27017, PORT]);
// ZeroTier (controller di VPS, dikelola dari menu ZeroTier panel)
const ZT_API = process.env.VPNACS_ZT_API || "http://127.0.0.1:9993";
const ZT_TOKEN_FILE = ROOT + "/var/lib/zerotier-one/authtoken.secret";
const ZTNET_DIR = ROOT + "/opt/ztnet";
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
  const os = require("os");
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
  for (const s of d.sites.filter((x) => !isZt(x))) {
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
  for (const s of d.sites.filter((x) => !isZt(x))) {
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
function fwdTarget(site, f) {
  if (f.target === "router") return isZt(site) ? site.ztIp || "0.0.0.0" : site.tunnelIp;
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
    const oif = isZt(site) ? "zt+" : "ppp+";
    if (isZt(site) && !site.ztIp) continue; // router ZeroTier belum bergabung
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
  for (const s of d.sites.filter((x) => !isZt(x))) {
    const ifc = peers[s.tunnelIp];
    if (ifc) await run("ip", ["route", "replace", s.virtualSubnet, "dev", ifc]);
  }
  await ensureLoAddr(d);
  await genieSync(d);
  if (ztCfg(d)) {
    const r = await syncZtRoutes(d);
    if (r.error) console.error("Sinkron route ZeroTier gagal:", r.error);
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
  if (cf && cf.https && cf.domain) return std ? `https://${cf.domain}` : `https://${cf.domain}:${PORT}`;
  return st.publicIp ? (std ? `http://${st.publicIp}` : `http://${st.publicIp}:${PORT}`) : "";
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
function mikrotikScript(s, st) {
  if (isZt(s)) return mikrotikScriptZt(s, st);
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
    transport: isZt(s) ? "zt" : "l2tp",
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
  const steps = isZt(site)
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
  let iface = "";
  if (zt) {
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
  if (key === "vpn") {
    if (iface) return { ok: true, detail: zt ? `MikroTik membalas lewat ZeroTier (${site.ztIp})` : `Tersambung lewat ${iface}` };
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
    const okr = zt ? /^zt/.test(dev) : !!iface && dev === iface;
    if (okr) return { ok: true, detail: `Lewat ${dev}` };
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
async function genieDevices() {
  if (GENIE_CACHE.data && Date.now() - GENIE_CACHE.t < 60000) return GENIE_CACHE.data;
  const port = readGenieEnv("GENIEACS_NBI_PORT") || "7557";
  const base = NBI_URL || `http://127.0.0.1:${port}`;
  const proj = ["_id", "_lastInform", "InternetGatewayDevice.ManagementServer.ConnectionRequestURL", "Device.ManagementServer.ConnectionRequestURL"].join(",");
  const r = await httpJson("GET", `${base}/devices/?projection=${encodeURIComponent(proj)}`, null, null, 20000);
  if (r.status !== 200 || !Array.isArray(r.json)) {
    return { error: r.status === 0 ? `GenieACS NBI tidak menjawab (${r.error})` : `GenieACS NBI menolak (HTTP ${r.status})` };
  }
  const data = { devices: r.json.map((d) => ({ id: d._id, last: d._lastInform ? Date.parse(d._lastInform) : 0, ip: crHost(d) })) };
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
  const per = d.sites.map((s) => ({ id: s.id, name: s.name, transport: isZt(s) ? "zt" : "l2tp", virtualSubnet: s.virtualSubnet, total: 0, active: 0, last: 0 }));
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
  const cidr = st.genieCidr;
  return {
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
  for (const o of d.sites) {
    if (overlap(sub, parseCidr(o.realSubnet))) return `Bentrok dengan subnet ONT router "${o.name}" (${o.realSubnet}).`;
    if (overlap(sub, parseCidr(o.virtualSubnet))) return `Bentrok dengan IP virtual router "${o.name}" (${o.virtualSubnet}).`;
  }
  return null;
}
// Status ZeroTier untuk halaman Pengaturan
async function ztStatus(d) {
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
  const z = ztCfg(d);
  if (z) {
    const j = await ztApi("GET", `/network/${z.nwid}`);
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
      status: j.ok ? j.json.status : "TIDAK TERGABUNG",
      iface: j.ok ? j.json.portDeviceName || z.iface : "",
      sites: d.sites.filter(isZt).length,
    });
    // Semua anggota jaringan: VPS, router panel, dan perangkat lain
    const mi = await ztMemberIps(z.nwid);
    const peers = await ztApi("GET", "/peer");
    const pmap = {};
    if (peers.ok) for (const p of peers.json || []) pmap[p.address] = p;
    out.members = [];
    const now = Date.now();
    for (const [id, m] of Object.entries(mi.members || {})) {
      const site = d.sites.find((s) => s.ztNode === id);
      const p = pmap[id];
      const paths = (p && p.paths) || [];
      const path = paths.find((x) => x.preferred) || paths.find((x) => x.active) || paths[0];
      const last = Math.max(0, ...paths.map((x) => x.lastReceive || 0));
      const meta = ztMetaOf(d, id);
      out.members.push({
        node: id,
        role: id === z.vpsNode ? "vps" : site ? "router" : "other",
        name: id === z.vpsNode ? "VPS (panel ini)" : site ? site.name : meta.name || "",
        note: meta.note || "",
        siteId: site ? site.id : "",
        authorized: !!m.authorized,
        ips: m.ipAssignments || [],
        online: id === z.vpsNode ? true : site ? !!ZT_ONLINE.get(site.id) : !!(last && now - last < 120000),
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
  for (const s of d.sites) m[s.id] = isZt(s) ? (ZT_ONLINE.get(s.id) ? (z && z.iface) || "zt" : "") : peers[s.tunnelIp] || "";
  return m;
}
// URL ACS sama untuk semua router: IP .1 jaringan VPN dipasang juga di loopback
let LO_ADDR = "";
async function ensureLoAddr(d) {
  const want = ztCfg(d) ? tun(d).local : "";
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
    const data = body == null ? null : Buffer.from(JSON.stringify(body));
    const h = Object.assign({ Accept: "application/json", "User-Agent": "vpn-acs-panel" }, headers || {});
    if (data) {
      h["Content-Type"] = "application/json";
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

// ---------- Subdomain layanan (GenieACS) ----------
const SUB_SERVICES = {
  acs: { label: "GenieACS", port: () => readGenieUiPort() || 3000, def: "acs" },
};
function subUrl(svc, host) {
  if (STD_ON && HTTPS_ON) return `https://${host}`;
  if (STD_ON) return `http://${host}`;
  return `http://${host}:${SUB_SERVICES[svc].port()}`;
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
  if (key === "sapply") {
    const d = loadData();
    const s = (d.settings = d.settings || {});
    const old = s.subdomains || {};
    const next = {};
    const notes = [];
    for (const svc of Object.keys(SUB_SERVICES)) {
      const host = job.subs[svc];
      const prev = old[svc];
      const urlKey = "genieUrl";
      if (host) {
        const r = (c.subRes || {})[svc] || {};
        const sameHost = prev && prev.host === host;
        next[svc] = { host, recordId: r.recordId || (prev && prev.recordId) || "", created: !!r.created || !!(sameHost && prev.created) };
        s[urlKey] = subUrl(svc, host);
        notes.push(`${SUB_SERVICES[svc].label}: ${s[urlKey]}`);
      } else if (prev) {
        if (s[urlKey] === subUrl(svc, prev.host)) s[urlKey] = "";
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
      const base = STD_ON ? `https://${host && isOurHost(host) ? host : HTTPS_DOMAIN}` : `https://${HTTPS_DOMAIN}:${PORT}`;
      sock.end(`HTTP/1.1 301 Moved Permanently\r\nLocation: ${base}${p}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n`);
      return;
    }
    pipeTls(sock, buf);
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
    desc: "Router RouterOS v7 (ARM/ARM64) tersambung lewat ZeroTier selain L2TP. Memasang ZeroTier (controller) di VPS; jaringan, subnet, dan perangkat diatur langsung dari menu ZeroTier di panel.",
    note: "Ringan: hanya paket zerotier-one (±10 MB), terpasang dalam hitungan detik.",
  },
  "panel-acs": {
    kind: "aplikasi",
    name: "Panel ACS",
    icon: "box",
    desc: "Monitoring ONT dari GenieACS: daftar & detail ONT, redaman RX dengan history grafik, ubah WiFi, reboot, faults, peta. ONT dikelompokkan otomatis per router panel.",
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
    desc: "Billing PPPoE & Hotspot MikroTik: paket, jatuh tempo, isolir otomatis, pembayaran, voucher. Router bisa diambil dari panel, API lewat VPN.",
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
    if (!j.done && j.detached && ADDONS[j.addon] && (j.action === "install" || j.action === "update")) {
      const ad = ADDONS[j.addon];
      const steps = ad.kind === "aplikasi" ? phpInstallSteps(j.addon, null, { update: j.action === "update" }) : ztInstallSteps();
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
    const re = ["vpn-acs", "xl2tpd", "(strongswan|ipsec)[^.]*", "genieacs-[^.]*", "addon-[^.]*", "vpnacs-job-[^.]*", "ztnet", "zerotier-one", "postgresql[^.]*"];
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
  const okDir = fs.existsSync(dir + "/index.php");
  const ver = okDir ? (await run("git", ["-C", dir, "log", "-1", "--format=%h %cs"])).out.trim() : "";
  add("Berkas aplikasi", okDir, okDir ? `${dir}${ver ? " · versi " + ver : ""}` : `${dir} tidak lengkap`, okDir ? "" : "Klik Perbarui atau Install ulang");
  const php = await run("php", ["-r", 'echo PHP_VERSION; foreach (["pdo_sqlite","curl","mbstring"] as $e) if (!extension_loaded($e)) echo " -", $e;']);
  const phpOk = php.code === 0 && !/ -/.test(php.out);
  add("PHP", phpOk, php.code === 0 ? "PHP " + php.out.trim().replace(/ -/g, " kurang: ") : "PHP tidak ditemukan", phpOk ? "" : "apt-get install -y php-cli php-sqlite3 php-curl php-mbstring");
  const svc = (await run("systemctl", ["is-active", `addon-${id}`])).out.trim();
  add(`Layanan addon-${id}`, svc === "active", svc || "tidak ada", svc === "active" ? "" : `journalctl -u addon-${id} -n 50`);
  if (a.timer) {
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
  if (a.db) {
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
  if (link && phpOk) {
    const api = await run("runuser", ["-u", "www-data", "--", "php", "-r", '$l=json_decode(file_get_contents($argv[1]),true); $c=curl_init(rtrim($l["url"],"/")."/api/addon/routers"); curl_setopt_array($c,[CURLOPT_RETURNTRANSFER=>1,CURLOPT_TIMEOUT=>8,CURLOPT_HTTPHEADER=>["X-Addon-Key: ".$l["key"]]]); $b=curl_exec($c); $j=json_decode((string)$b,true); echo curl_getinfo($c,CURLINFO_HTTP_CODE)," ",is_array($j)&&isset($j["routers"])?count($j["routers"]):-1;', dir + "/data/panel-link.json"]);
    const m = api.out.trim().match(/^(\d+) (-?\d+)$/);
    const apiOk = !!(m && m[1] === "200" && m[2] !== "-1");
    add("Aplikasi membaca router panel", apiOk, apiOk ? `${m[2]} router terbaca` : `Gagal (${api.out.trim().slice(0, 120) || "tidak ada jawaban"})`, apiOk ? "" : "Klik Perbarui, lalu restart panel: systemctl restart vpn-acs");
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
    label: "Pasang PHP",
    weight: 4,
    run: async (job) => {
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
    label: "Siapkan data",
    weight: 1,
    run: async () => {
      const d = loadData();
      fs.mkdirSync(dir + "/data", { recursive: true });
      // Penghubung ke panel utama: alamat lokal + kunci rahasia (hanya dari 127.0.0.1)
      writeIfChanged(dir + "/data/panel-link.json", JSON.stringify({ url: `http://127.0.0.1:${PORT}`, key: d.settings.addonKey, prefix: addonPath(d, id), nbi: nbiBase() }, null, 2), 0o640);
      await run("chown", ["-R", "www-data:www-data", dir + "/data"]);
      await run("chmod", ["750", dir + "/data"]);
      if (fs.existsSync(dir + "/bin/setup.php")) {
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
      const units = phpUnits(id);
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
    const x = { id, kind: a.kind, name: a.name, icon: a.icon, desc: a.desc, note: a.note || "", installed: !!st.installed, at: st.at || null, updatedAt: st.updatedAt || null };
    if (a.kind === "aplikasi") {
      x.path = addonPath(d, id);
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
      x.routers = d.sites.filter(isZt).length;
    }
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
  for (const [svc, x] of Object.entries(subs)) if (x && x.host === h && SUB_SERVICES[svc]) return SUB_SERVICES[svc].port();
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
    sock.end(`HTTP/1.1 301 Moved Permanently\r\nLocation: https://${host}${p}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n`);
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
// Port 80/443 aktif secara bawaan; hanya mati bila admin mematikannya di Pengaturan
function stdWanted(d) {
  return !(d && d.settings && d.settings.stdPorts === false);
}
async function stdPortsStart() {
  if (STD_ON) return { ok: true };
  const a = await listenPort(DRY_RUN ? STD_HTTP : 80, handler80);
  if (a.error) return { error: a.error };
  const b = await listenPort(DRY_RUN ? STD_HTTPS : 443, handler443);
  if (b.error) {
    a.srv.close();
    return { error: b.error };
  }
  std80 = a.srv;
  std443 = b.srv;
  STD_ON = true;
  STD_ERR = "";
  return { ok: true };
}
function stdPortsStop() {
  if (std80) std80.close();
  if (std443) std443.close();
  std80 = std443 = null;
  STD_ON = false;
}
// Cek port 80/443 bisa dipakai, tanpa mengubah apa pun
async function stdPortsProbe() {
  if (STD_ON) return { ok: true };
  const out = [];
  for (const port of DRY_RUN ? [STD_HTTP, STD_HTTPS] : [80, 443]) {
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
    if (!x || !x.host || !SUB_SERVICES[svc]) continue;
    const want = subUrl(svc, x.host);
    s.genieUrl = want;
    notes.push(want);
  }
  return notes;
}
function stdOnSteps() {
  return [
    {
      label: "Periksa port 80 dan 443",
      run: async () => {
        const r = await stdPortsProbe();
        if (r.error) return { error: r.error + ". Hentikan aplikasi itu (mis. nginx/apache) atau tetap pakai port " + PORT + "." };
        return { detail: "Port kosong" };
      },
    },
    {
      label: "Sertifikat untuk subdomain",
      weight: 3,
      run: async () => {
        const d = loadData();
        const cf = d.settings.cloudflare;
        const hosts = Object.entries(d.settings.subdomains || {}).filter(([k, x]) => SUB_SERVICES[k] && x && x.host).map(([, x]) => x.host);
        if (!(cf && cf.https && HTTPS_ON) || !hosts.length) return { skip: true, detail: "Tidak diperlukan" };
        const r = await certExpand(cf.domain, hosts);
        if (r.error) return r;
        return { detail: `Sertifikat mencakup ${[cf.domain].concat(hosts).join(", ")}` };
      },
    },
    {
      label: "Aktifkan port 80 dan 443",
      run: async () => {
        const r = await stdPortsStart();
        if (r.error) return r;
        const d = loadData();
        d.settings.stdPorts = true;
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

// ---------- Sesi & keamanan login ----------
// Sesi disimpan ke berkas (hanya hash token) agar tidak logout saat panel di-restart
const SESSION_FILE = path.dirname(DATA_FILE) + "/sessions.json";
const sessions = new Map();
const loginFails = new Map();
const tokHash = (t) => crypto.createHash("sha256").update(String(t)).digest("hex");
let sessSaveTimer = null;
function sessionsSave(now) {
  const write = () => {
    sessSaveTimer = null;
    try {
      const o = {};
      const n = Date.now();
      for (const [k, v] of sessions) if (v > n) o[k] = v;
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
    for (const [k, v] of Object.entries(o)) if (/^[a-f0-9]{64}$/.test(k) && v > n) sessions.set(k, v);
  } catch (e) {
    // belum ada
  }
}
sessionsLoad();
function newSession() {
  const t = crypto.randomBytes(32).toString("hex");
  sessions.set(tokHash(t), Date.now() + SESSION_TTL);
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
function authed(req) {
  const t = getCookie(req, "vpnacs");
  const k = t && tokHash(t);
  const exp = k && sessions.get(k);
  if (!exp) return false;
  if (exp < Date.now()) {
    sessions.delete(k);
    return false;
  }
  sessions.set(k, Date.now() + SESSION_TTL);
  sessionsSave();
  return true;
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
    const f = loginFails.get(ip) || { n: 0, until: 0 };
    if (f.until > Date.now()) {
      const sec = Math.ceil((f.until - Date.now()) / 1000);
      return send(res, 429, { error: `Terlalu banyak percobaan. Coba lagi dalam ${sec} detik.` });
    }
    const d = loadData();
    if (!checkPassword(body.password || "", d.admin)) {
      f.n += 1;
      if (f.n >= 5) {
        f.until = Date.now() + 5 * 60 * 1000;
        f.n = 0;
        logActivity(req, "Login diblokir", "5 kali salah password, diblokir 5 menit");
      } else logActivity(req, "Login gagal", "Password salah");
      loginFails.set(ip, f);
      await new Promise((r) => setTimeout(r, 800));
      return send(res, 401, { error: "Password salah." });
    }
    loginFails.delete(ip);
    const t = newSession();
    logActivity(req, "Login berhasil", "");
    return send(res, 200, { ok: true }, { "Set-Cookie": `vpnacs=${t}; ${cookieFlags(req)}; Max-Age=${SESSION_TTL / 1000}` });
  }
  if (p === "/api/logout" && method === "POST") {
    if (authed(req)) logActivity(req, "Logout", "");
    sessions.delete(tokHash(getCookie(req, "vpnacs")));
    sessionsSave(true);
    return send(res, 200, { ok: true }, { "Set-Cookie": `vpnacs=; ${cookieFlags(req)}; Max-Age=0` });
  }
  if (p === "/api/me" && method === "GET") return send(res, 200, { loggedIn: authed(req), panelName: brandOf(loadData()) });
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
            transport: isZt(x) ? "zt" : "l2tp",
            address: isZt(x) ? x.ztIp || "" : x.tunnelIp,
            vpsAddress: isZt(x) ? (st.zt ? st.zt.vpsIp : "") : st.tun.local,
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
        tunnelNet: st.tun.net,
        tunnelLocal: st.tun.local,
        tunnelStatic: `${intToIp(st.tun.first)} - ${intToIp(st.tun.last)}`,
        tunnelPool: `${st.tun.poolStart} - ${st.tun.poolEnd}`,
        tunnelMax: st.tun.last - st.tun.first + 1,
        presets: SERVICE_PRESETS,
        autoPortStart: FWD_AUTO_START,
        reservedPorts: Array.from(RESERVED_PORTS),
        port: PORT,
        stdPorts: { enabled: stdWanted(d), active: STD_ON, error: STD_ERR },
        panelUrl: panelPublicUrl(st, d),
        addons: Object.fromEntries(Object.entries(ADDONS).map(([id, a]) => [id, { installed: addonInstalled(d, id), kind: a.kind, name: a.name, icon: a.icon, path: a.kind === "aplikasi" ? addonPath(d, id) : "" }])),
        version: VERSION,
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
          ? { domain: cf.domain, zoneName: cf.zoneName, ip: cf.ip, https: !!cf.https, subdomains: d.settings.subdomains || {}, httpsActive: HTTPS_ON, appliedAt: cf.appliedAt, certExpiry: cf.https ? certExpiry(cf.domain) : null, publicIpBefore: d.settings.publicIpBeforeCf || "" }
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
    for (const svc of Object.keys(SUB_SERVICES)) {
      const label = String((body[svc] === undefined ? "" : body[svc]) || "").trim().toLowerCase();
      if (!label) continue;
      if (!/^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$/.test(label)) return send(res, 400, { error: `Nama subdomain ${SUB_SERVICES[svc].label} tidak valid. Pakai huruf kecil, angka, atau tanda minus, contoh: ${SUB_SERVICES[svc].def}` });
      const host = `${label}.${cf.zoneName}`;
      if (host === cf.domain) return send(res, 400, { error: `${host} sudah dipakai panel. Pilih nama lain.` });
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
  if (p === "/api/genie" && method === "GET") {
    if (url.searchParams.get("refresh") === "1") GENIE_CACHE.t = 0;
    return send(res, 200, await genieStatus(loadData()));
  }

  // --- ZeroTier ---
  if (p === "/api/zt" && method === "GET") {
    await ztRefresh(req).catch((e) => console.error("Pemeriksaan ZeroTier gagal:", e.message));
    return send(res, 200, await ztStatus(loadData()));
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
    return send(res, 200, { job: { id: j.id, addon: j.addon, title: j.title, pct: j.pct || 0, cur: j.cur, detail: j.detail || "", steps: j.steps, log: (j.log || []).slice(-120), done: !!j.done, ok: !!j.ok, error: j.error || "", interrupted: !!j.interrupted, elapsed: Math.round(((j.done ? j.finished || now : now) - (j.started || now)) / 1000), quiet: j.done ? 0 : Math.round((now - (j.lastOut || now)) / 1000) } });
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
        steps = a.kind === "aplikasi" ? phpInstallSteps(id, req, { update: action === "update" }) : ztInstallSteps();
        label = action === "install" ? "dipasang" : "diperbarui";
      } else {
        steps = a.kind === "aplikasi" ? phpRemoveSteps(id, !!body.purge) : ztRemoveSteps(!!body.purge);
        label = "dilepas";
      }
      const job = { id: crypto.randomBytes(6).toString("hex"), addon: id, action, title: `Add-on ${a.name} ${label}`, log: [], steps: [], pct: 0, req, created: Date.now() };
      runJob(job, steps).catch((e) => {
        job.done = true;
        job.error = e.message;
      });
      return send(res, 200, { ok: true, id: job.id });
    }
  }
  // --- Port standar 80/443 ---
  if (p === "/api/stdports" && method === "POST") {
    if (ADDON_JOB && !ADDON_JOB.done) return send(res, 409, { error: `Masih ada proses berjalan: ${ADDON_JOB.title}. Tunggu sampai selesai.` });
    const on = !!body.enable;
    const job = { id: crypto.randomBytes(6).toString("hex"), addon: "", action: on ? "on" : "off", title: on ? "Port 80/443 diaktifkan" : "Port 80/443 dimatikan", log: [], steps: [], pct: 0, req, created: Date.now() };
    runJob(job, on ? stdOnSteps() : stdOffSteps()).catch((e) => {
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
  // Ubah jaringan aktif: nama, akses, rentang IP, pool, DNS
  if (p === "/api/zt/network" && method === "PUT") {
    const d = loadData();
    const z = ztCfg(d);
    if (!z) return send(res, 400, { error: "ZeroTier belum dihubungkan." });
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
      changes.push(`rentang ${z.subnet} → ${sub.text}`);
    }
    if (body.poolStart !== undefined || body.poolEnd !== undefined || upd.routes) {
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
    if (upd.name && d2.settings && d2.settings.zt) { d2.settings.zt.name = upd.name; saveData(d2); }
    logActivity(req, "Jaringan ZeroTier diubah", changes.join(" · "));
    // Rentang/pool berubah: IP VPS, router, perangkat lain, dan route disesuaikan otomatis
    let adj = null;
    if (upd.routes || upd.ipAssignmentPools) adj = await ztRefresh(req).catch((e) => ({ error: e.message }));
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
    const z = ztCfg(d);
    if (!z) return send(res, 400, { error: "ZeroTier belum dihubungkan." });
    if (node === z.vpsNode) return send(res, 400, { error: "VPS tidak bisa dihapus dari jaringan." });
    const site = d.sites.find((x) => x.ztNode === node);
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
    const z = ztCfg(d);
    if (!z) return send(res, 400, { error: "ZeroTier belum dihubungkan." });
    if (node === z.vpsNode) return send(res, 400, { error: "Izin dan IP VPS diatur otomatis oleh panel." });
    const site = d.sites.find((x) => isZt(x) && x.ztNode === node);
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
    }
    if (body.ip !== undefined) {
      const ip = String(body.ip || "").trim();
      const sub = parseCidr(z.subnet);
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
      transport: body.transport === "zt" ? "zt" : "l2tp",
      ztNode: "",
      ztIp: "",
    };
    ensureJoinKey(site);
    d.sites.push(site);
    saveData(d);
    logActivity(req, "Router ditambah", `${site.name} · ${isZt(site) ? "ZeroTier" : "L2TP"} · ONT ${site.realSubnet} → virtual ${site.virtualSubnet}`);
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
  const m = p.match(/^\/api\/sites\/([a-f0-9]{12})(\/(test|test-plan|test-step|reset-password|history|zt-pending|zt-bind|zt-script-done))?$/);
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
      if (body.transport === "zt" || body.transport === "l2tp") {
        const was = isZt(site) ? "zt" : "l2tp";
        if (body.transport !== was) {
          changes.push(`jalur ${was === "zt" ? "ZeroTier" : "L2TP"} → ${body.transport === "zt" ? "ZeroTier" : "L2TP"}`);
          if (was === "zt") {
            await ztUnbind(d, site);
            ZT_ONLINE.delete(site.id);
          }
          site.transport = body.transport;
          ensureJoinKey(site);
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
      logs.push(["Password admin diganti", ""]);
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
  needrestartGuard();
  jobRestore();
  httpServer.on("upgrade", onUpgrade);
  const front = net.createServer(frontHandler);
  front.listen(PORT, HOST, () => console.log(`Panel VPN ACS berjalan di port ${PORT}`));
  if (stdWanted(loadData())) {
    stdPortsStart().then((r) => {
      if (r.error) {
        STD_ERR = r.error;
        logActivity(null, "Port 80/443 gagal", r.error + ". Panel tetap di port " + PORT);
        console.error("Port 80/443 tidak bisa dipakai:", r.error, "- panel tetap di port", PORT);
      } else console.log("Panel juga berjalan di port 80 dan 443");
    });
  }
}
SERVEREOF

cat > "$APP_DIR/public/index.html" <<'HTMLEOF'
<!DOCTYPE html>
<html lang="id">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>VPN ACS</title>
<link rel="icon" href="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 32 32'%3E%3Crect width='32' height='32' rx='8' fill='%231d4ed8'/%3E%3Cpath d='M16 6l8 3v6c0 4.6-3.4 8.6-8 9.6-4.6-1-8-5-8-9.6V9l8-3z' fill='none' stroke='white' stroke-width='2.2' stroke-linejoin='round'/%3E%3Cpath d='M12.5 15.5l2.5 2.5 4.5-4.5' fill='none' stroke='white' stroke-width='2.2' stroke-linecap='round' stroke-linejoin='round'/%3E%3C/svg%3E">
<link rel="preconnect" href="https://fonts.googleapis.com">
<link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700&display=swap" rel="stylesheet">
<style>
  :root{
    color-scheme:light;
    --bg:#f6f7fb;--surface:#fff;--subtle:#f8f9fc;--hover:#f3f5fa;
    --line:#e7e9f0;--line-2:#d9dde7;
    --text:#1f2633;--text-2:#4b5565;--muted:#7b8494;
    --primary:#1d4ed8;--primary-hover:#1e40af;--primary-soft:#eef3ff;--ring:rgba(29,78,216,.18);
    --ok:#16a34a;--ok-soft:#ecfdf3;--warn:#d97706;--warn-soft:#fffbeb;--bad:#dc2626;--bad-soft:#fef2f2;
    --side:#0f2a6b;--side-text:rgba(255,255,255,.72);--side-hover:rgba(255,255,255,.07);--side-on:rgba(255,255,255,.12);
    --code-bg:#0f172a;--code-fg:#e2e8f0;--tab-accent:#38bdf8;
    --r:10px;--r-sm:8px;--shadow:0 1px 2px rgba(16,24,40,.04);--shadow-lg:0 18px 48px -12px rgba(16,24,40,.28);
    --font:Inter,ui-sans-serif,system-ui,-apple-system,"Segoe UI",Roboto,Arial,sans-serif;
    --mono:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;
  }
  [data-theme="dark"]{
    color-scheme:dark;
    --bg:#0d1117;--surface:#151b24;--subtle:#1a212c;--hover:#1d2531;
    --line:#252e3b;--line-2:#323d4d;
    --text:#e6ebf2;--text-2:#b4bdcb;--muted:#8591a3;
    --primary:#5b8cff;--primary-hover:#7aa2ff;--primary-soft:#18243f;--ring:rgba(91,140,255,.25);
    --ok:#3ccf74;--ok-soft:#10291b;--warn:#f0a73a;--warn-soft:#2c2111;--bad:#f26b6b;--bad-soft:#2d1516;
    --side:#0b1530;--tab-accent:#38bdf8;
    --shadow:0 1px 2px rgba(0,0,0,.3);
  }
  *,*::before,*::after{box-sizing:border-box}
  html,body{margin:0}
  body{min-height:100vh;background:var(--bg);color:var(--text);font:14px/1.55 var(--font);-webkit-font-smoothing:antialiased}
  h1,h2,h3,p{margin:0}
  button,input,select{font:inherit;color:inherit}
  button{cursor:pointer}
  a{color:var(--primary);text-decoration:none}
  code,.mono{font-family:var(--mono);font-size:.92em}
  .hidden{display:none!important}
  .muted{color:var(--muted)}
  svg.i{width:18px;height:18px;flex:none}

  /* Layout */
  .side{position:fixed;inset:0 auto 0 0;width:248px;background:var(--side);display:flex;flex-direction:column;padding:18px 12px;z-index:40;transition:transform .22s ease}
  .brand{display:flex;align-items:center;gap:10px;padding:4px 10px 22px;color:#fff}
  .brand-mark{width:34px;height:34px;border-radius:9px;background:rgba(255,255,255,.12);display:grid;place-items:center}
  .brand-mark svg{width:19px;height:19px}
  .brand b{display:block;font-size:15.5px;font-weight:650;letter-spacing:-.01em;line-height:1.15}
  .brand small{display:block;font-size:11px;color:var(--side-text)}
  .nav-sec{padding:14px 12px 6px;font-size:11px;font-weight:600;letter-spacing:.06em;text-transform:uppercase;color:rgba(255,255,255,.45)}
  .nav{display:flex;align-items:center;gap:11px;width:100%;padding:9px 12px;margin:1px 0;border:0;border-radius:var(--r-sm);background:none;color:var(--side-text);font-size:14px;font-weight:500;text-align:left}
  .nav:hover{background:var(--side-hover);color:#fff}
  .nav.on{background:var(--side-on);color:#fff}
  .nav .cnt{margin-left:auto;font-size:11.5px;padding:1px 7px;border-radius:999px;background:rgba(255,255,255,.14);color:#fff}
  .side .grow{flex:1}
  .backdrop{position:fixed;inset:0;background:rgba(15,23,42,.45);z-index:35;opacity:0;visibility:hidden;transition:.2s}
  body.nav-open .backdrop{opacity:1;visibility:visible}
  .wrap{margin-left:248px;min-height:100vh;display:flex;flex-direction:column}
  .top{height:60px;display:flex;align-items:center;gap:10px;padding:0 28px;background:var(--surface);border-bottom:1px solid var(--line);position:sticky;top:0;z-index:20}
  .crumb{font-size:13.5px;color:var(--muted);display:flex;align-items:center;gap:6px;min-width:0}
  .crumb a{color:var(--muted)}.crumb a:hover{color:var(--text)}
  .crumb b{color:var(--text);font-weight:600;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
  .top-r{margin-left:auto;display:flex;align-items:center;gap:6px}
  .avatar{width:32px;height:32px;border-radius:50%;background:var(--primary);color:#fff;display:grid;place-items:center;font-weight:600;font-size:13px}
  #navBtn{display:none}
  .main{padding:28px;max-width:1180px;width:100%;margin:0 auto}
  #topWarn:empty{display:none}
  #topWarn{max-width:1180px;width:100%;margin:0 auto;padding:20px 28px 0}
  #topWarn .note{margin:0;align-items:center}
  #topWarn .note>div{flex:1}
  #topWarn .btn{flex:none}

  /* Header halaman */
  .ph{display:flex;align-items:flex-start;justify-content:space-between;gap:16px;flex-wrap:wrap;margin-bottom:22px}
  .ph h1{font-size:22px;font-weight:650;letter-spacing:-.02em}
  .ph p{color:var(--muted);margin-top:3px}
  .ph .acts{display:flex;gap:8px;align-items:center}

  /* Tombol */
  .btn{display:inline-flex;align-items:center;justify-content:center;gap:7px;height:36px;padding:0 14px;border:1px solid var(--line-2);border-radius:var(--r-sm);background:var(--surface);color:var(--text);font-size:13.5px;font-weight:500;white-space:nowrap;transition:background .12s,border-color .12s}
  .btn:hover{background:var(--hover)}
  .btn.pri{background:var(--primary);border-color:var(--primary);color:#fff}
  .btn.pri:hover{background:var(--primary-hover)}
  .btn.ghost{border-color:transparent;background:transparent}
  .btn.ghost:hover{background:var(--hover)}
  .btn.danger{color:var(--bad);border-color:var(--line-2)}
  .btn.danger:hover{background:var(--bad-soft);border-color:var(--bad)}
  .btn.sm{height:30px;padding:0 10px;font-size:12.5px}
  .btn.icon{width:36px;padding:0}
  .btn:disabled{opacity:.5;cursor:default}

  /* Kartu */
  .card{background:var(--surface);border:1px solid var(--line);border-radius:var(--r);box-shadow:var(--shadow)}
  .card+.card{margin-top:16px}
  .ch{display:flex;align-items:center;justify-content:space-between;gap:10px;padding:16px 20px;border-bottom:1px solid var(--line)}
  .ch h2{font-size:14.5px;font-weight:600}
  .ch a{font-size:13px;font-weight:500}
  .cb{padding:18px 20px}

  /* KPI */
  .kpis{display:grid;grid-template-columns:repeat(4,1fr);gap:16px;margin-bottom:20px}
  .kpi{background:var(--surface);border:1px solid var(--line);border-radius:var(--r);padding:16px 18px;box-shadow:var(--shadow)}
  .kpi span{display:flex;align-items:center;gap:7px;font-size:13px;color:var(--muted);font-weight:500}
  .kpi b{display:block;font-size:28px;font-weight:650;letter-spacing:-.03em;margin-top:6px;font-variant-numeric:tabular-nums}
  .kpi small{display:block;color:var(--muted);font-size:12px;margin-top:2px}
  .grid2{display:grid;grid-template-columns:1.35fr 1fr;gap:16px;align-items:start}
  .grid2 .card+.card{margin-top:0}
  .stack>.card+.card{margin-top:16px}

  /* Status */
  .dot{width:8px;height:8px;border-radius:50%;background:var(--muted);flex:none;display:inline-block}
  .dot.ok{background:var(--ok);box-shadow:0 0 0 3px var(--ok-soft)}
  .dot.bad{background:var(--warn);box-shadow:0 0 0 3px var(--warn-soft)}
  .pill{display:inline-flex;align-items:center;gap:6px;height:24px;padding:0 10px;border-radius:999px;font-size:12px;font-weight:550;white-space:nowrap}
  .pill.ok{background:var(--ok-soft);color:var(--ok)}
  .pill.bad{background:var(--warn-soft);color:var(--warn)}
  .pill::before{content:"";width:6px;height:6px;border-radius:50%;background:currentColor}
  .dot.wait{background:var(--muted);box-shadow:0 0 0 3px var(--subtle)}
  .pill.wait{background:var(--subtle);color:var(--muted);border:1px solid var(--line)}
  .pill.info{background:var(--primary-soft);color:var(--primary)}
  .up{font-size:12.5px;color:var(--muted);font-variant-numeric:tabular-nums;white-space:nowrap;min-width:56px;text-align:right}
  .up.warn{color:var(--warn)}.up.bad{color:var(--bad)}

  /* Daftar baris */
  .rows{list-style:none;margin:0;padding:0}
  .rows li{border-bottom:1px solid var(--line)}
  .rows li:last-child{border-bottom:0}
  .row{display:flex;align-items:center;gap:14px;padding:13px 20px;color:var(--text);cursor:pointer;transition:background .12s}
  .row:hover{background:var(--hover)}
  .row .nm{font-weight:600}
  .row .sb{font-size:12.5px;color:var(--muted)}
  .row .grow{flex:1;min-width:0}
  .row .meta{font-family:var(--mono);font-size:12.5px;color:var(--muted);white-space:nowrap}
  .row .chev{color:var(--muted)}
  .row.warn .ic,.row.info .ic{width:32px;height:32px;border-radius:8px;display:grid;place-items:center;background:var(--warn-soft);color:var(--warn);flex:none}
  .row.info .ic{background:var(--primary-soft);color:var(--primary)}
  .empty{padding:36px 20px;text-align:center;color:var(--muted)}
  .empty .big{width:44px;height:44px;margin:0 auto 10px;border-radius:12px;display:grid;place-items:center;background:var(--ok-soft);color:var(--ok)}
  .empty h3{color:var(--text);font-size:15px;font-weight:600;margin-bottom:4px}
  .toolbar{display:flex;align-items:center;gap:10px;padding:14px 20px;border-bottom:1px solid var(--line)}
  .search{position:relative;flex:1;max-width:360px}
  .search svg{position:absolute;left:10px;top:50%;transform:translateY(-50%);color:var(--muted);width:16px;height:16px}
  .search input[type=text]{padding-left:34px}
  .filters{display:flex;gap:4px;margin-left:auto}
  .chip{height:30px;padding:0 12px;border-radius:999px;border:1px solid var(--line-2);background:var(--surface);font-size:12.5px;font-weight:500;color:var(--text-2)}
  .chip.on{background:var(--text);border-color:var(--text);color:var(--surface)}

  /* Info list */
  .dl{display:grid;grid-template-columns:repeat(2,1fr);gap:0}
  .dl>div{padding:14px 20px;border-bottom:1px solid var(--line)}
  .dl>div:nth-child(odd){border-right:1px solid var(--line)}
  .dl dt{font-size:12.5px;color:var(--muted);margin-bottom:3px}
  .dl dd{margin:0;display:flex;align-items:center;gap:8px;font-family:var(--mono);font-size:13.5px;word-break:break-all}
  .kv{display:flex;justify-content:space-between;gap:12px;padding:11px 20px;border-bottom:1px solid var(--line);font-size:13.5px}
  .kv:last-child{border-bottom:0}
  .kv span{color:var(--muted)}
  .kv b{font-weight:500;font-family:var(--mono);font-size:13px;text-align:right;word-break:break-all}
  .kv b .pill{font-family:var(--font)}
  .copy{border:0;background:none;color:var(--muted);padding:2px;border-radius:5px;display:inline-grid;place-items:center}
  .copy:hover{color:var(--primary);background:var(--primary-soft)}
  .copy svg{width:15px;height:15px}

  /* Detail */
  .dh{display:flex;align-items:flex-start;justify-content:space-between;gap:16px;flex-wrap:wrap;margin-bottom:18px}
  .dh h1{font-size:22px;font-weight:650;letter-spacing:-.02em;display:flex;align-items:center;gap:12px;flex-wrap:wrap}
  .dh p{color:var(--muted);margin-top:3px}
  .tabs{display:flex;gap:6px;box-shadow:inset 0 -1px 0 var(--line);margin-bottom:22px;overflow-x:auto;overflow-y:hidden;scrollbar-width:none}
  .tabs::-webkit-scrollbar{display:none}
  .tab{display:inline-flex;align-items:center;gap:8px;padding:11px 14px 12px;font-size:14.5px;font-weight:500;color:var(--muted);border-bottom:2px solid transparent;white-space:nowrap;transition:color .12s,border-color .12s}
  .tab svg{width:17px;height:17px}
  .tab:hover{color:var(--text)}
  .tab.on{color:var(--text);font-weight:600;border-bottom-color:var(--tab-accent)}
  .menu{position:relative}
  .menu-list{position:absolute;right:0;top:42px;min-width:200px;background:var(--surface);border:1px solid var(--line);border-radius:var(--r);box-shadow:var(--shadow-lg);padding:6px;z-index:30}
  .menu-list button{display:flex;align-items:center;gap:9px;width:100%;padding:9px 10px;border:0;background:none;border-radius:6px;text-align:left;font-size:13.5px}
  .menu-list button:hover{background:var(--hover)}
  .menu-list button.d{color:var(--bad)}
  .menu-list hr{border:0;border-top:1px solid var(--line);margin:5px 0}

  /* Banner */
  .note{display:flex;gap:12px;align-items:flex-start;padding:12px 16px;border-radius:var(--r);border:1px solid;font-size:13.5px;margin-bottom:16px}
  .note svg{width:18px;height:18px;flex:none;margin-top:1px}
  .note b{display:block;font-weight:600}
  .note.warn{background:var(--warn-soft);border-color:color-mix(in srgb,var(--warn) 30%,transparent);color:var(--text)}
  .note.warn svg{color:var(--warn)}
  .note.ok{background:var(--ok-soft);border-color:color-mix(in srgb,var(--ok) 30%,transparent)}
  .note.ok svg{color:var(--ok)}
  .note.bad{background:var(--bad-soft);border-color:color-mix(in srgb,var(--bad) 30%,transparent)}
  .note.bad svg{color:var(--bad)}
  .note.info{background:var(--primary-soft);border-color:color-mix(in srgb,var(--primary) 25%,transparent)}
  .note.info svg{color:var(--primary)}

  /* Add-on */
  .addons{display:grid;grid-template-columns:repeat(auto-fill,minmax(320px,1fr));gap:16px}
  .addon{display:flex;flex-direction:column}
  .addon .ah{display:flex;gap:14px;align-items:flex-start;padding:18px 20px 12px}
  .addon .ai{width:42px;height:42px;border-radius:10px;display:grid;place-items:center;background:var(--primary-soft);color:var(--primary);flex:none}
  .addon .ai svg{width:22px;height:22px}
  .addon h3{font-size:15px;font-weight:650;display:flex;gap:8px;align-items:center;flex-wrap:wrap}
  .addon p{color:var(--text-2);font-size:13px;margin-top:4px;line-height:1.5}
  .addon .am{padding:0 20px 12px;display:flex;flex-direction:column;gap:6px;font-size:12.5px;color:var(--muted)}
  .addon .am b{color:var(--text-2);font-weight:550}
  .addon .af{margin-top:auto;padding:12px 20px;border-top:1px solid var(--line);display:flex;gap:8px;flex-wrap:wrap;align-items:center}
  .jprog{position:relative;height:12px;border-radius:99px;background:var(--line);overflow:hidden;margin:4px 0 6px}
  .jprog i{position:relative;display:block;height:100%;width:0;min-width:12px;background:var(--primary);border-radius:99px;transition:width .6s ease;overflow:hidden}
  .jprog.run i{background-image:linear-gradient(45deg,rgba(255,255,255,.22) 25%,transparent 25%,transparent 50%,rgba(255,255,255,.22) 50%,rgba(255,255,255,.22) 75%,transparent 75%,transparent);background-size:22px 22px;animation:jstripe .8s linear infinite}
  .jprog.run i::after{content:"";position:absolute;inset:0;background:linear-gradient(90deg,transparent,rgba(255,255,255,.55),transparent);transform:translateX(-100%);animation:jshine 1.6s ease-in-out infinite}
  .jprog.ok i{background:var(--ok)}.jprog.bad i{background:var(--bad)}
  @keyframes jstripe{to{background-position:22px 0}}
  @keyframes jshine{to{transform:translateX(100%)}}
  .jlive{display:flex;align-items:center;gap:8px;flex-wrap:wrap;color:var(--muted);font-size:12.5px;min-height:20px}
  .jlive .dot{width:8px;height:8px;border-radius:50%;background:var(--primary);flex:none;animation:jpulse 1.2s ease-in-out infinite}
  .jlive.ok .dot{background:var(--ok);animation:none}.jlive.bad .dot{background:var(--bad);animation:none}.jlive.lost .dot{background:var(--warn)}
  .jlive .sep{opacity:.5}
  @keyframes jpulse{0%,100%{opacity:1;transform:scale(1)}50%{opacity:.35;transform:scale(.7)}}
  .chk{list-style:none;margin:0;padding:6px 22px 10px}
  .chk li{display:flex;gap:12px;padding:11px 0;border-bottom:1px solid var(--line);align-items:flex-start}
  .chk li:last-child{border-bottom:0}
  .chk .ci{width:22px;height:22px;border-radius:50%;display:grid;place-items:center;flex:none;margin-top:1px}
  .chk .ci svg{width:13px;height:13px}
  .chk .ok .ci{background:var(--ok-soft);color:var(--ok)}.chk .bad .ci{background:var(--bad-soft);color:var(--bad)}.chk .warn .ci{background:var(--warn-soft);color:var(--warn)}
  .chk b{font-weight:600;font-size:13.5px}
  .chk .cd{color:var(--text-2);font-size:12.5px;margin-top:2px;word-break:break-word}
  .chk .ch2{margin-top:4px;font-size:12px}
  .chk .ch2 code{font-size:11.5px}
  .jtop{padding:16px 22px 6px}
  .jtop .jp{display:flex;justify-content:space-between;align-items:baseline;gap:10px}
  .jtop .jp b{font-size:26px;font-weight:700;font-variant-numeric:tabular-nums}
  .jtop .jp span{color:var(--muted);font-size:13px}
  .jlog{margin:4px 22px 14px}
  .jlog pre.code{max-height:220px;font-size:11.5px}
  /* ZeroTier */
  .zt-node{display:inline-flex;align-items:center;gap:8px}
  .zt-node .dot{margin-right:2px}
  .zt-empty .big{background:var(--primary-soft);color:var(--primary);width:52px;height:52px;border-radius:14px}
  .zt-empty .big svg{width:24px;height:24px}
  .zt-empty p{max-width:460px;margin:6px auto 0;line-height:1.55}
  .zt-hero{overflow:hidden}
  .zt-hh{display:flex;align-items:center;gap:14px;padding:18px 20px;border-bottom:1px solid var(--line)}
  .zt-hic{width:44px;height:44px;border-radius:12px;display:grid;place-items:center;background:linear-gradient(135deg,var(--primary),#3b82f6);color:#fff;flex:none;box-shadow:0 6px 16px -6px rgba(29,78,216,.55)}
  .zt-hic svg{width:22px;height:22px}
  .zt-ht{flex:1;min-width:0}
  .zt-ht h2{font-size:17px;font-weight:650;letter-spacing:-.01em;display:flex;align-items:center;gap:8px;flex-wrap:wrap}
  .zt-ht h2 .pill svg{width:11px;height:11px;margin-right:3px;vertical-align:-1px}
  .zt-id{display:flex;align-items:center;gap:6px;color:var(--muted);font-size:12.5px;margin-top:3px;flex-wrap:wrap}
  .zt-id .mono{color:var(--text-2)}
  .zt-id .sep,.jlive .sep{opacity:.5}
  .zt-ha{display:flex;gap:8px}
  .stats.zt-stats{grid-template-columns:repeat(4,1fr)}
  .zt-stats .stat b{font-size:20px}
  .zt-stats .stat b.mono{font-family:var(--mono);font-size:17px;letter-spacing:0;margin-top:7px}
  .zt-stats .stat b em{font-style:normal;color:var(--muted);font-weight:500;font-size:15px;margin-left:2px}
  .zt-stats .stat small{display:block;color:var(--muted);font-size:12px;margin-top:3px}
  .zt-cnt{display:inline-grid;place-items:center;min-width:18px;height:18px;padding:0 5px;border-radius:9px;background:var(--warn);color:#fff;font-size:11px;font-weight:600;margin-left:3px}
  .chip.on .zt-cnt{background:var(--surface);color:var(--text)}
  .zt-tw{overflow-x:auto}
  .zt-t td{vertical-align:middle}
  .zt-t tr.zt-wait td{background:color-mix(in srgb,var(--warn-soft) 70%,transparent)}
  .zt-dev{display:flex;align-items:center;gap:11px}
  .zt-av{width:34px;height:34px;border-radius:10px;display:grid;place-items:center;flex:none;background:var(--subtle);color:var(--text-2);border:1px solid var(--line)}
  .zt-av svg{width:17px;height:17px}
  .zt-av.router{background:var(--primary-soft);color:var(--primary);border-color:transparent}
  .zt-av.vps{background:var(--ok-soft);color:var(--ok);border-color:transparent}
  .zt-nm{font-weight:550;display:flex;align-items:center;gap:6px;flex-wrap:wrap}
  .zt-nm a{color:inherit}
  .zt-small{font-size:12px}
  .zt-note{max-width:280px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
  .zt-lat{display:inline-block;margin-left:7px;padding:1px 6px;border-radius:6px;background:var(--subtle);color:var(--text-2);font-size:11.5px;font-variant-numeric:tabular-nums}
  .zt-act{white-space:nowrap}
  .zt-act .btn+.btn{margin-left:6px}
  .zt-g2{margin-top:16px;grid-template-columns:1fr 1fr}
  .zt-routes{list-style:none;margin:0;padding:6px 20px 10px}
  .zt-routes li{display:flex;align-items:center;gap:8px;padding:9px 0;border-bottom:1px dashed var(--line);font-size:13px;flex-wrap:wrap}
  .zt-routes li:last-child{border-bottom:0}
  .zt-rt{font-weight:600}
  .zt-arrow{color:var(--muted)}
  .zt-rv{font-size:12.5px;flex:1;min-width:0}
  .zt-nets{list-style:none;margin:0;padding:4px 12px 10px}
  .zt-net{display:flex;align-items:center;gap:12px;padding:11px 8px;border-radius:var(--r-sm)}
  .zt-net+.zt-net{border-top:1px solid var(--line)}
  .zt-net.cur{background:var(--primary-soft)}
  .zt-nic{width:32px;height:32px;border-radius:9px;display:grid;place-items:center;background:var(--subtle);color:var(--text-2);flex:none}
  .zt-net.cur .zt-nic{background:var(--primary);color:#fff}
  .zt-nic svg{width:16px;height:16px}
  .zt-nb{flex:1;min-width:0}
  .zt-nb b{font-weight:600}
  .zt-na{display:flex;gap:6px;align-items:center}
  .zt-danger{border-top:1px solid var(--line);padding-top:12px;padding-bottom:12px}
  .zt-sec{padding:2px 0 14px;border-bottom:1px solid var(--line);margin-bottom:6px}
  .zt-sec:last-of-type{border-bottom:0}
  .zt-sec h3{font-size:12px;font-weight:650;text-transform:uppercase;letter-spacing:.06em;color:var(--muted);margin:10px 0 2px}
  .zt-2col{display:grid;grid-template-columns:1fr 1fr;gap:12px}
  .zt-subwarn{margin:10px 0 0}
  .zt-mhead{display:flex;gap:12px;align-items:center;padding:4px 0 6px}
  .zt-mhead b{font-weight:600}
  .zt-pend .btn{background:var(--surface)}
  textarea.zt-ta{width:100%;min-height:64px;padding:9px 12px;border:1px solid var(--line-2);border-radius:var(--r-sm);background:var(--surface);font:inherit;font-size:14px;color:inherit;outline:none;resize:vertical;transition:border-color .12s,box-shadow .12s}
  textarea.zt-ta:focus{border-color:var(--primary);box-shadow:0 0 0 3px var(--ring)}
  .chip{white-space:nowrap}
  .zt-nodesm{display:none}
  @media (max-width:1024px){.zt-g2{grid-template-columns:1fr}}
  @media (max-width:720px){
    .stats.zt-stats{grid-template-columns:1fr 1fr}.zt-stats .stat:nth-child(2){border-right:0}.zt-stats .stat:nth-child(-n+2){border-bottom:1px solid var(--line)}
    .zt-hh{flex-wrap:wrap;gap:12px}.zt-ht{flex:1 1 calc(100% - 60px)}.zt-ha{flex-basis:100%}.zt-ha .btn{flex:1;justify-content:center}
    .zt-2col{grid-template-columns:1fr}
    .zt-t .zt-colnode,.zt-t .zt-act,.zt-t th.r{display:none}.zt-nodesm{display:block}.zt-t tr.zt-tap{cursor:pointer}
    .zt-rv{display:none}.zt-routes li{gap:6px}
    .filters{flex-wrap:wrap}
  }
  .nav .nav-ext{margin-left:auto;opacity:.55;display:inline-flex}
  .nav .nav-ext svg{width:13px;height:13px}
  /* Stepper tes */
  .tst-head{display:flex;align-items:center;justify-content:space-between;gap:14px;flex-wrap:wrap;padding:18px 20px;border-bottom:1px solid var(--line)}
  .tst-head h2{font-size:15px;font-weight:600}
  .tst-head p{color:var(--muted);font-size:13px;margin-top:2px}
  .prog{height:4px;background:var(--line);overflow:hidden}
  .prog i{display:block;height:100%;width:0;background:var(--primary);transition:width .35s ease}
  .steps{list-style:none;margin:0;padding:8px 20px 12px}
  .step{display:flex;gap:14px;padding:12px 0;position:relative}
  .step:not(:last-child)::after{content:"";position:absolute;left:13px;top:42px;bottom:-6px;width:2px;background:var(--line)}
  .step.ok:not(:last-child)::after{background:color-mix(in srgb,var(--ok) 45%,var(--line))}
  .sic{width:28px;height:28px;border-radius:50%;flex:none;display:grid;place-items:center;border:2px solid var(--line-2);background:var(--surface);color:var(--muted);font-size:12px;font-weight:600;position:relative;z-index:1}
  .sic svg{width:15px;height:15px}
  .step.run .sic{border-color:var(--primary);color:var(--primary)}
  .step.run .sic::before{content:"";position:absolute;inset:-2px;border-radius:50%;border:2px solid transparent;border-top-color:var(--primary);animation:spin .8s linear infinite}
  .step.ok .sic{background:var(--ok);border-color:var(--ok);color:#fff}
  .step.fail .sic{background:var(--bad);border-color:var(--bad);color:#fff}
  .step.skip .sic{background:var(--subtle);border-color:var(--line-2)}
  .stx{flex:1;min-width:0;padding-top:3px}
  .stx b{display:block;font-weight:600;font-size:14px}
  .step.wait .stx b{color:var(--muted);font-weight:500}
  .stx small{display:block;color:var(--muted);font-size:12.5px}
  .sres{margin-top:6px;font-size:13px}
  .step.ok .sres{color:var(--ok)}
  .step.fail .sres{color:var(--bad)}
  .sres .hint{display:block;margin-top:4px;padding:8px 10px;border-radius:6px;background:var(--subtle);color:var(--text-2);font-size:12.5px}
  .step .tm{font-size:12px;color:var(--muted);padding-top:5px;font-variant-numeric:tabular-nums}
  @keyframes spin{to{transform:rotate(360deg)}}
  .tst-sum{padding:14px 20px;border-top:1px solid var(--line);display:flex;align-items:center;gap:10px;font-weight:550}
  .tst-sum.ok{color:var(--ok)}.tst-sum.fail{color:var(--bad)}

  /* Riwayat */
  .stats{display:grid;grid-template-columns:repeat(3,1fr)}
  .stat{padding:16px 20px;border-right:1px solid var(--line)}
  .stat:last-child{border-right:0}
  .stat span{font-size:12.5px;color:var(--muted);font-weight:500}
  .stat b{display:block;font-size:26px;font-weight:650;letter-spacing:-.03em;margin-top:4px;font-variant-numeric:tabular-nums}
  .stat b.warn{color:var(--warn)}.stat b.bad{color:var(--bad)}
  .bars{display:flex;gap:3px;height:38px}
  .bars i{flex:1;border-radius:3px;background:var(--ok);opacity:.85;transition:opacity .12s,transform .12s;cursor:default}
  .bars i:hover{opacity:1;transform:scaleY(1.1)}
  .bars i.minor{background:var(--warn)}.bars i.major{background:var(--bad)}.bars i.nodata{background:var(--line)}
  .bar-axis{display:flex;justify-content:space-between;font-size:12px;color:var(--muted);margin-top:8px}
  .legend{display:flex;flex-wrap:wrap;gap:6px 16px;font-size:12px;color:var(--muted);margin-top:12px}
  .legend i{display:inline-block;width:10px;height:10px;border-radius:2px;margin-right:6px;vertical-align:-1px}
  .bar-tip{min-height:20px;font-size:12.5px;color:var(--text-2);margin-top:10px}

  /* Form */
  label{display:block;font-size:13px;font-weight:500;margin:14px 0 6px}
  .help{font-size:12.5px;color:var(--muted);margin-top:6px}
  input[type=text],input[type=password],input[type=number],input[type=time],select{width:100%;height:38px;padding:0 12px;border:1px solid var(--line-2);border-radius:var(--r-sm);background:var(--surface);font-size:14px;outline:none;transition:border-color .12s,box-shadow .12s}
  input:focus,select:focus{border-color:var(--primary);box-shadow:0 0 0 3px var(--ring)}
  input[readonly]{background:var(--subtle)}
  input::placeholder{color:var(--muted)}
  input[type=checkbox],input[type=radio]{accent-color:var(--primary);width:16px;height:16px}
  .err{color:var(--bad);font-size:13px;margin-top:10px;min-height:0}
  .f2{display:grid;grid-template-columns:1fr 1fr;gap:0 14px}
  .check{display:flex;align-items:center;gap:9px;font-weight:500;cursor:pointer}
  .seg{display:flex;gap:6px;flex-wrap:wrap}
  .sw{display:inline-flex;padding:3px;gap:2px;background:var(--subtle);border:1px solid var(--line);border-radius:10px}
  .sw button{border:0;background:transparent;padding:6px 14px;border-radius:7px;font:inherit;font-size:13px;font-weight:550;color:var(--muted);cursor:pointer;display:inline-flex;align-items:center;gap:6px}
  .sw button:hover{color:var(--text)}
  .sw button.on{background:var(--surface);color:var(--text);box-shadow:0 1px 2px rgba(0,0,0,.08)}
  .sw button.on.danger{color:var(--bad)}
  .seg label{margin:0;display:flex;align-items:center;gap:8px;padding:8px 12px;border:1px solid var(--line-2);border-radius:var(--r-sm);cursor:pointer;font-weight:500}
  .seg label:has(input:checked){border-color:var(--primary);background:var(--primary-soft)}
  .form-actions{display:flex;gap:8px;margin-top:18px;flex-wrap:wrap}
  .form-actions .sp{flex:1}
  .sec-t{font-size:13px;font-weight:600;color:var(--text);margin:20px 0 2px;padding-top:16px;border-top:1px solid var(--line)}
  .sec-t:first-child{margin-top:0;padding-top:0;border-top:0}
  .check+.help{margin:-8px 0 8px 25px}
  select:disabled,input:disabled{background:var(--subtle);color:var(--muted)}

  /* Tabel kecil */
  table.t{width:100%;border-collapse:collapse;font-size:13.5px}
  table.t th{text-align:left;font-size:12px;font-weight:550;color:var(--muted);padding:10px 20px;border-bottom:1px solid var(--line);background:var(--subtle)}
  table.t td{padding:12px 20px;border-bottom:1px solid var(--line);vertical-align:middle}
  table.t tr:last-child td{border-bottom:0}
  table.t .r{text-align:right}

  /* Kode */
  pre.code{margin:0;background:var(--code-bg);color:var(--code-fg);font:12.5px/1.6 var(--mono);padding:16px 18px;border-radius:var(--r-sm);overflow:auto;max-height:340px;white-space:pre}
  .codebox{position:relative}
  .codebox .btn{position:absolute;top:10px;right:10px;background:rgba(255,255,255,.1);border-color:rgba(255,255,255,.15);color:#fff}
  .codebox .btn:hover{background:rgba(255,255,255,.18)}
  .howto{list-style:none;margin:0 0 16px;padding:0;display:grid;grid-template-columns:repeat(3,1fr);gap:12px}
  .howto li{padding:12px 14px;border:1px solid var(--line);border-radius:var(--r-sm);font-size:13px;color:var(--text-2)}
  .howto b{display:flex;align-items:center;gap:8px;color:var(--text);font-weight:600;margin-bottom:3px}
  .howto i{font-style:normal;width:20px;height:20px;border-radius:50%;background:var(--primary-soft);color:var(--primary);font-size:11.5px;display:grid;place-items:center}
  details.more{margin-top:14px}
  details.more summary{cursor:pointer;color:var(--muted);font-size:13px}
  details.more pre{margin-top:10px}

  /* Panduan */
  .guide p{color:var(--text-2)}
  .guide p+p{margin-top:8px}
  .flow{display:flex;align-items:center;gap:8px;flex-wrap:wrap;margin:4px 0 14px}
  .flow span{padding:6px 11px;border-radius:6px;background:var(--subtle);border:1px solid var(--line);font-size:13px;font-weight:500}
  .flow i{color:var(--muted);font-style:normal}
  .ol{counter-reset:s;list-style:none;margin:0;padding:0}
  .ol li{counter-increment:s;position:relative;padding:0 0 14px 38px}
  .ol li::before{content:counter(s);position:absolute;left:0;top:0;width:24px;height:24px;border-radius:50%;background:var(--primary-soft);color:var(--primary);font-size:12px;font-weight:600;display:grid;place-items:center}
  .ol b{display:block}
  .faq details{border-bottom:1px solid var(--line);padding:14px 20px}
  .faq details:last-child{border-bottom:0}
  .faq summary{cursor:pointer;font-weight:550}
  .faq p{margin-top:8px;color:var(--text-2)}

  /* Modal */
  .mbg{position:fixed;inset:0;background:rgba(15,23,42,.45);display:flex;align-items:flex-start;justify-content:center;padding:60px 14px;overflow:auto;z-index:60;animation:fade .15s}
  .modal{width:100%;max-width:520px;background:var(--surface);border-radius:12px;box-shadow:var(--shadow-lg);animation:pop .18s ease}
  .mh{display:flex;align-items:center;padding:18px 22px 4px}
  .mh h2{font-size:16.5px;font-weight:650}
  .mh .x{margin-left:auto}
  .mb{padding:6px 22px 4px}
  .mb>p{color:var(--text-2)}
  .mf{display:flex;justify-content:flex-end;gap:8px;padding:18px 22px}
  @keyframes fade{from{opacity:0}}
  @keyframes pop{from{opacity:0;transform:translateY(8px) scale(.98)}}

  /* Login */
  .login{min-height:100vh;display:grid;place-items:center;padding:24px}
  .login-card{width:100%;max-width:380px}
  .login-card .brand{justify-content:center;color:var(--text);padding:0 0 26px}
  .login-card .brand-mark{background:var(--primary);color:#fff}
  .login-card .brand small{color:var(--muted)}
  .login-box{background:var(--surface);border:1px solid var(--line);border-radius:12px;padding:26px;box-shadow:var(--shadow)}
  .login-box h1{font-size:18px;font-weight:650}
  .login-box p{color:var(--muted);margin:3px 0 6px}
  .login-box .btn{width:100%;margin-top:18px;height:40px}
  .login-foot{text-align:center;color:var(--muted);font-size:12px;margin-top:18px}

  /* Sidebar footer, menu akun */
  .side-foot{display:flex;justify-content:space-between;padding:12px 12px 2px;border-top:1px solid rgba(255,255,255,.08);font-size:11.5px;color:rgba(255,255,255,.45)}
  .user-btn{display:flex;align-items:center;gap:8px;height:38px;padding:0 8px 0 4px;border:1px solid transparent;border-radius:999px;background:none}
  .user-btn:hover{background:var(--hover)}
  .user-btn .who{font-size:13.5px;font-weight:550}
  .user-btn svg{width:15px;height:15px;color:var(--muted)}
  .menu-h{padding:8px 10px 10px;border-bottom:1px solid var(--line);margin-bottom:5px}
  .menu-h b{display:block;font-size:13.5px}.menu-h small{color:var(--muted);font-size:12px}
  .menu-list button svg{width:16px;height:16px;color:var(--muted)}
  .menu-list button.d svg{color:var(--bad)}

  /* Dialog */
  .modal.sm{max-width:440px}.modal.md{max-width:640px}.modal.lg{max-width:680px}
  .dlg-b{display:flex;gap:16px;padding:24px 24px 6px}
  .dlg-b h2{font-size:16.5px;font-weight:650;margin-bottom:4px}
  .dlg-t{color:var(--text-2);font-size:14px}
  .dlg-t p+p{margin-top:8px}
  .dlg-ic{width:42px;height:42px;border-radius:50%;flex:none;display:grid;place-items:center}
  .dlg-ic svg{width:20px;height:20px}
  .dlg-ic.bad{background:var(--bad-soft);color:var(--bad)}
  .dlg-ic.info{background:var(--primary-soft);color:var(--primary)}
  .dlg-ic.ok{background:var(--ok-soft);color:var(--ok)}
  .dlg-ic.warn{background:var(--warn-soft);color:var(--warn)}
  .dlg .mf{padding:18px 24px 20px}
  .btn.dangerf{background:var(--bad);border-color:var(--bad);color:#fff}
  .btn.dangerf:hover{filter:brightness(.92);background:var(--bad)}
  .spin{width:14px;height:14px;border:2px solid currentColor;border-right-color:transparent;border-radius:50%;display:inline-block;animation:spin .7s linear infinite}
  .mb.flush{padding:0}
  .modal.lg .mb{max-height:calc(100vh - 230px);overflow:auto}
  .modal.lg .mf{border-top:1px solid var(--line)}
  .step.skip .sres{color:var(--muted)}
  .grid-dash{display:grid;grid-template-columns:minmax(0,1.75fr) minmax(300px,1fr);gap:16px;align-items:start}
  .modal .steps{padding:4px 22px 8px}
  .modal .prog{margin:0}
  .tst-top{padding:0 22px 14px;color:var(--muted);font-size:13px}
  .modal .tst-sum{border-top:1px solid var(--line)}

  /* Tabel uptime dashboard */
  table.t tr.click{cursor:pointer;transition:background .12s}
  table.t tr.click:hover td{background:var(--hover)}
  .srv{display:flex;align-items:center;gap:10px;min-width:0}
  .srv b{font-weight:600;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;display:block}
  .srv small{display:block;color:var(--muted);font-size:12px;white-space:nowrap}
  .mini{display:flex;gap:2px;height:20px;min-width:120px}
  .mini i{flex:1;border-radius:2px;background:var(--ok);opacity:.85}
  .mini i.minor{background:var(--warn)}.mini i.major{background:var(--bad)}.mini i.nodata{background:var(--line)}
  td.pc{font-variant-numeric:tabular-nums;font-weight:550;white-space:nowrap}
  td.pc.warn{color:var(--warn)}td.pc.bad{color:var(--bad)}
  a.ext{display:inline-flex;align-items:center;gap:5px;font-family:var(--mono);font-size:13px;font-weight:500}
  a.ext svg{width:13px;height:13px}
  a.ext:hover{text-decoration:underline}
  .btn.del-ic{color:var(--bad)}
  .tag{display:inline-flex;align-items:center;height:20px;padding:0 7px;border-radius:5px;font-size:11px;font-weight:600;letter-spacing:.02em;background:var(--primary-soft);color:var(--primary);white-space:nowrap;vertical-align:middle}
  .tag.gray{background:var(--subtle);color:var(--muted);border:1px solid var(--line)}
  .pick{display:flex;align-items:center;gap:12px;padding:12px 14px;border:1px solid var(--line);border-radius:var(--r-sm);margin-top:8px}
  .pick b{font-family:var(--mono);font-size:14px}
  .pick small{display:block;color:var(--muted);font-size:12px}
  .pick .grow{flex:1;min-width:0}
  .netopt{display:flex;align-items:center;gap:12px;padding:12px 14px;border:1px solid var(--line-2);border-radius:var(--r-sm);margin-top:8px;cursor:pointer}
  .netopt:has(input:checked){border-color:var(--primary);background:var(--primary-soft)}
  .netopt.dis{opacity:.6;cursor:not-allowed}
  .netopt small{display:block;color:var(--muted);font-size:12px}
  .btn.del-ic:hover{background:var(--bad-soft);color:var(--bad)}

  [data-act=refresh].spinning svg{animation:spin .8s linear infinite}
  .toast{position:fixed;left:50%;bottom:24px;transform:translateX(-50%);background:var(--text);color:var(--surface);padding:10px 16px;border-radius:8px;font-size:13.5px;font-weight:500;z-index:90;box-shadow:var(--shadow-lg);animation:pop .18s}

  @media (max-width:1024px){
    .side{transform:translateX(-100%)}
    body.nav-open .side{transform:none}
    .wrap{margin-left:0}
    #navBtn{display:inline-flex}
    .top{padding:0 14px}
    .main{padding:20px 16px}
    #topWarn{padding:16px 16px 0}
    .grid2,.grid-dash{grid-template-columns:1fr}
  }
  @media (max-width:1280px){ .hide-md{display:none} }
  @media (max-width:720px){
    .kpis{grid-template-columns:1fr 1fr;gap:10px}
    .kpi b{font-size:24px}
    .row .meta{display:none}
    .dl{grid-template-columns:1fr}
    .dl>div:nth-child(odd){border-right:0}
    .howto{grid-template-columns:1fr}
    .stat{padding:12px 14px}.stat b{font-size:20px}
    .up{display:none}
    .f2{grid-template-columns:1fr}
    .toolbar{flex-wrap:wrap}
    .search{max-width:none;flex-basis:100%}
    .filters{margin-left:0}
    table.t .hide-sm{display:none}
    table.t th,table.t td{padding-left:14px;padding-right:14px}
    .user-btn .who,.user-btn svg{display:none}
    .hide-md{display:none}
  }
</style>
</head>
<body>

<!-- ================= LOGIN ================= -->
<div id="loginView" class="login hidden">
  <div class="login-card">
    <div class="brand"><span class="brand-mark" data-ic="shield"></span><span><b class="brand-name">VPN ACS</b><small>Control Panel</small></span></div>
    <form id="loginForm" class="login-box">
      <h1>Masuk</h1>
      <p>Masukkan password admin panel.</p>
      <label for="lp">Password</label>
      <input id="lp" type="password" autocomplete="current-password" autofocus>
      <div class="err" id="loginErr"></div>
      <button class="btn pri">Masuk</button>
    </form>
    <div class="login-foot">GenieACS · L2TP · NETMAP</div>
  </div>
</div>

<!-- ================= APLIKASI ================= -->
<div id="appView" class="hidden">
  <aside class="side">
    <div class="brand"><span class="brand-mark" data-ic="shield"></span><span><b class="brand-name">VPN ACS</b><small>Control Panel</small></span></div>
    <button class="nav" data-go="#/"><span data-ic="home"></span>Dashboard</button>
    <button class="nav" data-go="#/router"><span data-ic="router"></span>Router</button>
    <button class="nav" data-go="#/genieacs"><span data-ic="box"></span>GenieACS</button>
    <button class="nav hidden" id="navZt" data-go="#/zerotier"><span data-ic="hub"></span>ZeroTier</button>
    <div id="navApps"></div>
    <button class="nav" data-go="#/pengaturan"><span data-ic="gear"></span>Pengaturan</button>
    <button class="nav" data-go="#/addon"><span data-ic="puzzle"></span>Add-on</button>
    <button class="nav" data-go="#/panduan"><span data-ic="book"></span>Panduan</button>
    <button class="nav" data-go="#/log"><span data-ic="list"></span>Log aktivitas</button>
    <div class="grow"></div>
    <div class="side-foot"><span class="brand-name">VPN ACS</span><span id="ver"></span></div>
  </aside>
  <div class="backdrop" data-act="closenav"></div>
  <div class="wrap">
    <header class="top">
      <button class="btn ghost icon" id="navBtn" data-act="opennav" aria-label="Menu"><span data-ic="menu"></span></button>
      <div class="crumb" id="crumb"></div>
      <div class="top-r">
        <button class="btn ghost icon" data-act="refresh" title="Perbarui status"><span data-ic="refresh"></span></button>
        <div class="menu">
          <button class="user-btn" data-act="usermenu" aria-label="Menu akun"><span class="avatar">A</span><span class="who">Admin</span><span data-ic="down"></span></button>
          <div class="menu-list hidden" id="userList">
            <div class="menu-h"><b>Admin</b><small>Administrator panel</small></div>
            <button data-act="theme"><span id="themeIc"></span><span id="themeTx">Mode gelap</span></button>
            <button data-go="#/pengaturan/umum"><span data-ic="gear"></span>Pengaturan</button>
            <hr><button class="d" data-act="logout"><span data-ic="logout"></span>Keluar</button>
          </div>
        </div>
      </div>
    </header>
    <div id="topWarn"></div>
    <main class="main" id="view"></main>
  </div>
</div>

<div id="modalRoot"></div>

<script>
"use strict";
/* ================= Utilitas ================= */
const $ = (s, el = document) => el.querySelector(s);
const esc = (v) => String(v ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
const SV = 'viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"';
const ICONS = {
  shield: '<path d="M12 3l8 3v6c0 4.5-3.4 8.3-8 9-4.6-.7-8-4.5-8-9V6l8-3z"/><path d="M9 12l2 2 4-4"/>',
  home: '<path d="M3 10.5L12 3l9 7.5V20a1 1 0 0 1-1 1h-5v-6H9v6H4a1 1 0 0 1-1-1z"/>',
  router: '<rect x="3" y="13" width="18" height="7" rx="2"/><path d="M7 16.5h.01M11 16.5h.01M8 9a6 6 0 0 1 8 0M5.5 6.5a10 10 0 0 1 13 0"/>',
  book: '<path d="M4 5a2 2 0 0 1 2-2h13v16H6a2 2 0 0 0-2 2V5z"/><path d="M4 19a2 2 0 0 1 2-2h13"/>',
  gear: '<circle cx="12" cy="12" r="3"/><path d="M12 2v3M12 19v3M4.2 4.2l2.1 2.1M17.7 17.7l2.1 2.1M2 12h3M19 12h3M4.2 19.8l2.1-2.1M17.7 6.3l2.1-2.1"/>',
  moon: '<path d="M21 12.8A9 9 0 1 1 11.2 3a7 7 0 0 0 9.8 9.8z"/>',
  logout: '<path d="M9 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h4M16 17l5-5-5-5M21 12H9"/>',
  menu: '<path d="M4 6h16M4 12h16M4 18h16"/>',
  refresh: '<path d="M21 12a9 9 0 1 1-2.6-6.4M21 4v5h-5"/>',
  chev: '<path d="M9 6l6 6-6 6"/>',
  back: '<path d="M15 18l-6-6 6-6"/>',
  plus: '<path d="M12 5v14M5 12h14"/>',
  search: '<circle cx="11" cy="11" r="7"/><path d="M21 21l-4.3-4.3"/>',
  copy: '<rect x="9" y="9" width="12" height="12" rx="2"/><path d="M5 15V5a2 2 0 0 1 2-2h10"/>',
  check: '<path d="M5 12.5l4.5 4.5L19 7.5"/>',
  x: '<path d="M18 6L6 18M6 6l12 12"/>',
  minus: '<path d="M6 12h12"/>',
  alert: '<path d="M12 3l9.5 17H2.5z"/><path d="M12 10v4M12 17h.01"/>',
  info: '<circle cx="12" cy="12" r="9"/><path d="M12 11v5M12 8h.01"/>',
  dots: '<circle cx="5" cy="12" r="1.3"/><circle cx="12" cy="12" r="1.3"/><circle cx="19" cy="12" r="1.3"/>',
  eye: '<path d="M2 12s3.5-7 10-7 10 7 10 7-3.5 7-10 7S2 12 2 12z"/><circle cx="12" cy="12" r="3"/>',
  trash: '<path d="M3 6h18M8 6V4h8v2M19 6l-1 14H6L5 6"/>',
  edit: '<path d="M12 20h9"/><path d="M16.5 3.5a2.1 2.1 0 0 1 3 3L7 19l-4 1 1-4z"/>',
  key: '<circle cx="8" cy="15" r="4"/><path d="M10.8 12.2L20 3M16 7l3 3"/>',
  play: '<path d="M7 5l12 7-12 7z"/>',
  wifi_off: '<path d="M2 2l20 20M8.5 16.5a5 5 0 0 1 7 0M5 12.9a10 10 0 0 1 5.2-2.8M19 12.9a10 10 0 0 0-2-1.4M12 20h.01"/>',
  globe: '<circle cx="12" cy="12" r="9"/><path d="M3 12h18M12 3a14 14 0 0 1 0 18M12 3a14 14 0 0 0 0 18"/>',
  box: '<path d="M21 8l-9-5-9 5v8l9 5 9-5V8z"/><path d="M3 8l9 5 9-5M12 13v8"/>',
  puzzle: '<path d="M10 3h4v3a2 2 0 1 0 4 0V6h3v5h-3a2 2 0 1 0 0 4h3v6h-5v-3a2 2 0 1 0-4 0v3H4v-6h3a2 2 0 1 0 0-4H4V6h6z"/>',
  wallet: '<rect x="3" y="6" width="18" height="14" rx="2"/><path d="M3 10h18"/><path d="M16 15h2"/><path d="M6 6V5a2 2 0 0 1 2-2h9"/>',
  hub: '<circle cx="12" cy="5" r="2.2"/><circle cx="5" cy="18" r="2.2"/><circle cx="19" cy="18" r="2.2"/><path d="M12 7.2v4.3M12 11.5l-5.5 4.6M12 11.5l5.5 4.6"/>',
  bolt: '<path d="M13 2L4 14h7l-1 8 9-12h-7z"/>',
  share: '<path d="M4 12h11M11 8l4 4-4 4"/><rect x="15" y="5" width="6" height="14" rx="2"/>',
  code: '<path d="M8 8l-4 4 4 4M16 8l4 4-4 4M13.5 5l-3 14"/>',
  pulse: '<path d="M3 12h4l2.5-6 5 12 2.5-6h4"/>',
  sliders: '<path d="M4 6h10M18 6h2M4 12h4M12 12h8M4 18h12M20 18h0"/><circle cx="16" cy="6" r="2"/><circle cx="10" cy="12" r="2"/><circle cx="18" cy="18" r="2"/>',
  down: '<path d="M6 9l6 6 6-6"/>',
  sun: '<circle cx="12" cy="12" r="4"/><path d="M12 2v2M12 20v2M4.9 4.9l1.4 1.4M17.7 17.7l1.4 1.4M2 12h2M20 12h2M4.9 19.1l1.4-1.4M17.7 6.3l1.4-1.4"/>',
  list: '<path d="M9 6h11M9 12h11M9 18h11M4.5 6h.01M4.5 12h.01M4.5 18h.01"/>',
  bell: '<path d="M18 8a6 6 0 1 0-12 0c0 7-3 9-3 9h18s-3-2-3-9"/><path d="M13.7 21a2 2 0 0 1-3.4 0"/>',
  send: '<path d="M22 2L11 13M22 2l-7 20-4-9-9-4z"/>',
  lock: '<rect x="4" y="11" width="16" height="10" rx="2"/><path d="M8 11V7a4 4 0 0 1 8 0v4"/>',
  clock: '<circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/>',
  ext: '<path d="M14 4h6v6M20 4l-9 9M18 14v5a1 1 0 0 1-1 1H5a1 1 0 0 1-1-1V7a1 1 0 0 1 1-1h5"/>',
};
const ic = (n, cls = "i") => `<svg class="${cls}" ${SV}>${ICONS[n] || ""}</svg>`;
function paintIcons(root = document) { root.querySelectorAll("[data-ic]").forEach((el) => { el.innerHTML = ic(el.dataset.ic); el.removeAttribute("data-ic"); }); }

let STATE = { settings: {}, sites: [] };
let LOADED = false;

async function api(path, opts = {}) {
  const o = { method: opts.method || "GET", headers: {}, credentials: "same-origin" };
  if (o.method !== "GET") { o.headers["Content-Type"] = "application/json"; o.body = JSON.stringify(opts.body || {}); }
  const r = await fetch(path, o);
  let data = {};
  try { data = await r.json(); } catch (e) {}
  if (r.status === 401 && path !== "/api/login") { showLogin(); throw new Error(data.error || "Sesi habis"); }
  if (!r.ok) { const err = new Error(data.error || "Terjadi kesalahan (" + r.status + ")"); err.data = data; throw err; }
  return data;
}
function toast(msg) {
  document.querySelectorAll(".toast").forEach((t) => t.remove());
  const t = document.createElement("div"); t.className = "toast"; t.textContent = msg;
  document.body.appendChild(t); setTimeout(() => t.remove(), 2400);
}
function copyText(text, msg) {
  const done = () => toast(msg || "Tersalin");
  if (navigator.clipboard && window.isSecureContext) return navigator.clipboard.writeText(text).then(done);
  const ta = document.createElement("textarea"); ta.value = text; ta.style.position = "fixed"; ta.style.opacity = "0";
  document.body.appendChild(ta); ta.select();
  try { document.execCommand("copy"); } finally { ta.remove(); }
  done();
}
const copyBtn = (text, msg) => `<button class="copy" title="Salin" data-copy="${esc(text)}" data-msg="${esc(msg || "")}">${ic("copy", "")}</button>`;
const site = (id) => STATE.sites.find((s) => s.id === id);
const ST = { up: ["ok", "Tersambung"], down: ["bad", "Terputus"], pending: ["wait", "Menunggu pemasangan"] };
const stOf = (x) => ST[x.state] || ST.down;
const ztTag = (x) => (x.transport === "zt" ? ` <span class="tag" title="Tersambung lewat ZeroTier">ZT</span>` : "");
function tzId() { return STATE.settings.timezone || "Asia/Makassar"; }
function tzLabel() { const z = (STATE.settings.timezones || []).find((t) => t.id === tzId()); return z ? z.label : ""; }
function fmtT(t, full) {
  if (!t) return "—";
  const o = { timeZone: tzId(), hour: "2-digit", minute: "2-digit", hour12: false };
  if (full) { o.day = "numeric"; o.month = "short"; }
  try { return new Date(t).toLocaleString("id-ID", o); } catch (e) { return new Date(t).toLocaleString(); }
}
function fmtDur(ms) {
  const mins = Math.round(ms / 60000);
  if (mins < 1) return "< 1 menit";
  const d = Math.floor(mins / 1440), h = Math.floor((mins % 1440) / 60), m = mins % 60, p = [];
  if (d) p.push(d + " hari"); if (h) p.push(h + " jam"); if (m && !d) p.push(m + " menit");
  return p.slice(0, 2).join(" ");
}
function pct(v) { if (v == null) return "—"; return (v >= 99.995 ? "100" : v.toFixed(v >= 99 ? 2 : 1)).replace(".", ",") + "%"; }
const pctCls = (v) => (v == null || v >= 99 ? "" : v >= 95 ? "warn" : "bad");
function genieOk(v) { if (!v) return false; const x = v.toLowerCase(); return ["all", "true", "1", "yes"].includes(x) || v.split(",").map((t) => t.trim()).includes("10.100.0.0/14"); }

/* ================= Tema ================= */
function applyTheme(t) {
  document.documentElement.setAttribute("data-theme", t);
  const i = document.getElementById("themeIc"), x = document.getElementById("themeTx");
  if (i) i.innerHTML = ic(t === "dark" ? "sun" : "moon");
  if (x) x.textContent = t === "dark" ? "Mode terang" : "Mode gelap";
}
(function () {
  let t = null;
  try { t = localStorage.getItem("vpnacs-theme"); } catch (e) {}
  if (!t) t = window.matchMedia && matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light";
  applyTheme(t);
})();
function toggleTheme() {
  const t = document.documentElement.getAttribute("data-theme") === "dark" ? "light" : "dark";
  applyTheme(t);
  try { localStorage.setItem("vpnacs-theme", t); } catch (e) {}
}

/* ================= Dialog ================= */
function modal(title, body, footer, opts = {}) {
  $("#modalRoot").innerHTML = `<div class="mbg" id="mbg"><div class="modal ${opts.size || ""}" role="dialog" aria-modal="true">
    <div class="mh"><h2>${title}</h2><button class="btn ghost icon x" data-act="closemodal" aria-label="Tutup">${ic("x")}</button></div>
    <div class="mb${opts.flush ? " flush" : ""}">${body}</div>${footer ? `<div class="mf">${footer}</div>` : `<div style="height:18px"></div>`}</div></div>`;
  $("#mbg").addEventListener("mousedown", (e) => { if (e.target.id === "mbg") closeModal(); });
  const f = $("#modalRoot input:not([readonly]):not([type=radio]):not([type=checkbox])"); if (f) f.focus();
}
function closeModal() { $("#modalRoot").innerHTML = ""; if (TEST && !TEST.keep) TEST = null; }
function busyBtn(btn, on) {
  if (!btn) return;
  if (on) { btn.dataset.html = btn.innerHTML; btn.disabled = true; btn.innerHTML = `<span class="spin"></span>${btn.textContent.trim()}`; }
  else { btn.disabled = false; if (btn.dataset.html) btn.innerHTML = btn.dataset.html; }
}
// Dialog konfirmasi: tombol OK menjalankan onOk; galat ditampilkan di dalam dialog
function confirmDialog({ title, text, ok = "Lanjutkan", danger = false, icon, onOk, check, wide }) {
  const kind = danger ? "bad" : "info";
  $("#modalRoot").innerHTML = `<div class="mbg" id="mbg"><div class="modal dlg ${wide ? "md" : "sm"}" role="alertdialog" aria-modal="true">
    <div class="dlg-b"><span class="dlg-ic ${kind}">${ic(icon || (danger ? "trash" : "info"))}</span>
      <div style="flex:1;min-width:0"><h2>${title}</h2><div class="dlg-t">${text}</div>
        ${check ? `<label class="chk" style="display:flex;gap:10px;align-items:flex-start;margin:14px 0 0;font-weight:500;cursor:pointer"><input type="checkbox" id="dlgChk" style="margin-top:3px;width:16px;height:16px;flex:none"><span>${check}</span></label>` : ""}
        <div class="err" id="dlgErr"></div></div></div>
    <div class="mf"><button class="btn" data-act="closemodal">Batal</button><button class="btn ${danger ? "dangerf" : "pri"}" id="dlgOk" ${check ? "disabled" : ""}>${ok}</button></div></div></div>`;
  $("#mbg").addEventListener("mousedown", (e) => { if (e.target.id === "mbg") closeModal(); });
  const btn = $("#dlgOk");
  if (check) { $("#dlgChk").onchange = () => { btn.disabled = !$("#dlgChk").checked; }; $("#dlgChk").focus(); } else btn.focus();
  btn.onclick = async () => {
    $("#dlgErr").textContent = ""; busyBtn(btn, true);
    try { await onOk(); } catch (e) { if ($("#dlgErr")) { $("#dlgErr").textContent = e.message; busyBtn(btn, false); } }
  };
}
// Dialog hasil (berhasil / gagal), tertutup sendiri bila autoClose
function doneDialog(title, text, kind = "ok", autoClose = true) {
  $("#modalRoot").innerHTML = `<div class="mbg" id="mbg"><div class="modal dlg sm" role="dialog" aria-modal="true">
    <div class="dlg-b"><span class="dlg-ic ${kind}">${ic(kind === "ok" ? "check" : kind === "bad" ? "x" : "info")}</span>
      <div style="flex:1;min-width:0"><h2>${title}</h2>${text ? `<div class="dlg-t">${text}</div>` : ""}</div></div>
    <div class="mf"><button class="btn pri" data-act="closemodal" id="dlgOk">OK</button></div></div></div>`;
  $("#mbg").addEventListener("mousedown", (e) => { if (e.target.id === "mbg") closeModal(); });
  $("#dlgOk").focus();
  if (autoClose) { const el = $("#mbg"); setTimeout(() => { if ($("#mbg") === el) closeModal(); }, 2600); }
}

/* ================= Login ================= */
let BRAND = "VPN ACS";
function setBrand(n) {
  BRAND = n || "VPN ACS";
  document.querySelectorAll(".brand-name").forEach((el) => (el.textContent = BRAND));
}
function showLogin() { $("#appView").classList.add("hidden"); $("#loginView").classList.remove("hidden"); document.title = `Masuk · ${BRAND}`; $("#lp").focus(); }
function showApp() { $("#loginView").classList.add("hidden"); $("#appView").classList.remove("hidden"); }
$("#loginForm").addEventListener("submit", async (e) => {
  e.preventDefault(); $("#loginErr").textContent = "";
  const btn = $("#loginForm button"); busyBtn(btn, true);
  try { await api("/api/login", { method: "POST", body: { password: $("#lp").value } }); $("#lp").value = ""; showApp(); await load(); route(); }
  catch (err) { $("#loginErr").textContent = err.message; }
  busyBtn(btn, false);
});

/* ================= Data ================= */
async function load() {
  STATE = await api("/api/overview");
  LOADED = true;
  $("#ver").textContent = STATE.settings.version ? "v" + STATE.settings.version : "";
  setBrand(STATE.settings.panelName);
  const A = STATE.settings.addons || {};
  $("#navZt").classList.toggle("hidden", !(A.zerotier && A.zerotier.installed));
  $("#navApps").innerHTML = Object.entries(A).filter(([, a]) => a.kind === "aplikasi" && a.installed)
    .map(([id, a]) => `<a class="nav" href="${esc(a.path)}/" target="_blank" rel="noopener" title="Buka ${esc(a.name)} di tab baru"><span>${ic(a.icon || "box")}</span>${esc(a.name)}<span class="nav-ext">${ic("ext", "")}</span></a>`).join("");
}
function ztOn() { const a = (STATE.settings.addons || {}).zerotier; return !!(a && a.installed); }

/* ================= Router ================= */
let TEST = null; // tes koneksi yang sedang tampil
// Peringatan di semua halaman selama password masih bawaan
function topWarn(parts) {
  const el = $("#topWarn");
  if (!el) return;
  const st = STATE.settings || {};
  if (!st.defaultPassword) { el.innerHTML = ""; return; }
  const P = st.stdPorts || {};
  const onSet = parts[0] === "pengaturan" && (!parts[1] || parts[1] === "umum");
  el.innerHTML = `<div class="note bad">${ic("alert")}<div><b>Password admin masih bawaan (Admin123)</b>${P.active ? "Panel terbuka di port 80/443 sehingga mudah ditemukan orang. " : ""}Siapa pun yang mencoba Admin123 bisa masuk dan mengubah router Anda. Segera ganti password.</div>${onSet ? "" : `<a class="btn pri" href="#/pengaturan/umum">Ganti password</a>`}</div>`;
}
function route() {
  if (!LOADED) return;
  let h = location.hash || "#/";
  if (/^#\/(lokasi|server)(\/|$)/.test(h)) { h = h.replace(/^#\/(lokasi|server)/, "#/router"); history.replaceState(null, "", h); }
  if (/^#\/pengaturan\/zerotier/.test(h)) { h = "#/zerotier"; history.replaceState(null, "", h); }
  const parts = h.replace(/^#\/?/, "").split("/").filter(Boolean);
  document.querySelectorAll(".nav[data-go]").forEach((n) => {
    const g = n.dataset.go.replace(/^#\/?/, "");
    n.classList.toggle("on", (g === "" && parts.length === 0) || (g && parts[0] === g));
  });
  document.body.classList.remove("nav-open");
  document.querySelectorAll(".menu-list").forEach((m) => m.classList.add("hidden"));
  closeModal();
  const v = $("#view");
  topWarn(parts);
  let title = "Dashboard";
  if (parts[0] === "router" && (parts[1] === "terputus" || parts[1] === "menunggu")) { LIST.f = parts[1] === "terputus" ? "off" : "wait"; LIST.q = ""; history.replaceState(null, "", "#/router"); viewList(v); title = "Router"; }
  else if (parts[0] === "router" && parts[1]) {
    let tab = parts[2] || "ringkasan";
    const wantTest = tab === "tes";
    if (wantTest) { tab = "ringkasan"; history.replaceState(null, "", `#/router/${parts[1]}`); }
    viewDetail(v, parts[1], tab);
    const x = site(parts[1]); title = x ? x.name : "Router";
    if (wantTest && x) setTimeout(() => openTest(x.id), 50);
  }
  else if (parts[0] === "router") { viewList(v); title = "Router"; }
  else if (parts[0] === "panduan") { viewGuide(v); title = "Panduan"; }
  else if (parts[0] === "pengaturan") { viewSettings(v, parts[1] || "umum"); title = "Pengaturan"; }
  else if (parts[0] === "genieacs") { viewGenie(v); title = "GenieACS"; }
  else if (parts[0] === "zerotier" && !ztOn()) { location.hash = "#/addon"; return; }
  else if (parts[0] === "zerotier") { viewZerotier(v); title = "ZeroTier"; }
  else if (parts[0] === "addon") { viewAddons(v); title = "Add-on"; }
  else if (parts[0] === "log") { viewLog(v); title = "Log aktivitas"; }
  else { viewDashboard(v); }
  document.title = `${title} · ${BRAND}`;
  paintIcons(v);
  window.scrollTo(0, 0);
}
function crumb(items) {
  $("#crumb").innerHTML = items.map((x, i) => i < items.length - 1 ? `<a href="${x[1]}">${esc(x[0])}</a><span>/</span>` : `<b>${esc(x[0])}</b>`).join("");
}
window.addEventListener("hashchange", route);

/* ================= Dashboard ================= */
function issues() {
  const s = STATE.settings, list = [];
  if (s.defaultPassword) list.push({ t: "Password admin masih bawaan", d: "Password Admin123 mudah ditebak. Ganti di Pengaturan → Umum → Password admin.", go: "#/pengaturan" });
  if (!s.publicIp) list.push({ t: "Alamat VPS belum diisi", d: "Script MikroTik membutuhkan alamat VPS.", go: "#/pengaturan" });
  if (s.genieCidr !== null && !genieOk(s.genieCidr)) list.push({ t: "Patch IP virtual GenieACS belum aktif", d: "Summon ke ONT akan gagal.", go: "#/genieacs" });
  const off = STATE.sites.filter((x) => x.state === "down");
  if (off.length === 1) list.push({ t: `${off[0].name} terputus`, d: off[0].downSince ? `Sejak ${fmtT(off[0].downSince, true)} (${fmtDur(Date.now() - off[0].downSince)}). Klik untuk tes koneksi.` : "Klik untuk tes koneksi.", go: `#/router/${off[0].id}/tes` });
  else if (off.length > 1) {
    const names = off.map((x) => x.name);
    list.push({ t: `${off.length} router terputus`, d: names.slice(0, 4).join(", ") + (names.length > 4 ? ` dan ${names.length - 4} lainnya` : ""), go: "#/router/terputus" });
  }
  if (s.zt && s.zt.checkError) list.push({ t: "Jaringan ZeroTier bermasalah", d: s.zt.checkError, go: "#/zerotier" });
  for (const x of STATE.sites.filter((y) => y.ztStale && y.transport === "zt")) list.push({ t: `${x.name}: pasang ulang script ZeroTier`, d: "IP ZeroTier VPS berubah. Salin script terbaru ke MikroTik.", go: `#/router/${x.id}/script` });
  const tg = s.telegram || {};
  if (tg.active && tg.lastError) list.push({ t: "Notifikasi Telegram gagal terkirim", d: tg.lastError, go: "#/pengaturan/telegram" });
  const cf = s.cloudflare;
  if (cf && cf.https && cf.certExpiry && cf.certExpiry - Date.now() < 14 * 864e5) list.push({ t: "Sertifikat HTTPS hampir habis", d: `Berlaku sampai ${fmtT(cf.certExpiry, true)}. Perpanjangan otomatis mungkin gagal.`, go: "#/pengaturan/domain" });
  for (const x of STATE.sites) {
    if (x.inGenie === false) list.push({ t: `${x.name}: IP virtual di luar patch GenieACS`, d: `${x.virtualSubnet} tidak dikenali GenieACS, Summon akan gagal.`, go: `#/router/${x.id}` });
  }
  const pend = STATE.sites.filter((x) => x.state === "pending");
  for (const x of STATE.sites.filter((y) => y.transport === "zt" && !y.ztNode)) list.push({ k: "info", t: `${x.name}: router ZeroTier belum dipilih`, d: "Pasang script, lalu pilih router dari daftar yang bergabung.", go: `#/router/${x.id}` });
  if (pend.length === 1) list.push({ k: "info", t: `${pend[0].name} menunggu pemasangan`, d: "Script MikroTik belum dipasang atau belum pernah tersambung.", go: `#/router/${pend[0].id}/script` });
  else if (pend.length > 1) list.push({ k: "info", t: `${pend.length} router menunggu pemasangan`, d: pend.map((x) => x.name).slice(0, 4).join(", ") + (pend.length > 4 ? ` dan ${pend.length - 4} lainnya` : ""), go: "#/router/menunggu" });
  return list;
}
function viewDashboard(v) {
  crumb([["Dashboard"]]);
  const S = STATE.sites, inst = S.filter((x) => x.state !== "pending"), on = S.filter((x) => x.state === "up").length;
  const off = S.filter((x) => x.state === "down").length, pend = S.length - inst.length;
  const u7 = inst.map((x) => x.uptime && x.uptime.d7).filter((x) => x != null);
  const avg = u7.length ? u7.reduce((a, b) => a + b, 0) / u7.length : null;
  const iss = issues();
  v.innerHTML = `
    <div class="ph"><div><h1>Dashboard</h1><p>Ringkasan koneksi VPN dan uptime setiap router.</p></div>
      <div class="acts"><button class="btn pri" data-act="add">${ic("plus")}Tambah router</button></div></div>
    <div class="kpis">
      <div class="kpi"><span>Total router</span><b>${S.length}</b><small>${pend ? `${pend} menunggu pemasangan` : "MikroTik terdaftar"}</small></div>
      <div class="kpi"><span><i class="dot ok"></i>Tersambung</span><b>${on}</b><small>${inst.length ? Math.round((on / inst.length) * 100) : 0}% dari router terpasang</small></div>
      <div class="kpi"><span><i class="dot bad"></i>Terputus</span><b>${off}</b><small>${off ? "perlu dicek" : "tidak ada"}</small></div>
      <div class="kpi"><span>Rata-rata uptime</span><b class="${pctCls(avg)}" style="${avg != null && avg < 99 ? `color:var(--${avg >= 95 ? "warn" : "bad"})` : ""}">${pct(avg)}</b><small>7 hari terakhir</small></div>
    </div>
    <div class="grid-dash">
      <div class="card">
        <div class="ch"><h2>Uptime router</h2><span class="muted" style="font-size:12.5px">Klik baris untuk riwayat lengkap</span></div>
        ${S.length ? uptimeTable(S) : `<div class="empty"><h3>Belum ada router</h3><p>Tambahkan MikroTik pertama untuk mulai.</p><button class="btn pri" style="margin-top:12px" data-act="add">${ic("plus")}Tambah router</button></div>`}
      </div>
      <div class="stack">
        <div class="card">
          <div class="ch"><h2>Perlu perhatian</h2>${iss.length ? `<span class="muted">${iss.length}</span>` : ""}</div>
          ${iss.length ? `<ul class="rows">${iss.slice(0, 6).map((x) => `<li><a class="row ${x.k || "warn"}" href="${x.go}"><span class="ic">${ic(x.k === "info" ? "clock" : "alert")}</span><span class="grow"><span class="nm">${esc(x.t)}</span><span class="sb" style="display:block">${esc(x.d)}</span></span><span class="chev">${ic("chev")}</span></a></li>`).join("")}</ul>`
            : `<div class="empty"><div class="big">${ic("check")}</div><h3>Semua normal</h3><p>Semua router tersambung dan pengaturan lengkap.</p></div>`}
        </div>
        <div class="card">
          <div class="ch"><h2>VPS</h2><a href="#/pengaturan">Pengaturan</a></div>
          ${serverKv()}
        </div>
      </div>
    </div>`;
}
function uptimeTable(S) {
  const order = { down: 0, up: 1, pending: 2 };
  const rows = [...S].sort((a, b) => order[a.state] - order[b.state] || a.name.localeCompare(b.name, "id"));
  return `<table class="t"><thead><tr><th>Router</th><th class="hide-md">30 hari terakhir</th><th class="r">24 jam</th><th class="r">7 hari</th><th class="r hide-sm">30 hari</th></tr></thead><tbody>
    ${rows.map((x) => {
      const [c] = stOf(x);
      const sub = x.state === "down" ? `Terputus${x.downSince ? " · " + fmtDur(Date.now() - x.downSince) : ""}` : x.state === "pending" ? "Menunggu pemasangan" : x.incidents30 ? `${x.incidents30}× putus (30 hari)` : "Stabil";
      const name = `<td><div class="srv"><span class="dot ${c}"></span><span style="min-width:0"><b>${esc(x.name)}${ztTag(x)}</b><small${x.state === "down" ? ' style="color:var(--warn)"' : ""}>${esc(sub)}</small></span></div></td>`;
      if (!x.uptime) return `<tr class="click" data-go="#/router/${x.id}/script">${name}<td class="hide-md"><div class="mini">${"<i class=nodata></i>".repeat(30)}</div></td><td class="r muted">—</td><td class="r muted">—</td><td class="r muted hide-sm">—</td></tr>`;
      const U = x.uptime;
      return `<tr class="click" data-go="#/router/${x.id}/riwayat">${name}
        <td class="hide-md"><div class="mini">${(x.days || []).map((d) => `<i class="${d}"></i>`).join("")}</div></td>
        <td class="r pc ${pctCls(U.d1)}">${pct(U.d1)}</td><td class="r pc ${pctCls(U.d7)}">${pct(U.d7)}</td><td class="r pc hide-sm ${pctCls(U.d30)}">${pct(U.d30)}</td></tr>`;
    }).join("")}
  </tbody></table>`;
}
function serverKv() {
  const s = STATE.settings;
  const g = s.genieCidr === null ? "Tidak ada" : genieOk(s.genieCidr) ? "Aktif" : "Belum aktif";
  const tg = s.telegram || {};
  const tgs = !tg.tokenSet ? "Belum diatur" : !tg.enabled ? "Nonaktif" : tg.lastError ? "Gagal kirim" : "Aktif";
  const https = s.cloudflare && s.cloudflare.https ? "Aktif" : "Tidak";
  const genie = s.genieUrl
    ? `<div class="kv"><span>GenieACS</span><b><a class="ext" href="${esc(s.genieUrl)}" target="_blank" rel="noopener" title="Buka GenieACS di tab baru">${esc(s.genieUrl.replace(/^https?:\/\//, ""))}${ic("ext", "")}</a></b></div>`
    : `<div class="kv"><span>GenieACS</span><b><a href="#/genieacs">Atur alamat</a></b></div>`;
  const zt = s.zt ? `${s.zt.name || s.zt.nwid} · ${s.zt.vpsIp}` : "Tidak dipakai";
  return genie + [["Alamat VPS", s.publicIp || "—"], ["URL ACS ONT", s.acsUrl || "—"], ["Jaringan VPN", s.tunnelNet || "—"], ["ZeroTier", zt], ["Patch GenieACS", g], ["Notifikasi Telegram", tgs], ["HTTPS panel", https]]
    .map(([k, val]) => `<div class="kv"><span>${k}</span><b>${esc(val)}</b></div>`).join("");
}
function rowHtml(x) {
  const [c, t] = stOf(x);
  return `<li><a class="row" href="#/router/${x.id}">
    <span class="dot ${c}"></span>
    <span class="grow"><span class="nm">${esc(x.name)}</span>${ztTag(x)}${x.note ? `<span class="sb" style="display:block">${esc(x.note)}</span>` : ""}</span>
    <span class="meta">${esc(x.virtualSubnet)}</span>
    <span class="up ${pctCls(x.uptime7)}" title="${x.uptime7 == null ? "" : "Uptime 7 hari"}">${x.uptime7 == null ? "" : pct(x.uptime7)}</span>
    <span class="pill ${c}">${t}</span>
    <span class="chev">${ic("chev")}</span></a></li>`;
}

/* ================= Daftar router ================= */
let LIST = { q: "", f: "all" };
function viewList(v) {
  crumb([["Router"]]);
  v.innerHTML = `
    <div class="ph"><div><h1>Router</h1><p>Setiap router adalah satu MikroTik yang tersambung ke VPS lewat VPN.</p></div>
      <div class="acts"><button class="btn pri" data-act="add">${ic("plus")}Tambah router</button></div></div>
    <div class="card">
      <div class="toolbar">
        <div class="search">${ic("search", "")}<input id="q" type="text" placeholder="Cari nama, subnet, atau IP" value="${esc(LIST.q)}"></div>
        <div class="filters">
          <button class="chip ${LIST.f === "all" ? "on" : ""}" data-filter="all">Semua</button>
          <button class="chip ${LIST.f === "on" ? "on" : ""}" data-filter="on">Tersambung</button>
          <button class="chip ${LIST.f === "off" ? "on" : ""}" data-filter="off">Terputus</button>
          ${STATE.sites.some((x) => x.state === "pending") || LIST.f === "wait" ? `<button class="chip ${LIST.f === "wait" ? "on" : ""}" data-filter="wait">Menunggu</button>` : ""}
        </div>
      </div>
      <ul class="rows" id="listRows"></ul>
    </div>`;
  $("#q").addEventListener("input", (e) => { LIST.q = e.target.value; fillList(); });
  fillList();
}
function fillList() {
  const q = LIST.q.trim().toLowerCase();
  const rows = STATE.sites
    .filter((x) => LIST.f === "all" || x.state === { on: "up", off: "down", wait: "pending" }[LIST.f])
    .filter((x) => !q || [x.name, x.note, x.realSubnet, x.virtualSubnet, x.tunnelIp].join(" ").toLowerCase().includes(q))
    .sort((a, b) => a.name.localeCompare(b.name, "id"));
  const el = $("#listRows");
  if (!STATE.sites.length) el.innerHTML = `<li><div class="empty"><h3>Belum ada router</h3><p>Tambahkan MikroTik pertama untuk mulai.</p></div></li>`;
  else if (!rows.length) el.innerHTML = `<li><div class="empty"><p>Tidak ada router yang cocok.</p></div></li>`;
  else el.innerHTML = rows.map(rowHtml).join("");
}

/* ================= Detail router ================= */
const TABS = [["ringkasan", "Ringkasan", "bolt"], ["port", "Port Forwarding", "share"], ["script", "Script MikroTik", "code"], ["riwayat", "Riwayat", "pulse"]];
const tabsHtml = (list, cur, base) => `<nav class="tabs">${list.map(([k, t, i]) => `<a class="tab ${k === cur ? "on" : ""}" href="${base}/${k}">${ic(i, "")}${t}</a>`).join("")}</nav>`;
function viewDetail(v, id, tab) {
  const x = site(id);
  if (!x) { crumb([["Router", "#/router"], ["Tidak ditemukan"]]); v.innerHTML = `<div class="card"><div class="empty"><h3>Router tidak ditemukan</h3><p><a href="#/router">Kembali ke daftar router</a></p></div></div>`; return; }
  if (tab === "remote") { tab = "port"; history.replaceState(null, "", `#/router/${id}/port`); }
  if (!TABS.some(([k]) => k === tab)) tab = "ringkasan";
  crumb([["Router", "#/router"], [x.name]]);
  v.innerHTML = `
    <div class="dh">
      <div><h1>${esc(x.name)} <span class="pill ${stOf(x)[0]}">${stOf(x)[1]}</span> <span class="tag ${x.transport === "zt" ? "" : "gray"}">${x.transport === "zt" ? "ZeroTier" : "L2TP"}</span></h1>
        ${x.note ? `<p>${esc(x.note)}</p>` : ""}</div>
      <div class="acts" style="display:flex;gap:8px">
        <button class="btn" data-act="test" data-id="${x.id}">${ic("play")}Tes koneksi</button>
        <div class="menu"><button class="btn icon" data-act="menu" aria-label="Lainnya">${ic("dots")}</button>
          <div class="menu-list hidden" id="menuList">
            <button data-act="edit" data-id="${x.id}">${ic("edit")}Ubah router</button>
            ${x.transport === "zt" ? `<button data-act="ztpick" data-id="${x.id}">${ic("hub")}Pilih router ZeroTier</button>` : `<button data-act="resetpw" data-id="${x.id}">${ic("key")}Buat password VPN baru</button>`}
            <hr><button class="d" data-act="del" data-id="${x.id}">${ic("trash")}Hapus router</button>
          </div></div>
      </div>
    </div>
    ${tabsHtml(TABS, tab, `#/router/${x.id}`)}
    <div id="tabBody"></div>`;
  const b = $("#tabBody");
  if (tab === "port") tabRemote(b, x);
  else if (tab === "script") tabScript(b, x);
  else if (tab === "riwayat") tabHistory(b, x);
  else tabSummary(b, x);
}
function tabSummary(b, x) {
  b.innerHTML = `
    ${x.inGenie === false ? `<div class="note warn">${ic("alert")}<div><b>IP virtual di luar rentang patch GenieACS</b>Panel belum berhasil memperbarui setting GenieACS untuk ${esc(x.virtualSubnet)}, jadi Summon ke ONT di router ini akan gagal. Buka menu <a href="#/genieacs">GenieACS</a> untuk melihat statusnya.</div></div>` : ""}
    ${x.state === "pending" && !(x.transport === "zt" && !x.ztNode) ? `<div class="note info">${ic("clock")}<div><b>Menunggu pemasangan</b>Router ini belum pernah tersambung. Pasang script lewat tab <a href="#/router/${x.id}/script">Script MikroTik</a>. Riwayat dan notifikasi Telegram mulai berjalan setelah MikroTik tersambung pertama kali.</div></div>` : ""}
    ${x.state === "down" ? `<div class="note warn">${ic("alert")}<div><b>Terputus${x.downSince ? ` sejak ${esc(fmtT(x.downSince, true))} (${fmtDur(Date.now() - x.downSince)})` : ""}</b>Jalankan <a href="#" data-act="test" data-id="${x.id}">tes koneksi</a> untuk melihat penyebabnya.</div></div>` : ""}
    <div class="card">
      <div class="ch"><h2>Jaringan</h2></div>
      <dl class="dl" style="margin:0">
        <div><dt>Subnet ONT (asli)</dt><dd>${esc(x.realSubnet)}</dd></div>
        <div><dt>IP virtual di GenieACS</dt><dd>${esc(x.virtualSubnet)}</dd></div>
        <div><dt>URL ACS untuk ONT</dt><dd>${esc(x.acsUrl)} ${copyBtn(x.acsUrl, "URL ACS tersalin")}</dd></div>
        <div><dt>${x.transport === "zt" ? "IP ZeroTier MikroTik" : "IP VPN MikroTik"}</dt><dd>${x.transport === "zt" ? (x.ztIp ? esc(x.ztIp) : '<span class="muted">Belum dipilih</span>') : esc(x.tunnelIp)}</dd></div>
      </dl>
    </div>
    ${x.transport === "zt" ? ztCard(x) : `<div class="card">
      <div class="ch"><h2>Akun VPN</h2></div>
      <dl class="dl" style="margin:0">
        <div><dt>Alamat VPS (connect-to)</dt><dd>${esc(STATE.settings.publicIp || "—")}</dd></div>
        <div><dt>Username</dt><dd>${esc(x.username)} ${copyBtn(x.username)}</dd></div>
        <div><dt>Password</dt><dd><span id="pwv">••••••••••••</span><button class="copy" data-act="showpw" title="Lihat">${ic("eye", "")}</button>${copyBtn(x.password, "Password tersalin")}</dd></div>
        <div><dt>IPsec</dt><dd>${STATE.settings.useIpsec ? "Aktif" : "Tidak dipakai"}</dd></div>
      </dl>
    </div>`}`;
}
function ztStaleNote(x, style) {
  return x.ztStale ? `<div class="note warn"${style ? ` style="${style}"` : ""}>${ic("alert")}<div><b>Pasang ulang script ZeroTier</b>Rentang atau IP ZeroTier VPS berubah (sekarang ${esc((STATE.settings.zt || {}).vpsIp || "-")}). Salin script terbaru dari tab <a href="#/router/${x.id}/script">Script MikroTik</a> ke MikroTik, lalu klik <a href="#" data-act="ztdone" data-id="${x.id}">Sudah dipasang</a>.</div></div>` : "";
}
function ztCard(x) {
  const z = STATE.settings.zt;
  return `${ztStaleNote(x, "margin-top:16px")}${!x.ztNode ? `<div class="note info">${ic("hub")}<div><b>Menunggu MikroTik bergabung</b>Pasang script dari tab <a href="#/router/${x.id}/script">Script MikroTik</a>. Script melaporkan Node ID router ke panel, sehingga router terpilih otomatis dalam beberapa detik. Jika tidak, klik <a href="#" data-act="ztpick" data-id="${x.id}">Pilih router yang bergabung</a>.</div></div>` : ""}
    <div class="card">
      <div class="ch"><h2>ZeroTier</h2><button class="btn sm" data-act="ztpick" data-id="${x.id}">${ic("hub")}${x.ztNode ? "Ganti router" : "Pilih router yang bergabung"}</button></div>
      <dl class="dl" style="margin:0">
        <div><dt>Jaringan</dt><dd>${z ? `${esc(z.name || "—")} · ${esc(z.nwid)} ${copyBtn(z.nwid, "Network ID tersalin")}` : '<span class="muted">Belum diatur</span>'}</dd></div>
        <div><dt>Node ID router</dt><dd>${x.ztNode ? esc(x.ztNode) : '<span class="muted">—</span>'}</dd></div>
        <div><dt>IP ZeroTier VPS</dt><dd>${z ? esc(z.vpsIp) : "—"}</dd></div>
        <div><dt>Rentang jaringan</dt><dd>${z ? esc(z.subnet) : "—"}</dd></div>
      </dl>
    </div>`;
}
// Pilih anggota ZeroTier yang bergabung untuk router ini
async function openZtPick(id) {
  const x = site(id); if (!x) return;
  modal(`Pilih router ZeroTier · ${esc(x.name)}`, `<p class="muted" style="margin-bottom:6px">Perangkat yang sudah bergabung ke jaringan tetapi belum dipakai router mana pun. Pilih MikroTik <b>${esc(x.name)}</b>.</p>
    <div id="zpList"><div class="empty"><p>Memuat…</p></div></div>
    <label for="zpNode">Atau isi Node ID manual</label>
    <div style="display:flex;gap:8px"><input id="zpNode" type="text" maxlength="10" placeholder="contoh: 1a2b3c4d5e"><button class="btn" id="zpManual">Pakai</button></div>
    <div class="help">Node ID ada di Winbox → ZeroTier → kolom Identity (10 karakter pertama).</div>
    <div class="err" id="zpErr"></div>`,
    `<button class="btn" id="zpRefresh">${ic("refresh")}Muat ulang</button><button class="btn" data-act="closemodal">Tutup</button>`);
  const bind = async (node, btn) => {
    $("#zpErr").textContent = ""; busyBtn(btn, true);
    try {
      const r = await api(`/api/sites/${id}/zt-bind`, { method: "POST", body: { node } });
      await load(); route();
      doneDialog("Router ZeroTier disetujui", `<p>Node <b class="mono">${esc(node)}</b> mendapat IP <b class="mono">${esc(r.ip)}</b>.</p><p>Status tersambung muncul dalam 1 menit. Setelah itu jalankan tes koneksi.</p>`, "ok", false);
    } catch (e) { if ($("#zpErr")) { $("#zpErr").textContent = e.message; busyBtn(btn, false); } }
  };
  const fill = async () => {
    const el = $("#zpList"); if (!el) return;
    el.innerHTML = `<div class="empty"><p>Memuat…</p></div>`;
    let r;
    try { r = await api(`/api/sites/${id}/zt-pending`); } catch (e) { el.innerHTML = `<div class="err">${esc(e.message)}</div>`; return; }
    if (!$("#zpList")) return;
    el.innerHTML = r.list.length ? r.list.map((m) => `<div class="pick"><span class="dot ${m.seen ? "ok" : "wait"}"></span><span class="grow"><b>${esc(m.name || m.node)}</b>${m.name ? ` <span class="muted mono" style="font-size:12px">${esc(m.node)}</span>` : ""}${m.ips && m.ips.length ? ` <span class="muted mono" style="font-size:12px">· ${esc(m.ips[0])}</span>` : ""}
        <small>${m.seen ? `Terlihat online${m.physical ? " dari " + esc(m.physical) : ""}${m.latency >= 0 && m.latency != null ? ` · ${m.latency} ms` : ""}` : "Belum terlihat online"}${m.authorized ? " · sudah disetujui (mungkin perangkat lain)" : " · menunggu persetujuan"}</small></span>
        <button class="btn sm pri" data-node="${esc(m.node)}">Pilih</button></div>`).join("")
      : `<div class="empty" style="padding:22px 10px"><p>Belum ada perangkat yang bergabung.<br>Pasang script di MikroTik, tunggu sekitar 30 detik, lalu klik Muat ulang.</p></div>`;
    el.querySelectorAll("button[data-node]").forEach((btn) => (btn.onclick = () => bind(btn.dataset.node, btn)));
  };
  $("#zpRefresh").onclick = fill;
  $("#zpManual").onclick = () => { const v = $("#zpNode").value.trim().toLowerCase(); if (!/^[0-9a-f]{10}$/.test(v)) { $("#zpErr").textContent = "Node ID harus 10 karakter (0-9, a-f)."; return; } bind(v, $("#zpManual")); };
  fill();
}
const NON_WEB_PORTS = [21, 22, 23, 8291, 8728, 8729];
function fwdLink(f) {
  const web = f.service === "webfig" || f.service === "ontweb" || (f.service === "custom" && !NON_WEB_PORTS.includes(f.targetPort) && f.proto !== "udp");
  if (!web) return null;
  return ([443, 8443].includes(f.targetPort) ? "https://" : "http://") + f.remote;
}
function tabRemote(b, x) {
  b.innerHTML = `
    <div class="card">
      <div class="ch"><h2>Port forwarding</h2><button class="btn sm pri" data-act="addfwd">${ic("plus")}Tambah</button></div>
      ${x.forwards.length ? `<table class="t"><thead><tr><th>Layanan</th><th>Alamat</th><th class="hide-sm">Tujuan</th><th></th></tr></thead><tbody>
        ${x.forwards.map((f) => {
          const url = fwdLink(f);
          const addr = url
            ? `<a class="ext" href="${esc(url)}" target="_blank" rel="noopener" title="Buka di tab baru">${esc(f.remote)}${ic("ext", "")}</a> ${copyBtn(f.remote, "Alamat tersalin (tanpa http://)")}`
            : `<span class="mono">${esc(f.remote)}</span> ${copyBtn(f.remote, "Alamat tersalin")}`;
          return `<tr><td><b style="font-weight:550">${esc(f.label)}</b></td><td>${addr}</td>
          <td class="hide-sm muted mono">${f.target === "router" ? "MikroTik" : esc(f.lanIp)}:${f.targetPort}</td>
          <td class="r"><button class="btn sm ghost del-ic" data-act="delfwd" data-fid="${f.id}" title="Hapus" aria-label="Hapus">${ic("trash")}</button></td></tr>`;
        }).join("")}
      </tbody></table>`
      : `<div class="empty"><h3>Belum ada port forwarding</h3><p>Tambahkan Winbox atau web untuk me-remote router ini lewat ${esc(STATE.settings.publicIp || "VPS")}.</p></div>`}
    </div>
    <p class="help" style="margin-top:12px">Alamat layanan web bisa diklik untuk langsung membuka halamannya. Untuk Winbox, isi <b>Connect To</b> dengan alamat lengkap dengan port. Port ini terbuka ke internet, jadi pastikan password perangkat kuat.</p>`;
}
function fwdForm(x) {
  const P = STATE.settings.presets || {};
  modal("Tambah port forwarding", `
    <label for="wSvc">Layanan</label>
    <select id="wSvc">${Object.entries(P).map(([k, p]) => `<option value="${k}">${esc(p.label)}${p.port ? ` (port ${p.port})` : ""}</option>`).join("")}</select>
    <label>Tujuan</label>
    <div class="seg"><label><input type="radio" name="wTgt" value="router" checked>MikroTik ini</label><label><input type="radio" name="wTgt" value="lan">Perangkat di jaringan ONT</label></div>
    <div id="wLanBox" class="hidden"><label for="wLan">IP asli perangkat</label><input id="wLan" type="text" placeholder="contoh: ${esc(x.realGateway.replace(/\.1$/, ".25"))}"><div class="help">Di dalam ${esc(x.realSubnet)}. Panel menerjemahkannya ke IP virtual.</div></div>
    <div id="wLabelBox" class="hidden"><label for="wLabel">Nama layanan</label><input id="wLabel" type="text" maxlength="30" placeholder="contoh: Web OLT"></div>
    <div class="f2"><div><label for="wPort">Port tujuan</label><input id="wPort" type="text" inputmode="numeric"></div>
      <div><label for="wPub">Port publik</label><input id="wPub" type="text" inputmode="numeric" placeholder="Otomatis"></div></div>
    <input type="hidden" id="wProto" value="tcp">
    <div class="err" id="wErr"></div>`,
    `<button class="btn" data-act="closemodal">Batal</button><button class="btn pri" id="wSave">Simpan</button>`);
  const sync = () => {
    const p = P[$("#wSvc").value] || {};
    $("#wPort").value = p.port || ""; $("#wProto").value = p.proto || "tcp";
    $("#wLabelBox").classList.toggle("hidden", $("#wSvc").value !== "custom");
    if ($("#wSvc").value === "ontweb") document.querySelector("input[name=wTgt][value=lan]").checked = true;
    syncT();
  };
  const syncT = () => $("#wLanBox").classList.toggle("hidden", document.querySelector("input[name=wTgt]:checked").value !== "lan");
  $("#wSvc").onchange = sync; document.querySelectorAll("input[name=wTgt]").forEach((r) => (r.onchange = syncT)); sync();
  $("#wSave").onclick = async () => {
    $("#wErr").textContent = ""; busyBtn($("#wSave"), true);
    try {
      await api(`/api/sites/${x.id}/forwards`, { method: "POST", body: { service: $("#wSvc").value, proto: $("#wProto").value, target: document.querySelector("input[name=wTgt]:checked").value, lanIp: $("#wLan").value, targetPort: $("#wPort").value, publicPort: $("#wPub").value, label: $("#wLabel").value } });
      await load(); route();
      const nx = site(x.id), f = nx.forwards[nx.forwards.length - 1];
      doneDialog("Port forwarding ditambahkan", f ? `Alamat: <b class="mono">${esc(f.remote)}</b>` : "", "ok", false);
    } catch (e) { $("#wErr").textContent = e.message; busyBtn($("#wSave"), false); }
  };
}
function tabScript(b, x) {
  b.innerHTML = `
    ${x.transport === "zt" ? ztStaleNote(x) : ""}
    ${x.transport === "zt" ? `<div class="note info">${ic("hub")}<div><b>Jalur ZeroTier</b>Butuh RouterOS v7 dengan paket <code>zerotier</code> (router ARM/ARM64). Script otomatis melaporkan Node ID ke panel, jadi router langsung terpilih. Jika gagal (misalnya MikroTik tidak bisa menjangkau panel), pilih manual lewat <a href="#" data-act="ztpick" data-id="${x.id}">Pilih router yang bergabung</a>.</div></div>` : ""}
    ${x.state !== "pending" ? "" : `<ol class="howto">
      <li><b><i>1</i>Salin script</b>Klik tombol Salin di kotak script.</li>
      <li><b><i>2</i>Tempel di MikroTik</b>Winbox → New Terminal → klik kanan → Paste → Enter.</li>
      <li><b><i>3</i>Tes koneksi</b>Klik <a href="#" data-act="test" data-id="${x.id}">Tes koneksi</a> untuk memastikan semuanya jalan.</li></ol>`}
    <div class="card"><div class="ch"><h2>Script MikroTik</h2>
        <div class="sw" role="tablist"><button type="button" class="on" data-sw="pasang" role="tab">${ic("play")}Pasang</button><button type="button" data-sw="hapus" role="tab">${ic("trash")}Hapus</button></div></div>
      <div class="cb">
        <div data-pane="pasang">
          <p class="help" style="margin:0 0 10px">Memasang koneksi ke VPS, IP virtual (NETMAP), dan izin firewall. Aman dijalankan ulang: pengaturan lama dengan nama panel yang sama dihapus dulu.</p>
          <div class="codebox"><pre class="code">${esc(x.script)}</pre><button class="btn sm" data-copy="${esc(x.script)}" data-msg="Script tersalin. Tempel di Winbox → New Terminal">${ic("copy")}Salin</button></div>
        </div>
        <div data-pane="hapus" class="hidden">
          <div class="note warn" style="margin:0 0 10px">${ic("alert")}<div><b>Menghapus semua pengaturan panel dari MikroTik</b>Koneksi ke VPS, IP virtual, dan aturan firewall bertanda nama panel akan dihapus. Router lain dan pengaturan MikroTik Anda sendiri tidak tersentuh.</div></div>
          <div class="codebox"><pre class="code">${esc(x.removeScript)}</pre><button class="btn sm" data-copy="${esc(x.removeScript)}" data-msg="Script hapus tersalin">${ic("copy")}Salin</button></div>
        </div>
      </div></div>`;
  b.querySelectorAll(".sw [data-sw]").forEach((btn) => (btn.onclick = () => {
    b.querySelectorAll(".sw [data-sw]").forEach((y) => { const on = y === btn; y.classList.toggle("on", on); y.classList.toggle("danger", on && y.dataset.sw === "hapus"); });
    b.querySelectorAll("[data-pane]").forEach((pn) => pn.classList.toggle("hidden", pn.dataset.pane !== btn.dataset.sw));
  }));
}

/* ---------- Riwayat koneksi ---------- */
function tabHistory(b, x) {
  b.innerHTML = `<div class="card"><div class="empty"><p>Memuat riwayat…</p></div></div>`;
  api(`/api/sites/${x.id}/history`).then((h) => {
    if (!$("#tabBody") || !location.hash.includes(x.id + "/riwayat")) return;
    if (h.pending) {
      b.innerHTML = `<div class="card"><div class="empty"><div class="big" style="background:var(--subtle);color:var(--muted)">${ic("clock")}</div><h3>Belum ada riwayat</h3><p>Riwayat mulai dicatat setelah MikroTik tersambung pertama kali.<br><a href="#/router/${x.id}/script">Pasang script MikroTik</a></p></div></div>`;
      return;
    }
    const U = h.uptime, days = h.days;
    const tip = (d) => d.status === "nodata" ? `${d.label}: belum terpasang` : d.down ? `${d.label}: putus ${fmtDur(d.down)} (${d.count}×) · uptime ${pct(d.pct)}` : `${d.label}: normal, tidak ada putus`;
    const total = h.events.length, open = h.events.find((e) => e.open);
    b.innerHTML = `
      <div class="card"><div class="stats">
        ${[["24 jam", U.d1], ["7 hari", U.d7], ["30 hari", U.d30]].map(([k, val]) => `<div class="stat"><span>Uptime ${k}</span><b class="${pctCls(val)}">${pct(val)}</b></div>`).join("")}
      </div></div>
      <div class="card"><div class="ch"><h2>30 hari terakhir</h2><span class="muted" style="font-size:12.5px">1 batang = 1 hari</span></div><div class="cb">
        <div class="bars" id="bars">${days.map((d, i) => `<i class="${d.status}" data-i="${i}" title="${esc(tip(d))}"></i>`).join("")}</div>
        <div class="bar-axis"><span>${esc(days[0].label)}</span><span>Hari ini</span></div>
        <div class="bar-tip" id="barTip"></div>
        <div class="legend"><span><i style="background:var(--ok)"></i>Normal</span><span><i style="background:var(--warn)"></i>Putus &lt; 30 menit</span><span><i style="background:var(--bad)"></i>Putus ≥ 30 menit</span><span><i style="background:var(--line)"></i>Belum terpasang</span></div>
      </div></div>
      <div class="card"><div class="ch"><h2>Kejadian putus</h2><span class="muted" style="font-size:12.5px">${total ? `${total} kejadian · 90 hari` : ""}</span></div>
        ${total ? `<table class="t"><thead><tr><th>Mulai putus</th><th>Tersambung lagi</th><th class="r">Lama</th></tr></thead><tbody>
          ${h.events.slice(0, 50).map((e) => `<tr><td>${esc(fmtT(e.s, true))}</td><td>${e.open ? `<span class="pill bad">Masih terputus</span>` : esc(fmtT(e.e, true))}</td><td class="r mono">${fmtDur(e.dur)}</td></tr>`).join("")}
          </tbody></table>` : `<div class="empty"><div class="big">${ic("check")}</div><h3>Tidak ada kejadian putus</h3><p>VPN router ini stabil sejak tercatat.</p></div>`}
      </div>
      <p class="help" style="margin-top:12px">Dicatat sejak ${esc(fmtT(h.installedAt ? Date.parse(h.installedAt) : 0, true))} · diperiksa tiap 30 detik · waktu dalam ${esc(h.tz)}${open ? "" : ""}.</p>`;
    const bars = $("#bars");
    if (bars) bars.addEventListener("mouseover", (e) => { const i = e.target.dataset && e.target.dataset.i; if (i != null) $("#barTip").textContent = tip(days[+i]); });
  }).catch((e) => { b.innerHTML = `<div class="card"><div class="empty"><p>${esc(e.message)}</p></div></div>`; });
}

/* ---------- Add-on ---------- */
function viewAddons(v) {
  crumb([["Add-on"]]);
  v.innerHTML = `
    <div class="ph"><div><h1>Add-on</h1><p>Fitur tambahan yang bisa dipasang sesuai kebutuhan. Yang belum dipasang tidak muncul di menu.</p></div></div>
    <div id="adBody"><div class="card"><div class="empty"><p>Memuat add-on…</p></div></div></div>`;
  fillAddons();
}
// Periksa apakah add-on terpasang dan berjalan dengan benar
async function openAddonCheck(a) {
  modal(`Periksa ${esc(a.name)}`, `<div class="jtop"><div class="jprog run"><i style="width:100%"></i></div><div class="jlive"><span class="dot"></span><span>Memeriksa ${esc(a.name)}…</span></div></div><div id="ckBody"></div>`,
    `<button class="btn" id="ckAgain" type="button">${ic("refresh")}Periksa lagi</button><button class="btn pri" data-act="closemodal">Tutup</button>`, { size: "lg", flush: true });
  const runCheck = async () => {
    const top = $(".modal .jtop"); if (top) top.style.display = "";
    $("#ckBody").innerHTML = "";
    let r;
    try { r = await api(`/api/addons/${a.id}/check`); }
    catch (e) { if (top) top.style.display = "none"; $("#ckBody").innerHTML = `<div style="padding:16px 22px"><div class="note bad">${ic("alert")}<div><b>Gagal memeriksa</b>${esc(e.message)}</div></div></div>`; return; }
    if (!$("#ckBody")) return;
    if (top) top.style.display = "none";
    const sum = r.bad ? `<div class="tst-sum fail">${ic("alert")}${r.bad} pemeriksaan gagal. Lihat saran perbaikan di bawah.</div>`
      : r.warn ? `<div class="tst-sum ok">${ic("check")}${esc(r.name)} terpasang dan berjalan, dengan ${r.warn} catatan.</div>`
      : `<div class="tst-sum ok">${ic("check")}${esc(r.name)} terpasang dan berjalan dengan benar.</div>`;
    $("#ckBody").innerHTML = `<div style="padding:14px 22px 0">${sum}</div><ul class="chk">${r.checks.map((x) => {
      const c = x.ok === true ? "ok" : x.ok === false ? "bad" : "warn";
      return `<li class="${c}"><span class="ci">${ic(c === "ok" ? "check" : c === "bad" ? "x" : "alert")}</span><div style="min-width:0"><b>${esc(x.label)}</b>${x.detail ? `<div class="cd">${esc(x.detail)}</div>` : ""}${x.ok !== true && x.hint ? `<div class="ch2 muted">Saran: ${/^(systemctl|journalctl|apt-get|chown|zerotier-cli)/.test(x.hint) ? `<code>${esc(x.hint)}</code>` : esc(x.hint)}</div>` : ""}</div></li>`;
    }).join("")}</ul>`;
    paintIcons($("#ckBody"));
  };
  $("#ckAgain").onclick = runCheck;
  runCheck();
}
async function fillAddons() {
  const b = $("#adBody"); if (!b) return;
  let r;
  try { r = await api("/api/addons"); } catch (e) { b.innerHTML = `<div class="note bad">${ic("alert")}<div><b>Gagal memuat add-on</b>${esc(e.message)}</div></div>`; return; }
  if (!$("#adBody")) return;
  const base = (STATE.settings.panelUrl || "").replace(/\/$/, "");
  const card = (a) => {
    const kind = a.kind === "sistem" ? `<span class="tag gray">Sistem</span>` : `<span class="tag">Aplikasi</span>`;
    const st = a.installed ? (a.kind === "aplikasi" && a.running === false ? `<span class="pill bad">Terpasang · berhenti</span>` : `<span class="pill ok">Terpasang</span>`) : `<span class="pill wait">Belum dipasang</span>`;
    const meta = [];
    if (a.kind === "aplikasi") {
      meta.push(`<span>Alamat: <b class="mono">${a.installed ? `<a href="${esc(a.path)}/" target="_blank" rel="noopener">${esc((base || "") + a.path)}/</a>` : esc(a.path + "/")}</b></span>`);
      if (a.version) meta.push(`<span>Versi: <b class="mono">${esc(a.version)}</b></span>`);
      meta.push(`<span>Sumber: <a href="${esc(a.repo)}" target="_blank" rel="noopener">${esc(a.repo.replace(/^https:\/\/github.com\//, "github.com/"))}</a></span>`);
    } else {
      meta.push(`<span>Router memakai ZeroTier: <b>${a.routers || 0}</b></span>`);
      if (a.ztnet) meta.push(`<span>ZTNET lama terdeteksi · <a href="#/zerotier">pindahkan dari menu ZeroTier</a></span>`);
      if (a.note) meta.push(`<span>${esc(a.note)}</span>`);
    }
    const btns = [];
    if (!a.installed) btns.push(`<button class="btn pri" data-ad="install" data-id="${a.id}">${ic("down")}${a.kind === "sistem" && a.ztnet ? "Aktifkan" : "Install"}</button>`);
    else {
      if (a.kind === "aplikasi") btns.push(`<a class="btn pri" href="${esc(a.path)}/" target="_blank" rel="noopener">${ic("ext")}Buka</a>`, `<button class="btn" data-ad="update" data-id="${a.id}">${ic("refresh")}Perbarui</button>`, `<button class="btn" data-ad="path" data-id="${a.id}">${ic("edit")}Alamat</button>`);
      else btns.push(`<a class="btn pri" href="#/zerotier">${ic("hub")}Buka menu ZeroTier</a>`);
      btns.push(`<button class="btn" data-ad="check" data-id="${a.id}">${ic("check")}Periksa</button>`);
      btns.push(`<span style="flex:1"></span><button class="btn ghost danger" data-ad="remove" data-id="${a.id}">Lepas</button>`);
    }
    return `<div class="card addon"><div class="ah"><span class="ai">${ic(a.icon || "puzzle")}</span><div style="min-width:0"><h3>${esc(a.name)} ${kind}</h3><p>${esc(a.desc)}</p></div></div>
      <div class="am"><span>${st}</span>${meta.join("")}</div><div class="af">${btns.join("")}</div></div>`;
  };
  b.innerHTML = `${r.job ? `<div class="note info">${ic("clock")}<div><b>${esc(r.job.title.replace(/ (dipasang|diperbarui|dilepas)$/, ""))} sedang diproses</b><a href="#" id="adJob">Lihat progres</a></div></div>` : ""}
    <div class="addons">${r.list.map(card).join("")}</div>
    <p class="help" style="margin-top:14px">Add-on aplikasi berjalan di dalam VPS dan dibuka lewat alamat panel (tanpa port tambahan). Data add-on tidak ikut terhapus saat dilepas, kecuali Anda memilihnya.</p>`;
  paintIcons(b);
  const j = $("#adJob"); if (j) j.onclick = (e) => { e.preventDefault(); openJob(); };
  b.querySelectorAll("[data-ad]").forEach((btn) => (btn.onclick = () => {
    const a = r.list.find((x) => x.id === btn.dataset.id), act = btn.dataset.ad;
    if (act === "path") return openAddonPath(a);
    if (act === "check") return openAddonCheck(a);
    if (act === "remove") {
      return confirmDialog({
        title: `Lepas ${esc(a.name)}?`, danger: true, ok: "Lepas", wide: true,
        text: a.kind === "sistem"
          ? `<p>Menu ZeroTier disembunyikan dan VPS keluar dari jaringan ZeroTier panel. Router yang masih memakai ZeroTier harus dipindah ke L2TP atau dihapus dulu.</p><label class="check" style="margin-top:10px"><input type="checkbox" id="adPurge"> Hapus juga ZeroTier dari VPS (<b>semua jaringan</b> di controller ikut terhapus)</label>`
          : `<p>Layanan ${esc(a.name)} dihentikan dan menunya hilang dari panel. Data tetap disimpan dan dipakai lagi jika dipasang ulang.</p><label class="check" style="margin-top:10px"><input type="checkbox" id="adPurge"> Hapus juga aplikasi dan <b>semua datanya</b></label>`,
        onOk: async () => { const purge = !!($("#adPurge") && $("#adPurge").checked); await api(`/api/addons/${a.id}/remove`, { method: "POST", body: { purge } }); openJob(); },
      });
    }
    const go = async () => { busyBtn(btn, true); try { await api(`/api/addons/${a.id}/${act}`, { method: "POST", body: {} }); openJob(); } catch (e) { busyBtn(btn, false); toast(e.message); } };
    go();
  }));
}
function openAddonPath(a) {
  modal(`Alamat ${esc(a.name)}`, `
    <label for="adPath">Alamat di panel</label>
    <div style="display:flex;align-items:center;gap:6px"><span class="mono muted">${esc((STATE.settings.panelUrl || "").replace(/\/$/, ""))}</span><input id="adPath" type="text" class="mono" value="${esc(a.path)}" style="flex:1"></div>
    <div class="help">Contoh: <code>/acs</code>, <code>/panelku</code>, <code>/billing</code>. Huruf kecil, angka, atau minus.</div>
    <div class="err" id="adPathErr"></div>`,
    `<button class="btn" data-act="closemodal">Batal</button><button class="btn pri" id="adPathSave">Simpan</button>`);
  $("#adPathSave").onclick = async () => {
    $("#adPathErr").textContent = ""; busyBtn($("#adPathSave"), true);
    try { await api(`/api/addons/${a.id}`, { method: "PUT", body: { path: $("#adPath").value } }); await load(); closeModal(); route(); toast("Alamat disimpan"); }
    catch (e) { $("#adPathErr").textContent = e.message; busyBtn($("#adPathSave"), false); }
  };
}
// Modal progres proses (install, update, lepas, port 80/443)
let JOBPOLL = null;
function openJob(after) {
  modal(`<span id="jTitle">Memproses…</span>`, `
    <div class="jtop"><div class="jp"><b id="jPct">0%</b><span id="jDetail">Memulai…</span></div><div class="jprog run" id="jBar"><i></i></div><div class="jlive" id="jLive"><span class="dot"></span><span id="jLiveTx">Menghubungi panel…</span></div></div>
    <ol class="steps" id="jSteps"></ol>
    <div id="jSum"></div>
    <details class="jlog more"><summary>Log proses</summary><pre class="code" id="jLog"></pre></details>`,
    `<button class="btn" data-act="closemodal" id="jClose">Tutup</button>`, { size: "lg", flush: true });
  clearInterval(JOBPOLL);
  let fails = 0;
  const dur = (n) => { n = Math.max(0, n | 0); const m = Math.floor(n / 60), x = n % 60; return m ? `${m} mnt ${String(x).padStart(2, "0")} dtk` : `${x} dtk`; };
  const tick = async () => {
    if (!$("#jSteps")) { clearInterval(JOBPOLL); return; }
    let r;
    try {
      const res = await fetch("/api/addons/job", { credentials: "same-origin", cache: "no-store" });
      if (res.status === 401) { clearInterval(JOBPOLL); showLogin(); return; }
      r = (await res.json()).job; fails = 0;
    } catch (e) {
      // panel sedang restart atau koneksi terputus: tetap menunggu, jangan dianggap gagal
      fails++;
      const lv = $("#jLive"); if (lv) { lv.className = "jlive lost"; $("#jLiveTx").textContent = `Koneksi ke panel terputus, mencoba lagi… (${fails})`; }
      return;
    }
    if (!r || !$("#jSteps")) return;
    const lv = $("#jLive");
    if (lv) {
      lv.className = "jlive" + (r.done ? (r.ok ? " ok" : " bad") : "");
      $("#jLiveTx").innerHTML = r.done
        ? `${r.ok ? "Selesai" : r.interrupted ? "Terputus" : "Berhenti"} dalam ${dur(r.elapsed)}`
        : `Sedang bekerja <span class="sep">·</span> berjalan ${dur(r.elapsed)}${r.quiet >= 20 ? ` <span class="sep">·</span> ${r.quiet >= 900 ? `<b style="color:var(--warn)">tidak ada kemajuan ${dur(r.quiet)}, mungkin tertahan — lihat log</b>` : r.quiet >= 90 ? `tidak ada keluaran baru ${dur(r.quiet)} (langkah ini bisa lama)` : `menunggu keluaran ${dur(r.quiet)}`}` : ""}`;
    }
    $("#jTitle").textContent = r.done ? r.title : r.title.replace(/ (dipasang|diperbarui|dilepas|diaktifkan|dimatikan)$/, "") + " sedang diproses";
    $("#jPct").textContent = r.pct + "%";
    $("#jBar").className = "jprog" + (r.done ? (r.ok ? " ok" : " bad") : " run");
    $("#jBar i").style.width = r.pct + "%";
    const cur = r.steps[r.cur];
    $("#jDetail").textContent = r.done ? (r.ok ? "Selesai" : "Gagal") : (r.detail || (cur ? cur.label : "")) + "…";
    $("#jSteps").innerHTML = r.steps.map((x) => {
      const cls = x.state === "run" ? "run" : x.state === "ok" ? "ok" : x.state === "bad" ? "fail" : x.state === "skip" ? "skip" : "wait";
      const icn = x.state === "ok" ? ic("check") : x.state === "bad" ? ic("x") : x.state === "skip" ? ic("minus") : "";
      return `<li class="step ${cls}"><span class="sic">${icn}</span><span class="stx"><b>${esc(x.label)}</b>${x.detail ? `<div class="sres">${esc(x.detail)}</div>` : ""}</span></li>`;
    }).join("");
    const lg = $("#jLog"); const atEnd = lg.scrollTop + lg.clientHeight >= lg.scrollHeight - 20;
    lg.textContent = r.log.join("\n"); if (atEnd) lg.scrollTop = lg.scrollHeight;
    if (r.done) {
      clearInterval(JOBPOLL);
      $("#jSum").innerHTML = r.ok ? `<div class="tst-sum ok">${ic("check")}${esc(r.title)}.</div>` : `<div class="tst-sum fail">${ic("alert")}${esc(r.error)}</div>`;
      if (!r.ok) $(".jlog").open = true;
      await load().catch(() => {});
      if (after) after(r);
      if (location.hash.startsWith("#/addon")) fillAddons();
      else if (location.hash.startsWith("#/pengaturan")) route();
    }
  };
  tick(); JOBPOLL = setInterval(tick, 1000);
}

/* ---------- Tes koneksi (popup) ---------- */
function openTest(id) {
  const x = site(id); if (!x) return;
  modal(`Tes koneksi · ${esc(x.name)}`, `
    <div class="tst-top" id="tstSub">Memeriksa jalur dari VPS ke MikroTik, jaringan ONT, GenieACS, dan akses remote.</div>
    <div class="prog"><i id="tstProg"></i></div>
    <ol class="steps" id="tstSteps"><li class="step wait"><span class="sic">…</span><span class="stx"><b>Memuat langkah tes…</b></span></li></ol>
    <div id="tstSum"></div>`,
    `<button class="btn" data-act="closemodal">Tutup</button><button class="btn pri" id="tstBtn" data-act="runtest" disabled>${ic("play")}Tes ulang</button>`,
    { size: "lg", flush: true });
  TEST = { id: x.id, plan: null, res: {}, running: false, done: false };
  runTest();
}
function drawSteps() {
  if (!TEST || !$("#tstSteps") || !TEST.plan) return;
  const P = TEST.plan;
  $("#tstSteps").innerHTML = stepsHtml(P, TEST.res, TEST.current);
  const doneN = Object.keys(TEST.res).length;
  $("#tstProg").style.width = (P.length ? (doneN / P.length) * 100 : 0) + "%";
  if (TEST.running) $("#tstSub").textContent = `Langkah ${Math.min(doneN + 1, P.length)} dari ${P.length}…`;
  const btn = $("#tstBtn");
  if (TEST.done) {
    const fail = P.filter((s) => TEST.res[s.key] && TEST.res[s.key].ok === false).length;
    $("#tstSub").textContent = `Selesai · ${P.length} langkah`;
    $("#tstSum").innerHTML = fail
      ? `<div class="tst-sum fail">${ic("alert")}${fail} langkah perlu diperbaiki. Lihat saran di bawah langkah yang gagal.</div>`
      : `<div class="tst-sum ok">${ic("check")}Semua beres. GenieACS dapat menjangkau ONT di router ini.</div>`;
    if (btn) btn.disabled = false;
  } else { $("#tstSum").innerHTML = ""; if (btn) btn.disabled = true; }
}
async function runTest() {
  if (!TEST || TEST.running) return;
  const id = TEST.id;
  TEST.res = {}; TEST.running = true; TEST.done = false;
  try { TEST.plan = (await api(`/api/sites/${id}/test-plan`)).steps; }
  catch (e) { if ($("#tstSteps")) $("#tstSteps").innerHTML = `<li class="step fail"><span class="stx"><b>${esc(e.message)}</b></span></li>`; TEST.running = false; return; }
  let vpnDown = false;
  for (const s of TEST.plan) {
    if (!TEST || TEST.id !== id) return; // dialog ditutup
    TEST.current = s.key; drawSteps();
    const t0 = performance.now();
    let r;
    if (vpnDown && (["ping-mt", "route", "ping-gw"].includes(s.key) || s.key.startsWith("fwd:"))) r = { ok: null, detail: "Dilewati karena VPN belum tersambung" };
    else {
      try { r = await api(`/api/sites/${id}/test-step`, { method: "POST", body: { key: s.key } }); }
      catch (e) { r = { ok: false, detail: e.message }; }
      const el = performance.now() - t0; if (el < 450) await new Promise((z) => setTimeout(z, 450 - el));
    }
    if (!TEST || TEST.id !== id) return;
    r.ms = performance.now() - t0;
    if (s.key === "vpn" && r.ok === false) vpnDown = true;
    TEST.res[s.key] = r; TEST.current = null; drawSteps();
  }
  TEST.running = false; TEST.done = true; drawSteps();
  load().catch(() => {});
}

/* ================= Tambah / ubah / hapus router ================= */
function siteForm(x) {
  const z = STATE.settings.zt, cur = x ? x.transport : "l2tp";
  if (!ztOn() && cur !== "zt") return `<input type="radio" name="fTr" value="l2tp" checked class="hidden"><div id="fZtBox" class="hidden"></div>` + siteFormRest(x);
  return `
    <label>Jalur ke VPS</label>
    <div class="seg"><label><input type="radio" name="fTr" value="l2tp" ${cur !== "zt" ? "checked" : ""}>L2TP</label><label ${z ? "" : 'class="netopt dis" style="margin:0;padding:8px 12px" title="Hubungkan VPS ke jaringan di menu ZeroTier dulu"'}><input type="radio" name="fTr" value="zt" ${cur === "zt" ? "checked" : ""} ${z ? "" : "disabled"}>ZeroTier</label></div>
    <div class="help">${z ? "ZeroTier butuh RouterOS v7 dengan paket zerotier (router ARM/ARM64). Router lain pakai L2TP." : 'ZeroTier belum diatur. Buka <a href="#/zerotier">menu ZeroTier</a> untuk mengaktifkan.'}</div>
    <div id="fZtBox" class="${cur === "zt" ? "" : "hidden"}">${x && x.ztNode ? `<label for="fZtNode">Node ID ZeroTier router</label>
      <input id="fZtNode" type="text" maxlength="10" value="${esc(x.ztNode)}"><div class="help">Untuk mengganti, pakai tombol Ganti router di tab Ringkasan.</div>`
      : `<label for="fZtSel">Perangkat ZeroTier <span class="muted" style="font-weight:400">(opsional)</span></label>
      <select id="fZtSel"><option value="">Memuat perangkat yang bergabung…</option></select>
      <input id="fZtNode" type="text" maxlength="10" class="hidden" style="margin-top:8px" placeholder="Node ID 10 karakter, contoh: 1a2b3c4d5e">
      <div class="help" id="fZtHelp">Biasanya tidak perlu dipilih: script MikroTik melaporkan Node ID-nya sendiri ke panel. Pilih dari daftar hanya jika MikroTik sudah bergabung lebih dulu (nama dari menu ZeroTier).</div>`}</div>
` + siteFormRest(x);
}
function siteFormRest(x) {
  return `
    <label for="fName">Nama router</label>
    <input id="fName" type="text" maxlength="40" placeholder="contoh: Nangahale" value="${esc(x?.name || "")}">
    <label for="fSub">Subnet ONT di MikroTik</label>
    <input id="fSub" type="text" placeholder="10.0.0.0/24" value="${esc(x?.realSubnet || "10.0.0.0/24")}">
    <div class="help">Winbox → IP → DHCP Server → Networks. Boleh sama dengan router lain.</div>
    <label for="fVirt">IP virtual <span class="muted" style="font-weight:400">(opsional)</span></label>
    <input id="fVirt" type="text" placeholder="Otomatis" value="${esc(x?.virtualSubnet || "")}">
    <div class="help">Kosongkan agar dipilih otomatis (10.100.x.0). Boleh diisi IP private apa saja, misalnya 172.16.10.0/24; GenieACS di VPS ikut menyesuaikan otomatis. Tidak boleh sama dengan router lain.</div>
    <label for="fNote">Catatan <span class="muted" style="font-weight:400">(opsional)</span></label>
    <input id="fNote" type="text" maxlength="120" placeholder="contoh: OLT C-Data 8 port" value="${esc(x?.note || "")}">
    <div class="err" id="fErr"></div>`;
}
const readForm = () => ({ name: $("#fName").value, realSubnet: $("#fSub").value, virtualSubnet: $("#fVirt").value, note: $("#fNote").value, transport: (document.querySelector("input[name=fTr]:checked") || {}).value || "l2tp", ztNode: $("#fZtNode") ? $("#fZtNode").value.trim() : "" });
let ZTFREE = null; // cache daftar perangkat ZeroTier untuk form
async function loadZtFree() {
  const sel = $("#fZtSel"); if (!sel) return;
  const keep = sel.value;
  let list = [];
  try { list = (await api("/api/zt/free")).list || []; } catch (e) { list = null; }
  if (!$("#fZtSel")) return;
  ZTFREE = list || [];
  const opt = (v, t) => `<option value="${esc(v)}">${esc(t)}</option>`;
  sel.innerHTML = opt("", list && list.length ? "Pilih nanti, setelah script dipasang" : "Belum ada perangkat yang bergabung, pilih nanti")
    + (list || []).map((m) => opt(m.node, `${m.name || "Tanpa nama"} · ${m.node}${m.ips && m.ips.length ? " · " + m.ips[0] : ""} · ${m.seen ? "online" : "offline"}`)).join("")
    + opt("__manual", "Isi Node ID manual…");
  if (keep && [...sel.options].some((o) => o.value === keep)) sel.value = keep;
  if (list === null) $("#fZtHelp").textContent = "Daftar perangkat tidak bisa dibaca. Isi Node ID manual atau pilih nanti setelah script dipasang.";
}
function bindTrForm() {
  const sel = $("#fZtSel");
  const showZt = () => {
    const zt = (document.querySelector("input[name=fTr]:checked") || {}).value === "zt";
    $("#fZtBox").classList.toggle("hidden", !zt);
    if (zt && sel && ZTFREE === null) loadZtFree();
  };
  document.querySelectorAll("input[name=fTr]").forEach((r) => (r.onchange = showZt));
  if (sel) {
    ZTFREE = null;
    sel.onchange = () => {
      const v = sel.value, inp = $("#fZtNode");
      inp.classList.toggle("hidden", v !== "__manual");
      if (v === "__manual") { inp.value = ""; inp.focus(); return; }
      inp.value = v;
      const m = (ZTFREE || []).find((y) => y.node === v);
      if (m && m.name && !$("#fName").value.trim()) $("#fName").value = m.name;
    };
  }
  showZt();
}
function openAdd() {
  modal("Tambah router", siteForm(null), `<button class="btn" data-act="closemodal">Batal</button><button class="btn pri" id="fSave">Simpan</button>`);
  bindTrForm(); $("#fName").focus();
  $("#fSave").onclick = async () => {
    busyBtn($("#fSave"), true); $("#fErr").textContent = "";
    try {
      const r = await api("/api/sites", { method: "POST", body: readForm() });
      await load(); location.hash = `#/router/${r.site.id}/script`;
      setTimeout(() => r.bindError
        ? doneDialog("Router ditambahkan, ZeroTier belum disetujui", `<p>${esc(r.bindError)}</p><p>Pilih routernya nanti dari tab Ringkasan.</p>`, "warn", false)
        : doneDialog("Router ditambahkan", `<p><b>${esc(r.site.name)}</b> siap dipasang.</p><p>Langkah berikutnya: salin script di bawah, lalu tempel di Winbox → New Terminal.${r.site.transport === "zt" && !r.site.ztNode ? " Router akan terpilih otomatis setelah script dijalankan." : ""}</p>`, "ok", false), 60);
    } catch (e) { $("#fErr").textContent = e.message; busyBtn($("#fSave"), false); }
  };
}
function openEdit(id) {
  const x = site(id);
  modal("Ubah router", siteForm(x), `<button class="btn" data-act="closemodal">Batal</button><button class="btn pri" id="fSave">Simpan</button>`);
  bindTrForm();
  $("#fSave").onclick = async () => {
    busyBtn($("#fSave"), true); $("#fErr").textContent = "";
    const f = readForm();
    try {
      const r = await api("/api/sites/" + id, { method: "PUT", body: f });
      const net = f.realSubnet.trim() !== x.realSubnet || (f.virtualSubnet.trim() && f.virtualSubnet.trim() !== x.virtualSubnet) || f.transport !== x.transport;
      await load(); route();
      if (r.bindError) doneDialog("Disimpan, ZeroTier belum disetujui", esc(r.bindError), "warn", false);
      else doneDialog("Perubahan disimpan", net ? "Subnet atau jalur berubah. Pasang ulang script terbaru di MikroTik router ini." : "", "ok", !net);
    } catch (e) { $("#fErr").textContent = e.message; busyBtn($("#fSave"), false); }
  };
}
function openResetPw(id) {
  const x = site(id);
  confirmDialog({
    title: "Buat password VPN baru?", icon: "key", ok: "Buat password baru",
    text: `<p>MikroTik <b>${esc(x.name)}</b> akan terputus sampai script terbaru dipasang ulang.</p>`,
    onOk: async () => {
      await api(`/api/sites/${id}/reset-password`, { method: "POST" }); await load();
      location.hash = `#/router/${id}/script`;
      setTimeout(() => doneDialog("Password VPN diganti", "Salin script terbaru dan pasang ulang di MikroTik.", "ok", false), 60);
    },
  });
}
function openDelete(id) {
  const x = site(id);
  confirmDialog({
    title: `Hapus ${esc(x.name)}?`, danger: true, ok: "Hapus router", wide: true,
    text: `<p>${x.transport === "zt" ? "Router ini dikeluarkan dari jaringan ZeroTier panel" : "Akun VPN router ini dihapus"}, beserta port forwarding-nya. GenieACS tidak bisa lagi Summon ONT di router ini.</p>
      ${x.state === "pending" ? "" : `<div class="note warn" style="margin:12px 0 10px">${ic("alert")}<div><b>Bersihkan MikroTik ${esc(x.name)} dulu</b>Aturan dari panel (${x.transport === "zt" ? "interface zt-acs" : "interface l2tp-acs"}, route, NETMAP, dan firewall) tetap tertinggal di MikroTik kalau tidak dihapus. Salin script di bawah, tempel di Winbox → New Terminal, lalu hapus router di panel.</div></div>`}
      <div class="codebox"><pre class="code" style="max-height:200px;padding-top:46px">${esc(x.removeScript)}</pre><button class="btn sm" data-copy="${esc(x.removeScript)}" data-msg="Script hapus tersalin. Tempel di Winbox → New Terminal">${ic("copy")}Salin</button></div>`,
    check: x.state === "pending" ? "" : "Script hapus sudah saya jalankan di MikroTik, atau MikroTik ini sudah tidak dipakai.",
    onOk: async () => {
      await api("/api/sites/" + id, { method: "DELETE" }); await load();
      location.hash = "#/router";
      setTimeout(() => doneDialog("Router dihapus", `${esc(x.name)} sudah dihapus dari panel.`), 60);
    },
  });
}
function openDelFwd(id, fid) {
  const x = site(id), f = x && x.forwards.find((y) => y.id === fid);
  confirmDialog({
    title: "Hapus port forwarding?", danger: true, ok: "Hapus",
    text: `<p>${f ? `<b>${esc(f.label)}</b> · <span class="mono">${esc(f.remote)}</span><br>` : ""}Alamat ini tidak bisa dipakai lagi.</p>`,
    onOk: async () => { await api(`/api/sites/${id}/forwards/${fid}`, { method: "DELETE" }); await load(); route(); doneDialog("Port forwarding dihapus", ""); },
  });
}

/* ================= Panduan ================= */
function viewGuide(v) {
  crumb([["Panduan"]]);
  const s = STATE.settings;
  const names = [BRAND].concat(s.brandHistory || []);
  const rm = [`/interface l2tp-client remove [find where name="l2tp-acs"]`, `:do { /zerotier interface remove [find where name="zt-acs"] } on-error={}`]
    .concat(names.map((n) => `/ip route remove [find where comment="${n}"]`), names.map((n) => `/ip firewall nat remove [find where comment~"^${n} - "]`), names.map((n) => `/ip firewall filter remove [find where comment~"^${n} - "]`), [`:put "Pengaturan ${BRAND} sudah dihapus."`]).join("\n");
  v.innerHTML = `
    <div class="ph"><div><h1>Panduan</h1><p>Cara kerja dan langkah pemakaian, dengan bahasa sederhana.</p></div></div>
    <div class="card guide"><div class="ch"><h2>Cara kerja</h2></div><div class="cb">
      <div class="flow"><span>ONT</span><i>→</i><span>OLT</span><i>→</i><span>MikroTik</span><i>⇄ VPN L2TP ⇄</i><span>VPS · GenieACS</span></div>
      <p>Tanpa VPN, GenieACS hanya bisa membaca ONT, tetapi tidak bisa memberi perintah (Summon), karena ONT berada di jaringan lokal.</p>
      <p>Setiap MikroTik membuat VPN ke VPS. Karena subnet ONT di semua router boleh sama, tiap router mendapat <b>IP virtual</b> berbeda; MikroTik menerjemahkannya kembali ke IP asli (NETMAP).</p>
    </div></div>
    <div class="card"><div class="ch"><h2>Menambah router</h2></div><div class="cb"><ol class="ol">
      <li><b>Tambah router di panel</b>Isi nama dan subnet ONT (Winbox → IP → DHCP Server → Networks).</li>
      <li><b>Pasang script di MikroTik</b>Tab Script MikroTik → Salin → Winbox → New Terminal → Paste.</li>
      <li><b>Jalankan tes koneksi</b>Klik tombol Tes koneksi di halaman router. Popup tes memeriksa VPN, jaringan ONT, GenieACS, dan akses remote satu per satu.</li>
      <li><b>Atur ONT</b>URL ACS di ONT atau profil TR-069 OLT: <code>${esc(s.acsUrl || "")}</code></li>
    </ol></div></div>
${ztOn() ? `    <div class="card"><div class="ch"><h2>Router lewat ZeroTier (opsional)</h2></div><div class="cb"><ol class="ol">
      <li><b>Buat jaringan</b>Menu ZeroTier → <b>Buat jaringan</b>, misalnya rentang <code>172.27.0.0/24</code>. Centang "Langsung hubungkan VPS".</li>
      <li><b>Tambah router dengan jalur ZeroTier</b>Pasang script di MikroTik (RouterOS v7, router ARM/ARM64), lalu di tab Ringkasan klik <b>Pilih router yang bergabung</b>.</li>
    </ol><p class="help">URL ACS di ONT tetap sama (<code>${esc(s.acsUrl || "")}</code>), baik lewat L2TP maupun ZeroTier. Router MIPS (hAP lite, hEX, RB951) tetap memakai L2TP.</p></div></div>` : `<div class="card"><div class="ch"><h2>Router lewat ZeroTier (opsional)</h2></div><div class="cb"><p style="color:var(--text-2)">Untuk router RouterOS v7 ARM/ARM64, pasang add-on <b>ZeroTier</b> di menu <a href="#/addon">Add-on</a>.</p></div></div>`}
    <div class="card"><div class="ch"><h2>Remote MikroTik dari mana saja</h2></div><div class="cb"><ol class="ol">
      <li><b>Tambah akses remote</b>Buka router → tab Port Forwarding → Tambah → pilih Winbox atau WebFig.</li>
      <li><b>Hubungkan Winbox</b>Isi Connect To dengan alamat yang diberikan, misalnya <code>${esc(s.publicIp || "IP_VPS")}:20001</code>.</li>
    </ol><p class="help">Jika di MikroTik IP → Services kolom Available From diisi, tambahkan <code>${esc(s.tunnelLocal || "")}</code>.</p></div></div>
    <div class="card"><div class="ch"><h2>Membersihkan pengaturan</h2></div><div class="cb">
      <p style="margin-bottom:10px"><b>Di MikroTik</b> — hanya pengaturan bertanda "${esc(BRAND)}" yang dihapus:</p>
      <div class="codebox"><pre class="code">${esc(rm)}</pre><button class="btn sm" data-copy="${esc(rm)}" data-msg="Script hapus tersalin">${ic("copy")}Salin</button></div>
      <p style="margin-top:14px"><b>Di VPS</b> — jalankan <code>bash bersihkan.sh</code> dari folder <code>acs-netmap-panel</code> untuk menghapus port forwarding, panel dan akun VPN, patch GenieACS, atau mengembalikan parameter.</p>
    </div></div>
    <div class="card faq"><div class="ch"><h2>Pertanyaan umum</h2></div>
      <details><summary>Status tetap "Terputus" setelah script dipasang</summary><p>Jalankan Tes koneksi untuk melihat langkah yang gagal. Biasanya: MikroTik belum punya internet, alamat VPS salah, atau port UDP 1701 di VPS tertutup.</p></details>
      <details><summary>Summon di GenieACS masih gagal</summary><p>Pastikan langkah "Patch GenieACS" di Tes koneksi lolos, dan ONT sudah Inform sekali setelah VPN tersambung.</p></details>
      <details><summary>Remote Winbox tidak bisa masuk</summary><p>Pasang ulang script MikroTik terbaru (berisi aturan "remote dari VPS"), cek IP → Services → winbox aktif, dan pastikan provider VPS tidak memblokir port tersebut.</p></details>
      <details><summary>Bolehkah IP virtual sama dengan ZeroTier?</summary><p>Boleh. Yang tidak boleh: dua router memakai IP virtual yang sama, atau IP virtual sama dengan subnet lokal mana pun.</p></details>
      <details><summary>Apa arti status "Menunggu pemasangan"?</summary><p>Router sudah dibuat di panel tetapi MikroTik-nya belum pernah tersambung. Router ini tidak dihitung terputus dan tidak dikirim notifikasi Telegram. Statusnya berubah sendiri saat MikroTik tersambung pertama kali.</p></details>
      <details><summary>Notifikasi Telegram tidak masuk</summary><p>Buka Pengaturan → Notifikasi Telegram, klik Kirim pesan tes. Jika gagal, pesan kesalahannya menjelaskan penyebabnya (token salah, bot bukan admin, topik terhapus). Ingat: notifikasi baru dikirim setelah VPN putus melewati jeda yang diatur.</p></details>
      <details><summary>Setelah HTTPS aktif, panel tidak bisa dibuka lewat IP</summary><p>Itu normal. Buka lewat <code>https://domain:${esc(String(s.port || 8088))}</code>; alamat http dan IP akan dialihkan otomatis ke sana. Jika domain bermasalah, lepas domain di Pengaturan → Domain &amp; HTTPS.</p></details>
      <details><summary>Aman menjalankan script MikroTik berulang kali?</summary><p>Aman. Script menghapus pengaturan lama bertanda "${esc(BRAND)}" (termasuk nama panel sebelumnya) terlebih dulu; pengaturan lain tidak disentuh.</p></details>
    </div>`;
}

/* ================= Pengaturan ================= */
const SET_TABS = [["umum", "Umum", "sliders"], ["telegram", "Notifikasi Telegram", "send"], ["domain", "Domain & HTTPS", "globe"]];
function viewSettings(v, tab) {
  if (!SET_TABS.some(([k]) => k === tab)) tab = "umum";
  crumb([["Pengaturan", "#/pengaturan"], [SET_TABS.find(([k]) => k === tab)[1]]]);
  v.innerHTML = `
    <div class="ph"><div><h1>Pengaturan</h1><p>Pengaturan VPS, notifikasi, dan domain panel.</p></div></div>
    ${tabsHtml(SET_TABS, tab, "#/pengaturan")}
    <div id="setBody"></div>`;
  const b = $("#setBody");
  if (tab === "telegram") setTelegram(b);
  else if (tab === "domain") setDomain(b);
  else setGeneral(b);
}
function setGeneral(b) {
  const s = STATE.settings;
  b.innerHTML = `
    <div class="card"><div class="ch"><h2>Nama panel</h2></div><form class="cb" id="brandForm" style="padding-top:4px">
      <label for="sBrand">Nama panel</label>
      <input id="sBrand" type="text" maxlength="30" placeholder="VPN ACS" value="${esc(s.panelName || "")}">
      <div class="help">Tampil di judul panel dan dipakai sebagai komentar aturan di script MikroTik (contoh: <code>${esc(s.panelName || "VPN ACS")} - ONT ke IP virtual</code>). Huruf, angka, spasi, - atau _.</div>
      <div class="err" id="brandErr"></div>
      <div class="form-actions"><button class="btn pri">Simpan</button></div>
    </form></div>
    <div class="card"><div class="ch"><h2>VPS</h2></div><form class="cb" id="vpsForm" style="padding-top:4px">
      <label for="sIp">Alamat VPS</label>
      <input id="sIp" type="text" placeholder="103.20.30.40 atau vpn.domain.com" value="${esc(s.publicIp || "")}">
      <div class="help">Dipakai sebagai <i>connect-to</i> di MikroTik.${s.cloudflare ? ` Saat ini diatur lewat <a href="#/pengaturan/domain">Domain &amp; HTTPS</a>.` : ""}</div>
      <label for="sTz">Zona waktu</label>
      <select id="sTz">${(s.timezones || []).map((z) => `<option value="${z.id}" ${z.id === tzId() ? "selected" : ""}>${z.label} (${z.id})</option>`).join("")}</select>
      <div class="help">Untuk jam di riwayat, log aktivitas, dan pesan Telegram.</div>
      <label class="check" style="margin-top:16px"><input id="sIpsec" type="checkbox" ${s.useIpsec ? "checked" : ""}>Pakai IPsec (enkripsi)</label>
      <div class="help">Setelah diubah, pasang ulang script di semua MikroTik.</div>
      <div id="pskBox" class="${s.useIpsec ? "" : "hidden"}"><label>Kunci IPsec (PSK)</label><input type="text" readonly value="${esc(s.psk || "")}"></div>
      <div class="err" id="vpsErr"></div>
      <div class="form-actions"><button class="btn pri">Simpan</button></div>
    </form></div>
    <div class="card"><div class="ch"><h2>Jaringan VPN (L2TP)</h2></div>
      <div class="kv"><span>Jaringan</span><b>${esc(s.tunnelNet || "")}</b></div>
      <div class="kv"><span>IP VPS (URL ACS)</span><b>${esc(s.tunnelLocal || "")}</b></div>
      <div class="kv"><span>IP tetap MikroTik</span><b>${esc(s.tunnelStatic || "")} · maks. ${s.tunnelMax || 0}</b></div>
      <div class="kv"><span>Pool dinamis</span><b>${esc(s.tunnelPool || "")}</b></div>
      <form class="cb" id="tunForm" style="border-top:1px solid var(--line)">
        <div class="note warn" style="margin:0 0 4px">${ic("alert")}<div><b>Sebaiknya ditentukan sekali di awal</b>Jika diganti, semua VPN terputus sebentar, script di semua MikroTik harus dipasang ulang, dan URL ACS di semua ONT berubah.</div></div>
        <label for="tNet">Jaringan VPN baru</label>
        <input id="tNet" type="text" placeholder="contoh: 172.31.0.0/24">
        <div class="err" id="tErr"></div>
        <div class="form-actions"><button class="btn danger">Ganti jaringan VPN</button></div>
      </form>
    </div>
    ${(() => {
      const P = STATE.settings.stdPorts || {}, https = !!(STATE.settings.cloudflare && STATE.settings.cloudflare.https);
      const url = STATE.settings.panelUrl || "";
      return `<div class="card"><div class="ch"><h2>Alamat tanpa port (80 / 443)</h2>${P.enabled ? (P.active ? `<span class="pill ok">Aktif</span>` : `<span class="pill bad">Gagal</span>`) : `<span class="pill wait">Tidak aktif</span>`}</div><div class="cb" style="padding-top:4px">
        <p style="color:var(--text-2)">Panel juga dibuka lewat port standar, jadi alamatnya tanpa <code>:${esc(String(STATE.settings.port || 8088))}</code>: ${https ? "<b>443</b> (https) dengan domain, dan port <b>80</b> dialihkan ke https" : "port <b>80</b> (http)"}. Port ${esc(String(STATE.settings.port || 8088))} tetap bisa dipakai.${https ? " Subdomain GenieACS dan ZTNET juga ikut tanpa port dan ber-HTTPS." : ""}</p>
        ${P.error ? `<div class="note bad" style="margin:10px 0 0">${ic("alert")}<div><b>Port 80/443 tidak bisa dipakai</b>${esc(P.error)}. Panel tetap di port ${esc(String(STATE.settings.port || 8088))}.</div></div>` : ""}
        ${P.enabled && P.active ? `<div class="kv" style="padding:10px 0 0;border:0"><span>Alamat panel</span><b><a href="${esc(url)}" target="_blank" rel="noopener">${esc(url)}</a></b></div>` : ""}
        <div class="help">Aktif secara bawaan. Syarat: port 80/443 tidak dipakai aplikasi lain (mis. nginx/apache), dan TCP 80 + 443 dibuka di firewall provider VPS.</div>
        <div class="form-actions">${P.enabled ? `<button class="btn" id="stdOff" type="button">Matikan</button>` : `<button class="btn pri" id="stdOn" type="button">${ic("globe")}Aktifkan port 80/443</button>`}</div>
      </div></div>`;
    })()}
    <div class="card"><div class="ch"><h2>Password admin</h2></div><form class="cb" id="pwForm" style="padding-top:4px">
      ${STATE.settings.defaultPassword ? `<div class="note warn" style="margin-bottom:12px">${ic("alert")}<div><b>Masih memakai password bawaan</b>Isi password lama dengan <code>Admin123</code>, lalu buat password baru.</div></div>` : ""}
      <div class="f2"><div><label for="pOld">Password lama</label><input id="pOld" type="password" autocomplete="current-password"></div>
        <div><label for="pNew">Password baru</label><input id="pNew" type="password" autocomplete="new-password" placeholder="Minimal 8 karakter"></div></div>
      <div class="err" id="pwErr"></div>
      <div class="form-actions"><button class="btn pri">Ganti password</button></div>
    </form></div>`;
  $("#brandForm").onsubmit = async (e) => {
    e.preventDefault(); $("#brandErr").textContent = "";
    const before = s.panelName, btn = $("#brandForm button"); busyBtn(btn, true);
    try {
      await api("/api/settings", { method: "PUT", body: { panelName: $("#sBrand").value } });
      await load(); route();
      const changed = STATE.settings.panelName !== before;
      doneDialog("Nama panel disimpan", changed ? `<p>Komentar di script MikroTik sekarang memakai <b>${esc(STATE.settings.panelName)}</b>.</p><p>Router yang sudah terpasang tetap jalan. Pasang ulang script terbaru bila ingin komentarnya ikut berubah; script baru otomatis menghapus aturan dengan nama lama.</p>` : "", "ok", !changed);
    } catch (err) { $("#brandErr").textContent = err.message; busyBtn(btn, false); }
  };
  $("#sIpsec").onchange = () => $("#pskBox").classList.toggle("hidden", !$("#sIpsec").checked);
  $("#vpsForm").onsubmit = async (e) => {
    e.preventDefault(); $("#vpsErr").textContent = "";
    const changed = $("#sIpsec").checked !== !!s.useIpsec;
    const btn = e.submitter || $("#vpsForm button"); busyBtn(btn, true);
    try { await api("/api/settings", { method: "PUT", body: { publicIp: $("#sIp").value, useIpsec: $("#sIpsec").checked, timezone: $("#sTz").value } }); await load(); route(); doneDialog("Pengaturan disimpan", changed ? "IPsec diubah. Pasang ulang script di semua MikroTik." : "", "ok", !changed); }
    catch (err) { $("#vpsErr").textContent = err.message; busyBtn(btn, false); }
  };
  $("#tunForm").onsubmit = (e) => {
    e.preventDefault(); $("#tErr").textContent = "";
    const val = $("#tNet").value.trim();
    if (!val) { $("#tErr").textContent = "Isi jaringan VPN baru."; return; }
    confirmDialog({
      title: "Ganti jaringan VPN?", danger: true, icon: "alert", ok: "Ganti jaringan",
      text: `<p>Dari <b>${esc(s.tunnelNet)}</b> ke <b>${esc(val)}</b>.</p><p>Semua VPN terputus sebentar, script di ${STATE.sites.length} MikroTik harus dipasang ulang, dan URL ACS di semua ONT berubah.</p>`,
      onOk: async () => { await api("/api/settings", { method: "PUT", body: { tunnelNet: val } }); await load(); route(); doneDialog("Jaringan VPN diganti", `Sekarang ${esc(STATE.settings.tunnelNet)}. Pasang ulang script di semua MikroTik dan perbarui URL ACS di ONT.`, "ok", false); },
    });
  };
  const stdBtn = $("#stdOn") || $("#stdOff");
  if (stdBtn) stdBtn.onclick = async () => {
    const on = stdBtn.id === "stdOn";
    busyBtn(stdBtn, true);
    try { await api("/api/stdports", { method: "POST", body: { enable: on } }); openJob(); }
    catch (err) { busyBtn(stdBtn, false); toast(err.message); }
  };
  $("#pwForm").onsubmit = async (e) => {
    e.preventDefault(); $("#pwErr").textContent = "";
    const btn = $("#pwForm button"); busyBtn(btn, true);
    try { await api("/api/settings", { method: "PUT", body: { oldPassword: $("#pOld").value, newPassword: $("#pNew").value } }); $("#pOld").value = ""; $("#pNew").value = ""; await load(); route(); doneDialog("Password admin diganti", "Gunakan password baru saat login berikutnya."); }
    catch (err) { $("#pwErr").textContent = err.message; }
    busyBtn(btn, false);
  };
}

/* ================= GenieACS ================= */
function viewGenie(v) {
  crumb([["GenieACS"]]);
  const s = STATE.settings;
  v.innerHTML = `
    <div class="ph"><div><h1>GenieACS</h1><p>Status layanan, patch IP virtual, dan ONT yang melapor dari setiap router.</p></div>
      <div class="acts">${s.genieUrl ? `<a class="btn" href="${esc(s.genieUrl)}" target="_blank" rel="noopener">${ic("ext")}Buka GenieACS</a>` : ""}</div></div>
    <div id="gBody"><div class="card"><div class="empty"><p>Membaca data GenieACS…</p></div></div></div>`;
  fillGenie(false);
}
async function fillGenie(refresh) {
  const b = $("#gBody"); if (!b) return;
  let g;
  try { g = await api("/api/genie" + (refresh ? "?refresh=1" : "")); } catch (e) { b.innerHTML = `<div class="note bad">${ic("alert")}<div><b>Gagal membaca GenieACS</b>${esc(e.message)}</div></div>`; return; }
  if (!$("#gBody") || !location.hash.startsWith("#/genieacs")) return;
  const s = STATE.settings, T = g.totals;
  const rows = g.perRouter.slice().sort((a, b2) => b2.total - a.total || a.name.localeCompare(b2.name, "id"));
  const ago = (t) => (t ? fmtDur(Date.now() - t) + " lalu" : "—");
  const P = g.patch, R = P.ranges || { extra: [], fromSites: [] };
  const patch = P.cidr === null ? { c: "info", t: "GenieACS tidak ditemukan di VPS ini", d: "Abaikan jika GenieACS dipasang di server lain." }
    : !P.patched ? { c: "warn", t: "Patch IP virtual belum terpasang", d: "Summon ke ONT akan gagal. Di VPS jalankan: bash genieacs-virtualip.sh" }
    : !P.synced ? { c: "warn", t: "Setting GenieACS belum sama dengan panel", d: "Panel akan mencoba lagi dalam 5 menit. Jika tetap begini, cek: journalctl -u vpn-acs -n 50" }
    : { c: "ok", t: "Patch IP virtual aktif", d: "Rentang mengikuti IP virtual router di panel secara otomatis." };
  b.innerHTML = `
    <div class="kpis">
      <div class="kpi"><span>Total ONT</span><b>${g.devicesError ? "—" : T.total}</b><small>terdaftar di GenieACS</small></div>
      <div class="kpi"><span><i class="dot ok"></i>Melapor</span><b>${g.devicesError ? "—" : T.active}</b><small>dalam 1 jam terakhir</small></div>
      <div class="kpi"><span><i class="dot bad"></i>Tidak melapor</span><b>${g.devicesError ? "—" : T.idle}</b><small>lebih dari 1 jam</small></div>
      <div class="kpi"><span>Tanpa router</span><b>${g.devicesError ? "—" : T.other}</b><small>IP tidak cocok dengan router panel</small></div>
    </div>
    <div class="grid-dash">
      <div class="card">
        <div class="ch"><h2>ONT per router</h2><button class="btn sm ghost" id="gRefresh" title="Baca ulang dari GenieACS">${ic("refresh")}Perbarui</button></div>
        ${g.devicesError ? `<div class="cb"><div class="note warn" style="margin:0">${ic("alert")}<div><b>Data ONT tidak bisa dibaca</b>${esc(g.devicesError)}</div></div></div>`
          : !rows.length ? `<div class="empty"><p>Belum ada router.</p></div>`
          : `<table class="t"><thead><tr><th>Router</th><th class="r">ONT</th><th class="r">Melapor</th><th class="r hide-sm">Terakhir lapor</th></tr></thead><tbody>
            ${rows.map((r) => `<tr class="click" data-go="#/router/${r.id}"><td><b style="font-weight:550">${esc(r.name)}</b>${r.transport === "zt" ? ' <span class="tag">ZT</span>' : ""}<div class="muted mono" style="font-size:12px">${esc(r.virtualSubnet)}</div></td>
              <td class="r pc">${r.total}</td><td class="r pc ${r.total && r.active < r.total ? "warn" : ""}">${r.active}</td><td class="r muted hide-sm">${ago(r.last)}</td></tr>`).join("")}
            ${g.other.total ? `<tr><td><span class="muted">Tanpa router</span><div class="muted" style="font-size:12px">IP di luar IP virtual router panel</div></td><td class="r pc">${g.other.total}</td><td class="r pc">${g.other.active}</td><td class="r muted hide-sm">${ago(g.other.last)}</td></tr>` : ""}
          </tbody></table>`}
        <div class="cb" style="border-top:1px solid var(--line);padding:12px 20px"><span class="help" style="margin:0">ONT dikelompokkan menurut IP virtual di ConnectionRequestURL. Diperbarui tiap 1 menit${g.cachedAt ? ` · dibaca ${esc(fmtT(g.cachedAt))}` : ""}.</span></div>
      </div>
      <div class="stack">
        <div class="card"><div class="ch"><h2>Layanan</h2>${g.version ? `<span class="muted mono" style="font-size:12px">v${esc(g.version)}</span>` : ""}</div>
          ${g.services.map((x) => `<div class="kv"><span>${esc(x.label)}</span><b>${x.active ? `<span class="pill ok">Berjalan</span>` : `<span class="pill bad">${esc(x.state === "tidak ada" ? "Tidak ada" : "Mati")}</span>`}</b></div>`).join("")}
        </div>
        <div class="card"><div class="ch"><h2>Patch IP virtual</h2></div><div class="cb">
          <div class="note ${patch.c}" style="margin:0">${ic(patch.c === "ok" ? "check" : patch.c === "warn" ? "alert" : "info")}<div><b>${esc(patch.t)}</b>${esc(patch.d)}</div></div>
          ${P.outside.length ? `<div class="note warn" style="margin:12px 0 0">${ic("alert")}<div><b>${P.outside.length} router di luar rentang patch</b>${P.outside.map((o) => `<a href="#/router/${o.id}">${esc(o.name)}</a> (${esc(o.virtualSubnet)})`).join(", ")}</div></div>` : ""}
        </div>
        ${P.cidr === null ? "" : `
          <div class="kv"><span>Otomatis</span><b class="mono">${esc(R.pool || "")}</b></div>
          ${R.fromSites.map((x) => `<div class="kv"><span>IP virtual <a href="#/router/${x.id}">${esc(x.name)}</a></span><b class="mono">${esc(x.subnet)}</b></div>`).join("")}
          ${R.extra.map((x) => `<div class="kv"><span>Tambahan</span><b class="mono">${esc(x)}</b></div>`).join("")}
          <form class="cb" id="gExtraForm" style="border-top:1px solid var(--line)">
            <label for="gExtra" style="margin-top:0">Rentang tambahan (opsional)</label>
            <input id="gExtra" type="text" placeholder="contoh: 10.20.0.0/16" value="${esc(R.extra.join(", "))}">
            <div class="help">IP virtual router di panel otomatis dimasukkan. Isi ini hanya untuk ONT dengan IP virtual buatan sendiri di luar panel. Pisahkan dengan koma.</div>
            <div class="err" id="gExtraErr"></div>
            <div class="form-actions"><button class="btn pri">Simpan</button></div>
          </form>`}
        </div>
        <div class="card"><div class="ch"><h2>Alamat</h2></div>
          <div class="kv"><span>GenieACS UI</span><b>${g.url ? `<a class="ext" href="${esc(g.url)}" target="_blank" rel="noopener">${esc(g.url.replace(/^https?:\/\//, ""))}${ic("ext", "")}</a>` : "—"}</b></div>
          <div class="kv"><span>Subdomain</span><b>${g.subdomain ? esc(g.subdomain) : s.cloudflare ? `<a href="#/pengaturan/domain">Buat subdomain</a>` : "—"}</b></div>
          <div class="kv"><span>URL ACS untuk ONT</span><b>${esc(g.acsUrl)} ${copyBtn(g.acsUrl, "URL ACS tersalin")}</b></div>
          <form class="cb" id="genieForm" style="border-top:1px solid var(--line)">
            <label for="sGenie" style="margin-top:0">Alamat GenieACS UI</label>
            <input id="sGenie" type="text" placeholder="${esc(g.urlManual ? "" : g.url || "http://acs.domain.com:3000")}" value="${esc(g.urlManual)}">
            <div class="help">Kosongkan untuk otomatis (alamat VPS + port GenieACS).</div>
            <div class="err" id="genieErr"></div>
            <div class="form-actions"><button class="btn pri">Simpan</button></div>
          </form>
        </div>
      </div>
    </div>`;
  paintIcons(b);
  $("#gRefresh") && ($("#gRefresh").onclick = async () => { busyBtn($("#gRefresh"), true); await fillGenie(true); });
  $("#gExtraForm") && ($("#gExtraForm").onsubmit = async (e) => {
    e.preventDefault(); $("#gExtraErr").textContent = "";
    const btn = $("#gExtraForm button"); busyBtn(btn, true);
    try {
      const r = await api("/api/genie/ranges", { method: "PUT", body: { extra: $("#gExtra").value } });
      await fillGenie(true);
      doneDialog("Rentang GenieACS disimpan", `<p>Rentang yang dipakai GenieACS:</p><p class="mono">${esc(r.value.split(",").join(", "))}</p>${r.restarted ? "<p>GenieACS CWMP sudah di-restart. ONT perlu Inform sekali lagi (maksimal 5 menit) sebelum Summon memakai rentang baru.</p>" : ""}`);
    } catch (err) { $("#gExtraErr").textContent = err.message; busyBtn(btn, false); }
  });
  $("#genieForm").onsubmit = async (e) => {
    e.preventDefault(); $("#genieErr").textContent = "";
    const btn = $("#genieForm button"); busyBtn(btn, true);
    try { await api("/api/settings", { method: "PUT", body: { genieUrl: $("#sGenie").value } }); await load(); route(); doneDialog("Alamat GenieACS disimpan", ""); }
    catch (err) { $("#genieErr").textContent = err.message; busyBtn(btn, false); }
  };
}

/* ---------- ZeroTier ---------- */
let ZTPICK = false; // sedang memilih jaringan lain
function viewZerotier(v) {
  crumb([["ZeroTier"]]);
  v.innerHTML = `
    <div class="ph"><div><h1>ZeroTier</h1><p id="ztSubTitle">Controller ZeroTier di VPS: jaringan, alamat IP, dan perangkat diatur langsung dari sini.</p></div>
      <div class="acts" id="ztActs"></div></div>
    <div id="ztBody"></div>`;
  setZerotier($("#ztBody"));
}
const ZTV = { q: "", f: "all" }; // pencarian & filter anggota
function ztAgo(t) {
  if (!t) return "";
  const s = Math.max(0, Math.round((Date.now() - t) / 1000));
  if (s < 60) return "baru saja";
  if (s < 3600) return Math.round(s / 60) + " mnt lalu";
  if (s < 86400) return Math.round(s / 3600) + " jam lalu";
  return Math.round(s / 86400) + " hari lalu";
}
async function setZerotier(b) {
  if (!b.innerHTML) b.innerHTML = `<div class="card"><div class="empty"><span class="spin"></span><p style="margin-top:10px">Membaca controller ZeroTier…</p></div></div>`;
  let z;
  try { z = await api("/api/zt"); } catch (e) { b.innerHTML = `<div class="note bad">${ic("alert")}<div><b>Gagal membaca ZeroTier</b>${esc(e.message)}</div></div>`; return; }
  if (!location.hash.startsWith("#/zerotier")) return;
  const s = STATE.settings;
  const acts = $("#ztActs");
  if (!z.installed) {
    if (acts) acts.innerHTML = "";
    b.innerHTML = `<div class="card"><div class="empty zt-empty"><div class="big">${ic("hub")}</div><h3>ZeroTier belum terpasang di VPS</h3>
      <p>${esc(z.error || "")}</p><p>Pasang lewat menu Add-on. Hanya paket zerotier-one (±10 MB), selesai dalam hitungan detik.</p>
      <div class="form-actions" style="justify-content:center"><a class="btn pri" href="#/addon">${ic("puzzle")}Buka Add-on</a><button class="btn" id="ztRe">${ic("refresh")}Periksa lagi</button></div></div></div>`;
    $("#ztRe").onclick = () => setZerotier(b);
    return;
  }
  const sub = $("#ztSubTitle");
  if (sub) sub.innerHTML = `<span class="zt-node"><span class="dot ${z.online ? "ok" : "bad"}"></span>Controller <b class="mono">${esc(z.node)}</b> · ZeroTier ${esc(z.version || "")} · ${z.online ? "online" : "offline"}</span>`;
  if (acts) {
    acts.innerHTML = `<button class="btn" id="ztRe">${ic("refresh")}Muat ulang</button><button class="btn pri" id="ztNew">${ic("plus")}Buat jaringan</button>`;
    $("#ztRe").onclick = () => { busyBtn($("#ztRe"), true); setZerotier(b).finally(() => busyBtn($("#ztRe"), false)); };
    $("#ztNew").onclick = () => ztCreateDialog(z, b);
  }
  const cur = z.current;
  const members = z.members || [];
  const pending = members.filter((m) => !m.authorized && m.role !== "vps");
  const onlineN = members.filter((m) => m.authorized && m.online).length;
  const others = (z.networks || []).filter((n) => !n.current);
  const nameOf = (m) => m.name || "";
  const ipOwner = (ip) => { const m = members.find((x) => (x.ips || []).includes(ip)); return m ? nameOf(m) || m.node : ""; };

  const ztnetNote = z.ztnet ? `<div class="note info">${ic("info")}<div><b>ZTNET lama masih terpasang</b>Semua pengaturan ZeroTier kini ada di panel, jadi ZTNET tidak dipakai lagi. Nama perangkat dari ZTNET bisa disalin ke panel, lalu ZTNET dilepas untuk menghemat RAM.
    <div style="margin-top:10px"><button class="btn sm pri" id="ztnetGo">Pindahkan &amp; lepas ZTNET</button></div></div></div>` : "";

  // ---------- belum ada jaringan aktif ----------
  if (!cur) {
    const list = z.networks || [];
    b.innerHTML = `${ztnetNote}
      ${list.length ? `<div class="card"><div class="ch"><h2>Pilih jaringan untuk panel</h2><span class="muted" style="font-size:12.5px">${list.length} jaringan di controller</span></div>
        <p class="help" style="margin:2px 20px 6px">VPS bergabung ke jaringan ini dan mendapat IP ZeroTier. Router yang memilih jalur ZeroTier memakai jaringan yang sama. URL ACS untuk ONT tetap <b>${esc(s.acsUrl || "")}</b>.</p>
        <ul class="zt-nets">${list.map((n) => ztNetRow(n, { canUse: true })).join("")}</ul></div>`
      : `<div class="card"><div class="empty zt-empty"><div class="big">${ic("hub")}</div><h3>Belum ada jaringan ZeroTier</h3>
          <p>Buat jaringan untuk router yang tersambung ke GenieACS lewat ZeroTier. Rentang IP, pool, dan perangkat semuanya diatur dari panel ini.</p>
          <div class="form-actions" style="justify-content:center"><button class="btn pri" id="ztNew2">${ic("plus")}Buat jaringan</button></div></div></div>`}`;
    const n2 = $("#ztNew2"); if (n2) n2.onclick = () => ztCreateDialog(z, b);
    ztBindNets(b, z);
    ztBindZtnet(b);
    paintIcons(b);
    return;
  }

  // ---------- jaringan aktif ----------
  const okNet = cur.status === "OK";
  b.innerHTML = `${ztnetNote}
    ${cur.checkError ? `<div class="note bad">${ic("alert")}<div><b>Jaringan ZeroTier bermasalah</b>${esc(cur.checkError)}</div></div>` : ""}
    ${!okNet ? `<div class="note warn">${ic("alert")}<div><b>VPS belum tersambung ke jaringan</b>Status: ${esc(cur.status || "-")}. Biasanya selesai dalam beberapa detik; muat ulang halaman ini.</div></div>` : ""}
    ${pending.length ? `<div class="note warn zt-pend">${ic("clock")}<div><b>${pending.length} perangkat menunggu persetujuan</b>${pending.slice(0, 3).map((m) => `<span class="mono">${esc(m.node)}</span>${m.name ? ` (${esc(m.name)})` : ""}`).join(", ")}${pending.length > 3 ? " dan lainnya" : ""}. Router yang dipasang dari panel disetujui otomatis.
      <div style="margin-top:10px"><button class="btn sm" id="ztShowPend">Lihat &amp; setujui</button></div></div></div>` : ""}
    <div class="card zt-hero">
      <div class="zt-hh">
        <span class="zt-hic">${ic("hub")}</span>
        <div class="zt-ht">
          <h2>${esc(cur.name || "(tanpa nama)")} ${cur.private ? `<span class="pill ok">${ic("lock", "")}Private</span>` : `<span class="pill bad">Public</span>`} ${okNet ? `<span class="pill info">Dipakai panel</span>` : ""}</h2>
          <div class="zt-id"><span class="mono">${esc(cur.nwid)}</span>${copyBtn(cur.nwid, "Network ID tersalin")}<span class="sep">·</span>interface ${esc(cur.iface || "—")}</div>
        </div>
        <div class="zt-ha"><button class="btn" id="ztSet">${ic("sliders")}Pengaturan</button></div>
      </div>
      <div class="stats zt-stats">
        <div class="stat"><span>Rentang IP</span><b class="mono">${esc(cur.subnet)}</b><small>${cur.poolStart && cur.poolEnd ? `Pool ${esc(cur.poolStart)} – .${esc(cur.poolEnd.split(".").pop())}` : "Pool otomatis (seluruh rentang)"}</small></div>
        <div class="stat"><span>IP VPS</span><b class="mono">${esc(cur.vpsIp)}</b><small>gateway router ZeroTier</small></div>
        <div class="stat"><span>Perangkat online</span><b>${onlineN}<em>/${members.filter((m) => m.authorized).length}</em></b><small>${cur.sites || 0} router panel</small></div>
        <div class="stat"><span>Menunggu persetujuan</span><b class="${pending.length ? "warn" : ""}">${pending.length}</b><small>${cur.private ? "perangkat baru perlu disetujui" : "jaringan public: tanpa persetujuan"}</small></div>
      </div>
    </div>

    <div class="card" id="ztMembers">
      <div class="ch"><h2>Perangkat</h2><span class="muted" style="font-size:12.5px">${members.length} perangkat di jaringan</span></div>
      <div class="toolbar">
        <div class="search">${ic("search", "")}<input id="ztQ" type="text" placeholder="Cari nama, Node ID, atau IP" value="${esc(ZTV.q)}"></div>
        <div class="filters">
          <button class="chip ${ZTV.f === "all" ? "on" : ""}" data-zf="all">Semua</button>
          <button class="chip ${ZTV.f === "on" ? "on" : ""}" data-zf="on">Online</button>
          <button class="chip ${ZTV.f === "off" ? "on" : ""}" data-zf="off">Offline</button>
          <button class="chip ${ZTV.f === "wait" ? "on" : ""}" data-zf="wait">Menunggu${pending.length ? ` <b class="zt-cnt">${pending.length}</b>` : ""}</button>
        </div>
      </div>
      <div class="zt-tw"><table class="t zt-t"><thead><tr><th>Perangkat</th><th class="zt-colnode">Node ID</th><th class="zt-colnode">IP ZeroTier</th><th class="hide-sm">Koneksi</th><th>Status</th><th class="r"></th></tr></thead><tbody id="ztRows"></tbody></table></div>
    </div>

    <div class="grid2 zt-g2">
      <div class="card"><div class="ch"><h2>Rute jaringan</h2><span class="muted" style="font-size:12.5px">dibagikan ke semua perangkat</span></div>
        <ul class="zt-routes">${(cur.routes || []).map((r) => `<li><span class="mono zt-rt">${esc(r.target)}</span>
          ${r.via ? `<span class="zt-arrow">→</span><span class="mono">${esc(r.via)}</span><span class="muted zt-rv">${esc(ipOwner(r.via))}</span>` : `<span class="muted zt-rv">langsung (jaringan ZeroTier)</span>`}
          <span class="tag ${r.via ? (r.panel ? "" : "gray") : "gray"}">${r.via ? (r.panel ? "otomatis" : "manual") : "jaringan"}</span></li>`).join("") || `<li class="muted">Belum ada rute</li>`}</ul>
        <p class="help" style="margin:0 20px 16px">Rute IP virtual tiap router dan URL ACS dibuat otomatis oleh panel. Rentang jaringan diatur di Pengaturan.</p>
      </div>
      <div class="card"><div class="ch"><h2>Jaringan di controller</h2><span class="muted" style="font-size:12.5px">${(z.networks || []).length}</span></div>
        <ul class="zt-nets">${(z.networks || []).map((n) => ztNetRow(n, { canUse: false })).join("")}</ul>
        <div class="cb zt-danger"><button class="btn ghost danger sm" id="ztLeave">Lepas VPS dari jaringan ini</button></div>
      </div>
    </div>
    <p class="help" style="margin-top:12px">Rentang IP ZeroTier tidak boleh bentrok dengan ${esc(s.tunnelNet || "")} (L2TP), ${esc(s.virtualPool || "")} (IP virtual), subnet ONT, dan 172.17.0.0/16 (Docker). URL ACS untuk ONT tetap ${esc(s.acsUrl || "")}.</p>`;

  // ---------- tabel perangkat ----------
  const fill = () => {
    const q = ZTV.q.trim().toLowerCase();
    const rows = members.filter((m) => {
      if (ZTV.f === "on" && !(m.authorized && m.online)) return false;
      if (ZTV.f === "off" && !(m.authorized && !m.online)) return false;
      if (ZTV.f === "wait" && m.authorized) return false;
      if (!q) return true;
      return [m.name, m.note, m.node, (m.ips || []).join(" "), m.physical].join(" ").toLowerCase().includes(q);
    });
    $("#ztRows").innerHTML = rows.map((m) => {
      const av = m.role === "vps" ? "vps" : m.role === "router" ? "router" : "dev";
      const st = !m.authorized ? `<span class="pill wait">Menunggu</span>` : m.online ? `<span class="pill ok">Online</span>` : `<span class="pill bad">Offline</span>`;
      const conn = m.role === "vps" ? `<span class="muted">VPS ini</span>` : m.physical ? `<span class="mono">${esc(m.physical)}</span>${m.latency != null ? `<span class="zt-lat">${m.latency} ms</span>` : ""}${m.version ? `<div class="muted zt-small">ZeroTier ${esc(m.version)}</div>` : ""}` : `<span class="muted">${m.lastSeen ? "terakhir " + ztAgo(m.lastSeen) : "belum terlihat"}</span>`;
      const act = m.role === "vps" ? `<span class="muted zt-small">otomatis</span>`
        : `${!m.authorized ? `<button class="btn sm pri" data-zm="auth" data-node="${esc(m.node)}">Setujui</button>` : ""}<button class="btn sm ghost icon" title="Ubah" data-zm="edit" data-node="${esc(m.node)}">${ic("edit")}</button>`;
      return `<tr class="${!m.authorized ? "zt-wait" : ""}${m.role !== "vps" ? " zt-tap" : ""}" data-node="${esc(m.node)}">
        <td><div class="zt-dev"><span class="zt-av ${av}">${ic(av === "vps" ? "shield" : av === "router" ? "router" : "box")}</span><div style="min-width:0">
          <div class="zt-nm">${m.role === "router" ? `<a href="#/router/${esc(m.siteId)}">${esc(m.name)}</a> <span class="tag">Router</span>` : m.role === "vps" ? `VPS <span class="tag gray">panel ini</span>` : m.name ? esc(m.name) : `<span class="muted">Tanpa nama</span>`}</div>
          <div class="muted zt-small mono zt-nodesm">${esc(m.node)} · ${esc((m.ips || [])[0] || "—")}</div>
          ${m.note ? `<div class="muted zt-small zt-note">${esc(m.note)}</div>` : m.created && m.role === "other" ? `<div class="muted zt-small">bergabung ${ztAgo(m.created)}</div>` : ""}</div></div></td>
        <td class="zt-colnode"><span class="mono">${esc(m.node)}</span>${copyBtn(m.node, "Node ID tersalin")}</td>
        <td class="mono zt-colnode">${esc((m.ips || []).join(", ") || "—")}</td>
        <td class="hide-sm">${conn}</td>
        <td>${st}</td>
        <td class="r zt-act">${act}</td></tr>`;
    }).join("") || `<tr><td colspan="6"><div class="empty" style="padding:26px 10px">${ZTV.q || ZTV.f !== "all" ? "Tidak ada perangkat yang cocok." : "Belum ada perangkat di jaringan ini."}</div></td></tr>`;
    paintIcons($("#ztRows"));
    $("#ztRows").querySelectorAll("[data-zm]").forEach((btn) => (btn.onclick = (e) => { e.stopPropagation(); ztMemberAct(btn, members.find((x) => x.node === btn.dataset.node), cur, b); }));
    // Layar kecil: kolom aksi disembunyikan, ketuk baris untuk membuka detail perangkat
    $("#ztRows").querySelectorAll("tr.zt-tap").forEach((tr) => (tr.onclick = (e) => {
      if (window.innerWidth > 720 || e.target.closest("a,button")) return;
      ztMemberAct({ dataset: { zm: "edit" } }, members.find((x) => x.node === tr.dataset.node), cur, b);
    }));
  };
  $("#ztQ").addEventListener("input", (e) => { ZTV.q = e.target.value; fill(); });
  b.querySelectorAll("[data-zf]").forEach((c) => (c.onclick = () => { ZTV.f = c.dataset.zf; b.querySelectorAll("[data-zf]").forEach((x) => x.classList.toggle("on", x === c)); fill(); }));
  fill();
  const sp = $("#ztShowPend"); if (sp) sp.onclick = () => { ZTV.f = "wait"; ZTV.q = ""; setZerotier(b).then(() => { const el = $("#ztMembers"); if (el) el.scrollIntoView({ behavior: "smooth", block: "start" }); }); };
  $("#ztSet").onclick = () => ztSettingsDialog(cur, b);
  $("#ztLeave").onclick = () => confirmDialog({
    title: "Lepas VPS dari jaringan ini?", danger: true, icon: "hub", ok: "Lepas",
    text: `<p>VPS keluar dari jaringan <b>${esc(cur.name || cur.nwid)}</b>. Jaringan dan perangkatnya tetap tersimpan di controller dan bisa dihubungkan lagi. Router yang memakai ZeroTier harus dipindah ke L2TP atau dihapus dulu.</p>`,
    onOk: async () => { await api("/api/zt/leave", { method: "POST" }); await load(); closeModal(); setZerotier(b); toast("VPS dilepas dari jaringan ZeroTier"); },
  });
  ztBindNets(b, z);
  ztBindZtnet(b);
  paintIcons(b);
}
function ztNetRow(n, o) {
  return `<li class="zt-net${n.current ? " cur" : ""}">
    <span class="zt-nic">${ic("hub")}</span>
    <div class="zt-nb"><b>${esc(n.name || "(tanpa nama)")}</b> ${n.current ? `<span class="pill info">Dipakai panel</span>` : ""}
      <div class="muted zt-small"><span class="mono">${esc(n.nwid)}</span> · ${n.subnet ? `<span class="mono">${esc(n.subnet)}</span>` : "tanpa rentang"} · ${n.members} perangkat · ${n.private ? "private" : "public"}</div>
      ${n.conflict ? `<div class="zt-small" style="color:var(--bad);margin-top:2px">${esc(n.conflict)}</div>` : ""}</div>
    <div class="zt-na">${!n.current && o.canUse ? `<button class="btn sm pri" data-zuse="${esc(n.nwid)}" ${n.conflict ? "disabled" : ""}>Hubungkan VPS</button>` : ""}
      ${!n.current ? `<button class="btn sm ghost icon danger" title="Hapus jaringan" data-zdel="${esc(n.nwid)}" data-name="${esc(n.name || n.nwid)}" data-n="${n.members}">${ic("trash")}</button>` : ""}</div></li>`;
}
function ztBindNets(b, z) {
  b.querySelectorAll("[data-zuse]").forEach((btn) => (btn.onclick = async () => {
    busyBtn(btn, true);
    try {
      const r = await api("/api/zt/use", { method: "POST", body: { nwid: btn.dataset.zuse } });
      await load(); setZerotier(b);
      doneDialog("VPS tersambung ke ZeroTier", `<p>IP ZeroTier VPS: <b class="mono">${esc(r.vpsIp)}</b> (rentang ${esc(r.subnet)}).</p>${r.ready ? "" : "<p>Interface ZeroTier di VPS belum siap. Tunggu sebentar, lalu muat ulang.</p>"}<p>Sekarang jalur <b>ZeroTier</b> bisa dipilih saat menambah router.</p>`, "ok", false);
    } catch (e) { busyBtn(btn, false); toast(e.message); }
  }));
  b.querySelectorAll("[data-zdel]").forEach((btn) => (btn.onclick = () => confirmDialog({
    title: `Hapus jaringan ${esc(btn.dataset.name)}?`, danger: true, ok: "Hapus jaringan", wide: true,
    text: `<p>Jaringan <b class="mono">${esc(btn.dataset.zdel)}</b> dihapus dari controller beserta ${esc(btn.dataset.n)} perangkatnya. Perangkat yang masih memakai Network ID ini akan terputus.</p>`,
    check: "Saya mengerti jaringan ini tidak bisa dikembalikan",
    onOk: async () => { await api(`/api/zt/networks/${btn.dataset.zdel}`, { method: "DELETE" }); closeModal(); await load(); setZerotier(b); toast("Jaringan dihapus"); },
  })));
}
function ztBindZtnet(b) {
  const g = $("#ztnetGo");
  if (!g) return;
  g.onclick = () => confirmDialog({
    title: "Pindahkan dari ZTNET?", icon: "hub", ok: "Pindahkan & lepas", wide: true,
    text: `<p>Panel akan:</p><ol class="ol" style="margin:8px 0 0 18px"><li>menyalin nama &amp; catatan perangkat dari ZTNET ke panel,</li><li>menghentikan dan menghapus ZTNET (<code>/opt/ztnet</code>, port 3300).</li></ol>
      <p style="margin-top:10px">Jaringan, perangkat, dan IP ZeroTier <b>tidak berubah</b>: semuanya tersimpan di controller ZeroTier, bukan di ZTNET.</p>
      <label class="check" style="margin-top:12px"><input type="checkbox" id="ztnetDb"> Hapus juga database ZTNET (PostgreSQL dihapus bila tidak dipakai aplikasi lain)</label>`,
    onOk: async () => { const dropDb = !!($("#ztnetDb") && $("#ztnetDb").checked); await api("/api/zt/ztnet-remove", { method: "POST", body: { dropDb } }); openJob(() => { if (location.hash.startsWith("#/zerotier")) setZerotier($("#ztBody")); }); },
  });
}
function ztCreateDialog(z, b) {
  const first = !z.current;
  modal("Buat jaringan ZeroTier", `
    <p class="help" style="margin-top:0">Jaringan dibuat di controller ZeroTier VPS ini. Router MikroTik bergabung dengan Network ID-nya lewat script dari panel.</p>
    <label for="zcName">Nama jaringan</label>
    <input id="zcName" type="text" maxlength="64" value="${esc(first ? (STATE.settings.panelName || "ACS") + " ZeroTier" : "")}" placeholder="contoh: ACS Flores">
    <label for="zcSub">Rentang IP</label>
    <input id="zcSub" type="text" class="mono" value="${esc(z.suggest || "172.27.0.0/24")}" placeholder="172.27.0.0/24">
    <div class="help">IP private ukuran /16 sampai /29. Saran ${esc(z.suggest || "")} tidak bentrok dengan jaringan lain di panel. IP perangkat dibagikan otomatis dari rentang ini.</div>
    <label>Akses</label>
    <div class="seg"><label><input type="radio" name="zcPriv" value="1" checked>Private <span class="muted" style="font-weight:400">· disarankan</span></label><label><input type="radio" name="zcPriv" value="0">Public</label></div>
    ${first ? `<label class="check" style="margin-top:16px"><input type="checkbox" id="zcConn" checked> Langsung hubungkan VPS ke jaringan ini</label>` : ""}
    <div class="err" id="zcErr"></div>`,
    `<button class="btn" data-act="closemodal">Batal</button><button class="btn pri" id="zcOk">${ic("plus")}Buat jaringan</button>`);
  $("#zcOk").onclick = async () => {
    $("#zcErr").textContent = ""; busyBtn($("#zcOk"), true);
    try {
      const r = await api("/api/zt/networks", { method: "POST", body: { name: $("#zcName").value, subnet: $("#zcSub").value.trim(), private: document.querySelector("input[name=zcPriv]:checked").value === "1", connect: !!($("#zcConn") && $("#zcConn").checked) } });
      await load(); setZerotier(b);
      if (r.connected) doneDialog("Jaringan dibuat & VPS tersambung", `<p>Network ID <b class="mono">${esc(r.nwid)}</b>, IP VPS <b class="mono">${esc(r.vpsIp)}</b>.</p><p>Sekarang jalur <b>ZeroTier</b> bisa dipilih saat menambah router.</p>`, "ok", false);
      else if (r.connectError) doneDialog("Jaringan dibuat", `<p>Network ID <b class="mono">${esc(r.nwid)}</b>. VPS belum bisa dihubungkan: ${esc(r.connectError)}</p>`, "info", false);
      else doneDialog("Jaringan dibuat", `<p>Network ID <b class="mono">${esc(r.nwid)}</b>.</p>`);
    } catch (e) { $("#zcErr").textContent = e.message; busyBtn($("#zcOk"), false); }
  };
}
function ztSettingsDialog(cur, b) {
  const dns = cur.dns || { domain: "", servers: [] };
  modal("Pengaturan jaringan", `
    <div class="zt-sec"><h3>Umum</h3>
      <label for="zsName">Nama jaringan</label>
      <input id="zsName" type="text" maxlength="64" value="${esc(cur.name || "")}">
      <label>Akses</label>
      <div class="seg"><label><input type="radio" name="zsPriv" value="1" ${cur.private ? "checked" : ""}>Private</label><label><input type="radio" name="zsPriv" value="0" ${cur.private ? "" : "checked"}>Public</label></div>
      <div class="help" id="zsPrivHelp"></div></div>
    <div class="zt-sec"><h3>Alamat IP</h3>
      <label for="zsSub">Rentang IP</label>
      <input id="zsSub" type="text" class="mono" value="${esc(cur.subnet)}">
      <div class="note warn zt-subwarn hidden" id="zsSubWarn">${ic("alert")}<div><b>Semua IP ZeroTier akan dipindah</b>VPS, router, dan perangkat lain otomatis mendapat IP di rentang baru, dan rute ikut diperbarui. Bila IP VPS berubah, router ZeroTier ditandai untuk memasang ulang script MikroTik.</div></div>
      <div class="zt-2col">
        <div><label for="zsPs">Pool awal</label><input id="zsPs" type="text" class="mono" value="${esc(cur.poolStart || "")}"></div>
        <div><label for="zsPe">Pool akhir</label><input id="zsPe" type="text" class="mono" value="${esc(cur.poolEnd || "")}"></div>
      </div>
      <div class="help">IP otomatis untuk perangkat baru diambil dari pool. Kosongkan keduanya untuk memakai seluruh rentang.</div></div>
    <div class="zt-sec"><h3>DNS <span class="muted" style="font-weight:400;font-size:12.5px">opsional</span></h3>
      <div class="zt-2col">
        <div><label for="zsDd">Domain</label><input id="zsDd" type="text" value="${esc(dns.domain)}" placeholder="zt.lokal"></div>
        <div><label for="zsDs">Server DNS</label><input id="zsDs" type="text" class="mono" value="${esc((dns.servers || []).join(", "))}" placeholder="${esc(cur.vpsIp)}"></div>
      </div>
      <div class="help">Dikirim ke perangkat yang mengizinkan DNS dari ZeroTier. Biarkan kosong bila tidak dipakai.</div></div>
    <div class="err" id="zsErr"></div>`,
    `<button class="btn" data-act="closemodal">Batal</button><button class="btn pri" id="zsOk">Simpan</button>`, { size: "lg" });
  const help = () => {
    const pub = document.querySelector("input[name=zsPriv]:checked").value === "0";
    $("#zsPrivHelp").innerHTML = pub ? `<span style="color:var(--bad)"><b>Tidak disarankan.</b> Siapa pun yang tahu Network ID bisa bergabung tanpa persetujuan dan masuk ke jaringan GenieACS Anda.</span>` : "Perangkat baru harus disetujui di panel. Router yang dipasang dari panel disetujui otomatis.";
  };
  document.querySelectorAll("input[name=zsPriv]").forEach((r) => (r.onchange = help)); help();
  $("#zsSub").addEventListener("input", () => {
    const ch = $("#zsSub").value.trim() !== cur.subnet;
    $("#zsSubWarn").classList.toggle("hidden", !ch);
    if (ch) { $("#zsPs").value = ""; $("#zsPe").value = ""; }
  });
  $("#zsOk").onclick = async () => {
    $("#zsErr").textContent = ""; busyBtn($("#zsOk"), true);
    try {
      const r = await api("/api/zt/network", { method: "PUT", body: {
        name: $("#zsName").value, private: document.querySelector("input[name=zsPriv]:checked").value === "1",
        subnet: $("#zsSub").value.trim(), poolStart: $("#zsPs").value.trim(), poolEnd: $("#zsPe").value.trim(),
        dns: { domain: $("#zsDd").value.trim(), servers: $("#zsDs").value.trim() } } });
      await load(); setZerotier(b);
      if (r.error) doneDialog("Disimpan, tetapi ada masalah", `<p>${esc(r.error)}</p>`, "bad", false);
      else if ((r.notes || []).length) doneDialog("Jaringan disimpan", `<p>Disesuaikan otomatis:</p><ul style="margin:6px 0 0 18px;line-height:1.7">${r.notes.map((n) => `<li>${esc(n)}</li>`).join("")}</ul>`, "ok", false);
      else { closeModal(); toast(r.changed ? "Pengaturan jaringan disimpan" : "Tidak ada perubahan"); }
    } catch (e) { $("#zsErr").textContent = e.message; busyBtn($("#zsOk"), false); }
  };
}
async function ztMemberAct(btn, m, cur, b) {
  if (!m) return;
  const label = m.name || m.node;
  const save = async (bodyData, msg) => { await api(`/api/zt/member/${m.node}`, { method: "POST", body: bodyData }); await load(); setZerotier(b); toast(msg); };
  if (btn.dataset.zm === "auth") {
    busyBtn(btn, true);
    try { await save({ authorized: true }, `${label} disetujui`); } catch (e) { busyBtn(btn, false); toast(e.message); }
    return;
  }
  const isRouter = m.role === "router";
  modal(`Perangkat <span class="mono" style="font-weight:500">${esc(m.node)}</span>`, `
    <div class="zt-mhead"><span class="zt-av ${isRouter ? "router" : "dev"}">${ic(isRouter ? "router" : "box")}</span><div>
      <b>${isRouter ? esc(m.name) : esc(m.name || "Tanpa nama")}</b>
      <div class="muted zt-small">${m.authorized ? (m.online ? "Online" : "Offline") : "Menunggu persetujuan"}${m.physical ? ` · ${esc(m.physical)}` : ""}${m.latency != null ? ` · ${m.latency} ms` : ""}${m.version ? ` · ZeroTier ${esc(m.version)}` : ""}</div></div></div>
    <label for="zeName">Nama</label>
    <input id="zeName" type="text" maxlength="64" value="${esc(isRouter ? m.name : m.name || "")}" ${isRouter ? "disabled" : ""} placeholder="contoh: Laptop teknisi">
    ${isRouter ? `<div class="help">Nama mengikuti router di panel. Ubah di halaman <a href="#/router/${esc(m.siteId)}">router</a>.</div>` : ""}
    <label for="zeNote">Catatan</label>
    <textarea id="zeNote" class="zt-ta" rows="2" maxlength="200" placeholder="opsional">${esc(m.note || "")}</textarea>
    <label for="zeIp">IP ZeroTier</label>
    <input id="zeIp" type="text" class="mono" value="${esc((m.ips || [])[0] || "")}">
    <div class="help">Di dalam rentang ${esc(cur.subnet)} dan belum dipakai perangkat lain.${isRouter ? " Rute IP virtual router ini ikut diperbarui otomatis, script MikroTik tidak perlu dipasang ulang." : ""}</div>
    <label>Izin</label>
    <div class="seg"><label><input type="radio" name="zeAuth" value="1" ${m.authorized ? "checked" : ""}>Disetujui</label><label><input type="radio" name="zeAuth" value="0" ${m.authorized ? "" : "checked"}>Tidak disetujui</label></div>
    <div class="help" id="zeAuthHelp"></div>
    <div class="err" id="zeErr"></div>`,
    `${isRouter ? "" : `<button class="btn ghost danger" id="zeDel" style="margin-right:auto">${ic("trash")}Hapus perangkat</button>`}<button class="btn" data-act="closemodal">Batal</button><button class="btn pri" id="zeOk">Simpan</button>`, { size: "md" });
  const ah = () => {
    const off = document.querySelector("input[name=zeAuth]:checked").value === "0";
    $("#zeAuthHelp").innerHTML = off && m.authorized ? `<span style="color:var(--bad)">${isRouter ? `Router <b>${esc(m.name)}</b> akan terputus dari VPS: GenieACS tidak bisa menjangkau ONT dan port forwarding berhenti.` : "Perangkat ini tidak bisa memakai jaringan sampai disetujui lagi."}</span>` : "";
  };
  document.querySelectorAll("input[name=zeAuth]").forEach((r) => (r.onchange = ah)); ah();
  $("#zeOk").onclick = async () => {
    $("#zeErr").textContent = ""; busyBtn($("#zeOk"), true);
    const bodyData = { note: $("#zeNote").value, authorized: document.querySelector("input[name=zeAuth]:checked").value === "1" };
    if (!isRouter) bodyData.name = $("#zeName").value;
    const ip = $("#zeIp").value.trim();
    if (ip && ip !== ((m.ips || [])[0] || "")) bodyData.ip = ip;
    try { await save(bodyData, "Perangkat disimpan"); closeModal(); } catch (e) { $("#zeErr").textContent = e.message; busyBtn($("#zeOk"), false); }
  };
  const del = $("#zeDel");
  if (del) del.onclick = () => confirmDialog({
    title: `Hapus ${esc(label)} dari jaringan?`, danger: true, ok: "Hapus",
    text: `<p>Perangkat <span class="mono">${esc(m.node)}</span> dihapus dari controller beserta IP-nya. Bila perangkat itu masih mencoba bergabung, ia muncul lagi sebagai <b>menunggu persetujuan</b>${cur.private ? "" : " (atau langsung masuk, karena jaringan ini public)"}.</p>`,
    onOk: async () => { await api(`/api/zt/member/${m.node}`, { method: "DELETE" }); closeModal(); await load(); setZerotier(b); toast("Perangkat dihapus"); },
  });
}

/* ---------- Telegram ---------- */
let TGDET = null; // hasil deteksi grup & topik
function setTelegram(b) {
  const t = STATE.settings.telegram || {};
  const st = !t.tokenSet ? { c: "info", i: "info", h: "Belum diatur", d: "Ikuti langkah di bawah untuk mengirim notifikasi VPN terputus ke grup Telegram." }
    : !t.enabled ? { c: "warn", i: "alert", h: "Notifikasi nonaktif", d: "Centang \"Aktifkan notifikasi\" lalu simpan." }
    : t.lastError ? { c: "bad", i: "alert", h: "Pengiriman terakhir gagal", d: t.lastError }
    : { c: "ok", i: "check", h: "Notifikasi aktif", d: `Dikirim ke ${t.chatTitle || t.chatId}${t.threadName ? " › " + t.threadName : ""}${t.lastOk ? ` · terakhir terkirim ${fmtT(t.lastOk, true)}` : ""}` };
  const quiet = !!(t.quietStart && t.quietEnd);
  b.innerHTML = `
    <div class="note ${st.c}">${ic(st.i)}<div><b>${esc(st.h)}</b>${esc(st.d)}</div></div>
    <div class="card"><div class="ch"><h2>Bot &amp; grup tujuan</h2></div><div class="cb" style="padding-top:6px">
      <details class="more" style="margin:4px 0 6px"><summary>Cara menyiapkan bot dan grup</summary>
        <ol class="ol" style="margin-top:12px">
          <li><b>Buat bot</b>Di Telegram buka <b>@BotFather</b> → kirim <code>/newbot</code> → ikuti petunjuk → salin token yang diberikan.</li>
          <li><b>Siapkan grup</b>Buat grup → Info grup → Edit → aktifkan <b>Topik (Topics)</b> → buat topik, misalnya "🔴 VPN".</li>
          <li><b>Masukkan bot</b>Tambahkan bot ke grup, lalu jadikan <b>admin</b>.</li>
          <li><b>Bot bekas aplikasi lain?</b>Jika bot pernah dipakai aplikasi lain (webhook), klik <b>Hapus webhook</b> dulu.</li>
          <li><b>Kirim pesan di topik tujuan</b>Kirim pesan apa saja (misalnya "tes") di topik tersebut, lalu klik <b>Deteksi grup &amp; topik</b> di bawah.</li>
        </ol></details>
      <label for="tgTok">Token bot</label>
      <input id="tgTok" type="password" autocomplete="off" placeholder="${t.tokenSet ? `Tersimpan (${esc(t.tokenMask)}) — kosongkan jika tidak diganti` : "contoh: 123456789:AAHxxxxxxxxxxxxxxxxxxxxxxxxxxxx"}">
      <div class="form-actions" style="margin-top:10px"><button class="btn" id="tgDetect">${ic("search")}Deteksi grup &amp; topik</button><button class="btn ghost" id="tgHook" title="Lepas bot dari aplikasi lain yang memakai webhook">${ic("x")}Hapus webhook</button><span class="help" id="tgBot" style="margin:auto 0">${t.botName ? "Bot: @" + esc(t.botName) : ""}</span></div>
      <div class="f2">
        <div><label for="tgChat">Grup</label><select id="tgChat"></select></div>
        <div><label for="tgThread">Topik</label><select id="tgThread"></select></div>
      </div>
      <div class="help">Grup atau topik tidak muncul? Pastikan bot sudah admin, kirim pesan di topik itu, lalu klik Deteksi lagi.</div>
    </div></div>
    <div class="card"><div class="ch"><h2>Aturan notifikasi</h2></div><div class="cb" style="padding-top:6px">
      <label class="check" style="margin-top:10px"><input id="tgOn" type="checkbox" ${t.enabled !== false ? "checked" : ""}>Aktifkan notifikasi VPN terputus</label>
      <div class="help">Router berstatus "Menunggu pemasangan" tidak pernah dikirim notifikasi.</div>
      <div class="f2">
        <div><label for="tgDelay">Jeda sebelum lapor (menit)</label><input id="tgDelay" type="number" min="1" max="1440" value="${t.delayMin || 3}">
          <div class="help">VPN harus putus selama ini dulu, supaya putus sebentar tidak dilaporkan.</div></div>
        <div><label for="tgRemind">Ingatkan lagi jika masih putus (menit)</label><input id="tgRemind" type="number" min="0" max="1440" value="${t.remindMin ?? 60}">
          <div class="help">Isi 0 untuk mematikan. Minimal 10.</div></div>
      </div>
      <label class="check" style="margin-top:16px"><input id="tgRec" type="checkbox" ${t.notifyRecovery !== false ? "checked" : ""}>Kirim juga saat tersambung lagi (beserta lama putusnya)</label>
      <label class="check" style="margin-top:12px"><input id="tgQuiet" type="checkbox" ${quiet ? "checked" : ""}>Jam tenang (pesan tetap terkirim tanpa bunyi)</label>
      <div class="f2 ${quiet ? "" : "hidden"}" id="tgQuietBox">
        <div><label for="tgQs">Mulai</label><input id="tgQs" type="time" value="${esc(t.quietStart || "22:00")}"></div>
        <div><label for="tgQe">Selesai</label><input id="tgQe" type="time" value="${esc(t.quietEnd || "06:00")}"></div>
      </div>
      <div class="help">Zona waktu: ${esc(tzLabel())} (ubah di tab <a href="#/pengaturan/umum">Umum</a>).</div>
      <div class="err" id="tgErr"></div>
      <div class="form-actions">
        <button class="btn pri" id="tgSave">Simpan</button>
        <button class="btn" id="tgTest">${ic("send")}Kirim pesan tes</button>
        <span class="sp"></span>
        ${t.tokenSet ? `<button class="btn ghost danger" id="tgClear">${ic("trash")}Hapus Telegram</button>` : ""}
      </div>
    </div></div>`;
  const chatSel = $("#tgChat"), thrSel = $("#tgThread");
  const chats = () => {
    const list = TGDET ? TGDET.chats.slice() : [];
    if (t.chatId && !list.some((c) => c.id === t.chatId)) list.unshift({ id: t.chatId, title: t.chatTitle || t.chatId, isForum: !!t.threadId, topics: t.threadId ? [{ id: t.threadId, name: t.threadName }] : [], saved: true });
    return list;
  };
  const fillChats = (want) => {
    const list = chats();
    if (!list.length) { chatSel.innerHTML = `<option value="">— klik Deteksi dulu —</option>`; chatSel.disabled = true; fillThreads(); return; }
    chatSel.disabled = false;
    chatSel.innerHTML = list.map((c) => `<option value="${esc(c.id)}">${esc(c.title)}${c.isForum ? "" : " (tanpa topik)"}</option>`).join("");
    chatSel.value = list.some((c) => c.id === want) ? want : list[0].id;
    fillThreads(t.chatId === chatSel.value ? t.threadId : 0);
  };
  const fillThreads = (want) => {
    const c = chats().find((x) => x.id === chatSel.value);
    if (!c) { thrSel.innerHTML = `<option value="0">—</option>`; thrSel.disabled = true; return; }
    if (!c.isForum) { thrSel.innerHTML = `<option value="0">Grup tanpa topik</option>`; thrSel.disabled = true; return; }
    const tp = c.topics.slice();
    if (want && !tp.some((x) => x.id === want)) tp.push({ id: want, name: t.threadName || `Topik #${want}` });
    thrSel.disabled = false;
    thrSel.innerHTML = `<option value="0">Umum (General)</option>` + tp.map((x) => `<option value="${x.id}">${esc(x.name)}</option>`).join("");
    thrSel.value = String(want || (tp[0] ? tp[0].id : 0));
  };
  chatSel.onchange = () => fillThreads(0);
  fillChats(t.chatId);
  $("#tgQuiet").onchange = () => $("#tgQuietBox").classList.toggle("hidden", !$("#tgQuiet").checked);
  const body = () => {
    const c = chats().find((x) => x.id === chatSel.value);
    const th = parseInt(thrSel.value, 10) || 0;
    return {
      token: $("#tgTok").value.trim(),
      botName: TGDET ? TGDET.bot.username : undefined,
      chatId: chatSel.disabled ? "" : chatSel.value,
      chatTitle: c ? c.title : "",
      threadId: th,
      threadName: th ? thrSel.options[thrSel.selectedIndex].text : "",
      enabled: $("#tgOn").checked,
      delayMin: $("#tgDelay").value,
      remindMin: $("#tgRemind").value,
      notifyRecovery: $("#tgRec").checked,
      quietStart: $("#tgQuiet").checked ? $("#tgQs").value : "",
      quietEnd: $("#tgQuiet").checked ? $("#tgQe").value : "",
    };
  };
  $("#tgDetect").onclick = async () => {
    const btn = $("#tgDetect"); $("#tgErr").textContent = ""; busyBtn(btn, true);
    try {
      TGDET = await api("/api/telegram/detect", { method: "POST", body: { token: $("#tgTok").value.trim() } });
      $("#tgBot").textContent = "Bot: @" + TGDET.bot.username;
      fillChats(chatSel.value || t.chatId);
      toast(TGDET.chats.length ? `${TGDET.chats.length} grup ditemukan` : "Belum ada grup. Masukkan bot ke grup dan kirim pesan di sana.");
    } catch (e) {
      busyBtn(btn, false);
      if (e.data && e.data.webhook) return hookFlow(true);
      $("#tgErr").textContent = e.message;
    }
    busyBtn(btn, false);
  };
  // Hapus webhook: tampilkan dulu ke mana bot sedang terhubung, lalu minta konfirmasi
  const hookFlow = async (fromDetect) => {
    const token = $("#tgTok").value.trim(), btn = $("#tgHook");
    $("#tgErr").textContent = ""; busyBtn(btn, true);
    let info;
    try { info = await api("/api/telegram/webhook", { method: "POST", body: { token } }); }
    catch (e) { busyBtn(btn, false); $("#tgErr").textContent = e.message; return; }
    busyBtn(btn, false);
    if (!info.url) return doneDialog("Tidak ada webhook", "Bot ini tidak memakai webhook, jadi bisa langsung dipakai panel. Klik Deteksi grup &amp; topik.", "info", false);
    confirmDialog({
      title: "Hapus webhook bot?", danger: true, icon: "alert", ok: "Hapus webhook",
      text: `${fromDetect ? "<p>Grup tidak bisa dideteksi karena bot ini masih memakai webhook.</p>" : ""}
        <p>Bot sedang terhubung ke:<br><span class="mono" style="word-break:break-all">${esc(info.url.replace(/\d{5,}:[A-Za-z0-9_-]{30,}/g, "•••"))}</span></p>
        <p>Jika dihapus, aplikasi tersebut <b>berhenti menerima pesan</b> dari bot ini. Lanjutkan hanya jika bot itu memang akan dipakai untuk panel.</p>`,
      onOk: async () => {
        await api("/api/telegram/delete-webhook", { method: "POST", body: { token } });
        doneDialog("Webhook dihapus", "Bot siap dipakai panel. Kirim pesan di topik tujuan, lalu klik Deteksi grup &amp; topik.", "ok", false);
      },
    });
  };
  $("#tgHook").onclick = () => hookFlow(false);
  $("#tgTest").onclick = async () => {
    const btn = $("#tgTest"); $("#tgErr").textContent = ""; busyBtn(btn, true);
    try { await api("/api/telegram/test", { method: "POST", body: body() }); busyBtn(btn, false); doneDialog("Pesan tes terkirim", "Cek grup Telegram Anda. Jika sudah masuk, klik Simpan."); }
    catch (e) { busyBtn(btn, false); doneDialog("Pesan tes gagal", esc(e.message), "bad", false); }
  };
  $("#tgSave").onclick = async () => {
    const btn = $("#tgSave"); $("#tgErr").textContent = ""; busyBtn(btn, true);
    try { await api("/api/telegram", { method: "PUT", body: body() }); await load(); route(); doneDialog("Pengaturan Telegram disimpan", ""); }
    catch (e) { $("#tgErr").textContent = e.message; busyBtn(btn, false); }
  };
  const clr = $("#tgClear");
  if (clr) clr.onclick = () => {
    confirmDialog({
      title: "Hapus pengaturan Telegram?", danger: true, ok: "Hapus",
      text: "Token bot dan grup tujuan dihapus dari panel. Notifikasi berhenti dikirim.",
      onOk: async () => { await api("/api/telegram", { method: "PUT", body: { clear: true } }); TGDET = null; await load(); route(); doneDialog("Pengaturan Telegram dihapus", ""); },
    });
  };
}

/* ---------- Domain & HTTPS (Cloudflare) ---------- */
let CF = null; // proses verifikasi yang sedang berjalan
function stepsHtml(plan, res, current) {
  return plan.map((s, i) => {
    const r = res[s.key];
    const st = !r ? (current === s.key ? "run" : "wait") : r.ok === true ? "ok" : r.ok === false ? "fail" : "skip";
    const icon = st === "ok" ? ic("check", "") : st === "fail" ? ic("x", "") : st === "skip" ? ic("minus", "") : st === "run" ? "" : i + 1;
    return `<li class="step ${st}"><span class="sic">${icon}</span><span class="stx"><b>${esc(s.label)}</b><small>${esc(s.desc)}</small>
      ${r ? `<div class="sres">${esc(r.detail || "")}${r.hint && r.ok === false ? `<span class="hint">${esc(r.hint)}</span>` : ""}</div>` : st === "run" ? `<div class="sres muted">Memeriksa…</div>` : ""}</span>
      ${r && r.ms != null ? `<span class="tm">${(r.ms / 1000).toFixed(1)} dtk</span>` : ""}</li>`;
  }).join("");
}
function setDomain(b) {
  const c = STATE.settings.cloudflare, port = STATE.settings.port || 8088;
  const onHttps = location.protocol === "https:";
  b.innerHTML = `
    ${c ? `<div class="card"><div class="ch"><h2>Domain aktif</h2><span class="pill ok">Terhubung</span></div>
      <div class="kv"><span>Domain</span><b>${esc(c.domain)}</b></div>
      <div class="kv"><span>Mengarah ke</span><b>${esc(c.ip || "—")} · DNS only</b></div>
      <div class="kv"><span>HTTPS panel</span><b>${c.https ? (c.httpsActive ? "Aktif" : "Belum aktif") + (c.certExpiry ? ` · berlaku s/d ${esc(fmtT(c.certExpiry, true))}` : "") : "Tidak dipakai"}</b></div>
      <div class="kv"><span>Diterapkan</span><b>${esc(fmtT(Date.parse(c.appliedAt), true))}</b></div>
      ${c.https && c.httpsActive && !onHttps ? `<div class="cb" style="border-top:1px solid var(--line)"><a class="btn pri" href="https://${esc(c.domain)}:${port}/">${ic("lock")}Buka panel lewat HTTPS</a></div>` : ""}
      <div class="cb" style="border-top:1px solid var(--line);display:flex;gap:8px;flex-wrap:wrap">
        <button class="btn" id="cfAgain">${ic("refresh")}Verifikasi ulang</button>
        <span style="flex:1"></span>
        <button class="btn ghost danger" id="cfRemove">Lepas domain</button>
      </div></div>
    <div class="card"><div class="ch"><h2>Subdomain layanan</h2></div><form class="cb" id="subForm" style="padding-top:6px">
      <p class="help" style="margin-top:4px">Panel membuat record DNS (DNS only) untuk GenieACS di <b>${esc(c.zoneName)}</b>, lalu memasang link-nya di dashboard. Nama subdomain bisa diganti kapan saja; record lama buatan panel ikut dihapus.</p>
      ${[["acs", "GenieACS", 3000, "acs"]].map(([k, L, port, def]) => {
        const cur = (c.subdomains || {})[k];
        const val = cur ? cur.host.slice(0, -(c.zoneName.length + 1)) : def;
        return `<label class="check" style="margin-top:14px"><input type="checkbox" id="subOn_${k}" ${cur || !c.subdomains || !Object.keys(c.subdomains).length ? "checked" : ""}>${L}</label>
          <div style="display:flex;align-items:center;gap:8px;margin-top:6px"><input id="sub_${k}" type="text" value="${esc(val)}" style="max-width:200px"><span class="mono muted">.${esc(c.zoneName)}:${port}</span></div>
          ${cur ? `<div class="help">Aktif: <a class="ext" href="http://${esc(cur.host)}:${port}" target="_blank" rel="noopener">${esc(cur.host)}:${port}${ic("ext", "")}</a></div>` : ""}`;
      }).join("")}
      <div class="err" id="subErr"></div>
      <div class="form-actions"><button class="btn pri" id="subGo">${ic("play")}Terapkan subdomain</button></div>
    </form></div>` : ""}
    <div class="card" id="cfFormCard"><div class="ch"><h2>${c ? "Ganti domain" : "Hubungkan domain Cloudflare"}</h2></div><form class="cb" id="cfForm" style="padding-top:6px">
      <p class="help" style="margin-top:4px">Panel membuat record DNS yang mengarah ke VPS ini, lalu mengganti alamat VPS di script MikroTik menjadi domain. Setiap langkah diperiksa dulu. <b>Jika ada yang gagal, semua dibatalkan dan pengaturan tetap seperti semula.</b></p>
      <label for="cfDom">Domain / subdomain</label>
      <input id="cfDom" type="text" placeholder="contoh: vpn.domainanda.com" value="${esc(c ? c.domain : "")}">
      <label for="cfTok">API Token Cloudflare</label>
      <input id="cfTok" type="password" autocomplete="off" placeholder="${c ? "Tersimpan — kosongkan untuk memakai token yang sama" : "Tempel token dari Cloudflare"}">
      <details class="more"><summary>Cara membuat API Token</summary><ol class="ol" style="margin-top:12px">
        <li><b>Buka API Tokens</b>Cloudflare → ikon profil → <b>My Profile</b> → <b>API Tokens</b> → <b>Create Token</b>.</li>
        <li><b>Pilih template "Edit zone DNS"</b>Klik Use template.</li>
        <li><b>Tambah izin Zone Read</b>Di Permissions klik + Add more → <b>Zone → Zone → Read</b>. Hasilnya: Zone Read dan DNS Edit.</li>
        <li><b>Batasi ke domain Anda</b>Zone Resources: Include → Specific zone → pilih domain.</li>
        <li><b>Buat dan salin</b>Continue to summary → Create Token → salin token (hanya ditampilkan sekali). Jangan pakai Global API Key.</li>
      </ol></details>
      <label class="check" style="margin-top:16px"><input id="cfHttps" type="checkbox" ${!c || c.https ? "checked" : ""}>Pasang HTTPS untuk panel (sertifikat Let's Encrypt gratis, diperpanjang otomatis)</label>
      <div class="help">Panel akan dibuka lewat <span class="mono">https://domain:${port}</span>. VPN, GenieACS, dan Winbox tidak terpengaruh.</div>
      <div class="note info" style="margin:14px 0 0">${ic("info")}<div><b>Record dibuat dalam mode DNS only (awan abu-abu)</b>Proxy Cloudflare (awan oranye) tidak bisa meneruskan VPN L2TP dan Winbox, jadi panel otomatis mematikannya untuk domain ini.</div></div>
      <div class="err" id="cfErr"></div>
      <div class="form-actions"><button class="btn pri" id="cfGo">${ic("play")}Verifikasi &amp; terapkan</button></div>
    </form></div>
    <div class="card hidden" id="cfRun">
      <div class="tst-head"><div><h2 id="cfTitle">Memverifikasi</h2><p id="cfSub"></p></div></div>
      <div class="prog"><i id="cfProg"></i></div>
      <ol class="steps" id="cfSteps"></ol>
      <div id="cfSum"></div>
    </div>`;
  $("#cfForm").onsubmit = (e) => { e.preventDefault(); runCf($("#cfDom").value.trim(), $("#cfTok").value.trim(), $("#cfHttps").checked); };
  const sf = $("#subForm");
  if (sf) {
    const sync = (k) => { $("#sub_" + k).disabled = !$("#subOn_" + k).checked; };
    ["acs"].forEach((k) => { $("#subOn_" + k).onchange = () => sync(k); sync(k); });
    sf.onsubmit = (e) => {
      e.preventDefault(); $("#subErr").textContent = "";
      const body = {};
      ["acs"].forEach((k) => { body[k] = $("#subOn_" + k).checked ? $("#sub_" + k).value.trim() : ""; });
      if (!body.acs && !body.zt && !Object.keys(c.subdomains || {}).length) { $("#subErr").textContent = "Aktifkan minimal satu subdomain."; return; }
      runCf(c.zoneName, "", false, { path: "/api/cloudflare/subs", body, title: "subdomain", errEl: "#subErr" });
    };
  }
  if (c) {
    $("#cfAgain").onclick = () => runCf(c.domain, "", c.https);
    $("#cfRemove").onclick = () => {
      confirmDialog({
        title: "Lepas domain?", danger: true, icon: "globe", ok: "Lepas domain",
        text: `<p>Alamat VPS kembali ke <b>${esc(c.publicIpBefore || "IP publik (otomatis)")}</b> dan HTTPS panel dimatikan.</p><p>Record DNS di Cloudflare tidak dihapus, jadi MikroTik yang memakai domain tetap tersambung.</p>`,
        onOk: async () => {
          await api("/api/cloudflare/remove", { method: "POST" });
          if (location.protocol === "https:") { const ip = c.publicIpBefore || location.hostname; location.href = `http://${ip}:${port}/#/pengaturan/domain`; return; }
          await load(); route(); doneDialog("Domain dilepas", "Panel kembali memakai alamat IP.");
        },
      });
    };
  }
  if (CF && CF.plan) drawCf();
}
function drawCf() {
  const card = $("#cfRun"); if (!card || !CF) return;
  card.classList.remove("hidden");
  $("#cfSteps").innerHTML = stepsHtml(CF.plan, CF.res, CF.current);
  const n = Object.keys(CF.res).length;
  $("#cfProg").style.width = (CF.plan.length ? (n / CF.plan.length) * 100 : 0) + "%";
  $("#cfTitle").textContent = CF.running ? "Memverifikasi" : CF.ok ? "Berhasil diterapkan" : "Dibatalkan";
  $("#cfSub").textContent = CF.running ? `${CF.domain} · langkah ${Math.min(n + 1, CF.plan.length)} dari ${CF.plan.length}` : CF.domain;
  if (CF.running) { $("#cfSum").innerHTML = ""; return; }
  if (CF.ok) {
    $("#cfSum").innerHTML = CF.url
      ? `<div class="tst-sum ok" style="flex-wrap:wrap">${ic("check")}<span style="flex:1">Panel sekarang memakai HTTPS. Buka alamat baru lalu login lagi.</span><a class="btn pri" href="${esc(CF.url)}#/pengaturan/domain">${ic("lock")}Buka ${esc(CF.url.replace(/\/$/, ""))}</a></div>`
      : CF.sub ? `<div class="tst-sum ok">${ic("check")}Subdomain diterapkan. Link GenieACS di dashboard sudah memakai alamat baru.</div>`
      : `<div class="tst-sum ok">${ic("check")}Alamat VPS sekarang ${esc(CF.domain)}. Script MikroTik baru otomatis memakai domain ini.</div>`;
  } else {
    $("#cfSum").innerHTML = `<div class="tst-sum fail">${ic("alert")}${esc(CF.note || "Dibatalkan, pengaturan tetap seperti semula.")}</div>`;
  }
}
async function runCf(domain, token, withHttps, alt) {
  if (CF && CF.running) return;
  const errEl = (alt && alt.errEl) || "#cfErr";
  $(errEl).textContent = "";
  let r;
  try { r = await api(alt ? alt.path : "/api/cloudflare/start", { method: "POST", body: alt ? alt.body : { domain, token, https: withHttps } }); }
  catch (e) { $(errEl).textContent = e.message; return; }
  CF = { domain: alt ? "Subdomain layanan" : domain, sub: !!alt, plan: r.steps, jobId: r.jobId, res: {}, running: true, ok: false };
  $("#cfGo").disabled = true; const again = $("#cfAgain"); if (again) again.disabled = true; const sg = $("#subGo"); if (sg) sg.disabled = true;
  drawCf(); $("#cfRun").scrollIntoView({ behavior: "smooth", block: "start" });
  for (const s of CF.plan) {
    CF.current = s.key; drawCf();
    const t0 = performance.now();
    let x;
    try { x = await api("/api/cloudflare/step", { method: "POST", body: { jobId: CF.jobId, key: s.key } }); }
    catch (e) { x = { ok: false, detail: e.message }; }
    const el = performance.now() - t0; if (el < 450) await new Promise((z) => setTimeout(z, 450 - el));
    x.ms = performance.now() - t0; CF.res[s.key] = x; CF.current = null;
    if (x.ok === false) { CF.note = x.rollbackNote; break; }
    if (s.key === "apply") { CF.ok = true; CF.url = x.url; }
    if (s.key === "sapply") CF.ok = true;
  }
  CF.running = false; drawCf();
  const go = $("#cfGo"); if (go) go.disabled = false; const ag = $("#cfAgain"); if (ag) ag.disabled = false; const sg2 = $("#subGo"); if (sg2) sg2.disabled = false;
  // Setelah HTTPS aktif, akses http dialihkan, jadi data tidak dimuat ulang di halaman ini
  if (CF.ok && !CF.url) { await load(); const keep = CF; route(); CF = keep; drawCf(); }
}

/* ================= Log aktivitas ================= */
let LOGQ = "";
function viewLog(v) {
  crumb([["Log aktivitas"]]);
  v.innerHTML = `
    <div class="ph"><div><h1>Log aktivitas</h1><p>Catatan perubahan di panel dan kejadian penting. Disimpan 90 hari.</p></div></div>
    <div class="card">
      <div class="toolbar"><div class="search">${ic("search", "")}<input id="lq" type="text" placeholder="Cari aktivitas, router, atau IP" value="${esc(LOGQ)}"></div><span class="muted" id="logCount" style="margin-left:auto;font-size:12.5px"></span></div>
      <div id="logBody"><div class="empty"><p>Memuat…</p></div></div>
    </div>
    <p class="help" style="margin-top:12px">Password dan token tidak pernah dicatat. Waktu dalam ${esc(tzLabel())}.</p>`;
  let tm;
  $("#lq").addEventListener("input", (e) => { LOGQ = e.target.value; clearTimeout(tm); tm = setTimeout(fillLog, 250); });
  fillLog();
}
async function fillLog() {
  const el = $("#logBody"); if (!el) return;
  let r;
  try { r = await api("/api/activity?q=" + encodeURIComponent(LOGQ.trim())); } catch (e) { el.innerHTML = `<div class="empty"><p>${esc(e.message)}</p></div>`; return; }
  if (!$("#logBody")) return;
  $("#logCount").textContent = r.total > r.items.length ? `${r.items.length} dari ${r.total} terbaru` : `${r.total} catatan`;
  if (!r.items.length) { el.innerHTML = `<div class="empty"><p>${LOGQ ? "Tidak ada yang cocok." : "Belum ada aktivitas."}</p></div>`; return; }
  const bad = /gagal|diblokir|dibatalkan/i;
  el.innerHTML = `<table class="t"><thead><tr><th style="width:140px">Waktu</th><th>Aktivitas</th><th class="hide-sm" style="width:150px">Dari</th></tr></thead><tbody>
    ${r.items.map((x) => `<tr><td class="muted" style="white-space:nowrap">${esc(fmtT(x.t, true))}</td>
      <td><b style="font-weight:550;${bad.test(x.a) ? "color:var(--bad)" : ""}">${esc(x.a)}</b>${x.d ? `<div class="muted" style="font-size:12.5px;word-break:break-word">${esc(x.d)}</div>` : ""}</td>
      <td class="hide-sm mono muted">${x.ip === "sistem" ? "Sistem" : esc(x.ip)}</td></tr>`).join("")}
  </tbody></table>`;
}

/* ================= Aksi global ================= */
document.addEventListener("click", async (e) => {
  const cp = e.target.closest("[data-copy]");
  if (cp) { e.preventDefault(); copyText(cp.dataset.copy, cp.dataset.msg || undefined); return; }
  // Tutup menu yang terbuka bila klik di luar
  document.querySelectorAll(".menu-list:not(.hidden)").forEach((m) => { if (!m.parentElement.contains(e.target)) m.classList.add("hidden"); });
  const go = e.target.closest("[data-go]");
  if (go) { document.querySelectorAll(".menu-list").forEach((m) => m.classList.add("hidden")); if (location.hash === go.dataset.go || (go.dataset.go === "#/" && !location.hash)) route(); else location.hash = go.dataset.go; return; }
  const fl = e.target.closest("[data-filter]");
  if (fl) { LIST.f = fl.dataset.filter; document.querySelectorAll("[data-filter]").forEach((c) => c.classList.toggle("on", c === fl)); fillList(); return; }
  const a = e.target.closest("[data-act]");
  if (!a) return;
  const act = a.dataset.act;
  if (a.tagName === "A") e.preventDefault();
  const cur = (location.hash.match(/^#\/router\/([a-f0-9]{12})/) || [])[1];
  if (act === "theme") { toggleTheme(); }
  else if (act === "usermenu") $("#userList").classList.toggle("hidden");
  else if (act === "opennav") document.body.classList.add("nav-open");
  else if (act === "closenav") document.body.classList.remove("nav-open");
  else if (act === "closemodal") closeModal();
  else if (act === "logout") {
    $("#userList").classList.add("hidden");
    confirmDialog({ title: "Keluar dari panel?", icon: "logout", ok: "Keluar", text: "Anda perlu login lagi untuk membuka panel.",
      onOk: async () => { await api("/api/logout", { method: "POST" }).catch(() => {}); LOADED = false; closeModal(); showLogin(); } });
  }
  else if (act === "refresh") { const b = a; b.classList.add("spinning"); try { await load(); route(); toast("Status diperbarui"); } finally { b.classList.remove("spinning"); } }
  else if (act === "add") openAdd();
  else if (act === "menu") $("#menuList").classList.toggle("hidden");
  else if (act === "edit") { $("#menuList").classList.add("hidden"); openEdit(a.dataset.id); }
  else if (act === "resetpw") { $("#menuList").classList.add("hidden"); openResetPw(a.dataset.id); }
  else if (act === "ztdone") {
    const id = a.dataset.id || cur;
    try { await api(`/api/sites/${id}/zt-script-done`, { method: "POST", body: {} }); await load(); route(); toast("Ditandai sudah dipasang"); } catch (err) { toast(err.message, true); }
  }
  else if (act === "ztpick") { const m = $("#menuList"); if (m) m.classList.add("hidden"); openZtPick(a.dataset.id || cur); }
  else if (act === "del") { $("#menuList").classList.add("hidden"); openDelete(a.dataset.id); }
  else if (act === "test") openTest(a.dataset.id || cur);
  else if (act === "runtest") runTest();
  else if (act === "showpw") { const x = site(cur); const el = $("#pwv"); el.textContent = el.textContent.startsWith("•") ? x.password : "••••••••••••"; }
  else if (act === "addfwd") fwdForm(site(cur));
  else if (act === "delfwd") openDelFwd(cur, a.dataset.fid);
});
document.addEventListener("keydown", (e) => { if (e.key === "Escape") { closeModal(); document.querySelectorAll(".menu-list").forEach((m) => m.classList.add("hidden")); } });

/* ================= Mulai ================= */
paintIcons();
(async () => {
  try {
    const me = await api("/api/me");
    setBrand(me.panelName);
    if (me.loggedIn) { showApp(); await load(); route(); } else showLogin();
  } catch (e) { showLogin(); }
  setInterval(async () => {
    if ($("#appView").classList.contains("hidden") || $("#mbg") || TEST) return;
    const h = location.hash;
    if (CF && CF.running) return;
    try { await load(); if (!/\/(tes|port)$|^#\/(pengaturan|log|genieacs|zerotier)/.test(h) && !document.activeElement.matches("input,select")) route(); } catch (e) {}
  }, 30000);
})();
</script>
</body>
</html>
HTMLEOF
chmod 700 "$APP_DIR"
ok "Aplikasi ditulis ke $APP_DIR"

# Script pendukung untuk menu Add-on (pemasangan ZeroTier dari panel)
mkdir -p "$APP_DIR/scripts"
rm -f "$APP_DIR/scripts/pasang-ztnet.sh"
for f in ringkasan.sh cek.sh; do
  [ -f "$SCRIPT_DIR/$f" ] && install -m 700 "$SCRIPT_DIR/$f" "$APP_DIR/scripts/$f"
done
ok "Script add-on disalin ke $APP_DIR/scripts"

# ---------- Password admin ----------
if [ ! -f "$APP_DIR/data.json" ] || ! grep -q '"admin"' "$APP_DIR/data.json"; then
  ask_password
else
  ok "Password admin lama dipakai (ganti dengan: bash $0 password)"
fi

# ---------- IPv6 rusak? dahulukan IPv4 ----------
# Banyak VPS diberi alamat IPv6 yang tidak bisa dipakai keluar, sehingga Telegram/Cloudflare gagal
# karena IPv6 dicoba lebih dulu. Bila IPv4 jalan tetapi IPv6 tidak, sistem diatur memakai IPv4 dulu.
if command -v curl >/dev/null 2>&1 && ! grep -qE '^\s*precedence\s+::ffff:0:0/96' /etc/gai.conf 2>/dev/null; then
  if [ "$(curl -4 -s -o /dev/null -m 8 -w '%{http_code}' https://api.cloudflare.com 2>/dev/null)" != "000" ] \
     && [ "$(curl -6 -s -o /dev/null -m 8 -w '%{http_code}' https://api.cloudflare.com 2>/dev/null)" = "000" ] \
     && getent ahostsv6 api.telegram.org >/dev/null 2>&1; then
    printf '\n# ACS NETMAP Panel: IPv6 VPS tidak bisa keluar, dahulukan IPv4\nprecedence ::ffff:0:0/96  100\n' >> /etc/gai.conf
    ok "IPv6 VPS tidak berfungsi: sistem diatur memakai IPv4 lebih dulu (/etc/gai.conf)"
  fi
fi

# ---------- Service systemd ----------
cat > "$SERVICE" <<EOF
[Unit]
Description=Panel VPN ACS
After=network.target xl2tpd.service

[Service]
Environment=VPNACS_PORT=${PANEL_PORT}
ExecStartPre=-/bin/sh -c '[ "${ALLOW_PLAIN_L2TP}" = "yes" ] && command -v iptables >/dev/null && (iptables -C INPUT ${IPT_RULE} 2>/dev/null || iptables -I INPUT 1 ${IPT_RULE}) || true'
ExecStart=${NODE_BIN} ${APP_DIR}/server.js
Restart=always
RestartSec=3
# Saat memori habis (mis. build ZTNET), panel bukan yang dimatikan kernel
OOMScoreAdjust=-600

[Install]
WantedBy=multi-user.target
EOF
# needrestart (apt) tanpa dialog dan tanpa restart otomatis: pemasangan dari panel tidak tertahan/terputus
if [ -d /etc/needrestart ]; then
  mkdir -p /etc/needrestart/conf.d
  cat > /etc/needrestart/conf.d/vpn-acs.conf <<'NREOF'
# Ditulis ACS NETMAP Panel: needrestart (apt) tidak memunculkan dialog dan tidak me-restart layanan otomatis,
# supaya pemasangan dari panel tidak tertahan dialog "Pending kernel upgrade" atau mematikan panel/VPN.
$nrconf{restart} = 'l';
$nrconf{kernelhints} = 0;
$nrconf{ucodehint} = 0;
$nrconf{override_rc}->{qr(^vpn-acs\.service$)} = 0;
$nrconf{override_rc}->{qr(^xl2tpd\.service$)} = 0;
$nrconf{override_rc}->{qr(^(strongswan|ipsec)[^.]*\.service$)} = 0;
$nrconf{override_rc}->{qr(^genieacs-[^.]*\.service$)} = 0;
$nrconf{override_rc}->{qr(^addon-[^.]*\.service$)} = 0;
$nrconf{override_rc}->{qr(^vpnacs-job-[^.]*\.service$)} = 0;
$nrconf{override_rc}->{qr(^ztnet\.service$)} = 0;
$nrconf{override_rc}->{qr(^zerotier-one\.service$)} = 0;
$nrconf{override_rc}->{qr(^postgresql[^.]*\.service$)} = 0;
NREOF
fi
systemctl daemon-reload
systemctl enable --now vpn-acs >/dev/null 2>&1
systemctl restart vpn-acs
sleep 2
systemctl is-active --quiet vpn-acs || fail "Panel gagal berjalan. Cek: journalctl -u vpn-acs -n 50"

echo
ok "Panel VPN ACS berjalan"
# Panel memakai port 80/443 secara bawaan; beri tahu bila port itu dipakai program lain
for i in 1 2 3; do ss -Hltnp 2>/dev/null | grep -E '[:.]80[[:space:]]' | grep -q node && break; sleep 1; done
if ss -Hltnp 2>/dev/null | grep -E '[:.]80[[:space:]]' | grep -q node; then
  ok "Panel juga dibuka di port 80/443 (alamat tanpa port)"
else
  WHO80="$(ss -Hltnp 2>/dev/null | grep -E '[:.](80|443)[[:space:]]' | grep -oP 'users:\(\("\K[^"]+' | sort -u | tr '\n' ' ')"
  if [ -n "$WHO80" ]; then
    warn "Port 80/443 dipakai: ${WHO80}— panel hanya di port ${PANEL_PORT}. Hentikan program itu lalu: systemctl restart vpn-acs"
  fi
fi
SUMMARY="$SCRIPT_DIR/ringkasan.sh"
if [ -f "$SUMMARY" ]; then
  bash "$SUMMARY"
else
  PUBIP="$(hostname -I | awk '{print $1}')"
  HTTPS_DOM="$("$NODE_BIN" -e 'try{const c=require(process.argv[1]).settings.cloudflare;if(c&&c.https)console.log(c.domain)}catch(e){}' "$APP_DIR/data.json" 2>/dev/null)"
  if [ -n "$HTTPS_DOM" ]; then
    echo -e "   Buka di browser: ${GREEN}https://${HTTPS_DOM}:${PANEL_PORT}${NC}"
  else
    echo -e "   Buka di browser: ${GREEN}http://${PUBIP}:${PANEL_PORT}${NC}"
    echo "   (Jika IP di atas bukan IP publik, pakai IP publik VPS Anda)"
  fi
  if "$NODE_BIN" -e 'const c=require("crypto");const a=require(process.argv[1]).admin;process.exit(a&&c.scryptSync(process.argv[2],a.salt,64).toString("hex")===a.hash?0:1)' "$APP_DIR/data.json" "$DEFAULT_ADMIN_PW" 2>/dev/null; then
    echo -e "   Password login: ${YELLOW}${DEFAULT_ADMIN_PW}${NC} (password bawaan, segera ganti di Pengaturan)"
  fi
fi
