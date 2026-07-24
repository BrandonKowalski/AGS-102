#!/bin/sh
# Regression test for baseos-update: what it accepts, what it refuses, and —
# above all — that it never flips the GPT unless the inactive slot verified.
#
# Runs entirely on stubs and a small regular file standing in for the card, so
# it needs no device and no privileges. The BusyBox tar/gunzip/sha256sum used
# here are the same applets the handheld runs.
set -eu

HERE="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tools/docker-platform.sh
. "$HERE/tools/docker-platform.sh"

docker run --rm --platform "$BASEOS_DOCKER_PLATFORM_HOST" \
  -v "$HERE/overlay/usr/sbin/baseos-update":/usr/sbin/baseos-update:ro \
  alpine:3.20 sh -euc '
  # 8 MiB slots: small enough to stay quick, large enough that the chunked
  # write and read-back actually loop (step = max(1, MiB/16) = 1 MiB here).
  SLOT_BYTES=8388608
  SLOT_SECTORS=16384
  INACTIVE_MB=9               # SLOT_INACTIVE_START 18432 / 2048

  mkdir -p /mnt/sdcard /data /dev
  : > /dev/mmcblk0
  truncate -s 32M /dev/mmcblk0

  cat > /etc/baseos-release <<EOF
BASEOS=1
BASEOS_VERSION=1.0.0
BASEOS_BUILD=v1.0.0
BASEOS_TARGET=rg40xxv
EOF

  stub() { printf "%s\n" "#!/bin/sh" "$2" > "$1"; chmod 755 "$1"; }
  stub /usr/bin/baseos-splash "printf \"%s\\n\" \"\$*\" >> /tmp/splash.log"
  stub /usr/local/bin/reboot "echo reboot >> /tmp/reboot.log"
  stub /usr/local/bin/sleep "exit 0"
  mkdir -p /usr/sbin
  cat > /usr/sbin/gptslot <<"EOF"
#!/bin/sh
[ -f /tmp/no-layout ] && exit 2
case "$2" in
  geometry)
    echo "SLOT_ACTIVE=A"
    echo "SLOT_BASE=2048"
    echo "SLOT_SECTORS=16384"
    echo "SLOT_ACTIVE_START=2048"
    echo "SLOT_INACTIVE_START=18432"
    ;;
  flip) echo flip >> /tmp/flip.log ;;
  *) exit 2 ;;
