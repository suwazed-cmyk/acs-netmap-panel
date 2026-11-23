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

ask_password() {
  local p1 p2
  while true; do
    read -r -s -p "Buat password admin panel (minimal 8 karakter): " p1; echo
    [ ${#p1} -ge 8 ] || { echo "Terlalu pendek, coba lagi."; continue; }
    read -r -s -p "Ulangi password: " p2; echo
    [ "$p1" = "$p2" ] || { echo "Tidak sama, coba lagi."; continue; }
    break
  done
  "$NODE_BIN" "$APP_DIR/server.js" --set-password "$p1"
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
const net = require("net");
const tls = require("tls");
const fs = require("fs");
const path = require("path");
const crypto = require("crypto");
const { execFile } = require("child_process");

// ---------- Konfigurasi ----------
const ROOT = process.env.VPNACS_FSROOT || ""; // hanya untuk pengujian
const PORT = parseInt(process.env.VPNACS_PORT || "8088", 10);
const HOST = process.env.VPNACS_HOST || "0.0.0.0";
const APP_DIR = __dirname;
const DATA_FILE = ROOT + "/opt/vpn-acs/data.json";
const CHAP_FILE = ROOT + "/etc/ppp/chap-secrets";
const IPSEC_SECRETS = ROOT + "/etc/ipsec.secrets";
const ROUTE_SCRIPT = ROOT + "/etc/ppp/ip-up.d/vpn-acs-routes";
const GENIE_ENV = ROOT + "/opt/genieacs/genieacs.env";
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

const VERSION = "1.3.0";
const DEFAULT_TUNNEL_NET = "192.168.42.0/24";
const XL2TPD_CONF = ROOT + "/etc/xl2tpd/xl2tpd.conf";
const VIRTUAL_POOL = "10.100.0.0/14";
const ACS_PORT = 7547;
const MARK_BEGIN = "# >>> VPN-ACS (dikelola Panel VPN ACS, jangan diedit manual) >>>";
const MARK_END = "# <<< VPN-ACS <<<";
const SESSION_TTL = 12 * 3600 * 1000;
const FWD_AUTO_START = 20001; // port publik otomatis mulai dari sini
const RESERVED_PORTS = new Set([22, 25, 53, 80, 443, 500, 1701, 3000, 4500, 7547, 7557, 7567, 8080, 27017, PORT]);
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
function settings(d) {
  const s = d.settings || {};
  return {
    publicIp: s.publicIp || detectPublicIp(),
    psk: readPsk(),
    genieCidr: readGenieCidr(),
    useIpsec: !!s.useIpsec,
    tun: tun(d),
  };
}

// ---------- Jalankan perintah ----------
function run(cmd, args, timeoutMs) {
  return new Promise((resolve) => {
    if (DRY_RUN && ((cmd === "ip" && args[0] === "route") || cmd === "iptables")) return resolve({ code: 0, out: "" });
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
  for (const s of d.sites) {
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
  for (const s of d.sites) {
    sh += `  ${s.tunnelIp}) ip route replace ${s.virtualSubnet} dev "$IFNAME" ;; # ${s.name.replace(/[^\w .-]/g, "")}\n`;
  }
  sh += "esac\nexit 0\n";
  fs.mkdirSync(path.dirname(ROUTE_SCRIPT), { recursive: true });
  fs.writeFileSync(ROUTE_SCRIPT, sh, { mode: 0o755 });
}
function escapeRe(s) {
  return s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}
function fwdTarget(site, f) {
  if (f.target === "router") return site.tunnelIp;
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
    for (const f of site.forwards || []) {
      const target = fwdTarget(site, f);
      for (const p of fwdProtos(f)) {
        const c = ["-m", "comment", "--comment", `vpnacs ${site.username} ${f.label}`.slice(0, 250)];
        await ipt(["-t", "nat", "-A", "VPNACS_PRE", "-p", p, "-m", "addrtype", "--dst-type", "LOCAL", "--dport", String(f.publicPort), "-j", "DNAT", "--to-destination", `${target}:${f.targetPort}`].concat(c));
        await ipt(["-t", "nat", "-A", "VPNACS_POST", "-o", "ppp+", "-p", p, "-d", target, "--dport", String(f.targetPort), "-j", "MASQUERADE"].concat(c));
        await ipt(["-A", "VPNACS_FWD", "-o", "ppp+", "-p", p, "-d", target, "--dport", String(f.targetPort), "-j", "ACCEPT"].concat(c));
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
  for (const s of d.sites) {
    const ifc = peers[s.tunnelIp];
    if (ifc) await run("ip", ["route", "replace", s.virtualSubnet, "dev", ifc]);
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
function mikrotikScript(s, st) {
  const c = "VPN ACS";
  return [
    `# ================================================================`,
    `#  VPN ACS - ${s.name}`,
    `#  Paste semua baris ini di Winbox > New Terminal, lalu Enter.`,
    `#  Aman dijalankan ulang (pengaturan lama "VPN ACS" dihapus dulu).`,
    `# ================================================================`,
    ``,
    st.useIpsec ? `# 1) Sambungan VPN L2TP/IPsec ke VPS` : `# 1) Sambungan VPN L2TP ke VPS (tanpa IPsec)`,
    `/interface l2tp-client remove [find where name="l2tp-acs"]`,
    st.useIpsec
      ? `/interface l2tp-client add name=l2tp-acs connect-to=${st.publicIp || "IP_PUBLIK_VPS"} user="${s.username}" password="${s.password}" use-ipsec=yes ipsec-secret="${st.psk || "PSK_VPS"}" add-default-route=no disabled=no comment="${c}"`
      : `/interface l2tp-client add name=l2tp-acs connect-to=${st.publicIp || "IP_PUBLIK_VPS"} user="${s.username}" password="${s.password}" add-default-route=no disabled=no comment="${c}"`,
    ``,
    `# 2) Route ke VPS ACS`,
    `/ip route remove [find where comment="${c}"]`,
    `/ip route add dst-address=${st.tun.net} gateway=l2tp-acs comment="${c}"`,
    ``,
    `# 3) IP virtual ONT (NETMAP) - ONT ${s.realSubnet} terlihat di VPS sebagai ${s.virtualSubnet}`,
    `/ip firewall nat remove [find where comment~"^${c}"]`,
    `/ip firewall nat add chain=srcnat src-address=${s.realSubnet} dst-address=${st.tun.net} action=netmap to-addresses=${s.virtualSubnet} comment="${c} - ONT ke IP virtual"`,
    `/ip firewall nat add chain=dstnat in-interface=l2tp-acs dst-address=${s.virtualSubnet} action=netmap to-addresses=${s.realSubnet} comment="${c} - IP virtual ke ONT"`,
    `/ip firewall nat move [find where comment="${c} - IP virtual ke ONT"] destination=0`,
    `/ip firewall nat move [find where comment="${c} - ONT ke IP virtual"] destination=0`,
    ``,
    `# 4) Izinkan lalu lintas ACS <-> ONT`,
    `/ip firewall filter remove [find where comment~"^${c}"]`,
    `/ip firewall filter add chain=forward in-interface=l2tp-acs dst-address=${s.realSubnet} action=accept comment="${c} - ACS ke ONT"`,
    `/ip firewall filter add chain=forward src-address=${s.realSubnet} out-interface=l2tp-acs action=accept comment="${c} - ONT ke ACS"`,
    `/ip firewall filter add chain=input in-interface=l2tp-acs src-address=${st.tun.local} action=accept comment="${c} - remote dari VPS"`,
    `/ip firewall filter move [find where comment="${c} - ONT ke ACS"] destination=0`,
    `/ip firewall filter move [find where comment="${c} - ACS ke ONT"] destination=0`,
    `/ip firewall filter move [find where comment="${c} - remote dari VPS"] destination=0`,
    ``,
    `:put "VPN ACS selesai dipasang. Cek status: /interface l2tp-client print"`,
  ].join("\n");
}
function mikrotikRemoveScript() {
  const c = "VPN ACS";
  return [
    `# Hapus semua pengaturan VPN ACS dari MikroTik`,
    `/interface l2tp-client remove [find where name="l2tp-acs"]`,
    `/ip route remove [find where comment="${c}"]`,
    `/ip firewall nat remove [find where comment~"^${c}"]`,
    `/ip firewall filter remove [find where comment~"^${c}"]`,
    `:put "Pengaturan VPN ACS sudah dihapus."`,
  ].join("\n");
}
function siteView(s, st, peers, h, now) {
  const real = parseCidr(s.realSubnet);
  const virt = parseCidr(s.virtualSubnet);
  const online = !!(peers && peers[s.tunnelIp]);
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
    online: !!(peers && peers[s.tunnelIp]),
    iface: (peers && peers[s.tunnelIp]) || "",
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
    removeScript: mikrotikRemoveScript(),
  };
}

// ---------- Validasi ----------
function validateSite(d, input, existing) {
  const name = String(input.name || "").trim();
  if (name.length < 2 || name.length > 40) return "Nama server 2-40 karakter.";
  if (d.sites.some((s) => s !== existing && s.name.toLowerCase() === name.toLowerCase()))
    return "Nama server sudah dipakai.";
  const sub = parseCidr(input.realSubnet);
  if (!sub) return "Subnet ONT tidak valid. Contoh yang benar: 10.0.0.0/24";
  if (sub.prefix < 16 || sub.prefix > 29) return "Ukuran subnet ONT harus antara /16 sampai /29.";
  if (!sub.aligned)
    return `Subnet ONT harus ditulis dari alamat awalnya. Mungkin maksud Anda ${sub.text}`;
  const T = tun(d);
  if (overlap(sub, T.cidr)) return `Subnet ONT tidak boleh bentrok dengan jaringan VPN ${T.net}.`;
  const others = d.sites.filter((s) => s !== existing);
  if (others.some((o) => overlap(sub, parseCidr(o.virtualSubnet))))
    return "Subnet ONT bentrok dengan IP virtual server lain.";
  const vtext = String(input.virtualSubnet || "").trim();
  if (vtext) {
    const v = parseCidr(vtext);
    if (!v) return "IP virtual tidak valid. Contoh yang benar: 10.20.1.0/24";
    if (!v.aligned) return `IP virtual harus ditulis dari alamat awalnya. Mungkin maksud Anda ${v.text}`;
    if (v.prefix !== sub.prefix)
      return `Ukuran IP virtual harus sama dengan subnet ONT (/${sub.prefix}). Contoh: ${intToIp(v.net)}/${sub.prefix}`;
    if (overlap(v, T.cidr)) return `IP virtual tidak boleh bentrok dengan jaringan VPN ${T.net}.`;
    if (overlap(v, sub)) return "IP virtual tidak boleh sama dengan subnet ONT asli.";
    const clash = others.find((o) => overlap(v, parseCidr(o.virtualSubnet)));
    if (clash) return `IP virtual ${v.text} sudah dipakai server "${clash.name}" (${clash.virtualSubnet}). Pilih yang lain.`;
    const clashReal = others.find((o) => overlap(v, parseCidr(o.realSubnet)));
    if (clashReal) return `IP virtual ${v.text} bentrok dengan subnet ONT asli server "${clashReal.name}" (${clashReal.realSubnet}).`;
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
      return { error: `IP perangkat harus di dalam subnet ONT server ini (${site.realSubnet}).` };
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
      return { error: `Port publik ${publicPort} sudah dipakai${owner ? ` di server "${owner.name}"` : ""}. Pilih port lain atau kosongkan untuk otomatis.` };
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
  const steps = [
    { key: "vpn", label: "Koneksi VPN", desc: "MikroTik tersambung ke VPS lewat L2TP" },
    { key: "ping-mt", label: "Respons MikroTik", desc: `VPS menjangkau MikroTik di ${site.tunnelIp}` },
    { key: "route", label: "Jalur ke jaringan ONT", desc: `Route ${site.virtualSubnet} terpasang di VPS` },
    { key: "ping-gw", label: "Jaringan ONT", desc: `Gateway ${intToIp(virt.net + 1)} (asli ${intToIp(real.net + 1)}) terjangkau lewat NETMAP` },
    { key: "genie", label: "Patch GenieACS", desc: `IP virtual ${site.virtualSubnet} dikenali GenieACS untuk Summon` },
  ];
  for (const f of site.forwards || []) {
    if (f.proto === "udp") continue;
    steps.push({ key: "fwd:" + f.id, label: `Remote ${f.label}`, desc: `Port ${f.publicPort} → ${fwdTarget(site, f)}:${f.targetPort}` });
  }
  return steps;
}
async function runTestStep(site, key, st) {
  const peers = await onlinePeers();
  const iface = peers[site.tunnelIp] || "";
  const virt = parseCidr(site.virtualSubnet);
  const gw = intToIp(virt.net + 1);
  if (key === "vpn") {
    if (iface) return { ok: true, detail: `Tersambung lewat ${iface}` };
    return site.installedAt
      ? { ok: false, detail: "MikroTik belum tersambung ke VPS", hint: "Pastikan script MikroTik sudah dipasang, MikroTik punya internet, dan alamat VPS di Pengaturan benar." }
      : { ok: false, detail: "Server ini belum pernah tersambung (menunggu pemasangan)", hint: "Salin script dari tab Script MikroTik, tempel di Winbox → New Terminal, lalu tes lagi." };
  }
  if (key === "ping-mt") {
    const r = await run("ping", ["-c", "2", "-W", "1", site.tunnelIp]);
    if (r.code === -2) return { ok: null, detail: "Dilewati: perintah ping tidak ada di VPS", hint: "Pasang dengan: apt install iputils-ping" };
    return r.code === 0 ? { ok: true, detail: "MikroTik membalas" } : { ok: false, detail: "MikroTik tidak membalas", hint: "Cek apakah firewall MikroTik memblokir ping dari l2tp-acs." };
  }
  if (key === "route") {
    const r = await run("ip", ["route", "get", gw]);
    const okr = !!iface && r.out.includes(iface);
    return okr ? { ok: true, detail: `Lewat ${iface}` } : { ok: false, detail: "Route belum terpasang", hint: "Route dipasang otomatis saat VPN tersambung. Sambungkan ulang L2TP di MikroTik." };
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
      : { ok: false, detail: `Di luar rentang patch (${st.genieCidr || "kosong"})`, hint: "Jalankan ulang genieacs-virtualip.sh dengan VIRTUAL_CIDR yang mencakup IP virtual server ini." };
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
    [/terminated by other getUpdates|webhook/i, "Bot ini sedang dipakai aplikasi lain (webhook). Buat bot khusus untuk panel."],
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
  if (items.length > max) lines.push(`… dan ${items.length - max} server lainnya`);
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
async function monitorTick() {
  if (monitorBusy) return;
  monitorBusy = true;
  try {
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
    for (const s of d.sites) {
      ids.add(s.id);
      const online = !!peers[s.tunnelIp];
      if (!s.installedAt) {
        // Belum pernah tersambung = menunggu pemasangan: tidak dicatat, tidak dikirim notifikasi
        if (!online) continue;
        s.installedAt = new Date(now).toISOString();
        dataChanged = true;
        logActivity(null, "Server tersambung pertama kali", s.name);
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
  if (!(up.json && up.json.ok)) return { error: tgErr(up) };
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
    if (v.code === -2) return { ok: false, detail: "certbot belum terpasang di VPS", hint: "Jalankan ulang: cd /root/suwazed-panel && git pull && bash install-vpn-acs.sh" };
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

// =====================================================================
//  HTTPS panel: satu port untuk http & https
//  - HTTPS aktif: koneksi TLS diteruskan ke server https internal,
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
      sock.end(`HTTP/1.1 301 Moved Permanently\r\nLocation: https://${HTTPS_DOMAIN}:${PORT}${p}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n`);
      return;
    }
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
  });
}

// ---------- Sesi & keamanan login ----------
const sessions = new Map();
const loginFails = new Map();
function newSession() {
  const t = crypto.randomBytes(32).toString("hex");
  sessions.set(t, Date.now() + SESSION_TTL);
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
  const exp = t && sessions.get(t);
  if (!exp) return false;
  if (exp < Date.now()) {
    sessions.delete(t);
    return false;
  }
  sessions.set(t, Date.now() + SESSION_TTL);
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
    sessions.delete(getCookie(req, "vpnacs"));
    return send(res, 200, { ok: true }, { "Set-Cookie": `vpnacs=; ${cookieFlags(req)}; Max-Age=0` });
  }
  if (p === "/api/me" && method === "GET") return send(res, 200, { loggedIn: authed(req) });

  if (!authed(req)) return send(res, 401, { error: "Silakan login dulu." });

  // --- Ringkasan ---
  if (p === "/api/overview" && method === "GET") {
    const d = loadData();
    const st = settings(d);
    const peers = await onlinePeers();
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
        tunnelNet: st.tun.net,
        tunnelLocal: st.tun.local,
        tunnelStatic: `${intToIp(st.tun.first)} - ${intToIp(st.tun.last)}`,
        tunnelPool: `${st.tun.poolStart} - ${st.tun.poolEnd}`,
        tunnelMax: st.tun.last - st.tun.first + 1,
        presets: SERVICE_PRESETS,
        autoPortStart: FWD_AUTO_START,
        reservedPorts: Array.from(RESERVED_PORTS),
        port: PORT,
        version: VERSION,
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
          ? { domain: cf.domain, zoneName: cf.zoneName, ip: cf.ip, https: !!cf.https, httpsActive: HTTPS_ON, appliedAt: cf.appliedAt, certExpiry: cf.https ? certExpiry(cf.domain) : null, publicIpBefore: d.settings.publicIpBeforeCf || "" }
          : null,
      },
      sites: d.sites.map((s) => {
        const v = siteView(s, st, peers, h, now);
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
      if (r.error) return send(res, 400, { error: r.error });
      return send(res, 200, r);
    }
    if (p === "/api/telegram/test") {
      const chatId = String(body.chatId || saved.chatId || "").trim();
      if (!chatId) return send(res, 400, { error: "Pilih grup dulu (klik Deteksi grup & topik)." });
      const c = { token, chatId, threadId: parseInt(body.threadId, 10) || 0 };
      const tz = tzName(d);
      const r = await tgSend(c, `✅ <b>Tes notifikasi</b>\nPanel VPN ACS terhubung. Notifikasi VPN terputus akan dikirim ke sini.\n<i>${fmtClock(Date.now(), tz, true)} ${TIMEZONES[tz].label}</i>`, false);
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
    if (CF_JOB && !CF_JOB.done) await cfRollback(CF_JOB);
    CF_JOB = { id: crypto.randomBytes(8).toString("hex"), domain, token, https: body.https !== false, tz: tzName(d), steps: cfSteps(body.https !== false), idx: 0, ctx: {}, created: Date.now(), done: false };
    return send(res, 200, { jobId: CF_JOB.id, steps: CF_JOB.steps });
  }
  if (p === "/api/cloudflare/step" && method === "POST") {
    const job = CF_JOB;
    if (!job || job.id !== body.jobId || job.done) return send(res, 400, { error: "Proses sudah berakhir. Mulai ulang." });
    const step = job.steps[job.idx];
    if (!step || step.key !== body.key) return send(res, 400, { error: "Urutan langkah tidak sesuai." });
    let r;
    try {
      r = await cfRunStep(job, step.key);
    } catch (e) {
      r = { ok: false, detail: "Terjadi kesalahan: " + e.message };
    }
    if (r.ok === false) {
      const notes = await cfRollback(job);
      r.rolledBack = true;
      r.rollbackNote = "Dibatalkan, pengaturan tetap seperti semula" + (notes.length ? ` (${notes.join(", ")})` : "") + ".";
      logActivity(req, "Cloudflare gagal", `${job.domain}: ${step.label} — ${r.detail}`);
    } else {
      job.idx++;
      if (step.key === "apply") {
        job.done = true;
        logActivity(req, "Cloudflare diterapkan", `${job.domain} → ${job.ctx.ip}${job.https ? " + HTTPS" : ""}`);
      }
    }
    return send(res, 200, Object.assign({ key: step.key }, r));
  }
  if (p === "/api/cloudflare/cancel" && method === "POST") {
    if (CF_JOB && CF_JOB.id === body.jobId && !CF_JOB.done) await cfRollback(CF_JOB);
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

  // --- Tambah server ---
  if (p === "/api/sites" && method === "POST") {
    const d = loadData();
    const err = validateSite(d, body, null);
    if (err) return send(res, 400, { error: err });
    const sub = parseCidr(body.realSubnet);
    const tunnelIp = allocTunnelIp(d);
    if (!tunnelIp) {
      const T = tun(d);
      return send(res, 400, { error: `Slot VPN penuh (maksimal ${T.last - T.first + 1} server untuk ${T.net}). Perbesar jaringan VPN di Pengaturan.` });
    }
    const custom = String(body.virtualSubnet || "").trim();
    const virtualSubnet = custom ? parseCidr(custom).text : allocVirtual(d, sub.prefix);
    if (!virtualSubnet) return send(res, 400, { error: "Rentang IP virtual otomatis penuh. Isi IP virtual secara manual." });
    let base = String(body.name).toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "").slice(0, 20) || "server";
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
    };
    d.sites.push(site);
    saveData(d);
    logActivity(req, "Server ditambah", `${site.name} · ONT ${site.realSubnet} → virtual ${site.virtualSubnet}`);
    await applyAll(d);
    const st = settings(d);
    return send(res, 200, { ok: true, site: siteView(site, st, await onlinePeers(), loadHistory()) });
  }

  // --- Port forwarding ---
  const mf = p.match(/^\/api\/sites\/([a-f0-9]{12})\/forwards(\/([a-f0-9]{8}))?$/);
  if (mf) {
    const d = loadData();
    const site = d.sites.find((s) => s.id === mf[1]);
    if (!site) return send(res, 404, { error: "Server tidak ditemukan." });
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

  // --- Ubah / hapus / tes / riwayat server ---
  const m = p.match(/^\/api\/sites\/([a-f0-9]{12})(\/(test|test-plan|test-step|reset-password|history))?$/);
  if (m) {
    const d = loadData();
    const site = d.sites.find((s) => s.id === m[1]);
    if (!site) return send(res, 404, { error: "Server tidak ditemukan." });
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
      saveData(d);
      logActivity(req, "Server diubah", `${site.name}${changes.length ? ": " + changes.join(", ") : " (tanpa perubahan)"}`);
      await applyAll(d, removed);
      return send(res, 200, { ok: true });
    }
    if (!action && method === "DELETE") {
      d.sites = d.sites.filter((s) => s.id !== site.id);
      saveData(d);
      logActivity(req, "Server dihapus", `${site.name} · ${site.virtualSubnet}`);
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
      const peers = await onlinePeers();
      const result = { online: !!peers[site.tunnelIp], iface: peers[site.tunnelIp] || "", steps: [] };
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
      for (const o of d.sites) {
        if (overlap(t, parseCidr(o.realSubnet))) return send(res, 400, { error: `Bentrok dengan subnet ONT server "${o.name}" (${o.realSubnet}).` });
        if (overlap(t, parseCidr(o.virtualSubnet))) return send(res, 400, { error: `Bentrok dengan IP virtual server "${o.name}" (${o.virtualSubnet}).` });
      }
      const nt = tunnelCfg(t.text);
      const slots = nt.last - nt.first + 1;
      if (d.sites.length > slots) return send(res, 400, { error: `Terlalu kecil: hanya ${slots} slot, padahal ada ${d.sites.length} server.` });
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
    // Server dari versi lama dianggap sudah terpasang (bukan "menunggu pemasangan")
    if (!d.v2) {
      for (const s of d.sites || []) if (s.installedAt === undefined) s.installedAt = s.createdAt || new Date().toISOString();
      d.v2 = true;
      saveData(d);
    }
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
      await cfRollback(CF_JOB);
      logActivity(null, "Cloudflare dibatalkan", `${CF_JOB.domain}: proses ditinggal lebih dari 10 menit`);
    }
  }, 60 * 1000);
  setInterval(certReloadCheck, 3600 * 1000);
  const front = net.createServer(frontHandler);
  front.listen(PORT, HOST, () => console.log(`Panel VPN ACS berjalan di port ${PORT}`));
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
    --code-bg:#0f172a;--code-fg:#e2e8f0;
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
    --side:#0b1530;
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
  .copy{border:0;background:none;color:var(--muted);padding:2px;border-radius:5px;display:inline-grid;place-items:center}
  .copy:hover{color:var(--primary);background:var(--primary-soft)}
  .copy svg{width:15px;height:15px}

  /* Detail */
  .dh{display:flex;align-items:flex-start;justify-content:space-between;gap:16px;flex-wrap:wrap;margin-bottom:18px}
  .dh h1{font-size:22px;font-weight:650;letter-spacing:-.02em;display:flex;align-items:center;gap:12px;flex-wrap:wrap}
  .dh p{color:var(--muted);margin-top:3px}
  .tabs{display:flex;gap:4px;border-bottom:1px solid var(--line);margin-bottom:20px;overflow-x:auto}
  .tab{border:0;background:none;padding:10px 14px;font-size:13.5px;font-weight:500;color:var(--muted);border-bottom:2px solid transparent;margin-bottom:-1px;white-space:nowrap}
  .tab:hover{color:var(--text)}
  .tab.on{color:var(--primary);border-bottom-color:var(--primary)}
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
  .modal.sm{max-width:440px}.modal.lg{max-width:680px}
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

  [data-act=refresh].spinning svg{animation:spin .8s linear infinite}
  .toast{position:fixed;left:50%;bottom:24px;transform:translateX(-50%);background:var(--text);color:var(--surface);padding:10px 16px;border-radius:8px;font-size:13.5px;font-weight:500;z-index:90;box-shadow:var(--shadow-lg);animation:pop .18s}

  @media (max-width:1024px){
    .side{transform:translateX(-100%)}
    body.nav-open .side{transform:none}
    .wrap{margin-left:0}
    #navBtn{display:inline-flex}
    .top{padding:0 14px}
    .main{padding:20px 16px}
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
    <div class="brand"><span class="brand-mark" data-ic="shield"></span><span><b>VPN ACS</b><small>Control Panel</small></span></div>
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
    <div class="brand"><span class="brand-mark" data-ic="shield"></span><span><b>VPN ACS</b><small>Control Panel</small></span></div>
    <button class="nav" data-go="#/"><span data-ic="home"></span>Dashboard</button>
    <button class="nav" data-go="#/server"><span data-ic="router"></span>Server<span class="cnt" id="navCount">0</span></button>
    <div class="nav-sec">Lainnya</div>
    <button class="nav" data-go="#/log"><span data-ic="list"></span>Log aktivitas</button>
    <button class="nav" data-go="#/panduan"><span data-ic="book"></span>Panduan</button>
    <button class="nav" data-go="#/pengaturan"><span data-ic="gear"></span>Pengaturan</button>
    <div class="grow"></div>
    <div class="side-foot"><span>VPN ACS Panel</span><span id="ver"></span></div>
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
  if (!r.ok) throw new Error(data.error || "Terjadi kesalahan (" + r.status + ")");
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
function confirmDialog({ title, text, ok = "Lanjutkan", danger = false, icon, onOk }) {
  const kind = danger ? "bad" : "info";
  $("#modalRoot").innerHTML = `<div class="mbg" id="mbg"><div class="modal dlg sm" role="alertdialog" aria-modal="true">
    <div class="dlg-b"><span class="dlg-ic ${kind}">${ic(icon || (danger ? "trash" : "info"))}</span>
      <div style="flex:1;min-width:0"><h2>${title}</h2><div class="dlg-t">${text}</div><div class="err" id="dlgErr"></div></div></div>
    <div class="mf"><button class="btn" data-act="closemodal">Batal</button><button class="btn ${danger ? "dangerf" : "pri"}" id="dlgOk">${ok}</button></div></div></div>`;
  $("#mbg").addEventListener("mousedown", (e) => { if (e.target.id === "mbg") closeModal(); });
  const btn = $("#dlgOk"); btn.focus();
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
function showLogin() { $("#appView").classList.add("hidden"); $("#loginView").classList.remove("hidden"); document.title = "Masuk · VPN ACS"; $("#lp").focus(); }
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
  $("#navCount").textContent = STATE.sites.length;
  $("#ver").textContent = STATE.settings.version ? "v" + STATE.settings.version : "";
}

/* ================= Router ================= */
let TEST = null; // tes koneksi yang sedang tampil
function route() {
  if (!LOADED) return;
  let h = location.hash || "#/";
  if (/^#\/lokasi/.test(h)) { h = h.replace("#/lokasi", "#/server"); history.replaceState(null, "", h); }
  const parts = h.replace(/^#\/?/, "").split("/").filter(Boolean);
  document.querySelectorAll(".nav[data-go]").forEach((n) => {
    const g = n.dataset.go.replace(/^#\/?/, "");
    n.classList.toggle("on", (g === "" && parts.length === 0) || (g && parts[0] === g));
  });
  document.body.classList.remove("nav-open");
  document.querySelectorAll(".menu-list").forEach((m) => m.classList.add("hidden"));
  closeModal();
  const v = $("#view");
  let title = "Dashboard";
  if (parts[0] === "server" && (parts[1] === "terputus" || parts[1] === "menunggu")) { LIST.f = parts[1] === "terputus" ? "off" : "wait"; LIST.q = ""; history.replaceState(null, "", "#/server"); viewList(v); title = "Server"; }
  else if (parts[0] === "server" && parts[1]) {
    let tab = parts[2] || "ringkasan";
    const wantTest = tab === "tes";
    if (wantTest) { tab = "ringkasan"; history.replaceState(null, "", `#/server/${parts[1]}`); }
    viewDetail(v, parts[1], tab);
    const x = site(parts[1]); title = x ? x.name : "Server";
    if (wantTest && x) setTimeout(() => openTest(x.id), 50);
  }
  else if (parts[0] === "server") { viewList(v); title = "Server"; }
  else if (parts[0] === "panduan") { viewGuide(v); title = "Panduan"; }
  else if (parts[0] === "pengaturan") { viewSettings(v, parts[1] || "umum"); title = "Pengaturan"; }
  else if (parts[0] === "log") { viewLog(v); title = "Log aktivitas"; }
  else { viewDashboard(v); }
  document.title = `${title} · VPN ACS`;
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
  if (!s.publicIp) list.push({ t: "Alamat VPS belum diisi", d: "Script MikroTik membutuhkan alamat VPS.", go: "#/pengaturan" });
  if (s.genieCidr !== null && !genieOk(s.genieCidr)) list.push({ t: "Patch IP virtual GenieACS belum aktif", d: "Summon ke ONT akan gagal.", go: "#/pengaturan" });
  const off = STATE.sites.filter((x) => x.state === "down");
  if (off.length === 1) list.push({ t: `${off[0].name} terputus`, d: off[0].downSince ? `Sejak ${fmtT(off[0].downSince, true)} (${fmtDur(Date.now() - off[0].downSince)}). Klik untuk tes koneksi.` : "Klik untuk tes koneksi.", go: `#/server/${off[0].id}/tes` });
  else if (off.length > 1) {
    const names = off.map((x) => x.name);
    list.push({ t: `${off.length} server terputus`, d: names.slice(0, 4).join(", ") + (names.length > 4 ? ` dan ${names.length - 4} lainnya` : ""), go: "#/server/terputus" });
  }
  const tg = s.telegram || {};
  if (tg.active && tg.lastError) list.push({ t: "Notifikasi Telegram gagal terkirim", d: tg.lastError, go: "#/pengaturan/telegram" });
  const cf = s.cloudflare;
  if (cf && cf.https && cf.certExpiry && cf.certExpiry - Date.now() < 14 * 864e5) list.push({ t: "Sertifikat HTTPS hampir habis", d: `Berlaku sampai ${fmtT(cf.certExpiry, true)}. Perpanjangan otomatis mungkin gagal.`, go: "#/pengaturan/domain" });
  for (const x of STATE.sites) {
    if (x.inGenie === false) list.push({ t: `${x.name}: IP virtual di luar patch GenieACS`, d: `${x.virtualSubnet} tidak dikenali GenieACS, Summon akan gagal.`, go: `#/server/${x.id}` });
  }
  const pend = STATE.sites.filter((x) => x.state === "pending");
  if (pend.length === 1) list.push({ k: "info", t: `${pend[0].name} menunggu pemasangan`, d: "Script MikroTik belum dipasang atau belum pernah tersambung.", go: `#/server/${pend[0].id}/script` });
  else if (pend.length > 1) list.push({ k: "info", t: `${pend.length} server menunggu pemasangan`, d: pend.map((x) => x.name).slice(0, 4).join(", ") + (pend.length > 4 ? ` dan ${pend.length - 4} lainnya` : ""), go: "#/server/menunggu" });
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
    <div class="ph"><div><h1>Dashboard</h1><p>Ringkasan koneksi VPN dan uptime setiap server.</p></div>
      <div class="acts"><button class="btn pri" data-act="add">${ic("plus")}Tambah server</button></div></div>
    <div class="kpis">
      <div class="kpi"><span>Total server</span><b>${S.length}</b><small>${pend ? `${pend} menunggu pemasangan` : "MikroTik terdaftar"}</small></div>
      <div class="kpi"><span><i class="dot ok"></i>Tersambung</span><b>${on}</b><small>${inst.length ? Math.round((on / inst.length) * 100) : 0}% dari server terpasang</small></div>
      <div class="kpi"><span><i class="dot bad"></i>Terputus</span><b>${off}</b><small>${off ? "perlu dicek" : "tidak ada"}</small></div>
      <div class="kpi"><span>Rata-rata uptime</span><b class="${pctCls(avg)}" style="${avg != null && avg < 99 ? `color:var(--${avg >= 95 ? "warn" : "bad"})` : ""}">${pct(avg)}</b><small>7 hari terakhir</small></div>
    </div>
    <div class="grid-dash">
      <div class="card">
        <div class="ch"><h2>Uptime server</h2><span class="muted" style="font-size:12.5px">Klik baris untuk riwayat lengkap</span></div>
        ${S.length ? uptimeTable(S) : `<div class="empty"><h3>Belum ada server</h3><p>Tambahkan MikroTik pertama untuk mulai.</p><button class="btn pri" style="margin-top:12px" data-act="add">${ic("plus")}Tambah server</button></div>`}
      </div>
      <div class="stack">
        <div class="card">
          <div class="ch"><h2>Perlu perhatian</h2>${iss.length ? `<span class="muted">${iss.length}</span>` : ""}</div>
          ${iss.length ? `<ul class="rows">${iss.slice(0, 6).map((x) => `<li><a class="row ${x.k || "warn"}" href="${x.go}"><span class="ic">${ic(x.k === "info" ? "clock" : "alert")}</span><span class="grow"><span class="nm">${esc(x.t)}</span><span class="sb" style="display:block">${esc(x.d)}</span></span><span class="chev">${ic("chev")}</span></a></li>`).join("")}</ul>`
            : `<div class="empty"><div class="big">${ic("check")}</div><h3>Semua normal</h3><p>Semua server tersambung dan pengaturan lengkap.</p></div>`}
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
  return `<table class="t"><thead><tr><th>Server</th><th class="hide-md">30 hari terakhir</th><th class="r">24 jam</th><th class="r">7 hari</th><th class="r hide-sm">30 hari</th></tr></thead><tbody>
    ${rows.map((x) => {
      const [c] = stOf(x);
      const sub = x.state === "down" ? `Terputus${x.downSince ? " · " + fmtDur(Date.now() - x.downSince) : ""}` : x.state === "pending" ? "Menunggu pemasangan" : x.incidents30 ? `${x.incidents30}× putus (30 hari)` : "Stabil";
      const name = `<td><div class="srv"><span class="dot ${c}"></span><span style="min-width:0"><b>${esc(x.name)}</b><small${x.state === "down" ? ' style="color:var(--warn)"' : ""}>${esc(sub)}</small></span></div></td>`;
      if (!x.uptime) return `<tr class="click" data-go="#/server/${x.id}/script">${name}<td class="hide-md"><div class="mini">${"<i class=nodata></i>".repeat(30)}</div></td><td class="r muted">—</td><td class="r muted">—</td><td class="r muted hide-sm">—</td></tr>`;
      const U = x.uptime;
      return `<tr class="click" data-go="#/server/${x.id}/riwayat">${name}
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
  return [["Alamat", s.publicIp || "—"], ["URL ACS ONT", s.acsUrl || "—"], ["Jaringan VPN", s.tunnelNet || "—"], ["Patch GenieACS", g], ["Notifikasi Telegram", tgs], ["HTTPS panel", https]]
    .map(([k, val]) => `<div class="kv"><span>${k}</span><b>${esc(val)}</b></div>`).join("");
}
function rowHtml(x) {
  const [c, t] = stOf(x);
  return `<li><a class="row" href="#/server/${x.id}">
    <span class="dot ${c}"></span>
    <span class="grow"><span class="nm">${esc(x.name)}</span>${x.note ? `<span class="sb" style="display:block">${esc(x.note)}</span>` : ""}</span>
    <span class="meta">${esc(x.virtualSubnet)}</span>
    <span class="up ${pctCls(x.uptime7)}" title="${x.uptime7 == null ? "" : "Uptime 7 hari"}">${x.uptime7 == null ? "" : pct(x.uptime7)}</span>
    <span class="pill ${c}">${t}</span>
    <span class="chev">${ic("chev")}</span></a></li>`;
}

/* ================= Daftar server ================= */
let LIST = { q: "", f: "all" };
function viewList(v) {
  crumb([["Server"]]);
  v.innerHTML = `
    <div class="ph"><div><h1>Server</h1><p>Setiap server adalah satu MikroTik yang tersambung ke VPS lewat VPN.</p></div>
      <div class="acts"><button class="btn pri" data-act="add">${ic("plus")}Tambah server</button></div></div>
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
  if (!STATE.sites.length) el.innerHTML = `<li><div class="empty"><h3>Belum ada server</h3><p>Tambahkan MikroTik pertama untuk mulai.</p></div></li>`;
  else if (!rows.length) el.innerHTML = `<li><div class="empty"><p>Tidak ada server yang cocok.</p></div></li>`;
  else el.innerHTML = rows.map(rowHtml).join("");
}

/* ================= Detail server ================= */
const TABS = [["ringkasan", "Ringkasan"], ["riwayat", "Riwayat"], ["remote", "Remote"], ["script", "Script MikroTik"]];
function viewDetail(v, id, tab) {
  const x = site(id);
  if (!x) { crumb([["Server", "#/server"], ["Tidak ditemukan"]]); v.innerHTML = `<div class="card"><div class="empty"><h3>Server tidak ditemukan</h3><p><a href="#/server">Kembali ke daftar server</a></p></div></div>`; return; }
  if (!TABS.some(([k]) => k === tab)) tab = "ringkasan";
  crumb([["Server", "#/server"], [x.name]]);
  v.innerHTML = `
    <div class="dh">
      <div><h1>${esc(x.name)} <span class="pill ${stOf(x)[0]}">${stOf(x)[1]}</span></h1>
        <p>${x.note ? esc(x.note) + " · " : ""}IP virtual ${esc(x.virtualSubnet)}</p></div>
      <div class="acts" style="display:flex;gap:8px">
        <button class="btn" data-act="test" data-id="${x.id}">${ic("play")}Tes koneksi</button>
        <div class="menu"><button class="btn icon" data-act="menu" aria-label="Lainnya">${ic("dots")}</button>
          <div class="menu-list hidden" id="menuList">
            <button data-act="edit" data-id="${x.id}">${ic("edit")}Ubah server</button>
            <button data-act="resetpw" data-id="${x.id}">${ic("key")}Buat password VPN baru</button>
            <hr><button class="d" data-act="del" data-id="${x.id}">${ic("trash")}Hapus server</button>
          </div></div>
      </div>
    </div>
    <nav class="tabs">${TABS.map(([k, t]) => `<a class="tab ${k === tab ? "on" : ""}" href="#/server/${x.id}/${k}">${t}${k === "remote" && x.forwards.length ? ` <span class="muted">${x.forwards.length}</span>` : ""}</a>`).join("")}</nav>
    <div id="tabBody"></div>`;
  const b = $("#tabBody");
  if (tab === "remote") tabRemote(b, x);
  else if (tab === "script") tabScript(b, x);
  else if (tab === "riwayat") tabHistory(b, x);
  else tabSummary(b, x);
}
function tabSummary(b, x) {
  b.innerHTML = `
    ${x.inGenie === false ? `<div class="note warn">${ic("alert")}<div><b>IP virtual di luar rentang patch GenieACS</b>Summon ke ONT di server ini akan gagal. Jalankan ulang <code>genieacs-virtualip.sh</code> dengan rentang yang mencakup ${esc(x.virtualSubnet)}.</div></div>` : ""}
    ${x.state === "pending" ? `<div class="note info">${ic("clock")}<div><b>Menunggu pemasangan</b>Server ini belum pernah tersambung. Pasang script lewat tab <a href="#/server/${x.id}/script">Script MikroTik</a>. Riwayat dan notifikasi Telegram mulai berjalan setelah MikroTik tersambung pertama kali.</div></div>` : ""}
    ${x.state === "down" ? `<div class="note warn">${ic("alert")}<div><b>Terputus${x.downSince ? ` sejak ${esc(fmtT(x.downSince, true))} (${fmtDur(Date.now() - x.downSince)})` : ""}</b>Jalankan <a href="#" data-act="test" data-id="${x.id}">tes koneksi</a> untuk melihat penyebabnya.</div></div>` : ""}
    <div class="card">
      <div class="ch"><h2>Jaringan</h2></div>
      <dl class="dl" style="margin:0">
        <div><dt>Subnet ONT (asli)</dt><dd>${esc(x.realSubnet)}</dd></div>
        <div><dt>IP virtual di GenieACS</dt><dd>${esc(x.virtualSubnet)}</dd></div>
        <div><dt>URL ACS untuk ONT</dt><dd>${esc(x.acsUrl)} ${copyBtn(x.acsUrl, "URL ACS tersalin")}</dd></div>
        <div><dt>IP VPN MikroTik</dt><dd>${esc(x.tunnelIp)}</dd></div>
      </dl>
    </div>
    <div class="card">
      <div class="ch"><h2>Akun VPN</h2></div>
      <dl class="dl" style="margin:0">
        <div><dt>Alamat VPS (connect-to)</dt><dd>${esc(STATE.settings.publicIp || "—")}</dd></div>
        <div><dt>Username</dt><dd>${esc(x.username)} ${copyBtn(x.username)}</dd></div>
        <div><dt>Password</dt><dd><span id="pwv">••••••••••••</span><button class="copy" data-act="showpw" title="Lihat">${ic("eye", "")}</button>${copyBtn(x.password, "Password tersalin")}</dd></div>
        <div><dt>IPsec</dt><dd>${STATE.settings.useIpsec ? "Aktif" : "Tidak dipakai"}</dd></div>
      </dl>
    </div>`;
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
      <div class="ch"><h2>Akses remote</h2><button class="btn sm pri" data-act="addfwd">${ic("plus")}Tambah</button></div>
      ${x.forwards.length ? `<table class="t"><thead><tr><th>Layanan</th><th>Alamat</th><th class="hide-sm">Tujuan</th><th></th></tr></thead><tbody>
        ${x.forwards.map((f) => {
          const url = fwdLink(f);
          const addr = url
            ? `<a class="ext" href="${esc(url)}" target="_blank" rel="noopener" title="Buka di tab baru">${esc(f.remote)}${ic("ext", "")}</a> ${copyBtn(url, "Alamat tersalin")}`
            : `<span class="mono">${esc(f.remote)}</span> ${copyBtn(f.remote, "Alamat tersalin")}${f.service === "winbox" ? `<div class="muted" style="font-size:12px">Buka lewat aplikasi Winbox</div>` : ""}`;
          return `<tr><td><b style="font-weight:550">${esc(f.label)}</b></td><td>${addr}</td>
          <td class="hide-sm muted mono">${f.target === "router" ? "MikroTik" : esc(f.lanIp)}:${f.targetPort}</td>
          <td class="r"><button class="btn sm ghost" data-act="delfwd" data-fid="${f.id}" title="Hapus">${ic("trash")}</button></td></tr>`;
        }).join("")}
      </tbody></table>`
      : `<div class="empty"><h3>Belum ada akses remote</h3><p>Tambahkan Winbox atau web untuk me-remote server ini lewat ${esc(STATE.settings.publicIp || "VPS")}.</p></div>`}
    </div>
    <p class="help" style="margin-top:12px">Alamat layanan web bisa diklik untuk langsung membuka halamannya. Untuk Winbox, isi <b>Connect To</b> dengan alamat lengkap dengan port. Port ini terbuka ke internet, jadi pastikan password perangkat kuat.</p>`;
}
function fwdForm(x) {
  const P = STATE.settings.presets || {};
  modal("Tambah akses remote", `
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
      doneDialog("Akses remote ditambahkan", f ? `Alamat: <b class="mono">${esc(f.remote)}</b>` : "", "ok", false);
    } catch (e) { $("#wErr").textContent = e.message; busyBtn($("#wSave"), false); }
  };
}
function tabScript(b, x) {
  b.innerHTML = `
    ${x.state !== "pending" ? "" : `<ol class="howto">
      <li><b><i>1</i>Salin script</b>Klik tombol Salin di kotak script.</li>
      <li><b><i>2</i>Tempel di MikroTik</b>Winbox → New Terminal → klik kanan → Paste → Enter.</li>
      <li><b><i>3</i>Tes koneksi</b>Klik <a href="#" data-act="test" data-id="${x.id}">Tes koneksi</a> untuk memastikan semuanya jalan.</li></ol>`}
    <div class="card"><div class="ch"><h2>Script pemasangan</h2><span class="muted" style="font-size:12.5px">Aman dijalankan ulang</span></div>
      <div class="cb"><div class="codebox"><pre class="code">${esc(x.script)}</pre><button class="btn sm" data-copy="${esc(x.script)}" data-msg="Script tersalin. Tempel di Winbox → New Terminal">${ic("copy")}Salin</button></div>
      <details class="more"><summary>Script untuk menghapus dari MikroTik</summary><div class="codebox"><pre class="code">${esc(x.removeScript)}</pre><button class="btn sm" data-copy="${esc(x.removeScript)}" data-msg="Script hapus tersalin">${ic("copy")}Salin</button></div></details></div></div>`;
}

/* ---------- Riwayat koneksi ---------- */
function tabHistory(b, x) {
  b.innerHTML = `<div class="card"><div class="empty"><p>Memuat riwayat…</p></div></div>`;
  api(`/api/sites/${x.id}/history`).then((h) => {
    if (!$("#tabBody") || !location.hash.includes(x.id + "/riwayat")) return;
    if (h.pending) {
      b.innerHTML = `<div class="card"><div class="empty"><div class="big" style="background:var(--subtle);color:var(--muted)">${ic("clock")}</div><h3>Belum ada riwayat</h3><p>Riwayat mulai dicatat setelah MikroTik tersambung pertama kali.<br><a href="#/server/${x.id}/script">Pasang script MikroTik</a></p></div></div>`;
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
          </tbody></table>` : `<div class="empty"><div class="big">${ic("check")}</div><h3>Tidak ada kejadian putus</h3><p>VPN server ini stabil sejak tercatat.</p></div>`}
      </div>
      <p class="help" style="margin-top:12px">Dicatat sejak ${esc(fmtT(h.installedAt ? Date.parse(h.installedAt) : 0, true))} · diperiksa tiap 30 detik · waktu dalam ${esc(h.tz)}${open ? "" : ""}.</p>`;
    const bars = $("#bars");
    if (bars) bars.addEventListener("mouseover", (e) => { const i = e.target.dataset && e.target.dataset.i; if (i != null) $("#barTip").textContent = tip(days[+i]); });
  }).catch((e) => { b.innerHTML = `<div class="card"><div class="empty"><p>${esc(e.message)}</p></div></div>`; });
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
      : `<div class="tst-sum ok">${ic("check")}Semua beres. GenieACS dapat menjangkau ONT di server ini.</div>`;
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

/* ================= Tambah / ubah / hapus server ================= */
function siteForm(x) {
  return `
    <label for="fName">Nama server</label>
    <input id="fName" type="text" maxlength="40" placeholder="contoh: Nangahale" value="${esc(x?.name || "")}">
    <label for="fSub">Subnet ONT di MikroTik</label>
    <input id="fSub" type="text" placeholder="10.0.0.0/24" value="${esc(x?.realSubnet || "10.0.0.0/24")}">
    <div class="help">Winbox → IP → DHCP Server → Networks. Boleh sama dengan server lain.</div>
    <label for="fVirt">IP virtual <span class="muted" style="font-weight:400">(opsional)</span></label>
    <input id="fVirt" type="text" placeholder="Otomatis" value="${esc(x?.virtualSubnet || "")}">
    <div class="help">Kosongkan agar dipilih otomatis. Tidak boleh sama dengan server lain.</div>
    <label for="fNote">Catatan <span class="muted" style="font-weight:400">(opsional)</span></label>
    <input id="fNote" type="text" maxlength="120" placeholder="contoh: OLT C-Data 8 port" value="${esc(x?.note || "")}">
    <div class="err" id="fErr"></div>`;
}
const readForm = () => ({ name: $("#fName").value, realSubnet: $("#fSub").value, virtualSubnet: $("#fVirt").value, note: $("#fNote").value });
function openAdd() {
  modal("Tambah server", siteForm(null), `<button class="btn" data-act="closemodal">Batal</button><button class="btn pri" id="fSave">Simpan</button>`);
  $("#fSave").onclick = async () => {
    busyBtn($("#fSave"), true); $("#fErr").textContent = "";
    try {
      const r = await api("/api/sites", { method: "POST", body: readForm() });
      await load(); location.hash = `#/server/${r.site.id}/script`;
      setTimeout(() => doneDialog("Server ditambahkan", `<p><b>${esc(r.site.name)}</b> siap dipasang.</p><p>Langkah berikutnya: salin script di bawah, lalu tempel di Winbox → New Terminal.</p>`, "ok", false), 60);
    } catch (e) { $("#fErr").textContent = e.message; busyBtn($("#fSave"), false); }
  };
}
function openEdit(id) {
  const x = site(id);
  modal("Ubah server", siteForm(x), `<button class="btn" data-act="closemodal">Batal</button><button class="btn pri" id="fSave">Simpan</button>`);
  $("#fSave").onclick = async () => {
    busyBtn($("#fSave"), true); $("#fErr").textContent = "";
    const f = readForm();
    try {
      await api("/api/sites/" + id, { method: "PUT", body: f });
      const net = f.realSubnet.trim() !== x.realSubnet || (f.virtualSubnet.trim() && f.virtualSubnet.trim() !== x.virtualSubnet);
      await load(); route();
      doneDialog("Perubahan disimpan", net ? "Subnet berubah. Pasang ulang script terbaru di MikroTik server ini." : "", "ok", !net);
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
      location.hash = `#/server/${id}/script`;
      setTimeout(() => doneDialog("Password VPN diganti", "Salin script terbaru dan pasang ulang di MikroTik.", "ok", false), 60);
    },
  });
}
function openDelete(id) {
  const x = site(id);
  confirmDialog({
    title: `Hapus ${esc(x.name)}?`, danger: true, ok: "Hapus server",
    text: `<p>Akun VPN dan akses remote server ini dihapus. GenieACS tidak bisa lagi Summon ONT di server ini.</p>
      <details class="more"><summary>Script untuk membersihkan MikroTik</summary><div class="codebox"><pre class="code" style="max-height:160px">${esc(x.removeScript)}</pre><button class="btn sm" data-copy="${esc(x.removeScript)}" data-msg="Script hapus tersalin">${ic("copy")}Salin</button></div></details>`,
    onOk: async () => {
      await api("/api/sites/" + id, { method: "DELETE" }); await load();
      location.hash = "#/server";
      setTimeout(() => doneDialog("Server dihapus", `${esc(x.name)} sudah dihapus dari panel.`), 60);
    },
  });
}
function openDelFwd(id, fid) {
  const x = site(id), f = x && x.forwards.find((y) => y.id === fid);
  confirmDialog({
    title: "Hapus akses remote?", danger: true, ok: "Hapus",
    text: `<p>${f ? `<b>${esc(f.label)}</b> · <span class="mono">${esc(f.remote)}</span><br>` : ""}Alamat ini tidak bisa dipakai lagi.</p>`,
    onOk: async () => { await api(`/api/sites/${id}/forwards/${fid}`, { method: "DELETE" }); await load(); route(); doneDialog("Akses remote dihapus", ""); },
  });
}

/* ================= Panduan ================= */
function viewGuide(v) {
  crumb([["Panduan"]]);
  const s = STATE.settings;
  const rm = `/interface l2tp-client remove [find where name="l2tp-acs"]\n/ip route remove [find where comment="VPN ACS"]\n/ip firewall nat remove [find where comment~"^VPN ACS"]\n/ip firewall filter remove [find where comment~"^VPN ACS"]\n:put "Pengaturan VPN ACS sudah dihapus."`;
  v.innerHTML = `
    <div class="ph"><div><h1>Panduan</h1><p>Cara kerja dan langkah pemakaian, dengan bahasa sederhana.</p></div></div>
    <div class="card guide"><div class="ch"><h2>Cara kerja</h2></div><div class="cb">
      <div class="flow"><span>ONT</span><i>→</i><span>OLT</span><i>→</i><span>MikroTik</span><i>⇄ VPN L2TP ⇄</i><span>VPS · GenieACS</span></div>
      <p>Tanpa VPN, GenieACS hanya bisa membaca ONT, tetapi tidak bisa memberi perintah (Summon), karena ONT berada di jaringan lokal.</p>
      <p>Setiap MikroTik membuat VPN ke VPS. Karena subnet ONT di semua server boleh sama, tiap server mendapat <b>IP virtual</b> berbeda; MikroTik menerjemahkannya kembali ke IP asli (NETMAP).</p>
    </div></div>
    <div class="card"><div class="ch"><h2>Menambah server</h2></div><div class="cb"><ol class="ol">
      <li><b>Tambah server di panel</b>Isi nama dan subnet ONT (Winbox → IP → DHCP Server → Networks).</li>
      <li><b>Pasang script di MikroTik</b>Tab Script MikroTik → Salin → Winbox → New Terminal → Paste.</li>
      <li><b>Jalankan tes koneksi</b>Klik tombol Tes koneksi di halaman server. Popup tes memeriksa VPN, jaringan ONT, GenieACS, dan akses remote satu per satu.</li>
      <li><b>Atur ONT</b>URL ACS di ONT atau profil TR-069 OLT: <code>${esc(s.acsUrl || "")}</code></li>
    </ol></div></div>
    <div class="card"><div class="ch"><h2>Remote MikroTik dari mana saja</h2></div><div class="cb"><ol class="ol">
      <li><b>Tambah akses remote</b>Buka server → tab Remote → Tambah → pilih Winbox atau WebFig.</li>
      <li><b>Hubungkan Winbox</b>Isi Connect To dengan alamat yang diberikan, misalnya <code>${esc(s.publicIp || "IP_VPS")}:20001</code>.</li>
    </ol><p class="help">Jika di MikroTik IP → Services kolom Available From diisi, tambahkan <code>${esc(s.tunnelLocal || "")}</code>.</p></div></div>
    <div class="card"><div class="ch"><h2>Membersihkan pengaturan</h2></div><div class="cb">
      <p style="margin-bottom:10px"><b>Di MikroTik</b> — hanya pengaturan bertanda "VPN ACS" yang dihapus:</p>
      <div class="codebox"><pre class="code">${esc(rm)}</pre><button class="btn sm" data-copy="${esc(rm)}" data-msg="Script hapus tersalin">${ic("copy")}Salin</button></div>
      <p style="margin-top:14px"><b>Di VPS</b> — jalankan <code>bash bersihkan.sh</code> dari folder <code>suwazed-panel</code> untuk menghapus port forwarding, panel dan akun VPN, patch GenieACS, atau mengembalikan parameter.</p>
    </div></div>
    <div class="card faq"><div class="ch"><h2>Pertanyaan umum</h2></div>
      <details><summary>Status tetap "Terputus" setelah script dipasang</summary><p>Jalankan Tes koneksi untuk melihat langkah yang gagal. Biasanya: MikroTik belum punya internet, alamat VPS salah, atau port UDP 1701 di VPS tertutup.</p></details>
      <details><summary>Summon di GenieACS masih gagal</summary><p>Pastikan langkah "Patch GenieACS" di Tes koneksi lolos, dan ONT sudah Inform sekali setelah VPN tersambung.</p></details>
      <details><summary>Remote Winbox tidak bisa masuk</summary><p>Pasang ulang script MikroTik terbaru (berisi aturan "remote dari VPS"), cek IP → Services → winbox aktif, dan pastikan provider VPS tidak memblokir port tersebut.</p></details>
      <details><summary>Bolehkah IP virtual sama dengan ZeroTier?</summary><p>Boleh. Yang tidak boleh: dua server memakai IP virtual yang sama, atau IP virtual sama dengan subnet lokal mana pun.</p></details>
      <details><summary>Apa arti status "Menunggu pemasangan"?</summary><p>Server sudah dibuat di panel tetapi MikroTik-nya belum pernah tersambung. Server ini tidak dihitung terputus dan tidak dikirim notifikasi Telegram. Statusnya berubah sendiri saat MikroTik tersambung pertama kali.</p></details>
      <details><summary>Notifikasi Telegram tidak masuk</summary><p>Buka Pengaturan → Notifikasi Telegram, klik Kirim pesan tes. Jika gagal, pesan kesalahannya menjelaskan penyebabnya (token salah, bot bukan admin, topik terhapus). Ingat: notifikasi baru dikirim setelah VPN putus melewati jeda yang diatur.</p></details>
      <details><summary>Setelah HTTPS aktif, panel tidak bisa dibuka lewat IP</summary><p>Itu normal. Buka lewat <code>https://domain:${esc(String(s.port || 8088))}</code>; alamat http dan IP akan dialihkan otomatis ke sana. Jika domain bermasalah, lepas domain di Pengaturan → Domain &amp; HTTPS.</p></details>
      <details><summary>Aman menjalankan script MikroTik berulang kali?</summary><p>Aman. Script menghapus pengaturan lama bertanda "VPN ACS" terlebih dulu; pengaturan lain tidak disentuh.</p></details>
    </div>`;
}

/* ================= Pengaturan ================= */
const SET_TABS = [["umum", "Umum"], ["telegram", "Notifikasi Telegram"], ["domain", "Domain & HTTPS"]];
function viewSettings(v, tab) {
  if (!SET_TABS.some(([k]) => k === tab)) tab = "umum";
  crumb([["Pengaturan", "#/pengaturan"], [SET_TABS.find(([k]) => k === tab)[1]]]);
  v.innerHTML = `
    <div class="ph"><div><h1>Pengaturan</h1><p>Pengaturan VPS, notifikasi, dan domain panel.</p></div></div>
    <nav class="tabs">${SET_TABS.map(([k, t]) => `<a class="tab ${k === tab ? "on" : ""}" href="#/pengaturan/${k}">${t}</a>`).join("")}</nav>
    <div id="setBody"></div>`;
  const b = $("#setBody");
  if (tab === "telegram") setTelegram(b);
  else if (tab === "domain") setDomain(b);
  else setGeneral(b);
}
function setGeneral(b) {
  const s = STATE.settings;
  const g = s.genieCidr === null ? { c: "info", t: "GenieACS tidak ditemukan di VPS ini", d: "Abaikan jika GenieACS dipasang di server lain." }
    : genieOk(s.genieCidr) ? { c: "ok", t: "Patch IP virtual aktif", d: `GENIEACS_CR_USE_REMOTE_ADDRESS = ${s.genieCidr}` }
    : { c: "warn", t: "Patch IP virtual belum aktif", d: `Nilai sekarang: ${s.genieCidr || "(kosong)"}. Jalankan genieacs-virtualip.sh.` };
  b.innerHTML = `
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
    <div class="card"><div class="ch"><h2>GenieACS</h2></div><div class="cb">
      <div class="note ${g.c}" style="margin:0">${ic(g.c === "ok" ? "check" : g.c === "warn" ? "alert" : "info")}<div><b>${esc(g.t)}</b>${esc(g.d)}</div></div>
    </div></div>
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
    <div class="card"><div class="ch"><h2>Password admin</h2></div><form class="cb" id="pwForm" style="padding-top:4px">
      <div class="f2"><div><label for="pOld">Password lama</label><input id="pOld" type="password" autocomplete="current-password"></div>
        <div><label for="pNew">Password baru</label><input id="pNew" type="password" autocomplete="new-password" placeholder="Minimal 8 karakter"></div></div>
      <div class="err" id="pwErr"></div>
      <div class="form-actions"><button class="btn pri">Ganti password</button></div>
    </form></div>`;
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
  $("#pwForm").onsubmit = async (e) => {
    e.preventDefault(); $("#pwErr").textContent = "";
    const btn = $("#pwForm button"); busyBtn(btn, true);
    try { await api("/api/settings", { method: "PUT", body: { oldPassword: $("#pOld").value, newPassword: $("#pNew").value } }); $("#pOld").value = ""; $("#pNew").value = ""; doneDialog("Password admin diganti", "Gunakan password baru saat login berikutnya."); }
    catch (err) { $("#pwErr").textContent = err.message; }
    busyBtn(btn, false);
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
          <li><b>Kirim pesan di topik tujuan</b>Kirim pesan apa saja (misalnya "tes") di topik tersebut, lalu klik <b>Deteksi grup &amp; topik</b> di bawah.</li>
        </ol></details>
      <label for="tgTok">Token bot</label>
      <input id="tgTok" type="password" autocomplete="off" placeholder="${t.tokenSet ? `Tersimpan (${esc(t.tokenMask)}) — kosongkan jika tidak diganti` : "contoh: 123456789:AAHxxxxxxxxxxxxxxxxxxxxxxxxxxxx"}">
      <div class="form-actions" style="margin-top:10px"><button class="btn" id="tgDetect">${ic("search")}Deteksi grup &amp; topik</button><span class="help" id="tgBot" style="margin:auto 0">${t.botName ? "Bot: @" + esc(t.botName) : ""}</span></div>
      <div class="f2">
        <div><label for="tgChat">Grup</label><select id="tgChat"></select></div>
        <div><label for="tgThread">Topik</label><select id="tgThread"></select></div>
      </div>
      <div class="help">Grup atau topik tidak muncul? Pastikan bot sudah admin, kirim pesan di topik itu, lalu klik Deteksi lagi.</div>
    </div></div>
    <div class="card"><div class="ch"><h2>Aturan notifikasi</h2></div><div class="cb" style="padding-top:6px">
      <label class="check" style="margin-top:10px"><input id="tgOn" type="checkbox" ${t.enabled !== false ? "checked" : ""}>Aktifkan notifikasi VPN terputus</label>
      <div class="help">Server berstatus "Menunggu pemasangan" tidak pernah dikirim notifikasi.</div>
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
    } catch (e) { $("#tgErr").textContent = e.message; }
    busyBtn(btn, false);
  };
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
      </div></div>` : ""}
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
      : `<div class="tst-sum ok">${ic("check")}Alamat VPS sekarang ${esc(CF.domain)}. Script MikroTik baru otomatis memakai domain ini.</div>`;
  } else {
    $("#cfSum").innerHTML = `<div class="tst-sum fail">${ic("alert")}${esc(CF.note || "Dibatalkan, pengaturan tetap seperti semula.")}</div>`;
  }
}
async function runCf(domain, token, withHttps) {
  if (CF && CF.running) return;
  $("#cfErr").textContent = "";
  let r;
  try { r = await api("/api/cloudflare/start", { method: "POST", body: { domain, token, https: withHttps } }); }
  catch (e) { $("#cfErr").textContent = e.message; return; }
  CF = { domain, plan: r.steps, jobId: r.jobId, res: {}, running: true, ok: false };
  $("#cfGo").disabled = true; const again = $("#cfAgain"); if (again) again.disabled = true;
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
  }
  CF.running = false; drawCf();
  const go = $("#cfGo"); if (go) go.disabled = false; const ag = $("#cfAgain"); if (ag) ag.disabled = false;
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
      <div class="toolbar"><div class="search">${ic("search", "")}<input id="lq" type="text" placeholder="Cari aktivitas, server, atau IP" value="${esc(LOGQ)}"></div><span class="muted" id="logCount" style="margin-left:auto;font-size:12.5px"></span></div>
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
  const cur = (location.hash.match(/^#\/server\/([a-f0-9]{12})/) || [])[1];
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
    if (me.loggedIn) { showApp(); await load(); route(); } else showLogin();
  } catch (e) { showLogin(); }
  setInterval(async () => {
    if ($("#appView").classList.contains("hidden") || $("#mbg") || TEST) return;
    const h = location.hash;
    if (CF && CF.running) return;
    try { await load(); if (!/\/(tes|remote)$|^#\/(pengaturan|log)/.test(h) && !document.activeElement.matches("input,select")) route(); } catch (e) {}
  }, 30000);
})();
</script>
</body>
</html>
HTMLEOF
chmod 700 "$APP_DIR"
ok "Aplikasi ditulis ke $APP_DIR"

# ---------- Password admin ----------
if [ ! -f "$APP_DIR/data.json" ] || ! grep -q '"admin"' "$APP_DIR/data.json"; then
  ask_password
else
  ok "Password admin lama dipakai (ganti dengan: bash $0 password)"
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

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now vpn-acs >/dev/null 2>&1
systemctl restart vpn-acs
sleep 2
systemctl is-active --quiet vpn-acs || fail "Panel gagal berjalan. Cek: journalctl -u vpn-acs -n 50"

PUBIP="$(hostname -I | awk '{print $1}')"
HTTPS_DOM="$("$NODE_BIN" -e 'try{const c=require(process.argv[1]).settings.cloudflare;if(c&&c.https)console.log(c.domain)}catch(e){}' "$APP_DIR/data.json" 2>/dev/null)"
echo
ok "Panel VPN ACS berjalan"
if [ -n "$HTTPS_DOM" ]; then
  echo -e "   Buka di browser: ${GREEN}https://${HTTPS_DOM}:${PANEL_PORT}${NC}"
else
  echo -e "   Buka di browser: ${GREEN}http://${PUBIP}:${PANEL_PORT}${NC}"
  echo "   (Jika IP di atas bukan IP publik, pakai IP publik VPS Anda)"
fi
