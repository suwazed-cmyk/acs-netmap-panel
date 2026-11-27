#!/bin/bash
# =====================================================================
#  GenieACS Virtual IP Patch (NETMAP) - untuk GenieACS v1.2.13 s/d v1.2.16
#  Membuat GenieACS memakai IP virtual (IP pengirim Inform hasil NETMAP
#  MikroTik) pada ConnectionRequestURL, sehingga Summon menuju IP virtual.
#
#  Pemakaian (sebagai root):
#    bash genieacs-virtualip.sh            -> pasang / pasang ulang patch
#    bash genieacs-virtualip.sh rollback   -> kembali ke GenieACS asli (npm)
#    bash genieacs-virtualip.sh status     -> cek status
#
#  VIRTUAL_CIDR hanya nilai awal. Jika Panel VPN ACS terpasang, panel
#  mengatur rentang ini sendiri mengikuti IP virtual setiap router
#  (menu GenieACS di panel), jadi tidak perlu diubah di sini.
#  Contoh 10.100.0.0/14 mencakup 10.100.x.x s/d 10.103.x.x.
# =====================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VIRTUAL_CIDR="10.100.0.0/14"
# Versi source mengikuti GenieACS yang terpasang (npm -g): 1.2.13 dari genie.sh, 1.2.16 dari install.sh.
# Bisa dipaksa: GENIE_TAG=v1.2.16 bash genieacs-virtualip.sh
installed_genie_version() {
  local f
  for f in /usr/lib/node_modules/genieacs/package.json /usr/local/lib/node_modules/genieacs/package.json; do
    [ -f "$f" ] && { grep -oP '"version":\s*"\K[0-9.]+' "$f" | head -1; return; }
  done
}
GV="$(installed_genie_version || true)"
case "$GV" in 1.2.13|1.2.14|1.2.15|1.2.16) GENIE_TAG="${GENIE_TAG:-v$GV}" ;; *) GENIE_TAG="${GENIE_TAG:-v1.2.13}" ;; esac

SRC_DIR="/opt/genieacs-src"
APP_DIR="/opt/genieacs-app"
ENV_FILE="/opt/genieacs/genieacs.env"
SERVICES="cwmp nbi fs ui"

set -euo pipefail
GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
ok()   { echo -e "${GREEN}[OK]${NC} $*"; }
fail() { echo -e "${RED}[GAGAL]${NC} $*"; exit 1; }

[ "$(id -u)" -eq 0 ] || fail "Jalankan sebagai root"
[ -f "$ENV_FILE" ] || fail "$ENV_FILE tidak ada. Install GenieACS dengan genie.sh dulu."
for s in $SERVICES; do
  [ -f "/etc/systemd/system/genieacs-$s.service" ] || fail "Service genieacs-$s tidak ditemukan"
done
NODE_BIN="$(command -v node || true)"
[ -n "$NODE_BIN" ] || fail "Node.js tidak ditemukan"

set_env() {
  local key="$1" val="$2"
  if grep -q "^${key}=" "$ENV_FILE"; then
    sed -i "s#^${key}=.*#${key}=${val}#" "$ENV_FILE"
  else
    echo "${key}=${val}" >> "$ENV_FILE"
  fi
}

restart_all() {
  systemctl daemon-reload
  for s in $SERVICES; do systemctl restart "genieacs-$s"; done
  sleep 3
  for s in $SERVICES; do
    if systemctl is-active --quiet "genieacs-$s"; then ok "genieacs-$s berjalan"
    else echo -e "${RED}[GAGAL]${NC} genieacs-$s tidak berjalan, cek: journalctl -u genieacs-$s -n 50"; fi
  done
}

do_status() {
  for s in $SERVICES; do
    echo "genieacs-$s : $(systemctl is-active genieacs-$s)  $(grep '^ExecStart=' /etc/systemd/system/genieacs-$s.service)"
  done
  echo "Setting : $(grep '^GENIEACS_CR_USE_REMOTE_ADDRESS=' "$ENV_FILE" || echo 'GENIEACS_CR_USE_REMOTE_ADDRESS belum diset (nonaktif)')"
}

do_rollback() {
  for s in $SERVICES; do
    local bin="/usr/bin/genieacs-$s"; [ -x "$bin" ] || bin="$(command -v "genieacs-$s" || echo "$bin")"
    sed -i "s#^ExecStart=.*#ExecStart=${bin}#" "/etc/systemd/system/genieacs-$s.service"
  done
  sed -i '/^GENIEACS_CR_USE_REMOTE_ADDRESS=/d' "$ENV_FILE"
  restart_all
  ok "Kembali ke GenieACS asli (tanpa patch)"
}

