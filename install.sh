#!/bin/bash
# =====================================================================
#  ACS NETMAP Panel: installer satu perintah
#
#  Memasang semua yang dibutuhkan di VPS kosong, tanpa pertanyaan:
#    1. VPN L2TP/IPsec  (paket resmi Ubuntu/Debian: xl2tpd + strongSwan)
#    2. MongoDB         (repo resmi MongoDB: 8.0, atau 4.4 bila CPU tanpa AVX)
#    3. Node.js 22      (rilis resmi nodejs.org, dicek SHA256)
#    4. GenieACS 1.2.16 (npm resmi, susunan sesuai dokumentasi GenieACS)
#    5. Patch IP virtual GenieACS (NETMAP)
#    6. Panel VPN ACS + provision inform berkala
#
#  OS   : Ubuntu 20.04 / 22.04 / 24.04, Debian 11 / 12
#  CPU  : x86_64 (amd64) atau arm64
#
#  Pemakaian (sebagai root):
#    curl -fsSL https://raw.githubusercontent.com/suwazed-cmyk/acs-netmap-panel/main/install.sh | bash
#  atau dari folder repo:
#    bash install.sh
#
#  Aman dijalankan ulang: komponen yang sudah ada (mis. dari vpnsetup.sh / genie.sh)
#  tidak diubah, hanya panel yang diperbarui.
#
#  Log lengkap : /var/log/acs-netmap-install.log
#  Info akhir  : /root/acs-netmap-info.txt
# =====================================================================

REPO_URL="https://github.com/suwazed-cmyk/acs-netmap-panel.git"
REPO_DIR_DEFAULT="/root/acs-netmap-panel"
GENIE_VERSION="1.2.16"
NODE_MAJOR="22"
LOG="/var/log/acs-netmap-install.log"
INFO="/root/acs-netmap-info.txt"
VPN_NET_LOCAL="192.168.42.1"
VPN_POOL="192.168.42.128-192.168.42.254"

main() {
  set -uo pipefail
  umask 022
  export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1 APT_LISTCHANGES_FRONTEND=none
  export LC_ALL=C.UTF-8 2>/dev/null || true
  APT=(apt-get -o DPkg::Lock::Timeout=900 -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold -y -q)

  ui_init
  [ "$(id -u)" -eq 0 ] || die "Jalankan sebagai root (sudo -i lalu ulangi perintahnya)."
  mkdir -p "$(dirname "$LOG")"
  : >>"$LOG"; chmod 600 "$LOG"
  log_head "Mulai $(date '+%F %T')"

  banner
  detect_system
  plan_steps
  run_all
  finish
}

