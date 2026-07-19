#!/bin/sh
# Regression test for first-boot expansion splash and exit handling.
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"

docker run --rm --platform linux/arm64 \
  -v "$HERE/overlay/usr/sbin/expand-storage":/test/expand-storage:ro \
  alpine:3.20 sh -euc '
  mknod /dev/mmcblk0 b 7 0
  mknod /dev/mmcblk0p8 b 7 1

  make_stub() {
    path="$1"; shift
    printf "%s\n" "#!/bin/sh" "$*" > "$path"
    chmod 755 "$path"
  }
  make_stub /usr/bin/fbsplash "printf \"%s\\n\" \"\$*\" >> /tmp/splash.log"
  make_stub /usr/local/bin/mkfs.vfat "printf \"%s\\n\" \"\$*\" >> /tmp/mkfs.log"
  make_stub /usr/local/bin/partprobe "exit 0"

  # Subsequent boot: gptgrow reports that p8 already fills the disk. There
  # must be no expansion splash and no format attempt.
  make_stub /usr/sbin/gptgrow "exit 1"
  rm -f /tmp/splash.log /tmp/mkfs.log
  /bin/sh /test/expand-storage
  test ! -e /tmp/splash.log
  test ! -e /tmp/mkfs.log

  # First boot: display the message only after gptgrow confirms it changed p8.
  make_stub /usr/sbin/gptgrow "exit 0"
  rm -f /tmp/splash.log /tmp/mkfs.log
  /bin/sh /test/expand-storage
  grep -qx "45 EXPANDING STORAGE" /tmp/splash.log
  grep -qx -- "-F 32 -n BASEOS /dev/mmcblk0p8" /tmp/mkfs.log

  # A real gptgrow error is neither an already-expanded card nor a reason to
  # display progress or format anything.
  make_stub /usr/sbin/gptgrow "exit 2"
  rm -f /tmp/splash.log /tmp/mkfs.log
  if /bin/sh /test/expand-storage; then
    echo "expected gptgrow failure to propagate" >&2
    exit 1
  fi
  test ! -e /tmp/splash.log
  test ! -e /tmp/mkfs.log

  echo "RESULT: PASS — expansion splash is first-boot only"
'
