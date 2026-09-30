# CrowdStrike MCP server — KSM edition (Windows) setup kit

## Why this is a kit and not a finished install

This session runs in an ephemeral Linux container in the cloud, not on your
Windows machine. Confirmed from inside it:

```
$ uname -a
Linux vm 6.18.44-fc-v50 ... x86_64 GNU/Linux
$ echo "[$LOCALAPPDATA]" ; echo "[$USERPROFILE]"
[]
[]
$ command -v py powershell.exe pwsh
(nothing)
```

So there is no `py` launcher, no `%LOCALAPPDATA%`, no `%USERPROFILE%\.claude\settings.json`,
and no PowerShell here. The `~/.claude/` directory that does exist belongs to
the container's root user and is discarded when the container is reclaimed — it
is not your Claude Code config. Anything I installed here would be thrown away
and would register no MCP server for you.

I also did not ask for your one-time KSM access token, and you should not paste
it into this chat. It would travel to a container that cannot use it, it is
single-use (so spending it here would burn it), and the long-lived device
credentials it mints would be destroyed with the container. Run
`init-profile.ps1` locally instead and pass the token there.

What is here is the whole job, scripted, so the local part is three commands.

## Files

| File | Covers | What it does |
|---|---|---|
| `setup.ps1` | steps 1–5 | Finds Python 3.11, creates `%LOCALAPPDATA%\mcp-servers\crowdstrike-mcp-ksm\`, builds the venv, installs the pinned packages, writes `run.ps1`, backs up and patches `settings.json`. Stops before anything needing the token. |
| `run.ps1` | step 4 | The launcher, verbatim as specified. `setup.ps1` writes its own copy; this one is here for review/diff. |
| `init-profile.ps1` | steps 7–10 | Takes the token, inits the device profile, locks down `keeper.ini` with `icacls`, auto-discovers the record UID, writes `secrets.env`, runs the verifications. |
| `verify-launch.ps1` | pre-step-11 | Optional smoke test: proves `ksm exec` resolves the creds, without printing them. |
| `settings-snippet.json` | step 5 | The entry to paste by hand if `setup.ps1` can't parse your `settings.json`. |

## Run it

From an ordinary (non-elevated) PowerShell prompt, as the user who runs Claude Code:

```powershell
# steps 1-5
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\setup.ps1

# steps 7-10 -- your one-time token goes here, on your own machine only
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\init-profile.ps1 -Token <ONE-TIME-TOKEN>

# optional: confirm creds resolve before you restart
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\verify-launch.ps1
```

If step 1 reports no Python 3.11, install it and re-run:
`winget install --id Python.Python.3.11 -e`

If `init-profile.ps1` finds more than one record shared to the Application it
prints the titles and UIDs and exits rather than guessing. Pick one and re-run
with `-RecordUid <UID>`; `keeper.ini` is already bound by then, so that run
resumes at step 9. If it finds zero records, the Keeper sharing setup needs
fixing — the folder or record holding the Falcon credentials has to be added to
the Secrets Manager Application the token was issued for.

### Step 11 — restart Claude Code

Fully quit: **File > Exit**, or right-click the taskbar/tray icon and choose
**Exit**. Closing the window is not enough; check Task Manager for a lingering
process. MCP servers are only loaded at launch, so `crowdstrike-ksm` will not
appear until you reopen.

### Step 12 — connectivity check

After restarting, in your local Claude Code session run `falcon_check_connectivity`
and `falcon_list_enabled_modules` against `crowdstrike-ksm`. I cannot run these
for you from here: the tools only exist in the process that loaded the server,
which is your local client. Paste the output back here if anything looks wrong.

## Notes on the spec

- **Pinned versions both exist on PyPI** (checked): `falcon-mcp==0.15.0` and
  `keeper-secrets-manager-cli==1.4.0`. Note that `falcon-mcp` is at 0.19.0
  upstream, so 0.15.0 is a deliberate pin, not the latest. `falcon-mcp` declares
  `requires_python >=3.11`, so the 3.11 requirement is real.
- **`run.ps1` is byte-for-byte as specified**, with two line-wraps from the
  paste repaired: the `Write-Error` string and the final `ksm exec` line were
  each broken mid-statement and would not have parsed. Nothing else changed.
- **Two cosmetic quirks left as-is** in `run.ps1`, since you asked for exactly
  that content: `exit 1` after `Write-Error` is unreachable under
  `$ErrorActionPreference = "Stop"` (the `Write-Error` already terminates), and
  the final line relies on parenthesized expressions being evaluated in
  argument position after `--`, which works but reads oddly. Neither breaks
  anything.
- **`icacls` fallback added**: `init-profile.ps1` tries the bare
  `$env:USERNAME:(R,W)` form first and retries as `DOMAIN\user` if the bare form
  is rejected, which domain-joined machines sometimes do.
- **`settings.json` patching is non-destructive**: it backs up to `.bak`, reads
  the existing JSON, adds only `mcpServers.crowdstrike-ksm`, and prints the full
  list of entries afterwards so you can see nothing was dropped. If your
  `settings.json` contains comments or trailing commas it cannot be parsed
  safely, so the script changes nothing and tells you to paste
  `settings-snippet.json` in by hand.
- **Not syntax-checked.** No PowerShell runtime exists in this container, so
  these scripts have been written and reviewed carefully but never executed.
  Read `setup.ps1` before running it.
