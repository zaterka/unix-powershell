#Requires -Version 5.1
#
# unix-powershell - lib/00-core.ps1
# Core state ($global:Ux), config load/save, capability probe, shadowed-alias snapshot.
# Target: Windows PowerShell 5.1 (7+ compatible). Pure ASCII. Strict-mode-proof.
# No .NET static calls, no reflection, no Invoke-Expression, no Add-Type, no network.
#
# LOAD ORDER (driven by profile/profile.ps1; kept explicit on purpose):
#   1. dot-source lib/00-core.ps1        - creates $global:Ux with default config
#   2. Initialize-UxConfig               - $global:Ux.Config from <install>\config.json
#   3. Initialize-UxCaps                 - fills $global:Ux.Caps (Vt/Color/Git/...)
#   4. Remove-UxShadowedCommands         - snapshot Alias/Function entries, then remove them
#   5. dot-source 05-args, 10-git, 20-prompt, 30-unix, 40-commands
#   6. profile.ps1 records $global:Ux.LoadMs and prints the banner
# Step 4 runs BEFORE the wrapper files define their functions: aliases resolve before
# functions, so the shadowing aliases/functions must be gone for the wrappers to work.
#
# STARTUP BUDGET NOTES (measured in the CI container, which is emulated amd64):
#   - The first Get-Command call of a cold session costs 120-170 ms (command discovery and
#     module analysis). Test-UxCommandOnPath replaces it for the git probe with the same
#     "is it an application on PATH" semantics at ~3-35 ms. Remove-UxShadowedCommands uses
#     Get-Alias (small fixed dictionary) instead of Get-Command -All per name (~90 ms).
#   - Get-UxConfig never touches the disk: the config file is read and parsed at most once
#     per session (Initialize-UxConfig + the ConfigLoaded flag), so prompt-time reads are
#     pure in-memory hash lookups.
#   - Dotted paths are split with String.Split([char]'.') rather than -split (regex) so the
#     regex engine is not initialised during startup.
#
# Public surface (dot-sourced, so plain functions):
#   Get-UxEsc, Get-UxHome, Get-UxInstallDir, Get-UxConfigPath, Get-UxState,
#   Test-UxCommandOnPath, ConvertTo-UxHashtable, Get-UxConfig, Set-UxConfig, Save-UxConfig,
#   Get-UxDefaultConfig, Get-UxConfigDefaultValue, Read-UxConfigFile, Merge-UxConfig,
#   Initialize-UxConfig, Get-UxCaps, Initialize-UxCaps, Test-UxInteractive, Write-UxDebug,
#   Remove-UxShadowedCommands, Restore-UxShadowedCommands
#

function Get-UxEsc {
    return [string][char]27
}

function Get-UxState {
    # Returns $global:Ux when it is a hashtable, otherwise $null. Never throws.
    try {
        $state = Get-Variable -Name 'Ux' -Scope Global -ErrorAction SilentlyContinue
        if ($null -ne $state -and $state.Value -is [hashtable]) { return $state.Value }
    } catch { }
    return $null
}

function Get-UxHome {
    try {
        if ($HOME) { return [string]$HOME }
        if ($env:USERPROFILE) { return [string]$env:USERPROFILE }
    } catch { }
    return ''
}

function Get-UxInstallDir {
    # Precedence: $env:UX_INSTALL_DIR -> <home>\.unix-powershell
    #
    # Deliberately NOT read from config.json: the config file lives INSIDE the install dir,
    # so using it to locate the install dir is circular, and it made `ux uninstall` (which
    # deletes this path recursively) follow a value the user never chose. Anything that
    # deletes or dot-sources this path must also validate it - see ux uninstall.
    try {
        if ($env:UX_INSTALL_DIR) { return [string]$env:UX_INSTALL_DIR }

        $homeDir = Get-UxHome
        if ($homeDir -ne '') { return (Join-Path $homeDir '.unix-powershell') }
    } catch { }
    return ''
}

function Get-UxConfigPath {
    $dir = ''
    try { $dir = Get-UxInstallDir } catch { $dir = '' }
    if ($dir -eq '') { return 'config.json' }
    return (Join-Path $dir 'config.json')
}

