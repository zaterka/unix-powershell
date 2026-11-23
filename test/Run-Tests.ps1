#Requires -Version 5.1
<#
.SYNOPSIS
    Runs the Pester test suite for unix-powershell.

.DESCRIPTION
    Discovers test/*.Tests.ps1, requires Pester 5+, and returns a non-zero exit
    code when any test fails (so CI and docker-verify.sh can gate on it).

    Works on Windows PowerShell 5.1 and PowerShell 7+, because the Windows checklist
    asks the user to run this on the machine that actually matters.

.PARAMETER CI
    Exit with the Pester failed-test count as the process exit code. Also disables
    the interactive pause-free verbosity downgrade.

.PARAMETER Path
    One or more test paths to run. Defaults to this script's directory.

.EXAMPLE
    ./test/Run-Tests.ps1 -CI

.EXAMPLE
    docker run --rm --platform linux/amd64 -v "$PWD:/work:ro" -w /work unix-powershell-test pwsh -NoProfile -File /work/test/Run-Tests.ps1 -CI
#>
[CmdletBinding()]
param(
    [switch]$CI,
    [string[]]$Path
)

$ErrorActionPreference = 'Stop'

$here = $PSScriptRoot
if (-not $here) { $here = Split-Path -Parent $MyInvocation.MyCommand.Path }

if (-not $Path) {
    $Path = @($here)
}

$pester = Get-Module -ListAvailable -Name Pester |
    Sort-Object -Property Version -Descending |
    Select-Object -First 1

if (-not $pester) {
    Write-Host 'FAIL: Pester is not installed.' -ForegroundColor Red
    Write-Host '      Install-Module Pester -Scope CurrentUser -MinimumVersion 5.5.0 -Force' -ForegroundColor Yellow
    exit 2
}

if ($pester.Version.Major -lt 5) {
    Write-Host ("FAIL: Pester {0} found, but version 5.0 or newer is required." -f $pester.Version) -ForegroundColor Red
    Write-Host '      Install-Module Pester -Scope CurrentUser -MinimumVersion 5.5.0 -Force -SkipPublisherCheck' -ForegroundColor Yellow
    exit 2
}

Import-Module Pester -MinimumVersion 5.0 -ErrorAction Stop

# Report which host this run exercised: several suite behaviours are OS-gated.
$osLabel = 'unknown'
if ($env:OS -eq 'Windows_NT') {
    $osLabel = 'windows'
} elseif ((Get-Command uname -CommandType Application -ErrorAction SilentlyContinue)) {
    $osLabel = 'unix'
}

Write-Host ''
Write-Host 'unix-powershell test suite' -ForegroundColor Cyan
Write-Host ("  pester   : {0}" -f $pester.Version)
Write-Host ("  pwsh     : {0}" -f $PSVersionTable.PSVersion)
Write-Host ("  platform : {0}" -f $osLabel)
Write-Host ("  path     : {0}" -f ($Path -join ', '))
Write-Host ''

$config = New-PesterConfiguration
$config.Run.Path = $Path
$config.Run.PassThru = $true
$config.Run.Exit = $false
$config.Output.Verbosity = 'Detailed'

if ($CI) {
    $config.Output.Verbosity = 'Normal'
}

$result = Invoke-Pester -Configuration $config

Write-Host ''
if ($result.FailedCount -gt 0) {
    Write-Host ("RESULT: FAILED - {0} failed, {1} passed, {2} skipped / {3} discovered" -f `
        $result.FailedCount, $result.PassedCount, $result.SkippedCount, $result.TotalCount) -ForegroundColor Red
    exit 1
}

Write-Host ("RESULT: PASSED - {0} passed, {1} skipped / {2} discovered" -f `
    $result.PassedCount, $result.SkippedCount, $result.TotalCount) -ForegroundColor Green
exit 0
