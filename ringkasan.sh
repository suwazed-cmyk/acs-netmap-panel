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
#  dan pasang-ztnet.sh, jadi ringkasannya selalu lengkap walaupun
#  komponen dipasang di hari yang berbeda.
# =====================================================================

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; DIM='\033[2m'; BOLD='\033[1m'; NC='\033[0m'

PANEL_DIR="/opt/vpn-acs"
PANEL_DATA="$PANEL_DIR/data.json"
PANEL_PORT="8088"
GENIE_ENV="/opt/genieacs/genieacs.env"
ZTNET_DIR="/opt/ztnet"
ZTNET_PORT="3300"
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
    else if (k === "ztnetUrl") v = s.ztnetUrl || "";
    else if (k === "httpsDomain") v = cf.https ? cf.domain || "" : "";
    else if (k === "panelName") v = s.panelName || "VPN ACS";
    else if (k === "useIpsec") v = s.useIpsec ? "1" : "";
    else if (k === "sites") v = String((d.sites || []).length);
    else if (k === "ztNet") v = s.zt && s.zt.nwid ? `${s.zt.name || s.zt.nwid} (${s.zt.subnet || "-"})` : "";
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
  if ss -Hltnp 2>/dev/null | grep -E '[:.]80[[:space:]]' | grep -q node; then STD=1; else STD=""; fi
  if [ -n "$HTTPS_DOM" ]; then
    if [ -n "$STD" ]; then PANEL_URL="https://${HTTPS_DOM}"; else PANEL_URL="https://${HTTPS_DOM}:${PANEL_PORT}"; fi
  else
    if [ -n "$STD" ]; then PANEL_URL="http://${VPS_ADDR}"; else PANEL_URL="http://${VPS_ADDR}:${PANEL_PORT}"; fi
  fi
  line "Status" "$(badge "$(svc_state vpn-acs)")"
  line "Alamat web" "${GREEN}${PANEL_URL}${NC}"
  if [ -n "$STD" ]; then
    line "Cadangan" "port ${PANEL_PORT} tetap bisa dipakai"
  else
    line "Port 80/443" "${YELLOW}tidak aktif${NC} (dipakai aplikasi lain atau dimatikan di Pengaturan)"
  fi
  line "Nama panel" "$(panel_get panelName)"
  line "Router" "$(panel_get sites) terdaftar"
  if [ "$(panel_get defaultPw)" = "1" ]; then
    line "Password" "${RED}${DEFAULT_ADMIN_PW}${NC} (bawaan! SEGERA ganti di Pengaturan → Umum)"
  else
    line "Password" "sesuai yang Anda buat"
  fi
  TCP_OPEN+=("80|Panel (http)")
  TCP_OPEN+=("443|Panel (https)")
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

# ---------- ZeroTier / ZTNET (opsional) ----------
head1 "ZeroTier + ZTNET (opsional)"
if [ -d "$ZTNET_DIR" ] || svc_exists zerotier-one; then
  ZT_URL="$(panel_get ztnetUrl)"
  if [ -z "$ZT_URL" ] && [ -f "$ZTNET_DIR/.env" ]; then
    ZT_URL="$(grep -oP '^NEXTAUTH_URL=\K.*' "$ZTNET_DIR/.env" 2>/dev/null | tr -d '"' | tr -d "'")"
  fi
  ZT_URL="${ZT_URL:-http://${VPS_ADDR}:${ZTNET_PORT}}"
  line "ZeroTier" "$(badge "$(svc_state zerotier-one)")"
  if [ -d "$ZTNET_DIR" ]; then
    line "ZTNET" "$(badge "$(svc_state ztnet)")"
    line "Alamat web" "${GREEN}${ZT_URL}${NC}"
    TCP_OPEN+=("${ZTNET_PORT}|Web ZTNET")
  else
    line "ZTNET" "${DIM}belum dipasang${NC}"
  fi
  ZTN="$(panel_get ztNet)"
  if [ -n "$ZTN" ]; then line "Jaringan panel" "$ZTN"
  elif [ -f "$PANEL_DIR/server.js" ]; then line "Jaringan panel" "${YELLOW}belum dihubungkan${NC} (panel → menu ZeroTier)"; fi
  UDP_OPEN+=("9993|ZeroTier")
else
  line "Status" "${DIM}belum dipasang${NC} (tidak wajib, hanya untuk router RouterOS v7 ARM/ARM64)"
  MISSING+=("ZeroTier + ZTNET   : bash pasang-ztnet.sh   (opsional)")
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