esac
EOF
  chmod 755 /usr/sbin/gptslot

  # Build a payload named after its version, so the on-card glob order matches
  # what a user actually accumulates. $1 target, $2 slot-sectors, $3
  # clean|corrupt, $4 version (default 1.0.1), $5 "keep" to leave existing
  # payloads in place.
  make_payload() {
    ver="${4:-1.0.1}"
    rm -rf /tmp/pay; mkdir -p /tmp/pay; cd /tmp/pay
    dd if=/dev/urandom of=slot.img bs=1M count=8 status=none
    printf "%s" "$ver" | dd of=slot.img bs=1 seek=0 conv=notrunc status=none
    sha="$(sha256sum slot.img | cut -d" " -f1)"
    if [ "$3" = corrupt ]; then
      dd if=/dev/urandom of=slot.img bs=512 count=1 conv=notrunc status=none
    fi
    gzip -c slot.img > rootfs.img.gz
    printf "format=baseos-update/1\ntarget=%s\nversion=%s\nbuild=test\n" "$1" "$ver" > manifest
    printf "slot-sectors=%s\nimage-size=%s\nimage-sha256=%s\n" \
      "$2" "$SLOT_BYTES" "$sha" >> manifest
    [ "${5:-}" = keep ] || rm -f /mnt/sdcard/*.bosupd
    tar -cf "/mnt/sdcard/baseos-rg40xxv-$ver.bosupd" manifest rootfs.img.gz
    cd /
  }

  reset() { rm -f /tmp/flip.log /tmp/splash.log /tmp/reboot.log; rm -rf /data/update; }
  no_flip() {
    [ -f /tmp/flip.log ] && { echo "FAIL: $1 — the GPT was flipped" >&2; exit 1; }
    return 0
  }

  echo "== no payload is a silent no-op =="
  reset
  baseos-update apply
  no_flip "empty card"
  test ! -f /tmp/splash.log || { echo "FAIL: painted a pill with no payload" >&2; exit 1; }
  echo "ok"

  echo "== a payload for another target is refused =="
  reset; make_payload rg35xxh "$SLOT_SECTORS" clean
  if baseos-update apply; then echo "FAIL: wrong target accepted" >&2; exit 1; fi
  no_flip "wrong target"
  echo "ok"

  echo "== a payload for a different slot size is refused =="
  reset; make_payload rg40xxv 4096 clean
  if baseos-update apply; then echo "FAIL: wrong slot size accepted" >&2; exit 1; fi
  no_flip "wrong slot size"
  echo "ok"

  echo "== a corrupted image is refused after the write =="
  reset; make_payload rg40xxv "$SLOT_SECTORS" corrupt
  if baseos-update apply; then echo "FAIL: corrupt image accepted" >&2; exit 1; fi
  no_flip "hash mismatch"
  grep -q "UPDATE FAILED" /tmp/splash.log || { echo "FAIL: no failure pill" >&2; exit 1; }
  echo "ok: written but never committed"

  echo "== a card with no A/B layout is left alone =="
  reset; make_payload rg40xxv "$SLOT_SECTORS" clean
  : > /tmp/no-layout
  baseos-update apply
  rm -f /tmp/no-layout
  no_flip "pre-1.0 layout"
  echo "ok"

  echo "== a good payload is written, verified and committed =="
  reset; make_payload rg40xxv "$SLOT_SECTORS" clean
  want="$(sha256sum /tmp/pay/slot.img | cut -d" " -f1)"
  baseos-update apply
  got="$(dd if=/dev/mmcblk0 bs=1M skip=$INACTIVE_MB count=8 status=none | sha256sum | cut -d" " -f1)"
  test "$got" = "$want" || { echo "FAIL: inactive slot content" >&2; exit 1; }
  test -f /tmp/flip.log || { echo "FAIL: no commit" >&2; exit 1; }
  test -f /tmp/reboot.log || { echo "FAIL: no reboot" >&2; exit 1; }
  grep -q "UPDATING SYSTEM" /tmp/splash.log || { echo "FAIL: no progress pill" >&2; exit 1; }
  # The bar must actually move, and never backwards: one paint before the write,
  # one per written chunk, one per verified chunk, one at the commit.
  awk "/UPDATING SYSTEM/ {print \$2}" /tmp/splash.log > /tmp/progress.txt
  test "$(wc -l < /tmp/progress.txt)" -ge 10 \
    || { echo "FAIL: progress pill did not move (only $(wc -l < /tmp/progress.txt) paints)" >&2; exit 1; }
  awk "NR > 1 && \$1 < prev { exit 1 } { prev = \$1 }" /tmp/progress.txt \
    || { echo "FAIL: progress went backwards" >&2; exit 1; }
  test "$(head -1 /tmp/progress.txt)" -eq 0 || { echo "FAIL: bar should start at 0" >&2; exit 1; }
  test "$(tail -1 /tmp/progress.txt)" -eq 98 || { echo "FAIL: bar should reach 98" >&2; exit 1; }
  echo "  progress: $(tr "\n" " " < /tmp/progress.txt)"
  grep -qx "trial=1.0.1" /data/update/state || { echo "FAIL: no trial state" >&2; exit 1; }
  echo "ok"

  grep -q "^$want 1.0.1 test$" /data/update/history \
    || { echo "FAIL: the commit was not recorded before the reboot" >&2; exit 1; }
  echo "ok"

  echo "== the trial ends when a frontend session starts =="
  baseos-update confirm
  test ! -f /data/update/state || { echo "FAIL: trial state survived confirm" >&2; exit 1; }
  grep -q "confirmed" /data/update/log || { echo "FAIL: nothing logged" >&2; exit 1; }
  echo "ok"

  echo "== an already-applied payload is skipped =="
  rm -f /tmp/flip.log
  baseos-update apply
  no_flip "re-applying the same image"
  echo "ok: one card can update several handhelds"

  echo "== a payload matching the running build is skipped =="
  # A payload whose version and build match the running system is skipped
  # outright, so the file left on the card is inert from the first boot after an
  # update — before anything has been confirmed.
  reset; make_payload rg40xxv "$SLOT_SECTORS" clean
  cat > /etc/baseos-release <<EOF
BASEOS=1
BASEOS_VERSION=1.0.1
BASEOS_BUILD=test
BASEOS_TARGET=rg40xxv
EOF
  baseos-update apply
  no_flip "payload equals the running build"
  echo "ok: no reboot loop on the first boot after an update"

  echo "== a stale payload does not mask a newer one beside it =="
  # Exactly the field report: 1.0.1 and 1.0.2 both on the card. 1.0.1 sorts
  # first and is the running build, so a scan that stops at the first file
  # finds nothing to do and never looks at 1.0.2.
  reset
  cat > /etc/baseos-release <<EOF
BASEOS=1
BASEOS_VERSION=1.0.1
BASEOS_BUILD=test
BASEOS_TARGET=rg40xxv
EOF
  make_payload rg40xxv "$SLOT_SECTORS" clean 1.0.1
  make_payload rg40xxv "$SLOT_SECTORS" clean 1.0.2 keep
  newer="$(sha256sum /tmp/pay/slot.img | cut -d" " -f1)"
  test "$(ls /mnt/sdcard/*.bosupd | wc -l)" -eq 2 || { echo "FAIL: setup" >&2; exit 1; }
  baseos-update apply
  test -f /tmp/flip.log || { echo "FAIL: the newer payload was never found" >&2; exit 1; }
  got="$(dd if=/dev/mmcblk0 bs=1M skip=$INACTIVE_MB count=8 status=none | sha256sum | cut -d" " -f1)"
  test "$got" = "$newer" || { echo "FAIL: applied the wrong payload" >&2; exit 1; }
  grep -qx "trial=1.0.2" /data/update/state || { echo "FAIL: wrong version applied" >&2; exit 1; }
  echo "ok: every payload is considered, not just the first"

  echo "== an older payload is never applied =="
  # Without this the stale payload becomes applicable again the moment you
  # update past it: downgrade, then re-apply the newer one, forever.
  reset
  cat > /etc/baseos-release <<EOF
BASEOS=1
BASEOS_VERSION=1.0.2
BASEOS_BUILD=test
BASEOS_TARGET=rg40xxv
EOF
  make_payload rg40xxv "$SLOT_SECTORS" clean 1.0.1
  baseos-update apply
  no_flip "older payload"
  echo "ok: no downgrade ping-pong"

  echo "== a rolled-back payload is not applied again =="
  # The failure that oscillates forever if the commit is only recorded on
  # success: apply -> flip -> three bad boots -> roll back -> and the payload is
  # still sitting on the card, so the next boot re-applies the same bad update.
  reset; make_payload rg40xxv "$SLOT_SECTORS" clean
  cat > /etc/baseos-release <<EOF
BASEOS=1
BASEOS_VERSION=1.0.0
BASEOS_BUILD=v1.0.0
BASEOS_TARGET=rg40xxv
EOF
  baseos-update apply                          # commits and reboots
  test -f /tmp/flip.log || { echo "FAIL: no commit" >&2; exit 1; }
  baseos-update boot-check                     # boot 1 of the trial
  baseos-update boot-check                     # boot 2
  baseos-update boot-check                     # boot 3: restore the old slot
  test "$(wc -l < /tmp/flip.log)" -eq 2 || { echo "FAIL: no rollback flip" >&2; exit 1; }
  baseos-update apply                          # back on the old slot, payload still there
  test "$(wc -l < /tmp/flip.log)" -eq 2 \
    || { echo "FAIL: the rolled-back payload was applied again" >&2; exit 1; }
  echo "ok: a bad update cannot oscillate"

  echo "== a slot that never reaches a session is restored =="
  reset
  mkdir -p /data/update
  printf "trial=1.0.1\nattempts=1\nrestored-from=A\nsha=deadbeef\n" > /data/update/state
  baseos-update boot-check          # attempt 2 of 3: still on trial
  test ! -f /tmp/flip.log || { echo "FAIL: rolled back too early" >&2; exit 1; }
  grep -qx "attempts=2" /data/update/state || { echo "FAIL: attempts not counted" >&2; exit 1; }
  baseos-update boot-check          # attempt 3 of 3: restore the old slot
  test -f /tmp/flip.log || { echo "FAIL: no rollback flip" >&2; exit 1; }
  test ! -f /data/update/state || { echo "FAIL: trial state survived rollback" >&2; exit 1; }
  grep -q "RESTORING SYSTEM" /tmp/splash.log || { echo "FAIL: no restore pill" >&2; exit 1; }
  echo "ok"

  echo "RESULT: PASS — payload validation, verify-then-commit, and rollback"
'
