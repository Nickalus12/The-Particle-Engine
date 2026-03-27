@echo off
set target=%2
if /I "%target%"=="git" exit /b 0
if /I "%target%"=="pwsh" exit /b 0
if /I "%target%"=="PowerShell.exe" exit /b 0
exit /b 1
