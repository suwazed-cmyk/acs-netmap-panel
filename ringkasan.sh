#!/bin/bash
# =====================================================================
#  Ringkasan instalasi ACS NETMAP Panel
#  Menampilkan semua layanan yang terpasang di VPS ini beserta alamat web,
#  port, status, dan port yang harus dibuka di firewall provider.
#
#  Pemakaian:
#    bash ringkasan.sh
#
#  Otomatis dijalankan di akhir install-vpn-acs.sh, genieacs-virtualip.sh,
#  dan add-on, jadi ringkasannya selalu lengkap walaupun
#  komponen dipasang di hari yang berbeda.
# =====================================================================

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; DIM='\033[2m'; BOLD='\033[1m'; NC='\033[0m'

PANEL_DIR="/opt/vpn-acs"
PANEL_DATA="$PANEL_DIR/data.json"
PANEL_PORT="8088"
GENIE_ENV="/opt/genieacs/genieacs.env"
ZTNET_DIR="/opt/ztnet"
DEFAULT_ADMIN_PW="Admin123"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

NODE_BIN="$(command -v node || true)"

# ---------- Utilitas ----------
svc_state() { systemctl is-active "$1" 2>/dev/null || true; }
svc_exists() { systemctl list-unit-files "$1.service" --no-legend 2>/dev/null | grep -q "^$1.service"; }
badge() {
  case "$1" in
    active) echo -e "${GREEN}berjalan${NC}" ;;
    "")     echo -e "${DIM}tidak ada${NC}" ;;
    *)      echo -e "${RED}$1${NC}" ;;
  esac
}
line() { printf "   %-16s %b\n" "$1" "$2"; }
head1() { echo; echo -e "${BOLD}${CYAN}$1${NC}"; }

# Baca nilai dari data.json panel (kosong jika panel belum terpasang)
panel_get() {
  [ -n "$NODE_BIN" ] && [ -f "$PANEL_DATA" ] || return 0
  "$NODE_BIN" -e '
    let d = {};
    try { d = require(process.argv[1]); } catch (e) { process.exit(0); }
    const s = d.settings || {};
    const cf = s.cloudflare || {};
    const k = process.argv[2];
    let v = "";
    if (k === "publicIp") v = s.publicIp || "";
    else if (k === "genieUrl") v = s.genieUrl || "";
    else if (k === "httpsDomain") v = cf.https ? cf.domain || "" : "";
    else if (k === "panelName") v = s.panelName || "VPN ACS";
    else if (k === "useIpsec") v = s.useIpsec ? "1" : "";
    else if (k === "sites") v = String((d.sites || []).length);
    else if (k === "stdHttp") v = String(s.stdHttp || 80);
    else if (k === "stdHttps") v = String(s.stdHttps || 443);
    else if (k === "ztNet") v = s.zt && s.zt.nwid ? `${s.zt.name || s.zt.nwid} (${s.zt.subnet || "-"})` : "";
    else if (k === "wgOn") v = s.addons && s.addons.wireguard && s.addons.wireguard.installed ? "1" : "";
    else if (k === "wgNet") v = s.wg ? `${s.wg.subnet} · VPS ${s.wg.vpsIp} · UDP ${s.wg.port}` : "";
    else if (k === "wgPort") v = s.wg ? String(s.wg.port || 51820) : "";
    else if (k === "wgSites") v = String((d.sites || []).filter((x) => x.transport === "wg").length);
    else if (k === "healthOn") v = !s.health || s.health.enabled !== false ? `tiap ${(s.health && s.health.days) || 7} hari jam ${(s.health && s.health.time) || "08:00"}` : "nonaktif";
    else if (k === "idleMin") v = String((s.security && s.security.idleMin) || 60);
    else if (k === "tunnelLocal") {
      const net = s.tunnelNet || "192.168.42.0/24";
      const p = net.split("/")[0].split(".").map(Number);
      v = p.length === 4 ? `${p[0]}.${p[1]}.${p[2]}.${p[3] + 1}` : "192.168.42.1";
    } else if (k === "defaultPw") {
      const a = d.admin, c = require("crypto");
      v = a && a.salt && a.hash && c.scryptSync(process.argv[3], a.salt, 64).toString("hex") === a.hash ? "1" : "";
    }
    process.stdout.write(String(v));
  ' "$PANEL_DATA" "$1" "$DEFAULT_ADMIN_PW" 2>/dev/null
}

# ---------- Alamat VPS ----------
VPS_ADDR="$(panel_get publicIp)"
if [ -z "$VPS_ADDR" ]; then
  VPS_ADDR="$(curl -4 -s --max-time 4 https://api.ipify.org 2>/dev/null || true)"
  echo "$VPS_ADDR" | grep -qE '^[0-9]+(\.[0-9]+){3}$' || VPS_ADDR=""
fi
[ -n "$VPS_ADDR" ] || VPS_ADDR="$(hostname -I 2>/dev/null | awk '{print $1}')"
[ -n "$VPS_ADDR" ] || VPS_ADDR="IP_VPS"

