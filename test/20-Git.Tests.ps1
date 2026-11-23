#Requires -Version 5.1
<#
    Git discovery and prompt model: lib/10-git.ps1 (PLAN.md 5.2, 6, 7).

    Every fixture below is a real on-disk repository layout under $TestDrive, written the
    way git itself writes it (HEAD, refs/heads, packed-refs, a .git *file* with
    "gitdir:", a per-worktree dir with "commondir", the MERGE_HEAD / rebase-merge /
    CHERRY_PICK_HEAD / REVERT_HEAD / BISECT_LOG state files). Nothing is mocked: the
    assertions read what Get-UxGitModel actually returns for that layout.

    The two process-contract tests (at most one `git` per prompt, graceful degradation
    when it fails) use a counting shell script earlier on PATH than the real binary.

    Determinism: no Start-Sleep anywhere. Cache freshness is driven by explicit
    LastWriteTime values and by git.cacheMs in the in-memory config.

    Isolation: $global:Ux is rebuilt from lib/00-core.ps1 before every test, PATH and the
    environment are restored from a baseline after every test, and the git memos are
    dropped with Reset-UxGitCache.
#>

BeforeAll {
    $script:Root = Split-Path -Parent $PSScriptRoot
    if (-not $script:Root) { $script:Root = Split-Path -Parent $MyInvocation.MyCommand.Path }
    $script:CorePath = Join-Path $script:Root 'lib/00-core.ps1'
    $script:GitPath = Join-Path $script:Root 'lib/10-git.ps1'

    . $script:CorePath
    . $script:GitPath

    $script:OriginalState = $global:Ux

    # --- environment isolation -------------------------------------------------
    $script:EnvNames = @('PATH', 'UX_DEBUG', 'UX_DISABLE', 'UX_INSTALL_DIR', 'OS')
    $script:EnvBaseline = @{}
    foreach ($name in $script:EnvNames) {
        $item = Get-Item -Path ('Env:' + $name) -ErrorAction SilentlyContinue
        if ($null -ne $item) { $script:EnvBaseline[$name] = [string]$item.Value }
        else { $script:EnvBaseline[$name] = $null }
    }
    $script:BaselinePath = [string]$env:PATH
    $script:PathSeparator = [string][char]58
    if ($env:OS -eq 'Windows_NT') { $script:PathSeparator = ';' }

    function script:Set-UxGitTestEnv {
        param([string]$Name, [string]$Value)
        if ($null -eq $Value) {
            Remove-Item -Path ('Env:' + $Name) -ErrorAction SilentlyContinue
        }
        else {
            Set-Item -Path ('Env:' + $Name) -Value $Value -ErrorAction SilentlyContinue
        }
    }

    function script:Restore-UxGitTestEnv {
        foreach ($name in $script:EnvNames) {
            script:Set-UxGitTestEnv -Name $name -Value $script:EnvBaseline[$name]
        }
    }

    function script:Reset-UxGitTestState {
        # Fresh $global:Ux (default config, empty GitCache) exactly as a session start.
        . $script:CorePath
        $global:Ux['ConfigLoaded'] = $false
        Reset-UxGitCache
    }

    # --- fixture builders ------------------------------------------------------
    $script:CommitSha = '0123456789abcdef0123456789abcdef01234567'
    $script:DetachedSha = 'abcdef0123456789abcdef0123456789abcdef01'

    function script:New-UxFixtureDirectory {
        param([Parameter(Mandatory = $true)][string]$Path)
        if (-not (Test-Path -LiteralPath $Path)) {
            $null = New-Item -ItemType Directory -Force -Path $Path
        }
        return $Path
    }

    function script:New-UxFixtureRepo {
        param(
            [Parameter(Mandatory = $true)][string]$Path,
            [string]$Branch = 'main',
            [switch]$Detached,
            [switch]$Unborn,
            [switch]$PackedOnly
        )
        $null = script:New-UxFixtureDirectory -Path $Path
        $gitDir = Join-Path $Path '.git'
        $null = script:New-UxFixtureDirectory -Path (Join-Path $gitDir 'refs/heads')
        $null = script:New-UxFixtureDirectory -Path (Join-Path $gitDir 'objects')
        Set-Content -LiteralPath (Join-Path $gitDir 'config') -Value ("[core]`n`trepositoryformatversion = 0`n") -Encoding ASCII

        if ($Detached) {
            Set-Content -LiteralPath (Join-Path $gitDir 'HEAD') -Value $script:DetachedSha -Encoding ASCII
            return $Path
        }

        Set-Content -LiteralPath (Join-Path $gitDir 'HEAD') -Value ('ref: refs/heads/' + $Branch) -Encoding ASCII
        if ($PackedOnly) {
            $packed = @(
                '# pack-refs with: peeled fully-peeled'
                ($script:CommitSha + ' refs/heads/' + $Branch)
                ''
            )
            Set-Content -LiteralPath (Join-Path $gitDir 'packed-refs') -Value $packed -Encoding ASCII
        }
        elseif (-not $Unborn) {
            Set-Content -LiteralPath (Join-Path $gitDir ('refs/heads/' + $Branch)) -Value $script:CommitSha -Encoding ASCII
        }
        return $Path
    }

    # --- static fixtures -------------------------------------------------------
    $script:NormalRepo = script:New-UxFixtureRepo -Path (Join-Path $TestDrive 'normal') -Branch 'main'
    $script:NestedDir = script:New-UxFixtureDirectory -Path (Join-Path $script:NormalRepo 'sub/deep')
    $script:DetachedRepo = script:New-UxFixtureRepo -Path (Join-Path $TestDrive 'detached') -Detached
    $script:UnbornRepo = script:New-UxFixtureRepo -Path (Join-Path $TestDrive 'unborn') -Branch 'trunk' -Unborn
    $script:PackedRepo = script:New-UxFixtureRepo -Path (Join-Path $TestDrive 'packed') -Branch 'packedbranch' -PackedOnly
    $script:PlainDir = script:New-UxFixtureDirectory -Path (Join-Path $TestDrive 'plain-not-a-repo')
    $script:MissingDir = Join-Path $TestDrive 'does-not-exist'

    # .git as a FILE (worktree / submodule checkout) pointing at a real git dir.
    $script:LinkedStore = script:New-UxFixtureDirectory -Path (Join-Path $TestDrive 'store/real.git')
    $null = script:New-UxFixtureDirectory -Path (Join-Path $script:LinkedStore 'refs/heads')
    Set-Content -LiteralPath (Join-Path $script:LinkedStore 'HEAD') -Value 'ref: refs/heads/gitfilebranch' -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $script:LinkedStore 'refs/heads/gitfilebranch') -Value $script:CommitSha -Encoding ASCII
    $script:LinkedWorkTree = script:New-UxFixtureDirectory -Path (Join-Path $TestDrive 'linked')
    Set-Content -LiteralPath (Join-Path $script:LinkedWorkTree '.git') -Value ('gitdir: ' + $script:LinkedStore) -Encoding ASCII

    # Linked worktree: HEAD lives in .git/worktrees/wt, refs live in the common dir
    # that `commondir` names relative to the per-worktree git dir.
    $script:WorktreeMain = script:New-UxFixtureRepo -Path (Join-Path $TestDrive 'worktree-main') -Branch 'main'
    $script:WorktreeGitDir = script:New-UxFixtureDirectory -Path (Join-Path $script:WorktreeMain '.git/worktrees/wt')
    Set-Content -LiteralPath (Join-Path $script:WorktreeGitDir 'HEAD') -Value 'ref: refs/heads/wtbranch' -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $script:WorktreeGitDir 'commondir') -Value '../..' -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $script:WorktreeMain '.git/refs/heads/wtbranch') -Value $script:CommitSha -Encoding ASCII
    $script:WorktreeDir = script:New-UxFixtureDirectory -Path (Join-Path $TestDrive 'worktree')
    Set-Content -LiteralPath (Join-Path $script:WorktreeDir '.git') -Value ('gitdir: ' + $script:WorktreeGitDir) -Encoding ASCII

    # A path that would be a wildcard if it were not handled with -LiteralPath.
    $script:BracketRepo = script:New-UxFixtureRepo -Path (Join-Path $TestDrive 'br[ackets]') -Branch 'bracketbranch'
    $script:BracketSub = script:New-UxFixtureDirectory -Path (Join-Path $script:BracketRepo 'z[1]')

    # --- git shim --------------------------------------------------------------
    function script:Use-UxFakeGit {
        param([string]$Mode = 'ok')
        $shimDir = Join-Path $TestDrive ('git-shim-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $null = script:New-UxFixtureDirectory -Path $shimDir
        $counter = Join-Path $shimDir 'calls.txt'
        $null = New-Item -ItemType File -Path $counter -Force

        $lines = @('#!/bin/sh')
        $lines += ('echo call >> "' + $counter + '"')
        if ($Mode -eq 'ok') {
            $lines += 'if [ "$1" = "--version" ]; then echo "git version 2.34.1"; exit 0; fi'
            $lines += 'echo "# branch.oid 0123456789abcdef0123456789abcdef01234567"'
            $lines += 'echo "# branch.head main"'
            $lines += 'echo "# branch.ab +1 -2"'
            $lines += 'exit 0'
        }
        else {
            $lines += 'echo "fatal: not a git repository" >&2'
            $lines += 'exit 128'
        }
        $shim = Join-Path $shimDir 'git'
        Set-Content -LiteralPath $shim -Value ($lines -join "`n") -Encoding ASCII
        & chmod 755 $shim

        $script:ShimDir = $shimDir
        $script:ShimCounter = $counter
        script:Set-UxGitTestEnv -Name 'PATH' -Value ($shimDir + $script:PathSeparator + $script:BaselinePath)
    }

    function script:Get-UxShimCallCount {
        if ($script:ShimCounter -eq '' -or -not (Test-Path -LiteralPath $script:ShimCounter)) { return 0 }
        return @(Get-Content -LiteralPath $script:ShimCounter -ErrorAction SilentlyContinue).Count
    }

    $script:ShimCounter = ''
}

