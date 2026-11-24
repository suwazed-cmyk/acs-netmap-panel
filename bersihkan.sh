#!/bin/bash
# =====================================================================
#  Bersihkan pengaturan suwazed-panel dari VPS
#
#  Pemakaian (sebagai root, dari folder suwazed-panel):
#    bash bersihkan.sh                -> menu pilihan
#    bash bersihkan.sh portforward    -> hapus semua port forwarding saja
#    bash bersihkan.sh panel          -> hapus Panel VPN ACS + akun VPN router + aturan firewall
#    bash bersihkan.sh genieacs       -> kembalikan GenieACS asli (tanpa patch IP virtual)
#    bash bersihkan.sh parameter      -> kembalikan parameter GenieACS dari backup
#    bash bersihkan.sh semua          -> panel + genieacs (+ parameter, ditanyakan)
#
#  Yang TIDAK dihapus: server VPN (xl2tpd/IPsec dari vpnsetup.sh), GenieACS,
#  MongoDB, dan data perangkat ONT.
# =====================================================================

set -uo pipefail
GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'
ok()   { echo -e "${GREEN}[OK]${NC} $*"; }
info() { echo -e "     $*"; }
warn() { echo -e "${YELLOW}[PERHATIAN]${NC} $*"; }
fail() { echo -e "${RED}[GAGAL]${NC} $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || fail "Jalankan sebagai root"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="/opt/vpn-acs"
DATA="$APP_DIR/data.json"
SERVICE="/etc/systemd/system/vpn-acs.service"
CHAP="/etc/ppp/chap-secrets"
ROUTE_SCRIPT="/etc/ppp/ip-up.d/vpn-acs-routes"
XL2TPD_CONF="/etc/xl2tpd/xl2tpd.conf"
SYSCTL_FILE="/etc/sysctl.d/99-vpn-acs.conf"
MARK_BEGIN="# >>> VPN-ACS (dikelola Panel VPN ACS, jangan diedit manual) >>>"
MARK_END="# <<< VPN-ACS <<<"
STAMP="$(date +%Y%m%d-%H%M%S)"

konfirmasi() {
  local jawab
  echo
  echo -e "${YELLOW}$1${NC}"
  read -r -p "Ketik YA untuk melanjutkan: " jawab
  [ "$jawab" = "YA" ] || { echo "Dibatalkan, tidak ada yang diubah."; exit 0; }
}

# ---------- bagian-bagian ----------
hapus_firewall_panel() {
  command -v iptables >/dev/null 2>&1 || { warn "iptables tidak ada, lewati"; return 0; }
  local t
  for t in "nat PREROUTING VPNACS_PRE" "nat POSTROUTING VPNACS_POST" "filter FORWARD VPNACS_FWD"; do
    set -- $t
    while iptables -w -t "$1" -D "$2" -j "$3" 2>/dev/null; do :; done
    iptables -w -t "$1" -F "$3" 2>/dev/null || true
    iptables -w -t "$1" -X "$3" 2>/dev/null || true
  done
  ok "Aturan port forwarding & firewall panel dihapus dari iptables"
}

hapus_aturan_l2tp_polos() {
  command -v iptables >/dev/null 2>&1 || return 0
  while iptables -w -D INPUT -p udp --dport 1701 -m comment --comment vpn-acs-l2tp -j ACCEPT 2>/dev/null; do :; done
  local f
  for f in /etc/iptables.rules /etc/iptables/rules.v4; do
    [ -f "$f" ] && grep -q "vpn-acs-l2tp" "$f" && sed -i '/vpn-acs-l2tp/d' "$f" && ok "Aturan L2TP tanpa IPsec dihapus dari $f"
  done
  ok "Port UDP 1701 untuk L2TP tanpa IPsec ditutup kembali (L2TP/IPsec tetap bisa dipakai)"
}

hapus_route_virtual() {
  [ -f "$DATA" ] || return 0
  command -v node >/dev/null 2>&1 || return 0
  local subnets s
  subnets="$(node -e 'try{const d=JSON.parse(require("fs").readFileSync(process.argv[1]));for(const s of d.sites||[])console.log(s.virtualSubnet)}catch(e){}' "$DATA")"
  for s in $subnets; do ip route del "$s" 2>/dev/null && info "route $s dihapus"; done
  ok "Route IP virtual dihapus"
}

hapus_akun_vpn() {
  if [ -f "$CHAP" ] && grep -qF "$MARK_BEGIN" "$CHAP"; then
    cp "$CHAP" "/root/backup-chap-secrets-$STAMP"
    awk -v b="$MARK_BEGIN" -v e="$MARK_END" '
      $0 == b { skip = 1; next }
      $0 == e { skip = 0; next }
      !skip { print }
    ' "$CHAP" > "$CHAP.tmp" && cat "$CHAP.tmp" > "$CHAP" && rm -f "$CHAP.tmp"
    ok "Akun VPN router dihapus dari $CHAP (backup: /root/backup-chap-secrets-$STAMP)"
  else
    info "Tidak ada akun VPN dari panel di $CHAP"
  fi
  if [ -f "$ROUTE_SCRIPT" ]; then rm -f "$ROUTE_SCRIPT"; ok "Script route otomatis $ROUTE_SCRIPT dihapus"; fi
}

kembalikan_xl2tpd() {
  [ -f "$XL2TPD_CONF" ] || return 0
  sed -i -E 's/^(\s*local ip\s*=\s*).*/\1192.168.42.1/; s/^(\s*ip range\s*=\s*).*/\1192.168.42.10-192.168.42.250/' "$XL2TPD_CONF"
  ok "xl2tpd dikembalikan ke bawaan vpnsetup.sh (local ip 192.168.42.1, pool .10-.250)"
  systemctl restart xl2tpd 2>/dev/null && ok "xl2tpd di-restart (semua sesi L2TP terputus)" || warn "Gagal restart xl2tpd"
}

hapus_layanan_panel() {
  systemctl disable --now vpn-acs >/dev/null 2>&1 || true
  rm -f "$SERVICE"
  systemctl daemon-reload 2>/dev/null || true
  LO_IP=""
  if [ -f "$DATA" ]; then
    LO_IP="$(node -e 'try{const d=require(process.argv[1]);if(!(d.settings&&d.settings.zt))process.exit();const n=((d.settings&&d.settings.tunnelNet)||"192.168.42.0/24").split("/")[0].split(".").map(Number);n[3]+=1;console.log(n.join("."))}catch(e){}' "$DATA" 2>/dev/null)"
    cp "$DATA" "/root/backup-vpnacs-$STAMP.json"
    chmod 600 "/root/backup-vpnacs-$STAMP.json"
    ok "Data panel dibackup ke /root/backup-vpnacs-$STAMP.json"
    # Sertifikat HTTPS panel (jika dipakai) ikut dihapus supaya perpanjangan otomatis tidak gagal terus
    local dom
    dom="$(node -e 'try{const c=require(process.argv[1]).settings.cloudflare;if(c&&c.https)console.log(c.domain)}catch(e){}' "$DATA" 2>/dev/null)"
    if [ -n "$dom" ] && command -v certbot >/dev/null 2>&1; then
      certbot delete --cert-name "$dom" --non-interactive >/dev/null 2>&1 && ok "Sertifikat HTTPS $dom dihapus" || warn "Sertifikat HTTPS $dom tidak bisa dihapus otomatis (certbot delete --cert-name $dom)"
      warn "Record DNS $dom di Cloudflare tidak dihapus. Hapus manual di dashboard Cloudflare jika tidak dipakai."
    fi
  fi
  rm -rf "$APP_DIR"
  rm -f "$SYSCTL_FILE"
  # Alamat URL ACS di loopback (dipasang panel hanya jika ZeroTier dipakai)
  if [ -n "$LO_IP" ] && ip -4 addr show dev lo | grep -q "inet ${LO_IP}/32"; then
    ip addr del "${LO_IP}/32" dev lo 2>/dev/null && ok "Alamat ${LO_IP} dilepas dari loopback"
  fi
  ok "Layanan dan file Panel VPN ACS dihapus"
}

cetak_script_mikrotik() {
  echo
  echo -e "${GREEN}== Bersihkan juga setiap MikroTik ==${NC}"
  echo "Salin baris berikut ke Winbox > New Terminal di setiap MikroTik router:"
  echo
  cat <<'EOF'
/interface l2tp-client remove [find where name="l2tp-acs"]
/ip route remove [find where comment="VPN ACS"]
/ip firewall nat remove [find where comment~"^VPN ACS"]
/ip firewall filter remove [find where comment~"^VPN ACS"]
:put "Pengaturan VPN ACS sudah dihapus."
EOF
  echo
}

# ---------- mode ----------
mode_portforward() {
  konfirmasi "Semua port forwarding (remote Winbox, Web ONT, dll) di SEMUA router akan dihapus. VPN dan router tetap ada."
  if [ -f "$DATA" ] && command -v node >/dev/null 2>&1; then
    cp "$DATA" "/root/backup-vpnacs-$STAMP.json"; chmod 600 "/root/backup-vpnacs-$STAMP.json"
    node -e 'const fs=require("fs");const f=process.argv[1];const d=JSON.parse(fs.readFileSync(f));let n=0;for(const s of d.sites||[]){n+=(s.forwards||[]).length;s.forwards=[]}fs.writeFileSync(f,JSON.stringify(d,null,2));console.log("     "+n+" port forwarding dihapus dari data panel")' "$DATA"
    ok "Data panel dibackup ke /root/backup-vpnacs-$STAMP.json"
  fi
  hapus_firewall_panel
  if systemctl is-active --quiet vpn-acs 2>/dev/null; then
    systemctl restart vpn-acs && ok "Panel di-restart"
  fi
}

mode_panel() {
  konfirmasi "Panel VPN ACS, SEMUA akun VPN router, route IP virtual, dan aturan firewall panel akan dihapus. Semua MikroTik akan terputus dari VPS."
  hapus_route_virtual
  hapus_layanan_panel
  hapus_firewall_panel
  hapus_aturan_l2tp_polos
  hapus_akun_vpn
  kembalikan_xl2tpd
  cetak_script_mikrotik
}

mode_genieacs() {
  if [ -f "$SCRIPT_DIR/genieacs-virtualip.sh" ]; then
    konfirmasi "GenieACS akan dikembalikan ke versi asli (tanpa patch IP virtual). Summon ke ONT lewat IP virtual tidak akan berfungsi lagi."
    bash "$SCRIPT_DIR/genieacs-virtualip.sh" rollback
  else
    fail "genieacs-virtualip.sh tidak ditemukan di $SCRIPT_DIR"
  fi
}

mode_parameter() {
  local list b pilih
  list="$(ls -1d /root/backup-parameter-* 2>/dev/null || true)"
  [ -n "$list" ] || { warn "Tidak ada backup parameter (/root/backup-parameter-*). Lewati."; return 0; }
  echo
  echo "Backup parameter yang tersedia:"
  local i=1; while read -r b; do echo "  $i) $b"; i=$((i+1)); done <<< "$list"
  read -r -p "Pilih nomor backup (Enter = paling lama, yaitu parameter sebelum pertama kali dipasang): " pilih
  if [ -z "$pilih" ]; then b="$(echo "$list" | head -1)"; else b="$(echo "$list" | sed -n "${pilih}p")"; fi
  [ -n "$b" ] || fail "Pilihan tidak valid"
  konfirmasi "Parameter GenieACS (preset, provision, virtual parameter, tampilan) akan dikembalikan dari $b."
  [ -d "$b/genieacs" ] || fail "Folder backup tidak valid: $b"
  command -v mongorestore >/dev/null || fail "mongorestore tidak ditemukan (MongoDB belum terpasang?)"
  mongorestore --quiet --db genieacs --drop "$b/genieacs" || fail "Gagal mengembalikan parameter"
  ok "Parameter GenieACS dikembalikan dari $b"
  for s in genieacs-cwmp genieacs-nbi genieacs-fs genieacs-ui; do systemctl restart "$s" 2>/dev/null || true; done
  sleep 2
  for s in genieacs-cwmp genieacs-nbi genieacs-ui; do
    if systemctl is-active --quiet "$s"; then ok "$s berjalan"; else warn "$s tidak berjalan, cek: journalctl -u $s -n 30"; fi
  done
}

mode_semua() {
  konfirmasi "SEMUA yang dipasang suwazed-panel akan dihapus: Panel VPN ACS, akun VPN router, port forwarding, aturan firewall, dan patch GenieACS."
  hapus_route_virtual
  hapus_layanan_panel
  hapus_firewall_panel
  hapus_aturan_l2tp_polos
  hapus_akun_vpn
  kembalikan_xl2tpd
  if [ -f "$SCRIPT_DIR/genieacs-virtualip.sh" ]; then bash "$SCRIPT_DIR/genieacs-virtualip.sh" rollback; fi
  read -r -p "Kembalikan juga parameter GenieACS lama? [y/N]: " p
  [ "${p,,}" = "y" ] && mode_parameter
  cetak_script_mikrotik
}

menu() {
  echo -e "${GREEN}== Bersihkan suwazed-panel ==${NC}"
  echo "  1) Hapus semua port forwarding saja (VPN & router tetap)"
  echo "  2) Hapus Panel VPN ACS + akun VPN router + aturan firewall"
  echo "  3) Kembalikan GenieACS asli (hapus patch IP virtual)"
  echo "  4) Kembalikan parameter GenieACS dari backup"
  echo "  5) Hapus SEMUA (2 + 3, parameter ditanyakan)"
  echo "  0) Batal"
  read -r -p "Pilih: " m
  case "$m" in
    1) mode_portforward ;;
    2) mode_panel ;;
    3) mode_genieacs ;;
    4) mode_parameter ;;
    5) mode_semua ;;
    *) echo "Dibatalkan."; exit 0 ;;
  esac
}

case "${1:-menu}" in
  menu)        menu ;;
  portforward) mode_portforward ;;
  panel)       mode_panel ;;
  genieacs)    mode_genieacs ;;
  parameter)   mode_parameter ;;
  semua)       mode_semua ;;
  *) echo "Pemakaian: bash $0 [portforward|panel|genieacs|parameter|semua]"; exit 1 ;;
esac

echo
ok "Selesai."
