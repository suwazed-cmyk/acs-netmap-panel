#!/bin/bash
# =====================================================================
#  Tes semua layanan ACS NETMAP Panel
#  Memeriksa layanan yang tampil di ringkasan.sh benar-benar berjalan:
#  status service, port terbuka, web menjawab, patch aktif, dan lainnya.
#
#  Pemakaian (sebagai root):
#    bash cek.sh
#
#  Hasil: [OK] berjalan normal, [PERINGATAN] berjalan tapi perlu dicek,
#         [GAGAL] tidak berjalan. Kode keluar 1 jika ada yang GAGAL.
# =====================================================================

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; DIM='\033[2m'; BOLD='\033[1m'; NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PANEL_DIR="/opt/vpn-acs"
PANEL_DATA="$PANEL_DIR/data.json"
PANEL_PORT="8088"
GENIE_ENV="/opt/genieacs/genieacs.env"
GENIE_PATCH_DIR="/opt/genieacs-app"
ZTNET_DIR="/opt/ztnet"
ZTNET_PORT="3300"
DEFAULT_ADMIN_PW="Admin123"
NODE_BIN="$(command -v node || true)"

N_OK=0; N_WARN=0; N_FAIL=0; N_SKIP=0
ok()   { N_OK=$((N_OK+1));     echo -e "   ${GREEN}[OK]${NC}         $1"; }
warn() { N_WARN=$((N_WARN+1)); echo -e "   ${YELLOW}[PERINGATAN]${NC} $1"; [ -n "${2:-}" ] && echo -e "                ${DIM}→ $2${NC}"; }
bad()  { N_FAIL=$((N_FAIL+1)); echo -e "   ${RED}[GAGAL]${NC}      $1"; [ -n "${2:-}" ] && echo -e "                ${DIM}→ $2${NC}"; }
skip() { N_SKIP=$((N_SKIP+1)); echo -e "   ${DIM}[LEWATI]     $1${NC}"; }
head1() { echo; echo -e "${BOLD}${CYAN}$1${NC}"; }

[ "$(id -u)" -eq 0 ] || { echo "Jalankan sebagai root: sudo bash $0"; exit 1; }

svc_exists() { systemctl list-unit-files "$1.service" --no-legend 2>/dev/null | grep -q "^$1.service"; }
# Tes service aktif: cek_svc NAMA LABEL
cek_svc() {
  local st; st="$(systemctl is-active "$1" 2>/dev/null)"
  if [ "$st" = "active" ]; then ok "$2 berjalan ($1)"
  else bad "$2 tidak berjalan ($1: ${st:-tidak ada})" "journalctl -u $1 -n 50 --no-pager"; fi
}
# Alamat yang mendengarkan port TCP/UDP (kosong jika tidak ada)
listen_tcp() { ss -Hlnt 2>/dev/null | awk '{print $4}' | grep -E "[:.]$1$" | head -1; }
listen_udp() { ss -Hlnu 2>/dev/null | awk '{print $4}' | grep -E "[:.]$1$" | head -1; }
cek_tcp() {
  local a; a="$(listen_tcp "$1")"
  if [ -n "$a" ]; then ok "Port TCP $1 terbuka ($2, $a)"; else bad "Port TCP $1 tidak terbuka ($2)" "${3:-cek service-nya}"; fi
}
cek_udp() {
  local a; a="$(listen_udp "$1")"
  if [ -n "$a" ]; then ok "Port UDP $1 terbuka ($2)"; else bad "Port UDP $1 tidak terbuka ($2)" "${3:-cek service-nya}"; fi
}
# Kode HTTP dari alamat lokal (000 = tidak menjawab)
http_code() { curl --noproxy '*' -sk -o /dev/null -m 8 -w '%{http_code}' "$1" 2>/dev/null || true; }
cek_web() {
  local c; c="$(http_code "$1")"
  case "$c" in
    2??|3??) ok "$2 menjawab ($1 → HTTP $c)" ;;
    000|"")  bad "$2 tidak menjawab ($1)" "${3:-cek service-nya}" ;;
    *)       warn "$2 menjawab dengan HTTP $c ($1)" "${3:-cek log service-nya}" ;;
  esac
}
panel_get() {
  [ -n "$NODE_BIN" ] && [ -f "$PANEL_DATA" ] || return 0
  "$NODE_BIN" -e '
    let d = {};
    try { d = require(process.argv[1]); } catch (e) { process.exit(0); }
    const s = d.settings || {}, cf = s.cloudflare || {}, k = process.argv[2];
    let v = "";
    if (k === "publicIp") v = s.publicIp || "";
    else if (k === "httpsDomain") v = cf.https ? cf.domain || "" : "";
    else if (k === "cfDomain") v = cf.domain || "";
    else if (k === "useIpsec") v = s.useIpsec ? "1" : "";
    else if (k === "ztNwid") v = (s.zt && s.zt.nwid) || "";
    else if (k === "subHosts") v = Object.values(s.subdomains || {}).map((x) => x && x.host).filter(Boolean).join(" ");
    else if (k === "sites") v = String((d.sites || []).length);
    else if (k === "defaultPw") {
      const a = d.admin, c = require("crypto");
      v = a && a.salt && a.hash && c.scryptSync(process.argv[3], a.salt, 64).toString("hex") === a.hash ? "1" : "";
    }
    process.stdout.write(String(v));
  ' "$PANEL_DATA" "$1" "$DEFAULT_ADMIN_PW" 2>/dev/null
}

