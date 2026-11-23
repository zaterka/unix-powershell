#Requires -Version 5.1
#
# unix-powershell - lib/30-unix.ps1
# The 19 Unix-style command wrappers: ls ll la cd touch mkdir rm mv grep find
# head tail wc which env export unset kill unzip.
#
# Trimmed on purpose (see PLAN.md "Amendment"): ps, cat and cp are NOT wrapped, because a
# stock PowerShell prompt already does what you would type - "ps name" is the Get-Process
# alias with a name filter, "cat f1 f2" is Get-Content, and "cp -r" binds to -Recurse.
# A wrapper is kept only where the native command rejects the Unix spelling (ls -la,
# rm -rf, mv -f, kill -9), lacks it on 5.1 (cd -), or actively does the wrong thing
# (mkdir -p creates a stray directory literally named "-p").
#
# Target: Windows PowerShell 5.1 (7+ compatible). Pure ASCII. Strict-mode-proof.
# No .NET static calls, no reflection, no Invoke-Expression, no Add-Type, no network.
#
# DESIGN RULE (PLAN.md 5.1) - every wrapper is a PLAIN, non-advanced function:
#   * no [CmdletBinding()], no [Parameter()], no ValueFromPipeline, no process {} block
#   * a param() block declares only [switch] names that are safe to bind; everything else
#     - including clustered flags such as -rf, -la and -9 - arrives verbatim in $args
#   * [switch] parameters never consume a positional operand, so a file path can never be
#     mistaken for a parameter value (declaring [int]$Count would break "head file.txt")
#   * ConvertFrom-UxArgv (lib/05-args.ps1) expands clusters, honours --, and provides values
#   * pipeline input is read with $input, because a plain function has no process {} block
#
# Output stays object-based wherever a native cmdlet is the mapping (ls); only the text
# tools (grep, wc, which, env, head, tail) emit strings, because that is their Unix contract.
#
# Alias shadowing is NOT done here. lib/00-core.ps1 removes the shadowing aliases before this
# file is dot-sourced; aliases resolve before functions, so that ordering is mandatory.
#
# Documented divergences from GNU behaviour appear in each function's help and in README.md.
#
# Two cross-cutting divergences worth knowing before reading the wrappers:
#   * Paths are always passed with -LiteralPath (so [brackets] work). PowerShell does not
#     expand shell globs, so "ls *.txt" is treated as a literal name and reports "No such
#     file"; expand the pattern yourself or use Get-ChildItem -Path.
#   * grep and find set $global:LASTEXITCODE to 0/1/2. Every other wrapper except env also
#     sets it to 0/1 (Unix-style), which means a successful wrapper resets an earlier native
#     exit code.

# Previous working directory for "cd -". $script: scope so the value survives between calls.
$script:UxOldPwd = $null

function ls {
    <#
    .SYNOPSIS
        List directory contents with Unix-style flags (maps to Get-ChildItem).
    .DESCRIPTION
        -a includes hidden items (Get-ChildItem -Force), -R recurses, -1 emits names only,
        -d emits the item itself instead of its children, and -l is an accepted no-op:
        PowerShell's default table output already is a long listing.

        Items are returned as objects, never as formatted text, so
        "ls -l | Select-Object -First 3" and "ls -l | Where-Object Length -gt 1mb" work.
        Divergence: GNU ls prints columns; this returns FileInfo/DirectoryInfo objects.
        Several paths are concatenated without GNU's directory headings, and -1 with -R
        prints bare names without headings either. PowerShell does not expand shell globs,
        so "ls *.txt" is a literal filename here; use Get-ChildItem -Path for wildcards.
    .EXAMPLE
        ls -la
    .EXAMPLE
        ls -1 -R
    #>
    param(
        [switch]$All,
        [switch]$Recurse
    )

    $argv = ConvertFrom-UxArgv -Tokens $args -ValueFlags @() -AliasMap @{
        All       = 'a'
        Recursive = 'r'
        Recurse   = 'r'
    }
    $flags = @{}
    foreach ($key in $argv.Flags.Keys) { $flags[[string]$key] = $true }
    if ($All) { $flags['a'] = $true }
    if ($Recurse) { $flags['r'] = $true }

    $showHidden = $flags.ContainsKey('a')
    $doRecurse = $flags.ContainsKey('r')
    $namesOnly = $flags.ContainsKey('1')
    $selfOnly = $flags.ContainsKey('d')

    $paths = @($argv.Positional)
    if ($paths.Count -eq 0) { $paths = @('.') }

    $failed = $false
    foreach ($pathValue in $paths) {
        $path = [string]$pathValue
        if ($env:OS -ne 'Windows_NT' -and $path -match '^/{2,}') {
            $path = '/' + ($path -replace '^/+', '')
        }

        if ($selfOnly) {
            $item = $null
            try { $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop } catch { $item = $null }
            if ($null -eq $item) {
                Write-Error -Message ("ls: cannot access '{0}': No such file or directory" -f $path) -ErrorAction Continue
                $failed = $true
                continue
            }
            if ($namesOnly) { [string]$item.Name } else { $item }
            continue
        }

        $getChildItem = @{ LiteralPath = $path; ErrorAction = 'Stop' }
        if ($showHidden) { $getChildItem['Force'] = $true }
        if ($doRecurse) { $getChildItem['Recurse'] = $true }

        $items = @()
        try {
            $items = @(Get-ChildItem @getChildItem)
        } catch {
            Write-Error -Message ("ls: cannot access '{0}': {1}" -f $path, $_.Exception.Message) -ErrorAction Continue
            $failed = $true
            continue
        }

        if ($namesOnly) {
            foreach ($entry in $items) { [string]$entry.Name }
        } else {
            $items
        }
    }

    if ($failed) { $global:LASTEXITCODE = 1 } else { $global:LASTEXITCODE = 0 }
}

function ll {
    <#
    .SYNOPSIS
        Long listing: forwards every argument to "ls -l".
    .DESCRIPTION
        Forwarded tokens land in $args of ls and are tokenized there, so "ll -a" and
        "ll -R /tmp" keep working. Output is objects, exactly like ls.
    .EXAMPLE
        ll /tmp
    #>
    ls -l @args
}

function la {
    <#
    .SYNOPSIS
        Long listing including hidden items: forwards every argument to "ls -la".
    .DESCRIPTION
        Same object output as ls; see the divergence documented on ls.
    .EXAMPLE
        la
    #>
    ls -la @args
}

function cd {
    <#
    .SYNOPSIS
        Change location (Set-Location) with "cd -", "~" and Unix-style errors.
    .DESCRIPTION
        A bare "cd" goes to $HOME (then $env:USERPROFILE), "~" and ".." are honoured,
        and "cd -" returns to the previous location recorded by this module. A bad target
        writes a Unix-style error and sets $LASTEXITCODE = 1 instead of silently staying put.

        Divergence: a directory whose name starts with "-" cannot be entered without a
        quoted "./-name" path; PowerShell consumes the leading "--" separator before the
        wrapper sees it.
    .EXAMPLE
        cd /tmp
        cd -
    #>
    $argv = ConvertFrom-UxArgv -Tokens $args -ValueFlags @() -AliasMap @{}

    $previous = $null
    if ($null -ne $script:UxOldPwd) { $previous = [string]$script:UxOldPwd }

    $target = $null
    $usePrevious = $false
    $operands = @()
    foreach ($value in @($argv.Positional)) {
        $text = [string]$value
        if ($text -eq '-') {
            $usePrevious = $true
            continue
        }
        $operands += $text
    }

    if ($operands.Count -gt 1 -or ($usePrevious -and $operands.Count -gt 0)) {
        Write-Error -Message ('cd: too many arguments') -ErrorAction Continue
        $global:LASTEXITCODE = 1
        return
    }
    if ($operands.Count -eq 1) { $target = $operands[0] }

    $printNew = $false
    if ($usePrevious) {
        if ($null -eq $previous -or $previous -eq '') {
            Write-Error -Message 'cd: OLDPWD not set' -ErrorAction Continue
            $global:LASTEXITCODE = 1
            return
        }
        $target = $previous
        $printNew = $true
    }

    if ($null -ne $target -and $env:OS -ne 'Windows_NT' -and $target -match '^/{2,}') {
        $target = '/' + ($target -replace '^/+', '')
    }

    if ($null -eq $target -or $target -eq '') {
        $homeDirectory = ''
        try { if ($HOME) { $homeDirectory = [string]$HOME } } catch { $homeDirectory = '' }
        if ($homeDirectory -eq '') { $homeDirectory = [string]$env:USERPROFILE }
        $target = $homeDirectory
    }

    if ($null -eq $target -or $target -eq '') {
        Write-Error -Message 'cd: cannot determine the home directory' -ErrorAction Continue
        $global:LASTEXITCODE = 1
        return
    }

    $current = ''
    try { $current = [string](Get-Location).Path } catch { $current = '' }

    try {
        Set-Location -LiteralPath $target -ErrorAction Stop
        if ($current -ne '') { $script:UxOldPwd = $current }
        if ($printNew) { [string](Get-Location).Path }
        $global:LASTEXITCODE = 0
    } catch {
        Write-Error -Message ("cd: {0}: {1}" -f $target, $_.Exception.Message) -ErrorAction Continue
        $global:LASTEXITCODE = 1
    }
}

