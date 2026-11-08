@echo off
rem System Health Check - launcher.
rem Runs system-health-check.ps1 (read-only) with the Windows PowerShell 5.1 that ships
rem with Windows 10 and 11 and passes every argument through, for example:
rem     system-health-check.bat -LoadTest 60
setlocal EnableExtensions DisableDelayedExpansion

rem Started by double-click (cmd /c): the window closes at the end, so ask the script to wait.
set "SHC_PAUSE="
setlocal EnableDelayedExpansion
set "SHC_CMDLINE=!cmdcmdline!"
set "SHC_FLAG="
if defined SHC_CMDLINE if /i not "!SHC_CMDLINE:/c=!"=="!SHC_CMDLINE!" set "SHC_FLAG=-PauseOnExit"
endlocal & set "SHC_PAUSE=%SHC_FLAG%"

set "SHC_SCRIPT=%~dp0system-health-check.ps1"
if not exist "%SHC_SCRIPT%" goto :missing

rem Absolute path: never pick up a powershell.exe from the current folder or PATH.
rem A 32-bit cmd.exe sees SysWOW64 as System32; Sysnative reaches the 64-bit host.
set "SHC_PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if exist "%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" set "SHC_PS=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
if exist "%SHC_PS%" goto :run
set "SHC_PS="
for %%I in (pwsh.exe) do set "SHC_PS=%%~$PATH:I"
if not defined SHC_PS goto :nopowershell

:run
rem -ExecutionPolicy Bypass applies to this process only. The script only reads.
"%SHC_PS%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%SHC_SCRIPT%" %SHC_PAUSE% %*
exit /b %ERRORLEVEL%

:missing
echo.
echo  System Health Check
echo  Required file not found: "%SHC_SCRIPT%"
echo  Keep system-health-check.bat and system-health-check.ps1 in the same folder.
goto :fail

:nopowershell
echo.
echo  System Health Check
echo  Windows PowerShell was not found. It is part of Windows 10 and Windows 11.

:fail
echo.
if defined SHC_PAUSE pause
exit /b 1