# IP publik VPS (untuk cek DNS domain)
VPS_IP="$(curl -4 -s -m 5 https://api.ipify.org 2>/dev/null || true)"
echo "$VPS_IP" | grep -qE '^[0-9]+(\.[0-9]+){3}$' || VPS_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"

echo
echo -e "${BOLD}=====================================================================${NC}"
echo -e "${BOLD}  TES LAYANAN ACS NETMAP PANEL${NC}"
echo -e "${BOLD}=====================================================================${NC}"

# ---------- Sistem ----------
head1 "Sistem"
if [ "$(sysctl -n net.ipv4.ip_forward 2>/dev/null)" = "1" ]; then ok "IP forwarding aktif"
else bad "IP forwarding mati (VPN dan NETMAP tidak jalan)" "sysctl -w net.ipv4.ip_forward=1"; fi
if curl -s -o /dev/null -m 6 https://api.telegram.org; then ok "VPS bisa keluar ke internet (Telegram, Cloudflare, Let's Encrypt)"
else warn "VPS tidak bisa menjangkau api.telegram.org" "Notifikasi Telegram dan pengaturan domain tidak akan jalan"; fi
if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
  warn "ufw menyala (bisa bentrok dengan aturan VPN)" "ufw disable, lalu buka port di firewall provider"
fi
MEM_FREE=$(awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo 2>/dev/null)
DISK_FREE=$(df -Pm / 2>/dev/null | awk 'NR==2{print $4}')
[ -n "$MEM_FREE" ] && { [ "$MEM_FREE" -ge 200 ] && ok "RAM tersedia ${MEM_FREE} MB" || warn "RAM tersedia tinggal ${MEM_FREE} MB" "Pertimbangkan swap atau VPS lebih besar"; }
[ -n "$DISK_FREE" ] && { [ "$DISK_FREE" -ge 2048 ] && ok "Disk kosong $((DISK_FREE/1024)) GB" || warn "Disk kosong tinggal ${DISK_FREE} MB" "Bersihkan log: journalctl --vacuum-size=200M"; }

