# Windows checklist - Windows PowerShell 5.1

These are the claims this project could **not** verify automatically. The test suite runs on Linux
`pwsh` in a container; Windows-only behaviour is gated behind an OS check and lands here instead, as
a manual pass you run once on a real Windows machine.

Everything below is copy-paste, uses no admin rights, and writes only inside your own
`%USERPROFILE%`. The cleanup lines are included - please run them, and leave the home directory as
you found it.

**Run this checklist in `powershell.exe` (Windows PowerShell 5.1), not `pwsh`.** The whole point is
the 5.1 baseline. The 7 items are:

| # | Item | Why it cannot be automated here |
|---|---|---|
| 1 | Clustered flags (`-rf`, `-la`, `-9`) reach `$args` in a **5.1** simple function | verified on 7.4 only |
| 2 | `mkdir`/`md`/`rd`/`rmdir` are **functions** on 5.1, and snapshot/restore stays correct | 5.1-specific command shapes |
| 3 | `$Host.UI.SupportsVirtualTerminal` behaves sanely in this console host | host- and image-specific |
| 4 | `Remove-Item -Recurse` over a junction, and the drive-root refusal | 5.1 filesystem behaviour |
| 5 | `Unblock-File` and the execution-policy tier actually observed | policy differs per machine |
| 6 | Load under Constrained Language Mode with no `Import-Module` | policy-specific |
| 7 | Real startup timing, including any antivirus filter driver | machine-specific |

Record the result of each item at the end. If an item FAILs, the *what to do* line tells you whether
it is a doc bug, an environment limit, or a stop-everything regression.

---

## 1. Clustered flags reach `$args` in a 5.1 simple function

The whole Unix layer depends on one rule: a plain (non-advanced) function receives dash-prefixed
tokens it does not declare, verbatim, in `$args`. An advanced function with `[CmdletBinding()]` does
not - it fails parameter binding. This was verified on PowerShell 7.4 and is the reason every wrapper
is a plain function, but it has never been executed on 5.1.

**Run.**

```powershell
function Test-UxArgv { $args }
Test-UxArgv -rf -la -9
```

**PASS.**

```
-rf
-la
-9
```

Three lines, each token on its own line, no error. Then confirm the real wrappers on a scratch tree:

```powershell
mkdir -p $HOME\ux-check\sub
Set-Location $HOME\ux-check
'hello' | Set-Content .\a.txt
ls -la
rm -rf .\sub
Test-Path .\sub
```

**PASS.** `mkdir -p` succeeds silently (no message, no error, directory created). `ls -la` lists
`a.txt` as a table row - **it must not** fail with a parameter-binding error about `la`. `rm -rf`
succeeds silently and the final line prints `False`.

Then the signal case, which needs a live process:

```powershell
$p = Start-Process powershell -ArgumentList '-NoProfile','-Command','Start-Sleep -Seconds 120' -PassThru
kill -9 $p.Id
Get-Process -Id $p.Id -ErrorAction SilentlyContinue
```

**PASS.** No binding error about `9`; the last command prints nothing (the process is gone). If it is
still listed, wait a second and re-check - termination is not always instantaneous.

**FAIL.** If any of these reports *"A parameter cannot be found that matches parameter name 'rf'"*
(or `'la'`, or `'9'`), the plain-function rule does not hold on 5.1. **Stop and file an issue** - this
invalidates the design of the entire command layer, and it is not a documentation problem.

**Cleanup.**

```powershell
Set-Location $HOME
Remove-Item -LiteralPath $HOME\ux-check -Recurse -Force -ErrorAction SilentlyContinue
```

---

## 2. `mkdir`/`md`/`rd`/`rmdir` are functions on 5.1

On Windows, `mkdir` is not necessarily an alias to `New-Item` - it can be a **function**, and so can
`md`, `rd` and `rmdir`. That matters twice over: the loader must snapshot the real command shapes so
`ux restore-aliases` is faithful, and it must then replace them, which it can only do for a function
by removing it first and redefining it.

**Run, in a shell with the profile loaded.**

```powershell
Get-Command mkdir, md, rd, rmdir -ErrorAction SilentlyContinue |
  Select-Object Name, CommandType, ModuleName, Source
```

**PASS.** Each name reports `Function`:

```
Name  CommandType ModuleName Source
----  ----------- ---------- ------
mkdir Function
md    Function
rd    Function
rmdir Function
```

and the key one-liner the plan calls out:

```powershell
(Get-Command mkdir).CommandType
```

**PASS.**

```
Function
```

Then the behavioural proof that our wrapper is the one that won - the 5.1 built-in has no `-p`, so
if `-p` works, the wrapper is loaded:

```powershell
Get-Command mkdir | Select-Object CommandType, ModuleName, Source
mkdir -p $HOME\ux-check2\deep\nested
Test-Path $HOME\ux-check2\deep\nested
```

