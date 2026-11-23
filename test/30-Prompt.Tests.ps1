#Requires -Version 5.1
<#
    Pester 5 suite for the prompt engine (lib/20-prompt.ps1).

    Contract under test (PLAN.md 5.3):
      Format-UxPrompt         PURE   model -> array of @{ Text; Color; Vt }
      Get-UxPromptModel              session state + config + git -> model
      Write-UxPromptSegments         the only function that writes to the host
      prompt                         capture status -> model -> render -> emit -> ' '

    Design notes that shaped the assertions below:

      * Every theme is pure ASCII and stock-font safe, so the ASCII sweep is a
        table over 4 themes x 3 modes instead of a spot check.
      * Text is the visible prompt; Mode only blanks the Vt field. A mode must
        never change Text, so every cell of the matrix is compared against the
        Plain render of the same model.
      * Width truncation is the one thing allowed to change Text, and it applies
        in every mode, so the width assertions run on the concatenated Text and
        measure the longest visible line.
      * Format-UxPrompt never reads git or session state: the git segment is
        driven from the model. That is what makes the git cases (dirty, ahead,
        unborn, not-a-repo, unknown-dirty) deterministic without a fixture repo.
      * $LASTEXITCODE preservation has its own test, because the prompt's own git
        call is exactly what clobbers it: the test installs a *global* git stub
        that runs a native command exiting 7, so a missing restore shows up as 7.
      * prompt renders through the host, so the fallback path is asserted on the
        information stream (Write-Host) with 6>&1, never on the success stream.

    Everything here runs on Linux and on Windows PowerShell 5.1. The one test that
    needs a native exit code picks cmd.exe or /bin/sh from env:OS, so it skips only
    on a host that has neither.
#>

BeforeAll {
    $script:Root = Split-Path -Parent $PSScriptRoot
    if (-not $script:Root) { $script:Root = Split-Path -Parent $MyInvocation.MyCommand.Path }

    . (Join-Path -Path $script:Root -ChildPath 'lib/20-prompt.ps1')

    $script:PromptThemes = @('ascii', 'classic', 'blocks', 'two-line')
    $script:PromptModes = @('Vt', 'Console', 'Plain')
    $script:FakeHome = '/tmp/ux-prompt-home'

    # Global state the tests may replace; restored in AfterAll.
    $script:SavedUx = $null
    $savedVar = Get-Variable -Name 'Ux' -Scope Global -ErrorAction SilentlyContinue
    if ($null -ne $savedVar) { $script:SavedUx = $savedVar.Value }

    function script:New-UxPromptTestModel {
        param(
            [string]$Path = '~/repo',
            $Git = $null,
            [int]$LastExit = 0,
            [bool]$LastOk = $true,
            [bool]$ShowHost = $true,
            [bool]$ShowTime = $false,
            [string]$PathStyle = 'full'
        )
        return @{
            User      = 'pedro'
            Host      = 'winbox'
            Path      = $Path
            Git       = $Git
            Time      = '09:30'
            LastExit  = $LastExit
            LastOk    = $LastOk
            Symbol    = '$'
            Width     = 120
            PathStyle = $PathStyle
            ShowUser  = $true
            ShowHost  = $ShowHost
            ShowTime  = $ShowTime
            ShowGit   = $true
            ShowExit  = $true
        }
    }

    function script:Get-UxPromptTestText {
        param($Segments)
        $parts = @()
        foreach ($segment in @($Segments)) {
            if ($null -eq $segment) { continue }
            $parts += [string]$segment['Text']
        }
        return ($parts -join '')
    }

    function script:Get-UxPromptTestNonAscii {
        param([string]$Text)
        $bad = @()
        foreach ($ch in $Text.ToCharArray()) {
            $code = [int]$ch
            if ($code -gt 126) {
                $bad += ('non-ascii ' + $code)
            } elseif ($code -lt 32 -and $code -ne 10 -and $code -ne 9) {
                $bad += ('control ' + $code)
            }
        }
        return ($bad -join ', ')
    }

    function script:Get-UxPromptTestLineInfo {
        param([string]$Text)
        $lines = @($Text -split "`n")
        $max = 0
        $newlines = 0
        foreach ($ch in $Text.ToCharArray()) {
            if ([int]$ch -eq 10) { $newlines = $newlines + 1 }
        }
        foreach ($line in $lines) {
            if ($line.Length -gt $max) { $max = $line.Length }
        }
        return @{ Lines = $lines; MaxLength = $max; NewlineCount = $newlines }
    }

    function script:Get-UxPromptTestInfoText {
        param($Items)
        # Write-Host lands in the information stream; this pulls the text back out.
        $parts = @()
        foreach ($item in @($Items)) {
            if ($null -eq $item) { continue }
            if ($item.GetType().Name -eq 'InformationRecord') { $parts += [string]$item.MessageData }
        }
        return ($parts -join '')
    }
}

