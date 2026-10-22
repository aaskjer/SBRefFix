@echo off
setlocal
set "HERE=%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%HERE%Fix-SBExport.ps1" -Check %*
echo.
pause