function Test-UxCommandOnPath {
    # Is <Name> an executable reachable on PATH? Same semantics as
    # Get-Command -Name <Name> -CommandType Application, but 4-50x cheaper in a cold
    # session (see the STARTUP BUDGET NOTES in the header). Never throws.
    param([Parameter(Position = 0)][string]$Name = '')

    try {
        if ($Name -eq '') { return $false }
        $pathValue = [string]$env:PATH
        if ($pathValue -eq '') { return $false }

        $parts = @()
        $suffixes = @('')
        if ($env:OS -eq 'Windows_NT') {
            $parts = $pathValue -split ';'
            $suffixes = @('.exe', '.cmd', '.bat', '.com')
        } else {
            $parts = $pathValue -split ':'
        }

        foreach ($dir in $parts) {
            if ($null -eq $dir -or $dir -eq '') { continue }
            $cleanDir = $dir -replace '"', ''
            if ($cleanDir -eq '') { continue }
            foreach ($suffix in $suffixes) {
                if (Test-Path -LiteralPath (Join-Path $cleanDir ($Name + $suffix))) { return $true }
            }
        }
    } catch { }
    return $false
}

function ConvertTo-UxHashtable {
    # Recursive normaliser: PSCustomObject / IDictionary / arrays -> nested hashtables.
    # Windows PowerShell 5.1 has no ConvertFrom-Json -AsHashtable, so this is mandatory.
    param([Parameter(Position = 0)] $InputObject)

    if ($null -eq $InputObject) { return $null }

    if ($InputObject -is [hashtable]) {
        $result = @{}
        foreach ($key in @($InputObject.Keys)) {
            $result[[string]$key] = ConvertTo-UxHashtable -InputObject $InputObject[$key]
        }
        return $result
    }

    if ($InputObject -is [array]) {
        $items = @()
        foreach ($item in $InputObject) { $items += ,(ConvertTo-UxHashtable -InputObject $item) }
        return ,$items
    }

    # Dictionary-like without being a Hashtable (e.g. [ordered]@{}) exposes Keys + Values.
    try {
        if ($null -ne $InputObject.PSObject.Properties['Keys'] -and $null -ne $InputObject.PSObject.Properties['Values']) {
            $result = @{}
            foreach ($key in @($InputObject.Keys)) {
                $result[[string]$key] = ConvertTo-UxHashtable -InputObject $InputObject[$key]
            }
            return $result
        }
    } catch { }

    # Property bag: only PSCustomObject (ConvertFrom-Json output, [pscustomobject]@{}) is
    # normalised. Matching on the type name is deliberate: a [string] also exposes properties
    # (Length) and must pass through untouched.
    try {
        if (@($InputObject.PSObject.TypeNames) -contains 'System.Management.Automation.PSCustomObject') {
            $result = @{}
            foreach ($prop in @($InputObject.PSObject.Properties)) {
                if ($null -ne $prop) { $result[[string]$prop.Name] = ConvertTo-UxHashtable -InputObject $prop.Value }
            }
            return $result
        }
    } catch { }

    # Scalars (string, int, bool, ...) pass through untouched.
    return $InputObject
}

function Get-UxDefaultConfig {
    # Schema version 1 (PLAN.md 5.1). All keys optional in config.json.
    return @{
        version = 1
        theme   = 'ascii'
        prompt  = @{
            pathStyle = 'full'
            git       = $true
            user      = $true
            host      = $false
            time      = $false
            symbol    = '$'
            exitCode  = $true
        }
        git     = @{
            useGitBinary    = $true
            untrackedFiles  = $false
            cacheMs         = 2000
            slowThresholdMs = 250
            maxDepth        = 40
        }
        ui      = @{
            color  = 'auto'
            banner = $true
        }
    }
}

function Merge-UxConfig {
    # Deep merge: values from -User win, nested hashtables merge, defaults fill the gaps.
    param($Defaults, $User)

    $result = @{}
    if ($Defaults -is [hashtable]) {
        foreach ($key in @($Defaults.Keys)) { $result[$key] = $Defaults[$key] }
    }
    if (-not ($User -is [hashtable])) { return $result }

    foreach ($key in @($User.Keys)) {
        $userValue = $User[$key]
        if ($result.ContainsKey($key) -and $result[$key] -is [hashtable] -and $userValue -is [hashtable]) {
            $result[$key] = Merge-UxConfig -Defaults $result[$key] -User $userValue
        } else {
            $result[$key] = $userValue
        }
    }
    return $result
}