AfterAll {
    # Restore the global state the prompt tests replaced.
    if ($null -eq $script:SavedUx) {
        Remove-Variable -Name 'Ux' -Scope Global -ErrorAction SilentlyContinue
    } else {
        $global:Ux = $script:SavedUx
    }
    Remove-Item -LiteralPath 'Function:\Get-UxGitModel' -ErrorAction SilentlyContinue
}

Describe 'Format-UxPrompt: themes x modes are pure ASCII and non-empty' {
    It '<Theme> in <Mode> renders non-empty pure-ASCII text' -ForEach @(
        @{ Theme = 'ascii'; Mode = 'Vt' }
        @{ Theme = 'ascii'; Mode = 'Console' }
        @{ Theme = 'ascii'; Mode = 'Plain' }
        @{ Theme = 'classic'; Mode = 'Vt' }
        @{ Theme = 'classic'; Mode = 'Console' }
        @{ Theme = 'classic'; Mode = 'Plain' }
        @{ Theme = 'blocks'; Mode = 'Vt' }
        @{ Theme = 'blocks'; Mode = 'Console' }
        @{ Theme = 'blocks'; Mode = 'Plain' }
        @{ Theme = 'two-line'; Mode = 'Vt' }
        @{ Theme = 'two-line'; Mode = 'Console' }
        @{ Theme = 'two-line'; Mode = 'Plain' }
    ) {
        $model = script:New-UxPromptTestModel -Git @{
            IsRepo = $true; Branch = 'main'; Dirty = $true; Ahead = 1; Behind = 2; State = ''
        }

        $segments = @(Format-UxPrompt -Model $model -Theme $Theme -Mode $Mode)
        $text = script:Get-UxPromptTestText -Segments $segments

        $segments.Count | Should -BeGreaterThan 0 -Because 'a theme that renders no segments means the prompt is empty'
        $text.Length | Should -BeGreaterThan 0 -Because 'an empty prompt makes the shell look hung'
        script:Get-UxPromptTestNonAscii -Text $text | Should -Be '' -Because 'every theme must render in a stock console font on 5.1, so no byte above 0x7E and no control characters (except the two-line newline) are allowed'

        # Mode only blanks the Vt field: the visible text must be identical everywhere.
        $plainText = script:Get-UxPromptTestText -Segments (Format-UxPrompt -Model $model -Theme $Theme -Mode 'Plain')
        $text | Should -Be $plainText -Because 'Mode may only change the Vt escape data, never the visible prompt'
    }

    It 'populates Vt only in Vt mode (<Theme>)' -ForEach @(
        @{ Theme = 'ascii' }
        @{ Theme = 'classic' }
        @{ Theme = 'blocks' }
        @{ Theme = 'two-line' }
    ) {
        $model = script:New-UxPromptTestModel -Git @{
            IsRepo = $true; Branch = 'main'; Dirty = $true; Ahead = 0; Behind = 0; State = ''
        }

        $vtSegments = @(Format-UxPrompt -Model $model -Theme $Theme -Mode 'Vt')
        $styled = @($vtSegments | Where-Object { [string]$_['Vt'] -ne '' })
        $styled.Count | Should -BeGreaterThan 0 -Because 'Vt mode must carry SGR parameters, otherwise there is no colour on a VT-capable host'

        foreach ($otherMode in @('Console', 'Plain')) {
            $otherSegments = @(Format-UxPrompt -Model $model -Theme $Theme -Mode $otherMode)
            $leaked = @($otherSegments | Where-Object { [string]$_['Vt'] -ne '' })
            $leaked.Count | Should -Be 0 -Because ("{0} mode must not emit SGR parameters" -f $otherMode)
        }
    }

    It 'falls back to the ascii theme for an unknown theme name' {
        $model = script:New-UxPromptTestModel -Git $null
        $unknown = script:Get-UxPromptTestText -Segments (Format-UxPrompt -Model $model -Theme 'no-such-theme' -Mode 'Plain')
        $ascii = script:Get-UxPromptTestText -Segments (Format-UxPrompt -Model $model -Theme 'ascii' -Mode 'Plain')
        $unknown | Should -Be $ascii -Because 'an unknown theme name must degrade to the default, never to an empty prompt'
    }
}

