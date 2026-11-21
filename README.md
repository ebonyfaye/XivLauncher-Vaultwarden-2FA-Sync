# Automated FFXIV Multi-Client 2FA/TOTP Login (ISBoxer + XIVLauncher + Vaultwarden)

Automated One-Time Password (TOTP) injection for multi-boxing **Final Fantasy XIV** using **Inner Space / ISBoxer**, **XIVLauncher**, and a self-hosted **Vaultwarden** instance via the Bitwarden CLI (`bw`).

---

## Overview & Architecture

When launching multiple FFXIV accounts simultaneously via ISBoxer, XIVLauncher exposes a local HTTP listener on `127.0.0.1:4646` to receive TOTP codes. This wrapper batch script (`XIVLauncher.cmd`) coordinates multi-client launches without port collisions or interactive CLI prompts:

1. **NAS-to-Local Sync:** Mirrors the character's roaming profile from the network share (`X:\XIVLauncherBatch\<character>`) to local storage (`C:\XIVLauncherBatch\<character>`) using multi-threaded `robocopy` (`/MT:8`), then syncs changes back after the game closes.
2. **Stale Lock Recovery & Queue Serialization:** Uses `C:\XIVLauncherBatch\otp.lock` to serialize launches one character at a time so simultaneous ISBoxer clients never collide on port `4646`. Automatically clears stale lock files if no `XIVLauncher.exe` process is running or if a lock exceeds 65 seconds.
3. **Listener Detection & Window Guard:** Polls `127.0.0.1:4646` via .NET `TcpClient` (up to 60 seconds) and checks remaining seconds in the current 30-second TOTP window (waiting if fewer than 7 seconds remain so codes never expire mid-submission).
4. **Non-Interactive Vaultwarden Lookup:** Reads a pre-mapped character-to-UUID file (`vw_items.txt`) and a persisted CLI session key (`bw_session.txt`) to fetch the live 6-digit TOTP with `--nointeraction`, then injects it via `curl.exe -4 --http0.9`.

---

## Prerequisites

- **Windows 10/11** with PowerShell and built-in `curl.exe`
- **Inner Space / ISBoxer** configured with character virtualization (`XIVLauncher-env.cmd`)
- **XIVLauncher** installed in `%LOCALAPPDATA%\XIVLauncher`
- **Bitwarden CLI (`bw`)** installed and configured against your Vaultwarden server (`bw config server https://your-vaultwarden-domain`)
- **Vaultwarden Folder Structure:**
  - Create a dedicated folder in Vaultwarden (e.g., `Final Fantasy XIV`).
  - Name each login item identically to its corresponding character roaming folder name (e.g., `blossom`), with the TOTP authenticator seed saved on the item.

---

## Directory Layout

```text
X:\XIVLauncherBatch\                  # Network share (source of truth)
├── XIVLauncher.cmd                   # Main ISBoxer launch & OTP automation script
├── XIVLauncher-env.cmd               # Per-character environment variables (ROAMINGPATH_PRE, etc.)
└── <character>\                      # Character-specific XIVLauncher config folders

C:\XIVLauncherBatch\                  # Local fast-storage working directory
├── bw_session.txt                    # Active Bitwarden CLI session token (DO NOT COMMIT)
├── vw_items.txt                      # Character-to-Vaultwarden Item UUID mapping
├── otp.lock                          # Temporary runtime mutex lock (auto-cleaned)
└── <character>\                      # Local synced roaming profile
```

> **Security Note:** Add `bw_session.txt`, `vw_items.txt`, and `otp.lock` to your `.gitignore` so sensitive session tokens and vault identifiers are never pushed to GitHub.

---

## One-Time Setup

