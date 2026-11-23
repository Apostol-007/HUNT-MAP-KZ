@echo off
setlocal EnableExtensions
cd /d "%~dp0.."
chcp 65001 >nul
where py >nul 2>nul
if errorlevel 1 (
 echo Python 3 not found. Install Python from python.org.
 pause
 exit /b 1
)
set "PMT=%~dp0pmtiles.exe"
if not exist "%PMT%" (
 echo Downloading official Protomaps PMTiles CLI for Windows...
 powershell -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop'; $r=Invoke-RestMethod -Uri 'https://api.github.com/repos/protomaps/go-pmtiles/releases/latest' -Headers @{'User-Agent'='HuntMapKZ'}; $a=$r.assets | Where-Object { $_.name -match '(?i)windows.*(x86_64|amd64).*(zip|exe)$' } | Select-Object -First 1; if(!$a){throw 'Windows AMD64 binary not found in release. Download pmtiles.exe manually.'}; $target=Join-Path '%~dp0' $a.name; Invoke-WebRequest -Uri $a.browser_download_url -OutFile $target; if($a.name -match '(?i)\.zip$'){Expand-Archive -Force -Path $target -DestinationPath '%~dp0pmtiles-unpack'; $exe=Get-ChildItem '%~dp0pmtiles-unpack' -Recurse -Filter 'pmtiles.exe' | Select-Object -First 1; if(!$exe){throw 'pmtiles.exe missing from ZIP'}; Copy-Item $exe.FullName '%PMT%' -Force}else{Move-Item $target '%PMT%' -Force}"
 if errorlevel 1 (
  echo Could not install pmtiles CLI. Download official Windows executable from:
  echo https://github.com/protomaps/go-pmtiles/releases
  pause
  exit /b 1
 )
)
echo.
echo HUNT MAP KZ - Protomaps regional PMTiles builder.
echo Default area: Almaty and nearby mountains [76.7,43.1,77.2,43.5].
echo Source: latest verified official Protomaps daily build.
echo.
set /p REGION=Bounding box west,south,east,north [76.7,43.1,77.2,43.5]:
if "%REGION%"=="" set "REGION=76.7,43.1,77.2,43.5"
set "SRC=auto"
echo Source selection: automatic (no URL input required).
echo Auto mode probes PMTiles headers with HTTP Range without downloading the planet.
py tools\prepare_protomaps_grid.py --pmtiles "%PMT%" --source "%SRC%" --bbox "%REGION%" --step 0.1 --maxzoom 15
if errorlevel 1 (
 echo ERROR. Existing downloaded archives are kept.
 pause
 exit /b 1
)
echo.
echo Upload everything from hosting_upload\protomaps\ to:
echo https://create.web-works.kz/maps/protomaps/
echo Files must be publicly downloadable via HTTPS.
pause
