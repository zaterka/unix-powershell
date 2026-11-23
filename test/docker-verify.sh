#!/bin/sh
# One-shot verification for unix-powershell.
#
# Builds the pinned test image and runs the full Pester suite against a
# read-only bind mount of this checkout. Exits non-zero when any test fails.
#
# Why --platform linux/amd64 is mandatory: the pwsh lts-alpine image segfaults
# (exit 139) under emulation on arm64 hosts, and lts-ubuntu-22.04 is the tag
# that works there.
#
# Usage:
#   ./test/docker-verify.sh
#   UX_TEST_IMAGE=my-tag ./test/docker-verify.sh
#   UX_SKIP_BUILD=1 ./test/docker-verify.sh      # reuse an already-built image
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
IMAGE=${UX_TEST_IMAGE:-unix-powershell-test}

echo "unix-powershell: docker verification"
echo "  root  : $ROOT"
echo "  image : $IMAGE"
echo

if [ "${UX_SKIP_BUILD:-0}" = "1" ]; then
    echo "skipping image build (UX_SKIP_BUILD=1)"
else
    docker build --platform linux/amd64 -t "$IMAGE" "$ROOT/test"
fi

echo
echo "running Pester suite in container"
echo

# Read-only mount: the suite must not need to write inside the checkout.
# --user keeps permission-denied cases meaningful (root bypasses them).
docker run --rm \
    --platform linux/amd64 \
    --user 1000:1000 \
    -e HOME=/tmp \
    -v "$ROOT:/work:ro" \
    -w /work \
    "$IMAGE" \
    pwsh -NoProfile -File /work/test/Run-Tests.ps1 -CI
