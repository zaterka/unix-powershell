#Requires -Version 5.1
#
# unix-powershell - lib/05-args.ps1
# ConvertFrom-UxArgv: the shared Unix-style argv tokenizer used by every wrapper.
#
# Why it exists (PLAN.md 5.1): a [CmdletBinding()] advanced function refuses unknown
# parameters ("A parameter cannot be found that matches parameter name 'rf'"), so every
# wrapper is a plain function and every unbound token - clustered flags included - arrives
# verbatim in $args. This tokenizer turns those tokens into a predictable structure.
#
#   ConvertFrom-UxArgv -Tokens $args [-ValueFlags @('n','name','type','d','t')] [-AliasMap @{ R='r' }]
#     -> @{ Flags = [ordered]@{}; Values = [ordered]@{}; Positional = @(); Problems = @() }
#
# Rules:
#   --                 ends flag parsing; the rest is positional
#   -                  a bare dash is a positional filename (Unix convention)
#   --long             Flags['long'] = $true
#   --long=value       Values['long'] = 'value'
#   --long value       Values['long'] = 'value' when 'long' is in -ValueFlags
#   -x                 Values['x'] = next token when 'x' is in -ValueFlags, else Flags['x']
#   -rf                cluster: one flag per character; a value flag must be last and
#                      consumes the next token
#   -9 / -15           an all-digit token is a flag, so `kill -9 PID` works
#   unknown flags      permissive: recorded as flags, never an error
#   -AliasMap          maps long/verbose names to their short form (--recursive -> r)
#
# It never throws: anything suspicious is appended to Problems (array of strings).
# Flags/Values are ordered so callers can report the first unknown flag deterministically.
#

