#Requires -Version 5.1
#
# unix-powershell - profile/profile.ps1
# Entry point dot-sourced from the injected $PROFILE block (install.ps1 writes that block).
#
# LOAD ORDER (explicit, and shared with lib/00-core.ps1's header):
#   1. dot-source lib/00-core.ps1        - creates $global:Ux, default config
#   2. Initialize-UxConfig               - reads <install>\config.json (strict JSON)
#   3. Initialize-UxCaps                 - capability probe (Vt/Color/Git/...)
#   4. Remove-UxShadowedCommands         - snapshot + remove shadowing Alias/Function entries
#   5. dot-source lib/05-args.ps1        - ConvertFrom-UxArgv
#   6. dot-source lib/10-git.ps1         - repo discovery
#   7. dot-source lib/20-prompt.ps1      - prompt + themes
#   8. dot-source lib/30-unix.ps1        - Unix wrappers
#   9. dot-source lib/40-commands.ps1    - the `ux` command
#  10. record $global:Ux.LoadMs, set $global:UxLoaded, print the one-line banner
# Step 4 must happen before step 8: aliases win over functions, so the shadowing entries
# have to go before the wrapper functions are defined.
#
# This file defines NO wrappers, NO aliases and NO prompt. It never throws: every step is
# individually guarded and a failure prints exactly one ASCII line and keeps the shell alive.

$uxScriptStart = Get-Date
$uxErrorPrefix = '[unix-powershell]'
$uxLoadedFlag = $false
$uxExistingLoad = Get-Variable -Name 'UxLoaded' -Scope Global -ErrorAction SilentlyContinue

