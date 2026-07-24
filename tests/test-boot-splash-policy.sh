#!/bin/sh
set -eu

HERE="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

mkdir -p "$TMP/bin"
cat > "$TMP/bin/fbsplash" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$BASEOS_TEST_SPLASH_LOG"
EOF
chmod +x "$TMP/bin/fbsplash"

run_splash() {
	BASEOS_FBSPLASH="$TMP/bin/fbsplash" \
	BASEOS_TEST_SPLASH_LOG="$TMP/splash.log" \
		sh "$HERE/overlay/usr/bin/baseos-splash" "$@"
}

# The regular boot chain has no splash process on its critical path.
if grep -Eq 'baseos-splash|fbsplash' \
	"$HERE/overlay/init" "$HERE/overlay/etc/init.d/rcS"; then
	echo "routine boot script invokes the splash renderer" >&2
	exit 1
fi
if grep -Eq '(^|[[:space:]])splash[[:space:]]+100' \
	"$HERE/overlay/usr/sbin/nextui-session"; then
	echo "frontend hand-off invokes routine splash progress" >&2
	exit 1
fi

# Only the wrapper may reach the renderer. A script calling fbsplash directly
# could omit the message, and a message-less call is a full-screen repaint that
# erases whatever boot logo the user has on p2.
direct="$(grep -rl "fbsplash" "$HERE/overlay" | grep -v "/baseos-splash$" || true)"
if [ -n "$direct" ]; then
	echo "overlay scripts invoke the renderer directly: $direct" >&2
	exit 1
fi

# The wrapper rejects routine progress: ordinary boot must never touch fb0.
if run_splash 30; then
	echo "routine splash unexpectedly succeeded" >&2
	exit 1
fi
[ ! -e "$TMP/splash.log" ]

# The message is what selects the pill over the full-screen logo, so the
# wrapper must refuse a call that lacks one instead of passing it through.
if run_splash --important 45; then
	echo "message-less splash unexpectedly succeeded" >&2
	exit 1
fi
if run_splash --important 45 ""; then
	echo "empty-message splash unexpectedly succeeded" >&2
	exit 1
fi
[ ! -e "$TMP/splash.log" ]

# Exceptional work reaches the renderer as progress + message, which is what
# makes it draw the compact pill and preserve every pixel outside it.
run_splash --important 45 "EXPANDING STORAGE"
grep -qx -- "45 EXPANDING STORAGE" "$TMP/splash.log"

echo "boot splash policy tests passed"
