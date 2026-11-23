@echo off
setlocal EnableExtensions DisableDelayedExpansion
title HUNT MAP KZ - Build offline Valhalla routing tiles for Kazakhstan
cd /d "%~dp0.."
chcp 65001 >nul
echo ===============================================
echo  HUNT MAP KZ - VALHALLA KAZAKHSTAN OFFLINE ROUTES
echo ===============================================
echo.
echo This operation builds a ROUTING GRAPH from Kazakhstan OpenStreetMap data.
echo It is NOT PMTiles. Requires Docker Desktop and considerable disk/RAM.
echo The finished TAR can be downloaded by the iPhone from your hosting.
echo.
where docker >nul 2>nul
if errorlevel 1 (
 echo ERROR: Install Docker Desktop for Windows and start it first.
 goto :FAILED
)
docker info >nul 2>nul
if errorlevel 1 (
 echo ERROR: Docker Desktop engine is not running.
 goto :FAILED
)
if not exist "hosting_upload\valhalla" mkdir "hosting_upload\valhalla"
if exist "hosting_upload\valhalla\valhalla_tiles.tar" (
 echo Existing valhalla_tiles.tar found. Reusing it.
 goto :CATALOG
)
echo.
echo Downloading OSM Kazakhstan and building the Valhalla routing graph.
echo Official Valhalla Docker image, no extra scripts.
echo Depending on data volume this can use many GB of memory and storage.
echo.
docker run --rm --name huntmap-kz-valhalla-builder -v "%CD%\hosting_upload\valhalla:/custom_files" -e "tile_urls=https://download.geofabrik.de/asia/kazakhstan-latest.osm.pbf" -e "build_tar=True" -e "serve_tiles=False" -e "server_threads=4" ghcr.io/valhalla/valhalla-scripted:latest
if errorlevel 1 (
 echo ERROR: Valhalla Docker build failed. Look at output above.
 echo You can rerun the BAT after fixing Docker or disk space.
 goto :FAILED
)
:CATALOG
if not exist "hosting_upload\valhalla\valhalla_tiles.tar" (
 echo ERROR: No valhalla_tiles.tar was created.
 goto :FAILED
)
echo.
echo Generating SHA-256 manifest for the app...
powershell -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop'; $p='hosting_upload\valhalla\valhalla_tiles.tar'; $f=Get-Item -LiteralPath $p; $hash=(Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash.ToLowerInvariant(); $manifest=@{schema='hunt-valhalla-v1';file=@{url='https://create.web-works.kz/maps/valhalla/valhalla_tiles.tar';bytes=[long]$f.Length;sha256=$hash}}; $manifest | ConvertTo-Json -Depth 4 | Set-Content -Path 'hosting_upload\valhalla\catalog.json' -Encoding UTF8"
if errorlevel 1 (
 echo ERROR: Could not calculate routing archive checksum.
 goto :FAILED
)
echo.
echo SUCCESS. Upload BOTH files to:
echo https://create.web-works.kz/maps/valhalla/
echo   valhalla_tiles.tar
echo   catalog.json
echo.
echo Then tap "Download Valhalla" in HUNT MAP KZ on your iPhone.
pause
exit /b 0
:FAILED
echo.
echo Task stopped. Window remains open. Do not upload incomplete files.
pause
exit /b 1
