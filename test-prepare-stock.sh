#!/bin/sh
# Synthetic tests for the StockMod firmware importer. No hardware or firmware
# download is required; all artifacts live inside the disposable container.
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=tools/docker-platform.sh
. "$HERE/tools/docker-platform.sh"

# Host-native: synthetic prepare tests never execute aarch64 device ELFs.
docker run --rm --platform "$BASEOS_DOCKER_PLATFORM_HOST" \
  -v "$HERE":/src:ro alpine:3.20 sh -euc '
  apk add -q python3 e2fsprogs e2fsprogs-extra busybox-static dosfstools tar
  T=/tmp/baseos-prepare-test
  mkdir -p "$T/root/etc" "$T/root/usr/lib" "$T/root/usr/share/demo"
  printf "required\n" > "$T/root/etc/demo.conf"
  printf "library-content\n" > "$T/root/usr/lib/libdemo.so.1.0"
  ln -s libdemo.so.1.0 "$T/root/usr/lib/libdemo-relative.so"
  ln -s /usr/lib/libdemo.so.1.0 "$T/root/usr/lib/libdemo-absolute.so"
  printf "directory-content\n" > "$T/root/usr/share/demo/value"
  printf "%s\n" \
    /etc/demo.conf \
    /usr/lib/libdemo-relative.so \
    /usr/lib/libdemo-absolute.so \
    /usr/share/demo > "$T/harvest.list"

  IMG="$T/RG40XXV-synthetic.img"
  python3 /src/tests/make_stock_fixture.py "$IMG" "$T/root"

  prepare() {
    python3 /src/tools/prepare_stock.py \
      --target rg40xxv --image "$1" --output "$2" \
      --manifest "$3" --profiles /src/devices.json
  }
  must_fail() {
    if "$@" >"$T/expected-failure.log" 2>&1; then
      echo "expected command to fail: $*" >&2
      exit 1
    fi
  }

  mkdir "$T/images"
  touch \
    "$T/images/RG28XX-test.img" \
    "$T/images/RG34XX-test.img" \
    "$T/images/RG34XXSP-test.img" \
    "$T/images/RG35XX+-P-test.img" \
    "$T/images/RG35XXH-test.img" \
    "$T/images/RG35XXPRO-test.img" \
    "$T/images/RG35XXSP-test.img" \
    "$T/images/RG40XXH-test.img" \
    "$T/images/RG40XXV-test.img" \
    "$T/images/RGCUBEXX-test.img" \
    "$T/images/RGSP-test.img"
  for target in $(python3 /src/tools/device_profile.py list); do
    python3 /src/tools/device_profile.py find "$T/images" "$target" >/dev/null
  done
  touch "$T/images/RG40XXV-second.img"
  must_fail python3 /src/tools/device_profile.py find "$T/images" rg40xxv

  # filename_alias also finds a hand-named image, and still refuses two matches.
  mkdir "$T/aliased"
  touch "$T/aliased/2026-07-27 ANBERNIC RG SP TF1.img"
  python3 /src/tools/device_profile.py find "$T/aliased" rgsp >/dev/null
  touch "$T/aliased/RGSP-official.img"
  must_fail python3 /src/tools/device_profile.py find "$T/aliased" rgsp

  prepare "$IMG" "$T/out1" "$T/harvest.list"
  python3 /src/tools/source_manifest.py verify "$T/out1/source.json" rg40xxv
  cp "$T/out1/boot-prefix.img" "$T/composed.img"
  truncate -s $((150000 * 512)) "$T/composed.img"
  python3 /src/tools/mkgpt.py "$T/composed.img" 150000 4096 4096 4096 >/dev/null
  python3 -c "import struct; open(\"$T/logo.bmp\", \"wb\").write(b\"BM\" + b\"\\0\" * 16 + struct.pack(\"<ii\", 640, 480))"
  python3 /src/tools/source_manifest.py verify-image \
    "$T/out1/source.json" rg40xxv "$T/out1/boot-prefix.img" \
    "$T/composed.img" "$T/logo.bmp"
  mkdir "$T/extracted"
  tar -xf "$T/out1/stock-harvest.tar" -C "$T/extracted"
  test ! -L "$T/extracted/usr/lib/libdemo-relative.so"
  test ! -L "$T/extracted/usr/lib/libdemo-absolute.so"
  cmp "$T/extracted/usr/lib/libdemo-relative.so" "$T/root/usr/lib/libdemo.so.1.0"
  cmp "$T/extracted/usr/lib/libdemo-absolute.so" "$T/root/usr/lib/libdemo.so.1.0"
  grep -qx directory-content "$T/extracted/usr/share/demo/value"

  prepare "$IMG" "$T/out2" "$T/harvest.list"
  cmp "$T/out1/boot-prefix.img" "$T/out2/boot-prefix.img"
  cmp "$T/out1/stock-harvest.tar" "$T/out2/stock-harvest.tar"
  cmp "$T/out1/source.json" "$T/out2/source.json"

  python3 /src/tests/make_stock_fixture.py \
    "$T/RG40XXV-stockmod-base.img" "$T/root" --stockmod-base
  prepare "$T/RG40XXV-stockmod-base.img" "$T/trimmed-base" "$T/harvest.list"
  python3 -c "import json; d=json.load(open(\"$T/trimmed-base/source.json\")); assert d[\"layout\"][\"packaging\"] == \"stockmod-base-trimmed\"; assert not d[\"layout\"][\"backup_gpt_present\"]; assert len(d[\"layout\"][\"partitions\"]) == 7"

  cp "$IMG" "$T/RG28XX-synthetic.img"
  printf "%s\n" \
    /etc/demo.conf \
    "## WiFi" \
    /usr/sbin/wpa_supplicant > "$T/radio-optional.list"
  python3 /src/tools/prepare_stock.py \
    --target rg28xx --image "$T/RG28XX-synthetic.img" --output "$T/rg28" \
    --manifest "$T/radio-optional.list" --profiles /src/devices.json
  python3 -c "import json; d=json.load(open(\"$T/rg28/source.json\")); assert d[\"harvest\"][\"optional_omissions\"] == [\"/usr/sbin/wpa_supplicant\"]"

  cp "$IMG" "$T/RG40XXV-invalid-gpt.img"
  dd if=/dev/zero of="$T/RG40XXV-invalid-gpt.img" bs=512 seek=1 count=1 conv=notrunc status=none
  must_fail prepare "$T/RG40XXV-invalid-gpt.img" "$T/bad-gpt" "$T/harvest.list"

  cp "$IMG" "$T/RG40XXV-invalid-backup.img"
  LAST_SECTOR=$(( $(stat -c %s "$T/RG40XXV-invalid-backup.img") / 512 - 1 ))
  dd if=/dev/zero of="$T/RG40XXV-invalid-backup.img" bs=512 seek="$LAST_SECTOR" count=1 conv=notrunc status=none
  must_fail prepare "$T/RG40XXV-invalid-backup.img" "$T/bad-backup" "$T/harvest.list"

  python3 /src/tests/make_stock_fixture.py \
    "$T/RG40XXV-wrong-name.img" "$T/root" --first-name not-special
  must_fail prepare "$T/RG40XXV-wrong-name.img" "$T/bad-name" "$T/harvest.list"

  cp "$IMG" "$T/RG40XXV-truncated.img"
  truncate -s 48M "$T/RG40XXV-truncated.img"
  must_fail prepare "$T/RG40XXV-truncated.img" "$T/truncated" "$T/harvest.list"

  cp "$T/harvest.list" "$T/missing.list"
  printf "/missing-required-file\n" >> "$T/missing.list"
  must_fail prepare "$IMG" "$T/missing" "$T/missing.list"

  echo "RESULT: PASS — StockMod preparation synthetic tests"
'
