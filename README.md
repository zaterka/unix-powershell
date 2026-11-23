# unix-powershell

Unix-style commands and a git-aware prompt for Windows PowerShell - installed in one command,
into your own profile, with **no administrator rights and no dependencies**.

PowerShell's built-in `ls`, `rm` and friends are aliases for cmdlets, so they take PowerShell
parameters rather than Unix flags: `ls -la` and `rm -rf` are rejected outright. This profile adds
the small set of commands where that gap actually matters, wraps them as ordinary PowerShell
functions, and gives you a prompt that looks and behaves like a shell you already know.

Everything is per-user. Nothing is installed machine-wide, nothing is added to `PATH`, no module is
required, and no network call is made when a shell starts.

```
PS ~/code/api (main*) $ ls -la
PS ~/code/api (main*) $ rm -rf build
PS ~/code/api (main*) $ grep -rn TODO src
```

## What it is, and what it is not

It is a **drop-in profile**: one command adds a delimited block to your `$PROFILE`, copies a few
PowerShell files into `%USERPROFILE%\.unix-powershell`, and that is the whole footprint. Delete it
with one command and your session is exactly as it was.

It is **not** a Unix emulator, not WSL, and not a replacement for PowerShell. It does not try to
reimplement `sed` or `awk`, it does not shadow a cmdlet you rely on, and it does not pretend
`/bin/bash` exists. Where a stock PowerShell prompt already does the right thing, this profile
stays out of the way - see [what is deliberately not wrapped](#what-is-deliberately-not-wrapped).

## Requirements

- Windows PowerShell **5.1** (the version that ships with Windows) or PowerShell **7+**
- Windows 10 or later

That is the whole list. Specifically **not** required:

| Not needed | Because |
|---|---|
| Administrator rights | everything is per-user, under `%USERPROFILE%` |
| WSL or any Linux subsystem | the commands are PowerShell functions |
| Windows Terminal | works in the stock console, with or without colour support |
| A Nerd Font | the prompt is pure ASCII by design - no glyphs to be missing |
| oh-my-posh, Pester, any PowerShell module | zero dependencies |
| winget, Chocolatey, the PowerShell Gallery | nothing is installed |
| Internet access at shell startup | the profile never touches the network |

## Install

Pinned to a tag, run from any shell:

```powershell
powershell -NoProfile -Command "iwr https://raw.githubusercontent.com/zaterka/unix-powershell/v0.1.0/install.ps1 -UseBasicParsing | iex"
```

`-NoProfile` is deliberate: it keeps a half-loaded profile from being involved in its own
installation.

Prefer to review the code first? Extract a release zip (or clone the repository) and install from
the checkout - no network is used at all:

```powershell
powershell -NoProfile -File .\install.ps1 -SourceDir .
```

The installer writes, and only writes:

| Path | What |
|---|---|
| `%USERPROFILE%\.unix-powershell\` | the profile files, plus a `config.json` and a `manifest.json` |
| `$PROFILE.CurrentUserAllHosts` | one delimited `# BEGIN unix-powershell` ... `# END unix-powershell` block |

Your existing profile content is preserved, backed up once, and never rewritten outside the block.
Each file is verified against the SHA-256 in `manifest.json` before anything is activated, and the
install is staged next to the target so a failed download cannot damage a working install.

Then start a new shell and check it:

```powershell
ux doctor
```

### What the hashes do and do not prove

The manifest is fetched over the same channel as the files, so it proves **transport integrity** -
nothing was truncated or mangled on the way - not authorship. If you need more than that, install
with `-SourceDir` from a checkout you reviewed and compare it against the published `SHA256SUMS`.

## What is deliberately not wrapped

Only **19** commands are wrapped, because a wrapper is worth having only where the native command
rejects the Unix spelling or does something wrong. The audit that decided this:

| Command | Native PowerShell | Verdict |
|---|---|---|
| `ls -la` | `A parameter cannot be found that matches parameter name 'la'` | **wrapped** |
| `ls -l` | silently binds `-l` to `-LiteralPath`, not a long listing | **wrapped** |
| `rm -rf` | `A parameter cannot be found that matches parameter name 'rf'` | **wrapped** |
| `mv -f` | `parameter name 'f' is ambiguous. Possible matches: -Force -Filter` | **wrapped** |
| `kill -9 1234` | `A positional parameter cannot be found that accepts argument '1234'` | **wrapped** |
| `mkdir -p dir` | creates `dir` **and a stray directory literally named `-p`** | **wrapped** |
| `cd -` | missing in 5.1 (PowerShell gained it only in 6.2) | **wrapped** |
| `cat f1 f2` | `Get-Content` already does this | not wrapped |
| `cp -r src dst` | `Copy-Item` binds `-r` to `-Recurse` already | not wrapped |
| `ps name` | `Get-Process` alias already filters by name | not wrapped |
| `touch`, `grep`, `head`, `tail`, `wc`, `find`, `which`, `env`, `export`, `unset`, `unzip` | the command does not exist at all | **wrapped** |

Two of those deserve a note. Windows ships `find.exe` and `where.exe`, which are *different tools*
from Unix `find` and `which`; this profile's `find` and `which` shadow those names on purpose. And
`curl`, `wget` and `type` are **un-shadowed rather than wrapped**: their built-in aliases point at
`Invoke-WebRequest`/`Get-Content`, so removing them lets a real `curl.exe` be found and lets you
call the cmdlets by their proper names.

If you want any of the three unwrapped commands back as a wrapper, it is one entry in
`WrapperNames` and one function - but check the table above first.

## Command reference

### Unix commands (19 wrappers)

All wrappers are plain (non-advanced) PowerShell functions. That is a hard requirement, not a style
choice: an advanced function with `[CmdletBinding()]` cannot receive clustered Unix flags - `rm -rf`
fails parameter binding with *"A parameter cannot be found that matches parameter name 'rf'"*. In a
plain function the unbound tokens arrive in `$args` verbatim and are expanded by a shared tokenizer,
so `-rf`, `-la` and `-9` all work.

| Command | Maps to | Supported flags | Notable behaviour |
|---|---|---|---|
| `ls` | `Get-ChildItem` | `-a` (hidden), `-R` (recurse), `-1` (names only), `-d` (the item itself), `-l` | `-l` returns objects - PowerShell's default table already *is* the long format. Never formatted text, so `ls -l \| Where-Object Length -gt 1mb` works |
| `ll` / `la` | `ls -l` / `ls -la` | forwards its arguments | same as `ls` |
| `cd` | `Set-Location` | `-`, `~`, `..`, bare path | `cd -` returns to the previous directory (including on 5.1, which lacks it); a bad target errors instead of silently staying put |
| `touch` | `New-Item` / set `LastWriteTime` | `[file...]` | creates files only, never parent directories |
| `mkdir` | `New-Item -ItemType Directory` | `-p` (parents, no error if it exists) | without `-p`, an existing directory is an error; `-p` is consumed as a flag, so no stray `-p` directory is created |
| `rm` | `Remove-Item` | `-r`, `-f` | never prompts (`-Confirm:$false`); refuses drive roots, share roots and `$HOME`; on 5.1 refuses a recursive delete across a junction instead of following it |
| `mv` | `Move-Item` | `-f`, `src... dest` | without `-f` an existing destination is refused; with `-f` it is replaced (5.1 `Move-Item -Force` does not overwrite) |
| `grep` | `Select-String` | `-i`, `-F`, `-E`, `-v`, `-n`, `-r`, `-l`, `-c`, `-q`, `PATTERN [path...]` | **case-sensitive** and **literal-match** by default, the opposite of `Select-String`; `-i` ignores case, `-E` switches to .NET regex; output is `path:text`, or `path:line: text` with `-n`; sets `$LASTEXITCODE` |
| `find` | `Get-ChildItem` | `[path] -name PAT`, `-type f` or `-type d` | prints full paths; name matching is **case-insensitive on every platform**; sets `$LASTEXITCODE` (0 found, 1 none, 2 error) |
| `head` | `Get-Content -Head` / pipe | `-n N`, `-N` (default 10) | works on pipeline input as well as files |
| `tail` | `Get-Content -Tail` / pipe | `-n N`, `-N`, `-f` | `-f` is `-Wait`: it needs an extra Enter to stop |
| `wc` | counted directly | `-l`, `-w`, `-c` | for files `-c` is the exact byte length; on piped input `-c` counts characters |
| `which` | `Get-Command` | `NAME` | resolves alias -> function -> cmdlet -> application and prints what it found |
| `env` | `Get-ChildItem Env:` | optional `NAME` filter | prints `NAME=VALUE` |
| `export` | `Set-Item Env:` | `NAME=VALUE` | a bare `NAME` is a no-op |
| `unset` | `Remove-Item Env:` | `NAME...` | missing names are ignored |
| `kill` | `Stop-Process` | `-9`, `-15`, `PID...` | the signal number is accepted and ignored - Windows has no SIGTERM/SIGKILL distinction here |
| `unzip` | `Expand-Archive` | `-d DEST`, `-o` | `-o` overwrites instead of erroring |

### `ux` verbs

| Verb | Behaviour |
|---|---|
| `ux help`, `ux version` | usage table / version, host and config path |
| `ux doctor` | environment report: PowerShell version and edition, host, LanguageMode, execution policy per scope, VT and colour capability with a visible test glyph, install dir, config path, git presence/version, theme, profile block present, last load time. `-Json` for machine output |
| `ux verify` | every wrapper resolves to `CommandType Function`, no shadowing alias left, config parses, manifest matches the files on disk |
| `ux theme [list\|show\|set <name>]` | list, show, or persist a theme and re-render |
| `ux config [path\|edit\|get <key>\|set <key> <value>]` | dotted access with typed coercion; `edit` opens `$env:EDITOR`, else `notepad.exe` |
| `ux reload` | re-read the profile in the current session |
| `ux update [-Check]` | prints a pasteable, version-pinned installer command (it never downloads by itself); `-Check` compares the remote manifest version only: exit 0 up to date, 1 differs, 2 could not check |
| `ux disable` / `ux enable` | toggle the marker file that makes the profile block do nothing |
| `ux restore-aliases` | put back the aliases this profile removed, for this session |
| `ux uninstall [-Force]` | remove the profile block and delete the install directory |

## The prompt

Four built-in themes, all pure ASCII, so nothing depends on a Nerd Font:

| Theme | Looks like |
|---|---|
| `ascii` (default) | `PS ~/repo (main*) $ ` |
| `classic` | `user@host:~/repo (main +1-0)$ ` |
| `blocks` | `[user@host] > [~/repo] > [main*] > $ ` |
| `two-line` | `~/repo (main*)` then `$ ` on the next line |

```powershell
ux theme set classic      # persists in config.json
ux theme list             # compare all four
```

Colour adapts to the host: ANSI escape sequences where the console understands them, per-segment
`Write-Host -ForegroundColor` where it does not, and plain text with `UX_NO_COLOR=1` or
`ux config set ui.color never`.

### Git information

The git segment shows the branch, `*` for a dirty working tree, `+A`/`-B` for ahead/behind, a
`|STATE` marker while a merge, rebase, cherry-pick, revert or bisect is in progress, and `(new)` for
a branch with no commits yet.

The branch name comes from reading `.git` directly, so it works **even if git is not installed or
not on `PATH`**. Dirty/ahead/behind need the git binary; without it those markers are simply absent
rather than wrong. At most one `git` process runs per prompt, and after two slow calls the session
stops calling git altogether.

The dirty marker can lag by up to `git.cacheMs` (default 2 seconds): `.git` file timestamps cannot
see working-tree edits, so a short cache is the honest compromise. Lower it if you want fresher
output:

```powershell
ux config set git.cacheMs 500
```

## Configuration

`config.json` lives in the install directory and every key is optional:

```json
{
  "version": 1,
  "theme": "ascii",
  "prompt": { "pathStyle": "full", "git": true, "user": true, "host": false,
              "time": false, "symbol": "$", "exitCode": true },
  "git":    { "useGitBinary": true, "untrackedFiles": false, "cacheMs": 2000,
              "slowThresholdMs": 250, "maxDepth": 40 },
  "ui":     { "color": "auto", "banner": true }
}
```

Change it with `ux config` (typed, validated, persisted) or edit it directly:

```powershell
ux config get git.cacheMs
ux config set theme two-line
ux config set prompt.host true
ux config edit
```

Environment variables override the file for a single session:

| Variable | Effect |
|---|---|
| `UX_DISABLE=1` | the profile block does nothing at all - the project is inert for that session |
| `UX_QUIET=1` | suppress the load-time banner and notices |
| `UX_NO_COLOR=1` | no colour and no escape sequences |
| `UX_THEME=` | theme for this session only (does not touch `config.json`) |
| `UX_INSTALL_DIR=` | install root, for a non-default location |
| `UX_PROXY=` | proxy URI for the installer and `ux update` |
| `UX_UPDATE_URL=` | override the manifest URL used by `ux update -Check` |
| `UX_DEBUG=1` | extra diagnostics on the load and update paths |

## Known divergences

1. **Shell globs are not expanded.** PowerShell has no shell to expand `*` before the command runs,
   and every wrapper uses `-LiteralPath` so that filenames containing `[` `]` `*` `?` work. So
   `ls *.txt` looks for a file literally named `*.txt`. Use `ls -Filter *.txt`, or
   `Get-ChildItem *.txt` (which does expand), or `grep -r`, which is usually what you wanted.

2. **A standalone `--` cannot reach a wrapper.** PowerShell consumes `--` as its own
   end-of-parameters marker, and its lexer splits an unquoted `-weird.txt` into `-weird` + `.txt`.
   Quote the name (`cat -- '-weird.txt'`) or use `./-weird.txt`.

3. **Every wrapper except `env` sets `$LASTEXITCODE`** (0 success, non-zero failure; `grep` and
   `find` use 1 for "no match", 2 for "error"). Branch on `$LASTEXITCODE`, never on `$?`: `$?`
   describes the function call, and stays `True` even when the wrapper handled an error.

4. **`ls` returns objects, not columns.** Select properties instead of parsing text:
   `ls | Sort-Object Length | Select-Object -Last 5`.

5. **`grep` is literal and case-sensitive by default.** `.`, `*`, `[`, `(`, `|` are literals unless
   you pass `-E`. `-i` ignores case.

6. **`wc -c` on piped input counts characters, not bytes.** Files use their exact byte length.

7. **`tail -f`** is `Get-Content -Wait`: it needs an extra Enter to stop and is unreliable over SMB.

8. **`mv -f` is emulate-and-overwrite**, not atomic: it removes the destination first.

9. **Regex is .NET, not BRE/ERE.** `-E` gives you .NET regular expressions.

## Execution policy

Execution policy decides whether the profile block can load at all. Three tiers:

| Tier | Behaviour |
|---|---|
| `RemoteSigned` / `Unrestricted` (overridable) | **Works.** `Unblock-File` is applied during install, so the files are not blocked as "downloaded" |
| `AllSigned` via Group Policy | The block cannot load unsigned. Two no-admin routes, below |
| `Restricted`, or AppLocker/WDAC denial | **Not supported** without an administrator. `ux doctor` says so instead of guessing |

Check where you stand:

```powershell
Get-ExecutionPolicy -List
```

A `MachinePolicy` or `UserPolicy` row that is not `Undefined` comes from Group Policy and wins over
every other scope - including `-ExecutionPolicy` on the command line.

**If you are on `AllSigned`,** execution policy does not apply to `-Command` strings, so a one-time
bootstrap always works:

```powershell
powershell -NoProfile -Command "iwr https://raw.githubusercontent.com/zaterka/unix-powershell/v0.1.0/install.ps1 -UseBasicParsing | iex"
```

That installs the files, but the profile block is still an unsigned script. To let it load, trust a
code-signing certificate of your own (per-user stores, no administrator) and sign the installed
scripts:

```powershell
$cert = New-SelfSignedCertificate -Type CodeSigningCert -Subject "CN=$env:USERNAME-unix-powershell" -CertStoreLocation Cert:\CurrentUser\My
Export-Certificate -Cert $cert -FilePath "$env:TEMP\unix-powershell.cer" | Out-Null
Import-Certificate -FilePath "$env:TEMP\unix-powershell.cer" -CertStoreLocation Cert:\CurrentUser\Root | Out-Null
Import-Certificate -FilePath "$env:TEMP\unix-powershell.cer" -CertStoreLocation Cert:\CurrentUser\TrustedPublisher | Out-Null
Get-ChildItem "$HOME\.unix-powershell" -Recurse -Filter *.ps1 | Set-AuthenticodeSignature -Certificate $cert
```

Re-run the signing step after an update, since the installer replaces the files. If policy forbids
adding certificates to your own stores, stop here - `AllSigned` with no trust exception is a policy
decision, not a bug in this profile.

## Update and uninstall

```powershell
ux update      # prints the exact command for the next version
ux uninstall   # remove the block, then the install directory
```

`ux uninstall` removes only the delimited block, leaving every line of your own profile content
exactly as it was, then deletes the install directory. Because that last step is recursive, it
refuses when the path is a drive or share root, is your home directory, contains your current
directory, or does not look like an install.

Without a working profile, use the standalone entry point or the repository script:

```powershell
powershell -NoProfile -File "$HOME\.unix-powershell\ux.ps1" uninstall
powershell -NoProfile -File .\uninstall.ps1 -Force
```

Nothing was ever written outside `%USERPROFILE%`, so there is nothing else to clean up: no registry
keys, no machine-wide files, no scheduled tasks.

## Performance

- **Startup**: roughly 250-450 ms for the whole profile in an emulated Linux test container, of
  which ~95 ms is a bare five-function profile - that is interpreter warm-up, not this code. Native
  x86_64 hardware is considerably faster, and `ux doctor` reports your actual load time.
- **What it does not do at startup**: no network, no jobs, no `Add-Type`, no module import, no
  background runspace.
- **Per prompt**: at most one `git` process, and only when the cache has expired. The git-free path
  is a handful of file reads.
- **On a machine with an aggressive antivirus filter driver**, every script load is slower. Set
  `ux config set prompt.git false` to drop git, or `ux config set git.useGitBinary false` to keep
  the branch but read it from files only.

## Troubleshooting

| Symptom | Where to look |
|---|---|
| `ux` is not recognised | the profile block did not load - run `powershell -NoProfile -File "$HOME\.unix-powershell\ux.ps1" doctor` |
| `... cannot be loaded because running scripts is disabled` | see *Execution policy* above |
| No colour, or literal escape codes | `ux doctor` shows VT capability; force plain with `UX_NO_COLOR=1` |
| No `(branch)` in the prompt | `ux doctor` distinguishes "git not installed" from "git refused this repo" |
| A wrapper shadows something you need | call the cmdlet by module-qualified name (`Microsoft.PowerShell.Management\Get-ChildItem`) or run `ux restore-aliases` |
| Need it gone right now | `UX_DISABLE=1` for this session, or `ux disable` |
| Anything else | `docs/TROUBLESHOOTING.md`, then `ux verify` |

## Design notes

If you are reading the source, these constraints explain most of the odd-looking code:

- **Windows PowerShell 5.1 is the baseline.** No `&&`, no ternary, no `??`, no `?.`, no `$PSStyle`,
  no `$IsWindows`. PowerShell 7 works too, but 5.1 is what has to work.
- **Pure ASCII, everywhere** - including the prompt and the docs. 5.1 mis-decodes BOM-less non-ASCII
  script files, and a stock console font has no glyphs for fancy separators.
- **No `Invoke-Expression`, `Add-Type`, COM or reflection**, and no .NET static calls in the runtime
  path, so the profile keeps working in Constrained Language Mode.
- **Strict-mode proof**: it loads under `Set-StrictMode -Version Latest`, because you may set that in
  your own profile.
- **Plain functions only** for the wrappers, so clustered flags survive.

The full design record, including every rejected alternative and the verification matrix, is in
`PLAN.md`. Tests live in `test/` and run with `./test/docker-verify.sh` (PowerShell in Docker, no
Windows needed); the Windows-specific checks are listed in `test/WINDOWS-CHECKLIST.md`.

## License

MIT - see `LICENSE`. The idea comes from
[CrazyWolf13/unix-pwsh](https://github.com/CrazyWolf13/unix-pwsh), reimplemented here without the
admin requirements, module dependencies or network calls.
