#!/bin/sh
# Regenerate assets/bootlogo.bmp from the fbsplash renderer so the hardware
# bootlogo (shown by boot0/U-Boot on the boot-resource partition) is pixel-
# identical to fbsplash at rest (0% illumination). Run this whenever the
# fbsplash design or font changes; build-image.sh writes the result onto p2.
# Output format matches the stock vendor logo: 640x480, 24bpp, uncompressed BMP.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
BASE="$HERE/.."

docker run --rm --platform linux/arm64 \
  -v "$BASE/src":/src:ro -v "$BASE/assets":/assets alpine:3.20 sh -euc '
  apk add -q build-base linux-headers pkgconf freetype-dev freetype-static \
    zlib-static libpng-static bzip2-static brotli-static imagemagick
  mkdir -p /usr/share/baseos && cp /assets/boot.ttf /usr/share/baseos/boot.ttf
  gcc -DFBSPLASH_TEST -O2 $(pkg-config --cflags freetype2) -o /tmp/fbtest \
    /src/fbsplash.c $(pkg-config --static --libs freetype2)
  /tmp/fbtest 0 "" /tmp/logo.ppm
  convert /tmp/logo.ppm -type TrueColor -define bmp:format=bmp3 BMP3:/assets/bootlogo.bmp
'
echo "wrote $BASE/assets/bootlogo.bmp"
