#!/bin/bash
# =====================================================================
#  Pasang ZTNET (web pengelola ZeroTier) + ZeroTier controller
#  langsung di VPS (tanpa Docker), web di port 3300.
#
#  Versi ringan: ZTNET TIDAK di-build di VPS. Paket siap pakai diunduh
#  dari rilis GitHub repo ini (dibangun GitHub Actions dari kode resmi
#  ZTNET, lihat ztnet-build/). Hasilnya:
#   - cepat (1-3 menit) dan hemat RAM (tanpa npm install / build Next.js)
#   - tanpa pertanyaan dan tanpa dialog, bisa dipasang dari menu Add-on panel
#   - Node.js yang dipakai GenieACS dan panel tidak diganti
#   - versi ZTNET dikunci (ZTNET_VERSION di bawah)
#
#  Kompatibel dengan ZTNET yang dipasang installer resmi sebelumnya:
#  folder /opt/ztnet, database, dan .env yang ada tetap dipakai.
#
#  Pemakaian (sebagai root):
#    bash pasang-ztnet.sh            -> pasang / update ZTNET
#    bash pasang-ztnet.sh status     -> cek status
# =====================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ZTNET_VERSION="${ZTNET_VERSION:-v0.8.7}"
ZTNET_PKG_URL="${ZTNET_PKG_URL:-https://github.com/suwazed-cmyk/acs-netmap-panel/releases/download/ztnet-${ZTNET_VERSION}}"
ZEROTIER_VERSION="1.14.2"
ZTNET_PORT=3300
ZTNET_DIR="/opt/ztnet"
DROPIN_DIR="/etc/systemd/system/ztnet.service.d"
PG_USER="ztnet"
PG_DB="ztnet"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
ok()   { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[PERHATIAN]${NC} $*"; }
fail() { echo -e "${RED}[GAGAL]${NC} $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || fail "Jalankan sebagai root"

# ZTNET_AUTO=1 : dipasang dari menu Add-on panel (tanpa pertanyaan, pilihan bawaan)
AUTO="${ZTNET_AUTO:-0}"
export NEEDRESTART_SUSPEND=1 NEEDRESTART_MODE=l DEBIAN_FRONTEND=noninteractive
export CHECKPOINT_DISABLE=1 PRISMA_HIDE_UPDATE_MESSAGE=1 NEXT_TELEMETRY_DISABLED=1
progress() { [ "$AUTO" = "1" ] && echo "@@PROGRESS $*"; return 0; }
ask() { # ask "pertanyaan" "bawaan" -> isi variabel REPLY
  if [ "$AUTO" = "1" ]; then REPLY="$2"; echo "$1 $2 (otomatis)"; else read -r -p "$1" REPLY; REPLY="${REPLY:-$2}"; fi
}
APT() { apt-get -o DPkg::Lock::Timeout=300 -o Dpkg::Options::=--force-confold "$@"; }

cek_layanan() {
  for s in genieacs-cwmp genieacs-ui vpn-acs xl2tpd; do
    if systemctl cat "$s" >/dev/null 2>&1; then
      if systemctl is-active --quiet "$s"; then ok "$s berjalan"; else warn "$s TIDAK berjalan (cek: journalctl -u $s -n 30)"; fi
    fi
  done
}
env_get() { grep -m1 "^$1=" "$ZTNET_DIR/.env" 2>/dev/null | cut -d= -f2- | tr -d '"'; }

if [ "${1:-}" = "status" ]; then
  systemctl is-active --quiet ztnet && ok "ztnet berjalan" || warn "ztnet tidak berjalan"
  systemctl is-active --quiet zerotier-one && ok "zerotier-one berjalan" || warn "zerotier-one tidak berjalan"
  command -v zerotier-cli >/dev/null && zerotier-cli info
  [ -f "$ZTNET_DIR/.ztnet-version" ] && echo "Versi ZTNET: $(cat "$ZTNET_DIR/.ztnet-version")"
  grep '^NEXTAUTH_URL=' "$ZTNET_DIR/.env" 2>/dev/null
  ss -lntup 2>/dev/null | grep -E ":(3000|$ZTNET_PORT|9993) " || true
  exit 0
fi

# needrestart (apt): tanpa dialog "Pending kernel upgrade" dan tanpa restart layanan otomatis
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
$nrconf{override_rc}->{qr(^postgresql[^.]*\.service$)} = 0;
NREOF
fi

echo -e "${GREEN}== Pemeriksaan sebelum memasang ==${NC}"
progress 3 "Pemeriksaan awal"

# 1) Arsitektur dan sistem
case "$(uname -m)" in
  x86_64) ARCH=amd64 ;;
  aarch64|arm64) ARCH=arm64 ;;
  *) fail "Arsitektur $(uname -m) belum didukung (hanya x86_64 dan arm64)" ;;