### 1. Configure XIVLauncher Profiles
For each character profile:
1. Check **Use one-time password** on the XIVLauncher login screen.
2. Uncheck **Auto-login** (XIVLauncher must pause on the login screen to keep port `4646` open).
3. Open **Settings (Gear Icon) → General**, enable **Enable XL Authenticator app/OTP macro support**, and click **Save**.
4. Ensure `XIVLauncher-env.cmd` passes `XIVLAUNCHER_USE_OTP=true`.

### 2. Unlock Vaultwarden CLI & Export Item UUIDs
Run the following in **Administrator PowerShell** to generate your local session key and map your `Final Fantasy XIV` folder items:

```powershell
# 1. Unlock Vaultwarden CLI and store the 88-character session token locally
bw unlock --raw | Out-File -FilePath "C:\XIVLauncherBatch\bw_session.txt" -Encoding ASCII -NoNewline

# 2. Retrieve your "Final Fantasy XIV" folder UUID
$key = Get-Content "C:\XIVLauncherBatch\bw_session.txt" -Raw
bw sync --session $key
bw list folders --session $key

# 3. Map all items in that folder to C:\XIVLauncherBatch\vw_items.txt
$folderId = "YOUR_FFXIV_FOLDER_UUID"
(bw list items --folderid $folderId --session $key | ConvertFrom-Json) |
  ForEach-Object { "$($_.name)=$($_.id)" } |
  Set-Content "C:\XIVLauncherBatch\vw_items.txt" -Encoding ASCII
```

Verify `C:\XIVLauncherBatch\vw_items.txt` contains clean `character=uuid` pairs:
```text
blossom=00000000-0000-0000-0000-000000000000
character2=11111111-1111-1111-1111-111111111111
```

---

## `XIVLauncher.cmd`

Place this script at `X:\XIVLauncherBatch\XIVLauncher.cmd`:

