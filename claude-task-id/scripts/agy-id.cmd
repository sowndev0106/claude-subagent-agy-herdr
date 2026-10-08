@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0agy-id.ps1" %*
exit /b %ERRORLEVEL%
