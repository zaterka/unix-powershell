#Requires -Version 5.1
#
# unix-powershell - lib/20-prompt.ps1
# Prompt engine and the four built-in themes.
# Target: Windows PowerShell 5.1 (7+ compatible). Pure ASCII. Strict-mode-proof.
# No .NET static calls, no reflection, no Invoke-Expression, no Add-Type, no network.
#
# Two layers, so tests never depend on global state:
#   Format-UxPrompt   PURE  model -> array of @{ Text; Color; Vt }
#   Write-UxPromptSegments  the only function that touches the host (Write-Host -NoNewline)
#   Get-UxPromptModel       session state + config + git -> model hashtable
#   prompt                  thin wrapper: capture status -> model -> render -> emit -> ' '
#
# Model contract (Format-UxPrompt reads these keys; every one is optional):
#   User, Host, Path, Git, Time, LastExit, LastOk, Symbol, Width
#   plus the resolved options Get-UxPromptModel adds so Format stays pure:
#   PathStyle, ShowUser, ShowHost, ShowTime, ShowGit, ShowExit, Theme
#
# Git model consumed (owned by lib/10-git.ps1, treated as optional and read defensively):
#   @{ Root; Branch; Detached; ShortSha; Dirty; Ahead; Behind; State; IsRepo }
#
# Segment contract returned by Format-UxPrompt:
#   @{ Text = <string>; Color = <ConsoleColor name>; Vt = <SGR parameters> }
#   Text values concatenated are exactly the visible prompt. Mode only changes Vt; Width
#   truncation is the one thing that can change Text (and it applies in every mode).
#   ANSI escapes are never stored in Text; Write-UxPromptSegments wraps Vt in
#   $global:Ux.Esc + '[' + Vt + 'm' so no literal ESC byte or backtick-e exists in this file.
#
# LOAD ORDER: dot-sourced by profile/profile.ps1 after 00-core.ps1 / 10-git.ps1.
# Every sibling API (Get-UxConfig, Get-UxGitModel, Test-UxInteractive, $global:Ux) is
# optional at load time because this file is also smoke-tested standalone.
#

# ---------------------------------------------------------------------------
# Theme data. One renderer (New-UxPromptRender) consumes these tables; no theme
# is a hand-written output function. All shapes are pure ASCII and stock-font safe.
#
#   Layout       ps | classic | blocks | twoline
#   Prefix       literal lead-in for the ps layout
#   GitOpen/Close  brackets around the git segment for ps/classic/twoline
#   SegmentJoin  separator used by the blocks layout
#   Vt           SGR parameters per role (only emitted in Mode Vt)
#   Colors       ConsoleColor name per role (only used in Mode Console)
# ---------------------------------------------------------------------------
$script:UxPromptThemes = @{
    'ascii' = @{
        Layout      = 'ps'
        Prefix      = 'PS'
        GitOpen     = '('
        GitClose    = ')'
        SegmentJoin = ' '
        Vt     = @{ prefix = '1;32'; identity = '1;32'; path = '1;36'; git = '33'; exit = '1;31'; symbol = '1;32'; time = '90' }
        Colors = @{ prefix = 'Green'; identity = 'Green'; path = 'Cyan'; git = 'Yellow'; exit = 'Red'; symbol = 'Green'; time = 'DarkGray' }
    }
    'classic' = @{
        Layout      = 'classic'
        Prefix      = ''
        GitOpen     = '('
        GitClose    = ')'
        SegmentJoin = ' '
        Vt     = @{ prefix = '1;32'; identity = '1;32'; path = '1;36'; git = '33'; exit = '1;31'; symbol = '32'; time = '90' }
        Colors = @{ prefix = 'Green'; identity = 'Green'; path = 'Cyan'; git = 'Yellow'; exit = 'Red'; symbol = 'Green'; time = 'DarkGray' }
    }
    'blocks' = @{
        Layout      = 'blocks'
        Prefix      = ''
        GitOpen     = ''
        GitClose    = ''
        SegmentJoin = ' > '
        Vt     = @{ prefix = '1;32'; identity = '7;32'; path = '7;36'; git = '7;33'; exit = '7;31'; symbol = '1;32'; time = '7;90' }
        Colors = @{ prefix = 'Green'; identity = 'Green'; path = 'Cyan'; git = 'Yellow'; exit = 'Red'; symbol = 'Green'; time = 'Gray' }
    }
    'two-line' = @{
        Layout      = 'twoline'
        Prefix      = ''
        GitOpen     = '('
        GitClose    = ')'
        SegmentJoin = ' '
        Vt     = @{ prefix = '1;32'; identity = '1;32'; path = '2;36'; git = '2;33'; exit = '1;31'; symbol = '1;32'; time = '90' }
        Colors = @{ prefix = 'Green'; identity = 'Green'; path = 'DarkCyan'; git = 'DarkYellow'; exit = 'Red'; symbol = 'Green'; time = 'DarkGray' }
    }
}

