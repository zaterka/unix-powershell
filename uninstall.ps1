#Requires -Version 5.1
<#
.SYNOPSIS
    Uninstaller for unix-powershell. No admin rights required.

.DESCRIPTION
    Removes the delimited unix-powershell block from the per-user PowerShell profile(s)
    and deletes the install directory. Everything outside the delimited block is kept
    exactly as it was, so a hand-written profile survives.

    This script is deliberately standalone and thin: it does not dot-source anything
    from lib/ and does not need the install directory to exist, so it still works when
    the install is half broken. Running it twice is safe: with nothing installed it
    reports that there was nothing to do and exits without an error.

    Nothing is written outside $HOME (apart from the profile file that PowerShell
    itself points at), no elevation is attempted, and the script is ASCII only and
    Windows PowerShell 5.1 compatible.

.PARAMETER Force
    Do not ask for confirmation before deleting the install directory.

.PARAMETER InstallDir
    Install root to delete. Defaults to $HOME\.unix-powershell.

.EXAMPLE
    .\uninstall.ps1

.EXAMPLE
    .\uninstall.ps1 -Force

.NOTES
    This script does not call Set-StrictMode itself, because when its text is piped into
    iex that would change the caller's session. It is written to behave correctly under
    Set-StrictMode -Version Latest.
#>
[CmdletBinding()]
param(
    [switch]$Force,
    [string]$InstallDir
)

# The delimited block written by install.ps1. The pattern matches any version so an
# older block is removed as well; it is anchored on the delimiter lines, never on the
# block body, and it leaves every other line of the profile untouched.
$script:UxBlockPattern = '(?ms)^[ \t]*\#[ \t]*BEGIN[ \t]+unix-powershell[ \t]+v[0-9]+\.[0-9]+\.[0-9]+[ \t]*\r?\n.*?^[ \t]*\#[ \t]*END[ \t]+unix-powershell[ \t]+v[0-9]+\.[0-9]+\.[0-9]+[ \t]*(?:\r?\n|\z)'
$script:UxBlockMarker = '\# BEGIN unix-powershell'

function Write-UxLine {
    param(
        [string]$Text,
        [string]$Color
    )
    if ($Color) {
        Write-Host $Text -ForegroundColor $Color
    }
    else {
        Write-Host $Text
    }
}

# Fatal errors print their details here (short lines, wrapped by hand) and then throw a
# single short line, so the console never has to wrap a multi-line exception message.
function Stop-UxError {
    param(
        [string]$Message,
        [string[]]$Detail
    )
    Write-UxLine ('[unix-powershell] ' + $Message) 'Red'
    foreach ($line in @($Detail)) {
        if ($line) { Write-UxLine ('             ' + $line) 'Red' }
    }
    throw $Message
}

# Get-Content -Raw returns nothing at all for a zero byte file, and a [string] cast of a
# command that produced no output yields $null, so every text read goes through this.
function Read-UxFileText {
    param([string]$Path)

    if (-not $Path) { return '' }
    $raw = $null
    try {
        $raw = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
    }
    catch {
        return ''
    }
    if ($null -eq $raw) { return '' }
    return [string]$raw
}

# Literal leaf/parent extraction. Split-Path's -Path parameter set is wildcard aware,
# and its -LiteralPath set cannot be combined with -Parent/-Leaf, so the two pieces we
# need are derived from the string instead: no wildcard interpretation, no .NET IO.
function Get-UxLeaf {
    param([string]$Path)
    $text = [string]$Path
    if (-not $text) { return '' }
    $text = $text.TrimEnd(@([char]92, [char]47))
    if (-not $text) { return '' }
    $index = $text.LastIndexOfAny(@([char]92, [char]47))
    if ($index -lt 0) { return $text }
    return $text.Substring($index + 1)
}

function Get-UxParent {
    param([string]$Path)
    $text = [string]$Path
    if (-not $text) { return '' }
    $text = $text.TrimEnd(@([char]92, [char]47))
    if (-not $text) { return '' }
    $index = $text.LastIndexOfAny(@([char]92, [char]47))
    if ($index -le 0) { return '' }
    return $text.Substring(0, $index)
}

