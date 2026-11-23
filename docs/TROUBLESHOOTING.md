# Troubleshooting

This project is built on the assumption that you have **no admin rights and no support escalation**:
if something breaks you have to be able to diagnose and fix it yourself. So every failure mode below
gives you the symptom, the reason, and the exact command to run.

Start here, in this order:

```powershell
ux doctor                              # the environment report
ux doctor -Json                        # the same report, machine-readable
ux verify                              # wrappers, aliases, config, manifest hashes
```

If `ux` itself is not recognised, the profile did not load - use the standalone entry point:

```powershell
powershell -NoProfile -File "$HOME\.unix-powershell\ux.ps1" doctor
```

| Symptom | Section |
|---|---|
| Nothing changed, no Unix commands, no prompt | [1](#1-the-profile-does-not-load-at-all) |
| `... cannot be loaded because running scripts is disabled` | [2](#2-execution-policy-and-group-policy) |
| Some things work, some silently do not | [3](#3-constrained-language-mode) |
| Colour codes printed literally, or no colour | [4](#4-no-colour--no-virtual-terminal-support) |
| Boxes and question marks where the prompt should be | [5](#5-missing-glyphs-and-nerd-font-expectations) |
| No `(branch)` segment, or no `*` dirty marker | [6](#6-the-git-segment-is-missing) |
| Prompt takes a visible moment to appear | [7](#7-the-prompt-is-slow) |
| `ls -Path .` no longer works, or `type`/`curl` vanished | [8](#8-a-wrapper-is-shadowing-a-command-i-need) |
| Startup line about a missing entry point | [9](#9-the-install-directory-was-deleted-but-the-block-remains) |
| I need this gone immediately | [10](#10-emergency-exits-ux_disable-and-ux-disable) |
| A yellow `[unix-powershell] load failed: ...` line | [11](#11-reading-the-one-line-load-failure-message) |

---

## 1. The profile does not load at all

**Symptom.** A new shell has no `ux`, no Unix commands, and the default `PS C:\>` prompt. No error
message either.

**Why.** One of four things: the profile block was never written to the file your host actually
loads; the file is not being loaded because PowerShell is starting with `-NoProfile`; the block was
written but the install entry point is missing (in which case the block is silent by design - see
section 9); or the block threw and printed a message that scrolled past.

**Run.**

```powershell
# Which profile files does this host actually load?
$PROFILE | Format-List *
$PROFILE.CurrentUserAllHosts

# Is the block in there?
Select-String -Path $PROFILE.CurrentUserAllHosts -Pattern 'unix-powershell' -SimpleMatch

# Does the entry point exist?
Test-Path (Join-Path $HOME '.unix-powershell\profile\profile.ps1')
```

Read the result like this:

- **Nothing matched** -> the block is not installed. Run the installer again (README, *Install*).
- **The path above does not exist / `Test-Path` was `False`** -> the block lives in a different
  profile file than the one this host loads. The installer patches
  `$PROFILE.CurrentUserAllHosts` for the host that ran it; if you install from `powershell.exe` and
  then use `pwsh`, or vice versa, use `-AllHosts` on the installer to patch both.
- **Block present, entry point missing** -> section 9.
- **Launched from a shortcut, `.lnk`, or a corporate launcher with `-NoProfile`** -> nothing you
  install will load. `powershell -NoProfile` is the documented way to work *around* a broken profile,
  not a normal working mode. Check the shortcut's target, and your terminal profile settings for a
  "no profile" toggle.

To confirm the files are fine independently of your profile:

```powershell
powershell -NoProfile -File "$HOME\.unix-powershell\ux.ps1" doctor
```

If that prints a full report, the runtime is healthy and the problem is purely your profile wiring.

---

## 2. Execution policy and Group Policy

**Symptom.** Either a red error mentioning `running scripts is disabled on this system`, or nothing
at all - and the report from section 1 shows the block is present.

**Why.** Execution policy decides whether a `.ps1` file may be loaded. The profile block *is* a
script file, so it is subject to the policy. There are three tiers, and only two are supported:
`RemoteSigned`/`Unrestricted` work; `AllSigned` blocks the unsigned block but has two documented
no-admin escape hatches (README, *Execution policy*); `Restricted`, AppLocker and WDAC are
unsupported without admin.

**Run.**

```powershell
Get-ExecutionPolicy -List
Get-ExecutionPolicy
```

`Get-ExecutionPolicy -List` prints one row per scope. Read it top-down, because the **highest
precedence non-`Undefined` value wins**:

| Scope | Set by | Can you change it? |
|---|---|---|
| `MachinePolicy` | Group Policy (machine) | **No** - admin/GPO only |
| `UserPolicy` | Group Policy (per user) | **No** - admin/GPO only |
| `Process` | `-ExecutionPolicy` on the command line, or `Set-ExecutionPolicy -Scope Process` | Yes, for this process only |
| `CurrentUser` | HKCU | **Yes**, no admin needed |
| `LocalMachine` | HKLM | No - admin only |

How to read your output:

- A `MachinePolicy` or `UserPolicy` row that is **not** `Undefined` is a GPO. It beats everything
  else, including `-ExecutionPolicy Bypass` on the command line (that switch is simply ignored), and
  including anything you set in `CurrentUser`. `ux doctor` flags these rows as GPO-locked.
- Otherwise the effective value is the first of `Process`, `CurrentUser`, `LocalMachine` that is not
  `Undefined` - that is what the bare `Get-ExecutionPolicy` call prints.

If you have no GPO row, this is a one-liner you can run without admin:

```powershell
Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned
```

Then open a new shell. Nothing here needs elevation, and the installer can do this for you with
`-SetExecutionPolicy` - it refuses if a `MachinePolicy`/`UserPolicy` override is present, because in
that case the change would not take effect and you would be left with a false sense of progress.

If a GPO is present with `AllSigned`, use the `AllSigned` escape hatches in the README: the one-time
`powershell -NoProfile -Command "..."` bootstrap (execution policy does not apply to command strings
or `Invoke-Expression`), and the manual per-user trusted-publisher procedure (create a code-signing
certificate, import it into `Cert:\CurrentUser\Root` and `Cert:\CurrentUser\TrustedPublisher`, then
sign the installed scripts). There is deliberately no `ux trust` verb for this. If a GPO is
present with `Restricted`, or AppLocker/WDAC denies execution outright, there is no supported path
without admin - `ux doctor` says so rather than guessing.

---

## 3. Constrained Language Mode

**Symptom.** The prompt and the Unix commands mostly work, but something looks reduced: tab completion
for `ux` arguments does nothing, an install or update message says parser validation was skipped, or
a download fell back from `curl.exe` to `Invoke-WebRequest`.

**Why.** Constrained Language Mode (CLM) is a *language* restriction imposed by AppLocker/WDAC, not
an execution-policy setting. The runtime path of this project is written to survive it: no
`Add-Type`, no reflection, no .NET *static* method calls. But CLM is **tiered, not binary**, so some
things genuinely degrade:

| Capability | Under CLM |
|---|---|
| Unix command wrappers, prompt rendering, git file parsing, config read/write | **Work.** This is the designed path |
| Argument completion for `ux` | Not registered - it is wrapped in `try/catch` precisely so this cannot break loading |
| `[Parser]::ParseFile` syntax pre-validation during install/update | Blocked; skipped and **reported as skipped**. SHA256 via `Get-FileHash` is the real integrity gate |
| `Invoke-WebRequest` downloads | CLM-hostile, so the installer prefers `curl.exe` where it exists |
| Pester test suite | Cannot load under CLM (that is why there is a module-free `60-Clm.ps1` smoke script) |

**Run.**

```powershell
$ExecutionContext.SessionState.LanguageMode
```

- `FullLanguage` -> CLM is not the problem; look elsewhere.
- `ConstrainedLanguage` -> CLM is active. Confirm the runtime still loads end to end:

```powershell
ux doctor
ux verify
```

If both succeed under `ConstrainedLanguage`, nothing is wrong. If `ux verify` reports failed
assertions, capture its output - that is the report to attach to any issue.

You cannot lift CLM from your own account: it is set by security policy. What you *can* do is
confirm you are on the supported path, which is the point of the design. If the profile block fails
to load only under CLM, use the standalone entry point
(`powershell -NoProfile -File "$HOME\.unix-powershell\ux.ps1" doctor`) so you get a report instead
of silence.

---

## 4. No colour / no virtual terminal support

**Symptom.** One of: colour sequences printed as literal text such as `[32m` or `ESC[1;32m` before
the prompt; every prompt element in the same colour; no colour at all, just plain text.

**Why.** VT (virtual terminal / ANSI) support is not guaranteed on a locked-down Windows console.
The capability probe checks for `SupportsVirtualTerminal` on the host, then the `WT_SESSION`,
`TERM_PROGRAM` and `ConEmuANSI=ON` environment variables, then PowerShell 7+. If all of that is
false, the prompt renders in `Console` mode (per-segment colours via `Write-Host -ForegroundColor`)
or `Plain` mode (no escapes at all). Literal escape sequences on screen mean the probe believed the
host supported VT when it did not - rare, and fixable with one variable.

**Run.** Look at the test glyph in the `ux doctor` report. It is rendered *after* the capability
probe, so it shows what the host will actually do:

```powershell
ux doctor
```

Then force plain text for the session:

```powershell
$env:UX_NO_COLOR = '1'
```

and re-check. To make it stick across sessions, set the user environment variable:

```powershell
[Environment]::SetEnvironmentVariable('UX_NO_COLOR', '1', 'User')
```

That is a per-user variable, so no admin is involved. Read the doctor report like this:

- glyph renders in colour, no stray escape fragments such as `[32m` -> VT works, keep colour.
- glyph renders in colour but the prompt shows escape text -> set `UX_NO_COLOR=1` as above.
- glyph renders uncoloured but readable -> `Console` mode, which is the correct degraded state.
- glyph is the only thing on the line and the prompt is bare `PS>` -> the prompt itself is failing;
  see section 11.

---

## 5. Missing glyphs and Nerd Font expectations

**Symptom.** You expected a fancy prompt with branch icons and got plain text. Or you see question
marks or empty boxes in the prompt.

**Why.** This is **expected, and by design**. The prompt is pure ASCII in all four themes and the
project ships **no font installer**: installing a font into the system font store needs admin, and
requiring a Nerd Font would exclude exactly the environment this project targets. There are no
glyphs to be missing. Every decoration is either ASCII punctuation or colour.

If you *do* see boxes or question marks, they are not coming from this project:

**Run.**

```powershell
# Is the prompt we rendered pure ASCII?
ux doctor

# Which other prompt/theme modules are loaded in this session?
Get-Module | Where-Object { $_.Name -match 'posh|theme|terminal|icons' }
Get-ChildItem Function:prompt | Select-Object Name, ModuleName
```

There must be exactly one `prompt` function and it is the one this profile defines. If another module
defines `prompt` too, the last one loaded wins - this profile's block runs from your profile, so a
module imported *after* it will override it. Import such modules before the block, or remove them.

Themes are a colour/arrangement choice, not a glyph choice:

```powershell
ux theme list
ux theme set two-line
```

---

## 6. The git segment is missing

**Symptom.** You are in a git repository but the prompt shows no `(branch)`, or it shows the branch
but never a `*` dirty marker, or `+A`/`-B` never appear.

**Why.** Four different causes, and `ux doctor` distinguishes them for you:

| Cause | What you get |
|---|---|
| `git` is not installed | branch and state from `.git` file parsing; **no** dirty/ahead/behind |
| `git` is older than 2.11 | older status format fallback; dirty/ahead-behind may be limited |
| git refuses the repo (`safe.directory`, "dubious ownership") | falls back to file parsing; the refusal reason is surfaced in `ux doctor` |
| `git.useGitBinary` is `false` | file parsing only, intentionally - this is the fast path |

Dirty/ahead/behind also requires the one `git status` call to succeed; branch and state never need
it. A dirty marker may additionally be **up to `git.cacheMs` (default 2 s) out of date** - that is
the documented staleness contract, not a fault.

**Run.**

```powershell
ux doctor                                    # git presence, version, safe.directory status
git --version
git -C . --no-optional-locks status --porcelain=v2 --branch   # what the prompt runs on git 2.15+
git -C . status --porcelain=v2 --branch                       # git 2.11 to 2.14
git -C . rev-parse --is-inside-work-tree
ux config get git.useGitBinary
```

The `--no-optional-locks` flag is deliberate: a plain `git status` inside a prompt can take
`index.lock` and collide with your own git commands. It needs git 2.15 or newer, so the prompt drops
it on older clients and falls back to `status --porcelain -b` below 2.11.

Read the result:

- `git --version` fails -> git is absent. Nothing to fix without admin; the file-parsing path is the
  documented behaviour. Re-enable the `*` marker only by installing git, which needs admin.
- version below 2.11 -> the prompt still works, with the older status format.
- `fatal: detected dubious ownership in repository at ...` -> git 2.35+ refuses repos owned by a
  different user (very common on shared home directories and mapped drives). You can trust that
  one path for your own user, no admin needed:

  ```powershell
  git config --global --add safe.directory 'C:/path/to/repo'
  ```

  This is a trust decision - only add paths you actually control. `ux doctor` reports the same
  refusal so you do not have to guess.
- all of the above fine but still no segment -> check the settings:

  ```powershell
  ux config get prompt.git
  ux config set prompt.git true
  ```

If your shell is on a non-filesystem location (`Registry::`, `Cert:`) the repo walk is skipped by
design, and there is nothing to show.

---

## 7. The prompt is slow

**Symptom.** There is a visible pause every time you press Enter, especially on a network or
redirected path. The prompt itself is fine on a local scratch directory.

**Why.** A prompt renders after *every* command, so anything it does is multiplied by everything you
do. The known slow cases:

- **Huge repository** - `git status` has to examine the working tree.
- **Network drive or UNC path** - directory stats are round-trips, and a repo walk may traverse
  several levels.
- **Dead or disconnected mapped drive** - each stat can block until the network stack gives up.
- **OneDrive-redirected home with the file offline** - reading a placeholder triggers a download.
- **Corporate antivirus filter driver** - every file open is inspected; this one is outside the
  project's control.

The design contains the damage: the repo walk is bounded by `git.maxDepth`, a path that turns out
unreachable is cached as "no repo" so a dead mapped drive costs **one** stat per session rather than
one per prompt, results are cached for `git.cacheMs`, and if a `git status` exceeds
`slowThresholdMs` twice in a session, git is not called again for the rest of that session -
the prompt degrades to file parsing automatically.

**Run.**

```powershell
ux doctor     # last load ms, and an Offline-attribute warning for the install dir
ux config get git.cacheMs
ux config get git.slowThresholdMs
```

Fixes, cheapest first:

```powershell
ux config set git.useGitBinary false   # branch and state only, no git process per prompt
ux config set prompt.git false         # drop the git segment entirely
ux config set git.maxDepth 8           # shallower repo walk on deep network paths
ux config set git.cacheMs 5000         # accept staler dirty markers for fewer status calls
```

If the install directory itself lives on a OneDrive path that is offline, `ux doctor` warns about the
`Offline` attribute. Re-run the installer with `-InstallDir` pointed at a local path, or set
`UX_INSTALL_DIR` to a local directory, so loading the profile does not trigger a sync.

If numbers stay high with `git.useGitBinary false` and the install dir local, the remaining cost is
your host and its antivirus: check the last load ms in `ux doctor` before and after adding the
profile directory to any AV exclusion your organisation allows.

---

## 8. A wrapper is shadowing a command I need

**Symptom.** A name you used to pass cmdlet parameters to now rejects them - `ls -Path .`,
`cat -Encoding UTF8` - or a script that relied on `Get-ChildItem`-style parameters through `ls`,
`cp`, `mv`, `rm`, `ps` or `kill` behaves differently. Also: `type file.txt` stops working, and `curl`
and `wget` are gone as commands.

**Why.** Providing `ls`, `ll`, `la`, `cd`, `cat`, `touch`, `mkdir`, `rm`, `cp`, `mv`, `grep`, `find`,
`head`, `tail`, `wc`, `which`, `env`, `export`, `unset`, `ps`, `kill` and `unzip` as functions
necessarily means those names now resolve to the wrappers. On Windows, aliases resolve **before**
functions, so a function cannot shadow an alias at all - the loader snapshots and then removes the
aliases that carry the wrapped names (for example `ls`, `cat`, `cd`, `rm`, `cp`, `mv`, `ps`, `kill`,
`wc`) so the functions can win.

Two consequences worth knowing:

- The underlying cmdlets are **not** modified. `Get-ChildItem`, `Remove-Item`, `Set-Location` and the
  rest keep every parameter they ever had. It is the *name* you type that changed meaning.
- `curl`, `wget` and `type` are **not** wrapped, only snapshot-shadowed so a restore is faithful. That
  means their aliases are removed too. `type` is the usual casualty (use `Get-Content`);
  for `curl`, call `curl.exe` explicitly - the real executable is present on Windows 10 1803 and
  later, and preferring it is the documented outcome.

**Run.** Check what a name currently resolves to:

```powershell
Get-Command Get-ChildItem -All | Select-Object CommandType, Name, Source
Get-Command rm, ls, cd | Select-Object CommandType, Name
```

Bypass one command without giving anything up - module-qualify it:

```powershell
Microsoft.PowerShell.Management\Get-ChildItem -Path .
Microsoft.PowerShell.Management\Remove-Item -LiteralPath .\thing
Microsoft.PowerShell.Management\Set-Location -Path C:\
```

Or put the original names back for the rest of the session:

```powershell
ux restore-aliases
```

That replays the load-time snapshot; aliases are restored fully, functions best-effort. Confirm the
wrappers are still where they should be, or that they are gone:

```powershell
ux verify
```

If you want a permanently cleaner session, remove the wrappers you never use - but note that the
profile defines them together, so the supported ways are `ux restore-aliases` (all) or
module-qualifying the call (one).

---

## 9. The install directory was deleted but the block remains

**Symptom.** `ux` is not recognised and no Unix commands exist, but there is no error at all - or a
single short hint about a missing entry point on each new shell.

**Why.** The profile block is a self-contained ~10-line snippet that only dot-sources the entry
point. It deliberately checks whether the entry point file exists *before* trying to load it, and
when it is missing the block does nothing - no stack trace, no error, no half-loaded session. That
is one of the project's core promises: a broken install can never brick the shell. Silence is
therefore an expected symptom, which is exactly why it is listed here.

**Run.**

```powershell
# See the block and what it points at
Select-String -Path $PROFILE.CurrentUserAllHosts -Pattern 'unix-powershell' -Context 0,12 -SimpleMatch
$HOME
Test-Path (Join-Path $HOME '.unix-powershell\profile\profile.ps1')
Test-Path (Join-Path $HOME '.unix-powershell\ux.ps1')
```

Two ways forward:

1. **Reinstall** with the one-liner or `-SourceDir` (README, *Install*). The installer replaces the
   existing block rather than duplicating it, so the state fixes itself. Your `config.json` is gone
   with the directory, but nothing else on the machine was ever touched.
2. **Remove the block by hand.** Open `$PROFILE.CurrentUserAllHosts` in an editor, delete everything
   from the `# BEGIN unix-powershell ...` line through the `# END unix-powershell ...` line, save, and
   open a new shell. Nothing outside those markers belongs to this project.

If the hint says the entry point exists but loading still fails, go to section 11.

---

## 10. Emergency exits: `UX_DISABLE` and `ux disable`

When you need a normal PowerShell session *right now*, there are two exits. Both are per-user and
need no admin.

**For the current session and its children:**

```powershell
$env:UX_DISABLE = '1'
```

The profile block checks `UX_DISABLE` before doing anything, so every shell started from this one is
plain PowerShell. This does **not** unload anything already defined in the shell you are typing in -
the wrappers are ordinary functions once loaded. To clear them in the current session:

```powershell
ux restore-aliases
```

**To make it stick across all sessions, reversibly:**

```powershell
ux disable     # creates the marker file <install>\.disabled; the block consults it
ux enable      # removes it again
```

The marker file is a file in your own home directory, so `ux disable` survives reboots, GPO refreshes
and profile re-imports without needing admin. It lives *inside* the install directory, though, so a
reinstall or `ux uninstall` takes it with them - re-run `ux disable` if the project comes back and you
want it to stay off. `ux doctor` reports whether the marker is present.

**To remove the project entirely**, see *Uninstall* in the README: `ux uninstall`, or
`powershell -NoProfile -File "$HOME\.unix-powershell\ux.ps1" uninstall` when no profile loads.

None of these is destructive: each is reversible, and none of them touch anything outside
`%USERPROFILE%`.

---

## 11. Reading the one-line load failure message

**Symptom.** A new shell starts with a yellow line (or two) beginning with `[unix-powershell]`, and
the rest of the shell works normally.

**Why.** The profile block wraps the dot-source in `try/catch` and prints only what it needs:

```
[unix-powershell] load failed: <the exception message>
[unix-powershell] diagnose: powershell -NoProfile -File "<install>\ux.ps1" doctor | bypass: set UX_DISABLE=1
```

There is no stack trace on purpose: a prompt is not a debugging console, and a wall of red on every
new shell is how people conclude their shell is broken. The first line is the exception message from
the failed load; the second is the exact command to run, plus the bypass.

**Run.** Copy the `diagnose:` command it printed - it uses `-NoProfile`, so it runs even when your
profile is what is broken:

```powershell
powershell -NoProfile -File "$HOME\.unix-powershell\ux.ps1" doctor
```

Then read the first line against this table:

| Message contains | Likely cause | Go to |
|---|---|---|
| `running scripts is disabled` / `cannot be loaded` / `not digitally signed` | execution policy; on an `AllSigned` GPO the unsigned block is expected to be refused | section 2, then README *Execution policy* |
| `Cannot find path` / `does not exist` | install directory moved or deleted | section 9 |
| `Unexpected token` / `Missing closing` / `ParserError` | a truncated or hand-edited file | reinstall (README, *Install*) |
| `Cannot index into a null array` / `property cannot be found` | a strict-mode interaction; the runtime is written to be strict-mode-proof, so this one is a real bug | collect the stack trace with the manual dot-source below |
| `Access is denied` | the install directory is not readable by your account, or sits on a path your policy blocks | reinstall with `-InstallDir` pointed at a directory you own |
| nothing from `diagnose:` | the block's own paths are wrong | section 9 |

If the diagnose command produces a full report but the profile still fails to load, the difference is
the environment the block runs in. Start a shell with the block inert, then load the entry point by
hand so the error surfaces with a full stack and line numbers:

```powershell
$env:UX_DISABLE = '1'
powershell -NoProfile
# in the new shell, where the block is inert:
. (Join-Path $HOME '.unix-powershell\profile\profile.ps1')
```

The uncaught error that follows is the real one. It is safe to run: the failure will be the same one
the block caught, and nothing has been loaded yet that could make it worse.
