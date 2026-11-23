#Requires -Version 5.1
<#
.SYNOPSIS
    Smoke test: the profile must load and work in Constrained Language Mode.

.DESCRIPTION
    Constrained Language Mode (CLM) is common on managed machines (AppLocker / WDAC) and
    blocks Add-Type, reflection, COM, and .NET static method calls. The runtime path of
    this project is written to survive that, but "written to survive" is not evidence.

    This script is deliberately module-free (Pester cannot load under CLM), so it can run
    inside the constrained session it is testing. It exits 0 on success and 1 on failure,
    printing one ASCII line per check.

    How CLM is forced: setting __PSLockdownPolicy=4 in the environment before a new
    Windows PowerShell process starts puts that process in ConstrainedLanguage. This is the
    documented, non-admin mechanism. On PowerShell 7 the variable has no effect, so the
    script reports the mode it actually observed and fails loudly if it could not force it.

.PARAMETER InstallDir
    Install root to test. Defaults to $HOME\.unix-powershell, or UX_INSTALL_DIR.

.PARAMETER Force
    Run the checks even when the session is not actually constrained (useful for a
    FullLanguage dry run of the same assertions).

.EXAMPLE
    powershell -NoProfile -File .\test\60-Clm.ps1

.EXAMPLE
    # self-relaunch under the lockdown policy, which is how the checklist uses it
    $env:__PSLockdownPolicy = '4'
    powershell -NoProfile -File .\test\60-Clm.ps1
#>
[CmdletBinding()]
param(
    [string]$InstallDir,
    [switch]$Force
)

$ErrorActionPreference = 'Continue'

$script:Failures = 0
$script:Checks = 0

function Write-Check {
    param(
        [string]$Name,
        [bool]$Passed,
        [string]$Detail
    )
    $script:Checks++
    if ($Passed) {
        Write-Host ("  [OK]   {0}" -f $Name) -ForegroundColor Green
    }
    else {
        $script:Failures++
        Write-Host ("  [FAIL] {0}" -f $Name) -ForegroundColor Red
    }
    if ($Detail) {
        Write-Host ("         {0}" -f $Detail) -ForegroundColor DarkGray
    }
}

Write-Host ''
Write-Host 'unix-powershell: Constrained Language Mode smoke test' -ForegroundColor Cyan
Write-Host ("  host     : {0}" -f $Host.Name)
Write-Host ("  version  : {0}" -f $PSVersionTable.PSVersion)
Write-Host ("  platform : {0}" -f $env:OS)
Write-Host ''

$isWindowsHost = $env:OS -eq 'Windows_NT'
Write-Check -Name 'running on Windows' -Passed $isWindowsHost -Detail 'this test only means something on the target platform'
if (-not $isWindowsHost) {
    Write-Host 'SKIP: not a Windows host; Constrained Language Mode cannot be exercised here.' -ForegroundColor Yellow
    exit 0
}

$mode = [string]$ExecutionContext.SessionState.LanguageMode
Write-Check -Name 'session language mode is ConstrainedLanguage' -Passed ($mode -eq 'ConstrainedLanguage') -Detail ("observed: {0}" -f $mode)

if ($mode -ne 'ConstrainedLanguage' -and -not $Force) {
    Write-Host ''
    Write-Host 'The session is not constrained, so this run proves nothing about CLM.' -ForegroundColor Yellow
    Write-Host 'Re-run it like this:' -ForegroundColor Yellow
    Write-Host '  $env:__PSLockdownPolicy = ''4''' -ForegroundColor Yellow
    Write-Host '  powershell -NoProfile -File .\test\60-Clm.ps1' -ForegroundColor Yellow
    Write-Host 'or pass -Force to run the same assertions in FullLanguage.' -ForegroundColor Yellow
    exit 1
}

if (-not $InstallDir) {
    if ($env:UX_INSTALL_DIR) {
        $InstallDir = $env:UX_INSTALL_DIR
    }
    else {
        $homePath = $HOME
        if (-not $homePath) { $homePath = $env:USERPROFILE }
        $InstallDir = Join-Path $homePath '.unix-powershell'
    }
}

