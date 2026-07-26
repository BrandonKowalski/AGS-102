#!/bin/sh
# Restore the prepared build inputs without needing the StockMod .img files.
# Usage: ./fetch-prepared.sh [--from BUNDLE] [--force] [target ...]
#
# prepare-stock.sh derives exactly three things per target from an 11.7 GB
# vendor image: boot-prefix.img, stock-harvest.tar and source.json. This fetches
# the first two pre-made and installs the third from git, so a clean checkout
# builds every model without downloading ~117 GB of firmware.
#
# It is a cache restore, not a second build path. Integrity is checked twice and
# both anchors live in git: the bundle's SHA-256 (manifest/prepared/bundle.sha256)
# covers the download, and each artifact's own size and SHA-256 — recorded in the
# committed source.json — cover the contents. That second check is the same one
# build-rootfs.sh and build-image.sh already run on every build, so a bad restore
# fails in exactly the place a bad prepare would.
#
# --from takes a local bundle instead of downloading, which is also how you use
# one you packed yourself with cache-pack.sh.
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=tools/docker-platform.sh
. "$HERE/tools/docker-platform.sh"

PREPARED="$HERE/manifest/prepared"
CACHE_DIR="$HERE/work/prepared"
BUNDLE=""
FORCE=0
TARGETS=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --from) BUNDLE="${2:?--from needs a path}"; shift 2 ;;
    --force) FORCE=1; shift ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    -*) echo "unknown option: $1" >&2; exit 2 ;;
    *) TARGETS="$TARGETS $1"; shift ;;
  esac
done
[ -n "$TARGETS" ] || TARGETS="$(python3 "$HERE/tools/device_profile.py" list)"

[ -f "$PREPARED/bundle.sha256" ] || { echo "missing $PREPARED/bundle.sha256" >&2; exit 1; }
[ -f "$PREPARED/bundle.url" ] || { echo "missing $PREPARED/bundle.url" >&2; exit 1; }
WANT_SHA="$(cut -d' ' -f1 < "$PREPARED/bundle.sha256")"
NAME="$(awk '{print $NF}' < "$PREPARED/bundle.sha256")"
URL="${BASEOS_PREPARED_URL:-$(cat "$PREPARED/bundle.url")}"

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

# A source.json in work/ that differs from the committed one means a local
# prepare-stock.sh run against different firmware. Overwriting it would throw
# away the only record of what that build came from, so stop and say so.
CONFLICTS=""
for target in $TARGETS; do
  committed="$PREPARED/$target.json"
  [ -f "$committed" ] || { echo "no cached manifest for target '$target'" >&2; exit 1; }
  local_manifest="$HERE/work/$target/source.json"
  if [ -f "$local_manifest" ] && ! cmp -s "$committed" "$local_manifest"; then
    CONFLICTS="$CONFLICTS $target"
  fi
done
if [ -n "$CONFLICTS" ] && [ "$FORCE" -eq 0 ]; then
  echo "these targets were prepared locally from different firmware:$CONFLICTS" >&2
  echo "re-run with --force to replace them with the published baseline" >&2
  exit 1
fi

# Install the committed manifests, then let the existing verifier decide what
# actually needs restoring. Re-running this script is therefore a cheap no-op.
RESTORE=""
for target in $TARGETS; do
  mkdir -p "$HERE/work/$target"
  cp "$PREPARED/$target.json" "$HERE/work/$target/source.json"
  if python3 "$HERE/tools/source_manifest.py" verify \
      "$HERE/work/$target/source.json" "$target" >/dev/null 2>&1; then
    echo "up to date: $target"
  else
    RESTORE="$RESTORE $target"
  fi
done

if [ -z "$RESTORE" ]; then
  echo
  echo "All requested targets already have their prepared artifacts."
  exit 0
fi
echo "restoring:$RESTORE"

if [ -n "$BUNDLE" ]; then
  [ -f "$BUNDLE" ] || { echo "bundle not found: $BUNDLE" >&2; exit 1; }
else
  mkdir -p "$CACHE_DIR"
  BUNDLE="$CACHE_DIR/$NAME"
  if [ -f "$BUNDLE" ] && [ "$(sha256_of "$BUNDLE")" = "$WANT_SHA" ]; then
    echo "using previously downloaded $BUNDLE"
  else
    echo "downloading $URL"
    curl -fL --progress-bar -o "$BUNDLE.part" "$URL"
    mv "$BUNDLE.part" "$BUNDLE"
  fi
fi

GOT_SHA="$(sha256_of "$BUNDLE")"
if [ "$GOT_SHA" != "$WANT_SHA" ]; then
  echo "bundle SHA-256 mismatch — refusing to unpack" >&2
  echo "  expected $WANT_SHA" >&2
  echo "  got      $GOT_SHA" >&2
  exit 1
fi
echo "bundle SHA-256 OK"

BUNDLE_DIR="$(cd "$(dirname "$BUNDLE")" && pwd)"
# Host-native: tar and zstd only. --long=31 must be repeated on decompression;
# the frame's window is larger than the decoder's default budget.
docker run --rm --platform "$BASEOS_DOCKER_PLATFORM_HOST" \
  -v "$HERE/work":/work -v "$BUNDLE_DIR":/bundle:ro \
  -e RESTORE="$RESTORE" -e NAME="$(basename "$BUNDLE")" \
  alpine:3.20 sh -euc '
  apk add -q tar zstd
  cd /work
  members=""
  for target in $RESTORE; do
    members="$members $target/boot-prefix.img $target/stock-harvest.tar"
  done
  # shellcheck disable=SC2086
  zstd -d --long=31 -c "/bundle/$NAME" | tar -xf - $members
'

for target in $RESTORE; do
  # Derived artifacts built from the previous inputs are now stale. Leaving them
  # would let a build mix a fresh boot prefix with an old rootfs, which is
  # exactly the confusion prepare-stock.sh clears for the same reason.
  for stale in rootfs.tar closure-report.txt bootlogo.bmp \
               "baseos-$target.img" "baseos-$target.img.zip"; do
    rm -f "$HERE/work/$target/$stale"
  done
  python3 "$HERE/tools/source_manifest.py" verify "$HERE/work/$target/source.json" "$target"
done

echo
echo "Prepared inputs restored. Build with:"
echo "  ./build-all.sh"
