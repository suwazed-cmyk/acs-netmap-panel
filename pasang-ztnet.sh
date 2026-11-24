#!/bin/bash
# =====================================================================
#  Pasang ZTNET (web pengelola ZeroTier) + ZeroTier controller
#  langsung di VPS (tanpa Docker), web di port 3300.
#
#  Memakai installer resmi ZTNET (install.ztnet.network), dengan
#  penyesuaian supaya tidak bentrok dengan GenieACS (port 3000):
#   - Port web ZTNET dipindah ke 3300 (pengaturan systemd terpisah,
#     tidak tertimpa saat ZTNET di-update)
#   - NEXTAUTH_URL disesuaikan ke port 3300
#   - Memeriksa Node.js, RAM, dan layanan GenieACS / panel sebelum & sesudah
#
#  Pemakaian (sebagai root):
#    bash pasang-ztnet.sh            -> pasang / update ZTNET
#    bash pasang-ztnet.sh status     -> cek status
# =====================================================================

ZTNET_PORT=3300
ZTNET_DIR="/opt/ztnet"
DROPIN_DIR="/etc/systemd/system/ztnet.service.d"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
ok()   { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[PERHATIAN]${NC} $*"; }
fail() { echo -e "${RED}[GAGAL]${NC} $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || fail "Jalankan sebagai root"

cek_layanan() {
  for s in genieacs-cwmp genieacs-ui vpn-acs xl2tpd; do
    if systemctl list-unit-files "$s.service" >/dev/null 2>&1 && systemctl cat "$s" >/dev/null 2>&1; then
      if systemctl is-active --quiet "$s"; then ok "$s berjalan"; else warn "$s TIDAK berjalan (cek: journalctl -u $s -n 30)"; fi
    fi
  done
}

if [ "${1:-}" = "status" ]; then
  systemctl is-active --quiet ztnet && ok "ztnet berjalan" || warn "ztnet tidak berjalan"
  systemctl is-active --quiet zerotier-one && ok "zerotier-one berjalan" || warn "zerotier-one tidak berjalan"
  command -v zerotier-cli >/dev/null && zerotier-cli info
  grep '^NEXTAUTH_URL=' "$ZTNET_DIR/.env" 2>/dev/null
  ss -lntup 2>/dev/null | grep -E ":(3000|$ZTNET_PORT|9993) " || true
  exit 0
fi

echo -e "${GREEN}== Pemeriksaan sebelum memasang ==${NC}"

# 1) Port 3300 harus kosong (kecuali sudah dipakai ZTNET sendiri)
if ss -lnt 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${ZTNET_PORT}$"; then
  if ! systemctl is-active --quiet ztnet; then
    fail "Port ${ZTNET_PORT} sudah dipakai aplikasi lain. Cek: ss -lntp | grep ${ZTNET_PORT}"
  fi
fi

# 2) Node.js: installer ZTNET memasang Node 20 jika Node belum ada atau versinya di bawah 20
NODE_BEFORE=""
if command -v node >/dev/null 2>&1; then
  NODE_BEFORE="$(node -v)"
  NODE_MAJOR="$(node -v | sed 's/^v//' | cut -d. -f1)"
  if [ "$NODE_MAJOR" -ge 20 ] 2>/dev/null; then
    ok "Node.js $NODE_BEFORE (tidak akan diubah installer ZTNET)"
  else
    warn "Node.js $NODE_BEFORE akan DIGANTI ke Node 20 oleh installer ZTNET. GenieACS dan panel ikut memakai Node ini."
    read -r -p "Lanjutkan? [y/N]: " jawab
    [ "${jawab,,}" = "y" ] || fail "Dibatalkan."
  fi
else
  warn "Node.js belum ada; installer ZTNET akan memasang Node 20."
fi

# 3) RAM: proses build ZTNET butuh memori cukup besar
MEM_MB=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
SWAP_MB=$(awk '/SwapTotal/ {print int($2/1024)}' /proc/meminfo)
TOTAL_MB=$((MEM_MB + SWAP_MB))
ok "RAM ${MEM_MB} MB + swap ${SWAP_MB} MB"
if [ "$TOTAL_MB" -lt 3500 ]; then
  warn "RAM + swap di bawah 3.5 GB. Build ZTNET bisa gagal atau membuat GenieACS lambat."
  if [ ! -f /swapfile-ztnet ]; then
    read -r -p "Buat swap tambahan 2 GB di /swapfile-ztnet? [Y/n]: " jawab
    if [ "${jawab,,}" != "n" ]; then
      fallocate -l 2G /swapfile-ztnet && chmod 600 /swapfile-ztnet && mkswap /swapfile-ztnet >/dev/null && swapon /swapfile-ztnet \
        && { grep -q '/swapfile-ztnet' /etc/fstab || echo '/swapfile-ztnet none swap sw 0 0' >> /etc/fstab; } \
        && ok "Swap 2 GB ditambahkan" || warn "Gagal membuat swap, lanjut tanpa swap tambahan"
    fi
  fi
fi

# 4) Alamat web ZTNET
DEF_HOST="$(hostname -I | awk '{print $1}')"
# Bawaan dari panel: subdomain ZTNET yang sudah diatur, atau zt.<domain Cloudflare>
PANEL_HOST="$(node -e 'try{const s=require("/opt/vpn-acs/data.json").settings||{};const z=s.subdomains&&s.subdomains.zt;if(z&&z.host)console.log(z.host);else if(s.cloudflare&&s.cloudflare.zoneName)console.log("zt."+s.cloudflare.zoneName)}catch(e){}' 2>/dev/null)"
[ -n "$PANEL_HOST" ] && DEF_HOST="$PANEL_HOST"
if [ -f "$ZTNET_DIR/.env" ]; then
  CUR_URL="$(grep '^NEXTAUTH_URL=' "$ZTNET_DIR/.env" | cut -d= -f2- | tr -d '"')"
  DEF_HOST="$(echo "$CUR_URL" | sed -E 's#^https?://##; s#:[0-9]+.*$##; s#/.*$##')"
fi
echo
echo "Alamat untuk membuka ZTNET (domain atau IP publik VPS), tanpa http:// dan tanpa port."
echo "Contoh: zt.inetwifi.xyz   (sebaiknya subdomain sendiri, bukan domain panel)"
read -r -p "Alamat [${DEF_HOST}]: " ZT_HOST
ZT_HOST="${ZT_HOST:-$DEF_HOST}"
ZT_HOST="$(echo "$ZT_HOST" | sed -E 's#^https?://##; s#/.*$##; s#:[0-9]+$##')"
[ -n "$ZT_HOST" ] || fail "Alamat kosong."
ZT_URL="http://${ZT_HOST}:${ZTNET_PORT}"

# 5) Port 3300 lewat pengaturan systemd terpisah (dibuat sebelum memasang
#    supaya ZTNET tidak sempat berebut port 3000 dengan GenieACS)
mkdir -p "$DROPIN_DIR"
cat > "$DROPIN_DIR/port.conf" <<EOF
[Service]
Environment=PORT=${ZTNET_PORT}
Environment=HOSTNAME=0.0.0.0
EOF
systemctl daemon-reload
ok "ZTNET akan memakai port ${ZTNET_PORT}"

echo
echo -e "${GREEN}== Menjalankan installer resmi ZTNET ==${NC}"
echo "Petunjuk saat installer bertanya:"
echo "  - IP address or domain name     : ${ZT_HOST}"
echo "  - Password PostgreSQL           : tekan Enter (pakai bawaan)"
echo "  - Kirim laporan error (jika ada): No"
echo
read -r -p "Tekan Enter untuk mulai..." _
apt-get update -qq && apt-get install -y -qq sudo curl lsb-release >/dev/null || fail "Gagal memasang sudo/curl/lsb-release"
curl -s http://install.ztnet.network | sudo bash
[ -d "$ZTNET_DIR" ] || fail "Installer ZTNET tidak selesai ($ZTNET_DIR tidak ada). Lihat pesan di atas."

echo
echo -e "${GREEN}== Penyesuaian setelah memasang ==${NC}"
if grep -q '^NEXTAUTH_URL=' "$ZTNET_DIR/.env" 2>/dev/null; then
  sed -i "s#^NEXTAUTH_URL=.*#NEXTAUTH_URL=${ZT_URL}#" "$ZTNET_DIR/.env"
else
  echo "NEXTAUTH_URL=${ZT_URL}" >> "$ZTNET_DIR/.env"
fi
ok "NEXTAUTH_URL=${ZT_URL}"
systemctl daemon-reload
systemctl restart ztnet
sleep 5

echo
echo -e "${GREEN}== Pemeriksaan sesudah memasang ==${NC}"
systemctl is-active --quiet ztnet && ok "ztnet berjalan" || warn "ztnet tidak berjalan (cek: journalctl -u ztnet -n 50)"
systemctl is-active --quiet zerotier-one && ok "zerotier-one berjalan" || warn "zerotier-one tidak berjalan"
if ss -lnt 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${ZTNET_PORT}$"; then ok "Web ZTNET mendengarkan di port ${ZTNET_PORT}"; else warn "Port ${ZTNET_PORT} belum terbuka, tunggu sebentar lalu: bash $0 status"; fi
if [ -n "$NODE_BEFORE" ] && [ "$(node -v)" != "$NODE_BEFORE" ]; then
  warn "Versi Node.js berubah: $NODE_BEFORE -> $(node -v). Pastikan GenieACS dan panel tetap berjalan (lihat di bawah)."
fi
cek_layanan
# Panel membaca ZeroTier saat halaman dibuka; restart agar deteksi ZTNET langsung muncul
systemctl is-active --quiet vpn-acs && systemctl restart vpn-acs

echo
ok "Selesai."
echo -e "   Buka ZTNET : ${GREEN}${ZT_URL}${NC}  (akun pertama yang mendaftar menjadi admin, segera daftar)"
echo "   Buka port di firewall provider VPS: TCP ${ZTNET_PORT} (web ZTNET) dan UDP 9993 (ZeroTier)."
echo "   Panel VPN ACS -> Pengaturan -> Domain & HTTPS -> Subdomain layanan: buat record DNS acs/zt otomatis."
echo "   Langkah berikutnya:"
echo "     1. Di ZTNET: Networks -> Create Network, atur rentang IPv4 (contoh 172.27.0.0/24)"
echo "     2. Di panel VPN ACS: Pengaturan -> ZeroTier -> pilih jaringan -> Hubungkan VPS"
echo "   Update ZTNET nanti: jalankan lagi bash $0 (port 3300 tetap)."
