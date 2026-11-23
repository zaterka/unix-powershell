#Requires -Version 5.1
# ---------------------------------------------------------------------------
# lib/10-git.ps1 -- git repository discovery + prompt model (PLAN.md 5.2, 6).
#
# Public surface:
#   Get-UxGitModel -Path <string>   -> @{ Root; Branch; Detached; ShortSha;
#                                        Dirty; Ahead; Behind; State; IsRepo }
#   Reset-UxGitCache                -> drop every memo + reset the degradation counter
#   Get-UxGitStatusCapability       -> @{ Mode; Version; Reason }  (probes `git --version` once)
#   Get-UxGitDiagnostics            -> @{ Message; Blocked; Reason; Degraded; Slow } for `ux doctor`
#
# Rules this file obeys:
#   * Windows PowerShell 5.1 syntax only: no pipeline chains, no ternary, no null-coalescing,
#     no null-conditional, no PS7 style/escape helpers.
#   * Pure ASCII. No Invoke-Expression / Add-Type / COM / reflection / .NET *static* calls.
#   * Strict-mode-proof (Set-StrictMode -Version Latest): every variable initialised,
#     .ContainsKey() instead of a bare index, PSObject.Properties[] instead of a bare property.
#   * Never throws: every public function is a try/catch boundary that degrades.
#   * No network, no jobs, no parallel work. The no-binary path is a handful of file reads.
#
# Cost model (this is the whole point of the file):
#   1) Discovery walks up from the requested path, one `Test-Path .git` per level, and is
#      memoised per requested path -- including "not a repo", so a dead mapped drive costs
#      one stat per session instead of one per prompt.
#   2) Branch / detached / state come from file reads only (HEAD, refs, packed-refs, state
#      files). That path always works, with or without a git binary.
#   3) Dirty + ahead/behind need the binary: at most ONE `git status` process per cache
#      window (git.cacheMs, default 2000 ms), never one per prompt.
#   4) The `git --version` probe is a SECOND process, so the model path never spawns it:
#      it uses the version already known ($global:Ux.Caps.GitVersion, filled by the core
#      capability probe or by an explicit Get-UxGitStatusCapability call) and otherwise
#      falls back to portable `--porcelain --branch`, which every git since ~1.7
#      understands and which still carries ahead/behind. That keeps the strict
#      "at most one git process per prompt" contract true even on the very first prompt.
# ---------------------------------------------------------------------------

$script:UxGitLastError = ''
$script:UxGitSlowCount = 0
$script:UxGitDegraded = $false
$script:UxGitBlocked = $false
$script:UxGitBlockReason = ''
$script:UxGitVersion = ''
$script:UxGitCapability = $null
$script:UxGitModeOverride = ''
$script:UxGitNoLocksUnsupported = $false
$script:UxGitHelpers = @{}

# ---------------------------------------------------------------------------
# Small local helpers (this file may be smoke-tested without lib/00-core.ps1).
# ---------------------------------------------------------------------------
function Test-UxGitHelperAvailable {
    param([string]$Name)
    # Resolved once per session. `Get-Command <missing name>` costs milliseconds
    # (measured 3.7 ms) because it scans every command source; a provider lookup on
    # the Function: drive costs ~0.09 ms. Called on the prompt path, so it matters.
    if ($null -eq $Name -or $Name.Length -eq 0) { return $false }
    if ($script:UxGitHelpers.ContainsKey($Name)) { return [bool]$script:UxGitHelpers[$Name] }

    $available = $false
    try { $available = [bool](Test-Path -Path ('Function:' + $Name)) } catch { $available = $false }
    if (-not $available) {
        # No Function: drive (unusual host): fall back once, never on every call.
        try {
            $command = Get-Command -Name $Name -ErrorAction SilentlyContinue
            if ($null -ne $command) { $available = $true }
        } catch {
            $available = $false
        }
    }
    $script:UxGitHelpers[$Name] = $available
    return $available
}

function Get-UxGitDebug {
    param([string]$Message)
    # Write-UxDebug when core is loaded, otherwise honour UX_DEBUG directly.
    try {
        if ($env:UX_DEBUG -ne '1') { return }
        if (Test-UxGitHelperAvailable -Name 'Write-UxDebug') {
            Write-UxDebug -Message $Message
            return
        }
        Write-Host ('[ux-git] ' + $Message) -ForegroundColor DarkGray
    } catch { }
}

function Get-UxGitGlobals {
    # The shared $global:Ux state, created on demand so this file also runs standalone.
    # Direct scoped access (~0.03 ms) rather than Get-Variable (~0.13 ms): the strict-mode
    # "variable not set" error is a normal, catchable error and only happens until the
    # stand-in table is created.
    $state = $null
    try { $state = $global:Ux } catch { $state = $null }
    if ($false -eq ($state -is [hashtable])) {
        $state = @{}
        try { $global:Ux = $state } catch { }
    }
    $usable = $false
    if ($state.ContainsKey('GitCache')) {
        $existing = $state['GitCache']
        if ($existing -is [hashtable]) { $usable = $true }
    }
    if (-not $usable) { $state['GitCache'] = @{} }
    return $state
}

function Get-UxGitCache {
    $state = Get-UxGitGlobals
    return $state['GitCache']
}

function Get-UxGitHome {
    $home = ''
    try { if ($null -ne $HOME) { $home = [string]$HOME } } catch { $home = '' }
    if ($home.Length -eq 0) { try { $home = [string]$env:USERPROFILE } catch { $home = '' } }
    if ($null -eq $home) { $home = '' }
    return $home
}

function Get-UxGitBasePath {
    $path = ''
    try { $path = [string](Get-Location).Path } catch { $path = '' }
    if ($null -eq $path -or $path.Length -eq 0) { try { $path = [string]$PWD } catch { $path = '' } }
    if ($null -eq $path) { $path = '' }
    return $path
}

