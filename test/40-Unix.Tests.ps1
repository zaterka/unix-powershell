#Requires -Version 5.1
<#
    Pester 5 suite for the Unix command layer (lib/30-unix.ps1, 19 wrappers).

    Why the wrapper design is the thing under test:

      Every wrapper is a PLAIN function with an optional param() block for a few
      [switch] names, and it tokenises whatever is left in $args with
      ConvertFrom-UxArgv (lib/05-args.ps1). That is the only way "-rf", "-la",
      "-9" and "-5" can work: a [CmdletBinding()] function rejects an unknown
      parameter name at binding time, before the function body runs. So the
      clustered-flag cases below are the highest-value tests in this file, and
      the last Describe asserts CmdletBinding is false for all 19 wrappers (the
      guard against "fixing" a wrapper by adding [CmdletBinding()]).

    Environment notes that shape the assertions:

      * The suite runs on Linux (Docker, amd64) and on Windows PowerShell 5.1.
        Nothing here depends on a shell alias being absent, because aliases
        resolve before functions: the wrappers are called by name and the one
        shadowed name (cd is an alias for Set-Location) is inspected through
        Get-Command -CommandType Function instead of being invoked.
      * All fixtures live under $TestDrive; the repository checkout is mounted
        read-only, so nothing is written outside the test drive.
      * Windows-specific behaviour is chosen from env:OS (the IsWindows
        automatic variable does not exist on 5.1) rather than assumed, so the
        same file runs on both targets: the HOME vs USERPROFILE variable name,
        C:\ vs / as the drive root, and the child process used by kill -9.
      * kill -9 is the only test that waits on a process, because a terminated
        process needs a moment to disappear. Everything else is deterministic
        without sleeps, including touch, which uses an explicit timestamp.
#>

BeforeAll {
    $script:Root = Split-Path -Parent $PSScriptRoot
    if (-not $script:Root) { $script:Root = Split-Path -Parent $MyInvocation.MyCommand.Path }

    . (Join-Path -Path $script:Root -ChildPath 'lib/05-args.ps1')
    . (Join-Path -Path $script:Root -ChildPath 'lib/30-unix.ps1')

    $script:Fx = Join-Path $TestDrive 'fx'
    $script:Sub = Join-Path $script:Fx 'sub'
    $script:Deeper = Join-Path $script:Sub 'deeper'
    $script:Tree = Join-Path $script:Fx 'tree'
    $script:Leaf = Join-Path $script:Tree 'leaf'

    New-Item -ItemType Directory -Path $script:Fx -Force | Out-Null
    New-Item -ItemType Directory -Path $script:Deeper -Force | Out-Null
    New-Item -ItemType Directory -Path $script:Leaf -Force | Out-Null

    Set-Content -LiteralPath (Join-Path $script:Fx 'a.txt') -Value @('alpha', 'Beta', 'gamma')
    Set-Content -LiteralPath (Join-Path $script:Fx '.hidden.txt') -Value @('hidden')
    Set-Content -LiteralPath (Join-Path $script:Fx '[brackets].txt') -Value @('one', 'two', 'three')
    Set-Content -LiteralPath (Join-Path $script:Fx '-weird.txt') -Value @('weird content')
    Set-Content -LiteralPath (Join-Path $script:Fx 'regex.txt') -Value @('aab', 'zzz')
    Set-Content -LiteralPath (Join-Path $script:Sub 'deep.txt') -Value @('betamax', 'delta')
    Set-Content -LiteralPath (Join-Path $script:Deeper 'inner.txt') -Value @('delta')
    Set-Content -LiteralPath (Join-Path $script:Leaf 'f.txt') -Value @('leaf-content')

    $numbers = @()
    for ($line = 1; $line -le 10; $line++) { $numbers += ('line' + $line) }
    Set-Content -LiteralPath (Join-Path $script:Fx 'nums.txt') -Value $numbers

    function script:Get-UxUnixTestText {
        param($Items)
        $parts = @()
        foreach ($item in @($Items)) {
            if ($null -eq $item) { continue }
            $parts += [string]$item
        }
        return ($parts -join "`n")
    }

    function script:Test-UxUnixTestBindingError {
        param([string]$Text)
        # A [CmdletBinding()] wrapper fails with "A parameter cannot be found that
        # matches parameter name 'rf'". A plain wrapper never does.
        if ($Text -match 'cannot be found that matches parameter name') { return $true }
        if ($Text -match 'ParameterBindingException') { return $true }
        return $false
    }

    function script:Get-UxUnixTestLeaf {
        param($Items)
        $leaves = @()
        foreach ($item in @($Items)) {
            if ($null -eq $item) { continue }
            $leaves += [string](Split-Path -Leaf ([string]$item))
        }
        return $leaves
    }
}

