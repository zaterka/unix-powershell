#Requires -Version 5.1
<#
    Installer and uninstaller behaviour.

    Every test runs the installer as a child process with a fake HOME, because the thing
    under test is "what does this do to a machine": the profile it patches is derived from
    $PROFILE.CurrentUserAllHosts, which PowerShell computes at process start. Mutating
    $env:HOME in-process would test the wrong path.

    These tests need manifest.json, which is generated from the runtime files. Until it
    exists they are skipped rather than failed.
#>

# Evaluated at discovery time: Pester resolves -Skip before BeforeAll runs, so a
# $script: variable set inside BeforeAll would always look null and skip everything.
$uxTestRoot = Split-Path -Parent $PSScriptRoot
$uxTestHasManifest = Test-Path -LiteralPath (Join-Path $uxTestRoot 'manifest.json')

BeforeAll {
    $script:Root = Split-Path -Parent $PSScriptRoot
    if (-not $script:Root) { $script:Root = Split-Path -Parent $MyInvocation.MyCommand.Path }
    $script:Installer = Join-Path $script:Root 'install.ps1'
    $script:Uninstaller = Join-Path $script:Root 'uninstall.ps1'
    $script:ManifestPath = Join-Path $script:Root 'manifest.json'
    $script:HasManifest = Test-Path -LiteralPath $script:ManifestPath

    function script:Get-HostExecutable {
        $major = 5
        if ($PSVersionTable.ContainsKey('PSVersion')) { $major = [int]$PSVersionTable.PSVersion.Major }
        if ($env:OS -eq 'Windows_NT') {
            if ($major -ge 7) { return (Join-Path $PSHOME 'pwsh.exe') }
            return (Join-Path $PSHOME 'powershell.exe')
        }
        return (Join-Path $PSHOME 'pwsh')
    }

    # The profile path a child process will compute for a given home directory.
    function script:Get-ExpectedProfilePath {
        param([string]$HomePath)
        $major = 5
        if ($PSVersionTable.ContainsKey('PSVersion')) { $major = [int]$PSVersionTable.PSVersion.Major }
        if ($env:OS -eq 'Windows_NT') {
            if ($major -ge 7) { return (Join-Path $HomePath 'Documents/PowerShell/profile.ps1') }
            return (Join-Path $HomePath 'Documents/WindowsPowerShell/profile.ps1')
        }
        return (Join-Path $HomePath '.config/powershell/profile.ps1')
    }

    function script:Invoke-External {
        param(
            [string[]]$Arguments,
            [string]$HomePath
        )
        $exe = script:Get-HostExecutable
        $savedHome = $env:HOME
        $savedUserProfile = $env:USERPROFILE
        $code = -1
        $output = ''
        try {
            if ($HomePath) {
                $env:HOME = $HomePath
                $env:USERPROFILE = $HomePath
            }
            $output = (& $exe -NoProfile -File @Arguments 2>&1 | Out-String)
            $code = $LASTEXITCODE
        }
        finally {
            $env:HOME = $savedHome
            $env:USERPROFILE = $savedUserProfile
        }
        return [pscustomobject]@{ ExitCode = $code; Output = $output }
    }

    function script:New-FakeHome {
        param([string]$Base)
        $fakeHome = Join-Path $Base 'home'
        $null = New-Item -ItemType Directory -Force -Path $fakeHome
        return $fakeHome
    }

    function script:New-SourceDir {
        # A writable copy of the runtime files plus the manifest, so a test can tamper
        # with a file to prove the hash gate works.
        param([string]$Base)
        $source = Join-Path $Base 'source'
        $null = New-Item -ItemType Directory -Force -Path $source
        Copy-Item -LiteralPath $script:ManifestPath -Destination $source -Force
        foreach ($relative in @(
                'profile/profile.ps1'
                'lib/00-core.ps1'
                'lib/05-args.ps1'
                'lib/10-git.ps1'
                'lib/20-prompt.ps1'
                'lib/30-unix.ps1'
                'lib/40-commands.ps1'
                'ux.ps1'
            )) {
            $from = Join-Path $script:Root $relative
            if (-not (Test-Path -LiteralPath $from)) { continue }
            $to = Join-Path $source $relative
            $parent = Split-Path -Parent $to
            if (-not (Test-Path -LiteralPath $parent)) { $null = New-Item -ItemType Directory -Force -Path $parent }
            Copy-Item -LiteralPath $from -Destination $to -Force
        }
        return $source
    }
}