function Remove-UxTrailingSeparator {
    param([string]$Path)
    $text = [string]$Path
    if (-not $text) { return '' }
    $trimmed = $text.TrimEnd(@([char]92, [char]47))
    if (-not $trimmed) { return $text }
    return $trimmed
}

function Get-UxFullPath {
    param([string]$Path)

    $text = [string]$Path
    if (-not $text) { return '' }

    $resolved = $null
    try {
        $resolved = Resolve-Path -LiteralPath $text -ErrorAction SilentlyContinue
    }
    catch {
        $resolved = $null
    }

    if ($resolved) {
        $first = @($resolved)[0]
        $resolvedPath = ''
        try {
            $resolvedPath = [string]$first.Path
        }
        catch {
            $resolvedPath = ''
        }
        if ($resolvedPath) { $text = $resolvedPath }
    }
    elseif (-not ($text -match '^[A-Za-z]:')) {
        if (-not ($text -match '^[\\/]')) {
            $cwd = ''
            try { $cwd = [string](Get-Location).Path } catch { $cwd = '' }
            if ($cwd) { $text = Join-Path $cwd $text }
        }
    }

    return (Remove-UxTrailingSeparator -Path $text)
}

function Test-UxPathsEqual {
    param(
        [string]$Path,
        [string]$Other
    )
    $left = Get-UxFullPath -Path $Path
    $right = Get-UxFullPath -Path $Other
    if (-not $left) { return $false }
    if (-not $right) { return $false }
    return $left.Equals($right, 'OrdinalIgnoreCase')
}

function Test-UxPathInside {
    param(
        [string]$Path,
        [string]$Root
    )
    $child = Get-UxFullPath -Path $Path
    $parent = Get-UxFullPath -Path $Root
    if (-not $child) { return $false }
    if (-not $parent) { return $false }
    if ($child.Equals($parent, 'OrdinalIgnoreCase')) { return $true }

    $separator = [string][char]47
    if ($parent.Contains([string][char]92)) { $separator = [string][char]92 }
    $prefix = $parent
    if (-not $prefix.EndsWith($separator)) { $prefix = $prefix + $separator }
    return $child.StartsWith($prefix, 'OrdinalIgnoreCase')
}