# ---------------------------------------------------------------------
#  Tampilan: progress bar (terminal) atau baris biasa (tanpa terminal)
# ---------------------------------------------------------------------
ui_init() {
  if [ -t 1 ] && [ "${TERM:-dumb}" != "dumb" ]; then TTY=1; else TTY=0; fi
  if [ "$TTY" = 1 ]; then
    B=$'\033[1m'; D=$'\033[2m'; G=$'\033[32m'; R=$'\033[31m'; Y=$'\033[33m'; C=$'\033[36m'; N=$'\033[0m'
  else
    B=""; D=""; G=""; R=""; Y=""; C=""; N=""
  fi
  if [ "$TTY" = 1 ] && printf '%s' "${LANG:-}${LC_ALL:-}" | grep -qi 'utf-\?8'; then
    FULL="█"; EMPTY="░"; SPIN=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏); OKM="✓"; BADM="✗"
  else
    FULL="#"; EMPTY="."; SPIN=('|' '/' '-' '\'); OKM="OK"; BADM="GAGAL"
  fi
  BARW=30
}
log_head() { printf '\n===== %s =====\n' "$*" >>"$LOG"; }
say() { printf '%s\n' "$*"; }
die() {
  [ "${TTY:-0}" = 1 ] && printf '\r\033[K'
  say "${R}${B}GAGAL:${N} $*"
  say "Log lengkap: $LOG"
  exit 1
}
fmt_dur() { local s=$1; if [ "$s" -ge 60 ]; then printf '%dm %02dd' $((s / 60)) $((s % 60)); else printf '%dd' "$s"; fi; }
draw_bar() { # persen, label, detik berjalan, indeks spinner
  local pct=$1 label=$2 el=$3 sp=$4 fill i bar=""
  fill=$((pct * BARW / 100))
  for ((i = 0; i < BARW; i++)); do if [ $i -lt $fill ]; then bar+="$FULL"; else bar+="$EMPTY"; fi; done
  local cols=${COLUMNS:-$(tput cols 2>/dev/null || echo 80)}
  local txt="${SPIN[$sp]} ${label} ($(fmt_dur "$el"))"
  local room=$((cols - BARW - 10)); [ $room -lt 10 ] && room=10
  [ ${#txt} -gt $room ] && txt="${txt:0:$((room - 1))}…"
  printf '\r\033[K %s[%s]%s %3d%%  %s' "$C" "$bar" "$N" "$pct" "$txt"
}
banner() {
  say ""
  say "${B}ACS NETMAP Panel — installer${N}"
  say "${D}L2TP/IPsec · MongoDB · Node.js · GenieACS ${GENIE_VERSION} · Panel${N}"
  say ""
}

# ---------------------------------------------------------------------
#  Deteksi sistem dan komponen yang sudah ada
# ---------------------------------------------------------------------
unit_exists() { systemctl list-unit-files "$1.service" --no-legend 2>/dev/null | grep -q "^$1\.service"; }
detect_system() {
  [ -r /etc/os-release ] || die "Tidak bisa membaca /etc/os-release."
  . /etc/os-release
  OS_ID="${ID:-}"; OS_VER="${VERSION_ID:-}"; CODENAME="${VERSION_CODENAME:-}"
  case "$OS_ID:$OS_VER" in
    ubuntu:20.04|ubuntu:22.04|ubuntu:24.04|debian:11|debian:12) ;;
    *) die "OS ${PRETTY_NAME:-tidak dikenal} belum didukung. Pakai Ubuntu 20.04/22.04/24.04 atau Debian 11/12." ;;
  esac
  case "$(uname -m)" in
    x86_64|amd64) ARCH=amd64; NARCH=x64 ;;
    aarch64|arm64) ARCH=arm64; NARCH=arm64 ;;
    *) die "Arsitektur $(uname -m) tidak didukung (hanya x86_64 dan arm64)." ;;
  esac
  VIRT="$(systemd-detect-virt 2>/dev/null || echo none)"
  case "$VIRT" in openvz|lxc|lxc-libvirt) die "VPS ${VIRT} tidak didukung: L2TP/PPP butuh kernel sendiri. Pakai VPS KVM." ;; esac
  [ -e /dev/ppp ] || modprobe ppp_generic >/dev/null 2>&1 || true

  MEM_MB=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
  SWAP_MB=$(awk '/SwapTotal/ {print int($2/1024)}' /proc/meminfo)
  DISK_MB=$(df -Pm / | awk 'NR==2 {print $4}')
  [ "${DISK_MB:-0}" -ge 3000 ] || die "Sisa disk hanya ${DISK_MB} MB. Butuh minimal 3 GB kosong."

  # Komponen yang sudah ada: tidak diubah
  HAVE_L2TP=0; { unit_exists xl2tpd && [ -f /etc/ppp/chap-secrets ]; } && HAVE_L2TP=1
  HAVE_MONGO=0; { command -v mongod >/dev/null 2>&1 || unit_exists mongod; } && HAVE_MONGO=1
  HAVE_GENIE=0; unit_exists genieacs-cwmp && HAVE_GENIE=1
  HAVE_PATCH=0; grep -qs '/opt/genieacs-app/' /etc/systemd/system/genieacs-cwmp.service && HAVE_PATCH=1
  HAVE_PANEL=0; [ -f /opt/vpn-acs/server.js ] && HAVE_PANEL=1
  HAVE_NODE=0; NODE_NOW=""
  if command -v node >/dev/null 2>&1; then
    NODE_NOW="$(node -v 2>/dev/null)"
    [ "$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)" -ge 18 ] && HAVE_NODE=1
  fi

  # Rencana MongoDB (hanya bila belum ada)
  MONGO_VER=""; LIBSSL11=0
  if [ $HAVE_MONGO = 0 ]; then
    local cpu_ok=1
    if [ "$ARCH" = amd64 ]; then grep -qw avx /proc/cpuinfo || cpu_ok=0
    else { grep -qw atomics /proc/cpuinfo && grep -qw dcpop /proc/cpuinfo; } || cpu_ok=0; fi
    if [ "$OS_ID" = debian ] && [ "$ARCH" = arm64 ]; then
      die "MongoDB resmi tidak tersedia untuk Debian arm64. Pakai Ubuntu 22.04/24.04 arm64."
    fi
    if [ $cpu_ok = 1 ]; then
      MONGO_VER="8.0"
    else
      local why; [ "$ARCH" = amd64 ] && why="CPU tanpa AVX" || why="CPU arm64 di bawah ARMv8.2"
      case "$OS_ID:$OS_VER" in
        ubuntu:20.04) MONGO_VER="4.4" ;;
        ubuntu:22.04) MONGO_VER="4.4"; LIBSSL11=1 ;;
        debian:11)    MONGO_VER="4.4" ;;
        debian:12)    MONGO_VER="4.4"; LIBSSL11=1 ;;
        *) die "${why}: MongoDB 5.0+ tidak bisa jalan, dan MongoDB 4.4 tidak tersedia untuk ${PRETTY_NAME}. Pakai Ubuntu 22.04, atau minta provider CPU dengan AVX (host-passthrough)." ;;
      esac
      MONGO_WHY="$why"
    fi
  fi

  say "  Sistem   : ${PRETTY_NAME} · ${ARCH} · RAM ${MEM_MB} MB · disk kosong $((DISK_MB / 1024)) GB · ${VIRT}"
  line_have "VPN L2TP" $HAVE_L2TP "sudah ada, tidak diubah" "dipasang"
  if [ $HAVE_MONGO = 1 ]; then line_have "MongoDB" 1 "sudah ada ($(mongod --version 2>/dev/null | grep -oP 'db version v\K[0-9.]+' | head -1)), tidak diubah" ""
  else line_have "MongoDB" 0 "" "dipasang versi ${MONGO_VER}${MONGO_WHY:+ (${MONGO_WHY})}"; fi
  line_have "Node.js" $HAVE_NODE "sudah ada (${NODE_NOW}), tidak diubah" "dipasang versi ${NODE_MAJOR}"
  line_have "GenieACS" $HAVE_GENIE "sudah ada, tidak diubah" "dipasang versi ${GENIE_VERSION}"
  line_have "Patch IP" $HAVE_PATCH "sudah aktif" "dipasang"
  line_have "Panel" 0 "" "$([ $HAVE_PANEL = 1 ] && echo diperbarui || echo dipasang)"
  say ""
  {
    echo "OS=${PRETTY_NAME} ARCH=${ARCH} VIRT=${VIRT} RAM=${MEM_MB}MB SWAP=${SWAP_MB}MB DISK=${DISK_MB}MB"
    echo "HAVE: l2tp=$HAVE_L2TP mongo=$HAVE_MONGO node=$HAVE_NODE($NODE_NOW) genie=$HAVE_GENIE patch=$HAVE_PATCH panel=$HAVE_PANEL"
    echo "PLAN: mongo=${MONGO_VER:-skip} libssl11=$LIBSSL11"
  } >>"$LOG"
}
line_have() { # label, ada?, teks-ada, teks-baru
  if [ "$2" = 1 ]; then say "  $(printf '%-9s' "$1"): ${D}$3${N}"; else say "  $(printf '%-9s' "$1"): ${G}$4${N}"; fi
}

