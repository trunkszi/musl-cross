#!/usr/bin/env bash
set -euo pipefail
[[ $# == 3 ]] || { echo "Usage: $0 <target> <container-image> <os-label>" >&2; exit 64; }
TARGET=$1
CONTAINER_IMAGE=$2
OS_LABEL=$3
PROJECT_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
[[ $TARGET =~ ^[a-z0-9_]+(-[a-z0-9_]+)+$ && -f ${PROJECT_ROOT}/targets/${TARGET}/config ]] || {
    echo "Unsupported target" >&2; exit 64;
}
case "$OS_LABEL" in amazonlinux2|alinux3|centos7|ubuntu22) ;; *) echo "Unsupported container label" >&2; exit 64 ;; esac
[[ $CONTAINER_IMAGE =~ ^[a-zA-Z0-9][a-zA-Z0-9./_:@-]+$ ]] || { echo "Invalid container image" >&2; exit 64; }
CONTAINER_NAME="musl-cross-${OS_LABEL}-${TARGET}-$$-${RANDOM}"
cleanup() { docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true; }
trap cleanup EXIT
# setarch -R is required by the native TSan regression check.
docker run -d --security-opt seccomp=unconfined --name "$CONTAINER_NAME" \
    -v "${PROJECT_ROOT}:/workspace/musl-cross" -w /workspace/musl-cross \
    "$CONTAINER_IMAGE" tail -f /dev/null
# Dependency setup is owned by scripts/host-dependencies.sh inside make.
docker exec -e BUILD_TARGET="$TARGET" -e BUILD_OS_LABEL="$OS_LABEL" \
    -e BUILD_JOBS="${BUILD_JOBS:-2}" "$CONTAINER_NAME" bash -c '
    set -euo pipefail
    cd /workspace/musl-cross
    ./scripts/make "$BUILD_TARGET"
    source_archive="${BUILD_TARGET}.tar.xz"
    artifact="${BUILD_TARGET}-${BUILD_OS_LABEL}.tar.xz"
    test -s "$source_archive"
    test -s "${source_archive}.sha256"
    read -r expected < "${source_archive}.sha256"
    [[ $expected =~ ^[0-9a-f]{64}$ ]]
    printf "%s  %s\n" "$expected" "$source_archive" | sha256sum --check -
    mv -- "$source_archive" "$artifact"
    mv -- "${source_archive}.sha256" "${artifact}.sha256"
    printf "%s  %s\n" "$expected" "$artifact" | sha256sum --check -
'
echo "Build output: ${TARGET}-${OS_LABEL}.tar.xz and .sha256"