function Get-UxGitConfigValue {
    param([string]$Key, $Default = $null)

    # Preferred source: the core helper. Guarded because this file is also loaded alone.
    try {
        if (Test-UxGitHelperAvailable -Name 'Get-UxConfig') {
            $value = Get-UxConfig -Path $Key -Default $Default
            if ($null -ne $value) { return $value }
            return $Default
        }
    } catch { }

    # Fallback: walk $global:Ux.Config ourselves (dotted path, hashtable or object).
    try {
        $state = Get-UxGitGlobals
        if (-not $state.ContainsKey('Config')) { return $Default }
        $node = $state['Config']
        if ($null -eq $node) { return $Default }
        foreach ($segment in ($Key -split '\.')) {
            if ($null -eq $segment -or $segment.Length -eq 0) { continue }
            if ($null -eq $node) { return $Default }
            if ($node -is [hashtable]) {
                if (-not $node.ContainsKey($segment)) { return $Default }
                $node = $node[$segment]
                continue
            }
            $property = $null
            try { $property = $node.PSObject.Properties[$segment] } catch { $property = $null }
            if ($null -eq $property) { return $Default }
            $node = $property.Value
        }
        if ($null -eq $node) { return $Default }
        return $node
    } catch { }

    return $Default
}

function Get-UxGitIntConfig {
    param([string]$Key, [int]$Default, [int]$Minimum)

    $raw = $null
    try { $raw = Get-UxGitConfigValue -Key $Key -Default $Default } catch { $raw = $Default }
    $value = $Default
    if ($null -ne $raw) {
        try { $value = [int]$raw } catch { $value = $Default }
    }
    if ($value -lt $Minimum) { $value = $Minimum }
    return $value
}

function Get-UxGitBoolConfig {
    param([string]$Key, [bool]$Default)

    $raw = $null
    try { $raw = Get-UxGitConfigValue -Key $Key -Default $Default } catch { $raw = $Default }
    if ($null -eq $raw) { return $Default }
    if ($raw -is [bool]) { return [bool]$raw }
    $text = ''
    try { $text = ([string]$raw).Trim().ToLower() } catch { $text = '' }
    if ($text -eq 'true' -or $text -eq '1' -or $text -eq 'yes' -or $text -eq 'on') { return $true }
    if ($text -eq 'false' -or $text -eq '0' -or $text -eq 'no' -or $text -eq 'off') { return $false }
    return $Default
}

# ---------------------------------------------------------------------------
# Path helpers -- pure string work, no [System.IO.*], no Resolve-Path surprises.
# ---------------------------------------------------------------------------
function ConvertTo-UxGitCleanPath {
    param([string]$Path)
    # Collapses '.', '..' and duplicate separators without touching the file system.
    if ($null -eq $Path) { return '' }
    $text = $Path.Trim()
    if ($text.Length -eq 0) { return '' }

    $separator = [string][char]47
    try { if ($env:OS -eq 'Windows_NT') { $separator = [string][char]92 } } catch { }

    $root = ''
    $rest = $text
    if ($text -match '^([A-Za-z]:)[\\/]*') {
        $root = $Matches[1] + $separator
        $rest = $text.Substring($Matches[0].Length)
    } elseif ($text -match '^[\\/]{2}([^\\/]+)[\\/]+([^\\/]+)[\\/]*') {
        $root = $separator + $separator + $Matches[1] + $separator + $Matches[2] + $separator
        $rest = $text.Substring($Matches[0].Length)
    } elseif ($text -match '^[\\/]+') {
        $root = $separator
        $rest = $text.Substring($Matches[0].Length)
    }

    $segments = @()
    foreach ($segment in ($rest -split '[\\/]+')) {
        if ($null -eq $segment) { continue }
        if ($segment.Length -eq 0) { continue }
        if ($segment -eq '.') { continue }
        if ($segment -eq '..') {
            if ($segments.Count -gt 1) {
                $segments = $segments[0..($segments.Count - 2)]
            } elseif ($segments.Count -eq 1) {
                $segments = @()
            }
            continue
        }
        $segments += $segment
    }

    if ($root.Length -eq 0) {
        if ($segments.Count -eq 0) { return '.' }
        return ($segments -join $separator)
    }
    if ($segments.Count -eq 0) { return $root }
    return ($root + ($segments -join $separator))
}

function ConvertTo-UxGitFullPath {
    param([string]$Base, [string]$Path)
    # Joins Base + Path and collapses the result. Returns '' when impossible.
    if ($null -eq $Path) { return '' }
    $text = $Path.Trim()
    if ($text.Length -eq 0) { return '' }

    if ($text -eq '~') {
        $text = Get-UxGitHome
    } elseif ($text -match '^~[\\/]') {
        $text = (Get-UxGitHome) + $text.Substring(1)
    }
    if ($text.Length -eq 0) { return '' }

    $absolute = $false
    if ($text -match '^[A-Za-z]:') { $absolute = $true }
    elseif ($text -match '^[\\/]') { $absolute = $true }

    if (-not $absolute) {
        if ($null -eq $Base -or $Base.Length -eq 0) { return '' }
        $text = $Base + '/' + $text
    }
    return (ConvertTo-UxGitCleanPath -Path $text)
}

