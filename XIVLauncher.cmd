@echo off
setlocal enabledelayedexpansion
rem ***************************************************************************
rem *                                                                         *
rem * XIVLauncher Helper Batch File for Inner Space/ISBoxer                   *
rem * Original multi-client roaming batch script by: Tsukasa                  *
rem * Extended with automated Vaultwarden/Bitwarden CLI 2FA / TOTP injection  *
rem *                                                                         *
rem ***************************************************************************

rem ***************************************************************************
rem * C O N F I G U R A T I O N                                               *
rem ***************************************************************************

rem Skip XIVLauncher update check? [true/false, default: false]
rem set XL_NOAUTOUPDATE=false

rem ISDalamudUpdater location [real path, default: commented out]
rem set ISDU_ROOT=C:\Users\ebony\NextCloud\XIVLauncherBatch

rem Root location of the XIVLauncher executables [real path, default: %LOCALAPPDATA%\XIVLauncher]
set XIVLAUNCHER_LOCALDATA=%LOCALAPPDATA%\XIVLauncher

rem Root directory for character/characterset-specific data on NAS [real path]
set ROAMINGPATH_ROOT=X:\XIVLauncherBatch

rem Local cache directory on C: for fast, lock-free per-character execution
set LOCAL_ROAMING_ROOT=C:\XIVLauncherBatch

rem Sync character profile between NAS (X:) and local C: drive via Robocopy [true/false]
rem Set to false if running on a single PC without a NAS
set ENABLE_NAS_SYNC=true

rem Vaultwarden / Bitwarden CLI 2FA configuration
set VW_ITEM_MAP=%ROAMINGPATH_ROOT%\vw_items.txt
set VW_SESSION_FILE=%LOCAL_ROAMING_ROOT%\bw_session.txt
set OTP_LOCK=%LOCAL_ROAMING_ROOT%\otp.lock


rem ***************************************************************************
rem * P R O C E S S I N G                                                     *
rem ***************************************************************************

rem --- Pre-checks ------------------------------------------------------------
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

if /i "%ENABLE_NAS_SYNC%"=="true" (
  set "LOCAL_CHAR_PATH=%LOCAL_ROAMING_ROOT%\%CHAR_FOLDER%"
  if "!LOCAL_CHAR_PATH:~-1!"=="\" set "LOCAL_CHAR_PATH=!LOCAL_CHAR_PATH:~0,-1!"

  echo Syncing %CHAR_FOLDER% from %NAS_CHAR_PATH% to !LOCAL_CHAR_PATH!...
  robocopy "%NAS_CHAR_PATH%" "!LOCAL_CHAR_PATH%" /MIR /XO /R:1 /W:1 /NFL /NDL /NJH /NJS

  set "ROAMINGPATH=!LOCAL_CHAR_PATH!"
  title XIV Sync - %CHAR_FOLDER%
  powershell -NoProfile -Command "$h=(Get-Process -Id $PID).MainWindowHandle; if($h -ne 0){Add-Type -Name U -Namespace W -MemberDefinition '[DllImport(\"user32.dll\")]public static extern bool ShowWindowAsync(IntPtr h,int n);';[W.U]::ShowWindowAsync($h,6)}" >nul 2>&1
)

echo Will be using directory as roamingPath: %ROAMINGPATH%

rem --- Set-up --account parameter --------------------------------------------
if not "%XIVLAUNCHER_ACCOUNT%" == "" (
  set XIVLAUNCHER_ACCOUNT_ARG=--account="%XIVLAUNCHER_ACCOUNT%-%XIVLAUNCHER_USE_OTP%-%XIVLAUNCHER_USE_STEAM%"
  echo.
  echo Setting XIVLauncher account name to: %XIVLAUNCHER_ACCOUNT% [Use OTP: %XIVLAUNCHER_USE_OTP%, Is Steam: %XIVLAUNCHER_USE_STEAM%]
)

rem --- Automatic Dalamud update ----------------------------------------------
if defined ISDU_ROOT (
  if exist "%ISDU_ROOT%" (
    echo.
    echo Updating Dalamud...
    call "%ISDU_ROOT%\ISDalamudUpdater.exe" --roamingPath="%ROAMINGPATH%"
  )
)

rem --- Check for Vaultwarden 2FA mapping -------------------------------------
set "VW_ITEM_ID="
if exist "%VW_ITEM_MAP%" (
  for /f "usebackq tokens=1,2 delims==" %%A in ("%VW_ITEM_MAP%") do (
    if /i "%%~A"=="%CHAR_FOLDER%" set "VW_ITEM_ID=%%~B"
  )
)

if "!VW_ITEM_ID!"=="" (
  rem --- Standard launch (no 2FA mapping found) ------------------------------
  echo No Vaultwarden 2FA mapping found for %CHAR_FOLDER% - skipping OTP...
  echo Launching XIVLauncher...
  start /wait "XIV Launcher" "%XIVLAUNCHER_LOCALDATA%\current\XIVLauncher.exe" --roamingPath="%ROAMINGPATH%" %XIVLAUNCHER_ACCOUNT_ARG% %*
  goto :WAIT_FOR_GAME
)