$entry = Join-Path $InstallDir 'profile\profile.ps1'
Write-Check -Name 'profile entry point exists' -Passed (Test-Path -LiteralPath $entry) -Detail $entry

if (-not (Test-Path -LiteralPath $entry)) {
    Write-Host ''
    Write-Host ("RESULT: FAILED - {0} of {1} checks failed (nothing installed to test)" -f $script:Failures, $script:Checks) -ForegroundColor Red
    exit 1
}

# Capture anything the load writes to the error stream: in CLM a silent failure is the
# likely symptom, and swallowing it is exactly the bug this test exists to catch.
$loadErrors = @()
try {
    $Error.Clear()
    . $entry
    foreach ($err in $Error) { $loadErrors += $err.Exception.Message }
}
catch {
    $loadErrors += $_.Exception.Message
}

Write-Check -Name 'profile loads without a terminating error' -Passed ($loadErrors.Count -eq 0) -Detail (($loadErrors -join ' | '))
Write-Check -Name 'load flag is set' -Passed ([bool]$global:UxLoaded) -Detail ("UxLoaded = {0}" -f [bool]$global:UxLoaded)

if ($global:Ux -and $global:Ux.ContainsKey('Version')) {
    Write-Check -Name 'state hashtable is populated' -Passed $true -Detail ("version {0}, caps lang {1}" -f $global:Ux.Version, $global:Ux.Caps.LanguageMode)
}
else {
    Write-Check -Name 'state hashtable is populated' -Passed $false -Detail '$global:Ux missing or empty'
}

# The wrappers are the whole point: they must exist, and they must be functions rather
# than shadowed aliases.
$wrapperProbe = @('ls', 'cat', 'grep', 'head', 'tail', 'rm', 'mkdir', 'ps')
$missing = @()
$shadowed = @()
foreach ($name in $wrapperProbe) {
    $command = Get-Command -Name $name -ErrorAction SilentlyContinue
    if (-not $command) {
        $missing += $name
    }
    elseif ($command.CommandType -ne 'Function') {
        $shadowed += ('{0}={1}' -f $name, $command.CommandType)
    }
}
Write-Check -Name 'unix wrappers exist' -Passed ($missing.Count -eq 0) -Detail ("missing: {0}" -f ($missing -join ', '))
Write-Check -Name 'unix wrappers resolve to functions' -Passed ($shadowed.Count -eq 0) -Detail ("shadowed: {0}" -f ($shadowed -join ', '))

# A wrapper must actually run: this is the CLM failure that unit tests in FullLanguage miss.
$runError = ''
try {
    $null = @(head -n 1 (Join-Path $InstallDir 'manifest.json') 2>$null)
}
catch {
    $runError = $_.Exception.Message
}
Write-Check -Name 'a wrapper executes without a CLM violation' -Passed ([string]::IsNullOrEmpty($runError)) -Detail $runError

# prompt must render rather than throw under CLM.
$promptError = ''
$promptText = ''
try {
    $promptText = [string](prompt)
}
catch {
    $promptError = $_.Exception.Message
}
Write-Check -Name 'prompt renders without throwing' -Passed ([string]::IsNullOrEmpty($promptError)) -Detail $promptError
$promptAscii = $true
foreach ($ch in $promptText.ToCharArray()) {
    if ([int]$ch -gt 126) { $promptAscii = $false }
}
Write-Check -Name 'prompt output is ASCII' -Passed $promptAscii -Detail ''

# ux doctor must be usable in CLM - it is the documented diagnostic path.
$doctorError = ''
try {
    $null = ux doctor 2>&1
}
catch {
    $doctorError = $_.Exception.Message
}
Write-Check -Name 'ux doctor runs without throwing' -Passed ([string]::IsNullOrEmpty($doctorError)) -Detail $doctorError

Write-Host ''
if ($script:Failures -gt 0) {
    Write-Host ("RESULT: FAILED - {0} of {1} checks failed" -f $script:Failures, $script:Checks) -ForegroundColor Red
    exit 1
}
Write-Host ("RESULT: PASSED - {0} checks" -f $script:Checks) -ForegroundColor Green
exit 0
