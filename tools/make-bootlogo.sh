#!/bin/sh
# Generate one target's static bootlogo.
# Boot0/U-Boot shows it from the boot-resource partition; build-image.sh writes
# the result onto p2.
#
# Two sources, in order:
#   assets/bootlogo.svg   an artwork file, rendered at the size it will occupy
#   src/fbsplash.c        the built-in wordmark, drawn by the splash renderer
#
# The SVG is preferred when present. It is rasterised straight to its final
# width rather than rendered large and scaled down: a wordmark is nothing but
# edges, and resampling one is exactly where it goes soft.
#
# Output format matches the selected device either way: native dimensions,
# 24bpp, uncompressed BMP, pre-turned for a panel that is mounted turned, so the
# BMP holds exactly the pixels the panel scans out — the same convention as the
# vendor's own bootlogo. The artifact is written beneath work/<target>/.
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

# How much of the panel's width the artwork spans. Enough to read across a room,
# short of the edge-to-edge look of a splash that has run out of margin.
LOGO_WIDTH_PCT="${BOOTLOGO_WIDTH_PCT:-65}"

if [ -f "$BASE/assets/bootlogo.svg" ]; then
  docker run --rm --platform "$BASEOS_DOCKER_PLATFORM_HOST" \
    -v "$BASE/assets":/assets:ro -v "$BASE/work/$TARGET":/out \
    -e WIDTH="$PROFILE_BOOTLOGO_WIDTH" -e HEIGHT="$PROFILE_BOOTLOGO_HEIGHT" \
    -e ROTATION="$PROFILE_PANEL_ROTATION_CCW" -e PCT="$LOGO_WIDTH_PCT" \
    alpine:3.20 sh -euc '
    apk add -q imagemagick librsvg rsvg-convert
    # Compose upright, then turn. On a panel mounted turned, the upright canvas
    # is the panel geometry with its axes swapped. (Exercised only at rotation 0
    # so far; the RG SP does not turn.)
    case "$ROTATION" in
      90|270) CW="$HEIGHT"; CH="$WIDTH" ;;
      *)      CW="$WIDTH";  CH="$HEIGHT" ;;
    esac
    rsvg-convert -w "$(( CW * PCT / 100 ))" -a /assets/bootlogo.svg -o /tmp/logo.png
    convert -size "${CW}x${CH}" xc:black /tmp/logo.png -gravity center -composite /tmp/flat.png
    # ImageMagick turns clockwise for a positive angle; the profile is counter.
    [ "$ROTATION" = 0 ] || convert /tmp/flat.png -rotate "-${ROTATION}" /tmp/flat.png
    convert /tmp/flat.png -type TrueColor -define bmp:format=bmp3 BMP3:/out/bootlogo.bmp
  '
  echo "wrote $OUT from assets/bootlogo.svg" \
       "($PROFILE_BOOTLOGO_WIDTH x $PROFILE_BOOTLOGO_HEIGHT," \
       "turned ${PROFILE_PANEL_ROTATION_CCW}° ccw, ${LOGO_WIDTH_PCT}% wide)"
  exit 0
fi

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
