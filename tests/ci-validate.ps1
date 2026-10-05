#Requires -Version 5.1
<#
    End-to-end validation on a disposable Windows machine (GitHub Actions runner).

    Runs the Pester suite and then the real program, as a child process of the same
    PowerShell edition, against fixtures planted in the real %TEMP%, %SystemRoot%\Temp and
    %LOCALAPPDATA%\CrashDumps. The real cleanup also cleans the runner's own temp folders.

    DO NOT run this on a computer you care about: it performs a real cleanup.
#>
[CmdletBinding()]
param(
    [string]$ResultsPath = (Join-Path ([IO.Path]::GetTempPath()) 'cwtf-results'),
    [switch]$SkipDism
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$tool = Join-Path $root 'clean-win-temp-files.ps1'
$launcher = Join-Path $root 'clean-win-temp-files.bat'
$hostExe = (Get-Process -Id $PID).Path
$failures = New-Object System.Collections.Generic.List[string]
$runNumber = 0
[void][IO.Directory]::CreateDirectory($ResultsPath)

function Write-Section([string]$Title) { Write-Host ''; Write-Host "=== $Title" -ForegroundColor Cyan }

function Assert-That([string]$Name, [bool]$Condition, [string]$Detail = '') {
    if ($Condition) { Write-Host "  [PASS] $Name" -ForegroundColor Green }
    else {
        Write-Host "  [FAIL] $Name $Detail" -ForegroundColor Red
        $failures.Add($Name)
    }
}

function Invoke-Tool {
    # Runs the real program in a child process; stdin is redirected so it never waits for input.
    param([string[]]$Arguments)
    $script:runNumber++
    $log = Join-Path $ResultsPath ('run-{0:00}.log' -f $script:runNumber)
    $allArguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $tool) + $Arguments + @('-NoColor', '-LogPath', $log)
    $output = '' | & $hostExe @allArguments 2>&1 | Out-String
    $code = $LASTEXITCODE
    Write-Host ($output.TrimEnd())
    $jsonPath = [IO.Path]::ChangeExtension($log, '.json')
    $json = $null
    if (Test-Path -LiteralPath $jsonPath) { $json = Get-Content -LiteralPath $jsonPath -Raw | ConvertFrom-Json }
    return [pscustomobject]@{ ExitCode = $code; Output = $output; Json = $json; Log = $log }
}

function Get-Category($Run, [string]$Id) {
    if (-not $Run.Json) { return $null }
    return $Run.Json.categories | Where-Object { $_.id -eq $Id } | Select-Object -First 1
}

function New-AgedTestFile([string]$Path, [int]$AgeDays, [int]$Size = 1024) {
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path))
    [IO.File]::WriteAllBytes($Path, (New-Object byte[] $Size))
    $stamp = [datetime]::UtcNow.AddDays(-$AgeDays)
    [IO.File]::SetCreationTimeUtc($Path, $stamp)
    [IO.File]::SetLastWriteTimeUtc($Path, $stamp)
    return $Path
}

function Set-DirectoryAge([string]$Path, [int]$AgeDays) {
    $stamp = [datetime]::UtcNow.AddDays(-$AgeDays)
    [IO.Directory]::SetCreationTimeUtc($Path, $stamp)
    [IO.Directory]::SetLastWriteTimeUtc($Path, $stamp)
}

Write-Section ("Environment: PowerShell {0} {1} on {2}" -f $PSVersionTable.PSVersion, $PSVersionTable.PSEdition, [Environment]::OSVersion.VersionString)
Write-Host "  TEMP=$env:TEMP"
Write-Host "  GetTempPath=$([IO.Path]::GetTempPath())"