function Test-UxRootPath {
    param([string]$Path)
    $text = Get-UxFullPath -Path $Path
    if (-not $text) { return $false }
    if ($text -match '^[A-Za-z]:$') { return $true }
    if ($text -eq '/') { return $true }
    if ($text -eq '\') { return $true }
    if ($text -match '^\\\\[^\\]+\\[^\\]+$') { return $true }
    return $false
}

function Get-UxHomePath {
    if ($HOME) { return (Get-UxFullPath -Path ([string]$HOME)) }
    if ($env:USERPROFILE) { return (Get-UxFullPath -Path ([string]$env:USERPROFILE)) }
    throw 'cannot determine the home directory: both $HOME and $env:USERPROFILE are empty'
}

function Join-UxRelativePath {
    param(
        [string]$Base,
        [string]$Relative
    )
    $current = [string]$Base
    foreach ($part in ($Relative -split '[\\/]+')) {
        if ($part) { $current = Join-Path -Path $current -ChildPath $part }
    }
    return $current
}

function Get-UxNewLineFor {
    param([string]$Content)
    $text = [string]$Content
    if ($text) {
        if ($text.Contains("`r`n")) { return "`r`n" }
        if ($text.Contains("`n")) { return "`n" }
    }
    if ($env:OS -eq 'Windows_NT') { return "`r`n" }
    return "`n"
}

# The running host's profile is taken from $PROFILE so a redirected Documents folder
# (OneDrive) or a custom location is honoured. The explicit paths are only used to
# find the other host's profile, which is where a 5.1 install would live when this
# script runs under 7, and vice versa.
function Get-UxCurrentUserAllHostsProfile {
    $path = ''
    try {
        if ($PROFILE) { $path = [string]$PROFILE.CurrentUserAllHosts }
    }
    catch {
        $path = ''
    }
    if ($path) { return $path }

    $homePath = Get-UxHomePath
    $major = 5
    if ($PSVersionTable.ContainsKey('PSVersion')) { $major = [int]$PSVersionTable.PSVersion.Major }
    if ($major -ge 7) {
        return (Join-UxRelativePath -Base $homePath -Relative 'Documents\PowerShell\profile.ps1')
    }
    return (Join-UxRelativePath -Base $homePath -Relative 'Documents\WindowsPowerShell\profile.ps1')
}

function Get-UxOtherHostProfile {
    $homePath = Get-UxHomePath
    $major = 5
    if ($PSVersionTable.ContainsKey('PSVersion')) { $major = [int]$PSVersionTable.PSVersion.Major }
    if ($major -ge 7) {
        return (Join-UxRelativePath -Base $homePath -Relative 'Documents\WindowsPowerShell\profile.ps1')
    }
    return (Join-UxRelativePath -Base $homePath -Relative 'Documents\PowerShell\profile.ps1')
}

# A block whose markers were damaged (one of the two lines edited or deleted) can never be
# matched by the regex, so it is not guessed at and the file is not truncated: the user
# gets the exact instruction instead. The instruction text is deliberately identical to
# install.ps1's, and so is the note for the damaged-marker case ('unmatched BEGIN marker
# left in place'), so the two scripts never disagree about what the manual repair is.
function Write-UxManualBlockHint {
    param(
        [string]$ProfilePath,
        [string]$Note
    )

    Write-UxLine ('profile   : ' + $ProfilePath + ' needs a manual edit - ' + $Note) 'Yellow'
    Write-UxLine '              manual step: open that file and delete every line from "# BEGIN unix-powershell"' 'Yellow'
    Write-UxLine '              to "# END unix-powershell", including both marker lines.' 'Yellow'
    Write-UxLine '              If only one of the two marker lines is still there, delete that line as well,' 'Yellow'
    Write-UxLine '              save the file, and run this command again.' 'Yellow'
}

function Remove-UxProfileBlock {
    param([string]$ProfilePath)

    $info = @{
        Path   = $ProfilePath
        Action = 'absent'
        Note   = ''
    }

    if (-not (Test-Path -LiteralPath $ProfilePath)) {
        $info.Note = 'file not present'
        return $info
    }

    $item = Get-Item -LiteralPath $ProfilePath -Force -ErrorAction SilentlyContinue
    if ($item -and $item.PSObject.Properties['PSIsContainer'] -and $item.PSIsContainer) {
        $info.Action = 'manual'
        $info.Note = 'path is a directory, not a file'
        return $info
    }

    $content = Read-UxFileText -Path $ProfilePath
    if ($content -notmatch $script:UxBlockMarker) {
        $info.Note = 'no unix-powershell block'
        return $info
    }

    $payload = $content -replace $script:UxBlockPattern, ''
    if ($payload -match $script:UxBlockMarker) {
        # Hand-edited markers: do not guess, and definitely do not truncate the file. Same
        # note string as install.ps1's -RemoveOnly path.
        $info.Action = 'manual'
        $info.Note = 'unmatched BEGIN marker left in place'
        return $info
    }

    $newLine = Get-UxNewLineFor -Content $content
    $payload = $payload.TrimEnd(@([char]10, [char]13))
    $newContent = ''
    if ($payload.Length -gt 0) { $newContent = $payload + $newLine }

    Set-Content -LiteralPath $ProfilePath -Value $newContent -Encoding UTF8 -NoNewline
    $info.Action = 'removed'
    return $info
}

# ---------------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------------
$HomePath = Get-UxHomePath
if (-not $InstallDir) { $InstallDir = Join-Path $HomePath '.unix-powershell' }
$InstallRoot = Get-UxFullPath -Path $InstallDir

Write-UxLine ''
Write-UxLine 'unix-powershell - uninstall' 'Cyan'
Write-UxLine '============================' 'Cyan'

if (-not $InstallRoot) {
    Stop-UxError -Message 'the install directory resolved to an empty path.' -Detail @('Pass -InstallDir with the path that was installed.')
}
if (Test-UxRootPath -Path $InstallRoot) {
    Stop-UxError -Message 'refusing to work on a filesystem root as the install directory.' -Detail @(('install directory: ' + $InstallRoot))
}
if (Test-UxPathsEqual -Path $InstallRoot -Other $HomePath) {
    Stop-UxError -Message 'refusing to work on the home directory itself.' -Detail @(('home directory: ' + $HomePath), 'unix-powershell never installs into $HOME directly, so there is nothing of ours to remove there.')
}

$cwd = ''
try { $cwd = [string](Get-Location).Path } catch { $cwd = '' }
if ($cwd -and (Test-UxPathInside -Path $cwd -Root $InstallRoot)) {
    Stop-UxError -Message 'refusing to uninstall while the current directory is inside the install directory.' -Detail @(('current directory: ' + $cwd), ('install directory: ' + $InstallRoot), 'Change to another directory and re-run.')
}

# 1. Profile block(s): the running host, plus the other host's profile when it exists
#    and actually contains our marker. Files without the marker are never rewritten.
$targets = @()
$runningProfile = Get-UxCurrentUserAllHostsProfile
if ($runningProfile) { $targets += $runningProfile }
$otherProfile = Get-UxOtherHostProfile
$duplicate = $false
foreach ($existing in $targets) {
    if (Test-UxPathsEqual -Path $existing -Other $otherProfile) { $duplicate = $true }
}
if (-not $duplicate) { $targets += $otherProfile }

$removedSomething = $false
foreach ($target in $targets) {
    $result = Remove-UxProfileBlock -ProfilePath $target
    switch ($result.Action) {
        'removed' {
            Write-UxLine ('profile   : removed the unix-powershell block from ' + $target) 'Green'
            $removedSomething = $true
        }
        'manual' {
            Write-UxManualBlockHint -ProfilePath $target -Note $result.Note
            $removedSomething = $true
        }
        default {
            Write-UxLine ('profile   : nothing to remove in ' + $target + ' (' + $result.Note + ')') 'Gray'
        }
    }
}

# 2. Install directory, with confirmation unless -Force.
$exists = Test-Path -LiteralPath $InstallRoot
$mayRemove = $true
if ($exists -and -not $Force) {
    $answer = ''
    try {
        $answer = [string](Read-Host ('Remove ' + $InstallRoot + ' and everything under it? [y/N]'))
    }
    catch {
        $answer = ''
    }
    if (-not ($answer -match '^(y|yes)$')) {
        $mayRemove = $false
        Write-UxLine ('install   : kept ' + $InstallRoot + ' (not confirmed; re-run with -Force to remove it)') 'Yellow'
    }
}

if ($exists -and $mayRemove) {
    $item = Get-Item -LiteralPath $InstallRoot -Force -ErrorAction SilentlyContinue
    if ($item -and $item.PSObject.Properties['LinkType'] -and $item.LinkType) {
        Stop-UxError -Message ('refusing to delete ' + $InstallRoot + ': it is a reparse point.') -Detail @(('link type: ' + [string]$item.LinkType), 'Remove it manually if that is really what you want.')
    }
    Remove-Item -LiteralPath $InstallRoot -Recurse -Force -Confirm:$false -ErrorAction Stop
    Write-UxLine ('install   : removed ' + $InstallRoot) 'Green'
    $removedSomething = $true
}
elseif (-not $exists) {
    Write-UxLine ('install   : nothing at ' + $InstallRoot + ' (already clean)') 'Gray'
}

# 3. Report what is left behind rather than deleting anything we did not create.
$leftovers = @()
$parent = Get-UxParent -Path $InstallRoot
$leaf = Get-UxLeaf -Path $InstallRoot
if ($parent -and $leaf -and (Test-Path -LiteralPath $parent)) {
    foreach ($child in @(Get-ChildItem -LiteralPath $parent -Force -ErrorAction SilentlyContinue)) {
        if ($child.Name.StartsWith($leaf + '.bak.', 'OrdinalIgnoreCase')) {
            $leftovers += [string]$child.FullName
        }
    }
}
if ($leftovers.Count -gt 0) {
    Write-UxLine 'left behind (delete these yourself if you do not want them):' 'Yellow'
    foreach ($leftover in $leftovers) {
        Write-UxLine ('            ' + $leftover) 'Yellow'
    }
}
else {
    Write-UxLine 'left behind: nothing' 'Gray'
}

Write-UxLine ''
if ($removedSomething) {
    Write-UxLine 'done      : restart your shell to get the previous prompt back' 'Cyan'
}
else {
    Write-UxLine 'done      : nothing was installed, so nothing had to be removed' 'Cyan'
}
Write-UxLine ''