esac
. /etc/os-release 2>/dev/null
CODENAME="${VERSION_CODENAME:-jammy}"
OSSL="$(openssl version 2>/dev/null | awk '{print $2}' | cut -d. -f1)"
[ "${OSSL:-0}" -ge 3 ] 2>/dev/null || fail "Butuh OpenSSL 3 (Ubuntu 22.04 / Debian 12 atau lebih baru). Sistem ini: ${PRETTY_NAME:-?}"
ok "${PRETTY_NAME:-Linux} ($ARCH)"

# 2) Port 3300 harus kosong (kecuali sudah dipakai ZTNET sendiri)
if ss -lnt 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${ZTNET_PORT}$"; then
  systemctl is-active --quiet ztnet || fail "Port ${ZTNET_PORT} sudah dipakai aplikasi lain. Cek: ss -lntp | grep ${ZTNET_PORT}"
fi

# 3) Node.js 20+ (dipakai juga oleh GenieACS dan panel; tidak diganti oleh script ini)
NODE_BIN="$(command -v node || true)"
[ -n "$NODE_BIN" ] || fail "Node.js tidak ditemukan. Pasang GenieACS / panel dulu."
NODE_MAJOR="$("$NODE_BIN" -v | sed 's/^v//' | cut -d. -f1)"
[ "$NODE_MAJOR" -ge 20 ] 2>/dev/null || fail "ZTNET butuh Node.js 20 atau lebih baru (terpasang $("$NODE_BIN" -v)). Naikkan Node.js dulu."
ok "Node.js $("$NODE_BIN" -v)"

# 4) Ruang disk
FREE_MB=$(df -Pm /opt 2>/dev/null | awk 'NR==2{print $4}')
[ "${FREE_MB:-0}" -ge 800 ] || fail "Ruang disk di /opt tinggal ${FREE_MB} MB (minimal 800 MB)"
ok "Disk kosong $((FREE_MB/1024)) GB, RAM $(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo) MB"

# 5) Alamat web ZTNET
DEF_HOST="$(hostname -I | awk '{print $1}')"
# Bawaan dari panel: subdomain ZTNET yang sudah diatur, atau zt.<domain Cloudflare>
PANEL_HOST="$("$NODE_BIN" -e 'try{const s=require("/opt/vpn-acs/data.json").settings||{};const z=s.subdomains&&s.subdomains.zt;if(z&&z.host)console.log(z.host);else if(s.cloudflare&&s.cloudflare.zoneName)console.log("zt."+s.cloudflare.zoneName)}catch(e){}' 2>/dev/null)"
[ -n "$PANEL_HOST" ] && DEF_HOST="$PANEL_HOST"
CUR_URL="$(env_get NEXTAUTH_URL)"
[ -n "$CUR_URL" ] && DEF_HOST="$(echo "$CUR_URL" | sed -E 's#^https?://##; s#:[0-9]+.*$##; s#/.*$##')"
[ -n "${ZTNET_HOST:-}" ] && DEF_HOST="$ZTNET_HOST"
echo
echo "Alamat untuk membuka ZTNET (domain atau IP publik VPS), tanpa http:// dan tanpa port."
ask "Alamat [${DEF_HOST}]: " "$DEF_HOST"; ZT_HOST="${REPLY:-$DEF_HOST}"
ZT_HOST="$(echo "$ZT_HOST" | sed -E 's#^https?://##; s#/.*$##; s#:[0-9]+$##')"
[ -n "$ZT_HOST" ] || fail "Alamat kosong."
ZT_URL="http://${ZT_HOST}:${ZTNET_PORT}"
# alamat yang sudah diatur panel (mis. https://zt.domain tanpa port) dipertahankan
case "$CUR_URL" in https://*) [ "$(echo "$CUR_URL" | sed -E 's#^https://##; s#[:/].*$##')" = "$ZT_HOST" ] && ZT_URL="$CUR_URL" ;; esac
progress 8 "Alamat ZTNET: $ZT_URL"