#region Pester
Write-Section 'Pester'
$pester = Get-Module -ListAvailable -Name Pester | Where-Object { $_.Version -ge [version]'5.5.0' } | Sort-Object Version -Descending | Select-Object -First 1
if (-not $pester) {
    if ($PSVersionTable.PSEdition -eq 'Desktop') {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope CurrentUser | Out-Null
    }
    Install-Module -Name Pester -MinimumVersion 5.5.0 -Force -SkipPublisherCheck -Scope CurrentUser
}
Import-Module Pester -MinimumVersion 5.5.0
$configuration = New-PesterConfiguration
$configuration.Run.Path = Join-Path $root 'tests'
$configuration.Run.PassThru = $true
$configuration.Output.Verbosity = 'Detailed'
$configuration.TestResult.Enabled = $true
$configuration.TestResult.OutputFormat = 'NUnitXml'
$configuration.TestResult.OutputPath = Join-Path $ResultsPath 'pester.xml'
$pesterResult = Invoke-Pester -Configuration $configuration
Assert-That 'Pester: no failures' ($pesterResult.FailedCount -eq 0) "($($pesterResult.FailedCount) failed)"
Assert-That 'Pester: Windows-only tests ran (none skipped)' ($pesterResult.SkippedCount -eq 0) "($($pesterResult.SkippedCount) skipped)"
Assert-That 'Pester: test containers loaded' (@($pesterResult.Containers | Where-Object { $_.Result -eq 'Failed' }).Count -eq 0)
#endregion

#region Fixtures
Write-Section 'Fixtures'
$tag = 'cwtf-ci-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
$userTemp = Join-Path ([IO.Path]::GetTempPath()) $tag
$windowsTemp = Join-Path $env:SystemRoot 'Temp'
$crashDumps = Join-Path $env:LOCALAPPDATA 'CrashDumps'
$precious = Join-Path $env:USERPROFILE "$tag-precious"

$old = @(
    (New-AgedTestFile (Join-Path $userTemp 'old.tmp') 10),
    (New-AgedTestFile (Join-Path $userTemp 'nome com espaço ção 文件.tmp') 10),
    (New-AgedTestFile (Join-Path $userTemp 'deep\a\b\old.log') 10 4096)
)
$readOnly = New-AgedTestFile (Join-Path $userTemp 'readonly.tmp') 10
[IO.File]::SetAttributes($readOnly, [IO.FileAttributes]::ReadOnly)
$old += $readOnly
foreach ($dir in @('deep\a\b', 'deep\a', 'deep')) { Set-DirectoryAge (Join-Path $userTemp $dir) 10 }

$recent = New-AgedTestFile (Join-Path $userTemp 'recent.tmp') 0
$locked = New-AgedTestFile (Join-Path $userTemp 'locked.tmp') 10
$keep = New-AgedTestFile (Join-Path $precious 'keep.txt') 10
$keepDeep = New-AgedTestFile (Join-Path $precious 'sub\keep2.txt') 10
$junction = Join-Path $userTemp 'junction-to-precious'
New-Item -ItemType Junction -Path $junction -Target $precious | Out-Null
$fileLink = Join-Path $userTemp 'file-link.tmp'
New-Item -ItemType SymbolicLink -Path $fileLink -Target $keep | Out-Null
foreach ($link in @($junction, $fileLink)) {
    $stamp = [datetime]::UtcNow.AddDays(-10)
    try { [IO.File]::SetLastWriteTimeUtc($link, $stamp) } catch { Write-Verbose 'link time not settable' }
}

$winOld = New-AgedTestFile (Join-Path $windowsTemp "$tag-old.tmp") 5
$winNew = New-AgedTestFile (Join-Path $windowsTemp "$tag-new.tmp") 1
$dumpOld = New-AgedTestFile (Join-Path $crashDumps "$tag-old.dmp") 40
$dumpNew = New-AgedTestFile (Join-Path $crashDumps "$tag-new.dmp") 5
$dumpOther = New-AgedTestFile (Join-Path $crashDumps "$tag-old.txt") 40
Write-Host "  planted fixtures under $userTemp, $windowsTemp, $crashDumps and $precious"
#endregion

#region Basic commands
Write-Section 'ListCategories'
$run = Invoke-Tool @('-ListCategories')
Assert-That 'ListCategories exits 0' ($run.ExitCode -eq 0) "(exit $($run.ExitCode))"
Assert-That 'ListCategories lists every category' (($run.Output -match 'UserTemp') -and ($run.Output -match 'ComponentStore') -and ($run.Output -notmatch 'Prefetch'))

Write-Section 'Unknown category'
$run = Invoke-Tool @('-Yes', '-DryRun', '-Include', 'Prefetch')
Assert-That 'Unknown category exits 2' ($run.ExitCode -eq 2) "(exit $($run.ExitCode))"
#endregion