function Split-UxConfigPath {
    # 'git.cacheMs' -> 'git','cacheMs'. String.Split keeps the regex engine out of startup.
    param([Parameter(Position = 0)][string]$Path = '')

    $segments = @()
    if ($Path -eq '') { return ,$segments }
    foreach ($segment in $Path.Split([char]'.')) {
        if ($null -ne $segment -and $segment -ne '') { $segments += [string]$segment }
    }
    return ,$segments
}

function Get-UxConfig {
    # Dotted-path read over $global:Ux.Config. Never throws; absent key -> -Default.
    # Pure in-memory: the config file is parsed once per session by Initialize-UxConfig.
    param(
        [Parameter(Position = 0)][string]$Path = '',
        $Default = $null
    )

    try {
        $ux = Get-UxState
        if ($null -eq $ux) { return $Default }
        if (-not $ux.ContainsKey('Config')) { return $Default }

        $node = $ux['Config']
        if ($null -eq $node) { return $Default }
        if ($Path -eq '') { return $node }

        foreach ($segment in (Split-UxConfigPath -Path $Path)) {
            if ($null -eq $node) { return $Default }

            if ($node -is [hashtable]) {
                if (-not $node.ContainsKey($segment)) { return $Default }
                $node = $node[$segment]
                continue
            }

            # Dictionary-like without being a Hashtable (e.g. [ordered]@{}).
            try {
                if ($null -ne $node.PSObject.Properties['Keys'] -and $null -ne $node.PSObject.Properties['Values']) {
                    $matched = $false
                    $nextNode = $null
                    foreach ($key in @($node.Keys)) {
                        if ([string]$key -eq $segment) { $nextNode = $node[$key]; $matched = $true; break }
                    }
                    if (-not $matched) { return $Default }
                    $node = $nextNode
                    continue
                }
            } catch {
                return $Default
            }

            $prop = $null
            try { $prop = $node.PSObject.Properties[$segment] } catch { $prop = $null }
            if ($null -eq $prop) { return $Default }
            $node = $prop.Value
        }

        if ($null -eq $node) { return $Default }
        return $node
    } catch {
        return $Default
    }
}

function Get-UxConfigDefaultValue {
    # Default value for a dotted path in the shipping schema (used for typed coercion).
    param([Parameter(Position = 0)][string]$Path = '')

    $node = Get-UxDefaultConfig
    foreach ($segment in (Split-UxConfigPath -Path $Path)) {
        if (-not ($node -is [hashtable])) { return $null }
        if (-not $node.ContainsKey($segment)) { return $null }
        $node = $node[$segment]
    }
    return $node
}

function Set-UxConfig {
    # Dotted-path write over $global:Ux.Config, then persist to disk.
    param(
        [Parameter(Position = 0)][string]$Path = '',
        [Parameter(Position = 1)] $Value = $null
    )

    try {
        $segments = Split-UxConfigPath -Path $Path
        if ($segments.Count -eq 0) { return $false }

        $ux = Get-UxState
        if ($null -eq $ux) { return $false }
        if (-not $ux.ContainsKey('Config') -or -not ($ux['Config'] -is [hashtable])) {
            $ux['Config'] = Get-UxDefaultConfig
        }
        $node = $ux['Config']

        # Light typed coercion so "set ui.banner false" does not store the string 'false'.
        $typedValue = $Value
        if ($typedValue -is [string]) {
            $schemaDefault = Get-UxConfigDefaultValue -Path $Path
            if ($schemaDefault -is [bool]) {
                if ($typedValue -eq 'true') { $typedValue = $true }
                elseif ($typedValue -eq 'false') { $typedValue = $false }
            } elseif ($schemaDefault -is [int] -or $schemaDefault -is [long] -or $schemaDefault -is [double]) {
                if ($typedValue -match '^-?[0-9]+$') { $typedValue = [int]$typedValue }
            }
        }

        for ($i = 0; $i -lt ($segments.Count - 1); $i++) {
            if (-not ($node -is [hashtable])) { return $false }
            $segment = $segments[$i]
            if (-not $node.ContainsKey($segment) -or -not ($node[$segment] -is [hashtable])) {
                $node[$segment] = @{}
            }
            $node = $node[$segment]
        }
        if (-not ($node -is [hashtable])) { return $false }
        $node[$segments[$segments.Count - 1]] = $typedValue

        [void](Save-UxConfig)
        return $true
    } catch {
        return $false
    }
}