AfterAll {
    # Environment variable the export/unset round-trip may leave behind if an
    # assertion failed before unset ran.
    Remove-Item -LiteralPath 'Env:UX_TEST_ROUNDTRIP' -ErrorAction SilentlyContinue
}

Describe 'Clustered flags: the cases a [CmdletBinding()] wrapper cannot support' {
    It 'rm -rf removes a non-empty directory tree' {
        $target = Join-Path $TestDrive 'rmrf-tree'
        New-Item -ItemType Directory -Path (Join-Path $target 'nested') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $target 'nested/payload.txt') -Value 'payload'

        $captured = @(& rm -rf $target 2>&1)
        $text = script:Get-UxUnixTestText -Items $captured

        script:Test-UxUnixTestBindingError -Text $text | Should -BeFalse -Because 'a plain function passes the -rf cluster to the tokeniser instead of failing parameter binding'
        $text | Should -Be '' -Because 'a successful rm -rf is silent, like unix rm'
        Test-Path -LiteralPath $target | Should -BeFalse
        $LASTEXITCODE | Should -Be 0
    }

    It 'ls -la lists hidden items and still returns objects' {
        $items = @(& ls -la $script:Fx)
        $names = @($items | ForEach-Object { [string]$_.Name })

        $names -contains '.hidden.txt' | Should -BeTrue -Because '-a (the cluster tail of -la) maps to Get-ChildItem -Force'
        $names -contains 'a.txt' | Should -BeTrue
        foreach ($item in $items) {
            $typeName = [string]$item.GetType().Name
            (($typeName -eq 'FileInfo') -or ($typeName -eq 'DirectoryInfo')) | Should -BeTrue -Because 'ls -l is a no-op that keeps passing real items through'
        }

        $captured = @(& ls -la $script:Fx 2>&1)
        script:Test-UxUnixTestBindingError -Text (script:Get-UxUnixTestText -Items $captured) | Should -BeFalse
        $LASTEXITCODE | Should -Be 0
    }

    It 'kill -9 terminates a process by PID' {
        # A child process to signal: /bin/sleep where it exists (fast), otherwise the
        # current host's own executable, so this also runs on Windows PowerShell 5.1
        # (the Windows target) instead of being skipped there.
        $childPath = ''
        $childArgs = @()
        if (Test-Path -LiteralPath '/bin/sleep') {
            $childPath = '/bin/sleep'
            $childArgs = @('300')
        } else {
            try { $childPath = [string](Get-Process -Id $PID).Path } catch { $childPath = '' }
            $childArgs = @('-NoProfile', '-Command', 'Start-Sleep -Seconds 300')
        }
        $childPath | Should -Not -BeNullOrEmpty -Because 'the kill test needs an executable it can start and then terminate'

        $child = Start-Process -FilePath $childPath -ArgumentList $childArgs -PassThru
        try {
            # Inherent to the behaviour: the child must exist as a running process
            # before the signal can be observed to work.
            Start-Sleep -Milliseconds 200

            $captured = @(& kill -9 $child.Id 2>&1)
            $text = script:Get-UxUnixTestText -Items $captured

            script:Test-UxUnixTestBindingError -Text $text | Should -BeFalse -Because '-9 is a numeric flag, not a parameter name'
            $LASTEXITCODE | Should -Be 0

            # And the process must actually be gone; polling needs a bounded wait.
            $gone = $false
            for ($attempt = 0; $attempt -lt 20; $attempt++) {
                $alive = Get-Process -Id $child.Id -ErrorAction SilentlyContinue
                if ($null -eq $alive) { $gone = $true; break }
                Start-Sleep -Milliseconds 100
            }
            $gone | Should -BeTrue -Because 'kill -9 maps to Stop-Process -Force'
        } finally {
            # Never leave a stray sleep process behind if an assertion failed early.
            if ($null -ne $child) {
                Get-Process -Id $child.Id -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
            }
        }
    }




    It 'head -5 prints the first five lines (numeric cluster flag)' {
        $captured = @(& head -5 (Join-Path $script:Fx 'nums.txt') 2>&1)
        $text = script:Get-UxUnixTestText -Items $captured

        script:Test-UxUnixTestBindingError -Text $text | Should -BeFalse
        @($captured).Count | Should -Be 5
        [string]$captured[0] | Should -Be 'line1'
        [string]$captured[4] | Should -Be 'line5' -Because 'the short GNU form -5 means -n 5'
        $LASTEXITCODE | Should -Be 0
    }
}

