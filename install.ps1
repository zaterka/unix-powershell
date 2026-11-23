#Requires -Version 5.1
<#
.SYNOPSIS
    Per-user installer for unix-powershell. No admin rights required.

.DESCRIPTION
    Installs the unix-powershell runtime into $HOME\.unix-powershell and patches the
    per-user PowerShell profile ($PROFILE.CurrentUserAllHosts) with a delimited block
    that can be removed at any time with -Uninstall.

    Constraints this script obeys (PLAN.md section 5.6, section 6):

      - Per user only. Everything is written under $HOME plus the profile file that
        PowerShell already points at. No elevation, no HKLM, no AllUsers profile.
      - Downloads prefer curl.exe. This is deliberate: on Windows PowerShell 5.1 the
        default security protocol is TLS 1.0 and forcing TLS 1.2 would need
        Net.ServicePointManager.SecurityProtocol, which this project bans (no .NET
        static calls, so the installer stays ConstrainedLanguage friendly). curl.exe
        (present on Windows 10 1803+) negotiates TLS 1.2 itself and fails non-zero on
        HTTP errors, so it is the primary path. Invoke-WebRequest is only the fallback
        for hosts that have no curl.exe, and on such a host TLS may have to be enabled
        by policy first.
      - No Invoke-Expression. No downloaded text is piped to iex or executed. No
        Add-Type, no COM objects, no reflection, no System.IO.File style calls.
      - Safe to run twice: exactly one profile block, one config.json, bounded backups.
      - Atomic with respect to the live install directory: everything is downloaded,
        hash-verified and parse-checked in a sibling staging directory first, and only a
        fully verified tree is swapped into place. A failed install deletes the staging
        directory and leaves the working install (and therefore the user's shell) alone.
      - Works when this script's text is piped into iex: nothing here depends on
        $PSScriptRoot or on files sitting next to this script. Without -SourceDir the
        manifest and the files are resolved from the pinned tag URL below.

.PARAMETER SourceDir
    Install from a local checkout or extracted zip instead of the network. The
    directory must contain manifest.json plus the files that manifest lists.

.PARAMETER InstallDir
    Install root. Defaults to $HOME\.unix-powershell.

.PARAMETER NoProfile
    Install files only. Do not read, create or modify any profile file. This also skips
    the post-install `ux doctor` run, because that needs the profile's entry point.

.PARAMETER NoDoctor
    Skip the post-install `ux doctor` run (it is started in a child process purely as a
    convenience; the install itself never depends on it).

.PARAMETER AllHosts
    Also patch the other host's CurrentUserAllHosts profile (WindowsPowerShell for a
    7+ host, PowerShell for a 5.1 host), so both shells load the profile.

.PARAMETER Force
    Do not ask for confirmation (uninstall) and never prompt.

.PARAMETER SetExecutionPolicy
    Set ExecutionPolicy RemoteSigned for the CurrentUser scope. Refused when a GPO
    (MachinePolicy or UserPolicy) overrides the scope, because CurrentUser would then
    be ignored and claiming otherwise would be a lie.

.PARAMETER Proxy
    Proxy URI for downloads. Defaults to $env:UX_PROXY.

.PARAMETER UseDefaultCredentials
    Send the current Windows credentials with Invoke-WebRequest downloads.

.PARAMETER Uninstall
    Remove the delimited profile block(s) and the install directory.

.EXAMPLE
    .\install.ps1

.EXAMPLE
    .\install.ps1 -SourceDir C:\temp\unix-powershell -NoProfile

.EXAMPLE
    .\install.ps1 -Uninstall -Force

.NOTES
    This script does not call Set-StrictMode itself: when its text is piped into iex
    that would silently change the caller's session. It is written to behave correctly
    under Set-StrictMode -Version Latest (no unset variable reads, no bare property
    access on optional members); run it from a strict-mode session to verify.
#>
[CmdletBinding()]
param(
    [string]$SourceDir,
    [string]$InstallDir,
    [switch]$NoProfile,
    [switch]$NoDoctor,
    [switch]$AllHosts,
    [switch]$Force,
    [switch]$SetExecutionPolicy,
    [string]$Proxy,
    [switch]$UseDefaultCredentials,
    [switch]$Uninstall
)

# ---------------------------------------------------------------------------------
# Pinned identity. A fork changes exactly these three values (and nothing else):
# the tag used to fetch manifest.json, the repository path in raw.githubusercontent,
# and the version the installer itself ships with. The version in manifest.json is
# authoritative for the installed files and for the profile block delimiters; this
# pin only decides which tag the manifest itself is fetched from.
# ---------------------------------------------------------------------------------
$script:UxVersion = '0.1.0'
$script:UxRepoTail = 'zaterka/unix-powershell'
$script:UxRawBase = 'https://raw.githubusercontent.com/' + $script:UxRepoTail
$script:UxTag = 'v' + $script:UxVersion
$script:UxManifestUrl = $script:UxRawBase + '/' + $script:UxTag + '/manifest.json'

# Delimiters of the injected profile block. The pattern matches any version so an
# upgrade replaces the previous block instead of stacking a second one; it is anchored
# on the delimiter lines only and never on the block body.
$script:UxBlockMarker = '\# BEGIN unix-powershell'
$script:UxBlockPattern = '(?ms)^[ \t]*\#[ \t]*BEGIN[ \t]+unix-powershell[ \t]+v[0-9]+\.[0-9]+\.[0-9]+[ \t]*\r?\n.*?^[ \t]*\#[ \t]*END[ \t]+unix-powershell[ \t]+v[0-9]+\.[0-9]+\.[0-9]+[ \t]*(?:\r?\n|\z)'

# Maximum number of timestamped backups kept next to the install dir.
$script:UxKeepBackups = 2

# Set when a fatal error has already been described to the user, and the path of the
# most recent install-directory backup (used in the failure hint).
$script:UxReported = $false
$script:UxLastBackup = ''
# Set when the swap rolled the install dir aside and could not put it back, so the failure
# hint must offer the restore recipe instead of claiming the old install is fine.
$script:UxRestoreNeeded = $false

