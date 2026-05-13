@echo off
setlocal EnableDelayedExpansion

set "SCRIPT_DIR=%~dp0"
set "PS_SINGLE=%SCRIPT_DIR%mkv-reorder.ps1"
set "PS_BATCH=%SCRIPT_DIR%mkv-batch-reorder.ps1"

if not exist "%PS_SINGLE%" (
    echo ERROR: mkv-reorder.ps1 not found next to this batch file.
    echo Expected: %PS_SINGLE%
    pause
    exit /b 1
)
if not exist "%PS_BATCH%" (
    echo ERROR: mkv-batch-reorder.ps1 not found next to this batch file.
    echo Expected: %PS_BATCH%
    pause
    exit /b 1
)

:checkdeps
set "MKVMERGE="
if exist "C:\Program Files\MKVToolNix\mkvmerge.exe" set "MKVMERGE=C:\Program Files\MKVToolNix\mkvmerge.exe"
if not defined MKVMERGE if exist "C:\Program Files (x86)\MKVToolNix\mkvmerge.exe" set "MKVMERGE=C:\Program Files (x86)\MKVToolNix\mkvmerge.exe"
if not defined MKVMERGE for /f "delims=" %%i in ('where mkvmerge.exe 2^>nul') do set "MKVMERGE=%%i"

if not defined MKVMERGE (
    echo.
    echo ============================================================
    echo  MKVToolNix is required but was not found.
    echo ============================================================
    echo.
    set /p "INSTALL=Install MKVToolNix automatically via winget? [Y/N]: "
    if /i "!INSTALL!"=="Y" goto install
    echo.
    echo Please install MKVToolNix manually from:
    echo   https://mkvtoolnix.download/
    echo.
    pause
    exit /b 1
)
goto run

:install
where winget >nul 2>&1
if errorlevel 1 (
    echo.
    echo winget is not available on this system ^(requires Windows 10 1709+ or Windows 11^).
    echo Please install MKVToolNix manually from:
    echo   https://mkvtoolnix.download/
    echo.
    pause
    exit /b 1
)
echo.
echo Installing MKVToolNix via winget...
echo.
winget install --id MoritzBunkus.MKVToolNix -e --accept-source-agreements --accept-package-agreements
if errorlevel 1 (
    echo.
    echo Installation failed.
    echo Please install manually from: https://mkvtoolnix.download/
    echo.
    pause
    exit /b 1
)
echo.
echo Install complete. Continuing...
echo.
goto checkdeps

:run
if "%~1"=="" (
    echo.
    echo Usage:
    echo   Drag an MKV file or folder onto this batch file.
    echo   File:   reorders audio tracks in a single MKV.
    echo   Folder: scans recursively and batch-processes matching MKVs.
    echo.
    pause
    exit /b 1
)

if exist "%~1\" (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PS_BATCH%" -FolderPath "%~1" %2 %3 %4 %5 %6 %7 %8
) else (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PS_SINGLE%" -FilePath "%~1" %2 %3 %4 %5 %6
)
set "PSEXIT=%ERRORLEVEL%"

echo.
pause
exit /b %PSEXIT%
