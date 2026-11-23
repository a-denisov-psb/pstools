@echo off
rem Starts the PSTools GUI (Windows PowerShell 5.1, ExecutionPolicy Bypass for this process only).
rem   Start-PSTools.cmd          GUI without console window
rem   Start-PSTools.cmd debug    GUI with console window (shows errors and warnings)

if /i "%~1"=="debug" (
    "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -STA -NoExit -File "%~dp0PSTools.ps1"
    goto :eof
)

start "" "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0PSTools.ps1"