function ConvertFrom-UxArgv {
    param(
        [Parameter(Position = 0)] $Tokens = @(),
        $ValueFlags = @(),
        $AliasMap = @{}
    )

    $flags = [ordered]@{}
    $values = [ordered]@{}
    $positional = @()
    $problems = @()

    # Normalise the token list. A single scalar token is accepted too.
    $tokenList = @()
    if ($null -ne $Tokens) {
        $inputCount = 0
        if ($Tokens -is [array]) { $inputCount = $Tokens.Count } else { $inputCount = 1 }
        if ($inputCount -gt 0) {
            foreach ($token in @($Tokens)) {
                if ($null -eq $token) { $tokenList += '' } else { $tokenList += [string]$token }
            }
        }
    }

    # Value-flag lookup set.
    $valueFlagSet = @{}
    if ($null -ne $ValueFlags) {
        if ($ValueFlags -is [string]) {
            $valueFlagSet[[string]$ValueFlags] = $true
        } else {
            foreach ($valueFlag in @($ValueFlags)) {
                if ($null -ne $valueFlag -and [string]$valueFlag -ne '') { $valueFlagSet[[string]$valueFlag] = $true }
            }
        }
    }

    # Alias map: long/verbose -> short form. Case-insensitive hashtable on purpose.
    $aliasLookup = @{}
    if ($null -ne $AliasMap) {
        if ($AliasMap -is [hashtable]) {
            foreach ($aliasKey in @($AliasMap.Keys)) {
                if ($null -eq $aliasKey) { continue }
                $aliasLookup[[string]$aliasKey] = [string]$AliasMap[$aliasKey]
            }
        } elseif ($AliasMap -is [string]) {
            # Accept a single "long=short" pair for convenience.
            $aliasText = [string]$AliasMap
            if ($aliasText -ne '') { $aliasLookup[$aliasText] = $aliasText }
        }
    }

    $count = $tokenList.Count
    $endOfFlags = $false
    $index = 0

    while ($index -lt $count) {
        $token = [string]$tokenList[$index]

        if ($endOfFlags) {
            $positional += ,$token
            $index = $index + 1
            continue
        }

        if ($token -eq '--') {
            $endOfFlags = $true
            $index = $index + 1
            continue
        }

        if ($token -eq '-') {
            # A bare dash is a filename (stdin placeholder), never a flag.
            $positional += ,$token
            $index = $index + 1
            continue
        }

        if ($token.Length -lt 2 -or -not $token.StartsWith('-')) {
            $positional += ,$token
            $index = $index + 1
            continue
        }

        # ---- long form: --name or --name=value ----
        if ($token.StartsWith('--')) {
            $body = $token.Substring(2)
            if ($body -eq '') {
                # Treated like a bare '--' terminator (defensive: '--' was handled above).
                $endOfFlags = $true
                $index = $index + 1
                continue
            }

            $equalsAt = $body.IndexOf('=')
            $longName = $body
            $longValue = $null
            $hasInlineValue = $false
            if ($equalsAt -ge 0) {
                $longName = $body.Substring(0, $equalsAt)
                $longValue = $body.Substring($equalsAt + 1)
                $hasInlineValue = $true
            }

            if ($aliasLookup.ContainsKey($longName)) {
                $mapped = [string]$aliasLookup[$longName]
                if ($mapped -ne '') { $longName = $mapped }
            }

            if ($hasInlineValue) {
                $values[$longName] = [string]$longValue
                $index = $index + 1
                continue
            }

            if ($valueFlagSet.ContainsKey($longName)) {
                if (($index + 1) -lt $count) {
                    $values[$longName] = [string]$tokenList[$index + 1]
                    $index = $index + 2
                } else {
                    $problems += ('option --' + $longName + ' requires a value')
                    $index = $index + 1
                }
                continue
            }

            $flags[$longName] = $true
            $index = $index + 1
            continue
        }

        # ---- short form (single dash, at least two characters) ----
        $body = $token.Substring(1)

        # -9 / -15 / -123: numeric flags (kill signals).
        if ($body -match '^[0-9]+$') {
            $flags[$body] = $true
            $index = $index + 1
            continue
        }

        # A whole-token value flag: -name 3, -type d (helpful beyond strict clusters).
        if ($valueFlagSet.ContainsKey($body)) {
            if (($index + 1) -lt $count) {
                $values[$body] = [string]$tokenList[$index + 1]
                $index = $index + 2
            } else {
                $problems += ('option -' + $body + ' requires a value')
                $index = $index + 1
            }
            continue
        }

        # A whole-token alias (verbose single-dash form): -recursive -> r.
        if ($aliasLookup.ContainsKey($body)) {
            $mapped = [string]$aliasLookup[$body]
            if ($mapped -ne '') {
                if ($valueFlagSet.ContainsKey($mapped)) {
                    if (($index + 1) -lt $count) {
                        $values[$mapped] = [string]$tokenList[$index + 1]
                        $index = $index + 2
                    } else {
                        $problems += ('option -' + $body + ' requires a value')
                        $index = $index + 1
                    }
                } else {
                    $flags[$mapped] = $true
                    $index = $index + 1
                }
                continue
            }
        }

        # Cluster: -rf, -la, -rfv ...
        $chars = $body.ToCharArray()
        $charCount = $chars.Count
        $consumedNext = $false
        for ($charIndex = 0; $charIndex -lt $charCount; $charIndex++) {
            $charText = [string]$chars[$charIndex]
            $isLast = ($charIndex -eq ($charCount - 1))

            if ($valueFlagSet.ContainsKey($charText)) {
                if (-not $isLast) {
                    $problems += ('option -' + $charText + ' in cluster -' + $body + ' must be the last character')
                }
                if (($index + 1) -lt $count) {
                    $values[$charText] = [string]$tokenList[$index + 1]
                    $consumedNext = $true
                } else {
                    $problems += ('option -' + $charText + ' requires a value')
                }
                break
            }

            $flags[$charText] = $true
        }

        if ($consumedNext) {
            $index = $index + 2
        } else {
            $index = $index + 1
        }
    }

    # [ordered]@{...} is an OrderedDictionary: it preserves insertion order (so callers can
    # report the first unknown flag) but it only exposes Contains(), not ContainsKey().
    # The published contract - and every caller asking "was -r given?" - uses ContainsKey,
    # so add it as a script method. Plain wrapper code never notices the ~0.2 ms; if the host
    # refuses (ConstrainedLanguage), ordering still works and Contains() remains available.
    foreach ($map in @($flags, $values)) {
        try {
            Add-Member -InputObject $map -MemberType ScriptMethod -Name 'ContainsKey' -Force -ErrorAction Stop -Value {
                param($key)
                return $this.Contains($key)
            }
        } catch { }
    }

    return @{
        Flags      = $flags
        Values     = $values
        Positional = $positional
        Problems   = $problems
    }
}
