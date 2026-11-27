#!/bin/bash
# =====================================================================
#  Installer Panel VPN ACS
#  Panel web untuk membuat akun VPN L2TP MikroTik -> VPS GenieACS,
#  script MikroTik siap salin (IP virtual / NETMAP), dan port forwarding
#  untuk remote MikroTik / perangkat lokasi lewat IP publik VPS.
#
#  Syarat: L2TP/IPsec, MongoDB, Node.js, dan GenieACS sudah terpasang.
#  Cara termudah: jalankan install.sh (memasang semuanya, lalu panel ini).
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
[ -n "$NODE_BIN" ] || fail "Node.js tidak ditemukan. Jalankan install.sh (memasang semua komponen)."

DEFAULT_ADMIN_PW="Admin123"
ask_password() {
  local p1 p2
  # install.sh mengirim password acak lewat variabel ini (tanpa pertanyaan)
  if [ -n "${VPNACS_ADMIN_PASSWORD:-}" ]; then
    "$NODE_BIN" "$APP_DIR/server.js" --set-password "$VPNACS_ADMIN_PASSWORD"
    return
  fi
  if [ ! -t 0 ]; then
    p1="$(openssl rand -base64 18 2>/dev/null | tr -dc 'A-Za-z0-9' | head -c 12)"
    [ ${#p1} -ge 8 ] || p1="$DEFAULT_ADMIN_PW"
    "$NODE_BIN" "$APP_DIR/server.js" --set-password "$p1"
    warn "Tidak ada terminal untuk bertanya: password admin dibuat acak: $p1"
    return
  fi
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
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1
APT_OPT=(-o DPkg::Lock::Timeout=900 -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)
command -v iptables >/dev/null 2>&1 || apt-get "${APT_OPT[@]}" install -y -qq iptables </dev/null >/dev/null 2>&1 || true
command -v iptables >/dev/null 2>&1 || fail "iptables tidak ditemukan. Pasang dulu: apt install iptables"
if ! command -v ping >/dev/null 2>&1; then
  apt-get "${APT_OPT[@]}" install -y -qq iputils-ping </dev/null >/dev/null 2>&1 && ok "ping terpasang (untuk Tes Koneksi)" || warn "Gagal memasang ping, Tes Koneksi melewati langkah ping"
fi
# certbot + plugin Cloudflare: untuk HTTPS panel (menu Pengaturan > Domain & HTTPS)
if ! command -v certbot >/dev/null 2>&1 || ! dpkg -s python3-certbot-dns-cloudflare >/dev/null 2>&1; then
  echo "Memasang certbot (untuk HTTPS panel)..."
  if apt-get "${APT_OPT[@]}" install -y -qq certbot python3-certbot-dns-cloudflare </dev/null >/dev/null 2>&1 || \
     { apt-get "${APT_OPT[@]}" update -qq </dev/null >/dev/null 2>&1 && apt-get "${APT_OPT[@]}" install -y -qq certbot python3-certbot-dns-cloudflare </dev/null >/dev/null 2>&1; }; then
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
[ -f /etc/ppp/chap-secrets ] || warn "/etc/ppp/chap-secrets tidak ada. Pasang VPN dengan install.sh dulu."
[ -f /etc/ipsec.secrets ] || warn "/etc/ipsec.secrets tidak ada. PSK tidak bisa dibaca otomatis."

# ---------- Jaringan VPN ----------
# "local ip" dan "ip range" di /etc/xl2tpd/xl2tpd.conf diatur otomatis oleh panel
# (separuh awal subnet = IP tetap MikroTik, separuh akhir = pool dinamis).
[ -f "$XL2TPD_CONF" ] || warn "$XL2TPD_CONF tidak ditemukan. Pasang VPN dengan install.sh dulu."

# ---------- Izinkan L2TP tanpa IPsec ----------
# vpnsetup.sh (hwdsl2, instalasi lama) memblokir L2TP yang tidak memakai IPsec.
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

const VERSION = "2.12.2";
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
  const r = await httpJson("GET", UPDATE_RAW, null, { Range: "bytes=0-6000", Accept: "text/plain" }, 15000);
  const m = r.text && r.text.match(/const VERSION = "([\d.]+)"/);
  if (!m) {
    out.error = r.status ? `GitHub menjawab HTTP ${r.status}` : `Tidak bisa menghubungi GitHub (${r.error || "?"})`;
    return out;
  }
  out.latest = m[1];
  out.available = verCmp(out.latest, VERSION) > 0;
  if (out.available) {
    const c = await httpJson("GET", `https://api.github.com/repos/${UPDATE_REPO}/commits/main`, null, {}, 15000);
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
SERVEREOF

cat > "$APP_DIR/public/index.html" <<'HTMLEOF'
<!DOCTYPE html>
<html lang="id">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>VPN ACS</title>
<link rel="icon" href="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 32 32'%3E%3Crect width='32' height='32' rx='8' fill='%231d4ed8'/%3E%3Cpath d='M16 6l8 3v6c0 4.6-3.4 8.6-8 9.6-4.6-1-8-5-8-9.6V9l8-3z' fill='none' stroke='white' stroke-width='2.2' stroke-linejoin='round'/%3E%3Cpath d='M12.5 15.5l2.5 2.5 4.5-4.5' fill='none' stroke='white' stroke-width='2.2' stroke-linecap='round' stroke-linejoin='round'/%3E%3C/svg%3E">
<style>
  /* Font Plus Jakarta Sans (SIL Open Font License 1.1, Tokotype), disertakan langsung agar tanpa CDN */
  @font-face{font-family:"Plus Jakarta Sans";font-style:normal;font-display:swap;font-weight:200 800;src:url(data:font/woff2;base64,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) format("woff2");unicode-range:U+0000-00FF,U+0131,U+0152-0153,U+02BB-02BC,U+02C6,U+02DA,U+02DC,U+0304,U+0308,U+0329,U+2000-206F,U+20AC,U+2122,U+2191,U+2193,U+2212,U+2215,U+FEFF,U+FFFD}
  @font-face{font-family:"Plus Jakarta Sans";font-style:normal;font-display:swap;font-weight:200 800;src:url(data:font/woff2;base64,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) format("woff2");unicode-range:U+0100-02BA,U+02BD-02C5,U+02C7-02CC,U+02CE-02D7,U+02DD-02FF,U+1E00-1E9F,U+1EF2-1EFF,U+20A0-20AB,U+20AD-20C0,U+2C60-2C7F,U+A720-A7FF}
  :root{
    color-scheme:light;
    --bg:#f8f8fa;--surface:#fff;--subtle:#f8f9fb;--hover:#f3f6f9;
    --line:#e5e8ec;--line-2:#cfd6de;
    --text:#1f2937;--text-2:#374151;--muted:#5f6b7a;--head:#111827;
    --primary:#1c84ee;--primary-hover:#1670cb;--primary-soft:#e8f2fd;--ring:rgba(28,132,238,.18);
    --ok:#15803d;--ok-soft:#e8f6ed;--warn:#b45309;--warn-soft:#fdf3e3;--bad:#dc2626;--bad-soft:#fdeeee;
    --side:#fff;--side-text:#374151;--side-on:#f4f8fe;--side-lbl:#6b7280;--side-line:#eaedf1;--top:#fff;--search:#f3f5f8;
    --code-bg:#1f2732;--code-fg:#e2e8f0;--tab-accent:#1c84ee;
    --r:.3rem;--r-sm:.3rem;--shadow:0 3px 4px 0 rgba(0,0,0,.03);--shadow-lg:0 10px 30px -6px rgba(30,40,60,.18);
    --font:"Wix Madefor Text",ui-sans-serif,system-ui,-apple-system,"Segoe UI",Roboto,Arial,sans-serif;
    --mono:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;
  }
  [data-theme="dark"]{
    color-scheme:dark;
    --bg:#22282e;--surface:#282f36;--subtle:#2d353c;--hover:#2f373f;
    --line:#3a434d;--line-2:#4a5560;
    --text:#e8ecf0;--text-2:#d3d9e0;--muted:#a7b1bc;--head:#f8fafc;
    --primary:#3b95f0;--primary-hover:#62aaf3;--primary-soft:#1f3347;--ring:rgba(59,149,240,.25);
    --ok:#38d071;--ok-soft:#1d3527;--warn:#f9b931;--warn-soft:#3a3221;--bad:#f27474;--bad-soft:#3d2629;
    --side:#262d34;--side-text:#d3d9e0;--side-on:#2c3640;--side-lbl:#98a2ae;--side-line:#30383f;--top:#22282e;--search:#2b3239;--tab-accent:#3b95f0;
    --shadow:0 3px 4px 0 rgba(0,0,0,.12);
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
  .ph h1{font-size:26px;font-weight:700;letter-spacing:-.025em;line-height:1.2}
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
  .ch h2{font-size:15px;font-weight:650;letter-spacing:-.01em}
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
  .stack{display:flex;flex-direction:column;gap:24px}
  .stack>*{margin:0!important}

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
  .dh h1{font-size:26px;font-weight:700;letter-spacing:-.025em;display:flex;align-items:center;gap:12px;flex-wrap:wrap}
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
  .hl-row{display:grid;grid-template-columns:160px 160px;gap:12px}
  .hl-in{display:flex;align-items:center;gap:8px}.hl-in input{width:90px}.hl-in span{color:var(--muted);font-size:13.5px}
  .vh{padding:14px 20px 16px;display:grid;gap:12px}
  .vh-t{display:flex;justify-content:space-between;font-size:13px}.vh-t span{color:var(--muted);font-weight:500}.vh-t b{font-weight:650;font-variant-numeric:tabular-nums}
  .vh-r .zt-bar{margin-top:5px}.vh-r small{display:block;font-size:12px;color:var(--muted);margin-top:3px}
  .vh-f{display:flex;align-items:center;justify-content:space-between;gap:8px;margin-top:2px}
  #dashHealth:empty{display:none}
  .sec-steps{list-style:none;padding:0;display:grid;grid-template-columns:repeat(3,1fr);gap:10px;margin:6px 0 10px;counter-reset:st}
  .sec-steps li{border:1px solid var(--line);border-radius:var(--r-sm);padding:10px 12px;counter-increment:st;display:grid;gap:2px}
  .sec-steps li b{font-size:13px}.sec-steps li b::before{content:counter(st) ". ";color:var(--muted)}
  .sec-steps li span{font-size:13px;color:var(--warn);font-weight:600}
  .sess{list-style:none;padding:0;margin:0}
  .sess li{display:flex;align-items:center;gap:12px;padding:12px 20px;border-bottom:1px solid var(--line)}
  .sess li:last-child{border-bottom:0}
  .sess-ic{width:34px;height:34px;flex:none;display:grid;place-items:center;border-radius:9px;background:var(--subtle);color:var(--text-2)}.sess-ic svg{width:17px;height:17px}
  .sess-b{flex:1;min-width:0}
  .idle-bg{z-index:95}
  @media (max-width:720px){.sec-steps{grid-template-columns:1fr}}
  .wg-key{font-size:12.5px;word-break:break-all;color:var(--text-2)}
  .wg-port{display:flex;align-items:center;gap:8px;margin-top:10px;padding:10px 12px;border-radius:var(--r-sm);background:var(--subtle);border:1px solid var(--line);font-weight:600}
  .tr-opts{display:grid;gap:10px;margin-top:10px}
  .tr-opt{display:flex;align-items:center;gap:12px;padding:12px 14px;border:1px solid var(--line);border-radius:var(--r-sm);cursor:pointer;margin:0;font-weight:400}
  .tr-opt:has(input:checked){border-color:var(--primary);background:var(--primary-soft)}
  .tr-opt.dis{opacity:.55;cursor:not-allowed}
  .tr-ic{width:34px;height:34px;flex:none;display:grid;place-items:center;border-radius:9px;background:var(--subtle);color:var(--text-2)}.tr-ic svg{width:17px;height:17px}
  .tr-tx{display:grid;gap:2px}.tr-tx b{font-size:14px}.tr-tx small{color:var(--muted);font-size:12.5px}
  .tr-steps{margin:10px 0 14px;padding-left:20px;display:grid;gap:14px}.tr-steps li{min-width:0}.tr-steps .codebox{max-width:100%}.tr-steps pre{overflow:auto}.tr-steps li b{display:block;margin-bottom:6px}
  .inf-card{margin-bottom:16px}
  .inf-lead{font-size:13.5px;line-height:1.6;color:var(--text-2);margin:0 0 12px}
  .inf-bar{display:flex;height:10px;border-radius:99px;overflow:hidden;background:var(--subtle);border:1px solid var(--line)}
  .inf-bar i{display:block;height:100%}
  .inf-bar .ok,.inf-leg .ok{background:var(--ok)}.inf-bar .warn,.inf-leg .warn{background:var(--warn)}.inf-bar .bad,.inf-leg .bad{background:var(--bad)}.inf-bar .unk,.inf-leg .unk{background:var(--line-2)}
  .inf-leg{display:flex;flex-wrap:wrap;gap:6px 16px;margin-top:8px;font-size:12.5px;color:var(--muted)}
  .inf-leg i{display:inline-block;width:9px;height:9px;border-radius:3px;margin-right:6px;vertical-align:-1px}
  .inf-top{display:flex;align-items:center;flex-wrap:wrap;gap:6px;margin-top:12px}
  .inf-act{display:flex;align-items:center;flex-wrap:wrap;gap:8px;margin-top:14px}
  .det-grid{display:grid;grid-template-columns:minmax(0,1fr) 300px;gap:16px;align-items:start}
  .det-main{min-width:0}.det-side{display:grid;gap:16px;min-width:0}.det-side>.card{margin:0}
  .det-main>.card:first-child,.det-main>.note:first-child{margin-top:0}
  .ds-body{padding:14px 20px 18px;display:grid;gap:12px}
  .ds-kv{display:flex;justify-content:space-between;gap:10px;font-size:13.5px}.ds-kv span{color:var(--muted)}.ds-kv b{font-weight:600;text-align:right}
  .ds-up{display:grid;grid-template-columns:1fr auto;align-items:center;gap:2px 10px;font-size:13px}.ds-up span{color:var(--muted)}.ds-up b{font-weight:650;font-variant-numeric:tabular-nums}.ds-up .zt-bar{grid-column:1/-1;margin-top:4px}
  @media (max-width:1024px){.det-grid{grid-template-columns:1fr}.det-side{grid-template-columns:1fr 1fr;order:-1}}
  @media (max-width:720px){.det-side{grid-template-columns:1fr}}
  .zt-top{display:grid;grid-template-columns:minmax(0,1fr) 300px;gap:16px;margin-bottom:16px;align-items:start}
  .zt-main,.zt-side{display:grid;gap:16px;min-width:0}
  .zt-main>.card,.zt-side>.card{margin:0}
  .zt-ch .zt-selw{flex:0 1 260px;min-width:0}
  .zt-ch select{width:100%;height:32px;font-size:13px;font-weight:550}
  .zt-cur{padding:14px 20px 18px}
  .zt-idbox{display:inline-flex;align-items:center;gap:4px;padding:4px 6px 4px 12px;border-radius:8px;background:var(--subtle);border:1px solid var(--line)}
  .zt-health{display:grid;grid-template-columns:1fr 1fr}
  .zt-hc{padding:16px 20px;border-right:1px solid var(--line);border-bottom:1px solid var(--line);min-width:0}
  .zt-hc:nth-child(2n){border-right:0}.zt-hc:nth-last-child(-n+2){border-bottom:0}
  .zt-hc>span{font-size:12.5px;color:var(--muted);font-weight:500}
  .zt-hc b{display:block;font-size:19px;font-weight:650;margin-top:4px;letter-spacing:-.01em;font-variant-numeric:tabular-nums}
  .zt-hc b.warn{color:var(--warn)}
  .zt-hc b em{font-style:normal;font-size:13px;font-weight:500;color:var(--muted)}
  .zt-hc small{display:block;font-size:12.5px;color:var(--muted);margin-top:3px}
  .zt-bar{height:6px;border-radius:99px;background:var(--subtle);border:1px solid var(--line);margin-top:9px;overflow:hidden}
  .zt-bar i{display:block;height:100%;background:var(--ok);border-radius:99px;transition:width .4s}
  .zt-tip{color:var(--muted);display:inline-grid;cursor:help}.zt-tip svg{width:16px;height:16px}
  .zt-qrc{text-align:center}
  .zt-qrbig{width:164px;height:164px;margin:18px auto 0;display:block;padding:10px;border-radius:12px;background:#fff;border:1px solid var(--line);cursor:zoom-in;transition:box-shadow .15s}
  .zt-qrbig:hover{box-shadow:0 10px 24px -12px rgba(16,24,40,.35)}
  .zt-qrbig svg{width:100%;height:100%;display:block}
  .zt-qrt{margin:10px 16px 16px}
  .zt-actc{padding:16px;display:grid;gap:8px}
  .zt-actc .btn{justify-content:center;width:100%}
  .zt-actc p{margin:2px 2px 0;line-height:1.5}
  @media (max-width:1024px){.zt-top{grid-template-columns:1fr}.zt-side{grid-template-columns:1fr 1fr}}
  @media (max-width:720px){.zt-side{grid-template-columns:1fr}.zt-health{grid-template-columns:1fr}.zt-hc{border-right:0}.zt-hc:nth-last-child(2){border-bottom:1px solid var(--line)}.zt-ch{flex-wrap:wrap}.zt-ch .zt-selw{flex:1 1 100%}.zt-cur{padding:12px 16px 16px}.zt-hc{padding:14px 16px}}
  .zt-hrow{display:grid;grid-template-columns:120px minmax(0,1fr);align-items:center;gap:10px;min-height:32px}
  .zt-hl{font-weight:500;color:var(--muted);font-size:13px}
  .zt-hv{display:flex;align-items:center;gap:8px;min-width:0}
  .zt-nwid{font-size:17px;font-weight:600;letter-spacing:.02em;color:var(--text);line-height:1.2;word-break:break-all}
  .zt-nname{font-size:14.5px;font-weight:600;color:var(--text);overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
  .zt-nin{max-width:280px;height:32px!important;font-size:14px!important}
  .zt-ib{width:28px;height:28px;flex:none;display:grid;place-items:center;border:1px solid transparent;border-radius:8px;background:none;color:var(--muted);cursor:pointer;transition:background .12s,color .12s}
  .zt-ib:hover{background:var(--hover);color:var(--text)}
  .zt-ib svg{width:15px;height:15px}
  .zt-ib.ok{color:var(--ok)}
  .zt-hmeta{display:flex;align-items:center;gap:8px;flex-wrap:wrap;margin-top:10px;font-size:12.5px}
  .zt-hmeta .pill svg{width:11px;height:11px;margin-right:3px;vertical-align:-1px}
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
  .zt-apm{margin-top:6px}
  .zt-qr{display:flex;gap:22px;align-items:flex-start}
  .zt-qrbox{flex:none;width:210px;height:210px;border-radius:14px;background:#fff;border:1px solid var(--line);padding:8px;box-shadow:var(--shadow)}
  .zt-qrbox svg{width:100%;height:100%;display:block}
  .zt-qrinfo{flex:1;min-width:0}
  .zt-qrid{font-size:22px;font-weight:600;letter-spacing:.04em;margin-top:2px;word-break:break-all}
  .zt-qrsteps{margin-top:18px}
  .zt-qrsteps li{padding-bottom:10px;font-size:13px;color:var(--text-2)}
  .zt-qrsteps li b{display:inline;color:var(--text);font-weight:600}
  .zt-qrsteps li > b:first-child{display:block}
  @media (max-width:1024px){.zt-g2{grid-template-columns:1fr}}
  @media (max-width:720px){
    .stats.zt-stats{grid-template-columns:1fr 1fr}.zt-stats .stat:nth-child(2){border-right:0}.zt-stats .stat:nth-child(-n+2){border-bottom:1px solid var(--line)}
    .zt-hrow{grid-template-columns:1fr;gap:2px;min-height:0;margin-bottom:10px}.zt-nwid{font-size:16px}
    .zt-2col{grid-template-columns:1fr}
    .zt-qr{flex-direction:column;align-items:center}.zt-qrinfo{width:100%}
    .zt-t .zt-colnode,.zt-t .zt-act,.zt-t th.r{display:none}.zt-nodesm{display:block}.zt-t tr.zt-tap{cursor:pointer}.zt-t .zt-apm{display:inline-flex}
    .zt-rv{display:none}.zt-routes li{gap:6px}
    .filters{flex-wrap:wrap}
  }
  /* Pola aksi: kelompok tombol di kanan (utama paling kanan), aksi berbahaya di kiri */
  .card-actions{display:flex;gap:8px;flex-wrap:wrap;align-items:center;justify-content:flex-end;border-top:1px solid var(--line);padding-top:14px;padding-bottom:14px}
  .card-actions .sp,.mf .sp,.ad-mf .sp{flex:1}
  .mf{align-items:center}
  /* Add-on */
  .ad-search{width:280px;max-width:100%}
  .ad-sec{margin-bottom:24px}
  .ad-sh{display:flex;align-items:center;gap:8px;margin:0 2px 12px}
  .ad-sh h2{font-size:13px;font-weight:650;text-transform:uppercase;letter-spacing:.07em;color:var(--muted)}
  .ad-sh span{font-size:12px;font-weight:600;color:var(--text-2);background:var(--subtle);border:1px solid var(--line);border-radius:99px;padding:0 8px;line-height:18px}
  .ad-grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(300px,1fr));gap:16px}
  .ad-grid .card{margin:0}
  .ad-tile{display:flex;flex-direction:column;transition:border-color .15s,box-shadow .15s,transform .15s}
  .ad-tile:hover{border-color:var(--line-2);box-shadow:0 10px 28px -14px rgba(16,24,40,.25);transform:translateY(-1px)}
  .ad-tt{display:flex;align-items:center;gap:12px;padding:18px 16px 0 18px}
  .ad-tn{flex:1;min-width:0}
  .ad-tn b{display:block;font-size:15px;font-weight:650;letter-spacing:-.01em}
  .ad-st{display:flex;align-items:center;gap:6px;color:var(--muted);font-size:12.5px;margin-top:3px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
  .ad-st .dot{width:7px;height:7px}
  .ad-tg{color:var(--text-2);font-size:13px;line-height:1.55;padding:12px 18px 16px;margin:0;flex:1}
  .ad-tf{display:flex;justify-content:flex-end;gap:8px;padding:12px 16px;border-top:1px solid var(--line);background:var(--subtle);border-radius:0 0 var(--r) var(--r)}
  .ad-ic{width:44px;height:44px;border-radius:12px;display:grid;place-items:center;flex:none;color:#fff;box-shadow:0 6px 14px -8px rgba(16,24,40,.45)}
  .ad-ic svg{width:21px;height:21px}
  .ad-ic.sm{width:34px;height:34px;border-radius:10px}
  .ad-ic.sm svg{width:17px;height:17px}
  .ad-ic.c-blue{background:linear-gradient(135deg,#2563eb,#60a5fa)}
  .ad-ic.c-teal{background:linear-gradient(135deg,#0d9488,#2dd4bf)}
  .ad-ic.c-amber{background:linear-gradient(135deg,#d97706,#fbbf24)}
  .ad-ic.c-violet{background:linear-gradient(135deg,#7c3aed,#a78bfa)}
  .ad-list{list-style:none;margin:0;padding:0}
  .ad-list li+li{border-top:1px solid var(--line)}
  .ad-row{display:flex;align-items:center;gap:14px;width:100%;padding:14px 20px;border:0;background:none;text-align:left;color:inherit;cursor:pointer;transition:background .12s}
  .ad-row:hover{background:var(--hover)}
  .ad-row .chev{color:var(--muted);display:flex}
  .ad-row .chev svg{width:16px;height:16px}
  .ad-rb{flex:1;min-width:0;display:flex;flex-direction:column;gap:2px}
  .ad-rn{font-weight:600;display:flex;align-items:center;gap:8px}
  .ad-rd{color:var(--muted);font-size:12.5px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
  .ad-mh{display:inline-flex;align-items:center;gap:12px}
  .ad-dh{display:flex;gap:8px;align-items:center;margin-bottom:12px}
  .ad-lead{font-size:15px;font-weight:550;line-height:1.5;margin:0 0 6px}
  .ad-desc{color:var(--text-2);font-size:13.5px;line-height:1.6;margin:0}
  .ad-h3{font-size:12px;font-weight:650;text-transform:uppercase;letter-spacing:.07em;color:var(--muted);margin:20px 0 10px}
  .ad-feat{list-style:none;margin:0;padding:0;display:grid;grid-template-columns:1fr 1fr;gap:8px 18px}
  .ad-feat li{display:flex;gap:8px;align-items:flex-start;font-size:13.5px;line-height:1.45}
  .ad-feat svg{width:15px;height:15px;color:var(--ok);flex:none;margin-top:2px}
  .ad-info{display:grid;grid-template-columns:1fr;margin:0;border:1px solid var(--line);border-radius:var(--r-sm);overflow:hidden}
  .ad-info div{display:flex;gap:12px;padding:9px 14px;font-size:13px}
  .ad-info div+div{border-top:1px solid var(--line)}
  .ad-info dt{width:130px;flex:none;color:var(--muted)}
  .ad-info dd{margin:0;min-width:0;word-break:break-word}
  .ad-mf{display:flex;align-items:center;gap:8px;width:100%;flex-wrap:wrap}
  .subl{display:grid;gap:14px;margin-top:12px}
  .subi{padding:12px 14px;border:1px solid var(--line);border-radius:var(--r-sm)}
  .subi .check{margin:0}
  .subr{display:flex;align-items:center;gap:8px;margin-top:8px}
  .subr input{max-width:220px}
  .ad-upd{display:flex;gap:8px;align-items:flex-start;margin:-4px 18px 14px;padding:9px 12px;border-radius:var(--r-sm);background:var(--primary-soft);color:var(--primary);font-size:12.5px;line-height:1.45}
  .ad-upd svg{width:15px;height:15px;flex:none;margin-top:1px}
  .ad-acts{gap:8px}
  .upd-dot{display:inline-block;margin-left:6px;padding:1px 7px;border-radius:99px;background:#f59e0b;color:#111;font-weight:600;font-size:10.5px;text-decoration:none}
  .dapps{list-style:none;margin:0;padding:4px 0}
  .dapps li{display:flex;align-items:center;gap:12px;padding:10px 20px}
  .dapps li+li{border-top:1px solid var(--line)}
  .dapps .grow{flex:1;min-width:0}
  .dapps b{display:block;font-weight:600;font-size:13.5px}
  .dapps small{display:block;color:var(--muted);font-size:12px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
  @media (max-width:720px){.ad-acts{width:100%;flex-wrap:wrap}.ad-search{width:100%}.ad-feat{grid-template-columns:1fr}.ad-info dt{width:100px}.ad-row .pill{display:none}}
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
  .form-actions{display:flex;gap:8px;margin-top:18px;flex-wrap:wrap;justify-content:flex-end;align-items:center}
  .form-actions.start{justify-content:flex-start}
  .form-actions .sp{flex:1}
  .sec-t{font-size:13px;font-weight:600;color:var(--text);margin:20px 0 2px;padding-top:16px;border-top:1px solid var(--line)}
  .sec-t:first-child{margin-top:0;padding-top:0;border-top:0}
  .check+.help{margin:-8px 0 8px 25px}
  select:disabled,input:disabled{background:var(--subtle);color:var(--muted)}

  /* Tabel kecil */
  table.t{width:100%;border-collapse:collapse;font-size:13.5px}
  table.t th{text-align:left;font-size:12.5px;font-weight:600;color:var(--text-2);padding:11px 20px;border-bottom:1px solid var(--line);background:var(--subtle)}
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
  .grid-dash{display:grid;grid-template-columns:minmax(0,1.75fr) minmax(300px,1fr);gap:24px;align-items:start}
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
  .tag.violet{background:color-mix(in srgb,#7c3aed 12%,transparent);color:#7c3aed}
  [data-theme=dark] .tag.violet{color:#a78bfa}
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
    .grid2,.grid-dash{grid-template-columns:minmax(0,1fr)}.grid-dash>.card{overflow-x:auto}
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
    .user-btn .who{display:none}
    .hide-md{display:none}
  }

  /* ===== gaya Reback (CSS ditulis sendiri) ===== */
  h1,h2,h3,.kpi b,.login-box h1,.menu-h b{color:var(--head)}
  .side{width:260px;background:var(--side);border-right:1px solid var(--side-line);padding:0 0 12px;overflow-y:auto}
  .side>.brand{justify-content:center;height:70px;padding:0 20px;color:var(--head);flex:none}
  .brand-mark{background:var(--primary);color:#fff;border-radius:8px}
  .side .brand b{font-size:17px;font-weight:700;color:var(--head)}
  .side .brand small{color:var(--muted);font-weight:500}
  .nav-sec{padding:18px 25px 8px;font-size:11px;font-weight:600;letter-spacing:.08em;color:var(--side-lbl)}
  .nav{gap:12px;padding:10px 25px;margin:0;border-radius:0;color:var(--side-text);font-size:14.5px;position:relative}
  .nav:hover{background:none;color:var(--primary)}
  .nav.on{background:var(--side-on);color:var(--head);font-weight:600}
  .nav.on::before{content:"";position:absolute;left:0;top:0;bottom:0;width:3px;background:var(--primary)}
  .nav.on svg{color:var(--primary)}
  .nav .cnt{background:var(--primary-soft);color:var(--primary);font-weight:600}
  .side-foot{border-top:0;padding:12px 25px 2px;color:var(--side-lbl)}
  .wrap{margin-left:260px}
  .top{height:70px;gap:6px;padding:0 24px;background:var(--top);border-bottom:0;box-shadow:0 2px 8px rgba(30,40,60,.05)}
  [data-theme="dark"] .top{box-shadow:0 1px 0 var(--line)}
  .tsearch{position:relative;width:300px;max-width:100%}
  .tsearch>span{position:absolute;left:13px;top:50%;transform:translateY(-50%);display:flex;color:var(--muted);pointer-events:none;z-index:1}
  .tsearch>span svg{width:16px;height:16px}
  .tsearch input{width:100%;height:40px;padding:0 12px 0 38px!important;background:var(--search);border:1px solid transparent;border-radius:var(--r);outline:none;color:var(--head)}
  .tsearch input:focus{border-color:var(--primary)}
  .tsearch input:focus{background:var(--surface)}
  .tsres{position:absolute;left:0;right:0;top:calc(100% + 6px);min-width:280px;background:var(--surface);border:1px solid var(--line);border-radius:var(--r);box-shadow:var(--shadow-lg);padding:6px;z-index:60}
  .tsres a{display:block;padding:8px 10px;border-radius:var(--r);color:var(--text-2)}
  .tsres a b{display:block;font-weight:600;font-size:13.5px;color:var(--head)}
  .tsres a small{display:block;font-size:11.5px;color:var(--muted)}
  .tsres a:hover,.tsres a.on{background:var(--primary-soft)}
  .tsres .none{padding:10px;color:var(--muted);font-size:13px}
  .top .btn.ghost.icon{width:40px;height:40px;border-radius:50%}
  .top .btn.ghost.icon:hover{color:var(--primary)}
  .top .btn.ghost.icon svg{width:20px;height:20px}
  .user-btn{height:40px;padding:0 6px 0 8px;border-radius:var(--r)}
  .user-btn .uic{width:30px;height:30px;border-radius:50%;background:var(--primary-soft);color:var(--primary);display:grid;place-items:center}
  .user-btn .uic svg{width:17px;height:17px;color:var(--primary)}
  .user-btn .who{font-weight:600;color:var(--head);font-size:14px}
  .menu-list{top:calc(100% + 14px);border-radius:var(--r)}
  .menu-list button{border-radius:var(--r)}
  .main{padding:24px;max-width:none;margin:0}
  #topWarn{max-width:none;margin:0;padding:24px 24px 0}
  .pbar{display:flex;align-items:center;justify-content:space-between;gap:10px 16px;flex-wrap:wrap;margin:0 0 18px;min-height:40px}
  .pbar .crumb{font-size:15px;gap:8px}
  .pbar .crumb>a:first-child{width:34px;height:34px;border-radius:var(--r);background:var(--surface);box-shadow:var(--shadow);display:grid;place-items:center;color:var(--primary)}
  .pbar .crumb>a:first-child svg{width:17px;height:17px;color:var(--primary)}
  .pbar .crumb b{font-size:18px;font-weight:600;color:var(--head)}
  .pacts{display:flex;gap:8px;align-items:center}
  .pacts:empty{display:none}
  /* Dashboard: tab Uptime router / Perlu perhatian */
  .dtabs{display:flex;gap:4px;align-self:stretch;margin:-16px 0 -16px -6px}
  .dtabs button{display:flex;align-items:center;gap:8px;border:0;background:none;padding:0 14px;font-size:15px;font-weight:600;color:var(--muted);border-bottom:2px solid transparent;margin-bottom:-1px}
  .dtabs button:hover{color:var(--head)}
  .dtabs button.on{color:var(--primary);border-bottom-color:var(--primary)}
  .dtabs .n{min-width:21px;height:21px;padding:0 6px;border-radius:11px;font-size:12px;font-weight:700;display:inline-grid;place-items:center;background:var(--bad);color:#fff}
  .dtabs .n.warn{background:var(--warn)}
  .dtabs .n.info{background:var(--primary)}
  .dh h1{font-size:20px;font-weight:600}
  .crumb{font-size:14px;color:var(--text-2);gap:6px}
  .crumb a{color:var(--text-2);display:inline-flex}.crumb a:hover{color:var(--primary)}
  .crumb b{color:var(--head);font-weight:500}
  .crumb svg{width:14px;height:14px;color:var(--muted)}
  .ph{align-items:center;margin-bottom:20px}
  .ph h1{display:none}
  .ph p{margin-top:0;color:var(--muted)}
  .card{border:0;border-radius:var(--r)}
  [data-theme="dark"] .card,[data-theme="dark"] .kpi{border:1px solid var(--line)}
  .card+.card{margin-top:24px}
  .ch{padding:16px 20px;min-height:60px}
  .ch h2{font-size:16px;font-weight:600}
  .cb{padding:20px}
  .btn{height:38px;border-radius:var(--r);font-weight:500;padding:0 16px}
  .btn.sm{height:32px;padding:0 11px}
  .btn.icon{width:38px;padding:0}
  .kpis{gap:24px;margin-bottom:24px}
  .kpi{border:0;padding:20px;border-radius:var(--r)}
  .kpi b{font-size:24px;font-weight:600;letter-spacing:-.01em}
  .grid2{gap:24px}
  .login{background:var(--bg)}
  .login-box{border:0;border-radius:var(--r);box-shadow:0 10px 30px -10px rgba(30,40,60,.15);padding:32px}
  [data-theme="dark"] .login-box{border:1px solid var(--line)}
  .login-card .brand{color:var(--head)}
  @media (max-width:900px){
    .wrap{margin-left:0}
    .top{height:62px;padding:0 10px}
    .tsearch{flex:1;width:auto;min-width:0}
    .tsearch input{padding-left:32px!important}.tsearch>span{left:10px}
    .user-btn .who,.user-btn>span:last-child{display:none}
    .main{padding:14px 12px}#topWarn{padding:14px 12px 0}
    .pbar .crumb>a:first-child{width:30px;height:30px}.pbar .crumb b{font-size:16px}
    .dtabs button{padding:0 9px;font-size:14px;white-space:nowrap}.dtabs~.muted{display:none}
    .kpis,.grid2{gap:12px}.kpis{margin-bottom:12px}.card+.card{margin-top:12px}.stack,.grid-dash{gap:12px}
  }
  /* kontras teks lebih tinggi */
  body{color:var(--text)}
  table.t td{color:var(--text)}
  input::placeholder,textarea::placeholder{color:#8a94a3;opacity:1}
  [data-theme="dark"] input::placeholder,[data-theme="dark"] textarea::placeholder{color:#8f99a5}
  /* ===== v2.10: gaya lebih lembut (Plus Jakarta Sans, sudut membulat, bayangan halus) ===== */
  :root{
    --bg:#f3f6fa;--surface:#fff;--subtle:#eef2f8;--hover:#eef2f8;--surface-3:#e4ebf4;
    --line:#e2e9f2;--line-2:#d3deeb;
    --text:#0d1a2e;--text-2:#33465f;--muted:#647690;--faint:#8fa1b8;--head:#0d1a2e;
    --primary:#1c6ce0;--primary-hover:#175cbf;--primary-soft:#e7f0fd;--primary-ink:#155cb8;--ring:rgba(28,108,224,.16);
    --ok:#149a52;--ok-soft:#e5f6ec;--warn:#c77400;--warn-soft:#fdf1de;--bad:#d64545;--bad-soft:#fdecec;
    --side:#fff;--side-text:#33465f;--side-on:#e7f0fd;--side-lbl:#8fa1b8;--side-line:#e2e9f2;--top:rgba(243,246,250,.82);--search:#fff;
    --r:16px;--r-sm:11px;
    --shadow:0 1px 2px rgba(13,32,64,.05),0 1px 3px rgba(13,32,64,.04);
    --shadow-md:0 4px 16px -4px rgba(13,32,64,.10),0 2px 6px -2px rgba(13,32,64,.06);
    --shadow-lg:0 24px 60px -16px rgba(8,24,52,.28);
    --font:"Plus Jakarta Sans",ui-sans-serif,system-ui,-apple-system,"Segoe UI",Roboto,Arial,sans-serif;
  }
  [data-theme="dark"]{
    --bg:#081120;--surface:#0e1a2e;--subtle:#132238;--hover:#132238;--surface-3:#1a2c47;
    --line:#1c2c46;--line-2:#27395a;
    --text:#e9eff8;--text-2:#c3d2e6;--muted:#8fa3bd;--faint:#677d99;--head:#e9eff8;
    --primary:#4d8ef7;--primary-hover:#6aa3f8;--primary-soft:#16294a;--primary-ink:#9dc2fb;--ring:rgba(77,142,247,.25);
    --ok:#3ecf7f;--ok-soft:#0f2f22;--warn:#f0a832;--warn-soft:#38290f;--bad:#f07676;--bad-soft:#3a1d22;
    --side:#0e1a2e;--side-text:#c3d2e6;--side-on:#16294a;--side-lbl:#677d99;--side-line:#1c2c46;--top:rgba(8,17,32,.82);--search:#0e1a2e;
    --shadow:0 1px 2px rgba(0,0,0,.35);--shadow-md:0 4px 16px -4px rgba(0,0,0,.45);--shadow-lg:0 24px 60px -16px rgba(0,0,0,.6);
  }
  body{font-size:14.5px;color:var(--text);transition:background .25s,color .25s}
  /* sidebar */
  .side{width:268px;padding:0 0 0}
  .side>.brand{justify-content:flex-start;height:auto;padding:22px 22px 14px;gap:12px}
  .brand-mark{width:44px;height:44px;border-radius:12px;box-shadow:0 6px 14px -6px var(--primary)}
  .brand-mark svg{width:24px;height:24px}
  .side .brand b{font-size:18px;font-weight:800;letter-spacing:-.01em}
  .side .brand small{font-size:12.5px}
  .nav-sec{padding:18px 26px 6px;font-size:11px;font-weight:700;letter-spacing:.12em}
  .nav{width:calc(100% - 28px);margin:1px 14px;padding:11px 12px;min-height:44px;border-radius:10px;font-weight:600;font-size:14.5px;color:var(--side-text)}
  .nav svg{color:var(--muted)}
  .nav:hover{background:var(--subtle);color:var(--text)}
  .nav.on{background:var(--primary-soft);color:var(--primary-ink);font-weight:700}
  .nav.on::before{display:none}
  .nav.on svg{color:var(--primary)}
  .side-foot{border-top:1px solid var(--line);padding:14px 22px;font-weight:600;font-size:12.5px;color:var(--muted)}
  .side-foot #ver{background:var(--subtle);border:1px solid var(--line);padding:2px 8px;border-radius:999px;font-size:11.5px}
  .wrap{margin-left:268px}
  /* bar atas: kaca buram */
  .top{height:72px;background:var(--top);backdrop-filter:blur(12px);-webkit-backdrop-filter:blur(12px);box-shadow:none;border-bottom:1px solid var(--line);gap:10px;padding:0 32px}
  .tsearch{width:440px}
  .tsearch input{height:44px;border-radius:11px;border:1px solid var(--line)!important;background:var(--surface);box-shadow:var(--shadow);padding-right:44px!important;font-size:14.5px}
  .tsearch input:focus{box-shadow:0 0 0 3px var(--primary-soft)}
  .tsearch>span{left:14px}
  .tsearch>span svg{width:18px;height:18px;color:var(--faint)}
  .tsearch kbd{position:absolute;right:12px;top:50%;transform:translateY(-50%);font:700 11.5px var(--font);color:var(--muted);background:var(--subtle);border:1px solid var(--line);border-bottom-width:2px;border-radius:6px;padding:2px 7px;pointer-events:none}
  .tsearch input:focus~kbd,.tsearch input:not(:placeholder-shown)~kbd{display:none}
  .top .btn.ghost.icon{width:42px;height:42px;border-radius:11px;background:var(--surface);border:1px solid var(--line);box-shadow:var(--shadow);color:var(--text-2)}
  .top .btn.ghost.icon:hover{background:var(--subtle);color:var(--text)}
  .user-btn{height:44px;padding:5px 12px 5px 5px;border-radius:999px;background:var(--surface);border:1px solid var(--line);box-shadow:var(--shadow);gap:10px}
  .user-btn:hover{background:var(--subtle)}
  .user-btn .uic{width:34px;height:34px}
  .user-btn .who{font-weight:700}
  .menu-list{border-radius:14px;padding:8px;width:230px}
  .menu-list button{border-radius:9px;min-height:40px;font-weight:600;color:var(--text-2)}
  /* isi */
  .main{padding:28px 32px 56px;max-width:1300px;margin:0 auto}
  #topWarn{max-width:1300px;margin:0 auto;padding:24px 32px 0}
  .pbar{margin-bottom:22px}
  .pbar .crumb>a:first-child{width:38px;height:38px;border-radius:11px;border:1px solid var(--line)}
  .pbar .crumb b{font-size:22px;font-weight:800;letter-spacing:-.02em}
  .pupd{color:var(--faint);font-size:13px;white-space:nowrap}
  .pupd b{color:var(--muted);font-weight:600}
  .btn{min-height:40px;height:auto;padding:0 18px;border-radius:11px;font-weight:700;border-color:var(--line-2)}
  .btn svg{width:18px;height:18px}
  .btn.pri{box-shadow:0 8px 18px -8px var(--primary)}
  .btn.sm{min-height:34px;padding:0 12px;border-radius:9px;font-size:13px}
  .btn:active{transform:translateY(1px)}
  .pacts .btn.pri{min-height:44px;padding:0 20px;font-size:14.5px}
  .card{border:1px solid var(--line)!important;border-radius:var(--r);box-shadow:var(--shadow);overflow:hidden}
  .ch{padding:18px 22px;min-height:62px}
  .ch h2{font-size:17px;font-weight:700}
  .ch a{font-weight:600}
  .cb{padding:22px}
  /* KPI */
  .kpis{gap:18px;margin-bottom:18px}
  .kpi{border:1px solid var(--line)!important;border-radius:var(--r);padding:20px;box-shadow:var(--shadow);transition:box-shadow .2s,transform .2s}
  .kpi:hover{box-shadow:var(--shadow-md);transform:translateY(-2px)}
  .kpi>span{display:flex;align-items:center;gap:10px;font-weight:600;color:var(--muted);font-size:14px}
  .kico{width:38px;height:38px;border-radius:11px;display:grid;place-items:center;flex:none}
  .kico svg{width:20px;height:20px}
  .kico.blue{background:var(--primary-soft);color:var(--primary)}.kico.green{background:var(--ok-soft);color:var(--ok)}.kico.red{background:var(--bad-soft);color:var(--bad)}.kico.amber{background:var(--warn-soft);color:var(--warn)}
  .kpi b{font-size:36px;font-weight:800;letter-spacing:-.03em;line-height:1.1;margin:12px 0 4px}
  .kpi small{font-size:13.5px;color:var(--muted)}
  .grid-dash{gap:18px;grid-template-columns:minmax(0,1fr) 380px}
  .stack{gap:18px}
  /* tab kartu kiri */
  .dtabs{margin:-18px 0 -18px -8px}
  .dtabs button{font-size:16px;font-weight:700;padding:0 14px}
  /* tabel */
  table.t th{background:none;font-size:12px;font-weight:700;letter-spacing:.07em;text-transform:uppercase;color:var(--faint);padding:12px 22px}
  table.t td{padding:15px 22px}
  table.t th:first-child,table.t td:first-child{padding-left:22px}
  table.t tr.click:hover td{background:var(--subtle)}
  .pill{border-radius:999px;font-weight:700;font-size:12.5px;padding:5px 11px;height:auto}
  /* daftar perlu perhatian & aplikasi */
  .row{padding:15px 22px}
  .row .ic{border-radius:11px}
  .dapps li{padding:13px 22px}
  .dapps b{font-size:14.5px;font-weight:700}
  .dapps small{font-size:12.5px}
  .kv{padding:12px 22px}
  .empty{padding:48px 24px}
  .empty .big{width:58px;height:58px;border-radius:16px;background:var(--ok-soft);color:var(--ok)}
  .empty .big svg{width:28px;height:28px}
  .empty h3{font-size:16.5px;font-weight:700}
  /* kesehatan VPS */
  .live{margin-left:auto;display:inline-flex;align-items:center;gap:6px;font-size:12px;font-weight:700;color:var(--ok);background:var(--ok-soft);padding:4px 10px;border-radius:999px}
  .live i{width:7px;height:7px;border-radius:50%;background:var(--ok);animation:livep 2s infinite}
  .live.bad{color:var(--bad);background:var(--bad-soft)}.live.bad i{background:var(--bad)}
  @keyframes livep{0%{box-shadow:0 0 0 0 var(--ok-soft)}70%{box-shadow:0 0 0 6px transparent}100%{box-shadow:0 0 0 0 transparent}}
  .vh{padding:18px 22px 20px;gap:14px}
  .vps-ip{display:flex;align-items:center;gap:10px;background:var(--subtle);border:1px solid var(--line);border-radius:11px;padding:10px 12px}
  .vps-ip svg{width:17px;height:17px;color:var(--muted);flex:none}
  .vps-ip b{font-family:var(--mono);font-weight:600;font-size:13.5px;min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
  .vps-ip button{margin-left:auto;display:inline-flex;align-items:center;gap:6px;font-size:12.5px;font-weight:700;color:var(--primary-ink);background:var(--surface);border:1px solid var(--line);border-radius:8px;padding:5px 10px}
  .vps-ip button:hover{background:var(--primary-soft)}
  .vps-ip button svg{width:14px;height:14px;color:inherit}
  .vh-t{font-size:13.5px}.vh-t span{color:var(--text-2);font-weight:600}.vh-t b{font-weight:700}
  .vh-r .zt-bar{height:8px;border-radius:99px;margin-top:7px}
  .vh-r .zt-bar i{border-radius:99px}
  .vh-f{border-top:1px solid var(--line);padding-top:14px;margin-top:4px}
  .vh-l{font-size:13px;font-weight:600}
  /* lain-lain */
  input:not([type=checkbox]):not([type=radio]),select,textarea{border-radius:11px}
  .chip{border-radius:999px;font-weight:600}
  .modal{border-radius:20px}
  .note{border-radius:14px}
  .login-box{border-radius:20px}
  .dsec{padding:12px 22px 2px;font-size:11px;font-weight:700;letter-spacing:.12em;text-transform:uppercase;color:var(--faint);border-top:1px solid var(--line)}
  @media (max-width:1080px){.grid-dash{grid-template-columns:minmax(0,1fr)}.tsearch{width:auto;flex:1;max-width:440px}}
  @media (max-width:900px){
    .wrap{margin-left:0}.top{padding:0 12px;height:64px}.main{padding:18px 14px 40px}#topWarn{padding:14px 14px 0}
    .tsearch kbd{display:none}.tsearch input{padding-right:12px!important}
    .pbar .crumb b{font-size:19px}.pupd{display:none}
    .kpis,.grid-dash,.stack{gap:12px}
    .user-btn{padding:4px}
  }
  @media (max-width:600px){.kpi{padding:16px}.kpi b{font-size:28px}.pacts .btn.pri{min-height:40px;padding:0 14px}}

  /* ===== v2.10.3: tampilan lebih rapat (compact), tanpa deskripsi halaman ===== */
  .ph{display:none!important}
  body{font-size:14px}
  .side{width:244px}
  .wrap{margin-left:244px}
  .side>.brand{padding:16px 18px 8px;gap:10px}
  .brand-mark{width:38px;height:38px;border-radius:10px}
  .brand-mark svg{width:20px;height:20px}
  .side .brand b{font-size:16.5px}
  .side .brand small{font-size:12px}
  .nav-sec{padding:12px 22px 4px;font-size:10.5px}
  .nav{width:calc(100% - 20px);margin:1px 10px;padding:8px 12px;min-height:38px;font-size:14px;border-radius:9px}
  .nav svg{width:18px;height:18px}
  .side-foot{padding:10px 18px}
  .top{height:58px;padding:0 20px;gap:8px}
  .tsearch{width:380px}
  .tsearch input{height:38px;border-radius:10px}
  .top .btn.ghost.icon{width:36px;height:36px;border-radius:10px}
  .top .btn.ghost.icon svg{width:18px;height:18px}
  .user-btn{height:38px;padding:3px 10px 3px 3px;gap:8px}
  .user-btn .uic{width:30px;height:30px}
  .user-btn .who{font-size:13.5px}
  .main{padding:14px 20px 32px}
  #topWarn{padding:14px 20px 0}
  #topWarn .note{padding:10px 14px}
  .pbar{margin:0 0 12px;min-height:34px}
  .pbar .crumb{gap:6px;font-size:14px}
  .pbar .crumb>a:first-child{width:30px;height:30px;border-radius:9px}
  .pbar .crumb>a:first-child svg{width:16px;height:16px}
  .pbar .crumb b{font-size:17px;font-weight:700;letter-spacing:-.01em}
  .pupd{font-size:12.5px}
  .pacts{gap:6px}
  .pacts .btn.pri,.btn{min-height:34px;padding:0 13px;border-radius:9px;font-size:13.5px;gap:6px}
  .btn svg{width:16px;height:16px}
  .btn.pri{box-shadow:0 6px 14px -8px var(--primary)}
  .btn.sm{min-height:30px;padding:0 10px;font-size:12.5px;border-radius:8px}
  .btn.icon{width:34px;padding:0}
  .pacts .search input,.pacts input{height:34px}
  .card{border-radius:12px}
  .card+.card{margin-top:14px}
  .ch{padding:11px 16px;min-height:48px;gap:8px}
  .ch h2{font-size:15px}
  .ch .muted,.ch a{font-size:12.5px}
  .cb{padding:14px 16px}
  .kpis{gap:12px;margin-bottom:12px}
  .kpi{padding:12px 14px;border-radius:12px}
  .kpi:hover{transform:translateY(-1px)}
  .kpi>span{font-size:13px;gap:8px}
  .kico{width:28px;height:28px;border-radius:8px}
  .kico svg{width:16px;height:16px}
  .kpi b{font-size:24px;margin:6px 0 0;line-height:1.15}
  .kpi small{font-size:12.5px}
  .grid-dash{gap:12px;grid-template-columns:minmax(0,1fr) 340px}
  .stack{gap:12px}
  .dtabs{margin:-11px 0 -11px -6px}
  .dtabs button{font-size:14.5px;padding:0 11px}
  .dtabs .n{min-width:19px;height:19px;font-size:11px}
  table.t th{padding:8px 16px;font-size:11px}
  table.t td{padding:9px 16px}
  table.t th:first-child,table.t td:first-child{padding-left:16px}
  .srv small{font-size:12px}
  .row{padding:10px 16px;gap:12px}
  .row .ic{width:32px;height:32px}
  .dapps li{padding:9px 16px;gap:10px}
  .dapps b{font-size:13.5px}
  .kv{padding:8px 16px;font-size:13px}
  .vh{padding:12px 16px 14px;gap:10px}
  .vps-ip{padding:7px 10px;border-radius:9px}
  .vh-r .zt-bar{height:6px;margin-top:5px}
  .vh-f{padding-top:10px}
  .empty{padding:30px 20px}
  .empty .big{width:46px;height:46px;border-radius:12px}
  .toolbar{padding:10px 16px}
  input:not([type=checkbox]):not([type=radio]),select{height:36px;border-radius:9px}
  textarea{border-radius:9px}
  .chip{height:28px;padding:0 11px}
  .dh{margin-bottom:12px}
  .dh h1{font-size:18px}
  .pacts .acts{display:flex;align-items:center;gap:6px;flex-wrap:nowrap}
  .pacts .ad-search{width:230px}
  .side-foot{align-items:center;gap:8px}
  .side-foot>span:first-child{min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
  .side-foot #ver{display:inline-flex;align-items:center;gap:5px;white-space:nowrap;flex:none}
  @media (max-width:720px){.pacts .ad-search{width:150px}}
  @media (max-width:1080px){.grid-dash{grid-template-columns:minmax(0,1fr)}}
  @media (max-width:900px){.wrap{margin-left:0}.top{height:56px;padding:0 10px}.main{padding:12px 10px 32px}#topWarn{padding:10px 10px 0}.pbar .crumb b{font-size:16px}}
  @media (max-width:600px){.kpi b{font-size:22px}.kpis{gap:8px}}

  button.tab{border:0;border-bottom:2px solid transparent;background:none;cursor:pointer;font:inherit}
  .subtabs{margin-bottom:14px}
  .subtabs .tab{padding:9px 12px 10px;font-size:14px}
  .tab.on{color:var(--primary-ink);border-bottom-color:var(--primary)}
  .tab.on svg{color:var(--primary)}
  .tcnt{min-width:19px;height:19px;padding:0 6px;border-radius:10px;font-size:11px;font-weight:700;display:inline-grid;place-items:center;background:var(--bad);color:#fff}
  .tcnt.warn{background:var(--warn)}
  [data-pane]>.card+.card,[data-pane]>.card+.grid2,[data-pane]>.kpis+.card{margin-top:12px}

  /* ZeroTier: jaringan saat ini + QR dalam satu kartu, tab Pengaturan */
  .zt-curqr{display:grid;grid-template-columns:minmax(0,1fr) auto;gap:18px;align-items:center;padding:6px 16px 14px}
  .zt-curqr .zt-cur{padding:4px 0 0}
  .zt-qrside{display:flex;flex-direction:column;align-items:center;gap:6px;padding-left:18px;border-left:1px solid var(--line)}
  .zt-qrside .zt-qrbig{width:124px;height:124px;margin:0;padding:8px}
  .zt-qrside .zt-small{font-size:11.5px}
  .zt-curc,.zt-hcard{margin-bottom:12px}
  .zt-cur .zt-hv b.mono{font-size:14px;font-weight:600}
  .zt-cur .zt-hv .zt-small{margin-left:8px}
  .zt-hcard .zt-health{grid-template-columns:repeat(4,1fr)}
  .zt-hcard .zt-hc{border-bottom:0;border-right:1px solid var(--line)}
  .zt-hcard .zt-hc:last-child{border-right:0}
  .zt-setgrid,.g-setgrid{display:grid;grid-template-columns:minmax(0,1.3fr) minmax(0,1fr);gap:12px;align-items:start;margin-bottom:12px}
  .g-setgrid>*>.card,.g-setgrid>.card{margin:0}
  .g-inf>.card,.g-inf>div{margin:0}
  .zt-setin .zt-sec:first-child{margin-top:0}
  .zt-actc{padding:12px 16px 14px;gap:8px}
  .zt-acth{display:flex;align-items:center;justify-content:space-between;font-size:14px}
  @media (max-width:1024px){.zt-hcard .zt-health{grid-template-columns:1fr 1fr}.zt-hcard .zt-hc:nth-child(2n){border-right:0}.zt-hcard .zt-hc:nth-child(-n+2){border-bottom:1px solid var(--line)}.zt-setgrid,.g-setgrid{grid-template-columns:1fr}}
  @media (max-width:720px){.zt-curqr{grid-template-columns:1fr}.zt-qrside{border-left:0;padding-left:0;border-top:1px solid var(--line);padding-top:12px}.zt-hcard .zt-health{grid-template-columns:1fr}.zt-hcard .zt-hc{border-right:0;border-bottom:1px solid var(--line)}.zt-hcard .zt-hc:last-child{border-bottom:0}}
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
    <div class="nav-sec">Utama</div>
    <button class="nav" data-go="#/"><span data-ic="home"></span>Dashboard</button>
    <div class="nav-sec">Jaringan</div>
    <button class="nav" data-go="#/router"><span data-ic="router"></span>Router</button>
    <button class="nav" data-go="#/genieacs"><span data-ic="box"></span>GenieACS</button>
    <button class="nav hidden" id="navZt" data-go="#/zerotier"><span data-ic="hub"></span>ZeroTier</button>
    <button class="nav hidden" id="navWg" data-go="#/wireguard"><span data-ic="bolt"></span>WireGuard</button>
    <div class="nav-sec">Aplikasi</div>
    <button class="nav" data-go="#/addon"><span data-ic="puzzle"></span>Add-on</button>
    <div class="nav-sec">Sistem</div>
    <button class="nav" data-go="#/pengaturan"><span data-ic="gear"></span>Pengaturan</button>
    <button class="nav" data-go="#/panduan"><span data-ic="book"></span>Panduan</button>
    <button class="nav" data-go="#/log"><span data-ic="list"></span>Log aktivitas</button>
    <div class="grow"></div>
    <div class="side-foot"><span class="brand-name">VPN ACS</span><span id="ver"></span></div>
  </aside>
  <div class="backdrop" data-act="closenav"></div>
  <div class="wrap">
    <header class="top">
      <button class="btn ghost icon" id="navBtn" data-act="opennav" aria-label="Menu"><span data-ic="menu"></span></button>
      <div class="tsearch" role="search"><span data-ic="search"></span><input type="search" id="tq" placeholder="Cari menu atau router…" autocomplete="off" aria-label="Cari menu atau router"><kbd>/</kbd><div class="tsres hidden" id="tsres"></div></div>
      <div class="top-r">
        <button class="btn ghost icon" data-act="refresh" title="Perbarui status" aria-label="Perbarui status"><span data-ic="refresh"></span></button>
        <button class="btn ghost icon" data-act="theme" title="Tampilan gelap / terang" aria-label="Ganti tampilan gelap atau terang"><span id="themeIc"></span></button>
        <div class="menu">
          <button class="user-btn" data-act="usermenu" aria-label="Menu akun"><span class="uic" data-ic="user"></span><span class="who">Admin</span><span data-ic="down"></span></button>
          <div class="menu-list hidden" id="userList">
            <div class="menu-h"><small>Masuk sebagai</small><b>Admin</b></div>
            <button data-go="#/pengaturan/umum"><span data-ic="gear"></span>Pengaturan</button>
            <hr><button class="d" data-act="logout"><span data-ic="logout"></span>Keluar</button>
          </div>
        </div>
      </div>
    </header>
    <div id="topWarn"></div>
    <main class="main"><div class="pbar"><nav class="crumb" id="crumb" aria-label="Breadcrumb"></nav><div class="pacts" id="pActs"></div></div><div id="view"></div></main>
  </div>
</div>

<div id="modalRoot"></div>

<script>
/* QR Code Generator for JavaScript — Copyright (c) 2009 Kazuhiko Arase — MIT license — https://github.com/kazuhikoarase/qrcode-generator */
var qrcode=function(){var P=function(x,w){var g=236,l=17,n=x,s=O[w],t=null,r=0,h=null,i=[],v={},_=function(a,f){r=n*4+17,t=function(e){for(var u=new Array(e),o=0;o<e;o+=1){u[o]=new Array(e);for(var d=0;d<e;d+=1)u[o][d]=null}return u}(r),B(0,0),B(r-7,0),B(0,r-7),E(),T(),m(a,f),n>=7&&N(a),h==null&&(h=nr(n,s,i)),U(h,f)},B=function(a,f){for(var e=-1;e<=7;e+=1)if(!(a+e<=-1||r<=a+e))for(var u=-1;u<=7;u+=1)f+u<=-1||r<=f+u||(0<=e&&e<=6&&(u==0||u==6)||0<=u&&u<=6&&(e==0||e==6)||2<=e&&e<=4&&2<=u&&u<=4?t[a+e][f+u]=!0:t[a+e][f+u]=!1)},y=function(){for(var a=0,f=0,e=0;e<8;e+=1){_(!0,e);var u=k.getLostPoint(v);(e==0||a>u)&&(a=u,f=e)}return f},T=function(){for(var a=8;a<r-8;a+=1)t[a][6]==null&&(t[a][6]=a%2==0);for(var f=8;f<r-8;f+=1)t[6][f]==null&&(t[6][f]=f%2==0)},E=function(){for(var a=k.getPatternPosition(n),f=0;f<a.length;f+=1)for(var e=0;e<a.length;e+=1){var u=a[f],o=a[e];if(t[u][o]==null)for(var d=-2;d<=2;d+=1)for(var c=-2;c<=2;c+=1)d==-2||d==2||c==-2||c==2||d==0&&c==0?t[u+d][o+c]=!0:t[u+d][o+c]=!1}},N=function(a){for(var f=k.getBCHTypeNumber(n),e=0;e<18;e+=1){var u=!a&&(f>>e&1)==1;t[Math.floor(e/3)][e%3+r-8-3]=u}for(var e=0;e<18;e+=1){var u=!a&&(f>>e&1)==1;t[e%3+r-8-3][Math.floor(e/3)]=u}},m=function(a,f){for(var e=s<<3|f,u=k.getBCHTypeInfo(e),o=0;o<15;o+=1){var d=!a&&(u>>o&1)==1;o<6?t[o][8]=d:o<8?t[o+1][8]=d:t[r-15+o][8]=d}for(var o=0;o<15;o+=1){var d=!a&&(u>>o&1)==1;o<8?t[8][r-o-1]=d:o<9?t[8][15-o-1+1]=d:t[8][15-o-1]=d}t[r-8][8]=!a},U=function(a,f){for(var e=-1,u=r-1,o=7,d=0,c=k.getMaskFunction(f),p=r-1;p>0;p-=2)for(p==6&&(p-=1);;){for(var b=0;b<2;b+=1)if(t[u][p-b]==null){var C=!1;d<a.length&&(C=(a[d]>>>o&1)==1);var A=c(u,p-b);A&&(C=!C),t[u][p-b]=C,o-=1,o==-1&&(d+=1,o=7)}if(u+=e,u<0||r<=u){u-=e,e=-e;break}}},H=function(a,f){for(var e=0,u=0,o=0,d=new Array(f.length),c=new Array(f.length),p=0;p<f.length;p+=1){var b=f[p].dataCount,C=f[p].totalCount-b;u=Math.max(u,b),o=Math.max(o,C),d[p]=new Array(b);for(var A=0;A<d[p].length;A+=1)d[p][A]=255&a.getBuffer()[A+e];e+=b;var R=k.getErrorCorrectPolynomial(C),I=K(d[p],R.getLength()-1),S=I.mod(R);c[p]=new Array(R.getLength()-1);for(var A=0;A<c[p].length;A+=1){var X=A+S.getLength()-c[p].length;c[p][A]=X>=0?S.getAt(X):0}}for(var Z=0,A=0;A<f.length;A+=1)Z+=f[A].totalCount;for(var J=new Array(Z),Q=0,A=0;A<u;A+=1)for(var p=0;p<f.length;p+=1)A<d[p].length&&(J[Q]=d[p][A],Q+=1);for(var A=0;A<o;A+=1)for(var p=0;p<f.length;p+=1)A<c[p].length&&(J[Q]=c[p][A],Q+=1);return J},nr=function(a,f,e){for(var u=Y.getRSBlocks(a,f),o=G(),d=0;d<e.length;d+=1){var c=e[d];o.put(c.getMode(),4),o.put(c.getLength(),k.getLengthInBits(c.getMode(),a)),c.write(o)}for(var p=0,d=0;d<u.length;d+=1)p+=u[d].dataCount;if(o.getLengthInBits()>p*8)throw"code length overflow. ("+o.getLengthInBits()+">"+p*8+")";for(o.getLengthInBits()+4<=p*8&&o.put(0,4);o.getLengthInBits()%8!=0;)o.putBit(!1);for(;!(o.getLengthInBits()>=p*8||(o.put(g,8),o.getLengthInBits()>=p*8));)o.put(l,8);return H(o,u)};v.addData=function(a,f){f=f||"Byte";var e=null;switch(f){case"Numeric":e=$(a);break;case"Alphanumeric":e=W(a);break;case"Byte":e=V(a);break;case"Kanji":e=q(a);break;default:throw"mode:"+f}i.push(e),h=null},v.isDark=function(a,f){if(a<0||r<=a||f<0||r<=f)throw a+","+f;return t[a][f]},v.getModuleCount=function(){return r},v.make=function(){if(n<1){for(var a=1;a<40;a++){for(var f=Y.getRSBlocks(a,s),e=G(),u=0;u<i.length;u++){var o=i[u];e.put(o.getMode(),4),e.put(o.getLength(),k.getLengthInBits(o.getMode(),a)),o.write(e)}for(var d=0,u=0;u<f.length;u++)d+=f[u].dataCount;if(e.getLengthInBits()<=d*8)break}n=a}_(!1,y())},v.createTableTag=function(a,f){a=a||2,f=typeof f>"u"?a*4:f;var e="";e+='<table style="',e+=" border-width: 0px; border-style: none;",e+=" border-collapse: collapse;",e+=" padding: 0px; margin: "+f+"px;",e+='">',e+="<tbody>";for(var u=0;u<v.getModuleCount();u+=1){e+="<tr>";for(var o=0;o<v.getModuleCount();o+=1)e+='<td style="',e+=" border-width: 0px; border-style: none;",e+=" border-collapse: collapse;",e+=" padding: 0px; margin: 0px;",e+=" width: "+a+"px;",e+=" height: "+a+"px;",e+=" background-color: ",e+=v.isDark(u,o)?"#000000":"#ffffff",e+=";",e+='"/>';e+="</tr>"}return e+="</tbody>",e+="</table>",e},v.createSvgTag=function(a,f,e,u){var o={};typeof arguments[0]=="object"&&(o=arguments[0],a=o.cellSize,f=o.margin,e=o.alt,u=o.title),a=a||2,f=typeof f>"u"?a*4:f,e=typeof e=="string"?{text:e}:e||{},e.text=e.text||null,e.id=e.text?e.id||"qrcode-description":null,u=typeof u=="string"?{text:u}:u||{},u.text=u.text||null,u.id=u.text?u.id||"qrcode-title":null;var d=v.getModuleCount()*a+f*2,c,p,b,C,A="",R;for(R="l"+a+",0 0,"+a+" -"+a+",0 0,-"+a+"z ",A+='<svg version="1.1" xmlns="http://www.w3.org/2000/svg"',A+=o.scalable?"":' width="'+d+'px" height="'+d+'px"',A+=' viewBox="0 0 '+d+" "+d+'" ',A+=' preserveAspectRatio="xMinYMin meet"',A+=u.text||e.text?' role="img" aria-labelledby="'+F([u.id,e.id].join(" ").trim())+'"':"",A+=">",A+=u.text?'<title id="'+F(u.id)+'">'+F(u.text)+"</title>":"",A+=e.text?'<description id="'+F(e.id)+'">'+F(e.text)+"</description>":"",A+='<rect width="100%" height="100%" fill="white" cx="0" cy="0"/>',A+='<path d="',b=0;b<v.getModuleCount();b+=1)for(C=b*a+f,c=0;c<v.getModuleCount();c+=1)v.isDark(b,c)&&(p=c*a+f,A+="M"+p+","+C+R);return A+='" stroke="transparent" fill="black"/>',A+="</svg>",A},v.createDataURL=function(a,f){a=a||2,f=typeof f>"u"?a*4:f;var e=v.getModuleCount()*a+f*2,u=f,o=e-f;return er(e,e,function(d,c){if(u<=d&&d<o&&u<=c&&c<o){var p=Math.floor((d-u)/a),b=Math.floor((c-u)/a);return v.isDark(b,p)?0:1}else return 1})},v.createImgTag=function(a,f,e){a=a||2,f=typeof f>"u"?a*4:f;var u=v.getModuleCount()*a+f*2,o="";return o+="<img",o+=' src="',o+=v.createDataURL(a,f),o+='"',o+=' width="',o+=u,o+='"',o+=' height="',o+=u,o+='"',e&&(o+=' alt="',o+=F(e),o+='"'),o+="/>",o};var F=function(a){for(var f="",e=0;e<a.length;e+=1){var u=a.charAt(e);switch(u){case"<":f+="&lt;";break;case">":f+="&gt;";break;case"&":f+="&amp;";break;case'"':f+="&quot;";break;default:f+=u;break}}return f},ar=function(a){var f=1;a=typeof a>"u"?f*2:a;var e=v.getModuleCount()*f+a*2,u=a,o=e-a,d,c,p,b,C,A={"\u2588\u2588":"\u2588","\u2588 ":"\u2580"," \u2588":"\u2584","  ":" "},R={"\u2588\u2588":"\u2580","\u2588 ":"\u2580"," \u2588":" ","  ":" "},I="";for(d=0;d<e;d+=2){for(p=Math.floor((d-u)/f),b=Math.floor((d+1-u)/f),c=0;c<e;c+=1)C="\u2588",u<=c&&c<o&&u<=d&&d<o&&v.isDark(p,Math.floor((c-u)/f))&&(C=" "),u<=c&&c<o&&u<=d+1&&d+1<o&&v.isDark(b,Math.floor((c-u)/f))?C+=" ":C+="\u2588",I+=a<1&&d+1>=o?R[C]:A[C];I+=`
`}return e%2&&a>0?I.substring(0,I.length-e-1)+Array(e+1).join("\u2580"):I.substring(0,I.length-1)};return v.createASCII=function(a,f){if(a=a||1,a<2)return ar(f);a-=1,f=typeof f>"u"?a*2:f;var e=v.getModuleCount()*a+f*2,u=f,o=e-f,d,c,p,b,C=Array(a+1).join("\u2588\u2588"),A=Array(a+1).join("  "),R="",I="";for(d=0;d<e;d+=1){for(p=Math.floor((d-u)/a),I="",c=0;c<e;c+=1)b=1,u<=c&&c<o&&u<=d&&d<o&&v.isDark(p,Math.floor((c-u)/a))&&(b=0),I+=b?C:A;for(p=0;p<a;p+=1)R+=I+`
`}return R.substring(0,R.length-1)},v.renderTo2dContext=function(a,f){f=f||2;for(var e=v.getModuleCount(),u=0;u<e;u++)for(var o=0;o<e;o++)a.fillStyle=v.isDark(u,o)?"black":"white",a.fillRect(u*f,o*f,f,f)},v};P.stringToBytesFuncs={default:function(x){for(var w=[],g=0;g<x.length;g+=1){var l=x.charCodeAt(g);w.push(l&255)}return w}},P.stringToBytes=P.stringToBytesFuncs.default,P.createStringToBytes=function(x,w){var g=function(){for(var n=rr(x),s=function(){var T=n.read();if(T==-1)throw"eof";return T},t=0,r={};;){var h=n.read();if(h==-1)break;var i=s(),v=s(),_=s(),B=String.fromCharCode(h<<8|i),y=v<<8|_;r[B]=y,t+=1}if(t!=w)throw t+" != "+w;return r}(),l=63;return function(n){for(var s=[],t=0;t<n.length;t+=1){var r=n.charCodeAt(t);if(r<128)s.push(r);else{var h=g[n.charAt(t)];typeof h=="number"?(h&255)==h?s.push(h):(s.push(h>>>8),s.push(h&255)):s.push(l)}}return s}};var D={MODE_NUMBER:1,MODE_ALPHA_NUM:2,MODE_8BIT_BYTE:4,MODE_KANJI:8},O={L:1,M:0,Q:3,H:2},L={PATTERN000:0,PATTERN001:1,PATTERN010:2,PATTERN011:3,PATTERN100:4,PATTERN101:5,PATTERN110:6,PATTERN111:7},k=function(){var x=[[],[6,18],[6,22],[6,26],[6,30],[6,34],[6,22,38],[6,24,42],[6,26,46],[6,28,50],[6,30,54],[6,32,58],[6,34,62],[6,26,46,66],[6,26,48,70],[6,26,50,74],[6,30,54,78],[6,30,56,82],[6,30,58,86],[6,34,62,90],[6,28,50,72,94],[6,26,50,74,98],[6,30,54,78,102],[6,28,54,80,106],[6,32,58,84,110],[6,30,58,86,114],[6,34,62,90,118],[6,26,50,74,98,122],[6,30,54,78,102,126],[6,26,52,78,104,130],[6,30,56,82,108,134],[6,34,60,86,112,138],[6,30,58,86,114,142],[6,34,62,90,118,146],[6,30,54,78,102,126,150],[6,24,50,76,102,128,154],[6,28,54,80,106,132,158],[6,32,58,84,110,136,162],[6,26,54,82,110,138,166],[6,30,58,86,114,142,170]],w=1335,g=7973,l=21522,n={},s=function(t){for(var r=0;t!=0;)r+=1,t>>>=1;return r};return n.getBCHTypeInfo=function(t){for(var r=t<<10;s(r)-s(w)>=0;)r^=w<<s(r)-s(w);return(t<<10|r)^l},n.getBCHTypeNumber=function(t){for(var r=t<<12;s(r)-s(g)>=0;)r^=g<<s(r)-s(g);return t<<12|r},n.getPatternPosition=function(t){return x[t-1]},n.getMaskFunction=function(t){switch(t){case L.PATTERN000:return function(r,h){return(r+h)%2==0};case L.PATTERN001:return function(r,h){return r%2==0};case L.PATTERN010:return function(r,h){return h%3==0};case L.PATTERN011:return function(r,h){return(r+h)%3==0};case L.PATTERN100:return function(r,h){return(Math.floor(r/2)+Math.floor(h/3))%2==0};case L.PATTERN101:return function(r,h){return r*h%2+r*h%3==0};case L.PATTERN110:return function(r,h){return(r*h%2+r*h%3)%2==0};case L.PATTERN111:return function(r,h){return(r*h%3+(r+h)%2)%2==0};default:throw"bad maskPattern:"+t}},n.getErrorCorrectPolynomial=function(t){for(var r=K([1],0),h=0;h<t;h+=1)r=r.multiply(K([1,M.gexp(h)],0));return r},n.getLengthInBits=function(t,r){if(1<=r&&r<10)switch(t){case D.MODE_NUMBER:return 10;case D.MODE_ALPHA_NUM:return 9;case D.MODE_8BIT_BYTE:return 8;case D.MODE_KANJI:return 8;default:throw"mode:"+t}else if(r<27)switch(t){case D.MODE_NUMBER:return 12;case D.MODE_ALPHA_NUM:return 11;case D.MODE_8BIT_BYTE:return 16;case D.MODE_KANJI:return 10;default:throw"mode:"+t}else if(r<41)switch(t){case D.MODE_NUMBER:return 14;case D.MODE_ALPHA_NUM:return 13;case D.MODE_8BIT_BYTE:return 16;case D.MODE_KANJI:return 12;default:throw"mode:"+t}else throw"type:"+r},n.getLostPoint=function(t){for(var r=t.getModuleCount(),h=0,i=0;i<r;i+=1)for(var v=0;v<r;v+=1){for(var _=0,B=t.isDark(i,v),y=-1;y<=1;y+=1)if(!(i+y<0||r<=i+y))for(var T=-1;T<=1;T+=1)v+T<0||r<=v+T||y==0&&T==0||B==t.isDark(i+y,v+T)&&(_+=1);_>5&&(h+=3+_-5)}for(var i=0;i<r-1;i+=1)for(var v=0;v<r-1;v+=1){var E=0;t.isDark(i,v)&&(E+=1),t.isDark(i+1,v)&&(E+=1),t.isDark(i,v+1)&&(E+=1),t.isDark(i+1,v+1)&&(E+=1),(E==0||E==4)&&(h+=3)}for(var i=0;i<r;i+=1)for(var v=0;v<r-6;v+=1)t.isDark(i,v)&&!t.isDark(i,v+1)&&t.isDark(i,v+2)&&t.isDark(i,v+3)&&t.isDark(i,v+4)&&!t.isDark(i,v+5)&&t.isDark(i,v+6)&&(h+=40);for(var v=0;v<r;v+=1)for(var i=0;i<r-6;i+=1)t.isDark(i,v)&&!t.isDark(i+1,v)&&t.isDark(i+2,v)&&t.isDark(i+3,v)&&t.isDark(i+4,v)&&!t.isDark(i+5,v)&&t.isDark(i+6,v)&&(h+=40);for(var N=0,v=0;v<r;v+=1)for(var i=0;i<r;i+=1)t.isDark(i,v)&&(N+=1);var m=Math.abs(100*N/r/r-50)/5;return h+=m*10,h},n}(),M=function(){for(var x=new Array(256),w=new Array(256),g=0;g<8;g+=1)x[g]=1<<g;for(var g=8;g<256;g+=1)x[g]=x[g-4]^x[g-5]^x[g-6]^x[g-8];for(var g=0;g<255;g+=1)w[x[g]]=g;var l={};return l.glog=function(n){if(n<1)throw"glog("+n+")";return w[n]},l.gexp=function(n){for(;n<0;)n+=255;for(;n>=256;)n-=255;return x[n]},l}();function K(x,w){if(typeof x.length>"u")throw x.length+"/"+w;var g=function(){for(var n=0;n<x.length&&x[n]==0;)n+=1;for(var s=new Array(x.length-n+w),t=0;t<x.length-n;t+=1)s[t]=x[t+n];return s}(),l={};return l.getAt=function(n){return g[n]},l.getLength=function(){return g.length},l.multiply=function(n){for(var s=new Array(l.getLength()+n.getLength()-1),t=0;t<l.getLength();t+=1)for(var r=0;r<n.getLength();r+=1)s[t+r]^=M.gexp(M.glog(l.getAt(t))+M.glog(n.getAt(r)));return K(s,0)},l.mod=function(n){if(l.getLength()-n.getLength()<0)return l;for(var s=M.glog(l.getAt(0))-M.glog(n.getAt(0)),t=new Array(l.getLength()),r=0;r<l.getLength();r+=1)t[r]=l.getAt(r);for(var r=0;r<n.getLength();r+=1)t[r]^=M.gexp(M.glog(n.getAt(r))+s);return K(t,0).mod(n)},l}var Y=function(){var x=[[1,26,19],[1,26,16],[1,26,13],[1,26,9],[1,44,34],[1,44,28],[1,44,22],[1,44,16],[1,70,55],[1,70,44],[2,35,17],[2,35,13],[1,100,80],[2,50,32],[2,50,24],[4,25,9],[1,134,108],[2,67,43],[2,33,15,2,34,16],[2,33,11,2,34,12],[2,86,68],[4,43,27],[4,43,19],[4,43,15],[2,98,78],[4,49,31],[2,32,14,4,33,15],[4,39,13,1,40,14],[2,121,97],[2,60,38,2,61,39],[4,40,18,2,41,19],[4,40,14,2,41,15],[2,146,116],[3,58,36,2,59,37],[4,36,16,4,37,17],[4,36,12,4,37,13],[2,86,68,2,87,69],[4,69,43,1,70,44],[6,43,19,2,44,20],[6,43,15,2,44,16],[4,101,81],[1,80,50,4,81,51],[4,50,22,4,51,23],[3,36,12,8,37,13],[2,116,92,2,117,93],[6,58,36,2,59,37],[4,46,20,6,47,21],[7,42,14,4,43,15],[4,133,107],[8,59,37,1,60,38],[8,44,20,4,45,21],[12,33,11,4,34,12],[3,145,115,1,146,116],[4,64,40,5,65,41],[11,36,16,5,37,17],[11,36,12,5,37,13],[5,109,87,1,110,88],[5,65,41,5,66,42],[5,54,24,7,55,25],[11,36,12,7,37,13],[5,122,98,1,123,99],[7,73,45,3,74,46],[15,43,19,2,44,20],[3,45,15,13,46,16],[1,135,107,5,136,108],[10,74,46,1,75,47],[1,50,22,15,51,23],[2,42,14,17,43,15],[5,150,120,1,151,121],[9,69,43,4,70,44],[17,50,22,1,51,23],[2,42,14,19,43,15],[3,141,113,4,142,114],[3,70,44,11,71,45],[17,47,21,4,48,22],[9,39,13,16,40,14],[3,135,107,5,136,108],[3,67,41,13,68,42],[15,54,24,5,55,25],[15,43,15,10,44,16],[4,144,116,4,145,117],[17,68,42],[17,50,22,6,51,23],[19,46,16,6,47,17],[2,139,111,7,140,112],[17,74,46],[7,54,24,16,55,25],[34,37,13],[4,151,121,5,152,122],[4,75,47,14,76,48],[11,54,24,14,55,25],[16,45,15,14,46,16],[6,147,117,4,148,118],[6,73,45,14,74,46],[11,54,24,16,55,25],[30,46,16,2,47,17],[8,132,106,4,133,107],[8,75,47,13,76,48],[7,54,24,22,55,25],[22,45,15,13,46,16],[10,142,114,2,143,115],[19,74,46,4,75,47],[28,50,22,6,51,23],[33,46,16,4,47,17],[8,152,122,4,153,123],[22,73,45,3,74,46],[8,53,23,26,54,24],[12,45,15,28,46,16],[3,147,117,10,148,118],[3,73,45,23,74,46],[4,54,24,31,55,25],[11,45,15,31,46,16],[7,146,116,7,147,117],[21,73,45,7,74,46],[1,53,23,37,54,24],[19,45,15,26,46,16],[5,145,115,10,146,116],[19,75,47,10,76,48],[15,54,24,25,55,25],[23,45,15,25,46,16],[13,145,115,3,146,116],[2,74,46,29,75,47],[42,54,24,1,55,25],[23,45,15,28,46,16],[17,145,115],[10,74,46,23,75,47],[10,54,24,35,55,25],[19,45,15,35,46,16],[17,145,115,1,146,116],[14,74,46,21,75,47],[29,54,24,19,55,25],[11,45,15,46,46,16],[13,145,115,6,146,116],[14,74,46,23,75,47],[44,54,24,7,55,25],[59,46,16,1,47,17],[12,151,121,7,152,122],[12,75,47,26,76,48],[39,54,24,14,55,25],[22,45,15,41,46,16],[6,151,121,14,152,122],[6,75,47,34,76,48],[46,54,24,10,55,25],[2,45,15,64,46,16],[17,152,122,4,153,123],[29,74,46,14,75,47],[49,54,24,10,55,25],[24,45,15,46,46,16],[4,152,122,18,153,123],[13,74,46,32,75,47],[48,54,24,14,55,25],[42,45,15,32,46,16],[20,147,117,4,148,118],[40,75,47,7,76,48],[43,54,24,22,55,25],[10,45,15,67,46,16],[19,148,118,6,149,119],[18,75,47,31,76,48],[34,54,24,34,55,25],[20,45,15,61,46,16]],w=function(n,s){var t={};return t.totalCount=n,t.dataCount=s,t},g={},l=function(n,s){switch(s){case O.L:return x[(n-1)*4+0];case O.M:return x[(n-1)*4+1];case O.Q:return x[(n-1)*4+2];case O.H:return x[(n-1)*4+3];default:return}};return g.getRSBlocks=function(n,s){var t=l(n,s);if(typeof t>"u")throw"bad rs block @ typeNumber:"+n+"/errorCorrectionLevel:"+s;for(var r=t.length/3,h=[],i=0;i<r;i+=1)for(var v=t[i*3+0],_=t[i*3+1],B=t[i*3+2],y=0;y<v;y+=1)h.push(w(_,B));return h},g}(),G=function(){var x=[],w=0,g={};return g.getBuffer=function(){return x},g.getAt=function(l){var n=Math.floor(l/8);return(x[n]>>>7-l%8&1)==1},g.put=function(l,n){for(var s=0;s<n;s+=1)g.putBit((l>>>n-s-1&1)==1)},g.getLengthInBits=function(){return w},g.putBit=function(l){var n=Math.floor(w/8);x.length<=n&&x.push(0),l&&(x[n]|=128>>>w%8),w+=1},g},$=function(x){var w=D.MODE_NUMBER,g=x,l={};l.getMode=function(){return w},l.getLength=function(t){return g.length},l.write=function(t){for(var r=g,h=0;h+2<r.length;)t.put(n(r.substring(h,h+3)),10),h+=3;h<r.length&&(r.length-h==1?t.put(n(r.substring(h,h+1)),4):r.length-h==2&&t.put(n(r.substring(h,h+2)),7))};var n=function(t){for(var r=0,h=0;h<t.length;h+=1)r=r*10+s(t.charAt(h));return r},s=function(t){if("0"<=t&&t<="9")return t.charCodeAt(0)-48;throw"illegal char :"+t};return l},W=function(x){var w=D.MODE_ALPHA_NUM,g=x,l={};l.getMode=function(){return w},l.getLength=function(s){return g.length},l.write=function(s){for(var t=g,r=0;r+1<t.length;)s.put(n(t.charAt(r))*45+n(t.charAt(r+1)),11),r+=2;r<t.length&&s.put(n(t.charAt(r)),6)};var n=function(s){if("0"<=s&&s<="9")return s.charCodeAt(0)-48;if("A"<=s&&s<="Z")return s.charCodeAt(0)-65+10;switch(s){case" ":return 36;case"$":return 37;case"%":return 38;case"*":return 39;case"+":return 40;case"-":return 41;case".":return 42;case"/":return 43;case":":return 44;default:throw"illegal char :"+s}};return l},V=function(x){var w=D.MODE_8BIT_BYTE,g=x,l=P.stringToBytes(x),n={};return n.getMode=function(){return w},n.getLength=function(s){return l.length},n.write=function(s){for(var t=0;t<l.length;t+=1)s.put(l[t],8)},n},q=function(x){var w=D.MODE_KANJI,g=x,l=P.stringToBytesFuncs.SJIS;if(!l)throw"sjis not supported.";(function(t,r){var h=l(t);if(h.length!=2||(h[0]<<8|h[1])!=r)throw"sjis not supported."})("\u53CB",38726);var n=l(x),s={};return s.getMode=function(){return w},s.getLength=function(t){return~~(n.length/2)},s.write=function(t){for(var r=n,h=0;h+1<r.length;){var i=(255&r[h])<<8|255&r[h+1];if(33088<=i&&i<=40956)i-=33088;else if(57408<=i&&i<=60351)i-=49472;else throw"illegal char at "+(h+1)+"/"+i;i=(i>>>8&255)*192+(i&255),t.put(i,13),h+=2}if(h<r.length)throw"illegal char at "+(h+1)},s},j=function(){var x=[],w={};return w.writeByte=function(g){x.push(g&255)},w.writeShort=function(g){w.writeByte(g),w.writeByte(g>>>8)},w.writeBytes=function(g,l,n){l=l||0,n=n||g.length;for(var s=0;s<n;s+=1)w.writeByte(g[s+l])},w.writeString=function(g){for(var l=0;l<g.length;l+=1)w.writeByte(g.charCodeAt(l))},w.toByteArray=function(){return x},w.toString=function(){var g="";g+="[";for(var l=0;l<x.length;l+=1)l>0&&(g+=","),g+=x[l];return g+="]",g},w},z=function(){var x=0,w=0,g=0,l="",n={},s=function(r){l+=String.fromCharCode(t(r&63))},t=function(r){if(!(r<0)){if(r<26)return 65+r;if(r<52)return 97+(r-26);if(r<62)return 48+(r-52);if(r==62)return 43;if(r==63)return 47}throw"n:"+r};return n.writeByte=function(r){for(x=x<<8|r&255,w+=8,g+=1;w>=6;)s(x>>>w-6),w-=6},n.flush=function(){if(w>0&&(s(x<<6-w),x=0,w=0),g%3!=0)for(var r=3-g%3,h=0;h<r;h+=1)l+="="},n.toString=function(){return l},n},rr=function(x){var w=x,g=0,l=0,n=0,s={};s.read=function(){for(;n<8;){if(g>=w.length){if(n==0)return-1;throw"unexpected end of file./"+n}var r=w.charAt(g);if(g+=1,r=="=")return n=0,-1;if(r.match(/^\s$/))continue;l=l<<6|t(r.charCodeAt(0)),n+=6}var h=l>>>n-8&255;return n-=8,h};var t=function(r){if(65<=r&&r<=90)return r-65;if(97<=r&&r<=122)return r-97+26;if(48<=r&&r<=57)return r-48+52;if(r==43)return 62;if(r==47)return 63;throw"c:"+r};return s},tr=function(x,w){var g=x,l=w,n=new Array(x*w),s={};s.setPixel=function(i,v,_){n[v*g+i]=_},s.write=function(i){i.writeString("GIF87a"),i.writeShort(g),i.writeShort(l),i.writeByte(128),i.writeByte(0),i.writeByte(0),i.writeByte(0),i.writeByte(0),i.writeByte(0),i.writeByte(255),i.writeByte(255),i.writeByte(255),i.writeString(","),i.writeShort(0),i.writeShort(0),i.writeShort(g),i.writeShort(l),i.writeByte(0);var v=2,_=r(v);i.writeByte(v);for(var B=0;_.length-B>255;)i.writeByte(255),i.writeBytes(_,B,255),B+=255;i.writeByte(_.length-B),i.writeBytes(_,B,_.length-B),i.writeByte(0),i.writeString(";")};var t=function(i){var v=i,_=0,B=0,y={};return y.write=function(T,E){if(T>>>E)throw"length over";for(;_+E>=8;)v.writeByte(255&(T<<_|B)),E-=8-_,T>>>=8-_,B=0,_=0;B=T<<_|B,_=_+E},y.flush=function(){_>0&&v.writeByte(B)},y},r=function(i){for(var v=1<<i,_=(1<<i)+1,B=i+1,y=h(),T=0;T<v;T+=1)y.add(String.fromCharCode(T));y.add(String.fromCharCode(v)),y.add(String.fromCharCode(_));var E=j(),N=t(E);N.write(v,B);var m=0,U=String.fromCharCode(n[m]);for(m+=1;m<n.length;){var H=String.fromCharCode(n[m]);m+=1,y.contains(U+H)?U=U+H:(N.write(y.indexOf(U),B),y.size()<4095&&(y.size()==1<<B&&(B+=1),y.add(U+H)),U=H)}return N.write(y.indexOf(U),B),N.write(_,B),N.flush(),E.toByteArray()},h=function(){var i={},v=0,_={};return _.add=function(B){if(_.contains(B))throw"dup key:"+B;i[B]=v,v+=1},_.size=function(){return v},_.indexOf=function(B){return i[B]},_.contains=function(B){return typeof i[B]<"u"},_};return s},er=function(x,w,g){for(var l=tr(x,w),n=0;n<w;n+=1)for(var s=0;s<x;s+=1)l.setPixel(s,n,g(s,n));var t=j();l.write(t);for(var r=z(),h=t.toByteArray(),i=0;i<h.length;i+=1)r.writeByte(h[i]);return r.flush(),"data:image/gif;base64,"+r};return P}();(function(){qrcode.stringToBytesFuncs["UTF-8"]=function(P){function D(O){for(var L=[],k=0;k<O.length;k++){var M=O.charCodeAt(k);M<128?L.push(M):M<2048?L.push(192|M>>6,128|M&63):M<55296||M>=57344?L.push(224|M>>12,128|M>>6&63,128|M&63):(k++,M=65536+((M&1023)<<10|O.charCodeAt(k)&1023),L.push(240|M>>18,128|M>>12&63,128|M>>6&63,128|M&63))}return L}return D(P)}})(),function(P){typeof define=="function"&&define.amd?define([],P):typeof exports=="object"&&(module.exports=P())}(function(){return qrcode});
</script>
<script>
"use strict";
/* ================= Utilitas ================= */
const $ = (s, el = document) => el.querySelector(s);
const esc = (v) => String(v ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
const SV = 'viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"';
const ICONS = {
  user: '<circle cx="12" cy="8" r="4"/><path d="M4 21a8 8 0 0 1 16 0"/>',
  phone: '<rect x="6" y="2.5" width="12" height="19" rx="2.5"/><path d="M11 18h2"/>',
  monitor: '<rect x="2.5" y="4" width="19" height="13" rx="2"/><path d="M8 21h8M12 17v4"/>',
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
  dl: '<path d="M12 4v11M7 10l5 5 5-5M5 20h14"/>',
  qr: '<rect x="3" y="3" width="7" height="7" rx="1"/><rect x="14" y="3" width="7" height="7" rx="1"/><rect x="3" y="14" width="7" height="7" rx="1"/><path d="M14 14h3v3h-3zM21 14v.01M14 21h.01M17 21h4v-4"/>',
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
  const o = { method: opts.method || "GET", headers: { "X-Idle": String(Math.floor((Date.now() - lastAct()) / 1000)) }, credentials: "same-origin" };
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
const ztTag = (x) => (x.transport === "zt" ? ` <span class="tag" title="Tersambung lewat ZeroTier">ZT</span>` : x.transport === "wg" ? ` <span class="tag violet" title="Tersambung lewat WireGuard">WG</span>` : "");
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
/* Cari menu dan router dari bar atas */
(function () {
  const inp = () => document.getElementById("tq"), box = () => document.getElementById("tsres");
  let sel = 0, list = [];
  const items = () => {
    const out = []; let grp = "";
    document.querySelectorAll(".side > *").forEach((el) => {
      if (el.classList.contains("nav-sec")) grp = el.textContent;
      else if (el.classList.contains("nav") && el.dataset.go && !el.classList.contains("hidden")) out.push({ t: el.textContent.trim(), g: grp, u: el.dataset.go });
    });
    for (const x of (STATE.sites || [])) out.push({ t: x.name, g: "Router" + (x.subnet ? " · " + x.subnet : "") + (x.vip ? " · " + x.vip : ""), u: "#/router/" + x.id, k: [x.subnet, x.vip, x.ip].filter(Boolean).join(" ") });
    return out;
  };
  const draw = () => {
    const q = inp().value.trim().toLowerCase(), b = box();
    if (!q) { b.classList.add("hidden"); return; }
    list = items().filter((x) => (x.t + " " + x.g + " " + (x.k || "")).toLowerCase().includes(q)).slice(0, 8);
    if (sel >= list.length) sel = 0;
    b.innerHTML = list.length ? list.map((x, i) => `<a href="${esc(x.u)}"${i === sel ? ' class="on"' : ""}><b>${esc(x.t)}</b><small>${esc(x.g)}</small></a>`).join("") : '<div class="none">Tidak ditemukan</div>';
    b.classList.remove("hidden");
  };
  const done = () => { inp().value = ""; box().classList.add("hidden"); inp().blur(); };
  document.addEventListener("input", (e) => { if (e.target.id === "tq") { sel = 0; draw(); } });
  document.addEventListener("keydown", (e) => {
    if (e.target.id === "tq") {
      if (e.key === "ArrowDown") { sel = Math.min(sel + 1, list.length - 1); draw(); e.preventDefault(); }
      else if (e.key === "ArrowUp") { sel = Math.max(sel - 1, 0); draw(); e.preventDefault(); }
      else if (e.key === "Enter") { if (list[sel]) { location.hash = list[sel].u; done(); } e.preventDefault(); }
      else if (e.key === "Escape") done();
    } else if (e.key === "/" && !/INPUT|TEXTAREA|SELECT/.test((document.activeElement || {}).tagName || "") && inp()) { e.preventDefault(); inp().focus(); }
  });
  document.addEventListener("click", (e) => { if (!e.target.closest(".tsearch") && box()) box().classList.add("hidden"); else if (e.target.closest(".tsres a")) setTimeout(done, 0); });
})();
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
// Halaman yang perlu dimuat ulang setelah proses selesai, ditunda sampai jendela ditutup
let ROUTE_AFTER_CLOSE = false;
function closeModal() {
  if (typeof CF !== "undefined" && CF && CF.running && $("#cfSteps")) return; // proses domain sedang berjalan
  $("#modalRoot").innerHTML = ""; if (TEST && !TEST.keep) TEST = null;
  if (ROUTE_AFTER_CLOSE) { ROUTE_AFTER_CLOSE = false; setTimeout(route, 0); }
}
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

/* ================= Logout otomatis saat diam ================= */
// Aktivitas nyata (klik, ketik, sentuh, gulir, pindah halaman) dicatat di localStorage agar
// berlaku untuk semua tab. Penyegaran otomatis tidak dihitung sebagai aktivitas.
let ACT_MEM = Date.now(), IDLE_MS = 60 * 60e3, IDLE_TIMER = null, BEAT_AT = 0;
function lastAct() {
  let v = 0; try { v = parseInt(localStorage.getItem("vpnacs-act"), 10) || 0; } catch (e) {}
  return Math.max(ACT_MEM, v);
}
function markAct() {
  const n = Date.now();
  if (n - ACT_MEM < 2000) return;
  ACT_MEM = n; try { localStorage.setItem("vpnacs-act", String(n)); } catch (e) {}
}
["click", "keydown", "touchstart", "wheel", "scroll"].forEach((ev) => window.addEventListener(ev, markAct, { passive: true, capture: true }));
window.addEventListener("hashchange", markAct);
async function idleStart() {
  markAct(); ACT_MEM = Date.now();
  try { const r = await api("/api/session"); IDLE_MS = r.idleMs || IDLE_MS; } catch (e) { return; }
  clearInterval(IDLE_TIMER);
  IDLE_TIMER = setInterval(idleTick, 5000);
}
async function idleTick() {
  if (!LOADED || $("#appView").classList.contains("hidden")) return;
  const idle = Date.now() - lastAct();
  // Ada aktivitas sejak tanda terakhir: beri tahu server (paling sering 1x per menit)
  if (lastAct() > BEAT_AT && Date.now() - BEAT_AT > 60e3) { BEAT_AT = Date.now(); api("/api/session", { method: "POST" }).catch(() => {}); }
  if (idle < IDLE_MS - 60e3 || $("#idleWarn")) return;
  // Pastikan ke server: mungkin tab lain masih dipakai
  let remain = 0;
  try { remain = (await api("/api/session")).remainMs; } catch (e) { return; }
  if (remain > 65e3) { ACT_MEM = Date.now() - (IDLE_MS - remain); return; }
  idleWarn(remain);
}
function idleWarn(remain) {
  const end = Date.now() + Math.max(5e3, remain);
  const el = document.createElement("div");
  el.id = "idleWarn"; el.className = "mbg idle-bg";
  el.innerHTML = `<div class="modal dlg sm" role="alertdialog" aria-modal="true"><div class="dlg-b"><span class="dlg-ic info">${ic("clock")}</span>
    <div style="flex:1;min-width:0"><h2>Sesi akan berakhir</h2><div class="dlg-t">Tidak ada aktivitas selama ${esc(fmtDurShort(IDLE_MS))}. Panel keluar otomatis dalam <b id="idleSec">60</b> detik.</div></div></div>
    <div class="mf"><button class="btn" id="idleOut">Keluar</button><button class="btn pri" id="idleStay">Tetap masuk</button></div></div>`;
  document.body.appendChild(el);
  paintIcons(el);
  $("#idleStay").focus();
  const t = setInterval(() => {
    if (!document.body.contains(el)) return clearInterval(t);
    if (lastAct() > Date.now() - 3000 && document.activeElement !== $("#idleStay")) { /* aktivitas dari tab lain */ }
    const left = Math.max(0, Math.ceil((end - Date.now()) / 1000));
    if ($("#idleSec")) $("#idleSec").textContent = left;
    if (left <= 0) { clearInterval(t); idleLogout(true); }
  }, 500);
  $("#idleStay").onclick = async () => { clearInterval(t); el.remove(); ACT_MEM = 0; markAct(); try { await api("/api/session", { method: "POST" }); toast("Sesi diperpanjang"); } catch (e) {} };
  $("#idleOut").onclick = () => { clearInterval(t); idleLogout(false); };
}
async function idleLogout(auto) {
  const w = $("#idleWarn"); if (w) w.remove();
  clearInterval(IDLE_TIMER);
  await fetch("/api/logout", { method: "POST", headers: { "Content-Type": "application/json" }, body: "{}", credentials: "same-origin" }).catch(() => {});
  LOADED = false; closeModal(); showLogin();
  if (auto) $("#loginErr").innerHTML = `<span style="color:var(--muted)">Anda keluar otomatis karena tidak ada aktivitas.</span>`;
}
function fmtDurShort(ms) { const m = Math.round(ms / 60e3); return m >= 60 ? `${m / 60} jam` : `${m} menit`; }

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
  try { await api("/api/login", { method: "POST", body: { password: $("#lp").value } }); $("#lp").value = ""; showApp(); await load(); route(); idleStart(); }
  catch (err) { $("#loginErr").textContent = err.message; }
  busyBtn(btn, false);
});

/* ================= Data ================= */
async function load() {
  STATE = await api("/api/overview");
  LOADED = true;
  const U = STATE.settings.updates || {};
  const nUp = (U.panel ? 1 : 0) + (U.addons || []).length;
  $("#ver").innerHTML = (STATE.settings.version ? "v" + esc(STATE.settings.version) : "") + (nUp ? ` <a class="upd-dot" href="${U.panel ? "#/pengaturan/umum" : "#/addon"}" title="${nUp} pembaruan tersedia">${nUp} pembaruan</a>` : "");
  setBrand(STATE.settings.panelName);
  const A = STATE.settings.addons || {};
  $("#navZt").classList.toggle("hidden", !(A.zerotier && A.zerotier.installed));
  $("#navWg").classList.toggle("hidden", !(A.wireguard && A.wireguard.installed));

}
function ztOn() { const a = (STATE.settings.addons || {}).zerotier; return !!(a && a.installed); }
function wgOn() { const a = (STATE.settings.addons || {}).wireguard; return !!(a && a.installed); }
const TRL = { l2tp: "L2TP", zt: "ZeroTier", wg: "WireGuard" };

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
  el.innerHTML = `<div class="note bad">${ic("alert")}<div><b>Password admin masih bawaan (Admin123)</b>${P.active ? "Panel terbuka di port web standar sehingga mudah ditemukan orang. " : ""}Siapa pun yang mencoba Admin123 bisa masuk dan mengubah router Anda. Segera ganti password.</div>${onSet ? "" : `<a class="btn pri" href="#/pengaturan/umum">Ganti password</a>`}</div>`;
}
/* ---------- Perbarui tampilan tanpa menggambar ulang halaman ----------
   Isi baru dibuat di luar layar lalu hanya bagian yang berubah yang disalin
   ke halaman (angka, teks, baris). Scroll, menu terbuka, fokus, dan tab tetap. */
function morph(a, b, inner = true) {
  // inner = true (panggilan luar): hanya isi yang disamakan, atribut wadah (id, class) tidak disentuh
  if (!inner && (a.nodeType !== b.nodeType || a.nodeName !== b.nodeName)) { a.replaceWith(b.cloneNode(true)); return; }
  if (a.nodeType === 3 || a.nodeType === 8) { if (a.nodeValue !== b.nodeValue) a.nodeValue = b.nodeValue; return; }
  if (a.nodeType !== 1) return;
  if (a === document.activeElement && /^(INPUT|SELECT|TEXTAREA)$/.test(a.nodeName)) return;
  if (!inner) {
    const wasOpen = a.nodeName === "DETAILS" && a.open;
    for (const at of [...a.attributes]) if (!b.hasAttribute(at.name) && !(at.name === "open" && wasOpen)) a.removeAttribute(at.name);
    for (const at of [...b.attributes]) if (a.getAttribute(at.name) !== at.value) a.setAttribute(at.name, at.value);
  }
  const ac = [...a.childNodes], bc = [...b.childNodes];
  for (let i = 0; i < bc.length; i++) { if (i < ac.length) morph(ac[i], bc[i], false); else a.appendChild(bc[i].cloneNode(true)); }
  for (let i = bc.length; i < ac.length; i++) ac[i].remove();
}
function liveRefresh() {
  const h = location.hash || "#/";
  const v = $("#view");
  if ((h === "#/" || h === "#") && v.querySelector(".grid-dash")) {
    const tmp = document.createElement("div");
    viewDashboard(tmp, true);
    paintIcons(tmp);
    morph(v, tmp);
    return;
  }
  if (h === "#/router" && $("#q")) { fillList(); return; }
  route();
}
// Tombol aksi halaman (.ph .acts) dipindah ke baris breadcrumb, karena judul dan deskripsi halaman disembunyikan
function hoistActs() {
  const ph = document.querySelector("#view > .ph"), pa = $("#pActs");
  if (!ph || !pa) return;
  const acts = ph.querySelector(".acts");
  if (acts) pa.replaceChildren(acts);
}
new MutationObserver(hoistActs).observe(document.getElementById("view"), { childList: true });
let LAST_HASH = "";
function route() {
  if (!LOADED) return;
  let h = location.hash || "#/";
  const same = h === LAST_HASH, keepY = same ? window.scrollY : 0;
  LAST_HASH = h;
  if (/^#\/(lokasi|server)(\/|$)/.test(h)) { h = h.replace(/^#\/(lokasi|server)/, "#/router"); history.replaceState(null, "", h); }
  if (/^#\/pengaturan\/zerotier/.test(h)) { h = "#/zerotier"; history.replaceState(null, "", h); }
  const parts = h.replace(/^#\/?/, "").split("/").filter(Boolean);
  document.querySelectorAll(".nav[data-go]").forEach((n) => {
    const g = n.dataset.go.replace(/^#\/?/, "");
    n.classList.toggle("on", (g === "" && parts.length === 0) || (g && parts[0] === g));
  });
  if (!same) {
    document.body.classList.remove("nav-open");
    document.querySelectorAll(".menu-list").forEach((m) => m.classList.add("hidden"));
    closeModal();
  }
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
  else if (parts[0] === "wireguard" && !wgOn()) { location.hash = "#/addon"; return; }
  else if (parts[0] === "wireguard") { viewWireguard(v); title = "WireGuard"; }
  else if (parts[0] === "addon") { viewAddons(v); title = "Add-on"; }
  else if (parts[0] === "log") { viewLog(v); title = "Log aktivitas"; }
  else { viewDashboard(v); }
  document.title = `${title} · ${BRAND}`;
  paintIcons(v);
  hoistActs();
  window.scrollTo(0, keepY);
}
function crumb(items) {
  if (items[0][0] !== "Dashboard") items = [["Dashboard", "#/"]].concat(items);
  const pa = $("#pActs"); if (pa) pa.innerHTML = "";
  $("#crumb").innerHTML = `<a href="#/" aria-label="Dashboard">${ic("home")}</a>` + items.slice(1).map((x, i, a) => ic("chev") + (i < a.length - 1 ? `<a href="${x[1]}">${esc(x[0])}</a>` : `<b>${esc(x[0])}</b>`)).join("") + (items.length === 1 ? ic("chev") + `<b>Dashboard</b>` : "");
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
  for (const x of STATE.sites.filter((y) => y.wgStale && y.transport === "wg")) list.push({ t: `${x.name}: pasang ulang script WireGuard`, d: "Port, rentang, atau kunci WireGuard berubah. Salin script terbaru ke MikroTik.", go: `#/router/${x.id}/script` });
  for (const x of STATE.sites.filter((y) => y.ztStale && y.transport === "zt")) list.push({ t: `${x.name}: pasang ulang script ZeroTier`, d: "IP ZeroTier VPS berubah. Salin script terbaru ke MikroTik.", go: `#/router/${x.id}/script` });
  const tg = s.telegram || {};
  if (tg.active && tg.lastError) list.push({ t: "Notifikasi Telegram gagal terkirim", d: tg.lastError, go: "#/pengaturan/telegram" });
  const cf = s.cloudflare;
  if (cf && cf.https && cf.certExpiry && cf.certExpiry - Date.now() < 14 * 864e5) list.push({ t: "Sertifikat HTTPS hampir habis", d: `Berlaku sampai ${fmtT(cf.certExpiry, true)}. Perpanjangan otomatis mungkin gagal.`, go: "#/pengaturan/domain" });
  for (const x of STATE.sites) {
    if (x.inGenie === false) list.push({ t: `${x.name}: IP virtual di luar patch GenieACS`, d: `${x.virtualSubnet} tidak dikenali GenieACS, Summon akan gagal.`, go: `#/router/${x.id}` });
  }
  const UP = STATE.settings.updates || {};
  if (UP.panel) list.push({ k: "info", t: `Pembaruan panel v${UP.latest} tersedia`, d: "Perbarui dari Pengaturan → Umum → Pembaruan panel.", go: "#/pengaturan/umum" });
  if ((UP.addons || []).length) list.push({ k: "info", t: `${UP.addons.length} add-on punya pembaruan`, d: UP.addons.map((id) => ((STATE.settings.addons || {})[id] || {}).name || id).join(", "), go: "#/addon" });
  const pend = STATE.sites.filter((x) => x.state === "pending");
  for (const x of STATE.sites.filter((y) => y.transport === "zt" && !y.ztNode)) list.push({ k: "info", t: `${x.name}: router ZeroTier belum dipilih`, d: "Pasang script, lalu pilih router dari daftar yang bergabung.", go: `#/router/${x.id}` });
  if (pend.length === 1) list.push({ k: "info", t: `${pend[0].name} menunggu pemasangan`, d: "Script MikroTik belum dipasang atau belum pernah tersambung.", go: `#/router/${pend[0].id}/script` });
  else if (pend.length > 1) list.push({ k: "info", t: `${pend.length} router menunggu pemasangan`, d: pend.map((x) => x.name).slice(0, 4).join(", ") + (pend.length > 4 ? ` dan ${pend.length - 4} lainnya` : ""), go: "#/router/menunggu" });
  return list;
}
let DASH_TAB = "uptime"; // tab yang terbuka di kartu kiri Dashboard
function viewDashboard(v, live) {
  crumb([["Dashboard"]]);
  const S = STATE.sites, inst = S.filter((x) => x.state !== "pending"), on = S.filter((x) => x.state === "up").length;
  const off = S.filter((x) => x.state === "down").length, pend = S.length - inst.length;
  const u7 = inst.map((x) => x.uptime && x.uptime.d7).filter((x) => x != null);
  const avg = u7.length ? u7.reduce((a, b) => a + b, 0) / u7.length : null;
  const iss = issues();
  const issK = iss.some((x) => (x.k || "warn") === "bad") ? "" : iss.some((x) => (x.k || "warn") === "warn") ? "warn" : "info";
  if (DASH_TAB === "issues" && !iss.length) DASH_TAB = "uptime";
  $("#pActs").innerHTML = `<span class="pupd">Terakhir diperbarui: <b>${new Date().toLocaleTimeString("id-ID", { hour: "2-digit", minute: "2-digit", second: "2-digit" }).replace(/\./g, ":")}</b></span><button class="btn pri" data-act="add">${ic("plus")}Tambah router</button>`;
  v.innerHTML = `
    <div class="kpis">
      <div class="kpi"><span><i class="kico blue">${ic("router")}</i>Total router</span><b>${S.length}</b><small>${pend ? `${pend} menunggu pemasangan` : "MikroTik terdaftar"}</small></div>
      <div class="kpi"><span><i class="kico green">${ic("check")}</i>Tersambung</span><b>${on}</b><small>${inst.length ? Math.round((on / inst.length) * 100) : 0}% dari router terpasang</small></div>
      <div class="kpi"><span><i class="kico red">${ic("x")}</i>Terputus</span><b>${off}</b><small>${off ? "perlu dicek" : "tidak ada"}</small></div>
      <div class="kpi"><span><i class="kico amber">${ic("pulse")}</i>Rata-rata uptime</span><b class="${pctCls(avg)}" style="${avg != null && avg < 99 ? `color:var(--${avg >= 95 ? "warn" : "bad"})` : ""}">${pct(avg)}</b><small>7 hari terakhir</small></div>
    </div>
    <div class="grid-dash">
      <div class="card">
        <div class="ch"><div class="dtabs" role="tablist">
          <button type="button" role="tab" data-dtab="uptime" class="${DASH_TAB === "uptime" ? "on" : ""}" aria-selected="${DASH_TAB === "uptime"}">Uptime router</button>
          <button type="button" role="tab" data-dtab="issues" class="${DASH_TAB === "issues" ? "on" : ""}" aria-selected="${DASH_TAB === "issues"}">Perlu perhatian${iss.length ? `<span class="n ${issK}">${iss.length}</span>` : ""}</button>
        </div>${DASH_TAB === "uptime" && S.length ? `<span class="muted hide-sm" style="font-size:12.5px">Klik baris untuk riwayat lengkap</span>` : ""}</div>
        <div data-dpane="uptime"${DASH_TAB === "uptime" ? "" : " hidden"}>
          ${S.length ? uptimeTable(S) : `<div class="empty"><h3>Belum ada router</h3><p>Tambahkan MikroTik pertama untuk mulai.</p><button class="btn pri" style="margin-top:12px" data-act="add">${ic("plus")}Tambah router</button></div>`}
        </div>
        <div data-dpane="issues"${DASH_TAB === "issues" ? "" : " hidden"}>
          ${iss.length ? `<ul class="rows">${iss.map((x) => `<li><a class="row ${x.k || "warn"}" href="${x.go}"><span class="ic">${ic(x.k === "info" ? "clock" : "alert")}</span><span class="grow"><span class="nm">${esc(x.t)}</span><span class="sb" style="display:block">${esc(x.d)}</span></span><span class="chev">${ic("chev")}</span></a></li>`).join("")}</ul>`
            : `<div class="empty"><div class="big">${ic("check")}</div><h3>Semua normal</h3><p>Semua router tersambung dan pengaturan lengkap.</p></div>`}
        </div>
      </div>
      <div class="stack">
        <div id="dashHealth">${HEALTH_HTML}</div>
        ${dashApps()}
        <div class="card">
          <div class="ch"><h2>VPS</h2><a href="#/pengaturan">Pengaturan</a></div>
          ${serverKv()}
        </div>
      </div>
    </div>`;
  if (live) { dashHealth(); return; }
  v.querySelectorAll("[data-dtab]").forEach((b) => (b.onclick = () => {
    DASH_TAB = b.dataset.dtab;
    v.querySelectorAll("[data-dtab]").forEach((x) => { x.classList.toggle("on", x === b); x.setAttribute("aria-selected", x === b); });
    v.querySelectorAll("[data-dpane]").forEach((p) => (p.hidden = p.dataset.dpane !== DASH_TAB));
    const hint = b.closest(".ch").querySelector(".muted"); if (hint) hint.hidden = DASH_TAB !== "uptime";
  }));
  dashHealth();
}
// Add-on yang terpasang, dibuka langsung dari Dashboard
function dashApps() {
  // Hanya aplikasi web terpasang yang dibuka di tab baru (Bilingku, Panel ACS); add-on sistem (ZeroTier, WireGuard) punya menu sendiri
  const A = Object.entries(STATE.settings.addons || {}).filter(([, a]) => a.installed && a.kind === "aplikasi").map(([id, a]) => Object.assign({ id }, a));
  if (!A.length) return "";
  A.sort((x, y) => x.name.localeCompare(y.name));
  return `<div class="card"><div class="ch"><h2>Aplikasi</h2><a href="#/addon">Kelola</a></div>
    <ul class="dapps">${A.map((a) => `<li>${adIcon(a, "sm")}<span class="grow"><b>${esc(a.name)}</b><small>${esc(a.tagline || "")}</small></span>${a.kind === "aplikasi"
      ? `<a class="btn sm" href="${esc(adHref(a))}" target="_blank" rel="noopener">${ic("ext")}Buka</a>`
      : `<a class="btn sm" href="#/${esc(a.id)}">Buka</a>`}</li>`).join("")}</ul></div>`;
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
  return genie + [["Alamat VPS", s.publicIp || "—"], ["URL ACS ONT", s.acsUrl || "—"], ["Jaringan VPN", s.tunnelNet || "—"], ["ZeroTier", zt], ...(s.wg ? [["WireGuard", `${s.wg.subnet} · UDP ${s.wg.port}`]] : []), ["Patch GenieACS", g], ["Notifikasi Telegram", tgs], ["HTTPS panel", https]]
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
      <div class="ch"><h2>Daftar router</h2><span class="muted" style="font-size:12.5px">${STATE.sites.length} router</span></div>
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
// Tab di dalam halaman (tanpa pindah alamat): [kunci, judul, ikon, angka/tanda]
const subTabs = (list, cur) => `<nav class="tabs subtabs" role="tablist">${list.map(([k, t, i, n]) => `<button type="button" role="tab" class="tab ${k === cur ? "on" : ""}" data-st="${k}" aria-selected="${k === cur}">${ic(i, "")}${t}${n ? `<span class="tcnt${n === "!" ? " warn" : ""}">${n}</span>` : ""}</button>`).join("")}</nav>`;
function bindSubTabs(root, set) {
  root.querySelectorAll(":scope > .subtabs [data-st]").forEach((btn) => (btn.onclick = () => {
    set(btn.dataset.st);
    root.querySelectorAll(":scope > .subtabs [data-st]").forEach((x) => { x.classList.toggle("on", x === btn); x.setAttribute("aria-selected", x === btn); });
    root.querySelectorAll(":scope > [data-pane]").forEach((p) => (p.hidden = p.dataset.pane !== btn.dataset.st));
  }));
}
const tabsHtml = (list, cur, base) => `<nav class="tabs">${list.map(([k, t, i]) => `<a class="tab ${k === cur ? "on" : ""}" href="${base}/${k}">${ic(i, "")}${t}</a>`).join("")}</nav>`;
function viewDetail(v, id, tab) {
  const x = site(id);
  if (!x) { crumb([["Router", "#/router"], ["Tidak ditemukan"]]); v.innerHTML = `<div class="card"><div class="empty"><h3>Router tidak ditemukan</h3><p><a href="#/router">Kembali ke daftar router</a></p></div></div>`; return; }
  if (tab === "remote") { tab = "port"; history.replaceState(null, "", `#/router/${id}/port`); }
  if (!TABS.some(([k]) => k === tab)) tab = "ringkasan";
  crumb([["Router", "#/router"], [x.name]]);
  v.innerHTML = `
    <div class="dh">
      <div><h1>${esc(x.name)} <span class="pill ${stOf(x)[0]}">${stOf(x)[1]}</span> <span class="tag ${x.transport === "zt" ? "" : x.transport === "wg" ? "violet" : "gray"}">${TRL[x.transport] || "L2TP"}</span></h1>
        ${x.note ? `<p>${esc(x.note)}</p>` : ""}</div>
      <div class="acts" style="display:flex;gap:8px">
        ${tab === "ringkasan" ? "" : `<button class="btn" data-act="test" data-id="${x.id}">${ic("play")}Tes koneksi</button>`}
        <div class="menu"><button class="btn icon" data-act="menu" aria-label="Lainnya">${ic("dots")}</button>
          <div class="menu-list hidden" id="menuList">
            <button data-act="edit" data-id="${x.id}">${ic("edit")}Ubah router</button>
            <button data-act="transport" data-id="${x.id}">${ic("share")}Ubah jalur VPN</button>
            ${x.transport === "zt" ? `<button data-act="ztpick" data-id="${x.id}">${ic("hub")}Pilih router ZeroTier</button>` : x.transport === "wg" ? `<button data-act="wgrekey" data-id="${x.id}">${ic("key")}Buat kunci WireGuard baru</button>` : `<button data-act="resetpw" data-id="${x.id}">${ic("key")}Buat password VPN baru</button>`}
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
function detSide(x) {
  const [c, t] = stOf(x);
  const U = x.uptime;
  const bar = (k, label) => U && U[k] != null ? `<div class="ds-up"><span>${label}</span><b class="${pctCls(U[k])}">${pct(U[k])}</b><div class="zt-bar"><i style="width:${Math.max(0, Math.min(100, U[k]))}%;background:${U[k] >= 99 ? "var(--ok)" : U[k] >= 95 ? "var(--warn)" : "var(--bad)"}"></i></div></div>` : "";
  const since = x.state === "down" && x.downSince ? `Terputus ${fmtDur(Date.now() - x.downSince)}` : x.state === "pending" ? "Belum pernah tersambung" : x.incidents30 ? `${x.incidents30}× putus dalam 30 hari` : "Stabil 30 hari terakhir";
  return `<div class="det-side">
    <div class="card"><div class="ch"><h2>Status koneksi</h2><span class="pill ${c}">${t}</span></div>
      <div class="ds-body">
        <div class="ds-kv"><span>Jalur</span><b>${x.transport === "zt" ? "ZeroTier" : x.transport === "wg" ? "WireGuard" : "VPN L2TP"}</b></div>
        ${x.transport === "wg" && x.wg ? `<div class="ds-kv"><span>Handshake</span><b>${x.wg.handshake ? esc(ztAgo(x.wg.handshake)) : "belum pernah"}</b></div>` : ""}
        <div class="ds-kv"><span>Keterangan</span><b>${esc(since)}</b></div>
        ${U ? `${bar("d1", "24 jam")}${bar("d7", "7 hari")}${bar("d30", "30 hari")}` : `<p class="muted zt-small" style="margin-top:6px">Uptime tampil setelah router tersambung.</p>`}
      </div></div>
    <div class="card zt-actc">
      <button class="btn pri" data-act="test" data-id="${x.id}">${ic("play")}Tes koneksi</button>
      <a class="btn" href="#/router/${x.id}/script">${ic("code")}Script MikroTik</a>
      <a class="btn" href="#/router/${x.id}/riwayat">${ic("pulse")}Riwayat koneksi</a>
    </div>
  </div>`;
}
function tabSummary(b, x) {
  b.innerHTML = `<div class="det-grid"><div class="det-main">
    ${x.inGenie === false ? `<div class="note warn">${ic("alert")}<div><b>IP virtual di luar rentang patch GenieACS</b>Panel belum berhasil memperbarui setting GenieACS untuk ${esc(x.virtualSubnet)}, jadi Summon ke ONT di router ini akan gagal. Buka menu <a href="#/genieacs">GenieACS</a> untuk melihat statusnya.</div></div>` : ""}
    ${x.state === "pending" && !(x.transport === "zt" && !x.ztNode) ? `<div class="note info">${ic("clock")}<div><b>Menunggu pemasangan</b>Router ini belum pernah tersambung. Pasang script lewat tab <a href="#/router/${x.id}/script">Script MikroTik</a>. Riwayat dan notifikasi Telegram mulai berjalan setelah MikroTik tersambung pertama kali.</div></div>` : ""}
    ${x.state === "down" ? `<div class="note warn">${ic("alert")}<div><b>Terputus${x.downSince ? ` sejak ${esc(fmtT(x.downSince, true))} (${fmtDur(Date.now() - x.downSince)})` : ""}</b>Jalankan <a href="#" data-act="test" data-id="${x.id}">tes koneksi</a> untuk melihat penyebabnya.</div></div>` : ""}
    <div class="card">
      <div class="ch"><h2>Jaringan</h2></div>
      <dl class="dl" style="margin:0">
        <div><dt>Subnet ONT (asli)</dt><dd>${esc(x.realSubnet)}</dd></div>
        <div><dt>IP virtual di GenieACS</dt><dd>${esc(x.virtualSubnet)}</dd></div>
        <div><dt>URL ACS untuk ONT</dt><dd>${esc(x.acsUrl)} ${copyBtn(x.acsUrl, "URL ACS tersalin")}</dd></div>
        <div><dt>${x.transport === "zt" ? "IP ZeroTier MikroTik" : x.transport === "wg" ? "IP WireGuard MikroTik" : "IP VPN MikroTik"}</dt><dd>${x.transport === "wg" ? esc(x.wgIp || "—") : x.transport === "zt" ? (x.ztIp ? esc(x.ztIp) : '<span class="muted">Belum dipilih</span>') : esc(x.tunnelIp)}</dd></div>
      </dl>
    </div>
    ${x.transport === "zt" ? ztCard(x) : x.transport === "wg" ? wgCard(x) : `<div class="card">
      <div class="ch"><h2>Akun VPN</h2></div>
      <dl class="dl" style="margin:0">
        <div><dt>Alamat VPS (connect-to)</dt><dd>${esc(STATE.settings.publicIp || "—")}</dd></div>
        <div><dt>Username</dt><dd>${esc(x.username)} ${copyBtn(x.username)}</dd></div>
        <div><dt>Password</dt><dd><span id="pwv">••••••••••••</span><button class="copy" data-act="showpw" title="Lihat">${ic("eye", "")}</button>${copyBtn(x.password, "Password tersalin")}</dd></div>
        <div><dt>IPsec</dt><dd>${STATE.settings.useIpsec ? "Aktif" : "Tidak dipakai"}</dd></div>
      </dl>
    </div>`}</div>${detSide(x)}</div>`;
}
// ---------- Ubah jalur VPN (L2TP / WireGuard / ZeroTier) ----------
const TR_DESC = {
  l2tp: ["L2TP", "Semua versi RouterOS (v6 dan v7). Paling umum.", "lock"],
  wg: ["WireGuard", "RouterOS v7, semua jenis router. Ringan dan cepat (UDP).", "bolt"],
  zt: ["ZeroTier", "RouterOS v7 ARM/ARM64 dengan paket zerotier.", "hub"],
};
// Baris MikroTik untuk menghapus jalur lama saja (route, NAT, dan firewall diganti oleh script jalur baru)
function trRemoveScript(tr) {
  if (tr === "zt") return `# Hapus jalur ZeroTier lama\n:do { /zerotier interface remove [find where name="zt-acs"] } on-error={}\n:put "Jalur ZeroTier lama dihapus."`;
  if (tr === "wg") return `# Hapus jalur WireGuard lama\n:do { /ip address remove [find where interface="wg-acs"] } on-error={}\n:do { /interface wireguard peers remove [find where interface="wg-acs"] } on-error={}\n:do { /interface wireguard remove [find where name="wg-acs"] } on-error={}\n:put "Jalur WireGuard lama dihapus."`;
  return `# Hapus jalur L2TP lama\n:do { /interface l2tp-client remove [find where name="l2tp-acs"] } on-error={}\n:put "Jalur L2TP lama dihapus."`;
}
function openTransport(id) {
  const x = site(id); if (!x) return;
  const cur = x.transport || "l2tp";
  const avail = { l2tp: true, wg: !!STATE.settings.wg, zt: !!STATE.settings.zt };
  const why = { wg: wgOn() ? "WireGuard belum siap di VPS" : "Pasang add-on WireGuard dulu", zt: ztOn() ? "Hubungkan VPS ke jaringan di menu ZeroTier dulu" : "Pasang add-on ZeroTier dulu" };
  const opts = ["l2tp", "wg", "zt"].filter((k) => k !== cur);
  modal(`Ubah jalur VPN · ${esc(x.name)}`, `
    <p class="muted" style="margin-top:0">Jalur sekarang: <b style="color:var(--text)">${esc(TR_DESC[cur][0])}</b>. Pilih jalur baru:</p>
    <div class="tr-opts">${opts.map((k, i) => `<label class="tr-opt${avail[k] ? "" : " dis"}"><input type="radio" name="trNew" value="${k}" ${avail[k] && !opts.slice(0, i).some((o) => avail[o]) ? "checked" : ""} ${avail[k] ? "" : "disabled"}>
      <span class="tr-ic">${ic(TR_DESC[k][2])}</span><span class="tr-tx"><b>${TR_DESC[k][0]}</b><small>${avail[k] ? TR_DESC[k][1] : esc(why[k])}</small></span></label>`).join("")}</div>
    <div class="note info" style="margin-top:14px">${ic("info")}<div><b>Yang terjadi</b>Akses jalur lama di VPS langsung dicabut. IP virtual, port forwarding, dan URL ACS tetap sama. Setelah ini panel menampilkan script untuk <strong>menghapus jalur lama</strong> di MikroTik dan script <strong>jalur baru</strong>.</div></div>
    <div class="err" id="trErr"></div>`,
    `<button class="btn" data-act="closemodal">Batal</button><button class="btn pri" id="trOk" ${opts.some((k) => avail[k]) ? "" : "disabled"}>Ubah jalur</button>`, { size: "md" });
  $("#trOk").onclick = async () => {
    const to = (document.querySelector("input[name=trNew]:checked") || {}).value;
    if (!to) return;
    $("#trErr").textContent = ""; busyBtn($("#trOk"), true);
    try {
      await api(`/api/sites/${x.id}`, { method: "PUT", body: { name: x.name, realSubnet: x.realSubnet, virtualSubnet: x.virtualSubnet, note: x.note || "", transport: to } });
      await load();
      trDoneDialog(site(x.id), cur, to);
    } catch (e) { $("#trErr").textContent = e.message; busyBtn($("#trOk"), false); }
  };
}
function trDoneDialog(x, from, to) {
  const rm = trRemoveScript(from);
  modal(`Jalur diubah ke ${esc(TR_DESC[to][0])}`, `
    <p style="margin-top:0">Pasang di MikroTik <b>${esc(x.name)}</b> lewat Winbox → New Terminal, berurutan:</p>
    <ol class="tr-steps">
      <li><b>Pasang jalur baru ${esc(TR_DESC[to][0])}</b>
        <div class="codebox"><pre class="code" style="max-height:170px;padding-top:46px">${esc(x.script)}</pre><button class="btn sm" data-copy="${esc(x.script)}" data-msg="Script jalur baru tersalin">${ic("copy")}Salin</button></div></li>
      <li><b>Hapus jalur lama ${esc(TR_DESC[from][0])}</b>
        <div class="codebox"><pre class="code" style="padding-top:46px">${esc(rm)}</pre><button class="btn sm" data-copy="${esc(rm)}" data-msg="Script hapus jalur lama tersalin">${ic("copy")}Salin</button></div></li>
    </ol>
    <div class="note warn">${ic("alert")}<div><b>Jangan lewat remote panel</b>Bila Winbox tersambung lewat port forwarding panel (jalur lama), koneksi akan terputus saat jalur diganti. Pakai Winbox lokal atau IP publik MikroTik.</div></div>
    ${to === "zt" ? `<p class="help">ZeroTier: setelah script dipasang, router melapor Node ID ke panel dan dipilih otomatis.</p>` : ""}`,
    `<button class="btn" id="trScript">${ic("code")}Buka tab Script</button><button class="btn pri" data-act="closemodal">Selesai</button>`, { size: "lg" });
  ROUTE_AFTER_CLOSE = true;
  $("#trScript").onclick = () => { ROUTE_AFTER_CLOSE = false; closeModal(); location.hash = `#/router/${x.id}/script`; };
}
function wgStaleNote(x, style) {
  return x.wgStale ? `<div class="note warn"${style ? ` style="${style}"` : ""}>${ic("alert")}<div><b>Pasang ulang script WireGuard</b>Port, rentang IP, atau kunci WireGuard berubah. Salin script terbaru dari tab <a href="#/router/${x.id}/script">Script MikroTik</a> ke MikroTik, lalu klik <a href="#" data-act="wgdone" data-id="${x.id}">Sudah dipasang</a>.</div></div>` : "";
}
function wgCard(x) {
  const w = STATE.settings.wg || {}, p = x.wg || {};
  const fb = (n) => (n >= 1024 ** 3 ? (n / 1024 ** 3).toFixed(1).replace(".", ",") + " GB" : n >= 1024 ** 2 ? (n / 1024 ** 2).toFixed(1).replace(".", ",") + " MB" : Math.round(n / 1024) + " KB");
  return `${wgStaleNote(x, "margin-top:16px")}
    <div class="card">
      <div class="ch"><h2>WireGuard</h2><a href="#/wireguard">Menu WireGuard</a></div>
      <dl class="dl" style="margin:0">
        <div><dt>Endpoint VPS</dt><dd>${esc(STATE.settings.publicIp || "—")}:${esc(w.port || 51820)}</dd></div>
        <div><dt>IP WireGuard VPS</dt><dd>${esc(w.vpsIp || "—")}</dd></div>
        <div><dt>Handshake terakhir</dt><dd>${p.handshake ? esc(ztAgo(p.handshake)) : '<span class="muted">belum pernah</span>'}${p.endpoint ? ` <span class="muted">dari ${esc(p.endpoint)}</span>` : ""}</dd></div>
        <div><dt>Data diterima / dikirim</dt><dd>${fb(p.rx || 0)} / ${fb(p.tx || 0)}</dd></div>
        <div style="grid-column:1/-1"><dt>Public key router</dt><dd>${esc(x.wgPub || "—")} ${x.wgPub ? copyBtn(x.wgPub, "Public key tersalin") : ""}</dd></div>
      </dl>
    </div>`;
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
    ${x.transport === "zt" ? ztStaleNote(x) : x.transport === "wg" ? wgStaleNote(x) : ""}
    ${x.transport === "wg" ? `<div class="note info">${ic("bolt")}<div><b>Jalur WireGuard</b>Butuh RouterOS v7 (semua jenis router). Script membuat interface <code>wg-acs</code> dengan kunci khusus router ini, lalu tersambung ke VPS lewat UDP ${esc((STATE.settings.wg || {}).port || 51820)}. Pastikan port itu terbuka di firewall provider VPS.</div></div>` : ""}
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
function viewAddons(v) {
  crumb([["Add-on"]]);
  v.innerHTML = `
    <div class="ph"><div><h1>Add-on</h1><p>Tambahkan fitur ke panel sesuai kebutuhan. Aplikasi yang terpasang bisa dibuka dari sini dan dari Dashboard.</p></div>
      <div class="acts ad-acts"><div class="search ad-search">${ic("search", "")}<input id="adQ" type="text" placeholder="Cari add-on" value="${esc(ADV.q)}" aria-label="Cari add-on"></div><button class="btn" id="adUpd" title="Periksa pembaruan add-on">${ic("refresh")}Periksa pembaruan</button></div></div>
    <div id="adBody"><div class="card"><div class="empty"><span class="spin"></span><p style="margin-top:10px">Memuat add-on…</p></div></div></div>`;
  $("#adQ").addEventListener("input", (e) => { ADV.q = e.target.value; paintAddons(); });
  $("#adUpd").onclick = async () => {
    const btn = $("#adUpd"); busyBtn(btn, true);
    try { const u = await api("/api/updates?refresh=1"); await load(); await fillAddons(); const n = Object.values(u.addons || {}).filter((x) => x && x.available).length; toast(n ? `${n} add-on punya pembaruan` : "Semua add-on sudah versi terbaru"); }
    catch (e) { toast(e.message); }
    busyBtn(btn, false);
  };
  fillAddons();
}
const ADV = { q: "", list: null, job: null };
const adCat = (a) => (a.kind === "sistem" ? "Sistem" : "Aplikasi");
const adIcon = (a, sz) => `<span class="ad-ic c-${esc(a.color || "blue")}${sz ? " " + sz : ""}">${ic(a.icon || "puzzle")}</span>`;
function adState(a) {
  if (!a.installed) return { c: "wait", t: "Belum dipasang" };
  if (a.kind === "aplikasi" && a.running === false) return { c: "bad", t: "Berhenti" };
  return { c: "ok", t: a.kind === "sistem" ? "Aktif" : "Berjalan" };
}
// Tombol "Buka": aplikasi di tab baru, add-on sistem ke menunya sendiri
const adHref = (a) => a.url || a.path + "/";
const adOpen = (a, cls) => a.kind === "aplikasi"
  ? `<a class="btn pri ${cls || ""}" href="${esc(adHref(a))}" target="_blank" rel="noopener">${ic("ext")}Buka</a>`
  : `<a class="btn pri ${cls || ""}" href="#/${esc(a.id)}">Buka</a>`;
async function fillAddons() {
  try {
    const r = await api("/api/addons");
    ADV.list = r.list; ADV.job = r.job;
  } catch (e) {
    const b = $("#adBody"); if (b) b.innerHTML = `<div class="note bad">${ic("alert")}<div><b>Gagal memuat add-on</b>${esc(e.message)}</div></div>`;
    return;
  }
  paintAddons();
}
function paintAddons() {
  const b = $("#adBody"); if (!b || !ADV.list) return;
  const q = ADV.q.trim().toLowerCase();
  const hit = (a) => !q || [a.name, a.tagline, a.desc, adCat(a), (a.features || []).join(" ")].join(" ").toLowerCase().includes(q);
  const inst = ADV.list.filter((a) => a.installed && hit(a));
  const all = ADV.list.filter(hit);
  const tile = (a) => {
    const st = adState(a);
    const meta = a.kind === "aplikasi" ? `<span class="mono">${esc(a.url ? a.url.replace(/^https?:\/\//, "") : a.path + "/")}</span>${a.version ? ` · ${esc(a.version.split(" ")[0])}` : ""}` : `${a.routers || 0} router memakai`;
    return `<div class="card ad-tile">
      <div class="ad-tt">${adIcon(a)}
        <div class="ad-tn"><b>${esc(a.name)}</b><span class="ad-st"><i class="dot ${st.c}"></i>${esc(st.t)} · ${meta}</span></div>
        <div class="menu"><button class="btn ghost icon sm" data-admenu="${esc(a.id)}" title="Aksi lainnya" aria-label="Aksi lainnya">${ic("dots")}</button>
          <div class="menu-list hidden" id="adm-${esc(a.id)}">
            <button data-ad="update" data-id="${esc(a.id)}">${ic("refresh")}Perbarui</button>
            ${a.kind === "aplikasi" ? `<button data-ad="path" data-id="${esc(a.id)}">${ic("edit")}Ubah alamat</button>` : ""}
            <button data-ad="check" data-id="${esc(a.id)}">${ic("check")}Periksa</button>
            <button data-ad="detail" data-id="${esc(a.id)}">${ic("info")}Detail</button>
            <hr><button class="d" data-ad="remove" data-id="${esc(a.id)}">${ic("trash")}Lepas</button>
          </div></div>
      </div>
      <p class="ad-tg">${esc(a.tagline || a.desc)}</p>
      ${a.update ? `<div class="ad-upd">${ic("dl")}<span>Pembaruan tersedia${a.update.latest ? ` · <span class="mono">${esc(a.update.latest.split(" ")[0])}</span>` : ""}${a.update.notes ? ` — ${esc(a.update.notes)}` : ""}</span></div>` : ""}
      <div class="ad-tf">${a.update ? `<button class="btn" data-ad="update" data-id="${esc(a.id)}">${ic("dl")}Perbarui</button>` : `<button class="btn" data-ad="detail" data-id="${esc(a.id)}">Detail</button>`}${adOpen(a)}</div>
    </div>`;
  };
  const row = (a) => {
    const st = adState(a);
    return `<li><button class="ad-row" data-ad="detail" data-id="${esc(a.id)}">${adIcon(a, "sm")}
      <span class="ad-rb"><span class="ad-rn">${esc(a.name)} <span class="tag gray">${adCat(a)}</span></span><span class="ad-rd">${esc(a.tagline || a.desc)}</span></span>
      ${a.update ? `<span class="pill info">Pembaruan</span>` : ""}<span class="pill ${st.c}">${esc(st.t)}</span><span class="chev">${ic("chev")}</span></button></li>`;
  };
  b.innerHTML = `
    ${ADV.job ? `<div class="note info">${ic("clock")}<div><b>${esc(ADV.job.title.replace(/ (dipasang|diperbarui|dilepas)$/, ""))} sedang diproses</b><a href="#" id="adJob">Lihat progres</a></div></div>` : ""}
    ${inst.length ? `<section class="ad-sec"><div class="ad-sh"><h2>Terpasang</h2><span>${inst.length}</span></div><div class="ad-grid">${inst.map(tile).join("")}</div></section>` : ""}
    <section class="ad-sec"><div class="ad-sh"><h2>Semua add-on</h2><span>${all.length}</span></div>
      <div class="card">${all.length ? `<ul class="ad-list">${all.map(row).join("")}</ul>` : `<div class="empty"><h3>Tidak ditemukan</h3><p>Tidak ada add-on yang cocok dengan "${esc(ADV.q)}".</p></div>`}</div>
    </section>
    <p class="help">Aplikasi berjalan di dalam VPS dan dibuka lewat alamat panel, tanpa port tambahan. Data aplikasi tidak ikut terhapus saat dilepas, kecuali Anda memilihnya.</p>`;
  paintIcons(b);
  const j = $("#adJob"); if (j) j.onclick = (e) => { e.preventDefault(); openJob(); };
  b.querySelectorAll("[data-admenu]").forEach((btn) => (btn.onclick = (e) => {
    e.stopPropagation();
    const m = $("#adm-" + btn.dataset.admenu), was = !m.classList.contains("hidden");
    document.querySelectorAll(".menu-list").forEach((x) => x.classList.add("hidden"));
    if (!was) m.classList.remove("hidden");
  }));
  b.querySelectorAll("[data-ad]").forEach((btn) => (btn.onclick = (e) => {
    e.stopPropagation();
    document.querySelectorAll(".menu-list").forEach((x) => x.classList.add("hidden"));
    adAction(btn.dataset.ad, ADV.list.find((x) => x.id === btn.dataset.id), btn);
  }));
}
function adAction(act, a, btn) {
  if (!a) return;
  if (act === "detail") return adDetail(a);
  if (act === "path") return openAddonPath(a);
  if (act === "check") return openAddonCheck(a);
  if (act === "remove") {
    return confirmDialog({
      title: `Lepas ${esc(a.name)}?`, danger: true, ok: "Lepas", wide: true,
      text: a.kind === "sistem"
        ? `<p>Menu ${esc(a.name)} disembunyikan dan VPS keluar dari jaringan ZeroTier panel. Router yang masih memakai ZeroTier harus dipindah ke L2TP atau dihapus dulu.</p><label class="check" style="margin-top:10px"><input type="checkbox" id="adPurge"> Hapus juga ZeroTier dari VPS (<b>semua jaringan</b> di controller ikut terhapus)</label>`
        : `<p>Layanan ${esc(a.name)} dihentikan. Data tetap disimpan dan dipakai lagi bila dipasang ulang.</p><label class="check" style="margin-top:10px"><input type="checkbox" id="adPurge"> Hapus juga aplikasi dan <b>semua datanya</b></label>`,
      onOk: async () => { const purge = !!($("#adPurge") && $("#adPurge").checked); await api(`/api/addons/${a.id}/remove`, { method: "POST", body: { purge } }); openJob(); },
    });
  }
  // install / update
  (async () => {
    if (btn) busyBtn(btn, true);
    try { await api(`/api/addons/${a.id}/${act}`, { method: "POST", body: {} }); openJob(); }
    catch (e) { if (btn) busyBtn(btn, false); toast(e.message); }
  })();
}
function adDetail(a) {
  const st = adState(a);
  const info = [];
  info.push(["Kategori", adCat(a)]);
  if (a.installed && a.kind === "aplikasi") {
    info.push(["Alamat", `<a href="${esc(adHref(a))}" target="_blank" rel="noopener" class="mono">${esc(a.url || (STATE.settings.panelUrl || "").replace(/\/$/, "") + a.path + "/")}</a>${a.url ? `<div class="muted" style="font-size:12.5px">juga di ${esc((STATE.settings.panelUrl || "").replace(/\/$/, "") + a.path)}/</div>` : `<div class="muted" style="font-size:12.5px">Subdomain sendiri bisa diatur di <a href="#/pengaturan/domain">Domain &amp; HTTPS</a></div>`}`]);
    if (a.version) info.push(["Versi", `<span class="mono">${esc(a.version)}</span>`]);
  } else if (a.kind === "aplikasi") info.push(["Alamat", `<span class="mono">${esc(a.path)}/</span> <span class="muted">(bisa diganti setelah dipasang)</span>`]);
  if (a.kind === "sistem" && a.installed) info.push(["Router memakai", String(a.routers || 0)]);
  if (a.installed && a.at) info.push(["Dipasang", esc(fmtT(Date.parse(a.at), true))]);
  if (a.repo) info.push(["Sumber", `<a href="${esc(a.repo)}" target="_blank" rel="noopener">${esc(a.repo.replace(/^https:\/\/github.com\//, "github.com/"))}</a>`]);
  if (a.note) info.push(["Catatan", esc(a.note)]);
  if (a.update) info.push(["Pembaruan", `<b style="color:var(--primary)">Tersedia</b>${a.update.latest ? ` · <span class="mono">${esc(a.update.latest)}</span>` : ""}${a.update.behind ? ` · ${a.update.behind} perubahan` : ""}${a.update.notes ? `<div class="muted" style="font-size:12.5px;margin-top:2px">${esc(a.update.notes)}</div>` : ""}`]);
  const left = a.installed ? `<button class="btn ghost danger" data-add="remove">${ic("trash")}Lepas</button><span class="sp"></span>` : "";
  const right = a.installed
    ? `<button class="btn" data-add="check">${ic("check")}Periksa</button><button class="btn" data-add="update">${ic(a.update ? "dl" : "refresh")}Perbarui</button>${adOpen(a)}`
    : `<button class="btn" data-act="closemodal">Tutup</button><button class="btn pri" data-add="install">${ic("dl")}Install</button>`;
  modal(`<span class="ad-mh">${adIcon(a, "sm")}${esc(a.name)}</span>`, `
    <div class="ad-dh"><span class="pill ${st.c}">${esc(st.t)}</span><span class="tag gray">${adCat(a)}</span></div>
    <p class="ad-lead">${esc(a.tagline || "")}</p>
    <p class="ad-desc">${esc(a.desc)}</p>
    ${(a.features || []).length ? `<h3 class="ad-h3">Fitur</h3><ul class="ad-feat">${a.features.map((f) => `<li>${ic("check")}<span>${esc(f)}</span></li>`).join("")}</ul>` : ""}
    <h3 class="ad-h3">Informasi</h3>
    <dl class="ad-info">${info.map(([k, val]) => `<div><dt>${k}</dt><dd>${val}</dd></div>`).join("")}</dl>`,
    `<div class="ad-mf">${left}${right}</div>`, { size: "md" });
  document.querySelectorAll("#modalRoot [data-add]").forEach((btn) => (btn.onclick = () => {
    const act = btn.dataset.add;
    if (act !== "remove") closeModal();
    adAction(act, a, act === "remove" ? null : null);
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
      $("#jSum").innerHTML = r.ok ? `<div class="tst-sum ok">${ic("check")}${esc(r.title)}.${r.action === "selfupdate" ? ` <span style="flex:1"></span><button class="btn pri sm" onclick="location.reload()">${ic("refresh")}Muat ulang halaman</button>` : ""}</div>` : `<div class="tst-sum fail">${ic("alert")}${esc(r.error)}</div>`;
      if (!r.ok) $(".jlog").open = true;
      await load().catch(() => {});
      if (after) after(r);
      if (location.hash.startsWith("#/addon")) fillAddons();
      else if (location.hash.startsWith("#/pengaturan")) ROUTE_AFTER_CLOSE = true;
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
  const z = STATE.settings.zt, w = STATE.settings.wg, cur = x ? x.transport : "l2tp";
  const showZt = ztOn() || cur === "zt", showWg = wgOn() || cur === "wg";
  if (!showZt && !showWg) return `<input type="radio" name="fTr" value="l2tp" checked class="hidden"><div id="fZtBox" class="hidden"></div>` + siteFormRest(x);
  return `
    <label>Jalur ke VPS</label>
    <div class="seg"><label><input type="radio" name="fTr" value="l2tp" ${cur === "l2tp" || !cur ? "checked" : ""}>L2TP</label>${showWg ? `<label ${w ? "" : 'class="netopt dis" style="margin:0;padding:8px 12px" title="WireGuard belum siap di VPS"'}><input type="radio" name="fTr" value="wg" ${cur === "wg" ? "checked" : ""} ${w ? "" : "disabled"}>WireGuard</label>` : ""}${showZt ? `<label ${z ? "" : 'class="netopt dis" style="margin:0;padding:8px 12px" title="Hubungkan VPS ke jaringan di menu ZeroTier dulu"'}><input type="radio" name="fTr" value="zt" ${cur === "zt" ? "checked" : ""} ${z ? "" : "disabled"}>ZeroTier</label>` : ""}</div>
    <div class="help" id="fTrHelp"></div>
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
    const tr = (document.querySelector("input[name=fTr]:checked") || {}).value;
    const zt = tr === "zt";
    $("#fZtBox").classList.toggle("hidden", !zt);
    const hp = $("#fTrHelp");
    if (hp) hp.innerHTML = tr === "wg" ? `WireGuard: semua RouterOS v7, ringan dan cepat. Kunci dan IP (${esc((STATE.settings.wg || {}).subnet || "10.66.0.0/24")}) dibuat otomatis.` : tr === "zt" ? (STATE.settings.zt ? "ZeroTier butuh RouterOS v7 dengan paket zerotier (router ARM/ARM64)." : 'ZeroTier belum diatur. Buka <a href="#/zerotier">menu ZeroTier</a> untuk mengaktifkan.') : "L2TP: semua versi RouterOS (v6 dan v7).";
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
    text: `<p>${x.transport === "zt" ? "Router ini dikeluarkan dari jaringan ZeroTier panel" : x.transport === "wg" ? "Kunci WireGuard router ini dihapus dari VPS" : "Akun VPN router ini dihapus"}, beserta port forwarding-nya. GenieACS tidak bisa lagi Summon ONT di router ini.</p>
      ${x.state === "pending" ? "" : `<div class="note warn" style="margin:12px 0 10px">${ic("alert")}<div><b>Bersihkan MikroTik ${esc(x.name)} dulu</b>Aturan dari panel (${x.transport === "zt" ? "interface zt-acs" : x.transport === "wg" ? "interface wg-acs" : "interface l2tp-acs"}, route, NETMAP, dan firewall) tetap tertinggal di MikroTik kalau tidak dihapus. Salin script di bawah, tempel di Winbox → New Terminal, lalu hapus router di panel.</div></div>`}
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
  const rm = [`/interface l2tp-client remove [find where name="l2tp-acs"]`, `:do { /zerotier interface remove [find where name="zt-acs"] } on-error={}`, `:do { /interface wireguard peers remove [find where interface="wg-acs"]; /interface wireguard remove [find where name="wg-acs"] } on-error={}`]
    .concat(names.map((n) => `/ip route remove [find where comment="${n}"]`), names.map((n) => `/ip firewall nat remove [find where comment~"^${n} - "]`), names.map((n) => `/ip firewall filter remove [find where comment~"^${n} - "]`), [`:put "Pengaturan ${BRAND} sudah dihapus."`]).join("\n");
  v.innerHTML = `
    <div class="ph"><div><h1>Panduan</h1><p>Cara kerja dan langkah pemakaian, dengan bahasa sederhana.</p></div></div>
    <div class="card guide"><div class="ch"><h2>Cara kerja</h2></div><div class="cb">
      <div class="flow"><span>ONT</span><i>→</i><span>OLT</span><i>→</i><span>MikroTik</span><i>⇄ L2TP / WireGuard / ZeroTier ⇄</i><span>VPS · GenieACS</span></div>
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
${wgOn() ? `    <div class="card"><div class="ch"><h2>Router lewat WireGuard (opsional)</h2></div><div class="cb"><ol class="ol">
      <li><b>Buka port UDP</b>Buka UDP <code>${esc((s.wg || {}).port || 51820)}</code> di firewall provider VPS (firewall VPS sudah dibuka panel).</li>
      <li><b>Tambah router dengan jalur WireGuard</b>Pasang script di MikroTik (semua RouterOS v7). Kunci dan IP WireGuard dibuat panel, router tersambung dalam beberapa detik.</li>
      <li><b>Pantau</b>Menu WireGuard menampilkan handshake terakhir, endpoint, dan data setiap router.</li>
    </ol><p class="help">URL ACS di ONT tetap sama (<code>${esc(s.acsUrl || "")}</code>). Bila port atau rentang WireGuard diganti, pasang ulang script di router WireGuard.</p></div></div>` : ""}
    <div class="card"><div class="ch"><h2>Keamanan panel</h2></div><div class="cb"><ol class="ol">
      <li><b>Logout otomatis</b>Panel keluar sendiri bila tidak ada aktivitas (bawaan 1 jam). Atur di Pengaturan → Keamanan.</li>
      <li><b>Blokir salah password</b>5 kali salah: IP diblokir 5 menit, lalu 30 menit, lalu 24 jam. Notifikasi dikirim ke Telegram.</li>
      <li><b>Sesi aktif</b>Lihat perangkat yang sedang login dan keluarkan yang tidak dikenal. Ganti password admin juga mengeluarkan perangkat lain.</li>
    </ol></div></div>
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
      <details><summary>Router WireGuard tetap Terputus</summary><p>Buka menu WireGuard: bila handshake "belum pernah", port UDP WireGuard kemungkinan tertutup di firewall provider VPS atau script belum dipasang. Di MikroTik cek WireGuard → Peers → Last Handshake.</p></details>
      <details><summary>Saya keluar sendiri dari panel</summary><p>Itu logout otomatis karena tidak ada aktivitas. Ubah batas waktunya di Pengaturan → Keamanan (15 menit sampai 12 jam).</p></details>
      <details><summary>Notifikasi Telegram tidak masuk</summary><p>Buka Pengaturan → Notifikasi Telegram, klik Kirim pesan tes. Jika gagal, pesan kesalahannya menjelaskan penyebabnya (token salah, bot bukan admin, topik terhapus). Ingat: notifikasi baru dikirim setelah VPN putus melewati jeda yang diatur.</p></details>
      <details><summary>Setelah HTTPS aktif, panel tidak bisa dibuka lewat IP</summary><p>Itu normal. Buka lewat <code>https://domain:${esc(String(s.port || 8088))}</code>; alamat http dan IP akan dialihkan otomatis ke sana. Jika domain bermasalah, lepas domain di Pengaturan → Domain &amp; HTTPS.</p></details>
      <details><summary>Aman menjalankan script MikroTik berulang kali?</summary><p>Aman. Script menghapus pengaturan lama bertanda "${esc(BRAND)}" (termasuk nama panel sebelumnya) terlebih dulu; pengaturan lain tidak disentuh.</p></details>
    </div>`;
}

/* ================= Pengaturan ================= */
const SET_TABS = [["umum", "Umum", "sliders"], ["keamanan", "Keamanan", "shield"], ["vpn", "VPN L2TP", "lock"], ["telegram", "Notifikasi Telegram", "send"], ["domain", "Domain & HTTPS", "globe"]];
function viewSettings(v, tab) {
  if (!SET_TABS.some(([k]) => k === tab)) tab = "umum";
  crumb([["Pengaturan", "#/pengaturan"], [SET_TABS.find(([k]) => k === tab)[1]]]);
  v.innerHTML = `
    <div class="ph"><div><h1>Pengaturan</h1><p>Pengaturan VPS, keamanan login, VPN L2TP, notifikasi, dan domain panel.</p></div></div>
    ${tabsHtml(SET_TABS, tab, "#/pengaturan")}
    <div id="setBody"></div>`;
  const b = $("#setBody");
  if (tab === "telegram") setTelegram(b);
  else if (tab === "keamanan") setSecurity(b);
  else if (tab === "domain") setDomain(b);
  else if (tab === "vpn") setVpn(b);
  else setGeneral(b);
}
// ---------- Pengaturan → Keamanan ----------
async function setSecurity(b) {
  if (!b.innerHTML) b.innerHTML = `<div class="card"><div class="empty"><span class="spin"></span></div></div>`;
  let x;
  try { x = await api("/api/security"); } catch (e) { b.innerHTML = `<div class="note bad">${ic("alert")}<div><b>Gagal membaca pengaturan keamanan</b>${esc(e.message)}</div></div>`; return; }
  if (!location.hash.startsWith("#/pengaturan/keamanan")) return;
  const tg = STATE.settings.telegram || {};
  const tgOn = !!(tg.tokenSet && tg.enabled && tg.chatId);
  const lbl = (m) => (m >= 60 ? `${m / 60} jam` : `${m} menit`);
  const step = (ms) => (ms >= 3600e3 ? `${ms / 3600e3} jam` : `${ms / 60e3} menit`);
  const others = x.sessions.filter((z) => !z.current).length;
  b.innerHTML = `
    <div class="card"><div class="ch"><h2>Logout otomatis</h2><span class="pill info">${lbl(x.idleMin)}</span></div>
      <form class="cb" id="idleForm" style="padding-top:4px">
        <label for="secIdle">Keluar otomatis bila tidak ada aktivitas selama</label>
        <select id="secIdle" style="max-width:260px">${x.idleChoices.map((m) => `<option value="${m}" ${m === x.idleMin ? "selected" : ""}>${lbl(m)}${m === 60 ? " (disarankan)" : ""}</option>`).join("")}</select>
        <div class="help">Aktivitas = klik, ketik, gulir, atau pindah halaman. Penyegaran otomatis (misalnya di halaman ZeroTier) tidak dihitung, jadi tab yang dibiarkan terbuka tetap keluar. Satu menit sebelumnya muncul peringatan dengan tombol <b>Tetap masuk</b>.</div>
        <div class="form-actions"><button class="btn pri">Simpan</button></div>
      </form></div>

    <div class="card"><div class="ch"><h2>Blokir salah password</h2><span class="muted zt-small">${x.blocked.length ? `${x.blocked.length} IP diblokir` : "tidak ada IP diblokir"}</span></div>
      <div class="cb" style="padding-top:4px">
        <ol class="sec-steps">${x.blockSteps.map((ms, i) => `<li><b>${i === 0 ? "5 kali salah" : i === 1 ? "Mengulang lagi" : "Masih mengulang"}</b><span>diblokir ${step(ms)}</span></li>`).join("")}</ol>
        <div class="help">Blokir berlaku per alamat IP dan tetap tersimpan walaupun panel di-restart. Tingkat blokir kembali ke awal setelah 24 jam tanpa percobaan salah.</div>
        <label class="check" style="margin-top:14px"><input type="checkbox" id="secNotify" ${x.notifyBlock ? "checked" : ""}> Kirim notifikasi Telegram saat ada IP diblokir</label>
        ${tgOn ? "" : `<div class="help">Telegram belum diatur. Atur dulu di <a href="#/pengaturan/telegram">Notifikasi Telegram</a>.</div>`}
      </div>
      ${x.blocked.length ? `<table class="t"><thead><tr><th>IP</th><th>Tingkat</th><th class="hide-sm">Salah total</th><th>Diblokir sampai</th><th class="r"></th></tr></thead><tbody>
        ${x.blocked.map((z) => `<tr><td class="mono">${esc(z.ip)}</td><td>${z.level} dari 3</td><td class="hide-sm">${z.total}×</td><td>${esc(fmtT(z.until, true))}</td><td class="r"><button class="btn sm" data-unblock="${esc(z.ip)}">Buka blokir</button></td></tr>`).join("")}
      </tbody></table>` : ""}
    </div>

    <div class="card"><div class="ch"><h2>Sesi aktif</h2><span class="muted zt-small">${x.sessions.length} perangkat</span></div>
      <ul class="sess">${x.sessions.map((z) => `<li><span class="sess-ic">${ic(z.mobile ? "phone" : "monitor")}</span>
        <div class="sess-b"><b>${esc(z.device)}</b> ${z.current ? `<span class="pill ok">Perangkat ini</span>` : ""}
          <div class="muted zt-small"><span class="mono">${esc(z.ip || "—")}</span> · masuk ${esc(fmtT(z.created, true))} · aktif ${esc(ztAgo(z.last))}</div></div>
        ${z.current ? "" : `<button class="btn sm ghost danger" data-kick="${esc(z.id)}">Keluarkan</button>`}</li>`).join("")}</ul>
      <div class="cb card-actions"><span class="muted zt-small">Mengganti password admin otomatis mengeluarkan semua perangkat lain.</span><span class="sp"></span><button class="btn danger" id="kickAll" ${others ? "" : "disabled"}>${ic("logout")}Keluarkan semua perangkat lain</button></div>
    </div>`;
  paintIcons(b);
  $("#idleForm").onsubmit = async (e) => {
    e.preventDefault(); const btn = e.target.querySelector("button"); busyBtn(btn, true);
    try { await api("/api/security", { method: "PUT", body: { idleMin: parseInt($("#secIdle").value, 10) } }); IDLE_MS = parseInt($("#secIdle").value, 10) * 60e3; toast("Logout otomatis disimpan"); setSecurity(b); }
    catch (err) { toast(err.message); busyBtn(btn, false); }
  };
  $("#secNotify").onchange = async (e) => { try { await api("/api/security", { method: "PUT", body: { notifyBlock: e.target.checked } }); toast(e.target.checked ? "Notifikasi blokir aktif" : "Notifikasi blokir dimatikan"); } catch (err) { toast(err.message); } };
  b.querySelectorAll("[data-unblock]").forEach((btn) => (btn.onclick = async () => { busyBtn(btn, true); try { await api("/api/security/unblock", { method: "POST", body: { ip: btn.dataset.unblock } }); toast("Blokir dibuka"); setSecurity(b); } catch (e) { toast(e.message); busyBtn(btn, false); } }));
  b.querySelectorAll("[data-kick]").forEach((btn) => (btn.onclick = async () => { busyBtn(btn, true); try { await api(`/api/sessions/${btn.dataset.kick}`, { method: "DELETE" }); toast("Sesi dikeluarkan"); setSecurity(b); } catch (e) { toast(e.message); busyBtn(btn, false); } }));
  $("#kickAll").onclick = () => confirmDialog({
    title: "Keluarkan semua perangkat lain?", danger: true, icon: "logout", ok: "Keluarkan",
    text: `<p>${others} perangkat lain harus login lagi. Perangkat ini tetap masuk.</p>`,
    onOk: async () => { const r = await api("/api/sessions/others", { method: "DELETE" }); closeModal(); toast(`${r.count} perangkat dikeluarkan`); setSecurity(b); },
  });
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
      <div class="err" id="vpsErr"></div>
      <div class="form-actions"><button class="btn pri">Simpan</button></div>
    </form></div>
    <div class="card" id="updCard"><div class="ch"><h2>Pembaruan panel</h2><span id="updPill"></span></div><div class="cb" id="updBody" style="padding-top:4px"><p class="muted">Memeriksa…</p></div></div>
    ${(() => {
      const P = STATE.settings.stdPorts || {}, https = !!(STATE.settings.cloudflare && STATE.settings.cloudflare.https);
      const url = STATE.settings.panelUrl || "", bp = esc(String(STATE.settings.port || 8088));
      const pill = P.enabled ? (P.active ? `<span class="pill ok">Aktif</span>` : `<span class="pill bad">Gagal</span>`) : `<span class="pill wait">Tidak aktif</span>`;
      return `<div class="card"><div class="ch"><h2>Alamat panel</h2>${pill}</div><form class="cb" id="portForm" style="padding-top:4px">
        <p style="color:var(--text-2);margin:0 0 4px">Panel dibuka lewat port web standar sehingga alamatnya tanpa nomor port. Bawaan <b>${P.defHttp || 80}</b> (http) dan <b>${P.defHttps || 443}</b> (https${https ? ", dipakai karena domain ber-HTTPS" : ""}). Bila port itu dipakai aplikasi lain, ganti dengan port lain. Port ${bp} tetap jalan sebagai cadangan.</p>
        ${P.error ? `<div class="note bad" style="margin:10px 0 0">${ic("alert")}<div><b>Port tidak bisa dipakai</b>${esc(P.error)}. Panel tetap di port ${bp}.</div></div>` : ""}
        ${P.enabled && P.active ? `<div class="kv" style="padding:10px 0 0;border:0"><span>Alamat panel</span><b><a href="${esc(url)}" target="_blank" rel="noopener">${esc(url)}</a></b></div>` : ""}
        <div class="f2"><div><label for="pHttp">Port HTTP</label><input id="pHttp" type="number" min="1" max="65535" value="${esc(String(P.http || P.defHttp || 80))}"></div>
          <div><label for="pHttps">Port HTTPS</label><input id="pHttps" type="number" min="1" max="65535" value="${esc(String(P.https || P.defHttps || 443))}"></div></div>
        <div class="help">Buka port ini (TCP) di firewall provider VPS. Bila bukan ${P.defHttp || 80}/${P.defHttps || 443}, alamat panel ikut memakai nomor port, misalnya <code>http://IP-VPS:8000</code>.</div>
        <div class="err" id="portErr"></div>
        <div class="form-actions">${P.enabled ? `<button class="btn" id="stdOff" type="button">Matikan</button>` : ""}<button class="btn" id="portDef" type="button">Kembalikan bawaan</button><button class="btn pri" id="portSave">${P.enabled ? "Simpan port" : `${ic("globe")}Aktifkan`}</button></div>
      </form></div>`;
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
  $("#vpsForm").onsubmit = async (e) => {
    e.preventDefault(); $("#vpsErr").textContent = "";
    const btn = e.submitter || $("#vpsForm button"); busyBtn(btn, true);
    try { await api("/api/settings", { method: "PUT", body: { publicIp: $("#sIp").value, timezone: $("#sTz").value } }); await load(); route(); toast("Pengaturan disimpan"); }
    catch (err) { $("#vpsErr").textContent = err.message; busyBtn(btn, false); }
  };
  const off = $("#stdOff");
  if (off) off.onclick = async () => {
    busyBtn(off, true);
    try { await api("/api/stdports", { method: "POST", body: { enable: false } }); openJob(); }
    catch (err) { busyBtn(off, false); toast(err.message); }
  };
  $("#portDef").onclick = () => { const P = STATE.settings.stdPorts || {}; $("#pHttp").value = P.defHttp || 80; $("#pHttps").value = P.defHttps || 443; };
  $("#portForm").onsubmit = async (e) => {
    e.preventDefault(); $("#portErr").textContent = "";
    const btn = $("#portSave"); busyBtn(btn, true);
    try { await api("/api/stdports", { method: "POST", body: { enable: true, http: $("#pHttp").value.trim(), https: $("#pHttps").value.trim() } }); openJob(); }
    catch (err) { $("#portErr").textContent = err.message; busyBtn(btn, false); }
  };
  fillUpdate();
  $("#pwForm").onsubmit = async (e) => {
    e.preventDefault(); $("#pwErr").textContent = "";
    const btn = $("#pwForm button"); busyBtn(btn, true);
    try { await api("/api/settings", { method: "PUT", body: { oldPassword: $("#pOld").value, newPassword: $("#pNew").value } }); $("#pOld").value = ""; $("#pNew").value = ""; await load(); route(); doneDialog("Password admin diganti", "Gunakan password baru saat login berikutnya."); }
    catch (err) { $("#pwErr").textContent = err.message; }
    busyBtn(btn, false);
  };
}

// Tab VPN L2TP: enkripsi IPsec dan jaringan VPN
function setVpn(b) {
  const s = STATE.settings;
  b.innerHTML = `
    <div class="card"><div class="ch"><h2>Enkripsi IPsec</h2>${s.useIpsec ? `<span class="pill ok">${ic("lock", "")}Aktif</span>` : `<span class="pill wait">Tidak aktif</span>`}</div><form class="cb" id="ipsecForm" style="padding-top:4px">
      <p style="color:var(--text-2);margin:0">L2TP tanpa IPsec tidak dienkripsi tetapi lebih ringan dan didukung semua MikroTik. IPsec menambah enkripsi untuk VPN.</p>
      <label class="check" style="margin-top:14px"><input id="sIpsec" type="checkbox" ${s.useIpsec ? "checked" : ""}>Pakai IPsec (enkripsi)</label>
      <div class="help">Setelah diubah, pasang ulang script di semua MikroTik.</div>
      <div id="pskBox" class="${s.useIpsec ? "" : "hidden"}"><label>Kunci IPsec (PSK)</label><div style="display:flex;gap:8px"><input type="text" readonly class="mono" value="${esc(s.psk || "")}" style="flex:1">${s.psk ? copyBtn(s.psk, "PSK tersalin") : ""}</div></div>
      <div class="err" id="ipsecErr"></div>
      <div class="form-actions"><button class="btn pri">Simpan</button></div>
    </form></div>
    <div class="card"><div class="ch"><h2>Jaringan VPN</h2></div>
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
`;
  $("#sIpsec").onchange = () => $("#pskBox").classList.toggle("hidden", !$("#sIpsec").checked);
  $("#ipsecForm").onsubmit = async (e) => {
    e.preventDefault(); $("#ipsecErr").textContent = "";
    const changed = $("#sIpsec").checked !== !!s.useIpsec;
    const btn = $("#ipsecForm button"); busyBtn(btn, true);
    try { await api("/api/settings", { method: "PUT", body: { useIpsec: $("#sIpsec").checked } }); await load(); route(); doneDialog("Pengaturan disimpan", changed ? "IPsec diubah. Pasang ulang script di semua MikroTik." : "", "ok", !changed); }
    catch (err) { $("#ipsecErr").textContent = err.message; busyBtn(btn, false); }
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
}
// Kartu pembaruan panel (Pengaturan → Umum)
async function fillUpdate(refresh) {
  const b = $("#updBody"); if (!b) return;
  let u;
  try { u = await api("/api/updates" + (refresh ? "?refresh=1" : "")); }
  catch (e) { b.innerHTML = `<div class="note bad">${ic("alert")}<div><b>Gagal memeriksa pembaruan</b>${esc(e.message)}</div></div>`; return; }
  if (!$("#updBody")) return;
  const P = u.panel || {};
  $("#updPill").innerHTML = P.available ? `<span class="pill info">Versi ${esc(P.latest)} tersedia</span>` : P.error ? `<span class="pill wait">Tidak bisa dicek</span>` : `<span class="pill ok">Terbaru</span>`;
  b.innerHTML = `
    ${P.available ? `<div class="note info" style="margin:0 0 12px">${ic("dl")}<div><b>Versi ${esc(P.latest)} tersedia</b>${P.notes ? esc(P.notes) : "Ada pembaruan panel di GitHub."}${P.date ? ` <span class="muted">· ${esc(fmtT(Date.parse(P.date), true))}</span>` : ""}</div></div>` : ""}
    ${P.error ? `<div class="note warn" style="margin:0 0 12px">${ic("alert")}<div><b>Tidak bisa menghubungi GitHub</b>${esc(P.error)}</div></div>` : ""}
    <div class="kv" style="padding:0 0 8px;border:0"><span>Versi terpasang</span><b>v${esc(u.version || "")}</b></div>
    <div class="kv" style="padding:0 0 8px;border:0"><span>Versi terbaru</span><b>${P.latest ? "v" + esc(P.latest) : "—"}</b></div>
    <div class="kv" style="padding:0;border:0"><span>Terakhir diperiksa</span><b>${u.checkedAt ? esc(fmtT(u.checkedAt, true)) : "—"}</b></div>
    <div class="help">Diperiksa otomatis tiap 12 jam. ${u.canSelfUpdate ? "Pembaruan menjalankan <code>git pull</code> lalu installer di folder repo; panel menyala ulang beberapa detik, data tetap aman." : "Perbarui lewat SSH: <code>cd /root/acs-netmap-panel &amp;&amp; git pull &amp;&amp; bash install-vpn-acs.sh</code> (setelah itu tombol Perbarui tersedia di sini)."}</div>
    <div class="form-actions"><button class="btn" id="updCheck" type="button">${ic("refresh")}Periksa sekarang</button>${P.available && u.canSelfUpdate ? `<button class="btn pri" id="updGo" type="button">${ic("dl")}Perbarui ke v${esc(P.latest)}</button>` : ""}</div>`;
  $("#updCheck").onclick = async () => { busyBtn($("#updCheck"), true); await fillUpdate(true); await load().catch(() => {}); };
  const go = $("#updGo");
  if (go) go.onclick = () => confirmDialog({
    title: `Perbarui panel ke v${esc(P.latest)}?`, icon: "dl", ok: "Perbarui",
    text: `<p>Panel menjalankan <code>git pull</code> lalu installer. Panel menyala ulang beberapa detik; VPN, GenieACS, dan data router tidak terganggu.</p>`,
    onOk: async () => { await api("/api/updates/panel", { method: "POST", body: {} }); openJob(); },
  });
}

/* ================= GenieACS ================= */
// ---------- Inform berkala ONT: penyebab umum ONT terlihat offline padahal hidup ----------
function informCard(g) {
  const I = g.inform; if (!I || !I.total || g.devicesError) return "";
  const P = I.provision || {};
  const bad = I.slow + I.off + I.unknown;
  const top = Object.entries(I.intervals).sort((a, b) => b[1] - a[1]).slice(0, 4).map(([iv, n]) => `<span class="pill ${iv <= 300 ? "ok" : "bad"}">${iv >= 3600 ? iv / 3600 + " jam" : iv >= 60 ? Math.round(iv / 60) + " menit" : iv + " dtk"} · ${n} ONT</span>`).join("");
  const seg = (n, cls) => (n ? `<i class="${cls}" style="width:${(n / I.total) * 100}%"></i>` : "");
  return `<div class="card inf-card">
    <div class="ch"><h2>Inform berkala ONT</h2>${P.installed ? `<span class="pill ok">Provision aktif${P.interval ? ` · tiap ${P.interval} detik` : ""}</span>` : bad ? `<span class="pill bad">Perlu diperbaiki</span>` : `<span class="pill ok">Normal</span>`}</div>
    <div class="cb" style="padding-top:12px">
      <p class="inf-lead">${P.installed ? `Semua ONT diatur melapor ke GenieACS ${P.interval ? `tiap <b>${P.interval} detik</b>` : "secara berkala"}. ONT yang belum ikut berubah setelah inform berikutnya.`
        : bad ? `<b>${bad} dari ${I.total} ONT</b> melapor jarang (lebih dari 5 menit), inform berkalanya mati, atau intervalnya belum diketahui. ONT seperti ini terlihat <b>offline</b> di GenieACS beberapa menit setelah tersambung, padahal di lokasi tetap hidup. Penyebabnya bukan VPN (L2TP, WireGuard, maupun ZeroTier sama saja).`
        : "Semua ONT melapor tiap 5 menit atau lebih cepat."}</p>
      <div class="inf-bar">${seg(I.fast, "ok")}${seg(I.slow, "warn")}${seg(I.off, "bad")}${seg(I.unknown, "unk")}</div>
      <div class="inf-leg"><span><i class="ok"></i>≤ 5 menit: ${I.fast}</span><span><i class="warn"></i>lebih jarang: ${I.slow}</span><span><i class="bad"></i>inform berkala mati: ${I.off}</span><span><i class="unk"></i>belum diketahui: ${I.unknown}</span></div>
      ${top ? `<div class="inf-top"><span class="muted zt-small">Interval terbanyak</span>${top}</div>` : ""}
      <div class="inf-act">
        <label for="infIv" class="muted zt-small" style="margin:0">Laporkan tiap</label>
        <select id="infIv" style="width:auto">${[120, 240, 300, 600].map((v) => `<option value="${v}" ${(P.interval || 240) === v ? "selected" : ""}>${v / 60} menit${v === 240 ? " (disarankan)" : ""}</option>`).join("")}</select>
        <button class="btn pri" id="infGo">${ic("check")}${P.installed ? "Simpan interval" : "Perbaiki semua ONT"}</button>
        ${P.installed ? `<button class="btn ghost danger" id="infRm">Hapus provision</button>` : ""}
      </div>
      <p class="help">Panel memasang provision <code>vpnacs-inform</code> + preset di GenieACS yang menyalakan inform berkala di setiap ONT. Berlaku saat ONT melapor berikutnya (biasanya setelah reboot ONT atau inform berkala lama). Tidak mengubah pengaturan lain.</p>
    </div></div>`;
}
function bindInform(g) {
  const go = $("#infGo"); if (!go) return;
  go.onclick = async () => {
    busyBtn(go, true);
    try { await api("/api/genie/inform", { method: "POST", body: { interval: parseInt($("#infIv").value, 10) } }); toast("Provision inform berkala dipasang"); fillGenie(true); }
    catch (e) { toast(e.message); busyBtn(go, false); }
  };
  const rm = $("#infRm");
  if (rm) rm.onclick = () => confirmDialog({ title: "Hapus provision inform berkala?", danger: true, ok: "Hapus",
    text: "<p>Preset dan provision <code>vpnacs-inform</code> dihapus dari GenieACS. Interval di ONT tidak dikembalikan; ONT tetap memakai nilai terakhir.</p>",
    onOk: async () => { await api("/api/genie/inform", { method: "POST", body: { remove: true } }); closeModal(); toast("Provision dihapus"); fillGenie(true); } });
}
function viewGenie(v) {
  crumb([["GenieACS"]]);
  const s = STATE.settings;
  v.innerHTML = `
    <div class="ph"><div><h1>GenieACS</h1><p>Status layanan, patch IP virtual, dan ONT yang melapor dari setiap router.</p></div>
      <div class="acts">${s.genieUrl ? `<a class="btn" href="${esc(s.genieUrl)}" target="_blank" rel="noopener">${ic("ext")}Buka GenieACS</a>` : ""}</div></div>
    <div id="gBody"><div class="card"><div class="empty"><p>Membaca data GenieACS…</p></div></div></div>`;
  fillGenie(false);
}
let GTAB = "ringkasan"; // tab yang terbuka di halaman GenieACS
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
  const svcDown = g.services.filter((x) => !x.active).length;
  const GT = [["ringkasan", "Ringkasan", "pulse"], ["pengaturan", "Pengaturan", "sliders", P.cidr !== null && (!P.patched || !P.synced || P.outside.length) ? "!" : ""], ["layanan", "Layanan & alamat", "box", svcDown || ""]];
  if (!GT.some(([k]) => k === GTAB)) GTAB = "ringkasan";
  b.innerHTML = `
    ${subTabs(GT, GTAB)}
    <div data-pane="ringkasan"${GTAB === "ringkasan" ? "" : " hidden"}>
    <div class="kpis">
      <div class="kpi"><span>Total ONT</span><b>${g.devicesError ? "—" : T.total}</b><small>terdaftar di GenieACS</small></div>
      <div class="kpi"><span><i class="dot ok"></i>Melapor</span><b>${g.devicesError ? "—" : T.active}</b><small>dalam 1 jam terakhir</small></div>
      <div class="kpi"><span><i class="dot bad"></i>Tidak melapor</span><b>${g.devicesError ? "—" : T.idle}</b><small>lebih dari 1 jam</small></div>
      <div class="kpi"><span>Tanpa router</span><b>${g.devicesError ? "—" : T.other}</b><small>IP tidak cocok dengan router panel</small></div>
    </div>
      <div class="card">
        <div class="ch"><h2>ONT per router</h2><button class="btn sm ghost" id="gRefresh" title="Baca ulang dari GenieACS">${ic("refresh")}Perbarui</button></div>
        ${g.devicesError ? `<div class="cb"><div class="note warn" style="margin:0">${ic("alert")}<div><b>Data ONT tidak bisa dibaca</b>${esc(g.devicesError)}</div></div></div>`
          : !rows.length ? `<div class="empty"><p>Belum ada router.</p></div>`
          : `<table class="t"><thead><tr><th>Router</th><th class="r">ONT</th><th class="r">Melapor</th><th class="r hide-sm">Terakhir lapor</th></tr></thead><tbody>
            ${rows.map((r) => `<tr class="click" data-go="#/router/${r.id}"><td><b style="font-weight:550">${esc(r.name)}</b>${r.transport === "zt" ? ' <span class="tag">ZT</span>' : r.transport === "wg" ? ' <span class="tag violet">WG</span>' : ""}<div class="muted mono" style="font-size:12px">${esc(r.virtualSubnet)}</div></td>
              <td class="r pc">${r.total}</td><td class="r pc ${r.total && r.active < r.total ? "warn" : ""}">${r.active}</td><td class="r muted hide-sm">${ago(r.last)}</td></tr>`).join("")}
            ${g.other.total ? `<tr><td><span class="muted">Tanpa router</span><div class="muted" style="font-size:12px">IP di luar IP virtual router panel</div></td><td class="r pc">${g.other.total}</td><td class="r pc">${g.other.active}</td><td class="r muted hide-sm">${ago(g.other.last)}</td></tr>` : ""}
          </tbody></table>`}
        <div class="cb" style="border-top:1px solid var(--line);padding:12px 20px"><span class="help" style="margin:0">ONT dikelompokkan menurut IP virtual di ConnectionRequestURL. Diperbarui tiap 1 menit${g.cachedAt ? ` · dibaca ${esc(fmtT(g.cachedAt))}` : ""}.</span></div>
      </div>
    </div>
    <div data-pane="pengaturan"${GTAB === "pengaturan" ? "" : " hidden"}>
    <div class="g-setgrid">
    <div class="g-inf">${informCard(g)}</div>
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
    </div>
    </div>
    <div data-pane="layanan"${GTAB === "layanan" ? "" : " hidden"}>
      <div class="grid2">
        <div class="card"><div class="ch"><h2>Layanan</h2>${g.version ? `<span class="muted mono" style="font-size:12px">v${esc(g.version)}</span>` : ""}</div>
          ${g.services.map((x) => `<div class="kv"><span>${esc(x.label)}</span><b>${x.active ? `<span class="pill ok">Berjalan</span>` : `<span class="pill bad">${esc(x.state === "tidak ada" ? "Tidak ada" : "Mati")}</span>`}</b></div>`).join("")}
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
    </div>`;
  bindSubTabs(b, (k) => (GTAB = k));
  paintIcons(b);
  bindInform(g);
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
  if ($("#genieForm")) $("#genieForm").onsubmit = async (e) => {
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
const ZTV = { q: "", f: "all", net: (() => { try { return localStorage.getItem("vpnacs-ztnet") || ""; } catch (e) { return ""; } })() }; // pencarian, filter anggota, jaringan yang dibuka
const ztApiUrl = () => "/api/zt" + (ZTV.net ? "?nwid=" + ZTV.net : "");
function ztOpenNet(nwid, b) {
  ZTV.net = nwid || ""; ZTV.q = ""; ZTV.f = "all";
  try { ZTV.net ? localStorage.setItem("vpnacs-ztnet", ZTV.net) : localStorage.removeItem("vpnacs-ztnet"); } catch (e) {}
  return setZerotier(b).then(() => window.scrollTo({ top: 0, behavior: "smooth" }));
}
function ztAgo(t) {
  if (!t) return "";
  const s = Math.max(0, Math.round((Date.now() - t) / 1000));
  if (s < 60) return "baru saja";
  if (s < 3600) return Math.round(s / 60) + " mnt lalu";
  if (s < 86400) return Math.round(s / 3600) + " jam lalu";
  return Math.round(s / 86400) + " hari lalu";
}
let ZTAB = "ringkasan"; // tab yang terbuka di halaman ZeroTier
async function setZerotier(b) {
  if (!b.innerHTML) b.innerHTML = `<div class="card"><div class="empty"><span class="spin"></span><p style="margin-top:10px">Membaca controller ZeroTier…</p></div></div>`;
  let z;
  try { z = await api(ztApiUrl()); } catch (e) { b.innerHTML = `<div class="note bad">${ic("alert")}<div><b>Gagal membaca ZeroTier</b>${esc(e.message)}</div></div>`; return; }
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
  // Jaringan yang diminta sudah tidak ada: kembali ke jaringan panel
  if (ZTV.net && (!cur || cur.nwid !== ZTV.net)) { ZTV.net = ""; try { localStorage.removeItem("vpnacs-ztnet"); } catch (e) {} }
  if (cur && cur.active && ZTV.net) { ZTV.net = ""; try { localStorage.removeItem("vpnacs-ztnet"); } catch (e) {} }
  const members = z.members || [];
  const pending = members.filter((m) => !m.authorized && m.role !== "vps");
  const onlineN = members.filter((m) => m.authorized && m.online).length;
  const nets = z.networks || [];
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
        <ul class="zt-nets">${list.map((n) => ztNetRow(n, { canUse: true, open: true })).join("")}</ul></div>`
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
  const act = cur.active;
  const actNet = nets.find((n) => n.current);
  const ZT = [["ringkasan", "Ringkasan", "hub", pending.length || ""], ["pengaturan", "Pengaturan", "sliders"]];
  if (!ZT.some(([k]) => k === ZTAB)) ZTAB = "ringkasan";
  b.innerHTML = `${subTabs(ZT, ZTAB)}
    <div data-pane="ringkasan"${ZTAB === "ringkasan" ? "" : " hidden"}>${ztnetNote}
    ${cur.checkError ? `<div class="note bad">${ic("alert")}<div><b>Jaringan ZeroTier bermasalah</b>${esc(cur.checkError)}</div></div>` : ""}
    ${act && !okNet ? `<div class="note warn">${ic("alert")}<div><b>VPS belum tersambung ke jaringan</b>Status: ${esc(cur.status || "-")}. Biasanya selesai dalam beberapa detik; muat ulang halaman ini.</div></div>` : ""}
    ${pending.length ? `<div class="note warn zt-pend">${ic("clock")}<div><b>${pending.length} perangkat menunggu persetujuan</b>${pending.slice(0, 3).map((m) => `<span class="mono">${esc(m.node)}</span>${m.name ? ` (${esc(m.name)})` : ""}`).join(", ")}${pending.length > 3 ? " dan lainnya" : ""}. Router yang dipasang dari panel disetujui otomatis.
      <div style="margin-top:10px"><button class="btn sm" id="ztShowPend">Lihat &amp; setujui</button></div></div></div>` : ""}
    <div class="card zt-curc">
      <div class="ch zt-ch"><h2>Jaringan saat ini</h2>
        <div class="zt-selw" title="Pilih jaringan di controller"><select id="ztNetSel" aria-label="Pilih jaringan">${nets.map((n) => `<option value="${esc(n.current ? "" : n.nwid)}" ${n.nwid === cur.nwid ? "selected" : ""}>${esc(n.name || "(tanpa nama)")}${n.current ? " · dipakai panel" : ""}</option>`).join("")}</select></div></div>
      <div class="zt-curqr">
        <div class="zt-cur">
            <div class="zt-hrow"><span class="zt-hl">Network ID</span><span class="zt-hv"><span class="zt-idbox"><span class="zt-nwid mono">${esc(cur.nwid)}</span><button class="zt-ib" data-copy="${esc(cur.nwid)}" data-msg="Network ID tersalin" title="Salin Network ID" aria-label="Salin Network ID">${ic("copy")}</button></span></span></div>
            <div class="zt-hrow"><span class="zt-hl">Nama jaringan</span><span class="zt-hv" id="ztNameBox"><span class="zt-nname">${esc(cur.name || "(tanpa nama)")}</span><button class="zt-ib" id="ztNameEdit" title="Ganti nama" aria-label="Ganti nama">${ic("edit")}</button></span></div>
            <div class="zt-hrow"><span class="zt-hl">Rentang IP</span><span class="zt-hv"><b class="mono">${esc(cur.subnet || "—")}</b><span class="muted zt-small">${cur.poolStart && cur.poolEnd ? `pool ${esc(cur.poolStart)} – .${esc(cur.poolEnd.split(".").pop())}` : "pool otomatis"}</span></span></div>
            <div class="zt-hrow"><span class="zt-hl">IP VPS (gateway)</span><span class="zt-hv"><b class="mono">${esc(act ? cur.vpsIp : "—")}</b><span class="muted zt-small">${act ? `${cur.sites || 0} router panel memakai jalur ini` : "VPS tidak bergabung"}</span></span></div>
            <div class="zt-hmeta">${act ? (okNet ? `<span class="pill ok">VPS tersambung</span>` : `<span class="pill bad">VPS belum tersambung</span>`) : `<span class="pill wait">Tidak dipakai panel</span>`}${cur.private ? `<span class="pill ok">${ic("lock", "")}Private</span>` : `<span class="pill bad">Public</span>`}${act ? `<span class="muted">interface <span class="mono">${esc(cur.iface || "—")}</span></span>` : ""}</div>
        </div>
        <div class="zt-qrside"><button class="zt-qrbig" id="ztQr" title="Perbesar QR Network ID" aria-label="Perbesar QR Network ID">${(() => { try { const q = qrcode(0, "M"); q.addData(cur.nwid); q.make(); return q.createSvgTag({ cellSize: 4, margin: 0, scalable: true }); } catch (e) { return ic("qr"); } })()}</button><span class="muted zt-small">Pindai untuk menyalin Network ID</span></div>
      </div>
    </div>


    <div class="card" id="ztMembers">
      <div class="ch"><h2>Perangkat di jaringan</h2><span class="muted" style="font-size:12.5px">${members.length} perangkat · ${onlineN} online${pending.length ? ` · <b style="color:var(--warn)">${pending.length} menunggu</b>` : ""}</span></div>
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
    </div>
    <div data-pane="pengaturan"${ZTAB === "pengaturan" ? "" : " hidden"}>
    <div class="zt-setgrid">
      <div class="card" id="ztSetBox"></div>
      <div class="stack">
        <div class="card zt-actc"><div class="zt-acth"><b>Dipakai panel</b><span>${act ? `<span class="pill ok">Ya</span>` : `<span class="pill wait">Tidak</span>`}</span></div>
          ${!act ? `<button class="btn" data-zuse="${esc(cur.nwid)}" ${cur.conflict || !cur.subnet ? "disabled" : ""}>${ic("hub")}Jadikan jaringan panel</button>
          <p class="muted zt-small">${cur.conflict ? esc(cur.conflict) : `${actNet ? `Jaringan panel sekarang: <b>${esc(actNet.name || actNet.nwid)}</b>. ` : ""}VPS bergabung ke jaringan ini dan router ZeroTier memakainya.`}</p>`
            : `<button class="btn ghost danger" id="ztLeave">${ic("trash")}Lepas VPS dari jaringan</button>`}
        </div>
      <div class="card"><div class="ch"><h2>Rute jaringan</h2><span class="muted" style="font-size:12.5px">dibagikan ke semua perangkat</span></div>
        <ul class="zt-routes">${(cur.routes || []).map((r) => `<li><span class="mono zt-rt">${esc(r.target)}</span>
          ${r.via ? `<span class="zt-arrow">→</span><span class="mono">${esc(r.via)}</span><span class="muted zt-rv">${esc(ipOwner(r.via))}</span>` : `<span class="muted zt-rv">langsung (jaringan ZeroTier)</span>`}
          <span class="tag ${r.via ? (r.panel ? "" : "gray") : "gray"}">${r.via ? (r.panel ? "otomatis" : "manual") : "jaringan"}</span></li>`).join("") || `<li class="muted">Belum ada rute</li>`}</ul>
        <p class="help" style="margin:0 16px 12px">Rute IP virtual tiap router dan URL ACS dibuat otomatis oleh panel. Rentang jaringan diatur di Pengaturan.</p>
      </div>
      <div class="card"><div class="ch"><h2>Jaringan di controller</h2><span class="muted" style="font-size:12.5px">${nets.length} jaringan</span></div>
        <ul class="zt-nets">${nets.map((n) => ztNetRow(n, { canUse: false, open: true })).join("")}</ul>

      </div>
      </div>
    </div>

    <p class="help" style="margin-top:12px">${act ? "" : "Rute IP virtual router dan URL ACS hanya dibuat otomatis di jaringan panel. "}Rentang IP ZeroTier tidak boleh bentrok dengan ${esc(s.tunnelNet || "")} (L2TP), ${esc(s.virtualPool || "")} (IP virtual), subnet ONT, dan 172.17.0.0/16 (Docker). URL ACS untuk ONT tetap ${esc(s.acsUrl || "")}.</p>
    </div>`;

  // ---------- tabel perangkat ----------
  const fill = () => {
    const q = ZTV.q.trim().toLowerCase();
    const rank = (m) => (m.role === "vps" ? 0 : !m.authorized ? 1 : 2);
    const rows = members.slice().sort((a, b2) => rank(a) - rank(b2)).filter((m) => {
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
          ${!m.authorized && m.role !== "vps" ? `<button class="btn sm pri zt-nodesm zt-apm" data-zm="auth" data-node="${esc(m.node)}">Setujui</button>` : ""}
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
  bindSubTabs(b, (k) => (ZTAB = k));
  $("#ztQ").addEventListener("input", (e) => { ZTV.q = e.target.value; fill(); });
  b.querySelectorAll("[data-zf]").forEach((c) => (c.onclick = () => { ZTV.f = c.dataset.zf; b.querySelectorAll("[data-zf]").forEach((x) => x.classList.toggle("on", x === c)); fill(); }));
  fill();
  const sp = $("#ztShowPend"); if (sp) sp.onclick = () => { ZTV.f = "wait"; ZTV.q = ""; ZTAB = "ringkasan"; setZerotier(b).then(() => { const el = $("#ztMembers"); if (el) el.scrollIntoView({ behavior: "smooth", block: "start" }); }); };
  if ($("#ztSetBox")) ztSettingsDialog(cur, b, $("#ztSetBox"));
  $("#ztQr").onclick = () => ztQrDialog(cur);
  ztInlineEdit(cur, b);
  $("#ztNetSel").onchange = (e) => ztOpenNet(e.target.value, b);
  if ($("#ztLeave")) $("#ztLeave").onclick = () => confirmDialog({
    title: "Lepas VPS dari jaringan ini?", danger: true, icon: "hub", ok: "Lepas",
    text: `<p>VPS keluar dari jaringan <b>${esc(cur.name || cur.nwid)}</b>. Jaringan dan perangkatnya tetap tersimpan di controller dan bisa dihubungkan lagi. Router yang memakai ZeroTier harus dipindah ke L2TP atau dihapus dulu.</p>`,
    onOk: async () => { await api("/api/zt/leave", { method: "POST" }); await load(); closeModal(); setZerotier(b); toast("VPS dilepas dari jaringan ZeroTier"); },
  });
  ztBindNets(b, z);
  ztBindZtnet(b);
  paintIcons(b);
  ztAutoRefresh(b, members);
}
// Segarkan halaman ZeroTier tiap 10 detik bila ada perubahan (perangkat baru bergabung, online/offline),
// kecuali saat jendela dialog terbuka atau sedang mengetik di kotak cari.
let ZTPOLL = null;
const ztSig = (list) => (list || []).map((m) => `${m.node}:${m.authorized ? 1 : 0}:${m.online ? 1 : 0}:${(m.ips || []).join(",")}:${m.name}:${m.note}`).sort().join("|");
function ztAutoRefresh(b, members) {
  clearInterval(ZTPOLL);
  const sig = ztSig(members);
  ZTPOLL = setInterval(async () => {
    if (!location.hash.startsWith("#/zerotier") || !document.body.contains(b)) { clearInterval(ZTPOLL); return; }
    if ($("#modalRoot").innerHTML || document.activeElement === $("#ztQ") || $("#ztNameIn") || document.hidden) return;
    let z;
    try { z = await api(ztApiUrl()); } catch (e) { return; }
    if (ztSig(z.members) !== sig) setZerotier(b);
  }, 10000);
}
// Ganti nama & deskripsi jaringan langsung di kartu
function ztInlineEdit(cur, b) {
  const save = async (bodyData, msg) => { await api("/api/zt/network", { method: "PUT", body: Object.assign({ nwid: cur.nwid }, bodyData) }); await load(); setZerotier(b); toast(msg); };
  $("#ztNameEdit").onclick = () => {
    const box = $("#ztNameBox");
    box.innerHTML = `<input id="ztNameIn" type="text" maxlength="64" value="${esc(cur.name || "")}" class="zt-nin"><button class="zt-ib ok" id="ztNameOk" title="Simpan">${ic("check")}</button><button class="zt-ib" id="ztNameNo" title="Batal">${ic("x")}</button>`;
    const inp = $("#ztNameIn"); inp.focus(); inp.select();
    const go = async () => {
      const v = inp.value.trim();
      if (v === (cur.name || "")) return setZerotier(b);
      busyBtn($("#ztNameOk"), true);
      try { await save({ name: v }, "Nama jaringan disimpan"); } catch (e) { toast(e.message); busyBtn($("#ztNameOk"), false); inp.focus(); }
    };
    $("#ztNameOk").onclick = go;
    $("#ztNameNo").onclick = () => setZerotier(b);
    inp.onkeydown = (e) => { if (e.key === "Enter") { e.preventDefault(); go(); } else if (e.key === "Escape") { e.stopPropagation(); setZerotier(b); } };
  };
}
function ztQrDialog(cur) {
  let svg = "";
  try { const q = qrcode(0, "M"); q.addData(cur.nwid); q.make(); svg = q.createSvgTag({ cellSize: 6, margin: 3, scalable: true }); } catch (e) { svg = ""; }
  modal("QR Network ID", `
    <div class="zt-qr">
      <div class="zt-qrbox">${svg || `<p class="muted">QR tidak bisa dibuat</p>`}</div>
      <div class="zt-qrinfo">
        <div class="muted zt-small">Network ID · ${esc(cur.name || "")}</div>
        <div class="zt-qrid mono">${esc(cur.nwid)}</div>
        <div style="margin-top:8px"><button class="btn sm" data-copy="${esc(cur.nwid)}" data-msg="Network ID tersalin">${ic("copy")}Salin Network ID</button></div>
        <ol class="ol zt-qrsteps">
          <li><b>Pasang aplikasi ZeroTier One</b>dari Play Store (Android) atau App Store (iPhone).</li>
          <li><b>Pindai QR ini</b>dengan kamera / Google Lens, lalu salin Network ID-nya. Atau ketik manual.</li>
          <li><b>Tambah jaringan</b>Di aplikasi ketuk <b>+</b>, tempel Network ID, lalu aktifkan.</li>
          <li><b>Setujui di panel</b>Perangkat muncul di tabel sebagai <b>Menunggu</b> dalam beberapa detik. Klik <b>Setujui</b>.</li>
        </ol>
      </div>
    </div>`, `<button class="btn pri" data-act="closemodal">Selesai</button>`, { size: "md" });
}
function ztNetRow(n, o) {
  return `<li class="zt-net${n.viewing ? " cur" : ""}">
    <span class="zt-nic">${ic("hub")}</span>
    <div class="zt-nb"><b>${esc(n.name || "(tanpa nama)")}</b> ${n.current ? `<span class="pill info">Dipakai panel</span>` : ""}${n.viewing ? ` <span class="tag gray">sedang dibuka</span>` : ""}
      <div class="muted zt-small"><span class="mono">${esc(n.nwid)}</span> · ${n.subnet ? `<span class="mono">${esc(n.subnet)}</span>` : "tanpa rentang"} · ${n.members} perangkat · ${n.private ? "private" : "public"}</div>
      ${n.conflict ? `<div class="zt-small" style="color:var(--bad);margin-top:2px">${esc(n.conflict)}</div>` : ""}</div>
    <div class="zt-na">${o.open && !n.viewing ? `<button class="btn sm" data-zopen="${esc(n.current ? "" : n.nwid)}">Buka</button>` : ""}${!n.current && o.canUse ? `<button class="btn sm pri" data-zuse="${esc(n.nwid)}" ${n.conflict ? "disabled" : ""}>Hubungkan VPS</button>` : ""}
      ${!n.current ? `<button class="btn sm ghost icon danger" title="Hapus jaringan" data-zdel="${esc(n.nwid)}" data-name="${esc(n.name || n.nwid)}" data-n="${n.members}">${ic("trash")}</button>` : ""}</div></li>`;
}
function ztBindNets(b, z) {
  b.querySelectorAll("[data-zopen]").forEach((btn) => (btn.onclick = () => ztOpenNet(btn.dataset.zopen, b)));
  b.querySelectorAll("[data-zuse]").forEach((btn) => (btn.onclick = async () => {
    busyBtn(btn, true);
    try {
      const r = await api("/api/zt/use", { method: "POST", body: { nwid: btn.dataset.zuse } });
      await load(); ZTV.net = ""; try { localStorage.removeItem("vpnacs-ztnet"); } catch (e) {} setZerotier(b);
      doneDialog("VPS tersambung ke ZeroTier", `<p>IP ZeroTier VPS: <b class="mono">${esc(r.vpsIp)}</b> (rentang ${esc(r.subnet)}).</p>${r.ready ? "" : "<p>Interface ZeroTier di VPS belum siap. Tunggu sebentar, lalu muat ulang.</p>"}<p>Sekarang jalur <b>ZeroTier</b> bisa dipilih saat menambah router.</p>`, "ok", false);
    } catch (e) { busyBtn(btn, false); toast(e.message); }
  }));
  b.querySelectorAll("[data-zdel]").forEach((btn) => (btn.onclick = () => confirmDialog({
    title: `Hapus jaringan ${esc(btn.dataset.name)}?`, danger: true, ok: "Hapus jaringan", wide: true,
    text: `<p>Jaringan <b class="mono">${esc(btn.dataset.zdel)}</b> dihapus dari controller beserta ${esc(btn.dataset.n)} perangkatnya. Perangkat yang masih memakai Network ID ini akan terputus.</p>`,
    check: "Saya mengerti jaringan ini tidak bisa dikembalikan",
    onOk: async () => { await api(`/api/zt/networks/${btn.dataset.zdel}`, { method: "DELETE" }); closeModal(); await load(); if (ZTV.net === btn.dataset.zdel) { ZTV.net = ""; try { localStorage.removeItem("vpnacs-ztnet"); } catch (e) {} } setZerotier(b); toast("Jaringan dihapus"); },
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
      await load();
      ZTV.net = r.connected ? "" : r.nwid; try { ZTV.net ? localStorage.setItem("vpnacs-ztnet", ZTV.net) : localStorage.removeItem("vpnacs-ztnet"); } catch (e) {}
      setZerotier(b);
      if (r.connected) doneDialog("Jaringan dibuat & VPS tersambung", `<p>Network ID <b class="mono">${esc(r.nwid)}</b>, IP VPS <b class="mono">${esc(r.vpsIp)}</b>.</p><p>Sekarang jalur <b>ZeroTier</b> bisa dipilih saat menambah router.</p>`, "ok", false);
      else if (r.connectError) doneDialog("Jaringan dibuat", `<p>Network ID <b class="mono">${esc(r.nwid)}</b>. VPS belum bisa dihubungkan: ${esc(r.connectError)}</p>`, "info", false);
      else doneDialog("Jaringan dibuat", `<p>Network ID <b class="mono">${esc(r.nwid)}</b>.</p>`);
    } catch (e) { $("#zcErr").textContent = e.message; busyBtn($("#zcOk"), false); }
  };
}
function ztSettingsDialog(cur, b, box) {
  const dns = cur.dns || { domain: "", servers: [] };
  const form = `
    <div class="zt-sec"><h3>Umum</h3>
      <label for="zsName">Nama jaringan</label>
      <input id="zsName" type="text" maxlength="64" value="${esc(cur.name || "")}">
      <label>Akses</label>
      <div class="seg"><label><input type="radio" name="zsPriv" value="1" ${cur.private ? "checked" : ""}>Private</label><label><input type="radio" name="zsPriv" value="0" ${cur.private ? "" : "checked"}>Public</label></div>
      <div class="help" id="zsPrivHelp"></div></div>
    <div class="zt-sec"><h3>Alamat IP</h3>
      <label for="zsSub">Rentang IP</label>
      <input id="zsSub" type="text" class="mono" value="${esc(cur.subnet)}">
      <div class="note warn zt-subwarn hidden" id="zsSubWarn">${ic("alert")}<div>${cur.active ? "<b>Semua IP ZeroTier akan dipindah</b>VPS, router, dan perangkat lain otomatis mendapat IP di rentang baru, dan rute ikut diperbarui. Bila IP VPS berubah, router ZeroTier ditandai untuk memasang ulang script MikroTik." : "<b>Rentang jaringan diganti</b>Perangkat baru mendapat IP di rentang baru. IP perangkat yang sudah ada tidak dipindah otomatis; ubah per perangkat bila perlu."}</div></div>
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
    <div class="err" id="zsErr"></div>`;
  if (box) box.innerHTML = `<div class="ch"><h2>Pengaturan jaringan</h2><span class="muted zt-small">${esc(cur.name || cur.nwid)}</span></div><div class="cb zt-setin">${form}<div class="form-actions"><button class="btn pri" id="zsOk">${ic("check")}Simpan</button></div></div>`;
  else modal("Pengaturan jaringan", form, `<button class="btn" data-act="closemodal">Batal</button><button class="btn pri" id="zsOk">Simpan</button>`, { size: "lg" });
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
        nwid: cur.nwid, name: $("#zsName").value, private: document.querySelector("input[name=zsPriv]:checked").value === "1",
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
  const save = async (bodyData, msg) => { await api(`/api/zt/member/${m.node}?nwid=${cur.nwid}`, { method: "POST", body: bodyData }); await load(); setZerotier(b); toast(msg); };
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
    `${isRouter ? "" : `<button class="btn ghost danger" id="zeDel">${ic("trash")}Hapus perangkat</button><span class="sp"></span>`}<button class="btn" data-act="closemodal">Batal</button><button class="btn pri" id="zeOk">Simpan</button>`, { size: "md" });
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
    onOk: async () => { await api(`/api/zt/member/${m.node}?nwid=${cur.nwid}`, { method: "DELETE" }); closeModal(); await load(); setZerotier(b); toast("Perangkat dihapus"); },
  });
}

/* ================= WireGuard ================= */
function viewWireguard(v) {
  crumb([["WireGuard"]]);
  v.innerHTML = `
    <div class="ph"><div><h1>WireGuard</h1><p id="wgSub">Jalur VPN UDP yang ringan untuk router RouterOS v7.</p></div>
      <div class="acts"><button class="btn" id="wgRe">${ic("refresh")}Muat ulang</button><button class="btn pri" data-act="add">${ic("plus")}Tambah router</button></div></div>
    <div id="wgBody"></div>`;
  const b = $("#wgBody");
  $("#wgRe").onclick = () => { busyBtn($("#wgRe"), true); setWireguard(b).finally(() => busyBtn($("#wgRe"), false)); };
  setWireguard(b);
}
let WGPOLL = null;
async function setWireguard(b) {
  if (!b.innerHTML) b.innerHTML = `<div class="card"><div class="empty"><span class="spin"></span><p style="margin-top:10px">Membaca WireGuard…</p></div></div>`;
  let w;
  try { w = await api("/api/wg"); } catch (e) { b.innerHTML = `<div class="note bad">${ic("alert")}<div><b>Gagal membaca WireGuard</b>${esc(e.message)}</div></div>`; return; }
  if (!location.hash.startsWith("#/wireguard")) return;
  const sub = $("#wgSub");
  if (sub) sub.innerHTML = `<span class="zt-node"><span class="dot ${w.up ? "ok" : "bad"}"></span>Interface <b class="mono">${esc(w.iface)}</b> · ${esc(w.version || "wireguard-tools")} · ${w.up ? "menyala" : "mati"}</span>`;
  const S = w.sites, on = S.filter((x) => x.online).length;
  const fb = (n) => (n >= 1024 ** 3 ? (n / 1024 ** 3).toFixed(1).replace(".", ",") + " GB" : n >= 1024 ** 2 ? (n / 1024 ** 2).toFixed(1).replace(".", ",") + " MB" : Math.round(n / 1024) + " KB");
  const stale = S.filter((x) => x.stale);
  b.innerHTML = `
    ${!w.up ? `<div class="note bad">${ic("alert")}<div><b>Interface ${esc(w.iface)} tidak menyala</b>Router WireGuard tidak bisa tersambung. Coba <code>systemctl restart wg-quick@${esc(w.iface)}</code>, atau buka Add-on → WireGuard → Periksa.</div></div>` : ""}
    ${stale.length ? `<div class="note warn">${ic("alert")}<div><b>${stale.length} router perlu pasang ulang script</b>${stale.map((x) => `<a href="#/router/${esc(x.id)}/script">${esc(x.name)}</a>`).join(", ")}. Port, rentang, atau kunci berubah; salin script terbaru ke MikroTik.</div></div>` : ""}
    <div class="zt-top">
      <div class="zt-main">
        <div class="card">
          <div class="ch"><h2>Server WireGuard di VPS</h2>${w.up ? `<span class="pill ok">Menyala</span>` : `<span class="pill bad">Mati</span>`}</div>
          <div class="zt-cur">
            <div class="zt-hrow"><span class="zt-hl">Endpoint</span><span class="zt-hv"><span class="zt-idbox"><span class="zt-nwid mono" style="font-size:15px">${esc(w.endpoint)}</span><button class="zt-ib" data-copy="${esc(w.endpoint)}" data-msg="Endpoint tersalin" title="Salin endpoint">${ic("copy")}</button></span></span></div>
            <div class="zt-hrow"><span class="zt-hl">Public key VPS</span><span class="zt-hv"><span class="mono wg-key">${esc(w.pub)}</span><button class="zt-ib" data-copy="${esc(w.pub)}" data-msg="Public key tersalin" title="Salin public key">${ic("copy")}</button></span></div>
            <div class="zt-hmeta"><span class="pill info">UDP ${esc(w.port)}</span><span class="muted">interface <span class="mono">${esc(w.iface)}</span></span></div>
          </div>
        </div>
        <div class="card">
          <div class="ch"><h2>Konfigurasi &amp; kesehatan</h2><span class="muted zt-small">diperbarui tiap menit</span></div>
          <div class="zt-health">
            <div class="zt-hc"><span>Rentang IP</span><b class="mono">${esc(w.subnet)}</b><small>IP router dibagikan otomatis mulai .2</small></div>
            <div class="zt-hc"><span>IP VPS (gateway)</span><b class="mono">${esc(w.vpsIp)}</b><small>${S.length} router memakai jalur ini</small></div>
            <div class="zt-hc"><span>Router tersambung</span><b>${on} <em>dari ${S.length}</em></b><div class="zt-bar"><i style="width:${S.length ? Math.round((on / S.length) * 100) : 0}%"></i></div></div>
            <div class="zt-hc"><span>Data total</span><b>${fb(S.reduce((a, x) => a + x.rx, 0))}</b><small>diterima · ${fb(S.reduce((a, x) => a + x.tx, 0))} dikirim</small></div>
          </div>
        </div>
      </div>
      <div class="zt-side">
        <div class="card"><div class="ch"><h2>Firewall provider</h2><span class="zt-tip" title="Panel sudah membuka port ini di firewall VPS (iptables/UFW).">${ic("info")}</span></div>
          <div class="cb" style="padding-top:12px">
            <p class="muted" style="font-size:13px;line-height:1.55">Buka port berikut di firewall/security group provider VPS (bila ada), supaya MikroTik bisa tersambung:</p>
            <div class="wg-port"><span class="mono">UDP ${esc(w.port)}</span>${copyBtn(String(w.port), "Port tersalin")}</div>
          </div></div>
        <div class="card zt-actc">
          <button class="btn pri" id="wgSet">${ic("sliders")}Pengaturan WireGuard</button>
          <a class="btn" href="#/addon">${ic("puzzle")}Periksa di Add-on</a>
        </div>
      </div>
    </div>
    <div class="card">
      <div class="ch"><h2>Router WireGuard</h2><span class="muted" style="font-size:12.5px">${S.length} router</span></div>
      ${S.length ? `<div class="zt-tw"><table class="t"><thead><tr><th>Router</th><th>IP WireGuard</th><th class="hide-sm">Endpoint</th><th class="hide-sm">Handshake</th><th class="hide-md">Data</th><th>Status</th></tr></thead><tbody>
        ${S.map((x) => `<tr class="click" data-go="#/router/${esc(x.id)}"><td><div class="zt-dev"><span class="zt-av router">${ic("router")}</span><div style="min-width:0"><div class="zt-nm">${esc(x.name)}${x.stale ? ' <span class="tag gray">pasang ulang script</span>' : ""}</div><div class="muted zt-small mono">${esc(x.virtualSubnet)}</div></div></div></td>
          <td class="mono">${esc(x.wgIp || "—")}</td>
          <td class="hide-sm mono">${esc(x.endpoint || "—")}</td>
          <td class="hide-sm">${x.handshake ? esc(ztAgo(x.handshake)) : '<span class="muted">belum pernah</span>'}</td>
          <td class="hide-md muted">${x.handshake ? `↓ ${fb(x.rx)} · ↑ ${fb(x.tx)}` : "—"}</td>
          <td>${x.online ? `<span class="pill ok">Tersambung</span>` : x.installed ? `<span class="pill bad">Terputus</span>` : `<span class="pill wait">Menunggu</span>`}</td></tr>`).join("")}
      </tbody></table></div>`
      : `<div class="empty"><div class="big">${ic("bolt")}</div><h3>Belum ada router WireGuard</h3><p>Tambah router baru dengan jalur WireGuard, atau ubah jalur router yang sudah ada.</p><button class="btn pri" style="margin-top:12px" data-act="add">${ic("plus")}Tambah router</button></div>`}
    </div>
    <p class="help" style="margin-top:12px">Router dianggap tersambung bila handshake terakhir kurang dari 3 menit. Script memakai <code>persistent-keepalive</code> 25 detik, jadi tetap tersambung walau MikroTik di belakang NAT.</p>`;
  paintIcons(b);
  b.querySelectorAll("tr[data-go]").forEach((tr) => (tr.onclick = (e) => { if (!e.target.closest("a,button")) location.hash = tr.dataset.go; }));
  $("#wgSet").onclick = () => wgSettingsDialog(w, b);
  clearInterval(WGPOLL);
  WGPOLL = setInterval(() => {
    if (!location.hash.startsWith("#/wireguard") || !document.body.contains(b)) return clearInterval(WGPOLL);
    if ($("#modalRoot").innerHTML || document.hidden) return;
    setWireguard(b);
  }, 30000);
}
function wgSettingsDialog(w, b) {
  modal("Pengaturan WireGuard", `
    <label for="wsPort">Port UDP</label>
    <input id="wsPort" type="number" min="1024" max="65535" value="${esc(w.port)}" style="max-width:180px">
    <div class="help">Bawaan 51820. Ganti bila port itu diblokir provider. Panel membuka port baru di firewall VPS; buka juga di firewall provider.</div>
    <label for="wsSub">Rentang IP</label>
    <input id="wsSub" type="text" class="mono" value="${esc(w.subnet)}">
    <div class="help">IP private /16 sampai /28. VPS memakai alamat .1, router mulai .2. Tidak boleh bentrok dengan L2TP, ZeroTier, IP virtual, atau subnet ONT.</div>
    ${w.sites.length ? `<div class="note warn" style="margin-top:12px">${ic("alert")}<div><b>${w.sites.length} router perlu pasang ulang script</b>Bila port atau rentang diganti, router WireGuard terputus sampai script terbaru dipasang di MikroTik.</div></div>` : ""}
    <div class="err" id="wsErr"></div>`,
    `<button class="btn" data-act="closemodal">Batal</button><button class="btn pri" id="wsOk">Simpan</button>`, { size: "md" });
  $("#wsOk").onclick = async () => {
    $("#wsErr").textContent = ""; busyBtn($("#wsOk"), true);
    try {
      const r = await api("/api/wg", { method: "PUT", body: { port: parseInt($("#wsPort").value, 10), subnet: $("#wsSub").value.trim() } });
      await load(); setWireguard(b);
      if (!r.changed) { closeModal(); toast("Tidak ada perubahan"); }
      else doneDialog("Pengaturan WireGuard disimpan", r.stale ? `<p>${r.stale} router perlu pasang ulang script MikroTik. Daftarnya ada di bagian atas halaman WireGuard.</p>` : "", "ok", !r.stale);
    } catch (e) { $("#wsErr").textContent = e.message; busyBtn($("#wsOk"), false); }
  };
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
      <div class="form-actions start" style="margin-top:10px"><button class="btn" id="tgDetect">${ic("search")}Deteksi grup &amp; topik</button><button class="btn ghost" id="tgHook" title="Lepas bot dari aplikasi lain yang memakai webhook">${ic("x")}Hapus webhook</button><span class="help" id="tgBot" style="margin:auto 0">${t.botName ? "Bot: @" + esc(t.botName) : ""}</span></div>
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
        ${t.tokenSet ? `<button class="btn ghost danger" id="tgClear">${ic("trash")}Hapus Telegram</button><span class="sp"></span>` : ""}
        <button class="btn" id="tgTest">${ic("send")}Kirim pesan tes</button>
        <button class="btn pri" id="tgSave">Simpan</button>
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
  const hc = document.createElement("div"); b.appendChild(hc); healthSettings(hc);
}
// ---------- Laporan kesehatan VPS (tab Notifikasi Telegram) ----------
async function healthSettings(el) {
  let x;
  try { x = await api("/api/health"); } catch (e) { el.innerHTML = ""; return; }
  if (!document.body.contains(el)) return;
  const c = x.conf;
  el.innerHTML = `<div class="card" style="margin-top:16px"><div class="ch"><h2>Laporan kesehatan VPS</h2>${c.enabled ? `<span class="pill ok">tiap ${c.days} hari · ${esc(c.time)}</span>` : `<span class="pill wait">nonaktif</span>`}</div>
    <form class="cb" id="hlForm" style="padding-top:4px">
      <label class="check" style="margin-top:4px"><input type="checkbox" id="hlOn" ${c.enabled ? "checked" : ""}> Kirim laporan kesehatan VPS secara berkala</label>
      <div class="hl-row">
        <div><label for="hlDays">Interval</label><div class="hl-in"><input id="hlDays" type="number" min="1" max="30" value="${c.days}"><span>hari</span></div></div>
        <div><label for="hlTime">Jam kirim</label><input id="hlTime" type="time" value="${esc(c.time)}"></div>
      </div>
      <div class="help">Isi: CPU, RAM, swap, disk, uptime VPS, status layanan (panel, VPN, GenieACS, add-on), dan ringkasan router. ${x.next ? `Laporan berikutnya <b>${esc(fmtT(x.next, true))}</b>.` : ""}${x.lastSent ? ` Terakhir dikirim ${esc(fmtT(x.lastSent, true))}.` : ""}</div>
      <label class="check" style="margin-top:14px"><input type="checkbox" id="hlAlert" ${c.alerts ? "checked" : ""}> Peringatan langsung bila disk atau RAM di atas 90% atau ada layanan mati</label>
      <div class="help">Dikirim saat masalah muncul, diulang paling sering sekali per 6 jam selama belum beres, dan ada pesan saat kembali normal.</div>
      ${x.tgActive ? "" : `<div class="note warn" style="margin-top:12px">${ic("alert")}<div><b>Telegram belum aktif</b>Atur bot dan grup di atas dulu; laporan baru dikirim setelah Telegram aktif.</div></div>`}
      <div class="err" id="hlErr"></div>
      <div class="form-actions"><button type="button" class="btn" id="hlTest" ${x.tgActive ? "" : "disabled"}>${ic("send")}Kirim sekarang</button><button class="btn pri">Simpan</button></div>
    </form></div>`;
  paintIcons(el);
  const sync = () => { const on = $("#hlOn").checked; $("#hlDays").disabled = !on; $("#hlTime").disabled = !on; };
  $("#hlOn").onchange = sync; sync();
  $("#hlForm").onsubmit = async (e) => {
    e.preventDefault(); $("#hlErr").textContent = ""; const btn = e.target.querySelector("button.pri"); busyBtn(btn, true);
    try {
      const r = await api("/api/health", { method: "PUT", body: { enabled: $("#hlOn").checked, days: parseInt($("#hlDays").value, 10), time: $("#hlTime").value, alerts: $("#hlAlert").checked } });
      toast(r.next ? `Disimpan · laporan berikutnya ${fmtT(r.next, true)}` : "Disimpan"); healthSettings(el);
    } catch (err) { $("#hlErr").textContent = err.message; busyBtn(btn, false); }
  };
  $("#hlTest").onclick = async () => { const btn = $("#hlTest"); busyBtn(btn, true); try { await api("/api/health/send", { method: "POST" }); toast("Laporan dikirim ke Telegram"); } catch (err) { $("#hlErr").textContent = err.message; } busyBtn(btn, false); };
}
// ---------- Kartu Kesehatan VPS (Dashboard) ----------
let HEALTH_HTML = "";
async function dashHealth() {
  const el = $("#dashHealth"); if (!el) return;
  let x;
  try { x = await api("/api/health"); } catch (e) { el.innerHTML = ""; return; }
  if (!document.body.contains(el)) return;
  const col = (p) => (p >= 90 ? "var(--bad)" : p >= 75 ? "var(--warn)" : "var(--ok)");
  const bar = (label, p, sub) => `<div class="vh-r"><div class="vh-t"><span>${label}</span><b>${p == null ? "—" : p + "%"}</b></div><div class="zt-bar"><i style="width:${p || 0}%;background:${col(p || 0)}"></i></div><small>${sub}</small></div>`;
  const fb = (n) => (n >= 1024 ** 3 ? (n / 1024 ** 3).toFixed(1).replace(".", ",") + " GB" : Math.round(n / 1024 ** 2) + " MB");
  const down = x.services.filter((v) => !v.active);
  const html = `<div class="card"><div class="ch"><h2>Kesehatan VPS</h2><span class="live${down.length ? " bad" : ""}"><i></i>${down.length ? "Ada layanan mati" : "Online"}</span></div>
    <div class="vh">
      ${bar("CPU", x.cpu == null ? null : Math.round(x.cpu), `beban ${x.load[0].toFixed(2).replace(".", ",")} · ${x.cores} inti`)}
      ${bar("RAM", x.mem.pct, `${fb(x.mem.used)} / ${fb(x.mem.total)}`)}
      ${x.disk ? bar("Disk", x.disk.pct, `${fb(x.disk.used)} / ${fb(x.disk.total)}`) : ""}
      <div class="vh-f"><span class="pill ${down.length ? "bad" : "ok"}">${down.length ? `${down.length} layanan mati` : `${x.services.length} layanan berjalan`}</span><span class="muted zt-small">uptime ${esc(fmtDurShortD(x.uptime))}</span></div>
      ${down.length ? `<div class="zt-small" style="color:var(--bad)">${down.map((v) => esc(v.label)).join(", ")}</div>` : ""}
      <div class="vh-l"><a href="#/pengaturan/telegram">Laporan kesehatan ke Telegram</a></div>
    </div></div>`;
  if (el.firstElementChild) { const t = document.createElement("div"); t.innerHTML = html; paintIcons(t); morph(el, t); } else { el.innerHTML = html; paintIcons(el); }
  HEALTH_HTML = el.innerHTML;
}
function fmtDurShortD(ms) { const d = Math.floor(ms / 86400e3), h = Math.floor((ms % 86400e3) / 3600e3); return d ? `${d} hari ${h} jam` : `${h} jam ${Math.floor((ms % 3600e3) / 60e3)} menit`; }

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
      ${c.https && c.httpsActive && !onHttps ? `<div class="cb card-actions"><a class="btn pri" href="https://${esc(c.domain)}:${port}/">${ic("lock")}Buka panel lewat HTTPS</a></div>` : ""}
      <div class="cb card-actions">
        <button class="btn ghost danger" id="cfRemove">${ic("trash")}Lepas domain</button>
        <span class="sp"></span>
        <button class="btn" id="cfAgain">${ic("refresh")}Verifikasi ulang</button>
      </div></div>
    <div class="card"><div class="ch"><h2>Subdomain layanan</h2></div><form class="cb" id="subForm" style="padding-top:6px">
      <p class="help" style="margin-top:4px">Panel membuat record DNS (DNS only) di <b>${esc(c.zoneName)}</b> untuk GenieACS dan aplikasi add-on yang terpasang, lalu memasang link-nya di panel. ${c.https ? "Sertifikat HTTPS ikut diperluas otomatis. " : ""}Nama subdomain bisa diganti kapan saja; record lama buatan panel ikut dihapus.</p>
      <div class="subl">${(c.subServices || []).map((x) => {
        const k = x.key, cur = (c.subdomains || {})[k];
        const val = cur ? cur.host.slice(0, -(c.zoneName.length + 1)) : x.def;
        const sfx = x.port && !c.stdActive ? ":" + x.port : "";
        const scheme = c.https && c.stdActive ? "https" : "http";
        const blocked = x.addon && !c.stdActive;
        return `<div class="subi"><label class="check"><input type="checkbox" id="subOn_${esc(k)}" ${blocked ? "disabled" : cur || (!x.addon && !Object.keys(c.subdomains || {}).length) ? "checked" : ""}>${esc(x.label)} ${x.addon ? `<span class="tag gray">Add-on</span>` : ""}</label>
          <div class="subr"><input id="sub_${esc(k)}" type="text" value="${esc(val)}"><span class="mono muted">.${esc(c.zoneName)}${sfx}</span></div>
          ${blocked ? `<div class="help">Butuh <a href="#/pengaturan/umum">Alamat panel</a> (port web) aktif.</div>` : cur ? `<div class="help">Aktif: <a class="ext" href="${scheme}://${esc(cur.host)}${sfx}" target="_blank" rel="noopener">${esc(cur.host)}${sfx}${ic("ext", "")}</a></div>` : ""}</div>`;
      }).join("")}</div>
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
      <div class="help">Panel akan dibuka lewat <span class="mono">${STATE.settings.stdPorts && STATE.settings.stdPorts.active ? "https://domain" : "https://domain:" + port}</span>. VPN, GenieACS, dan Winbox tidak terpengaruh.</div>
      <div class="note info" style="margin:14px 0 0">${ic("info")}<div><b>Record dibuat dalam mode DNS only (awan abu-abu)</b>Proxy Cloudflare (awan oranye) tidak bisa meneruskan VPN L2TP dan Winbox, jadi panel otomatis mematikannya untuk domain ini.</div></div>
      <div class="err" id="cfErr"></div>
      <div class="form-actions"><button class="btn pri" id="cfGo">${ic("play")}Verifikasi &amp; terapkan</button></div>
    </form></div>
`;
  $("#cfForm").onsubmit = (e) => { e.preventDefault(); runCf($("#cfDom").value.trim(), $("#cfTok").value.trim(), $("#cfHttps").checked); };
  const sf = $("#subForm");
  if (sf) {
    const sync = (k) => { $("#sub_" + k).disabled = !$("#subOn_" + k).checked; };
    const SK = (c.subServices || []).map((x) => x.key);
    SK.forEach((k) => { $("#subOn_" + k).onchange = () => sync(k); sync(k); });
    sf.onsubmit = (e) => {
      e.preventDefault(); $("#subErr").textContent = "";
      const body = {};
      SK.forEach((k) => { body[k] = $("#subOn_" + k).checked ? $("#sub_" + k).value.trim() : ""; });
      if (!SK.some((k) => body[k]) && !Object.keys(c.subdomains || {}).length) { $("#subErr").textContent = "Aktifkan minimal satu subdomain."; return; }
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
  if (!$("#cfSteps") || !CF) return;
  const cl = $("#cfClose"); if (cl) cl.disabled = !!CF.running;
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
  // Proses tampil di jendela progres, sama seperti pemasangan add-on dan tes koneksi
  modal(`<span id="cfTitle">Memverifikasi</span>`, `
    <div class="tst-top" id="cfSub"></div>
    <div class="prog"><i id="cfProg"></i></div>
    <ol class="steps" id="cfSteps"></ol>
    <div id="cfSum"></div>`, `<button class="btn" data-act="closemodal" id="cfClose" disabled>Tutup</button>`, { size: "lg", flush: true });
  drawCf();
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
  if (CF.ok && !CF.url) { await load(); ROUTE_AFTER_CLOSE = true; }
}

/* ================= Log aktivitas ================= */
let LOGQ = "";
function viewLog(v) {
  crumb([["Log aktivitas"]]);
  v.innerHTML = `
    <div class="ph"><div><h1>Log aktivitas</h1><p>Catatan perubahan di panel dan kejadian penting. Disimpan 90 hari.</p></div></div>
    <div class="card">
      <div class="ch"><h2>Riwayat aktivitas</h2><span class="muted" id="logCount" style="font-size:12.5px"></span></div>
      <div class="toolbar"><div class="search">${ic("search", "")}<input id="lq" type="text" placeholder="Cari aktivitas, router, atau IP" value="${esc(LOGQ)}"></div></div>
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
  else if (act === "refresh") { const b = a; b.classList.add("spinning"); try { await load(); liveRefresh(); toast("Status diperbarui"); } finally { b.classList.remove("spinning"); } }
  else if (act === "add") openAdd();
  else if (act === "menu") $("#menuList").classList.toggle("hidden");
  else if (act === "edit") { $("#menuList").classList.add("hidden"); openEdit(a.dataset.id); }
  else if (act === "resetpw") { $("#menuList").classList.add("hidden"); openResetPw(a.dataset.id); }
  else if (act === "ztdone") {
    const id = a.dataset.id || cur;
    try { await api(`/api/sites/${id}/zt-script-done`, { method: "POST", body: {} }); await load(); route(); toast("Ditandai sudah dipasang"); } catch (err) { toast(err.message, true); }
  }
  else if (act === "transport") { const m = $("#menuList"); if (m) m.classList.add("hidden"); openTransport(a.dataset.id || cur); }
  else if (act === "wgdone") {
    const id = a.dataset.id || cur;
    try { await api(`/api/sites/${id}/wg-script-done`, { method: "POST", body: {} }); await load(); route(); toast("Ditandai sudah dipasang"); } catch (err) { toast(err.message, true); }
  }
  else if (act === "wgrekey") {
    $("#menuList").classList.add("hidden");
    const id = a.dataset.id || cur, xs = site(id);
    confirmDialog({ title: "Buat kunci WireGuard baru?", icon: "key", ok: "Buat kunci baru", danger: true,
      text: `<p>Kunci lama <b>${esc(xs ? xs.name : "")}</b> langsung tidak berlaku, jadi router terputus sampai script baru dipasang di MikroTik. Pakai ini bila kunci router mungkin bocor.</p>`,
      onOk: async () => { await api(`/api/sites/${id}/wg-rekey`, { method: "POST", body: {} }); closeModal(); await load(); location.hash = `#/router/${id}/script`; route(); toast("Kunci baru dibuat. Pasang ulang script."); } });
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
    if (me.loggedIn) { showApp(); await load(); route(); idleStart(); } else showLogin();
  } catch (e) { showLogin(); }
  setInterval(async () => {
    if ($("#appView").classList.contains("hidden") || $("#mbg") || TEST) return;
    const h = location.hash;
    if (CF && CF.running) return;
    try { await load(); if (!/\/(tes|port)$|^#\/(pengaturan|log|genieacs|zerotier|wireguard)/.test(h) && !document.activeElement.matches("input,select")) liveRefresh(); } catch (e) {}
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
# Folder repo ini dicatat agar panel bisa memperbarui dirinya sendiri (menu Pengaturan → Pembaruan)
if [ -d "$SCRIPT_DIR/.git" ]; then echo "$SCRIPT_DIR" > "$APP_DIR/source-dir"; chmod 600 "$APP_DIR/source-dir"; fi

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
$nrconf{override_rc}->{qr(^wg-quick@[^.]*\.service$)} = 0;
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
# Panel memakai port 80/443 secara bawaan (bisa diganti di Pengaturan); beri tahu bila port itu dipakai program lain
SP_HTTP="$("$NODE_BIN" -e 'try{console.log(require(process.argv[1]).settings.stdHttp||80)}catch(e){console.log(80)}' "$APP_DIR/data.json" 2>/dev/null)"; SP_HTTP="${SP_HTTP:-80}"
SP_HTTPS="$("$NODE_BIN" -e 'try{console.log(require(process.argv[1]).settings.stdHttps||443)}catch(e){console.log(443)}' "$APP_DIR/data.json" 2>/dev/null)"; SP_HTTPS="${SP_HTTPS:-443}"
for i in 1 2 3; do ss -Hltnp 2>/dev/null | grep -E "[:.]${SP_HTTP}[[:space:]]" | grep -q node && break; sleep 1; done
if ss -Hltnp 2>/dev/null | grep -E "[:.]${SP_HTTP}[[:space:]]" | grep -q node; then
  ok "Panel juga dibuka di port ${SP_HTTP}/${SP_HTTPS}"
else
  WHO80="$(ss -Hltnp 2>/dev/null | grep -E "[:.](${SP_HTTP}|${SP_HTTPS})[[:space:]]" | grep -oP 'users:\(\("\K[^"]+' | sort -u | tr '\n' ' ')"
  if [ -n "$WHO80" ]; then
    warn "Port ${SP_HTTP}/${SP_HTTPS} dipakai: ${WHO80}— panel hanya di port ${PANEL_PORT}. Ganti port di Pengaturan → Umum → Alamat panel"
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
