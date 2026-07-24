#!/bin/sh
# Print the stamp identifying the in-repo sources that work/tools binaries are
# compiled from.
#
# build-tools.sh writes this to work/tools/.stamp; build-stockmod.sh and
# build-rootfs.sh compare against it. Existence checks alone cannot see a
# source edit, so a stale binary used to ship silently alongside freshly built
# overlay scripts — which is exactly how a pre-pill fbsplash reached a device
# whose boot scripts already spoke the new contract.
#
# Every compiled source in the tree is covered by glob rather than by name, so
# adding a tool needs no change here and cannot be forgotten. Only sources built
# into work/tools belong in these directories; busybox, curl, dropbear and
# sftp-server are pinned upstream releases whose versions live in build-tools.sh,
# and changing one already changes that file.
set -eu

HERE="$(cd "$(dirname "$0")/.." && pwd)"

sha256() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$1"
	else
		shasum -a 256 "$1"
	fi
}

# Relative paths and a fixed sort order keep the stamp identical across
# machines and independent of glob expansion order.
cd "$HERE"
export LC_ALL=C

for source in src/*.c src/*.h tools/*.c tools/*.h; do
	[ -f "$source" ] || continue
	printf '%s %s\n' "$source" "$(sha256 "$source" | cut -d' ' -f1)"
done | sort
