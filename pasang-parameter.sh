#!/bin/bash
# =====================================================================
#  Pasang parameter GenieACS versi bersih (basis beryindo/genieacs)
#
#  Yang diganti : presets, provisions, virtualParameters, config
#  Yang TIDAK disentuh : data perangkat ONT, tasks, users, files
#
#  Pemakaian (sebagai root, di VPS GenieACS):
#    bash pasang-parameter.sh                     -> pasang (backup otomatis dulu)
#    bash pasang-parameter.sh rollback FOLDER     -> kembali ke backup
#    bash pasang-parameter.sh daftar-backup       -> lihat daftar backup
# =====================================================================

set -euo pipefail
GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'
ok()   { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[PERHATIAN]${NC} $*"; }
fail() { echo -e "${RED}[GAGAL]${NC} $*" >&2; exit 1; }

DB="genieacs"
COLLS="presets provisions virtualParameters config"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PARAM_DIR="$SCRIPT_DIR/parameter"
CRED_FILE="/root/genieacs-kredensial-acs.txt"

[ "$(id -u)" -eq 0 ] || fail "Jalankan sebagai root"
command -v mongodump   >/dev/null || fail "mongodump tidak ditemukan (MongoDB belum terpasang?)"
command -v mongorestore >/dev/null || fail "mongorestore tidak ditemukan"
command -v node >/dev/null || fail "Node.js tidak ditemukan"
if command -v mongo >/dev/null; then MONGO_SHELL="mongo"
elif command -v mongosh >/dev/null; then MONGO_SHELL="mongosh"
else fail "mongo / mongosh tidak ditemukan"; fi

mongo_eval() { "$MONGO_SHELL" --quiet "$DB" --eval "$1"; }

restart_genieacs() {
  for s in genieacs-cwmp genieacs-nbi genieacs-fs genieacs-ui; do
    systemctl restart "$s" 2>/dev/null || true
  done
  sleep 2
  for s in genieacs-cwmp genieacs-nbi genieacs-ui; do
    if systemctl is-active --quiet "$s"; then ok "$s berjalan"; else warn "$s tidak berjalan, cek: journalctl -u $s -n 30"; fi
  done
}

do_backup() {
  local dir="/root/backup-parameter-$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$dir"
  for c in $COLLS; do
    mongodump --quiet --db "$DB" --collection "$c" --out "$dir" >/dev/null
  done
  [ -d "$dir/$DB" ] || fail "Backup gagal dibuat"
  echo "$dir"
}

# ---------- rollback ----------
if [ "${1:-}" = "daftar-backup" ]; then
  ls -1d /root/backup-parameter-* 2>/dev/null || echo "Belum ada backup."
  exit 0
fi
if [ "${1:-}" = "rollback" ]; then
  B="${2:-}"
  [ -n "$B" ] || fail "Sebutkan folder backup. Lihat: bash $0 daftar-backup"
  [ -d "$B/$DB" ] || fail "Folder backup tidak valid: $B"
  mongorestore --quiet --db "$DB" --drop "$B/$DB" || fail "Rollback gagal"
  ok "Parameter dikembalikan dari $B"
  restart_genieacs
  exit 0
fi

# ---------- pasang ----------
for c in $COLLS; do
  [ -f "$PARAM_DIR/$c.bson" ] || fail "File $PARAM_DIR/$c.bson tidak ada. Jalankan dari folder repo suwazed-panel."
done

echo -e "${GREEN}== Akses WAN ONT ==${NC}"
echo "  1) buka-web : web ONT boleh dibuka dari WAN (untuk fitur 'Web ONT' di Panel VPN ACS),"
echo "                SSH & Telnet dari WAN ditutup   [disarankan]"
echo "  2) tutup    : HTTP, SSH, Telnet dari WAN ditutup semua"
echo "  3) biarkan  : pengaturan akses WAN di ONT tidak diubah"
read -r -p "Pilih [1/2/3] (Enter = 1): " PILIH
case "${PILIH:-1}" in
  1) MODE="buka-web" ;;
  2) MODE="tutup" ;;
  3) MODE="biarkan" ;;
  *) fail "Pilihan tidak dikenal" ;;
