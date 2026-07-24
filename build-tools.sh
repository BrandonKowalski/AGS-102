#!/bin/sh
# Build/fetch the static aarch64 tools for the base OS rootfs:
#   work/tools/busybox        (Alpine busybox-static: init, ash, mount, insmod,
#                              udhcpc, hwclock, getty, poweroff, vi, top, ...)
#   work/tools/dropbearmulti  (static dropbear + dropbearkey + dbclient + scp)
#   work/tools/curl           (static HTTPS client used by RetroAchievements)
#   work/tools/ca-certificates.crt (TLS trust store)
#   work/tools/fbsplash       (framebuffer boot splash)
#   work/tools/gptgrow        (grow last GPT partition on first boot)
#   work/tools/sftp-server    (OpenSSH sftp subsystem child for dropbear)
# Must use --platform linux/arm64 so the produced binaries are aarch64 for the
# handheld (native on Apple Silicon; QEMU on Intel hosts).
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=tools/docker-platform.sh
. "$HERE/tools/docker-platform.sh"
TOOLS="$HERE/work/tools"
mkdir -p "$TOOLS"

docker run --rm --platform "$BASEOS_DOCKER_PLATFORM_AARCH64" -v "$TOOLS":/out alpine:3.20 sh -euc '
  apk add -q busybox-static
  cp /bin/busybox.static /out/busybox

  apk add -q build-base zlib-dev zlib-static curl
  cd /tmp
  curl -fsSLO https://matt.ucc.asn.au/dropbear/releases/dropbear-2024.85.tar.bz2
  tar xf dropbear-2024.85.tar.bz2
  cd dropbear-2024.85
  ./configure --enable-static --disable-lastlog --disable-wtmp >/dev/null
  make -j"$(nproc)" PROGRAMS="dropbear dropbearkey dbclient scp" MULTI=1 >/dev/null
  cp dropbearmulti /out/dropbearmulti
  chmod 755 /out/busybox /out/dropbearmulti
'

# curl: NextUI's HTTP layer invokes the CLI for RetroAchievements. Build it in
# a clean container so it cannot inherit configure state from another tool.
# The pinned static binary carries no StockMod or frontend ABI dependency.
docker run --rm --platform "$BASEOS_DOCKER_PLATFORM_AARCH64" -v "$TOOLS":/out alpine:3.20 sh -euc '
  apk add -q build-base ca-certificates tar xz perl \
    openssl-dev openssl-libs-static zlib-dev zlib-static
  CURL_VERSION=8.21.0
  CURL_SHA256=aa1b66a70eace83dc624508745646c08ae561de512ab403adffb93ac87fc72e6
  cd /tmp
  wget -q "https://curl.se/download/curl-$CURL_VERSION.tar.xz"
  echo "$CURL_SHA256  curl-$CURL_VERSION.tar.xz" | sha256sum -c -
  tar xf "curl-$CURL_VERSION.tar.xz"
  cd "curl-$CURL_VERSION"
  ./configure \
    --disable-shared --enable-static --with-openssl --with-zlib \
    --without-libpsl --without-brotli --without-zstd --without-libidn2 \
    --without-nghttp2 --disable-ldap --disable-ldaps --disable-rtsp \
    --disable-dict --disable-telnet --disable-tftp --disable-pop3 \
    --disable-imap --disable-smb --disable-smtp --disable-gopher \
    --disable-mqtt --disable-manual >/dev/null
  make -j"$(nproc)" LDFLAGS=-all-static >/dev/null
  strip src/curl
  cp src/curl /out/curl
  cp /etc/ssl/certs/ca-certificates.crt /out/ca-certificates.crt
  chmod 755 /out/curl
'

# fbsplash: framebuffer boot splash (Lexend wordmark via freetype), see
# src/fbsplash.c.
docker run --rm --platform "$BASEOS_DOCKER_PLATFORM_AARCH64" \
  -v "$TOOLS":/out -v "$HERE/src":/src:ro alpine:3.20 sh -euc '
  apk add -q build-base linux-headers pkgconf \
    freetype-dev freetype-static zlib-static libpng-static bzip2-static brotli-static
  gcc -static -O2 $(pkg-config --cflags freetype2) -o /out/fbsplash /src/fbsplash.c \
    $(pkg-config --static --libs freetype2)
  strip /out/fbsplash
'

# gptgrow: zero-dependency static tool that grows the last GPT partition to
# fill the card on first boot (see tools/gptgrow.c).
docker run --rm --platform "$BASEOS_DOCKER_PLATFORM_AARCH64" \
  -v "$TOOLS":/out -v "$HERE/tools":/src:ro alpine:3.20 sh -euc '
  apk add -q build-base linux-headers
  gcc -static -O2 -o /out/gptgrow /src/gptgrow.c
  strip /out/gptgrow
'

# sftp-server: dropbear 2024.85 ships the sftp subsystem execing
# SFTPSERVER_PATH=/usr/libexec/sftp-server, so the transport (owned by dropbear)
# hands each sftp session to this OpenSSH helper. It needs no crypto of its own,
# so build it without OpenSSL and without zlib for a small static binary.
docker run --rm --platform "$BASEOS_DOCKER_PLATFORM_AARCH64" -v "$TOOLS":/out alpine:3.20 sh -euc '
  apk add -q build-base linux-headers ca-certificates zlib-dev zlib-static
  OPENSSH_VERSION=10.4p1
  OPENSSH_SHA256=ef6026dd2aea8d56059638d5d3262902c892ceba9f88395835e0d06d3fb63238
  cd /tmp
  wget -q "https://cdn.openbsd.org/pub/OpenBSD/OpenSSH/portable/openssh-$OPENSSH_VERSION.tar.gz"
  echo "$OPENSSH_SHA256  openssh-$OPENSSH_VERSION.tar.gz" | sha256sum -c -
  tar xf "openssh-$OPENSSH_VERSION.tar.gz"
  cd "openssh-$OPENSSH_VERSION"
  ./configure --without-openssl --without-zlib --without-pam LDFLAGS=-static >/dev/null
  make sftp-server >/dev/null
  strip sftp-server
  cp sftp-server /out/sftp-server
  chmod 755 /out/sftp-server
'

file "$TOOLS/busybox" "$TOOLS/dropbearmulti" "$TOOLS/curl" \
  "$TOOLS/fbsplash" "$TOOLS/gptgrow" "$TOOLS/sftp-server" 2>/dev/null || true
[ -x "$TOOLS/curl" ] || { echo "curl build did not produce an executable" >&2; exit 1; }
file "$TOOLS/curl" | grep -q "statically linked" \
  || { echo "curl build is not static" >&2; exit 1; }
[ -s "$TOOLS/ca-certificates.crt" ] \
  || { echo "curl CA bundle is missing or empty" >&2; exit 1; }
[ -x "$TOOLS/sftp-server" ] || { echo "sftp-server build did not produce an executable" >&2; exit 1; }
file "$TOOLS/sftp-server" | grep -q "statically linked" \
  || { echo "sftp-server build is not static" >&2; exit 1; }
ls -lh "$TOOLS"