Describe 'Installer: writes only under the user home' -Skip:(-not $uxTestHasManifest) {
    BeforeEach {
        $script:Work = Join-Path $TestDrive ([guid]::NewGuid().ToString('N').Substring(0, 8))
        $null = New-Item -ItemType Directory -Force -Path $script:Work
        $script:FakeHome = script:New-FakeHome -Base $script:Work
        $script:InstallDir = Join-Path $script:FakeHome '.unix-powershell'
    }

    It 'installs from -SourceDir and exits 0' {
        $result = script:Invoke-External -HomePath $script:FakeHome -Arguments @(
            $script:Installer, '-SourceDir', $script:Root, '-InstallDir', $script:InstallDir, '-Force'
        )
        $result.ExitCode | Should -Be 0 -Because ("installer output was:`n" + $result.Output)
        Test-Path -LiteralPath (Join-Path $script:InstallDir 'profile/profile.ps1') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $script:InstallDir 'lib/00-core.ps1') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $script:InstallDir 'ux.ps1') | Should -BeTrue
    }

    It 'writes the profile block exactly once, even when run twice' {
        $arguments = @($script:Installer, '-SourceDir', $script:Root, '-InstallDir', $script:InstallDir, '-Force')
        $first = script:Invoke-External -HomePath $script:FakeHome -Arguments $arguments
        $first.ExitCode | Should -Be 0 -Because $first.Output
        $second = script:Invoke-External -HomePath $script:FakeHome -Arguments $arguments
        $second.ExitCode | Should -Be 0 -Because $second.Output

        $profilePath = script:Get-ExpectedProfilePath -HomePath $script:FakeHome
        Test-Path -LiteralPath $profilePath | Should -BeTrue -Because 'the installer must create the profile directory when missing'
        $content = Get-Content -LiteralPath $profilePath -Raw
        $text = [string]$content
        ([regex]::Matches($text, '# BEGIN unix-powershell')).Count | Should -Be 1
        ([regex]::Matches($text, '# END unix-powershell')).Count | Should -Be 1
        # The block keeps the verbatim relative form (Join-Path $__uxBase '.unix-powershell')
        # when the install dir sits where the template expects it, and is rewritten to an
        # absolute path only for a custom location. Accept either, and prove it resolves.
        $pointsAtInstall = ($text -match [regex]::Escape($script:InstallDir)) -or ($text -match '\.unix-powershell')
        $pointsAtInstall | Should -BeTrue -Because 'the block must point at the chosen install dir'
        $entryLine = 'profile\profile.ps1'
        $text.Contains($entryLine) | Should -BeTrue -Because 'the block must dot-source the profile entry point'
    }

    It 'preserves existing user profile content and backs it up' {
        $profilePath = script:Get-ExpectedProfilePath -HomePath $script:FakeHome
        $parent = Split-Path -Parent $profilePath
        $null = New-Item -ItemType Directory -Force -Path $parent
        $userLine = 'Set-Alias showcase Write-Output'
        Set-Content -LiteralPath $profilePath -Value $userLine -Encoding UTF8

        $result = script:Invoke-External -HomePath $script:FakeHome -Arguments @(
            $script:Installer, '-SourceDir', $script:Root, '-InstallDir', $script:InstallDir, '-Force'
        )
        $result.ExitCode | Should -Be 0 -Because $result.Output

        $text = [string](Get-Content -LiteralPath $profilePath -Raw)
        $text | Should -Match ([regex]::Escape($userLine)) -Because 'user content outside the block must survive'
        $text | Should -Match '# BEGIN unix-powershell'

        $backups = @(Get-ChildItem -LiteralPath $parent -Filter 'profile.ps1.bak.*' -ErrorAction SilentlyContinue)
        $backups.Count | Should -BeGreaterThan 0 -Because 'a modified profile must be backed up first'
    }

    It 'does not touch the profile with -NoProfile' {
        $result = script:Invoke-External -HomePath $script:FakeHome -Arguments @(
            $script:Installer, '-SourceDir', $script:Root, '-InstallDir', $script:InstallDir, '-NoProfile', '-Force'
        )
        $result.ExitCode | Should -Be 0 -Because $result.Output
        $profilePath = script:Get-ExpectedProfilePath -HomePath $script:FakeHome
        Test-Path -LiteralPath $profilePath | Should -BeFalse
    }

    It 'refuses to use the home directory itself as the install dir' {
        $result = script:Invoke-External -HomePath $script:FakeHome -Arguments @(
            $script:Installer, '-SourceDir', $script:Root, '-InstallDir', $script:FakeHome, '-Force'
        )
        $result.ExitCode | Should -Not -Be 0 -Because 'installing into $HOME itself would delete user files on upgrade'
        $result.Output | Should -Match 'home'
    }

    It 'preserves config.json across a reinstall' {
        $null = script:Invoke-External -HomePath $script:FakeHome -Arguments @(
            $script:Installer, '-SourceDir', $script:Root, '-InstallDir', $script:InstallDir, '-NoProfile', '-Force'
        )
        $configPath = Join-Path $script:InstallDir 'config.json'

        # The installer never creates config.json (the runtime does), so a test that only
        # asserts when it already exists can pass without testing anything. Create it the
        # way the runtime would, then prove the upgrade carries it forward.
        Set-Content -LiteralPath $configPath -Value '{"version":1,"theme":"classic"}' -Encoding UTF8
        Test-Path -LiteralPath $configPath | Should -BeTrue

        $second = script:Invoke-External -HomePath $script:FakeHome -Arguments @(
            $script:Installer, '-SourceDir', $script:Root, '-InstallDir', $script:InstallDir, '-NoProfile', '-Force'
        )
        $second.ExitCode | Should -Be 0 -Because $second.Output
        Test-Path -LiteralPath $configPath | Should -BeTrue -Because 'a reinstall must not drop the user settings file'
        $after = [string](Get-Content -LiteralPath $configPath -Raw)
        $after | Should -Match 'classic' -Because 'an upgrade must never reset the user theme'
    }

    It 'rewrites the block to an absolute path for a non-default install dir' {
        $customDir = Join-Path $script:FakeHome 'custom-profile-root'
        $result = script:Invoke-External -HomePath $script:FakeHome -Arguments @(
            $script:Installer, '-SourceDir', $script:Root, '-InstallDir', $customDir, '-Force'
        )
        $result.ExitCode | Should -Be 0 -Because $result.Output

        $profilePath = script:Get-ExpectedProfilePath -HomePath $script:FakeHome
        $text = [string](Get-Content -LiteralPath $profilePath -Raw)
        # The verbatim template hardcodes '.unix-powershell'; a custom root must be substituted
        # or the block would load the wrong directory (and silently load nothing).
        $text | Should -Match ([regex]::Escape($customDir)) -Because 'a custom install dir must appear in the block'
        $text | Should -Not -Match ([regex]::Escape((Join-Path $script:FakeHome '.unix-powershell'))) -Because 'the hardcoded default must have been replaced'
    }

    It 'uninstalls cleanly, removing the block but keeping user content' {
        $profilePath = script:Get-ExpectedProfilePath -HomePath $script:FakeHome
        $parent = Split-Path -Parent $profilePath
        $null = New-Item -ItemType Directory -Force -Path $parent
        $userLine = 'Set-Alias showcase Write-Output'
        Set-Content -LiteralPath $profilePath -Value $userLine -Encoding UTF8

        $null = script:Invoke-External -HomePath $script:FakeHome -Arguments @(
            $script:Installer, '-SourceDir', $script:Root, '-InstallDir', $script:InstallDir, '-Force'
        )
        $result = script:Invoke-External -HomePath $script:FakeHome -Arguments @(
            $script:Installer, '-Uninstall', '-InstallDir', $script:InstallDir, '-Force'
        )
        $result.ExitCode | Should -Be 0 -Because $result.Output

        $text = ''
        if (Test-Path -LiteralPath $profilePath) {
            $text = [string](Get-Content -LiteralPath $profilePath -Raw)
        }
        $text | Should -Not -Match '# BEGIN unix-powershell'
        $text | Should -Match ([regex]::Escape($userLine))
        Test-Path -LiteralPath $script:InstallDir | Should -BeFalse
    }

    It 'aborts when a source file does not match its manifest hash' {
        $source = script:New-SourceDir -Base $script:Work
        Add-Content -LiteralPath (Join-Path $source 'lib/00-core.ps1') -Value '# tampered'

        $result = script:Invoke-External -HomePath $script:FakeHome -Arguments @(
            $script:Installer, '-SourceDir', $source, '-InstallDir', $script:InstallDir, '-Force'
        )
        $result.ExitCode | Should -Not -Be 0 -Because 'a hash mismatch must stop the install'
        $result.Output | Should -Match 'sha256|hash'
    }

    It 'keeps at most two install backups' {
        for ($i = 1; $i -le 4; $i++) {
            $result = script:Invoke-External -HomePath $script:FakeHome -Arguments @(
                $script:Installer, '-SourceDir', $script:Root, '-InstallDir', $script:InstallDir, '-Force'
            )
            $result.ExitCode | Should -Be 0 -Because $result.Output
            Start-Sleep -Milliseconds 1100 # backup names carry a second-resolution timestamp
        }
        $backups = @(Get-ChildItem -LiteralPath $script:FakeHome -Filter '.unix-powershell.bak.*' -ErrorAction SilentlyContinue)
        $backups.Count | Should -BeLessOrEqual 2 -Because 'unbounded backups fill a quota-limited home directory'
    }
}

Describe 'Uninstaller: standalone script' -Skip:(-not $uxTestHasManifest) {
    It 'is safe to run twice on a clean machine' {
        $work = Join-Path $TestDrive ([guid]::NewGuid().ToString('N').Substring(0, 8))
        $null = New-Item -ItemType Directory -Force -Path $work
        $fakeHome = script:New-FakeHome -Base $work
        $installDir = Join-Path $fakeHome '.unix-powershell'

        $first = script:Invoke-External -HomePath $fakeHome -Arguments @(
            $script:Uninstaller, '-InstallDir', $installDir, '-Force'
        )
        $second = script:Invoke-External -HomePath $fakeHome -Arguments @(
            $script:Uninstaller, '-InstallDir', $installDir, '-Force'
        )
        $first.ExitCode | Should -Be 0 -Because $first.Output
        $second.ExitCode | Should -Be 0 -Because 'a second uninstall must not error'
    }
}