**PASS.** `mkdir -p` creates the nested path and `Test-Path` prints `True`; `CommandType` is
`Function`. Record the `ModuleName`/`Source` columns exactly as printed - on some images the built-in
`mkdir` carries a module name and on others it does not, and that is exactly the kind of detail the
loader's snapshot has to cope with.

Now prove the snapshot is faithful:

```powershell
ux restore-aliases
(Get-Command mkdir).CommandType
```

**PASS.** Still `Function` - the original 5.1 `mkdir` was restored (functions are restored through
`$function:<name> = <scriptblock>`, which is best-effort by design). A subsequent `mkdir -p` in this
session is *not* expected to work any more; that is the restore doing its job, not a bug.

Reopen a shell to get the wrapper back, or run `ux reload` to re-source the entry point.

**FAIL.** If a name reports `Alias` when the plan says `Function`, or `ux restore-aliases` leaves
nothing behind, record the actual `Get-Command` output - the snapshot needs the real shapes from
your image, and that is exactly what this item is for.

**Cleanup.**

```powershell
Remove-Item -LiteralPath $HOME\ux-check2 -Recurse -Force -ErrorAction SilentlyContinue
```

---

## 3. `$Host.UI.SupportsVirtualTerminal` in this console host

Colour is the only decoration the prompt has, so the capability probe decides between three render
modes: `Vt` (raw ANSI), `Console` (per-segment `-ForegroundColor`), and `Plain` (no colour at all).
The probe must never throw, whatever the host reports.

**Run.**

```powershell
$host.UI.PSObject.Properties['SupportsVirtualTerminal']
$env:WT_SESSION
$env:TERM_PROGRAM
$env:ConEmuANSI
$PSVersionTable.PSVersion
```

**PASS.** No exception from the first line. The property is either present with a boolean `Value`, or
absent (prints nothing) - both are handled, and both are correct for some hosts. Any of the
environment variables being set is a positive VT signal. A `$PSVersionTable.PSVersion.Major` of 5 is
expected here - this is the baseline being tested.

Now look at the glyph, which is rendered **after** the probe, so it shows what the host will really
do:

```powershell
ux doctor
```

**PASS.** The VT line shows the test glyph **in colour**, on the same line, with no literal escape
text such as `[32m`, `[1;32m` or `ESC[` anywhere in the report. The prompt above your command line
looks like `PS ~/ux-check $` (or whichever theme you set) with colour and no stray characters.

Then force the no-colour path and confirm it is clean:

```powershell
$env:UX_NO_COLOR = '1'
ux reload
```

**PASS.** The prompt re-renders as plain text with no escape sequences and no colour. Remove the
variable and reload to get colour back.

**FAIL.** Literal escape sequences on screen mean the host claimed VT support but does not provide
it. Record the host name from `ux doctor`, the `SupportsVirtualTerminal` value, and set
`UX_NO_COLOR = '1'` (see `docs/TROUBLESHOOTING.md`, section 4). This is an environment limit with a
documented workaround, not a regression. An **exception** from `$host.UI.PSObject.Properties[...]`,
however, is a real bug - report it.

---

## 4. `Remove-Item -Recurse` over a junction, and the drive-root refusal

This is the data-loss item. On Windows PowerShell 5.1, `Remove-Item -Recurse` has historically
followed a junction or reparse point and deleted the **target's** contents. The `rm` wrapper therefore
refuses a recursive delete that crosses a reparse point, and refuses drive roots and `$HOME`
outright. Both refusals are the correct behaviour, and both need to be confirmed on the real
filesystem.

**Run - the wrapper must refuse, and the data must survive.**

```powershell
$t = Join-Path $HOME 'ux-junction-test'
New-Item -ItemType Directory -Path (Join-Path $t 'target') -Force | Out-Null
'do not delete me' | Set-Content -Path (Join-Path $t 'target\keep.txt')
New-Item -ItemType Junction -Path (Join-Path $t 'link') -Target (Join-Path $t 'target') | Out-Null
rm -r (Join-Path $t 'link')
Get-Content -LiteralPath (Join-Path $t 'target\keep.txt')
```

**PASS.** `rm -r` prints a refusal explaining the reparse point (it does **not** delete), and
`Get-Content` prints `do not delete me`. The junction may or may not still exist - what matters is
that the target file is untouched.

**Run - record what the raw cmdlet does, on a throwaway file only.**

```powershell
'temp' | Set-Content -Path (Join-Path $t 'target\scratch.txt')
Remove-Item -LiteralPath (Join-Path $t 'link') -Recurse -Force -ErrorAction SilentlyContinue
Test-Path -LiteralPath (Join-Path $t 'target\scratch.txt')
```