function Save-UxConfig {
    # ConvertTo-Json -Depth 10 is mandatory: the 5.1 default depth of 2 turns nested
    # hashtables into "System.Collections.Hashtable" strings.
    param([string]$Path = '')

    $tempPath = ''
    try {
        if ($Path -eq '') { $Path = Get-UxConfigPath }
        if ($Path -eq '') { return $false }

        $config = $null
        $ux = Get-UxState
        if ($null -ne $ux -and $ux.ContainsKey('Config') -and $ux['Config'] -is [hashtable]) {
            $config = $ux['Config']
        }
        if ($null -eq $config) { $config = Get-UxDefaultConfig }

        $json = $config | ConvertTo-Json -Depth 10

        $parentDir = Split-Path -Parent $Path
        if ($parentDir -ne '' -and -not (Test-Path -LiteralPath $parentDir)) {
            $null = New-Item -ItemType Directory -Path $parentDir -Force -ErrorAction Stop
        }

        $tempPath = $Path + '.tmp.' + [string]$PID
        Set-Content -LiteralPath $tempPath -Value $json -Encoding UTF8 -ErrorAction Stop
        Move-Item -LiteralPath $tempPath -Destination $Path -Force -ErrorAction Stop
        return $true
    } catch {
        try {
            if ($tempPath -ne '' -and (Test-Path -LiteralPath $tempPath)) {
                Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
            }
        } catch { }
        return $false
    }
}

function Read-UxConfigFile {
    # Strict-JSON config loader. Returns a merged hashtable, never throws.
    # Missing/empty -> defaults (silent). Not usable (bad JSON, not an object) -> renamed
    # config.json.bad + one warning. Unsupported schema version -> refused with one warning,
    # defaults used, file left untouched so the user can fix it.
    param([string]$Path = '')

    $defaults = Get-UxDefaultConfig
    try {
        if ($Path -eq '') { $Path = Get-UxConfigPath }
        if ($Path -eq '' -or -not (Test-Path -LiteralPath $Path)) { return $defaults }

        $raw = ''
        try {
            $raw = [string](Get-Content -LiteralPath $Path -Raw -ErrorAction Stop)
        } catch {
            Write-Warning ('[unix-powershell] could not read {0}: {1} - using defaults' -f $Path, $_.Exception.Message)
            return $defaults
        }
        if ($null -eq $raw) { $raw = '' }
        if ($raw.Length -gt 0 -and [int][char]$raw[0] -eq 65279) { $raw = $raw.Substring(1) }
        if ($raw.Trim() -eq '') { return $defaults }

        $parsed = $null
        try { $parsed = $raw | ConvertFrom-Json -ErrorAction Stop } catch { $parsed = $null }

        $user = $null
        if ($null -ne $parsed -and -not ($parsed -is [array])) {
            $user = ConvertTo-UxHashtable -InputObject $parsed
        }

        if (-not ($user -is [hashtable])) {
            $badPath = $Path + '.bad'
            try { Move-Item -LiteralPath $Path -Destination $badPath -Force -ErrorAction Stop } catch { }
            Write-Warning ('[unix-powershell] config.json is not usable (invalid JSON or not an object) - moved to {0}; using defaults' -f $badPath)
            return $defaults
        }

        if ($user.ContainsKey('version')) {
            $declared = $user['version']
            $supported = $false
            if ($declared -is [int] -or $declared -is [long] -or $declared -is [double]) {
                if ([int]$declared -eq 1) { $supported = $true }
            } elseif ($declared -is [string]) {
                if ($declared -eq '1') { $supported = $true }
            }
            if (-not $supported) {
                Write-Warning ('[unix-powershell] config.json declares unsupported version {0} (this build supports 1) - using defaults; {1} left untouched' -f [string]$declared, $Path)
                return $defaults
            }
        }

        $merged = Merge-UxConfig -Defaults $defaults -User $user
        $merged['version'] = 1
        return $merged
    } catch {
        return $defaults
    }
}

