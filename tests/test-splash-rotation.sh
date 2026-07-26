#!/bin/sh
# The splash renders upright on a panel that is mounted turned.
#
# Builds the host test binary once and compares renders instead of eyeballing
# them: a rotated render must be its unrotated counterpart turned through the
# profile's angle, pixel for pixel. That is the whole contract, and it catches
# the two mistakes worth catching — a rotation applied in the wrong direction,
# and a pill laid out against physical rather than as-held dimensions.
set -eu

HERE="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../tools/docker-platform.sh
. "$HERE/tools/docker-platform.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

# Every profile's rotation must be one the renderer implements. devices.json is
# validated by device_profile.py; this asserts the two agree on the same set.
python3 - "$HERE" <<'EOF'
import re
import sys
from pathlib import Path

root = Path(sys.argv[1])
sys.path.insert(0, str(root / "tools"))
import device_profile

source = (root / "src" / "fbsplash.c").read_text(encoding="utf-8")
match = re.search(r"return (rot == .*?) \? rot : 0;", source)
if not match:
    raise SystemExit("fbsplash.c: cannot find the rotation whitelist")
implemented = {0} | {int(angle) for angle in re.findall(r"rot == (\d+)", match.group(1))}
if implemented != set(device_profile.PANEL_ROTATIONS):
    raise SystemExit(
        f"fbsplash implements {sorted(implemented)} but profiles allow "
        f"{sorted(device_profile.PANEL_ROTATIONS)}"
    )
for profile in device_profile.load_profiles():
    if profile["panel_rotation_ccw"] not in device_profile.PANEL_ROTATIONS:
        raise SystemExit(f"{profile['id']}: unimplemented panel rotation")
print("rotation whitelist matches the device profiles")
EOF

# The RG28XX is the reason this exists: a 480x640 panel held in landscape, so
# 640x480 of layout turned 90 degrees counter-clockwise onto it.
docker run --rm --platform "$BASEOS_DOCKER_PLATFORM_HOST" \
  -v "$HERE/src":/src:ro -v "$HERE/assets":/assets:ro -v "$TMP":/out \
  alpine:3.20 sh -euc '
  apk add -q build-base linux-headers pkgconf freetype-dev freetype-static \
    zlib-static libpng-static bzip2-static brotli-static imagemagick
  mkdir -p /usr/share/baseos && cp /assets/boot.ttf /usr/share/baseos/boot.ttf
  gcc -DFBSPLASH_TEST -O2 $(pkg-config --cflags freetype2) -o /tmp/fbtest \
    /src/fbsplash.c $(pkg-config --static --libs freetype2)

  # Full-screen logo: the bootlogo case.
  /tmp/fbtest 100 "" /out/logo-upright.ppm 640 480 0
  /tmp/fbtest 100 "" /out/logo-rotated.ppm 480 640 90
  # Status pill over the logo: the runtime case, including its off-screen
  # composition and the seed read back out of the framebuffer.
  /tmp/fbtest 50 "UPDATING SYSTEM" /out/pill-upright.ppm 640 480 0
  /tmp/fbtest 50 "UPDATING SYSTEM" /out/pill-rotated.ppm 480 640 90
  # 270 is the same panel mounted the other way: two quarter turns apart.
  /tmp/fbtest 100 "" /out/logo-rotated270.ppm 480 640 270

  for pair in logo pill; do
    convert "/out/$pair-upright.ppm" -rotate -90 "/out/$pair-expected.ppm"
    identify "/out/$pair-rotated.ppm" | grep -q " 480x640 " \
      || { echo "$pair: rotated render is not the panel geometry" >&2; exit 1; }
    cmp "/out/$pair-rotated.ppm" "/out/$pair-expected.ppm" \
      || { echo "$pair: rotated render is not the upright one turned 90 ccw" >&2; exit 1; }
  done

  convert /out/logo-rotated.ppm -rotate 180 /out/logo-flipped.ppm
  cmp /out/logo-flipped.ppm /out/logo-rotated270.ppm \
    || { echo "270 is not 90 turned the other way" >&2; exit 1; }

  # An unrotated target must render exactly what it always did: same geometry,
  # and the rotation code path never entered.
  /tmp/fbtest 100 "" /out/logo-zero.ppm 640 480 0
  cmp /out/logo-zero.ppm /out/logo-upright.ppm
  # A nonsense angle degrades to unrotated rather than to a blank panel.
  /tmp/fbtest 100 "" /out/logo-bogus.ppm 640 480 45
  cmp /out/logo-bogus.ppm /out/logo-upright.ppm
'

echo "splash rotation tests passed"
