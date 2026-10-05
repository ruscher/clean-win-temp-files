@echo off
rem Clean Windows Temp Files - launcher.
rem Runs clean-win-temp-files.ps1 with the Windows PowerShell 5.1 that ships with
rem Windows 10 and 11 and passes every argument through, for example:
rem     clean-win-temp-files.bat -DryRun
rem Administrator rights are requested by the script itself, only when needed.
setlocal EnableExtensions DisableDelayedExpansion

rem Started by double-click (cmd /c): the window closes at the end, so ask the script to wait.
set "CWTF_PAUSE="
setlocal EnableDelayedExpansion
set "CWTF_CMDLINE=!cmdcmdline!"
set "CWTF_FLAG="
if defined CWTF_CMDLINE if /i not "!CWTF_CMDLINE:/c=!"=="!CWTF_CMDLINE!" set "CWTF_FLAG=-PauseOnExit"
endlocal & set "CWTF_PAUSE=%CWTF_FLAG%"

set "CWTF_SCRIPT=%~dp0clean-win-temp-files.ps1"
if not exist "%CWTF_SCRIPT%" goto :missing

rem Absolute path: never pick up a powershell.exe from the current folder or PATH.
rem A 32-bit cmd.exe sees SysWOW64 as System32; Sysnative reaches the 64-bit host.
set "CWTF_PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if exist "%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" set "CWTF_PS=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
if exist "%CWTF_PS%" goto :run
set "CWTF_PS="
for %%I in (pwsh.exe) do set "CWTF_PS=%%~$PATH:I"
if not defined CWTF_PS goto :nopowershell

:run
rem -ExecutionPolicy Bypass applies to this process only; Windows blocks downloaded
rem scripts by default. Group Policy settings still take precedence.
"%CWTF_PS%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%CWTF_SCRIPT%" %CWTF_PAUSE% %*
exit /b %ERRORLEVEL%

:missing
echo.
echo  Clean Windows Temp Files
echo  Required file not found: "%CWTF_SCRIPT%"
echo  Keep clean-win-temp-files.bat and clean-win-temp-files.ps1 in the same folder.
goto :fail

:nopowershell
echo.
echo  Clean Windows Temp Files
echo  Windows PowerShell was not found. It is part of Windows 10 and Windows 11.

:fail
echo.
if defined CWTF_PAUSE pause
exit /b 1