function Initialize-UxConfig {
    # Called from profile/profile.ps1 (step 2). Sets $global:Ux.Config and InstallDir.
    # The file is read and parsed at most once per session (ConfigLoaded flag), so repeated
    # Get-UxConfig calls - the prompt makes several - never touch the disk.
    # The existence check happens here so a fresh install (no config.json) never pays for
    # compiling the strict-JSON reader at all.
    $ux = Get-UxState
    if ($null -ne $ux) {
        if ($ux.ContainsKey('ConfigLoaded') -and $ux['ConfigLoaded'] -eq $true) {
            if ($ux.ContainsKey('Config') -and $ux['Config'] -is [hashtable]) { return $ux['Config'] }
        }
    }

    $config = Get-UxDefaultConfig
    $configPath = ''
    try { $configPath = Get-UxConfigPath } catch { $configPath = '' }
    if ($configPath -ne '' -and (Test-Path -LiteralPath $configPath)) {
        $loaded = $null
        try { $loaded = Read-UxConfigFile -Path $configPath } catch { $loaded = $null }
        if ($loaded -is [hashtable]) { $config = $loaded }
    }

    try {
        if ($null -ne $ux) {
            $ux['Config'] = $config
            $ux['ConfigLoaded'] = $true
            $installDir = Get-UxInstallDir
            if ($installDir -ne '') { $ux['InstallDir'] = $installDir }
        }
    } catch { }

    return $config
}

function Get-UxCaps {
    # Pure capability probe: returns a hashtable, touches no global state.
    $caps = @{
        Vt           = $false
        Color        = $false
        Git          = $false
        GitVersion   = $null
        LanguageMode = ''
        PSEdition    = ''
        PSVersion    = ''
    }

    # --- Vt: host property, then environment markers, then PS 7+ ---
    $vt = $false
    try {
        $ui = $Host.UI
        if ($null -ne $ui) {
            $supportsVt = $ui.PSObject.Properties['SupportsVirtualTerminal']
            if ($null -ne $supportsVt -and $supportsVt.Value -eq $true) { $vt = $true }
        }
    } catch { }
    if (-not $vt) {
        try {
            # Unset env vars are $null (falsy); a set-but-empty value is falsy too.
            if ($env:WT_SESSION -or $env:TERM_PROGRAM -or ($env:ConEmuANSI -eq 'ON')) { $vt = $true }
        } catch { }
    }
    if (-not $vt) {
        try {
            $psv = $PSVersionTable['PSVersion']
            if ($null -ne $psv -and [int]$psv.Major -ge 7) { $vt = $true }
        } catch { }
    }
    $caps['Vt'] = $vt

    # --- Color: independent of Vt, respects NO_COLOR / UX_NO_COLOR / ui.color = never ---
    # Colour in this project has two ladders: ANSI when the console understands VT, and
    # per-segment Write-Host -ForegroundColor when it does not. Both are "colour", so the
    # capability must NOT depend on Vt - otherwise a legacy 5.1 conhost (Vt = false) loses
    # every colour and the documented Console mode becomes unreachable dead code.
    $color = $true
    try {
        if ($env:NO_COLOR -or ($env:UX_NO_COLOR -eq '1')) { $color = $false }
    } catch { }
    try {
        if ([string](Get-UxConfig -Path 'ui.color' -Default 'auto') -eq 'never') { $color = $false }
    } catch { }
    $caps['Color'] = $color

    # --- Git binary: an application on PATH (not an alias/function) ---
    try {
        if (Test-UxCommandOnPath -Name 'git') { $caps['Git'] = $true }
    } catch { }
    # GitVersion stays $null until lib/10-git.ps1 probes `git --version` once per session.

    # --- Host/runtime metadata ---
    try { $caps['LanguageMode'] = [string]$ExecutionContext.SessionState.LanguageMode } catch { }

    try {
        $psv = $PSVersionTable['PSVersion']
        $caps['PSVersion'] = [string]$psv
        if ($PSVersionTable.ContainsKey('PSEdition')) {
            $caps['PSEdition'] = [string]$PSVersionTable['PSEdition']
        } elseif ([int]$psv.Major -lt 6) {
            # Windows PowerShell 5.1 has no PSEdition key: Desktop is the inference.
            $caps['PSEdition'] = 'Desktop'
        } else {
            $caps['PSEdition'] = 'Unknown'
        }
    } catch { }

    return $caps
}