# ---------------------------------------------------------------------
echo
echo -e "${GREEN}== Paket sistem ==${NC}"
progress 10 "Memeriksa paket yang setengah terpasang"
dpkg --configure -a >/dev/null 2>&1 || true

NEED=""
command -v psql >/dev/null 2>&1 && systemctl cat postgresql >/dev/null 2>&1 || NEED="$NEED postgresql"
for p in curl ca-certificates openssl; do dpkg -s "$p" >/dev/null 2>&1 || NEED="$NEED $p"; done
if [ -n "$NEED" ]; then
  progress 12 "Memasang${NEED}"
  APT update -q || fail "apt-get update gagal (cek koneksi internet VPS)"
  APT install -y -q $NEED || fail "Gagal memasang:${NEED}"
  ok "Terpasang:${NEED}"
else
  ok "PostgreSQL dan paket pendukung sudah ada"
fi
systemctl enable --now postgresql >/dev/null 2>&1
for i in $(seq 1 30); do runuser -u postgres -- psql -tAc "select 1" >/dev/null 2>&1 && break; sleep 1; done
runuser -u postgres -- psql -tAc "select 1" >/dev/null 2>&1 || fail "PostgreSQL tidak berjalan (cek: journalctl -u postgresql -n 30)"
ok "PostgreSQL berjalan"

# ZeroTier
progress 25 "Memasang ZeroTier"
if ! command -v zerotier-cli >/dev/null 2>&1; then
  ZT_DEB="zerotier-one_${ZEROTIER_VERSION}_${ARCH}.deb"
  ZT_BASE="https://download.zerotier.com/RELEASES/${ZEROTIER_VERSION}/dist/debian"
  CODE="$(curl -sSI -o /dev/null -w '%{http_code}' "$ZT_BASE/$CODENAME/$ZT_DEB" 2>/dev/null)"
  if [ "$CODE" = "404" ]; then
    if [ "${ID:-}" = "ubuntu" ]; then CODENAME=noble; else CODENAME=bookworm; fi
    warn "ZeroTier $ZEROTIER_VERSION belum ada untuk sistem ini, memakai paket $CODENAME"
  fi
  curl -fsSL --retry 3 -o "/tmp/$ZT_DEB" "$ZT_BASE/$CODENAME/$ZT_DEB" || fail "Gagal mengunduh ZeroTier dari download.zerotier.com"
  dpkg -i "/tmp/$ZT_DEB" >/dev/null 2>&1 || APT install -f -y -q || fail "Gagal memasang ZeroTier"
  rm -f "/tmp/$ZT_DEB"
  ok "ZeroTier $ZEROTIER_VERSION terpasang"
else
  ok "ZeroTier sudah ada ($(zerotier-cli -v 2>/dev/null))"
fi
systemctl enable --now zerotier-one >/dev/null 2>&1
for i in $(seq 1 30); do [ -f /var/lib/zerotier-one/identity.secret ] && break; sleep 1; done
[ -f /var/lib/zerotier-one/identity.secret ] || fail "ZeroTier tidak berjalan (cek: journalctl -u zerotier-one -n 30)"
ok "ZeroTier berjalan, alamat $(cut -d: -f1 /var/lib/zerotier-one/identity.public)"

# ---------------------------------------------------------------------
echo
echo -e "${GREEN}== ZTNET ${ZTNET_VERSION} ==${NC}"
PKG="ztnet-${ZTNET_VERSION}-linux-${ARCH}.tar.gz"
TMP="$(mktemp -d /tmp/ztnet-pasang.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
progress 35 "Mengunduh paket ZTNET ${ZTNET_VERSION}"
curl -fsSL --retry 3 -o "$TMP/$PKG" "$ZTNET_PKG_URL/$PKG" || fail "Gagal mengunduh $ZTNET_PKG_URL/$PKG"
curl -fsSL --retry 3 -o "$TMP/$PKG.sha256" "$ZTNET_PKG_URL/$PKG.sha256" || fail "Gagal mengunduh checksum paket"
( cd "$TMP" && sha256sum -c "$PKG.sha256" >/dev/null ) || fail "Paket ZTNET rusak (checksum tidak cocok). Coba lagi."
ok "Paket diunduh ($(du -h "$TMP/$PKG" | cut -f1))"
progress 45 "Membuka paket"
tar -C "$TMP" -xzf "$TMP/$PKG" || fail "Gagal membuka paket"
[ -f "$TMP/ztnet/server.js" ] || fail "Isi paket tidak lengkap"

