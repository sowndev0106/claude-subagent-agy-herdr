@echo off
rem An toan: cmd.exe doc lai tham so cua file .cmd nay (ky tu dac biet trong tham so co the thanh lenh shell).
rem Prompt khong do ban viet: truyen bang file (-f prompt.md), hoac goi thang file .ps1 tu PowerShell.
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0agy-fan.ps1" %*
exit /b %ERRORLEVEL%