# ---------- Panel ----------
head1 "Panel VPN ACS"
if [ -f "$PANEL_DIR/server.js" ]; then
  cek_svc vpn-acs "Panel"
  cek_tcp "$PANEL_PORT" "panel" "journalctl -u vpn-acs -n 50 --no-pager"
  c="$(http_code "http://127.0.0.1:${PANEL_PORT}/api/me")"
  case "$c" in
    200) ok "Panel menjawab (HTTP)" ;;
    301|308) ok "Panel menjawab (dialihkan ke HTTPS)" ;;
    *) bad "Panel tidak menjawab di port ${PANEL_PORT} (HTTP ${c:-000})" "journalctl -u vpn-acs -n 50 --no-pager" ;;
  esac
  if ss -Hltnp 2>/dev/null | grep -E '[:.]80[[:space:]]' | grep -q node; then ok "Panel juga di port 80/443 (alamat tanpa port)"
  else
    who="$(ss -Hltnp 2>/dev/null | grep -E '[:.]80[[:space:]]' | grep -oP 'users:\(\("\K[^"]+' | head -1)"
    if [ -n "$who" ]; then warn "Port 80 dipakai ${who}, panel hanya di port ${PANEL_PORT}" "Hentikan ${who} (systemctl disable --now ${who}), lalu systemctl restart vpn-acs"
    else warn "Panel tidak memakai port 80/443" "Aktifkan di Pengaturan → Umum → Alamat tanpa port"; fi
  fi
  HTTPS_DOM="$(panel_get httpsDomain)"
  if [ -n "$HTTPS_DOM" ]; then
    cek_web "https://127.0.0.1:${PANEL_PORT}/api/me" "Panel HTTPS"
    CERT="/etc/letsencrypt/live/${HTTPS_DOM}/cert.pem"
    if [ -f "$CERT" ]; then
      END="$(openssl x509 -enddate -noout -in "$CERT" 2>/dev/null | cut -d= -f2)"
      DAYS=$(( ( $(date -d "$END" +%s 2>/dev/null || echo 0) - $(date +%s) ) / 86400 ))
      if [ "$DAYS" -ge 14 ]; then ok "Sertifikat HTTPS ${HTTPS_DOM} berlaku ${DAYS} hari lagi"
      elif [ "$DAYS" -ge 0 ]; then warn "Sertifikat HTTPS tinggal ${DAYS} hari" "certbot renew --cert-name ${HTTPS_DOM}"
      else bad "Sertifikat HTTPS sudah habis" "certbot renew --cert-name ${HTTPS_DOM}"; fi
    else
      bad "Sertifikat HTTPS ${HTTPS_DOM} tidak ditemukan" "Ulangi Pengaturan → Domain & HTTPS di panel"
    fi
  fi
  perm="$(stat -c %a "$PANEL_DATA" 2>/dev/null)"
  if [ "$perm" = "600" ]; then ok "data.json terlindungi (izin 600)"
  elif [ -n "$perm" ]; then warn "Izin data.json $perm (seharusnya 600)" "chmod 600 $PANEL_DATA"
  else bad "data.json tidak ada" "bash install-vpn-acs.sh"; fi
  if [ "$(panel_get defaultPw)" = "1" ]; then warn "Password admin masih bawaan ${DEFAULT_ADMIN_PW}" "Ganti di panel: Pengaturan → Umum → Password admin"
  else ok "Password admin sudah diganti"; fi
  miss=""
  for ch in "nat VPNACS_PRE" "nat VPNACS_POST" "filter VPNACS_FWD"; do
    set -- $ch
    iptables -t "$1" -nL "$2" >/dev/null 2>&1 || miss+=" $2"
  done
  if [ -z "$miss" ]; then ok "Aturan iptables panel terpasang (NETMAP & port forwarding)"
  else bad "Aturan iptables panel tidak lengkap:$miss" "systemctl restart vpn-acs"; fi
  for h in $(panel_get cfDomain) $(panel_get subHosts); do
    ip="$(getent ahostsv4 "$h" 2>/dev/null | awk 'NR==1{print $1}')"
    if [ -z "$ip" ]; then bad "Domain $h tidak bisa di-resolve" "Cek record DNS di Cloudflare"
    elif [ -n "$VPS_IP" ] && [ "$ip" != "$VPS_IP" ]; then warn "Domain $h mengarah ke $ip, bukan $VPS_IP" "Pastikan record A tidak di-proxy (awan abu-abu) dan IP-nya benar"
    else ok "Domain $h mengarah ke VPS ($ip)"; fi
  done
else
  skip "Panel belum dipasang (bash install-vpn-acs.sh)"
fi

# ---------- L2TP ----------
head1 "VPN L2TP"
if svc_exists xl2tpd; then
  cek_svc xl2tpd "Server L2TP"
  cek_udp 1701 "L2TP" "systemctl restart xl2tpd"
  if [ "$(panel_get useIpsec)" = "1" ]; then
    cek_svc ipsec "IPsec"
    cek_udp 500 "IPsec"; cek_udp 4500 "IPsec NAT-T"
  fi
  PEERS=$(ip -o -4 addr show 2>/dev/null | awk '$2 ~ /^ppp/' | wc -l)
  SITES="$(panel_get sites)"
  if [ -n "$SITES" ] && [ "$SITES" != "0" ]; then
    ok "Router tersambung lewat L2TP: ${PEERS} (terdaftar di panel: ${SITES})"
  else
    ok "Router tersambung lewat L2TP: ${PEERS}"
  fi
else
  skip "L2TP belum dipasang (README langkah 3)"
fi

# ---------- GenieACS ----------
head1 "GenieACS"
if [ -f "$GENIE_ENV" ] || svc_exists genieacs-cwmp; then
  cek_svc mongod "MongoDB"
  for s in cwmp nbi fs ui; do cek_svc "genieacs-$s" "GenieACS $s"; done
  UI_PORT="$(grep -oP '^GENIEACS_UI_PORT=\K[0-9]+' "$GENIE_ENV" 2>/dev/null)"; UI_PORT="${UI_PORT:-3000}"
  CWMP_PORT="$(grep -oP '^GENIEACS_CWMP_PORT=\K[0-9]+' "$GENIE_ENV" 2>/dev/null)"; CWMP_PORT="${CWMP_PORT:-7547}"
  NBI_PORT="$(grep -oP '^GENIEACS_NBI_PORT=\K[0-9]+' "$GENIE_ENV" 2>/dev/null)"; NBI_PORT="${NBI_PORT:-7557}"
  cek_tcp "$CWMP_PORT" "CWMP, tujuan Inform ONT"
  cek_tcp "$UI_PORT" "GenieACS UI"
  cek_web "http://127.0.0.1:${UI_PORT}/" "GenieACS UI"
  a="$(listen_tcp "$NBI_PORT")"
  if [ -z "$a" ]; then bad "NBI port $NBI_PORT tidak terbuka (panel tidak bisa membaca ONT)" "journalctl -u genieacs-nbi -n 50 --no-pager"
  elif echo "$a" | grep -qE '^127\.0\.0\.1:|^\[::1\]:'; then ok "NBI hanya untuk lokal ($a)"
  else warn "NBI terbuka untuk semua alamat ($a)" "Isi GENIEACS_NBI_INTERFACE=127.0.0.1 di $GENIE_ENV (README langkah 4)"; fi
  c="$(http_code "http://127.0.0.1:${NBI_PORT}/devices/?projection=_id&limit=1")"
  if [ "$c" = "200" ]; then
    N_DEV="$(curl --noproxy '*' -s -m 8 "http://127.0.0.1:${NBI_PORT}/devices/?projection=_id" 2>/dev/null | grep -o '"_id"' | wc -l)"
    ok "NBI menjawab, ONT terdaftar di GenieACS: ${N_DEV}"
  else
    bad "NBI tidak menjawab (HTTP ${c:-000})" "journalctl -u genieacs-nbi -n 50 --no-pager"
  fi
  JWT="$(grep -oP '^GENIEACS_UI_JWT_SECRET=\K.*' "$GENIE_ENV" 2>/dev/null)"
  if [ "${#JWT}" -ge 32 ]; then ok "JWT secret GenieACS sudah diganti"
  else warn "JWT secret GenieACS masih bawaan" "README langkah 4: Perbaikan keamanan"; fi
  CIDR="$(grep -oP '^GENIEACS_CR_USE_REMOTE_ADDRESS=\K.*' "$GENIE_ENV" 2>/dev/null)"
  # ExecStart bisa berupa "/usr/bin/node /opt/genieacs-app/bin/genieacs-cwmp": cek seluruh baris
  EXE="$(grep '^ExecStart=' /etc/systemd/system/genieacs-cwmp.service 2>/dev/null)"
  if [ -n "$CIDR" ] && echo "$EXE" | grep -q "$GENIE_PATCH_DIR/"; then ok "Patch IP virtual aktif ($CIDR)"
  elif [ -n "$CIDR" ]; then bad "Setting IP virtual ada, tapi GenieACS belum memakai versi patch" "bash genieacs-virtualip.sh"
  else bad "Patch IP virtual belum aktif (Summon ke ONT akan gagal)" "bash genieacs-virtualip.sh"; fi
else
  skip "GenieACS belum dipasang (README langkah 4)"
fi

# ---------- ZeroTier / ZTNET ----------
head1 "ZeroTier + ZTNET (opsional)"
if [ -d "$ZTNET_DIR" ] || svc_exists zerotier-one; then
  cek_svc zerotier-one "ZeroTier"
  cek_udp 9993 "ZeroTier"
  if command -v zerotier-cli >/dev/null; then
    INFO="$(zerotier-cli info 2>/dev/null)"
    if echo "$INFO" | grep -q ONLINE; then ok "ZeroTier online ($(echo "$INFO" | awk '{print $3}'))"
    else warn "ZeroTier belum ONLINE (${INFO:-tidak ada jawaban})" "Pastikan UDP 9993 dibuka di firewall provider"; fi
    NW="$(panel_get ztNwid)"
    if [ -n "$NW" ]; then
      L="$(zerotier-cli listnetworks 2>/dev/null | grep " $NW ")"
      if echo "$L" | grep -q " OK "; then ok "VPS tergabung di jaringan $NW"
      else bad "VPS belum tergabung di jaringan $NW" "Panel → menu ZeroTier → Hubungkan VPS"; fi
    elif [ -f "$PANEL_DIR/server.js" ]; then
      warn "Jaringan ZeroTier belum dihubungkan ke panel" "Panel → menu ZeroTier → pilih jaringan → Hubungkan VPS"
    fi
  fi
  if [ -d "$ZTNET_DIR" ]; then
    svc_exists postgresql && cek_svc postgresql "Database ZTNET (PostgreSQL)"
    cek_svc ztnet "ZTNET"
    cek_tcp "$ZTNET_PORT" "web ZTNET" "journalctl -u ztnet -n 50 --no-pager"
    cek_web "http://127.0.0.1:${ZTNET_PORT}/" "Web ZTNET" "journalctl -u ztnet -n 50 --no-pager"
  else
    skip "ZTNET belum dipasang (bash pasang-ztnet.sh)"
  fi
else
  skip "ZeroTier belum dipasang (opsional: bash pasang-ztnet.sh)"
fi

# ---------- Hasil ----------
echo
echo -e "${BOLD}=====================================================================${NC}"
SKIPTXT=""; [ "$N_SKIP" -gt 0 ] && SKIPTXT=", ${N_SKIP} dilewati (belum dipasang)"
echo -e "  Hasil: ${GREEN}${N_OK} OK${NC}, ${YELLOW}${N_WARN} peringatan${NC}, ${RED}${N_FAIL} gagal${NC}${SKIPTXT}"
if [ "$N_FAIL" -eq 0 ]; then
  echo -e "  ${GREEN}Semua layanan yang terpasang berjalan.${NC}"
else
  echo -e "  ${RED}Ada layanan yang belum berjalan.${NC} Ikuti petunjuk → di bawah tiap baris GAGAL."
fi
echo -e "  ${DIM}Tes ini dijalankan dari dalam VPS. Port yang dibuka di firewall provider${NC}"
echo -e "  ${DIM}perlu dicek dari luar, misalnya buka alamat web panel dari HP/PC Anda.${NC}"
echo -e "  ${DIM}Alamat web dan port: bash ${SCRIPT_DIR}/ringkasan.sh${NC}"
echo -e "${BOLD}=====================================================================${NC}"
echo
[ "$N_FAIL" -eq 0 ]
