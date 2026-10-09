@echo off
setlocal
rem setup.cmd check hoac fix, them -Yes de khong hoi: chay setup.ps1 (kiem tra, cai dat bo agy tren Windows)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup.ps1" %*
exit /b %ERRORLEVEL%
