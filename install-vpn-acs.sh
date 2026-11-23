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
    return iface
      ? { ok: true, detail: `Tersambung lewat ${iface}` }
      : { ok: false, detail: "MikroTik belum tersambung ke VPS", hint: "Pastikan script MikroTik sudah dipasang, MikroTik punya internet, dan alamat VPS di Pengaturan benar." };
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
      : { ok: false, detail: `Di luar rentang patch (${st.genieCidr || "kosong"})`, hint: "Jalankan ulang genieacs-virtualip.sh dengan VIRTUAL_CIDR yang mencakup IP virtual lokasi ini." };
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

  const m = p.match(/^\/api\/sites\/([a-f0-9]{12})(\/(test|test-plan|test-step|reset-password))?$/);
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
    if (action === "test-plan" && method === "GET") {
      return send(res, 200, { steps: testPlan(site) });
    }
    if (action === "test-step" && method === "POST") {
      const body = await readBody(req);
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
<title>VPN ACS</title>
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
  .row.warn .ic{width:32px;height:32px;border-radius:8px;display:grid;place-items:center;background:var(--warn-soft);color:var(--warn);flex:none}
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

  /* Form */
  label{display:block;font-size:13px;font-weight:500;margin:14px 0 6px}
  .help{font-size:12.5px;color:var(--muted);margin-top:6px}
  input[type=text],input[type=password],select{width:100%;height:38px;padding:0 12px;border:1px solid var(--line-2);border-radius:var(--r-sm);background:var(--surface);font-size:14px;outline:none;transition:border-color .12s,box-shadow .12s}
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
  .form-actions{display:flex;gap:8px;margin-top:18px}

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

  .toast{position:fixed;left:50%;bottom:24px;transform:translateX(-50%);background:var(--text);color:var(--surface);padding:10px 16px;border-radius:8px;font-size:13.5px;font-weight:500;z-index:90;box-shadow:var(--shadow-lg);animation:pop .18s}

  @media (max-width:1024px){
    .side{transform:translateX(-100%)}
    body.nav-open .side{transform:none}
    .wrap{margin-left:0}
    #navBtn{display:inline-flex}
    .top{padding:0 14px}
    .main{padding:20px 16px}
    .grid2{grid-template-columns:1fr}
  }
  @media (max-width:720px){
    .kpis{grid-template-columns:1fr 1fr;gap:10px}
    .kpi b{font-size:24px}
    .row .meta{display:none}
    .dl{grid-template-columns:1fr}
    .dl>div:nth-child(odd){border-right:0}
    .howto{grid-template-columns:1fr}
    .f2{grid-template-columns:1fr}
    .toolbar{flex-wrap:wrap}
    .search{max-width:none;flex-basis:100%}
    .filters{margin-left:0}
    table.t .hide-sm{display:none}
    table.t th,table.t td{padding-left:14px;padding-right:14px}
    .avatar{display:none}
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
    <button class="nav" data-go="#/lokasi"><span data-ic="router"></span>Lokasi<span class="cnt" id="navCount">0</span></button>
    <div class="nav-sec">Lainnya</div>
    <button class="nav" data-go="#/panduan"><span data-ic="book"></span>Panduan</button>
    <button class="nav" data-go="#/pengaturan"><span data-ic="gear"></span>Pengaturan</button>
    <div class="grow"></div>
    <button class="nav" data-act="theme"><span data-ic="moon"></span>Mode gelap</button>
    <button class="nav" data-act="logout"><span data-ic="logout"></span>Keluar</button>
  </aside>
  <div class="backdrop" data-act="closenav"></div>
  <div class="wrap">
    <header class="top">
      <button class="btn ghost icon" id="navBtn" data-act="opennav" aria-label="Menu"><span data-ic="menu"></span></button>
      <div class="crumb" id="crumb"></div>
      <div class="top-r">
        <button class="btn ghost icon" data-act="refresh" title="Muat ulang status"><span data-ic="refresh"></span></button>
        <button class="btn ghost icon" data-act="theme" title="Mode gelap / terang"><span data-ic="moon"></span></button>
        <span class="avatar">A</span>
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
function genieOk(v) { if (!v) return false; const x = v.toLowerCase(); return ["all", "true", "1", "yes"].includes(x) || v.split(",").map((t) => t.trim()).includes("10.100.0.0/14"); }

/* ================= Tema & navigasi ================= */
function applyTheme(t) { document.documentElement.setAttribute("data-theme", t); }
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

/* ================= Modal ================= */
function modal(title, body, footer) {
  $("#modalRoot").innerHTML = `<div class="mbg" id="mbg"><div class="modal" role="dialog" aria-modal="true">
    <div class="mh"><h2>${title}</h2><button class="btn ghost icon x" data-act="closemodal" aria-label="Tutup">${ic("x")}</button></div>
    <div class="mb">${body}</div>${footer ? `<div class="mf">${footer}</div>` : `<div style="height:18px"></div>`}</div></div>`;
  $("#mbg").addEventListener("mousedown", (e) => { if (e.target.id === "mbg") closeModal(); });
  const f = $("#modalRoot input:not([readonly])"); if (f) f.focus();
}
function closeModal() { $("#modalRoot").innerHTML = ""; }

/* ================= Login ================= */
function showLogin() { $("#appView").classList.add("hidden"); $("#loginView").classList.remove("hidden"); $("#lp").focus(); }
function showApp() { $("#loginView").classList.add("hidden"); $("#appView").classList.remove("hidden"); }
$("#loginForm").addEventListener("submit", async (e) => {
  e.preventDefault(); $("#loginErr").textContent = "";
  try { await api("/api/login", { method: "POST", body: { password: $("#lp").value } }); $("#lp").value = ""; showApp(); await load(); route(); }
  catch (err) { $("#loginErr").textContent = err.message; }
});

/* ================= Data ================= */
async function load() {
  STATE = await api("/api/overview");
  LOADED = true;
  $("#navCount").textContent = STATE.sites.length;
}

/* ================= Router ================= */
let TEST = null; // status tes yang sedang berjalan
function route() {
  if (!LOADED) return;
  const h = location.hash || "#/";
  const parts = h.replace(/^#\/?/, "").split("/").filter(Boolean);
  document.querySelectorAll(".nav[data-go]").forEach((n) => {
    const g = n.dataset.go.replace(/^#\/?/, "");
    n.classList.toggle("on", (g === "" && parts.length === 0) || (g && parts[0] === g));
  });
  document.body.classList.remove("nav-open");
  closeModal();
  const v = $("#view");
  if (parts[0] === "lokasi" && parts[1] === "terputus") { LIST.f = "off"; LIST.q = ""; history.replaceState(null, "", "#/lokasi"); viewList(v); }
  else if (parts[0] === "lokasi" && parts[1]) { viewDetail(v, parts[1], parts[2] || "ringkasan"); }
  else if (parts[0] === "lokasi") { viewList(v); }
  else if (parts[0] === "panduan") { viewGuide(v); }
  else if (parts[0] === "pengaturan") { viewSettings(v); }
  else { viewDashboard(v); }
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
  const off = STATE.sites.filter((x) => !x.online);
  if (off.length === 1) list.push({ t: `${off[0].name} terputus`, d: "MikroTik belum tersambung ke VPS. Jalankan tes koneksi.", go: `#/lokasi/${off[0].id}/tes` });
  else if (off.length > 1) {
    const names = off.map((x) => x.name);
    list.push({ t: `${off.length} lokasi terputus`, d: names.slice(0, 4).join(", ") + (names.length > 4 ? ` dan ${names.length - 4} lainnya` : ""), go: "#/lokasi/terputus" });
  }
  for (const x of STATE.sites) {
    if (x.inGenie === false) list.push({ t: `${x.name}: IP virtual di luar patch GenieACS`, d: `${x.virtualSubnet} tidak dikenali GenieACS, Summon akan gagal.`, go: `#/lokasi/${x.id}` });
  }
  return list;
}
function viewDashboard(v) {
  crumb([["Dashboard"]]);
  const S = STATE.sites, on = S.filter((x) => x.online).length, fw = S.reduce((a, x) => a + x.forwards.length, 0);
  const iss = issues();
  const recent = [...S].sort((a, b) => (a.online === b.online ? a.name.localeCompare(b.name, "id") : a.online ? 1 : -1)).slice(0, 6);
  v.innerHTML = `
    <div class="ph"><div><h1>Dashboard</h1><p>Ringkasan jaringan VPN ACS.</p></div>
      <div class="acts"><button class="btn pri" data-act="add">${ic("plus")}Tambah lokasi</button></div></div>
    <div class="kpis">
      <div class="kpi"><span>Lokasi</span><b>${S.length}</b><small>MikroTik terdaftar</small></div>
      <div class="kpi"><span><i class="dot ok"></i>Tersambung</span><b>${on}</b><small>${S.length ? Math.round((on / S.length) * 100) : 0}% dari semua lokasi</small></div>
      <div class="kpi"><span><i class="dot bad"></i>Terputus</span><b>${S.length - on}</b><small>${S.length - on ? "perlu dicek" : "tidak ada"}</small></div>
      <div class="kpi"><span>Remote aktif</span><b>${fw}</b><small>port forwarding</small></div>
    </div>
    <div class="grid2">
      <div class="stack">
        <div class="card">
          <div class="ch"><h2>Perlu perhatian</h2>${iss.length ? `<span class="muted">${iss.length} item</span>` : ""}</div>
          ${iss.length ? `<ul class="rows">${iss.slice(0, 6).map((x) => `<li><a class="row warn" href="${x.go}"><span class="ic">${ic("alert")}</span><span class="grow"><span class="nm">${esc(x.t)}</span><span class="sb" style="display:block">${esc(x.d)}</span></span><span class="chev">${ic("chev")}</span></a></li>`).join("")}</ul>`
            : `<div class="empty"><div class="big">${ic("check")}</div><h3>Semua normal</h3><p>Semua lokasi tersambung dan pengaturan lengkap.</p></div>`}
        </div>
        <div class="card">
          <div class="ch"><h2>Lokasi</h2>${S.length ? `<a href="#/lokasi">Lihat semua</a>` : ""}</div>
          ${S.length ? `<ul class="rows">${recent.map(rowHtml).join("")}</ul>`
            : `<div class="empty"><h3>Belum ada lokasi</h3><p>Tambahkan MikroTik pertama untuk mulai.</p><button class="btn pri" style="margin-top:12px" data-act="add">${ic("plus")}Tambah lokasi</button></div>`}
        </div>
      </div>
      <div class="card">
        <div class="ch"><h2>Server</h2><a href="#/pengaturan">Pengaturan</a></div>
        ${serverKv()}
      </div>
    </div>`;
}
function serverKv() {
  const s = STATE.settings;
  const g = s.genieCidr === null ? "Tidak ada" : genieOk(s.genieCidr) ? "Aktif" : "Belum aktif";
  return [["Alamat VPS", s.publicIp || "—"], ["URL ACS ONT", s.acsUrl || "—"], ["Jaringan VPN", s.tunnelNet || "—"], ["IPsec", s.useIpsec ? "Aktif" : "Tidak dipakai"], ["Patch GenieACS", g]]
    .map(([k, val]) => `<div class="kv"><span>${k}</span><b>${esc(val)}</b></div>`).join("");
}
function rowHtml(x) {
  return `<li><a class="row" href="#/lokasi/${x.id}">
    <span class="dot ${x.online ? "ok" : "bad"}"></span>
    <span class="grow"><span class="nm">${esc(x.name)}</span>${x.note ? `<span class="sb" style="display:block">${esc(x.note)}</span>` : ""}</span>
    <span class="meta">${esc(x.virtualSubnet)}</span>
    <span class="pill ${x.online ? "ok" : "bad"}">${x.online ? "Tersambung" : "Terputus"}</span>
    <span class="chev">${ic("chev")}</span></a></li>`;
}

/* ================= Daftar lokasi ================= */
let LIST = { q: "", f: "all" };
function viewList(v) {
  crumb([["Lokasi"]]);
  v.innerHTML = `
    <div class="ph"><div><h1>Lokasi</h1><p>Setiap lokasi adalah satu MikroTik yang tersambung ke VPS lewat VPN.</p></div>
      <div class="acts"><button class="btn pri" data-act="add">${ic("plus")}Tambah lokasi</button></div></div>
    <div class="card">
      <div class="toolbar">
        <div class="search">${ic("search", "")}<input id="q" type="text" placeholder="Cari nama, subnet, atau IP" value="${esc(LIST.q)}"></div>
        <div class="filters">
          <button class="chip ${LIST.f === "all" ? "on" : ""}" data-filter="all">Semua</button>
          <button class="chip ${LIST.f === "on" ? "on" : ""}" data-filter="on">Tersambung</button>
          <button class="chip ${LIST.f === "off" ? "on" : ""}" data-filter="off">Terputus</button>
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
    .filter((x) => LIST.f === "all" || (LIST.f === "on" ? x.online : !x.online))
    .filter((x) => !q || [x.name, x.note, x.realSubnet, x.virtualSubnet, x.tunnelIp].join(" ").toLowerCase().includes(q))
    .sort((a, b) => a.name.localeCompare(b.name, "id"));
  const el = $("#listRows");
  if (!STATE.sites.length) el.innerHTML = `<li><div class="empty"><h3>Belum ada lokasi</h3><p>Tambahkan MikroTik pertama untuk mulai.</p></div></li>`;
  else if (!rows.length) el.innerHTML = `<li><div class="empty"><p>Tidak ada lokasi yang cocok.</p></div></li>`;
  else el.innerHTML = rows.map(rowHtml).join("");
}

/* ================= Detail lokasi ================= */
const TABS = [["ringkasan", "Ringkasan"], ["remote", "Remote"], ["script", "Script MikroTik"], ["tes", "Tes koneksi"]];
function viewDetail(v, id, tab) {
  const x = site(id);
  if (!x) { crumb([["Lokasi", "#/lokasi"], ["Tidak ditemukan"]]); v.innerHTML = `<div class="card"><div class="empty"><h3>Lokasi tidak ditemukan</h3><p><a href="#/lokasi">Kembali ke daftar lokasi</a></p></div></div>`; return; }
  crumb([["Lokasi", "#/lokasi"], [x.name]]);
  v.innerHTML = `
    <div class="dh">
      <div><h1>${esc(x.name)} <span class="pill ${x.online ? "ok" : "bad"}">${x.online ? "Tersambung" : "Terputus"}</span></h1>
        <p>${x.note ? esc(x.note) + " · " : ""}IP virtual ${esc(x.virtualSubnet)}</p></div>
      <div class="acts" style="display:flex;gap:8px">
        <a class="btn" href="#/lokasi/${x.id}/tes">${ic("play")}Tes koneksi</a>
        <div class="menu"><button class="btn icon" data-act="menu" aria-label="Lainnya">${ic("dots")}</button>
          <div class="menu-list hidden" id="menuList">
            <button data-act="edit" data-id="${x.id}">${ic("edit")}Ubah lokasi</button>
            <button data-act="resetpw" data-id="${x.id}">${ic("key")}Buat password VPN baru</button>
            <hr><button class="d" data-act="del" data-id="${x.id}">${ic("trash")}Hapus lokasi</button>
          </div></div>
      </div>
    </div>
    <nav class="tabs">${TABS.map(([k, t]) => `<a class="tab ${k === tab ? "on" : ""}" href="#/lokasi/${x.id}/${k}">${t}${k === "remote" && x.forwards.length ? ` <span class="muted">${x.forwards.length}</span>` : ""}</a>`).join("")}</nav>
    <div id="tabBody"></div>`;
  const b = $("#tabBody");
  if (tab === "remote") tabRemote(b, x);
  else if (tab === "script") tabScript(b, x);
  else if (tab === "tes") tabTest(b, x);
  else tabSummary(b, x);
}
function tabSummary(b, x) {
  b.innerHTML = `
    ${x.inGenie === false ? `<div class="note warn">${ic("alert")}<div><b>IP virtual di luar rentang patch GenieACS</b>Summon ke ONT di lokasi ini akan gagal. Jalankan ulang <code>genieacs-virtualip.sh</code> dengan rentang yang mencakup ${esc(x.virtualSubnet)}.</div></div>` : ""}
    ${!x.online ? `<div class="note info">${ic("info")}<div><b>MikroTik belum tersambung</b>Pasang script di MikroTik lewat tab <a href="#/lokasi/${x.id}/script">Script MikroTik</a>, lalu jalankan <a href="#/lokasi/${x.id}/tes">Tes koneksi</a>.</div></div>` : ""}
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
        <div><dt>Server (connect-to)</dt><dd>${esc(STATE.settings.publicIp || "—")}</dd></div>
        <div><dt>Username</dt><dd>${esc(x.username)} ${copyBtn(x.username)}</dd></div>
        <div><dt>Password</dt><dd><span id="pwv">••••••••••••</span><button class="copy" data-act="showpw" title="Lihat">${ic("eye", "")}</button>${copyBtn(x.password, "Password tersalin")}</dd></div>
        <div><dt>IPsec</dt><dd>${STATE.settings.useIpsec ? "Aktif" : "Tidak dipakai"}</dd></div>
      </dl>
    </div>`;
}
function tabRemote(b, x) {
  const P = STATE.settings.presets || {};
  b.innerHTML = `
    <div class="card">
      <div class="ch"><h2>Akses remote</h2><button class="btn sm pri" data-act="addfwd">${ic("plus")}Tambah</button></div>
      ${x.forwards.length ? `<table class="t"><thead><tr><th>Layanan</th><th>Alamat</th><th class="hide-sm">Tujuan</th><th></th></tr></thead><tbody>
        ${x.forwards.map((f) => `<tr><td><b style="font-weight:550">${esc(f.label)}</b></td>
          <td><span class="mono">${esc(f.remote)}</span> ${copyBtn(f.remote, "Alamat tersalin")}</td>
          <td class="hide-sm muted mono">${f.target === "router" ? "MikroTik" : esc(f.lanIp)}:${f.targetPort}</td>
          <td class="r"><button class="btn sm ghost" data-act="delfwd" data-fid="${f.id}" title="Hapus">${ic("trash")}</button></td></tr>`).join("")}
      </tbody></table>`
      : `<div class="empty"><h3>Belum ada akses remote</h3><p>Tambahkan Winbox untuk remote MikroTik ini lewat ${esc(STATE.settings.publicIp || "VPS")}.</p></div>`}
    </div>
    <p class="help" style="margin-top:12px">Di Winbox, isi <b>Connect To</b> dengan alamat di atas (lengkap dengan port). Port ini terbuka ke internet, jadi pastikan password MikroTik kuat.</p>`;
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
    `<button class="btn" data-act="closemodal">Batal</button><button class="btn pri" id="wSave">Tambah</button>`);
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
    $("#wErr").textContent = ""; $("#wSave").disabled = true;
    try {
      await api(`/api/sites/${x.id}/forwards`, { method: "POST", body: { service: $("#wSvc").value, proto: $("#wProto").value, target: document.querySelector("input[name=wTgt]:checked").value, lanIp: $("#wLan").value, targetPort: $("#wPort").value, publicPort: $("#wPub").value, label: $("#wLabel").value } });
      await load(); route(); toast("Akses remote ditambahkan");
    } catch (e) { $("#wErr").textContent = e.message; $("#wSave").disabled = false; }
  };
}
function tabScript(b, x) {
  b.innerHTML = `
    ${x.online ? "" : `<ol class="howto">
      <li><b><i>1</i>Salin script</b>Klik tombol Salin di kotak script.</li>
      <li><b><i>2</i>Tempel di MikroTik</b>Winbox → New Terminal → klik kanan → Paste → Enter.</li>
      <li><b><i>3</i>Tes koneksi</b>Buka tab <a href="#/lokasi/${x.id}/tes">Tes koneksi</a> untuk memastikan semuanya jalan.</li></ol>`}
    <div class="card"><div class="ch"><h2>Script pemasangan</h2><span class="muted" style="font-size:12.5px">Aman dijalankan ulang</span></div>
      <div class="cb"><div class="codebox"><pre class="code">${esc(x.script)}</pre><button class="btn sm" data-copy="${esc(x.script)}" data-msg="Script tersalin. Tempel di Winbox → New Terminal">${ic("copy")}Salin</button></div>
      <details class="more"><summary>Script untuk menghapus dari MikroTik</summary><div class="codebox"><pre class="code">${esc(x.removeScript)}</pre><button class="btn sm" data-copy="${esc(x.removeScript)}" data-msg="Script hapus tersalin">${ic("copy")}Salin</button></div></details></div></div>`;
}

/* ---------- Tes koneksi bertahap ---------- */
function tabTest(b, x) {
  const running = TEST && TEST.id === x.id && TEST.running;
  b.innerHTML = `
    <div class="card" id="tstCard">
      <div class="tst-head"><div><h2>Tes koneksi</h2><p id="tstSub">Memeriksa jalur dari VPS ke MikroTik, jaringan ONT, GenieACS, dan akses remote.</p></div>
        <button class="btn pri" id="tstBtn" data-act="runtest" ${running ? "disabled" : ""}>${ic("play")}${TEST && TEST.id === x.id && TEST.done ? "Tes ulang" : "Mulai tes"}</button></div>
      <div class="prog"><i id="tstProg"></i></div>
      <ol class="steps" id="tstSteps"><li class="step wait"><span class="sic">…</span><span class="stx"><b>Memuat langkah tes…</b></span></li></ol>
      <div id="tstSum"></div>
    </div>`;
  if (TEST && TEST.id === x.id && TEST.plan) { drawSteps(); return; }
  api(`/api/sites/${x.id}/test-plan`).then((r) => {
    TEST = { id: x.id, plan: r.steps, res: {}, running: false, done: false };
    drawSteps();
    if (location.hash.endsWith("/tes") && !sessionStorageGet("tested-" + x.id)) runTest();
  }).catch((e) => { $("#tstSteps").innerHTML = `<li class="step fail"><span class="stx"><b>${esc(e.message)}</b></span></li>`; });
}
function sessionStorageGet(k) { try { return sessionStorage.getItem(k); } catch (e) { return null; } }
function sessionStorageSet(k, v) { try { sessionStorage.setItem(k, v); } catch (e) {} }
function drawSteps() {
  if (!TEST || !$("#tstSteps")) return;
  const P = TEST.plan;
  $("#tstSteps").innerHTML = P.map((s, i) => {
    const r = TEST.res[s.key];
    const st = !r ? (TEST.current === s.key ? "run" : "wait") : r.ok === true ? "ok" : r.ok === false ? "fail" : "skip";
    const icon = st === "ok" ? ic("check", "") : st === "fail" ? ic("x", "") : st === "skip" ? ic("minus", "") : st === "run" ? "" : i + 1;
    return `<li class="step ${st}"><span class="sic">${icon}</span><span class="stx"><b>${esc(s.label)}</b><small>${esc(s.desc)}</small>
      ${r ? `<div class="sres">${esc(r.detail)}${r.hint && r.ok === false ? `<span class="hint">${esc(r.hint)}</span>` : ""}</div>` : st === "run" ? `<div class="sres muted">Memeriksa…</div>` : ""}</span>
      ${r && r.ms != null ? `<span class="tm">${(r.ms / 1000).toFixed(1)} dtk</span>` : ""}</li>`;
  }).join("");
  const doneN = Object.keys(TEST.res).length;
  $("#tstProg").style.width = (P.length ? (doneN / P.length) * 100 : 0) + "%";
  if (TEST.running) $("#tstSub").textContent = `Langkah ${Math.min(doneN + 1, P.length)} dari ${P.length}…`;
  if (TEST.done) {
    const fail = P.filter((s) => TEST.res[s.key] && TEST.res[s.key].ok === false).length;
    $("#tstSub").textContent = `Selesai · ${P.length} langkah`;
    $("#tstSum").innerHTML = fail
      ? `<div class="tst-sum fail">${ic("alert")}${fail} langkah perlu diperbaiki. Lihat saran di bawah langkah yang gagal.</div>`
      : `<div class="tst-sum ok">${ic("check")}Semua beres. GenieACS dapat menjangkau ONT di lokasi ini.</div>`;
    const btn = $("#tstBtn"); if (btn) { btn.disabled = false; btn.innerHTML = ic("play") + "Tes ulang"; }
  } else $("#tstSum").innerHTML = "";
}
async function runTest() {
  if (!TEST || TEST.running) return;
  const id = TEST.id;
  TEST.res = {}; TEST.running = true; TEST.done = false;
  try { TEST.plan = (await api(`/api/sites/${id}/test-plan`)).steps; } catch (e) {}
  sessionStorageSet("tested-" + id, "1");
  const btn = $("#tstBtn"); if (btn) btn.disabled = true;
  let vpnDown = false;
  for (const s of TEST.plan) {
    if (!TEST || TEST.id !== id) return;
    TEST.current = s.key; drawSteps();
    const t0 = performance.now();
    let r;
    if (vpnDown && ["ping-mt", "route", "ping-gw"].includes(s.key)) r = { ok: null, detail: "Dilewati karena VPN belum tersambung" };
    else if (vpnDown && s.key.startsWith("fwd:")) r = { ok: null, detail: "Dilewati karena VPN belum tersambung" };
    else {
      try { r = await api(`/api/sites/${id}/test-step`, { method: "POST", body: { key: s.key } }); }
      catch (e) { r = { ok: false, detail: e.message }; }
      const minMs = 450; const el = performance.now() - t0; if (el < minMs) await new Promise((z) => setTimeout(z, minMs - el));
    }
    r.ms = performance.now() - t0;
    if (s.key === "vpn" && r.ok === false) vpnDown = true;
    TEST.res[s.key] = r; TEST.current = null; drawSteps();
  }
  TEST.running = false; TEST.done = true; drawSteps();
  load().then(() => { $("#navCount").textContent = STATE.sites.length; });
}

/* ================= Tambah / ubah / hapus lokasi ================= */
function siteForm(x) {
  return `
    <label for="fName">Nama lokasi</label>
    <input id="fName" type="text" maxlength="40" placeholder="contoh: Nangahale" value="${esc(x?.name || "")}">
    <label for="fSub">Subnet ONT di MikroTik</label>
    <input id="fSub" type="text" placeholder="10.0.0.0/24" value="${esc(x?.realSubnet || "10.0.0.0/24")}">
    <div class="help">Winbox → IP → DHCP Server → Networks. Boleh sama dengan lokasi lain.</div>
    <label for="fVirt">IP virtual <span class="muted" style="font-weight:400">(opsional)</span></label>
    <input id="fVirt" type="text" placeholder="Otomatis" value="${esc(x?.virtualSubnet || "")}">
    <div class="help">Kosongkan agar dipilih otomatis. Tidak boleh sama dengan lokasi lain.</div>
    <label for="fNote">Catatan <span class="muted" style="font-weight:400">(opsional)</span></label>
    <input id="fNote" type="text" maxlength="120" placeholder="contoh: OLT C-Data 8 port" value="${esc(x?.note || "")}">
    <div class="err" id="fErr"></div>`;
}
const readForm = () => ({ name: $("#fName").value, realSubnet: $("#fSub").value, virtualSubnet: $("#fVirt").value, note: $("#fNote").value });
function openAdd() {
  modal("Tambah lokasi", siteForm(null), `<button class="btn" data-act="closemodal">Batal</button><button class="btn pri" id="fSave">Simpan</button>`);
  $("#fSave").onclick = async () => {
    $("#fSave").disabled = true;
    try { const r = await api("/api/sites", { method: "POST", body: readForm() }); await load(); location.hash = `#/lokasi/${r.site.id}/script`; toast("Lokasi dibuat. Pasang script di MikroTik."); }
    catch (e) { $("#fErr").textContent = e.message; $("#fSave").disabled = false; }
  };
}
function openEdit(id) {
  const x = site(id);
  modal("Ubah lokasi", siteForm(x), `<button class="btn" data-act="closemodal">Batal</button><button class="btn pri" id="fSave">Simpan</button>`);
  $("#fSave").onclick = async () => {
    try { await api("/api/sites/" + id, { method: "PUT", body: readForm() }); await load(); route(); toast("Perubahan disimpan. Pasang ulang script jika subnet berubah."); }
    catch (e) { $("#fErr").textContent = e.message; }
  };
}
function openResetPw(id) {
  modal("Buat password VPN baru?", `<p>MikroTik lokasi ini akan terputus sampai script terbaru dipasang ulang.</p>`,
    `<button class="btn" data-act="closemodal">Batal</button><button class="btn pri" id="ok">Buat password baru</button>`);
  $("#ok").onclick = async () => { await api(`/api/sites/${id}/reset-password`, { method: "POST" }); await load(); location.hash = `#/lokasi/${id}/script`; route(); toast("Password baru dibuat. Pasang ulang script."); };
}
function openDelete(id) {
  const x = site(id);
  modal(`Hapus ${esc(x.name)}?`, `<p>Akun VPN dan akses remote lokasi ini akan dihapus. GenieACS tidak bisa lagi Summon ONT di lokasi ini.</p>
    <details class="more"><summary>Script untuk membersihkan MikroTik</summary><div class="codebox"><pre class="code">${esc(x.removeScript)}</pre><button class="btn sm" data-copy="${esc(x.removeScript)}" data-msg="Script hapus tersalin">${ic("copy")}Salin</button></div></details>`,
    `<button class="btn" data-act="closemodal">Batal</button><button class="btn danger" id="ok">Hapus lokasi</button>`);
  $("#ok").onclick = async () => { await api("/api/sites/" + id, { method: "DELETE" }); await load(); location.hash = "#/lokasi"; toast("Lokasi dihapus"); };
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
      <p>Setiap MikroTik membuat VPN ke VPS. Karena subnet ONT di semua lokasi boleh sama, tiap lokasi mendapat <b>IP virtual</b> berbeda; MikroTik menerjemahkannya kembali ke IP asli (NETMAP).</p>
    </div></div>
    <div class="card"><div class="ch"><h2>Menambah lokasi</h2></div><div class="cb"><ol class="ol">
      <li><b>Tambah lokasi di panel</b>Isi nama dan subnet ONT (Winbox → IP → DHCP Server → Networks).</li>
      <li><b>Pasang script di MikroTik</b>Tab Script MikroTik → Salin → Winbox → New Terminal → Paste.</li>
      <li><b>Jalankan tes koneksi</b>Tab Tes koneksi memeriksa VPN, jaringan ONT, GenieACS, dan akses remote satu per satu.</li>
      <li><b>Atur ONT</b>URL ACS di ONT atau profil TR-069 OLT: <code>${esc(s.acsUrl || "")}</code></li>
    </ol></div></div>
    <div class="card"><div class="ch"><h2>Remote MikroTik dari mana saja</h2></div><div class="cb"><ol class="ol">
      <li><b>Tambah akses remote</b>Buka lokasi → tab Remote → Tambah → pilih Winbox.</li>
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
      <details><summary>Bolehkah IP virtual sama dengan ZeroTier?</summary><p>Boleh. Yang tidak boleh: dua lokasi memakai IP virtual yang sama, atau IP virtual sama dengan subnet lokal mana pun.</p></details>
      <details><summary>Aman menjalankan script MikroTik berulang kali?</summary><p>Aman. Script menghapus pengaturan lama bertanda "VPN ACS" terlebih dulu; pengaturan lain tidak disentuh.</p></details>
    </div>`;
}

/* ================= Pengaturan ================= */
function viewSettings(v) {
  crumb([["Pengaturan"]]);
  const s = STATE.settings;
  const g = s.genieCidr === null ? { c: "info", t: "GenieACS tidak ditemukan di VPS ini", d: "Abaikan jika GenieACS dipasang di server lain." }
    : genieOk(s.genieCidr) ? { c: "ok", t: "Patch IP virtual aktif", d: `GENIEACS_CR_USE_REMOTE_ADDRESS = ${s.genieCidr}` }
    : { c: "warn", t: "Patch IP virtual belum aktif", d: `Nilai sekarang: ${s.genieCidr || "(kosong)"}. Jalankan genieacs-virtualip.sh.` };
  v.innerHTML = `
    <div class="ph"><div><h1>Pengaturan</h1><p>Data VPS yang dipakai untuk membuat script MikroTik.</p></div></div>
    <div class="card"><div class="ch"><h2>VPS</h2></div><form class="cb" id="vpsForm" style="padding-top:4px">
      <label for="sIp">Alamat VPS</label>
      <input id="sIp" type="text" placeholder="103.20.30.40 atau vpn.domain.com" value="${esc(s.publicIp || "")}">
      <div class="help">Dipakai sebagai <i>connect-to</i> di MikroTik.</div>
      <label class="check"><input id="sIpsec" type="checkbox" ${s.useIpsec ? "checked" : ""}>Pakai IPsec (enkripsi)</label>
      <div class="help" style="margin-top:0">Setelah diubah, pasang ulang script di semua MikroTik.</div>
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
    try { await api("/api/settings", { method: "PUT", body: { publicIp: $("#sIp").value, useIpsec: $("#sIpsec").checked } }); await load(); route(); toast(changed ? "Disimpan. Pasang ulang script di semua MikroTik." : "Pengaturan disimpan"); }
    catch (err) { $("#vpsErr").textContent = err.message; }
  };
  $("#tunForm").onsubmit = (e) => {
    e.preventDefault(); $("#tErr").textContent = "";
    const val = $("#tNet").value.trim();
    if (!val) { $("#tErr").textContent = "Isi jaringan VPN baru."; return; }
    modal("Ganti jaringan VPN?", `<p>Dari <b>${esc(s.tunnelNet)}</b> ke <b>${esc(val)}</b>. Semua VPN terputus sebentar, script di ${STATE.sites.length} MikroTik harus dipasang ulang, dan URL ACS di semua ONT berubah.</p><div class="err" id="tErr2"></div>`,
      `<button class="btn" data-act="closemodal">Batal</button><button class="btn danger" id="ok">Ganti</button>`);
    $("#ok").onclick = async () => {
      try { await api("/api/settings", { method: "PUT", body: { tunnelNet: val } }); await load(); route(); toast(`Jaringan VPN sekarang ${STATE.settings.tunnelNet}. Pasang ulang semua script.`); }
      catch (err) { $("#tErr2").textContent = err.message; }
    };
  };
  $("#pwForm").onsubmit = async (e) => {
    e.preventDefault(); $("#pwErr").textContent = "";
    try { await api("/api/settings", { method: "PUT", body: { oldPassword: $("#pOld").value, newPassword: $("#pNew").value } }); $("#pOld").value = ""; $("#pNew").value = ""; toast("Password diganti"); }
    catch (err) { $("#pwErr").textContent = err.message; }
  };
}

/* ================= Aksi global ================= */
document.addEventListener("click", async (e) => {
  const cp = e.target.closest("[data-copy]");
  if (cp) { e.preventDefault(); copyText(cp.dataset.copy, cp.dataset.msg || undefined); return; }
  const go = e.target.closest("[data-go]");
  if (go) { if (location.hash === go.dataset.go || (go.dataset.go === "#/" && !location.hash)) route(); else location.hash = go.dataset.go; return; }
  const fl = e.target.closest("[data-filter]");
  if (fl) { LIST.f = fl.dataset.filter; document.querySelectorAll("[data-filter]").forEach((c) => c.classList.toggle("on", c === fl)); fillList(); return; }
  const a = e.target.closest("[data-act]");
  const menu = $("#menuList");
  if (menu && !e.target.closest(".menu")) menu.classList.add("hidden");
  if (!a) return;
  const act = a.dataset.act;
  const cur = (location.hash.match(/^#\/lokasi\/([a-f0-9]{12})/) || [])[1];
  if (act === "theme") toggleTheme();
  else if (act === "opennav") document.body.classList.add("nav-open");
  else if (act === "closenav") document.body.classList.remove("nav-open");
  else if (act === "closemodal") closeModal();
  else if (act === "logout") { await api("/api/logout", { method: "POST" }).catch(() => {}); LOADED = false; showLogin(); }
  else if (act === "refresh") { await load(); route(); toast("Status diperbarui"); }
  else if (act === "add") openAdd();
  else if (act === "menu") $("#menuList").classList.toggle("hidden");
  else if (act === "edit") openEdit(a.dataset.id);
  else if (act === "resetpw") openResetPw(a.dataset.id);
  else if (act === "del") openDelete(a.dataset.id);
  else if (act === "showpw") { const x = site(cur); const el = $("#pwv"); el.textContent = el.textContent.startsWith("•") ? x.password : "••••••••••••"; }
  else if (act === "addfwd") fwdForm(site(cur));
  else if (act === "delfwd") {
    modal("Hapus akses remote?", `<p>Alamat remote ini tidak bisa dipakai lagi.</p>`, `<button class="btn" data-act="closemodal">Batal</button><button class="btn danger" id="ok">Hapus</button>`);
    $("#ok").onclick = async () => { await api(`/api/sites/${cur}/forwards/${a.dataset.fid}`, { method: "DELETE" }); await load(); route(); toast("Akses remote dihapus"); };
  }
  else if (act === "runtest") runTest();
});
document.addEventListener("keydown", (e) => { if (e.key === "Escape") { closeModal(); const m = $("#menuList"); if (m) m.classList.add("hidden"); } });

/* ================= Mulai ================= */
paintIcons();
(async () => {
  try {
    const me = await api("/api/me");
    if (me.loggedIn) { showApp(); await load(); route(); } else showLogin();
  } catch (e) { showLogin(); }
  setInterval(async () => {
    if ($("#appView").classList.contains("hidden") || $("#mbg") || (TEST && TEST.running)) return;
    const h = location.hash;
    try { await load(); if (!/\/(tes|remote)$/.test(h) && !document.activeElement.matches("input")) route(); } catch (e) {}
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
echo
ok "Panel VPN ACS berjalan"
echo -e "   Buka di browser: ${GREEN}http://${PUBIP}:${PANEL_PORT}${NC}"
echo "   (Jika IP di atas bukan IP publik, pakai IP publik VPS Anda)"