# ConsoleColor names accepted by Write-Host -ForegroundColor (validated before use so a bad
# value can never throw from inside the prompt).
$script:UxPromptColorNames = @(
    'Black', 'DarkBlue', 'DarkGreen', 'DarkCyan', 'DarkRed', 'DarkMagenta', 'DarkYellow',
    'Gray', 'DarkGray', 'Blue', 'Green', 'Cyan', 'Red', 'Magenta', 'Yellow', 'White'
)

# ---------------------------------------------------------------------------
# Defensive value access. Everything read from the model, the git model or config
# goes through here so a missing key, a PSCustomObject or $null can never throw
# under Set-StrictMode -Version Latest.
# ---------------------------------------------------------------------------
function Get-UxPromptMapValue {
    param(
        $Map,
        [string]$Key = '',
        $Default = $null
    )

    if ($null -eq $Map -or $Key -eq '') { return $Default }
    try {
        if ($Map -is [hashtable]) {
            if ($Map.ContainsKey($Key)) {
                $value = $Map[$Key]
                if ($null -ne $value) { return $value }
            }
            return $Default
        }

        $property = $null
        try { $property = $Map.PSObject.Properties[$Key] } catch { $property = $null }
        if ($null -ne $property) {
            $value = $property.Value
            if ($null -ne $value) { return $value }
        }
    } catch { }
    return $Default
}

function ConvertTo-UxPromptBool {
    # Typed coercion that does not fall into the [bool]'false' -eq $true trap.
    param(
        $Value,
        [bool]$Default = $false
    )

    if ($null -eq $Value) { return $Default }
    if ($Value -is [bool]) { return $Value }
    try {
        if ($Value -is [int] -or $Value -is [long] -or $Value -is [double]) { return ([double]$Value -ne 0) }
    } catch { }
    $text = ''
    try { $text = ([string]$Value).Trim().ToLowerInvariant() } catch { return $Default }
    if ($text -eq 'true' -or $text -eq '1' -or $text -eq 'yes' -or $text -eq 'on') { return $true }
    if ($text -eq 'false' -or $text -eq '0' -or $text -eq 'no' -or $text -eq 'off') { return $false }
    return $Default
}

function ConvertTo-UxPromptHomePath {
    # Collapses the home directory prefix to '~'. Never collapses a sibling that merely
    # shares the prefix ("/home/pedro2" must not become "~2").
    param(
        [string]$Path = '',
        [string]$HomeDir = ''
    )

    if ($null -eq $Path) { return '' }
    $text = [string]$Path
    if ($text -eq '') { return '' }
    if ($null -eq $HomeDir -or $HomeDir -eq '') { return $text }

    $trimmed = [string]$HomeDir
    while ($trimmed.Length -gt 1) {
        $last = $trimmed.Substring($trimmed.Length - 1, 1)
        if ($last -eq '\' -or $last -eq '/') {
            $trimmed = $trimmed.Substring(0, $trimmed.Length - 1)
        } else {
            break
        }
    }
    if ($trimmed -eq '') { return $text }
    if ($text -eq $trimmed) { return '~' }
    if ($text.Length -le $trimmed.Length) { return $text }

    $prefix = $text.Substring(0, $trimmed.Length)
    if ($prefix -eq $trimmed) {
        $next = $text.Substring($trimmed.Length, 1)
        if ($next -eq '\' -or $next -eq '/') {
            return '~' + $text.Substring($trimmed.Length)
        }
    }
    return $text
}