Describe 'ls: object output' {
    It 'returns FileInfo/DirectoryInfo objects, never strings' {
        $items = @(& ls $script:Fx)

        $items.Count | Should -BeGreaterThan 0
        foreach ($item in $items) {
            $typeName = [string]$item.GetType().Name
            (($typeName -eq 'FileInfo') -or ($typeName -eq 'DirectoryInfo')) | Should -BeTrue -Because 'ls must stay pipeline-friendly'
        }
        $LASTEXITCODE | Should -Be 0
    }

    It 'ls -1 returns names as strings' {
        $names = @(& ls -1 $script:Fx)

        $names.Count | Should -BeGreaterThan 0
        foreach ($name in $names) {
            [string]$name.GetType().Name | Should -Be 'String'
        }
        $names -contains 'a.txt' | Should -BeTrue
    }

    It 'ls -a includes dotfiles and plain ls does not' {
        $withHidden = @(& ls -a $script:Fx | ForEach-Object { [string]$_.Name })
        $withoutHidden = @(& ls $script:Fx | ForEach-Object { [string]$_.Name })

        $withHidden -contains '.hidden.txt' | Should -BeTrue
        $withoutHidden -contains '.hidden.txt' | Should -BeFalse
    }

    It 'ls -R recurses into subdirectories' {
        $names = @(& ls -R $script:Fx | ForEach-Object { [string]$_.Name })

        $names -contains 'deep.txt' | Should -BeTrue
        $names -contains 'inner.txt' | Should -BeTrue -Because '-R has to recurse more than one level'
    }

    It 'ls -d returns the directory item itself' {
        $items = @(& ls -d $script:Fx)

        $items.Count | Should -Be 1
        $items[0].PSIsContainer | Should -BeTrue
        [string]$items[0].FullName | Should -Be ([string](Get-Item -LiteralPath $script:Fx).FullName)
    }

    It 'ls -l | Select-Object -First 3 still yields pipeline objects' {
        $three = @(& ls -l $script:Fx | Select-Object -First 3)

        $three.Count | Should -Be 3
        foreach ($item in $three) {
            $typeName = [string]$item.GetType().Name
            (($typeName -eq 'FileInfo') -or ($typeName -eq 'DirectoryInfo')) | Should -BeTrue -Because 'a wrapper that emitted formatted text would break the pipeline here'
        }
    }

    It 'll and la forward their arguments to ls' {
        $longNames = @(& ll $script:Fx | ForEach-Object { [string]$_.Name })
        $allNames = @(& la $script:Fx | ForEach-Object { [string]$_.Name })

        $longNames -contains '.hidden.txt' | Should -BeFalse -Because 'll is ls -l, and -l alone does not show dotfiles'
        $allNames -contains '.hidden.txt' | Should -BeTrue -Because 'la is ls -la, so the forwarded -a must survive the extra hop'
    }

    It 'reports a missing path as an error with a non-zero last exit code' {
        $captured = @(& ls (Join-Path $script:Fx 'does-not-exist') 2>&1)
        $text = script:Get-UxUnixTestText -Items $captured

        $text | Should -Match 'cannot access'
        $LASTEXITCODE | Should -Be 1
    }
}

