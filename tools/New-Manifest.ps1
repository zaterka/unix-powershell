#Requires -Version 5.1
<#
.SYNOPSIS
    Regenerates manifest.json (and SHA256SUMS) for unix-powershell.

.DESCRIPTION
    manifest.json is the single source of truth for the installer: it carries the
    version string and the SHA256 of every runtime file. Two rules keep it honest:

      1. The version in the manifest must equal $global:Ux.Version in lib/00-core.ps1.
         A test enforces this, and this script refuses to write a manifest that
         disagrees.

      2. Only runtime files are listed. Tests, docs, tools and the installer itself
         are deliberately excluded: the installer fetches the manifest and then the
         files it names, so anything listed here is downloaded at install time.

.PARAMETER Version
    Version to write. Defaults to the version currently declared in lib/00-core.ps1.

.PARAMETER Root
    Repository root. Defaults to the parent of this script's directory.

.PARAMETER OutputPath
    Manifest path. Defaults to <Root>/manifest.json.

.EXAMPLE
    ./tools/New-Manifest.ps1

.EXAMPLE
    ./tools/New-Manifest.ps1 -Version 0.2.0
#>
[CmdletBinding()]
param(
    [string]$Version,
    [string]$Root,
    [string]$OutputPath
)

$ErrorActionPreference = 'Stop'

if (-not $Root) {
    $scriptDir = $PSScriptRoot
    if (-not $scriptDir) { $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
    $Root = Split-Path -Parent $scriptDir
}

if (-not $OutputPath) { $OutputPath = Join-Path $Root 'manifest.json' }

# Runtime files shipped to the user. Keep this list explicit: adding a lib file
# without updating it is a packaging bug we want to surface, not hide.
$runtimeFiles = @(
    'profile/profile.ps1'
    'lib/00-core.ps1'
    'lib/05-args.ps1'
    'lib/10-git.ps1'
    'lib/20-prompt.ps1'
    'lib/30-unix.ps1'
    'lib/40-commands.ps1'
    'ux.ps1'
)

$corePath = Join-Path $Root 'lib/00-core.ps1'
if (-not (Test-Path -LiteralPath $corePath)) {
    throw ("core file not found: {0}" -f $corePath)
}

if (-not $Version) {
    $coreText = Get-Content -LiteralPath $corePath -Raw
    if ($coreText -match "Version\s*=\s*'([0-9]+\.[0-9]+\.[0-9]+)'") {
        $Version = $Matches[1]
    }
    else {
        throw 'could not read the version from lib/00-core.ps1; pass -Version explicitly'
    }
}

if ($Version -notmatch '^[0-9]+\.[0-9]+\.[0-9]+$') {
    throw ("version must be X.Y.Z (got '{0}')" -f $Version)
}

$entries = @()
$missing = @()

foreach ($relative in $runtimeFiles) {
    $full = Join-Path $Root $relative
    if (-not (Test-Path -LiteralPath $full)) {
        $missing += $relative
        continue
    }

    $hash = Get-FileHash -LiteralPath $full -Algorithm SHA256
    $entries += [ordered]@{
        path   = $relative
        sha256 = $hash.Hash.ToLower()
        bytes  = (Get-Item -LiteralPath $full).Length
    }
}

if ($missing.Count -gt 0) {
    throw ("missing runtime file(s): {0}" -f ($missing -join ', '))
}

$manifest = [ordered]@{
    version = $Version
    files   = $entries
}

$json = $manifest | ConvertTo-Json -Depth 10
Set-Content -LiteralPath $OutputPath -Value $json -Encoding UTF8

Write-Host ("wrote {0} ({1} files, version {2})" -f $OutputPath, $entries.Count, $Version) -ForegroundColor Green

# Human-comparable checksums for out-of-band review: the documented trust model
# asks reviewers to verify a reviewed checkout against published sums.
$sumsPath = Join-Path $Root 'SHA256SUMS'
$sumLines = @()
foreach ($entry in $entries) {
    $sumLines += ('{0}  {1}' -f $entry['sha256'], $entry['path'])
}
Set-Content -LiteralPath $sumsPath -Value $sumLines -Encoding UTF8
Write-Host ("wrote {0}" -f $sumsPath) -ForegroundColor Green
