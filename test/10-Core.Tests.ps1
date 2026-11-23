#Requires -Version 5.1
<#
    Core behaviour: lib/00-core.ps1 (config, capability probe, shadowed commands) and
    lib/05-args.ps1 (ConvertFrom-UxArgv).

    Every test here corresponds to a documented claim in PLAN.md 5.1 and 6, i.e. one of
    the ways this profile can silently misbehave on a locked-down machine:

      * a missing / empty / corrupt / future-versioned config.json must degrade to the
        shipped defaults and never take the shell down;
      * the JSON writer must not truncate nested keys into "System.Collections.Hashtable"
        strings (the ConvertTo-Json -Depth trap on Windows PowerShell 5.1);
      * the capability probe must return the documented shape even when a dependency
        throws (it is wrapped in try/catch on purpose);
      * a shadowing alias / function must be snapshotted and removable, and restorable;
      * everything must survive a user's Set-StrictMode -Version Latest.

    Isolation rules (this file runs in the same session as the other test files):
      * the install dir is redirected into $TestDrive through $env:UX_INSTALL_DIR, so
        nothing is ever written into the (read-only) checkout or into $HOME;
      * $global:Ux is rebuilt from lib/00-core.ps1 before every test and restored after,
        and every environment variable a test touches is restored from a baseline;
      * the profile-load tests run in a child pwsh process, because profile.ps1 mutates
        globals and removes shadowing aliases - exactly the kind of state a later test
        file must not inherit.
#>

BeforeAll {
    $script:Root = Split-Path -Parent $PSScriptRoot
    if (-not $script:Root) { $script:Root = Split-Path -Parent $MyInvocation.MyCommand.Path }
    $script:CorePath = Join-Path $script:Root 'lib/00-core.ps1'
    $script:ArgsPath = Join-Path $script:Root 'lib/05-args.ps1'
    $script:ProfilePath = Join-Path $script:Root 'profile/profile.ps1'

    . $script:CorePath
    . $script:ArgsPath

    # The $global:Ux that lib/00-core.ps1 just created: every test gets a fresh copy of
    # this shape, and AfterEach puts this exact object back.
    $script:OriginalState = $global:Ux

    # --- environment isolation -------------------------------------------------
    # Captured once, restored after every test, so one test can never leak UX_DISABLE
    # or a modified PATH into another file's session.
    $script:EnvNames = @(
        'UX_INSTALL_DIR', 'UX_DISABLE', 'UX_QUIET', 'UX_NO_COLOR', 'UX_DEBUG',
        'NO_COLOR', 'WT_SESSION', 'TERM_PROGRAM', 'ConEmuANSI', 'OS'
    )
    $script:EnvBaseline = @{}
    foreach ($name in $script:EnvNames) {
        $item = Get-Item -Path ('Env:' + $name) -ErrorAction SilentlyContinue
        if ($null -ne $item) { $script:EnvBaseline[$name] = [string]$item.Value }
        else { $script:EnvBaseline[$name] = $null }
    }

    function script:Set-UxTestEnv {
        param([string]$Name, [string]$Value)
        if ($null -eq $Value) {
            Remove-Item -Path ('Env:' + $Name) -ErrorAction SilentlyContinue
        }
        else {
            Set-Item -Path ('Env:' + $Name) -Value $Value -ErrorAction SilentlyContinue
        }
    }

    function script:Restore-UxTestEnv {
        foreach ($name in $script:EnvNames) {
            script:Set-UxTestEnv -Name $name -Value $script:EnvBaseline[$name]
        }
    }

    # --- $global:Ux isolation --------------------------------------------------
    function script:Reset-UxTestState {
        param([string]$InstallDir = '')
        # Dot-sourcing the real file is the only honest way to get "the state a fresh
        # session would have": the assignment at the bottom of lib/00-core.ps1 is
        # global, so this replaces $global:Ux with a brand new hashtable.
        . $script:CorePath
        if ($InstallDir -ne '') { $global:Ux['InstallDir'] = $InstallDir }
        $global:Ux['ConfigLoaded'] = $false
    }

    function script:Write-UxTestConfig {
        param([string]$Path, [string]$Text)
        $parent = Split-Path -Parent $Path
        if ($parent -ne '' -and -not (Test-Path -LiteralPath $parent)) {
            $null = New-Item -ItemType Directory -Force -Path $parent
        }
        Set-Content -LiteralPath $Path -Value $Text -Encoding UTF8
    }

    function script:Get-UxTestWarnings {
        # Read-UxConfigFile reports through Write-Warning. A simple (non-advanced)
        # function accepts no -WarningVariable, so merge stream 3 into the output.
        param($Source)
        $messages = @()
        foreach ($item in @($Source)) {
            if ($null -eq $item) { continue }
            if ($item.GetType().Name -eq 'WarningRecord') { $messages += [string]$item }
        }
        return , $messages
    }

    function script:Get-HostExecutable {
        $major = 5
        if ($PSVersionTable.ContainsKey('PSVersion')) { $major = [int]$PSVersionTable.PSVersion.Major }
        if ($env:OS -eq 'Windows_NT') {
            if ($major -ge 7) { return (Join-Path $PSHOME 'pwsh.exe') }
            return (Join-Path $PSHOME 'powershell.exe')
        }
        return (Join-Path $PSHOME 'pwsh')
    }

    # --- strict-mode / disabled-load probe -------------------------------------
    # A child process is the only way to dot-source profile/profile.ps1 without
    # mutating this session: profile.ps1 sets $global:UxLoaded, rebuilds $global:Ux and
    # removes shadowing aliases. The probe prints one 'UXPROBE:<json>' line.
    $script:LoadProbe = @'
#Requires -Version 5.1
param(
    [Parameter(Mandatory = $true)][string]$Root,
    [string]$StrictMode = '0'
)
$ErrorActionPreference = 'Continue'
if ($StrictMode -eq '1') { Set-StrictMode -Version Latest }
$entry = Join-Path $Root 'profile/profile.ps1'
$threw = ''
try { . $entry } catch { $threw = [string]$_.Exception.Message }
$ids = @()
foreach ($record in $Error) {
    $id = 'unknown'
    try { $id = [string]$record.FullyQualifiedErrorId } catch { $id = 'unknown' }
    if ($ids -notcontains $id) { $ids = $ids + $id }
}
$state = $null
try { $state = Get-Variable -Name 'Ux' -Scope Global -ErrorAction SilentlyContinue } catch { $state = $null }
$loaded = $false
try { $loaded = ($null -ne (Get-Variable -Name 'UxLoaded' -Scope Global -ErrorAction SilentlyContinue)) } catch { $loaded = $false }
$keyCount = 0
$hasConfig = $false
$hasCaps = $false
if ($null -ne $state) {
    if ($state.Value -is [hashtable]) {
        $keyCount = $state.Value.Keys.Count
        if ($state.Value.ContainsKey('Config') -and $state.Value['Config'] -is [hashtable]) { $hasConfig = $true }
        if ($state.Value.ContainsKey('Caps') -and $state.Value['Caps'] -is [hashtable]) { $hasCaps = $true }
    }
}
$payload = @{
    Threw      = $threw
    ErrorIds   = $ids
    UxLoaded   = $loaded
    UxKeyCount = $keyCount
    HasConfig  = $hasConfig
    HasCaps    = $hasCaps
}
'UXPROBE:' + ($payload | ConvertTo-Json -Compress)
'@
    $script:LoadProbePath = Join-Path $TestDrive 'load-probe.ps1'
    Set-Content -LiteralPath $script:LoadProbePath -Value $script:LoadProbe -Encoding ASCII

    function script:Invoke-LoadProbe {
        param([string]$StrictMode = '0')
        $exe = script:Get-HostExecutable
        $raw = @(& $exe -NoProfile -File $script:LoadProbePath -Root $script:Root -StrictMode $StrictMode 2>&1)
        $lines = @()
        $payload = $null
        foreach ($item in $raw) {
            $text = [string]$item
            $lines += $text
            if ($text.StartsWith('UXPROBE:')) {
                $payload = $text.Substring(8) | ConvertFrom-Json
            }
        }
        return [pscustomobject]@{ Payload = $payload; Lines = $lines; ExitCode = $LASTEXITCODE }
    }

    function script:Get-ProbeText {
        param($Probe)
        return (@($Probe.Lines) -join "`n")
    }

    # State the shadowing tests touch. `MkdirProbeActive` is the guard that keeps
    # AfterEach from deleting the *built-in* mkdir function on a real Windows session:
    # cleanup only runs for a probe this file actually installed.
    $script:SavedMkdir = $null
    $script:MkdirProbeActive = $false
}

