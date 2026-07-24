#!/bin/sh
# Build the .bosupd system-update payload for one target from its composed
# image. Users copy the result onto their card; the next boot applies it to the
# inactive rootfs slot without touching their ROMs, saves or settings.
# Usage: ./build-update.sh <target>
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
TARGET="${1:?usage: $0 <target>}"
[ "$#" -eq 1 ] || { echo "usage: $0 <target>" >&2; exit 2; }

WORK="$HERE/work/$TARGET"
IMAGE="$WORK/baseos-$TARGET.img"
[ -f "$IMAGE" ] || { echo "missing $IMAGE (run build-image.sh $TARGET)" >&2; exit 1; }

BASEOS_VERSION="$(tr -d ' \n' < "$HERE/VERSION")"
BASEOS_BUILD="$(git -C "$HERE" describe --always --dirty 2>/dev/null || echo unknown)"
OUT="$WORK/baseos-$TARGET-$BASEOS_VERSION.bosupd"

python3 "$HERE/tools/mkupdate.py" "$IMAGE" "$TARGET" \
  "$BASEOS_VERSION" "$BASEOS_BUILD" "$OUT"

echo
echo "Copy $(basename "$OUT") to the root of the card and power on."