try {
    # ---- guard: disabled, or already loaded once in this session ----
    if ($null -ne $uxExistingLoad -and $uxExistingLoad.Value -eq $true) {
        Remove-Variable -Name 'uxScriptStart', 'uxErrorPrefix', 'uxLoadedFlag', 'uxExistingLoad' -ErrorAction SilentlyContinue
        return
    }
    if ($env:UX_DISABLE -eq '1') {
        Remove-Variable -Name 'uxScriptStart', 'uxErrorPrefix', 'uxLoadedFlag', 'uxExistingLoad' -ErrorAction SilentlyContinue
        return
    }

    # ---- locate the install root: the directory above profile\ ----
    $uxRoot = ''
    try {
        if ($null -ne $PSScriptRoot -and $PSScriptRoot -ne '') {
            # Split-Path -Parent does not accept -LiteralPath (parameter-set error), and this path
            # comes from $PSScriptRoot rather than user input.
            $uxRoot = Split-Path -Parent $PSScriptRoot
        }
    } catch {
        $uxRoot = ''
    }
    if ($null -eq $uxRoot -or $uxRoot -eq '') {
        # $PSScriptRoot is empty (piped script / unusual host): fall back to the
        # install-dir precedence env -> home, without depending on lib/00-core.ps1.
        $uxRoot = ''
        if ($null -ne $env:UX_INSTALL_DIR -and $env:UX_INSTALL_DIR -ne '') {
            $uxRoot = [string]$env:UX_INSTALL_DIR
        } else {
            $uxHomeBase = ''
            if ($null -ne $HOME -and $HOME -ne '') { $uxHomeBase = [string]$HOME }
            elseif ($null -ne $env:USERPROFILE -and $env:USERPROFILE -ne '') { $uxHomeBase = [string]$env:USERPROFILE }
            if ($uxHomeBase -ne '') { $uxRoot = Join-Path $uxHomeBase '.unix-powershell' }
        }
    }

    $uxLibDir = ''
    if ($null -ne $uxRoot -and $uxRoot -ne '') { $uxLibDir = Join-Path $uxRoot 'lib' }

    # ---- 1. core ----
    $uxCoreName = '00-core.ps1'
    $uxCoreLoaded = $false
    try {
        if ($uxLibDir -eq '') {
            Write-Host ('{0} failed to load {1}: install directory not found' -f $uxErrorPrefix, $uxCoreName)
        } else {
            $uxCorePath = Join-Path $uxLibDir $uxCoreName
            if (Test-Path -LiteralPath $uxCorePath) {
                . $uxCorePath
                $uxCoreLoaded = $true
            } else {
                Write-Host ('{0} failed to load {1}: file not found in {2}' -f $uxErrorPrefix, $uxCoreName, $uxLibDir)
            }
        }
    } catch {
        $uxCoreLoaded = $false
        Write-Host ('{0} failed to load {1}: {2}' -f $uxErrorPrefix, $uxCoreName, $_.Exception.Message)
    }

    # ---- 2-4. config, capability probe, alias snapshot (core functions, guarded) ----
    # No Get-Command existence checks here: a missing function is caught by the try/catch
    # below, and four Get-Command calls cost more startup time than the guards are worth.
    if ($uxCoreLoaded) {
        try {
            $uxState = Get-Variable -Name 'Ux' -Scope Global -ErrorAction SilentlyContinue
            if ($null -ne $uxState -and $uxState.Value -is [hashtable]) {
                $uxState.Value['LoadStart'] = $uxScriptStart
            }
        } catch { }

        try { $null = Initialize-UxConfig } catch {
            Write-Host ('{0} config load failed: {1}' -f $uxErrorPrefix, $_.Exception.Message)
        }
        try { $null = Initialize-UxCaps } catch {
            Write-Host ('{0} capability probe failed: {1}' -f $uxErrorPrefix, $_.Exception.Message)
        }
        try { Remove-UxShadowedCommands } catch {
            Write-Host ('{0} alias snapshot failed: {1}' -f $uxErrorPrefix, $_.Exception.Message)
        }
    }

    # ---- 4b. snapshot user-defined FUNCTIONS that shadow a wrapper name ----
    # Removal happens after the wrapper files load (step 9b), but by then our own functions
    # would be indistinguishable from the user's. Record them here with a cheap provider
    # lookup (Test-Path Function:, no command discovery) so `ux restore-aliases` can bring
    # the user's version back. Merges into the snapshot core already took for aliases.
    if ($uxCoreLoaded) {
        $uxUserFunctionNames = @()
        try {
            $uxSnapState = Get-Variable -Name 'Ux' -Scope Global -ErrorAction SilentlyContinue
            if ($null -ne $uxSnapState -and $uxSnapState.Value -is [hashtable]) {
                $uxSnap = $uxSnapState.Value
                if ($uxSnap.ContainsKey('WrapperNames')) { $uxUserFunctionNames = @($uxSnap['WrapperNames']) }
                if (-not $uxSnap.ContainsKey('AliasBackup')) { $uxSnap['AliasBackup'] = @() }

                foreach ($uxFnName in $uxUserFunctionNames) {
                    try {
                        if (-not (Test-Path -LiteralPath ('Function:' + $uxFnName))) { continue }
                        $uxFnItem = Get-Item -LiteralPath ('Function:' + $uxFnName) -ErrorAction SilentlyContinue
                        if ($null -eq $uxFnItem) { continue }

                        # On a reload our own wrappers are still defined in the session. Do not
                        # snapshot them as if the user had defined them, or `ux restore-aliases`
                        # would replay a previous generation of the profile over itself.
                        # A function defined by a dot-sourced file records that file, so anything
                        # under our install root is ours.
                        $uxFnFile = ''
                        try { if ($uxFnItem.ScriptBlock.File) { $uxFnFile = [string]$uxFnItem.ScriptBlock.File } } catch { }
                        if ($uxFnFile -ne '' -and $uxRoot -ne '' -and $uxFnFile.StartsWith($uxRoot, 'OrdinalIgnoreCase')) { continue }

                        $uxAlready = $false
                        foreach ($uxExisting in @($uxSnap['AliasBackup'])) {
                            if ($null -eq $uxExisting) { continue }
                            if ([string]$uxExisting['Name'] -eq $uxFnName -and [string]$uxExisting['CommandType'] -eq 'Function') {
                                $uxAlready = $true
                            }
                        }
                        if (-not $uxAlready) {
                            $uxSnap['AliasBackup'] = @($uxSnap['AliasBackup']) + @(@{
                                    Name        = $uxFnName
                                    CommandType = 'Function'
                                    Definition  = [string]$uxFnItem.Definition
                                    ScriptBlock = $uxFnItem.ScriptBlock
                                })
                        }
                    } catch { }
                }
            }
        } catch { }
    }

    # ---- 5-9. remaining libs, in order, each guarded ----
    $uxLibNames = @('05-args.ps1', '10-git.ps1', '20-prompt.ps1', '30-unix.ps1', '40-commands.ps1')
    foreach ($uxLibName in $uxLibNames) {
        try {
            if ($uxLibDir -eq '') {
                Write-Host ('{0} failed to load {1}: install directory not found' -f $uxErrorPrefix, $uxLibName)
                continue
            }
            $uxLibPath = Join-Path $uxLibDir $uxLibName
            if (-not (Test-Path -LiteralPath $uxLibPath)) {
                Write-Host ('{0} failed to load {1}: file not found in {2}' -f $uxErrorPrefix, $uxLibName, $uxLibDir)
                continue
            }
            . $uxLibPath
        } catch {
            Write-Host ('{0} failed to load {1}: {2}' -f $uxErrorPrefix, $uxLibName, $_.Exception.Message)
            continue
        }
    }

    # ---- 9b. remove the shadowing entries at THIS scope ----
    # Why here and not earlier: removing an AllScope alias (cd, md, del, dir, echo, where, ...)
    # from inside a function only hides the local copy, so the removal must run as top-level
    # code of the dot-sourced profile. It also must run only for wrappers that actually
    # LOADED - if 30-unix.ps1 is missing, deleting the cd alias would leave the session with
    # no cd at all, which is worse than leaving the original alias in place.
    # ShadowExtra aliases (curl/wget/type) are removed unconditionally: they point at
    # Invoke-WebRequest and are not wrappers this profile replaces.
    if ($uxCoreLoaded) {
        $uxRemoveNames = @()
        $uxExtraNames = @()
        try {
            $uxRemState = Get-Variable -Name 'Ux' -Scope Global -ErrorAction SilentlyContinue
            if ($null -ne $uxRemState -and $uxRemState.Value -is [hashtable]) {
                if ($uxRemState.Value.ContainsKey('WrapperNames')) { $uxRemoveNames = @($uxRemState.Value['WrapperNames']) }
                if ($uxRemState.Value.ContainsKey('ShadowExtra')) { $uxExtraNames = @($uxRemState.Value['ShadowExtra']) }
            }
        } catch { }

        foreach ($uxRemName in $uxRemoveNames) {
            try {
                # Only drop the original when our replacement is actually in place.
                if (-not (Test-Path -LiteralPath ('Function:' + $uxRemName))) { continue }
                Remove-Item -LiteralPath ('Alias:' + $uxRemName) -Force -ErrorAction SilentlyContinue
            } catch { }
        }
        foreach ($uxExtraName in $uxExtraNames) {
            try { Remove-Item -LiteralPath ('Alias:' + $uxExtraName) -Force -ErrorAction SilentlyContinue } catch { }
        }
    }

    # ---- 10. timing, loaded flag, banner ----
    $uxElapsedMs = 0
    try {
        $uxSpan = (Get-Date) - $uxScriptStart
        $uxElapsedMs = [int]$uxSpan.TotalMilliseconds
    } catch {
        $uxElapsedMs = 0
    }

    $uxVersion = '0.1.0'
    $uxState = Get-Variable -Name 'Ux' -Scope Global -ErrorAction SilentlyContinue
    if ($null -ne $uxState -and $uxState.Value -is [hashtable]) {
        try {
            $uxState.Value['LoadMs'] = $uxElapsedMs
            if ($uxState.Value.ContainsKey('Version')) { $uxVersion = [string]$uxState.Value['Version'] }
        } catch { }
    }

    $uxShowBanner = $false
    try {
        if ($env:UX_QUIET -ne '1') {
            $uxBannerEnabled = Get-UxConfig -Path 'ui.banner' -Default $true
            if ($uxBannerEnabled -eq $true) {
                if (Test-UxInteractive) { $uxShowBanner = $true }
            }
        }
    } catch {
        $uxShowBanner = $false
    }

    if ($uxShowBanner) {
        Write-Host ('unix-powershell {0} loaded in {1}ms - type ''ux help''' -f $uxVersion, $uxElapsedMs)
    }

    $uxLoadedFlag = $true
} catch {
    # Absolute last resort: one ASCII line, shell stays alive.
    Write-Host ('{0} load failed: {1}' -f $uxErrorPrefix, $_.Exception.Message)
    $uxLoadedFlag = $false
}

if ($uxLoadedFlag) { $global:UxLoaded = $true }

# This script is dot-sourced into the user's session, so clean up every helper variable.
Remove-Variable -Name 'uxScriptStart', 'uxErrorPrefix', 'uxLoadedFlag', 'uxExistingLoad', 'uxRoot', 'uxLibDir',
    'uxCoreName', 'uxCoreLoaded', 'uxCorePath', 'uxState', 'uxInitConfig', 'uxInitCaps', 'uxRemoveAliases',
    'uxLibNames', 'uxLibName', 'uxLibPath', 'uxElapsedMs', 'uxSpan', 'uxVersion', 'uxShowBanner',
    'uxGetConfig', 'uxInteractive', 'uxBannerEnabled', 'uxHomeBase', 'uxUserFunctionNames', 'uxSnapState',
    'uxSnap', 'uxFnName', 'uxFnItem', 'uxAlready', 'uxExisting', 'uxRemoveNames', 'uxExtraNames',
    'uxRemState', 'uxRemName', 'uxExtraName', 'uxFnFile' -ErrorAction SilentlyContinue