# NOTE ON THE TEMPLATE BELOW: the block text is compared byte for byte by the test suite,
# so the single-quoted backslash in 'profile\profile.ps1' must stay exactly as it is. A
# backslash is the Windows directory separator; Join-Path keeps the string verbatim and
# the FileSystem provider normalises it when the path is resolved, so the same line
# resolves on Windows, Linux and macOS. Do not rewrite it as a forward slash here.
#
# The profile block, verbatim from PLAN.md section 5.6. It is authored at v0.1.0 and
# the real version is substituted at install time, so a fork only edits the constants
# above. The body is deliberately exception proof and never calls Set-StrictMode.
$script:UxBlockTemplate = @'
# BEGIN unix-powershell v0.1.0
$__uxBase = if ($HOME) { $HOME } else { $env:USERPROFILE }
$__uxHome = Join-Path $__uxBase '.unix-powershell'
$__uxEntry = Join-Path $__uxHome 'profile\profile.ps1'
$__uxBlocked = ($env:UX_DISABLE -eq '1') -or (Test-Path -LiteralPath (Join-Path $__uxHome '.disabled')) -or -not (Test-Path -LiteralPath $__uxEntry)
if (-not $__uxBlocked) {
  $__uxEap = $ErrorActionPreference
  try { $ErrorActionPreference = 'Continue'; . $__uxEntry }
  catch {
    Write-Host ("[unix-powershell] load failed: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
    Write-Host ("[unix-powershell] diagnose: powershell -NoProfile -File `"{0}`" doctor | bypass: set UX_DISABLE=1" -f (Join-Path $__uxHome 'ux.ps1')) -ForegroundColor Yellow
  }
  finally { $ErrorActionPreference = $__uxEap; Remove-Variable __uxEap -ErrorAction SilentlyContinue }
}
Remove-Variable __uxBase,__uxHome,__uxEntry,__uxBlocked -ErrorAction SilentlyContinue
# END unix-powershell v0.1.0
'@

# ---------------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------------
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

function Write-UxFail {
    param([string]$Text)
    Write-UxLine ('[unix-powershell] ' + $Text) 'Red'
}

function Write-UxWarn {
    param([string]$Text)
    Write-UxLine ('[unix-powershell] ' + $Text) 'Yellow'
}

# Fatal errors print their details here (short lines, wrapped by hand) and then throw a
# single short line, so the console never has to wrap a multi-line exception message.
function Stop-UxError {
    param(
        [string]$Message,
        [string[]]$Detail
    )
    Write-UxFail $Message
    foreach ($line in @($Detail)) {
        if ($line) { Write-UxLine ('             ' + $line) 'Red' }
    }
    $script:UxReported = $true
    throw $Message
}

# ---------------------------------------------------------------------------------
# Path helpers. Get-UxFullPath resolves an existing path and falls back to anchoring a
# relative path at the current location, because the install dir or a profile file may
# not exist yet. No .NET IO is used anywhere.
# ---------------------------------------------------------------------------------
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
        # Not on disk (yet) and not drive-qualified: everything else that starts with
        # a separator (or is a plain relative name) is anchored at the current location.
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

function Test-UxRelativePathSafe {
    param([string]$Relative)
    $text = [string]$Relative
    if (-not $text) { return $false }
    if ($text -match '^[A-Za-z]:') { return $false }
    if ($text.StartsWith('/')) { return $false }
    if ($text.StartsWith('\')) { return $false }
    if ($text -match '(^|[\\/])\.\.([\\/]|$)') { return $false }
    return $true
}

function Get-UxTempPath {
    param([string]$FileName)
    $candidates = @($env:TEMP, $env:TMP, $env:TMPDIR)
    foreach ($candidate in $candidates) {
        if (-not $candidate) { continue }
        if (Test-Path -LiteralPath $candidate) { return (Join-Path $candidate $FileName) }
    }
    # Last resort: a dot-file in the home directory (removed by the caller).
    return (Join-Path (Get-UxHomePath) ('.ux-tmp-' + $FileName))
}

# Get-Content -Raw returns nothing at all for a zero byte file, and a [string] cast of a
# command that produced no output yields $null (verified in pwsh 7 and on 5.1 semantics),
# so every text read goes through this helper instead of a bare cast.
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

function Get-UxTimestamp {
    return (Get-Date -Format 'yyyyMMddHHmmss')
}

# ---------------------------------------------------------------------------------
# Profile paths. Never hardcoded for the running host: $PROFILE.CurrentUserAllHosts is
# authoritative (Documents may be redirected to OneDrive). The two explicit paths are
# only used to construct the *other* host's location.
# ---------------------------------------------------------------------------------
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

function Get-UxBlockText {
    param(
        [string]$Version,
        [string]$InstallRoot,
        [string]$DefaultInstallRoot,
        [string]$NewLine
    )
    $replaced = $script:UxBlockTemplate.Replace('unix-powershell v0.1.0', 'unix-powershell v' + $Version)

    # The verbatim block hardcodes the default '.unix-powershell' folder name. A custom
    # install root would make the block point at the wrong place, so substitute the
    # absolute path for that one line and leave every other line untouched.
    if (-not (Test-UxPathsEqual -Path $InstallRoot -Other $DefaultInstallRoot)) {
        $escaped = $InstallRoot.Replace("'", "''")
        $needle = "`$__uxHome = Join-Path `$__uxBase '.unix-powershell'"
        $replacement = "`$__uxHome = '" + $escaped + "'"
        $replaced = $replaced.Replace($needle, $replacement)
    }

    $lines = $replaced -split "\r?\n"
    return ($lines -join $NewLine)
}

# ---------------------------------------------------------------------------------
# Validation helpers. The parser type is unavailable in ConstrainedLanguage mode, so
# both helpers degrade to "skipped" instead of throwing.
# ---------------------------------------------------------------------------------
function Test-UxParserAvailable {
    $probe = $null
    try {
        $probe = [System.Management.Automation.Language.Parser]
    }
    catch {
        return $false
    }
    if ($probe) { return $true }
    return $false
}

function Test-UxScriptParses {
    param([string]$Path)

    $result = @{
        Ok      = $true
        Skipped = $true
        Message = ''
    }

    $tokens = $null
    $errors = $null
    try {
        $null = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
        $result.Skipped = $false
    }
    catch {
        $result.Skipped = $true
        $result.Message = $_.Exception.Message
        return $result
    }

    $list = @()
    if ($errors) { $list = @($errors) }
    if ($list.Count -gt 0) {
        $first = $list[0]
        $line = 0
        try { $line = [int]$first.Extent.StartLineNumber } catch { $line = 0 }
        $result.Ok = $false
        $result.Message = ('line {0}: {1}' -f $line, [string]$first.Message)
    }
    return $result
}

function Invoke-UxUnblockFile {
    param([string]$Path)
    $command = Get-Command Unblock-File -ErrorAction SilentlyContinue
    if (-not $command) { return $false }
    try {
        Unblock-File -LiteralPath $Path -ErrorAction SilentlyContinue
    }
    catch {
        return $false
    }
    return $true
}

# ---------------------------------------------------------------------------------
# Download helpers
# ---------------------------------------------------------------------------------
function Get-UxCurlPath {
    $command = @(Get-Command curl.exe -CommandType Application -ErrorAction SilentlyContinue)
    if ($command.Count -eq 0) { return '' }
    $source = ''
    try {
        $source = [string]$command[0].Source
    }
    catch {
        $source = ''
    }
    if (-not $source) {
        try { $source = [string]$command[0].Path } catch { $source = '' }
    }
    return $source
}

function Invoke-UxFetch {
    param(
        [string]$Url,
        [string]$Destination,
        [string]$ProxyUri,
        [switch]$DefaultCredentials,
        [string]$CurlPath
    )

    if ($CurlPath) {
        # curl.exe: -f fails on HTTP errors, -s -S is quiet but reports errors, -L
        # follows redirects. It negotiates TLS itself, which is why it is preferred on
        # Windows PowerShell 5.1 (see the comment at the top of this script). The
        # timeouts stop a blocked proxy or firewall from hanging the install forever.
        $arguments = @('-fsSL', '--connect-timeout', '20', '--max-time', '300')
        if ($ProxyUri) { $arguments += @('--proxy', $ProxyUri) }
        $arguments += @('-o', $Destination, $Url)

        & $CurlPath @arguments
        $exitCode = 0
        if ($LASTEXITCODE) { $exitCode = [int]$LASTEXITCODE }
        if ($exitCode -ne 0) {
            throw ('curl.exe exited with code {0} while downloading {1}' -f $exitCode, $Url)
        }
        return
    }

    $savedPreference = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    try {
        $request = @{
            Uri             = $Url
            OutFile         = $Destination
            UseBasicParsing = $true
            TimeoutSec      = 300
            ErrorAction     = 'Stop'
        }
        if ($ProxyUri) { $request['Proxy'] = $ProxyUri }
        if ($DefaultCredentials) { $request['UseDefaultCredentials'] = $true }
        Invoke-WebRequest @request
    }
    finally {
        $ProgressPreference = $savedPreference
    }
}

function Get-UxRemoteText {
    param(
        [string]$Url,
        [string]$ProxyUri,
        [switch]$DefaultCredentials
    )

    $curlPath = Get-UxCurlPath
    if ($curlPath) {
        $temp = Get-UxTempPath -FileName ('ux-manifest-' + [string]$PID + '.json')
        $text = ''
        try {
            Invoke-UxFetch -Url $Url -Destination $temp -ProxyUri $ProxyUri -CurlPath $curlPath
            $text = Read-UxFileText -Path $temp
        }
        finally {
            if (Test-Path -LiteralPath $temp) {
                Remove-Item -LiteralPath $temp -Force -Confirm:$false -ErrorAction SilentlyContinue
            }
        }
        return $text
    }

    $savedPreference = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    try {
        $request = @{
            Uri             = $Url
            UseBasicParsing = $true
            TimeoutSec      = 300
            ErrorAction     = 'Stop'
        }
        if ($ProxyUri) { $request['Proxy'] = $ProxyUri }
        if ($DefaultCredentials) { $request['UseDefaultCredentials'] = $true }
        $response = Invoke-WebRequest @request
        return [string]$response.Content
    }
    finally {
        $ProgressPreference = $savedPreference
    }
}

# ---------------------------------------------------------------------------------
# Manifest
# ---------------------------------------------------------------------------------
function Read-UxManifestDocument {
    param([string]$Text)

    if (-not $Text) { throw 'manifest.json is empty' }

    $document = $null
    try {
        $document = $Text | ConvertFrom-Json
    }
    catch {
        throw ('manifest.json is not valid JSON: {0}' -f $_.Exception.Message)
    }
    if (-not $document) { throw 'manifest.json is empty' }

    $version = ''
    if ($document.PSObject.Properties['version']) { $version = [string]$document.version }
    if ($version -notmatch '^[0-9]+\.[0-9]+\.[0-9]+$') {
        throw ('manifest.json has no valid version (found "{0}"); expected X.Y.Z' -f $version)
    }

    $rawEntries = $null
    if ($document.PSObject.Properties['files']) { $rawEntries = $document.files }
    if (-not $rawEntries) { throw 'manifest.json has no files array' }

    $files = @()
    foreach ($entry in @($rawEntries)) {
        $relativePath = ''
        $sha256 = ''
        $bytes = 0
        if ($entry.PSObject.Properties['path']) { $relativePath = [string]$entry.path }
        if ($entry.PSObject.Properties['sha256']) { $sha256 = ([string]$entry.sha256).ToLowerInvariant() }
        if ($entry.PSObject.Properties['bytes']) {
            try { $bytes = [int]$entry.bytes } catch { $bytes = 0 }
        }
        if (-not $relativePath) { throw 'manifest.json contains a file entry without a path' }
        $files += @{
            Path   = $relativePath
            Sha256 = $sha256
            Bytes  = $bytes
        }
    }

    if ($files.Count -eq 0) { throw 'manifest.json lists no files' }

    return @{
        Version = $version
        Files   = $files
    }
}

# ---------------------------------------------------------------------------------
# Backups. Only names that this installer produced are ever deleted, so a user folder
# that merely looks similar is left alone.
# ---------------------------------------------------------------------------------
function Remove-UxOldFileBackups {
    param(
        [string]$ProfilePath,
        [int]$Keep
    )

    $parent = Get-UxParent -Path $ProfilePath
    if (-not $parent) { return @() }
    $leaf = Get-UxLeaf -Path $ProfilePath
    $prefix = $leaf + '.bak.'

    $found = @()
    foreach ($item in @(Get-ChildItem -LiteralPath $parent -File -Force -ErrorAction SilentlyContinue)) {
        if (-not $item.Name.StartsWith($prefix, 'OrdinalIgnoreCase')) { continue }
        $suffix = $item.Name.Substring($prefix.Length)
        if ($suffix -match '^[0-9]{14}(-[0-9]+)?$') { $found += $item }
    }
    if (@($found).Count -le $Keep) { return @() }

    $sorted = @($found | Sort-Object -Property Name -Descending)
    $removed = @()
    for ($index = $Keep; $index -lt $sorted.Count; $index++) {
        try {
            Remove-Item -LiteralPath $sorted[$index].FullName -Force -Confirm:$false -ErrorAction Stop
            $removed += [string]$sorted[$index].FullName
        }
        catch {
            # A backup we cannot delete is not a reason to fail the install.
        }
    }
    return $removed
}

function New-UxProfileBackup {
    param([string]$ProfilePath)

    $stamp = Get-UxTimestamp
    $target = $ProfilePath + '.bak.' + $stamp
    $counter = 1
    while (Test-Path -LiteralPath $target) {
        $counter = $counter + 1
        $target = $ProfilePath + '.bak.' + $stamp + '-' + [string]$counter
    }
    Copy-Item -LiteralPath $ProfilePath -Destination $target -Force -ErrorAction Stop
    $null = Remove-UxOldFileBackups -ProfilePath $ProfilePath -Keep 2
    return $target
}

function Remove-UxOldDirBackups {
    param(
        [string]$Parent,
        [string]$Leaf,
        [int]$Keep
    )

    $prefix = $Leaf + '.bak.'
    $found = @()
    foreach ($item in @(Get-ChildItem -LiteralPath $Parent -Directory -Force -ErrorAction SilentlyContinue)) {
        if (-not $item.Name.StartsWith($prefix, 'OrdinalIgnoreCase')) { continue }
        $suffix = $item.Name.Substring($prefix.Length)
        if ($suffix -match '^[0-9]{14}(-[0-9]+)?$') { $found += $item }
    }
    if (@($found).Count -le $Keep) { return @() }

    $sorted = @($found | Sort-Object -Property Name -Descending)
    $removed = @()
    for ($index = $Keep; $index -lt $sorted.Count; $index++) {
        try {
            Remove-Item -LiteralPath $sorted[$index].FullName -Recurse -Force -Confirm:$false -ErrorAction Stop
            $removed += [string]$sorted[$index].FullName
        }
        catch {
            # Same reasoning as above: a stale backup is not fatal.
        }
    }
    return $removed
}

# A timestamped sibling of the install dir, in the same parent directory (so a move is a
# plain rename on one volume, never a copy). Only two kinds are ever produced, and both
# carry the same shape the pruning regex recognises: <leaf>.<kind>.<yyyyMMddHHmmss>[-n].
function New-UxSiblingDirPath {
    param(
        [string]$InstallRoot,
        [string]$Kind
    )

    $parent = Get-UxParent -Path $InstallRoot
    if (-not $parent) { return '' }
    $leaf = Get-UxLeaf -Path $InstallRoot
    if (-not $leaf) { return '' }

    $stamp = Get-UxTimestamp
    $target = Join-Path $parent ($leaf + '.' + $Kind + '.' + $stamp)
    $counter = 1
    while (Test-Path -LiteralPath $target) {
        $counter = $counter + 1
        $target = Join-Path $parent ($leaf + '.' + $Kind + '.' + $stamp + '-' + [string]$counter)
    }
    return $target
}

# Moves the live install dir aside (one rename inside the same parent directory). Nothing
# is deleted and nothing is pruned here: pruning only happens after the staged tree has
# been activated, so a failed install can always be rolled back by moving this back.
function Move-UxInstallDirAside {
    param([string]$InstallRoot)

    $info = @{
        Backup = ''
        Ok     = $true
        Note   = ''
    }

    if (-not (Test-Path -LiteralPath $InstallRoot)) {
        $info.Note = 'no previous install'
        return $info
    }

    $target = New-UxSiblingDirPath -InstallRoot $InstallRoot -Kind 'bak'
    if (-not $target) {
        $info.Ok = $false
        $info.Note = 'the install directory has no usable parent directory'
        return $info
    }

    try {
        Move-Item -LiteralPath $InstallRoot -Destination $target -ErrorAction Stop
    }
    catch {
        $info.Ok = $false
        $info.Note = $_.Exception.Message
        return $info
    }

    $info.Backup = $target
    return $info
}

# Puts a moved-aside install dir back where the profile block expects it.
function Restore-UxInstallDirAside {
    param(
        [string]$Backup,
        [string]$InstallRoot
    )

    if (-not $Backup) { return $false }
    if (-not (Test-Path -LiteralPath $Backup)) { return $false }
    try {
        Move-Item -LiteralPath $Backup -Destination $InstallRoot -ErrorAction Stop
    }
    catch {
        return $false
    }
    return $true
}

# Cheap structural check, four Test-Path calls and no hashing: is there plausibly a
# complete install at this path? It only decides which failure hint is honest, so it
# must never be expensive and must never throw.
function Test-UxInstallLooksComplete {
    param([string]$Path)

    if (-not $Path) { return $false }
    if (-not (Test-Path -LiteralPath $Path)) { return $false }

    foreach ($relative in @('manifest.json', 'ux.ps1', 'profile/profile.ps1', 'lib/00-core.ps1')) {
        $full = Join-UxRelativePath -Base $Path -Relative $relative
        if (-not (Test-Path -LiteralPath $full)) { return $false }
    }
    return $true
}

# The most recent <leaf>.bak.<stamp> sibling, if there is one that still looks like a
# complete install. Only used to make the failure hint useful when the live directory is
# already broken - for example by a failed run of an older installer version that moved
# the install dir aside before it had downloaded anything.
function Find-UxLatestDirBackup {
    param([string]$InstallRoot)

    $parent = Get-UxParent -Path $InstallRoot
    $leaf = Get-UxLeaf -Path $InstallRoot
    if (-not $parent) { return '' }
    if (-not $leaf) { return '' }
    if (-not (Test-Path -LiteralPath $parent)) { return '' }

    $prefix = $leaf + '.bak.'
    $found = @()
    foreach ($item in @(Get-ChildItem -LiteralPath $parent -Directory -Force -ErrorAction SilentlyContinue)) {
        if (-not $item.Name.StartsWith($prefix, 'OrdinalIgnoreCase')) { continue }
        $suffix = $item.Name.Substring($prefix.Length)
        if ($suffix -match '^[0-9]{14}(-[0-9]+)?$') { $found += $item }
    }
    if (@($found).Count -eq 0) { return '' }

    $sorted = @($found | Sort-Object -Property Name -Descending)
    foreach ($candidate in $sorted) {
        $path = [string]$candidate.FullName
        if (Test-UxInstallLooksComplete -Path $path) { return $path }
    }
    return ''
}

# The two-step restore recipe printed on failure. It is copy-pasteable as printed: the
# first command clears whatever is left at the install path, the second moves the backup
# into that (now empty) path. Moving a backup into a directory that still exists is what
# nested the tree in the old hint, which is why the removal comes first.
function Write-UxRestoreHint {
    param(
        [string]$InstallRoot,
        [string]$Backup,
        [switch]$BrokenTree
    )

    if ($BrokenTree) {
        Write-UxLine ('             the install directory is missing or incomplete: ' + $InstallRoot) 'Yellow'
    }
    if (-not $Backup) {
        Write-UxLine '             nothing was installed, so there is nothing to restore.' 'Yellow'
        if ($BrokenTree -and (Test-Path -LiteralPath $InstallRoot)) {
            Write-UxLine '             clear the incomplete directory and re-run the installer:' 'Yellow'
            Write-UxLine ('             Remove-Item -LiteralPath "' + $InstallRoot + '" -Recurse -Force -Confirm:$false') 'Yellow'
        }
        return
    }

    Write-UxLine ('             previous install is intact at: ' + $Backup) 'Yellow'
    Write-UxLine '             restore it with these two commands, in this order:' 'Yellow'
    Write-UxLine ('             Remove-Item -LiteralPath "' + $InstallRoot + '" -Recurse -Force -Confirm:$false') 'Yellow'
    Write-UxLine ('             Move-Item -LiteralPath "' + $Backup + '" -Destination "' + $InstallRoot + '"') 'Yellow'
}

# ---------------------------------------------------------------------------------
# Profile block maintenance: insert, replace, or remove, idempotently.
# ---------------------------------------------------------------------------------
function Update-UxProfileFile {
    param(
        [string]$ProfilePath,
        [string]$BlockText,
        [switch]$RemoveOnly
    )

    $info = @{
        Path   = $ProfilePath
        Action = 'absent'
        Backup = ''
        Note   = ''
    }

    $exists = Test-Path -LiteralPath $ProfilePath
    $content = ''
    if ($exists) {
        $item = Get-Item -LiteralPath $ProfilePath -Force -ErrorAction SilentlyContinue
        if ($item -and $item.PSObject.Properties['PSIsContainer'] -and $item.PSIsContainer) {
            $info.Action = 'manual'
            $info.Note = 'path is a directory, not a file'
            return $info
        }
        $content = Read-UxFileText -Path $ProfilePath
    }

    $newLine = Get-UxNewLineFor -Content $content
    $trimChars = @([char]10, [char]13)
    $before = $content.TrimEnd($trimChars)

    if ($RemoveOnly) {
        if (-not $exists) {
            $info.Action = 'absent'
            return $info
        }
        if ($content -notmatch $script:UxBlockMarker) {
            $info.Action = 'absent'
            $info.Note = 'no block found'
            return $info
        }
        $payload = $content -replace $script:UxBlockPattern, ''
        if ($payload -match $script:UxBlockMarker) {
            $info.Action = 'manual'
            $info.Note = 'unmatched BEGIN marker left in place'
            return $info
        }
        $payload = $payload.TrimEnd($trimChars)
        $newContent = ''
        if ($payload.Length -gt 0) { $newContent = $payload + $newLine }
    }
    else {
        $payload = $content -replace $script:UxBlockPattern, ''
        if ($payload -match $script:UxBlockMarker) {
            $info.Action = 'manual'
            $info.Note = 'unmatched BEGIN marker left in place; remove it by hand and re-run'
            return $info
        }
        $payload = $payload.TrimEnd($trimChars)
        if ($payload.Length -gt 0) {
            $newContent = $payload + $newLine + $newLine + $BlockText + $newLine
        }
        else {
            $newContent = $BlockText + $newLine
        }
    }

    $after = $newContent.TrimEnd($trimChars)
    if ($exists -and $before.Equals($after, 'Ordinal')) {
        $info.Action = 'unchanged'
        return $info
    }

    # A backup is only useful when there is user material to protect, and it is written
    # at most once per run for a given file (this function is called once per file).
    if (-not $RemoveOnly) {
        if ($before.Length -gt 0) {
            try {
                $info.Backup = New-UxProfileBackup -ProfilePath $ProfilePath
            }
            catch {
                Write-UxWarn ('could not back up {0}: {1}' -f $ProfilePath, $_.Exception.Message)
            }
        }
    }

    $parent = Get-UxParent -Path $ProfilePath
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        $null = New-Item -ItemType Directory -Force -Path $parent
    }

    Set-Content -LiteralPath $ProfilePath -Value $newContent -Encoding UTF8 -NoNewline

    if ($RemoveOnly) {
        $info.Action = 'removed'
    }
    elseif ($exists) {
        $info.Action = 'updated'
    }
    else {
        $info.Action = 'created'
    }
    return $info
}

function Get-UxProfileTargets {
    param([switch]$IncludeOtherHost)

    $targets = @()
    $running = Get-UxCurrentUserAllHostsProfile
    if ($running) { $targets += $running }

    if ($IncludeOtherHost) {
        $other = Get-UxOtherHostProfile
        if ($other) {
            $duplicate = $false
            foreach ($existing in $targets) {
                if (Test-UxPathsEqual -Path $existing -Other $other) { $duplicate = $true }
            }
            if (-not $duplicate) { $targets += $other }
        }
    }
    return $targets
}

# ---------------------------------------------------------------------------------
# Execution policy: three tiers, honestly labelled (PLAN.md section 6).
# ---------------------------------------------------------------------------------
function Invoke-UxExecutionPolicyStep {
    param([switch]$Requested)

    $state = @{
        Requested = [bool]$Requested
        Changed   = $false
        Summary   = 'not requested'
        Detail    = ''
    }

    if (-not $Requested) {
        $current = ''
        try { $current = [string](Get-ExecutionPolicy -Scope CurrentUser -ErrorAction SilentlyContinue) } catch { $current = '' }
        if ($current) {
            $state.Summary = 'unchanged (CurrentUser = ' + $current + ')'
        }
        else {
            $state.Summary = 'unchanged'
        }
        return $state
    }

    if ($env:OS -ne 'Windows_NT') {
        $state.Summary = 'not changed - execution policy is not enforced on this platform'
        $state.Detail = 'Set-ExecutionPolicy is Windows-only; nothing to do here.'
        return $state
    }

    $entries = @()
    try {
        $entries = @(Get-ExecutionPolicy -List -ErrorAction Stop)
    }
    catch {
        $entries = @()
    }

    foreach ($entry in $entries) {
        $scope = ''
        $policy = ''
        if ($entry.PSObject.Properties['Scope']) { $scope = [string]$entry.Scope }
        if ($entry.PSObject.Properties['ExecutionPolicy']) { $policy = [string]$entry.ExecutionPolicy }
        if ($scope -eq 'MachinePolicy' -or $scope -eq 'UserPolicy') {
            if ($policy -and $policy -ne 'Undefined') {
                $state.Summary = 'not changed - blocked by a Group Policy setting'
                $state.Detail = ('{0} is {1}, which overrides the CurrentUser scope. Setting CurrentUser would be ignored, so nothing was changed. Ask IT for an exception, or use the iex one-liner documented in the README.' -f $scope, $policy)
                return $state
            }
        }
    }

    try {
        Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned -Force -Confirm:$false -ErrorAction Stop
        $state.Changed = $true
        $readBack = ''
        try { $readBack = [string](Get-ExecutionPolicy -Scope CurrentUser -ErrorAction SilentlyContinue) } catch { $readBack = '' }
        if (-not $readBack) { $readBack = 'RemoteSigned' }
        $state.Summary = 'set to RemoteSigned (CurrentUser)'
        $state.Detail = ('This is a per-user change. Revert with: Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy Undefined (or -ExecutionPolicy Restricted). Current value now reads: ' + $readBack)
    }
    catch {
        $state.Summary = 'could not be changed'
        $state.Detail = $_.Exception.Message
    }
    return $state
}

# ---------------------------------------------------------------------------------
# Post-install doctor (PLAN.md section 5.6 step 7). It runs in a CHILD process so nothing
# it does - dot-sourcing the profile entry point, defining wrappers, rebuilding
# $global:Ux - can leak into the installer's own session. Its output is streamed, and any
# problem with it is one plain line: by the time it runs the files are already verified
# on disk, so a doctor failure must never fail the install.
# ---------------------------------------------------------------------------------
function Get-UxHostExecutable {
    $root = ''
    try { $root = [string]$PSHOME } catch { $root = '' }
    if (-not $root) { return '' }

    $major = 5
    if ($PSVersionTable.ContainsKey('PSVersion')) { $major = [int]$PSVersionTable.PSVersion.Major }

    # The running host's own executable first: a 5.1 host must start powershell.exe, a 7+
    # host pwsh.exe, and on Linux/macOS the binary in $PSHOME has no extension.
    $names = @()
    if ($env:OS -eq 'Windows_NT') {
        if ($major -ge 7) { $names += 'pwsh.exe' }
        $names += 'powershell.exe'
        $names += 'pwsh.exe'
    }
    else {
        $names += 'pwsh'
        $names += 'powershell'
    }

    foreach ($name in $names) {
        $candidate = Join-Path $root $name
        if (Test-Path -LiteralPath $candidate) { return $candidate }
    }
    return ''
}

function Invoke-UxDoctorStep {
    param([string]$InstallRoot)

    $entry = Join-UxRelativePath -Base $InstallRoot -Relative 'ux.ps1'
    if (-not (Test-Path -LiteralPath $entry)) {
        Write-UxLine 'doctor      : skipped (ux.ps1 is not in the install directory)' 'Gray'
        return
    }

    $executable = Get-UxHostExecutable
    if (-not $executable) {
        Write-UxWarn 'doctor      : could not run - the PowerShell executable for this session was not found'
        Write-UxLine '              the install is complete; run it yourself after restarting the shell: ux doctor' 'Gray'
        return
    }

    Write-UxLine ''
    Write-UxLine ('doctor      : ' + $executable + ' -NoProfile -File "' + $entry + '" doctor') 'Gray'

    $failed = $false
    $exitCode = 0
    try {
        & $executable -NoProfile -File $entry doctor
        $lastExit = Get-Variable -Name 'LASTEXITCODE' -ErrorAction SilentlyContinue
        if ($lastExit) {
            if ($LASTEXITCODE) { $exitCode = [int]$LASTEXITCODE }
        }
    }
    catch {
        $failed = $true
        Write-UxWarn ('doctor      : could not run - ' + [string]$_.Exception.Message)
    }

    if ($failed) {
        Write-UxLine ('              the install is complete; run it yourself after restarting the shell: ux doctor') 'Gray'
        return
    }
    if ($exitCode -ne 0) {
        Write-UxWarn ('doctor      : reported a problem (exit code ' + [string]$exitCode + '); the installed files are complete.')
        Write-UxLine '              restart the shell and run: ux doctor' 'Gray'
    }
}

# Printed when a profile file could not be patched automatically (read-only file, damaged
# markers, a directory in the way). The exact block is printed because guessing at a
# half-written block is how profiles get corrupted; the installer never writes a partial
# one.
function Write-UxBlockManualHint {
    param(
        [string]$ProfilePath,
        [string]$Reason,
        [string]$BlockText
    )

    Write-UxWarn ('profile     : could not patch ' + $ProfilePath + ' - ' + $Reason)
    Write-UxWarn '              the installed files are complete and valid; only the profile block is missing.'
    Write-UxLine '              manual step: open that file in an editor and paste this block in, exactly as shown:' 'Yellow'
    if ($BlockText) {
        foreach ($line in @($BlockText -split "\r?\n")) {
            if ($line) { Write-UxLine ('              ' + $line) 'Yellow' }
        }
    }
}

# A block whose markers were damaged (one of the two lines edited or deleted) can never be
# matched by the regex, so it is not guessed at and the file is not truncated: the user
# gets the exact instruction instead. The text is deliberately identical to the helper of
# the same name in uninstall.ps1.
function Write-UxManualBlockHint {
    param(
        [string]$ProfilePath,
        [string]$Note
    )

    Write-UxWarn ('profile     : ' + $ProfilePath + ' needs a manual edit - ' + $Note)
    Write-UxLine '              manual step: open that file and delete every line from "# BEGIN unix-powershell"' 'Yellow'
    Write-UxLine '              to "# END unix-powershell", including both marker lines.' 'Yellow'
    Write-UxLine '              If only one of the two marker lines is still there, delete that line as well,' 'Yellow'
    Write-UxLine '              save the file, and run this command again.' 'Yellow'
}

# ---------------------------------------------------------------------------------
# Uninstall flow (shared by -Uninstall)
# ---------------------------------------------------------------------------------
function Invoke-UxUninstallFlow {
    param(
        [string]$InstallRoot,
        [string]$HomePath,
        [switch]$IncludeOtherHost,
        [switch]$NoConfirm,
        [switch]$SkipProfile
    )

    Write-UxLine ''
    Write-UxLine 'unix-powershell - uninstall' 'Cyan'
    Write-UxLine '============================' 'Cyan'

    $cwd = ''
    try { $cwd = [string](Get-Location).Path } catch { $cwd = '' }
    if ($cwd -and (Test-UxPathInside -Path $cwd -Root $InstallRoot)) {
        Stop-UxError -Message 'refusing to uninstall while the current directory is inside the install directory.' -Detail @(('current directory: ' + $cwd), ('install directory: ' + $InstallRoot), 'Change to another directory and re-run.')
    }

    # 1. profile block(s)
    if ($SkipProfile) {
        Write-UxLine 'profile   : not touched (-NoProfile)' 'Gray'
    }
    else {
        $targets = @(Get-UxProfileTargets -IncludeOtherHost:$IncludeOtherHost)
        $blockText = Get-UxBlockText -Version $script:UxVersion -InstallRoot $InstallRoot -DefaultInstallRoot (Join-Path $HomePath '.unix-powershell') -NewLine "`n"
        foreach ($target in $targets) {
            $result = Update-UxProfileFile -ProfilePath $target -BlockText $blockText -RemoveOnly
            switch ($result.Action) {
                'removed' {
                    Write-UxLine ('profile   : removed the unix-powershell block from ' + $target) 'Green'
                }
                'absent' {
                    Write-UxLine ('profile   : no block in ' + $target + ' (' + $result.Note + ')') 'Gray'
                }
                'manual' {
                    Write-UxManualBlockHint -ProfilePath $target -Note $result.Note
                }
                default {
                    Write-UxLine ('profile   : ' + $target + ' -> ' + $result.Action) 'Gray'
                }
            }
        }
    }

    # 2. install directory
    $exists = Test-Path -LiteralPath $InstallRoot
    $mayRemove = $true
    if ($exists -and -not $NoConfirm) {
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
    }
    elseif (-not $exists) {
        Write-UxLine ('install   : nothing at ' + $InstallRoot + ' (already clean)') 'Gray'
    }

    # 3. report what is left behind instead of deleting anything else
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
    Write-UxLine 'next step : restart your shell (the profile block is gone)' 'Cyan'
    Write-UxLine ''
}

# ---------------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------------
$HomePath = Get-UxHomePath

if (-not $InstallDir) { $InstallDir = Join-Path $HomePath '.unix-powershell' }
$InstallRoot = Get-UxFullPath -Path $InstallDir

# Refusals first: never let a typo aim this script at a drive root or at $HOME itself.
if (-not $InstallRoot) {
    Stop-UxError -Message 'the install directory resolved to an empty path.' -Detail @('Pass -InstallDir with an absolute path under your home directory.')
}
if (Test-UxRootPath -Path $InstallRoot) {
    Stop-UxError -Message 'refusing to use a filesystem root as the install directory.' -Detail @(('install directory: ' + $InstallRoot), 'Pass -InstallDir with a dedicated folder, for example $HOME\.unix-powershell.')
}
if (Test-UxPathsEqual -Path $InstallRoot -Other $HomePath) {
    Stop-UxError -Message 'refusing to use the home directory itself as the install directory.' -Detail @(('home directory: ' + $HomePath), 'Pass -InstallDir with a dedicated folder, for example $HOME\.unix-powershell.')
}
if (Test-UxPathInside -Path $HomePath -Root $InstallRoot) {
    Stop-UxError -Message 'refusing to install into a directory that contains your home directory.' -Detail @(('install directory: ' + $InstallRoot), ('home directory: ' + $HomePath))
}

$DefaultInstallRoot = Join-Path $HomePath '.unix-powershell'

# UX_DISABLE only bypasses the profile block at shell start. It is deliberately
# irrelevant here: installing or repairing while the profile is disabled is legitimate.
if (-not $Proxy) {
    if ($env:UX_PROXY) { $Proxy = [string]$env:UX_PROXY }
}

if ($Uninstall) {
    Invoke-UxUninstallFlow -InstallRoot $InstallRoot -HomePath $HomePath -IncludeOtherHost:$AllHosts -NoConfirm:$Force -SkipProfile:$NoProfile
    return
}

if (-not (Test-UxPathInside -Path $InstallRoot -Root $HomePath)) {
    Write-UxWarn ('the install directory is outside your home directory: ' + $InstallRoot)
    Write-UxWarn 'unix-powershell is designed to live under $HOME and to need no admin rights.'
}

Write-UxLine ''
Write-UxLine ('unix-powershell ' + $script:UxVersion + ' - installer') 'Cyan'
Write-UxLine '================================' 'Cyan'

# Installer state that the failure handler needs. $stagingRoot is set while a staged tree
# exists and cleared the moment that tree is activated, so the handler can never delete a
# live install. $swapDone records whether the live directory was already replaced.
$stagingRoot = ''
$swapDone = $false
$profileBlock = ''

try {
    # ---------------------------------------------------------------- 1. manifest
    $sourceRoot = ''
    $manifestText = ''
    if ($SourceDir) {
        $sourceRoot = Get-UxFullPath -Path $SourceDir
        if (-not (Test-Path -LiteralPath $sourceRoot)) {
            Stop-UxError -Message '-SourceDir does not exist.' -Detail @([string]$sourceRoot)
        }
        $sourceManifest = Join-Path $sourceRoot 'manifest.json'
        if (-not (Test-Path -LiteralPath $sourceManifest)) {
            Stop-UxError -Message '-SourceDir has no manifest.json.' -Detail @([string]$sourceManifest, 'Point -SourceDir at a checkout or at an extracted release zip.')
        }
        $manifestText = Read-UxFileText -Path $sourceManifest
        Write-UxLine ('source    : ' + $sourceRoot) 'Gray'
    }
    else {
        Write-UxLine ('manifest  : ' + $script:UxManifestUrl) 'Gray'
        $manifestText = Get-UxRemoteText -Url $script:UxManifestUrl -ProxyUri $Proxy -DefaultCredentials:$UseDefaultCredentials
    }

    $manifest = Read-UxManifestDocument -Text $manifestText
    $version = [string]$manifest.Version
    $files = @($manifest.Files)

    if ($version -ne $script:UxVersion) {
        Write-UxWarn ('manifest version ' + $version + ' differs from the installer pin ' + $script:UxVersion + '; the manifest wins for what gets installed.')
    }

    Write-UxLine ('version   : ' + $version + ' (' + [string]$files.Count + ' files)') 'Gray'

    # ---------------------------------------------------------------- 2. staging dir
    # Nothing is downloaded into, or moved out of, the live install dir. Everything that
    # can fail happens in a sibling staging directory, so a failure here leaves the
    # previous install (and therefore the user's shell) working.
    $liveConfigPath = Join-Path $InstallRoot 'config.json'
    $configText = ''
    $configPresent = $false
    if (Test-Path -LiteralPath $liveConfigPath) {
        $configText = Read-UxFileText -Path $liveConfigPath
        $configPresent = $true
    }

    $stagingRoot = New-UxSiblingDirPath -InstallRoot $InstallRoot -Kind 'new'
    if (-not $stagingRoot) {
        Stop-UxError -Message 'could not create a staging directory next to the install directory.' -Detail @(('install directory: ' + $InstallRoot), 'The install directory needs a parent directory that the current user can write to.')
    }
    # New-Item has no -LiteralPath parameter set (verified on 5.1-era and 7 docs: the only
    # sets are pathSet and nameSet, both with -Path), so -Path is the only option here. It
    # creates the leaf verbatim, so a directory name containing [ ] still works.
    try {
        $null = New-Item -ItemType Directory -Force -Path $stagingRoot -ErrorAction Stop
    }
    catch {
        Stop-UxError -Message 'could not create the staging directory, so nothing was changed.' -Detail @(
            ('staging directory: ' + $stagingRoot),
            ('reason: ' + [string]$_.Exception.Message),
            'The parent of the install directory must be writable by the current user.'
        )
    }
    Write-UxLine ('staging   : ' + $stagingRoot) 'Gray'

    # ---------------------------------------------------------------- 3. files
    $curlPath = ''
    if (-not $sourceRoot) {
        $curlPath = Get-UxCurlPath
        if ($curlPath) {
            Write-UxLine ('download  : curl.exe (' + $curlPath + ')') 'Gray'
        }
        else {
            Write-UxLine 'download  : Invoke-WebRequest (curl.exe not found)' 'Gray'
        }
    }

    $unblockAvailable = [bool](Get-Command Unblock-File -ErrorAction SilentlyContinue)
    $parserAvailable = Test-UxParserAvailable

    $written = 0
    $hashVerified = 0
    $hashSkipped = 0
    $unblocked = 0
    $unblockAttempted = 0
    $parsed = 0
    $parseSkipped = 0
    $downloadTag = 'v' + $version

    foreach ($file in $files) {
        $relative = [string]$file.Path
        if (-not (Test-UxRelativePathSafe -Relative $relative)) {
            Stop-UxError -Message 'refusing to install: manifest.json lists an unsafe file path.' -Detail @([string]$relative, 'A path must be relative and must not contain "..".')
        }
        $destination = Join-UxRelativePath -Base $stagingRoot -Relative $relative
        if (-not (Test-UxPathInside -Path $destination -Root $stagingRoot)) {
            Stop-UxError -Message 'refusing to install: a manifest path escapes the install directory.' -Detail @([string]$relative)
        }

        $destinationParent = Get-UxParent -Path $destination
        if ($destinationParent -and -not (Test-Path -LiteralPath $destinationParent)) {
            $null = New-Item -ItemType Directory -Force -Path $destinationParent
        }

        if ($sourceRoot) {
            $origin = Join-UxRelativePath -Base $sourceRoot -Relative $relative
            if (-not (Test-Path -LiteralPath $origin)) {
                Stop-UxError -Message ('-SourceDir is missing ' + $relative) -Detail @(('expected at: ' + $origin))
            }
            Copy-Item -LiteralPath $origin -Destination $destination -Force -ErrorAction Stop
        }
        else {
            $url = $script:UxRawBase + '/' + $downloadTag + '/' + $relative
            Invoke-UxFetch -Url $url -Destination $destination -ProxyUri $Proxy -DefaultCredentials:$UseDefaultCredentials -CurlPath $curlPath
        }
        $written = $written + 1

        # SHA256 is the real integrity gate (CLM-safe: Get-FileHash is a core cmdlet).
        if ($file.Sha256) {
            $actual = ''
            $hash = Get-FileHash -LiteralPath $destination -Algorithm SHA256 -ErrorAction Stop
            $actual = ([string]$hash.Hash).ToLowerInvariant()
            if (-not $actual.Equals([string]$file.Sha256, 'Ordinal')) {
                Stop-UxError -Message ('SHA256 mismatch for ' + $relative) -Detail @(
                    ('expected: ' + [string]$file.Sha256),
                    ('actual:   ' + $actual),
                    'The download was corrupted or tampered with, or the checkout is dirty.',
                    'Re-run the installer, or use -SourceDir with a reviewed checkout and',
                    'compare it against the published SHA256SUMS before installing.')
            }
            $hashVerified = $hashVerified + 1
        }
        else {
            $hashSkipped = $hashSkipped + 1
        }

        # Strip Zone.Identifier from zips and downloads. Unblock-File does not exist on
        # every platform, and it is a no-op or an error where it does not apply.
        if ($unblockAvailable) {
            $unblockAttempted = $unblockAttempted + 1
            if (Invoke-UxUnblockFile -Path $destination) { $unblocked = $unblocked + 1 }
        }

        # Best-effort syntax check. The Parser type is blocked in ConstrainedLanguage
        # mode; that is reported as skipped rather than silently ignored.
        if ($destination.EndsWith('.ps1', 'OrdinalIgnoreCase')) {
            if ($parserAvailable) {
                $parse = Test-UxScriptParses -Path $destination
                if ($parse.Skipped) {
                    $parseSkipped = $parseSkipped + 1
                }
                elseif (-not $parse.Ok) {
                    Stop-UxError -Message ('the installed file does not parse: ' + $relative) -Detail @([string]$parse.Message, 'Hashes matched, so this is a bug in the release - report it rather than editing the file.')
                }
                else {
                    $parsed = $parsed + 1
                }
            }
            else {
                $parseSkipped = $parseSkipped + 1
            }
        }
    }

    # ---------------------------------------------------------------- 4. complete the staged tree
    # The user's settings are carried into the staged tree (never into the live one), so a
    # swap can never lose them.
    if ($configPresent) {
        Set-Content -LiteralPath (Join-UxRelativePath -Base $stagingRoot -Relative 'config.json') -Value $configText -Encoding UTF8 -NoNewline
    }

    Set-Content -LiteralPath (Join-UxRelativePath -Base $stagingRoot -Relative 'manifest.json') -Value $manifestText -Encoding UTF8 -NoNewline

    # ---------------------------------------------------------------- 5. swap
    # Every file exists in the staged tree and every hash and parse check has passed, so
    # this is the only point where the live install dir is replaced. Both moves are
    # renames inside one parent directory; if the second one fails the first is undone.
    $backup = Move-UxInstallDirAside -InstallRoot $InstallRoot
    if (-not $backup.Ok) {
        Stop-UxError -Message 'could not move the previous install aside, so nothing was changed.' -Detail @(
            ('reason: ' + [string]$backup.Note),
            ('previous install: ' + $InstallRoot),
            'Close any shell that is using the install directory and run the installer again.'
        )
    }
    $backupDir = [string]$backup.Backup
    if ($backupDir) {
        $script:UxLastBackup = $backupDir
        Write-UxLine ('backup    : previous install moved to ' + $backupDir) 'Gray'
    }

    # Move-Item NESTS the source when the destination already exists, which is exactly how
    # the old recovery hint broke a backup. So the destination is checked before the move and
    # the result is checked after it: "did not throw" is not the same as "the tree landed".
    $activationError = ''
    if (Test-Path -LiteralPath $InstallRoot) {
        $activationError = 'the install directory was recreated while it was being replaced'
    }
    else {
        try {
            Move-Item -LiteralPath $stagingRoot -Destination $InstallRoot -ErrorAction Stop
        }
        catch {
            $activationError = [string]$_.Exception.Message
        }
        if (-not $activationError) {
            if ((Test-Path -LiteralPath $stagingRoot) -or -not (Test-UxInstallLooksComplete -Path $InstallRoot)) {
                $activationError = 'the staged copy did not land at the install directory'
            }
        }
    }

    if ($activationError) {
        # A restore move has the same nesting hazard, so it is only attempted when the install
        # path is free again.
        if ($backupDir -and -not (Test-Path -LiteralPath $InstallRoot)) {
            if (Restore-UxInstallDirAside -Backup $backupDir -InstallRoot $InstallRoot) {
                $script:UxLastBackup = ''
                Stop-UxError -Message 'could not activate the new install; the previous install was put back and keeps working.' -Detail @(
                    ('reason: ' + $activationError),
                    'The staged copy is deleted; nothing else was changed. Run the installer again.'
                )
            }
        }
        if ($backupDir) {
            $script:UxRestoreNeeded = $true
            Stop-UxError -Message 'could not activate the new install, and the previous install is not back in place.' -Detail @(
                ('reason: ' + $activationError),
                ('previous install (intact): ' + $backupDir),
                'Use the restore commands printed below.'
            )
        }
        Stop-UxError -Message 'could not activate the new install.' -Detail @(
            ('reason: ' + $activationError),
            'There was no previous install, so nothing was lost. Run the installer again.'
        )
    }

    # The staged tree is now the live tree: the failure handler must not delete it.
    $stagingRoot = ''
    Write-UxLine ('install   : activated ' + $InstallRoot) 'Gray'

    # ---------------------------------------------------------------- 6. prune old backups
    # Only after a successful swap, so a failed install never loses its rollback target.
    $pruneParent = Get-UxParent -Path $InstallRoot
    $pruneLeaf = Get-UxLeaf -Path $InstallRoot
    if ($pruneParent -and $pruneLeaf) {
        foreach ($pruned in @(Remove-UxOldDirBackups -Parent $pruneParent -Leaf $pruneLeaf -Keep $script:UxKeepBackups)) {
            Write-UxLine ('pruned    : ' + $pruned) 'Gray'
        }
    }

    # ---------------------------------------------------------------- 7. profile patch
    # After the swap: the block must never point at a tree that is not there yet.
    $profileResults = @()
    if (-not $NoProfile) {
        $runningProfile = Get-UxCurrentUserAllHostsProfile
        $blockNewLine = "`n"
        if ($runningProfile) {
            $runningContent = ''
            if (Test-Path -LiteralPath $runningProfile) {
                $runningContent = Read-UxFileText -Path $runningProfile
            }
            $blockNewLine = Get-UxNewLineFor -Content $runningContent
        }
        $profileBlock = Get-UxBlockText -Version $version -InstallRoot $InstallRoot -DefaultInstallRoot $DefaultInstallRoot -NewLine $blockNewLine

        $patchTarget = [string]$runningProfile
        try {
            $targets = @(Get-UxProfileTargets -IncludeOtherHost:$AllHosts)
            foreach ($target in $targets) {
                $patchTarget = [string]$target
                $result = Update-UxProfileFile -ProfilePath $target -BlockText $profileBlock
                $profileResults += $result
            }
        }
        catch {
            # The files are already live and verified: a profile problem must not undo them.
            Write-UxBlockManualHint -ProfilePath $patchTarget -Reason ([string]$_.Exception.Message) -BlockText $profileBlock
        }
    }

    # ---------------------------------------------------------------- 8. execution policy
    $policy = Invoke-UxExecutionPolicyStep -Requested:$SetExecutionPolicy

    # ---------------------------------------------------------------- 9. summary
    Write-UxLine ''
    Write-UxLine 'summary' 'Cyan'
    Write-UxLine '-------' 'Cyan'
    Write-UxLine ('install dir : ' + $InstallRoot)
    Write-UxLine ('files       : ' + [string]$written + ' written')
    $hashLine = [string]$hashVerified + ' verified'
    if ($hashSkipped -gt 0) { $hashLine = $hashLine + ', ' + [string]$hashSkipped + ' without a recorded hash' }
    Write-UxLine ('sha256      : ' + $hashLine)
    if (-not $unblockAvailable) {
        Write-UxLine 'unblocked   : skipped (Unblock-File is not available on this platform)'
    }
    elseif ($unblocked -gt 0) {
        Write-UxLine ('unblocked   : ' + [string]$unblocked + ' files (Zone.Identifier removed where present)')
    }
    else {
        Write-UxLine ('unblocked   : not supported here (tried ' + [string]$unblockAttempted + ' files; Zone.Identifier does not exist on this platform)')
    }
    if ($parserAvailable) {
        $parseLine = [string]$parsed + ' parsed'
        if ($parseSkipped -gt 0) { $parseLine = $parseLine + ', ' + [string]$parseSkipped + ' not parsed' }
        Write-UxLine ('parse check : ' + $parseLine)
    }
    else {
        Write-UxLine 'parse check : skipped (the PowerShell parser type is unavailable here - Constrained Language Mode)'
    }
    if ($configPresent) {
        Write-UxLine 'config      : preserved (config.json carried forward)'
    }
    else {
        Write-UxLine 'config      : defaults (no config.json existed yet)'
    }

    if ($NoProfile) {
        Write-UxLine 'profile     : not touched (-NoProfile)'
    }
    else {
        foreach ($result in $profileResults) {
            switch ($result.Action) {
                'created' {
                    Write-UxLine ('profile     : created and patched ' + $result.Path) 'Green'
                }
                'updated' {
                    Write-UxLine ('profile     : patched ' + $result.Path) 'Green'
                }
                'unchanged' {
                    Write-UxLine ('profile     : already up to date ' + $result.Path) 'Green'
                }
                'manual' {
                    Write-UxManualBlockHint -ProfilePath $result.Path -Note $result.Note
                }
                default {
                    Write-UxLine ('profile     : ' + $result.Action + ' ' + $result.Path) 'Gray'
                }
            }
            if ($result.Backup) {
                Write-UxLine ('              backup: ' + $result.Backup) 'Gray'
            }
        }
    }

    Write-UxLine ('policy      : ' + $policy.Summary)
    if ($policy.Detail) {
        Write-UxLine ('              ' + $policy.Detail) 'Gray'
    }

    Write-UxLine ''
    Write-UxLine 'next step   : restart your shell, or run: . $PROFILE' 'Cyan'
    Write-UxLine 'then        : ux doctor reports version, language mode, VT support, git and policy.' 'Gray'
    if (-not $NoProfile -and $profileResults.Count -gt 0) {
        $patched = $false
        foreach ($result in $profileResults) {
            if ($result.Action -eq 'created' -or $result.Action -eq 'updated' -or $result.Action -eq 'unchanged') { $patched = $true }
        }
        if (-not $patched) {
            Write-UxWarn 'the files are installed but no profile was patched - see the manual edit note above.'
        }
    }

    # ---------------------------------------------------------------- 10. doctor
    # PLAN.md section 5.6 step 7: it runs because the install succeeded, never to decide
    # whether it succeeded. -NoProfile skips it (the block is what it exercises) and
    # -NoDoctor is the explicit opt-out.
    if ($NoDoctor) {
        Write-UxLine ''
        Write-UxLine 'doctor      : skipped (-NoDoctor)' 'Gray'
    }
    elseif ($NoProfile) {
        Write-UxLine ''
        Write-UxLine 'doctor      : skipped (-NoProfile); run it yourself after restarting the shell: ux doctor' 'Gray'
    }
    else {
        Invoke-UxDoctorStep -InstallRoot $InstallRoot
    }

    Write-UxLine ''
}
catch {
    Write-UxLine ''
    if ($script:UxReported) {
        Write-UxFail 'install did not complete - see the message above.'
    }
    else {
        Write-UxFail 'install did not complete.'
        foreach ($line in (@(([string]$_.Exception.Message) -split "\r?\n"))) {
            if ($line) { Write-UxLine ('             ' + $line) 'Red' }
        }
    }

    # Cleanup: the staged tree only. The live install dir is never touched before the swap,
    # so this is the whole of the damage a failed run can do.
    if ($stagingRoot) {
        $abandoned = [string]$stagingRoot
        $stagingRoot = ''
        if (Test-Path -LiteralPath $abandoned) {
            try {
                Remove-Item -LiteralPath $abandoned -Recurse -Force -Confirm:$false -ErrorAction Stop
                Write-UxLine ('             staged copy deleted: ' + $abandoned) 'Yellow'
            }
            catch {
                Write-UxWarn ('could not delete the staged copy at ' + $abandoned + '; delete it yourself.')
            }
        }
    }

    if ($InstallRoot) {
        Write-UxLine ('             install dir: ' + $InstallRoot) 'Yellow'
        if ($swapDone) {
            Write-UxLine '             the new install is complete on disk; only a step after the swap failed.' 'Yellow'
            if ($script:UxLastBackup) {
                Write-UxLine ('             previous install kept at: ' + $script:UxLastBackup) 'Yellow'
            }
        }
        elseif (-not $script:UxRestoreNeeded -and (Test-UxInstallLooksComplete -Path $InstallRoot)) {
            Write-UxLine '             your existing install was not touched and still works.' 'Yellow'
            Write-UxLine '             fix the cause above and run the installer again.' 'Yellow'
        }
        else {
            # The live directory is missing or incomplete, so the shell cannot load it. Point
            # at a backup that still verifies structurally (this run's, or an older one).
            $hintBackup = [string]$script:UxLastBackup
            if (-not $hintBackup) { $hintBackup = Find-UxLatestDirBackup -InstallRoot $InstallRoot }
            Write-UxRestoreHint -InstallRoot $InstallRoot -Backup $hintBackup -BrokenTree
        }
    }
    throw
}