Describe 'cat: concatenation, numbering and literal paths' {


    It 'reads a file whose name contains [brackets] (proves -LiteralPath)' {
        $lines = @(& head -n 5 (Join-Path $script:Fx '[brackets].txt'))

        @($lines).Count | Should -Be 3
        [string]$lines[0] | Should -Be 'one'
        $LASTEXITCODE | Should -Be 0
    }

    It 'reports a missing file and sets a non-zero last exit code' {
        $captured = @(& head -n 5 (Join-Path $script:Fx 'nope.txt') 2>&1)
        $text = script:Get-UxUnixTestText -Items $captured

        $text | Should -Match 'No such file'
        $LASTEXITCODE | Should -Be 1
    }
}

Describe 'head and tail' {
    It 'head -n 2 reads a file' {
        $lines = @(& head -n 2 (Join-Path $script:Fx 'nums.txt'))

        @($lines).Count | Should -Be 2
        [string]$lines[0] | Should -Be 'line1'
        [string]$lines[1] | Should -Be 'line2'
    }

    It 'head -n 2 works on pipeline input' {
        $lines = @(Get-Content -LiteralPath (Join-Path $script:Fx 'nums.txt') | head -n 2)

        @($lines).Count | Should -Be 2
        [string]$lines[0] | Should -Be 'line1'
        [string]$lines[1] | Should -Be 'line2'
    }

    It 'tail -n 1 returns the last line of a file' {
        $lines = @(& tail -n 1 (Join-Path $script:Fx 'nums.txt'))

        @($lines).Count | Should -Be 1
        [string]$lines[0] | Should -Be 'line10'
    }

    It 'tail -n 2 works on pipeline input' {
        $lines = @(Get-Content -LiteralPath (Join-Path $script:Fx 'nums.txt') | tail -n 2)

        @($lines).Count | Should -Be 2
        [string]$lines[0] | Should -Be 'line9'
        [string]$lines[1] | Should -Be 'line10'
    }
}

Describe 'wc: counts' {
    It 'wc -l counts lines in a file' {
        $out = @(& wc -l (Join-Path $script:Fx 'nums.txt'))

        [string]$out[0] | Should -Match '^\s*10\s'
        [string]$out[0] | Should -Match 'nums\.txt'
        $LASTEXITCODE | Should -Be 0
    }

    It 'wc -w counts words in a file' {
        $out = @(& wc -w (Join-Path $script:Fx 'nums.txt'))

        [string]$out[0] | Should -Match '^\s*10\s'
    }

    It 'wc -c reports the real byte length of a file' {
        $path = Join-Path $script:Fx 'a.txt'
        $length = (Get-Item -LiteralPath $path).Length
        $out = @(& wc -c $path)

        [string]$out[0] | Should -Match ('^\s*' + $length + '\s') -Because '-c must be the byte count from Length, not a character guess'
    }

    It 'piped input counts characters for -c (documented divergence) and lines for -l' {
        $path = Join-Path $script:Fx 'nums.txt'
        $content = @(Get-Content -LiteralPath $path)
        $expectedChars = 0
        foreach ($line in $content) { $expectedChars = $expectedChars + ([string]$line).Length }

        $bytes = @(Get-Content -LiteralPath $path | wc -c)
        $lines = @(Get-Content -LiteralPath $path | wc -l)

        ([string]$bytes[0]).Trim() | Should -Be ([string]$expectedChars) -Because 'text on the pipeline has already lost its byte representation'
        ([string]$lines[0]).Trim() | Should -Be ([string]$content.Count)
    }
}