function Initialize-UxCaps {
    # Called from profile/profile.ps1 (step 3). Fills $global:Ux.Caps.
    $caps = Get-UxCaps
    try {
        $ux = Get-UxState
        if ($null -ne $ux) {
            $previous = $null
            if ($ux.ContainsKey('Caps') -and $ux['Caps'] -is [hashtable]) { $previous = $ux['Caps'] }
            if ($null -ne $previous -and $previous.ContainsKey('GitVersion') -and $null -ne $previous['GitVersion']) {
                $caps['GitVersion'] = $previous['GitVersion']
            }
            $ux['Caps'] = $caps
        }
    } catch { }
    return $caps
}

function Test-UxInteractive {
    # True only when a human is attached to this console host. Never throws, never blocks.
    # Conservative by design: a wrong "true" prints noise into CI logs and captured output,
    # a wrong "false" only hides one banner line.
    #   - $Host.Name must be ConsoleHost (ISE / ServerRemoteHost / DefaultHost fail here).
    #   - RawUI must be reachable: a Windows host without a console (service, scheduled task,
    #     fully redirected session) throws on RawUI access.
    #   - POSIX: a console host with no TERM at all has no terminal attached (docker run
    #     -Command, CI runners, cron). Windows consoles have no TERM, so TERM is only
    #     consulted off Windows. Known limit: on Windows a console-attached -Command/-File
    #     run still looks interactive; UX_QUIET=1 always suppresses the banner.
    try {
        if ($null -eq $Host) { return $false }
        if ($Host.Name -ne 'ConsoleHost') { return $false }
        $ui = $Host.UI
        if ($null -eq $ui) { return $false }
        $raw = $ui.RawUI
        if ($null -eq $raw) { return $false }
        $null = $raw.WindowSize
        if ($env:TERM -eq 'dumb') { return $false }
        if ($env:OS -ne 'Windows_NT') {
            if ($null -eq $env:TERM -or $env:TERM -eq '') { return $false }
        }
        return $true
    } catch {
        return $false
    }
}

function Write-UxDebug {
    param([Parameter(Position = 0)][string]$Message = '')

    try {
        if ($env:UX_DEBUG -eq '1') { Write-Host ('[ux] {0}' -f $Message) -ForegroundColor DarkGray }
    } catch { }
}