**PASS.** Record the boolean. If it prints `False` (or the whole `target` directory is gone), the
5.1 junction bug is present on this image and the wrapper's refusal is load-bearing - this is the
expected outcome. If it prints `True`, this image fixed the bug and the refusal is conservative; that
is also fine, and worth noting in the record.

**Run - the drive-root refusal, guarded.**

```powershell
if ((Get-Command rm).CommandType -ne 'Function') {
  Write-Host 'STOP: rm is not the unix-powershell wrapper - do not continue' -ForegroundColor Red
} else {
  rm -r "$env:SystemDrive\"
}
```

**PASS.** A refusal naming the drive root. Nothing is deleted, no prompt appears, and your `C:\` is
intact. The guard is there because an *unwrapped* `rm` would resolve to `Remove-Item` and this line
would be catastrophic - never run it with the profile unloaded.

Also confirm `$HOME` is refused, with the same guard:

```powershell
if ((Get-Command rm).CommandType -ne 'Function') {
  Write-Host 'STOP: rm is not the unix-powershell wrapper - do not continue' -ForegroundColor Red
} else {
  rm -r $HOME
}
```

**PASS.** Refused, with an explanation rather than a prompt, and the contents of your home directory
are intact.

**FAIL.** Any deletion, any interactive confirmation prompt, or an `Object reference not set to an
instance of an object` error (that is the non-interactive `Remove-Item` failure the wrapper exists to
avoid). **Stop and file an issue immediately** - this is the one failure mode that can destroy your
data.

**Cleanup.**

```powershell
Remove-Item -LiteralPath (Join-Path $t 'link') -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $t -Recurse -Force -ErrorAction SilentlyContinue
Test-Path -LiteralPath $t
```

The last line must print `False`.

---

## 5. `Unblock-File` and the observed execution-policy tier

Files that arrive with a `Zone.Identifier` stream are "from the internet", and on a `RemoteSigned`
machine PowerShell refuses to run them. The installer clears that mark on every installed file - from
a download **and** from a `-SourceDir` zip - and `ux update` does it again. The tier itself is set by
GPO per client and cannot be assumed.

**Run.**

```powershell
Get-ExecutionPolicy -List
Get-ExecutionPolicy
```

**PASS.** Record all five rows and the effective value. Any of these is a PASS for this item:

| Effective policy | Expected result |
|---|---|
| `RemoteSigned` / `Unrestricted` | profile block loads, `ux` works |
| `AllSigned` (GPO) | block does not load unsigned - use a documented escape hatch (README, *Execution policy*) |
| `Restricted` / AppLocker / WDAC | unsupported without admin; the record documents why |

Then confirm no installed file carries a download mark:

```powershell
Get-ChildItem "$HOME\.unix-powershell" -Recurse -File |
  ForEach-Object { Get-Item -LiteralPath $_.FullName -Stream Zone.Identifier -ErrorAction SilentlyContinue }
```

**PASS.** No output at all - no file has a `Zone.Identifier` stream. If anything is listed, clear it
and re-check:

```powershell
Get-ChildItem "$HOME\.unix-powershell" -Recurse -File | Unblock-File -ErrorAction SilentlyContinue
```

Then verify the block actually loads under this tier:

```powershell
powershell -NoProfile -Command "Get-ExecutionPolicy -Scope CurrentUser"
powershell -NoProfile -File "$HOME\.unix-powershell\ux.ps1" doctor
```

**PASS.** The second command prints the full doctor report even when your profile is untouched - it
is the documented standalone entry point, and it is what you rely on when the block cannot load.

If you are on `AllSigned`, also record whether the **block** loads (open a new shell) and whether the
`powershell -NoProfile -Command "..."` bootstrap works, since execution policy does not apply to
command strings. That single observation is the difference between "supported with a hatch" and
"not supported here".

**FAIL.** A `Zone.Identifier` stream that survives `Unblock-File`, or a `RemoteSigned` tier where the
block still refuses to load, is a real installer bug - record the file path, the policy rows, and the
exact error text.

---

## 6. Load under Constrained Language Mode, with no `Import-Module`

Under CLM, `Add-Type`, reflection and .NET statics are unavailable, and Pester cannot load at all -
which is why the CLM check is a module-free smoke script and not a Pester test. The runtime path is
written to survive CLM: no `Add-Type`, no reflection, no .NET static calls.

**Run - first, is CLM active on this image at all?**

```powershell
$ExecutionContext.SessionState.LanguageMode
```

**PASS.** `FullLanguage` or `ConstrainedLanguage`, both are valid answers; record which. If it is
`ConstrainedLanguage`, this item becomes the important one.

**Run - the smoke script.** It needs a checkout (or an install that shipped the `test` folder), so
check first:

```powershell
Test-Path "$HOME\.unix-powershell\test\60-Clm.ps1"
```

If `True`:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$HOME\.unix-powershell\test\60-Clm.ps1"
```

