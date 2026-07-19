#!/bin/sh
# Capture the stock-OS harvest set from a live H700 device over SSH.
# Produces work/stock-harvest.tar (paths relative to /, symlinks dereferenced)
# and records provenance in work/capture-info.txt.
#
# Usage: DEVICE=root@192.168.34.55 SSHPASS=root ./capture-stock.sh
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="$HERE/work"
DEVICE="${DEVICE:-root@192.168.34.55}"
SSHPASS="${SSHPASS:-root}"
OUT="$WORK/stock-harvest.tar"

mkdir -p "$WORK"

SSH="sshpass -p $SSHPASS ssh -o StrictHostKeyChecking=no $DEVICE"

# Expand the manifest device-side: keep only paths that exist, warn on missing.
LIST="$(grep -v '^#' "$HERE/manifest/harvest.list" | grep -v '^[[:space:]]*$')"

echo "$LIST" | $SSH 'missing=""; ok="";
while read -r p; do
  if [ -e "$p" ] || [ -L "$p" ]; then ok="$ok $p"; else missing="$missing $p"; fi
done
for m in $missing; do echo "MISSING: $m" >&2; done
# -h dereferences symlinks so soname paths become real files in the tar.
cd / && tar -chf - $ok' > "$OUT"

{
  echo "device: $DEVICE"
  echo "date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  $SSH 'echo "kernel: $(uname -a)"; echo "os: $(. /etc/os-release && echo $PRETTY_NAME)"' || true
  echo "sha256: $(shasum -a 256 "$OUT" | awk '{print $1}')"
  echo "size: $(stat -f %z "$OUT")"
} > "$WORK/capture-info.txt"

echo "Captured $(du -h "$OUT" | cut -f1) to $OUT"
cat "$WORK/capture-info.txt"