Describe 'grep: unix matching semantics' {
    It 'is case-sensitive by default' {
        $out = @(& grep 'beta' (Join-Path $script:Fx 'a.txt'))

        @($out).Count | Should -Be 0 -Because 'the file has "Beta"; a lowercase pattern must not match it'
        $LASTEXITCODE | Should -Be 1
    }

    It '-i ignores case' {
        $out = @(& grep -i 'beta' (Join-Path $script:Fx 'a.txt'))
        $text = script:Get-UxUnixTestText -Items $out

        $text | Should -Match 'Beta'
        $LASTEXITCODE | Should -Be 0
    }

    It '-v inverts the match' {
        $out = @(& grep -v 'Beta' (Join-Path $script:Fx 'a.txt'))
        $text = script:Get-UxUnixTestText -Items $out

        $text | Should -Match 'alpha'
        $text | Should -Match 'gamma'
        $text | Should -Not -Match 'Beta'
        $LASTEXITCODE | Should -Be 0
    }

    It '-n prefixes line numbers' {
        $out = @(& grep -n 'gamma' (Join-Path $script:Fx 'a.txt'))
        $text = script:Get-UxUnixTestText -Items $out

        $text | Should -Match 'a\.txt:3: gamma'
    }

    It '-r recurses a directory' {
        $out = @(& grep -r 'delta' $script:Fx)
        $text = script:Get-UxUnixTestText -Items $out

        $text | Should -Match 'deep\.txt'
        $text | Should -Match 'inner\.txt'
        $LASTEXITCODE | Should -Be 0
    }

    It '-c counts matching lines' {
        $out = @(& grep -c 'delta' (Join-Path $script:Sub 'deep.txt'))

        ([string]$out[0]).Trim() | Should -Be '1'
    }

    It '-q sets the exit code and prints nothing' {
        $noMatch = @(& grep -q 'zzz-nothing-here' (Join-Path $script:Fx 'a.txt'))
        @($noMatch).Count | Should -Be 0
        $LASTEXITCODE | Should -Be 1

        $match = @(& grep -q 'alpha' (Join-Path $script:Fx 'a.txt'))
        @($match).Count | Should -Be 0
        $LASTEXITCODE | Should -Be 0
    }

    It 'is literal by default and -E switches to .NET regex' {
        $path = Join-Path $script:Fx 'regex.txt'

        $literal = @(& grep 'a+b' $path)
        @($literal).Count | Should -Be 0 -Because 'the default is a literal string search, so "a+b" must not match "aab"'
        $LASTEXITCODE | Should -Be 1

        $regex = @(& grep -E 'a+b' $path)
        $text = script:Get-UxUnixTestText -Items $regex
        $text | Should -Match 'aab' -Because '-E turns the pattern into a .NET regex'
        $LASTEXITCODE | Should -Be 0
    }
}

Describe 'find: name and type filters' {
    It 'find NAME -name *.txt returns matches at the top level and nested' {
        $out = @(& find $script:Fx -name '*.txt')
        $leaves = script:Get-UxUnixTestLeaf -Items $out

        $leaves -contains 'a.txt' | Should -BeTrue -Because 'a top-level match must not be lost (the -Include-without-Recurse bug)'
        $leaves -contains 'deep.txt' | Should -BeTrue -Because 'a nested match must be found too'
        $leaves -contains 'inner.txt' | Should -BeTrue
        $LASTEXITCODE | Should -Be 0
    }

    It 'find -type d returns only directories, and prints full paths' {
        $out = @(& find $script:Fx -type d)

        @($out).Count | Should -BeGreaterThan 0
        foreach ($entry in $out) {
            Test-Path -LiteralPath ([string]$entry) -PathType Container | Should -BeTrue -Because '-type d must not return files'
            ([string]$entry).StartsWith($script:Fx) | Should -BeTrue -Because 'find prints full paths, not relative names'
        }
        $LASTEXITCODE | Should -Be 0
    }

    It 'sets the exit code to 1 when nothing matches' {
        $out = @(& find $script:Fx -name 'no-such-name-*.txt')

        @($out).Count | Should -Be 0
        $LASTEXITCODE | Should -Be 1
    }

    It 'reports a missing starting path with exit code 2' {
        $captured = @(& find (Join-Path $TestDrive 'no-such-dir') -name '*.txt' 2>&1)
        $text = script:Get-UxUnixTestText -Items $captured

        $text | Should -Match 'No such file or directory'
        $LASTEXITCODE | Should -Be 2
    }
}