# Database: pakai kredensial .env lama bila ada (pemasangan sebelumnya / installer resmi)
progress 55 "Menyiapkan database"
OLD_DBURL="$(env_get DATABASE_URL)"
PG_PASS=""
if [ -n "$OLD_DBURL" ]; then
  PG_USER="$(echo "$OLD_DBURL" | sed -E 's#^postgres(ql)?://([^:]+):.*#\2#')"
  PG_PASS="$(echo "$OLD_DBURL" | sed -E 's#^postgres(ql)?://[^:]+:([^@]*)@.*#\2#')"
  PG_DB="$(echo "$OLD_DBURL" | sed -E 's#^[^@]+@[^/]+/([^?]+).*#\1#')"
fi
[ -n "$PG_PASS" ] || PG_PASS="$(openssl rand -hex 16)"
echo "$PG_USER$PG_DB" | grep -qE '^[a-zA-Z0-9_]+$' || fail "Nama user/database di .env tidak wajar: $PG_USER / $PG_DB"
PSQL() { runuser -u postgres -- psql -v ON_ERROR_STOP=1 -qtA "$@"; }
if [ "$(PSQL -c "select 1 from pg_roles where rolname='$PG_USER'")" = "1" ]; then
  PSQL -c "ALTER ROLE \"$PG_USER\" WITH LOGIN PASSWORD '$PG_PASS'" >/dev/null || fail "Gagal mengatur user database"
else
  PSQL -c "CREATE ROLE \"$PG_USER\" WITH LOGIN PASSWORD '$PG_PASS'" >/dev/null || fail "Gagal membuat user database"
fi
if [ "$(PSQL -c "select 1 from pg_database where datname='$PG_DB'")" != "1" ]; then
  PSQL -c "CREATE DATABASE \"$PG_DB\" OWNER \"$PG_USER\"" >/dev/null || fail "Gagal membuat database"
fi
PSQL -c "GRANT ALL PRIVILEGES ON DATABASE \"$PG_DB\" TO \"$PG_USER\"" >/dev/null
PSQL -d "$PG_DB" -c "GRANT ALL ON SCHEMA public TO \"$PG_USER\"" >/dev/null
DATABASE_URL="postgresql://${PG_USER}:${PG_PASS}@127.0.0.1:5432/${PG_DB}?schema=public"
ok "Database $PG_DB siap"

# Pengaturan (.env): nilai lama dipertahankan
NEXTAUTH_SECRET="$(env_get NEXTAUTH_SECRET)"; [ -n "$NEXTAUTH_SECRET" ] || NEXTAUTH_SECRET="$(openssl rand -hex 32)"
ZT_ADDR="$(env_get ZT_ADDR)"
ZT_SECRET="$(env_get ZT_SECRET)"
cat > "$TMP/ztnet/.env" <<EOF
DATABASE_URL="${DATABASE_URL}"
NEXTAUTH_URL="${ZT_URL}"
NEXTAUTH_SECRET="${NEXTAUTH_SECRET}"
NEXT_PUBLIC_APP_VERSION="${ZTNET_VERSION}"
ZT_ADDR="${ZT_ADDR}"
ZT_SECRET="${ZT_SECRET}"
POSTGRES_PASSWORD="${PG_PASS}"
EOF
# baris lain di .env lama (pengaturan tambahan pengguna) ikut dibawa
if [ -f "$ZTNET_DIR/.env" ]; then
  grep -vE '^(DATABASE_URL|NEXTAUTH_URL|NEXTAUTH_SECRET|NEXT_PUBLIC_APP_VERSION|ZT_ADDR|ZT_SECRET|POSTGRES_PASSWORD)=' "$ZTNET_DIR/.env" | grep -E '^[A-Z_]+=' >> "$TMP/ztnet/.env" || true
fi
chmod 600 "$TMP/ztnet/.env"

# Migrasi database dijalankan dari folder baru sebelum dipindah (bila gagal, ZTNET lama tetap utuh)
progress 65 "Menyiapkan tabel database"
(
  cd "$TMP/ztnet" && set -a && . ./.env && set +a &&
  "$NODE_BIN" .tools/node_modules/prisma/build/index.js migrate deploy --schema prisma/schema.prisma
) || fail "Migrasi database gagal (lihat pesan di atas)"
ok "Tabel database siap"
progress 72 "Mengisi data awal"
( cd "$TMP/ztnet" && set -a && . ./.env && set +a && "$NODE_BIN" .tools/seed.js ) || fail "Pengisian data awal gagal"
ok "Data awal siap"