# ---------------------------------------------------------------------------
# Path display. full | short | last:N, width-driven shortening, ASCII '...' marker,
# drive roots and UNC roots kept intact, no trailing separator except a drive/UNC root.
# ---------------------------------------------------------------------------
function Format-UxPromptPath {
    param(
        [string]$Path = '',
        [string]$Style = 'full',
        [int]$MaxSegments = 0,
        [int]$MaxLength = 0
    )

    if ($null -eq $Path) { return '' }
    $text = [string]$Path
    if ($text -eq '') { return '' }

    $sep = '/'
    if ($text.IndexOf('\') -ge 0) { $sep = '\' }

    $root = ''
    $rest = $text

    if ($text -match '^[\\/]{2}([^\\/]+)[\\/]([^\\/]+)') {
        # UNC: the server/share pair is the unbreakable root, everything else is segments.
        $root = $sep + $sep + $Matches[1] + $sep + $Matches[2]
        $rest = $text.Substring($Matches[0].Length)
    } elseif ($text -match '^([A-Za-z]):([\\/])') {
        $root = $Matches[1] + ':' + $sep
        $rest = $text.Substring($Matches[0].Length)
    } elseif ($text -match '^([A-Za-z]):$') {
        return ($Matches[1] + ':')
    } elseif ($text.Length -ge 1 -and ($text.Substring(0, 1) -eq '\' -or $text.Substring(0, 1) -eq '/')) {
        $root = $sep
        $rest = $text.Substring(1)
    } elseif ($text.Length -ge 1 -and $text.Substring(0, 1) -eq '~') {
        $root = '~'
        $rest = $text.Substring(1)
    }

    $parts = @()
    if ($rest -ne '') {
        foreach ($piece in @($rest -split '[\\/]')) {
            if ($null -ne $piece -and $piece -ne '') { $parts += [string]$piece }
        }
    }

    $count = $parts.Count
    $keep = $count
    if ($Style -eq 'short') {
        $keep = 1
    } elseif ($Style -match '^last:([0-9]+)$') {
        $keep = [int]$Matches[1]
    }
    if ($keep -gt $count) { $keep = $count }
    if ($keep -lt 1 -and $count -gt 0) { $keep = 1 }
    if ($MaxSegments -gt 0 -and $MaxSegments -lt $keep) { $keep = $MaxSegments }

    $tail = ''
    if ($keep -gt 0) {
        $tailParts = @()
        for ($i = $count - $keep; $i -lt $count; $i++) {
            $tailParts += [string]$parts[$i]
        }
        $tail = $tailParts -join $sep
    }

    $rootText = $root
    if ($rootText -ne '') {
        $lastRoot = $rootText.Substring($rootText.Length - 1, 1)
        if ($lastRoot -ne $sep) { $rootText = $rootText + $sep }
    }

    $display = ''
    if ($count -eq 0) {
        $display = $root
        if ($display -eq '') { $display = $text }
    } elseif ($keep -lt $count) {
        $display = $rootText + '...'
        if ($tail -ne '') { $display = $display + $sep + $tail }
    } else {
        $display = $rootText + $tail
    }

    if ($MaxLength -gt 0 -and $display.Length -gt $MaxLength) {
        $keepChars = $MaxLength - 3
        if ($keepChars -lt 1) { $keepChars = 1 }
        if ($keepChars -lt $display.Length) {
            $tailText = $display.Substring($display.Length - $keepChars)
            # Prefer a segment boundary inside the kept tail so the abbreviated path
            # never starts with half a directory name ("...\f\g" over "...e\f\g").
            $boundary = $tailText.IndexOf($sep)
            if ($boundary -gt 0 -and $boundary -lt ($tailText.Length - 1)) {
                $tailText = $tailText.Substring($boundary)
            }
            $display = '...' + $tailText
        }
    }
    return $display
}

# ---------------------------------------------------------------------------
# Git segment: (branch) + '*' dirty + ' +A-B' ahead/behind + '|STATE', with the
# '(new)' unborn marker appended by the renderer just after the closing bracket.
# The parens are added by the ps/classic/twoline layouts; the blocks layout wraps the
# same text in its own square brackets. Dirty $null means "unknown" and renders nothing.
# ---------------------------------------------------------------------------
function Get-UxPromptGitText {
    param($Git)

    if ($null -eq $Git) { return '' }
    if (-not (ConvertTo-UxPromptBool (Get-UxPromptMapValue $Git 'IsRepo' $false) $false)) { return '' }

    $branch = [string](Get-UxPromptMapValue $Git 'Branch' '')
    $sha = [string](Get-UxPromptMapValue $Git 'ShortSha' '')
    $detached = ConvertTo-UxPromptBool (Get-UxPromptMapValue $Git 'Detached' $false) $false
    if ($branch -eq '') {
        if ($sha -ne '') {
            $branch = $sha
        } elseif ($detached) {
            $branch = 'detached'
        } else {
            return ''
        }
    }

    $text = $branch
    if (ConvertTo-UxPromptBool (Get-UxPromptMapValue $Git 'Dirty' $false) $false) {
        $text = $text + '*'
    }

    $ahead = 0
    $behind = 0
    try { $ahead = [int](Get-UxPromptMapValue $Git 'Ahead' 0) } catch { $ahead = 0 }
    try { $behind = [int](Get-UxPromptMapValue $Git 'Behind' 0) } catch { $behind = 0 }
    if ($ahead -lt 0) { $ahead = 0 }
    if ($behind -lt 0) { $behind = 0 }
    if ($ahead -gt 0 -or $behind -gt 0) {
        $text = $text + ' +' + [string]$ahead + '-' + [string]$behind
    }

    $state = [string](Get-UxPromptMapValue $Git 'State' '')
    if ($state -ne '' -and $state -ne 'new') {
        $text = $text + '|' + $state
    }
    return $text
}

function Test-UxPromptGitUnborn {
    # Unborn branch: no commit yet. lib/10-git.ps1 reports it as State 'new'; the
    # New/Unborn keys are accepted as well so either encoding renders '(new)'.
    param($Git)

    if ($null -eq $Git) { return $false }
    if (-not (ConvertTo-UxPromptBool (Get-UxPromptMapValue $Git 'IsRepo' $false) $false)) { return $false }
    $state = [string](Get-UxPromptMapValue $Git 'State' '')
    if ($state -eq 'new') { return $true }
    if (ConvertTo-UxPromptBool (Get-UxPromptMapValue $Git 'New' $false) $false) { return $true }
    return (ConvertTo-UxPromptBool (Get-UxPromptMapValue $Git 'Unborn' $false) $false)
}

# ---------------------------------------------------------------------------
# Segment factory. Vt is blanked for every mode except Vt, so Mode can never change Text.
# ---------------------------------------------------------------------------
function New-UxPromptSegment {
    param(
        [string]$Text = '',
        [string]$Color = '',
        [string]$Vt = '',
        [string]$Kind = 'text',
        [string]$Mode = 'Plain'
    )

    if ($Mode -ne 'Vt') { $Vt = '' }
    return @{
        Text = [string]$Text
        Color = [string]$Color
        Vt = [string]$Vt
        Kind = [string]$Kind
    }
}

function Get-UxPromptWidth {
    # Longest visible line length across the segments (newlines reset the counter).
    param($Segments)

    $max = 0
    $current = 0
    foreach ($segment in @($Segments)) {
        if ($null -eq $segment) { continue }
        $text = [string](Get-UxPromptMapValue $segment 'Text' '')
        foreach ($ch in $text.ToCharArray()) {
            if ($ch -eq [char]10) {
                if ($current -gt $max) { $max = $current }
                $current = 0
            } else {
                $current = $current + 1
            }
        }
    }
    if ($current -gt $max) { $max = $current }
    return $max
}

# ---------------------------------------------------------------------------
# The single theme renderer.
# ---------------------------------------------------------------------------
function New-UxPromptRender {
    param(
        $Model,
        [string]$Theme = 'ascii',
        [string]$Mode = 'Plain',
        [int]$PathMax = 0,
        [bool]$ShowGit = $true,
        [bool]$ShowUser = $true,
        [bool]$ShowHost = $true,
        [bool]$ShowTime = $true,
        [int]$PathMaxLength = 0
    )

    $def = $script:UxPromptThemes['ascii']
    if ($null -ne $Theme -and $script:UxPromptThemes.ContainsKey($Theme)) {
        $def = $script:UxPromptThemes[$Theme]
    }
    $layout = [string]$def['Layout']
    $vtMap = $def['Vt']
    $colorMap = $def['Colors']
    $gitOpen = [string]$def['GitOpen']
    $gitClose = [string]$def['GitClose']

    $style = [string](Get-UxPromptMapValue $Model 'PathStyle' 'full')
    if ($style -eq '') { $style = 'full' }
    $pathText = Format-UxPromptPath -Path ([string](Get-UxPromptMapValue $Model 'Path' '')) `
        -Style $style -MaxSegments $PathMax -MaxLength $PathMaxLength

    $symbol = [string](Get-UxPromptMapValue $Model 'Symbol' '$')
    if ($symbol -eq '') { $symbol = '$' }

    $identity = ''
    if ($ShowUser) { $identity = [string](Get-UxPromptMapValue $Model 'User' '') }
    if ($ShowHost) {
        $hostName = [string](Get-UxPromptMapValue $Model 'Host' '')
        if ($hostName -ne '') {
            if ($identity -ne '') { $identity = $identity + '@' + $hostName } else { $identity = $hostName }
        }
    }

    $timeText = ''
    if ($ShowTime) { $timeText = [string](Get-UxPromptMapValue $Model 'Time' '') }

    $gitText = ''
    $gitNote = ''
    if ($ShowGit) {
        $gitModel = Get-UxPromptMapValue $Model 'Git' $null
        $gitText = Get-UxPromptGitText -Git $gitModel
        if ($gitText -ne '' -and (Test-UxPromptGitUnborn -Git $gitModel)) { $gitNote = '(new)' }
    }

    $exitText = ''
    if ((ConvertTo-UxPromptBool (Get-UxPromptMapValue $Model 'ShowExit' $true) $true)) {
        $lastExit = 0
        $lastOk = $true
        try { $lastExit = [int](Get-UxPromptMapValue $Model 'LastExit' 0) } catch { $lastExit = 0 }
        try { $lastOk = ConvertTo-UxPromptBool (Get-UxPromptMapValue $Model 'LastOk' $true) $true } catch { $lastOk = $true }
        # A cmdlet that failed leaves LASTEXITCODE untouched (often 0) and only clears $?,
        # so the marker has to consider both. Without the LastOk half, `Get-Item /nope`
        # followed by a clean native command would show no marker at all.
        if (($lastExit -ne 0) -or (-not $lastOk)) { $exitText = '!' }
    }

    $segments = @()

    if ($layout -eq 'ps') {
        $segments += New-UxPromptSegment -Text ([string]$def['Prefix']) -Color ([string]$colorMap['prefix']) -Vt ([string]$vtMap['prefix']) -Kind 'prefix' -Mode $Mode
        if ($timeText -ne '') {
            $segments += New-UxPromptSegment -Text (' ' + $timeText) -Color ([string]$colorMap['time']) -Vt ([string]$vtMap['time']) -Kind 'time' -Mode $Mode
        }
        $segments += New-UxPromptSegment -Text (' ' + $pathText) -Color ([string]$colorMap['path']) -Vt ([string]$vtMap['path']) -Kind 'path' -Mode $Mode
        if ($gitText -ne '') {
            $segments += New-UxPromptSegment -Text (' ' + $gitOpen + $gitText + $gitClose + $gitNote) -Color ([string]$colorMap['git']) -Vt ([string]$vtMap['git']) -Kind 'git' -Mode $Mode
        }
        if ($exitText -ne '') {
            $segments += New-UxPromptSegment -Text (' ' + $exitText) -Color ([string]$colorMap['exit']) -Vt ([string]$vtMap['exit']) -Kind 'exit' -Mode $Mode
        }
        $segments += New-UxPromptSegment -Text (' ' + $symbol + ' ') -Color ([string]$colorMap['symbol']) -Vt ([string]$vtMap['symbol']) -Kind 'symbol' -Mode $Mode
    } elseif ($layout -eq 'classic') {
        if ($timeText -ne '') {
            $segments += New-UxPromptSegment -Text ($timeText + ' ') -Color ([string]$colorMap['time']) -Vt ([string]$vtMap['time']) -Kind 'time' -Mode $Mode
        }
        if ($identity -ne '') {
            $segments += New-UxPromptSegment -Text ($identity + ':') -Color ([string]$colorMap['identity']) -Vt ([string]$vtMap['identity']) -Kind 'identity' -Mode $Mode
        }
        $segments += New-UxPromptSegment -Text $pathText -Color ([string]$colorMap['path']) -Vt ([string]$vtMap['path']) -Kind 'path' -Mode $Mode
        if ($gitText -ne '') {
            $segments += New-UxPromptSegment -Text (' ' + $gitOpen + $gitText + $gitClose + $gitNote) -Color ([string]$colorMap['git']) -Vt ([string]$vtMap['git']) -Kind 'git' -Mode $Mode
        }
        if ($exitText -ne '') {
            $segments += New-UxPromptSegment -Text (' ' + $exitText) -Color ([string]$colorMap['exit']) -Vt ([string]$vtMap['exit']) -Kind 'exit' -Mode $Mode
        }
        $segments += New-UxPromptSegment -Text ($symbol + ' ') -Color ([string]$colorMap['symbol']) -Vt ([string]$vtMap['symbol']) -Kind 'symbol' -Mode $Mode
    } elseif ($layout -eq 'blocks') {
        $parts = @()
        if ($identity -ne '') {
            $parts += New-UxPromptSegment -Text ('[' + $identity + ']') -Color ([string]$colorMap['identity']) -Vt ([string]$vtMap['identity']) -Kind 'identity' -Mode $Mode
        }
        if ($timeText -ne '') {
            $parts += New-UxPromptSegment -Text ('[' + $timeText + ']') -Color ([string]$colorMap['time']) -Vt ([string]$vtMap['time']) -Kind 'time' -Mode $Mode
        }
        $parts += New-UxPromptSegment -Text ('[' + $pathText + ']') -Color ([string]$colorMap['path']) -Vt ([string]$vtMap['path']) -Kind 'path' -Mode $Mode
        if ($gitText -ne '') {
            $parts += New-UxPromptSegment -Text ('[' + $gitText + ']' + $gitNote) -Color ([string]$colorMap['git']) -Vt ([string]$vtMap['git']) -Kind 'git' -Mode $Mode
        }
        if ($exitText -ne '') {
            $parts += New-UxPromptSegment -Text ('[' + $exitText + ']') -Color ([string]$colorMap['exit']) -Vt ([string]$vtMap['exit']) -Kind 'exit' -Mode $Mode
        }

        $joinText = [string]$def['SegmentJoin']
        for ($i = 0; $i -lt $parts.Count; $i++) {
            if ($i -gt 0) {
                $segments += New-UxPromptSegment -Text $joinText -Kind 'separator' -Mode $Mode
            }
            $segments += $parts[$i]
        }
        $segments += New-UxPromptSegment -Text $joinText -Kind 'separator' -Mode $Mode
        $segments += New-UxPromptSegment -Text ($symbol + ' ') -Color ([string]$colorMap['symbol']) -Vt ([string]$vtMap['symbol']) -Kind 'symbol' -Mode $Mode
    } else {
        if ($timeText -ne '') {
            $segments += New-UxPromptSegment -Text ($timeText + ' ') -Color ([string]$colorMap['time']) -Vt ([string]$vtMap['time']) -Kind 'time' -Mode $Mode
        }
        $segments += New-UxPromptSegment -Text $pathText -Color ([string]$colorMap['path']) -Vt ([string]$vtMap['path']) -Kind 'path' -Mode $Mode
        if ($gitText -ne '') {
            $segments += New-UxPromptSegment -Text (' ' + $gitOpen + $gitText + $gitClose + $gitNote) -Color ([string]$colorMap['git']) -Vt ([string]$vtMap['git']) -Kind 'git' -Mode $Mode
        }
        $segments += New-UxPromptSegment -Text "`n" -Kind 'newline' -Mode $Mode
        if ($exitText -ne '') {
            $segments += New-UxPromptSegment -Text ($exitText + ' ') -Color ([string]$colorMap['exit']) -Vt ([string]$vtMap['exit']) -Kind 'exit' -Mode $Mode
        }
        $segments += New-UxPromptSegment -Text ($symbol + ' ') -Color ([string]$colorMap['symbol']) -Vt ([string]$vtMap['symbol']) -Kind 'symbol' -Mode $Mode
    }

    return $segments
}

# ---------------------------------------------------------------------------
# PUBLIC: Format-UxPrompt - PURE. No host output, no global mutation.
# ---------------------------------------------------------------------------
function Format-UxPrompt {
    param(
        $Model,
        [string]$Theme = 'ascii',
        [string]$Mode = 'Plain',
        [int]$Width = 0
    )

    if ($null -eq $Model) { $Model = @{} }

    $themeName = [string]$Theme
    if ($themeName -eq '' -or -not $script:UxPromptThemes.ContainsKey($themeName)) {
        $themeName = 'ascii'
    }

    $modeName = 'Plain'
    if ($Mode -eq 'Vt') {
        $modeName = 'Vt'
    } elseif ($Mode -eq 'Console') {
        $modeName = 'Console'
    }

    $effectiveWidth = $Width
    if ($effectiveWidth -le 0) {
        $modelWidth = 0
        try { $modelWidth = [int](Get-UxPromptMapValue $Model 'Width' 0) } catch { $modelWidth = 0 }
        if ($modelWidth -gt 0) { $effectiveWidth = $modelWidth } else { $effectiveWidth = 120 }
    }

    $showGit = ConvertTo-UxPromptBool (Get-UxPromptMapValue $Model 'ShowGit' $true) $true
    $showUser = ConvertTo-UxPromptBool (Get-UxPromptMapValue $Model 'ShowUser' $true) $true
    $showHost = ConvertTo-UxPromptBool (Get-UxPromptMapValue $Model 'ShowHost' $true) $true
    # No explicit ShowTime flag: a model that carries a Time value means "show it" (the
    # session model blanks Time when prompt.time is false and sets the flag explicitly).
    $showTimeValue = Get-UxPromptMapValue $Model 'ShowTime' $null
    $showTime = $false
    if ($null -ne $showTimeValue) {
        $showTime = ConvertTo-UxPromptBool $showTimeValue $false
    } elseif ([string](Get-UxPromptMapValue $Model 'Time' '') -ne '') {
        $showTime = $true
    }

    # Width fitting order: keep the path tail first, then drop git, user and host.
    # MaxSegments only ever shortens, so a 'short'/'last:N' style is never lengthened.
    $candidates = @(
        @{ PathMax = 0; Git = $showGit; User = $showUser; Host = $showHost; Time = $showTime },
        @{ PathMax = 3; Git = $showGit; User = $showUser; Host = $showHost; Time = $showTime },
        @{ PathMax = 2; Git = $showGit; User = $showUser; Host = $showHost; Time = $showTime },
        @{ PathMax = 1; Git = $showGit; User = $showUser; Host = $showHost; Time = $showTime },
        @{ PathMax = 1; Git = $false; User = $showUser; Host = $showHost; Time = $showTime },
        @{ PathMax = 1; Git = $false; User = $false; Host = $showHost; Time = $showTime },
        @{ PathMax = 1; Git = $false; User = $false; Host = $false; Time = $showTime },
        @{ PathMax = 1; Git = $false; User = $false; Host = $false; Time = $false }
    )

    $chosen = $null
    $chosenWidth = 0
    foreach ($candidate in $candidates) {
        $attempt = New-UxPromptRender -Model $Model -Theme $themeName -Mode $modeName `
            -PathMax ([int]$candidate['PathMax']) -ShowGit ([bool]$candidate['Git']) `
            -ShowUser ([bool]$candidate['User']) -ShowHost ([bool]$candidate['Host']) `
            -ShowTime ([bool]$candidate['Time'])
        $attemptWidth = Get-UxPromptWidth -Segments $attempt
        $chosen = $attempt
        $chosenWidth = $attemptWidth
        if ($attemptWidth -le $effectiveWidth) { break }
    }

    if ($chosenWidth -gt $effectiveWidth -and $null -ne $chosen) {
        $pathLength = 0
        foreach ($segment in $chosen) {
            if ([string](Get-UxPromptMapValue $segment 'Kind' '') -eq 'path') {
                $pathLength = ([string](Get-UxPromptMapValue $segment 'Text' '')).Length
            }
        }
        if ($pathLength -gt 4) {
            $newMax = $pathLength - ($chosenWidth - $effectiveWidth)
            if ($newMax -lt 4) { $newMax = 4 }
            $chosen = New-UxPromptRender -Model $Model -Theme $themeName -Mode $modeName `
                -PathMax 1 -ShowGit $false -ShowUser $false -ShowHost $false -ShowTime $false `
                -PathMaxLength $newMax
        }
    }

    $result = @()
    foreach ($segment in @($chosen)) {
        if ($null -eq $segment) { continue }
        $result += @{
            Text  = [string](Get-UxPromptMapValue $segment 'Text' '')
            Color = [string](Get-UxPromptMapValue $segment 'Color' '')
            Vt    = [string](Get-UxPromptMapValue $segment 'Vt' '')
        }
    }
    return $result
}

# ---------------------------------------------------------------------------
# PUBLIC: Write-UxPromptSegments - the only function that touches the host.
# Never writes to the success stream (Write-Host only), so command output is safe.
# ---------------------------------------------------------------------------
function Write-UxPromptSegments {
    param(
        [array]$Segments,
        [string]$Mode = 'Plain'
    )

    $modeName = 'Plain'
    if ($Mode -eq 'Vt') {
        $modeName = 'Vt'
    } elseif ($Mode -eq 'Console') {
        $modeName = 'Console'
    }

    if ($modeName -eq 'Vt') {
        $esc = [string][char]27
        try {
            $stateVar = Get-Variable -Name 'Ux' -Scope Global -ErrorAction SilentlyContinue
            if ($null -ne $stateVar -and $stateVar.Value -is [hashtable] -and $stateVar.Value.ContainsKey('Esc')) {
                $configuredEsc = [string]$stateVar.Value['Esc']
                if ($configuredEsc -ne '') { $esc = $configuredEsc }
            }
        } catch { }

        $chunks = @()
        foreach ($segment in @($Segments)) {
            if ($null -eq $segment) { continue }
            $text = [string](Get-UxPromptMapValue $segment 'Text' '')
            if ($text -eq '') { continue }
            $vt = [string](Get-UxPromptMapValue $segment 'Vt' '')
            if ($vt -eq '') {
                $chunks += $text
            } else {
                $chunks += ($esc + '[' + $vt + 'm' + $text + $esc + '[0m')
            }
        }
        $line = $chunks -join ''
        if ($line -ne '') { Write-Host -NoNewline $line }
        return
    }

    if ($modeName -eq 'Console') {
        foreach ($segment in @($Segments)) {
            if ($null -eq $segment) { continue }
            $text = [string](Get-UxPromptMapValue $segment 'Text' '')
            if ($text -eq '') { continue }
            $color = [string](Get-UxPromptMapValue $segment 'Color' '')
            if ($color -ne '' -and $script:UxPromptColorNames -contains $color) {
                Write-Host -NoNewline -ForegroundColor $color $text
            } else {
                Write-Host -NoNewline $text
            }
        }
        return
    }

    $chunks = @()
    foreach ($segment in @($Segments)) {
        if ($null -eq $segment) { continue }
        $text = [string](Get-UxPromptMapValue $segment 'Text' '')
        if ($text -ne '') { $chunks += $text }
    }
    $line = $chunks -join ''
    if ($line -ne '') { Write-Host -NoNewline $line }
}

# ---------------------------------------------------------------------------
# Config access (guarded: Get-UxConfig is owned by 00-core.ps1 and may be absent
# when this file is smoke-tested standalone).
# ---------------------------------------------------------------------------
function Get-UxPromptConfigValue {
    param(
        [string]$Path = '',
        $Default = $null
    )

    try {
        if ($null -ne (Get-Command -Name 'Get-UxConfig' -CommandType Function -ErrorAction SilentlyContinue)) {
            $value = Get-UxConfig -Path $Path -Default $Default
            if ($null -ne $value) { return $value }
        }
    } catch { }
    return $Default
}

# ---------------------------------------------------------------------------
# PUBLIC: Get-UxPromptModel - session state + config + git -> model.
# ---------------------------------------------------------------------------
function Get-UxPromptModel {
    param(
        [string]$Path = '',
        [int]$Width = 0
    )

    $stateVar = $null
    try { $stateVar = Get-Variable -Name 'Ux' -Scope Global -ErrorAction SilentlyContinue } catch { $stateVar = $null }
    $uxState = $null
    if ($null -ne $stateVar -and $stateVar.Value -is [hashtable]) { $uxState = $stateVar.Value }

    $user = ''
    try { $user = [string]$env:USERNAME } catch { $user = '' }
    if ($user -eq '') { try { $user = [string]$env:USER } catch { $user = '' } }

    $hostName = ''
    try { $hostName = [string]$env:COMPUTERNAME } catch { $hostName = '' }
    if ($hostName -eq '') { try { $hostName = [string]$env:HOSTNAME } catch { $hostName = '' } }

    $locationUsed = ($Path -eq '')
    $rawPath = [string]$Path
    if ($rawPath -eq '') {
        try { $rawPath = [string](Get-Location).Path } catch { $rawPath = '' }
        if ($rawPath -eq '') { try { $rawPath = [string]$PWD } catch { $rawPath = '' } }
    }

    $homeDir = ''
    if ($null -ne $uxState) {
        try { if ($uxState.ContainsKey('Home')) { $homeDir = [string]$uxState['Home'] } } catch { $homeDir = '' }
    }
    if ($homeDir -eq '') { try { $homeDir = [string]$HOME } catch { $homeDir = '' } }
    if ($homeDir -eq '') { try { $homeDir = [string]$env:USERPROFILE } catch { $homeDir = '' } }

    $showUser = ConvertTo-UxPromptBool (Get-UxPromptConfigValue 'prompt.user' $true) $true
    $showHost = ConvertTo-UxPromptBool (Get-UxPromptConfigValue 'prompt.host' $false) $false
    $showTime = ConvertTo-UxPromptBool (Get-UxPromptConfigValue 'prompt.time' $false) $false
    $showGit = ConvertTo-UxPromptBool (Get-UxPromptConfigValue 'prompt.git' $true) $true
    $showExit = ConvertTo-UxPromptBool (Get-UxPromptConfigValue 'prompt.exitCode' $true) $true
    $style = [string](Get-UxPromptConfigValue 'prompt.pathStyle' 'full')
    if ($style -eq '') { $style = 'full' }
    $theme = [string](Get-UxPromptConfigValue 'theme' 'ascii')
    if ($theme -eq '') { $theme = 'ascii' }

    try {
        $envTheme = [string]$env:UX_THEME
        if ($envTheme -ne '') { $theme = $envTheme }
    } catch { }

    $time = ''
    if ($showTime) {
        try { $time = (Get-Date).ToString('HH:mm') } catch { $time = '' }
    }

    $symbol = [string](Get-UxPromptConfigValue 'prompt.symbol' '$')
    if ($symbol -eq '') { $symbol = '$' }

    $lastExit = 0
    $lastOk = $true
    if ($null -ne $uxState) {
        try { if ($uxState.ContainsKey('LastExit')) { $lastExit = [int]$uxState['LastExit'] } } catch { $lastExit = 0 }
        try { if ($uxState.ContainsKey('LastOk')) { $lastOk = ConvertTo-UxPromptBool $uxState['LastOk'] $true } } catch { $lastOk = $true }
    }

    if ($locationUsed -and $rawPath -ne '') {
        # Non-FileSystem providers (Registry::, Cert:) never get a repo walk or a drive path.
        try {
            $providerName = [string](Get-Location).Provider.Name
            if ($providerName -ne '' -and $providerName -ne 'FileSystem') { $showGit = $false }
        } catch { }
    }

    $git = $null
    if ($showGit) {
        try {
            if ($null -ne (Get-Command -Name 'Get-UxGitModel' -CommandType Function -ErrorAction SilentlyContinue)) {
                $git = Get-UxGitModel -Path $rawPath
            }
        } catch { $git = $null }
    }

    $modelWidth = $Width
    if ($modelWidth -le 0) {
        try {
            $size = $Host.UI.RawUI.WindowSize
            if ($null -ne $size) { $modelWidth = [int]$size.Width }
        } catch { $modelWidth = 0 }
    }
    if ($modelWidth -le 0) { $modelWidth = 120 }

    return @{
        User      = $user
        Host      = $hostName
        Path      = (ConvertTo-UxPromptHomePath -Path $rawPath -HomeDir $homeDir)
        Git       = $git
        Time      = $time
        LastExit  = $lastExit
        LastOk    = $lastOk
        Symbol    = $symbol
        Width     = $modelWidth
        PathStyle = $style
        ShowUser  = $showUser
        ShowHost  = $showHost
        ShowTime  = $showTime
        ShowGit   = $showGit
        ShowExit  = $showExit
        Theme     = $theme
    }
}

# ---------------------------------------------------------------------------
# PUBLIC: prompt - thin wrapper. The first statements capture the previous command's
# status, because the prompt's own work (including a git call) overwrites both
# $LASTEXITCODE and $? (verified failure mode). Everything else is exception-proof.
# ---------------------------------------------------------------------------
function global:prompt {
    $script:LastOk = $?
    try {
        $script:LastExit = $LASTEXITCODE
        if ($null -eq $script:LastExit) { $script:LastExit = 0 }
    } catch {
        $script:LastExit = 0
    }

    try {
        $stateVar = Get-Variable -Name 'Ux' -Scope Global -ErrorAction SilentlyContinue
        if ($null -ne $stateVar -and $stateVar.Value -is [hashtable]) {
            $stateVar.Value['LastExit'] = $script:LastExit
            $stateVar.Value['LastOk'] = $script:LastOk
        }
    } catch { }

    try {
        $mode = 'Plain'
        $vt = $false
        $color = $false
        try {
            $stateVar = Get-Variable -Name 'Ux' -Scope Global -ErrorAction SilentlyContinue
            if ($null -ne $stateVar -and $stateVar.Value -is [hashtable]) {
                if ($stateVar.Value.ContainsKey('Caps')) {
                    $caps = $stateVar.Value['Caps']
                    if ($caps -is [hashtable]) {
                        if ($caps.ContainsKey('Vt')) { $vt = ConvertTo-UxPromptBool $caps['Vt'] $false }
                        if ($caps.ContainsKey('Color')) { $color = ConvertTo-UxPromptBool $caps['Color'] $false }
                    }
                }
            }
        } catch {
            $vt = $false
            $color = $false
        }
        if ($vt -and $color) {
            $mode = 'Vt'
        } elseif ($color) {
            $mode = 'Console'
        }
        try {
            if ($env:UX_NO_COLOR -eq '1') { $mode = 'Plain' }
        } catch { }

        $model = Get-UxPromptModel
        $theme = 'ascii'
        if ($null -ne $model) {
            try { $theme = [string]$model['Theme'] } catch { $theme = 'ascii' }
        }
        if ($theme -eq '') { $theme = 'ascii' }

        $segments = Format-UxPrompt -Model $model -Theme $theme -Mode $mode -Width $model.Width
        Write-UxPromptSegments -Segments $segments -Mode $mode
    } catch {
        try { Write-Host 'PS> ' -NoNewline } catch { }
    }

    try { $global:LASTEXITCODE = $script:LastExit } catch { }
    return ' '
}
