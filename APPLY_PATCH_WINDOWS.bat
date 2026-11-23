@echo off
setlocal
cd /d "%~dp0"
echo HUNT MAP KZ v4.8 - delete obsolete screens
if not exist "iOS\project.yml" (echo ERROR: run from repository root & exit /b 1)
for %%F in ("iOS\HuntMap\LegacyMainView.swift" "iOS\HuntMap\MapDownloadAndLayers.swift" "iOS\HuntMap\OfflineAreaPacks.swift") do (
 if exist %%F (del /f /q %%F && echo Deleted: %%F)
)
python scripts\check_ui_structure.py
if errorlevel 1 (echo ERROR: old UI still detected & exit /b 1)
echo Legacy UI removed. Commit deletions to GitHub.
endlocal
