@echo off
setlocal
cd /d "%~dp0"
title PC Cleanup

:menu
cls
echo.
echo   PC Cleanup ^& Health Check
echo   ------------------------------------------
echo   1. Health report only (changes nothing)
echo   2. Preview cleanup (shows what would be deleted)
echo   3. Clean now
echo   4. Deep clean as Administrator (also Windows temp + update cache)
echo   5. Exit
echo.
set /p choice="  Choose 1-5: "

if "%choice%"=="1" powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0PCCleanup.ps1" -ReportOnly & goto done
if "%choice%"=="2" powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0PCCleanup.ps1" -DryRun & goto done
if "%choice%"=="3" powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0PCCleanup.ps1" & goto done
if "%choice%"=="4" powershell -NoProfile -Command "Start-Process powershell -Verb RunAs -ArgumentList '-NoProfile -ExecutionPolicy Bypass -NoExit -File \"%~dp0PCCleanup.ps1\"'" & goto menu
if "%choice%"=="5" exit /b
goto menu

:done
echo.
pause
goto menu
