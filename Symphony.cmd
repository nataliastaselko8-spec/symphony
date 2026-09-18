@echo off
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\wsl\symphony.ps1" %*
exit /b %errorlevel%
