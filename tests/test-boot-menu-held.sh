#!/bin/sh
set -eu

HERE="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tools/docker-platform.sh
. "$HERE/tools/docker-platform.sh"
BINARY="$HERE/work/tools/boot-menu-held"

[ -x "$BINARY" ] \
	|| { echo "missing $BINARY (run build-tools.sh)" >&2; exit 1; }
file "$BINARY" | grep -q "statically linked" \
	|| { echo "boot-menu-held is not static" >&2; exit 1; }

# An environment with no evdev nodes must report "not held" (exit 1), not an
# operational error. The held BTN_MODE path is completed on real H700 input.
docker run --rm --platform "$BASEOS_DOCKER_PLATFORM_AARCH64" \
	-v "$BINARY":/boot-menu-held:ro alpine:3.20 sh -euc '
	set +e
	/boot-menu-held
	status=$?
	set -e
	[ "$status" -eq 1 ]
'

echo "boot-menu-held structural tests passed"