#region Dry run
Write-Section 'Dry run (advanced, includes crash dumps and Recycle Bin)'
$run = Invoke-Tool @('-Yes', '-DryRun', '-Mode', 'Advanced', '-Include', 'CrashDumps,RecycleBin')
Assert-That 'Dry run exits 0' ($run.ExitCode -eq 0) "(exit $($run.ExitCode))"
Assert-That 'Dry run wrote the JSON log' ($null -ne $run.Json)
$allFixtures = $old + @($recent, $locked, $keep, $keepDeep, $winOld, $winNew, $dumpOld, $dumpNew, $dumpOther)
Assert-That 'Dry run deleted nothing' (@($allFixtures | Where-Object { -not (Test-Path -LiteralPath $_) }).Count -eq 0)
$userCategory = Get-Category $run 'UserTemp'
Assert-That 'Dry run found the old user temp fixtures' ($userCategory -and $userCategory.scanState -eq 'Ready' -and $userCategory.foundFiles -ge $old.Count)
Assert-That 'Dry run saw links and did not count them' ($userCategory -and $userCategory.links -ge 2)
Assert-That 'Every scanned category has a final state' (@($run.Json.categories | Where-Object { $_.scanState -eq 'Error' }).Count -eq 0) ($run.Json.categories | Where-Object { $_.scanState -eq 'Error' } | ForEach-Object id)
foreach ($id in @('DeliveryOptimization', 'RecycleBin')) {
    $category = Get-Category $run $id
    Write-Host ("  {0}: scan={1} bytes={2}" -f $id, $category.scanState, $category.foundBytes)
}
#endregion

#region Real cleanup
Write-Section 'Real cleanup (safe selection + crash dumps), with one file locked'
$lock = [IO.File]::Open($locked, 'Open', 'Read', 'None')
try {
    $run = Invoke-Tool @('-Yes', '-Include', 'CrashDumps')
}
finally {
    $lock.Dispose()
}
Assert-That 'Cleanup exits 0' ($run.ExitCode -eq 0) "(exit $($run.ExitCode))"
foreach ($file in $old) { Assert-That "Removed old file $(Split-Path -Leaf $file)" (-not (Test-Path -LiteralPath $file)) }
Assert-That 'Removed old empty folders' (-not (Test-Path -LiteralPath (Join-Path $userTemp 'deep')))
Assert-That 'Kept the Temp folder itself' (Test-Path -LiteralPath ([IO.Path]::GetTempPath()))
Assert-That 'Kept the recent file' (Test-Path -LiteralPath $recent)
Assert-That 'Kept the locked file' (Test-Path -LiteralPath $locked)
Assert-That 'Kept the junction' (Test-Path -LiteralPath $junction)
Assert-That 'Kept the file symbolic link' (Test-Path -LiteralPath $fileLink)
Assert-That 'Kept everything behind the junction' ((Test-Path -LiteralPath $keep) -and (Test-Path -LiteralPath $keepDeep))
Assert-That 'Removed the old Windows Temp fixture' (-not (Test-Path -LiteralPath $winOld))
Assert-That 'Kept the 1-day-old Windows Temp fixture (72 h rule)' (Test-Path -LiteralPath $winNew)
Assert-That 'Removed the 40-day-old dump' (-not (Test-Path -LiteralPath $dumpOld))
Assert-That 'Kept the 5-day-old dump (30-day rule)' (Test-Path -LiteralPath $dumpNew)
Assert-That 'Kept a non-dump file in CrashDumps' (Test-Path -LiteralPath $dumpOther)
$userCategory = Get-Category $run 'UserTemp'
Assert-That 'Reported the locked file as in use' ($userCategory -and $userCategory.inUse -ge 1) "(inUse=$($userCategory.inUse))"
Assert-That 'Reported recovered bytes' ($run.Json -and $run.Json.recoveredBytes -gt 0)
Assert-That 'Log does not contain the profile path' (-not ((Get-Content -LiteralPath $run.Log -Raw).Contains($env:USERPROFILE)))
#endregion

