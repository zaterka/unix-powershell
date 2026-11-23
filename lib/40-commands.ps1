#Requires -Version 5.1
#
# unix-powershell - lib/40-commands.ps1
# The `ux` management command.
#
# `ux` is a PLAIN function, never [CmdletBinding()]: dash tokens such as `ux doctor -Json`
# must reach $args verbatim and be tokenized by ConvertFrom-UxArgv, exactly like the Unix
# wrappers in lib/30-unix.ps1. An advanced function would reject -Json at binding time.
#
# Verbs (PLAN.md 5.5):
#   help, version, doctor [-Json], verify, theme [list|show|set <name>],
#   config [path|edit|get <key>|set <key> <value>], reload, update [-Check],
#   disable, enable, restore-aliases, uninstall [-Force]
#
# Rules honoured here:
#   * Pure ASCII, Windows PowerShell 5.1 syntax, no .NET statics, no Add-Type,
#     no Invoke-Expression, no reflection -> CLM (ConstrainedLanguage) safe.
#   * Nothing in this file throws to the user: every probe is individually wrapped and
#     reports "unknown" instead. `ux doctor` must always produce a report.
#   * Every cross-module call is guarded by Get-Command, so this file still works when a
#     sibling module is missing (ux.ps1 recovery mode, partial installs, unit tests).
#   * Constants live in exactly one place: $script:UxThemes, $script:UxRuntimeFiles,
#     $script:UxVerbs. Nothing else re-lists theme names or runtime files.
#   * The only function defined here is `ux`. Its helpers are local scriptblocks, so no
#     bare helper name can shadow a user command.
#   * `ux trust` is deliberately NOT implemented (certificate work is out of scope; the
#     README documents the manual procedure instead).
#
# Exit codes: 0 success, 1 failed check or error, 2 unknown verb.
#

# ---------------------------------------------------------------------------
# Constants (single source of truth).
# ---------------------------------------------------------------------------

# Built-in theme names. lib/20-prompt.ps1 implements them; this list is the only place
# the names are spelled out, and `ux theme` derives its validation/output from here.
$script:UxThemes = @('ascii', 'classic', 'blocks', 'two-line')

# One-line shape notes for `ux theme list`. Keyed by theme name; a missing key is fine.
$script:UxThemeNotes = @{
    'ascii'    = 'PS ~/repo (main*) $  - default, minimum noise'
    'classic'  = 'user@host:~/repo (main +1-0)$  - familiar bash shape'
    'blocks'   = 'reverse-video segments joined by >  - high visibility'
    'two-line' = 'dim path line, then a $ line  - long paths, short prompt'
}

# Runtime files as installed under the install directory (relative, forward slashes).
# tools/New-Manifest.ps1 ships exactly this set; `ux verify` uses it for presence checks
# and manifest.json carries the hashes for the same paths.
$script:UxRuntimeFiles = @(
    'profile/profile.ps1'
    'lib/00-core.ps1'
    'lib/05-args.ps1'
    'lib/10-git.ps1'
    'lib/20-prompt.ps1'
    'lib/30-unix.ps1'
    'lib/40-commands.ps1'
    'ux.ps1'
)

# Verb table for `ux help` and for tab completion. One entry per verb, one help line each.
$script:UxVerbs = @(
    @{ Verb = 'help';            Summary = 'show this usage table' }
    @{ Verb = 'version';         Summary = 'profile version, PowerShell version, edition, host, install dir, config path' }
    @{ Verb = 'doctor';          Summary = 'environment report; -Json emits a single JSON object' }
    @{ Verb = 'verify';          Summary = 'wrappers, config and manifest hashes; exit 1 when a check fails' }
    @{ Verb = 'theme';           Summary = 'theme list | theme show | theme set <name>' }
    @{ Verb = 'config';          Summary = 'config path | config get <key> | config set <key> <value> | config edit' }
    @{ Verb = 'reload';          Summary = 're-load profile\profile.ps1 in this session' }
    @{ Verb = 'update';          Summary = 'print the update steps; -Check compares with the published manifest' }
    @{ Verb = 'enable';          Summary = 'remove the .disabled marker so new sessions load again' }
    @{ Verb = 'disable';         Summary = 'create the .disabled marker so new sessions skip loading' }
    @{ Verb = 'restore-aliases'; Summary = 'replay the aliases and functions shadowed at load time' }
    @{ Verb = 'uninstall';       Summary = 'remove the profile block and the install directory; -Force skips the prompt' }
)

# Repository location used by `ux update -Check` only. Must stay identical to
# $script:UxRepoTail in install.ps1 (the installer cannot be dot-sourced at runtime).
$script:UxRepoTail = 'zaterka/unix-powershell'

