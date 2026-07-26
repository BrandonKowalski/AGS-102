#!/bin/sh
# Publish the prepared-artifact cache that fetch-prepared.sh restores.
# Usage: ./cache-pack.sh [YYYYMMDD]
#
# Packs every target's boot-prefix.img and stock-harvest.tar — the only two
# things prepare-stock.sh derives from a StockMod .img — into one long-window
# zstd stream, and commits the manifests that make it verifiable:
#
#   manifest/prepared/<target>.json   each target's source.json, the trust anchor
#   manifest/prepared/bundle.sha256   hash of the bundle published below
#   manifest/prepared/bundle.url      where that bundle lives
#
# One stream rather than per-target blobs because the targets share most of
# their bytes (103 MiB of every boot prefix and 2406 of 2409 harvest files are
# identical across the fleet), so a 2 GiB window collapses ~2.9 GB to ~133 MB.
# The cost is that refreshing one target republishes the whole bundle, which is
# the right trade at a couple of firmware refreshes a year.
#
# The bundle hash covers the download; the per-artifact hashes inside each
# source.json cover the contents, and are what every build already checks. The
# bundle is therefore an optimisation, never a source of truth: prepare-stock.sh
# regenerates the same artifacts from the vendor image, and must produce the
# same hashes.
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=tools/docker-platform.sh
. "$HERE/tools/docker-platform.sh"
STAMP="${1:-$(date +%Y%m%d)}"
case "$STAMP" in
  [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]) ;;
  *) echo "usage: $0 [YYYYMMDD]" >&2; exit 2 ;;
esac

REPO_URL="https://github.com/pvaibhav/BaseOS"
PREPARED="$HERE/manifest/prepared"
OUT_DIR="$HERE/work/prepared"
NAME="baseos-prepared-$STAMP.tar.zst"
TAG="prepared-$STAMP"
TARGETS="$(python3 "$HERE/tools/device_profile.py" list)"

SKIP_VERIFY="${BASEOS_SKIP_VERIFY:-0}"

# Refuse to publish anything that has not passed the gates. Every target is
# checked before a single byte is packed, so a bad one cannot be half-published.
for target in $TARGETS; do
  work="$HERE/work/$target"
  for artifact in source.json boot-prefix.img stock-harvest.tar; do
    [ -f "$work/$artifact" ] || {
      echo "missing $work/$artifact (run prepare-stock.sh $target IMAGE)" >&2
      exit 1
    }
  done
  if [ "$SKIP_VERIFY" = 1 ]; then
    python3 "$HERE/tools/source_manifest.py" verify "$work/source.json" "$target"
  else
    "$HERE/verify-target.sh" "$target"
  fi
done

mkdir -p "$PREPARED" "$OUT_DIR"
for target in $TARGETS; do
  cp "$HERE/work/$target/source.json" "$PREPARED/$target.json"
done

# Host-native: tar and zstd only. Members are passed in a fixed order rather than
# sorted, grouped so each run of near-identical files stays together: all ten boot
# prefixes, then all ten harvests. Interleaving them per target costs ~4 MB.
# --mtime/--owner keep member metadata stable so the same inputs pack to the same
# stream.
#
# 2.87 GiB of input against zstd's largest window (--long=31, 2 GiB) means the
# harvests cannot reach back past the boot prefixes, which costs about 17 MB
# against compressing the two groups as separate streams (133 MB vs 150 MB).
# That is not worth a second stream, a second hash and a second decompress
# pipeline in fetch-prepared.sh for a download developers do once.
docker run --rm --platform "$BASEOS_DOCKER_PLATFORM_HOST" \
  -v "$HERE/work":/work -e TARGETS="$TARGETS" -e NAME="$NAME" \
  alpine:3.20 sh -euc '
  apk add -q tar zstd
  cd /work
  members=""
  for target in $TARGETS; do members="$members $target/boot-prefix.img"; done
  for target in $TARGETS; do members="$members $target/stock-harvest.tar"; done
  # shellcheck disable=SC2086
  tar --mtime=@0 --owner=0 --group=0 --numeric-owner -cf - $members \
    | zstd -19 -T0 --long=31 -o "/work/prepared/$NAME" -f
  ls -l "/work/prepared/$NAME"
'

if command -v sha256sum >/dev/null 2>&1; then
  BUNDLE_SHA="$(sha256sum "$OUT_DIR/$NAME" | cut -d' ' -f1)"
else
  BUNDLE_SHA="$(shasum -a 256 "$OUT_DIR/$NAME" | cut -d' ' -f1)"
fi
printf "%s  %s\n" "$BUNDLE_SHA" "$NAME" > "$PREPARED/bundle.sha256"
printf "%s/releases/download/%s/%s\n" "$REPO_URL" "$TAG" "$NAME" > "$PREPARED/bundle.url"

echo
echo "Bundle:  $OUT_DIR/$NAME"
echo "SHA-256: $BUNDLE_SHA"
echo
echo "Publish it, then commit the manifests:"
echo "  gh release create $TAG --prerelease --notes 'Prepared artifacts $STAMP' \\"
echo "    $OUT_DIR/$NAME"
echo "  git add manifest/prepared && git commit -m 'chore(cache): prepared artifacts $STAMP'"