Describe 'mkdir: -p and the plain form' {
    It 'mkdir -p creates nested parents' {
        $target = Join-Path $TestDrive 'mkp/a/b/c'

        $captured = @(& mkdir -p $target 2>&1)
        script:Test-UxUnixTestBindingError -Text (script:Get-UxUnixTestText -Items $captured) | Should -BeFalse

        Test-Path -LiteralPath $target -PathType Container | Should -BeTrue
        $LASTEXITCODE | Should -Be 0
    }

    It 'mkdir -p does not error when the directory already exists' {
        $target = Join-Path $TestDrive 'mkp-again/a/b'
        & mkdir -p $target
        $captured = @(& mkdir -p $target 2>&1)

        @($captured).Count | Should -Be 0 -Because '-p is idempotent, like mkdir -p'
        $LASTEXITCODE | Should -Be 0
    }

    It 'mkdir without -p treats an existing directory as an error' {
        $target = Join-Path $TestDrive 'mkplain'
        & mkdir $target
        $captured = @(& mkdir $target 2>&1)
        $text = script:Get-UxUnixTestText -Items $captured

        $text | Should -Match 'File exists'
        $LASTEXITCODE | Should -Be 1
    }

    It 'mkdir without -p refuses to invent a missing parent' {
        $captured = @(& mkdir (Join-Path $TestDrive 'noparent/child') 2>&1)
        $text = script:Get-UxUnixTestText -Items $captured

        $text | Should -Match 'No such file or directory'
        $LASTEXITCODE | Should -Be 1
    }
}

Describe 'touch: create and timestamp' {
    It 'creates a missing file' {
        $target = Join-Path $TestDrive 'touched-new.txt'
        Remove-Item -LiteralPath $target -ErrorAction SilentlyContinue

        & touch $target

        Test-Path -LiteralPath $target -PathType Leaf | Should -BeTrue
        $LASTEXITCODE | Should -Be 0
    }

    It 'updates the timestamp of an existing file (explicit old value, no sleeping)' {
        $target = Join-Path $TestDrive 'touched-old.txt'
        Set-Content -LiteralPath $target -Value 'x'
        $old = Get-Date '2001-02-03T04:05:06'
        (Get-Item -LiteralPath $target).LastWriteTime = $old
        $before = (Get-Item -LiteralPath $target).LastWriteTime

        & touch $target

        $after = (Get-Item -LiteralPath $target).LastWriteTime
        $after | Should -BeGreaterThan $before -Because 'touch bumps LastWriteTime to now'
        $after.Year | Should -BeGreaterThan 2001
        $LASTEXITCODE | Should -Be 0
    }
}