function touch {
    <#
    .SYNOPSIS
        Create empty files or update timestamps (New-Item / LastWriteTime).
    .DESCRIPTION
        An existing file or directory gets its LastWriteTime set to now; a missing path is
        created as an empty file. Missing parent directories are never created.

        Divergence: -a and -m are not implemented; touch always updates the write time.
    .EXAMPLE
        touch /tmp/new.txt
    #>
    $argv = ConvertFrom-UxArgv -Tokens $args -ValueFlags @() -AliasMap @{}

    $paths = @($argv.Positional)
    if ($paths.Count -eq 0) {
        Write-Error -Message 'touch: missing file operand' -ErrorAction Continue
        $global:LASTEXITCODE = 1
        return
    }

    $failed = $false
    foreach ($pathValue in $paths) {
        $path = [string]$pathValue
        if ($path -match '^[\\/]+$') {
            Write-Error -Message ("touch: cannot touch '{0}': Is a directory" -f $path) -ErrorAction Continue
            $failed = $true
            continue
        }
        if ($env:OS -ne 'Windows_NT' -and $path -match '^/{2,}') {
            $path = '/' + ($path -replace '^/+', '')
        }
        $item = $null
        try { $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop } catch { $item = $null }

        if ($null -ne $item) {
            try {
                $item.LastWriteTime = Get-Date
            } catch {
                Write-Error -Message ("touch: cannot touch '{0}': {1}" -f $path, $_.Exception.Message) -ErrorAction Continue
                $failed = $true
            }
            continue
        }

        try {
            New-Item -ItemType File -Path $path -ErrorAction Stop | Out-Null
        } catch {
            Write-Error -Message ("touch: cannot touch '{0}': {1}" -f $path, $_.Exception.Message) -ErrorAction Continue
            $failed = $true
        }
    }

    if ($failed) { $global:LASTEXITCODE = 1 } else { $global:LASTEXITCODE = 0 }
}

