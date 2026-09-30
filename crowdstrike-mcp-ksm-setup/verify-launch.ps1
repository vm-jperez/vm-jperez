<#
Optional pre-restart smoke test: proves that keeper.ini + secrets.env resolve to
real Falcon credentials through `ksm exec`, WITHOUT printing the values.

    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\verify-launch.ps1
#>
[CmdletBinding()]
param([string]$InstallDir = (Join-Path $env:LOCALAPPDATA "mcp-servers\crowdstrike-mcp-ksm"))

$ErrorActionPreference = "Stop"
Set-Location $InstallDir
$env:KSM_INI_FILE = Join-Path $InstallDir "keeper.ini"

Get-Content (Join-Path $InstallDir "secrets.env") | ForEach-Object {
    if ($_ -match '^\s*#' -or $_ -match '^\s*$') { return }
    $parts = $_ -split '=', 2
    Set-Item -Path "Env:$($parts[0])" -Value $parts[1]
}

$probe = @'
import os
for k in ("FALCON_CLIENT_ID", "FALCON_CLIENT_SECRET", "FALCON_BASE_URL"):
    v = os.environ.get(k, "")
    if not v:
        print(f"{k}: MISSING")
    elif v.startswith("keeper://"):
        print(f"{k}: NOT RESOLVED (still a keeper:// reference)")
    elif k == "FALCON_BASE_URL":
        print(f"{k}: {v}")
    else:
        print(f"{k}: resolved, {len(v)} chars")
import falcon_mcp
print("falcon_mcp import: ok")
'@

& (Join-Path $InstallDir ".venv\Scripts\ksm.exe") exec -- (Join-Path $InstallDir ".venv\Scripts\python.exe") -c $probe