Describe 'cp, mv and rm' {


    It 'mv -f overwrites an existing target' {
        $source = Join-Path $TestDrive 'mv-source.txt'
        $target = Join-Path $TestDrive 'mv-target.txt'
        Set-Content -LiteralPath $source -Value 'new'
        Set-Content -LiteralPath $target -Value 'old'

        $captured = @(& mv -f $source $target 2>&1)
        script:Test-UxUnixTestBindingError -Text (script:Get-UxUnixTestText -Items $captured) | Should -BeFalse

        (Get-Content -LiteralPath $target) | Should -Be 'new' -Because '-f removes the destination first, which 5.1 Move-Item -Force refuses to do'
        Test-Path -LiteralPath $source | Should -BeFalse
        $LASTEXITCODE | Should -Be 0
    }

    It 'mv without -f refuses to overwrite (documented divergence from GNU mv)' {
        $source = Join-Path $TestDrive 'mv-source2.txt'
        $target = Join-Path $TestDrive 'mv-target2.txt'
        Set-Content -LiteralPath $source -Value 'new'
        Set-Content -LiteralPath $target -Value 'old'

        $captured = @(& mv $source $target 2>&1)
        $text = script:Get-UxUnixTestText -Items $captured

        $text | Should -Match 'destination exists'
        (Get-Content -LiteralPath $target) | Should -Be 'old'
        $LASTEXITCODE | Should -Be 1
    }

    It 'rm -r removes a tree' {
        $target = Join-Path $TestDrive 'rm-r-tree'
        New-Item -ItemType Directory -Path (Join-Path $target 'inner') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $target 'inner/f.txt') -Value 'x'

        $captured = @(& rm -r $target 2>&1)
        script:Test-UxUnixTestBindingError -Text (script:Get-UxUnixTestText -Items $captured) | Should -BeFalse

        Test-Path -LiteralPath $target | Should -BeFalse
        $LASTEXITCODE | Should -Be 0
    }

    It 'rm refuses a directory without -r instead of prompting' {
        $target = Join-Path $TestDrive 'rm-plain-dir'
        New-Item -ItemType Directory -Path $target -Force | Out-Null

        $captured = @(& rm $target 2>&1)
        $text = script:Get-UxUnixTestText -Items $captured

        $text | Should -Match 'Is a directory'
        Test-Path -LiteralPath $target | Should -BeTrue
        $LASTEXITCODE | Should -Be 1
    }
}

