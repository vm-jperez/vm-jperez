<#
Steps 1-5 of the CrowdStrike MCP (KSM edition) setup, for Windows.

Run from an ordinary (non-elevated) PowerShell prompt as the user who will be
running Claude Code:

    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\setup.ps1

It stops before anything that needs your one-time KSM access token. Once this
finishes, run init-profile.ps1 with the token to do steps 7-10.
#>
[CmdletBinding()]
param(
    [string]$InstallDir = (Join-Path $env:LOCALAPPDATA "mcp-servers\crowdstrike-mcp-ksm"),
    [string]$SettingsPath = (Join-Path $env:USERPROFILE ".claude\settings.json")
)

$ErrorActionPreference = "Stop"

function Write-Step($n, $msg) { Write-Host "`n[$n] $msg" -ForegroundColor Cyan }

# ---------------------------------------------------------------- step 1
Write-Step 1 "Locating Python 3.11"

$pyExe = $null
$pyPre = @()
$probe = {
    param($cmd, $pre = @())
    $old = $ErrorActionPreference; $ErrorActionPreference = "Continue"
    try { $out = & $cmd @pre --version 2>&1 } catch { $out = "" }
    $ErrorActionPreference = $old
    return ($out | Out-String).Trim()
}

if (Get-Command py -ErrorAction SilentlyContinue) {
    $v = & $probe "py" @("-3.11")
    Write-Host "    py -3.11 --version -> $v"
    if ($v -match '^Python 3\.11\.') { $pyExe = "py"; $pyPre = @("-3.11") }
} else {
    Write-Host "    'py' launcher not found, falling back to 'python'"
}

if (-not $pyExe -and (Get-Command python -ErrorAction SilentlyContinue)) {
    $v = & $probe "python"
    Write-Host "    python --version -> $v"
    if ($v -match '^Python 3\.11\.') { $pyExe = "python"; $pyPre = @() }
}

if (-not $pyExe) {
    Write-Host ""
    Write-Host "Python 3.11 is not available on this machine. Install it first:" -ForegroundColor Red
    Write-Host "    winget install --id Python.Python.3.11 -e" -ForegroundColor Red
    Write-Host "then re-run this script." -ForegroundColor Red
    exit 1
}
Write-Host "    using: $pyExe $($pyPre -join ' ')" -ForegroundColor Green

# ---------------------------------------------------------------- step 2
Write-Step 2 "Creating project directory"
# Deliberately under %LOCALAPPDATA%, not Desktop/Documents: on managed machines
# those are commonly redirected into OneDrive (Known Folder Move), and OneDrive
# evicting then re-hydrating a venv causes multi-minute MCP startup delays.
New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
Write-Host "    $InstallDir" -ForegroundColor Green

if ($InstallDir -match '(?i)onedrive') {
    Write-Warning "InstallDir looks like it is inside OneDrive. Expect slow MCP startup."
}

# ---------------------------------------------------------------- step 3
Write-Step 3 "Creating venv and installing pinned packages"
$venvPy = Join-Path $InstallDir ".venv\Scripts\python.exe"
if (-not (Test-Path $venvPy)) {
    & $pyExe @pyPre -m venv (Join-Path $InstallDir ".venv")
    if ($LASTEXITCODE -ne 0) { throw "venv creation failed (exit $LASTEXITCODE)" }
} else {
    Write-Host "    venv already present, reusing it"
}
& $venvPy -m pip install --upgrade pip
if ($LASTEXITCODE -ne 0) { throw "pip upgrade failed (exit $LASTEXITCODE)" }
& $venvPy -m pip install "falcon-mcp==0.15.0" "keeper-secrets-manager-cli==1.4.0"
if ($LASTEXITCODE -ne 0) { throw "package install failed (exit $LASTEXITCODE)" }

$ksmExe = Join-Path $InstallDir ".venv\Scripts\ksm.exe"
if (-not (Test-Path $ksmExe)) { throw "ksm.exe not found at $ksmExe after install" }
Write-Host "    installed falcon-mcp 0.15.0 + keeper-secrets-manager-cli 1.4.0" -ForegroundColor Green

# ---------------------------------------------------------------- step 4
Write-Step 4 "Writing run.ps1"
$runPs1 = @'
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
'@
$runPath = Join-Path $InstallDir "run.ps1"
# UTF-8 without BOM: PowerShell 5.1 chokes on a BOM in some -File scenarios.
[System.IO.File]::WriteAllText($runPath, $runPs1, (New-Object System.Text.UTF8Encoding $false))
Write-Host "    $runPath" -ForegroundColor Green
# No chmod needed on Windows - PowerShell scripts have no Unix executable bit.

# ---------------------------------------------------------------- step 5
Write-Step 5 "Registering the MCP server in settings.json"

if (Test-Path $SettingsPath) {
    $bak = "$SettingsPath.bak"
    Copy-Item -Path $SettingsPath -Destination $bak -Force
    Write-Host "    backed up -> $bak" -ForegroundColor Green
    $raw = Get-Content -Raw -Path $SettingsPath
    try {
        $settings = $raw | ConvertFrom-Json
    } catch {
        Write-Host ""
        Write-Host "Could not parse $SettingsPath as JSON (comments or trailing commas?)." -ForegroundColor Red
        Write-Host "Nothing was modified. Add this entry under mcpServers by hand:" -ForegroundColor Red
        Write-Host ""
        Get-Content (Join-Path $PSScriptRoot "settings-snippet.json") -ErrorAction SilentlyContinue
        exit 1
    }
} else {
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $SettingsPath) | Out-Null
    Write-Host "    $SettingsPath does not exist; creating it"
    $settings = [pscustomobject]@{}
}

if ($settings.PSObject.Properties.Name -notcontains "mcpServers") {
    $settings | Add-Member -NotePropertyName mcpServers -NotePropertyValue ([pscustomobject]@{})
}

$existing = $settings.mcpServers.PSObject.Properties.Name
Write-Host "    existing mcpServers entries: $(if ($existing) { $existing -join ', ' } else { '(none)' })"

# A .ps1 cannot be the `command` directly the way run.sh can on Mac; invoke it
# through powershell.exe. -ExecutionPolicy Bypass applies to this one invocation
# only and does not change the system-wide execution policy.
$entry = [pscustomobject]@{
    command = "powershell.exe"
    args    = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $runPath)
}

if ($existing -contains "crowdstrike-ksm") {
    $settings.mcpServers.PSObject.Properties.Remove("crowdstrike-ksm")
    Write-Host "    replacing the existing 'crowdstrike-ksm' entry"
}
$settings.mcpServers | Add-Member -NotePropertyName "crowdstrike-ksm" -NotePropertyValue $entry

$json = $settings | ConvertTo-Json -Depth 100
[System.IO.File]::WriteAllText($SettingsPath, $json, (New-Object System.Text.UTF8Encoding $false))
Write-Host "    added mcpServers.crowdstrike-ksm (all other entries preserved)" -ForegroundColor Green
Write-Host "    other entries still present: $($settings.mcpServers.PSObject.Properties.Name -join ', ')"

# ---------------------------------------------------------------- next
Write-Host ""
Write-Host "Steps 1-5 done. Next you need your one-time KSM access token:" -ForegroundColor Yellow
Write-Host "    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\init-profile.ps1 -Token <ONE-TIME-TOKEN>" -ForegroundColor Yellow