```bat
@echo off
rem ***************************************************************************
rem *                                                                         *
rem * XIVLauncher Helper Batch File for Inner Space/ISBoxer                   *
rem *                                                                         *
rem ***************************************************************************

rem ***************************************************************************
rem * C O N F I G U R A T I O N                                               *
rem ***************************************************************************

set XIVLAUNCHER_LOCALDATA=%LOCALAPPDATA%\XIVLauncher
set ROAMINGPATH_ROOT=X:\XIVLauncherBatch
set LOCAL_ROAMING_ROOT=C:\XIVLauncherBatch
set OTP_LOCK=%LOCAL_ROAMING_ROOT%\otp.lock
set VW_ITEM_MAP=%LOCAL_ROAMING_ROOT%\vw_items.txt
set VW_SESSION_FILE=%LOCAL_ROAMING_ROOT%\bw_session.txt


rem ***************************************************************************
rem * P R O C E S S I N G                                                     *
rem ***************************************************************************

if not exist "%XIVLAUNCHER_LOCALDATA%" (
  echo Error: XIVLauncher not found in "%XIVLAUNCHER_LOCALDATA%".
  pause
  goto :END_OF_FILE
)

rem --- Check character virtualization ----------------------------------------
call "%~dp0%\XIVLauncher-env.cmd"

if not "%ROAMINGPATH_PRE%" == "" (
  set ROAMINGPATH=%ROAMINGPATH_PRE%
)

rem --- Sync ONLY this character's folder from NAS (X:) to Local C: -----------
for %%I in ("%ROAMINGPATH%") do set "CHAR_FOLDER=%%~nxI"
set "NAS_CHAR_PATH=%ROAMINGPATH%"
set "LOCAL_CHAR_PATH=%LOCAL_ROAMING_ROOT%\%CHAR_FOLDER%"

if "%LOCAL_CHAR_PATH:~-1%"=="\" set "LOCAL_CHAR_PATH=%LOCAL_CHAR_PATH:~0,-1%"

echo Syncing %CHAR_FOLDER% from %NAS_CHAR_PATH% to %LOCAL_CHAR_PATH%...
robocopy "%NAS_CHAR_PATH%" "%LOCAL_CHAR_PATH%" /MIR /XO /MT:8 /R:1 /W:1 /NFL /NDL /NJH /NJS

set "ROAMINGPATH=%LOCAL_CHAR_PATH%"
title XIV Sync - %CHAR_FOLDER%
echo Will be using local directory as roamingPath: %ROAMINGPATH%

rem --- Set-up --account parameter --------------------------------------------
if not "%XIVLAUNCHER_ACCOUNT%" == "" (
  set XIVLAUNCHER_ACCOUNT_ARG=--account="%XIVLAUNCHER_ACCOUNT%-%XIVLAUNCHER_USE_OTP%-%XIVLAUNCHER_USE_STEAM%"
  echo.
  echo Setting XIVLauncher account name to: %XIVLAUNCHER_ACCOUNT% [Use OTP: %XIVLAUNCHER_USE_OTP%, Is Steam: %XIVLAUNCHER_USE_STEAM%]
)

rem --- Clear stale lock immediately if no XIVLauncher.exe is currently open --
tasklist /FI "IMAGENAME eq XIVLauncher.exe" 2>NUL | find /I /N "XIVLauncher.exe">NUL
if not "%ERRORLEVEL%"=="0" (
  if exist "%OTP_LOCK%" del /f /q "%OTP_LOCK%" >nul 2>&1
)

rem --- Acquire brief OTP queue lock (auto-clears locks older than 65s) -------
powershell -NoProfile -Command "if (Test-Path $env:OTP_LOCK) { if (((Get-Date) - (Get-Item $env:OTP_LOCK).LastWriteTime).TotalSeconds -gt 65) { Remove-Item $env:OTP_LOCK -Force } }"
:WAIT_FOR_LOCK
if exist "%OTP_LOCK%" (
  timeout /t 1 /nobreak >nul
  goto :WAIT_FOR_LOCK
)
echo %CHAR_FOLDER% > "%OTP_LOCK%"

rem --- Start XIVLauncher -----------------------------------------------------
echo Launching XIVLauncher...
start "XIV Launcher" "%XIVLAUNCHER_LOCALDATA%\current\XIVLauncher.exe" --roamingPath="%ROAMINGPATH%" %XIVLAUNCHER_ACCOUNT_ARG% %*

rem --- Wait up to 60s for port 4646 listener ---------------------------------
echo Waiting for XIVLauncher OTP listener on port 4646...
powershell -NoProfile -Command "$deadline = (Get-Date).AddSeconds(60); while ((Get-Date) -lt $deadline) { $c = New-Object Net.Sockets.TcpClient; try { $c.Connect('127.0.0.1', 4646); $c.Close(); exit 0 } catch { Start-Sleep -Milliseconds 300 } }; exit 1"
if not "%ERRORLEVEL%"=="0" (
  echo Timed out waiting for XIVLauncher port 4646 after 60s.
  goto :RELEASE_LOCK
)
echo Port 4646 detected!

rem --- Ensure at least 7 seconds remain in the 30s TOTP window ---------------
powershell -NoProfile -Command "$rem = 30 - ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() %% 30); if ($rem -lt 7) { Write-Host \"Code expiring in ${rem}s, waiting for fresh code...\"; Start-Sleep -Seconds ($rem + 1) }"

rem --- Read saved Vaultwarden session key ------------------------------------
set "BW_KEY="
if exist "%VW_SESSION_FILE%" (
  set /p BW_KEY=<"%VW_SESSION_FILE%"
)

if "%BW_KEY%"=="" (
  echo Missing Vaultwarden session key in %VW_SESSION_FILE%.
  goto :RELEASE_LOCK
)

rem --- Look up pre-mapped item UUID for %CHAR_FOLDER% ------------------------
set "VW_ITEM_ID="
if exist "%VW_ITEM_MAP%" (
  for /f "usebackq tokens=1,2 delims==" %%A in ("%VW_ITEM_MAP%") do (
    if /i "%%A"=="%CHAR_FOLDER%" set "VW_ITEM_ID=%%B"
  )
)

if "%VW_ITEM_ID%"=="" (
  echo No Vaultwarden item ID mapped for %CHAR_FOLDER% in %VW_ITEM_MAP%.
  goto :RELEASE_LOCK
)

rem --- Fetch live 6-digit TOTP using --session and --nointeraction -----------
echo Fetching live OTP for %CHAR_FOLDER%...
set "LIVE_OTP="
for /f "delims=" %%T in ('bw get totp "%VW_ITEM_ID%" --session "%BW_KEY%" --nointeraction 2^>^&1') do set "LIVE_OTP=%%T"

echo %LIVE_OTP%| findstr /r "^[0-9][0-9][0-9][0-9][0-9][0-9]$" >nul
if "%ERRORLEVEL%"=="0" (
  echo Sending fresh OTP %LIVE_OTP% to XIVLauncher...
  curl.exe -4 -s --http0.9 --max-time 3 "[http://127.0.0.1:4646/ffxivlauncher/%LIVE_OTP](http://127.0.0.1:4646/ffxivlauncher/%LIVE_OTP)%" >nul 2>&1
  echo Sent OTP to XIVLauncher.
  timeout /t 2 /nobreak >nul
) else (
  echo Vaultwarden TOTP error for %CHAR_FOLDER%: %LIVE_OTP%
)

:RELEASE_LOCK
if exist "%OTP_LOCK%" del /f /q "%OTP_LOCK%" >nul 2>&1

rem --- Give XIVLauncher time to spawn game before checking process exit ------
timeout /t 10 /nobreak >nul

:WAIT_FOR_PROCESSES
timeout /t 5 /nobreak >nul
tasklist /FI "IMAGENAME eq XIVLauncher.exe" 2>NUL | find /I /N "XIVLauncher.exe">NUL
if "%ERRORLEVEL%"=="0" goto :WAIT_FOR_PROCESSES
tasklist /FI "IMAGENAME eq ffxiv_dx11.exe" 2>NUL | find /I /N "ffxiv_dx11.exe">NUL
if "%ERRORLEVEL%"=="0" goto :WAIT_FOR_PROCESSES

rem --- Sync updated character data back to NAS (X:) --------------------------
echo.
echo Game closed. Syncing %CHAR_FOLDER% back to %NAS_CHAR_PATH%...
robocopy "%LOCAL_CHAR_PATH%" "%NAS_CHAR_PATH%" /MIR /XO /MT:8 /R:1 /W:1 /NFL /NDL /NJH /NJS
echo Sync complete!
pause

exit 0
:END_OF_FILE
```

---

## Troubleshooting & Maintenance

| Symptom | Cause | Fix |
| :--- | :--- | :--- |
| `Vaultwarden TOTP error: Vault is locked.` | `bw_session.txt` expired after a PC reboot or server restart. | Re-run `bw unlock --raw \| Out-File "C:\XIVLauncherBatch\bw_session.txt" -Encoding ASCII -NoNewline` in PowerShell. |
| `Timed out waiting for XIVLauncher port 4646` | OTP macro support disabled, `Auto-login` enabled, or `XIVLAUNCHER_USE_OTP=false`. | Verify `"IsOtpServer": true` and `"AutoLogin": false` in `launcherConfigV3.json`, and ensure `XIVLAUNCHER_USE_OTP=true`. |
| `curl.exe` fails to connect to `localhost:4646` | XIVLauncher binds to IPv4 (`0.0.0.0:4646`), while `localhost` may resolve to IPv6 (`::1`). | Always target explicit IPv4 `http://127.0.0.1:4646/ffxivlauncher/<OTP>` with `curl.exe -4 --http0.9`. |
| Square Enix temporary login restriction | Too many failed OTP/password attempts in a short window. | Close all `XIVLauncher.exe` instances and wait **15–30 minutes** before retrying. |