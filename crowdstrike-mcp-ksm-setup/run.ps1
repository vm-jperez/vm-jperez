# CrowdStrike MCP server launcher — KSM edition (Windows).
# Falcon API creds are fetched from Keeper at launch and injected into the
# child process environment only; they are never written to disk.
$ErrorActionPreference = "Stop"
$DIR = $PSScriptRoot

# KSM device profile lives inside this directory (created by `ksm profile init`).
$env:KSM_INI_FILE = Join-Path $DIR "keeper.ini"
if (-not (Test-Path $env:KSM_INI_FILE)) {
    Write-Error "FATAL: $($env:KSM_INI_FILE) not found. Run the one-time init first:`n  cd `"$DIR`"; .\.venv\Scripts\ksm.exe profile init --token <ONE-TIME-TOKEN>"
    exit 1
}

# Load keeper:// references (no secrets in the file itself).
Get-Content (Join-Path $DIR "secrets.env") | ForEach-Object {
    if ($_ -match '^\s*#' -or $_ -match '^\s*$') { return }
    $parts = $_ -split '=', 2
    Set-Item -Path "Env:$($parts[0])" -Value $parts[1]
}

# ksm exec resolves keeper:// values and spawns the server with real creds in env.
& (Join-Path $DIR ".venv\Scripts\ksm.exe") exec -- (Join-Path $DIR ".venv\Scripts\python.exe") -m falcon_mcp.server