function Join-UxGitPath {
    param([string]$Base, [string]$Child)
    # Cheap join for an already-canonical git dir plus a plain name ('HEAD', 'index',
    # 'MERGE_HEAD', 'packed-refs', ...). No '.', '..' or '~' handling on purpose:
    # that work belongs to ConvertTo-UxGitFullPath and costs 3x more.
    if ($null -eq $Base -or $Base.Length -eq 0) { return '' }
    if ($null -eq $Child -or $Child.Length -eq 0) { return $Base }
    if ($Base.EndsWith('/') -or $Base.EndsWith('\')) { return ($Base + $Child) }
    return ($Base + '/' + $Child)
}

# ---------------------------------------------------------------------------
# Discovery (no process). Returns @{ Root; GitDir; CommonDir } or $null.
# ---------------------------------------------------------------------------
function Test-UxGitFileItem {
    param([string]$Path, [string]$Kind)

    if ($null -eq $Path -or $Path.Length -eq 0) { return $false }
    $result = $false
    try {
        if ($Kind -eq 'leaf') {
            $result = Test-Path -LiteralPath $Path -PathType Leaf -ErrorAction Stop
        } elseif ($Kind -eq 'container') {
            $result = Test-Path -LiteralPath $Path -PathType Container -ErrorAction Stop
        } else {
            $result = Test-Path -LiteralPath $Path -ErrorAction Stop
        }
    } catch {
        $result = $false
    }
    if ($null -eq $result) { $result = $false }
    return [bool]$result
}

function Read-UxGitTextFile {
    param([string]$Path)

    if ($null -eq $Path -or $Path.Length -eq 0) { return $null }
    $raw = $null
    try { $raw = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop } catch { return $null }
    if ($null -eq $raw) { return $null }
    return [string]$raw
}

function Get-UxGitFirstLine {
    param([string]$Text)

    if ($null -eq $Text) { return '' }
    foreach ($line in ($Text -split "[`r`n]")) {
        if ($null -eq $line) { continue }
        $trimmed = $line.Trim()
        if ($trimmed.Length -gt 0) { return $trimmed }
    }
    return ''
}

function Get-UxGitCommonDir {
    param([string]$GitDir)
    # A linked worktree keeps HEAD locally but refs/ + packed-refs in the common dir,
    # which `<gitdir>/commondir` names relative to the git dir. Absent -> same dir.
    if ($null -eq $GitDir -or $GitDir.Length -eq 0) { return '' }

    $commonFile = Join-UxGitPath -Base $GitDir -Child 'commondir'
    if ($commonFile.Length -eq 0) { return $GitDir }
    if (-not (Test-UxGitFileItem -Path $commonFile -Kind 'leaf')) { return $GitDir }

    $line = Get-UxGitFirstLine -Text (Read-UxGitTextFile -Path $commonFile)
    if ($line.Length -eq 0) { return $GitDir }

    $resolved = ConvertTo-UxGitFullPath -Base $GitDir -Path $line
    if ($resolved.Length -eq 0) { return $GitDir }
    if (-not (Test-UxGitFileItem -Path $resolved -Kind 'container')) { return $GitDir }
    return $resolved
}

function Get-UxGitDirFileTarget {
    param([string]$FilePath, [string]$Base)
    # `.git` as a FILE (worktree / submodule): "gitdir: <path>", relative to its own dir.
    $raw = Read-UxGitTextFile -Path $FilePath
    if ($null -eq $raw) { return '' }
    $line = Get-UxGitFirstLine -Text $raw
    if ($line.Length -eq 0) { return '' }
    if ($line -notmatch '^gitdir:\s*(.+)$') { return '' }
    $target = $Matches[1].Trim()
    if ($target.Length -eq 0) { return '' }
    return (ConvertTo-UxGitFullPath -Base $Base -Path $target)
}

function Get-UxGitDirAt {
    param([string]$Directory)
    # @{ Root; GitDir; CommonDir } when this directory carries a usable .git, else $null.
    if ($null -eq $Directory -or $Directory.Length -eq 0) { return $null }

    $entry = ''
    try { $entry = Join-Path -Path $Directory -ChildPath '.git' } catch { return $null }
    if ($null -eq $entry -or $entry.Length -eq 0) { return $null }

    if (Test-UxGitFileItem -Path $entry -Kind 'container') {
        $common = Get-UxGitCommonDir -GitDir $entry
        return @{ Root = $Directory; GitDir = $entry; CommonDir = $common }
    }

    if (-not (Test-UxGitFileItem -Path $entry -Kind 'leaf')) { return $null }

    $target = Get-UxGitDirFileTarget -FilePath $entry -Base $Directory
    if ($target.Length -eq 0) { return $null }
    if (-not (Test-UxGitFileItem -Path $target -Kind 'container')) { return $null }
    $common = Get-UxGitCommonDir -GitDir $target
    return @{ Root = $Directory; GitDir = $target; CommonDir = $common }
}

function Resolve-UxGitStartDirectory {
    param([string]$Path)
    # Full path of the directory to start the walk from; '' when the path is unusable
    # (missing, unresolvable, or a non-FileSystem provider such as Registry:: / Cert:).
    if ($null -eq $Path -or $Path.Length -eq 0) { return '' }

    $item = $null
    try { $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop } catch { return '' }
    if ($null -eq $item) { return '' }

    $provider = ''
    try { $provider = [string]$item.PSProvider.Name } catch { return '' }
    if ($provider -ne 'FileSystem') { return '' }

    $full = ''
    try { $full = [string]$item.FullName } catch { return '' }
    if ($full.Length -eq 0) { return '' }

    $isContainer = $true
    try { $isContainer = [bool]$item.PSIsContainer } catch { $isContainer = $true }
    if (-not $isContainer) {
        $parent = ''
        try { $parent = [string](Split-Path -Parent -Path $full) } catch { $parent = '' }
        if ($null -eq $parent -or $parent.Length -eq 0) { return '' }
        $full = $parent
    }
    return $full
}

function Find-UxGitLayout {
    param([string]$Path)

    $start = $Path
    if ($null -eq $start -or $start.Length -eq 0) { $start = Get-UxGitBasePath }
    if ($null -eq $start -or $start.Length -eq 0) { return $null }

    $current = Resolve-UxGitStartDirectory -Path $start
    if ($current.Length -eq 0) { return $null }

    $maxDepth = Get-UxGitIntConfig -Key 'git.maxDepth' -Default 40 -Minimum 1
    $depth = 0
    while ($true) {
        if ($depth -ge $maxDepth) { return $null }
        $depth = $depth + 1

        $found = Get-UxGitDirAt -Directory $current
        if ($null -ne $found) { return $found }

        $parent = ''
        try { $parent = [string](Split-Path -Parent -Path $current) } catch { $parent = '' }
        if ($null -eq $parent -or $parent.Length -eq 0) { return $null }
        if ($parent -eq $current) { return $null }
        $current = $parent
    }
}

# ---------------------------------------------------------------------------
# Branch / detached / state without the git binary.
# ---------------------------------------------------------------------------
function Get-UxGitPackedRefs {
    param([string]$CommonDir, [string]$GitDir)
    # Only read when a loose ref is missing, so packed-refs cost is paid at most once
    # per cache window and never for a normal checkout.
    $result = @{}
    $directories = @()
    if ($null -ne $CommonDir -and $CommonDir.Length -gt 0) { $directories += $CommonDir }
    if ($null -ne $GitDir -and $GitDir.Length -gt 0) {
        if ($GitDir -ne $CommonDir) { $directories += $GitDir }
    }
    foreach ($dir in $directories) {
        $path = Join-UxGitPath -Base $dir -Child 'packed-refs'
        if ($path.Length -eq 0) { continue }
        if (-not (Test-UxGitFileItem -Path $path -Kind 'leaf')) { continue }

        $raw = Read-UxGitTextFile -Path $path
        if ($null -eq $raw) { continue }
        foreach ($line in ($raw -split "[`r`n]")) {
            if ($null -eq $line) { continue }
            $text = $line.Trim()
            if ($text.Length -eq 0) { continue }
            if ($text -match '^#') { continue }
            if ($text -match '^\^') { continue }
            $parts = @($text -split '\s+')
            if ($parts.Count -lt 2) { continue }
            $name = [string]$parts[1]
            $oid = [string]$parts[0]
            if ($name.Length -eq 0) { continue }
            if (-not $result.ContainsKey($name)) { $result[$name] = $oid }
        }
        return $result
    }
    return $result
}

function Test-UxGitRefExists {
    param([string]$RefName, [string]$GitDir, [string]$CommonDir)

    if ($null -eq $RefName -or $RefName.Length -eq 0) { return $false }
    # A normal checkout has CommonDir -eq GitDir: check that directory once, not twice.
    $directories = @()
    if ($null -ne $CommonDir -and $CommonDir.Length -gt 0) { $directories += $CommonDir }
    if ($null -ne $GitDir -and $GitDir.Length -gt 0) {
        if ($GitDir -ne $CommonDir) { $directories += $GitDir }
    }
    foreach ($dir in $directories) {
        $path = ConvertTo-UxGitFullPath -Base $dir -Path $RefName
        if ($path.Length -eq 0) { continue }
        if (Test-UxGitFileItem -Path $path -Kind 'leaf') { return $true }
    }
    $packed = Get-UxGitPackedRefs -CommonDir $CommonDir -GitDir $GitDir
    return $packed.ContainsKey($RefName)
}

function Get-UxGitActivityState {
    param([string]$GitDir)
    # First match wins; order is the one documented in PLAN.md 5.2.
    if ($null -eq $GitDir -or $GitDir.Length -eq 0) { return '' }
    $probes = @(
        @{ Name = 'MERGE_HEAD'; State = 'MERGING' },
        @{ Name = 'rebase-merge'; State = 'REBASE' },
        @{ Name = 'rebase-apply'; State = 'REBASE' },
        @{ Name = 'CHERRY_PICK_HEAD'; State = 'PICK' },
        @{ Name = 'REVERT_HEAD'; State = 'REVERT' },
        @{ Name = 'BISECT_LOG'; State = 'BISECT' }
    )
    foreach ($probe in $probes) {
        $path = Join-UxGitPath -Base $GitDir -Child ([string]$probe['Name'])
        if ($path.Length -eq 0) { continue }
        # Direct Test-Path: this loop runs on every uncached prompt and the -Kind wrapper
        # costs twice a raw Test-Path (measured). One try/catch per probe is enough.
        $exists = $false
        try { $exists = [bool](Test-Path -LiteralPath $path -ErrorAction Stop) } catch { $exists = $false }
        if ($exists) { return [string]$probe['State'] }
    }
    return ''
}

function Get-UxGitRefState {
    param([string]$GitDir, [string]$CommonDir)
    # @{ Ok; Branch; Detached; ShortSha; State; Unborn }. Ok=$false means "no usable HEAD".
    $result = @{
        Ok       = $false
        Branch   = $null
        Detached = $false
        ShortSha = $null
        State    = ''
        Unborn   = $false
    }

    $headPath = Join-UxGitPath -Base $GitDir -Child 'HEAD'
    if ($headPath.Length -eq 0) { return $result }
    $raw = Read-UxGitTextFile -Path $headPath
    if ($null -eq $raw) { return $result }
    $head = $raw.Trim()
    if ($head.Length -eq 0) { return $result }

    if ($head -match '^ref:\s*(\S+)\s*$') {
        $refName = $Matches[1]
        $branch = $refName
        if ($branch -match '^refs/heads/(.+)$') { $branch = $Matches[1] }
        $result['Branch'] = $branch
        $result['Ok'] = $true
        if (-not (Test-UxGitRefExists -RefName $refName -GitDir $GitDir -CommonDir $CommonDir)) {
            $result['Unborn'] = $true
        }
    } elseif ($head -match '^[0-9a-fA-F]{7,64}$') {
        $oid = ''
        try { $oid = $head.ToLower() } catch { $oid = $head }
        $short = $oid
        if ($short.Length -gt 7) { $short = $short.Substring(0, 7) }
        $result['Detached'] = $true
        $result['ShortSha'] = $short
        $result['Branch'] = $short
        $result['Ok'] = $true
    } else {
        # Unparseable HEAD: treat the directory as not a repository (degrades safely).
        return $result
    }

    $state = Get-UxGitActivityState -GitDir $GitDir
    if ($state.Length -gt 0) {
        $result['State'] = $state
    } elseif ($result['Unborn']) {
        $result['State'] = 'NEW'
    }
    return $result
}

function New-UxGitModel {
    # Exact public shape: nine keys, nothing else.
    return @{
        Root     = $null
        Branch   = $null
        Detached = $null
        ShortSha = $null
        Dirty    = $null
        Ahead    = 0
        Behind   = 0
        State    = ''
        IsRepo   = $false
    }
}

function Copy-UxGitModel {
    param($Model)

    $copy = New-UxGitModel
    if ($false -eq ($Model -is [hashtable])) { return $copy }
    foreach ($key in @('Root', 'Branch', 'Detached', 'ShortSha', 'Dirty', 'Ahead', 'Behind', 'State', 'IsRepo')) {
        if ($Model.ContainsKey($key)) { $copy[$key] = $Model[$key] }
    }
    return $copy
}

function Get-UxGitFileModel {
    param([string]$Root, [string]$GitDir, [string]$CommonDir)
    # Model from file reads only: Dirty stays $null (= unknown) until git fills it in.
    $state = Get-UxGitRefState -GitDir $GitDir -CommonDir $CommonDir
    if (-not $state['Ok']) { return $null }

    $model = New-UxGitModel
    $model['IsRepo'] = $true
    $model['Root'] = $Root
    $model['Branch'] = $state['Branch']
    $model['Detached'] = $state['Detached']
    $model['ShortSha'] = $state['ShortSha']
    $model['State'] = $state['State']
    return $model
}

function Get-UxGitStamp {
    param([string]$Path)
    # Ticks of the last write, 0 when unknown. Instance member, no .NET statics.
    if ($null -eq $Path -or $Path.Length -eq 0) { return [long]0 }
    $item = $null
    try { $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop } catch { return [long]0 }
    if ($null -eq $item) { return [long]0 }
    $ticks = [long]0
    try { $ticks = [long]$item.LastWriteTime.Ticks } catch { $ticks = [long]0 }
    return $ticks
}

# ---------------------------------------------------------------------------
# git binary: resolution, capability, one status call.
# ---------------------------------------------------------------------------
function Find-UxGitOnPath {
    # Manual PATH scan. Get-Command caches its lookup table, so a directory added to
    # PATH later in the session (a test shim, or a user) can be missed; this is the
    # fallback that still finds it. No process, a few Test-Path calls.
    $path = ''
    try { $path = [string]$env:PATH } catch { $path = '' }
    if ($null -eq $path -or $path.Length -eq 0) { return $null }

    $separator = ':'
    try { if ($env:OS -eq 'Windows_NT') { $separator = ';' } } catch { }
    $names = @('git')
    try { if ($env:OS -eq 'Windows_NT') { $names = @('git.exe', 'git.cmd', 'git.bat', 'git') } } catch { }

    foreach ($entry in ($path -split ('\' + $separator))) {
        if ($null -eq $entry) { continue }
        $dir = $entry.Trim()
        if ($dir.Length -ge 2) {
            if ($dir.StartsWith('"') -and $dir.EndsWith('"')) { $dir = $dir.Trim('"') }
        }
        if ($dir.Length -eq 0) { continue }
        foreach ($name in $names) {
            $candidate = $dir + '/' + $name
            if ($dir.EndsWith('/') -or $dir.EndsWith('\')) { $candidate = $dir + $name }
            if (Test-UxGitFileItem -Path $candidate -Kind 'leaf') { return $candidate }
        }
    }
    return $null
}

function Get-UxGitCommand {
    # Path of the git executable, or $null. Never spawns anything.
    $candidate = ''
    try {
        $command = Get-Command -Name 'git' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -ne $command) {
            try { $candidate = [string]$command.Source } catch { $candidate = '' }
            if ($candidate.Length -eq 0) { try { $candidate = [string]$command.Path } catch { $candidate = '' } }
        }
    } catch {
        $candidate = ''
    }
    if ($candidate.Length -eq 0) {
        $scanned = Find-UxGitOnPath
        if ($null -ne $scanned) { $candidate = [string]$scanned }
    }
    if ($candidate.Length -eq 0) { return $null }
    return $candidate
}

function Get-UxGitVersionText {
    param([string]$Text)
    # "git version 2.43.0.windows.1" -> "2.43.0"; "2.11" -> "2.11"; garbage -> $null.
    if ($null -eq $Text) { return $null }
    if ($Text -match '(\d+)\.(\d+)\.(\d+)') { return ($Matches[1] + '.' + $Matches[2] + '.' + $Matches[3]) }
    if ($Text -match '(\d+)\.(\d+)') { return ($Matches[1] + '.' + $Matches[2]) }
    return $null
}

function Test-UxGitVersionAtLeast {
    param([string]$Version, [int]$Major, [int]$Minor)

    # NOTE: PowerShell variables are case-insensitive, so the local names must not
    # differ from $Major/$Minor only by case -- that silently overwrites the bound
    # parameters and makes every version compare "at least".
    if ($null -eq $Version -or $Version.Length -eq 0) { return $false }
    $parts = @($Version -split '\.')
    $haveMajor = 0
    $haveMinor = 0
    if ($parts.Count -ge 1) { try { $haveMajor = [int]$parts[0] } catch { $haveMajor = 0 } }
    if ($parts.Count -ge 2) { try { $haveMinor = [int]$parts[1] } catch { $haveMinor = 0 } }
    if ($haveMajor -gt $Major) { return $true }
    if ($haveMajor -lt $Major) { return $false }
    return ($haveMinor -ge $Minor)
}

function Get-UxGitKnownVersion {
    # Version already known without spawning a process: this module's cache first,
    # then the value the core capability probe stored in $global:Ux.Caps.GitVersion.
    if ($null -ne $script:UxGitVersion) {
        if ($script:UxGitVersion.Length -gt 0) { return $script:UxGitVersion }
    }
    try {
        $state = Get-UxGitGlobals
        if ($state.ContainsKey('Caps')) {
            $caps = $state['Caps']
            if ($null -ne $caps -and $caps -is [hashtable]) {
                if ($caps.ContainsKey('GitVersion')) {
                    $value = $caps['GitVersion']
                    if ($null -ne $value) {
                        $text = ([string]$value).Trim()
                        if ($text.Length -gt 0) { return $text }
                    }
                }
            }
        }
    } catch { }
    return $null
}

function Set-UxGitKnownVersion {
    param([string]$Version)

    if ($null -eq $Version) { return }
    $text = $Version.Trim()
    if ($text.Length -eq 0) { return }
    $script:UxGitVersion = $text
    try {
        $state = Get-UxGitGlobals
        if ($state.ContainsKey('Caps')) {
            $caps = $state['Caps']
            if ($null -ne $caps -and $caps -is [hashtable]) { $caps['GitVersion'] = $text }
        }
    } catch { }
}

function New-UxGitCapability {
    param([string]$Mode, $Version, [string]$Reason)

    # $Version stays untyped on purpose: the contract is <string or $null>, and a
    # [string] parameter would silently turn the "unknown" case into an empty string.
    $versionText = $null
    if ($null -ne $Version) {
        $text = ([string]$Version).Trim()
        if ($text.Length -gt 0) { $versionText = $text }
    }
    return @{ Mode = $Mode; Version = $versionText; Reason = $Reason }
}

function Copy-UxGitCapability {
    param($Capability)

    if ($false -eq ($Capability -is [hashtable])) {
        return (New-UxGitCapability -Mode 'file-only' -Version $null -Reason 'no capability recorded')
    }
    $mode = 'file-only'
    $version = $null
    $reason = ''
    if ($Capability.ContainsKey('Mode')) { $mode = [string]$Capability['Mode'] }
    if ($Capability.ContainsKey('Version')) {
        if ($null -ne $Capability['Version']) { $version = [string]$Capability['Version'] }
    }
    if ($Capability.ContainsKey('Reason')) { $reason = [string]$Capability['Reason'] }
    return (New-UxGitCapability -Mode $mode -Version $version -Reason $reason)
}

function Get-UxGitModeFromVersion {
    param([string]$Version)

    if ($null -ne $Version -and $Version.Length -gt 0) {
        if (Test-UxGitVersionAtLeast -Version $Version -Major 2 -Minor 11) { return 'porcelain-v2' }
        return 'porcelain-v1'
    }
    # Unknown version: portable porcelain v1. Every git understands it and it still
    # carries branch + ahead/behind through the `## branch...upstream [ahead N]` header.
    return 'porcelain-v1'
}

function Resolve-UxGitMode {
    $mode = Get-UxGitModeFromVersion -Version (Get-UxGitKnownVersion)
    if ($null -ne $script:UxGitModeOverride) {
        if ($script:UxGitModeOverride.Length -gt 0) { return $script:UxGitModeOverride }
    }
    return $mode
}

function Invoke-UxGitVersionProbe {
    param([string]$Executable)

    if ($null -eq $Executable -or $Executable.Length -eq 0) { return $null }
    $version = $null
    $previous = 'Continue'
    try { $previous = $ErrorActionPreference } catch { $previous = 'Continue' }
    try {
        $ErrorActionPreference = 'Continue'
        $lines = @(& $Executable '--version' 2>&1)
        $code = 0
        try { if ($null -ne $LASTEXITCODE) { $code = [int]$LASTEXITCODE } } catch { $code = 0 }
        if ($code -eq 0) {
            foreach ($line in $lines) {
                if ($line -is [string]) {
                    $version = Get-UxGitVersionText -Text $line
                    if ($null -ne $version) { break }
                }
            }
        }
    } catch {
        $version = $null
    } finally {
        try { $ErrorActionPreference = $previous } catch { }
    }
    return $version
}

function Get-UxGitStatusCapability {
    # Exported for `ux doctor`. Probes `git --version` ONCE per session and caches the
    # answer in $script:UxGitCapability and $global:Ux.Caps.GitVersion.
    # The model path deliberately does not call this (see the header comment): the probe
    # is a second process and the prompt may only afford one.
    try {
        if ($null -ne $script:UxGitCapability) { return (Copy-UxGitCapability -Capability $script:UxGitCapability) }

        $version = Get-UxGitKnownVersion
        if ($null -eq $version -or $version.Length -eq 0) {
            $executable = Get-UxGitCommand
            if ($null -eq $executable -or $executable.Length -eq 0) {
                $script:UxGitCapability = New-UxGitCapability -Mode 'file-only' -Version $null -Reason 'git not found on PATH'
                return (Copy-UxGitCapability -Capability $script:UxGitCapability)
            }
            $version = Invoke-UxGitVersionProbe -Executable $executable
            if ($null -ne $version) {
                Set-UxGitKnownVersion -Version $version
            } else {
                $script:UxGitCapability = New-UxGitCapability -Mode 'porcelain-v1' -Version $null -Reason 'git version could not be parsed; using portable porcelain v1'
                return (Copy-UxGitCapability -Capability $script:UxGitCapability)
            }
        }

        $mode = Get-UxGitModeFromVersion -Version $version
        $reason = 'git version ' + $version
        if ($mode -eq 'porcelain-v2') {
            if (Test-UxGitVersionAtLeast -Version $version -Major 2 -Minor 15) {
                $reason = $reason + ' (porcelain v2, --no-optional-locks)'
            } else {
                $reason = $reason + ' (porcelain v2, no --no-optional-locks before 2.15)'
            }
        } else {
            $reason = $reason + ' (portable porcelain v1)'
        }
        $script:UxGitCapability = New-UxGitCapability -Mode $mode -Version $version -Reason $reason
        return (Copy-UxGitCapability -Capability $script:UxGitCapability)
    } catch {
        $message = ''
        try { $message = [string]$_.Exception.Message } catch { $message = 'unknown error' }
        return (New-UxGitCapability -Mode 'file-only' -Version $null -Reason ('capability probe failed: ' + $message))
    }
}

function Invoke-UxGitStatus {
    param([string]$Root, [string]$GitDir)
    # One process. Returns @{ Ok; Dirty; Ahead; Behind; Branch; Detached; Reason; Slow }.
    $result = @{
        Ok       = $false
        Dirty    = $null
        Ahead    = 0
        Behind   = 0
        Branch   = $null
        Detached = $false
        Reason   = ''
        Slow     = $false
        Elapsed  = 0.0
    }

    $executable = Get-UxGitCommand
    if ($null -eq $executable -or $executable.Length -eq 0) {
        $result['Reason'] = 'git not found on PATH'
        return $result
    }

    $mode = Resolve-UxGitMode
    $untracked = Get-UxGitBoolConfig -Key 'git.untrackedFiles' -Default $false

    $arguments = @()
    $arguments += '-C'
    $arguments += $Root
    # --no-optional-locks matters: a plain `git status` inside a prompt can write
    # index.lock and collide with the user's own git commands. It exists since git 2.15,
    # and we cannot afford a separate `git --version` process per prompt, so we always try
    # it and let the "unknown option" handler above disable it permanently for this session
    # on an older git. One wasted attempt on ancient git beats an index.lock on modern git.
    if (-not $script:UxGitNoLocksUnsupported) {
        $arguments += '--no-optional-locks'
    }
    if ($mode -eq 'porcelain-v2') {
        $arguments += 'status'
        $arguments += '--porcelain=v2'
        $arguments += '--branch'
    } else {
        $arguments += 'status'
        $arguments += '--porcelain'
        $arguments += '--branch'
    }
    if (-not $untracked) { $arguments += '--untracked-files=no' }

    $started = $null
    try { $started = Get-Date } catch { $started = $null }
    $items = @()
    $previous = 'Continue'
    try { $previous = $ErrorActionPreference } catch { $previous = 'Continue' }
    try {
        # 2>&1 merges git's stderr into the pipeline as ErrorRecords, so the prompt never
        # sees git's error text and we can still inspect it for safe.directory refusals.
        $ErrorActionPreference = 'Continue'
        $items = @(& $executable @arguments 2>&1)
    } catch {
        $message = ''
        try { $message = [string]$_.Exception.Message } catch { $message = 'unknown error' }
        $result['Reason'] = 'git could not be started: ' + $message
        return $result
    } finally {
        try { $ErrorActionPreference = $previous } catch { }
    }

    $elapsed = 0.0
    try {
        if ($null -ne $started) { $elapsed = ((Get-Date) - $started).TotalMilliseconds }
    } catch {
        $elapsed = 0.0
    }
    $result['Elapsed'] = $elapsed
    $threshold = Get-UxGitIntConfig -Key 'git.slowThresholdMs' -Default 250 -Minimum 1
    if ($elapsed -gt $threshold) { $result['Slow'] = $true }

    $code = 0
    try { if ($null -ne $LASTEXITCODE) { $code = [int]$LASTEXITCODE } } catch { $code = 0 }

    $stdout = @()
    $stderr = ''
    foreach ($item in $items) {
        if ($item -is [string]) {
            $text = [string]$item
            if ($text -match '(?i)(dubious ownership|safe\.directory)') {
                $stderr = $stderr + $text + "`n"
                continue
            }
            $stdout += $text
        } else {
            try { $stderr = $stderr + [string]$item + "`n" } catch { }
        }
    }

    if ($code -ne 0) {
        $reason = 'git status exited with code ' + [string]$code
        if ($stderr.Trim().Length -gt 0) { $reason = $reason + ': ' + $stderr.Trim() }
        $result['Reason'] = $reason
        $script:UxGitLastError = $reason

        # "dubious ownership" never fixes itself during a session: stop spawning a process
        # that is guaranteed to fail on every prompt. Clear it with Reset-UxGitCache / reload.
        if ($stderr -match '(?i)(dubious ownership|safe\.directory)') {
            $script:UxGitBlocked = $true
            $script:UxGitBlockReason = 'git refused the repository (safe.directory / dubious ownership)'
        }
        # An "unknown option" failure means the assumed option set is wrong: fall back for
        # the rest of the session instead of retrying inside the same prompt.
        if ($stderr -match '(?i)(unknown option|unknown switch|unrecognized option|usage: git)') {
            if ($stderr -match '(?i)(no-optional-locks)') {
                # git older than 2.15: keep the status call, drop the lock flag.
                $script:UxGitNoLocksUnsupported = $true
            }
            if ($mode -eq 'porcelain-v2') { $script:UxGitModeOverride = 'porcelain-v1' }
        }
        return $result
    }

    $dirty = $false
    $sawOutput = $false
    $branch = $null
    $detached = $false
    $ahead = 0
    $behind = 0

    foreach ($line in $stdout) {
        $text = [string]$line
        if ($text.Length -eq 0) { continue }
        $sawOutput = $true

        if ($text.StartsWith('## ')) {
            # git status --porcelain --branch (v1) header.
            $rest = $text.Substring(3)
            if ($rest.StartsWith('HEAD (no branch)')) {
                $detached = $true
            } elseif ($rest -match '^(No commits yet|Initial commit) on (.+)$') {
                $branch = $Matches[2]
            } else {
                $name = $rest
                $index = $name.IndexOf('...')
                if ($index -gt 0) { $name = $name.Substring(0, $index) }
                $space = $name.IndexOf(' ')
                if ($space -gt 0) { $name = $name.Substring(0, $space) }
                $name = $name.Trim()
                if ($name.Length -gt 0) { $branch = $name }
            }
            if ($rest -match 'ahead (\d+)') { $ahead = [int]$Matches[1] }
            if ($rest -match 'behind (\d+)') { $behind = [int]$Matches[1] }
            continue
        }

        if ($text[0] -eq '#') {
            # git status --porcelain=v2 --branch header lines.
            if ($text -match '^# branch\.head (.+)$') {
                $name = $Matches[1].Trim()
                if ($name -eq '(detached)') {
                    $detached = $true
                } elseif ($name.Length -gt 0) {
                    $branch = $name
                }
            } elseif ($text -match '^# branch\.ab \+(\d+) -(\d+)') {
                $ahead = [int]$Matches[1]
                $behind = [int]$Matches[2]
            }
            # branch.oid / branch.upstream need no handling: HEAD already gave us the sha.
            continue
        }

        # Any non-header line is an entry: tracked change, staged change, or untracked.
        $dirty = $true
    }

    if (-not $sawOutput) { $dirty = $false }
    $result['Ok'] = $true
    $result['Dirty'] = $dirty
    $result['Ahead'] = $ahead
    $result['Behind'] = $behind
    $result['Branch'] = $branch
    $result['Detached'] = $detached
    $script:UxGitLastError = ''
    return $result
}

# ---------------------------------------------------------------------------
# Cache helpers.
# ---------------------------------------------------------------------------
function Limit-UxGitCache {
    param($Cache)
    # Simple bounded cache: 200 entries, then drop everything. No LRU bookkeeping.
    if ($null -eq $Cache) { return }
    if ($false -eq ($Cache -is [hashtable])) { return }
    if ($Cache.Count -gt 200) { $Cache.Clear() }
}

function Test-UxGitCacheEntry {
    param($Entry, $GitDir, [int]$CacheMs)
    # Reuse policy, stated honestly:
    #   * `cacheMs` is the real freshness contract. A plain working-tree edit
    #     ('echo x >> f') touches no file under .git, so no stamp can see it.
    #   * The HEAD/index stamp is only an early-invalidation fast path: a commit, a
    #     checkout, a stage or a rebase bumps one of them and forces a refresh now
    #     instead of up to cacheMs later.
    if ($null -eq $Entry) { return $false }
    if ($false -eq ($Entry -is [hashtable])) { return $false }
    foreach ($key in @('Time', 'Model', 'HeadStamp', 'IndexStamp')) {
        if (-not $Entry.ContainsKey($key)) { return $false }
    }
    if ($null -eq $Entry['Time']) { return $false }
    if ($null -eq $Entry['Model']) { return $false }

    $age = 0.0
    try { $age = ((Get-Date) - $Entry['Time']).TotalMilliseconds } catch { return $false }
    if ($age -lt 0) { $age = 0 }
    if ($age -ge $CacheMs) { return $false }

    $cachedHead = [long]$Entry['HeadStamp']
    $cachedIndex = [long]$Entry['IndexStamp']
    if ($cachedHead -ne [long]0) {
        $headStamp = Get-UxGitStamp -Path (Join-UxGitPath -Base $GitDir -Child 'HEAD')
        if ($headStamp -ne [long]0 -and $headStamp -ne $cachedHead) { return $false }
    }
    if ($cachedIndex -ne [long]0) {
        $indexStamp = Get-UxGitStamp -Path (Join-UxGitPath -Base $GitDir -Child 'index')
        if ($indexStamp -ne [long]0 -and $indexStamp -ne $cachedIndex) { return $false }
    }
    return $true
}

function Reset-UxGitCache {
    # Drops every memo (discovery + status) and the adaptive-degradation counters.
    try {
        $state = Get-UxGitGlobals
        $state['GitCache'] = @{}
    } catch { }
    try { $script:UxGitSlowCount = 0 } catch { }
    try { $script:UxGitDegraded = $false } catch { }
    try { $script:UxGitBlocked = $false } catch { }
    try { $script:UxGitBlockReason = '' } catch { }
    try { $script:UxGitModeOverride = '' } catch { }
    try { $script:UxGitNoLocksUnsupported = $false } catch { }
    try { $script:UxGitLastError = '' } catch { }
    # Forget the cached capability answer so `ux doctor` re-probes presence, but keep the
    # version: it is a session fact and re-probing it would cost an extra process.
    try { $script:UxGitCapability = $null } catch { }
    try { $script:UxGitHelpers = @{} } catch { }
    Get-UxGitDebug -Message 'git cache reset'
}

function Get-UxGitDiagnostics {
    # Extra export (not in the prompt path): what `ux doctor` wants to print.
    try {
        return @{
            Message  = [string]$script:UxGitLastError
            Blocked  = [bool]$script:UxGitBlocked
            Reason   = [string]$script:UxGitBlockReason
            Degraded = [bool]$script:UxGitDegraded
            Slow     = [int]$script:UxGitSlowCount
        }
    } catch {
        return @{ Message = ''; Blocked = $false; Reason = ''; Degraded = $false; Slow = 0 }
    }
}

# ---------------------------------------------------------------------------
# Public entry point.
# ---------------------------------------------------------------------------
function Get-UxGitModel {
    param([string]$Path)

    $fallback = New-UxGitModel
    try {
        $cache = $null
        try { $cache = Get-UxGitCache } catch { $cache = $null }
        if ($false -eq ($cache -is [hashtable])) { $cache = @{} }

        $requested = $Path
        if ($null -eq $requested -or $requested.Length -eq 0) { $requested = Get-UxGitBasePath }
        if ($null -eq $requested -or $requested.Length -eq 0) { return $fallback }

        # --- 1. discovery (memoised per requested path, "not a repo" included) ---
        $discoveryKey = 'p:' + $requested
        $layout = $null
        if ($cache.ContainsKey($discoveryKey)) {
            $existing = $cache[$discoveryKey]
            if ($existing -is [hashtable]) {
                if ($existing.ContainsKey('Root')) { $layout = $existing }
            }
        }
        if ($null -eq $layout) {
            $record = @{ Root = $null; GitDir = $null; CommonDir = $null; Time = (Get-Date); Model = $null }
            $found = $null
            try { $found = Find-UxGitLayout -Path $requested } catch { $found = $null }
            if ($null -ne $found) {
                $record['Root'] = $found['Root']
                $record['GitDir'] = $found['GitDir']
                $record['CommonDir'] = $found['CommonDir']
            }
            $cache[$discoveryKey] = $record
            Limit-UxGitCache -Cache $cache
            $layout = $record
        }

        $root = $layout['Root']
        if ($null -eq $root) { return $fallback }
        $root = [string]$root
        if ($root.Length -eq 0) { return $fallback }
        $gitDir = ''
        if ($null -ne $layout['GitDir']) { $gitDir = [string]$layout['GitDir'] }
        $commonDir = ''
        if ($null -ne $layout['CommonDir']) { $commonDir = [string]$layout['CommonDir'] }
        if ($gitDir.Length -eq 0) { return $fallback }

        # --- 2. warm status cache keyed on the repo root ---
        $cacheMs = Get-UxGitIntConfig -Key 'git.cacheMs' -Default 2000 -Minimum 0
        $statusKey = 'r:' + $root
        $cached = $null
        if ($cache.ContainsKey($statusKey)) { $cached = $cache[$statusKey] }
        if ($cacheMs -gt 0) {
            if (Test-UxGitCacheEntry -Entry $cached -GitDir $gitDir -CacheMs $cacheMs) {
                return (Copy-UxGitModel -Model $cached['Model'])
            }
        }

        # --- 3. branch / detached / state from files (always available) ---
        $model = $null
        try { $model = Get-UxGitFileModel -Root $root -GitDir $gitDir -CommonDir $commonDir } catch { $model = $null }
        if ($null -eq $model) {
            # A .git we cannot read is not a repository we can describe: cache that verdict
            # so a broken or half-removed .git costs one stat set per session.
            $cache[$discoveryKey] = @{ Root = $null; GitDir = $null; CommonDir = $null; Time = (Get-Date); Model = $null }
            Limit-UxGitCache -Cache $cache
            Get-UxGitDebug -Message ('unreadable git dir: ' + $gitDir)
            return $fallback
        }
        if ($layout -is [hashtable]) { $layout['Model'] = $model }

        $headStamp = Get-UxGitStamp -Path (Join-UxGitPath -Base $gitDir -Child 'HEAD')
        $indexStamp = Get-UxGitStamp -Path (Join-UxGitPath -Base $gitDir -Child 'index')

        # --- 4. dirty + ahead/behind: at most one process per cache window ---
        $gitEnabled = Get-UxGitBoolConfig -Key 'git.useGitBinary' -Default $true
        if ($gitEnabled -and -not $script:UxGitDegraded -and -not $script:UxGitBlocked) {
            $status = $null
            try { $status = Invoke-UxGitStatus -Root $root -GitDir $gitDir } catch { $status = $null }
            if ($null -ne $status) {
                if ($status['Slow']) {
                    $script:UxGitSlowCount = $script:UxGitSlowCount + 1
                    if ($script:UxGitSlowCount -ge 2) {
                        $script:UxGitDegraded = $true
                        $script:UxGitLastError = 'git status exceeded git.slowThresholdMs twice; file parsing only for the rest of this session'
                        Get-UxGitDebug -Message $script:UxGitLastError
                    }
                }
                if ($status['Ok']) {
                    $model['Dirty'] = $status['Dirty']
                    $model['Ahead'] = $status['Ahead']
                    $model['Behind'] = $status['Behind']
                    if ($null -eq $model['Branch']) {
                        if ($null -ne $status['Branch']) { $model['Branch'] = $status['Branch'] }
                    }
                    if ($null -eq $model['ShortSha']) {
                        if ($status['Detached'] -and $null -ne $model['Branch']) { $model['ShortSha'] = $model['Branch'] }
                    }
                }
            }
        }

        # --- 5. store the merged model, keyed on the root ---
        $cache[$statusKey] = @{
            Time       = (Get-Date)
            HeadStamp  = $headStamp
            IndexStamp = $indexStamp
            Model      = $model
        }
        Limit-UxGitCache -Cache $cache
        return (Copy-UxGitModel -Model $model)
    } catch {
        $message = ''
        try { $message = [string]$_.Exception.Message } catch { $message = 'unknown error' }
        $script:UxGitLastError = 'git model failed: ' + $message
        Get-UxGitDebug -Message $script:UxGitLastError
        return $fallback
    }
}
