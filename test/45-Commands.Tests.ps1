#Requires -Version 5.1
<#
    45-Commands.Tests.ps1 - the ux management command (lib/40-commands.ps1).

    There was no automated coverage of lib/40-commands.ps1 before this file. It drives ux
    IN-PROCESS against a throwaway install layout under $TestDrive: the profile is loaded
    once in BeforeAll from a copy of profile/ and lib/, so the config file, the .disabled
    marker and every file ux writes live inside that copy. $env:UX_INSTALL_DIR always points
    there, the two uninstall tests also point $PROFILE at files under $TestDrive, and the
    load-time aliases the snapshot needs are planted explicitly instead of inherited from
    whatever session happens to run the suite.

    Deliberately NOT tested: ux update -Check. It fetches the published manifest over the
    network, and this suite must run offline (the printing-only ux update is covered).
    ux uninstall is only ever exercised through its refusal paths, never against a real
    install: a passing delete test would destroy the fixture or, worse, the user profile.

    Written for Windows PowerShell 5.1 (no pipeline chains, no ternary, no null-conditional
    operators) and Pester 5.
#>

BeforeAll {
    $script:Root = Split-Path -Parent $PSScriptRoot
    if (-not $script:Root) { $script:Root = Split-Path -Parent $MyInvocation.MyCommand.Path }

    # ---- throwaway install layout -------------------------------------------------
    # profile/profile.ps1 resolves the install root from its own $PSScriptRoot, so a copy
    # under $TestDrive is both isolated and realistic.
    $script:InstallDir = Join-Path $TestDrive 'install'
    $null = New-Item -ItemType Directory -Path $script:InstallDir -Force
    foreach ($relative in @('lib', 'profile')) {
        $from = Join-Path $script:Root $relative
        if (Test-Path -LiteralPath $from) {
            Copy-Item -LiteralPath $from -Destination (Join-Path $script:InstallDir $relative) -Recurse -Force
        }
    }
    $entrySource = Join-Path $script:Root 'ux.ps1'
    if (Test-Path -LiteralPath $entrySource) {
        Copy-Item -LiteralPath $entrySource -Destination (Join-Path $script:InstallDir 'ux.ps1') -Force
    }

    $script:EntryPoint = Join-Path (Join-Path $script:InstallDir 'profile') 'profile.ps1'
    $script:ConfigPath = Join-Path $script:InstallDir 'config.json'
    $script:MarkerPath = Join-Path $script:InstallDir '.disabled'
    # manifest.json is deliberately NOT copied: ux verify must FAIL on an install without
    # one, and a copied manifest would make the hash checks depend on the checkout.

    # ---- environment ---------------------------------------------------------------
    $script:SavedInstallDir = $env:UX_INSTALL_DIR
    $script:SavedQuiet = $env:UX_QUIET
    $env:UX_INSTALL_DIR = $script:InstallDir
    # Deterministic: no load banner in the captured output. The CI container has no TERM,
    # but a developer console does, and the banner would land in every assertion.
    $env:UX_QUIET = '1'

    $script:HomeInstallExisted = $false
    if ($HOME) { $script:HomeInstallExisted = Test-Path -LiteralPath (Join-Path $HOME '.unix-powershell') }

    # ---- what must be put back after the suite -------------------------------------
    # The profile is loaded into this session, so a caller that already loaded the real one
    # (a developer running Invoke-Pester from their own shell) must get its own state back.
    $script:HadGlobalUx = $false
    $script:SavedGlobalUx = $null
    $uxVariable = Get-Variable -Name 'Ux' -Scope Global -ErrorAction SilentlyContinue
    if ($null -ne $uxVariable) {
        $script:HadGlobalUx = $true
        $script:SavedGlobalUx = $uxVariable.Value
    }
    $script:HadUxLoaded = $false
    $script:SavedUxLoaded = $null
    $uxLoadedVariable = Get-Variable -Name 'UxLoaded' -Scope Global -ErrorAction SilentlyContinue
    if ($null -ne $uxLoadedVariable) {
        $script:HadUxLoaded = $true
        $script:SavedUxLoaded = $uxLoadedVariable.Value
    }
    $script:SavedLocation = ''
    try { $script:SavedLocation = [string](Get-Location).Path } catch { $script:SavedLocation = '' }

    # The real profile files are normally absent in CI; the isolation test compares them
    # against this snapshot to prove the suite never edits one.
    $script:RealProfileFiles = @{}
    foreach ($path in @([string]$PROFILE.CurrentUserAllHosts, [string]$PROFILE.CurrentUserCurrentHost)) {
        if ($path -eq '') { continue }
        $content = $null
        if (Test-Path -LiteralPath $path) {
            $content = [string](Get-Content -LiteralPath $path -Raw -ErrorAction SilentlyContinue)
        }
        $script:RealProfileFiles[$path] = $content
    }

    # Plant the aliases the load-time snapshot is asserted against. Inheriting the ambient
    # session would make this suite pass or fail depending on who runs it (a shell that
    # already loaded the real profile has no cd alias left to snapshot).
    $null = Set-Alias -Name 'cd' -Value 'Set-Location' -Force -ErrorAction SilentlyContinue
    $null = Set-Alias -Name 'type' -Value 'Get-Content' -Force -ErrorAction SilentlyContinue

    # How many functions this profile defines. `ux reload` must refresh every one of them,
    # so this number is the completeness check for its promotion filter.
    $script:ProfileFunctionNames = @()
    $sourceFiles = @((Join-Path $script:InstallDir 'profile/profile.ps1'))
    foreach ($file in @(Get-ChildItem -LiteralPath (Join-Path $script:InstallDir 'lib') -Filter '*.ps1' -ErrorAction SilentlyContinue)) {
        $sourceFiles += $file.FullName
    }
    foreach ($file in $sourceFiles) {
        if (-not (Test-Path -LiteralPath $file)) { continue }
        foreach ($line in @(Get-Content -LiteralPath $file)) {
            if ($line -match '^\s*function\s+(global:)?([A-Za-z0-9_-]+)') { $script:ProfileFunctionNames += $Matches[2] }
        }
    }
    $script:ProfileFunctionCount = @($script:ProfileFunctionNames | Sort-Object -Unique).Count

    # ---- load the profile once -----------------------------------------------------
    $global:UxLoaded = $false
    . $script:EntryPoint

    $script:UxState = Get-UxState
    $script:UxVersion = '0.1.0'
    if ($null -ne $script:UxState -and $script:UxState.ContainsKey('Version')) {
        $script:UxVersion = [string]$script:UxState['Version']
    }
    $script:LoadAliasBackup = @()
    if ($null -ne $script:UxState -and $script:UxState.ContainsKey('AliasBackup')) {
        $script:LoadAliasBackup = @($script:UxState['AliasBackup'])
    }

    # ---- helpers -------------------------------------------------------------------
    # Runs ux and separates its streams. Write-Host output (the information stream) is
    # folded in with 6>&1; the success stream is kept apart because `ux config path` and
    # `ux doctor -Json` write their machine-readable answer there.
    function script:Invoke-TestUx {
        param([string[]]$Tokens = @())

        # Sentinel: a verb that forgets to set the exit code cannot inherit a stale 0.
        $global:LASTEXITCODE = -1
        $records = @(& { param([string[]]$Inner) ux @Inner 6>&1 } $Tokens)
        $code = $global:LASTEXITCODE

        $lines = @()
        $success = @()
        foreach ($record in $records) {
            $typeName = ''
            try { $typeName = $record.GetType().Name } catch { $typeName = '' }
            try { $lines += [string]$record } catch { $lines += '' }
            if ($typeName -ne 'InformationRecord') { $success += $record }
        }
        return [pscustomobject]@{
            ExitCode = $code
            Lines    = $lines
            Text     = ($lines -join "`n")
            Output   = $success
        }
    }

    # Defines a function that is NOT part of the profile, in this function's own temporary
    # scope, then reloads. The definition is gone when the function returns, so a name that
    # still resolves afterwards was copied into the GLOBAL scope - exactly what `ux reload`
    # must not do for a function that is not the profile's own.
    function script:Invoke-ReloadProbe {
        function ForeignProbeUxTest { 'foreign' }
        $tableSize = @(Get-ChildItem Function: -ErrorAction SilentlyContinue).Count
        $global:LASTEXITCODE = -1
        $lines = @(@(& { ux reload } 6>&1) | ForEach-Object { [string]$_ })
        $code = $global:LASTEXITCODE
        return @{ Lines = $lines; ExitCode = $code; TableSize = $tableSize }
    }
}