If `False`, run it from your checkout instead (`.\test\60-Clm.ps1`), or fall back to the equivalent
two-step check in the current session:

```powershell
$ExecutionContext.SessionState.LanguageMode
ux doctor
ux verify
```

**PASS.** The smoke script asserts `LanguageMode -eq 'ConstrainedLanguage'` in a child process and
loads the profile with **zero errors**, exiting 0. The fallback prints `ConstrainedLanguage` and then
a complete `ux doctor` report plus a clean `ux verify`.

Expected degradations under CLM, all of which are PASS, not failure: `ux` argument completion is not
registered (it is wrapped so it cannot break loading), `[Parser]::ParseFile` syntax validation is
skipped and reported as skipped, and `Invoke-WebRequest` is avoided in favour of `curl.exe`. SHA256
verification via `Get-FileHash` still runs - that is the real integrity gate.

Note that `-ExecutionPolicy Bypass` on the command line is **ignored** if a `MachinePolicy` or
`UserPolicy` row is set (see item 5); if the script refuses to run for that reason, that is the
policy, not the script.

**FAIL.** Any error during load, any `Add-Type` / reflection / .NET static failure, or a
`LanguageMode` assertion that reports `FullLanguage` when policy says CLM is enforced (that would mean
the child process is not actually constrained and the test proves nothing). Record the full output.

---

## 7. Real startup timing, with antivirus

The target is **under 150 ms for the profile itself**, at most **one `git` process per prompt**, and
**zero** network calls. Everything except the wall-clock number is asserted by the automated suite;
the number depends on the image and its filter drivers.

**Run - three loads, plus a baseline so you can subtract `powershell.exe` startup.**

```powershell
$entry = Join-Path $HOME '.unix-powershell\profile\profile.ps1'
$baseline = 1..3 | ForEach-Object {
  (Measure-Command { powershell -NoProfile -Command "exit" }).TotalMilliseconds
}
$loaded = 1..3 | ForEach-Object {
  (Measure-Command { powershell -NoProfile -Command "& '$entry'" }).TotalMilliseconds
}
"baseline: $($baseline -join ', ')"
"loaded:   $($loaded -join ', ')"
"delta:    $([int](($loaded | Measure-Object -Average).Average - ($baseline | Measure-Object -Average).Average)) ms"
```

Then read the number the profile measures about itself:

```powershell
ux doctor
```

**PASS.** The last-load-ms line in `ux doctor` is **under 150**, and the `delta` above is consistent
with it. Run the block twice before you believe the numbers - the first `powershell.exe` launch on a
cold image is always the slowest. Zero network traffic at shell start is part of the contract; nothing
in the load path opens a socket.

**Run - the one-git-process-per-prompt claim, observable without a shim.** `cd` into a git repository
you own, then run:

```powershell
$before = @(Get-Process git -ErrorAction SilentlyContinue).Count
# press Enter a few times, then:
$after = @(Get-Process git -ErrorAction SilentlyContinue).Count
"$before -> $after"
```

**PASS.** No `git` process lingers after the prompt renders (each `git status` exits before the prompt
is printed). `git` visible in Task Manager for a fraction of a second per prompt is normal; several
accumulating is not.

**FAIL.** If the profile-only cost is over 150 ms, work through the slow-prompt section of
`docs/TROUBLESHOOTING.md` before calling it a regression: `ux config set git.useGitBinary false`,
check the install directory is local and not a OneDrive offline placeholder (`ux doctor` warns about
the `Offline` attribute), and check whether your organisation allows an antivirus exclusion for the
install directory. A 5.1 host with a filter driver can legitimately exceed 150 ms - record the
number, the AV product, and whether the install directory is on a network or redirected path, because
that combination is what the record is for.

---

## Record

Fill this in on the machine and keep it with your notes.

| # | Item | Result (PASS/FAIL) | Observed value or output |
|---|---|---|---|
| 1 | Clustered flags reach `$args` on 5.1 | | |
| 2 | `mkdir`/`md`/`rd`/`rmdir` are functions; restore is faithful | | |
| 3 | `SupportsVirtualTerminal` and the `ux doctor` glyph | | |
| 4 | Junction refusal, raw `Remove-Item -Recurse` result, drive-root refusal | | |
| 5 | Execution-policy tier and absence of `Zone.Identifier` | | |
| 6 | CLM load, zero errors | | |
| 7 | Last load ms, AV product, path type | | |

Environment, for the record:

```powershell
$PSVersionTable | Format-List
$host.Name
[Environment]::OSVersion.VersionString
```

One row per image. If an item FAILs, quote the command and its output verbatim - every item here is
designed so that a failing result tells you which claim to distrust.
