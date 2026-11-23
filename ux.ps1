#Requires -Version 5.1
#
# unix-powershell - ux.ps1
# Standalone recovery entry point. Works with no profile loaded:
#
#   powershell -NoProfile -File "%USERPROFILE%\.unix-powershell\ux.ps1" doctor
#
# It locates profile\profile.ps1 next to itself, dot-sources it (so `ux` and its helpers
# exist in this session), and forwards every argument to the `ux` function. All logic lives
# in lib/40-commands.ps1; this file only bootstraps, so there is nothing to keep in sync.
# It never throws and never emits a stack trace: each failure is one ASCII line plus a
# non-zero exit code (a plain `return` when this file is dot-sourced instead of run).

$uxEntryMain = $true
try {
    if ([string]$MyInvocation.InvocationName -eq '.') { $uxEntryMain = $false }
} catch {
    $uxEntryMain = $true
}

$uxEntryDir = ''
try {
    if ($null -ne $PSScriptRoot -and $PSScriptRoot -ne '') {
        $uxEntryDir = [string]$PSScriptRoot
    } else {
        $uxEntryDir = (Get-Location).Path
    }
} catch {
    $uxEntryDir = ''
}

$uxEntryPath = ''
if ($uxEntryDir -ne '') { $uxEntryPath = Join-Path (Join-Path $uxEntryDir 'profile') 'profile.ps1' }

$uxEntryStatus = 'ok'
$uxEntryError = ''

if ($uxEntryPath -eq '' -or -not (Test-Path -LiteralPath $uxEntryPath)) {
    $uxEntryStatus = 'missing'
} else {
    try {
        . $uxEntryPath
    } catch {
        $uxEntryStatus = 'failed'
        $uxEntryError = $_.Exception.Message
    }
    if ($uxEntryStatus -eq 'ok') {
        $uxEntryCommand = $null
        try { $uxEntryCommand = Get-Command -Name 'ux' -ErrorAction SilentlyContinue } catch { $uxEntryCommand = $null }
        if ($null -eq $uxEntryCommand) { $uxEntryStatus = 'no-command' }
    }
}

if ($uxEntryStatus -ne 'ok') {
    if ($uxEntryStatus -eq 'missing') {
        Write-Host '[unix-powershell] install looks broken: profile\profile.ps1 was not found next to ux.ps1. Reinstall with the documented one-liner, or run: powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1 -SourceDir "<release folder>"'
    } elseif ($uxEntryStatus -eq 'failed') {
        Write-Host ('[unix-powershell] install looks broken: profile load failed ({0}). Reinstall with the documented one-liner, or run: powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1' -f $uxEntryError)
    } else {
        Write-Host ('[unix-powershell] install looks broken: the ux command did not load from {0}. Reinstall with the documented one-liner, or run: powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1' -f $uxEntryPath)
    }
    if ($uxEntryMain) { exit 1 }
    $global:LASTEXITCODE = 1
    Remove-Variable -Name 'uxEntryMain', 'uxEntryDir', 'uxEntryPath', 'uxEntryStatus', 'uxEntryError', 'uxEntryCommand' -ErrorAction SilentlyContinue
    return
}

try {
    ux @args
} catch {
    Write-Host ('[unix-powershell] ux failed: {0}' -f $_.Exception.Message)
    if ($uxEntryMain) { exit 1 }
    $global:LASTEXITCODE = 1
    Remove-Variable -Name 'uxEntryMain', 'uxEntryDir', 'uxEntryPath', 'uxEntryStatus', 'uxEntryError', 'uxEntryCommand' -ErrorAction SilentlyContinue
    return
}

Remove-Variable -Name 'uxEntryMain', 'uxEntryDir', 'uxEntryPath', 'uxEntryStatus', 'uxEntryError', 'uxEntryCommand' -ErrorAction SilentlyContinue