function mkdir {
    <#
    .SYNOPSIS
        Create directories (New-Item -ItemType Directory), with -p for parents.
    .DESCRIPTION
        -p creates missing parents and is silent when the directory already exists. Without
        -p, an existing directory is an error, exactly like Unix mkdir. An existing file at
        the target path is an error in both cases.
    .EXAMPLE
        mkdir -p /tmp/a/b/c
    #>
    param(
        [switch]$Parents
    )

    $argv = ConvertFrom-UxArgv -Tokens $args -ValueFlags @() -AliasMap @{
        Parents = 'p'
        Parent  = 'p'
    }
    $flags = @{}
    foreach ($key in $argv.Flags.Keys) { $flags[[string]$key] = $true }
    if ($Parents) { $flags['p'] = $true }
    $makeParents = $flags.ContainsKey('p')

    $paths = @($argv.Positional)
    if ($paths.Count -eq 0) {
        Write-Error -Message 'mkdir: missing operand' -ErrorAction Continue
        $global:LASTEXITCODE = 1
        return
    }

    $failed = $false
    foreach ($pathValue in $paths) {
        $path = [string]$pathValue
        if (Test-Path -LiteralPath $path) {
            if ((Test-Path -LiteralPath $path -PathType Container) -and $makeParents) { continue }
            Write-Error -Message ("mkdir: cannot create directory '{0}': File exists" -f $path) -ErrorAction Continue
            $failed = $true
            continue
        }

        if (-not $makeParents) {
            # Compute the parent lexically: Split-Path -LiteralPath has no -Parent
            # parameter set, and -Path would treat [brackets] as wildcards.
            $trimmedPath = $path.TrimEnd('\', '/')
            $separatorIndex = $trimmedPath.LastIndexOf([char]'\')
            $slashIndex = $trimmedPath.LastIndexOf([char]'/')
            if ($slashIndex -gt $separatorIndex) { $separatorIndex = $slashIndex }
            $parent = ''
            if ($separatorIndex -gt 0) {
                $parent = $trimmedPath.Substring(0, $separatorIndex)
                if ($parent -match '^[A-Za-z]:$') { $parent = $parent + [char]'\' }
            }
            if ($parent -ne '' -and -not (Test-Path -LiteralPath $parent -PathType Container)) {
                Write-Error -Message ("mkdir: cannot create directory '{0}': No such file or directory" -f $path) -ErrorAction Continue
                $failed = $true
                continue
            }
        }

        $newItem = @{ ItemType = 'Directory'; Path = $path; ErrorAction = 'Stop' }
        if ($makeParents) { $newItem['Force'] = $true }
        try {
            New-Item @newItem | Out-Null
        } catch {
            Write-Error -Message ("mkdir: cannot create directory '{0}': {1}" -f $path, $_.Exception.Message) -ErrorAction Continue
            $failed = $true
        }
    }

    if ($failed) { $global:LASTEXITCODE = 1 } else { $global:LASTEXITCODE = 0 }
}

function rm {
    <#
    .SYNOPSIS
        Remove files and, with -r, directory trees (Remove-Item), Unix-style.
    .DESCRIPTION
        Always non-interactive: Remove-Item runs with -Confirm:$false and -Force. A directory
        without -r is refused with "Is a directory" instead of letting Remove-Item prompt
        (a bare Remove-Item on a non-empty directory prompts, and in a non-interactive
        session aborts with "Object reference not set...", which -ErrorAction SilentlyContinue
        does not suppress).

        Safety refusals: the drive roots, UNC share roots and $HOME that can be resolved are
        refused. On Windows PowerShell 5.1 a recursive delete is refused when the target or
        any descendant carries the ReparsePoint attribute, because Remove-Item -Recurse would
        follow a junction/symlink on 5.1 and can destroy the link target.

        -f suppresses "No such file or directory" and read-only prompts; -r is required for
        directories. Divergence: -d (remove empty directories) is not implemented, and
        Remove-Item aborts a tree at the first locked item instead of continuing like GNU
        rm -rf (other operands are still attempted).
    .EXAMPLE
        rm -rf /tmp/build
    #>
    param(
        [switch]$Recurse,
        [switch]$Force
    )

    $argv = ConvertFrom-UxArgv -Tokens $args -ValueFlags @() -AliasMap @{
        Recursive = 'r'
        Recurse   = 'r'
        Force     = 'f'
    }
    $flags = @{}
    foreach ($key in $argv.Flags.Keys) { $flags[[string]$key] = $true }
    if ($Recurse) { $flags['r'] = $true }
    if ($Force) { $flags['f'] = $true }

    $recursive = $flags.ContainsKey('r')
    $forceFlag = $flags.ContainsKey('f')

    $paths = @($argv.Positional)
    if ($paths.Count -eq 0) {
        Write-Error -Message 'rm: missing operand' -ErrorAction Continue
        $global:LASTEXITCODE = 1
        return
    }

    $homeDirectory = ''
    try { if ($HOME) { $homeDirectory = [string]$HOME } } catch { $homeDirectory = '' }
    if ($homeDirectory -eq '') { $homeDirectory = [string]$env:USERPROFILE }
    $normalizedHome = $homeDirectory -replace '[\\/]+$', ''

    $isWindowsPowerShell51 = $false
    try {
        if ($PSVersionTable.PSVersion.Major -lt 6) { $isWindowsPowerShell51 = $true }
    } catch {
        $isWindowsPowerShell51 = $false
    }

    $failed = $false
    foreach ($pathValue in $paths) {
        $path = [string]$pathValue

        # A path made only of separators is a root request: refuse it before Get-Item,
        # because PowerShell on Unix resolves "//" to a bizarre drive-relative location
        # (for example "/opt/") instead of to "/".
        if ($path -match '^[\\/]+$') {
            Write-Error -Message ("rm: refusing to remove '{0}': it is a root path" -f $path) -ErrorAction Continue
            $failed = $true
            continue
        }
        if ($env:OS -eq 'Windows_NT' -and $path -match '^[A-Za-z]:$') {
            Write-Error -Message ("rm: refusing to remove '{0}': it is a drive root in disguise; name the directory explicitly" -f $path) -ErrorAction Continue
            $failed = $true
            continue
        }

        # On Unix, collapse a leading run of slashes to one, so "//tmp" means "/tmp"
        # (POSIX allows the double-slash form to be implementation-defined; PowerShell's
        # interpretation is not safe to pass through).
        if ($env:OS -ne 'Windows_NT' -and $path -match '^/{2,}') {
            $path = '/' + ($path -replace '^/+', '')
        }

        $item = $null
        try { $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop } catch { $item = $null }
        if ($null -eq $item) {
            if (-not $forceFlag) {
                Write-Error -Message ("rm: cannot remove '{0}': No such file or directory" -f $path) -ErrorAction Continue
                $failed = $true
            }
            continue
        }

        $full = [string]$item.FullName

        # Refuse drive roots ("C:\", "C:"), the Unix root, and UNC share roots.
        if ($full -match '^[A-Za-z]:[\\/]?$' -or $full -match '^[\\/]+$' -or $full -match '^\\\\[^\\]+\\[^\\]+\\?$') {
            Write-Error -Message ("rm: refusing to remove '{0}': it is a drive or share root" -f $full) -ErrorAction Continue
            $failed = $true
            continue
        }

        $normalizedFull = $full -replace '[\\/]+$', ''
        if ($normalizedHome -ne '' -and $normalizedFull -eq $normalizedHome) {
            Write-Error -Message ("rm: refusing to remove '{0}': it is the home directory" -f $full) -ErrorAction Continue
            $failed = $true
            continue
        }

        if ($item.PSIsContainer) {
            if (-not $recursive) {
                Write-Error -Message ("rm: cannot remove '{0}': Is a directory" -f $path) -ErrorAction Continue
                $failed = $true
                continue
            }

            if ($isWindowsPowerShell51) {
                # Walk the tree without traversing a link: check a directory for
                # ReparsePoint before enumerating its children.
                $hasReparsePoint = $false
                if ([string]$item.Attributes -match 'ReparsePoint') {
                    $hasReparsePoint = $true
                } else {
                    $stack = @($item)
                    while ($stack.Count -gt 0) {
                        $current = $stack[0]
                        if ($stack.Count -le 1) {
                            $stack = @()
                        } else {
                            $stack = @($stack[1..($stack.Count - 1)])
                        }
                        if ([string]$current.Attributes -match 'ReparsePoint') {
                            $hasReparsePoint = $true
                            break
                        }
                        if ($current.PSIsContainer) {
                            $children = @()
                            try {
                                $children = @(Get-ChildItem -LiteralPath ([string]$current.FullName) -Force -ErrorAction SilentlyContinue)
                            } catch {
                                $children = @()
                            }
                            foreach ($child in $children) { $stack += $child }
                        }
                    }
                }
                if ($hasReparsePoint) {
                    Write-Error -Message ("rm: refusing to remove '{0}': the tree contains a reparse point (junction or symlink), which Remove-Item -Recurse would follow on Windows PowerShell 5.1" -f $full) -ErrorAction Continue
                    $failed = $true
                    continue
                }
            }
        }

        try {
            if ($item.PSIsContainer) {
                Remove-Item -LiteralPath $full -Recurse -Force -Confirm:$false -ErrorAction Stop
            } else {
                Remove-Item -LiteralPath $full -Force -Confirm:$false -ErrorAction Stop
            }
        } catch {
            Write-Error -Message ("rm: cannot remove '{0}': {1}" -f $path, $_.Exception.Message) -ErrorAction Continue
            $failed = $true
        }
    }

    if ($failed) { $global:LASTEXITCODE = 1 } else { $global:LASTEXITCODE = 0 }
}

function mv {
    <#
    .SYNOPSIS
        Move or rename files and directories (Move-Item), with emulated -f overwrite.
    .DESCRIPTION
        Usage: mv [-f] SOURCE... DEST. Several sources require DEST to be an existing
        directory. Without -f an existing destination is an error, which is safer than GNU
        mv's silent overwrite. With -f the destination is removed first, because Windows
        PowerShell 5.1's Move-Item -Force refuses to overwrite an existing target.

        Divergence: the remove-then-move sequence is not atomic; do not build a transaction
        on it. Cross-volume moves depend on Move-Item's own copy fallback. PowerShell does
        not expand shell globs, so wildcard sources and destinations are literal paths.
    .EXAMPLE
        mv -f /tmp/new.txt /tmp/old.txt
    #>
    param(
        [switch]$Force
    )

    $argv = ConvertFrom-UxArgv -Tokens $args -ValueFlags @() -AliasMap @{ Force = 'f' }
    $flags = @{}
    foreach ($key in $argv.Flags.Keys) { $flags[[string]$key] = $true }
    if ($Force) { $flags['f'] = $true }
    $overwriteExisting = $flags.ContainsKey('f')

    $positional = @($argv.Positional)
    if ($positional.Count -lt 2) {
        if ($positional.Count -eq 1) {
            Write-Error -Message ("mv: missing destination file operand after '{0}'" -f [string]$positional[0]) -ErrorAction Continue
        } else {
            Write-Error -Message 'mv: missing file operand' -ErrorAction Continue
        }
        $global:LASTEXITCODE = 1
        return
    }

    $sources = @($positional[0..($positional.Count - 2)])
    $target = [string]$positional[$positional.Count - 1]

    if ($target -match '^[\\/]+$') {
        Write-Error -Message ("mv: refusing to use '{0}' as a destination: it is a root path" -f $target) -ErrorAction Continue
        $global:LASTEXITCODE = 1
        return
    }
    if ($env:OS -ne 'Windows_NT' -and $target -match '^/{2,}') {
        $target = '/' + ($target -replace '^/+', '')
    }

    $multiple = ($sources.Count -gt 1)

    if ($multiple -and -not (Test-Path -LiteralPath $target -PathType Container)) {
        Write-Error -Message ("mv: target '{0}' is not a directory" -f $target) -ErrorAction Continue
        $global:LASTEXITCODE = 1
        return
    }

    $targetIsDirectory = Test-Path -LiteralPath $target -PathType Container
    $failed = $false

    foreach ($sourceValue in $sources) {
        $source = [string]$sourceValue
        if ($source -match '^[\\/]+$') {
            Write-Error -Message ("mv: refusing to use '{0}': it is a root path" -f $source) -ErrorAction Continue
            $failed = $true
            continue
        }
        if ($env:OS -ne 'Windows_NT' -and $source -match '^/{2,}') {
            $source = '/' + ($source -replace '^/+', '')
        }
        $sourceItem = $null
        try { $sourceItem = Get-Item -LiteralPath $source -Force -ErrorAction Stop } catch { $sourceItem = $null }
        if ($null -eq $sourceItem) {
            Write-Error -Message ("mv: cannot stat '{0}': No such file or directory" -f $source) -ErrorAction Continue
            $failed = $true
            continue
        }

        $destination = $target
        if ($targetIsDirectory -or $multiple) {
            $destination = Join-Path -Path $target -ChildPath ([string]$sourceItem.Name)
        }

        $normalizedSource = ([string]$sourceItem.FullName) -replace '[\\/]+$', ''
        $normalizedDestination = $destination -replace '[\\/]+$', ''
        if ($normalizedSource -eq $normalizedDestination) {
            Write-Error -Message ("mv: '{0}' and '{1}' are the same file" -f $source, $destination) -ErrorAction Continue
            $failed = $true
            continue
        }

        if (Test-Path -LiteralPath $destination) {
            $destinationItem = $null
            try { $destinationItem = Get-Item -LiteralPath $destination -Force -ErrorAction Stop } catch { $destinationItem = $null }
            if ($null -ne $destinationItem -and (([string]$destinationItem.FullName) -replace '[\\/]+$', '') -eq $normalizedSource) {
                Write-Error -Message ("mv: '{0}' and '{1}' are the same file" -f $source, $destination) -ErrorAction Continue
                $failed = $true
                continue
            }
            if (-not $overwriteExisting) {
                Write-Error -Message ("mv: cannot move '{0}' to '{1}': destination exists (use -f to overwrite)" -f $source, $destination) -ErrorAction Continue
                $failed = $true
                continue
            }
            try {
                Remove-Item -LiteralPath $destination -Recurse -Force -Confirm:$false -ErrorAction Stop
            } catch {
                Write-Error -Message ("mv: cannot overwrite '{0}': {1}" -f $destination, $_.Exception.Message) -ErrorAction Continue
                $failed = $true
                continue
            }
        }

        try {
            Move-Item -LiteralPath ([string]$sourceItem.FullName) -Destination $destination -Force -ErrorAction Stop
        } catch {
            Write-Error -Message ("mv: cannot move '{0}' to '{1}': {2}" -f $source, $destination, $_.Exception.Message) -ErrorAction Continue
            $failed = $true
        }
    }

    if ($failed) { $global:LASTEXITCODE = 1 } else { $global:LASTEXITCODE = 0 }
}

function grep {
    <#
    .SYNOPSIS
        Search text with Unix semantics: case-sensitive and literal by default.
    .DESCRIPTION
        Flags: -i (ignore case), -F (literal, the default), -E (.NET regex), -v (invert),
        -n (line numbers), -r (recurse over files), -l (file names only), -c (counts),
        -q (quiet). PATTERN is the first positional token; the rest are paths.

        Output is "path:line: text" for files and "line: text" for pipeline input; the
        filename is always included for file sources. Matching is done per line so line
        numbers and inversion are exact. -r uses Get-ChildItem -Recurse -File, which
        skips hidden items unless they are named explicitly on the command line.

        $LASTEXITCODE is set explicitly: 0 = match, 1 = no match, 2 = error. $? is not
        reliable after an internal failure, so scripts should branch on $LASTEXITCODE.
        Divergence: single-file searches still print the filename; patterns beginning with
        "-" cannot be expressed (PowerShell consumes the "--" separator before the wrapper).
        PowerShell does not expand shell globs, so path operands are literal. With no path
        and no pipeline input grep reports no match (exit 1) instead of blocking on the
        console.
    .EXAMPLE
        grep -n beta /tmp/a.txt
    .EXAMPLE
        grep -i -r TODO /tmp/src
    .EXAMPLE
        Get-Content /tmp/a.txt | grep -v beta
    #>
    param(
        [switch]$Recurse,
        [switch]$IgnoreCase
    )

    $argv = ConvertFrom-UxArgv -Tokens $args -ValueFlags @() -AliasMap @{
        Recursive        = 'r'
        Recurse          = 'r'
        IgnoreCase       = 'i'
        InvertMatch      = 'v'
        LineNumber       = 'n'
        FilesWithMatches = 'l'
        Count            = 'c'
        Quiet            = 'q'
        Fixed            = 'F'
        FixedStrings     = 'F'
        Extended         = 'E'
        ExtendedRegexp   = 'E'
    }
    $flags = @{}
    foreach ($key in $argv.Flags.Keys) { $flags[[string]$key] = $true }
    if ($Recurse) { $flags['r'] = $true }
    if ($IgnoreCase) { $flags['i'] = $true }

    $global:LASTEXITCODE = 2

    $positional = @($argv.Positional)
    if ($positional.Count -lt 1) {
        Write-Error -Message 'grep: no pattern given (usage: grep [flags] PATTERN [path...])' -ErrorAction Continue
        return
    }

    $pattern = [string]$positional[0]
    $pathArgs = @()
    if ($positional.Count -gt 1) { $pathArgs = @($positional[1..($positional.Count - 1)]) }

    $recursive = $flags.ContainsKey('r')
    $caseSensitive = -not $flags.ContainsKey('i')
    $literal = -not $flags.ContainsKey('E')
    $invert = $flags.ContainsKey('v')
    $number = $flags.ContainsKey('n')
    $filesOnly = $flags.ContainsKey('l')
    $countOnly = $flags.ContainsKey('c')
    $quiet = $flags.ContainsKey('q')

    $matchAll = ($pattern -eq '')
    $globPattern = '*' + ($pattern -replace '([\*\?\[\]`])', '`$1') + '*'

    if (-not $literal) {
        $patternIsValid = $true
        try { $null = 'x' -cmatch $pattern } catch { $patternIsValid = $false }
        if (-not $patternIsValid) {
            Write-Error -Message ("grep: invalid regular expression: {0}" -f $pattern) -ErrorAction Continue
            return
        }
    }

    $fromPipeline = $false
    if ($pathArgs.Count -eq 0) {
        if ($recursive) {
            $pathArgs = @('.')
        } else {
            $fromPipeline = $true
        }
    }

    $files = @()
    $hadError = $false
    foreach ($pathValue in $pathArgs) {
        $pathText = [string]$pathValue
        $item = $null
        try { $item = Get-Item -LiteralPath $pathText -Force -ErrorAction Stop } catch { $item = $null }
        if ($null -eq $item) {
            Write-Error -Message ("grep: {0}: No such file or directory" -f $pathText) -ErrorAction Continue
            $hadError = $true
            continue
        }
        if ($item.PSIsContainer) {
            if (-not $recursive) {
                Write-Error -Message ("grep: {0}: Is a directory" -f $pathText) -ErrorAction Continue
                $hadError = $true
                continue
            }
            $children = @()
            try {
                $children = @(Get-ChildItem -LiteralPath ([string]$item.FullName) -Recurse -File -ErrorAction SilentlyContinue)
            } catch {
                $children = @()
            }
            foreach ($child in $children) { $files += $child }
        } else {
            $files += $item
        }
    }

    $sources = @()
    if ($fromPipeline) {
        $sources = @([pscustomobject]@{ Path = ''; Lines = @($input) })
    } else {
        foreach ($file in $files) {
            $sources += [pscustomobject]@{ Path = [string]$file.FullName; Lines = $null }
        }
    }

    $multiple = ($sources.Count -gt 1)
    $found = $false

    :sourceLoop foreach ($source in $sources) {
        $path = [string]$source.Path
        $lines = $source.Lines
        if ($null -eq $lines) {
            try {
                $lines = @(Get-Content -LiteralPath $path -ErrorAction Stop)
            } catch {
                Write-Error -Message ("grep: {0}: {1}" -f $path, $_.Exception.Message) -ErrorAction Continue
                $hadError = $true
                continue
            }
        }

        $lineNumber = 0
        $sourceMatches = 0

        :lineLoop foreach ($line in $lines) {
            $lineNumber = $lineNumber + 1
            $text = [string]$line

            $isMatch = $false
            if ($matchAll) {
                $isMatch = $true
            } elseif ($literal) {
                if ($caseSensitive) {
                    $isMatch = $text -clike $globPattern
                } else {
                    $isMatch = $text -like $globPattern
                }
            } else {
                if ($caseSensitive) {
                    $isMatch = $text -cmatch $pattern
                } else {
                    $isMatch = $text -imatch $pattern
                }
            }
            if ($invert) { $isMatch = -not $isMatch }
            if (-not $isMatch) { continue }

            $found = $true
            $sourceMatches = $sourceMatches + 1

            if ($quiet) { break sourceLoop }
            if ($filesOnly) { break lineLoop }
            if ($countOnly) { continue }

            if ($path -ne '') {
                if ($number) {
                    '{0}:{1}: {2}' -f $path, $lineNumber, $text
                } else {
                    '{0}:{1}' -f $path, $text
                }
            } else {
                if ($number) {
                    '{0}: {1}' -f $lineNumber, $text
                } else {
                    $text
                }
            }
        }

        if ($filesOnly) {
            if ($sourceMatches -gt 0) {
                if ($path -ne '') { $path } else { '(standard input)' }
            }
        } elseif ($countOnly) {
            if ($path -ne '' -and $multiple) {
                '{0}:{1}' -f $path, $sourceMatches
            } else {
                $sourceMatches
            }
        }
    }

    if ($hadError) {
        $global:LASTEXITCODE = 2
    } elseif ($found) {
        $global:LASTEXITCODE = 0
    } else {
        $global:LASTEXITCODE = 1
    }
}

function find {
    <#
    .SYNOPSIS
        Find files and directories recursively: find [path...] [-name PAT] [-type f|d].
    .DESCRIPTION
        Prints full paths. -name takes a PowerShell wildcard; a plain wildcard pattern is
        pushed into Get-ChildItem -Filter for provider-level speed and is then checked again
        with -like, because -Filter can over-match (Windows 8.3 short names). Patterns with a
        path separator or a character class are filtered with Where-Object only. -Include is
        never used: -Include without -Recurse silently returns nothing.

        Errors are suppressed during enumeration; a missing starting path is reported.
        $LASTEXITCODE is set explicitly: 0 = found, 1 = nothing found, 2 = error.

        Divergence: the starting path itself is not printed (GNU find prints it), the name
        match is case-insensitive on every platform (PowerShell -like semantics), -name only
        matches the base name, and starting paths are literal (PowerShell does not expand
        shell globs; -name is the pattern mechanism).
    .EXAMPLE
        find /tmp -name "*.txt"
    .EXAMPLE
        find . -type d
    #>
    $argv = ConvertFrom-UxArgv -Tokens $args -ValueFlags @('name', 'type') -AliasMap @{
        Name = 'name'
        Type = 'type'
    }
    $values = @{}
    foreach ($key in $argv.Values.Keys) { $values[[string]$key] = [string]$argv.Values[$key] }

    $paths = @($argv.Positional)
    if ($paths.Count -eq 0) { $paths = @('.') }

    $namePattern = '*'
    $filterPattern = $null
    if ($values.ContainsKey('name')) {
        $namePattern = [string]$values['name']
        if ($namePattern -ne '' -and $namePattern -notmatch '[\\/\[\]]') { $filterPattern = $namePattern }
    }

    $type = ''
    if ($values.ContainsKey('type')) { $type = [string]$values['type'] }
    if ($type -ne '' -and $type -ne 'f' -and $type -ne 'd') {
        Write-Error -Message ("find: unknown argument to -type: {0} (use f or d)" -f $type) -ErrorAction Continue
        $global:LASTEXITCODE = 2
        return
    }

    $hadError = $false
    $found = $false

    foreach ($pathValue in $paths) {
        $path = [string]$pathValue
        if (-not (Test-Path -LiteralPath $path)) {
            Write-Error -Message ("find: '{0}': No such file or directory" -f $path) -ErrorAction Continue
            $hadError = $true
            continue
        }

        $getChildItem = @{
            LiteralPath = $path
            Recurse     = $true
            Force       = $true
            ErrorAction = 'SilentlyContinue'
        }
        if ($null -ne $filterPattern) { $getChildItem['Filter'] = $filterPattern }

        $items = @()
        try { $items = @(Get-ChildItem @getChildItem) } catch { $items = @() }

        # -Filter is only a fast pre-filter (it can over-match 8.3 short names and it is
        # ignored when the starting path is itself a file), so the exact name check runs
        # through Where-Object -like in every case.
        if ($namePattern -ne '*') {
            $items = @($items | Where-Object { [string]$_.Name -like $namePattern })
        }
        if ($type -eq 'f') {
            $items = @($items | Where-Object { -not $_.PSIsContainer })
        } elseif ($type -eq 'd') {
            $items = @($items | Where-Object { $_.PSIsContainer })
        }

        foreach ($item in $items) {
            [string]$item.FullName
            $found = $true
        }
    }

    if ($hadError) {
        $global:LASTEXITCODE = 2
    } elseif ($found) {
        $global:LASTEXITCODE = 0
    } else {
        $global:LASTEXITCODE = 1
    }
}

function head {
    <#
    .SYNOPSIS
        Print the first N lines or objects (default 10).
    .DESCRIPTION
        Usage: head [-n N] [file...] or ... | head [-n N]. -n accepts a positive integer;
        the GNU forms "head -5" and "head -n5" both work. With several files, "==> file <==" headers
        are printed. Pipeline input is enumerated with $input and objects are passed through
        unchanged, so "Get-Process | head -n 3" keeps real process objects.

        Divergence: negative counts (GNU's "all but the last N") are not implemented;
        PowerShell does not expand shell globs, so path operands are literal; and with no
        operands and no pipeline input head returns immediately (it does not block on the
        console).
    .EXAMPLE
        head -n 20 /tmp/app.log
    .EXAMPLE
        Get-Content /tmp/app.log | head -5
    #>
    # Normalise GNU's attached count form (-n5) into "-n 5": the shared tokenizer
    # treats a value flag inside a cluster as consuming the next token, which would
    # otherwise swallow the filename.
    $tokenList = @()
    foreach ($rawToken in $args) {
        $tokenText = [string]$rawToken
        if ($tokenText -match '^-n-?[0-9]+$') {
            $tokenList += '-n'
            $tokenList += ($tokenText -replace '^-n', '')
        } else {
            $tokenList += $tokenText
        }
    }

    $argv = ConvertFrom-UxArgv -Tokens $tokenList -ValueFlags @('n') -AliasMap @{
        Count = 'n'
        Lines = 'n'
    }
    $flags = @{}
    foreach ($key in $argv.Flags.Keys) { $flags[[string]$key] = $true }
    $values = @{}
    foreach ($key in $argv.Values.Keys) { $values[[string]$key] = [string]$argv.Values[$key] }

    $count = 10
    if ($values.ContainsKey('n')) {
        $raw = [string]$values['n']
        $parsedCount = -1L
        if ($raw -match '^[0-9]+$') {
            try { $parsedCount = [long]$raw } catch { $parsedCount = -1 }
        }
        if ($parsedCount -lt 0) {
            Write-Error -Message ("head: invalid number of lines: '{0}'" -f $raw) -ErrorAction Continue
            $global:LASTEXITCODE = 1
            return
        }
        if ($parsedCount -gt 2147483647) { $parsedCount = 2147483647 }
        $count = [int]$parsedCount
    } else {
        foreach ($key in $flags.Keys) {
            $keyText = [string]$key
            if ($keyText -match '^[0-9]+$') {
                $parsedCount = 0L
                try { $parsedCount = [long]$keyText } catch { $parsedCount = 0 }
                if ($parsedCount -gt 2147483647) { $parsedCount = 2147483647 }
                $count = [int]$parsedCount
                break
            }
        }
    }

    $paths = @($argv.Positional)

    if ($paths.Count -eq 0) {
        $shown = 0
        foreach ($item in $input) {
            if ($shown -ge $count) { break }
            $item
            $shown = $shown + 1
        }
        $global:LASTEXITCODE = 0
        return
    }

    $failed = $false
    $multiple = ($paths.Count -gt 1)
    $first = $true

    foreach ($pathValue in $paths) {
        $path = [string]$pathValue
        $item = $null
        try { $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop } catch { $item = $null }
        if ($null -eq $item) {
            Write-Error -Message ("head: cannot open '{0}' for reading: No such file or directory" -f $path) -ErrorAction Continue
            $failed = $true
            continue
        }
        if ($item.PSIsContainer) {
            Write-Error -Message ("head: error reading '{0}': Is a directory" -f $path) -ErrorAction Continue
            $failed = $true
            continue
        }

        if ($multiple) {
            if (-not $first) { '' }
            '==> {0} <==' -f $path
            $first = $false
        }

        if ($count -gt 0) {
            try {
                Get-Content -LiteralPath ([string]$item.FullName) -TotalCount $count -ErrorAction Stop
            } catch {
                Write-Error -Message ("head: error reading '{0}': {1}" -f $path, $_.Exception.Message) -ErrorAction Continue
                $failed = $true
            }
        }
    }

    if ($failed) { $global:LASTEXITCODE = 1 } else { $global:LASTEXITCODE = 0 }
}

function tail {
    <#
    .SYNOPSIS
        Print the last N lines or objects (default 10), with -f to follow a file.
    .DESCRIPTION
        Usage: tail [-n N] [-f] [file...] or ... | tail [-n N]. -n accepts a positive integer;
        the GNU forms "tail -20" and "tail -n5" both work. Objects piped in are passed through
        unchanged, so "ps | tail -n 3" keeps real process objects.

        -f is Get-Content -Wait: it follows a single file until Ctrl+C or Enter. On Windows
        PowerShell 5.1 an extra Enter is needed to stop it, and file-change notification is
        unreliable over SMB (a line can arrive late or not at all).

        Divergence: -f supports exactly one file; -F (reopen on rotation) is not implemented;
        PowerShell does not expand shell globs, so path operands are literal; and with no
        operands and no pipeline input tail returns immediately (it does not block on the
        console).
    .EXAMPLE
        tail -n 50 /tmp/app.log
    .EXAMPLE
        tail -f /tmp/app.log
    #>
    param(
        [switch]$Follow
    )

    # Normalise GNU's attached count form (-n5) into "-n 5" (see head).
    $tokenList = @()
    foreach ($rawToken in $args) {
        $tokenText = [string]$rawToken
        if ($tokenText -match '^-n-?[0-9]+$') {
            $tokenList += '-n'
            $tokenList += ($tokenText -replace '^-n', '')
        } else {
            $tokenList += $tokenText
        }
    }

    $argv = ConvertFrom-UxArgv -Tokens $tokenList -ValueFlags @('n') -AliasMap @{
        Count  = 'n'
        Lines  = 'n'
        Follow = 'f'
    }
    $flags = @{}
    foreach ($key in $argv.Flags.Keys) { $flags[[string]$key] = $true }
    $values = @{}
    foreach ($key in $argv.Values.Keys) { $values[[string]$key] = [string]$argv.Values[$key] }
    if ($Follow) { $flags['f'] = $true }
    $doFollow = $flags.ContainsKey('f')

    $count = 10
    if ($values.ContainsKey('n')) {
        $raw = [string]$values['n']
        $parsedCount = -1L
        if ($raw -match '^[0-9]+$') {
            try { $parsedCount = [long]$raw } catch { $parsedCount = -1 }
        }
        if ($parsedCount -lt 0) {
            Write-Error -Message ("tail: invalid number of lines: '{0}'" -f $raw) -ErrorAction Continue
            $global:LASTEXITCODE = 1
            return
        }
        if ($parsedCount -gt 2147483647) { $parsedCount = 2147483647 }
        $count = [int]$parsedCount
    } else {
        foreach ($key in $flags.Keys) {
            $keyText = [string]$key
            if ($keyText -match '^[0-9]+$') {
                $parsedCount = 0L
                try { $parsedCount = [long]$keyText } catch { $parsedCount = 0 }
                if ($parsedCount -gt 2147483647) { $parsedCount = 2147483647 }
                $count = [int]$parsedCount
                break
            }
        }
    }

    $paths = @($argv.Positional)

    if ($paths.Count -eq 0) {
        if ($doFollow) {
            Write-Error -Message 'tail: cannot follow standard input' -ErrorAction Continue
            $global:LASTEXITCODE = 1
            return
        }
        $buffer = @()
        if ($count -gt 0) {
            foreach ($item in $input) {
                $buffer += $item
                if ($buffer.Count -gt $count) {
                    $start = $buffer.Count - $count
                    $buffer = @($buffer[$start..($buffer.Count - 1)])
                }
            }
        }
        foreach ($item in $buffer) { $item }
        $global:LASTEXITCODE = 0
        return
    }

    if ($doFollow -and $paths.Count -gt 1) {
        Write-Error -Message 'tail: -f supports exactly one file' -ErrorAction Continue
        $global:LASTEXITCODE = 1
        return
    }

    $failed = $false
    $multiple = ($paths.Count -gt 1)
    $first = $true

    foreach ($pathValue in $paths) {
        $path = [string]$pathValue
        $item = $null
        try { $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop } catch { $item = $null }
        if ($null -eq $item) {
            Write-Error -Message ("tail: cannot open '{0}' for reading: No such file or directory" -f $path) -ErrorAction Continue
            $failed = $true
            continue
        }
        if ($item.PSIsContainer) {
            Write-Error -Message ("tail: error reading '{0}': Is a directory" -f $path) -ErrorAction Continue
            $failed = $true
            continue
        }

        if ($multiple) {
            if (-not $first) { '' }
            '==> {0} <==' -f $path
            $first = $false
        }

        try {
            if ($doFollow) {
                Get-Content -LiteralPath ([string]$item.FullName) -Tail $count -Wait -ErrorAction Stop
            } elseif ($count -gt 0) {
                Get-Content -LiteralPath ([string]$item.FullName) -Tail $count -ErrorAction Stop
            }
        } catch {
            Write-Error -Message ("tail: error reading '{0}': {1}" -f $path, $_.Exception.Message) -ErrorAction Continue
            $failed = $true
        }
    }

    if ($failed) { $global:LASTEXITCODE = 1 } else { $global:LASTEXITCODE = 0 }
}

function wc {
    <#
    .SYNOPSIS
        Count lines, words and bytes/characters, like Unix wc.
    .DESCRIPTION
        -l lines, -w words, -c bytes; with no flag all three are printed. For files, -c is
        the exact byte length from Get-Item.Length. For pipeline input, -c counts characters,
        because text arriving through the pipeline has already lost its byte representation
        (documented divergence). Several files add a "total" row.

        Divergence: word splitting uses the PowerShell \s+ regex, which is close to but not
        identical to POSIX wc's whitespace handling. -l counts PowerShell text lines, so a
        final line without a newline still counts once (GNU wc -l counts newline characters).
        PowerShell does not expand shell globs, so wildcard paths are literal. With no
        operands and no pipeline input wc prints zeros because it cannot read an unbuffered
        console.
    .EXAMPLE
        wc -l /tmp/a.txt
    .EXAMPLE
        Get-Content /tmp/a.txt | wc -w
    #>
    param(
        [switch]$Lines,
        [switch]$Words
    )

    $argv = ConvertFrom-UxArgv -Tokens $args -ValueFlags @() -AliasMap @{
        Lines      = 'l'
        Words      = 'w'
        Bytes      = 'c'
        Characters = 'c'
        Chars      = 'c'
    }
    $flags = @{}
    foreach ($key in $argv.Flags.Keys) { $flags[[string]$key] = $true }
    if ($Lines) { $flags['l'] = $true }
    if ($Words) { $flags['w'] = $true }

    $doLines = $flags.ContainsKey('l')
    $doWords = $flags.ContainsKey('w')
    $doBytes = $flags.ContainsKey('c')
    if (-not $doLines -and -not $doWords -and -not $doBytes) {
        $doLines = $true
        $doWords = $true
        $doBytes = $true
    }

    $paths = @($argv.Positional)

    if ($paths.Count -eq 0) {
        $lineTotal = 0
        $wordTotal = 0
        $charTotal = 0
        foreach ($item in $input) {
            $lineTotal = $lineTotal + 1
            $text = [string]$item
            $charTotal = $charTotal + $text.Length
            $wordTotal = $wordTotal + @($text -split '\s+' | Where-Object { $_ -ne '' }).Count
        }
        $parts = @()
        if ($doLines) { $parts += ('{0,7}' -f $lineTotal) }
        if ($doWords) { $parts += ('{0,7}' -f $wordTotal) }
        if ($doBytes) { $parts += ('{0,7}' -f $charTotal) }
        $parts -join ' '
        $global:LASTEXITCODE = 0
        return
    }

    $failed = $false
    $lineTotal = 0
    $wordTotal = 0
    $byteTotal = 0
    $showTotal = ($paths.Count -gt 1)

    foreach ($pathValue in $paths) {
        $path = [string]$pathValue
        $item = $null
        try { $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop } catch { $item = $null }
        if ($null -eq $item) {
            Write-Error -Message ("wc: {0}: No such file or directory" -f $path) -ErrorAction Continue
            $failed = $true
            continue
        }
        if ($item.PSIsContainer) {
            Write-Error -Message ("wc: {0}: Is a directory" -f $path) -ErrorAction Continue
            $failed = $true
            continue
        }

        $fileLines = @()
        try {
            $fileLines = @(Get-Content -LiteralPath ([string]$item.FullName) -ErrorAction Stop)
        } catch {
            Write-Error -Message ("wc: {0}: {1}" -f $path, $_.Exception.Message) -ErrorAction Continue
            $failed = $true
            continue
        }

        $lineCount = $fileLines.Count
        $wordCount = 0
        foreach ($line in $fileLines) {
            $wordCount = $wordCount + @(([string]$line) -split '\s+' | Where-Object { $_ -ne '' }).Count
        }
        $byteCount = [long]$item.Length

        $lineTotal = $lineTotal + $lineCount
        $wordTotal = $wordTotal + $wordCount
        $byteTotal = $byteTotal + $byteCount

        $parts = @()
        if ($doLines) { $parts += ('{0,7}' -f $lineCount) }
        if ($doWords) { $parts += ('{0,7}' -f $wordCount) }
        if ($doBytes) { $parts += ('{0,7}' -f $byteCount) }
        $parts += $path
        $parts -join ' '
    }

    if ($showTotal) {
        $parts = @()
        if ($doLines) { $parts += ('{0,7}' -f $lineTotal) }
        if ($doWords) { $parts += ('{0,7}' -f $wordTotal) }
        if ($doBytes) { $parts += ('{0,7}' -f $byteTotal) }
        $parts += 'total'
        $parts -join ' '
    }

    if ($failed) { $global:LASTEXITCODE = 1 } else { $global:LASTEXITCODE = 0 }
}

function which {
    <#
    .SYNOPSIS
        Show what a command name resolves to: alias, function, cmdlet or application.
    .DESCRIPTION
        Resolution order is alias, function, filter, cmdlet, external script, script, then
        application - the same precedence PowerShell uses. An application prints its full
        path; a function prints its definition; an alias prints its target. A flag token
        such as -a is ignored and only the first match is printed (GNU -a is not
        implemented).

        $LASTEXITCODE is 0 when every name resolved and 1 when at least one did not.
    .EXAMPLE
        which Get-ChildItem
    .EXAMPLE
        which ls
    #>
    $names = @()
    foreach ($token in @($args)) {
        $text = [string]$token
        if ($text.Length -gt 1 -and $text.StartsWith('-')) { continue }
        $names += $text
    }
    if ($names.Count -eq 0) {
        Write-Error -Message 'which: usage: which NAME...' -ErrorAction Continue
        $global:LASTEXITCODE = 1
        return
    }

    $failed = $false
    foreach ($nameValue in $names) {
        $name = [string]$nameValue
        $escaped = $name -replace '([\*\?\[\]`])', '`$1'

        $candidates = @()
        try { $candidates = @(Get-Command -Name $escaped -All -ErrorAction SilentlyContinue) } catch { $candidates = @() }

        $picked = $null
        foreach ($typeName in @('Alias', 'Function', 'Filter', 'Cmdlet', 'ExternalScript', 'Script', 'Application')) {
            foreach ($candidate in $candidates) {
                if ([string]$candidate.CommandType -eq $typeName) {
                    $picked = $candidate
                    break
                }
            }
            if ($null -ne $picked) { break }
        }

        if ($null -eq $picked) {
            Write-Error -Message ("which: no {0} in (PATH)" -f $name) -ErrorAction Continue
            $failed = $true
            continue
        }

        $commandType = [string]$picked.CommandType
        if ($commandType -eq 'Alias') {
            '{0}: aliased to {1}' -f $name, [string]$picked.Definition
        } elseif ($commandType -eq 'Function' -or $commandType -eq 'Filter') {
            '{0}: function' -f $name
            $definition = [string]$picked.Definition
            if ($definition -ne '') { $definition }
        } elseif ($commandType -eq 'Cmdlet') {
            $module = ''
            try { $module = [string]$picked.ModuleName } catch { $module = '' }
            if ($module -ne '') {
                '{0}: cmdlet ({1})' -f $name, $module
            } else {
                '{0}: cmdlet' -f $name
            }
        } else {
            $target = ''
            try { $target = [string]$picked.Path } catch { $target = '' }
            if ($target -eq '') {
                try { $target = [string]$picked.Source } catch { $target = '' }
            }
            if ($target -ne '') {
                $target
            } else {
                '{0}: {1}' -f $name, $commandType
            }
        }
    }

    if ($failed) { $global:LASTEXITCODE = 1 } else { $global:LASTEXITCODE = 0 }
}

function env {
    <#
    .SYNOPSIS
        Print environment variables as NAME=VALUE, optionally filtered by name.
    .DESCRIPTION
        With no arguments every variable is printed, sorted by name for deterministic
        output. One or more NAME filters accept PowerShell wildcards and are matched
        case-insensitively against the variable name (Windows environment variables are
        case-insensitive). Tokens beginning with "-" are ignored (Unix flags are not
        implemented).
    .EXAMPLE
        env
    .EXAMPLE
        env UX_*
    #>
    $filters = @()
    foreach ($token in @($args)) {
        $text = [string]$token
        if ($text.Length -gt 1 -and $text.StartsWith('-')) { continue }
        $filters += $text
    }

    $entries = @()
    try { $entries = @(Get-ChildItem -LiteralPath 'Env:' -ErrorAction Stop) } catch { $entries = @() }
    $entries = @($entries | Sort-Object -Property Name)

    foreach ($entry in $entries) {
        $name = [string]$entry.Name
        $show = $true
        if ($filters.Count -gt 0) {
            $show = $false
            foreach ($filterValue in $filters) {
                $filter = [string]$filterValue
                if ($name -like $filter) {
                    $show = $true
                    break
                }
            }
        }
        if ($show) { '{0}={1}' -f $name, [string]$entry.Value }
    }
}

function export {
    <#
    .SYNOPSIS
        Set environment variables from NAME=VALUE tokens (Set-Item Env:).
    .DESCRIPTION
        Each argument is split at the first "="; everything after it is the value, so
        "export PATH=C:\x;y" keeps the semicolon. A bare NAME without "=" is a no-op, as
        documented in README.md (this is not a bash variable-export). Several NAME=VALUE
        pairs may be given at once.
    .EXAMPLE
        export UX_THEME=classic
    .EXAMPLE
        export FOO=1 BAR=2
    #>
    $failed = $false
    foreach ($token in @($args)) {
        $text = [string]$token
        if ($text.Length -gt 1 -and $text.StartsWith('-')) { continue }
        $equalsAt = $text.IndexOf('=')
        if ($equalsAt -lt 0) { continue }

        $name = $text.Substring(0, $equalsAt)
        if ($name -eq '') {
            Write-Error -Message ("export: not a valid identifier: '{0}'" -f $text) -ErrorAction Continue
            $failed = $true
            continue
        }

        $value = $text.Substring($equalsAt + 1)
        try {
            Set-Item -LiteralPath ('Env:' + $name) -Value $value -ErrorAction Stop
        } catch {
            Write-Error -Message ("export: cannot set '{0}': {1}" -f $name, $_.Exception.Message) -ErrorAction Continue
            $failed = $true
        }
    }

    if ($failed) { $global:LASTEXITCODE = 1 } else { $global:LASTEXITCODE = 0 }
}

function unset {
    <#
    .SYNOPSIS
        Remove environment variables (Remove-Item Env:).
    .DESCRIPTION
        One or more names may be given. Removing a variable that does not exist is silent,
        like Unix unset.
    .EXAMPLE
        unset UX_THEME UX_DEBUG
    #>
    foreach ($token in @($args)) {
        $name = [string]$token
        if ($name -eq '') { continue }
        if ($name.Length -gt 1 -and $name.StartsWith('-')) { continue }
        Remove-Item -LiteralPath ('Env:' + $name) -ErrorAction SilentlyContinue
    }
    $global:LASTEXITCODE = 0
}

function kill {
    <#
    .SYNOPSIS
        Terminate processes by PID (Stop-Process); -9 and -15 are accepted.
    .DESCRIPTION
        Signal numbers such as -9, -15 and -SIGKILL are accepted and ignored: Windows has no
        SIGTERM/SIGKILL distinction here, every signal maps to Stop-Process. A missing PID
        produces a Unix-style "No such process" error and $LASTEXITCODE = 1.

        Divergence: job control (kill %1), process groups and negative PIDs are not
        supported.
    .EXAMPLE
        kill -9 12345
    #>
    $targets = @()
    $failed = $false

    foreach ($token in @($args)) {
        $text = [string]$token
        if ($text.Length -gt 1 -and $text.StartsWith('-')) {
            # Signal number or signal name; accepted and ignored.
            continue
        }
        if ($text -match '^[0-9]+$') {
            $parsedId = -1L
            try { $parsedId = [long]$text } catch { $parsedId = -1 }
            if ($parsedId -lt 1 -or $parsedId -gt 2147483647) {
                Write-Error -Message ("kill: {0}: arguments must be process IDs" -f $text) -ErrorAction Continue
                $failed = $true
                continue
            }
            $targets += [int]$parsedId
            continue
        }
        Write-Error -Message ("kill: {0}: arguments must be process IDs" -f $text) -ErrorAction Continue
        $failed = $true
    }

    if ($targets.Count -eq 0) {
        Write-Error -Message 'kill: usage: kill [-9|-15] PID...' -ErrorAction Continue
        $global:LASTEXITCODE = 1
        return
    }

    foreach ($targetId in $targets) {
        $process = $null
        try { $process = Get-Process -Id $targetId -ErrorAction Stop } catch { $process = $null }
        if ($null -eq $process) {
            Write-Error -Message ("kill: ({0}) - No such process" -f $targetId) -ErrorAction Continue
            $failed = $true
            continue
        }
        try {
            Stop-Process -Id $targetId -Force -ErrorAction Stop
        } catch {
            Write-Error -Message ("kill: ({0}) - {1}" -f $targetId, $_.Exception.Message) -ErrorAction Continue
            $failed = $true
        }
    }

    if ($failed) { $global:LASTEXITCODE = 1 } else { $global:LASTEXITCODE = 0 }
}

function unzip {
    <#
    .SYNOPSIS
        Extract a zip archive (Expand-Archive), with -d DEST and -o overwrite.
    .DESCRIPTION
        -d names the destination directory (created when missing, like GNU unzip); with no
        -d the current directory is used. -o passes -Force to Expand-Archive so existing
        files are replaced; without -o an existing entry makes the extraction fail.

        Divergence: entry selection (unzip archive.zip file.txt) is not supported, because
        Expand-Archive cannot filter entries; the whole archive is always extracted, and a
        successful extraction is silent (no per-file listing). Expand-Archive also cannot
        extract into an existing destination whose name contains [ or ]; that is reported
        instead of silently extracting somewhere else.
    .EXAMPLE
        unzip -d /tmp/out /tmp/archive.zip
    .EXAMPLE
        unzip -o /tmp/archive.zip
    #>
    param(
        [switch]$Overwrite
    )

    $argv = ConvertFrom-UxArgv -Tokens $args -ValueFlags @('d') -AliasMap @{
        Directory   = 'd'
        Destination = 'd'
        Overwrite   = 'o'
    }
    $flags = @{}
    foreach ($key in $argv.Flags.Keys) { $flags[[string]$key] = $true }
    $values = @{}
    foreach ($key in $argv.Values.Keys) { $values[[string]$key] = [string]$argv.Values[$key] }
    if ($Overwrite) { $flags['o'] = $true }
    $doOverwrite = $flags.ContainsKey('o')

    $positional = @($argv.Positional)
    if ($positional.Count -lt 1) {
        Write-Error -Message 'unzip: usage: unzip [-d DEST] [-o] ARCHIVE' -ErrorAction Continue
        $global:LASTEXITCODE = 1
        return
    }
    if ($positional.Count -gt 1) {
        Write-Error -Message 'unzip: entry selection is not supported; extract the whole archive' -ErrorAction Continue
        $global:LASTEXITCODE = 1
        return
    }

    $archive = [string]$positional[0]
    $destination = '.'
    if ($values.ContainsKey('d')) { $destination = [string]$values['d'] }
    if ($destination -eq '') { $destination = '.' }

    $item = $null
    try { $item = Get-Item -LiteralPath $archive -ErrorAction Stop } catch { $item = $null }
    if ($null -eq $item) {
        Write-Error -Message ("unzip: cannot find or open {0}" -f $archive) -ErrorAction Continue
        $global:LASTEXITCODE = 1
        return
    }
    if ($item.PSIsContainer) {
        Write-Error -Message ("unzip: {0} is a directory" -f $archive) -ErrorAction Continue
        $global:LASTEXITCODE = 1
        return
    }

    try {
        # Expand-Archive creates a missing destination itself. Do not pre-create it:
        # when the directory already exists, Expand-Archive's own path handling treats
        # [brackets] in it as wildcards and fails with a confusing "already exists" error.
        if ((Test-Path -LiteralPath $destination -PathType Container) -and $destination -match '[\[\]]') {
            Write-Error -Message ("unzip: Expand-Archive cannot extract into the existing directory '{0}' because its name contains '[' or ']'; remove it first or choose another -d" -f $destination) -ErrorAction Continue
            $global:LASTEXITCODE = 1
            return
        }

        $expandArchive = @{
            LiteralPath      = [string]$item.FullName
            DestinationPath  = $destination
            ErrorAction      = 'Stop'
        }
        if ($doOverwrite) { $expandArchive['Force'] = $true }
        Expand-Archive @expandArchive | Out-Null
        $global:LASTEXITCODE = 0
    } catch {
        Write-Error -Message ("unzip: {0}" -f $_.Exception.Message) -ErrorAction Continue
        $global:LASTEXITCODE = 1
    }
}