Describe 'Format-UxPrompt: theme identity' {
    It 'ascii renders the "PS <path>" prefix' {
        $model = script:New-UxPromptTestModel -Git @{ IsRepo = $true; Branch = 'main'; Dirty = $false }
        $text = script:Get-UxPromptTestText -Segments (Format-UxPrompt -Model $model -Theme 'ascii' -Mode 'Plain')

        $text | Should -Match '^PS '
        $text | Should -Be 'PS ~/repo (main) $ '
    }

    It 'classic renders user@host:path' {
        $model = script:New-UxPromptTestModel -Git @{ IsRepo = $true; Branch = 'main'; Dirty = $false }
        $text = script:Get-UxPromptTestText -Segments (Format-UxPrompt -Model $model -Theme 'classic' -Mode 'Plain')

        $text | Should -Match '^pedro@winbox:'
        $text | Should -Be 'pedro@winbox:~/repo (main)$ '
    }

    It 'classic omits the host when ShowHost is false (host is off by default in config)' {
        $model = script:New-UxPromptTestModel -Git $null -ShowHost $false
        $text = script:Get-UxPromptTestText -Segments (Format-UxPrompt -Model $model -Theme 'classic' -Mode 'Plain')

        $text | Should -Not -Match '@' -Because 'prompt.host defaults to false, so a live classic prompt is user:path'
        $text | Should -Be 'pedro:~/repo$ '
    }

    It 'blocks joins its segments with ">"' {
        $model = script:New-UxPromptTestModel -Git @{ IsRepo = $true; Branch = 'main'; Dirty = $false }
        $segments = @(Format-UxPrompt -Model $model -Theme 'blocks' -Mode 'Plain')
        $text = script:Get-UxPromptTestText -Segments $segments

        $text | Should -Be '[pedro@winbox] > [~/repo] > [main] > $ '
        $separators = @($segments | Where-Object { [string]$_['Text'] -eq ' > ' })
        $separators.Count | Should -Be 3 -Because 'three joined segments need three ">" separators (identity, path, git, then the symbol)'
    }

    It 'two-line puts the symbol on its own line after exactly one newline' {
        $model = script:New-UxPromptTestModel -Git @{ IsRepo = $true; Branch = 'main'; Dirty = $false }
        $text = script:Get-UxPromptTestText -Segments (Format-UxPrompt -Model $model -Theme 'two-line' -Mode 'Plain')
        $info = script:Get-UxPromptTestLineInfo -Text $text

        $info.NewlineCount | Should -Be 1 -Because 'the two-line theme renders one dim identifier line and one symbol line'
        $info.Lines.Count | Should -Be 2
        $info.Lines[0] | Should -Be '~/repo (main)'
        $info.Lines[1] | Should -Be '$ ' -Because 'the symbol line must be the last line, so the cursor starts after it'
    }
}

