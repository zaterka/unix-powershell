# Reproducible test image for unix-powershell.
#
# The stock mcr.microsoft.com/powershell images are unusable for this project:
#   - lts-alpine segfaults (exit 139) under amd64 emulation on arm64 hosts
#   - no Pester and no git are installed
# so we bake both in. Keep the tag pinned; bump it deliberately.
#
# Build (from the repo root):
#   docker build --platform linux/amd64 -t unix-powershell-test test
# Run:
#   docker run --rm --platform linux/amd64 --user 1000:1000 \
#     -v "$PWD:/work:ro" -w /work unix-powershell-test \
#     pwsh -NoProfile -File /work/test/Run-Tests.ps1 -CI

FROM mcr.microsoft.com/powershell:lts-ubuntu-22.04

RUN apt-get update \
    && apt-get install -y --no-install-recommends git curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Pester is required by every test file; bake it so runs are offline-stable.
# Pinned to 5.7.1 on purpose: the suite is written against the Pester 5 API.
RUN pwsh -NoProfile -Command \
    "Set-PSRepository -Name PSGallery -InstallationPolicy Trusted; Install-Module Pester -Scope AllUsers -RequiredVersion 5.7.1 -Force -SkipPublisherCheck"

WORKDIR /work
