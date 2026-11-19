@echo off
setlocal
cd /d "%~dp0\.."
where py >nul 2>nul
if errorlevel 1 (
  echo Python launcher not found. Install Python 3 from python.org.
  pause
  exit /b 1
)
where osmium >nul 2>nul
if errorlevel 1 (
  echo osmium-tool not found in PATH. Install osmium-tool first.
  pause
  exit /b 1
)
py -c "from PIL import Image" >nul 2>nul
if errorlevel 1 (
  echo Installing Pillow...
  py -m pip install Pillow || exit /b 1
)
echo.
echo Available areas: almaty-city, astana-city, shymkent-city, karaganda-city, aktobe-city
echo.
set /p REGION=Choose area [almaty-city]:
if "%REGION%"=="" set "REGION=almaty-city"
py tools\prepare_offline_map.py --preset "%REGION%" --zoom 9:14
if errorlevel 1 (
  echo Map preparation failed. See error above.
  pause
  exit /b 1
)
echo.
echo Import maps\%REGION%.mbtiles into the iPhone application using Files.
pause