TCP_OPEN=(); UDP_OPEN=()
MISSING=()

echo
echo -e "${BOLD}=====================================================================${NC}"
echo -e "${BOLD}  RINGKASAN INSTALASI ACS NETMAP PANEL${NC}"
echo -e "${BOLD}=====================================================================${NC}"
line "Alamat VPS" "${BOLD}${VPS_ADDR}${NC}"
line "Sistem" "$(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-Linux}")"

# ---------- Panel ----------
head1 "Panel VPN ACS"
if [ -f "$PANEL_DIR/server.js" ]; then
  HTTPS_DOM="$(panel_get httpsDomain)"
  # Panel memakai port 80/443 bila tidak dipakai aplikasi lain (bawaan), selain port 8088
  SP_HTTP="$(panel_get stdHttp)"; SP_HTTP="${SP_HTTP:-80}"; SP_HTTPS="$(panel_get stdHttps)"; SP_HTTPS="${SP_HTTPS:-443}"
  if ss -Hltnp 2>/dev/null | grep -E "[:.]${SP_HTTP}[[:space:]]" | grep -q node; then STD=1; else STD=""; fi
  SFX_HTTP=""; [ "$SP_HTTP" != "80" ] && SFX_HTTP=":$SP_HTTP"
  SFX_HTTPS=""; [ "$SP_HTTPS" != "443" ] && SFX_HTTPS=":$SP_HTTPS"
  if [ -n "$HTTPS_DOM" ]; then
    if [ -n "$STD" ]; then PANEL_URL="https://${HTTPS_DOM}${SFX_HTTPS}"; else PANEL_URL="https://${HTTPS_DOM}:${PANEL_PORT}"; fi
  else
    if [ -n "$STD" ]; then PANEL_URL="http://${VPS_ADDR}${SFX_HTTP}"; else PANEL_URL="http://${VPS_ADDR}:${PANEL_PORT}"; fi
  fi
  line "Status" "$(badge "$(svc_state vpn-acs)")"
  line "Alamat web" "${GREEN}${PANEL_URL}${NC}"
  if [ -n "$STD" ]; then
    line "Cadangan" "port ${PANEL_PORT} tetap bisa dipakai"
  else
    line "Port ${SP_HTTP}/${SP_HTTPS}" "${YELLOW}tidak aktif${NC} (dipakai aplikasi lain atau dimatikan di Pengaturan)"
  fi
  line "Nama panel" "$(panel_get panelName)"
  line "Router" "$(panel_get sites) terdaftar"
  if [ "$(panel_get defaultPw)" = "1" ]; then
    line "Password" "${RED}${DEFAULT_ADMIN_PW}${NC} (bawaan! SEGERA ganti di Pengaturan → Umum)"
  else
    line "Password" "sesuai yang Anda buat"
  fi
  TCP_OPEN+=("${SP_HTTP}|Panel (http)")
  TCP_OPEN+=("${SP_HTTPS}|Panel (https)")
  TCP_OPEN+=("${PANEL_PORT}|Panel VPN ACS (cadangan)")
else
  line "Status" "${DIM}belum dipasang${NC}"
  MISSING+=("Panel VPN ACS      : bash install-vpn-acs.sh")
fi

# ---------- L2TP ----------
head1 "VPN L2TP"
if svc_exists xl2tpd; then
  line "Status" "$(badge "$(svc_state xl2tpd)")"
  line "Server" "${VPS_ADDR}"
  if [ "$(panel_get useIpsec)" = "1" ]; then
    line "Mode" "L2TP + IPsec"
    UDP_OPEN+=("500|IPsec" "4500|IPsec NAT-T")
  else
    line "Mode" "L2TP tanpa IPsec"
  fi
  UDP_OPEN+=("1701|L2TP")
else
  line "Status" "${DIM}belum dipasang${NC}"
  MISSING+=("VPN L2TP           : lihat README langkah 3 (vpnsetup.sh)")
fi

