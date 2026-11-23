#Requires -Version 5.1
<#
    Encodes the project's hard constraints as executable tests.

    These are not style opinions: each one corresponds to a way this profile
    would silently fail on the target (Windows PowerShell 5.1, possibly
    ConstrainedLanguage, stock console font, no admin). If one of these fails,
    the change is not shippable no matter how well it works on PowerShell 7.

    Rules enforced:
      1. Every text file is pure ASCII (the prompt must render in a stock font,
         and 5.1 mis-decodes BOM-less non-ASCII script files).
      2. Every .ps1 parses.
      3. No PowerShell 7-only syntax (5.1 is the baseline).
      4. No Invoke-Expression / Add-Type / COM / reflection anywhere.
      5. No .NET static method calls in the runtime path (CLM).
      6. Type literals come from a small allowlist (CLM + 5.1).
      7. #Requires -Version 5.1 in every .ps1.
      8. Network cmdlets only where the design allows them.
      9. manifest.json agrees with lib/00-core.ps1 and with the files on disk.
#>

BeforeAll {
    $script:Root = Split-Path -Parent $PSScriptRoot
    if (-not $script:Root) { $script:Root = Split-Path -Parent $MyInvocation.MyCommand.Path }

    # Paths that are allowed to make .NET static calls: they never run at shell
    # startup, are not part of the ConstrainedLanguage promise, and need the
    # parser/hash APIs.
    $script:StaticCallAllowed = @(
        'install.ps1'
        'uninstall.ps1'
        'tools/New-Manifest.ps1'
    )

    # Only these may talk to the network, and only on explicit user action.
    $script:NetworkAllowed = @(
        'install.ps1'
        'lib/40-commands.ps1'
    )

    function script:Get-RelativePath {
        param([string]$FullPath)
        $full = $FullPath.Replace('\', '/')
        $root = $script:Root.Replace('\', '/')
        if ($full.StartsWith($root)) {
            $full = $full.Substring($root.Length).TrimStart('/')
        }
        return $full
    }

    function script:Get-RepoTextFile {
        param([string]$Extension)
        $found = @()
        $found += Get-ChildItem -LiteralPath $script:Root -Recurse -Filter "*.$Extension" -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -notmatch '[\\/]\.git[\\/]' -and $_.FullName -notmatch '[\\/]\.docker-tmp[\\/]' }
        return $found
    }

    function script:Test-IsAscii {
        param([string]$Path)
        $text = Get-Content -LiteralPath $Path -Raw -ErrorAction SilentlyContinue
        if ($null -eq $text) { return $true }
        foreach ($ch in $text.ToCharArray()) {
            $code = [int]$ch
            if ($code -gt 126) { return $false }
            if ($code -lt 32 -and $code -ne 9 -and $code -ne 10 -and $code -ne 13) { return $false }
        }
        return $true
    }

    function script:Get-ParsedFile {
        param([string]$Path)
        $errors = $null
        $tokens = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
        return [pscustomobject]@{
            Path   = (script:Get-RelativePath $Path)
            Ast    = $ast
            Tokens = $tokens
            Errors = $errors
        }
    }

    $script:ScriptFiles = @(script:Get-RepoTextFile -Extension 'ps1')
    $script:Parsed = @($script:ScriptFiles | ForEach-Object { script:Get-ParsedFile -Path $_.FullName })
}

Describe 'Constraint: pure ASCII source' {
    It 'has no non-ASCII byte in any <Extension> file' -ForEach @(
        @{ Extension = 'ps1' }
        @{ Extension = 'md' }
        @{ Extension = 'json' }
        @{ Extension = 'sh' }
        @{ Extension = 'yml' }
    ) {
        $offenders = @()
        foreach ($file in (script:Get-RepoTextFile -Extension $Extension)) {
            if (-not (script:Test-IsAscii -Path $file.FullName)) {
                $offenders += (script:Get-RelativePath $file.FullName)
            }
        }
        $offenders -join ', ' | Should -Be '' -Because 'the prompt and every script must render in a stock font and load correctly on 5.1'
    }
}

Describe 'Constraint: every script parses' {
    It 'parses all <Count> script files' {
        $script:Parsed.Count | Should -BeGreaterThan 0 -Because 'the suite must not pass vacuously on an empty tree'
        $broken = @()
        foreach ($item in $script:Parsed) {
            if ($item.Errors -and $item.Errors.Count -gt 0) {
                $broken += ('{0}: {1}' -f $item.Path, $item.Errors[0].Message)
            }
        }
        $broken -join ' | ' | Should -Be '' -Because 'a parse error means the profile fails to load in the user shell'
    }
}

Describe 'Constraint: Windows PowerShell 5.1 syntax' {
    It 'contains no pipeline-chain (&& / ||) syntax' {
        $offenders = @()
        foreach ($item in $script:Parsed) {
            $found = $item.Ast.FindAll({
                    param($node)
                    $node.GetType().Name -eq 'PipelineChainAst'
                }, $true)
            if ($found -and $found.Count -gt 0) { $offenders += $item.Path }
        }
        $offenders -join ', ' | Should -Be '' -Because '&& and || do not work on 5.1'
    }

    It 'contains no ternary (condition ? a : b) syntax' {
        $offenders = @()
        foreach ($item in $script:Parsed) {
            $found = $item.Ast.FindAll({
                    param($node)
                    $node.GetType().Name -eq 'TernaryExpressionAst'
                }, $true)
            if ($found -and $found.Count -gt 0) { $offenders += $item.Path }
        }
        $offenders -join ', ' | Should -Be '' -Because 'the ternary operator does not work on 5.1'
    }

    It 'contains no null-coalescing (??) or null-conditional (?.) syntax' {
        $offenders = @()
        foreach ($item in $script:Parsed) {
            foreach ($token in $item.Tokens) {
                if ($token.Text -eq '??' -or $token.Text -eq '??=' -or $token.Text -eq '?.') {
                    $offenders += ('{0} (token {1})' -f $item.Path, $token.Text)
                }
            }
        }
        $offenders -join ', ' | Should -Be '' -Because 'these operators do not work on 5.1'
    }

    It 'contains no class or using-namespace declarations' {
        $offenders = @()
        foreach ($item in $script:Parsed) {
            $found = $item.Ast.FindAll({
                    param($node)
                    $node.GetType().Name -eq 'TypeDefinitionAst' -or $node.GetType().Name -eq 'UsingStatementAst'
                }, $true)
            if ($found -and $found.Count -gt 0) { $offenders += $item.Path }
        }
        $offenders -join ', ' | Should -Be '' -Because 'class definitions are 5.0+/7 syntax and unavailable in ConstrainedLanguage'
    }

    It 'does not use $IsWindows, $PSStyle, backtick-e or -Parallel' {
        # This file necessarily mentions the forbidden tokens as string literals,
        # so the raw-token scan skips itself. Every other check still applies to it.
        $selfPath = 'test/11-Compat.Tests.ps1'
        $offenders = @()
        foreach ($item in $script:Parsed) {
            $relative = $item.Path
            if ($relative -eq $selfPath) { continue }
            foreach ($token in $item.Tokens) {
                $text = $token.Text
                if ($text.Contains('$IsWindows')) { $offenders += ('{0}: $IsWindows' -f $relative) }
                if ($text.Contains('$PSStyle')) { $offenders += ('{0}: $PSStyle' -f $relative) }
                if ($text.Contains('`e')) { $offenders += ('{0}: backtick-e escape' -f $relative) }
                if ($text -eq '-Parallel') { $offenders += ('{0}: -Parallel' -f $relative) }
            }
        }
        $offenders -join ', ' | Should -Be '' -Because '$IsWindows and $PSStyle do not exist on 5.1 and -Parallel requires 7'
    }
}

Describe 'Constraint: no dangerous or forbidden commands' {
    It 'does not use Invoke-Expression, Add-Type, COM objects or script-block creation' {
        $forbidden = @('Invoke-Expression', 'iex', 'Add-Type', 'New-Object')
        $offenders = @()
        foreach ($item in $script:Parsed) {
            foreach ($node in $item.Ast.FindAll({ param($n) $n.GetType().Name -eq 'CommandAst' }, $true)) {
                $name = $node.GetCommandName()
                if (-not $name) { continue }
                if ($name -eq 'New-Object') {
                    # New-Object is only banned for COM: it needs CLR interop that CLM blocks.
                    $text = $node.Extent.Text
                    if ($text -match '-ComObject') { $offenders += ('{0}: New-Object -ComObject' -f $item.Path) }
                    continue
                }
                if ($forbidden -contains $name) {
                    $offenders += ('{0}: {1}' -f $item.Path, $name)
                }
            }
        }
        $offenders -join ', ' | Should -Be '' -Because 'Invoke-Expression and Add-Type are blocked in ConstrainedLanguage and are an injection risk'
    }

    It 'does not start background jobs or runspaces at load time' {
        $offenders = @()
        foreach ($item in $script:Parsed) {
            foreach ($node in $item.Ast.FindAll({ param($n) $n.GetType().Name -eq 'CommandAst' }, $true)) {
                $name = $node.GetCommandName()
                if ($name -eq 'Start-Job' -or $name -eq 'Start-ThreadJob' -or $name -eq 'Register-ScheduledJob') {
                    $offenders += ('{0}: {1}' -f $item.Path, $name)
                }
            }
        }
        $offenders -join ', ' | Should -Be '' -Because 'a background job costs ~300ms at every shell start and is unnecessary here'
    }

    It 'uses network cmdlets only in the installer and explicit update verb' {
        $allowed = $script:NetworkAllowed
        $networkCommands = @('Invoke-WebRequest', 'Invoke-RestMethod', 'curl', 'curl.exe', 'wget', 'Start-BitsTransfer')
        $offenders = @()
        foreach ($item in $script:Parsed) {
            if ($allowed -contains $item.Path) { continue }
            foreach ($node in $item.Ast.FindAll({ param($n) $n.GetType().Name -eq 'CommandAst' }, $true)) {
                $name = $node.GetCommandName()
                if ($networkCommands -contains $name) {
                    $offenders += ('{0}: {1}' -f $item.Path, $name)
                }
            }
        }
        $offenders -join ', ' | Should -Be '' -Because ("the shell must start with zero network calls (allowed: {0})" -f ($allowed -join ', '))
    }
}

Describe 'Constraint: ConstrainedLanguage safety' {
    It 'does not call .NET static methods in the runtime path' {
        $offenders = @()
        foreach ($item in $script:Parsed) {
            if ($script:StaticCallAllowed -contains $item.Path) { continue }
            if ($item.Path.StartsWith('test/')) { continue }
            foreach ($node in $item.Ast.FindAll({ param($n) $n.GetType().Name -eq 'InvokeMemberExpressionAst' }, $true)) {
                if ($node.Expression.GetType().Name -eq 'TypeExpressionAst') {
                    $typeName = $node.Expression.Extent.Text
                    $memberName = ''
                    if ($node.Member) { $memberName = $node.Member.Extent.Text }
                    $offenders += ('{0}: {1}::{2}' -f $item.Path, $typeName, $memberName)
                }
            }
        }
        $offenders -join ', ' | Should -Be '' -Because 'static method calls throw in ConstrainedLanguage, which is common on managed machines'
    }

    It 'uses only allowlisted type literals in the runtime path' {
        $allowlist = @(
            'ordered', 'pscustomobject', 'version', 'int', 'int32', 'int64', 'long',
            'double', 'decimal', 'char', 'string', 'regex', 'switch', 'hashtable',
            'array', 'bool', 'boolean', 'datetime', 'timespan', 'consolecolor',
            'pscredential', 'guid', 'byte', 'object', 'void', 'type', 'scriptblock',
            'collections.hashtable', 'wildcardpattern'
        )
        $offenders = @()
        foreach ($item in $script:Parsed) {
            if ($item.Path.StartsWith('test/') -or $script:StaticCallAllowed -contains $item.Path) { continue }
            foreach ($node in $item.Ast.FindAll({ param($n) $n.GetType().Name -eq 'TypeExpressionAst' }, $true)) {
                $text = $node.Extent.Text
                if ($text -match '^\[') { $text = $text.Substring(1) }
                if ($text -match '\]$') { $text = $text.Substring(0, $text.Length - 1) }
                $text = $text.Trim()
                $text = ($text -replace '^System\.', '')
                $text = $text.ToLower()
                if ($allowlist -notcontains $text) {
                    $offenders += ('{0}: [{1}]' -f $item.Path, $text)
                }
            }
        }
        $offenders -join ', ' | Should -Be '' -Because 'arbitrary .NET types are blocked in ConstrainedLanguage and may be absent on 5.1'
    }
}

Describe 'Constraint: version and packaging' {
    It 'declares #Requires -Version 5.1 in every script' {
        $offenders = @()
        foreach ($file in $script:ScriptFiles) {
            $relative = script:Get-RelativePath $file.FullName
            $head = Get-Content -LiteralPath $file.FullName -TotalCount 5 -ErrorAction SilentlyContinue
            $joined = ($head -join "`n")
            if ($joined -notmatch '#Requires\s+-Version\s+5\.1') {
                $offenders += $relative
            }
        }
        $offenders -join ', ' | Should -Be '' -Because 'an explicit floor turns a confusing runtime error into a clear one'
    }

    It 'has a manifest.json that matches lib/00-core.ps1' {
        $manifestPath = Join-Path $script:Root 'manifest.json'
        Test-Path -LiteralPath $manifestPath | Should -BeTrue -Because 'the installer needs a manifest to resolve version and hashes'

        $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
        $coreText = Get-Content -LiteralPath (Join-Path $script:Root 'lib/00-core.ps1') -Raw
        $coreVersion = $null
        if ($coreText -match "Version\s*=\s*'([0-9]+\.[0-9]+\.[0-9]+)'") { $coreVersion = $Matches[1] }

        $coreVersion | Should -Not -BeNullOrEmpty -Because 'the version must be readable from lib/00-core.ps1'
        $manifest.version | Should -Be $coreVersion -Because 'a mismatch means the installer ships one version and reports another'
    }

    It 'lists every runtime file in the manifest with a matching hash' {
        $manifestPath = Join-Path $script:Root 'manifest.json'
        Test-Path -LiteralPath $manifestPath | Should -BeTrue
        $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json

        $problems = @()
        foreach ($entry in $manifest.files) {
            $full = Join-Path $script:Root $entry.path
            if (-not (Test-Path -LiteralPath $full)) {
                $problems += ('{0}: missing on disk' -f $entry.path)
                continue
            }
            $actual = (Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash.ToLower()
            if ($actual -ne ([string]$entry.sha256).ToLower()) {
                $problems += ('{0}: hash mismatch (manifest {1}, disk {2})' -f $entry.path, $entry.sha256, $actual)
            }
        }
        $problems -join ' | ' | Should -Be '' -Because 'stale hashes make the installer abort on a valid release'
    }

    It 'covers every shipped lib file in the manifest' {
        $manifestPath = Join-Path $script:Root 'manifest.json'
        Test-Path -LiteralPath $manifestPath | Should -BeTrue
        $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
        $listed = @($manifest.files | ForEach-Object { $_.path })

        $missing = @()
        foreach ($file in (Get-ChildItem -LiteralPath (Join-Path $script:Root 'lib') -Filter '*.ps1' -ErrorAction SilentlyContinue)) {
            $relative = 'lib/' + $file.Name
            if ($listed -notcontains $relative) { $missing += $relative }
        }
        if ($listed -notcontains 'profile/profile.ps1') { $missing += 'profile/profile.ps1' }
        if ($listed -notcontains 'ux.ps1') { $missing += 'ux.ps1' }

        $missing -join ', ' | Should -Be '' -Because 'a lib file that is not in the manifest never reaches the user'
    }
}
