#!/usr/bin/env bash
#
# Build the k3OS kernel for amd64, arm64, and arm (armhf) on the host.
# Runs the same docker/buildx flow used by .github/workflows/build.yml so
# local results match CI artifacts.
#
# Usage:
#   ./build-all.sh                # build all three arches
#   ./build-all.sh amd64 arm64    # build a subset
#
# Requirements:
#   - docker with buildx
#   - tonistiigi/binfmt or qemu-user-static for emulating non-host arches
#
# Output:
#   ./dist/artifacts/<arch>/      # per-arch kernel/headers/extras tarballs

set -euo pipefail

cd "$(dirname "$0")"

declare -A PLATFORM=(
    [amd64]=linux/amd64
    [arm64]=linux/arm64
    [arm]=linux/arm/v7
)

ARCHES=("${@:-amd64 arm64 arm}")
# Re-split if invoked with no args; default expanded as a single string.
if [ "$#" -eq 0 ]; then
    ARCHES=(amd64 arm64 arm)
fi

for arch in "${ARCHES[@]}"; do
    if [ -z "${PLATFORM[$arch]:-}" ]; then
        echo "unknown arch: $arch (valid: amd64 arm64 arm)" >&2
        exit 2
    fi
done

if ! docker buildx version >/dev/null 2>&1; then
    echo "docker buildx is required; install Docker 20.10+ or the buildx plugin" >&2
    exit 2
fi

HOST_ARCH=$(uname -m)
case "${HOST_ARCH}" in
    x86_64)  HOST_ARCH=amd64 ;;
    aarch64) HOST_ARCH=arm64 ;;
    armv7l)  HOST_ARCH=arm   ;;
esac

need_qemu=0
for arch in "${ARCHES[@]}"; do
    if [ "${arch}" != "${HOST_ARCH}" ]; then
        need_qemu=1
    fi
done

if [ "${need_qemu}" -eq 1 ]; then
    echo "==> registering binfmt handlers for cross-arch builds"
    docker run --privileged --rm tonistiigi/binfmt --install all >/dev/null
fi

mkdir -p dist/artifacts build

for arch in "${ARCHES[@]}"; do
    platform=${PLATFORM[$arch]}
    image=k3os-kernel-builder:${arch}
    echo
    echo "==============================================================="
    echo "==> building ${arch} (${platform})"
    echo "==============================================================="

    docker buildx build \
        --platform "${platform}" \
        --build-arg DAPPER_HOST_ARCH="${arch}" \
        --load \
        -t "${image}" \
        -f Dockerfile.dapper .

    # Clean dist/build for this arch to keep artifact sets separate.
    rm -rf build dist/generic
    mkdir -p build

    docker run --rm --privileged \
        --platform "${platform}" \
        -e ARCH="${arch}" \
        -e DAPPER_UID="$(id -u)" \
        -e DAPPER_GID="$(id -g)" \
        -e GIT_CONFIG_COUNT=1 \
        -e GIT_CONFIG_KEY_0=safe.directory \
        -e GIT_CONFIG_VALUE_0='*' \
        -v "$(pwd)":/source \
        -w /source \
        "${image}" ci

    out=dist/artifacts/${arch}
    rm -rf "${out}"
    mkdir -p "${out}"
    # scripts/package writes per-arch tarballs into dist/artifacts/ at top level
    # since the same source tree is reused; move them under per-arch dirs.
    shopt -s nullglob
    moved=0
    for f in dist/artifacts/*_${arch}.tar.xz dist/artifacts/*.tar.xz; do
        [ -f "$f" ] || continue
        case "$f" in
            dist/artifacts/${arch}/*) continue ;;
        esac
        mv -f "$f" "${out}/"
        moved=$((moved + 1))
    done
    shopt -u nullglob
    echo "==> wrote ${moved} artifact(s) to ${out}"
done

echo
echo "==> done. artifacts under dist/artifacts/<arch>/"
ls -lah dist/artifacts/*/ 2>/dev/null || true
