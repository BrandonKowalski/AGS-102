# Shared Docker platform helpers for BaseOS build scripts.
# Source from a script that has set HERE to the repository root:
#   . "$HERE/tools/docker-platform.sh"
#
# BASEOS_DOCKER_PLATFORM_HOST  — this machine's CPU (no QEMU when possible)
# BASEOS_DOCKER_PLATFORM_AARCH64 — device/userspace arch for the handheld

BASEOS_DOCKER_PLATFORM_AARCH64=linux/arm64

case "$(uname -m)" in
  arm64|aarch64) BASEOS_DOCKER_PLATFORM_HOST=linux/arm64 ;;
  x86_64|amd64)  BASEOS_DOCKER_PLATFORM_HOST=linux/amd64 ;;
  *)
    echo "unsupported host architecture: $(uname -m)" >&2
    exit 1
    ;;
esac
