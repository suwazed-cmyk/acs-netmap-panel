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

# prisma.config.ts ikut terbawa file tracing dan butuh dotenv/tsx: tidak dipakai (skema diberikan langsung)
rm -f "$APP/prisma.config.ts"

echo "== Alat migrasi + seed"
# Hanya Prisma CLI (migrate deploy). Seed memakai @prisma/client milik aplikasi (node_modules di atasnya).
T="$APP/.tools"
mkdir -p "$T/bin"
cat > "$T/package.json" <<JSON
{ "name": "ztnet-tools", "private": true }
JSON
( cd "$T" && PRISMA_CLI_BINARY_TARGETS="debian-openssl-3.0.x,linux-arm64-openssl-3.0.x" \
    npm install --no-audit --no-fund --omit=dev "prisma@$PRISMA_VER" )
npx --yes esbuild@0.24.0 prisma/seed.ts --bundle --platform=node --target=node20 \
  --external:@prisma/client --outfile="$T/seed.js"
cp ztnodeid/build/linux_amd64/ztmkworld "$T/bin/ztmkworld-amd64"
cp ztnodeid/build/linux_arm64/ztmkworld "$T/bin/ztmkworld-arm64"
chmod +x "$T/bin/"*
echo "$VER" > "$APP/.ztnet-version"

echo "== Pangkas berkas yang tidak dipakai"
# mesin untuk OpenSSL 1.1 (sistem lama, tidak didukung), salinan mesin query di folder CLI,
# library gambar untuk Alpine/musl dan wasm, driver database selain PostgreSQL, berkas tipe & peta sumber
find "$APP" -depth -name "*openssl-1.1.x*" -exec rm -rf {} +
rm -f "$T/node_modules/prisma/libquery_engine-"*
rm -rf "$APP"/node_modules/@img/sharp-libvips-linuxmusl-* "$APP"/node_modules/@img/sharp-linuxmusl-* "$APP"/node_modules/@img/sharp-wasm32
find "$APP/node_modules/@prisma/client/runtime" -type f \( -name "*.mysql.*" -o -name "*.sqlite.*" -o -name "*.sqlserver.*" -o -name "*.cockroachdb.*" \) -delete
find "$APP" -path "$APP/.next" -prune -o -type f \( -name "*.map" -o -name "*.d.ts" -o -name "*.d.mts" -o -name "*.d.cts" \) -print0 | xargs -0 rm -f
du -sh "$APP"

echo "== Paket per arsitektur"
for arch in amd64 arm64; do
  D="$WORK/pkg-$arch/ztnet"
  rm -rf "$WORK/pkg-$arch"; mkdir -p "$WORK/pkg-$arch"
  cp -a "$APP" "$D"
  # buang mesin/library untuk arsitektur lain
  if [ "$arch" = amd64 ]; then pats=("*linux-arm64*"); else pats=("*debian-openssl*" "*linux-x64*"); fi
  for pat in "${pats[@]}"; do find "$D" -depth -name "$pat" -exec rm -rf {} +; done
  if [ "$arch" = amd64 ]; then rm -f "$D/.tools/bin/ztmkworld-arm64"; else rm -f "$D/.tools/bin/ztmkworld-amd64"; fi
  F="ztnet-$VER-linux-$arch.tar.gz"
  tar -C "$WORK/pkg-$arch" -czf "$OUT/$F" ztnet
  ( cd "$OUT" && sha256sum "$F" > "$F.sha256" )
  ls -la "$OUT/$F"
done