Describe 'Prompt model: home directory collapsing' {
    It 'collapses a path under the home directory to ~/... (helper contract)' {
        ConvertTo-UxPromptHomePath -Path '/tmp/ux-prompt-home/proj' -HomeDir '/tmp/ux-prompt-home/' | Should -Be '~/proj'
        ConvertTo-UxPromptHomePath -Path '/tmp/ux-prompt-home' -HomeDir '/tmp/ux-prompt-home' | Should -Be '~'
    }

    It 'does not collapse a sibling directory that merely shares the prefix' {
        ConvertTo-UxPromptHomePath -Path '/tmp/ux-prompt-home2/proj' -HomeDir '/tmp/ux-prompt-home' |
            Should -Be '/tmp/ux-prompt-home2/proj' -Because 'turning /home/pedro2 into ~2 would be a lie about where the user is'
    }

    It 'renders ~ for a path under the fake home, through model and render' {
        $global:Ux = @{ Home = $script:FakeHome }

        $model = Get-UxPromptModel -Path ($script:FakeHome + '/proj')
        $model['Path'] | Should -Be '~/proj' -Because 'Get-UxPromptModel is what collapses the home prefix for the renderer'

        $text = script:Get-UxPromptTestText -Segments (Format-UxPrompt -Model $model -Theme 'ascii' -Mode 'Plain')
        $text | Should -Be 'PS ~/proj $ '
    }

    It 'keeps a path outside the home directory absolute' {
        $global:Ux = @{ Home = $script:FakeHome }

        $model = Get-UxPromptModel -Path '/opt/ux-outside/app'
        $model['Path'] | Should -Be '/opt/ux-outside/app'

        $text = script:Get-UxPromptTestText -Segments (Format-UxPrompt -Model $model -Theme 'ascii' -Mode 'Plain')
        $text | Should -Be 'PS /opt/ux-outside/app $ '
    }
}

Describe 'Format-UxPrompt: width truncation' {
    BeforeAll {
        # Deep enough that every theme has to shorten something at Width 40.
        $script:DeepPath = '/home/pedro/projects/deep/subdir/nested/final/deeper'
    }

    It '<Theme> keeps the last path segments behind an ASCII "..." marker at Width 40' -ForEach @(
        @{ Theme = 'ascii' }
        @{ Theme = 'classic' }
        @{ Theme = 'blocks' }
    ) {
        $model = script:New-UxPromptTestModel -Path $script:DeepPath -Git @{
            IsRepo = $true; Branch = 'main'; Dirty = $true; Ahead = 1; Behind = 2; State = ''
        }

        $text = script:Get-UxPromptTestText -Segments (Format-UxPrompt -Model $model -Theme $Theme -Mode 'Plain' -Width 40)

        $text | Should -Match '\.\.\.' -Because 'a shortened path must say so, and the marker is ASCII dots'
        $text | Should -Match 'deeper' -Because 'the tail of the path is the part that tells the user where they are'
        $text | Should -Not -Match '/projects' -Because 'the leading segments are the ones that get dropped'
        (script:Get-UxPromptTestLineInfo -Text $text).MaxLength | Should -BeLessOrEqual 40
    }

    It '<Theme> never renders a line wider than Width' -ForEach @(
        @{ Theme = 'ascii' }
        @{ Theme = 'classic' }
        @{ Theme = 'blocks' }
        @{ Theme = 'two-line' }
    ) {
        $model = script:New-UxPromptTestModel -Path $script:DeepPath -Git @{
            IsRepo = $true; Branch = 'main'; Dirty = $true; Ahead = 12; Behind = 34; State = 'REBASE'
        }

        $text = script:Get-UxPromptTestText -Segments (Format-UxPrompt -Model $model -Theme $Theme -Mode 'Plain' -Width 40)
        $info = script:Get-UxPromptTestLineInfo -Text $text

        $info.MaxLength | Should -BeLessOrEqual 40 -Because 'the width fitting loop must shorten, drop git, drop user, drop host, then hard-truncate the path'
        $text | Should -Match '\.\.\.' -Because 'at this depth even the two-line theme has to shorten its first line'
    }

    It 'does not truncate a path that already fits, because Width is a ceiling and not a target' {
        # Documented behaviour: for two-line the path sits alone on the first line,
        # so a 39-character path inside Width 40 is rendered in full with no "..."
        # marker. This is the assertion the spec asks for in place of forcing
        # truncation the width does not require.
        $shortPath = '/home/pedro/projects/deep/sub/dir/final'
        $model = script:New-UxPromptTestModel -Path $shortPath -Git $null

        $text = script:Get-UxPromptTestText -Segments (Format-UxPrompt -Model $model -Theme 'two-line' -Mode 'Plain' -Width 40)
        $info = script:Get-UxPromptTestLineInfo -Text $text

        $text | Should -Not -Match '\.\.\.'
        $text | Should -Match '/home/pedro/projects/deep/sub/dir/final'
        $info.MaxLength | Should -BeLessOrEqual 40
    }
}

