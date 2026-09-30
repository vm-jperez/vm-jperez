<#
Steps 7-10: initialize the KSM device profile from a one-time access token,
lock down keeper.ini, auto-discover the shared record UID, write secrets.env,
and verify that no real credentials landed on disk.

    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\init-profile.ps1 -Token <ONE-TIME-TOKEN>

The token is one-time use: once this succeeds it is spent and the long-lived
device credentials live only in keeper.ini.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Token,
    [string]$InstallDir = (Join-Path $env:LOCALAPPDATA "mcp-servers\crowdstrike-mcp-ksm"),
    # Set this to skip discovery when more than one record is shared to the app.
    [string]$RecordUid
)

$ErrorActionPreference = "Stop"

function Write-Step($n, $msg) { Write-Host "`n[$n] $msg" -ForegroundColor Cyan }

if (-not (Test-Path $InstallDir)) { throw "$InstallDir not found - run setup.ps1 first." }
Set-Location $InstallDir

$ksm = Join-Path $InstallDir ".venv\Scripts\ksm.exe"
if (-not (Test-Path $ksm)) { throw "$ksm not found - run setup.ps1 first." }

$iniPath = Join-Path $InstallDir "keeper.ini"
$env:KSM_INI_FILE = $iniPath

# ---------------------------------------------------------------- step 7
Write-Step 7 "Initializing the KSM device profile"
if (Test-Path $iniPath) {
    Write-Warning "keeper.ini already exists. Delete it first if you want to re-bind with a new token."
} else {
    & $ksm profile init --token $Token
    if ($LASTEXITCODE -ne 0) { throw "ksm profile init failed (exit $LASTEXITCODE)" }
    if (-not (Test-Path $iniPath)) { throw "ksm profile init reported success but $iniPath was not created" }
    Write-Host "    created $iniPath" -ForegroundColor Green
}

Write-Host "    restricting keeper.ini to the current user (Windows equivalent of chmod 600)"
& icacls $iniPath /inheritance:r | Out-Null
if ($LASTEXITCODE -ne 0) { throw "icacls /inheritance:r failed (exit $LASTEXITCODE)" }

& icacls $iniPath /grant:r "$($env:USERNAME):(R,W)" | Out-Null
if ($LASTEXITCODE -ne 0) {
    # Domain accounts sometimes need the DOMAIN\user form.
    Write-Host "    bare username was rejected, retrying as $env:USERDOMAIN\$env:USERNAME"
    & icacls $iniPath /grant:r "$($env:USERDOMAIN)\$($env:USERNAME):(R,W)" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "icacls /grant:r failed (exit $LASTEXITCODE)" }
}
Write-Host "    ACL applied" -ForegroundColor Green

# ---------------------------------------------------------------- step 8
Write-Step 8 "Discovering the shared record UID"

if ($RecordUid) {
    $uid = $RecordUid
    Write-Host "    using UID supplied on the command line: $uid"
} else {
    $listRaw = & $ksm secret list --json 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { throw "ksm secret list failed (exit $LASTEXITCODE):`n$listRaw" }

    try {
        $parsed = $listRaw | ConvertFrom-Json
    } catch {
        throw "Could not parse 'ksm secret list --json' output as JSON:`n$listRaw"
    }

    # Tolerate both a bare array and an object wrapping a records array.
    $records = @()
    if ($parsed -is [System.Array]) { $records = $parsed }
    elseif ($parsed.PSObject.Properties.Name -contains "records") { $records = @($parsed.records) }
    elseif ($parsed) { $records = @($parsed) }

    if ($records.Count -eq 0) {
        Write-Host ""
        Write-Host "No records are shared to this KSM Application." -ForegroundColor Red
        Write-Host "The sharing setup in Keeper needs to be checked: the shared folder (or the" -ForegroundColor Red
        Write-Host "individual record) holding the Falcon API credentials has to be added to the" -ForegroundColor Red
        Write-Host "Secrets Manager Application this token was issued for." -ForegroundColor Red
        exit 1
    }

    if ($records.Count -gt 1) {
        Write-Host ""
        Write-Host "More than one record is shared to this Application - not guessing." -ForegroundColor Yellow
        $records | Select-Object title, uid, type | Format-Table -AutoSize
        Write-Host "Re-run with the one you want:" -ForegroundColor Yellow
        Write-Host "    .\init-profile.ps1 -Token <TOKEN> -RecordUid <UID>" -ForegroundColor Yellow
        Write-Host "(keeper.ini is already initialized, so that run will skip straight to step 9.)" -ForegroundColor Yellow
        exit 2
    }

    $uid = $records[0].uid
    if (-not $uid) { throw "The single shared record has no 'uid' field:`n$listRaw" }
    Write-Host "    exactly one record shared: '$($records[0].title)' -> $uid" -ForegroundColor Green
}

