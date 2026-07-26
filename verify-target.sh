#!/bin/sh
# Gate one prepared target before it is cached, built or published.
# Usage: ./verify-target.sh <target>
#
# These are the assumptions BaseOS relies on but does not otherwise test, each
# of which a refreshed vendor firmware could quietly invalidate:
#
#   1. the prepared artifacts still match the manifest that names them, and the
#      manifest still records the stock eight-partition H700 layout;
#   2. p1 `special` is an empty ext4, which is why the image build can preserve
#      it verbatim without carrying vendor state (docs/07 §2);
#   3. p3 `env` still boots /dev/mmcblk0p5 and still leaves `partitions` for
#      U-Boot to synthesise from GPT names — the fact the whole A/B slot design
#      rests on (docs/07 §2);
#   4. the vendor kernel in p4 still exports every symbol the harvested modules
#      import, with matching modversions CRCs. Without this a refreshed kernel
#      ships modules that simply fail to insmod, and the GPU or WiFi is dead on
#      a device with no other symptom.
#
# The ELF closure of the assembled rootfs is checked separately, by
# build-rootfs.sh, because it needs the overlay and tools merged in first.
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=tools/docker-platform.sh
. "$HERE/tools/docker-platform.sh"
TARGET="${1:?usage: $0 <target>}"
[ "$#" -eq 1 ] || { echo "usage: $0 <target>" >&2; exit 2; }
python3 "$HERE/tools/device_profile.py" shell "$TARGET" >/dev/null

WORK="$HERE/work/$TARGET"
[ -f "$WORK/source.json" ] || {
  echo "missing $WORK/source.json (run prepare-stock.sh or fetch-prepared.sh)" >&2
  exit 1
}

echo "=== verify $TARGET ==="

echo "--- 1. prepared artifacts and recorded layout"
python3 "$HERE/tools/source_manifest.py" verify "$WORK/source.json" "$TARGET"
eval "$(python3 "$HERE/tools/source_manifest.py" shell "$WORK/source.json" "$TARGET")"

echo "--- 2/3. p1 is an empty ext4, p3 still defers to the GPT"
# Host-native: dd, debugfs and grep only, no device code runs here.
docker run --rm --platform "$BASEOS_DOCKER_PLATFORM_HOST" \
  -v "$WORK":/work:ro \
  -e P1_START="$SOURCE_P1_START" -e P1_SECTORS="$SOURCE_P1_SECTORS" \
  -e P3_START="$SOURCE_P3_START" -e P3_SECTORS="$SOURCE_P3_SECTORS" \
  alpine:3.20 sh -euc '
  apk add -q e2fsprogs-extra

  dd if=/work/boot-prefix.img of=/tmp/p1.img bs=512 \
     skip="$P1_START" count="$P1_SECTORS" status=none
  # 0x53ef at 1024+56 is the ext superblock magic.
  magic=$(dd if=/tmp/p1.img bs=1 skip=1080 count=2 status=none | od -An -tx1 | tr -d " \n")
  [ "$magic" = "53ef" ] || { echo "FAIL: p1 is not an ext filesystem (magic $magic)"; exit 1; }
  entries=$(debugfs -R "ls -p /" /tmp/p1.img 2>/dev/null \
            | awk -F/ "\$6 != \"\" { print \$6 }" \
            | grep -vxE "\.|\.\.|lost\+found" || true)
  if [ -n "$entries" ]; then
    echo "FAIL: p1 special is not empty; it holds: $entries"
    echo "      BaseOS preserves p1 verbatim on the assumption it carries no vendor state."
    exit 1
  fi
  echo "PASS: p1 special is an empty ext4"

  dd if=/work/boot-prefix.img of=/tmp/p3.img bs=512 \
     skip="$P3_START" count="$P3_SECTORS" status=none
  grep -aq "mmc_root=/dev/mmcblk0p5" /tmp/p3.img \
    || { echo "FAIL: p3 env no longer sets mmc_root=/dev/mmcblk0p5"; exit 1; }
  grep -aq "partitions=\${partitions}" /tmp/p3.img \
    || { echo "FAIL: p3 env no longer defers partitions= to the GPT"; exit 1; }
  echo "PASS: p3 env boots p5 and synthesises partitions= from GPT names"
'

echo "--- 4. vendor kernel still satisfies the harvested modules"
python3 "$HERE/tools/kernel_abi.py" check "$TARGET"

echo
echo "=== $TARGET OK ==="