# ---------------------------------------------------------------------------
# The command.
# ---------------------------------------------------------------------------
function ux {
    param()

    # =======================================================================
    # Local helpers: scriptblocks, never functions.
    # =======================================================================

    # True when a command (function or cmdlet) is available in this session.
    $hasCommand = {
        param([string]$Name)
        try {
            $found = Get-Command -Name $Name -ErrorAction SilentlyContinue
            if ($null -ne $found) { return $true }
        } catch { }
        return $false
    }

    # Read one of this file's own script-scope constants. Falls back to the global scope
    # because `ux reload` re-dot-sources the profile into a nested scope: the promoted
    # functions must still find the originals.
    $getScriptVar = {
        param([string]$Name)
        foreach ($scopeName in @('Script', 'Global')) {
            try {
                $variable = Get-Variable -Name $Name -Scope $scopeName -ErrorAction SilentlyContinue
                if ($null -ne $variable -and $null -ne $variable.Value) { return $variable.Value }
            } catch { }
        }
        return $null
    }

    # $global:Ux as a hashtable, or $null. Never throws (strict-mode safe).
    $stateGet = {
        try {
            $variable = Get-Variable -Name 'Ux' -Scope Global -ErrorAction SilentlyContinue
            if ($null -ne $variable -and $variable.Value -is [hashtable]) { return $variable.Value }
        } catch { }
        return $null
    }

    # One key out of $global:Ux, with a default.
    $stateValue = {
        param([string]$Key, $Default = $null)
        try {
            $state = & $stateGet
            if ($null -ne $state -and $state.ContainsKey($Key)) { return $state[$Key] }
        } catch { }
        return $Default
    }

    # Read a property from either a hashtable or a ConvertFrom-Json object.
    $propValue = {
        param($Object, [string]$Name)
        if ($null -eq $Object) { return $null }
        try {
            if ($Object -is [hashtable]) {
                if ($Object.ContainsKey($Name)) { return $Object[$Name] }
                return $null
            }
            $property = $Object.PSObject.Properties[$Name]
            if ($null -ne $property) { return $property.Value }
        } catch { }
        return $null
    }

    # Dotted-path config read (Get-UxConfig when core is loaded, direct walk otherwise).
    $configGet = {
        param([string]$Path, $Default = $null)
        try {
            if (& $hasCommand 'Get-UxConfig') { return (Get-UxConfig -Path $Path -Default $Default) }
        } catch { }
        try {
            $state = & $stateGet
            if ($null -ne $state -and $state.ContainsKey('Config')) {
                $node = $state['Config']
                if ($Path -eq '') { return $node }
                foreach ($segment in @($Path -split '\.')) {
                    if ($null -eq $segment -or $segment -eq '') { continue }
                    if ($node -is [hashtable] -and $node.ContainsKey($segment)) {
                        $node = $node[$segment]
                    } else {
                        return $Default
                    }
                }
                return $node
            }
        } catch { }
        return $Default
    }

    # Dotted-path config write (core only: persistence lives in Set-UxConfig).
    $configSet = {
        param([string]$Path, $Value)
        if (-not (& $hasCommand 'Set-UxConfig')) { return $false }
        try { return [bool](Set-UxConfig -Path $Path -Value $Value) } catch { return $false }
    }

    # Default value from the shipping schema, or $null when the key is unknown.
    $configDefault = {
        param([string]$Path)
        try {
            if (& $hasCommand 'Get-UxConfigDefaultValue') { return (Get-UxConfigDefaultValue -Path $Path) }
        } catch { }
        return $null
    }

    $getInstallDir = {
        try {
            if (& $hasCommand 'Get-UxInstallDir') { return [string](Get-UxInstallDir) }
        } catch { }
        try {
            if ($null -ne $env:UX_INSTALL_DIR -and $env:UX_INSTALL_DIR -ne '') { return [string]$env:UX_INSTALL_DIR }
        } catch { }
        try {
            $homeDir = ''
            if ($null -ne $HOME -and $HOME -ne '') { $homeDir = [string]$HOME }
            elseif ($null -ne $env:USERPROFILE -and $env:USERPROFILE -ne '') { $homeDir = [string]$env:USERPROFILE }
            if ($homeDir -ne '') { return (Join-Path $homeDir '.unix-powershell') }
        } catch { }
        return ''
    }

    $getConfigPath = {
        try {
            if (& $hasCommand 'Get-UxConfigPath') { return [string](Get-UxConfigPath) }
        } catch { }
        $dir = ''
        try { $dir = [string](& $getInstallDir) } catch { $dir = '' }
        if ($dir -eq '') { return 'config.json' }
        return (Join-Path $dir 'config.json')
    }

    # Join a relative POSIX-ish path onto a base directory, separator-agnostic.
    $joinRelative = {
        param([string]$Base, [string]$Relative)
        if ($Base -eq '') { return $Relative }
        $result = $Base
        try {
            foreach ($part in @($Relative -split '[\\/]')) {
                if ($null -eq $part -or $part -eq '') { continue }
                $result = Join-Path $result $part
            }
        } catch {
            return $Relative
        }
        return $result
    }

    # Human-readable form of a config value.
    $formatValue = {
        param($Value)
        if ($null -eq $Value) { return '<unset>' }
        try {
            if ($Value -is [bool]) {
                if ($Value) { return 'true' }
                return 'false'
            }
            if ($Value -is [hashtable]) { return [string]($Value | ConvertTo-Json -Depth 10 -Compress) }
            return [string]$Value
        } catch {
            return '<unprintable>'
        }
    }

    # SHA256 of a file, lowercase, or '' when it cannot be hashed.
    $fileSha = {
        param([string]$Path)
        try {
            $hash = Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop
            if ($null -ne $hash) { return ([string]$hash.Hash).ToLower() }
        } catch { }
        return ''
    }

    $isInteractive = {
        try {
            if (& $hasCommand 'Test-UxInteractive') { return [bool](Test-UxInteractive) }
        } catch { }
        return $false
    }

    # label : value, ASCII aligned.
    $writeRow = {
        param([string]$Label, [string]$Value, [int]$Width)
        $padded = $Label
        while ($padded.Length -lt $Width) { $padded = $padded + ' ' }
        Write-Host ('  {0} : {1}' -f $padded, $Value)
    }

    # PASS/FAIL line for `ux verify`.
    $writeCheck = {
        param([bool]$Ok, [string]$Text, [string]$Detail)
        $label = 'FAIL'
        if ($Ok) { $label = 'PASS' }
        $line = ('  {0}  {1}' -f $label, $Text)
        if (-not $Ok -and $null -ne $Detail -and $Detail -ne '') { $line = $line + ' - ' + $Detail }
        try {
            if ($Ok) { Write-Host $line -ForegroundColor Green }
            else { Write-Host $line -ForegroundColor Red }
        } catch {
            Write-Host $line
        }
    }

    # Join a list for one output line, capped so a broken install cannot flood the console.
    $shortList = {
        param($Items, [int]$Cap = 8)
        $list = @($Items)
        if ($list.Count -eq 0) { return '' }
        if ($list.Count -le $Cap) { return ($list -join ', ') }
        $head = @()
        for ($i = 0; $i -lt $Cap; $i++) { $head += [string]$list[$i] }
        return (($head -join ', ') + ' ... (' + $list.Count + ' total)')
    }

    # Manual block-removal instructions: printed instead of silently doing nothing when
    # the delimiters are missing or damaged (PLAN.md 5.5, 5.6).
    $writeManualRemoval = {
        param([string]$Path, [string]$Reason, [string]$Install)
        Write-Host ('  manual removal needed in ' + $Path + ': ' + $Reason) -ForegroundColor Yellow
        Write-Host '    1. open that file and delete every line from the one starting with'
        Write-Host '       "# BEGIN unix-powershell" through the one starting with "# END unix-powershell"'
        Write-Host '    2. or delete the lines that dot-source the install entry point:'
        Write-Host ('         ' + (Join-Path (Join-Path $Install 'profile') 'profile.ps1'))
        Write-Host '    3. save it - everything outside the block is yours and is never touched'
    }

    # State of the injected profile block in one file.
    $profileBlockState = {
        param([string]$Path)
        if ($Path -eq '') { return 'unknown (path unavailable)' }
        if (-not (Test-Path -LiteralPath $Path)) { return 'file missing' }
        $lines = @()
        try { $lines = @(Get-Content -LiteralPath $Path -ErrorAction Stop) } catch { return ('unreadable: ' + $_.Exception.Message) }
        $beginAt = -1
        $endAt = -1
        $beginText = ''
        $index = 0
        foreach ($line in $lines) {
            $text = [string]$line
            if ($beginAt -lt 0 -and $text -match '^\s*#\s*BEGIN\s+unix-powershell') {
                $beginAt = $index
                $beginText = $text.Trim()
            }
            if ($endAt -lt 0 -and $text -match '^\s*#\s*END\s+unix-powershell') { $endAt = $index }
            $index = $index + 1
        }
        if ($beginAt -ge 0 -and $endAt -gt $beginAt) { return ('present (' + $beginText + ')') }
        if ($beginAt -ge 0) { return 'damaged (BEGIN without END)' }
        if ($endAt -ge 0) { return 'damaged (END without BEGIN)' }
        return 'not present'
    }

    # The other PowerShell host's AllHosts profile (5.1 <-> 7). Derived from $PROFILE so
    # Documents is never hardcoded (OneDrive-redirected homes). '' when it does not exist.
    $otherProfilePath = {
        param([string]$AllHostsPath)
        if ($AllHostsPath -eq '') { return '' }
        try {
            $hostDir = Split-Path -Parent $AllHostsPath
            if ($hostDir -eq '') { return '' }
            $parentDir = Split-Path -Parent $hostDir
            $leafDir = Split-Path -Leaf $hostDir
            $fileName = Split-Path -Leaf $AllHostsPath
            if ($fileName -eq '' -or $parentDir -eq '') { return '' }
            $otherDirName = 'WindowsPowerShell'
            if ($leafDir -eq 'WindowsPowerShell') { $otherDirName = 'PowerShell' }
            $candidate = Join-Path (Join-Path $parentDir $otherDirName) $fileName
            if (Test-Path -LiteralPath $candidate) { return $candidate }
        } catch { }
        return ''
    }

    # Remove the delimited block from one profile file. Returns @{ Status; Detail } where
    # Status is one of: no-file, clean, removed, manual.
    $stripProfileBlock = {
        param([string]$Path)
        if ($Path -eq '' -or -not (Test-Path -LiteralPath $Path)) {
            return @{ Status = 'no-file'; Detail = '' }
        }
        $lines = @()
        try { $lines = @(Get-Content -LiteralPath $Path -ErrorAction Stop) } catch {
            return @{ Status = 'manual'; Detail = ('unreadable: ' + $_.Exception.Message) }
        }
        $beginAt = -1
        $endAt = -1
        $mentions = $false
        $index = 0
        foreach ($line in $lines) {
            $text = [string]$line
            if ($text -match 'unix-powershell') { $mentions = $true }
            if ($beginAt -lt 0 -and $text -match '^\s*#\s*BEGIN\s+unix-powershell') { $beginAt = $index }
            if ($endAt -lt 0 -and $text -match '^\s*#\s*END\s+unix-powershell') { $endAt = $index }
            $index = $index + 1
        }
        if ($beginAt -lt 0 -and $endAt -lt 0) {
            if ($mentions) { return @{ Status = 'manual'; Detail = 'no BEGIN/END delimiters found' } }
            return @{ Status = 'clean'; Detail = '' }
        }
        if ($beginAt -lt 0) { return @{ Status = 'manual'; Detail = 'END delimiter without BEGIN' } }
        if ($endAt -lt 0) { return @{ Status = 'manual'; Detail = 'BEGIN delimiter without END' } }
        if ($endAt -lt $beginAt) { return @{ Status = 'manual'; Detail = 'END appears before BEGIN' } }

        $kept = @()
        for ($i = 0; $i -lt $beginAt; $i++) { $kept += [string]$lines[$i] }
        for ($i = $endAt + 1; $i -lt $lines.Count; $i++) { $kept += [string]$lines[$i] }

        # Drop the blank tail the removed block leaves behind.
        $keepCount = $kept.Count
        while ($keepCount -gt 0 -and ([string]$kept[$keepCount - 1]).Trim() -eq '') { $keepCount = $keepCount - 1 }
        $final = @()
        for ($i = 0; $i -lt $keepCount; $i++) { $final += [string]$kept[$i] }

        try {
            if ($final.Count -eq 0) { Set-Content -LiteralPath $Path -Value '' -Encoding UTF8 -ErrorAction Stop }
            else { Set-Content -LiteralPath $Path -Value $final -Encoding UTF8 -ErrorAction Stop }
        } catch {
            return @{ Status = 'manual'; Detail = ('could not write the file: ' + $_.Exception.Message) }
        }
        return @{ Status = 'removed'; Detail = ('removed ' + ($endAt - $beginAt + 1) + ' lines') }
    }

    # Is this path safe to delete recursively? Returns @{ Ok; Reason }. Used by
    # `ux uninstall`, which deletes its target with -Recurse: the path comes from the
    # environment, so a typo, a stray config value or a half-finished install must never
    # turn that verb into an arbitrary recursive delete.
    $checkInstallDir = {
        param([string]$Path)
        if ($Path -eq '') { return @{ Ok = $false; Reason = 'the install directory could not be resolved' } }

        # Resolve to an absolute path first: '.' or any relative path would otherwise slip
        # past every comparison below (it does contain profile/profile.ps1).
        $target = $Path
        try {
            $resolved = Resolve-Path -LiteralPath $Path -ErrorAction Stop
            if ($null -ne $resolved) {
                $providerPath = ''
                try { $providerPath = [string]$resolved.ProviderPath } catch { $providerPath = '' }
                if ($providerPath -ne '') { $target = $providerPath } else { $target = [string]$resolved }
            }
        } catch { $target = $Path }

        $normal = $target.ToLower().Replace([char]92, [char]47)
        while ($normal.Length -gt 1 -and $normal.EndsWith([string][char]47)) {
            $normal = $normal.Substring(0, $normal.Length - 1)
        }
        if ($normal -eq '' -or $normal -eq '/') {
            return @{ Ok = $false; Reason = ('"' + $target + '" is a filesystem root') }
        }
        if ($normal -match '^[a-z]:$') {
            return @{ Ok = $false; Reason = ('"' + $target + '" is a drive root') }
        }

        $normalHome = ''
        try {
            if ($null -ne $HOME -and $HOME -ne '') { $normalHome = [string]$HOME }
            elseif ($null -ne $env:USERPROFILE -and $env:USERPROFILE -ne '') { $normalHome = [string]$env:USERPROFILE }
        } catch { $normalHome = '' }
        if ($normalHome -ne '') {
            $normalHome = $normalHome.ToLower().Replace([char]92, [char]47)
            while ($normalHome.Length -gt 1 -and $normalHome.EndsWith([string][char]47)) {
                $normalHome = $normalHome.Substring(0, $normalHome.Length - 1)
            }
        }
        if ($normalHome -ne '' -and $normalHome -eq $normal) {
            return @{ Ok = $false; Reason = 'it resolves to your home directory' }
        }

        $normalPwd = ''
        try { $normalPwd = [string](Get-Location).Path } catch { $normalPwd = '' }
        if ($normalPwd -ne '') {
            $normalPwd = $normalPwd.ToLower().Replace([char]92, [char]47)
            while ($normalPwd.Length -gt 1 -and $normalPwd.EndsWith([string][char]47)) {
                $normalPwd = $normalPwd.Substring(0, $normalPwd.Length - 1)
            }
        }
        if ($normalPwd -ne '' -and ($normalPwd -eq $normal -or $normalPwd.StartsWith($normal + '/'))) {
            return @{ Ok = $false; Reason = 'the current directory is inside it (cd somewhere else first)' }
        }

        # Last gate: the path has to look like this project's install directory. A damaged
        # install can still be removed with the folder named .unix-powershell (the default).
        $entryPath = ''
        try { $entryPath = [string](& $joinRelative $target 'profile/profile.ps1') } catch { $entryPath = '' }
        $hasEntryPoint = $false
        if ($entryPath -ne '') {
            try { $hasEntryPoint = (Test-Path -LiteralPath $entryPath) } catch { $hasEntryPoint = $false }
        }
        $leaf = ''
        try { $leaf = [string](Split-Path -Leaf $target) } catch { $leaf = '' }
        if (-not $hasEntryPoint -and $leaf -ne '.unix-powershell') {
            return @{
                Ok     = $false
                Reason = ('it does not look like a unix-powershell install (no profile/profile.ps1 and the folder is not named .unix-powershell); delete it by hand if it is really yours')
            }
        }
        return @{ Ok = $true; Reason = '' }
    }

    # Sample model for the theme preview. Shape follows PLAN.md 5.3 and is filled from the
    # live config so the preview matches what the user will actually get. If
    # Format-UxPrompt disagrees the call is caught and the preview is simply skipped.
    $renderPreview = {
        param([string]$ThemeName)
        if (-not (& $hasCommand 'Format-UxPrompt')) { return '' }
        $showGit = $true
        $showUser = $true
        $showHost = $false
        $showTime = $false
        $showExit = $true
        $pathStyle = 'full'
        try {
            if (& $configGet 'prompt.git' $true) { $showGit = $true } else { $showGit = $false }
            if (& $configGet 'prompt.user' $true) { $showUser = $true } else { $showUser = $false }
            if (& $configGet 'prompt.host' $false) { $showHost = $true } else { $showHost = $false }
            if (& $configGet 'prompt.time' $false) { $showTime = $true } else { $showTime = $false }
            if (& $configGet 'prompt.exitCode' $true) { $showExit = $true } else { $showExit = $false }
            $configuredStyle = [string](& $configGet 'prompt.pathStyle' 'full')
            if ($configuredStyle -ne '') { $pathStyle = $configuredStyle }
        } catch { }
        $sample = @{
            User      = 'user'
            Host      = 'host'
            Path      = '~/repo'
            PathStyle = $pathStyle
            Time      = '12:00'
            LastExit  = 0
            LastOk    = $true
            Symbol    = '$'
            ShowGit   = $showGit
            ShowUser  = $showUser
            ShowHost  = $showHost
            ShowTime  = $showTime
            ShowExit  = $showExit
            Width     = 120
            Git       = @{
                Root     = '~/repo'
                Branch   = 'main'
                Detached = $false
                ShortSha = 'abc1234'
                Dirty    = $true
                Ahead    = 1
                Behind   = 0
                State    = ''
                IsRepo   = $true
            }
        }
        # The renderer returns an array of segments (@{ Text; Color; Vt }); older/simpler
        # implementations may return a plain string, so both shapes are accepted.
        $renderArgs = @(
            @{ Model = $sample; Theme = $ThemeName; Mode = 'Plain' },
            @{ Model = $sample; Theme = $ThemeName },
            @{ Model = $sample }
        )
        foreach ($argumentSet in $renderArgs) {
            $results = @()
            try { $results = @(Format-UxPrompt @argumentSet) } catch { $results = @() }
            if ($results.Count -eq 0) { continue }
            $text = ''
            foreach ($item in $results) {
                if ($null -eq $item) { continue }
                if ($item -is [string]) {
                    $text = $text + [string]$item
                    continue
                }
                $piece = [string](& $propValue $item 'Text')
                if ($piece -ne '') { $text = $text + $piece }
            }
            if ($text -ne '') { return $text }
        }
        return ''
    }

    # Fetch a URL as text. Only `ux update -Check` ever calls this (explicit user action).
    # curl first: Invoke-WebRequest is CLM-hostile and slow to start.
    $fetchText = {
        param([string]$Url)
        if ($Url -eq '') { return '' }
        $proxy = ''
        try {
            if ($null -ne $env:UX_PROXY -and $env:UX_PROXY -ne '') { $proxy = [string]$env:UX_PROXY }
        } catch { $proxy = '' }
        try {
            $curl = Get-Command -Name 'curl.exe' -CommandType Application -ErrorAction SilentlyContinue
            if ($null -eq $curl) { $curl = Get-Command -Name 'curl' -CommandType Application -ErrorAction SilentlyContinue }
            if ($null -ne $curl) {
                $curlPath = [string](& $propValue $curl 'Source')
                if ($curlPath -eq '') { $curlPath = [string](& $propValue $curl 'Definition') }
                if ($curlPath -ne '') {
                    $curlArgs = @('-fsSL', '--max-time', '20')
                    if ($proxy -ne '') { $curlArgs += @('--proxy', $proxy) }
                    $curlArgs += $Url
                    $fetched = @(& $curlPath @curlArgs 2>$null) -join ([string][char]10)
                    if ($LASTEXITCODE -eq 0 -and $fetched -ne '') { return $fetched }
                }
            }
        } catch { }
        try {
            $request = @{ Uri = $Url; UseBasicParsing = $true; ErrorAction = 'Stop'; TimeoutSec = 20 }
            if ($proxy -ne '') { $request['Proxy'] = $proxy }
            $response = Invoke-WebRequest @request
            if ($null -ne $response) { return [string]$response.Content }
        } catch { }
        return ''
    }

    # =======================================================================
    # Shared state.
    # =======================================================================
    $exitCode = 0

    $themeNames = @()
    try { $themeNames = @(& $getScriptVar 'UxThemes') } catch { $themeNames = @() }
    $themeNotes = $null
    try { $themeNotes = & $getScriptVar 'UxThemeNotes' } catch { $themeNotes = $null }
    $runtimeFiles = @()
    try { $runtimeFiles = @(& $getScriptVar 'UxRuntimeFiles') } catch { $runtimeFiles = @() }
    $verbTable = @()
    try { $verbTable = @(& $getScriptVar 'UxVerbs') } catch { $verbTable = @() }

    $installDir = ''
    try { $installDir = [string](& $getInstallDir) } catch { $installDir = '' }
    $configPath = ''
    try { $configPath = [string](& $getConfigPath) } catch { $configPath = '' }

    $profileVersion = 'unknown'
    try {
        $versionValue = & $stateValue 'Version' ''
        if ($null -ne $versionValue -and [string]$versionValue -ne '') { $profileVersion = [string]$versionValue }
    } catch { }

    # =======================================================================
    # argv: shared tokenizer, dash tokens arrive verbatim in $args.
    # =======================================================================
    $argv = $null
    try {
        if (& $hasCommand 'ConvertFrom-UxArgv') {
            $argv = ConvertFrom-UxArgv -Tokens @($args) -AliasMap @{
                'Json'    = 'json'
                'Check'   = 'check'
                'Force'   = 'force'
                'Help'    = 'help'
                'Version' = 'version'
                'H'       = 'help'
                '?'       = 'help'
            }
        }
    } catch {
        $argv = $null
    }

    if ($null -eq $argv) {
        # lib/05-args.ps1 missing: minimal fallback so `ux` still works.
        $fallbackFlags = @{}
        $fallbackPositional = @()
        foreach ($token in @($args)) {
            if ($null -eq $token) { continue }
            $text = [string]$token
            if ($text.Length -gt 1 -and $text.StartsWith([string][char]45)) {
                $fallbackFlags[$text.TrimStart([char]45).ToLower()] = $true
            } else {
                $fallbackPositional += ,$text
            }
        }
        $argv = @{ Flags = $fallbackFlags; Values = @{}; Positional = $fallbackPositional; Problems = @() }
    }

    $hasFlag = {
        param([string]$Name)
        try {
            $flagSet = $argv['Flags']
            if ($null -eq $flagSet) { return $false }
            foreach ($key in @($flagSet.Keys)) {
                if ($null -eq $key) { continue }
                if ([string]$key -eq $Name) { return [bool]$flagSet[$key] }
            }
        } catch { }
        return $false
    }

    $positional = @()
    try {
        foreach ($token in @($argv['Positional'])) {
            if ($null -eq $token) { continue }
            $positional += [string]$token
        }
    } catch {
        $positional = @()
    }

    $argAt = {
        param([int]$Index)
        if ($Index -ge 0 -and $Index -lt $positional.Count) { return [string]$positional[$Index] }
        return ''
    }

    $verb = ''
    if ($positional.Count -gt 0) { $verb = $positional[0].ToLower() }
    if ($verb -eq '') {
        if (& $hasFlag 'version') { $verb = 'version' }
        else { $verb = 'help' }
    }

    # The help table, used by `ux help` and by an unknown verb.
    $writeHelp = {
        $verbWidth = 4
        foreach ($entry in $verbTable) {
            if ($null -eq $entry) { continue }
            $name = ''
            try { if ($entry.ContainsKey('Verb')) { $name = [string]$entry['Verb'] } } catch { $name = '' }
            if ($name.Length -gt $verbWidth) { $verbWidth = $name.Length }
        }
        $verbHead = 'verb'
        while ($verbHead.Length -lt $verbWidth) { $verbHead = $verbHead + ' ' }
        $ruleLeft = ''
        while ($ruleLeft.Length -lt $verbWidth) { $ruleLeft = $ruleLeft + '-' }
        $ruleRight = ''
        while ($ruleRight.Length -lt 58) { $ruleRight = $ruleRight + '-' }

        Write-Host ''
        Write-Host ('unix-powershell {0} - ux management command' -f $profileVersion)
        Write-Host ''
        Write-Host 'usage: ux <verb> [options]'
        Write-Host ''
        Write-Host ('  {0}  {1}' -f $verbHead, 'behaviour')
        Write-Host ('  {0}  {1}' -f $ruleLeft, $ruleRight)
        foreach ($entry in $verbTable) {
            $name = ''
            $summary = ''
            try {
                if ($entry.ContainsKey('Verb')) { $name = [string]$entry['Verb'] }
                if ($entry.ContainsKey('Summary')) { $summary = [string]$entry['Summary'] }
            } catch { }
            while ($name.Length -lt $verbWidth) { $name = $name + ' ' }
            Write-Host ('  {0}  {1}' -f $name, $summary)
        }
        Write-Host ''
        Write-Host 'examples:'
        Write-Host '  ux doctor                  ux doctor -Json'
        Write-Host '  ux theme set classic       ux config set git.cacheMs 500'
        Write-Host '  ux verify                  ux uninstall -Force'
        Write-Host ''
        Write-Host 'exit codes: 0 success, 1 failed check or error, 2 unknown verb'
        Write-Host ''
    }

    # =======================================================================
    # Dispatch
    # =======================================================================

    if ($verb -eq 'help') {
        & $writeHelp
        $exitCode = 0
    }

    elseif ($verb -eq 'version') {
        $psVersionText = 'unknown'
        try {
            if ($null -ne $PSVersionTable -and $PSVersionTable.ContainsKey('PSVersion')) {
                $psVersionText = [string]$PSVersionTable['PSVersion']
            }
        } catch { }
        $editionText = 'unknown'
        try {
            if ($null -ne $PSVersionTable -and $PSVersionTable.ContainsKey('PSEdition')) {
                $editionText = [string]$PSVersionTable['PSEdition']
            }
        } catch { }
        $hostName = 'unknown'
        try {
            if ($null -ne $Host -and $null -ne $Host.Name) { $hostName = [string]$Host.Name }
        } catch { }

        Write-Host ''
        & $writeRow 'profile' $profileVersion 12
        & $writeRow 'powershell' $psVersionText 12
        & $writeRow 'edition' $editionText 12
        & $writeRow 'host' $hostName 12
        & $writeRow 'installDir' ($(if ($installDir -ne '') { $installDir } else { '<unknown>' })) 12
        & $writeRow 'configPath' ($(if ($configPath -ne '') { $configPath } else { '<unknown>' })) 12
        Write-Host ''
        $exitCode = 0
    }

    elseif ($verb -eq 'doctor') {
        # ------------------------------------------------------------------
        # Every probe below is independently guarded: one failing check must
        # never abort the report. Values become "unknown" instead.
        # ------------------------------------------------------------------
        $jsonMode = (& $hasFlag 'json')
        $interactive = (& $isInteractive)
        $escape = [string][char]27
        $rows = [ordered]@{}

        # --- PowerShell / runtime -----------------------------------------
        $psVersionText = 'unknown'
        $psMajor = 0
        $psMinor = 0
        try {
            if ($null -ne $PSVersionTable -and $PSVersionTable.ContainsKey('PSVersion')) {
                $psVersion = $PSVersionTable['PSVersion']
                if ($null -ne $psVersion) {
                    $psVersionText = [string]$psVersion
                    $psMajor = [int]$psVersion.Major
                    $psMinor = [int]$psVersion.Minor
                }
            }
        } catch { }
        $rows['PowerShellVersion'] = $psVersionText

        $editionText = 'unknown'
        try {
            if ($null -ne $PSVersionTable -and $PSVersionTable.ContainsKey('PSEdition')) {
                $editionText = [string]$PSVersionTable['PSEdition']
            } elseif ($psMajor -ge 6) {
                $editionText = 'Core (inferred: PSVersionTable has no PSEdition entry)'
            } elseif ($psMajor -gt 0) {
                $editionText = 'Desktop (inferred: PSVersionTable has no PSEdition entry)'
            }
        } catch { }
        $rows['PSEdition'] = $editionText

        if ($psMajor -le 0) {
            $rows['PSVersionMajorCheck'] = 'unknown (PSVersion unavailable)'
        } elseif ($psMajor -gt 5 -or ($psMajor -eq 5 -and $psMinor -ge 1)) {
            $rows['PSVersionMajorCheck'] = 'PASS (' + $psVersionText + ' is 5.1 or newer)'
        } else {
            $rows['PSVersionMajorCheck'] = 'FAIL (needs 5.1 or newer, running ' + $psVersionText + ')'
        }

        $hostName = 'unknown'
        try {
            if ($null -ne $Host -and $null -ne $Host.Name) { $hostName = [string]$Host.Name }
        } catch { }
        $rows['Host'] = $hostName

        # --- Language mode ------------------------------------------------
        $languageMode = 'unknown'
        try { $languageMode = [string]$ExecutionContext.SessionState.LanguageMode } catch { $languageMode = 'unknown' }
        $rows['LanguageMode'] = $languageMode
        if ($languageMode -eq 'ConstrainedLanguage') {
            $rows['LanguageModeNote'] = 'degraded: Add-Type/reflection/.NET statics are blocked, so parser validation is skipped (SHA256 is the integrity gate), Invoke-WebRequest and Pester are unusable (curl.exe is preferred), and tab-completion cannot be registered'
        } elseif ($languageMode -eq 'FullLanguage') {
            $rows['LanguageModeNote'] = 'none (FullLanguage: every feature available)'
        } else {
            $rows['LanguageModeNote'] = 'not evaluated (mode ' + $languageMode + ')'
        }

        # --- Execution policy (Windows only, always guarded) --------------
        # Get-ExecutionPolicy does not exist off Windows; the call is skipped there
        # rather than risk a binding failure on an exotic host.
        $policyScopes = [ordered]@{}
        $policyError = ''
        $isWindowsHost = ($env:OS -eq 'Windows_NT')
        if ($isWindowsHost) {
            try {
                $policyList = @(Get-ExecutionPolicy -List -ErrorAction Stop)
                foreach ($entry in $policyList) {
                    if ($null -eq $entry) { continue }
                    $scopeName = ''
                    $scopeValue = ''
                    try { $scopeName = [string](& $propValue $entry 'Scope') } catch { $scopeName = '' }
                    try { $scopeValue = [string](& $propValue $entry 'ExecutionPolicy') } catch { $scopeValue = '' }
                    if ($scopeName -eq '') { continue }
                    $policyScopes[$scopeName] = $scopeValue
                }
                if ($policyScopes.Count -eq 0) { $policyError = 'Get-ExecutionPolicy -List returned no scopes' }
            } catch {
                $policyError = $_.Exception.Message
            }
            if ($policyError -ne '') {
                $rows['ExecutionPolicy'] = 'unknown (' + $policyError + ')'
            } else {
                foreach ($scopeName in @($policyScopes.Keys)) {
                    $rows['ExecutionPolicy' + [string]$scopeName] = [string]$policyScopes[$scopeName]
                }
            }
        } else {
            $rows['ExecutionPolicy'] = 'n/a (skipped: not Windows)'
        }

        $gpoParts = @()
        foreach ($scopeName in @('MachinePolicy', 'UserPolicy')) {
            if ($policyScopes.Contains([string]$scopeName)) {
                $scopeValue = [string]$policyScopes[[string]$scopeName]
                if ($scopeValue -ne '' -and $scopeValue -ne 'Undefined') {
                    $gpoParts += ([string]$scopeName + '=' + $scopeValue)
                }
            }
        }

        if (-not $isWindowsHost) {
            $rows['ExecutionPolicyGpoLocked'] = 'n/a (not Windows)'
            $rows['PolicyNote'] = 'not Windows: execution policy does not apply'
        } else {
            if ($gpoParts.Count -gt 0) {
                $rows['ExecutionPolicyGpoLocked'] = 'yes (' + ($gpoParts -join ', ') + ') - a GPO sets it, per-user changes are ignored'
            } else {
                $rows['ExecutionPolicyGpoLocked'] = 'no'
            }
            $effective = ''
            if ($policyScopes.Contains('CurrentUser')) { $effective = [string]$policyScopes['CurrentUser'] }
            if ($gpoParts.Count -gt 0) {
                $rows['PolicyNote'] = 'GPO-locked tier: unsigned scripts may be refused; use the -Command one-liner or a -SourceDir install (see the README trust model)'
            } elseif ($effective -eq 'Restricted') {
                $rows['PolicyNote'] = 'Restricted: unsupported without admin - see the README execution-policy tiers'
            } elseif ($effective -eq 'AllSigned') {
                $rows['PolicyNote'] = 'AllSigned without GPO: this profile block is unsigned and will be refused; see the README trust model'
            } elseif ($effective -eq '' -or $effective -eq 'Undefined') {
                $rows['PolicyNote'] = 'no CurrentUser override: the LocalMachine or Process value applies'
            } else {
                $rows['PolicyNote'] = $effective + ': overridable per user; Unblock-File strips the download block'
            }
        }

        # --- VT / colour --------------------------------------------------
        $vtEnabled = $false
        $colorEnabled = $false
        try {
            $caps = & $stateValue 'Caps' $null
            if ($null -ne $caps -and $caps -is [hashtable]) {
                if ($caps.ContainsKey('Vt')) { $vtEnabled = [bool]$caps['Vt'] }
                if ($caps.ContainsKey('Color')) { $colorEnabled = [bool]$caps['Color'] }
            }
        } catch { }
        if (-not $vtEnabled -and -not $colorEnabled) {
            # Caps may never have been initialized (ux.ps1 recovery mode): probe once.
            try {
                if (& $hasCommand 'Get-UxCaps') {
                    $probed = Get-UxCaps
                    if ($null -ne $probed -and $probed -is [hashtable]) {
                        if ($probed.ContainsKey('Vt')) { $vtEnabled = [bool]$probed['Vt'] }
                        if ($probed.ContainsKey('Color')) { $colorEnabled = [bool]$probed['Color'] }
                    }
                }
            } catch { }
        }
        if ($vtEnabled) { $rows['Vt'] = 'yes' } else { $rows['Vt'] = 'no' }
        if ($colorEnabled) { $rows['Color'] = 'yes' } else { $rows['Color'] = 'no' }
        if ($interactive) {
            $rows['VtTest'] = 'rendered (GREEN and YELLOW expected)'
        } else {
            $rows['VtTest'] = 'skipped (host is not interactive)'
        }

        # --- Paths --------------------------------------------------------
        if ($installDir -ne '') { $rows['InstallDir'] = $installDir } else { $rows['InstallDir'] = 'unknown' }
        $installExists = $false
        if ($installDir -ne '') {
            try { $installExists = (Test-Path -LiteralPath $installDir) } catch { $installExists = $false }
        }
        if ($installExists) { $rows['InstallDirExists'] = 'yes' } else { $rows['InstallDirExists'] = 'no' }

        if ($configPath -ne '') { $rows['ConfigPath'] = $configPath } else { $rows['ConfigPath'] = 'unknown' }
        $configExists = $false
        if ($configPath -ne '') {
            try { $configExists = (Test-Path -LiteralPath $configPath) } catch { $configExists = $false }
        }
        if ($configExists) { $rows['ConfigExists'] = 'yes' } else { $rows['ConfigExists'] = 'no' }
        if (-not $configExists) {
            $rows['ConfigParses'] = 'n/a (no config file, defaults in use)'
        } else {
            try {
                $configRaw = [string](Get-Content -LiteralPath $configPath -Raw -ErrorAction Stop)
                if ($null -eq $configRaw) { $configRaw = '' }
                if ($configRaw.Length -gt 0 -and [int][char]$configRaw[0] -eq 65279) { $configRaw = $configRaw.Substring(1) }
                if ($configRaw.Trim() -eq '') {
                    $rows['ConfigParses'] = 'yes (empty file, defaults in use)'
                } else {
                    $null = $configRaw | ConvertFrom-Json -ErrorAction Stop
                    $rows['ConfigParses'] = 'yes'
                }
            } catch {
                $rows['ConfigParses'] = 'no (' + $_.Exception.Message + ')'
            }
        }

        # --- Theme --------------------------------------------------------
        $themeText = ''
        try { $themeText = [string](& $configGet 'theme' '') } catch { $themeText = '' }
        if ($themeText -eq '') { $themeText = 'unknown' }
        try {
            if ($null -ne $env:UX_THEME -and $env:UX_THEME -ne '') {
                $themeText = $themeText + ' (this session overridden by UX_THEME=' + [string]$env:UX_THEME + ')'
            }
        } catch { }
        $rows['Theme'] = $themeText

        # --- git ----------------------------------------------------------
        $gitPresent = 'no'
        $gitPath = ''
        try {
            $gitCommand = Get-Command -Name 'git' -CommandType Application -ErrorAction SilentlyContinue
            if ($null -ne $gitCommand) {
                $gitPresent = 'yes'
                try { $gitPath = [string](& $propValue $gitCommand 'Source') } catch { $gitPath = '' }
                if ($gitPath -eq '') {
                    try { $gitPath = [string](& $propValue $gitCommand 'Definition') } catch { $gitPath = '' }
                }
            }
        } catch { }
        if ($gitPath -ne '') { $gitPresent = 'yes (' + $gitPath + ')' }
        $rows['GitPresent'] = $gitPresent

        $gitVersion = 'not available'
        if ($gitPresent -like 'yes*') {
            $cachedGitVersion = ''
            try {
                $caps = & $stateValue 'Caps' $null
                if ($null -ne $caps -and $caps -is [hashtable]) {
                    if ($caps.ContainsKey('GitVersion') -and $null -ne $caps['GitVersion']) {
                        $cachedGitVersion = [string]$caps['GitVersion']
                    }
                }
            } catch { $cachedGitVersion = '' }

            if ($cachedGitVersion -ne '') {
                $gitVersion = $cachedGitVersion
            } else {
                # `ux doctor` is an explicit user action, so one probe here is fine; the
                # value is not written into Caps (lib/10-git.ps1 owns that cache).
                try {
                    $versionOutput = [string](& git --version 2>$null)
                    if ($versionOutput -match '([0-9]+\.[0-9]+(\.[0-9]+)?)') { $gitVersion = $Matches[1] }
                    elseif ($versionOutput -ne '') { $gitVersion = $versionOutput }
                    else { $gitVersion = 'unknown' }
                } catch {
                    $gitVersion = 'unknown (' + $_.Exception.Message + ')'
                }
            }
        }
        $rows['GitVersion'] = $gitVersion

        $gitStatus = 'not available (lib/10-git.ps1 is not loaded)'
        try {
            if (& $hasCommand 'Get-UxGitStatusCapability') {
                $capability = Get-UxGitStatusCapability
                if ($null -eq $capability) {
                    $gitStatus = 'unknown (Get-UxGitStatusCapability returned nothing)'
                } else {
                    $capMode = [string](& $propValue $capability 'Mode')
                    $capVersion = [string](& $propValue $capability 'Version')
                    $capReason = [string](& $propValue $capability 'Reason')
                    if ($capMode -eq '') { $capMode = 'unknown' }
                    $gitStatus = $capMode
                    if ($capVersion -ne '') { $gitStatus = $gitStatus + ' (git ' + $capVersion + ')' }
                    if ($capReason -ne '') { $gitStatus = $gitStatus + ' - ' + $capReason }
                }
            }
        } catch {
            $gitStatus = 'unknown (' + $_.Exception.Message + ')'
        }
        $rows['GitStatus'] = $gitStatus

        # --- OneDrive placeholder (string match, no .NET statics) ---------
        $offlineText = 'unknown (install dir not found)'
        if ($installExists) {
            try {
                $installItem = Get-Item -LiteralPath $installDir -Force -ErrorAction Stop
                $attributeText = [string](& $propValue $installItem 'Attributes')
                if ($attributeText -match 'Offline') {
                    $offlineText = 'yes (OneDrive/VOD placeholder: files may be cloud-only and slow to read)'
                } else {
                    $offlineText = 'no'
                }
            } catch {
                $offlineText = 'unknown (' + $_.Exception.Message + ')'
            }
        }
        $rows['OfflineAttribute'] = $offlineText

        # --- Profile block ------------------------------------------------
        $allHostsPath = ''
        $currentHostPath = ''
        try { $allHostsPath = [string]$PROFILE.CurrentUserAllHosts } catch { $allHostsPath = '' }
        try { $currentHostPath = [string]$PROFILE.CurrentUserCurrentHost } catch { $currentHostPath = '' }

        $rows['ProfileBlockCurrentUserAllHosts'] = (& $profileBlockState $allHostsPath)
        $rows['ProfileBlockCurrentUserCurrentHost'] = (& $profileBlockState $currentHostPath)

        $otherHostPath = ''
        if ($isWindowsHost) {
            try { $otherHostPath = [string](& $otherProfilePath $allHostsPath) } catch { $otherHostPath = '' }
        }
        if ($otherHostPath -eq '') {
            $rows['ProfileBlockOtherHost'] = 'n/a (not Windows, or the other host has no profile)'
        } else {
            $rows['ProfileBlockOtherHost'] = (& $profileBlockState $otherHostPath)
        }

        # --- Last load time ------------------------------------------------
        $lastLoadText = 'unknown (not measured yet)'
        try {
            $loadMs = & $stateValue 'LoadMs' $null
            if ($null -ne $loadMs -and [string]$loadMs -ne '') {
                $loadValue = 0
                try { $loadValue = [int]$loadMs } catch { $loadValue = 0 }
                if ($loadValue -gt 0) { $lastLoadText = [string]$loadValue + ' ms' }
            }
        } catch { }
        $rows['LastLoadMs'] = $lastLoadText

        # --- Output --------------------------------------------------------
        if ($jsonMode) {
            $jsonText = ''
            try { $jsonText = [string]([pscustomobject]$rows | ConvertTo-Json -Depth 10) } catch { }
            if ($jsonText -eq '') { $jsonText = '{}' }
            Write-Output $jsonText
        } else {
            $labelWidth = 24
            foreach ($key in @($rows.Keys)) {
                $keyText = [string]$key
                if ($keyText.Length -gt $labelWidth) { $labelWidth = $keyText.Length }
            }
            Write-Host ''
            Write-Host ('unix-powershell doctor  (version {0})' -f $profileVersion)
            Write-Host ''
            foreach ($key in @($rows.Keys)) {
                $valueText = [string]$rows[$key]
                if ([string]$key -eq 'VtTest' -and $interactive) {
                    $valueText = $escape + '[32mGREEN' + $escape + '[0m ' + $escape + '[33mYELLOW' + $escape + '[0m'
                    $valueText = $valueText + '  <- coloured means VT works; a literal [32m means it does not'
                }
                & $writeRow ([string]$key) $valueText $labelWidth
            }
            Write-Host ''
        }
        $exitCode = 0
    }

    elseif ($verb -eq 'verify') {
        $failures = 0
        $passes = 0

        Write-Host ''
        Write-Host ('unix-powershell verify  (version {0})' -f $profileVersion)
        Write-Host ''

        # --- 1. config parses ---------------------------------------------
        if ($configPath -eq '') {
            & $writeCheck $false 'config path resolved' 'install directory could not be resolved'
            $failures = $failures + 1
        } elseif (-not (Test-Path -LiteralPath $configPath)) {
            & $writeCheck $true 'config parses' ('no file at ' + $configPath + ', defaults in use')
            $passes = $passes + 1
        } else {
            $parseOk = $false
            $parseDetail = ''
            try {
                $configRaw = [string](Get-Content -LiteralPath $configPath -Raw -ErrorAction Stop)
                if ($null -eq $configRaw) { $configRaw = '' }
                if ($configRaw.Length -gt 0 -and [int][char]$configRaw[0] -eq 65279) { $configRaw = $configRaw.Substring(1) }
                if ($configRaw.Trim() -eq '') {
                    $parseOk = $true
                } else {
                    $parsedConfig = $configRaw | ConvertFrom-Json -ErrorAction Stop
                    $parseOk = $true
                    $declaredVersion = & $propValue $parsedConfig 'version'
                    if ($null -ne $declaredVersion) {
                        $declaredText = [string]$declaredVersion
                        if ($declaredText -ne '1') {
                            $parseOk = $false
                            $parseDetail = ('unsupported schema version ' + $declaredText + ' (this build supports 1)')
                        }
                    }
                }
            } catch {
                $parseOk = $false
                $parseDetail = $_.Exception.Message
            }
            if ($parseOk) {
                & $writeCheck $true ('config parses (' + $configPath + ')') ''
                $passes = $passes + 1
            } else {
                & $writeCheck $false ('config parses (' + $configPath + ')') $parseDetail
                $failures = $failures + 1
            }
        }

        # --- 2. core state loaded ------------------------------------------
        $stateOk = $false
        try {
            $state = & $stateGet
            if ($null -ne $state -and $state.ContainsKey('Config') -and $state['Config'] -is [hashtable]) { $stateOk = $true }
        } catch { $stateOk = $false }
        if ($stateOk) {
            & $writeCheck $true 'core state loaded ($global:Ux.Config is a hashtable)' ''
            $passes = $passes + 1
        } else {
            & $writeCheck $false 'core state loaded' '$global:Ux.Config is missing or not a hashtable'
            $failures = $failures + 1
        }

        # --- 3. every wrapper resolves to Function -------------------------
        $wrapperNames = @()
        $shadowNames = @()
        try {
            $declaredWrappers = & $stateValue 'WrapperNames' @()
            foreach ($name in @($declaredWrappers)) {
                if ($null -ne $name -and [string]$name -ne '') { $wrapperNames += [string]$name }
            }
            $declaredShadow = & $stateValue 'ShadowExtra' @()
            foreach ($name in @($declaredShadow)) {
                if ($null -ne $name -and [string]$name -ne '') { $shadowNames += [string]$name }
            }
        } catch { }
        foreach ($name in $wrapperNames) { $shadowNames += $name }

        if ($wrapperNames.Count -eq 0) {
            & $writeCheck $false 'wrapper list available' '$global:Ux.WrapperNames is empty or missing'
            $failures = $failures + 1
        } else {
            $badWrappers = @()
            foreach ($name in $wrapperNames) {
                $resolved = @()
                try { $resolved = @(Get-Command -Name $name -ErrorAction SilentlyContinue) } catch { $resolved = @() }
                if ($resolved.Count -eq 0) {
                    $badWrappers += ($name + ' (missing)')
                    continue
                }
                $resolvedType = ''
                try { $resolvedType = [string](& $propValue $resolved[0] 'CommandType') } catch { $resolvedType = '' }
                if ($resolvedType -ne 'Function') { $badWrappers += ($name + ' (' + $resolvedType + ')') }
            }
            if ($badWrappers.Count -eq 0) {
                & $writeCheck $true ('all ' + $wrapperNames.Count + ' wrappers resolve to CommandType Function') ''
                $passes = $passes + 1
            } else {
                $okCount = $wrapperNames.Count - $badWrappers.Count
                & $writeCheck $false ('wrappers resolve to CommandType Function (' + $okCount + '/' + $wrapperNames.Count + ')') (& $shortList $badWrappers)
                $failures = $failures + 1
            }
        }

        # --- 4. no shadowing alias survives --------------------------------
        $aliasLeft = @()
        foreach ($name in $shadowNames) {
            $all = @()
            try { $all = @(Get-Command -Name $name -All -ErrorAction SilentlyContinue) } catch { $all = @() }
            foreach ($command in $all) {
                $commandType = ''
                try { $commandType = [string](& $propValue $command 'CommandType') } catch { $commandType = '' }
                if ($commandType -eq 'Alias') {
                    $aliasLeft += $name
                    break
                }
            }
        }
        if ($aliasLeft.Count -eq 0) {
            & $writeCheck $true ('no shadowing alias remains for ' + $shadowNames.Count + ' names') ''
            $passes = $passes + 1
        } else {
            & $writeCheck $false 'no shadowing alias remains' ('aliases still shadow: ' + (& $shortList $aliasLeft))
            $failures = $failures + 1
        }

        # --- 5. runtime files present --------------------------------------
        if ($installDir -eq '' -or -not (Test-Path -LiteralPath $installDir)) {
            & $writeCheck $false 'install directory present' ('not found: ' + $installDir)
            $failures = $failures + 1
        } else {
            $absent = @()
            foreach ($relative in $runtimeFiles) {
                $full = & $joinRelative $installDir ([string]$relative)
                if (-not (Test-Path -LiteralPath $full)) { $absent += [string]$relative }
            }
            if ($absent.Count -eq 0) {
                & $writeCheck $true ('all ' + $runtimeFiles.Count + ' runtime files present') ''
                $passes = $passes + 1
            } else {
                & $writeCheck $false ('runtime files present (' + ($runtimeFiles.Count - $absent.Count) + '/' + $runtimeFiles.Count + ')') ('missing: ' + (& $shortList $absent))
                $failures = $failures + 1
            }
        }

        # --- 6. manifest hashes --------------------------------------------
        # A missing manifest is only acceptable when this is NOT an install (a bare temp dir,
        # a checkout, ux.ps1 recovery mode). The installer always writes manifest.json into
        # the install dir, so inside a real install its absence means a damaged install.
        $manifestPath = ''
        if ($installDir -ne '') { $manifestPath = Join-Path $installDir 'manifest.json' }
        $looksLikeInstall = $false
        if ($installDir -ne '') {
            $entryProbe = ''
            try { $entryProbe = [string](& $joinRelative $installDir 'profile/profile.ps1') } catch { $entryProbe = '' }
            if ($entryProbe -ne '') {
                try { $looksLikeInstall = (Test-Path -LiteralPath $entryProbe) } catch { $looksLikeInstall = $false }
            }
        }
        if ($manifestPath -eq '' -or -not (Test-Path -LiteralPath $manifestPath)) {
            if ($looksLikeInstall) {
                & $writeCheck $false 'manifest.json present' ('the installer always writes one; ' + $manifestPath + ' is missing, so this install is damaged - re-run the installer')
                $failures = $failures + 1
            } else {
                Write-Host '  SKIP  manifest.json not present and this path does not look like an install - nothing to compare'
            }
        } else {
            $manifest = $null
            $manifestError = ''
            try {
                $manifestRaw = [string](Get-Content -LiteralPath $manifestPath -Raw -ErrorAction Stop)
                $manifest = $manifestRaw | ConvertFrom-Json -ErrorAction Stop
            } catch {
                $manifestError = $_.Exception.Message
            }
            if ($null -eq $manifest) {
                & $writeCheck $false 'manifest parses' $manifestError
                $failures = $failures + 1
            } else {
                & $writeCheck $true ('manifest parses (' + $manifestPath + ')') ''
                $passes = $passes + 1

                $manifestVersion = [string](& $propValue $manifest 'version')
                if ($manifestVersion -eq '') {
                    & $writeCheck $false 'manifest version declared' 'the manifest has no version field'
                    $failures = $failures + 1
                } elseif ($manifestVersion -ne $profileVersion) {
                    & $writeCheck $false 'manifest version matches profile version' ('manifest ' + $manifestVersion + ', profile ' + $profileVersion)
                    $failures = $failures + 1
                } else {
                    & $writeCheck $true ('manifest version matches profile version (' + $manifestVersion + ')') ''
                    $passes = $passes + 1
                }

                $manifestFiles = @()
                try { $manifestFiles = @(& $propValue $manifest 'files') } catch { $manifestFiles = @() }
                if ($manifestFiles.Count -eq 0) {
                    & $writeCheck $false 'manifest lists files' 'the manifest has no files array'
                    $failures = $failures + 1
                } else {
                    $hashOk = 0
                    $hashBad = 0
                    foreach ($entry in $manifestFiles) {
                        if ($null -eq $entry) { continue }
                        $relative = [string](& $propValue $entry 'path')
                        $expected = [string](& $propValue $entry 'sha256')
                        if ($relative -eq '') { continue }
                        if ($expected -eq '') {
                            & $writeCheck $false ('hash ' + $relative) 'no sha256 in the manifest entry'
                            $hashBad = $hashBad + 1
                            continue
                        }
                        $full = & $joinRelative $installDir $relative
                        if (-not (Test-Path -LiteralPath $full)) {
                            & $writeCheck $false ('hash ' + $relative) 'file is missing on disk'
                            $hashBad = $hashBad + 1
                            continue
                        }
                        $actual = & $fileSha $full
                        if ($actual -eq '') {
                            & $writeCheck $false ('hash ' + $relative) 'could not hash the file'
                            $hashBad = $hashBad + 1
                        } elseif ($actual -ne $expected.ToLower()) {
                            & $writeCheck $false ('hash ' + $relative) ('on disk ' + $actual + ', manifest ' + $expected.ToLower())
                            $hashBad = $hashBad + 1
                        } else {
                            $hashOk = $hashOk + 1
                        }
                    }
                    if ($hashBad -eq 0) {
                        & $writeCheck $true ('manifest hashes match (' + $hashOk + ' files)') ''
                        $passes = $passes + 1
                    } else {
                        & $writeCheck $false ('manifest hashes match (' + $hashOk + ' ok, ' + $hashBad + ' bad)') 'see the per-file lines above'
                        $failures = $failures + 1
                    }
                }
            }
        }

        Write-Host ''
        if ($failures -eq 0) {
            Write-Host ('verify: OK (' + $passes + ' checks passed)') -ForegroundColor Green
            $exitCode = 0
        } else {
            Write-Host ('verify: FAILED (' + $failures + ' failed, ' + $passes + ' passed)') -ForegroundColor Red
            $exitCode = 1
        }
        Write-Host ''
    }

    elseif ($verb -eq 'theme') {
        $sub = (& $argAt 1).ToLower()
        $currentTheme = ''
        try { $currentTheme = [string](& $configGet 'theme' '') } catch { $currentTheme = '' }

        if ($sub -eq '' -or $sub -eq 'list') {
            Write-Host ''
            if ($currentTheme -ne '') { Write-Host ('themes (current: ' + $currentTheme + ')') }
            else { Write-Host 'themes (current: unknown)' }
            Write-Host ''
            $nameWidth = 4
            foreach ($name in $themeNames) {
                $themeNameText = [string]$name
                if ($themeNameText.Length -gt $nameWidth) { $nameWidth = $themeNameText.Length }
            }
            foreach ($name in $themeNames) {
                $marker = ' '
                if ([string]$name -eq $currentTheme) { $marker = '*' }
                $padded = [string]$name
                while ($padded.Length -lt $nameWidth) { $padded = $padded + ' ' }
                $note = ''
                try {
                    if ($themeNotes -is [hashtable] -and $themeNotes.ContainsKey([string]$name)) {
                        $note = [string]$themeNotes[[string]$name]
                    }
                } catch { $note = '' }
                Write-Host ('  {0} {1}  {2}' -f $marker, $padded, $note)
            }
            Write-Host ''
            Write-Host 'use: ux theme show | ux theme set <name>'
            Write-Host ''
            $exitCode = 0
        }
        elseif ($sub -eq 'show') {
            Write-Host ''
            & $writeRow 'theme' ($(if ($currentTheme -ne '') { $currentTheme } else { 'unknown' })) 10
            $note = ''
            try {
                if ($themeNotes -is [hashtable] -and $themeNotes.ContainsKey($currentTheme)) {
                    $note = [string]$themeNotes[$currentTheme]
                }
            } catch { $note = '' }
            if ($note -ne '') { & $writeRow 'shape' $note 10 }
            $envOverride = ''
            try {
                if ($null -ne $env:UX_THEME -and $env:UX_THEME -ne '') { $envOverride = [string]$env:UX_THEME }
            } catch { $envOverride = '' }
            if ($envOverride -ne '') { & $writeRow 'override' ('UX_THEME=' + $envOverride + ' (this session only)') 10 }
            else { & $writeRow 'override' 'none' 10 }
            $persistedText = 'no'
            if ($configPath -ne '' -and (Test-Path -LiteralPath $configPath)) { $persistedText = 'yes (' + $configPath + ')' }
            & $writeRow 'persisted' $persistedText 10
            if ($currentTheme -ne '') {
                $preview = (& $renderPreview $currentTheme)
                if ($preview -ne '') {
                    & $writeRow 'preview' $preview 10
                } else {
                    & $writeRow 'preview' 'not available (lib/20-prompt.ps1 is not loaded yet)' 10
                }
            }
            Write-Host ''
            $exitCode = 0
        }
        elseif ($sub -eq 'set') {
            $requested = (& $argAt 2).ToLower()
            $valid = $false
            foreach ($name in $themeNames) {
                if ([string]$name -eq $requested) { $valid = $true; break }
            }
            if ($requested -eq '') {
                Write-Host ('theme set: a theme name is required; valid: ' + ($themeNames -join ', ')) -ForegroundColor Red
                $exitCode = 1
            } elseif (-not $valid) {
                Write-Host ('theme set: unknown theme "' + $requested + '"; valid: ' + ($themeNames -join ', ')) -ForegroundColor Red
                $exitCode = 1
            } else {
                $saved = $false
                try { $saved = [bool](& $configSet 'theme' $requested) } catch { $saved = $false }
                if (-not $saved) {
                    Write-Host 'theme set: could not persist the theme (the value was rejected, or config.json is not writable)' -ForegroundColor Red
                    $exitCode = 1
                } else {
                    Write-Host ''
                    Write-Host ('theme set: ' + $requested + ' (saved to ' + $configPath + ')')
                    $preview = (& $renderPreview $requested)
                    if ($preview -ne '') {
                        & $writeRow 'preview' $preview 10
                    }
                    Write-Host 'the prompt redraws on your next command in a new or reloaded session (ux reload).'
                    Write-Host ''
                    $exitCode = 0
                }
            }
        }
        else {
            Write-Host ('theme: unknown subcommand "' + $sub + '"; use list, show or set <name>') -ForegroundColor Red
            $exitCode = 1
        }
    }

    elseif ($verb -eq 'config') {
        $sub = (& $argAt 1).ToLower()

        if ($sub -eq '') {
            Write-Host ''
            Write-Host 'usage:'
            Write-Host '  ux config path                       print the config file path'
            Write-Host '  ux config get <dotted.key>           print the effective value and its default'
            Write-Host '  ux config set <dotted.key> <value>   coerce and persist a value'
            Write-Host '  ux config edit                       open the file in $env:EDITOR (interactive only)'
            Write-Host ''
            $exitCode = 0
        }
        elseif ($sub -eq 'path') {
            if ($configPath -eq '') {
                Write-Host 'config path: unavailable (the install directory could not be resolved)' -ForegroundColor Red
                $exitCode = 1
            } else {
                Write-Output $configPath
                $exitCode = 0
            }
        }
        elseif ($sub -eq 'get') {
            $key = & $argAt 2
            if ($key -eq '') {
                Write-Host 'config get: a dotted key is required, for example: ux config get git.cacheMs' -ForegroundColor Red
                $exitCode = 1
            } else {
                $effective = $null
                try { $effective = & $configGet $key $null } catch { $effective = $null }
                $defaultValue = $null
                try { $defaultValue = & $configDefault $key } catch { $defaultValue = $null }

                $effectiveText = (& $formatValue $effective)
                $defaultText = (& $formatValue $defaultValue)
                if ($null -eq $effective -and $null -eq $defaultValue) {
                    Write-Host ($key + ' = <unset> (no such key, and no schema default)') -ForegroundColor Red
                    $exitCode = 1
                } else {
                    $line = $key + ' = ' + $effectiveText
                    if ($null -eq $defaultValue) {
                        $line = $line + ' (no schema default)'
                    } else {
                        $line = $line + ' (default ' + $defaultText + ')'
                        if ($effectiveText -ne $defaultText) { $line = $line + ' [overridden]' }
                    }
                    Write-Output $line
                    $exitCode = 0
                }
            }
        }
        elseif ($sub -eq 'set') {
            $key = & $argAt 2
            $rawValue = & $argAt 3
            if ($key -eq '') {
                Write-Host 'config set: usage: ux config set <dotted.key> <value>' -ForegroundColor Red
                $exitCode = 1
            } elseif ($rawValue -eq '' -and $positional.Count -lt 4) {
                Write-Host ('config set: a value is required for ' + $key + ' (use "" to set an empty string)') -ForegroundColor Red
                $exitCode = 1
            } else {
                # Typed coercion: true/false -> bool, integers -> int, everything else -> string.
                $typedValue = $rawValue
                $outOfRange = $false
                if ($rawValue -eq 'true') { $typedValue = $true }
                elseif ($rawValue -eq 'false') { $typedValue = $false }
                elseif ($rawValue -match '^-?[0-9]{1,10}$') {
                    try { $typedValue = [int]$rawValue } catch { $typedValue = $rawValue }
                }

                $knownKey = $true
                $defaultValue = $null
                try { $defaultValue = & $configDefault $key } catch { $defaultValue = $null }
                if ($null -eq $defaultValue) { $knownKey = $false }

                # A numeric key with an integer schema default must fit into [int]: core's
                # writer casts it and would otherwise fail with a generic message.
                if ($rawValue -match '^-?[0-9]+$' -and ($defaultValue -is [int] -or $defaultValue -is [long] -or $defaultValue -is [double])) {
                    if (-not ($typedValue -is [int])) { $outOfRange = $true }
                }

                $themeInvalid = $false
                if ($key -eq 'theme') {
                    $themeInvalid = $true
                    foreach ($name in $themeNames) {
                        if ([string]$name -eq [string]$typedValue) { $themeInvalid = $false; break }
                    }
                }

                if ($outOfRange) {
                    Write-Host ('config set: ' + $key + ' expects an integer that fits in 32 bits; "' + $rawValue + '" does not') -ForegroundColor Red
                    $exitCode = 1
                } elseif ($themeInvalid) {
                    Write-Host ('config set: unknown theme "' + [string]$typedValue + '"; valid: ' + ($themeNames -join ', ')) -ForegroundColor Red
                    $exitCode = 1
                } else {
                    if (-not $knownKey) {
                        Write-Host ('config set: warning - "' + $key + '" is not in the schema; writing it anyway') -ForegroundColor Yellow
                    }
                    $saved = $false
                    try { $saved = [bool](& $configSet $key $typedValue) } catch { $saved = $false }
                    if ($saved) {
                        Write-Host ($key + ' = ' + (& $formatValue $typedValue) + ' (saved to ' + $configPath + ')')
                        $exitCode = 0
                    } else {
                        Write-Host ('config set: could not persist ' + $key + ' (the value was rejected, or config.json is not writable)') -ForegroundColor Red
                        $exitCode = 1
                    }
                }
            }
        }
        elseif ($sub -eq 'edit') {
            $interactive = (& $isInteractive)
            if (-not $interactive) {
                Write-Host 'config edit: refusing in a non-interactive host (an editor would block the session)' -ForegroundColor Red
                Write-Host ('  edit the file directly: ' + $configPath)
                $exitCode = 1
            } elseif ($configPath -eq '') {
                Write-Host 'config edit: the config path could not be resolved' -ForegroundColor Red
                $exitCode = 1
            } else {
                if (-not (Test-Path -LiteralPath $configPath)) {
                    try {
                        if (& $hasCommand 'Save-UxConfig') { $null = Save-UxConfig }
                    } catch { }
                }
                $editor = ''
                try {
                    if ($null -ne $env:EDITOR -and $env:EDITOR -ne '') { $editor = [string]$env:EDITOR }
                } catch { $editor = '' }
                if ($editor -eq '' -and $env:OS -eq 'Windows_NT') { $editor = 'notepad.exe' }
                if ($editor -eq '') {
                    try {
                        if ($null -ne $env:VISUAL -and $env:VISUAL -ne '') { $editor = [string]$env:VISUAL }
                    } catch { $editor = '' }
                }
                if ($editor -eq '') {
                    foreach ($candidate in @('vi', 'nano')) {
                        try {
                            if ($null -ne (Get-Command -Name $candidate -CommandType Application -ErrorAction SilentlyContinue)) {
                                $editor = $candidate
                                break
                            }
                        } catch { }
                    }
                }
                if ($editor -eq '') {
                    Write-Host 'config edit: no editor found; set $env:EDITOR or edit this file directly:' -ForegroundColor Red
                    Write-Host ('  ' + $configPath)
                    $exitCode = 1
                } else {
                    $editorParts = @($editor -split '\s+')
                    $editorExe = ''
                    $editorArgs = @()
                    if ($editorParts.Count -gt 0) { $editorExe = [string]$editorParts[0] }
                    for ($i = 1; $i -lt $editorParts.Count; $i++) {
                        if ([string]$editorParts[$i] -ne '') { $editorArgs += [string]$editorParts[$i] }
                    }
                    try {
                        & $editorExe @editorArgs $configPath
                    } catch {
                        Write-Host ('config edit: the editor failed: ' + $_.Exception.Message) -ForegroundColor Red
                        $exitCode = 1
                    }
                    # Re-read the file so the session sees the edits immediately.
                    try {
                        if (& $hasCommand 'Read-UxConfigFile') {
                            $reloaded = Read-UxConfigFile
                            if ($reloaded -is [hashtable]) {
                                $state = & $stateGet
                                if ($null -ne $state) { $state['Config'] = $reloaded }
                                Write-Host 'config edit: config reloaded into this session'
                                $exitCode = 0
                            }
                        } else {
                            Write-Host 'config edit: saved; run ux reload to apply it (Read-UxConfigFile is unavailable)'
                            $exitCode = 0
                        }
                    } catch {
                        Write-Host ('config edit: saved, but reloading it failed: ' + $_.Exception.Message) -ForegroundColor Yellow
                        $exitCode = 0
                    }
                }
            }
        }
        else {
            Write-Host ('config: unknown subcommand "' + $sub + '"; use path, get, set or edit') -ForegroundColor Red
            $exitCode = 1
        }
    }

    elseif ($verb -eq 'reload') {
        if ($installDir -eq '') {
            Write-Host 'reload: the install directory could not be resolved' -ForegroundColor Red
            $exitCode = 1
        } else {
            $entryPath = Join-Path (Join-Path $installDir 'profile') 'profile.ps1'
            if (-not (Test-Path -LiteralPath $entryPath)) {
                Write-Host ('reload: profile entry point not found: ' + $entryPath) -ForegroundColor Red
                $exitCode = 1
            } else {
                # The reload rebuilds $global:Ux from scratch (lib/00-core.ps1 reassigns it),
                # so the load-time snapshot of the user's own aliases/functions has to be
                # captured BEFORE the dot-source and merged back afterwards. Without this,
                # `ux restore-aliases` replays nothing after a reload and the user can never
                # get the original aliases back.
                $snapshotBefore = @()
                try {
                    foreach ($entry in @(& $stateValue 'AliasBackup' @())) {
                        if ($null -ne $entry) { $snapshotBefore += $entry }
                    }
                } catch { $snapshotBefore = @() }

                # profile.ps1 guards against double loading with $global:UxLoaded; clear it
                # so a reload actually reloads.
                try { $global:UxLoaded = $false } catch { }

                $loadOk = $true
                $loadError = ''
                try { . $entryPath } catch {
                    $loadOk = $false
                    $loadError = $_.Exception.Message
                }

                # Merge the preserved snapshot back into the fresh $global:Ux. Preserved
                # entries come first (they are the user's originals). A fresh entry is only
                # appended when that Name+CommandType pair is not known yet - the same rule
                # the snapshot itself uses, because an alias and a function of the same name
                # are different shadows (the alias still wins at resolution).
                $mergeOk = $false
                $carried = 0
                $snapshotTotal = 0
                try {
                    $state = & $stateGet
                    if ($null -ne $state) {
                        $merged = @()
                        foreach ($entry in $snapshotBefore) {
                            $merged += $entry
                            $carried = $carried + 1
                        }
                        if ($state.ContainsKey('AliasBackup')) {
                            foreach ($entry in @($state['AliasBackup'])) {
                                if ($null -eq $entry) { continue }
                                $entryName = ''
                                $entryType = ''
                                try { $entryName = [string]$entry['Name'] } catch { $entryName = '' }
                                try { $entryType = [string]$entry['CommandType'] } catch { $entryType = '' }
                                $alreadyKnown = $false
                                foreach ($existing in $merged) {
                                    if ([string]$existing['Name'] -eq $entryName -and [string]$existing['CommandType'] -eq $entryType) {
                                        $alreadyKnown = $true
                                        break
                                    }
                                }
                                if (-not $alreadyKnown) { $merged += $entry }
                            }
                        }
                        $state['AliasBackup'] = $merged
                        $snapshotTotal = $merged.Count
                        $mergeOk = $true
                    }
                } catch { $mergeOk = $false }

                # This body runs in the function's local scope, so the dot-source defined
                # its functions locally. Promote the PROFILE'S OWN commands to the global
                # scope so the reload really replaced the session's commands (this also
                # covers same-name replacements: the copy simply wins).
                # Only names this project defines may be promoted: copying everything that
                # happens to be visible in the session (module functions included) would
                # shadow imported modules for the rest of the session, and the reported
                # number would describe the whole function table instead of this profile.
                $promoteNames = @{}
                try {
                    foreach ($name in @(& $stateValue 'WrapperNames' @())) {
                        if ($null -ne $name -and [string]$name -ne '') { $promoteNames[[string]$name] = $true }
                    }
                } catch { }
                $promoteNames['ux'] = $true
                $promoteNames['prompt'] = $true
                $promotePrefixes = @(
                    'Ux'
                    'Get-Ux'
                    'Set-Ux'
                    'Format-Ux'
                    'Convert-Ux'
                    'ConvertTo-Ux'
                    'ConvertFrom-Ux'
                    'Copy-Ux'
                    'Reset-Ux'
                    'Test-Ux'
                    'Initialize-Ux'
                    'Merge-Ux'
                    'Read-Ux'
                    'Save-Ux'
                    'Remove-Ux'
                    'Restore-Ux'
                    'Find-Ux'
                    'Join-Ux'
                    'New-Ux'
                    'Resolve-Ux'
                    'Invoke-Ux'
                    'Split-Ux'
                    'Write-Ux'
                    'Limit-Ux'
                )

                $promoted = 0
                try {
                    $visibleFunctions = @(Get-ChildItem Function: -ErrorAction SilentlyContinue)
                    foreach ($functionInfo in $visibleFunctions) {
                        if ($null -eq $functionInfo) { continue }
                        $functionName = ''
                        try { $functionName = [string]$functionInfo.Name } catch { $functionName = '' }
                        if ($functionName -eq '') { continue }

                        $isProfileName = $false
                        if ($promoteNames.ContainsKey($functionName)) { $isProfileName = $true }
                        if (-not $isProfileName) {
                            foreach ($prefix in $promotePrefixes) {
                                if ($functionName.StartsWith($prefix)) { $isProfileName = $true; break }
                            }
                        }
                        if (-not $isProfileName) { continue }

                        $scriptBlock = $null
                        try { $scriptBlock = $functionInfo.ScriptBlock } catch { $scriptBlock = $null }
                        if ($null -eq $scriptBlock) { continue }
                        try {
                            Set-Item -Path ('Function:\global:' + $functionName) -Value $scriptBlock -Force -ErrorAction Stop
                            $promoted = $promoted + 1
                        } catch { }
                    }
                } catch { }

                if ($loadOk) {
                    try { $global:UxLoaded = $true } catch { }
                    $loadMsText = ''
                    try {
                        $loadMs = & $stateValue 'LoadMs' $null
                        if ($null -ne $loadMs) {
                            $loadValue = 0
                            try { $loadValue = [int]$loadMs } catch { $loadValue = 0 }
                            if ($loadValue -gt 0) { $loadMsText = (', load ' + [string]$loadValue + ' ms') }
                        }
                    } catch { }
                    Write-Host ('reload: ok (' + $promoted + ' commands refreshed' + $loadMsText + ')')
                    if (-not $mergeOk) {
                        Write-Host 'warning: the alias snapshot could not be carried over; ux restore-aliases will not restore anything after this reload.' -ForegroundColor Yellow
                    } elseif ($carried -gt 0) {
                        Write-Host ('note: the alias snapshot was carried over (' + $carried + ' preserved, ' + $snapshotTotal + ' in total); ux restore-aliases still works.')
                    } else {
                        Write-Host ('note: the previous snapshot was empty, so nothing had to be carried over (' + $snapshotTotal + ' snapshot entries now).')
                    }
                    $exitCode = 0
                } else {
                    try { $global:UxLoaded = $true } catch { }
                    Write-Host ('reload: the entry point failed: ' + $loadError) -ForegroundColor Red
                    Write-Host ('reload: ' + $promoted + ' commands were refreshed before the failure; the session is still usable.')
                    if (-not $mergeOk) {
                        Write-Host 'warning: the alias snapshot could not be carried over; ux restore-aliases will not restore anything after this reload.' -ForegroundColor Yellow
                    } elseif ($carried -gt 0) {
                        Write-Host ('reload: the alias snapshot was carried over (' + $carried + ' preserved, ' + $snapshotTotal + ' in total).')
                    }
                    $exitCode = 1
                }
            }
        }
    }

    elseif ($verb -eq 'update') {
        $checkOnly = (& $hasFlag 'check')

        # One repository expression for both branches: `ux update` prints the installer URL
        # for the installed version and `ux update -Check` fetches the manifest at the same
        # place, so the two can never drift apart.
        $repoTail = ''
        try { $repoTail = [string](& $getScriptVar 'UxRepoTail') } catch { $repoTail = '' }
        $repoBase = ''
        if ($repoTail -ne '') { $repoBase = 'https://raw.githubusercontent.com/' + $repoTail }
        $versionKnown = ($profileVersion -ne '' -and $profileVersion -ne 'unknown')

        if (-not $checkOnly) {
            Write-Host ''
            Write-Host ('unix-powershell ' + $profileVersion + ' is installed in ' + $installDir)
            Write-Host ''
            Write-Host 'To update, re-run the installer for the release you want (it carries config.json forward):'
            if ($repoBase -ne '' -and $versionKnown) {
                $installerUrl = $repoBase + '/v' + $profileVersion + '/install.ps1'
                Write-Host ('  powershell -NoProfile -Command "iwr ' + $installerUrl + ' -UseBasicParsing | iex"')
            } else {
                # Only the parts that are actually known are filled in: the repository when
                # UxRepoTail is readable, the version when the profile could report one.
                $templateRepo = $repoBase
                if ($templateRepo -eq '') { $templateRepo = 'https://raw.githubusercontent.com/<owner>/<repo>' }
                $templateVersion = '<version>'
                if ($versionKnown) { $templateVersion = $profileVersion }
                $installerUrl = $templateRepo + '/v' + $templateVersion + '/install.ps1'
                Write-Host '  (the installed version or the repository location is unknown, so this line'
                Write-Host '   still carries a <version> placeholder: take it from the release notes)'
                Write-Host ('  powershell -NoProfile -Command "iwr ' + $installerUrl + ' -UseBasicParsing | iex"')
            }
            Write-Host '  powershell -NoProfile -File install.ps1 -SourceDir <reviewed checkout>'
            Write-Host ''
            Write-Host 'The URL above pins the version that is installed now, so replace v<version> with'
            Write-Host 'the release you are moving to. That line downloads install.ps1 for that tag and'
            Write-Host 'runs it. ux update itself downloads nothing - only ux update -Check fetches the'
            Write-Host 'published manifest, to compare it with the installed files.'
            Write-Host 'After updating, run: ux reload'
            Write-Host ''
            Write-Host 'Use ux update -Check to compare the installed files with the published manifest.'
            Write-Host ''
            $exitCode = 0
        } else {
            $remoteUrl = ''
            try {
                if ($null -ne $env:UX_UPDATE_URL -and $env:UX_UPDATE_URL -ne '') { $remoteUrl = [string]$env:UX_UPDATE_URL }
            } catch { $remoteUrl = '' }
            if ($remoteUrl -eq '') {
                if ($repoBase -eq '') {
                    Write-Host 'update -Check: the repository location is unknown (UxRepoTail is missing)' -ForegroundColor Red
                    $exitCode = 2
                } else {
                    $remoteUrl = $repoBase + '/v' + $profileVersion + '/manifest.json'
                }
            }

            if ($remoteUrl -eq '') {
                # already reported above
            } elseif ($installDir -eq '' -or -not (Test-Path -LiteralPath $installDir)) {
                Write-Host ('update -Check: install directory not found: ' + $installDir) -ForegroundColor Red
                $exitCode = 2
            } else {
                Write-Host ''
                Write-Host ('update -Check: comparing ' + $installDir)
                Write-Host ('             with ' + $remoteUrl)
                Write-Host ''
                $remoteText = (& $fetchText $remoteUrl)
                $remoteManifest = $null
                if ($remoteText -ne '') {
                    try { $remoteManifest = $remoteText | ConvertFrom-Json -ErrorAction Stop } catch { $remoteManifest = $null }
                }
                if ($null -eq $remoteManifest) {
                    Write-Host 'update -Check: could not fetch or parse the published manifest' -ForegroundColor Red
                    Write-Host '  (offline, a proxy is required, the tag does not exist, or UX_UPDATE_URL is wrong)'
                    $exitCode = 2
                } else {
                    $remoteVersion = [string](& $propValue $remoteManifest 'version')
                    if ($remoteVersion -eq '') {
                        Write-Host 'update -Check: the published manifest declares no version' -ForegroundColor Yellow
                    } elseif ($remoteVersion -eq $profileVersion) {
                        Write-Host ('version:            ' + $profileVersion + ' (installed) = ' + $remoteVersion + ' (published)')
                    } else {
                        Write-Host ('version:            ' + $profileVersion + ' (installed) <> ' + $remoteVersion + ' (published) - an update is available') -ForegroundColor Yellow
                    }

                    $remoteFiles = @()
                    try { $remoteFiles = @(& $propValue $remoteManifest 'files') } catch { $remoteFiles = @() }
                    $checked = 0
                    $bad = 0
                    foreach ($entry in $remoteFiles) {
                        if ($null -eq $entry) { continue }
                        $relative = [string](& $propValue $entry 'path')
                        $expected = [string](& $propValue $entry 'sha256')
                        if ($relative -eq '' -or $expected -eq '') { continue }
                        $checked = $checked + 1
                        $full = & $joinRelative $installDir $relative
                        if (-not (Test-Path -LiteralPath $full)) {
                            Write-Host ('  MISSING  ' + $relative) -ForegroundColor Yellow
                            $bad = $bad + 1
                            continue
                        }
                        $actual = & $fileSha $full
                        if ($actual -eq '' -or $actual -ne $expected.ToLower()) {
                            Write-Host ('  DIFFERS  ' + $relative) -ForegroundColor Yellow
                            $bad = $bad + 1
                        }
                    }
                    Write-Host ('files:              ' + $checked + ' compared, ' + $bad + ' differ')
                    Write-Host ''
                    if ($bad -eq 0 -and $remoteVersion -eq $profileVersion) {
                        Write-Host 'update -Check: up to date - every installed file matches the published manifest' -ForegroundColor Green
                        $exitCode = 0
                    } elseif ($bad -eq 0) {
                        Write-Host 'update -Check: files match, but the published version differs - re-run the installer' -ForegroundColor Yellow
                        $exitCode = 1
                    } else {
                        Write-Host 'update -Check: differences found - re-run the installer (it carries config.json forward)' -ForegroundColor Yellow
                        $exitCode = 1
                    }
                    Write-Host ''
                }
            }
        }
    }

    elseif ($verb -eq 'disable') {
        if ($installDir -eq '') {
            Write-Host 'disable: the install directory could not be resolved' -ForegroundColor Red
            $exitCode = 1
        } else {
            if (-not (Test-Path -LiteralPath $installDir)) {
                try { $null = New-Item -ItemType Directory -Path $installDir -Force -ErrorAction Stop } catch { }
            }
            $markerPath = Join-Path $installDir '.disabled'
            $created = $false
            try {
                $message = 'unix-powershell is disabled for this install. Delete this file (or run: ux enable) to load the profile again.'
                Set-Content -LiteralPath $markerPath -Value $message -Encoding UTF8 -ErrorAction Stop
                $created = $true
            } catch {
                $created = $false
            }
            if ($created) {
                Write-Host ('disable: created ' + $markerPath)
                Write-Host 'new sessions will not load the profile; this session keeps working.'
            } else {
                Write-Host ('disable: could not create ' + $markerPath) -ForegroundColor Red
                $exitCode = 1
            }
            try {
                if ($env:UX_DISABLE -eq '1') {
                    Write-Host 'disable: note - UX_DISABLE=1 is also set in this environment; unset it as well.'
                }
            } catch { }
        }
    }

    elseif ($verb -eq 'enable') {
        if ($installDir -eq '') {
            Write-Host 'enable: the install directory could not be resolved' -ForegroundColor Red
            $exitCode = 1
        } else {
            $markerPath = Join-Path $installDir '.disabled'
            $existed = $false
            try { $existed = (Test-Path -LiteralPath $markerPath) } catch { $existed = $false }
            if (-not $existed) {
                Write-Host ('enable: already enabled (no marker at ' + $markerPath + ')')
            } else {
                $removed = $false
                try {
                    Remove-Item -LiteralPath $markerPath -Force -ErrorAction Stop
                    $removed = $true
                } catch {
                    $removed = $false
                }
                if ($removed) {
                    Write-Host ('enable: removed ' + $markerPath)
                    Write-Host 'new sessions will load the profile again (this session is unaffected).'
                } else {
                    Write-Host ('enable: could not remove ' + $markerPath) -ForegroundColor Red
                    $exitCode = 1
                }
            }
            try {
                if ($env:UX_DISABLE -eq '1') {
                    Write-Host 'enable: note - UX_DISABLE=1 is still set in this environment; new sessions stay disabled until it is unset.'
                }
            } catch { }
        }
    }

    elseif ($verb -eq 'restore-aliases') {
        $snapshotCount = 0
        try {
            # @(...) around the pipeline: an empty snapshot would otherwise arrive as
            # $null and count as 1 entry.
            $snapshot = @(& $stateValue 'AliasBackup' @())
            $snapshotCount = $snapshot.Count
        } catch { $snapshotCount = 0 }

        if (-not (& $hasCommand 'Restore-UxShadowedCommands')) {
            Write-Host 'restore-aliases: Restore-UxShadowedCommands is unavailable (lib/00-core.ps1 is not loaded)' -ForegroundColor Red
            $exitCode = 1
        } else {
            $restored = $true
            $restoreError = ''
            try { Restore-UxShadowedCommands } catch {
                $restored = $false
                $restoreError = $_.Exception.Message
            }
            if ($restored) {
                Write-Host ('restore-aliases: replayed ' + $snapshotCount + ' snapshot entries (aliases resolve before functions, so the originals win again)')
                $exitCode = 0
            } else {
                Write-Host ('restore-aliases: replay failed: ' + $restoreError) -ForegroundColor Red
                $exitCode = 1
            }
        }
    }

    elseif ($verb -eq 'uninstall') {
        $force = (& $hasFlag 'force')
        $interactive = (& $isInteractive)

        if ($installDir -eq '') {
            Write-Host 'uninstall: the install directory could not be resolved' -ForegroundColor Red
            $exitCode = 1
        } else {
            # Refuse while the current directory lives inside the install directory:
            # deleting it underneath the session is never what the user meant.
            $normalPwd = ''
            try { $normalPwd = ([string](Get-Location).Path).ToLower().Replace([char]92, [char]47) } catch { $normalPwd = '' }
            $normalInstall = $installDir.ToLower().Replace([char]92, [char]47)
            while ($normalPwd.Length -gt 1 -and $normalPwd.EndsWith([string][char]47)) {
                $normalPwd = $normalPwd.Substring(0, $normalPwd.Length - 1)
            }
            while ($normalInstall.Length -gt 1 -and $normalInstall.EndsWith([string][char]47)) {
                $normalInstall = $normalInstall.Substring(0, $normalInstall.Length - 1)
            }
            $insideInstall = $false
            if ($normalPwd -ne '' -and $normalInstall -ne '') {
                if ($normalPwd -eq $normalInstall) { $insideInstall = $true }
                elseif ($normalPwd.StartsWith($normalInstall + '/')) { $insideInstall = $true }
            }

            $normalHome = ''
            try {
                if ($null -ne $HOME -and $HOME -ne '') { $normalHome = ([string]$HOME).ToLower().Replace([char]92, [char]47) }
                elseif ($null -ne $env:USERPROFILE -and $env:USERPROFILE -ne '') { $normalHome = ([string]$env:USERPROFILE).ToLower().Replace([char]92, [char]47) }
            } catch { $normalHome = '' }
            $isHome = ($normalHome -ne '' -and $normalHome -eq $normalInstall)

            # Safety gate: this verb deletes $installDir with -Recurse, and the path comes
            # from the environment. Refuse anything that is not demonstrably this install
            # (root, $HOME, a directory containing $PWD, or a folder that does not look like
            # a unix-powershell install). One ASCII line, exit 1, nothing is touched.
            $safetyOk = $true
            $safetyReason = ''
            try {
                $safety = (& $checkInstallDir $installDir)
                $safetyOk = [bool]($safety['Ok'])
                $safetyReason = [string]($safety['Reason'])
            } catch {
                $safetyOk = $false
                $safetyReason = 'the install directory could not be validated'
            }

            if (-not $safetyOk) {
                Write-Host ('uninstall: refusing - ' + $safetyReason + '. Nothing was deleted.') -ForegroundColor Red
                $exitCode = 1
            } elseif ($insideInstall) {
                Write-Host 'uninstall: refusing - the current directory is inside the install directory' -ForegroundColor Red
                Write-Host ('  cd somewhere else first, then re-run: ux uninstall' + $(if ($force) { ' -Force' } else { '' }))
                $exitCode = 1
            } elseif ($isHome) {
                Write-Host 'uninstall: refusing - the install directory resolves to your home directory' -ForegroundColor Red
                $exitCode = 1
            } else {
                $proceed = $true
                if (-not $force) {
                    if (-not $interactive) {
                        Write-Host 'uninstall: refusing in a non-interactive session; re-run with -Force' -ForegroundColor Red
                        $proceed = $false
                        $exitCode = 1
                    } else {
                        $answer = ''
                        try {
                            $answer = [string](Read-Host ('Remove the unix-powershell profile block and delete ' + $installDir + '? [y/N]'))
                        } catch { $answer = '' }
                        if ($answer -notmatch '^(y|yes)$') {
                            Write-Host 'uninstall: cancelled'
                            $proceed = $false
                            $exitCode = 1
                        }
                    }
                }

                if ($proceed) {
                    Write-Host ''
                    Write-Host 'uninstall: removing the profile block'

                    $candidates = @()
                    $allHostsPath = ''
                    $currentHostPath = ''
                    try { $allHostsPath = [string]$PROFILE.CurrentUserAllHosts } catch { $allHostsPath = '' }
                    try { $currentHostPath = [string]$PROFILE.CurrentUserCurrentHost } catch { $currentHostPath = '' }
                    if ($allHostsPath -ne '') { $candidates += $allHostsPath }
                    if ($currentHostPath -ne '' -and $currentHostPath -ne $allHostsPath) { $candidates += $currentHostPath }
                    if ($env:OS -eq 'Windows_NT' -and $allHostsPath -ne '') {
                        $otherHostPath = ''
                        try { $otherHostPath = [string](& $otherProfilePath $allHostsPath) } catch { $otherHostPath = '' }
                        if ($otherHostPath -ne '' -and $candidates -notcontains $otherHostPath) { $candidates += $otherHostPath }
                    }

                    $manualNeeded = $false
                    if ($candidates.Count -eq 0) {
                        Write-Host '  no profile path could be resolved; check $PROFILE manually' -ForegroundColor Yellow
                    }
                    foreach ($profilePath in $candidates) {
                        $result = (& $stripProfileBlock $profilePath)
                        $status = ''
                        $detail = ''
                        try {
                            $status = [string]$result['Status']
                            $detail = [string]$result['Detail']
                        } catch { $status = 'manual'; $detail = 'unexpected result' }
                        if ($status -eq 'removed') {
                            Write-Host ('  removed   ' + $profilePath + ' (' + $detail + ')')
                        } elseif ($status -eq 'clean') {
                            Write-Host ('  untouched ' + $profilePath + ' (no unix-powershell block)')
                        } elseif ($status -eq 'no-file') {
                            Write-Host ('  skipped   ' + $profilePath + ' (file does not exist)')
                        } else {
                            $manualNeeded = $true
                            & $writeManualRemoval $profilePath $detail $installDir
                        }
                    }

                    if ($manualNeeded) {
                        Write-Host ''
                        Write-Host 'uninstall: the profile still references unix-powershell - follow the manual steps above,' -ForegroundColor Yellow
                        Write-Host '           then delete the install directory yourself: ' -ForegroundColor Yellow
                        Write-Host ('           ' + $installDir)
                        $exitCode = 1
                    } else {
                        Write-Host ''
                        Write-Host ('uninstall: deleting ' + $installDir)
                        $deleted = $false
                        $deleteError = ''
                        try {
                            if (Test-Path -LiteralPath $installDir) {
                                Remove-Item -LiteralPath $installDir -Recurse -Force -ErrorAction Stop
                            }
                            $deleted = $true
                        } catch {
                            $deleted = $false
                            $deleteError = $_.Exception.Message
                        }
                        if ($deleted) {
                            Write-Host 'uninstall: done - open a new shell; the profile block is gone and the files are deleted.' -ForegroundColor Green
                            Write-Host 'note: ux stays available in this session until you close it.'
                            $exitCode = 0
                        } else {
                            Write-Host ('uninstall: could not delete ' + $installDir + ': ' + $deleteError) -ForegroundColor Red
                            Write-Host '  close every shell that loaded the profile, then delete the directory by hand.'
                            $exitCode = 1
                        }
                    }
                    Write-Host ''
                }
            }
        }
    }

    else {
        # Unknown verb: usage table plus a distinct exit code (2) so scripts can tell it apart.
        Write-Host ('ux: unknown verb "' + (& $argAt 0) + '"') -ForegroundColor Red
        & $writeHelp
        $exitCode = 2
    }

    $global:LASTEXITCODE = $exitCode
}