do_install() {
  echo -e "${GREEN}== Install paket pendukung ==${NC}"
  export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1
  apt-get -o DPkg::Lock::Timeout=900 update -qq </dev/null
  apt-get -o DPkg::Lock::Timeout=900 -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold install -y -qq git python3 ca-certificates </dev/null >/dev/null
  ok "git & python3 siap"

  echo -e "${GREEN}== Ambil source GenieACS ${GENIE_TAG} ==${NC}"
  rm -rf "$SRC_DIR"
  git clone -q --depth 1 --branch "$GENIE_TAG" https://github.com/genieacs/genieacs.git "$SRC_DIR"
  ok "Source di $SRC_DIR"

  echo -e "${GREEN}== Tulis patch ==${NC}"
  cat > "$SRC_DIR/lib/virtual-ip.ts" <<'TSEOF'
// Patch IP virtual (NETMAP) untuk GenieACS
// Mengganti host pada ManagementServer.ConnectionRequestURL dengan IP pengirim
// Inform/GPV (IP virtual hasil NETMAP MikroTik), supaya summon menuju IP virtual.
//
// Diaktifkan lewat variabel lingkungan di /opt/genieacs/genieacs.env:
//   GENIEACS_CR_USE_REMOTE_ADDRESS=10.100.0.0/14      (hanya IP pengirim di CIDR ini)
//   GENIEACS_CR_USE_REMOTE_ADDRESS=10.101.0.0/24,10.102.0.0/24
//   GENIEACS_CR_USE_REMOTE_ADDRESS=all                (semua perangkat)
// Kosong / tidak diisi = nonaktif (perilaku GenieACS asli).

import { IncomingMessage } from "node:http";
import { parseCIDR, parse, IPv4, IPv6 } from "ipaddr.js";
import { getRequestOrigin } from "./forwarded.ts";

const SETTING = (process.env["GENIEACS_CR_USE_REMOTE_ADDRESS"] || "").trim();
const ALL = ["all", "true", "1", "yes"].includes(SETTING.toLowerCase());
const CIDRS: [IPv4 | IPv6, number][] = [];

if (!ALL && SETTING) {
  for (const s of SETTING.split(",").map((x) => x.trim())) {
    if (!s) continue;
    try {
      CIDRS.push(parseCIDR(s));
    } catch (err) {
      try {
        const ip = parse(s);
        CIDRS.push([ip, ip.toByteArray().length * 8]);
      } catch (err2) {
        // abaikan nilai yang tidak valid
      }
    }
  }
}

const ENABLED = ALL || CIDRS.length > 0;
const SUFFIX = ".ManagementServer.ConnectionRequestURL";

function normalize(addr: string): string {
  if (!addr) return "";
  if (addr.startsWith("::ffff:")) return addr.slice(7);
  return addr;
}

function allowed(addr: string): boolean {
  if (ALL) return true;
  try {
    let ip = parse(addr);
    if (ip.kind() === "ipv6" && (ip as IPv6).isIPv4MappedAddress())
      ip = (ip as IPv6).toIPv4Address();
    return CIDRS.some((c) => ip.kind() === c[0].kind() && ip.match(c));
  } catch (err) {
    return false;
  }
}

export function rewriteConnectionRequestUrl(
  httpRequest: IncomingMessage,
  path: string,
  value: unknown,
): unknown {
  if (!ENABLED || typeof value !== "string" || !path.endsWith(SUFFIX))
    return value;
  if (!httpRequest) return value;

  const remote = normalize(getRequestOrigin(httpRequest).remoteAddress);
  if (!remote || !allowed(remote)) return value;

  const host = remote.includes(":") ? `[${remote}]` : remote;
  return value.replace(
    /^([a-zA-Z][a-zA-Z0-9+.-]*:\/\/(?:[^@/?#]*@)?)(\[[^\]]*\]|[^:/?#]*)/,
    `$1${host}`,
  );
}
TSEOF

  cat > /tmp/genieacs_patch_session.py <<'PYEOF'
import sys

f = sys.argv[1]
s = open(f, encoding="utf-8").read()

if "rewriteConnectionRequestUrl" in s:
    print("session.ts sudah di-patch, dilewati")
    sys.exit(0)

imp = 'import { getRequestOrigin } from "./forwarded.ts";\n'
assert imp in s, "import getRequestOrigin tidak ditemukan"
s = s.replace(imp, imp + 'import { rewriteConnectionRequestUrl } from "./virtual-ip.ts";\n', 1)

old_inform = """  for (const p of rpcReq.parameterList) {
    const path = p[0];
    params.push([
      path,
      timestamp,
      {
        object: [timestamp, 0],
        value: [timestamp, p.slice(1) as [string | number | boolean, string]],
      },
    ]);
  }"""
new_inform = """  for (const p of rpcReq.parameterList) {
    const path = p[0];
    const v = rewriteConnectionRequestUrl(
      sessionContext.httpRequest,
      path.toString(),
      p[1],
    ) as string | number | boolean;
    params.push([
      path,
      timestamp,
      {
        object: [timestamp, 0],
        value: [timestamp, [v, p[2]] as [string | number | boolean, string]],
      },
    ]);
  }"""
assert s.count(old_inform) == 1, "blok Inform tidak cocok"
s = s.replace(old_inform, new_inform)

old_gpv = """    for (const [path, value, type] of rpcRes.parameterList) {
      if (!requested.delete(path.toString())) {"""
new_gpv = """    for (const [path, _value, type] of rpcRes.parameterList) {
      const value = rewriteConnectionRequestUrl(
        sessionContext.httpRequest,
        path.toString(),
        _value,
      ) as typeof _value;
      if (!requested.delete(path.toString())) {"""
assert s.count(old_gpv) == 1, "blok GetParameterValues tidak cocok"
s = s.replace(old_gpv, new_gpv)

open(f, "w", encoding="utf-8").write(s)
print("session.ts berhasil di-patch")
PYEOF
  python3 /tmp/genieacs_patch_session.py "$SRC_DIR/lib/session.ts"
  rm -f /tmp/genieacs_patch_session.py

  echo -e "${GREEN}== Build GenieACS (beberapa menit) ==${NC}"
  cd "$SRC_DIR"
  npm ci --no-audit --no-fund --loglevel=error
  npm run build --silent
  grep -q "GENIEACS_CR_USE_REMOTE_ADDRESS" dist/bin/genieacs-cwmp || fail "Patch tidak masuk ke hasil build"
  ok "Build selesai"

  echo -e "${GREEN}== Pasang ke $APP_DIR ==${NC}"
  rm -rf "${APP_DIR}.new"
  cp -r dist "${APP_DIR}.new"
  cd "${APP_DIR}.new"
  npm ci --omit=dev --no-audit --no-fund --loglevel=error
  rm -rf "$APP_DIR"
  mv "${APP_DIR}.new" "$APP_DIR"
  ok "Aplikasi terpasang di $APP_DIR"

  echo -e "${GREEN}== Arahkan service systemd ke versi patch ==${NC}"
  for s in $SERVICES; do
    sed -i "s#^ExecStart=.*#ExecStart=${NODE_BIN} ${APP_DIR}/bin/genieacs-$s#" "/etc/systemd/system/genieacs-$s.service"
  done
  set_env "GENIEACS_CR_USE_REMOTE_ADDRESS" "$VIRTUAL_CIDR"
  ok "GENIEACS_CR_USE_REMOTE_ADDRESS=$VIRTUAL_CIDR"

  restart_all
  echo
  # Panel mengatur rentang IP virtual sendiri: restart agar langsung disesuaikan
  if systemctl is-active --quiet vpn-acs; then
    systemctl restart vpn-acs
    sleep 2
    ok "Rentang disesuaikan oleh Panel VPN ACS: $(grep '^GENIEACS_CR_USE_REMOTE_ADDRESS=' "$ENV_FILE" | cut -d= -f2)"
  fi
  ok "Selesai. Summon akan memakai IP virtual setelah ONT Inform 1x."
  echo "Cek: journalctl -u genieacs-cwmp -n 20 | grep version  (harus ada '+' di versi)"
  local summary
  summary="$SCRIPT_DIR/ringkasan.sh"
  if [ -f "$summary" ] && [ -z "${VPNACS_NO_SUMMARY:-}" ]; then bash "$summary" || true; fi
  return 0
}

case "${1:-install}" in
  install)  do_install ;;
  rollback) do_rollback ;;
  status)   do_status ;;
  *) echo "Pemakaian: $0 [install|rollback|status]"; exit 1 ;;
esac