Describe 'Git discovery and prompt model' {

    BeforeEach {
        script:Restore-UxGitTestEnv
        script:Reset-UxGitTestState
    }

    AfterEach {
        script:Restore-UxGitTestEnv
        Reset-UxGitCache
        $global:Ux = $script:OriginalState
    }

    Describe 'Repository discovery' {

        It 'reports a normal checkout as a repository on its branch' {
            $model = Get-UxGitModel -Path $script:NormalRepo

            $model['IsRepo'] | Should -BeTrue
            $model['Root'] | Should -Be $script:NormalRepo
            $model['Branch'] | Should -Be 'main'
            $model['Detached'] | Should -BeFalse
            $model['State'] | Should -Be ''
            $model['ShortSha'] | Should -BeNullOrEmpty
        }

        It 'resolves a nested directory to the repository root' {
            $model = Get-UxGitModel -Path $script:NestedDir

            $model['IsRepo'] | Should -BeTrue
            $model['Root'] | Should -Be $script:NormalRepo -Because 'the prompt must show the repository, not the cwd'
            $model['Branch'] | Should -Be 'main'
        }

        It 'reports a detached HEAD with a seven-character short SHA' {
            $model = Get-UxGitModel -Path $script:DetachedRepo

            $model['IsRepo'] | Should -BeTrue
            $model['Detached'] | Should -BeTrue
            ([string]$model['ShortSha']) | Should -Match '^[0-9a-f]{7}$'
            $model['ShortSha'] | Should -Be ([string]$script:DetachedSha).Substring(0, 7)
            $model['Branch'] | Should -Be $model['ShortSha'] -Because 'a detached HEAD displays the SHA'
        }

        It 'names the branch of an unborn repository and marks it NEW' {
            $model = Get-UxGitModel -Path $script:UnbornRepo

            $model['IsRepo'] | Should -BeTrue
            $model['Branch'] | Should -Be 'trunk' -Because 'HEAD already names the branch before the first commit'
            $model['State'] | Should -Be 'NEW'
            $model['Detached'] | Should -BeFalse
        }

        It 'resolves a branch that only exists in packed-refs' {
            $model = Get-UxGitModel -Path $script:PackedRepo

            $model['IsRepo'] | Should -BeTrue
            $model['Branch'] | Should -Be 'packedbranch'
            $model['State'] | Should -Be '' -Because 'the ref exists, so the branch is not unborn'
        }

        It 'follows a .git file that carries gitdir:' {
            Test-Path -LiteralPath (Join-Path $script:LinkedWorkTree '.git') -PathType Leaf |
                Should -BeTrue -Because 'this fixture is a .git FILE, not a directory'

            $model = Get-UxGitModel -Path $script:LinkedWorkTree

            $model['IsRepo'] | Should -BeTrue
            $model['Root'] | Should -Be $script:LinkedWorkTree
            $model['Branch'] | Should -Be 'gitfilebranch'
        }

        It 'reads refs from the common dir of a linked worktree' {
            Test-Path -LiteralPath (Join-Path $script:WorktreeGitDir 'commondir') | Should -BeTrue

            $model = Get-UxGitModel -Path $script:WorktreeDir

            $model['IsRepo'] | Should -BeTrue
            $model['Root'] | Should -Be $script:WorktreeDir
            $model['Branch'] | Should -Be 'wtbranch' -Because 'the ref lives in the common dir named by commondir'
            $model['State'] | Should -Be ''
        }

        It 'resolves a path containing [brackets] literally' {
            $model = Get-UxGitModel -Path $script:BracketRepo

            $model['IsRepo'] | Should -BeTrue
            $model['Root'] | Should -Be $script:BracketRepo
            $model['Branch'] | Should -Be 'bracketbranch'

            $nested = Get-UxGitModel -Path $script:BracketSub
            $nested['IsRepo'] | Should -BeTrue
            $nested['Root'] | Should -Be $script:BracketRepo
        }

        It 'returns IsRepo=false for a plain directory without throwing' {
            $threw = ''
            $model = $null
            try { $model = Get-UxGitModel -Path $script:PlainDir } catch { $threw = [string]$_.Exception.Message }

            $threw | Should -BeNullOrEmpty -Because 'the prompt calls this on every keystroke path'
            $model['IsRepo'] | Should -BeFalse
            $model['Root'] | Should -BeNullOrEmpty
            $model['Ahead'] | Should -Be 0
            $model['Behind'] | Should -Be 0
        }

        It 'returns IsRepo=false for a path that does not exist' {
            $model = Get-UxGitModel -Path $script:MissingDir
            $model['IsRepo'] | Should -BeFalse
        }

        It 'skips the walk for a non-FileSystem provider path' {
            # Env: is a provider that exists on every platform; its items are not files, so
            # the walk must be skipped instead of stat-ing a registry/env path.
            $threw = ''
            $model = $null
            try { $model = Get-UxGitModel -Path 'Env:' } catch { $threw = [string]$_.Exception.Message }

            $threw | Should -BeNullOrEmpty
            $model['IsRepo'] | Should -BeFalse
        }

        It 'skips the walk for Registry:: on Windows (skipped on Linux CI: no Registry provider there; covered on the Windows host)' -Skip:($env:OS -ne 'Windows_NT') {
            # Windows-only: there is no Registry provider on Linux/macOS CI. Covered on the
            # Windows by this suite plus test/WINDOWS-CHECKLIST.md.
            $model = Get-UxGitModel -Path 'HKLM:\SOFTWARE'
            $model['IsRepo'] | Should -BeFalse
        }

        It 'resolves a relative gitdir: path against the directory holding .git' {
            # git writes a relative gitdir for submodule checkouts ("gitdir: ../.git/modules/x").
            $workTree = script:New-UxFixtureDirectory -Path (Join-Path $TestDrive 'submodule-like')
            Set-Content -LiteralPath (Join-Path $workTree '.git') -Value 'gitdir: ../store/real.git' -Encoding ASCII

            $model = Get-UxGitModel -Path $workTree

            $model['IsRepo'] | Should -BeTrue
            $model['Root'] | Should -Be $workTree
            $model['Branch'] | Should -Be 'gitfilebranch'
        }

        It 'treats a .git file with a missing target as not a repository' {
            $workTree = script:New-UxFixtureDirectory -Path (Join-Path $TestDrive 'broken-link')
            Set-Content -LiteralPath (Join-Path $workTree '.git') -Value 'gitdir: ../store/does-not-exist.git' -Encoding ASCII

            $threw = ''
            $model = $null
            try { $model = Get-UxGitModel -Path $workTree } catch { $threw = [string]$_.Exception.Message }

            $threw | Should -BeNullOrEmpty
            $model['IsRepo'] | Should -BeFalse
        }

        It 'treats an unparseable HEAD as not a repository without throwing' {
            $repo = script:New-UxFixtureRepo -Path (Join-Path $TestDrive 'bad-head') -Branch 'main'
            Set-Content -LiteralPath (Join-Path $repo '.git/HEAD') -Value 'this is not a git HEAD line' -Encoding ASCII
            Reset-UxGitCache

            $threw = ''
            $model = $null
            try { $model = Get-UxGitModel -Path $repo } catch { $threw = [string]$_.Exception.Message }

            $threw | Should -BeNullOrEmpty -Because 'a half-removed .git must degrade, not throw'
            $model['IsRepo'] | Should -BeFalse
        }

        It 'returns exactly the nine documented model keys' {
            $model = Get-UxGitModel -Path $script:NormalRepo

            @($model.Keys).Count | Should -Be 9
            foreach ($key in @('Root', 'Branch', 'Detached', 'ShortSha', 'Dirty', 'Ahead', 'Behind', 'State', 'IsRepo')) {
                $model.ContainsKey($key) | Should -BeTrue -Because ('the prompt reads model.' + $key)
            }
            $model['IsRepo'] -is [bool] | Should -BeTrue
            $model['Detached'] -is [bool] | Should -BeTrue
            $model['Ahead'] -is [int] | Should -BeTrue
            $model['Behind'] -is [int] | Should -BeTrue
            $model['State'] -is [string] | Should -BeTrue
        }
    }

    Describe 'Repository state' {

        It 'reports <Expected> while <Name> exists' -ForEach @(
            @{ Name = 'MERGE_HEAD'; Expected = 'MERGING'; Container = $false }
            @{ Name = 'rebase-merge'; Expected = 'REBASE'; Container = $true }
            @{ Name = 'CHERRY_PICK_HEAD'; Expected = 'PICK'; Container = $false }
            @{ Name = 'REVERT_HEAD'; Expected = 'REVERT'; Container = $false }
            @{ Name = 'BISECT_LOG'; Expected = 'BISECT'; Container = $false }
        ) {
            $repo = script:New-UxFixtureRepo -Path (Join-Path $TestDrive ('state-' + $Name)) -Branch 'main'
            if ($Container) {
                $null = script:New-UxFixtureDirectory -Path (Join-Path $repo ('.git/' + $Name))
            }
            else {
                Set-Content -LiteralPath (Join-Path $repo ('.git/' + $Name)) -Value $script:CommitSha -Encoding ASCII
            }
            Reset-UxGitCache

            $model = Get-UxGitModel -Path $repo

            $model['IsRepo'] | Should -BeTrue
            $model['Branch'] | Should -Be 'main'
            $model['State'] | Should -Be $Expected
        }

        It 'prefers MERGING over the other state files' {
            $repo = script:New-UxFixtureRepo -Path (Join-Path $TestDrive 'state-order') -Branch 'main'
            Set-Content -LiteralPath (Join-Path $repo '.git/MERGE_HEAD') -Value $script:CommitSha -Encoding ASCII
            Set-Content -LiteralPath (Join-Path $repo '.git/CHERRY_PICK_HEAD') -Value $script:CommitSha -Encoding ASCII
            Reset-UxGitCache

            (Get-UxGitModel -Path $repo)['State'] | Should -Be 'MERGING' -Because 'the documented probe order is fixed'
        }
    }

    Describe 'Process contract: one git call per cache window' {

        It 'runs git at most once for three warm calls and again after a reset (POSIX counting shim; the Windows git.cmd shim is a Windows checklist item)' -Skip:($env:OS -eq 'Windows_NT') {
            # Windows gate: the counting shim is a POSIX shell script (chmod +x). The
            # equivalent git.cmd shim is listed in test/WINDOWS-CHECKLIST.md; the assertions
            # below are the same ones that would run there.
            script:Use-UxFakeGit -Mode 'ok'
            Reset-UxGitCache

            $first = Get-UxGitModel -Path $script:NormalRepo
            $afterFirst = script:Get-UxShimCallCount
            $second = Get-UxGitModel -Path $script:NormalRepo
            $third = Get-UxGitModel -Path $script:NormalRepo
            $afterWarm = script:Get-UxShimCallCount
            Reset-UxGitCache
            $fourth = Get-UxGitModel -Path $script:NormalRepo
            $afterReset = script:Get-UxShimCallCount

            $afterFirst | Should -Be 1 -Because 'the cold model needs exactly one git process'
            $afterWarm | Should -Be 1 -Because 'the warm cache must not spawn git at all'
            $afterReset | Should -Be 2 -Because 'Reset-UxGitCache forces a fresh call'

            $first['Ahead'] | Should -Be 1 -Because 'the shim reports "+1 -2" and the model must parse it'
            $first['Behind'] | Should -Be 2
            $first['Dirty'] | Should -BeFalse -Because 'the shim printed only header lines'

            $second['Branch'] | Should -Be 'main'
            $third['Branch'] | Should -Be 'main'
            $fourth['Branch'] | Should -Be 'main'
        }

        It 'does not run git when git.useGitBinary is false (POSIX counting shim; Windows checklist item)' -Skip:($env:OS -eq 'Windows_NT') {
            script:Use-UxFakeGit -Mode 'ok'
            $global:Ux['Config']['git']['useGitBinary'] = $false
            Reset-UxGitCache

            $model = Get-UxGitModel -Path $script:NormalRepo

            script:Get-UxShimCallCount | Should -Be 0
            $model['Branch'] | Should -Be 'main' -Because 'the branch comes from files, with or without the binary'
            $model['Dirty'] | Should -BeNullOrEmpty -Because 'dirty is unknown, not false, when git is not run'
        }

        It 'falls back to file parsing when git exits 128 (POSIX failing shim; Windows checklist item)' -Skip:($env:OS -eq 'Windows_NT') {
            script:Use-UxFakeGit -Mode 'fail'
            Reset-UxGitCache

            $threw = ''
            $model = $null
            try { $model = Get-UxGitModel -Path $script:NormalRepo } catch { $threw = [string]$_.Exception.Message }

            $threw | Should -BeNullOrEmpty -Because 'prompt must never throw'
            $model['IsRepo'] | Should -BeTrue
            $model['Branch'] | Should -Be 'main' -Because 'HEAD still names the branch'
            $model['Dirty'] | Should -BeNullOrEmpty

            ([string](Get-UxGitDiagnostics)['Message']) | Should -Match '128' -Because 'ux doctor reports why the dirty marker is missing'
        }

        It 'reports the capability mode and a reason' {
            # Clear the session memo so this test does not depend on whether another test
            # already probed (the lib stores it in $script:, i.e. this file's scope).
            $script:UxGitCapability = $null
            $script:UxGitVersion = ''

            $capability = Get-UxGitStatusCapability

            @('porcelain-v2', 'porcelain-v1', 'file-only') -contains [string]$capability['Mode'] |
                Should -BeTrue -Because 'those are the three documented modes'
            ([string]$capability['Reason']) | Should -Not -BeNullOrEmpty
            $capability.ContainsKey('Version') | Should -BeTrue

            $gitAvailable = ($null -ne (Get-Command -Name 'git' -CommandType Application -ErrorAction SilentlyContinue))
            if ($gitAvailable) {
                $capability['Mode'] | Should -Not -Be 'file-only' -Because 'a git binary on PATH must produce a porcelain mode'
                ([string]$capability['Version']) | Should -Match '^[0-9]+\.[0-9]+'
            }
        }

        It 'reports diagnostics with the documented shape and clears them on reset' {
            $null = Get-UxGitModel -Path $script:NormalRepo
            $diagnostics = Get-UxGitDiagnostics

            foreach ($key in @('Message', 'Blocked', 'Reason', 'Degraded', 'Slow')) {
                $diagnostics.ContainsKey($key) | Should -BeTrue -Because ('ux doctor prints ' + $key)
            }
            $diagnostics['Blocked'] -is [bool] | Should -BeTrue
            $diagnostics['Degraded'] -is [bool] | Should -BeTrue
            $diagnostics['Slow'] -is [int] | Should -BeTrue

            Reset-UxGitCache
            $cleared = Get-UxGitDiagnostics
            $cleared['Message'] | Should -Be ''
            $cleared['Blocked'] | Should -BeFalse
            $cleared['Degraded'] | Should -BeFalse
            $cleared['Slow'] | Should -Be 0
        }
    }

    Describe 'Cache correctness' {

        It 'does not leak a cached model between two repositories' {
            $repoA = script:New-UxFixtureRepo -Path (Join-Path $TestDrive 'cache-a') -Branch 'alpha'
            $repoB = script:New-UxFixtureRepo -Path (Join-Path $TestDrive 'cache-b') -Branch 'beta'
            Reset-UxGitCache

            (Get-UxGitModel -Path $repoA)['Branch'] | Should -Be 'alpha'
            (Get-UxGitModel -Path $repoB)['Branch'] | Should -Be 'beta'
            (Get-UxGitModel -Path $repoA)['Branch'] | Should -Be 'alpha'
            (Get-UxGitModel -Path $repoA)['Root'] | Should -Be $repoA
        }

        It 'returns an identical model for repeated warm calls' {
            Reset-UxGitCache
            $first = Get-UxGitModel -Path $script:NormalRepo
            $second = Get-UxGitModel -Path $script:NormalRepo

            $second['Root'] | Should -Be $first['Root']
            $second['Branch'] | Should -Be $first['Branch']
            $second['Detached'] | Should -Be $first['Detached']
            $second['Dirty'] | Should -Be $first['Dirty']
            $second['Ahead'] | Should -Be $first['Ahead']
            $second['Behind'] | Should -Be $first['Behind']
            $second['State'] | Should -Be $first['State']
        }

        It 'invalidates the cache when HEAD changes, without sleeping' {
            $repo = script:New-UxFixtureRepo -Path (Join-Path $TestDrive 'stamp-repo') -Branch 'main'
            # A long cache window makes the stamp - not the clock - the only thing that can
            # invalidate this entry, so the test is deterministic and needs no Start-Sleep.
            $global:Ux['Config']['git']['cacheMs'] = 60000
            Reset-UxGitCache

            (Get-UxGitModel -Path $repo)['Branch'] | Should -Be 'main'

            $headPath = Join-Path $repo '.git/HEAD'
            Set-Content -LiteralPath $headPath -Value 'ref: refs/heads/feature' -Encoding ASCII
            Set-Content -LiteralPath (Join-Path $repo '.git/refs/heads/feature') -Value $script:CommitSha -Encoding ASCII
            $item = Get-Item -LiteralPath $headPath -Force
            $item.LastWriteTime = (Get-Date -Year 2021 -Month 3 -Day 4 -Hour 5 -Minute 6 -Second 7)

            (Get-UxGitModel -Path $repo)['Branch'] | Should -Be 'feature' -Because 'the HEAD mtime is the early-invalidation fast path'
        }

        It 'honours git.cacheMs = 0 by never reusing a model (POSIX counting shim; Windows checklist item)' -Skip:($env:OS -eq 'Windows_NT') {
            script:Use-UxFakeGit -Mode 'ok'
            $global:Ux['Config']['git']['cacheMs'] = 0
            Reset-UxGitCache

            $null = Get-UxGitModel -Path $script:NormalRepo
            $null = Get-UxGitModel -Path $script:NormalRepo

            script:Get-UxShimCallCount | Should -Be 2 -Because 'cacheMs 0 is the documented "always fresh" setting'
        }
    }
}