rem --- Acquire local otp.lock to serialize port 4646 across clients ----------
:WAIT_OTP_LOCK
if exist "%OTP_LOCK%" (
  powershell -NoProfile -Command ^
    "$lock = Get-Item '%OTP_LOCK%' -ErrorAction SilentlyContinue; " ^
    "$xl = Get-Process 'XIVLauncher' -ErrorAction SilentlyContinue; " ^
    "if ($lock -and (((Get-Date) - $lock.LastWriteTime).TotalSeconds -gt 65 -or -not $xl)) { Remove-Item '%OTP_LOCK%' -Force }"
)
if exist "%OTP_LOCK%" (
  timeout /t 1 /nobreak >nul
  goto :WAIT_OTP_LOCK
)
echo %CHAR_FOLDER% > "%OTP_LOCK%"

rem --- Start XIVLauncher and inject Vaultwarden TOTP on port 4646 ------------
echo Launching XIVLauncher with Vaultwarden 2FA for %CHAR_FOLDER%...
start "XIV Launcher" "%XIVLAUNCHER_LOCALDATA%\current\XIVLauncher.exe" --roamingPath="%ROAMINGPATH%" %XIVLAUNCHER_ACCOUNT_ARG% %*

echo Waiting for XIVLauncher OTP listener on port 4646...
powershell -NoProfile -Command ^
  "$deadline = (Get-Date).AddSeconds(60); " ^
  "while ((Get-Date) -lt $deadline) { " ^
  "  $tcp = New-Object System.Net.Sockets.TcpClient; " ^
  "  try { $tcp.Connect('127.0.0.1', 4646); $tcp.Close(); exit 0 } catch { Start-Sleep -Milliseconds 500 } " ^
  "} exit 1"
if errorlevel 1 (
  echo Warning: Timed out waiting for XIVLauncher OTP listener on port 4646.
  goto :RELEASE_OTP_LOCK
)

powershell -NoProfile -Command ^
  "$rem = 30 - ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() %% 30); " ^
  "if ($rem -lt 4) { Write-Host 'Waiting for fresh 30-second TOTP window...'; Start-Sleep -Seconds ($rem + 1) }"

if exist "%VW_SESSION_FILE%" (
  set /p BW_SESSION=<"%VW_SESSION_FILE%"
  echo Fetching TOTP code from Vaultwarden for %CHAR_FOLDER%...
  set "OTP_CODE="
  for /f "delims=" %%T in ('bw get totp "!VW_ITEM_ID!" --session "!BW_SESSION!" --raw --nointeraction 2^>nul') do set "OTP_CODE=%%T"
  if not "!OTP_CODE!"=="" (
    echo Sending 2FA code to XIVLauncher on port 4646...
    powershell -NoProfile -Command ^
      "try { Invoke-RestMethod -Uri 'http://127.0.0.1:4646/ffxivlauncher/!OTP_CODE!' -Method Get -TimeoutSec 5 | Out-Null; exit 0 } catch { " ^
      "  Start-Sleep -Milliseconds 400; " ^
      "  $tcp = New-Object System.Net.Sockets.TcpClient; " ^
      "  try { $tcp.Connect('127.0.0.1', 4646); $tcp.Close(); exit 1 } catch { exit 0 } " ^
      "}"
    if not errorlevel 1 (
      echo OTP accepted for %CHAR_FOLDER%!
    ) else (
      echo Warning: Failed to send OTP code to XIVLauncher on port 4646.
    )
  ) else (
    echo Warning: Could not retrieve TOTP code from Vaultwarden. Check bw_session.txt.
  )
) else (
  echo Warning: Session file %VW_SESSION_FILE% not found.
)

:RELEASE_OTP_LOCK
if exist "%OTP_LOCK%" del /f /q "%OTP_LOCK%" >nul 2>&1

rem --- Wait for XIVLauncher to finish booting the game before monitoring -----
timeout /t 10 /nobreak >nul

rem --- Wait for FFXIV game client to close if running ------------------------
:WAIT_FOR_GAME
timeout /t 5 /nobreak >nul
tasklist /FI "IMAGENAME eq ffxiv_dx11.exe" 2>NUL | find /I /N "ffxiv_dx11.exe">NUL
if "%ERRORLEVEL%"=="0" goto :WAIT_FOR_GAME

rem --- Sync updated character data back to NAS (X:) --------------------------
if /i "%ENABLE_NAS_SYNC%"=="true" (
  echo.
  echo Game closed. Syncing %CHAR_FOLDER% back to %NAS_CHAR_PATH%...
  robocopy "%LOCAL_CHAR_PATH%" "%NAS_CHAR_PATH%" /MIR /XO /R:1 /W:1 /NFL /NDL /NJH /NJS
  echo Sync complete!
)

exit 0
:END_OF_FILE