# ---------------------------------------------------------------------------
# Tab completion: verbs for `ux`, theme names for `ux theme set <name>`.
# Deliberately wrapped: ConstrainedLanguage disables Register-ArgumentCompleter, and a
# completion failure must never break profile loading.
# ---------------------------------------------------------------------------
try {
    $uxCompleterRegistered = $false
    try {
        $null = Get-Command -Name 'Register-ArgumentCompleter' -ErrorAction Stop
        $uxCompleterRegistered = $true
    } catch {
        $uxCompleterRegistered = $false
    }

    if ($uxCompleterRegistered) {
        $uxCompleter = {
            param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)

            # The callback runs in a scope chain of the completion engine's choosing, so
            # every scope lookup gets its own try/catch: one unavailable scope must not
            # discard the others (Get-Variable -Scope Script can throw here).
            $fetchVariable = {
                param([string]$Name)
                foreach ($scopeName in @('Global', 'Script', 'Local')) {
                    try {
                        $variable = Get-Variable -Name $Name -Scope $scopeName -ErrorAction SilentlyContinue
                        if ($null -ne $variable -and $null -ne $variable.Value) { return $variable.Value }
                    } catch { }
                }
                try {
                    $variable = Get-Variable -Name $Name -ErrorAction SilentlyContinue
                    if ($null -ne $variable -and $null -ne $variable.Value) { return $variable.Value }
                } catch { }
                return $null
            }

            # AST nodes are recognised by their CommandElements property: the project's AST
            # allowlist limits type literals, so no AST type cast is used here.
            $looksLikeAst = {
                param($Candidate)
                if ($null -eq $Candidate) { return $false }
                try {
                    if ($null -ne $Candidate.PSObject.Properties['CommandElements']) { return $true }
                } catch { }
                return $false
            }

            # Engines differ: 5.1 calls (commandName, parameterName, wordToComplete,
            # commandAst, fakeBoundParameters); newer ones call (wordToComplete, commandAst,
            # cursorPosition). Support both instead of guessing.
            $ast = $null
            $word = ''
            if (& $looksLikeAst $commandAst) {
                $ast = $commandAst
                if ($null -ne $wordToComplete) { $word = [string]$wordToComplete }
            } elseif (& $looksLikeAst $parameterName) {
                $ast = $parameterName
                if ($null -ne $commandName) { $word = [string]$commandName }
            }

            $verbs = @()
            $themes = @()
            $verbSource = & $fetchVariable 'UxVerbs'
            if ($null -ne $verbSource) { $verbs = @($verbSource) }
            $themeSource = & $fetchVariable 'UxThemes'
            if ($null -ne $themeSource) { $themes = @($themeSource) }

            # Split the command line into words; the trailing partial token is the word
            # being completed, so it never counts as an already-typed verb.
            $words = @()
            try {
                foreach ($element in @($ast.CommandElements)) {
                    $text = ''
                    try { $text = [string]$element.Value } catch { $text = '' }
                    if ($text -eq '') {
                        try { $text = [string]$element.Extent.Text } catch { $text = '' }
                    }
                    $words += $text
                }
            } catch { $words = @() }

            $completedWords = @()
            $limit = $words.Count
            if ($word -ne '' -and $limit -gt 0) { $limit = $limit - 1 }
            for ($i = 0; $i -lt $limit; $i++) { $completedWords += [string]$words[$i] }

            $themeSetPosition = ($completedWords.Count -ge 3 -and $completedWords[1] -eq 'theme' -and $completedWords[2] -eq 'set')
            if ($themeSetPosition) {
                foreach ($theme in $themes) {
                    $name = [string]$theme
                    if ($name -eq '') { continue }
                    if ($word -eq '' -or $name.StartsWith($word)) { $name }
                }
                return
            }

            # Verbs only in the verb position: nothing but flags before the cursor.
            $verbAlreadyTyped = ''
            for ($i = 1; $i -lt $completedWords.Count; $i++) {
                $candidate = [string]$completedWords[$i]
                if ($candidate.StartsWith([string][char]45)) { continue }
                $verbAlreadyTyped = $candidate
                break
            }
            if ($verbAlreadyTyped -ne '') { return }

            foreach ($entry in $verbs) {
                $name = ''
                try {
                    if ($null -ne $entry -and $entry.ContainsKey('Verb')) { $name = [string]$entry['Verb'] }
                } catch { $name = '' }
                if ($name -eq '') { continue }
                if ($word -eq '' -or $name.StartsWith($word)) { $name }
            }
        }

        Register-ArgumentCompleter -CommandName 'ux' -ScriptBlock $uxCompleter -ErrorAction Stop
    }
} catch { }

Remove-Variable -Name 'uxCompleter', 'uxCompleterRegistered' -ErrorAction SilentlyContinue
