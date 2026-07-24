#!/bin/sh
# End-to-end check that a real .bosupd payload applies to a real image: the
# same code path the handheld runs, driven against a copy of the composed
# image instead of a card.
#
# Verifies the three things that matter: the inactive slot receives exactly the
# payload bytes, the GPT commits to it, and the user's data partitions come out
# byte-for-byte untouched.
#
# Usage: ./test-update-roundtrip.sh <target>
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=tools/docker-platform.sh
. "$HERE/tools/docker-platform.sh"
TARGET="${1:?usage: $0 <target>}"

WORK="$HERE/work/$TARGET"
IMAGE="$WORK/baseos-$TARGET.img"
[ -f "$IMAGE" ] || { echo "missing $IMAGE (run build-image.sh $TARGET)" >&2; exit 1; }
# The payload for the version currently in VERSION — work/ may hold several.
BASEOS_VERSION="$(tr -d ' \n' < "$HERE/VERSION")"
PAYLOAD="$WORK/baseos-$TARGET-$BASEOS_VERSION.bosupd"
[ -f "$PAYLOAD" ] || { echo "missing $PAYLOAD (run build-update.sh $TARGET)" >&2; exit 1; }
echo "image:   $IMAGE"
echo "payload: $PAYLOAD"

# A scratch copy of the image stands in for the card. It is bind-mounted at
# /dev/mmcblk0 so baseos-update runs against its real hard-coded device path;
# the container's own /dev tmpfs is far too small to hold it.
CARD="$WORK/.roundtrip-card.img"
trap 'rm -f "$CARD"' EXIT INT TERM
rm -f "$CARD"
cp -c "$IMAGE" "$CARD" 2>/dev/null || cp "$IMAGE" "$CARD"

docker run --rm --platform "$BASEOS_DOCKER_PLATFORM_HOST" \
  -v "$WORK":/work:ro -v "$HERE/tools":/src:ro \
  -v "$CARD":/dev/mmcblk0 \
  -v "$HERE/overlay/usr/sbin/baseos-update":/usr/sbin/baseos-update:ro \
  -e TARGET="$TARGET" -e PAYLOAD_NAME="$(basename "$PAYLOAD")" \
  alpine:3.20 sh -euc '
  apk add -q build-base python3 e2fsprogs e2fsprogs-extra
  gcc -static -O2 -I/src -o /usr/sbin/gptslot /src/gptslot.c

  mkdir -p /mnt/sdcard /data
  cp "/work/$PAYLOAD_NAME" /mnt/sdcard/

  # A device that has not been updated yet: the shipped release identity.
  cat > /etc/baseos-release <<EOF
BASEOS=1
BASEOS_VERSION=0.0.0-previous
BASEOS_BUILD=previous
BASEOS_TARGET=$TARGET
EOF
  printf "%s\n" "#!/bin/sh" "printf \"%s\\n\" \"\$*\" >> /tmp/splash.log" > /usr/bin/baseos-splash
  printf "%s\n" "#!/bin/sh" "echo reboot >> /tmp/reboot.log" > /usr/local/bin/reboot
  printf "%s\n" "#!/bin/sh" "exit 0" > /usr/local/bin/sleep
  chmod 755 /usr/bin/baseos-splash /usr/local/bin/reboot /usr/local/bin/sleep

  extent() { python3 -c "
import struct, sys
name = sys.argv[1]
with open(\"/dev/mmcblk0\", \"rb\") as f:
    f.seek(1024)
    table = f.read(8 * 128)
for i in range(8):
    e = table[i * 128 : (i + 1) * 128]
    if e[56:128].decode(\"utf-16-le\").rstrip(\"\\0\") == name:
        start, end = struct.unpack_from(\"<QQ\", e, 32)
        print(start, end - start + 1)
        break
else:
    raise SystemExit(f\"no partition named {name}\")
" "$1"; }

  digest() { dd if=/dev/mmcblk0 bs=512 skip="$1" count="$2" status=none | sha256sum | cut -d" " -f1; }

  eval "set -- $(extent rootfs)";     ROOT_BEFORE_START=$1; SLOT=$2
  eval "set -- $(extent UDISK)";      UDISK_START=$1; UDISK_SECTORS=$2
  eval "set -- $(extent primary)";    PRIMARY_START=$1; PRIMARY_SECTORS=$2
  UDISK_BEFORE="$(digest "$UDISK_START" "$UDISK_SECTORS")"
  PRIMARY_BEFORE="$(digest "$PRIMARY_START" "$PRIMARY_SECTORS")"
  gptslot /dev/mmcblk0 geometry
  echo

  echo "== applying =="
  baseos-update apply
  cat /tmp/splash.log
  test -f /tmp/reboot.log || { echo "FAIL: no reboot requested" >&2; exit 1; }

  echo
  echo "== the GPT committed to the other slot =="
  gptslot /dev/mmcblk0 geometry > /tmp/geom.txt
  cat /tmp/geom.txt
  . /tmp/geom.txt
  test "$SLOT_ACTIVE" = B || { echo "FAIL: still on slot A" >&2; exit 1; }
  eval "set -- $(extent rootfs)"
  test "$1" -ne "$ROOT_BEFORE_START" || { echo "FAIL: rootfs extent did not move" >&2; exit 1; }

  echo
  echo "== the new slot is the payload, byte for byte =="
  want="$(tar -xOf "/mnt/sdcard/$PAYLOAD_NAME" manifest | sed -n "s/^image-sha256=//p")"
  got="$(digest "$1" "$2")"
  test "$got" = "$want" || { echo "FAIL: new slot $got != payload $want" >&2; exit 1; }
  echo "$got"

  echo
  echo "== the new slot is a mountable rootfs =="
  dd if=/dev/mmcblk0 of=/tmp/new.img bs=512 skip="$1" count="$2" status=none
  e2fsck -fn /tmp/new.img > /dev/null
  debugfs -R "cat /etc/baseos-release" /tmp/new.img 2>/dev/null | grep -E "BASEOS_(VERSION|TARGET)="

  echo
  echo "== user data was not touched =="
  test "$(digest "$UDISK_START" "$UDISK_SECTORS")" = "$UDISK_BEFORE" \
    || { echo "FAIL: /data partition changed" >&2; exit 1; }
  test "$(digest "$PRIMARY_START" "$PRIMARY_SECTORS")" = "$PRIMARY_BEFORE" \
    || { echo "FAIL: the user FAT partition changed" >&2; exit 1; }
  echo "UDISK and primary unchanged"

  echo
  echo "RESULT: PASS — real payload applied to the inactive slot and committed"
'
