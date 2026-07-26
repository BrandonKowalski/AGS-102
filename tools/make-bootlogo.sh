#!/bin/sh
# Generate one target's static bootlogo from the fbsplash renderer.
# Boot0/U-Boot shows it from the boot-resource partition; build-image.sh writes
# the result onto p2.
# Output format matches the selected device: native dimensions, 24bpp,
# uncompressed BMP, pre-turned for a panel that is mounted turned (the renderer
# does that, so the BMP holds exactly the pixels the panel scans out — the same
# convention as the vendor's own bootlogo). The artifact is written beneath
# work/<target>/.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
BASE="$HERE/.."
# shellcheck source=docker-platform.sh
. "$HERE/docker-platform.sh"
TARGET="${1:?usage: $0 <target>}"
[ "$#" -eq 1 ] || { echo "usage: $0 <target>" >&2; exit 2; }
eval "$(python3 "$HERE/device_profile.py" shell "$TARGET")"
OUT="$BASE/work/$TARGET/bootlogo.bmp"
mkdir -p "$(dirname "$OUT")"

# Host-native: compiles a host test binary and writes a BMP. Explicit host
# platform avoids a cached arm64 image on Intel.
docker run --rm --platform "$BASEOS_DOCKER_PLATFORM_HOST" \
  -v "$BASE/src":/src:ro -v "$BASE/assets":/assets:ro \
  -v "$BASE/work/$TARGET":/out \
  -e WIDTH="$PROFILE_BOOTLOGO_WIDTH" -e HEIGHT="$PROFILE_BOOTLOGO_HEIGHT" \
  -e ROTATION="$PROFILE_PANEL_ROTATION_CCW" \
  alpine:3.20 sh -euc '
  apk add -q build-base linux-headers pkgconf freetype-dev freetype-static \
    zlib-static libpng-static bzip2-static brotli-static imagemagick
  mkdir -p /usr/share/baseos && cp /assets/boot.ttf /usr/share/baseos/boot.ttf
  gcc -DFBSPLASH_TEST -O2 $(pkg-config --cflags freetype2) -o /tmp/fbtest \
    /src/fbsplash.c $(pkg-config --static --libs freetype2)
  /tmp/fbtest 100 "" /tmp/logo.ppm "$WIDTH" "$HEIGHT" "$ROTATION"
  convert /tmp/logo.ppm -type TrueColor -define bmp:format=bmp3 BMP3:/out/bootlogo.bmp
'
echo "wrote $OUT ($PROFILE_BOOTLOGO_WIDTH x $PROFILE_BOOTLOGO_HEIGHT," \
     "turned ${PROFILE_PANEL_ROTATION_CCW}° ccw)"