esac
ok "Mode akses WAN: $MODE"

echo
echo -e "${GREEN}== Kredensial ACS yang ditulis ke ONT ==${NC}"
echo "Hanya huruf, angka, titik, minus, garis bawah. Tekan Enter untuk memakai nilai default (admin)."
gen() { node -e 'const c="ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz23456789";let s="";for(const b of require("crypto").randomBytes(16))s+=c[b%c.length];console.log(s)'; }
ask() {
  local label="$1" def="$2" v
  read -r -p "$label (Enter = $def): " v
  v="${v:-$def}"
  [[ "$v" =~ ^[A-Za-z0-9._-]{3,64}$ ]] || fail "$label tidak valid"
  echo "$v"
}
ACS_USER="$(ask 'ACS Username' 'admin')"
ACS_PASS="$(ask 'ACS Password' 'admin')"
CR_USER="$(ask 'Connection Request Username' 'admin')"
CR_PASS="$(ask 'Connection Request Password' 'admin')"

echo
echo -e "${GREEN}== Backup parameter lama ==${NC}"
BACKUP="$(do_backup)"
ok "Backup: $BACKUP"
echo "   Kembali ke parameter lama: bash $0 rollback $BACKUP"

echo
echo -e "${GREEN}== Pasang parameter bersih ==${NC}"
TMP="$(mktemp -d)"
for c in $COLLS; do cp "$PARAM_DIR/$c.bson" "$PARAM_DIR/$c.metadata.json" "$TMP/"; done
mongorestore --quiet --db "$DB" --drop "$TMP" || { rm -rf "$TMP"; fail "mongorestore gagal. Kembalikan dengan: bash $0 rollback $BACKUP"; }
rm -rf "$TMP"
ok "Preset, provision, virtual parameter, dan config terpasang"

J() { node -e 'console.log(JSON.stringify(process.argv[1]))' "$1"; }
mongo_eval "
var r = {MODE: $(J "$MODE"), AU: $(J "$ACS_USER"), AP: $(J "$ACS_PASS"), CU: $(J "$CR_USER"), CP: $(J "$CR_PASS")};
var map = {'__MODE_WAN__': r.MODE, '__ACS_USER__': r.AU, '__ACS_PASS__': r.AP, '__CR_USER__': r.CU, '__CR_PASS__': r.CP};
db.provisions.find({_id: {\$in: ['default', 'inform']}}).forEach(function (d) {
  var s = d.script;
  for (var k in map) s = s.split(k).join(map[k]);
  db.provisions.updateOne({_id: d._id}, {\$set: {script: s}});
});
var left = db.provisions.find({script: /__(MODE_WAN|ACS_USER|ACS_PASS|CR_USER|CR_PASS)__/}).count();
if (left > 0) { print('PLACEHOLDER_TERSISA'); }
var f = db.faults.deleteMany({channel: 'useradmin'});
print('fault useradmin dihapus: ' + f.deletedCount);
" | tee /tmp/pasang-parameter.log
grep -q PLACEHOLDER_TERSISA /tmp/pasang-parameter.log && fail "Pengisian kredensial gagal. Kembalikan dengan: bash $0 rollback $BACKUP"
ok "Mode akses WAN dan kredensial diterapkan"

umask 077
cat > "$CRED_FILE" <<EOF
# Kredensial ACS yang ditulis GenieACS ke semua ONT ($(date '+%Y-%m-%d %H:%M'))
ACS_USERNAME=$ACS_USER
ACS_PASSWORD=$ACS_PASS
CONNECTION_REQUEST_USERNAME=$CR_USER
CONNECTION_REQUEST_PASSWORD=$CR_PASS
MODE_AKSES_WAN=$MODE
BACKUP=$BACKUP
EOF
ok "Kredensial disimpan di $CRED_FILE (hanya root yang bisa baca)"

echo
echo -e "${GREEN}== Restart GenieACS ==${NC}"
restart_genieacs

echo
ok "Selesai. Perubahan masuk ke ONT pada Inform berikutnya (maks. beberapa menit)."
echo "   Grafik redaman memakai VirtualParameters.RXPowerInt yang terisi setelah ONT Inform."