# ---------------------------------------------------------------- step 9
Write-Step 9 "Writing secrets.env"
$secretsEnv = @"
# Keeper-notation references — resolved to real values by ``ksm exec`` at launch.
# NO actual secrets in this file.
FALCON_CLIENT_ID=keeper://$uid/field/login
FALCON_CLIENT_SECRET=keeper://$uid/field/password

# Non-secret, set directly:
FALCON_BASE_URL=https://api.crowdstrike.com
"@
$secretsPath = Join-Path $InstallDir "secrets.env"
[System.IO.File]::WriteAllText($secretsPath, $secretsEnv, (New-Object System.Text.UTF8Encoding $false))
Write-Host "    $secretsPath" -ForegroundColor Green

# ---------------------------------------------------------------- step 10
Write-Step 10 "Verifying"

Write-Host "`n--- icacls keeper.ini ---" -ForegroundColor Cyan
$acl = & icacls $iniPath | Out-String
Write-Host $acl
$bad = @("Everyone", "BUILTIN\Users", "\Users:", "Authenticated Users") | Where-Object { $acl -like "*$_*" }
if ($bad) {
    Write-Warning "keeper.ini ACL still grants: $($bad -join ', '). Fix before relying on this."
} else {
    Write-Host "keeper.ini ACL grants the current user only." -ForegroundColor Green
}

Write-Host "`n--- Select-String secrets.env for FALCON_CLIENT ---" -ForegroundColor Cyan
Select-String -Path $secretsPath -Pattern "FALCON_CLIENT" | ForEach-Object { Write-Host "  $($_.Line)" }

Write-Host "`n--- scanning the whole directory for literal credentials ---" -ForegroundColor Cyan
# keeper.ini legitimately holds the device key; it is the venv and the plaintext
# config files that must not contain the Falcon client id/secret.
$hits = Get-ChildItem -Path $InstallDir -File -Recurse -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -in @("secrets.env", "run.ps1") } |
    Select-String -Pattern "FALCON_CLIENT_(ID|SECRET)\s*=\s*(?!keeper://)\S" -ErrorAction SilentlyContinue
if ($hits) {
    Write-Warning "Something other than a keeper:// reference was found:"
    $hits | ForEach-Object { Write-Host "  $($_.Path): $($_.Line)" }
} else {
    Write-Host "No literal Client ID/Secret on disk - only keeper:// references." -ForegroundColor Green
}

# ---------------------------------------------------------------- next
Write-Host ""
Write-Host "Steps 7-10 done. Now fully quit and reopen Claude Code:" -ForegroundColor Yellow
Write-Host "  File > Exit, or right-click the taskbar/tray icon and choose Exit." -ForegroundColor Yellow
Write-Host "  Closing the window is not enough - check Task Manager for a lingering process." -ForegroundColor Yellow
Write-Host "  MCP servers only load at launch, so 'crowdstrike-ksm' will not appear until then." -ForegroundColor Yellow
