@echo off
title Update Vaultwarden FFXIV Item Map

rem ***************************************************************************
rem * C O N F I G U R A T I O N                                               *
rem ***************************************************************************
rem Name of the folder in Vaultwarden/Bitwarden containing your FFXIV logins
set "FOLDER_NAME=FFXIV"

rem Local folder on THIS PC (stores your private Bitwarden CLI session token)
set "LOCAL_DIR=C:\XIVLauncherBatch"

rem Shared NAS folder (or set identical to LOCAL_DIR if using a single PC)
set "SHARED_DIR=X:\XIVLauncherBatch"

rem -- DO NOT EDIT Below this unless you know what your doing.

set "SESSION_FILE=%LOCAL_DIR%\bw_session.txt"
set "OUTPUT_MAP=%SHARED_DIR%\vw_items.txt"

if not exist "%LOCAL_DIR%" mkdir "%LOCAL_DIR%"
if not exist "%SHARED_DIR%" mkdir "%SHARED_DIR%"

rem --- Check if existing session key is valid; prompt to unlock if locked ----
set "BW_KEY="
if exist "%SESSION_FILE%" set /p BW_KEY=<"%SESSION_FILE%"

if not "%BW_KEY%"=="" (
  bw status --session "%BW_KEY%" 2>nul | findstr /i "\"unlocked\"" >nul
  if "%ERRORLEVEL%"=="0" goto :SYNC_ITEMS
)

echo Vaultwarden CLI is locked or missing a session key.
echo Please enter your Vaultwarden Master Password below:
for /f "delims=" %%S in ('bw unlock --raw') do set "BW_KEY=%%S"

if "%BW_KEY%"=="" (
  echo.
  echo Failed to unlock Vaultwarden. Aborting.
  pause
  exit /b 1
)

<nul set /p="%BW_KEY%" > "%SESSION_FILE%"
echo Session key saved to %SESSION_FILE%.

:SYNC_ITEMS
echo.
echo Syncing Vaultwarden vault...
bw sync --session "%BW_KEY%"

echo Looking up folder "%FOLDER_NAME%" and exporting items to %OUTPUT_MAP%...
powershell -NoProfile -Command "$folder = (bw list folders --session '%BW_KEY%' | ConvertFrom-Json) | Where-Object { $_.name -eq '%FOLDER_NAME%' } | Select-Object -First 1; if (-not $folder) { Write-Host 'Folder not found: %FOLDER_NAME%'; exit 1 }; $items = bw list items --folderid $folder.id --session '%BW_KEY%' | ConvertFrom-Json; $items | ForEach-Object { \"$($_.name)=$($_.id)\" } | Set-Content -Path '%OUTPUT_MAP%' -Encoding ASCII"

if not exist "%OUTPUT_MAP%" (
  echo Failed to generate %OUTPUT_MAP%. Check that the folder name "%FOLDER_NAME%" matches Vaultwarden exactly.
  pause
  exit /b 1
)

echo.
echo Updated %OUTPUT_MAP%:
echo ----------------------------------------
type "%OUTPUT_MAP%"
echo ----------------------------------------
echo.
echo Done!
pause