function Remove-UxShadowedCommands {
    # Snapshots every Alias/Function that currently shadows a wrapper name, then removes it.
    # Fast path: an alias is a direct dictionary lookup (Get-Alias); Get-Command -All per name
    # costs ~90 ms for 25 names because it enumerates command resolution for each. Get-Command
    # is only used for the names that are FUNCTIONS in a stock Windows 5.1 session
    # (mkdir/md/rd/rmdir) and only on Windows. Applications (curl.exe, /usr/bin/ls) are left
    # alone. Never throws; repeated calls merge into the existing snapshot.
    try {
        $ux = Get-UxState
        if ($null -eq $ux) { return }

        $names = @()
        foreach ($key in @('WrapperNames', 'ShadowExtra')) {
            if (-not $ux.ContainsKey($key)) { continue }
            foreach ($name in @($ux[$key])) { if ($name) { $names += [string]$name } }
        }
        if ($names.Count -eq 0) { return }

        $uxOnWindows = $false
        if ($env:OS -eq 'Windows_NT') { $uxOnWindows = $true }
        $functionCandidates = @{ mkdir = $true; md = $true; rd = $true; rmdir = $true }

        $found = @()
        foreach ($name in $names) {
            try {
                $aliasInfo = Get-Alias -Name $name -ErrorAction SilentlyContinue
                if ($null -ne $aliasInfo) { $found += $aliasInfo }
            } catch { }
            if ($uxOnWindows -and $functionCandidates.ContainsKey($name)) {
                try {
                    $functionInfo = Get-Command -Name $name -CommandType Function -ErrorAction SilentlyContinue
                    if ($null -ne $functionInfo) { $found += $functionInfo }
                } catch { }
            }
        }

        $entries = @()
        if ($ux.ContainsKey('AliasBackup')) {
            foreach ($entry in @($ux['AliasBackup'])) { if ($null -ne $entry) { $entries += $entry } }
        }

        foreach ($command in $found) {
            if ($null -eq $command) { continue }
            try {
                $commandType = [string]$command.CommandType
                if ($commandType -ne 'Alias' -and $commandType -ne 'Function') { continue }

                $commandName = ''
                if ($null -ne $command.PSObject.Properties['Name']) { $commandName = [string]$command.PSObject.Properties['Name'].Value }
                if ($commandName -eq '') { continue }

                $definition = ''
                if ($null -ne $command.PSObject.Properties['Definition']) { $definition = [string]$command.PSObject.Properties['Definition'].Value }

                $scriptBlock = $null
                if ($commandType -eq 'Function') { $scriptBlock = $command.ScriptBlock }

                $alreadySnapshot = $false
                foreach ($existing in $entries) {
                    if ($null -eq $existing) { continue }
                    if ([string]$existing['Name'] -eq $commandName -and [string]$existing['CommandType'] -eq $commandType) {
                        $alreadySnapshot = $true
                        break
                    }
                }
                if (-not $alreadySnapshot) {
                    $entries += @{
                        CommandType = $commandType
                        Name        = $commandName
                        Definition  = $definition
                        ScriptBlock = $scriptBlock
                    }
                }

                if ($commandType -eq 'Alias') {
                    Remove-Item -LiteralPath ('Alias:\' + $commandName) -Force -ErrorAction SilentlyContinue
                } else {
                    Remove-Item -LiteralPath ('Function:\' + $commandName) -Force -ErrorAction SilentlyContinue
                }
            } catch { }
        }

        $ux['AliasBackup'] = $entries
    } catch { }
}

function Restore-UxShadowedCommands {
    # Best-effort replay of the load-time snapshot. One broken entry never stops the rest
    # and the function never throws.
    # Scope matters: this normally runs from a wrapper or the ux command, so a plain
    # Set-Item would recreate the alias/function in the *callee's* scope and it would vanish
    # as soon as the call returns. Aliases use Set-Alias -Scope Global; functions use the
    # 'Function:\global:<name>' provider path, with the plain path as a fallback for hosts
    # that reject the scope qualifier.
    try {
        $ux = Get-UxState
        if ($null -eq $ux) { return }
        if (-not $ux.ContainsKey('AliasBackup')) { return }

        foreach ($entry in @($ux['AliasBackup'])) {
            if ($null -eq $entry) { continue }
            try {
                $commandName = [string]$entry['Name']
                if ($commandName -eq '') { continue }
                $commandType = [string]$entry['CommandType']

                if ($commandType -eq 'Alias') {
                    $definition = [string]$entry['Definition']
                    if ($definition -ne '') {
                        Set-Alias -Name $commandName -Value $definition -Scope Global -Force -ErrorAction SilentlyContinue
                    }
                } elseif ($commandType -eq 'Function') {
                    $scriptBlock = $entry['ScriptBlock']
                    if ($null -ne $scriptBlock) {
                        $restored = $false
                        try {
                            Set-Item -Path ('Function:\global:' + $commandName) -Value $scriptBlock -Force -ErrorAction Stop
                            $restored = $true
                        } catch {
                            $restored = $false
                        }
                        if (-not $restored) {
                            Set-Item -Path ('Function:\' + $commandName) -Value $scriptBlock -Force -ErrorAction SilentlyContinue
                        }
                    }
                }
            } catch { }
        }
    } catch { }
}

# ---------------------------------------------------------------------------
# Global state (created on load; Initialize-UxConfig / Initialize-UxCaps refine it).
# ---------------------------------------------------------------------------
$global:Ux = @{
    Version             = '0.1.0'
    Esc                 = [string][char]27
    Home                = (Get-UxHome)
    InstallDir          = (Get-UxInstallDir)
    Config              = (Get-UxDefaultConfig)
    ConfigLoaded        = $false
    Caps                = @{
        Vt           = $false
        Color        = $false
        Git          = $false
        GitVersion   = $null
        LanguageMode = ''
        PSEdition    = ''
        PSVersion    = ''
    }
    LoadStart           = $null
    LoadMs              = 0
    GitCache            = @{}
    AliasBackup         = @()
    LastExit            = 0
    LastOk              = $true
    WrapperNames        = @('ls', 'll', 'la', 'cd', 'touch', 'mkdir', 'rm', 'mv', 'grep', 'find', 'head', 'tail', 'wc', 'which', 'env', 'export', 'unset', 'kill', 'unzip')
    ShadowExtra         = @('curl', 'wget', 'type')
    ProfileBlockVersion = '0.1.0'
}
