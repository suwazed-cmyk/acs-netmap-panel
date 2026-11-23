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