Describe 'Format-UxPrompt: UNC and drive paths' {
    It 'preserves "<Path>" verbatim and never mangles it into ~' -ForEach @(
        @{ Path = '\\server\share\dir' }
        @{ Path = 'C:\' }
        @{ Path = 'C:\Users\pedro' }
        @{ Path = 'C:' }
    ) {
        $model = script:New-UxPromptTestModel -Path $Path -Git $null
        $text = script:Get-UxPromptTestText -Segments (Format-UxPrompt -Model $model -Theme 'ascii' -Mode 'Plain')

        $text | Should -BeLike ('*' + $Path + '*') -Because 'a drive or share root must survive the path formatter unchanged'
        $text | Should -Not -Match '~' -Because 'a UNC path or a drive root is never the user home'
    }
}

Describe 'Format-UxPrompt: git segment' {
    It 'renders a dirty branch with an ASCII *' {
        $model = script:New-UxPromptTestModel -Git @{ IsRepo = $true; Branch = 'main'; Dirty = $true; Ahead = 0; Behind = 0; State = '' }
        $text = script:Get-UxPromptTestText -Segments (Format-UxPrompt -Model $model -Theme 'ascii' -Mode 'Plain')

        $text | Should -Match '\(main\*\)'
    }

    It 'renders ahead/behind as +1-2' {
        $model = script:New-UxPromptTestModel -Git @{ IsRepo = $true; Branch = 'main'; Dirty = $false; Ahead = 1; Behind = 2; State = '' }
        $text = script:Get-UxPromptTestText -Segments (Format-UxPrompt -Model $model -Theme 'ascii' -Mode 'Plain')

        $text | Should -Match '\(main \+1-2\)'
    }

    It 'renders an in-progress operation as |STATE' {
        $model = script:New-UxPromptTestModel -Git @{ IsRepo = $true; Branch = 'main'; Dirty = $false; Ahead = 0; Behind = 0; State = 'REBASE' }
        $text = script:Get-UxPromptTestText -Segments (Format-UxPrompt -Model $model -Theme 'ascii' -Mode 'Plain')

        $text | Should -Match '\(main\|REBASE\)'
    }

    It 'renders an unborn branch with the documented (new) marker' {
        # lib/10-git.ps1 encodes an unborn branch as State 'NEW' (uppercase).
        $model = script:New-UxPromptTestModel -Git @{ IsRepo = $true; Branch = 'main'; Dirty = $false; Ahead = 0; Behind = 0; State = 'NEW' }
        $text = script:Get-UxPromptTestText -Segments (Format-UxPrompt -Model $model -Theme 'ascii' -Mode 'Plain')

        $text | Should -Match '\(main\)\(new\)'
        $text | Should -Not -Match '\|NEW' -Because 'the unborn state has its own marker and must not also be printed as a raw state suffix'
    }

    It 'renders no git segment at all when the path is not a repository' {
        $model = script:New-UxPromptTestModel -Git @{ IsRepo = $false; Branch = ''; Dirty = $false }
        $text = script:Get-UxPromptTestText -Segments (Format-UxPrompt -Model $model -Theme 'ascii' -Mode 'Plain')

        $text | Should -Be 'PS ~/repo $ ' -Because 'not-a-repo must render nothing at all, not an empty pair of brackets'
        $text | Should -Not -Match '\('
    }

    It 'renders no * when Dirty is unknown ($null)' {
        $model = script:New-UxPromptTestModel -Git @{ IsRepo = $true; Branch = 'main'; Dirty = $null; Ahead = 0; Behind = 0; State = '' }
        $text = script:Get-UxPromptTestText -Segments (Format-UxPrompt -Model $model -Theme 'ascii' -Mode 'Plain')

        $text | Should -Match '\(main\)' -Because 'the branch is known even when dirtiness is not'
        $text | Should -Not -Match '\*' -Because 'unknown must not lie about being dirty'
    }
}

Describe 'Format-UxPrompt: exit marker' {
    It 'renders a red ASCII ! when the last command failed' {
        $model = script:New-UxPromptTestModel -Git $null -LastExit 3 -LastOk $false
        $segments = @(Format-UxPrompt -Model $model -Theme 'ascii' -Mode 'Vt')
        $text = script:Get-UxPromptTestText -Segments $segments

        $text | Should -Match '!'
        $exitSegments = @($segments | Where-Object { [string]$_['Text'] -eq ' !' })
        $exitSegments.Count | Should -Be 1 -Because 'the marker must be its own segment so it can carry its own colour'
        $exitSegments[0]['Color'] | Should -Be 'Red'
        $exitSegments[0]['Vt'] | Should -Be '1;31' -Because 'Vt mode must be able to colour the marker red without the PS7 style object'
    }

    It 'renders no marker when the last command succeeded' {
        $model = script:New-UxPromptTestModel -Git $null -LastExit 0 -LastOk $true
        $text = script:Get-UxPromptTestText -Segments (Format-UxPrompt -Model $model -Theme 'ascii' -Mode 'Vt')

        $text | Should -Not -Match '!'
        $text | Should -Be 'PS ~/repo $ '
    }
}

Describe 'Format-UxPrompt: purity' {
    It 'returns the same text on repeated calls and only plain segment objects' {
        $model = script:New-UxPromptTestModel -Git @{ IsRepo = $true; Branch = 'main'; Dirty = $true; Ahead = 0; Behind = 0; State = '' }

        $first = @(Format-UxPrompt -Model $model -Theme 'ascii' -Mode 'Plain')
        $second = @(Format-UxPrompt -Model $model -Theme 'ascii' -Mode 'Plain')

        script:Get-UxPromptTestText -Segments $first | Should -Be (script:Get-UxPromptTestText -Segments $second)
        $first.Count | Should -Be $second.Count
        foreach ($segment in $first) {
            $segment.GetType().Name | Should -Be 'Hashtable' -Because 'Format-UxPrompt returns data, not formatted text or host objects'
        }
    }

    It 'writes nothing to the host while rendering' {
        $model = script:New-UxPromptTestModel -Git @{ IsRepo = $true; Branch = 'main'; Dirty = $true; Ahead = 0; Behind = 0; State = '' }

        $direct = @(Format-UxPrompt -Model $model -Theme 'ascii' -Mode 'Plain')
        # 6>&1 folds the information stream (Write-Host) into the success stream, so a
        # host write would show up as an extra, non-hashtable element here.
        $captured = @(& { Format-UxPrompt -Model $model -Theme 'ascii' -Mode 'Plain' } 6>&1)

        $captured.Count | Should -Be $direct.Count -Because 'a pure formatter must not write to the host'
        foreach ($item in $captured) {
            $item.GetType().Name | Should -Be 'Hashtable'
        }
    }

    It 'does not mutate the model or the global state it is handed' {
        $global:Ux = @{ Home = $script:FakeHome; Caps = @{ Vt = $false } }
        $model = script:New-UxPromptTestModel -Path '~/repo' -Git $null

        $null = Format-UxPrompt -Model $model -Theme 'blocks' -Mode 'Vt' -Width 40

        $model['Path'] | Should -Be '~/repo'
        $model['User'] | Should -Be 'pedro'
        $global:Ux.Count | Should -Be 2 -Because 'rendering is not allowed to add keys to $global:Ux'
        $global:Ux['Home'] | Should -Be $script:FakeHome
    }
}

Describe 'prompt: robustness' {
    It 'returns exactly one space, as a single string' {
        $global:Ux = @{}

        $out = prompt

        @($out).Count | Should -Be 1 -Because 'the prompt function must return one separator string, not an array'
        [string]$out | Should -Be ' ' -Because 'PSReadLine and the host expect a single trailing space from prompt'
    }

    It 'never throws when $global:Ux is an empty hashtable' {
        $global:Ux = @{}

        { prompt } | Should -Not -Throw
    }

    It 'falls back to the bare PS> prompt when the render pipeline breaks' {
        $global:Ux = @{}
        Mock Get-UxPromptModel { throw 'simulated model failure' }

        $captured = @(& { prompt } 6>&1)

        Should -Invoke Get-UxPromptModel -Times 1 -Because 'the failure must come from the injected dependency, not from something else'
        $info = script:Get-UxPromptTestInfoText -Items $captured
        $info | Should -Be 'PS> ' -Because 'a broken prompt must degrade to a usable prompt and never propagate the exception into the session'

        $returned = @($captured | Where-Object { $null -ne $_ -and $_.GetType().Name -eq 'String' })
        $returned.Count | Should -Be 1
        [string]$returned[0] | Should -Be ' '
    }

    It 'preserves $LASTEXITCODE across its own git call' -Skip:((-not (Test-Path -LiteralPath '/bin/sh')) -and ($env:OS -ne 'Windows_NT')) {
        # The prompt resolves git through Get-UxPromptModel -> Get-UxGitModel. This
        # stub is global on purpose: it runs a native command that exits 7, which is
        # exactly the clobber that the capture-first code in prompt() exists to
        # survive. Without the restore the assertion below sees 7 instead of 3.
        # cmd.exe on Windows, /bin/sh elsewhere: no skip is needed on either target.
        $global:Ux = @{ Home = $script:FakeHome; Caps = @{ Vt = $false; Color = $false } }
        function global:Get-UxGitModel {
            param([string]$Path)
            if ($env:OS -eq 'Windows_NT') {
                & cmd /c 'exit 7' | Out-Null
            } else {
                & '/bin/sh' -c 'exit 7' | Out-Null
            }
            return @{ IsRepo = $false; Branch = '' }
        }

        try {
            if ($env:OS -eq 'Windows_NT') {
                & cmd /c 'exit 3' | Out-Null
            } else {
                & '/bin/sh' -c 'exit 3' | Out-Null
            }
            $LASTEXITCODE | Should -Be 3 -Because 'the fixture has to establish the status the prompt must preserve'

            $captured = @(& { prompt } 6>&1)

            $LASTEXITCODE | Should -Be 3 -Because 'the prompt git call must not overwrite the status of the previous command'
            $info = script:Get-UxPromptTestInfoText -Items $captured
            $info | Should -Match '!' -Because 'the preserved non-zero status has to reach the model and render the exit marker'
        } finally {
            Remove-Item -LiteralPath 'Function:\Get-UxGitModel' -ErrorAction SilentlyContinue
        }
    }
}