AfterAll {
    $env:UX_INSTALL_DIR = $script:SavedInstallDir
    $env:UX_QUIET = $script:SavedQuiet
    $null = Remove-Item -LiteralPath 'Alias:\cd' -Force -ErrorAction SilentlyContinue
    $null = Remove-Item -LiteralPath 'Alias:\type' -Force -ErrorAction SilentlyContinue

    # Hand the caller's session back exactly as it was before this suite touched it.
    if ($script:HadGlobalUx) {
        $global:Ux = $script:SavedGlobalUx
    } else {
        Remove-Variable -Name 'Ux' -Scope Global -ErrorAction SilentlyContinue
    }
    if ($script:HadUxLoaded) {
        $global:UxLoaded = $script:SavedUxLoaded
    } else {
        Remove-Variable -Name 'UxLoaded' -Scope Global -ErrorAction SilentlyContinue
    }
    if ($script:SavedLocation -ne '' -and (Test-Path -LiteralPath $script:SavedLocation)) {
        try { Set-Location -LiteralPath $script:SavedLocation } catch { }
    }
}

Describe 'ux management command (isolated install under TestDrive)' {

    BeforeEach {
        $env:UX_INSTALL_DIR = $script:InstallDir
        $env:UX_QUIET = '1'
        if ($null -ne $script:UxState) {
            $script:UxState['Version'] = $script:UxVersion
            $global:Ux = $script:UxState
        }
        (Get-UxInstallDir) | Should -Be $script:InstallDir -Because 'a test that escaped to the real install directory would be destructive'
    }

    AfterEach {
        # Everything this suite changed lives under $TestDrive; put the rest back.
        $env:UX_INSTALL_DIR = $script:InstallDir
        $env:UX_QUIET = '1'
        foreach ($path in @($script:MarkerPath, $script:ConfigPath)) {
            if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
        }
        $null = Remove-Item -LiteralPath 'Alias:\cd' -Force -ErrorAction SilentlyContinue
        $null = Remove-Item -LiteralPath 'Alias:\type' -Force -ErrorAction SilentlyContinue
        $pwdPath = ''
        try { $pwdPath = [string](Get-Location).Path } catch { $pwdPath = '' }
        if ($pwdPath -ne '' -and -not $pwdPath.StartsWith($TestDrive)) {
            Set-Location -LiteralPath $TestDrive
        }
        if ($null -ne $script:UxState) {
            $script:UxState['Config'] = Get-UxDefaultConfig
            $script:UxState['ConfigLoaded'] = $false
            $script:UxState['Version'] = $script:UxVersion
            $script:UxState['AliasBackup'] = @($script:LoadAliasBackup)
            $global:Ux = $script:UxState
        }
        $global:UxLoaded = $true
    }

    Describe 'usage surface' {
        It 'ux with no arguments prints the usage table and exits 0' {
            $result = script:Invoke-TestUx
            $result.ExitCode | Should -Be 0
            $result.Text.Contains('usage: ux <verb>') | Should -BeTrue
            $result.Text.Contains('exit codes: 0 success, 1 failed check or error, 2 unknown verb') | Should -BeTrue
        }

        It 'ux help documents every verb in the verb table' {
            $result = script:Invoke-TestUx -Tokens @('help')
            $result.ExitCode | Should -Be 0
            @($script:UxVerbs).Count | Should -BeGreaterThan 0 -Because 'the verb table is the single source of truth for ux help'
            $missing = @()
            foreach ($entry in @($script:UxVerbs)) {
                $name = [string]$entry['Verb']
                if (-not $result.Text.Contains($name)) { $missing += $name }
            }
            ($missing -join ', ') | Should -Be '' -Because 'an undocumented verb is invisible to the user'
        }

        It 'treats -Help and -Version like the verbs' {
            $helpFlag = script:Invoke-TestUx -Tokens @('-Help')
            $helpFlag.ExitCode | Should -Be 0
            $helpFlag.Text.Contains('usage: ux <verb>') | Should -BeTrue

            $versionFlag = script:Invoke-TestUx -Tokens @('-Version')
            $versionFlag.ExitCode | Should -Be 0
            $versionFlag.Text.Contains('powershell') | Should -BeTrue
        }

        It 'is a plain function, so dash tokens reach it verbatim' {
            $command = Get-Command -Name 'ux' -ErrorAction SilentlyContinue
            $command | Should -Not -BeNullOrEmpty
            ([string]$command.CommandType) | Should -Be 'Function'
            ([string]$command.ModuleName) | Should -Be '' -Because 'ux is a plain profile function, not a module command that could reject -Json at binding time'
        }
    }

    Describe 'ux version' {
        It 'reports version, host and the resolved paths' {
            $result = script:Invoke-TestUx -Tokens @('version')
            $result.ExitCode | Should -Be 0
            $result.Text.Contains($script:UxVersion) | Should -BeTrue
            $result.Text.Contains('installDir') | Should -BeTrue
            $result.Text.Contains($script:InstallDir) | Should -BeTrue
            $result.Text.Contains($script:ConfigPath) | Should -BeTrue
        }

        It 'also works through a literal call, without the capture helper' {
            # One test calls ux directly so the helper above cannot mask an argv regression.
            $global:LASTEXITCODE = -1
            $lines = @(ux version 6>&1 | ForEach-Object { [string]$_ })
            $global:LASTEXITCODE | Should -Be 0
            (($lines -join "`n").Contains('installDir')) | Should -BeTrue
        }
    }

    Describe 'ux doctor' {
        It 'prints a report and exits 0' {
            $result = script:Invoke-TestUx -Tokens @('doctor')
            $result.ExitCode | Should -Be 0
            $result.Text.Contains('unix-powershell doctor') | Should -BeTrue
            $result.Text.Contains('PowerShellVersion') | Should -BeTrue
            $result.Text.Contains('LanguageMode') | Should -BeTrue
        }

        It 'ux doctor -Json emits one JSON object with the documented keys' {
            $result = script:Invoke-TestUx -Tokens @('doctor', '-Json')
            $result.ExitCode | Should -Be 0
            @($result.Output).Count | Should -Be 1 -Because 'a machine reader must not have to skip extra lines'

            $report = $null
            try { $report = ([string]($result.Output -join "`n")) | ConvertFrom-Json } catch { $report = $null }
            $report | Should -Not -BeNullOrEmpty

            foreach ($key in @('PowerShellVersion', 'LanguageMode', 'InstallDir', 'ConfigPath', 'Theme', 'Vt', 'Color', 'GitPresent', 'LastLoadMs')) {
                $property = $report.PSObject.Properties[$key]
                $property | Should -Not -BeNullOrEmpty -Because ('ux doctor -Json must report ' + $key)
            }
            ([string]$report.InstallDir) | Should -Be $script:InstallDir
        }
    }

    Describe 'ux verify' {
        It 'FAILs when an install directory has no manifest.json' {
            # The installer always writes a manifest into the install dir, so its absence
            # inside a real install means a damaged install - not a "skip".
            $result = script:Invoke-TestUx -Tokens @('verify')
            $result.ExitCode | Should -Be 1
            $result.Text.Contains('verify: FAILED') | Should -BeTrue
            $result.Text.Contains('manifest.json present') | Should -BeTrue
            $result.Text.Contains('SKIP  manifest.json') | Should -BeFalse
        }

        It 'keeps SKIP only for a directory that is not an install, and still exits 1' {
            $bare = Join-Path $TestDrive 'bare-dir'
            $null = New-Item -ItemType Directory -Path $bare -Force
            $env:UX_INSTALL_DIR = $bare

            $result = script:Invoke-TestUx -Tokens @('verify')
            $result.ExitCode | Should -Be 1
            $result.Text.Contains('verify: FAILED') | Should -BeTrue
            $result.Text.Contains('SKIP  manifest.json') | Should -BeTrue
        }

        It 'reports six check lines, so no check can silently disappear' {
            $result = script:Invoke-TestUx -Tokens @('verify')
            $checks = @($result.Lines | Where-Object { $_ -match '^\s+(PASS|FAIL|SKIP)\s' })
            $checks.Count | Should -Be 6
        }
    }

    Describe 'ux theme' {
        It 'theme list shows every built-in theme and marks the current one' {
            $result = script:Invoke-TestUx -Tokens @('theme', 'list')
            $result.ExitCode | Should -Be 0
            @($script:UxThemes).Count | Should -BeGreaterThan 0
            $missing = @()
            foreach ($name in @($script:UxThemes)) {
                if (-not $result.Text.Contains([string]$name)) { $missing += [string]$name }
            }
            ($missing -join ', ') | Should -Be '' -Because 'theme list must document every theme the profile implements'
            $result.Text.Contains('current:') | Should -BeTrue
        }

        It 'theme show reports the current theme and its shape' {
            $result = script:Invoke-TestUx -Tokens @('theme', 'show')
            $result.ExitCode | Should -Be 0
            $result.Text.Contains('theme') | Should -BeTrue
            $result.Text.Contains('shape') | Should -BeTrue
            $result.Text.Contains('override') | Should -BeTrue
        }

        It 'theme set classic persists the choice' {
            $result = script:Invoke-TestUx -Tokens @('theme', 'set', 'classic')
            $result.ExitCode | Should -Be 0
            ([string](Get-UxConfig -Path 'theme' -Default '')) | Should -Be 'classic'
            Test-Path -LiteralPath $script:ConfigPath | Should -BeTrue
            $onDisk = [string](Get-Content -LiteralPath $script:ConfigPath -Raw)
            $onDisk.Contains('classic') | Should -BeTrue -Because 'theme set must persist, not only render'
        }

        It 'theme set refuses an unknown theme' {
            $result = script:Invoke-TestUx -Tokens @('theme', 'set', 'not-a-theme')
            $result.ExitCode | Should -Be 1
            $result.Text.Contains('unknown theme') | Should -BeTrue
        }

        It 'theme set without a name is refused' {
            $result = script:Invoke-TestUx -Tokens @('theme', 'set')
            $result.ExitCode | Should -Be 1
            $result.Text.Contains('a theme name is required') | Should -BeTrue
        }

        It 'theme with no subcommand behaves like list' {
            $result = script:Invoke-TestUx -Tokens @('theme')
            $result.ExitCode | Should -Be 0
            $result.Text.Contains('themes (current:') | Should -BeTrue
        }
    }

    Describe 'ux config' {
        It 'config path prints the config file location' {
            $result = script:Invoke-TestUx -Tokens @('config', 'path')
            $result.ExitCode | Should -Be 0
            ([string]($result.Output -join '')).Trim() | Should -Be $script:ConfigPath
        }

        It 'config get reports the effective value and the schema default' {
            $defaults = Get-UxDefaultConfig
            $expectedCache = [string]$defaults['git']['cacheMs']
            $result = script:Invoke-TestUx -Tokens @('config', 'get', 'git.cacheMs')
            $result.ExitCode | Should -Be 0
            $result.Text.Contains('git.cacheMs = ' + $expectedCache + ' (default ' + $expectedCache + ')') | Should -BeTrue
        }

        It 'config get refuses a key that is not in the schema' {
            $result = script:Invoke-TestUx -Tokens @('config', 'get', 'no.such.key')
            $result.ExitCode | Should -Be 1
            $result.Text.Contains('<unset>') | Should -BeTrue
        }

        It 'config get and config set refuse missing arguments' {
            (script:Invoke-TestUx -Tokens @('config', 'get')).ExitCode | Should -Be 1
            (script:Invoke-TestUx -Tokens @('config', 'set')).ExitCode | Should -Be 1
            (script:Invoke-TestUx -Tokens @('config', 'set', 'git.cacheMs')).ExitCode | Should -Be 1
        }

        It 'config set round-trips and keeps the on-disk JSON nested' {
            $result = script:Invoke-TestUx -Tokens @('config', 'set', 'git.cacheMs', '3000')
            $result.ExitCode | Should -Be 0
            ([int](Get-UxConfig -Path 'git.cacheMs' -Default 0)) | Should -Be 3000

            $disk = $null
            try { $disk = ([string](Get-Content -LiteralPath $script:ConfigPath -Raw)) | ConvertFrom-Json } catch { $disk = $null }
            $disk | Should -Not -BeNullOrEmpty
            ([int]$disk.git.cacheMs) | Should -Be 3000
            # A too-shallow ConvertTo-Json stores nested tables as the string
            # 'System.Collections.Hashtable'; the nested keys must still be readable.
            $defaults = Get-UxDefaultConfig
            ([string]$disk.prompt.pathStyle) | Should -Be ([string]$defaults['prompt']['pathStyle'])
            ([string]$disk.theme) | Should -Be ([string]$defaults['theme'])
            ([bool]$disk.prompt.exitCode) | Should -BeTrue
        }

        It 'config set writes a key that is not in the schema and says so' {
            $result = script:Invoke-TestUx -Tokens @('config', 'set', 'bogus.key', 'hello')
            $result.ExitCode | Should -Be 0
            $result.Text.Contains('is not in the schema') | Should -BeTrue -Because 'an unknown key is written, but the user is told'
            ([string](Get-UxConfig -Path 'bogus.key' -Default '')) | Should -Be 'hello'
        }

        It 'config set coerces booleans instead of storing the word' {
            $result = script:Invoke-TestUx -Tokens @('config', 'set', 'ui.banner', 'false')
            $result.ExitCode | Should -Be 0
            (Get-UxConfig -Path 'ui.banner' -Default $true) | Should -BeFalse
        }

        It 'config set refuses an integer that does not fit in 32 bits' {
            $result = script:Invoke-TestUx -Tokens @('config', 'set', 'git.cacheMs', '99999999999')
            $result.ExitCode | Should -Be 1
            $result.Text.Contains('expects an integer') | Should -BeTrue
        }

        It 'config with no subcommand prints usage' {
            $result = script:Invoke-TestUx -Tokens @('config')
            $result.ExitCode | Should -Be 0
            $result.Text.Contains('ux config path') | Should -BeTrue
        }
    }

    Describe 'ux enable and disable' {
        It 'disable creates the marker and enable removes it' {
            $disabled = script:Invoke-TestUx -Tokens @('disable')
            $disabled.ExitCode | Should -Be 0
            Test-Path -LiteralPath $script:MarkerPath | Should -BeTrue

            $enabled = script:Invoke-TestUx -Tokens @('enable')
            $enabled.ExitCode | Should -Be 0
            Test-Path -LiteralPath $script:MarkerPath | Should -BeFalse
        }

        It 'enable without a marker reports that it is already enabled' {
            $result = script:Invoke-TestUx -Tokens @('enable')
            $result.ExitCode | Should -Be 0
            $result.Text.Contains('already enabled') | Should -BeTrue
        }
    }

    Describe 'ux restore-aliases' {
        It 'replays the load-time snapshot' {
            $before = @($script:UxState['AliasBackup'])
            $before.Count | Should -BeGreaterThan 0 -Because 'a loaded session has at least one shadowed command to restore'

            $result = script:Invoke-TestUx -Tokens @('restore-aliases')
            $result.ExitCode | Should -Be 0
            $result.Text.Contains('replayed') | Should -BeTrue
            $result.Text.Contains('replayed 0 ') | Should -BeFalse
            (Get-Alias -Name 'cd' -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty -Because 'replaying the snapshot must bring the original alias back'
        }
    }

    Describe 'ux reload' {
        It 'carries the alias snapshot across the reload' {
            $before = @($script:UxState['AliasBackup'])
            $before.Count | Should -BeGreaterThan 0

            $result = script:Invoke-TestUx -Tokens @('reload')
            $result.ExitCode | Should -Be 0
            $result.Text.Contains('reload: ok') | Should -BeTrue
            $result.Text.Contains('carried over') | Should -BeTrue

            $after = @()
            if ($null -ne $global:Ux -and $global:Ux.ContainsKey('AliasBackup')) { $after = @($global:Ux['AliasBackup']) }
            $after.Count | Should -BeGreaterThan 0 -Because 'a reload used to wipe the snapshot and leave restore-aliases with nothing to replay'

            $missing = @()
            foreach ($entry in $before) {
                $name = [string]$entry['Name']
                $commandType = [string]$entry['CommandType']
                $found = $false
                foreach ($candidate in $after) {
                    if ([string]$candidate['Name'] -eq $name -and [string]$candidate['CommandType'] -eq $commandType) {
                        $found = $true
                        break
                    }
                }
                if (-not $found) { $missing += $name }
            }
            ($missing -join ', ') | Should -Be '' -Because 'every entry of the load-time snapshot must survive a reload'

            $restored = script:Invoke-TestUx -Tokens @('restore-aliases')
            $restored.ExitCode | Should -Be 0
            $restored.Text.Contains('replayed 0 ') | Should -BeFalse
            (Get-Alias -Name 'cd' -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty -Because 'after a reload the user must still be able to get the original alias back'
        }

        It 'promotes only the profile own commands into the global scope' {
            $probe = script:Invoke-ReloadProbe
            $probe['ExitCode'] | Should -Be 0
            $text = (@($probe['Lines']) -join "`n")
            $text.Contains('reload: ok') | Should -BeTrue

            $promoted = -1
            if ($text -match 'reload: ok \((\d+) commands refreshed') { $promoted = [int]$Matches[1] }
            # Every function the profile defines must be refreshed: a filter that forgets a
            # helper family would leave stale scriptblocks behind, and the count would drop.
            $promoted | Should -Be $script:ProfileFunctionCount -Because 'a reload must refresh every function the profile defines'
            $promoted | Should -BeLessThan ([int]$probe['TableSize']) -Because 'the reported number must describe this profile, not the whole function table'

            (Get-Command -Name 'ForeignProbeUxTest' -CommandType Function -ErrorAction SilentlyContinue) | Should -BeNullOrEmpty -Because 'copying a foreign function into the global scope would shadow a module for the rest of the session'
            (Get-Command -Name 'ux' -CommandType Function -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty
        }

        It 'reports a failed entry point without losing the snapshot' {
            $broken = Join-Path $TestDrive 'broken-install'
            $null = New-Item -ItemType Directory -Path (Join-Path $broken 'profile') -Force
            Set-Content -LiteralPath (Join-Path $broken 'profile/profile.ps1') -Value "throw 'this profile is broken'" -Encoding UTF8
            $env:UX_INSTALL_DIR = $broken
            $before = @($script:UxState['AliasBackup'])
            $before.Count | Should -BeGreaterThan 0

            $result = script:Invoke-TestUx -Tokens @('reload')
            $result.ExitCode | Should -Be 1
            $result.Text.Contains('the entry point failed') | Should -BeTrue
            $result.Text.Contains('carried over') | Should -BeTrue
            $global:Ux | Should -Not -BeNullOrEmpty -Because 'a failed reload must leave the session state intact'
        }
    }

    Describe 'ux update' {
        It 'prints a pasteable installer command with no placeholders' {
            $result = script:Invoke-TestUx -Tokens @('update')
            $result.ExitCode | Should -Be 0
            $expected = 'https://raw.githubusercontent.com/zaterka/unix-powershell/v' + $script:UxVersion + '/install.ps1'
            $result.Text.Contains($expected) | Should -BeTrue -Because 'the printed line has to be usable as-is'
            $result.Text.Contains('iwr') | Should -BeTrue
            $result.Text.Contains('REPO') | Should -BeFalse -Because 'a placeholder is not a runnable command'
            $result.Text.Contains('vTAG') | Should -BeFalse
            $result.Text.Contains('downloads nothing') | Should -BeTrue -Because 'it must say plainly that only the printed command downloads'
        }

        It 'prints a placeholder only where information really is missing' {
            $script:UxState['Version'] = ''
            $result = script:Invoke-TestUx -Tokens @('update')
            $result.ExitCode | Should -Be 0
            # The repository is known, so it must still be filled in; only the version -
            # which the profile could not report - stays a placeholder, and the prose says so.
            $result.Text.Contains('githubusercontent.com/zaterka/unix-powershell/v<version>/install.ps1') | Should -BeTrue
            $result.Text.Contains('REPO') | Should -BeFalse
            $result.Text.Contains('vTAG') | Should -BeFalse
        }
    }

    Describe 'ux uninstall' {
        # Both tests below point $PROFILE at files under $TestDrive before invoking the verb:
        # ux uninstall derives its profile candidates from $PROFILE, so even a regression in
        # the safety gate can then only touch throwaway paths.
        It 'refuses to delete a directory that is not an install' {
            $victim = Join-Path $TestDrive 'not-an-install'
            $null = New-Item -ItemType Directory -Path $victim -Force
            $keep = Join-Path $victim 'keep.txt'
            Set-Content -LiteralPath $keep -Value 'keep me' -Encoding UTF8
            $env:UX_INSTALL_DIR = $victim

            $savedProfile = $PROFILE
            try {
                $PROFILE = [pscustomobject]@{
                    CurrentUserAllHosts    = (Join-Path $TestDrive 'fake-all-hosts.ps1')
                    CurrentUserCurrentHost = (Join-Path $TestDrive 'fake-current-host.ps1')
                }
                ([string]$PROFILE.CurrentUserAllHosts).StartsWith($TestDrive) | Should -BeTrue -Because 'the fake profile must be in place before ux runs'

                $result = script:Invoke-TestUx -Tokens @('uninstall', '-Force')
                $result.ExitCode | Should -Be 1
                $result.Text.Contains('refusing') | Should -BeTrue
                $result.Text.Contains('Nothing was deleted') | Should -BeTrue
                Test-Path -LiteralPath $victim | Should -BeTrue
                Test-Path -LiteralPath $keep | Should -BeTrue -Because 'nothing may be deleted when the safety gate refuses'
            } finally {
                $PROFILE = $savedProfile
            }
        }

        It 'refuses while the current directory is inside the install directory' {
            # A dedicated copy, so even a regression cannot wipe the shared fixture.
            $inside = Join-Path $TestDrive 'inside-install'
            $null = New-Item -ItemType Directory -Path (Join-Path $inside 'profile') -Force
            Copy-Item -LiteralPath $script:EntryPoint -Destination (Join-Path $inside 'profile/profile.ps1') -Force
            $env:UX_INSTALL_DIR = $inside

            $savedProfile = $PROFILE
            Push-Location -LiteralPath $inside
            try {
                $PROFILE = [pscustomobject]@{
                    CurrentUserAllHosts    = (Join-Path $TestDrive 'fake-all-hosts.ps1')
                    CurrentUserCurrentHost = (Join-Path $TestDrive 'fake-current-host.ps1')
                }
                $result = script:Invoke-TestUx -Tokens @('uninstall', '-Force')
                $result.ExitCode | Should -Be 1
                # The safety gate's own wording (the older check further down cannot produce
                # this sentence), so the gate must fire before anything else happens.
                $result.Text.Contains('the current directory is inside it (cd somewhere else first)') | Should -BeTrue
                $result.Text.Contains('Nothing was deleted') | Should -BeTrue
                Test-Path -LiteralPath (Join-Path $inside 'profile/profile.ps1') | Should -BeTrue
            } finally {
                Pop-Location
                $PROFILE = $savedProfile
            }
        }
    }

    Describe 'unknown verb' {
        It 'exits 2 and shows the usage table' {
            $result = script:Invoke-TestUx -Tokens @('bogus-verb')
            $result.ExitCode | Should -Be 2
            $result.Text.Contains('unknown verb') | Should -BeTrue
            $result.Text.Contains('usage: ux <verb>') | Should -BeTrue
        }
    }

    Describe 'isolation' {
        It 'resolves every path inside the throwaway install and touches nothing in the real one' {
            (Get-UxInstallDir) | Should -Be $script:InstallDir
            ([string](Get-UxConfigPath)) | Should -Be $script:ConfigPath
            $script:ConfigPath.StartsWith($TestDrive) | Should -BeTrue
            if ($HOME) {
                (Test-Path -LiteralPath (Join-Path $HOME '.unix-powershell')) | Should -Be $script:HomeInstallExisted
            }
            foreach ($path in @($script:RealProfileFiles.Keys)) {
                $content = $null
                if (Test-Path -LiteralPath ([string]$path)) {
                    $content = [string](Get-Content -LiteralPath ([string]$path) -Raw -ErrorAction SilentlyContinue)
                }
                $content | Should -Be $script:RealProfileFiles[$path] -Because 'no test may edit a real profile file'
            }
        }
    }
}
