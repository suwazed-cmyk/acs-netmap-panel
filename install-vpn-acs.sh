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
function run(cmd, args) {
  return new Promise((resolve) => {
    if (DRY_RUN && ((cmd === "ip" && args[0] === "route") || cmd === "iptables")) return resolve({ code: 0, out: "" });
    execFile(cmd, args, { timeout: 15000 }, (err, stdout, stderr) => {
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
function siteView(s, st, peers) {
  const real = parseCidr(s.realSubnet);
  const virt = parseCidr(s.virtualSubnet);
  return {
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
  if (name.length < 2 || name.length > 40) return "Nama lokasi 2-40 karakter.";
  if (d.sites.some((s) => s !== existing && s.name.toLowerCase() === name.toLowerCase()))
    return "Nama lokasi sudah dipakai.";
  const sub = parseCidr(input.realSubnet);
  if (!sub) return "Subnet ONT tidak valid. Contoh yang benar: 10.0.0.0/24";
  if (sub.prefix < 16 || sub.prefix > 29) return "Ukuran subnet ONT harus antara /16 sampai /29.";
  if (!sub.aligned)
    return `Subnet ONT harus ditulis dari alamat awalnya. Mungkin maksud Anda ${sub.text}`;
  const T = tun(d);
  if (overlap(sub, T.cidr)) return `Subnet ONT tidak boleh bentrok dengan jaringan VPN ${T.net}.`;
  const others = d.sites.filter((s) => s !== existing);
  if (others.some((o) => overlap(sub, parseCidr(o.virtualSubnet))))
    return "Subnet ONT bentrok dengan IP virtual lokasi lain.";
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
    if (clash) return `IP virtual ${v.text} sudah dipakai lokasi "${clash.name}" (${clash.virtualSubnet}). Pilih yang lain.`;
    const clashReal = others.find((o) => overlap(v, parseCidr(o.realSubnet)));
    if (clashReal) return `IP virtual ${v.text} bentrok dengan subnet ONT asli lokasi "${clashReal.name}" (${clashReal.realSubnet}).`;
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
      return { error: `IP perangkat harus di dalam subnet ONT lokasi ini (${site.realSubnet}).` };
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
      return { error: `Port publik ${publicPort} sudah dipakai${owner ? ` di lokasi "${owner.name}"` : ""}. Pilih port lain atau kosongkan untuk otomatis.` };
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
  return (req.socket.remoteAddress || "").replace(/^::ffff:/, "");
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

  // --- Login ---
  if (p === "/api/login" && method === "POST") {
    const ip = clientIp(req);
    const f = loginFails.get(ip) || { n: 0, until: 0 };
    if (f.until > Date.now()) {
      const sec = Math.ceil((f.until - Date.now()) / 1000);
      return send(res, 429, { error: `Terlalu banyak percobaan. Coba lagi dalam ${sec} detik.` });
    }
    const body = await readBody(req);
    const d = loadData();
    if (!checkPassword(body.password || "", d.admin)) {
      f.n += 1;
      if (f.n >= 5) {
        f.until = Date.now() + 5 * 60 * 1000;
        f.n = 0;
      }
      loginFails.set(ip, f);
      await new Promise((r) => setTimeout(r, 800));
      return send(res, 401, { error: "Password salah." });
    }
    loginFails.delete(ip);
    const t = newSession();
    return send(res, 200, { ok: true }, {
      "Set-Cookie": `vpnacs=${t}; HttpOnly; SameSite=Strict; Path=/; Max-Age=${SESSION_TTL / 1000}`,
    });
  }
  if (p === "/api/logout" && method === "POST") {
    sessions.delete(getCookie(req, "vpnacs"));
    return send(res, 200, { ok: true }, { "Set-Cookie": "vpnacs=; HttpOnly; SameSite=Strict; Path=/; Max-Age=0" });
  }
  if (p === "/api/me" && method === "GET") return send(res, 200, { loggedIn: authed(req) });

  if (!authed(req)) return send(res, 401, { error: "Silakan login dulu." });

  // --- Ringkasan ---
  if (p === "/api/overview" && method === "GET") {
    const d = loadData();
    const st = settings(d);
    const peers = await onlinePeers();
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
      },
      sites: d.sites.map((s) => siteView(s, st, peers)),
    });
  }

  // --- Tambah lokasi ---
  if (p === "/api/sites" && method === "POST") {
    const body = await readBody(req);
    const d = loadData();
    const err = validateSite(d, body, null);
    if (err) return send(res, 400, { error: err });
    const sub = parseCidr(body.realSubnet);
    const tunnelIp = allocTunnelIp(d);
    if (!tunnelIp) {
      const T = tun(d);
      return send(res, 400, { error: `Slot VPN penuh (maksimal ${T.last - T.first + 1} lokasi untuk ${T.net}). Perbesar jaringan VPN di Pengaturan.` });
    }
    const custom = String(body.virtualSubnet || "").trim();
    const virtualSubnet = custom ? parseCidr(custom).text : allocVirtual(d, sub.prefix);
    if (!virtualSubnet) return send(res, 400, { error: "Rentang IP virtual otomatis penuh. Isi IP virtual secara manual." });
    let base = String(body.name).toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "").slice(0, 20) || "lokasi";
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
    };
    d.sites.push(site);
    saveData(d);
    await applyAll(d);
    const st = settings(d);
    return send(res, 200, { ok: true, site: siteView(site, st, await onlinePeers()) });
  }

  // --- Ubah / hapus / tes lokasi ---
  const mf = p.match(/^\/api\/sites\/([a-f0-9]{12})\/forwards(\/([a-f0-9]{8}))?$/);
  if (mf) {
    const d = loadData();
    const site = d.sites.find((s) => s.id === mf[1]);
    if (!site) return send(res, 404, { error: "Lokasi tidak ditemukan." });
    site.forwards = site.forwards || [];
    if (!mf[3] && method === "POST") {
      const body = await readBody(req);
      const r = validateForward(d, site, body);
      if (r.error) return send(res, 400, { error: r.error });
      site.forwards.push(r.fwd);
      saveData(d);
      await applyAll(d);
      return send(res, 200, { ok: true });
    }
    if (mf[3] && method === "DELETE") {
      const before = site.forwards.length;
      site.forwards = site.forwards.filter((f) => f.id !== mf[3]);
      if (site.forwards.length === before) return send(res, 404, { error: "Port forwarding tidak ditemukan." });
      saveData(d);
      await applyAll(d);
      return send(res, 200, { ok: true });
    }
  }

  const m = p.match(/^\/api\/sites\/([a-f0-9]{12})(\/(test|reset-password))?$/);
  if (m) {
    const d = loadData();
    const site = d.sites.find((s) => s.id === m[1]);
    if (!site) return send(res, 404, { error: "Lokasi tidak ditemukan." });
    const action = m[3];

    if (!action && method === "PUT") {
      const body = await readBody(req);
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
      if (newVirt !== site.virtualSubnet) {
        removed.push(site.virtualSubnet);
        site.virtualSubnet = newVirt;
      }
      site.name = String(body.name).trim();
      site.note = String(body.note || "").trim().slice(0, 120);
      site.realSubnet = sub.text;
      saveData(d);
      await applyAll(d, removed);
      return send(res, 200, { ok: true });
    }
    if (!action && method === "DELETE") {
      d.sites = d.sites.filter((s) => s.id !== site.id);
      saveData(d);
      await applyAll(d, [site.virtualSubnet]);
      return send(res, 200, { ok: true });
    }
    if (action === "reset-password" && method === "POST") {
      site.password = randomPassword(16);
      saveData(d);
      await applyAll(d);
      return send(res, 200, { ok: true });
    }
    if (action === "test" && method === "POST") {
      const peers = await onlinePeers();
      const virt = parseCidr(site.virtualSubnet);
      const gw = intToIp(virt.net + 1);
      const result = { online: !!peers[site.tunnelIp], iface: peers[site.tunnelIp] || "", steps: [] };
      result.steps.push({
        label: "VPN L2TP tersambung",
        ok: result.online,
        detail: result.online ? `Tersambung lewat ${result.iface}` : "MikroTik belum tersambung ke VPS",
      });
      const p1 = await run("ping", ["-c", "2", "-W", "1", site.tunnelIp]);
      result.steps.push(
        p1.code === -2
          ? { label: `Ping MikroTik (${site.tunnelIp})`, ok: null, detail: "Dilewati: perintah ping tidak ada di VPS (apt install iputils-ping)" }
          : { label: `Ping MikroTik (${site.tunnelIp})`, ok: p1.code === 0, detail: p1.code === 0 ? "Membalas" : "Tidak membalas" },
      );
      const r = await run("ip", ["route", "get", gw]);
      const routeOk = result.online && r.out.includes(result.iface);
      result.steps.push({ label: `Route ke ${site.virtualSubnet}`, ok: routeOk, detail: routeOk ? `Lewat ${result.iface}` : "Route belum terpasang" });
      const p2 = await run("ping", ["-c", "2", "-W", "1", gw]);
      result.steps.push({
        label: `Ping gateway ONT (${gw} = ${intToIp(parseCidr(site.realSubnet).net + 1)} asli)`,
        ok: p2.code === -2 ? null : p2.code === 0,
        detail:
          p2.code === -2
            ? "Dilewati: perintah ping tidak ada di VPS"
            : p2.code === 0
              ? "Membalas, NETMAP bekerja"
              : "Tidak membalas (cek NETMAP di MikroTik, atau gateway ONT bukan .1)",
      });
      for (const f of site.forwards || []) {
        if (f.proto === "udp") continue;
        const tip = fwdTarget(site, f);
        const okp = await tcpCheck(tip, f.targetPort);
        result.steps.push({
          label: `Port forward ${f.label} (${f.publicPort} → ${tip}:${f.targetPort})`,
          ok: okp,
          detail: okp ? "Tujuan bisa dijangkau dari VPS" : "Tujuan tidak menjawab (cek layanan aktif di perangkat tujuan / script MikroTik)",
        });
      }
      return send(res, 200, result);
    }
  }

  // --- Pengaturan ---
  if (p === "/api/settings" && method === "PUT") {
    const body = await readBody(req);
    const d = loadData();
    d.settings = d.settings || {};
    if (body.publicIp !== undefined) {
      const v = String(body.publicIp).trim().toLowerCase();
      const isHost = /^(?=.{1,253}$)([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$/.test(v);
      if (v && ipToInt(v) === null && !isHost)
        return send(res, 400, { error: "Alamat VPS tidak valid. Isi IP publik (103.20.30.40) atau domain (vpn.domain.com)." });
      d.settings.publicIp = v;
    }
    if (body.useIpsec !== undefined) d.settings.useIpsec = !!body.useIpsec;
    let tunnelChanged = false;
    if (body.tunnelNet !== undefined && String(body.tunnelNet).trim() !== tun(d).net) {
      const t = parseCidr(body.tunnelNet);
      if (!t) return send(res, 400, { error: "Jaringan VPN tidak valid. Contoh: 172.31.0.0/24" });
      if (!t.aligned) return send(res, 400, { error: `Tulis dari alamat awalnya. Mungkin maksud Anda ${t.text}` });
      if (t.prefix < 16 || t.prefix > 28) return send(res, 400, { error: "Ukuran jaringan VPN harus antara /16 sampai /28." });
      const priv = [parseCidr("10.0.0.0/8"), parseCidr("172.16.0.0/12"), parseCidr("192.168.0.0/16"), parseCidr("100.64.0.0/10")];
      if (!priv.some((p) => t.net >= p.net && t.net + t.size <= p.net + p.size))
        return send(res, 400, { error: "Jaringan VPN harus memakai IP privat (10.x, 172.16-31.x, 192.168.x, atau 100.64-127.x)." });
      if (overlap(t, parseCidr(VIRTUAL_POOL))) return send(res, 400, { error: `Bentrok dengan rentang IP virtual otomatis ${VIRTUAL_POOL}.` });
      for (const o of d.sites) {
        if (overlap(t, parseCidr(o.realSubnet))) return send(res, 400, { error: `Bentrok dengan subnet ONT lokasi "${o.name}" (${o.realSubnet}).` });
        if (overlap(t, parseCidr(o.virtualSubnet))) return send(res, 400, { error: `Bentrok dengan IP virtual lokasi "${o.name}" (${o.virtualSubnet}).` });
      }
      const nt = tunnelCfg(t.text);
      const slots = nt.last - nt.first + 1;
      if (d.sites.length > slots) return send(res, 400, { error: `Terlalu kecil: hanya ${slots} slot, padahal ada ${d.sites.length} lokasi.` });
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
      d.settings.tunnelNet = t.text;
      tunnelChanged = true;
    }
    if (body.newPassword !== undefined) {
      if (!checkPassword(body.oldPassword || "", d.admin)) return send(res, 400, { error: "Password lama salah." });
      if (String(body.newPassword).length < 8) return send(res, 400, { error: "Password baru minimal 8 karakter." });
      d.admin = hashPassword(body.newPassword);
    }
    saveData(d);
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

const server = http.createServer(async (req, res) => {
  try {
    const url = new URL(req.url, "http://localhost");
    if (url.pathname.startsWith("/api/")) return await handleApi(req, res, url);
    if (url.pathname === "/" || url.pathname === "/index.html") {
      res.writeHead(200, {
        "Content-Type": "text/html; charset=utf-8",
        "Cache-Control": "no-store",
        "X-Frame-Options": "DENY",
        "X-Content-Type-Options": "nosniff",
      });
      return res.end(indexHtml());
    }
    send(res, 404, "Tidak ditemukan");
  } catch (e) {
    console.error(e);
    send(res, 500, { error: "Terjadi kesalahan di server: " + e.message });
  }
});

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
    try {
      if (syncXl2tpd(d)) {
        console.log("xl2tpd.conf disesuaikan dengan jaringan VPN panel, restart xl2tpd");
        await restartXl2tpd();
      }
      await applyAll(d);
    } catch (e) {
      console.error("Gagal sinkron awal:", e.message);
    }
  })();
  // Pasang ulang aturan firewall panel jika terhapus (mis. iptables dimuat ulang saat boot)
  setInterval(async () => {
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
  }, 60 * 1000);
  server.listen(PORT, HOST, () => console.log(`Panel VPN ACS berjalan di http://${HOST}:${PORT}`));
}
SERVEREOF

cat > "$APP_DIR/public/index.html" <<'HTMLEOF'
<!DOCTYPE html>
<html lang="id">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Panel VPN ACS</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700&display=swap" rel="stylesheet">
<style>
  :root{
    color-scheme:light;
    --bg:#f0f2f8;--surface:#fff;--surface-2:#f8f9fc;--surface-3:#eef1f7;
    --text:#293240;--text-2:#4a5568;--heading:#1d2433;--muted:#8996a4;--border:#e8ebf2;--border-strong:#d5dbe6;
    --side-1:#0a33af;--side-2:#0b35af;--side-text:rgba(255,255,255,.78);--side-muted:rgba(255,255,255,.55);--side-active:#fff;
    --primary:#4680ff;--primary-2:#2f6bff;--primary-soft:#e8efff;--primary-ring:rgba(70,128,255,.22);
    --ok:#17c666;--ok-dark:#0e9f50;--ok-soft:#e3f8ec;
    --warn:#ffa21d;--warn-dark:#b86e00;--warn-soft:#fff4e2;
    --danger:#ea4d4d;--danger-dark:#c62f2f;--danger-soft:#fdeaea;
    --info:#3ec9d6;--info-dark:#14808b;--info-soft:#e2f7f9;
    --code-bg:#1d2433;--code-fg:#e3e8f2;
    --shadow-card:0 1px 20px 0 rgba(69,90,100,.08);--shadow-sm:0 2px 6px -1px rgba(0,0,0,.10);--shadow-lg:0 20px 50px -12px rgba(16,24,40,.30);
    --radius:6px;--sidebar-w:280px;--topbar-h:70px;
    --font:Inter,ui-sans-serif,system-ui,-apple-system,"Segoe UI",Roboto,Arial,sans-serif;
    --mono:ui-monospace,SFMono-Regular,Consolas,"Liberation Mono",monospace;
  }
  [data-theme="dark"]{
    color-scheme:dark;
    --bg:#111827;--surface:#1a2233;--surface-2:#1f2a3d;--surface-3:#26324a;
    --text:#d4dbe7;--text-2:#b0bccd;--heading:#f1f4f9;--muted:#8391a7;--border:#2a3650;--border-strong:#36445f;
    --side-1:#0d1a44;--side-2:#0a1435;
    --primary:#6b9bff;--primary-2:#4680ff;--primary-soft:#1e2c52;--primary-ring:rgba(107,155,255,.28);
    --ok-soft:#123826;--warn-soft:#3a2b10;--danger-soft:#3d1a1d;--info-soft:#113539;
    --ok-dark:#3ddc84;--warn-dark:#ffbf5c;--danger-dark:#ff7b7b;--info-dark:#5fd8e3;
    --shadow-card:0 1px 20px 0 rgba(0,0,0,.35);
  }
  *,*::before,*::after{box-sizing:border-box}
  body{margin:0;min-height:100vh;background:var(--bg);color:var(--text);font-family:var(--font);font-size:14px;line-height:1.55;-webkit-font-smoothing:antialiased}
  h1,h2,h3,p{margin:0}
  button,input,select{font:inherit}
  button{cursor:pointer}
  a{color:var(--primary)}
  code{font-family:var(--mono);font-size:.9em;background:var(--surface-3);color:var(--heading);padding:1px 6px;border-radius:4px}
  .hidden{display:none!important}
  svg.i{width:18px;height:18px;flex:none}

  /* ---------- Sidebar ---------- */
  .app{min-height:100vh}
  .sidebar{position:fixed;inset:0 auto 0 0;z-index:40;width:var(--sidebar-w);display:flex;flex-direction:column;background:linear-gradient(180deg,var(--side-1) 10%,var(--side-2) 100%);color:var(--side-text);overflow-y:auto;transition:transform .25s ease}
  .brand{display:flex;align-items:center;gap:12px;height:var(--topbar-h);padding:0 26px;color:#fff;text-decoration:none;flex:none}
  .brand-mark{width:38px;height:38px;flex:none;border-radius:10px;display:grid;place-items:center;background:rgba(255,255,255,.14);border:1px solid rgba(255,255,255,.18);color:#fff}
  .brand-mark svg{width:21px;height:21px}
  .brand-name{display:block;font-size:19px;font-weight:700;letter-spacing:-.02em;line-height:1.1;color:#fff}
  .brand-sub{display:block;font-size:10.5px;font-weight:600;letter-spacing:.12em;text-transform:uppercase;color:var(--side-muted)}
  .nav-label{padding:22px 30px 8px;font-size:11.5px;font-weight:600;letter-spacing:.06em;text-transform:uppercase;color:#fff;opacity:.9}
  .nav-item{display:flex;align-items:center;gap:14px;width:calc(100% - 20px);margin:1px 10px;padding:11px 20px;border:0;border-radius:6px;background:none;color:var(--side-text);font-size:14px;font-weight:500;text-align:left;transition:background .15s,color .15s}
  .nav-item svg{width:19px;height:19px;flex:none;opacity:.9}
  .nav-item:hover{color:#fff;background:rgba(255,255,255,.08)}
  .nav-item.on{color:var(--side-active);font-weight:600;background:rgba(255,255,255,.14)}
  .spacer{flex:1}
  .side-foot{padding:14px 0 18px;border-top:1px solid rgba(255,255,255,.12)}
  .side-foot .ver{padding:8px 30px 0;font-size:11.5px;color:var(--side-muted)}
  .sidebar-backdrop{position:fixed;inset:0;z-index:35;background:rgba(15,23,42,.45);opacity:0;visibility:hidden;transition:opacity .2s,visibility .2s}
  body.nav-open .sidebar-backdrop{opacity:1;visibility:visible}

  /* ---------- Topbar ---------- */
  .main-wrap{margin-left:var(--sidebar-w);min-height:100vh;display:flex;flex-direction:column}
  .topbar{position:sticky;top:0;z-index:30;height:var(--topbar-h);display:flex;align-items:center;gap:12px;padding:0 30px;background:var(--surface);box-shadow:0 1px 20px 0 rgba(69,90,100,.08)}
  .topbar .crumb{font-size:13px;color:var(--muted)}
  .topbar .crumb b{color:var(--heading);font-weight:600}
  .topbar-right{margin-left:auto;display:flex;align-items:center;gap:8px}
  .user{display:flex;align-items:center;gap:10px;padding-left:10px}
  .avatar{width:40px;height:40px;border-radius:50%;display:grid;place-items:center;background:linear-gradient(135deg,var(--primary),#6f42c1);color:#fff;font-weight:700;font-size:15px}
  .user b{display:block;font-size:14px;font-weight:600;color:var(--heading);line-height:1.2}
  .user small{display:block;font-size:12px;color:var(--muted)}
  #navToggle{display:none}

  /* ---------- Konten ---------- */
  .main{flex:1;width:100%;padding:30px}
  .page-head{display:flex;align-items:center;justify-content:space-between;gap:14px;flex-wrap:wrap;margin-bottom:24px}
  .page-head h1{font-size:24px;font-weight:500;color:var(--heading);letter-spacing:-.01em}
  .page-head .sub{margin-top:4px;color:var(--muted);font-size:13px;max-width:720px}
  .page-head-actions{display:flex;gap:8px;flex-wrap:wrap}
  h2{font-size:15px;font-weight:600;color:var(--heading);margin:0 0 12px}
  h3{font-size:14px;font-weight:600;color:var(--heading);margin:18px 0 8px}
  .sub{color:var(--muted)}

  /* ---------- Kartu ---------- */
  .card{background:var(--surface);border:0;border-radius:var(--radius);box-shadow:var(--shadow-card);padding:20px 25px 22px;margin-bottom:24px}
  .card>h2:first-child{margin:-20px -25px 18px;padding:18px 25px;border-bottom:1px solid var(--border);font-size:15px}
  .card-h{display:flex;align-items:center;justify-content:space-between;gap:12px;flex-wrap:wrap;padding:18px 25px;border-bottom:1px solid var(--border)}
  .card-h h2{margin:0}
  .card.flush{padding:0}
  .grid-side{display:grid;grid-template-columns:260px minmax(0,1fr);gap:24px;align-items:start}
  .grid-side>*,.card{min-width:0}

  /* status list */
  .status-list{list-style:none;margin:0;padding:6px 0}
  .status-list li{display:flex;align-items:center;justify-content:space-between;padding:13px 25px;border-bottom:1px solid var(--border)}
  .status-list li:last-child{border-bottom:0}
  .status-list span{color:var(--primary);font-weight:500}
  .count{min-width:26px;height:26px;padding:0 8px;border-radius:50px;display:inline-grid;place-items:center;color:#fff;font-size:12.5px;font-weight:600}
  .count.ok{background:var(--ok)}.count.warn{background:var(--warn)}.count.pri{background:var(--primary)}
  .vps-info{padding:4px 25px 18px;font-size:13px}
  .vps-info div{display:flex;justify-content:space-between;gap:10px;padding:7px 0;border-bottom:1px dashed var(--border)}
  .vps-info div:last-child{border-bottom:0}
  .vps-info span{color:var(--muted)}
  .vps-info b{font-family:var(--mono);font-weight:500;font-size:12.5px;color:var(--heading);text-align:right;word-break:break-all}

  /* ---------- Tabel ---------- */
  .table-tools{display:flex;align-items:center;justify-content:space-between;gap:12px;flex-wrap:wrap;padding:16px 25px 0}
  .table-tools .search{display:flex;align-items:center;gap:8px}
  .table-tools .search input{width:220px}
  .table-wrap{padding:16px 25px 22px;overflow-x:auto}
  table.list{width:100%;border-collapse:collapse;font-size:14px}
  table.list th{background:var(--bg);color:var(--heading);font-size:12.5px;font-weight:600;text-transform:uppercase;letter-spacing:.02em;text-align:left;padding:14px 12px;white-space:nowrap;border-bottom:1px solid var(--border)}
  table.list th.sort{cursor:pointer;user-select:none}
  table.list th.sort::after{content:" ⇅";color:var(--muted);font-weight:400}
  table.list th.asc::after{content:" ↑";color:var(--primary)}
  table.list th.desc::after{content:" ↓";color:var(--primary)}
  table.list td{padding:14px 12px;border-bottom:1px solid var(--border);vertical-align:middle}
  table.list tbody tr:nth-child(odd){background:var(--surface-2)}
  table.list tbody tr:hover{background:var(--primary-soft)}
  .t-name{font-weight:600;color:var(--heading)}
  .t-note{display:block;font-size:12px;color:var(--muted)}
  .t-mono{font-family:var(--mono);font-size:13px;white-space:nowrap}
  .t-sub{display:block;font-size:11.5px;color:var(--muted);font-family:var(--font)}
  .t-act{display:flex;gap:6px;justify-content:flex-end;white-space:nowrap}
  .t-empty{text-align:center;color:var(--muted);padding:40px 12px!important}
  .remote-mini{display:flex;flex-direction:column;gap:4px}
  .remote-mini a{display:inline-flex;align-items:center;flex-wrap:wrap;gap:2px 6px;font-size:12.5px;color:var(--text);text-decoration:none;cursor:pointer}
  .remote-mini a b{font-weight:600}
  .remote-mini a code{font-size:12px}
  .remote-mini a:hover code{background:var(--primary-soft);color:var(--primary)}
  .table-foot{display:flex;justify-content:space-between;gap:10px;flex-wrap:wrap;padding:0 25px 20px;color:var(--muted);font-size:13px}

  /* ---------- Badge ---------- */
  .badge{display:inline-flex;align-items:center;gap:5px;padding:3px 8px;border-radius:4px;font-size:11.5px;font-weight:600;line-height:1.3;white-space:nowrap;color:#fff}
  .badge.on{background:var(--ok)}
  .badge.off{background:var(--warn)}
  .badge.soft-warn{background:var(--warn-soft);color:var(--warn-dark)}
  .tag-warn{display:inline-block;margin-top:5px;font-size:11.5px;color:var(--warn-dark);font-weight:600}

  /* ---------- Tombol ---------- */
  .btn{display:inline-flex;align-items:center;justify-content:center;gap:7px;padding:9px 16px;border:1px solid transparent;border-radius:6px;background:var(--surface);color:var(--text);font-size:13.5px;font-weight:500;line-height:1.2;white-space:nowrap;box-shadow:var(--shadow-sm);transition:background .15s,box-shadow .15s,transform .1s,color .15s}
  .btn:hover{box-shadow:0 4px 12px -2px rgba(0,0,0,.14)}
  .btn:active{transform:translateY(1px)}
  .btn.primary,.btn-primary{background:var(--primary);color:#fff}
  .btn.primary:hover{background:var(--primary-2)}
  .btn.danger{background:var(--danger-soft);color:var(--danger-dark);box-shadow:none;border-color:transparent}
  .btn.danger:hover{background:var(--danger);color:#fff}
  .btn-ghost{background:transparent;box-shadow:none;color:var(--text-2)}
  .btn-ghost:hover{background:var(--surface-3);box-shadow:none}
  .btn.sm{padding:6px 11px;font-size:12.5px}
  .btn.big{padding:11px 22px;font-size:14.5px}
  .btn-icon{width:38px;height:38px;padding:0}
  .ib{width:32px;height:32px;padding:0;border-radius:6px;box-shadow:none;border:1px solid var(--border);background:var(--surface)}
  .ib svg{width:16px;height:16px}
  .ib:hover{border-color:var(--primary);color:var(--primary)}
  .ib.del:hover{border-color:var(--danger);color:var(--danger)}
  .btn:disabled{opacity:.55;cursor:default}

  /* ---------- Alert ---------- */
  .alert{border-radius:var(--radius);padding:12px 16px;margin:0 0 18px;display:flex;gap:10px;align-items:flex-start;font-size:13.5px;border-left:4px solid}
  .alert b{display:block}
  .alert.warn{background:var(--warn-soft);border-color:var(--warn);color:var(--warn-dark)}
  .alert.bad{background:var(--danger-soft);border-color:var(--danger);color:var(--danger-dark)}
  .alert.ok{background:var(--ok-soft);border-color:var(--ok);color:var(--ok-dark)}
  .alert.info{background:var(--info-soft);border-color:var(--info);color:var(--info-dark)}
  .alert code{background:rgba(255,255,255,.55)}

  /* ---------- Form ---------- */
  label{display:block;font-weight:500;font-size:13px;color:var(--heading);margin:14px 0 6px}
  .hint{color:var(--muted);font-size:12.5px;margin-top:6px}
  input[type=text],input[type=password],select{width:100%;padding:9px 13px;border:1px solid var(--border-strong);border-radius:6px;background:var(--surface);color:var(--text);font-size:14px;outline:none;transition:border-color .15s,box-shadow .15s}
  input[type=text]:focus,input[type=password]:focus,select:focus{border-color:var(--primary);box-shadow:0 0 0 3px var(--primary-ring)}
  input::placeholder{color:var(--muted)}
  input[readonly]{background:var(--surface-2)}
  input[type=checkbox],input[type=radio]{accent-color:var(--primary)}
  .row{display:flex;gap:8px}.row input{flex:1}
  .error{color:var(--danger-dark);font-weight:500;font-size:13px;margin-top:10px}
  .grid2{display:grid;grid-template-columns:1fr 1fr;gap:0 16px}
  .radio{display:flex;gap:18px;flex-wrap:wrap;margin-top:4px}
  .radio label{display:flex;align-items:center;gap:7px;font-weight:400;margin:0;cursor:pointer}
  .addbox{background:var(--surface-2);border:1px solid var(--border);border-radius:var(--radius);padding:4px 18px 18px;margin-top:18px}

  /* ---------- Modal ---------- */
  .modal-bg{position:fixed;inset:0;background:rgba(15,23,42,.5);display:flex;align-items:flex-start;justify-content:center;padding:44px 14px;overflow:auto;z-index:60}
  .modal{background:var(--surface);border-radius:8px;max-width:740px;width:100%;box-shadow:var(--shadow-lg)}
  .modal-h{display:flex;align-items:center;padding:18px 24px;border-bottom:1px solid var(--border)}
  .modal-h h2{margin:0;font-size:16px}
  .modal-h .x{margin-left:auto;background:none;border:0;font-size:24px;color:var(--muted);line-height:1;width:32px;height:32px;border-radius:6px}
  .modal-h .x:hover{background:var(--surface-3)}
  .modal-b{padding:20px 24px}
  .modal-f{padding:14px 24px;border-top:1px solid var(--border);display:flex;justify-content:flex-end;gap:10px}

  /* ---------- Isi lain ---------- */
  .steps{counter-reset:s;list-style:none;padding:0;margin:0}
  .steps>li{counter-increment:s;position:relative;padding:0 0 18px 46px}
  .steps>li::before{content:counter(s);position:absolute;left:0;top:-2px;width:30px;height:30px;border-radius:50%;background:var(--primary);color:#fff;font-weight:600;display:grid;place-items:center}
  .steps>li .st{display:block;font-weight:600;color:var(--heading);margin-bottom:3px}
  pre.code{background:var(--code-bg);color:var(--code-fg);font-family:var(--mono);font-size:12.5px;padding:14px 16px;border-radius:6px;overflow:auto;max-height:300px;white-space:pre;margin:8px 0}
  .copy-row{display:flex;gap:8px;align-items:center;flex-wrap:wrap}
  .copied{color:var(--ok-dark);font-weight:600;font-size:13px}
  table.info,table.fw{width:100%;border-collapse:collapse;font-size:13.5px;margin-top:6px}
  table.info td,table.fw td{padding:10px 12px;border-bottom:1px solid var(--border);vertical-align:middle}
  table.info tr:nth-child(odd) td{background:var(--surface-2)}
  table.info td:first-child{color:var(--muted);width:44%}
  table.info td:last-child{font-family:var(--mono)}
  table.fw th{padding:11px 12px;background:var(--bg);color:var(--heading);font-size:12px;font-weight:600;text-transform:uppercase;text-align:left;white-space:nowrap}
  table.fw td.m{font-family:var(--mono);font-size:13px}
  .check{list-style:none;padding:0;margin:0}
  .check li{display:flex;gap:12px;padding:11px 0;border-bottom:1px solid var(--border)}
  .check li:last-child{border-bottom:0}
  .check .ic{width:26px;height:26px;border-radius:50%;display:grid;place-items:center;font-weight:800;flex:none;color:#fff}
  .check .ic.ok{background:var(--ok)}.check .ic.no{background:var(--danger)}.check .ic.skip{background:var(--muted)}
  .check small{display:block;color:var(--muted)}
  .faq details{background:var(--surface);border-radius:var(--radius);box-shadow:var(--shadow-card);padding:14px 20px;margin-bottom:10px}
  .faq summary{font-weight:600;color:var(--heading);cursor:pointer}
  .faq p{margin:10px 0 2px;color:var(--text-2)}
  .diagram{display:flex;align-items:center;gap:8px;flex-wrap:wrap;margin:6px 0 14px}
  .node{background:var(--primary-soft);color:var(--primary);padding:7px 12px;border-radius:6px;font-weight:600;font-size:13px}
  .arrow{color:var(--muted);font-weight:700}
  .card p+p{margin-top:8px}
  .empty-box{text-align:center;padding:44px 20px}
  .empty-box p{color:var(--muted);max-width:440px;margin:8px auto 18px}

  /* ---------- Halaman login ---------- */
  .login{min-height:100vh;display:grid;grid-template-columns:1fr 1fr}
  .login-hero{position:relative;overflow:hidden;color:#fff;padding:40px 50px;display:flex;flex-direction:column;background:linear-gradient(160deg,#0a33af,#0b2a8f 60%,#08206e)}
  .login-hero::after{content:"";position:absolute;width:520px;height:520px;right:-160px;bottom:-160px;border-radius:50%;background:rgba(255,255,255,.06)}
  .login-hero::before{content:"";position:absolute;width:300px;height:300px;right:120px;top:-120px;border-radius:50%;background:rgba(255,255,255,.05)}
  .login-hero .brand{padding:0;height:auto}
  .login-hero .hero-body{margin:auto 0;max-width:440px;position:relative;z-index:1}
  .login-hero .kicker{font-size:12px;font-weight:600;letter-spacing:.1em;text-transform:uppercase;color:rgba(255,255,255,.65);margin-bottom:14px}
  .login-hero h1{font-size:40px;font-weight:700;letter-spacing:-.03em;line-height:1.12}
  .login-hero p{margin-top:14px;color:rgba(255,255,255,.75);font-size:15px}
  .login-hero .foot{font-size:12.5px;color:rgba(255,255,255,.55);position:relative;z-index:1}
  .login-side{display:grid;place-items:center;padding:32px 24px;background:var(--bg)}
  .login-box{width:100%;max-width:400px}
  .login-box .top{display:flex;align-items:center;justify-content:space-between;margin-bottom:26px;color:var(--muted);font-size:13px}
  .login-box h1{font-size:24px;font-weight:600;color:var(--heading)}
  .login-box .sub{margin:6px 0 20px;font-size:13.5px}
  .login-card{background:var(--surface);border-radius:8px;box-shadow:var(--shadow-card);padding:24px}
  .login-card label{margin-top:0}
  .login-card .btn{width:100%;margin-top:16px;padding:11px}
  .login-box .note{text-align:center;color:var(--muted);font-size:12px;margin-top:20px}

  .toast{position:fixed;bottom:24px;right:24px;background:var(--heading);color:var(--surface);padding:12px 18px;border-radius:6px;font-weight:500;z-index:80;box-shadow:var(--shadow-lg)}

  /* ---------- Responsif ---------- */
  @media (max-width:1680px){ .grid-side{grid-template-columns:1fr;gap:0} .side-col{display:grid;grid-template-columns:1fr 1fr;gap:24px;margin-bottom:24px} .side-col .card{margin-bottom:0} }
  @media (max-width:991px){
    .sidebar{transform:translateX(-100%)}
    body.nav-open .sidebar{transform:none;box-shadow:var(--shadow-lg)}
    .main-wrap{margin-left:0}
    #navToggle{display:inline-flex}
    .topbar{padding:0 16px}
    .main{padding:20px 16px}
    .login{grid-template-columns:1fr}.login-hero{display:none}
  }
  @media (max-width:760px){
    .side-col{grid-template-columns:1fr}
    .user div{display:none}
    .topbar .crumb{display:none}
    .table-tools .search input{width:100%}
    .table-tools .search{flex:1}
    table.list thead{display:none}
    table.list,table.list tbody,table.list tr,table.list td{display:block;width:100%}
    table.list tr{border:1px solid var(--border);border-radius:6px;margin-bottom:12px;background:var(--surface)!important}
    table.list td{display:flex;justify-content:space-between;gap:12px;border-bottom:1px dashed var(--border);padding:10px 14px;text-align:right}
    table.list td:last-child{border-bottom:0}
    table.list td::before{content:attr(data-label);font-size:11.5px;font-weight:600;text-transform:uppercase;color:var(--muted);text-align:left;flex:none}
    table.list td.t-empty::before{content:none}
    .t-act{justify-content:flex-end;flex-wrap:wrap}
    .remote-mini{align-items:flex-end}
    .grid2{grid-template-columns:1fr}
    table.fw .hide-sm{display:none}
    .page-head h1{font-size:21px}
  }
</style>
</head>
<body>

<!-- ============ LOGIN ============ -->
<div id="loginView" class="login hidden">
  <div class="login-hero">
    <div class="brand"><span class="brand-mark"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M12 3l8 3v6c0 4.5-3.4 8.3-8 9-4.6-.7-8-4.5-8-9V6l8-3z"/><path d="M9 12l2 2 4-4"/></svg></span><span><span class="brand-name">VPN ACS</span><span class="brand-sub">Control Panel</span></span></div>
    <div class="hero-body">
      <div class="kicker">GenieACS · MikroTik</div>
      <h1>Kendali ONT.<br>Dari mana saja.</h1>
      <p>VPN L2TP, IP virtual, dan remote MikroTik untuk GenieACS dalam satu panel.</p>
    </div>
    <div class="foot">L2TP · NETMAP · TR-069</div>
  </div>
  <div class="login-side">
    <div class="login-box">
      <div class="top"><span>Akses terbatas</span><button type="button" class="btn btn-ghost btn-icon theme-toggle" aria-label="Ganti tema"><svg class="i" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M21 12.8A9 9 0 1 1 11.2 3a7 7 0 0 0 9.8 9.8z"/></svg></button></div>
      <h1>Masuk ke panel</h1>
      <p class="sub">Masukkan password admin panel.</p>
      <form id="loginForm" class="login-card">
        <label for="lp">Password panel</label>
        <input id="lp" type="password" autocomplete="current-password" placeholder="Masukkan password" autofocus>
        <div class="error" id="loginErr"></div>
        <button class="btn primary"><svg class="i" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="4" y="11" width="16" height="10" rx="2"/><path d="M8 11V7a4 4 0 0 1 8 0v4"/></svg> Masuk</button>
      </form>
      <p class="note">Administrator access only</p>
    </div>
  </div>
</div>

<!-- ============ APLIKASI ============ -->
<div id="appView" class="app hidden">
  <aside class="sidebar">
    <div class="brand"><span class="brand-mark"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M12 3l8 3v6c0 4.5-3.4 8.3-8 9-4.6-.7-8-4.5-8-9V6l8-3z"/><path d="M9 12l2 2 4-4"/></svg></span><span><span class="brand-name">VPN ACS</span><span class="brand-sub">Control Panel</span></span></div>
    <div class="nav-label">Navigasi</div>
    <button class="nav-item on" data-tab="sites" data-title="Lokasi MikroTik" type="button"><svg class="i" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="13" width="18" height="7" rx="2"/><path d="M7 16.5h.01M11 16.5h.01M8 9a6 6 0 0 1 8 0M5.5 6.5a10 10 0 0 1 13 0"/></svg> Lokasi MikroTik</button>
    <button class="nav-item" data-tab="guide" data-title="Panduan" type="button"><svg class="i" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M4 5a2 2 0 0 1 2-2h13v16H6a2 2 0 0 0-2 2V5z"/><path d="M4 19a2 2 0 0 1 2-2h13"/></svg> Panduan</button>
    <button class="nav-item" data-tab="settings" data-title="Pengaturan" type="button"><svg class="i" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="3"/><path d="M12 2v3M12 19v3M4.2 4.2l2.1 2.1M17.7 17.7l2.1 2.1M2 12h3M19 12h3M4.2 19.8l2.1-2.1M17.7 6.3l2.1-2.1"/></svg> Pengaturan</button>
    <div class="nav-label">Akun</div>
    <button class="nav-item theme-toggle" type="button"><svg class="i" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M21 12.8A9 9 0 1 1 11.2 3a7 7 0 0 0 9.8 9.8z"/></svg> Mode gelap / terang</button>
    <button class="nav-item" id="logoutBtn" type="button"><svg class="i" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M9 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h4M16 17l5-5-5-5M21 12H9"/></svg> Keluar</button>
    <div class="spacer"></div>
    <div class="side-foot"><div class="ver">Panel VPN ACS · suwazed-panel</div></div>
  </aside>
  <div class="sidebar-backdrop" id="navBackdrop"></div>
  <div class="main-wrap">
    <header class="topbar">
      <button class="btn btn-ghost btn-icon" id="navToggle" type="button" aria-label="Menu"><svg class="i" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M4 6h16M4 12h16M4 18h16"/></svg></button>
      <div class="crumb">Panel VPN ACS / <b id="crumbTitle">Lokasi MikroTik</b></div>
      <div class="topbar-right">
        <button class="btn btn-ghost btn-icon theme-toggle" type="button" aria-label="Ganti tema" title="Mode gelap / terang"><svg class="i" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M21 12.8A9 9 0 1 1 11.2 3a7 7 0 0 0 9.8 9.8z"/></svg></button>
        <div class="user"><span class="avatar">A</span><div><b>Admin</b><small>Administrator</small></div></div>
      </div>
    </header>

  <main class="main">
    <div id="alerts"></div>

    <!-- Tab Lokasi -->
    <section id="tab-sites">
      <div class="page-head">
        <div>
          <h1>Lokasi MikroTik</h1>
          <p class="sub">Setiap lokasi = satu MikroTik yang tersambung ke VPS lewat VPN, supaya GenieACS bisa mengirim perintah (Summon) ke ONT di lokasi itu.</p>
        </div>
        <div class="page-head-actions">
          <button class="btn" id="refreshBtn">↻ Muat ulang status</button>
          <button class="btn primary" id="addBtn">＋ Tambah Lokasi</button>
        </div>
      </div>
      <div class="grid-side">
        <div class="side-col">
          <div class="card flush">
            <div class="card-h"><h2>Status Lokasi</h2></div>
            <ul class="status-list">
              <li><span>Tersambung</span><b class="count ok" id="stOn">0</b></li>
              <li><span>Terputus</span><b class="count warn" id="stOff">0</b></li>
              <li><span>Total lokasi</span><b class="count pri" id="stTotal">0</b></li>
            </ul>
          </div>
          <div class="card flush">
            <div class="card-h"><h2>Info VPS</h2></div>
            <div class="vps-info" id="vpsInfo"></div>
          </div>
        </div>
        <div class="card flush">
          <div class="card-h"><h2>Daftar Lokasi MikroTik</h2></div>
          <div class="table-tools">
            <div class="search"><label for="siteSearch" style="margin:0">Cari:</label><input id="siteSearch" type="text" placeholder="nama, subnet, IP, user..."></div>
          </div>
          <div class="table-wrap">
            <table class="list">
              <thead><tr>
                <th class="sort" data-sort="name">Nama Lokasi</th>
                <th>Subnet ONT → IP Virtual</th>
                <th class="sort" data-sort="tunnelIp">IP VPN</th>
                <th>Remote</th>
                <th class="sort" data-sort="online">Status</th>
                <th style="text-align:right">Aksi</th>
              </tr></thead>
              <tbody id="siteList"></tbody>
            </table>
          </div>
          <div class="table-foot"><span id="siteCount"></span><span>Klik alamat remote untuk menyalin</span></div>
        </div>
      </div>
    </section>

    <!-- Tab Panduan -->
    <section id="tab-guide" class="hidden">
      <div class="page-head"><div>
        <h1>Panduan</h1>
        <p class="sub">Penjelasan singkat dengan bahasa sederhana.</p>
      </div></div>

      <div class="card">
        <h2>Cara kerjanya</h2>
        <div class="diagram">
          <span class="node">ONT pelanggan</span><span class="arrow">→</span>
          <span class="node">OLT</span><span class="arrow">→</span>
          <span class="node">MikroTik lokasi</span><span class="arrow">⇄ VPN L2TP ⇄</span>
          <span class="node">VPS (GenieACS)</span>
        </div>
        <p>Tanpa VPN, GenieACS hanya bisa <b>membaca</b> ONT, tapi tidak bisa <b>memberi perintah</b> (Summon gagal), karena ONT berada di jaringan lokal yang tidak bisa dijangkau dari internet.</p>
        <p>Dengan VPN, setiap MikroTik membuat "terowongan" ke VPS. Karena subnet ONT di semua lokasi boleh sama (misalnya semua <code>10.0.0.0/24</code>), panel ini memberi setiap lokasi <b>IP virtual</b> yang berbeda. GenieACS melihat ONT memakai IP virtual itu, dan MikroTik menerjemahkannya kembali ke IP asli.</p>
      </div>

      <div class="card">
        <h2>Langkah menambah lokasi baru</h2>
        <ol class="steps">
          <li><span class="st">Cari subnet ONT di MikroTik lokasi</span>Buka Winbox → <i>IP → DHCP Server → Networks</i>. Lihat kolom <i>Address</i> pada jaringan yang dipakai ONT untuk TR-069, misalnya <code>10.0.0.0/24</code>.</li>
          <li><span class="st">Tambah lokasi di panel ini</span>Klik <i>＋ Tambah Lokasi</i>, isi nama lokasi dan subnet ONT tadi, lalu simpan.</li>
          <li><span class="st">Salin script ke MikroTik</span>Klik <i>Salin Script</i>, buka Winbox → <i>New Terminal</i>, klik kanan → <i>Paste</i>, lalu tekan Enter.</li>
          <li><span class="st">Tunggu status hijau</span>Kembali ke panel, klik <i>Muat ulang status</i>. Jika tertulis <i>Tersambung</i>, klik <i>Tes Koneksi</i> untuk memastikan semua beres.</li>
          <li><span class="st">Atur ONT</span>Di ONT (atau profil TR-069 di OLT), isi URL ACS: <code id="guideAcs">http://192.168.42.1:7547</code>. Setelah ONT muncul di GenieACS, coba Summon.</li>
        </ol>
      </div>

      <div class="card">
        <h2>Remote MikroTik dari mana saja</h2>
        <ol class="steps">
          <li><span class="st">Tambah port forwarding</span>Pada kartu lokasi, klik <i>🌐 Remote / Port Forward</i> → pilih <b>Winbox</b> → <i>＋ Tambah</i>. Panel memberi alamat seperti <code>vpn.domain.com:20001</code>.</li>
          <li><span class="st">Buka Winbox</span>Isi <i>Connect To</i> dengan alamat tadi (lengkap dengan port), lalu user dan password MikroTik seperti biasa.</li>
          <li><span class="st">Perangkat lain juga bisa</span>Pilih tujuan <i>Perangkat di jaringan ONT</i> untuk membuka web ONT atau OLT, cukup isi IP aslinya.</li>
        </ol>
        <p class="hint">Port ini terbuka ke internet, jadi pastikan password MikroTik kuat. Jika di MikroTik menu <i>IP → Services</i> kolom <i>Available From</i> diisi, tambahkan <code class="tunLocal">192.168.42.1</code>.</p>
      </div>

      <div class="card">
        <h2>Membersihkan pengaturan</h2>
        <p><b>Di MikroTik:</b> salin script ini ke Winbox → New Terminal. Yang dihapus hanya pengaturan bertanda "VPN ACS" (VPN, route, NETMAP, firewall); pengaturan lain tidak disentuh.</p>
        <pre class="code" id="rmScript"># Hapus semua pengaturan VPN ACS dari MikroTik
/interface l2tp-client remove [find where name="l2tp-acs"]
/ip route remove [find where comment="VPN ACS"]
/ip firewall nat remove [find where comment~"^VPN ACS"]
/ip firewall filter remove [find where comment~"^VPN ACS"]
:put "Pengaturan VPN ACS sudah dihapus."</pre>
        <div class="copy-row"><button class="btn sm" id="rmCopy">Salin script hapus</button><span class="copied hidden" id="rmCopyOk">✓ Tersalin</span></div>
        <p style="margin-top:14px"><b>Di VPS:</b> jalankan <code>bash bersihkan.sh</code> dari folder <code>suwazed-panel</code>. Ada pilihan menghapus aturan port forwarding saja, menghapus panel beserta akun VPN, mengembalikan GenieACS asli, atau mengembalikan parameter lama.</p>
      </div>

      <h2>Pertanyaan umum</h2>
      <div class="faq">
        <details><summary>Status tetap "Terputus" setelah script dipasang</summary>
          <p>Di MikroTik jalankan <code>/interface l2tp-client print</code>. Jika tidak ada huruf <b>R</b> (running): pastikan MikroTik punya internet, alamat VPS di menu Pengaturan benar, dan port UDP 1701 di VPS terbuka (ditambah UDP 500 dan 4500 jika memakai IPsec). Jika baru saja mereset password, salin ulang script terbaru.</p></details>
        <details><summary>Tes "Ping gateway ONT" gagal padahal VPN tersambung</summary>
          <p>Tes ini mencoba gateway ONT (alamat .1 di subnet ONT). Jika gateway lokasi Anda bukan .1, hasil merah ini bisa diabaikan. Jika gateway memang .1, pastikan script sudah dipasang lengkap (bagian NETMAP).</p></details>
        <details><summary>Summon di GenieACS masih gagal</summary>
          <p>Pastikan patch IP virtual GenieACS sudah dipasang dan nilai <code>GENIEACS_CR_USE_REMOTE_ADDRESS</code> mencakup <code>10.100.0.0/14</code> (lihat menu Pengaturan). ONT harus mengirim Inform sekali dulu setelah VPN tersambung.</p></details>
        <details><summary>Apakah aman menjalankan script MikroTik berulang kali?</summary>
          <p>Aman. Script selalu menghapus pengaturan lama bertanda "VPN ACS" dulu, lalu memasang yang baru. Pengaturan lain di MikroTik tidak disentuh.</p></details>
        <details><summary>Remote Winbox lewat VPS tidak bisa masuk</summary>
          <p>Pastikan status lokasi <i>Tersambung</i> dan klik <i>Tes Koneksi</i>. Jika baris port forward merah: salin ulang script MikroTik (aturan "remote dari VPS" harus ada), dan cek <i>IP → Services → winbox</i> aktif dan <i>Available From</i> kosong atau berisi <code class="tunLocal">192.168.42.1</code>. Pastikan juga penyedia VPS tidak memblokir port tersebut.</p></details>
        <details><summary>Apakah IP virtual boleh sama dengan ZeroTier?</summary>
          <p>Boleh, malah disarankan agar satu lokasi cukup punya satu IP virtual. Yang tidak boleh: dua lokasi memakai IP virtual yang sama, atau IP virtual sama dengan subnet lokal mana pun. Panel akan menolak otomatis.</p></details>
        <details><summary>Bagaimana menghapus VPN dari MikroTik?</summary>
          <p>Buka <i>Script MikroTik</i> pada lokasi tersebut, lalu salin bagian <i>Script hapus</i>.</p></details>
      </div>
    </section>

    <!-- Tab Pengaturan -->
    <section id="tab-settings" class="hidden">
      <div class="page-head"><div>
        <h1>Pengaturan</h1>
        <p class="sub">Data VPS yang dipakai untuk membuat script MikroTik.</p>
      </div></div>

      <div class="card">
        <h2>VPS</h2>
        <form id="vpsForm">
          <label for="sIp">Alamat VPS (IP publik atau domain)</label>
          <input id="sIp" type="text" placeholder="contoh: 103.20.30.40 atau vpn.domainanda.com">
          <div class="hint">Alamat yang dihubungi MikroTik (isian <i>connect-to</i>). Biasanya terisi otomatis; ubah jika salah.</div>
          <label style="display:flex;align-items:center;gap:10px;cursor:pointer"><input id="sIpsec" type="checkbox" style="width:18px;height:18px"> Pakai IPsec (enkripsi)</label>
          <div class="hint">Matikan untuk L2TP biasa yang lebih simpel (seperti tunnel pada umumnya). Nyalakan jika ingin trafik VPN terenkripsi. Setelah diubah, salin ulang script ke semua MikroTik.</div>
          <div id="pskBox">
            <label>Kunci IPsec (PSK)</label>
            <div class="row"><input id="sPsk" type="password" readonly><button type="button" class="btn" id="pskToggle">Lihat</button></div>
            <div class="hint">Dibaca otomatis dari VPS (<code>/etc/ipsec.secrets</code>).</div>
          </div>
          <label>URL ACS untuk ONT</label>
          <input id="sAcs" type="text" readonly>
          <div class="error" id="vpsErr"></div>
          <button class="btn primary" style="margin-top:12px">Simpan</button>
        </form>
      </div>

      <div class="card">
        <h2>Jaringan VPN (L2TP)</h2>
        <table class="info" style="margin-bottom:6px">
          <tr><td>Jaringan VPN sekarang</td><td id="tNow">-</td></tr>
          <tr><td>IP VPS di VPN (dipakai URL ACS)</td><td id="tLocal">-</td></tr>
          <tr><td>IP tetap untuk MikroTik</td><td id="tStatic">-</td></tr>
          <tr><td>Pool dinamis (akun manual)</td><td id="tPool">-</td></tr>
        </table>
        <form id="tunForm">
          <label for="tNet">Ganti jaringan VPN</label>
          <input id="tNet" type="text" placeholder="contoh: 172.31.0.0/24">
          <div class="hint">Ukuran /16 sampai /28, harus IP privat, dan tidak boleh bentrok dengan subnet ONT atau IP virtual lokasi mana pun. Alamat pertama (.1) otomatis menjadi IP VPS.</div>
          <div class="alert warn" style="margin-top:12px"><div><b>Sebaiknya ditentukan sekali di awal.</b>Jika diganti: semua VPN terputus sebentar, script MikroTik di <strong>semua lokasi</strong> harus disalin ulang, dan <strong>URL ACS di semua ONT berubah</strong> (ONT lama tidak bisa terhubung ke GenieACS sampai URL-nya diganti).</div></div>
          <div class="error" id="tErr"></div>
          <button class="btn danger" style="margin-top:4px">Ganti jaringan VPN</button>
        </form>
      </div>

      <div class="card">
        <h2>Patch IP virtual GenieACS</h2>
        <div id="genieStatus"></div>
      </div>

      <div class="card">
        <h2>Ganti password admin</h2>
        <form id="pwForm">
          <label for="pOld">Password lama</label>
          <input id="pOld" type="password" autocomplete="current-password">
          <label for="pNew">Password baru (minimal 8 karakter)</label>
          <input id="pNew" type="password" autocomplete="new-password">
          <div class="error" id="pwErr"></div>
          <button class="btn primary" style="margin-top:12px">Ganti password</button>
        </form>
      </div>
    </section>
  </main>
  </div>
</div>

<div id="modalRoot"></div>

<script>
"use strict";
const $ = (s, el = document) => el.querySelector(s);
const esc = (v) => String(v ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
let STATE = { settings: {}, sites: [] };

async function api(path, opts = {}) {
  const o = { method: opts.method || "GET", headers: {}, credentials: "same-origin" };
  if (opts.body !== undefined) { o.headers["Content-Type"] = "application/json"; o.body = JSON.stringify(opts.body); }
  else if (o.method !== "GET") { o.headers["Content-Type"] = "application/json"; o.body = "{}"; }
  const r = await fetch(path, o);
  let data = {};
  try { data = await r.json(); } catch (e) {}
  if (r.status === 401 && path !== "/api/login") { showLogin(); throw new Error(data.error || "Sesi habis"); }
  if (!r.ok) throw new Error(data.error || "Terjadi kesalahan (" + r.status + ")");
  return data;
}

function toast(msg) {
  const t = document.createElement("div");
  t.className = "toast"; t.textContent = msg;
  document.body.appendChild(t);
  setTimeout(() => t.remove(), 2600);
}

function copyText(text) {
  if (navigator.clipboard && window.isSecureContext) return navigator.clipboard.writeText(text);
  const ta = document.createElement("textarea");
  ta.value = text; ta.style.position = "fixed"; ta.style.opacity = "0";
  document.body.appendChild(ta); ta.select();
  try { document.execCommand("copy"); } finally { ta.remove(); }
  return Promise.resolve();
}

/* ---------- Tema & menu HP ---------- */
function applyTheme(t) { document.documentElement.setAttribute("data-theme", t); }
(function () {
  let t = null;
  try { t = localStorage.getItem("vpnacs-theme"); } catch (e) {}
  if (!t) t = window.matchMedia && window.matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light";
  applyTheme(t);
})();
document.querySelectorAll(".theme-toggle").forEach((b) => b.addEventListener("click", () => {
  const t = document.documentElement.getAttribute("data-theme") === "dark" ? "light" : "dark";
  applyTheme(t);
  try { localStorage.setItem("vpnacs-theme", t); } catch (e) {}
}));
$("#navToggle").addEventListener("click", () => document.body.classList.toggle("nav-open"));
$("#navBackdrop").addEventListener("click", () => document.body.classList.remove("nav-open"));

/* ---------- Login ---------- */
function showLogin() { $("#appView").classList.add("hidden"); $("#loginView").classList.remove("hidden"); $("#lp").focus(); }
function showApp() { $("#loginView").classList.add("hidden"); $("#appView").classList.remove("hidden"); }

$("#loginForm").addEventListener("submit", async (e) => {
  e.preventDefault();
  $("#loginErr").textContent = "";
  try {
    await api("/api/login", { method: "POST", body: { password: $("#lp").value } });
    $("#lp").value = "";
    showApp(); load();
  } catch (err) { $("#loginErr").textContent = err.message; }
});
$("#logoutBtn").addEventListener("click", async () => { await api("/api/logout", { method: "POST" }).catch(() => {}); showLogin(); });

/* ---------- Tab ---------- */
document.querySelectorAll(".nav-item[data-tab]").forEach((b) => b.addEventListener("click", () => {
  document.body.classList.remove("nav-open");
  $("#crumbTitle").textContent = b.dataset.title || "";
  document.querySelectorAll(".nav-item[data-tab]").forEach((x) => x.classList.toggle("on", x === b));
  ["sites", "guide", "settings"].forEach((t) => $("#tab-" + t).classList.toggle("hidden", t !== b.dataset.tab));
}));

/* ---------- Muat data ---------- */
async function load() {
  try { STATE = await api("/api/overview"); } catch (e) { return; }
  renderAlerts(); renderSites(); renderSettings();
}

function renderAlerts() {
  const s = STATE.settings, out = [];
  if (!s.publicIp) out.push(`<div class="alert bad"><div><b>Alamat VPS belum diketahui.</b>Isi di menu Pengaturan supaya script MikroTik benar.</div></div>`);
  if (s.useIpsec && !s.pskSet) out.push(`<div class="alert bad"><div><b>Kunci IPsec (PSK) tidak ditemukan di VPS.</b>Pastikan server VPN (vpnsetup.sh) sudah dipasang.</div></div>`);
  if (s.genieCidr !== null && !genieOk(s.genieCidr)) out.push(`<div class="alert warn"><div><b>Patch IP virtual GenieACS belum aktif.</b>Summon ke ONT akan gagal. Lihat menu Pengaturan.</div></div>`);
  $("#alerts").innerHTML = out.join("");
}
function genieOk(v) { if (!v) return false; const x = v.toLowerCase(); return ["all", "true", "1", "yes"].includes(x) || v.split(",").map((t) => t.trim()).includes("10.100.0.0/14"); }

let SORT = { key: "name", dir: 1 };
let QUERY = "";
function renderVpsInfo() {
  const s = STATE.settings;
  $("#vpsInfo").innerHTML = [
    ["Alamat VPS", s.publicIp || "-"],
    ["URL ACS ONT", s.acsUrl || "-"],
    ["Jaringan VPN", s.tunnelNet || "-"],
    ["IPsec", s.useIpsec ? "Aktif" : "Tidak dipakai"],
  ].map(([k, v]) => `<div><span>${k}</span><b>${esc(v)}</b></div>`).join("");
}
function renderSites() {
  const list = STATE.sites, on = list.filter((s) => s.online).length;
  $("#stTotal").textContent = list.length; $("#stOn").textContent = on; $("#stOff").textContent = list.length - on;
  renderVpsInfo();
  document.querySelectorAll("th.sort").forEach((th) => {
    th.classList.toggle("asc", th.dataset.sort === SORT.key && SORT.dir === 1);
    th.classList.toggle("desc", th.dataset.sort === SORT.key && SORT.dir === -1);
  });
  if (!list.length) {
    $("#siteList").innerHTML = `<tr><td colspan="6" class="t-empty"><div class="empty-box"><h2>Belum ada lokasi</h2><p>Tambahkan MikroTik pertama Anda. Panel akan membuatkan akun VPN dan script MikroTik yang tinggal disalin.</p><button class="btn primary big" onclick="openAdd()">＋ Tambah Lokasi Pertama</button></div></td></tr>`;
    $("#siteCount").textContent = "";
    return;
  }
  const q = QUERY.trim().toLowerCase();
  const rows = list
    .filter((s) => !q || [s.name, s.note, s.realSubnet, s.virtualSubnet, s.tunnelIp, s.username].join(" ").toLowerCase().includes(q))
    .sort((x, y) => {
      const k = SORT.key;
      let a = x[k], b = y[k];
      if (k === "tunnelIp") { a = a.split(".").map((n) => n.padStart(3, "0")).join("."); b = b.split(".").map((n) => n.padStart(3, "0")).join("."); }
      if (k === "online") { a = a ? 0 : 1; b = b ? 0 : 1; }
      if (typeof a === "string") return a.localeCompare(b, "id") * SORT.dir;
      return (a - b) * SORT.dir;
    });
  $("#siteCount").textContent = `Menampilkan ${rows.length} dari ${list.length} lokasi`;
  if (!rows.length) {
    $("#siteList").innerHTML = `<tr><td colspan="6" class="t-empty">Tidak ada lokasi yang cocok dengan "${esc(QUERY)}".</td></tr>`;
    return;
  }
  $("#siteList").innerHTML = rows.map((s) => `
    <tr>
      <td data-label="Nama"><div><span class="t-name">${esc(s.name)}</span>${s.note ? `<span class="t-note">${esc(s.note)}</span>` : ""}</div></td>
      <td data-label="Subnet → Virtual"><div><span class="t-mono">${esc(s.realSubnet)}</span><span class="t-sub">→ <span class="t-mono">${esc(s.virtualSubnet)}</span></span>${s.inGenie === false ? `<span class="tag-warn" title="IP virtual di luar rentang patch GenieACS (${esc(STATE.settings.genieCidr || "kosong")}). Summon ke lokasi ini akan gagal.">⚠ Di luar patch GenieACS</span>` : ""}</div></td>
      <td data-label="IP VPN"><div><span class="t-mono">${esc(s.tunnelIp)}</span><span class="t-sub">${esc(s.username)}</span></div></td>
      <td data-label="Remote">${s.forwards.length ? `<div class="remote-mini">${s.forwards.map((f) => `<a onclick="copyRemote('${esc(f.remote)}')" title="Klik untuk menyalin"><b>${esc(f.label)}</b><code>${esc(f.remote)}</code></a>`).join("")}</div>` : `<span class="sub">–</span>`}</td>
      <td data-label="Status"><span class="badge ${s.online ? "on" : "off"}">${s.online ? "Tersambung" : "Terputus"}</span></td>
      <td data-label="Aksi"><div class="t-act">
        <button class="btn primary sm" onclick="openScript('${s.id}')">Script</button>
        <button class="btn ib" title="Remote / Port Forward" onclick="openForward('${s.id}')"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="9"/><path d="M3 12h18M12 3a14 14 0 0 1 0 18M12 3a14 14 0 0 0 0 18"/></svg></button>
        <button class="btn ib" title="Tes Koneksi" onclick="openTest('${s.id}')"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M22 11.1V12a10 10 0 1 1-5.9-9.1"/><path d="M22 4L12 14l-3-3"/></svg></button>
        <button class="btn ib" title="Ubah" onclick="openEdit('${s.id}')"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M12 20h9"/><path d="M16.5 3.5a2.1 2.1 0 0 1 3 3L7 19l-4 1 1-4z"/></svg></button>
        <button class="btn ib del" title="Hapus" onclick="openDelete('${s.id}')"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M3 6h18M8 6V4h8v2M19 6l-1 14H6L5 6"/></svg></button>
      </div></td>
    </tr>`).join("");
}
$("#siteSearch").addEventListener("input", (e) => { QUERY = e.target.value; renderSites(); });
document.querySelectorAll("th.sort").forEach((th) => th.addEventListener("click", () => {
  if (SORT.key === th.dataset.sort) SORT.dir *= -1; else SORT = { key: th.dataset.sort, dir: 1 };
  renderSites();
}));
$("#rmCopy").addEventListener("click", () => copyText($("#rmScript").textContent).then(() => { $("#rmCopyOk").classList.remove("hidden"); toast("Script hapus tersalin"); }));

function renderSettings() {
  const s = STATE.settings;
  $("#sIp").value = s.publicIp || ""; $("#sPsk").value = s.psk || ""; $("#sAcs").value = s.acsUrl || "";
  $("#sIpsec").checked = !!s.useIpsec; $("#pskBox").classList.toggle("hidden", !s.useIpsec);
  $("#guideAcs").textContent = s.acsUrl || "";
  document.querySelectorAll(".tunLocal").forEach((el) => (el.textContent = s.tunnelLocal || ""));
  $("#tNow").textContent = s.tunnelNet || "-"; $("#tLocal").textContent = s.tunnelLocal || "-";
  $("#tStatic").textContent = (s.tunnelStatic || "-") + (s.tunnelMax ? ` (maks. ${s.tunnelMax} lokasi)` : "");
  $("#tPool").textContent = s.tunnelPool || "-";
  let g;
  if (s.genieCidr === null) g = `<div class="alert info"><div><b>GenieACS tidak ditemukan di VPS ini.</b>Abaikan jika GenieACS dipasang di server lain.</div></div>`;
  else if (genieOk(s.genieCidr)) g = `<div class="alert ok"><div><b>Aktif.</b>GENIEACS_CR_USE_REMOTE_ADDRESS = <code>${esc(s.genieCidr)}</code></div></div>`;
  else g = `<div class="alert warn"><div><b>Belum aktif atau rentang tidak cocok.</b>Nilai sekarang: <code>${esc(s.genieCidr || "(kosong)")}</code>. Jalankan <code>bash genieacs-virtualip.sh</code> dengan <code>VIRTUAL_CIDR="10.100.0.0/14"</code>.</div></div>`;
  $("#genieStatus").innerHTML = g;
}

/* ---------- Modal ---------- */
function modal(title, body, footer) {
  $("#modalRoot").innerHTML = `<div class="modal-bg" id="mbg"><div class="modal" role="dialog" aria-modal="true">
    <div class="modal-h"><h2>${title}</h2><button class="x" onclick="closeModal()" aria-label="Tutup">×</button></div>
    <div class="modal-b">${body}</div>${footer ? `<div class="modal-f">${footer}</div>` : ""}</div></div>`;
  $("#mbg").addEventListener("mousedown", (e) => { if (e.target.id === "mbg") closeModal(); });
}
function closeModal() { $("#modalRoot").innerHTML = ""; }
document.addEventListener("keydown", (e) => { if (e.key === "Escape") closeModal(); });
const site = (id) => STATE.sites.find((s) => s.id === id);

function siteForm(s) {
  return `
    <label for="fName">Nama lokasi</label>
    <input id="fName" type="text" maxlength="40" placeholder="contoh: Desa Sukamaju" value="${esc(s?.name || "")}">
    <label for="fSub">Subnet ONT di MikroTik lokasi ini</label>
    <input id="fSub" type="text" placeholder="contoh: 10.0.0.0/24" value="${esc(s?.realSubnet || "10.0.0.0/24")}">
    <div class="hint">Lihat di Winbox → <b>IP → DHCP Server → Networks</b>, kolom <i>Address</i>. Boleh sama dengan lokasi lain. IP virtual boleh dikosongkan, panel memilihnya otomatis.</div>
    <label for="fVirt">IP virtual (boleh kosong)</label>
    <input id="fVirt" type="text" placeholder="kosongkan = otomatis, contoh: 10.20.1.0/24" value="${esc(s?.virtualSubnet || "")}">
    <div class="hint">Isi jika ingin sama dengan IP virtual ZeroTier Anda. Ukurannya harus sama dengan subnet ONT, dan <b>tidak boleh sama dengan lokasi lain</b>.</div>
    <label for="fNote">Catatan (boleh kosong)</label>
    <input id="fNote" type="text" maxlength="120" placeholder="contoh: OLT C-Data 8 port, tower utara" value="${esc(s?.note || "")}">
    <div class="error" id="fErr"></div>`;
}
function readForm() { return { name: $("#fName").value, realSubnet: $("#fSub").value, virtualSubnet: $("#fVirt").value, note: $("#fNote").value }; }

window.openAdd = function () {
  modal("Tambah lokasi baru", siteForm(null), `<button class="btn" onclick="closeModal()">Batal</button><button class="btn primary" id="fSave">Simpan & buat script</button>`);
  $("#fName").focus();
  $("#fSave").onclick = async () => {
    $("#fSave").disabled = true;
    try {
      const r = await api("/api/sites", { method: "POST", body: readForm() });
      await load(); openScript(r.site.id, true);
    } catch (e) { $("#fErr").textContent = e.message; $("#fSave").disabled = false; }
  };
};
$("#addBtn").addEventListener("click", openAdd);
$("#refreshBtn").addEventListener("click", async () => { await load(); toast("Status diperbarui"); });

window.openEdit = function (id) {
  const s = site(id);
  modal("Ubah lokasi", siteForm(s) + `
    <h3>Password VPN</h3>
    <p class="hint" style="margin-top:0">Buat password baru jika password lama bocor. Setelah itu script MikroTik harus dipasang ulang.</p>
    <button class="btn sm" id="fReset">Buat password baru</button>`,
    `<button class="btn" onclick="closeModal()">Batal</button><button class="btn primary" id="fSave">Simpan</button>`);
  $("#fSave").onclick = async () => {
    try { await api("/api/sites/" + id, { method: "PUT", body: readForm() }); closeModal(); await load(); toast("Perubahan disimpan. Pasang ulang script jika subnet diubah."); }
    catch (e) { $("#fErr").textContent = e.message; }
  };
  $("#fReset").onclick = async () => {
    if (!confirm("Buat password VPN baru? MikroTik akan terputus sampai script baru dipasang.")) return;
    try { await api("/api/sites/" + id + "/reset-password", { method: "POST" }); await load(); openScript(id); toast("Password baru dibuat. Pasang ulang script di MikroTik."); }
    catch (e) { $("#fErr").textContent = e.message; }
  };
};

window.openDelete = function (id) {
  const s = site(id);
  modal("Hapus lokasi", `
    <p>Hapus lokasi <b>${esc(s.name)}</b>? Akun VPN-nya akan dinonaktifkan, dan GenieACS tidak bisa lagi Summon ONT di lokasi ini.</p>
    <p class="hint">Agar MikroTik bersih, salin script ini ke Winbox → New Terminal (boleh nanti):</p>
    <pre class="code">${esc(s.removeScript)}</pre>
    <div class="copy-row"><button class="btn sm" id="cpRm">Salin script hapus</button><span class="copied hidden" id="cpRmOk">✓ Tersalin</span></div>`,
    `<button class="btn" onclick="closeModal()">Batal</button><button class="btn danger" id="dDo">Ya, hapus</button>`);
  $("#cpRm").onclick = () => copyText(s.removeScript).then(() => $("#cpRmOk").classList.remove("hidden"));
  $("#dDo").onclick = async () => {
    try { await api("/api/sites/" + id, { method: "DELETE" }); closeModal(); await load(); toast("Lokasi dihapus"); }
    catch (e) { alert(e.message); }
  };
};

window.openScript = function (id, isNew) {
  const s = site(id);
  modal(isNew ? "✓ Lokasi dibuat. Pasang di MikroTik" : "Script MikroTik: " + esc(s.name), `
    ${isNew ? `<div class="alert ok"><div><b>Akun VPN untuk "${esc(s.name)}" sudah dibuat di VPS.</b>Sekarang ikuti 3 langkah di bawah.</div></div>` : ""}
    <ol class="steps">
      <li><span class="st">Salin script</span>
        <div class="copy-row"><button class="btn primary" id="cpBtn">📋 Salin Script</button><span class="copied hidden" id="cpOk">✓ Tersalin! Lanjut ke langkah 2</span></div>
        <details style="margin-top:8px"><summary class="hint" style="cursor:pointer">Lihat isi script</summary><pre class="code">${esc(s.script)}</pre></details>
      </li>
      <li><span class="st">Tempel di MikroTik</span>Buka <b>Winbox</b> → klik <b>New Terminal</b> → klik kanan → <b>Paste</b> → tekan <b>Enter</b>. Tunggu sampai muncul tulisan "VPN ACS selesai dipasang".</li>
      <li><span class="st">Cek status</span>Tutup jendela ini, klik <b>↻ Muat ulang status</b>. Jika lokasi berubah <span class="badge on">Tersambung</span>, klik <b>Tes Koneksi</b>.</li>
    </ol>
    <h3>Pengaturan ONT</h3>
    <table class="info">
      <tr><td>URL ACS (isi di ONT / profil TR-069 OLT)</td><td>${esc(s.acsUrl)}</td></tr>
      <tr><td>ONT ${esc(s.realSubnet)} terlihat di GenieACS sebagai</td><td>${esc(s.virtualSubnet)}</td></tr>
    </table>
    <h3>Data akun VPN (jika ingin mengisi manual)</h3>
    <table class="info">
      <tr><td>Connect To (alamat VPS)</td><td>${esc(STATE.settings.publicIp || "-")}</td></tr>
      <tr><td>User</td><td>${esc(s.username)}</td></tr>
      <tr><td>Password</td><td>${esc(s.password)}</td></tr>
      ${STATE.settings.useIpsec ? `<tr><td>IPsec secret (PSK)</td><td>${esc(STATE.settings.psk || "-")}</td></tr>` : `<tr><td>IPsec</td><td>Tidak dipakai</td></tr>`}
      <tr><td>IP VPN MikroTik</td><td>${esc(s.tunnelIp)}</td></tr>
    </table>`,
    `<button class="btn" onclick="closeModal()">Tutup</button>`);
  $("#cpBtn").onclick = () => copyText(s.script).then(() => { $("#cpOk").classList.remove("hidden"); toast("Script tersalin"); });
};

window.openTest = async function (id) {
  const s = site(id);
  modal("Tes koneksi: " + esc(s.name), `<p class="hint">Sedang mengetes, tunggu sebentar…</p>`);
  try {
    const r = await api("/api/sites/" + id + "/test", { method: "POST" });
    const allOk = r.steps.every((x) => x.ok !== false);
    const body = `
      ${allOk ? `<div class="alert ok"><div><b>Semua beres.</b>GenieACS sudah bisa menjangkau ONT di lokasi ini.</div></div>`
               : `<div class="alert warn"><div><b>Ada yang belum beres.</b>Lihat tanda merah di bawah dan menu Panduan → Pertanyaan umum.</div></div>`}
      <ul class="check">${r.steps.map((x) => `<li><span class="ic ${x.ok === null ? "skip" : x.ok ? "ok" : "no"}">${x.ok === null ? "–" : x.ok ? "✓" : "✕"}</span><div>${esc(x.label)}<small>${esc(x.detail)}</small></div></li>`).join("")}</ul>`;
    if ($("#mbg")) modal("Tes koneksi: " + esc(s.name), body, `<button class="btn" onclick="openTest('${id}')">Tes lagi</button><button class="btn primary" onclick="closeModal()">Tutup</button>`);
    load();
  } catch (e) { modal("Tes koneksi", `<div class="alert bad"><div>${esc(e.message)}</div></div>`); }
};

/* ---------- Remote / Port forwarding ---------- */
window.copyRemote = function (t) { copyText(t).then(() => toast("Tersalin: " + t)); };

window.openForward = function (id, keep) {
  const s = site(id), P = STATE.settings.presets || {};
  const rows = s.forwards.map((f) => `
    <tr>
      <td><b>${esc(f.label)}</b><div class="hint" style="margin:0">${f.proto === "both" ? "TCP+UDP" : f.proto.toUpperCase()}</div></td>
      <td class="m">${esc(f.remote)} <button class="btn sm" style="padding:3px 8px" onclick="copyRemote('${esc(f.remote)}')">Salin</button></td>
      <td class="m hide-sm">${f.target === "router" ? "MikroTik" : esc(f.lanIp)} : ${f.targetPort}</td>
      <td style="text-align:right"><button class="btn danger sm" onclick="delForward('${id}','${f.id}')">Hapus</button></td>
    </tr>`).join("");
  const opts = Object.entries(P).map(([k, v]) => `<option value="${k}">${esc(v.label)}${v.port ? " (port " + v.port + ")" : ""}</option>`).join("");
  modal("Remote / Port Forward: " + esc(s.name), `
    <p class="hint" style="margin-top:0">Akses MikroTik atau perangkat di lokasi ini dari mana saja lewat <b>alamat VPS + port</b>. Contoh di Winbox: isi <i>Connect To</i> dengan <code>${esc(STATE.settings.publicIp || "IP_VPS")}:20001</code>.</p>
    ${rows ? `<table class="fw"><tr><th>Layanan</th><th>Alamat remote</th><th class="hide-sm">Tujuan</th><th></th></tr>${rows}</table>`
           : `<div class="alert info"><div>Belum ada port forwarding. Tambahkan di bawah, misalnya <b>Winbox</b> untuk remote MikroTik.</div></div>`}
    <div class="addbox">
      <h3>Tambah port forwarding</h3>
      <div class="grid2">
        <div><label for="wSvc">Layanan</label><select id="wSvc">${opts}</select></div>
        <div><label for="wProto">Protokol</label><select id="wProto"><option value="tcp">TCP</option><option value="udp">UDP</option><option value="both">TCP + UDP</option></select></div>
      </div>
      <label>Tujuan</label>
      <div class="radio">
        <label><input type="radio" name="wTgt" value="router" checked> MikroTik ini</label>
        <label><input type="radio" name="wTgt" value="lan"> Perangkat di jaringan ONT (ONT, OLT, dll)</label>
      </div>
      <div id="wLanBox" class="hidden">
        <label for="wLan">IP asli perangkat</label>
        <input id="wLan" type="text" placeholder="contoh: ${esc(s.realGateway.replace(/\.1$/, ".25"))}">
        <div class="hint">Harus di dalam subnet ${esc(s.realSubnet)}. Panel otomatis menerjemahkan ke IP virtual.</div>
      </div>
      <div class="grid2">
        <div><label for="wPort">Port tujuan</label><input id="wPort" type="text" inputmode="numeric"></div>
        <div><label for="wPub">Port publik di VPS</label><input id="wPub" type="text" inputmode="numeric" placeholder="kosong = otomatis"></div>
      </div>
      <div id="wLabelBox" class="hidden"><label for="wLabel">Nama layanan</label><input id="wLabel" type="text" maxlength="30" placeholder="contoh: Web OLT"></div>
      <div class="error" id="wErr"></div>
      <button class="btn primary" id="wAdd" style="margin-top:12px">＋ Tambah</button>
    </div>
    <p class="hint">Port forwarding ke MikroTik butuh aturan "VPN ACS - remote dari VPS". Jika script MikroTik lokasi ini dipasang sebelum fitur ini ada, salin ulang script-nya sekali.</p>`,
    `<button class="btn" onclick="closeModal()">Tutup</button>`);
  const syncPreset = () => {
    const p = P[$("#wSvc").value] || {};
    $("#wPort").value = p.port || "";
    $("#wProto").value = p.proto || "tcp";
    $("#wLabelBox").classList.toggle("hidden", $("#wSvc").value !== "custom");
    if ($("#wSvc").value === "ontweb") { document.querySelector('input[name=wTgt][value=lan]').checked = true; syncTgt(); }
  };
  const syncTgt = () => $("#wLanBox").classList.toggle("hidden", document.querySelector("input[name=wTgt]:checked").value !== "lan");
  $("#wSvc").onchange = syncPreset;
  document.querySelectorAll("input[name=wTgt]").forEach((r) => (r.onchange = syncTgt));
  syncPreset();
  $("#wAdd").onclick = async () => {
    $("#wErr").textContent = ""; $("#wAdd").disabled = true;
    const body = {
      service: $("#wSvc").value, proto: $("#wProto").value,
      target: document.querySelector("input[name=wTgt]:checked").value,
      lanIp: $("#wLan").value, targetPort: $("#wPort").value, publicPort: $("#wPub").value, label: $("#wLabel").value,
    };
    try { await api("/api/sites/" + id + "/forwards", { method: "POST", body }); await load(); openForward(id); toast("Port forwarding ditambahkan"); }
    catch (e) { $("#wErr").textContent = e.message; $("#wAdd").disabled = false; }
  };
};

window.delForward = async function (id, fid) {
  if (!confirm("Hapus port forwarding ini?")) return;
  try { await api("/api/sites/" + id + "/forwards/" + fid, { method: "DELETE" }); await load(); openForward(id); toast("Port forwarding dihapus"); }
  catch (e) { alert(e.message); }
};

/* ---------- Pengaturan ---------- */
$("#sIpsec").addEventListener("change", () => $("#pskBox").classList.toggle("hidden", !$("#sIpsec").checked));
$("#pskToggle").addEventListener("click", () => { const i = $("#sPsk"); i.type = i.type === "password" ? "text" : "password"; $("#pskToggle").textContent = i.type === "password" ? "Lihat" : "Sembunyikan"; });
$("#vpsForm").addEventListener("submit", async (e) => {
  e.preventDefault(); $("#vpsErr").textContent = "";
  const changed = $("#sIpsec").checked !== !!STATE.settings.useIpsec;
  try { await api("/api/settings", { method: "PUT", body: { publicIp: $("#sIp").value, useIpsec: $("#sIpsec").checked } }); await load(); toast(changed ? "Disimpan. Salin ulang script ke semua MikroTik." : "Pengaturan disimpan"); }
  catch (err) { $("#vpsErr").textContent = err.message; }
});
$("#tunForm").addEventListener("submit", async (e) => {
  e.preventDefault(); $("#tErr").textContent = "";
  const v = $("#tNet").value.trim();
  if (!v) { $("#tErr").textContent = "Isi jaringan VPN baru dulu."; return; }
  if (v === STATE.settings.tunnelNet) { $("#tErr").textContent = "Sama dengan jaringan sekarang."; return; }
  const n = STATE.sites.length;
  if (!confirm(`Ganti jaringan VPN dari ${STATE.settings.tunnelNet} ke ${v}?\n\n- Semua VPN akan terputus sebentar.\n- Script MikroTik di ${n} lokasi harus disalin ulang.\n- URL ACS di semua ONT harus diganti.\n\nLanjutkan?`)) return;
  try {
    await api("/api/settings", { method: "PUT", body: { tunnelNet: v } });
    $("#tNet").value = ""; await load();
    modal("Jaringan VPN diganti", `
      <div class="alert ok"><div><b>Jaringan VPN sekarang ${esc(STATE.settings.tunnelNet)}.</b>Server VPN di VPS sudah disesuaikan dan di-restart.</div></div>
      <ol class="steps">
        <li><span class="st">Salin ulang script ke semua MikroTik</span>Buka tab Lokasi, klik <i>Script MikroTik</i> di setiap lokasi, lalu tempel di Winbox → New Terminal.</li>
        <li><span class="st">Ganti URL ACS di semua ONT</span>URL baru: <code>${esc(STATE.settings.acsUrl)}</code>. Paling cepat lewat profil TR-069 di OLT.</li>
        <li><span class="st">Cek</span>Klik <i>Muat ulang status</i> lalu <i>Tes Koneksi</i> di tiap lokasi.</li>
      </ol>`, `<button class="btn primary" onclick="closeModal()">Mengerti</button>`);
  } catch (err) { $("#tErr").textContent = err.message; }
});
$("#pwForm").addEventListener("submit", async (e) => {
  e.preventDefault(); $("#pwErr").textContent = "";
  try { await api("/api/settings", { method: "PUT", body: { oldPassword: $("#pOld").value, newPassword: $("#pNew").value } }); $("#pOld").value = ""; $("#pNew").value = ""; toast("Password diganti"); }
  catch (err) { $("#pwErr").textContent = err.message; }
});

/* ---------- Mulai ---------- */
(async () => {
  try { const me = await api("/api/me"); if (me.loggedIn) { showApp(); load(); } else showLogin(); }
  catch (e) { showLogin(); }
  setInterval(() => { if (!$("#appView").classList.contains("hidden") && !$("#mbg")) load(); }, 30000);
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
echo
ok "Panel VPN ACS berjalan"
echo -e "   Buka di browser: ${GREEN}http://${PUBIP}:${PANEL_PORT}${NC}"
echo "   (Jika IP di atas bukan IP publik, pakai IP publik VPS Anda)"
