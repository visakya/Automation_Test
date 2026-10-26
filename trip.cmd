@echo off
rem Batch: short command for the trip automation.
rem   trip           full run (book, drive, end ride, reset location)
rem   trip resume    continue a trip waiting at the pickup
rem   trip reset     put the driver phone back on real GPS
rem   trip devices   list connected phones
cd /d "%~dp0"

if /i "%1"=="resume" (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0run-trip-flow.ps1" -ResumeAtPickup
) else if /i "%1"=="reset" (
    powershell -NoProfile -ExecutionPolicy Bypass -Command "$env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' + [Environment]::GetEnvironmentVariable('Path','User'); . '%~dp0mock-location.ps1'; Reset-MockLocation '9b01005930533036340013b959553c' 6.8813 79.8568"
) else if /i "%1"=="devices" (
    powershell -NoProfile -Command "$env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' + [Environment]::GetEnvironmentVariable('Path','User'); adb devices"
) else (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0run-trip-flow.ps1"
)
