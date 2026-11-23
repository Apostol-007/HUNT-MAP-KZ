@echo off
setlocal EnableExtensions DisableDelayedExpansion
title HUNT MAP KZ - Kazakhstan Protomaps offline map preparation
cd /d "%~dp0.."
chcp 65001 >nul
echo ============================================
echo HUNT MAP KZ - WHOLE KAZAKHSTAN PMTiles
echo ============================================
echo.
echo Area: Kazakhstan [46.49,40.56,87.31,55.44]
echo Partition: 0.5 degree cells, processed in batches of 100.
echo Every completed archive and catalog entry is saved immediately.
echo Restart this BAT to resume any unfinished extraction.
echo NOTE: Area is a bounding rectangle, including neighboring territory.
echo.

where py >nul 2>nul
if errorlevel 1 (
 echo ERROR: Python launcher 'py' not found.
 echo Install Python 3 with Windows launcher.
 goto :FAILED
)

set "PMT=%~dp0pmtiles.exe"
if not exist "%PMT%" (
 echo Downloading official PMTiles CLI for Windows...
 powershell -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop'; $r=Invoke-RestMethod -Uri 'https://api.github.com/repos/protomaps/go-pmtiles/releases/latest' -Headers @{'User-Agent'='HuntMapKZ'}; $a=$r.assets | Where-Object { $_.name -match '(?i)windows.*(x86_64|amd64).*(zip|exe)$' } | Select-Object -First 1; if(!$a){throw 'Windows binary not found'}; $target=Join-Path '%~dp0' $a.name; Invoke-WebRequest -Uri $a.browser_download_url -OutFile $target; if($a.name -match '(?i)\.zip$'){Expand-Archive -Force -Path $target -DestinationPath '%~dp0pmtiles-unpack'; $exe=Get-ChildItem '%~dp0pmtiles-unpack' -Recurse -Filter 'pmtiles.exe' | Select-Object -First 1; if(!$exe){throw 'pmtiles.exe missing'}; Copy-Item $exe.FullName '%PMT%' -Force}else{Move-Item $target '%PMT%' -Force}"
 if errorlevel 1 (
  echo ERROR: Cannot install PMTiles CLI.
  echo Download pmtiles.exe manually: https://github.com/protomaps/go-pmtiles/releases
  goto :FAILED
 )
)

set "SRC=auto"
if exist "%CD%\kazakhstan.pmtiles" set "SRC=%CD%\kazakhstan.pmtiles"
if exist "%~dp0kazakhstan.pmtiles" set "SRC=%~dp0kazakhstan.pmtiles"
if /i "%SRC%"=="auto" (
 echo Source: official Protomaps daily build from internet.
) else (
 echo Source: existing local kazakhstan.pmtiles archive.
)
echo.
echo Preparing the complete Kazakhstan rectangle.
echo This can create many large files. Make sure free disk space is sufficient.
echo Progress log: hosting_upload\protomaps\prepare_protomaps.log
echo Press Ctrl+C to stop; restart to resume.
echo.

py -u "tools\prepare_protomaps_grid.py" --pmtiles "%PMT%" --source "%SRC%" --bbox "46.49,40.56,87.31,55.44" --step 0.5 --batch-size 100 --max-cells 100000 --maxzoom 15
set "RESULT=%ERRORLEVEL%"
if not "%RESULT%"=="0" goto :FAILED

echo.
echo SUCCESS. Upload hosting_upload\protomaps\ to:
echo https://create.web-works.kz/maps/protomaps/
echo.
echo The window remains open until you press a key.
pause
exit /b 0

:FAILED
echo.
echo Preparation stopped. Completed files and catalog are preserved.
echo Read hosting_upload\protomaps\prepare_protomaps.log
echo You may rerun this BAT later to resume.
echo.
pause
exit /b 1
