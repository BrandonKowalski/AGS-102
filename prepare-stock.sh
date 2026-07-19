#!/bin/sh
# Prepare per-target BaseOS inputs from an extracted StockMod firmware image.
# Usage: ./prepare-stock.sh <target> </path/to/stockmod.img>
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
TARGET="${1:?usage: $0 <target> </path/to/stockmod.img>}"
IMAGE="${2:?usage: $0 <target> </path/to/stockmod.img>}"
[ "$#" -eq 2 ] || { echo "usage: $0 <target> </path/to/stockmod.img>" >&2; exit 2; }

python3 "$HERE/tools/device_profile.py" shell "$TARGET" >/dev/null
[ -f "$IMAGE" ] || { echo "firmware image not found: $IMAGE" >&2; exit 1; }
case "$IMAGE" in *.[iI][mM][gG]) ;; *) echo "firmware input must be an extracted .img: $IMAGE" >&2; exit 1 ;; esac

IMAGE_DIR="$(cd "$(dirname "$IMAGE")" && pwd)"
IMAGE_NAME="$(basename "$IMAGE")"
mkdir -p "$HERE/work/$TARGET"

docker run --rm --platform linux/arm64 \
  -v "$IMAGE_DIR":/input:ro \
  -v "$HERE/work":/work \
  -v "$HERE/tools":/tools:ro \
  -v "$HERE/manifest":/manifest:ro \
  -v "$HERE/devices.json":/devices.json:ro \
  alpine:3.20 sh -euc '
    apk add -q python3 e2fsprogs e2fsprogs-extra busybox-static tar
    python3 /tools/prepare_stock.py \
      --target "$1" \
      --image "/input/$2" \
      --output "/work/$1" \
      --manifest /manifest/harvest.list \
      --profiles /devices.json
  ' sh "$TARGET" "$IMAGE_NAME"
