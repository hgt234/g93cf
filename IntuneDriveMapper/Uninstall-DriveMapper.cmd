@echo off
setlocal
set "PowerShellPath=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PowerShellPath%" set "PowerShellPath=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
"%PowerShellPath%" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%~dp0Uninstall-DriveMapper.ps1"
exit /b %ERRORLEVEL%