#region Misconfigured TEMP
Write-Section '%TEMP% pointing into Documents'
$documents = [Environment]::GetFolderPath('MyDocuments')
$badTemp = Join-Path $documents "Temp\$tag"
$thesis = New-AgedTestFile (Join-Path $badTemp 'thesis.docx') 30
$savedTemp = $env:TEMP
$savedTmp = $env:TMP
$env:TEMP = $badTemp
$env:TMP = $badTemp
try {
    $run = Invoke-Tool @('-Yes')
}
finally {
    $env:TEMP = $savedTemp
    $env:TMP = $savedTmp
}
Assert-That 'Run still exits 0' ($run.ExitCode -eq 0) "(exit $($run.ExitCode))"
Assert-That 'User temp category aborted' ((Get-Category $run 'UserTemp').scanState -eq 'Aborted')
Assert-That 'Document survived' (Test-Path -LiteralPath $thesis)
Assert-That 'Abort is visible on screen' ($run.Output -match 'skipped for safety')
#endregion

#region Launcher and language
Write-Section 'Launcher (.bat) and Portuguese UI'
$batOutput = cmd.exe /d /c "`"$launcher`" -DryRun -Yes -NoLog -Language pt < NUL" 2>&1 | Out-String
$batCode = $LASTEXITCODE
Write-Host ($batOutput.TrimEnd())
Assert-That 'Launcher exits 0' ($batCode -eq 0) "(exit $batCode)"
Assert-That 'Launcher shows the Portuguese UI' ($batOutput -match 'LIMPEZA SEGURA')
#endregion

#region DISM
if (-not $SkipDism) {
    Write-Section 'Component store analysis through DISM (dry run)'
    $run = Invoke-Tool @('-Yes', '-DryRun', '-Include', 'ComponentStore')
    $componentStore = Get-Category $run 'ComponentStore'
    Assert-That 'DISM dry run exits 0' ($run.ExitCode -eq 0) "(exit $($run.ExitCode))"
    Assert-That 'DISM analysis produced a decision' ($componentStore -and @('Simulated', 'Skipped') -contains $componentStore.cleanState) "(state=$($componentStore.cleanState))"
}
#endregion

#region Standard user
Write-Section 'Standard (non-administrator) user'
$userName = 'cwtfci' + (Get-Random -Maximum 9999)
$password = 'Cw!' + [guid]::NewGuid().ToString('N').Substring(0, 16)
$secure = ConvertTo-SecureString $password -AsPlainText -Force
$public = Join-Path $env:PUBLIC 'cwtf-ci'
[void][IO.Directory]::CreateDirectory($public)
Copy-Item -LiteralPath $tool -Destination $public -Force
$userOut = Join-Path $public 'user-output.txt'
try {
    & net.exe user $userName $password /add /y | Out-Null
    $credential = New-Object Management.Automation.PSCredential(".\$userName", $secure)
    $process = Start-Process -FilePath $hostExe -Credential $credential -LoadUserProfile -WorkingDirectory $public -PassThru -Wait `
        -RedirectStandardOutput $userOut -RedirectStandardError "$userOut.err" `
        -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $public 'clean-win-temp-files.ps1'), '-Yes', '-DryRun', '-NoColor', '-NoElevate', '-NoLog')
    $text = (Get-Content -LiteralPath $userOut -Raw) + (Get-Content -LiteralPath "$userOut.err" -Raw)
    Write-Host $text
    Assert-That 'Standard user run exits 0' ($process.ExitCode -eq 0) "(exit $($process.ExitCode))"
    Assert-That 'Standard user is detected' ($text -match 'Standard user')
    Assert-That 'Windows Temp needs administrator' ($text -match 'needs administrator')
}
catch {
    Write-Host "  [SKIP] could not run as a separate user on this runner: $($_.Exception.Message)" -ForegroundColor Yellow
}
finally {
    & net.exe user $userName /delete | Out-Null
}
#endregion

#region Cleanup of fixtures
# Remove the links themselves first (non-recursive), then the fixture folders.
try { [IO.Directory]::Delete($junction, $false) } catch { Write-Verbose 'junction already gone' }
try { [IO.File]::Delete($fileLink) } catch { Write-Verbose 'file link already gone' }
foreach ($item in @($userTemp, $precious, $badTemp)) { if (Test-Path -LiteralPath $item) { cmd.exe /d /c "rd /s /q `"$item`"" } }
foreach ($item in @($winNew, $dumpNew, $dumpOther)) { if (Test-Path -LiteralPath $item) { [IO.File]::Delete($item) } }
#endregion

Write-Section 'Summary'
if ($failures.Count -gt 0) {
    Write-Host ("{0} check(s) failed:" -f $failures.Count) -ForegroundColor Red
    $failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}
Write-Host 'All checks passed.' -ForegroundColor Green
exit 0