# ---------------------------------------------------------------------
#  Daftar langkah: fungsi | judul | perkiraan detik
# ---------------------------------------------------------------------
plan_steps() {
  STEPS=()
  STEPS+=("st_base|Menyiapkan sistem (paket dasar, swap)|60")
  STEPS+=("st_repo|Mengambil source ACS NETMAP Panel|10")
  [ $HAVE_L2TP = 0 ] && STEPS+=("st_l2tp|Memasang VPN L2TP/IPsec|40")
  [ $HAVE_MONGO = 0 ] && STEPS+=("st_mongo|Memasang MongoDB ${MONGO_VER}|120")
  # GenieACS baru butuh npm; Node lama tanpa npm ikut diganti Node ${NODE_MAJOR}
  [ $HAVE_GENIE = 0 ] && ! command -v npm >/dev/null 2>&1 && HAVE_NODE=0
  [ $HAVE_NODE = 0 ] && STEPS+=("st_node|Memasang Node.js ${NODE_MAJOR}|40")
  [ $HAVE_GENIE = 0 ] && STEPS+=("st_genie|Memasang GenieACS ${GENIE_VERSION}|90")
  [ $HAVE_PATCH = 0 ] && STEPS+=("st_patch|Membangun patch IP virtual GenieACS|300")
  STEPS+=("st_panel|$([ $HAVE_PANEL = 1 ] && echo Memperbarui || echo Memasang) panel VPN ACS|60")
  STEPS+=("st_inform|Memasang provision inform berkala|15")
  STEPS+=("st_verify|Memeriksa semua layanan|15")
  TOTAL_W=0
  local s; for s in "${STEPS[@]}"; do TOTAL_W=$((TOTAL_W + ${s##*|})); done
}

run_all() {
  local done_w=0 i=0 n=${#STEPS[@]} s fn label est
  for s in "${STEPS[@]}"; do
    i=$((i + 1)); fn="${s%%|*}"; label="${s#*|}"; label="${label%|*}"; est="${s##*|}"
    log_head "[$i/$n] $label"
    local t0=$SECONDS rc l0; l0=$(wc -l <"$LOG")
    if [ "$TTY" = 1 ]; then
      ( set -e; "$fn" ) >>"$LOG" 2>&1 </dev/null &
      local pid=$! k=0
      while kill -0 $pid 2>/dev/null; do
        local el=$((SECONDS - t0)) part
        # isi bagian langkah ini mengikuti waktu, paling banyak 95% dari bobotnya
        part=$((el * est / (est + el / 2 + 1))); [ $part -gt $((est * 95 / 100)) ] && part=$((est * 95 / 100))
        draw_bar $(((done_w + part) * 100 / TOTAL_W)) "[$i/$n] $label" "$el" $((k % ${#SPIN[@]}))
        k=$((k + 1)); sleep 0.2
      done
      wait $pid; rc=$?
      printf '\r\033[K'
    else
      say "[$i/$n] $label ..."
      ( set -e; "$fn" ) >>"$LOG" 2>&1 </dev/null; rc=$?
    fi
    local el=$((SECONDS - t0))
    if [ $rc -ne 0 ]; then
      say " ${R}${BADM}${N} [$i/$n] $label ${D}($(fmt_dur $el))${N}"
      say ""
      say "${D}--- keluaran terakhir langkah ini ---${N}"
      tail -n +"$((l0 + 1))" "$LOG" | grep -v '^\s*$' | tail -n 25 | sed 's/^/   /'
      die "Langkah \"$label\" gagal. Perbaiki penyebabnya lalu jalankan ulang perintah yang sama (aman diulang)."
    fi
    done_w=$((done_w + est))
    say " ${G}${OKM}${N} [$i/$n] $label ${D}($(fmt_dur $el))${N}"
    [ -f /tmp/acsnm-note ] && { sed 's/^/     /' /tmp/acsnm-note; rm -f /tmp/acsnm-note; }
  done
  [ "$TTY" = 1 ] && { draw_bar 100 "Selesai" $SECONDS 0; printf '\n'; }
}
note() { echo "$*" >>/tmp/acsnm-note; echo "CATATAN: $*"; }

# ---------------------------------------------------------------------
#  Langkah-langkah (jalan di subshell, set -e, keluaran ke log)
# ---------------------------------------------------------------------
apt_install() { "${APT[@]}" install --no-install-recommends "$@"; }
wait_port() { # port, detik
  local i; for ((i = 0; i < $2; i++)); do ss -Hlnt 2>/dev/null | awk '{print $4}' | grep -qE "[:.]$1$" && return 0; sleep 1; done
  return 1
}

st_base() {
  rm -f /tmp/acsnm-note
  # dpkg yang terputus di tengah jalan diselesaikan dulu
  dpkg --configure -a || true
  # needrestart tanpa dialog
  if [ -d /etc/needrestart ] || dpkg -s needrestart >/dev/null 2>&1; then
    mkdir -p /etc/needrestart/conf.d
    printf '%s\n' "\$nrconf{restart} = 'l';" "\$nrconf{kernelhints} = 0;" "\$nrconf{ucodehint} = 0;" >/etc/needrestart/conf.d/acs-netmap.conf
  fi
  "${APT[@]}" update
  apt_install ca-certificates curl wget gnupg git openssl iptables iproute2 iputils-ping python3 xz-utils procps psmisc logrotate tar
  # swap 2 GB bila RAM kecil dan belum ada swap (build patch GenieACS butuh memori)
  if [ "$SWAP_MB" -lt 512 ] && [ "$MEM_MB" -lt 3500 ] && [ ! -f /swapfile ]; then
    fallocate -l 2G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=2048 status=none
    chmod 600 /swapfile && mkswap /swapfile >/dev/null && swapon /swapfile
    grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >>/etc/fstab
    note "Swap 2 GB dibuat (/swapfile) karena RAM ${MEM_MB} MB."
  fi
  sysctl -qw net.ipv4.ip_forward=1
  grep -qs '^net.ipv4.ip_forward *= *1' /etc/sysctl.conf /etc/sysctl.d/*.conf || echo 'net.ipv4.ip_forward = 1' >/etc/sysctl.d/99-vpn-acs.conf
}

st_repo() {
  local here=""
  if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; fi
  if [ -n "$here" ] && [ -f "$here/install-vpn-acs.sh" ]; then
    echo "$here" >/tmp/acsnm-repo
    echo "Memakai repo di $here"
    return 0
  fi
  if [ -d "$REPO_DIR_DEFAULT/.git" ]; then
    git -C "$REPO_DIR_DEFAULT" pull --ff-only -q || echo "git pull gagal, memakai salinan yang ada"
  else
    rm -rf "$REPO_DIR_DEFAULT"
    git clone -q --depth 1 "$REPO_URL" "$REPO_DIR_DEFAULT"
  fi
  [ -f "$REPO_DIR_DEFAULT/install-vpn-acs.sh" ]
  echo "$REPO_DIR_DEFAULT" >/tmp/acsnm-repo
}
repo_dir() { cat /tmp/acsnm-repo; }

st_l2tp() {
  apt_install xl2tpd ppp strongswan
  # strongSwan versi baru memisahkan "starter" (ipsec.conf); pastikan ada
  dpkg -s strongswan-starter >/dev/null 2>&1 || apt_install strongswan-starter || true
  local psk; psk="$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 20)"
  [ -f /etc/ipsec.conf ] && cp -n /etc/ipsec.conf /etc/ipsec.conf.asli || true
  cat >/etc/ipsec.conf <<'EOF'
# Ditulis install.sh (ACS NETMAP Panel): L2TP/IPsec PSK untuk MikroTik
config setup
  uniqueids=no

conn l2tp-psk
  keyexchange=ikev1
  authby=secret
  type=transport
  left=%defaultroute
  leftprotoport=17/1701
  right=%any
  rightprotoport=17/%any
  auto=add
  ike=aes256-sha256-modp2048,aes256-sha1-modp2048,aes128-sha1-modp2048,aes256-sha1-modp1024,aes128-sha1-modp1024,3des-sha1-modp1024
  esp=aes256-sha256,aes256-sha1,aes128-sha1,3des-sha1
  ikelifetime=24h
  lifetime=8h
  dpddelay=30
  dpdtimeout=120
  dpdaction=clear
  rekey=no
EOF
  umask 077
  printf '%s\n' "# Ditulis install.sh (ACS NETMAP Panel)" "%any %any : PSK \"${psk}\"" >/etc/ipsec.secrets
  umask 022
  mkdir -p /etc/xl2tpd
  [ -f /etc/xl2tpd/xl2tpd.conf ] && cp -n /etc/xl2tpd/xl2tpd.conf /etc/xl2tpd/xl2tpd.conf.asli || true
  cat >/etc/xl2tpd/xl2tpd.conf <<EOF
; Ditulis install.sh (ACS NETMAP Panel). "local ip" dan "ip range" diatur panel.
[global]
port = 1701

[lns default]
ip range = ${VPN_POOL}
local ip = ${VPN_NET_LOCAL}
require chap = yes
refuse pap = yes
require authentication = yes
name = l2tpd
pppoptfile = /etc/ppp/options.xl2tpd
length bit = yes
EOF
  cat >/etc/ppp/options.xl2tpd <<'EOF'
# Ditulis install.sh (ACS NETMAP Panel)
+mschap-v2
ipcp-accept-local
ipcp-accept-remote
noccp
auth
mtu 1280
mru 1280
proxyarp
lcp-echo-failure 4
lcp-echo-interval 30
connect-delay 5000
ms-dns 1.1.1.1
ms-dns 8.8.8.8
EOF
  [ -f /etc/ppp/chap-secrets ] || printf '%s\n' '# Secrets for authentication using CHAP' '# client  server  secret  IP addresses' >/etc/ppp/chap-secrets
  chmod 600 /etc/ppp/chap-secrets
  mkdir -p /etc/ppp/ip-up.d
  local u
  for u in strongswan-starter strongswan ipsec; do
    if unit_exists "$u"; then systemctl enable "$u" >/dev/null 2>&1 || true; systemctl restart "$u"; break; fi
  done
  systemctl enable xl2tpd >/dev/null 2>&1 || true
  systemctl restart xl2tpd
  sleep 1
  systemctl is-active --quiet xl2tpd
  echo "L2TP siap, PSK baru dibuat"
}

pool_latest() { # url-pool, pola-awal, arsitektur -> nama berkas terbaru
  curl -fsSL "$1" | grep -oE "${2}[^\"<>]*_${3}\.deb" | sort -uV | tail -1
}
st_mongo() {
  local key="/usr/share/keyrings/mongodb-server-${MONGO_VER}.gpg" list="/etc/apt/sources.list.d/mongodb-org-${MONGO_VER}.list" suite
  curl -fsSL "https://www.mongodb.org/static/pgp/server-${MONGO_VER}.asc" | gpg --dearmor --yes -o "$key"
  if [ "$OS_ID" = ubuntu ]; then
    if [ "$MONGO_VER" = 8.0 ]; then suite="$CODENAME"; else suite="focal"; fi
    echo "deb [ arch=${ARCH} signed-by=${key} ] https://repo.mongodb.org/apt/ubuntu ${suite}/mongodb-org/${MONGO_VER} multiverse" >"$list"
  else
    if [ "$MONGO_VER" = 8.0 ]; then suite="$CODENAME"; else suite="buster"; fi
    echo "deb [ signed-by=${key} ] https://repo.mongodb.org/apt/debian ${suite}/mongodb-org/${MONGO_VER} main" >"$list"
  fi
  if [ "$LIBSSL11" = 1 ] && ! dpkg -s libssl1.1 >/dev/null 2>&1; then
    # MongoDB 4.4 butuh libssl1.1 (tidak ada lagi di OS baru): ambil dari arsip resmi distro
    local base f
    if [ "$OS_ID" = ubuntu ]; then
      [ "$ARCH" = amd64 ] && base="http://archive.ubuntu.com/ubuntu/pool/main/o/openssl/" || base="http://ports.ubuntu.com/ubuntu-ports/pool/main/o/openssl/"
      f="$(pool_latest "$base" 'libssl1\.1_1\.1\.1f-1ubuntu2' "$ARCH")"
    else
      base="http://deb.debian.org/debian/pool/main/o/openssl/"
      f="$(pool_latest "$base" 'libssl1\.1_1\.1\.1' "$ARCH")"
    fi
    [ -n "$f" ] || { echo "libssl1.1 tidak ditemukan di $base"; return 1; }
    curl -fsSL -o "/tmp/$f" "$base$f"
    dpkg -i "/tmp/$f" || "${APT[@]}" install -f
    rm -f "/tmp/$f"
  fi
  "${APT[@]}" update
  apt_install mongodb-org
  systemctl daemon-reload
  systemctl enable mongod >/dev/null 2>&1 || true
  systemctl restart mongod
  if ! wait_port 27017 60; then
    journalctl -u mongod -n 30 --no-pager || true
    echo "MongoDB tidak berjalan. Bila kernel 6.19 s/d 7.0.13, MongoDB 8.0 diketahui gagal start (lihat catatan rilis MongoDB)."
    return 1
  fi
  mongod --version | head -1
}

st_node() {
  local base="https://nodejs.org/dist/latest-v${NODE_MAJOR}.x" f tmp
  tmp="$(mktemp -d)"
  curl -fsSL -o "$tmp/SHASUMS256.txt" "$base/SHASUMS256.txt"
  f="$(grep -oE "node-v[0-9.]+-linux-${NARCH}\.tar\.xz" "$tmp/SHASUMS256.txt" | head -1)"
  [ -n "$f" ] || { echo "Berkas Node.js untuk ${NARCH} tidak ditemukan"; return 1; }
  curl -fsSL -o "$tmp/$f" "$base/$f"
  (cd "$tmp" && grep " $f\$" SHASUMS256.txt | sha256sum -c -)
  tar -xJf "$tmp/$f" -C /usr/local --strip-components=1 --no-same-owner \
    --exclude='*/CHANGELOG.md' --exclude='*/LICENSE' --exclude='*/README.md'
  rm -rf "$tmp"
  hash -r
  /usr/local/bin/node -v
  /usr/local/bin/npm -v
}

st_genie() {
  export PATH="/usr/local/bin:$PATH"
  npm install -g --no-audit --no-fund --loglevel=error "genieacs@${GENIE_VERSION}"
  local s bin
  for s in cwmp nbi fs ui; do
    bin="$(command -v "genieacs-$s")"
    [ -x "/usr/bin/genieacs-$s" ] || ln -sf "$bin" "/usr/bin/genieacs-$s"
  done
  id genieacs >/dev/null 2>&1 || useradd --system --no-create-home --user-group genieacs
  mkdir -p /opt/genieacs/ext /var/log/genieacs
  chown genieacs:genieacs /opt/genieacs/ext /var/log/genieacs
  if [ ! -f /opt/genieacs/genieacs.env ]; then
    cat >/opt/genieacs/genieacs.env <<EOF
GENIEACS_CWMP_ACCESS_LOG_FILE=/var/log/genieacs/genieacs-cwmp-access.log
GENIEACS_NBI_ACCESS_LOG_FILE=/var/log/genieacs/genieacs-nbi-access.log
GENIEACS_FS_ACCESS_LOG_FILE=/var/log/genieacs/genieacs-fs-access.log
GENIEACS_UI_ACCESS_LOG_FILE=/var/log/genieacs/genieacs-ui-access.log
GENIEACS_DEBUG_FILE=/var/log/genieacs/genieacs-debug.yaml
NODE_OPTIONS=--enable-source-maps
GENIEACS_EXT_DIR=/opt/genieacs/ext
GENIEACS_UI_JWT_SECRET=$(openssl rand -hex 32)
GENIEACS_NBI_INTERFACE=127.0.0.1
EOF
  fi
  chown genieacs:genieacs /opt/genieacs/genieacs.env
  chmod 600 /opt/genieacs/genieacs.env
  local desc
  for s in cwmp nbi fs ui; do
    case $s in cwmp) desc="GenieACS CWMP" ;; nbi) desc="GenieACS NBI" ;; fs) desc="GenieACS FS" ;; ui) desc="GenieACS UI" ;; esac
    cat >"/etc/systemd/system/genieacs-$s.service" <<EOF
[Unit]
Description=${desc}
After=network.target mongod.service

[Service]
User=genieacs
EnvironmentFile=/opt/genieacs/genieacs.env
ExecStart=/usr/bin/genieacs-$s
Restart=always
RestartSec=5

[Install]
WantedBy=default.target
EOF
  done
  cat >/etc/logrotate.d/genieacs <<'EOF'
/var/log/genieacs/*.log /var/log/genieacs/*.yaml {
    daily
    rotate 30
    compress
    delaycompress
    dateext
}
EOF
  systemctl daemon-reload
  for s in cwmp nbi fs ui; do systemctl enable "genieacs-$s" >/dev/null 2>&1; systemctl restart "genieacs-$s"; done
  wait_port 7547 60 && wait_port 7557 60 && wait_port 3000 60
  echo "GenieACS ${GENIE_VERSION} berjalan"
}

st_patch() {
  export PATH="/usr/local/bin:$PATH" VPNACS_NO_SUMMARY=1
  # Keberhasilan dinilai dari hasilnya (service memakai versi patch dan berjalan), bukan kode keluar skrip
  bash "$(repo_dir)/genieacs-virtualip.sh" install || echo "genieacs-virtualip.sh keluar dengan kode $?"
  grep -q '/opt/genieacs-app/' /etc/systemd/system/genieacs-cwmp.service || { echo "Service GenieACS belum memakai versi patch"; return 1; }
  grep -q 'GENIEACS_CR_USE_REMOTE_ADDRESS' /opt/genieacs-app/bin/genieacs-cwmp || { echo "Hasil build tidak berisi patch"; return 1; }
  local s; for s in cwmp nbi fs ui; do systemctl is-active --quiet "genieacs-$s" || { echo "genieacs-$s tidak berjalan"; return 1; }; done
  wait_port 7557 60
}

st_panel() {
  export PATH="/usr/local/bin:$PATH"
  local pw=""
  if [ $HAVE_PANEL = 0 ] || ! grep -qs '"admin"' /opt/vpn-acs/data.json; then
    pw="$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 14)"
    echo "$pw" >/tmp/acsnm-pw; chmod 600 /tmp/acsnm-pw
  fi
  VPNACS_ADMIN_PASSWORD="$pw" bash "$(repo_dir)/install-vpn-acs.sh"
  systemctl is-active --quiet vpn-acs
  # ufw aktif: buka port yang dibutuhkan (README menyarankan ufw tetap mati)
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw allow 1701/udp; ufw allow 80/tcp; ufw allow 443/tcp; ufw allow 8088/tcp; ufw allow 3000/tcp
    ufw allow in on ppp+ to any port 7547 proto tcp || true
    note "ufw aktif: port 1701/udp, 80, 443, 8088, 3000 dibuka."
  fi
}

st_inform() {
  export PATH="/usr/local/bin:$PATH"
  node /opt/vpn-acs/server.js --genie-inform 300
}

st_verify() {
  local bad=0 u
  for u in xl2tpd mongod genieacs-cwmp genieacs-nbi genieacs-fs genieacs-ui vpn-acs; do
    if systemctl is-active --quiet "$u"; then echo "OK   $u"; else echo "MATI $u"; bad=1; fi
  done
  ss -Hlnt | awk '{print $4}' | grep -E '[:.]7557$' | grep -qvE '^(127\.0\.0\.1|\[::1\]):' && { echo "NBI terbuka ke luar!"; bad=1; }
  [ $bad = 0 ] || { echo "Ada layanan yang tidak berjalan"; return 1; }
}

# ---------------------------------------------------------------------
#  Ringkasan akhir (layar + /root/acs-netmap-info.txt)
# ---------------------------------------------------------------------
public_ip() {
  local ip
  ip="$(curl -4 -fsS -m 6 https://api.ipify.org 2>/dev/null || true)"
  [ -n "$ip" ] || ip="$(curl -4 -fsS -m 6 https://ifconfig.me 2>/dev/null || true)"
  [ -n "$ip" ] || ip="$(ip -4 route get 1.1.1.1 2>/dev/null | grep -oP 'src \K[0-9.]+' | head -1)"
  echo "$ip"
}
finish() {
  local ip pw psk tun std ui_port repo
  ip="$(public_ip)"
  pw="$(cat /tmp/acsnm-pw 2>/dev/null || true)"
  repo="$(cat /tmp/acsnm-repo 2>/dev/null || echo "$REPO_DIR_DEFAULT")"
  rm -f /tmp/acsnm-pw /tmp/acsnm-repo
  psk="$(grep -oP 'PSK\s+"\K[^"]*' /etc/ipsec.secrets 2>/dev/null | head -1)"
  tun="$(node -e 'try{const s=require("/opt/vpn-acs/data.json").settings||{};console.log((s.tunnelNet||"192.168.42.0/24").replace(/\.0\/\d+$/,".1"))}catch(e){console.log("192.168.42.1")}' 2>/dev/null || echo 192.168.42.1)"
  std="$(ss -Hltnp 2>/dev/null | grep -E '[:.]80[[:space:]]' | grep -q node && echo 1 || echo 0)"
  ui_port="$(grep -oP '^GENIEACS_UI_PORT=\K[0-9]+' /opt/genieacs/genieacs.env 2>/dev/null || echo 3000)"
  local panel_url; [ "$std" = 1 ] && panel_url="http://${ip}" || panel_url="http://${ip}:8088"
  {
    echo "ACS NETMAP Panel — info pemasangan ($(date '+%F %T'))"
    echo "Simpan berkas ini baik-baik, lalu hapus bila sudah dicatat: rm $INFO"
    echo
    if [ "$std" = 1 ]; then echo "Panel VPN ACS    : ${panel_url}   (cadangan: http://${ip}:8088)"
    else echo "Panel VPN ACS    : ${panel_url}"; fi
    if [ -n "$pw" ]; then echo "Password admin   : ${pw}"
    else echo "Password admin   : (tidak berubah, pakai password lama)"; fi
    echo "GenieACS UI      : http://${ip}:${ui_port}   (pertama kali: buat akun admin di wizard)"
    echo "URL ACS di ONT   : http://${tun}:7547   (lewat VPN, sama untuk semua router)"
    [ -n "$psk" ] && echo "PSK IPsec        : ${psk}   (hanya dipakai bila IPsec dinyalakan di panel)"
    echo
    echo "Port yang dibuka di firewall provider: 22/tcp, 1701/udp, 80/tcp, 443/tcp, 8088/tcp, 3000/tcp, 20001-20999/tcp"
    echo "Tes semua layanan : bash ${repo}/cek.sh"
    echo "Log pemasangan    : $LOG"
  } >"$INFO"
  chmod 600 "$INFO"
  log_head "Selesai $(date '+%F %T')"
  say ""
  say "${G}${B}Pemasangan selesai.${N}"
  say ""
  sed -n '4,9p' "$INFO" | sed 's/^/  /'
  say ""
  say "  Info di atas juga disimpan di ${B}${INFO}${N} (hanya root yang bisa membaca)."
  [ -n "$pw" ] && say "  ${Y}Catat password admin sekarang; panel tidak menampilkannya lagi.${N}"
  say ""
}

main "$@"