Describe 'rm: safety refusals' {
    It 'refuses a drive or share root' {
        $root = '/'
        if ($env:OS -eq 'Windows_NT') { $root = 'C:\' }

        $captured = @(& rm -r $root 2>&1)
        $text = script:Get-UxUnixTestText -Items $captured

        $text | Should -Match 'refusing to remove'
        $LASTEXITCODE | Should -Be 1
        Test-Path -LiteralPath $root | Should -BeTrue
    }

    It 'refuses the home directory' {
        $homeDirectory = [string]$HOME
        if ($homeDirectory -eq '') { $homeDirectory = [string]$env:USERPROFILE }
        $homeDirectory | Should -Not -BeNullOrEmpty -Because 'the refusal can only be tested where a home directory is known'

        $captured = @(& rm -r $homeDirectory 2>&1)
        $text = script:Get-UxUnixTestText -Items $captured

        $text | Should -Match 'home directory'
        $LASTEXITCODE | Should -Be 1
        Test-Path -LiteralPath $homeDirectory | Should -BeTrue -Because 'the refusal must happen before Remove-Item runs'
    }
}

Describe 'which, env, export, unset, ps and unzip' {
    It 'which resolves a cmdlet' {
        $out = @(& which Get-ChildItem)
        $text = script:Get-UxUnixTestText -Items $out

        $text | Should -Match 'cmdlet'
        $LASTEXITCODE | Should -Be 0
    }

    It 'which resolves a function' {
        $out = @(& which ls)

        [string]$out[0] | Should -Be 'ls: function'
        $LASTEXITCODE | Should -Be 0
    }

    It 'which reports an unknown name with a non-zero exit code' {
        $captured = @(& which 'ux-no-such-command-xyz' 2>&1)
        $text = script:Get-UxUnixTestText -Items $captured

        $text | Should -Match 'no ux-no-such-command-xyz in'
        $LASTEXITCODE | Should -Be 1
    }

    It 'env prints NAME=VALUE lines' {
        $out = @(& env)

        $out.Count | Should -BeGreaterThan 0
        $labelled = @($out | Where-Object { [string]$_ -match '^[^=]+=' })
        $labelled.Count | Should -Be $out.Count -Because 'every env line is NAME=VALUE'
    }

    It 'env filters by name' {
        $name = 'HOME'
        if ($env:OS -eq 'Windows_NT') { $name = 'USERPROFILE' }

        $out = @(& env $name)

        @($out).Count | Should -Be 1
        [string]$out[0] | Should -Match ('^' + $name + '=')
    }

    It 'export then unset round-trips an environment variable' {
        & export 'UX_TEST_ROUNDTRIP=hello world'

        $env:UX_TEST_ROUNDTRIP | Should -Be 'hello world' -Because 'everything after the first = is the value'
        [string](@(& env UX_TEST_ROUNDTRIP)[0]) | Should -Be 'UX_TEST_ROUNDTRIP=hello world'
        $LASTEXITCODE | Should -Be 0

        & unset UX_TEST_ROUNDTRIP

        Test-Path -LiteralPath Env:UX_TEST_ROUNDTRIP | Should -BeFalse
        $LASTEXITCODE | Should -Be 0
    }

    It 'unzip -d extracts an archive into the named directory' {
        $source = Join-Path $TestDrive 'zip-src'
        New-Item -ItemType Directory -Path $source -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $source 'inside.txt') -Value 'zipped'
        $archive = Join-Path $TestDrive 'archive.zip'
        Compress-Archive -Path (Join-Path $source 'inside.txt') -DestinationPath $archive -Force

        $destination = Join-Path $TestDrive 'unzipped'
        $captured = @(& unzip -d $destination $archive 2>&1)
        script:Test-UxUnixTestBindingError -Text (script:Get-UxUnixTestText -Items $captured) | Should -BeFalse

        $LASTEXITCODE | Should -Be 0
        (Get-Content -LiteralPath (Join-Path $destination 'inside.txt')) | Should -Be 'zipped'
    }
}

Describe 'Object passthrough discipline' {
    It 'ls and ps emit domain objects, never Format-* wrappers' {
        $items = @(& ls $script:Fx)
        $items += @(& ps)

        $items.Count | Should -BeGreaterThan 0
        foreach ($item in $items) {
            $typeName = [string]$item.GetType().Name
            $typeName | Should -Not -Match '^Format' -Because 'formatting at the wrapper level would break Select-Object and Where-Object'
            $typeName | Should -Not -Be 'PSObject'
        }
    }
}

Describe 'Every wrapper is a plain (non-advanced) function' {
    It '<Name> has CmdletBinding = false' -ForEach @(
        @{ Name = 'ls' }
        @{ Name = 'll' }
        @{ Name = 'la' }
        @{ Name = 'cd' }
        @{ Name = 'touch' }
        @{ Name = 'mkdir' }
        @{ Name = 'rm' }
        @{ Name = 'mv' }
        @{ Name = 'grep' }
        @{ Name = 'find' }
        @{ Name = 'head' }
        @{ Name = 'tail' }
        @{ Name = 'wc' }
        @{ Name = 'which' }
        @{ Name = 'env' }
        @{ Name = 'export' }
        @{ Name = 'unset' }
        @{ Name = 'kill' }
        @{ Name = 'unzip' }
    ) {
        # -CommandType Function on purpose: on a stock host cd is still an alias for
        # Set-Location, and the alias would otherwise hide the wrapper.
        $command = Get-Command -Name $Name -CommandType Function -ErrorAction SilentlyContinue

        $command | Should -Not -BeNullOrEmpty -Because 'all 19 wrappers must be defined by lib/30-unix.ps1'
        [string]$command.CommandType | Should -Be 'Function'
        $command.CmdletBinding | Should -BeFalse -Because 'adding [CmdletBinding()] turns -rf, -la, -9 and -5 into parameter-binding errors'
    }
}