# ---------- GenieACS ----------
head1 "GenieACS"
if [ -f "$GENIE_ENV" ] || svc_exists genieacs-cwmp; then
  UI_PORT="$(grep -oP '^GENIEACS_UI_PORT=\K[0-9]+' "$GENIE_ENV" 2>/dev/null)"; UI_PORT="${UI_PORT:-3000}"
  CWMP_PORT="$(grep -oP '^GENIEACS_CWMP_PORT=\K[0-9]+' "$GENIE_ENV" 2>/dev/null)"; CWMP_PORT="${CWMP_PORT:-7547}"
  GENIE_URL="$(panel_get genieUrl)"; GENIE_URL="${GENIE_URL:-http://${VPS_ADDR}:${UI_PORT}}"
  st=""
  for s in cwmp nbi fs ui; do
    a="$(svc_state genieacs-$s)"
    [ "$a" = "active" ] && st+="${GREEN}${s}${NC} " || st+="${RED}${s}${NC} "
  done
  line "Layanan" "$st"
  line "MongoDB" "$(badge "$(svc_state mongod)")"
  line "Alamat web" "${GREEN}${GENIE_URL}${NC}"
  TUN_LOCAL="$(panel_get tunnelLocal)"; TUN_LOCAL="${TUN_LOCAL:-192.168.42.1}"
  line "URL ACS di ONT" "http://${TUN_LOCAL}:${CWMP_PORT}  (lewat VPN, ACS user/pass kosong)"
  CIDR="$(grep -oP '^GENIEACS_CR_USE_REMOTE_ADDRESS=\K.*' "$GENIE_ENV" 2>/dev/null)"
  if [ -n "$CIDR" ]; then
    line "Patch IP virtual" "${GREEN}aktif${NC} ($CIDR)"
  else
    line "Patch IP virtual" "${YELLOW}belum aktif${NC}"
    MISSING+=("Patch IP virtual   : bash genieacs-virtualip.sh")
  fi
  TCP_OPEN+=("${UI_PORT}|GenieACS UI")
else
  line "Status" "${DIM}belum dipasang${NC}"
  MISSING+=("GenieACS           : lihat README langkah 4 (genie.sh)")
fi

# ---------- ZeroTier (opsional) ----------
head1 "ZeroTier (opsional)"
if svc_exists zerotier-one; then
  line "ZeroTier" "$(badge "$(svc_state zerotier-one)")"
  line "Pengelolaan" "panel → menu ZeroTier (jaringan, rentang IP, perangkat)"
  ZTN="$(panel_get ztNet)"
  if [ -n "$ZTN" ]; then line "Jaringan panel" "$ZTN"
  elif [ -f "$PANEL_DIR/server.js" ]; then line "Jaringan panel" "${YELLOW}belum ada${NC} (panel → menu ZeroTier → Buat jaringan)"; fi
  [ -d "$ZTNET_DIR" ] && line "ZTNET lama" "${YELLOW}masih terpasang${NC} (panel → menu ZeroTier → Pindahkan & lepas ZTNET)"
  UDP_OPEN+=("9993|ZeroTier")
else
  line "Status" "${DIM}belum dipasang${NC} (tidak wajib, hanya untuk router RouterOS v7 ARM/ARM64)"
  MISSING+=("ZeroTier           : panel → Add-on → ZeroTier → Install   (opsional)")
fi

# ---------- WireGuard (opsional) ----------
head1 "WireGuard (opsional)"
if [ -n "$(panel_get wgOn)" ]; then
  line "WireGuard" "$(badge "$(svc_state wg-quick@wg0)")"
  line "Jaringan" "$(panel_get wgNet)"
  line "Router" "$(panel_get wgSites) router memakai WireGuard"
  line "Pengelolaan" "panel → menu WireGuard"
  WGP="$(panel_get wgPort)"; [ -n "$WGP" ] && UDP_OPEN+=("$WGP|WireGuard")
else
  line "Status" "${DIM}belum dipasang${NC} (tidak wajib, jalur VPN UDP untuk RouterOS v7)"
  MISSING+=("WireGuard          : panel → Add-on → WireGuard → Install  (opsional)")
fi

# ---------- Keamanan & laporan ----------
head1 "Keamanan & laporan"
if [ -f "$PANEL_DATA" ]; then
  line "Logout otomatis" "setelah diam $(panel_get idleMin) menit (panel → Pengaturan → Keamanan)"
  line "Blokir login" "5x salah: 5 menit → 30 menit → 24 jam"
  line "Laporan VPS" "$(panel_get healthOn) (Pengaturan → Notifikasi Telegram)"
fi

# ---------- Firewall ----------
head1 "Port yang harus dibuka di firewall provider VPS"
line "TCP 22" "SSH"
for x in "${TCP_OPEN[@]}"; do line "TCP ${x%%|*}" "${x#*|}"; done
for x in "${UDP_OPEN[@]}"; do line "UDP ${x%%|*}" "${x#*|}"; done
[ -f "$PANEL_DIR/server.js" ] && line "TCP 20001-20999" "Port forwarding router (remote Winbox/web ONT)"
echo -e "   ${DIM}Jangan menyalakan ufw. Port 7547 dan 7557 tidak perlu dibuka.${NC}"

# ---------- Belum dipasang ----------
if [ ${#MISSING[@]} -gt 0 ]; then
  head1 "Belum dipasang"
  for m in "${MISSING[@]}"; do echo "   - $m"; done
  echo -e "   ${DIM}(jalankan dari folder ${REPO_DIR})${NC}"
fi

echo
echo -e "${DIM}Tampilkan ringkasan ini kapan saja: bash ${REPO_DIR}/ringkasan.sh${NC}"
echo -e "${DIM}Tes apakah semua layanan benar-benar berjalan: bash ${REPO_DIR}/cek.sh${NC}"
echo -e "${BOLD}=====================================================================${NC}"
echo
