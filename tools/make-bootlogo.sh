#!/bin/sh
# Generate one target's bootlogo from the fbsplash renderer so the hardware
# bootlogo (shown by boot0/U-Boot on the boot-resource partition) is pixel-
# identical to fbsplash at rest (0% illumination). build-image.sh writes the
# result onto p2.
# Output format matches the selected device: native dimensions, 24bpp,
# uncompressed BMP. The artifact is written beneath work/<target>/.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
BASE="$HERE/.."
TARGET="${1:?usage: $0 <target>}"
[ "$#" -eq 1 ] || { echo "usage: $0 <target>" >&2; exit 2; }
eval "$(python3 "$HERE/device_profile.py" shell "$TARGET")"
OUT="$BASE/work/$TARGET/bootlogo.bmp"
mkdir -p "$(dirname "$OUT")"

docker run --rm --platform linux/arm64 \
  -v "$BASE/src":/src:ro -v "$BASE/assets":/assets:ro \
  -v "$BASE/work/$TARGET":/out \
  -e WIDTH="$PROFILE_BOOTLOGO_WIDTH" -e HEIGHT="$PROFILE_BOOTLOGO_HEIGHT" \
  alpine:3.20 sh -euc '
  apk add -q build-base linux-headers pkgconf freetype-dev freetype-static \
    zlib-static libpng-static bzip2-static brotli-static imagemagick
  mkdir -p /usr/share/baseos && cp /assets/boot.ttf /usr/share/baseos/boot.ttf
  gcc -DFBSPLASH_TEST -O2 $(pkg-config --cflags freetype2) -o /tmp/fbtest \
    /src/fbsplash.c $(pkg-config --static --libs freetype2)
  /tmp/fbtest 0 "" /tmp/logo.ppm "$WIDTH" "$HEIGHT"
  convert /tmp/logo.ppm -type TrueColor -define bmp:format=bmp3 BMP3:/out/bootlogo.bmp
'
echo "wrote $OUT ($PROFILE_BOOTLOGO_WIDTH x $PROFILE_BOOTLOGO_HEIGHT)"
