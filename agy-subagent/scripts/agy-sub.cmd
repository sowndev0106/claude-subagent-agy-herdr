@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0agy-sub.ps1" %*
exit /b %ERRORLEVEL%