Describe 'Core library and tokenizer' {

    BeforeEach {
        $script:InstallDir = Join-Path $TestDrive ('install-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $null = New-Item -ItemType Directory -Force -Path $script:InstallDir
        $script:ConfigPath = Join-Path $script:InstallDir 'config.json'

        script:Restore-UxTestEnv
        script:Set-UxTestEnv -Name 'UX_INSTALL_DIR' -Value $script:InstallDir
        script:Reset-UxTestState -InstallDir $script:InstallDir
    }

    AfterEach {
        # Shadowing tests create global aliases/functions; remove them even when an
        # assertion failed half way through.
        foreach ($name in @('zzshadowalias', 'zzshadowalias2', 'zzbystander')) {
            Remove-Item -LiteralPath ('Alias:\' + $name) -Force -ErrorAction SilentlyContinue
        }
        if ($script:MkdirProbeActive) {
            # Put back whatever mkdir was before this file shadowed it (the built-in
            # function on a Windows session, nothing on Linux/macOS). The two provider
            # paths are not interchangeable: Set-Item honours the 'global:' qualifier,
            # Remove-Item does not (it silently does nothing for 'Function:\global:x'),
            # which is why lib/00-core.ps1 uses the same pair.
            if ($null -ne $script:SavedMkdir) {
                Set-Item -Path 'Function:\global:mkdir' -Value $script:SavedMkdir -Force -ErrorAction SilentlyContinue
            }
            else {
                Remove-Item -LiteralPath 'Function:\mkdir' -Force -ErrorAction SilentlyContinue
            }
            $script:SavedMkdir = $null
            $script:MkdirProbeActive = $false
        }

        $global:Ux = $script:OriginalState
        Remove-Variable -Name 'UxLoaded' -Scope Global -ErrorAction SilentlyContinue
        script:Restore-UxTestEnv
    }

    Describe 'Config: defaults and documented reads' {

        It 'returns the shipped defaults when no config file exists' {
            Test-Path -LiteralPath $script:ConfigPath | Should -BeFalse -Because 'this test is only meaningful without a file'
            $null = Initialize-UxConfig

            Get-UxConfig -Path 'version' | Should -Be 1
            Get-UxConfig -Path 'theme' | Should -Be 'ascii'
            Get-UxConfig -Path 'git.cacheMs' | Should -Be 2000
            Get-UxConfig -Path 'git.maxDepth' | Should -Be 40
            Get-UxConfig -Path 'git.slowThresholdMs' | Should -Be 250
            Get-UxConfig -Path 'prompt.symbol' | Should -Be '$'
            Get-UxConfig -Path 'ui.banner' | Should -BeTrue
            (Get-UxConfig -Path 'prompt') -is [hashtable] | Should -BeTrue
        }

        It 'returns -Default for a missing key and never throws' {
            $null = Initialize-UxConfig
            $threw = ''
            $value = $null
            try {
                $value = Get-UxConfig -Path 'nope.not.here' -Default 'sentinel'
            }
            catch {
                $threw = [string]$_.Exception.Message
            }
            $threw | Should -BeNullOrEmpty -Because 'a prompt-time config read must never throw'
            $value | Should -Be 'sentinel'

            Get-UxConfig -Path 'git.cacheMs.deeper' -Default 7 | Should -Be 7 -Because 'a scalar node has no children'
            Get-UxConfig -Path 'nope' | Should -BeNullOrEmpty
            (Get-UxConfig) -is [hashtable] | Should -BeTrue -Because 'the empty path returns the whole config'
        }

        It 'deep-merges a partial config file over the defaults' {
            script:Write-UxTestConfig -Path $script:ConfigPath -Text '{"version":1,"theme":"classic","git":{"cacheMs":500}}'
            $null = Initialize-UxConfig

            Get-UxConfig -Path 'theme' | Should -Be 'classic'
            Get-UxConfig -Path 'git.cacheMs' | Should -Be 500
            Get-UxConfig -Path 'git.slowThresholdMs' | Should -Be 250 -Because 'keys the user omitted keep their default'
            Get-UxConfig -Path 'prompt.symbol' | Should -Be '$'
        }
    }

    Describe 'Config: normalisation of PSCustomObject trees' {

        It 'converts a four-level PSCustomObject tree into nested hashtables' {
            $tree = [pscustomobject]@{
                level1 = [pscustomobject]@{
                    level2 = [pscustomobject]@{
                        level3 = [pscustomobject]@{
                            level4 = 'deep'
                            list   = @(1, [pscustomobject]@{ leaf = 'x' })
                        }
                    }
                }
            }

            $result = ConvertTo-UxHashtable -InputObject $tree
            $result -is [hashtable] | Should -BeTrue
            $result['level1'] -is [hashtable] | Should -BeTrue
            $result['level1']['level2'] -is [hashtable] | Should -BeTrue
            $result['level1']['level2']['level3'] -is [hashtable] | Should -BeTrue -Because 'Windows PowerShell 5.1 has no ConvertFrom-Json -AsHashtable'
            $result['level1']['level2']['level3']['level4'] | Should -Be 'deep'

            $list = @($result['level1']['level2']['level3']['list'])
            $list.Count | Should -Be 2 -Because 'arrays must be preserved, not collapsed into a single element'
            $list[0] | Should -Be 1
            $list[1] -is [hashtable] | Should -BeTrue
            $list[1]['leaf'] | Should -Be 'x'
        }

        It 'normalises real ConvertFrom-Json output with arrays of objects' {
            $json = '{"version":1,"files":[{"path":"a.ps1","sha256":"aa"},{"path":"b.ps1","sha256":"bb"}]}'
            $parsed = ConvertTo-UxHashtable -InputObject ($json | ConvertFrom-Json)

            $parsed -is [hashtable] | Should -BeTrue
            $files = @($parsed['files'])
            $files.Count | Should -Be 2
            $files[0] -is [hashtable] | Should -BeTrue
            $files[1]['path'] | Should -Be 'b.ps1'
        }

        It 'passes scalars and nulls through untouched' {
            (ConvertTo-UxHashtable -InputObject 'text') | Should -Be 'text'
            (ConvertTo-UxHashtable -InputObject 42) | Should -Be 42
            (ConvertTo-UxHashtable -InputObject $true) | Should -BeTrue
            (ConvertTo-UxHashtable -InputObject $null) | Should -BeNullOrEmpty
            (ConvertTo-UxHashtable -InputObject ([ordered]@{ a = 1 })) -is [hashtable] | Should -BeTrue
        }
    }

    Describe 'Config: corrupt, empty and unreadable files' {

        It 'falls back to defaults and quarantines invalid JSON as config.json.bad' {
            script:Write-UxTestConfig -Path $script:ConfigPath -Text '{"version": 1, "theme": "classic",'
            $threw = ''
            $warnings = @()
            try {
                $warnings = script:Get-UxTestWarnings -Source @(Initialize-UxConfig 3>&1)
            }
            catch {
                $threw = [string]$_.Exception.Message
            }

            $threw | Should -BeNullOrEmpty -Because 'a corrupt config must never take the shell down'
            Get-UxConfig -Path 'theme' | Should -Be 'ascii' -Because 'the defaults win when the file is unusable'
            Get-UxConfig -Path 'git.cacheMs' | Should -Be 2000

            $badPath = $script:ConfigPath + '.bad'
            Test-Path -LiteralPath $badPath | Should -BeTrue
            Test-Path -LiteralPath $script:ConfigPath | Should -BeFalse -Because 'the file is moved, not copied'

            $warnings.Count | Should -BeGreaterThan 0 -Because 'the user is told once, instead of silently losing settings'
            ($warnings -join ' ') | Should -Match 'config\.json'
            ($warnings -join ' ') | Should -Match 'defaults'
        }

        It 'treats valid JSON that is not an object as unusable' {
            script:Write-UxTestConfig -Path $script:ConfigPath -Text '[1, 2, 3]'
            $warnings = script:Get-UxTestWarnings -Source @(Initialize-UxConfig 3>&1)

            Get-UxConfig -Path 'theme' | Should -Be 'ascii'
            Test-Path -LiteralPath ($script:ConfigPath + '.bad') | Should -BeTrue
            Test-Path -LiteralPath $script:ConfigPath | Should -BeFalse
            $warnings.Count | Should -BeGreaterThan 0
        }

        It 'uses defaults for an empty file without renaming it' {
            script:Write-UxTestConfig -Path $script:ConfigPath -Text ''
            $threw = ''
            try { $null = Initialize-UxConfig } catch { $threw = [string]$_.Exception.Message }

            $threw | Should -BeNullOrEmpty
            Get-UxConfig -Path 'theme' | Should -Be 'ascii'
            Get-UxConfig -Path 'git.cacheMs' | Should -Be 2000
            Test-Path -LiteralPath $script:ConfigPath | Should -BeTrue -Because 'an empty file is not corrupt, it is just empty'
            Test-Path -LiteralPath ($script:ConfigPath + '.bad') | Should -BeFalse
        }

        It 'uses defaults for a whitespace-only file' {
            script:Write-UxTestConfig -Path $script:ConfigPath -Text ("   `n`n`t")
            $null = Initialize-UxConfig

            Get-UxConfig -Path 'theme' | Should -Be 'ascii'
            Test-Path -LiteralPath $script:ConfigPath | Should -BeTrue
        }
    }

    Describe 'Config: schema version gate' {

        It 'refuses an unknown schema version with a message and keeps the file' {
            $body = '{"version": 999, "theme": "classic"}'
            script:Write-UxTestConfig -Path $script:ConfigPath -Text $body

            $threw = ''
            $warnings = @()
            try {
                $warnings = script:Get-UxTestWarnings -Source @(Initialize-UxConfig 3>&1)
            }
            catch {
                $threw = [string]$_.Exception.Message
            }

            $threw | Should -BeNullOrEmpty
            Get-UxConfig -Path 'theme' | Should -Be 'ascii' -Because 'a future schema is not coerced into this build'
            ($warnings -join ' ') | Should -Match 'unsupported version'
            ($warnings -join ' ') | Should -Match '999'
            Test-Path -LiteralPath $script:ConfigPath | Should -BeTrue -Because 'the user must be able to fix the file'
            ([string](Get-Content -LiteralPath $script:ConfigPath -Raw)) | Should -Match '999'
            Test-Path -LiteralPath ($script:ConfigPath + '.bad') | Should -BeFalse
        }

        It 'accepts the supported version written as a string' {
            script:Write-UxTestConfig -Path $script:ConfigPath -Text '{"version": "1", "theme": "classic"}'
            $null = Initialize-UxConfig

            Get-UxConfig -Path 'theme' | Should -Be 'classic'
            Get-UxConfig -Path 'version' | Should -Be 1
        }
    }

    Describe 'Config: write round-trip' {

        It 'writes a dotted key back without truncating the nested objects' {
            $null = Initialize-UxConfig

            (Set-UxConfig -Path 'git.cacheMs' -Value 3000) | Should -BeTrue
            Get-UxConfig -Path 'git.cacheMs' | Should -Be 3000
            (Get-UxConfig -Path 'git.cacheMs') -is [int] | Should -BeTrue -Because 'the value is coerced to the schema type'

            Test-Path -LiteralPath $script:ConfigPath | Should -BeTrue
            $text = [string](Get-Content -LiteralPath $script:ConfigPath -Raw)
            $text | Should -Not -Match 'System\.Collections' -Because 'ConvertTo-Json -Depth 2 would replace nested objects with that string'
            $text | Should -Match 'cacheMs'

            $onDisk = $text | ConvertFrom-Json
            $onDisk.version | Should -Be 1
            $onDisk.git.cacheMs | Should -Be 3000
            $onDisk.git.slowThresholdMs | Should -Be 250 -Because 'sibling keys inside the same nested object must survive the write'
            $onDisk.git.maxDepth | Should -Be 40
            $onDisk.prompt.symbol | Should -Be '$'
            $onDisk.ui.banner | Should -BeTrue

            $reloaded = Read-UxConfigFile -Path $script:ConfigPath
            $reloaded['git']['cacheMs'] | Should -Be 3000 -Because 'a fresh session must read back what this one wrote'
            $reloaded['theme'] | Should -Be 'ascii'

            @(Get-ChildItem -LiteralPath $script:InstallDir -Filter '*.tmp.*' -ErrorAction SilentlyContinue).Count |
                Should -Be 0 -Because 'the temp file is moved into place, never left behind'
        }

        It 'coerces a string value to the documented schema type' {
            $null = Initialize-UxConfig

            (Set-UxConfig -Path 'ui.banner' -Value 'false') | Should -BeTrue
            (Get-UxConfig -Path 'ui.banner') -is [bool] | Should -BeTrue -Because '"ux config set ui.banner false" must not store the string'
            Get-UxConfig -Path 'ui.banner' | Should -BeFalse

            $onDisk = ([string](Get-Content -LiteralPath $script:ConfigPath -Raw)) | ConvertFrom-Json
            $onDisk.ui.banner | Should -BeFalse
        }
    }

    Describe 'Env overrides' {

        It 'lets UX_INSTALL_DIR win over $HOME' {
            $env:UX_INSTALL_DIR | Should -Be $script:InstallDir
            Get-UxInstallDir | Should -Be $script:InstallDir -Because 'the environment override is the documented first choice'

            script:Set-UxTestEnv -Name 'UX_INSTALL_DIR' -Value $null
            $installRoot = Join-Path (Get-UxHome) '.unix-powershell'
            Get-UxInstallDir | Should -Be $installRoot -Because 'the default install root is <home>/.unix-powershell'
            (Get-UxConfigPath) | Should -Be (Join-Path $installRoot 'config.json') -Because 'the config lives inside the install root, whatever the path separator is'
        }

        It 'refuses to let a config.json key redirect the install root' {
            # Regression guard: config.json lives INSIDE the install dir, so honouring an
            # "installDir" key made path resolution circular and turned `ux uninstall`
            # (a recursive delete of this path) into a delete of whatever the file named.
            $global:Ux['Config']['installDir'] = '/nonexistent/from-config'
            script:Set-UxTestEnv -Name 'UX_INSTALL_DIR' -Value $null

            $installRoot = Join-Path (Get-UxHome) '.unix-powershell'
            Get-UxInstallDir | Should -Be $installRoot -Because 'a config key must never choose the directory that the config file itself lives in'
            Get-UxInstallDir | Should -Not -Be '/nonexistent/from-config'

            $global:Ux['Config'].Remove('installDir')
        }

        It 'does not load the profile at all when UX_DISABLE=1' {
            # The probe dot-sources profile/profile.ps1 in a child process: profile.ps1
            # mutates $global:Ux, sets $global:UxLoaded and removes shadowing aliases, so
            # running it in this session would leak into every later test file.
            script:Set-UxTestEnv -Name 'UX_DISABLE' -Value '1'
            script:Set-UxTestEnv -Name 'UX_QUIET' -Value '1'
            $probe = script:Invoke-LoadProbe -StrictMode '0'

            $probe.Payload | Should -Not -BeNullOrEmpty -Because ('the probe must print its result: ' + (script:Get-ProbeText $probe))
            $probe.Payload.Threw | Should -BeNullOrEmpty
            $probe.Payload.UxLoaded | Should -BeFalse -Because '$global:UxLoaded is the loader''s own "I ran" flag'
            $probe.Payload.UxKeyCount | Should -Be 0 -Because 'a disabled profile defines no state at all'
            script:Get-ProbeText $probe | Should -Not -Match 'load failed'
        }

        It 'loads silently when UX_QUIET=1' {
            # With UX_QUIET=1 the banner branch is skipped before Test-UxInteractive is even
            # consulted. A non-interactive host is silent too, so this asserts the visible
            # contract (no output at load) rather than the banner text, which is only
            # reachable in an interactive console (test/WINDOWS-CHECKLIST.md).
            script:Set-UxTestEnv -Name 'UX_QUIET' -Value '1'
            $probe = script:Invoke-LoadProbe -StrictMode '0'

            $probe.Payload.UxLoaded | Should -BeTrue -Because 'quiet only suppresses output, it must not skip the load'
            $noise = @()
            foreach ($line in @($probe.Lines)) {
                $text = [string]$line
                if ($text -eq '') { continue }
                if ($text.StartsWith('UXPROBE:')) { continue }
                $noise += $text
            }
            ($noise -join ' | ') | Should -Be '' -Because 'a quiet profile writes nothing into the user session'
        }
    }

    Describe 'Capability probe' {

        It 'exposes every documented key with the documented type' {
            $caps = Initialize-UxCaps

            foreach ($key in @('Vt', 'Color', 'Git', 'GitVersion', 'LanguageMode', 'PSEdition', 'PSVersion')) {
                $caps.ContainsKey($key) | Should -BeTrue -Because ('ux doctor and the prompt read Caps.' + $key)
            }
            $caps['Vt'] -is [bool] | Should -BeTrue
            $caps['Color'] -is [bool] | Should -BeTrue
            $caps['Git'] -is [bool] | Should -BeTrue

            [string]$caps['LanguageMode'] | Should -Not -BeNullOrEmpty -Because 'CLM detection depends on it'
            [string]$caps['PSEdition'] | Should -Not -BeNullOrEmpty

            # Stored as a string (the schema) but it must be usable as a version.
            [string]$caps['PSVersion'] | Should -Not -BeNullOrEmpty
            $asVersion = $caps['PSVersion'] -as [version]
            $null -ne $asVersion | Should -BeTrue -Because 'the value is parsed as a version by callers'
            $asVersion.Major | Should -Be ([int]$PSVersionTable.PSVersion.Major)

            ($global:Ux['Caps']) -is [hashtable] | Should -BeTrue -Because 'Initialize-UxCaps must publish the probe into $global:Ux.Caps'
            $global:Ux['Caps']['Vt'] -is [bool] | Should -BeTrue
        }

        It 'honours the documented VT environment markers' {
            script:Set-UxTestEnv -Name 'WT_SESSION' -Value 'ux-test-session'
            $caps = Get-UxCaps

            $caps['Vt'] | Should -BeTrue -Because 'WT_SESSION is a documented VT marker'
            $caps['Color'] -is [bool] | Should -BeTrue
        }

        It 'turns colour off when UX_NO_COLOR=1 but leaves VT detection alone' {
            script:Set-UxTestEnv -Name 'WT_SESSION' -Value 'ux-test-session'
            script:Set-UxTestEnv -Name 'UX_NO_COLOR' -Value '1'
            $caps = Get-UxCaps

            $caps['Vt'] | Should -BeTrue
            $caps['Color'] | Should -BeFalse -Because 'UX_NO_COLOR=1 must suppress colour'
        }

        It 'completes when a config read throws inside the probe' {
            # The probe reads ui.color through Get-UxConfig; that call is inside a try/catch
            # on purpose (a broken config must not break the prompt). WT_SESSION forces the
            # VT branch, so the colour branch - and therefore the guarded config read - is
            # always reached, on every host.
            script:Set-UxTestEnv -Name 'WT_SESSION' -Value 'ux-test-session'
            Mock Get-UxConfig { throw 'boom-from-config' }

            $directThrew = $false
            try { $null = Get-UxConfig -Path 'ui.color' } catch { $directThrew = $true }
            $directThrew | Should -BeTrue -Because 'the mock must really be active for this test to mean anything'

            $threw = ''
            $caps = $null
            try { $caps = Get-UxCaps } catch { $threw = [string]$_.Exception.Message }
            $threw | Should -BeNullOrEmpty
            @($caps.Keys).Count | Should -Be 7 -Because 'a degraded probe still returns the full shape'
            $caps['Color'] -is [bool] | Should -BeTrue
        }

        It 'tolerates a host UI object without SupportsVirtualTerminal (skipped everywhere: needs a real non-console host; see the comment)' -Skip:($true) {
            # SKIPPED: $Host is a read-only automatic variable, so a host UI without the
            # SupportsVirtualTerminal property cannot be constructed in-process without
            # Add-Type (banned by PLAN.md success criterion 7), and the ISE / remote-host
            # case only exists on Windows. The property-absence branch is
            #   $ui.PSObject.Properties['SupportsVirtualTerminal'] -eq $null
            # and it is covered on the Windows box by test/WINDOWS-CHECKLIST.md item 3.
            $true | Should -BeTrue
        }

        It 'keeps a git version that a previous probe already discovered' {
            $global:Ux['Caps'] = @{
                Vt           = $true
                Color        = $true
                Git          = $true
                GitVersion   = '2.43.0'
                LanguageMode = 'FullLanguage'
                PSEdition    = 'Desktop'
                PSVersion    = '5.1.19041.1'
            }
            $caps = Initialize-UxCaps

            $caps['GitVersion'] | Should -Be '2.43.0' -Because 're-probing must not throw away the one-process `git --version` result'
        }
    }

    Describe 'Shadowed commands (alias snapshot and restore)' {

        It 'records and removes an alias that shadows a wrapper name' {
            # Remove-UxShadowedCommands reads the hardcoded wrapper list from $global:Ux, so
            # the probe names are swapped in temporarily instead of shadowing a real
            # command (which would break the rest of the session on Windows).
            $global:Ux['WrapperNames'] = @('zzshadowalias')
            $global:Ux['ShadowExtra'] = @()
            $global:Ux['AliasBackup'] = @()
            Set-Alias -Name zzshadowalias -Value Write-Output -Scope Global

            Remove-UxShadowedCommands

            Get-Alias -Name zzshadowalias -ErrorAction SilentlyContinue | Should -BeNullOrEmpty -Because 'the alias would win over the wrapper function'
            $entries = @($global:Ux['AliasBackup'])
            $entries.Count | Should -Be 1
            $entries[0]['CommandType'] | Should -Be 'Alias'
            $entries[0]['Name'] | Should -Be 'zzshadowalias'
            $entries[0]['Definition'] | Should -Be 'Write-Output'

            Restore-UxShadowedCommands
            $restored = Get-Alias -Name zzshadowalias -ErrorAction SilentlyContinue
            $restored | Should -Not -BeNullOrEmpty -Because 'ux restore-aliases replays the snapshot'
            $restored.Definition | Should -Be 'Write-Output'
        }

        It 'leaves aliases that are not on the wrapper list alone' {
            $global:Ux['WrapperNames'] = @('zzshadowalias')
            $global:Ux['ShadowExtra'] = @()
            $global:Ux['AliasBackup'] = @()
            Set-Alias -Name zzshadowalias -Value Write-Output -Scope Global
            Set-Alias -Name zzbystander -Value Get-Date -Scope Global

            Remove-UxShadowedCommands

            $bystander = Get-Alias -Name zzbystander -ErrorAction SilentlyContinue
            $bystander | Should -Not -BeNullOrEmpty
            $bystander.Definition | Should -Be 'Get-Date'
            @($global:Ux['AliasBackup']).Count | Should -Be 1
        }

        It 'snapshots and removes a shadowing function (the stock-Windows mkdir case)' {
            # On Windows PowerShell 5.1 mkdir/md/rd/rmdir resolve to FUNCTIONS, so the alias
            # sweep is not enough. lib/00-core.ps1 only asks Get-Command for those names
            # when $env:OS is Windows_NT; both the decision and the removal path
            # (Function:\<name>) behave the same on every platform, so the switch is set
            # here on purpose instead of leaving the branch untested on Linux CI.
            $previous = Get-Command -Name 'mkdir' -CommandType Function -ErrorAction SilentlyContinue
            if ($null -ne $previous) { $script:SavedMkdir = $previous.ScriptBlock }
            else { $script:SavedMkdir = $null }
            $script:MkdirProbeActive = $true

            function global:mkdir { return 'fake-mkdir' }
            $global:Ux['WrapperNames'] = @('mkdir')
            $global:Ux['ShadowExtra'] = @()
            $global:Ux['AliasBackup'] = @()

            $savedOs = $env:OS
            try {
                $env:OS = 'Windows_NT'
                Remove-UxShadowedCommands
            }
            finally {
                $env:OS = $savedOs
            }

            Get-Command -Name 'mkdir' -CommandType Function -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
            $entries = @($global:Ux['AliasBackup'])
            $entries.Count | Should -Be 1
            $entries[0]['CommandType'] | Should -Be 'Function'
            $entries[0]['Name'] | Should -Be 'mkdir'
            ([string]$entries[0]['Definition']) | Should -Match 'fake-mkdir'
            $entries[0]['ScriptBlock'] | Should -Not -BeNullOrEmpty -Because 'a function is only restorable through its script block'

            Restore-UxShadowedCommands
            Get-Command -Name 'mkdir' -CommandType Function -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
            (& mkdir) | Should -Be 'fake-mkdir'
        }

        It 'merges repeated snapshots instead of duplicating entries' {
            $global:Ux['WrapperNames'] = @('zzshadowalias2')
            $global:Ux['ShadowExtra'] = @()
            $global:Ux['AliasBackup'] = @()

            Set-Alias -Name zzshadowalias2 -Value Write-Output -Scope Global
            Remove-UxShadowedCommands
            Set-Alias -Name zzshadowalias2 -Value Write-Output -Scope Global
            Remove-UxShadowedCommands

            @($global:Ux['AliasBackup']).Count | Should -Be 1 -Because 'a reload must not grow the snapshot without bound'
        }

        It 'is a no-op without a usable $global:Ux state' {
            $global:Ux = $null
            $threw = ''
            try {
                Remove-UxShadowedCommands
                Restore-UxShadowedCommands
            }
            catch {
                $threw = [string]$_.Exception.Message
            }
            $threw | Should -BeNullOrEmpty
        }
    }

    Describe 'Strict mode' {

        It 'loads the whole profile under Set-StrictMode -Version Latest' {
            script:Set-UxTestEnv -Name 'UX_QUIET' -Value '1'
            $baseline = script:Invoke-LoadProbe -StrictMode '0'
            $strict = script:Invoke-LoadProbe -StrictMode '1'

            $strict.Payload | Should -Not -BeNullOrEmpty -Because ('the probe must print its result: ' + (script:Get-ProbeText $strict))
            $strict.Payload.Threw | Should -BeNullOrEmpty -Because 'Set-StrictMode -Version Latest in a user profile must not break the load'
            $strict.Payload.UxLoaded | Should -BeTrue
            $strict.Payload.UxKeyCount | Should -BeGreaterThan 10 -Because '$global:Ux must be populated'
            $strict.Payload.HasConfig | Should -BeTrue -Because 'step 2 of the load order is Initialize-UxConfig'
            $strict.Payload.HasCaps | Should -BeTrue -Because 'step 3 of the load order is Initialize-UxCaps'
            script:Get-ProbeText $strict | Should -Not -Match 'load failed'
            script:Get-ProbeText $strict | Should -Not -Match 'failed to load'

            # Strict mode must not introduce a failure the normal load does not already
            # have. (Both loads record the suppressed Get-Alias / Get-Variable lookups in
            # $Error; those are benign and identical in both runs.)
            $baselineIds = @($baseline.Payload.ErrorIds)
            $strictOnly = @()
            foreach ($id in @($strict.Payload.ErrorIds)) {
                if ($baselineIds -notcontains $id) { $strictOnly += $id }
            }
            ($strictOnly -join ', ') | Should -Be '' -Because 'a strict-mode-only error means a lib variable or property is read before it is set'

            $strictIds = (@($strict.Payload.ErrorIds) -join ' ')
            $strictIds | Should -Not -Match 'Strict'
        }

        It 'loads the core and tokenizer files directly under strict mode' {
            $script:StrictStateOk = $false
            $threw = ''
            try {
                & {
                    Set-StrictMode -Version Latest
                    . $script:CorePath
                    . $script:ArgsPath
                    $null = Get-UxCaps
                    $null = ConvertFrom-UxArgv -Tokens @('-rf', 'file')
                    $null = Get-UxConfig -Path 'theme'
                    $null = Get-UxDefaultConfig
                    $null = ConvertTo-UxHashtable -InputObject ([pscustomobject]@{ a = [pscustomobject]@{ b = 1 } })

                    # Assert from inside the strict scope: it is this scope's rules that
                    # would bite, not the caller's.
                    $state = Get-Variable -Name 'Ux' -Scope Global -ErrorAction SilentlyContinue
                    if ($null -ne $state -and $state.Value -is [hashtable]) {
                        if ($state.Value.ContainsKey('Config') -and $state.Value['Config'] -is [hashtable]) {
                            $script:StrictStateOk = $true
                        }
                    }
                }
            }
            catch {
                $threw = [string]$_.Exception.Message
            }
            $threw | Should -BeNullOrEmpty
            $script:StrictStateOk | Should -BeTrue -Because 'the strict-mode load must leave $global:Ux populated and usable'
        }
    }

    Describe '$global:Ux shape' {

        It 'contains every documented key with the documented type' {
            $state = $global:Ux
            foreach ($key in @(
                    'Version', 'Esc', 'Home', 'InstallDir', 'Config', 'Caps', 'LoadMs',
                    'GitCache', 'AliasBackup', 'LastExit', 'LastOk', 'WrapperNames',
                    'ShadowExtra', 'ProfileBlockVersion'
                )) {
                $state.ContainsKey($key) | Should -BeTrue -Because ('the prompt and ux doctor read $global:Ux.' + $key)
            }

            [string]$state['Version'] | Should -Match '^[0-9]+\.[0-9]+\.[0-9]+$'
            [string]$state['Esc'] | Should -Be ([string][char]27)
            [string]$state['Home'] | Should -Not -BeNullOrEmpty
            $state['Config'] -is [hashtable] | Should -BeTrue
            $state['Caps'] -is [hashtable] | Should -BeTrue
            $state['GitCache'] -is [hashtable] | Should -BeTrue
            $state['LastExit'] -is [int] | Should -BeTrue
            $state['LastOk'] -is [bool] | Should -BeTrue
            $state['LoadMs'] -is [int] | Should -BeTrue
            @($state['AliasBackup']).GetType().Name | Should -Match 'Array|Collection|Object'

            $wrappers = @($state['WrapperNames'])
            $wrappers -contains 'rm' | Should -BeTrue
            $wrappers -contains 'ls' | Should -BeTrue
            $wrappers -contains 'grep' | Should -BeTrue
            @($state['ShadowExtra']) -contains 'curl' | Should -BeTrue -Because 'curl/wget/type are snapshotted even though they are not wrapped'
        }
    }

    Describe 'Tokenizer (ConvertFrom-UxArgv)' {

        It 'returns the four documented keys and never throws' {
            $threw = ''
            $parsed = $null
            try { $parsed = ConvertFrom-UxArgv -Tokens @() } catch { $threw = [string]$_.Exception.Message }
            $threw | Should -BeNullOrEmpty

            $parsed -is [hashtable] | Should -BeTrue
            foreach ($key in @('Flags', 'Values', 'Positional', 'Problems')) {
                $parsed.ContainsKey($key) | Should -BeTrue -Because ('every wrapper reads .' + $key)
            }
            @($parsed['Positional']).Count | Should -Be 0
            @($parsed['Problems']).Count | Should -Be 0
            $parsed['Flags'].PSObject.Methods['ContainsKey'] | Should -Not -BeNullOrEmpty -Because '[ordered] only exposes Contains(), so the tokenizer adds ContainsKey'
            ($parsed['Flags'].ContainsKey('r')) | Should -BeFalse
        }

        It 'expands a flag cluster into single flags' {
            $parsed = ConvertFrom-UxArgv -Tokens @('-rf', 'file.txt')
            @($parsed['Flags'].Keys) -join ',' | Should -Be 'r,f'
            @($parsed['Positional']) -join ',' | Should -Be 'file.txt'
            @($parsed['Problems']).Count | Should -Be 0
            $parsed['Flags'].ContainsKey('r') | Should -BeTrue
        }

        It 'consumes the value of a value flag' {
            $parsed = ConvertFrom-UxArgv -Tokens @('-n', '3', 'file.txt') -ValueFlags @('n')
            $parsed['Values']['n'] | Should -Be '3'
            @($parsed['Positional']) -join ',' | Should -Be 'file.txt'
            @($parsed['Flags'].Keys).Count | Should -Be 0
            @($parsed['Problems']).Count | Should -Be 0
        }

        It 'consumes a whole-token value flag and a whole-token alias' {
            $parsed = ConvertFrom-UxArgv -Tokens @('-name', '*.ps1', 'dir') -ValueFlags @('name')
            $parsed['Values']['name'] | Should -Be '*.ps1'
            @($parsed['Positional']) -join ',' | Should -Be 'dir'

            $mapped = ConvertFrom-UxArgv -Tokens @('--recursive', 'dir') -AliasMap @{ recursive = 'r' }
            $mapped['Flags'].ContainsKey('r') | Should -BeTrue -Because '--recursive maps to the short form r'
            @($mapped['Positional']) -join ',' | Should -Be 'dir'
            @($mapped['Problems']).Count | Should -Be 0
        }

        It 'treats -- as end-of-flags' {
            $parsed = ConvertFrom-UxArgv -Tokens @('-r', '--', '-weird', '--also')
            $parsed['Flags'].ContainsKey('r') | Should -BeTrue
            @($parsed['Positional']) -join ',' | Should -Be '-weird,--also'
            @($parsed['Flags'].Keys).Count | Should -Be 1
        }

        It 'treats a bare - as a literal filename' {
            $parsed = ConvertFrom-UxArgv -Tokens @('cat', '-', 'out.txt')
            @($parsed['Positional']) -join ',' | Should -Be 'cat,-,out.txt'
            @($parsed['Flags'].Keys).Count | Should -Be 0
        }

        It 'splits --long=value into Values and --flag into Flags' {
            $parsed = ConvertFrom-UxArgv -Tokens @('--long=value', '--flag', 'x')
            $parsed['Values']['long'] | Should -Be 'value'
            $parsed['Flags'].ContainsKey('flag') | Should -BeTrue
            @($parsed['Positional']) -join ',' | Should -Be 'x'
        }

        It 'treats an all-digit short token as a flag' {
            $parsed = ConvertFrom-UxArgv -Tokens @('-9', '1234')
            $parsed['Flags'].ContainsKey('9') | Should -BeTrue -Because 'kill -9 PID must not lose the signal'
            @($parsed['Positional']) -join ',' | Should -Be '1234'

            $fifteen = ConvertFrom-UxArgv -Tokens @('-15', '4321')
            $fifteen['Flags'].ContainsKey('15') | Should -BeTrue
        }

        It 'reports a missing value-flag argument without throwing' {
            $parsed = ConvertFrom-UxArgv -Tokens @('cat', '-n') -ValueFlags @('n')
            @($parsed['Problems']).Count | Should -Be 1
            ([string](@($parsed['Problems'])[0])) | Should -Match 'requires a value'
            @($parsed['Positional']) -join ',' | Should -Be 'cat' -Because 'a malformed flag must not swallow the positional'
        }

        It 'records an unknown flag permissively instead of failing' {
            $parsed = ConvertFrom-UxArgv -Tokens @('-Z', 'file')
            $parsed['Flags'].ContainsKey('Z') | Should -BeTrue
            @($parsed['Problems']).Count | Should -Be 0 -Because 'unknown flags are permissive by design'
        }
    }
}