# Pasang: folder lama disimpan sebentar sebagai /opt/ztnet.lama
progress 80 "Memasang ZTNET"
systemctl stop ztnet >/dev/null 2>&1
rm -rf "${ZTNET_DIR}.lama"
[ -d "$ZTNET_DIR" ] && mv "$ZTNET_DIR" "${ZTNET_DIR}.lama"
mv "$TMP/ztnet" "$ZTNET_DIR"
install -m 755 "$ZTNET_DIR/.tools/bin/ztmkworld-$ARCH" /usr/local/bin/ztmkworld 2>/dev/null || true

cat > /etc/systemd/system/ztnet.service <<EOF
[Unit]
Description=ZTNET (web pengelola ZeroTier)
After=network.target postgresql.service zerotier-one.service

[Service]
WorkingDirectory=${ZTNET_DIR}
EnvironmentFile=${ZTNET_DIR}/.env
Environment=NODE_ENV=production
ExecStart=${NODE_BIN} ${ZTNET_DIR}/server.js
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
mkdir -p "$DROPIN_DIR"
cat > "$DROPIN_DIR/port.conf" <<EOF
[Service]
Environment=PORT=${ZTNET_PORT}
Environment=HOSTNAME=0.0.0.0
EOF
systemctl daemon-reload
systemctl enable ztnet >/dev/null 2>&1
systemctl restart ztnet

progress 90 "Menunggu web ZTNET menyala"
UP=""
for i in $(seq 1 60); do
  c="$(curl -s -o /dev/null -m 3 -w '%{http_code}' "http://127.0.0.1:${ZTNET_PORT}/" 2>/dev/null)"
  if [ -n "$c" ] && [ "$c" != "000" ]; then UP=1; break; fi
  sleep 1
done
if [ -z "$UP" ]; then
  journalctl -u ztnet -n 30 --no-pager 2>/dev/null
  if [ -d "${ZTNET_DIR}.lama" ]; then
    warn "Web ZTNET baru tidak menyala, kembali ke versi lama"
    systemctl stop ztnet; rm -rf "$ZTNET_DIR"; mv "${ZTNET_DIR}.lama" "$ZTNET_DIR"; systemctl restart ztnet
  fi
  fail "Web ZTNET tidak menyala di port ${ZTNET_PORT} (lihat log di atas)"
fi
rm -rf "${ZTNET_DIR}.lama"
ok "Web ZTNET menyala di port ${ZTNET_PORT}"

echo
echo -e "${GREEN}== Pemeriksaan sesudah memasang ==${NC}"
systemctl is-active --quiet ztnet && ok "ztnet berjalan" || warn "ztnet tidak berjalan (cek: journalctl -u ztnet -n 50)"
systemctl is-active --quiet zerotier-one && ok "zerotier-one berjalan" || warn "zerotier-one tidak berjalan"
cek_layanan
# Panel membaca ZeroTier saat halaman dibuka; restart agar deteksi ZTNET langsung muncul
# (tidak dilakukan bila dipasang dari panel, karena panel sendiri yang menjalankan script ini)
[ "$AUTO" = "1" ] || { systemctl is-active --quiet vpn-acs && systemctl restart vpn-acs; }
progress 100 "Selesai"

echo
ok "Selesai. ZTNET ${ZTNET_VERSION}"
echo -e "   Buka ZTNET : ${GREEN}${ZT_URL}${NC}  (akun pertama yang mendaftar menjadi admin, segera daftar)"
echo "   Buka port di firewall provider VPS: TCP ${ZTNET_PORT} (web ZTNET) dan UDP 9993 (ZeroTier)."
echo "   Langkah berikutnya:"
echo "     1. Di ZTNET: Networks -> Create Network, atur rentang IPv4 (contoh 172.27.0.0/24)"
echo "     2. Di panel VPN ACS: menu ZeroTier -> pilih jaringan -> Hubungkan VPS"
echo "   Update ZTNET nanti: jalankan lagi bash $0 (data dan pengaturan tetap)."
SUMMARY="$SCRIPT_DIR/ringkasan.sh"
[ "$AUTO" = "1" ] || { [ -f "$SUMMARY" ] && bash "$SUMMARY"; }
