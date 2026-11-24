#!/bin/bash
# Membangun paket ZTNET siap pakai (dijalankan GitHub Actions, bukan di VPS).
# Hasil: ztnet-<versi>-linux-amd64.tar.gz dan ztnet-<versi>-linux-arm64.tar.gz
# Isi paket: web ZTNET hasil build (Next.js standalone), skema + migrasi database,
# alat migrasi Prisma, seed dalam bentuk JS, dan ztmkworld. VPS tidak perlu npm install / build.
set -euo pipefail
VER="${1:?versi ZTNET, mis. v0.8.7}"
WORK="${WORK:-$PWD/work}"
OUT="${OUT:-$PWD/dist}"
PRISMA_VER=""
rm -rf "$WORK" "$OUT"; mkdir -p "$WORK" "$OUT"

echo "== Unduh ZTNET $VER"
git clone -q --depth 1 --branch "$VER" https://github.com/sinamics/ztnet.git "$WORK/src"
cd "$WORK/src"
PRISMA_VER="$(node -p 'require("./package.json").dependencies.prisma.replace(/^[^0-9]*/, "")')"
echo "Prisma $PRISMA_VER"

echo "== npm ci"
npm ci --no-audit --no-fund

echo "== Build"
NEXT_TELEMETRY_DISABLED=1 SKIP_ENV_VALIDATION=1 NEXT_PUBLIC_APP_VERSION="$VER" npm run build

echo "== Susun paket"
APP="$WORK/ztnet"
mkdir -p "$APP/.next"
cp -a .next/standalone/. "$APP/"
cp -a .next/static "$APP/.next/static"
cp -a public "$APP/public"
cp package.json next.config.mjs "$APP/"
mkdir -p "$APP/prisma"
cp -a prisma/schema.prisma prisma/migrations "$APP/prisma/"
# mesin Prisma untuk kedua arsitektur (file tracing Next kadang hanya membawa yang native)
mkdir -p "$APP/node_modules/.prisma/client"
cp -a node_modules/.prisma/client/. "$APP/node_modules/.prisma/client/"

echo "== Alat migrasi + seed"
T="$APP/.tools"
mkdir -p "$T/bin"
cat > "$T/package.json" <<JSON
{ "name": "ztnet-tools", "private": true }
JSON
( cd "$T" && PRISMA_CLI_BINARY_TARGETS="debian-openssl-3.0.x,linux-arm64-openssl-3.0.x" \
    npm install --no-audit --no-fund --omit=dev "prisma@$PRISMA_VER" "@prisma/client@$PRISMA_VER" @paralleldrive/cuid2 )
( cd "$T" && npx prisma generate --schema "$APP/prisma/schema.prisma" )
npx --yes esbuild@0.24.0 prisma/seed.ts --bundle --platform=node --target=node20 \
  --external:@prisma/client --outfile="$T/seed.js"
cp ztnodeid/build/linux_amd64/ztmkworld "$T/bin/ztmkworld-amd64"
cp ztnodeid/build/linux_arm64/ztmkworld "$T/bin/ztmkworld-arm64"
chmod +x "$T/bin/"*
echo "$VER" > "$APP/.ztnet-version"

echo "== Paket per arsitektur"
for arch in amd64 arm64; do
  D="$WORK/pkg-$arch/ztnet"
  rm -rf "$WORK/pkg-$arch"; mkdir -p "$WORK/pkg-$arch"
  cp -a "$APP" "$D"
  if [ "$arch" = amd64 ]; then other="linux-arm64"; else other="debian-openssl"; fi
  find "$D" \( -name "*${other}*" \) -type f -print -delete | sed 's/^/  hapus /' | head -20
  if [ "$arch" = amd64 ]; then rm -f "$D/.tools/bin/ztmkworld-arm64"; else rm -f "$D/.tools/bin/ztmkworld-amd64"; fi
  F="ztnet-$VER-linux-$arch.tar.gz"
  tar -C "$WORK/pkg-$arch" -czf "$OUT/$F" ztnet
  ( cd "$OUT" && sha256sum "$F" > "$F.sha256" )
  ls -la "$OUT/$F"
done
