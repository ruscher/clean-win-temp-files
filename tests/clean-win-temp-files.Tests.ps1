#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
    Safety and behavior tests for clean-win-temp-files.ps1.

    Run:  Invoke-Pester -Path .\tests -Output Detailed
    Every destructive test works on fixtures created inside Pester's TestDrive.
    Tests that need Windows (locked files, junctions, the real environment) are skipped elsewhere.
#>

BeforeDiscovery {
    # -Skip conditions are evaluated during discovery, before BeforeAll runs.
    $OnWindows = [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT
}

BeforeAll {
    $scriptPath = [IO.Path]::Combine($PSScriptRoot, '..', 'clean-win-temp-files.ps1')
    . $scriptPath

    $script:IsWindowsHost = Test-IsWindowsHost

    function New-FakeEnvironment {
        param([string]$Drive = 'C:', [string]$User = 'Joao', [switch]$Empty)
        if ($Empty) {
            return @{ SystemRoot = $null; SystemDrive = $null; ProfileRoots = @(); KnownFolders = @() }
        }
        $profileRoot = "$Drive\Users\$User"
        return @{
            SystemRoot        = "$Drive\Windows"
            SystemDrive       = $Drive
            ProgramFiles      = "$Drive\Program Files"
            ProgramFilesX86   = "$Drive\Program Files (x86)"
            ProgramW6432      = "$Drive\Program Files"
            ProgramData       = "$Drive\ProgramData"
            Public            = "$Drive\Users\Public"
            UserProfile       = $profileRoot
            AppData           = "$profileRoot\AppData\Roaming"
            LocalAppData      = "$profileRoot\AppData\Local"
            OwnLocalAppData   = "$profileRoot\AppData\Local"
            ProfilesDirectory = "$Drive\Users"
            ProfileRoots      = @($profileRoot, "$Drive\Users\Public")
            KnownFolders      = @("$profileRoot\Desktop", "$profileRoot\Documents", "$profileRoot\Downloads",
                "$profileRoot\Pictures", "$profileRoot\Videos", "$profileRoot\Music", "$profileRoot\OneDrive")
            TempCandidates    = @("$profileRoot\AppData\Local\Temp\")
        }
    }

    function New-FakeContext {
        param($Policy, [bool]$IsAdmin = $true, [datetime]$ReferenceTimeUtc = [datetime]::UtcNow)
        return [pscustomobject]@{
            IsAdmin          = $IsAdmin
            Environment      = New-FakeEnvironment
            Policy           = $Policy
            LocalAppData     = 'C:\Users\Joao\AppData\Local'
            OtherUser        = $false
            WindowsTempRoot  = 'C:\Windows\Temp'
            PendingFiles     = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
            RebootPending    = $false
            ReferenceTimeUtc = $ReferenceTimeUtc
            RunningProcesses = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        }
    }

    function Set-EntryTime {
        param([string]$Path, [datetime]$Utc)
        if ([IO.Directory]::Exists($Path)) {
            [IO.Directory]::SetLastWriteTimeUtc($Path, $Utc)
            try { [IO.Directory]::SetCreationTimeUtc($Path, $Utc) } catch { Write-Verbose 'creation time not settable' }
        }
        else {
            [IO.File]::SetLastWriteTimeUtc($Path, $Utc)
            try { [IO.File]::SetCreationTimeUtc($Path, $Utc) } catch { Write-Verbose 'creation time not settable' }
        }
    }

    function New-TextFile {
        param([string]$Path, [int]$Size = 64)
        [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path))
        [IO.File]::WriteAllBytes($Path, (New-Object byte[] $Size))
        return $Path
    }

    function New-DirectoryLink {
        # Junction on Windows (no privilege needed), symbolic link elsewhere.
        param([string]$Path, [string]$Target)
        if ($script:IsWindowsHost) { New-Item -ItemType Junction -Path $Path -Target $Target | Out-Null }
        else { New-Item -ItemType SymbolicLink -Path $Path -Target $Target | Out-Null }
    }

    $script:FakePolicy = New-ProtectionPolicy -Environment (New-FakeEnvironment)
}

Describe 'Path canonicalization' {
    It 'normalizes <Value> to <Expected>' -ForEach @(
        @{ Value = 'C:\Windows\'; Expected = 'C:\Windows' }
        @{ Value = 'c:/windows/temp'; Expected = 'C:\windows\temp' }
        @{ Value = 'C:\Windows. '; Expected = 'C:\Windows' }
        @{ Value = 'C:\Windows\Temp\..'; Expected = 'C:\Windows' }
        @{ Value = 'C:\Windows\.\Temp'; Expected = 'C:\Windows\Temp' }
        @{ Value = 'C:\\Users\\\\x'; Expected = 'C:\Users\x' }
        @{ Value = 'C:\'; Expected = 'C:\' }
        @{ Value = '  C:\Users\João Silva\AppData\Local\Temp  '; Expected = 'C:\Users\João Silva\AppData\Local\Temp' }
    ) {
        ConvertTo-CanonicalPath $Value | Should -BeExactly $Expected
    }

    It 'rejects <Value>' -ForEach @(
        @{ Value = $null }
        @{ Value = '' }
        @{ Value = '   ' }
        @{ Value = '%TEMP%' }
        @{ Value = '%SystemRoot%\Temp' }
        @{ Value = 'C:' }
        @{ Value = 'C:Windows' }
        @{ Value = 'Temp' }
        @{ Value = '.\Temp' }
        @{ Value = '\Windows\Temp' }
        @{ Value = '\\server\share\Temp' }
        @{ Value = '\\?\C:\Windows' }
        @{ Value = '\\.\C:\Windows' }
        @{ Value = 'C:\..\..\Windows' }
        @{ Value = 'C:\Temp\*' }
        @{ Value = 'C:\Temp\file.txt:stream' }
        @{ Value = '"C:\Temp"' }
        @{ Value = "C:\Temp`n" + 'x' }
    ) {
        ConvertTo-CanonicalPath $Value | Should -BeNullOrEmpty
    }

    It 'does not treat a sibling with a common prefix as a child' {
        Test-PathIsSameOrUnder -Path 'C:\Windows2\Temp' -Parent 'C:\Windows' | Should -BeFalse
        Test-PathIsSameOrUnder -Path 'C:\Windows\Temp' -Parent 'C:\Windows' | Should -BeTrue
        Test-PathIsSameOrUnder -Path 'c:\windows' -Parent 'C:\Windows' | Should -BeTrue
        Test-PathIsSameOrUnder -Path 'D:\Windows' -Parent 'C:\' | Should -BeFalse
    }

    It 'flags 8.3 short names' {
        Test-HasShortNameSegment 'C:\PROGRA~1\App' | Should -BeTrue
        Test-HasShortNameSegment 'C:\Users\JOAOSI~1\AppData\Local\Temp' | Should -BeTrue
        Test-HasShortNameSegment 'C:\Users\Joao\AppData\Local\Temp' | Should -BeFalse
    }
}

Describe 'CRITICAL: dangerous cleanup roots are refused' {
    It 'refuses <Path>' -ForEach @(
        @{ Path = 'C:\' }
        @{ Path = 'C:' }
        @{ Path = '%SystemDrive%' }
        @{ Path = '%SystemRoot%' }
        @{ Path = '%SystemDrive%\' }
        @{ Path = '%USERPROFILE%' }
        @{ Path = 'D:\' }
        @{ Path = 'C:\Windows' }
        @{ Path = 'C:\Windows\' }
        @{ Path = 'c:\WINDOWS' }
        @{ Path = 'C:\Windows.' }
        @{ Path = 'C:/Windows' }
        @{ Path = 'C:\Windows\Temp\..' }
        @{ Path = 'C:\Windows\System32' }
        @{ Path = 'C:\Windows\System32\DriverStore' }
        @{ Path = 'C:\Windows\SysWOW64' }
        @{ Path = 'C:\Windows\WinSxS' }
        @{ Path = 'C:\Windows\WinSxS\Temp' }
        @{ Path = 'C:\Windows\Prefetch' }
        @{ Path = 'C:\Windows\SoftwareDistribution' }
        @{ Path = 'C:\Windows\SoftwareDistribution\Download' }
        @{ Path = 'C:\Windows\Installer' }
        @{ Path = 'C:\Windows\Logs' }
        @{ Path = 'C:\Users' }
        @{ Path = 'C:\Users\Joao' }
        @{ Path = 'C:\Users\Public' }
        @{ Path = 'C:\Users\Joao\AppData' }
        @{ Path = 'C:\Users\Joao\AppData\Local' }
        @{ Path = 'C:\Users\Joao\AppData\Roaming' }
        @{ Path = 'C:\Users\Joao\AppData\Roaming\Temp' }
        @{ Path = 'C:\Users\Joao\Documents' }
        @{ Path = 'C:\Users\Joao\Documents\Temp' }
        @{ Path = 'C:\Users\Joao\Downloads' }
        @{ Path = 'C:\Users\Joao\Downloads\Temp' }
        @{ Path = 'C:\Users\Joao\Desktop' }
        @{ Path = 'C:\Users\Joao\Pictures' }
        @{ Path = 'C:\Users\Joao\OneDrive\Temp' }
        @{ Path = 'C:\Program Files' }
        @{ Path = 'C:\Program Files (x86)' }
        @{ Path = 'C:\Program Files\Vendor\Temp' }
        @{ Path = 'C:\ProgramData' }
        @{ Path = 'C:\Recovery' }
        @{ Path = 'C:\System Volume Information' }
        @{ Path = 'C:\$Recycle.Bin' }
        @{ Path = 'C:\Windows.old' }
        @{ Path = 'C:\$WINDOWS.~BT' }
    ) {
        $result = Test-CleanupRootAllowed -Path $Path -Policy $script:FakePolicy
        $result.Allowed | Should -BeFalse -Because "$Path must never be a cleanup root"
    }

    It 'still refuses the C: system folders when Windows is installed on D:' {
        $policy = New-ProtectionPolicy -Environment (New-FakeEnvironment -Drive 'D:')
        foreach ($path in @('C:\Windows', 'C:\Users', 'C:\Program Files', 'C:\ProgramData', 'D:\Windows', 'D:\Users', 'D:\Windows\System32', 'D:\')) {
            (Test-CleanupRootAllowed -Path $path -Policy $policy).Allowed | Should -BeFalse -Because $path
        }
        (Test-CleanupRootAllowed -Path 'D:\Windows\Temp' -Policy $policy).Allowed | Should -BeTrue
    }

    It 'still refuses the system folders when every environment variable is missing' {
        $policy = New-ProtectionPolicy -Environment (New-FakeEnvironment -Empty)
        foreach ($path in @('C:\', 'C:\Windows', 'C:\Windows\System32', 'C:\Users', 'C:\Program Files', 'C:\Program Files (x86)', 'C:\ProgramData', '\Temp', $null)) {
            (Test-CleanupRootAllowed -Path $path -Policy $policy).Allowed | Should -BeFalse -Because "$path"
        }
    }

    It 'accepts the real temporary folders: <Path>' -ForEach @(
        @{ Path = 'C:\Users\Joao\AppData\Local\Temp' }
        @{ Path = 'C:\Users\Joao\AppData\Local\Temp\2' }
        @{ Path = 'C:\Windows\Temp' }
        @{ Path = 'D:\Temp' }
        @{ Path = 'C:\Users\Joao\AppData\Local\Packages\App_8wekyb3d8bbwe\TempState' }
        @{ Path = 'C:\Users\Joao\AppData\Local\D3DSCache' }
        @{ Path = 'C:\ProgramData\Microsoft\Windows\WER\ReportArchive' }
        @{ Path = 'C:\Windows\Minidump' }
    ) {
        (Test-CleanupRootAllowed -Path $Path -Policy $script:FakePolicy).Allowed | Should -BeTrue
    }

    It 'accepts a profile with spaces and Unicode characters' {
        $policy = New-ProtectionPolicy -Environment (New-FakeEnvironment -User 'João da Silva Ñ')
        (Test-CleanupRootAllowed -Path 'C:\Users\João da Silva Ñ\AppData\Local\Temp' -Policy $policy).Allowed | Should -BeTrue
        (Test-CleanupRootAllowed -Path 'C:\Users\João da Silva Ñ' -Policy $policy).Allowed | Should -BeFalse
        (Test-CleanupRootAllowed -Path 'C:\Users\João da Silva Ñ\Documents' -Policy $policy).Allowed | Should -BeFalse
    }

    It 'only allows whitelisted single files' {
        (Test-CleanupFileAllowed -Path 'C:\Windows\MEMORY.DMP' -Policy $script:FakePolicy).Allowed | Should -BeTrue
        foreach ($path in @('C:\Windows\System32\config\SAM', 'C:\pagefile.sys', 'C:\hiberfil.sys', 'C:\swapfile.sys',
                'C:\Windows\notepad.exe', 'C:\Windows\System32\MEMORY.DMP', 'C:\Users\Joao\Documents\MEMORY.DMP', 'C:\')) {
            (Test-CleanupFileAllowed -Path $path -Policy $script:FakePolicy).Allowed | Should -BeFalse -Because $path
        }
    }

    It 'requires a Temp folder name for %TEMP%/%TMP% values' {
        $target = New-CleanupTarget -Path 'D:\Data' -RequireTempName $true
        $result = Resolve-CleanupTarget -Target $target -Policy $script:FakePolicy
        $result.Status | Should -Be 'Rejected'
        $result.Reason | Should -Be 'NotTempFolder'
    }

    It 'refuses the real Windows system locations' -Skip:(-not $OnWindows) {
        $policy = New-ProtectionPolicy -Environment (Get-HostEnvironment)
        $paths = @($env:SystemDrive, "$env:SystemDrive\", $env:SystemRoot, "$env:SystemRoot\System32", $env:USERPROFILE,
            $env:LOCALAPPDATA, $env:APPDATA, $env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramData,
            [Environment]::GetFolderPath('MyDocuments'), [Environment]::GetFolderPath('Desktop'))
        foreach ($path in $paths) {
            if (-not $path) { continue }
            (Test-CleanupRootAllowed -Path $path -Policy $policy).Allowed | Should -BeFalse -Because $path
        }
        (Test-CleanupRootAllowed -Path ([IO.Path]::GetTempPath()) -Policy $policy).Allowed | Should -BeTrue
        (Test-CleanupRootAllowed -Path "$env:SystemRoot\Temp" -Policy $policy).Allowed | Should -BeTrue
    }
}

Describe 'Category abort on a bad root' {
    It 'aborts the whole category when any target resolves to a protected place' {
        $good = Join-Path $TestDrive 'abort-good'
        New-TextFile (Join-Path $good 'old.tmp') | Out-Null
        Set-EntryTime (Join-Path $good 'old.tmp') ([datetime]::UtcNow.AddDays(-10))

        function Get-MixedTestTarget {
            param($Context)
            New-CleanupTarget -Path $good -MinAgeHours 1
            New-CleanupTarget -Path 'C:\Windows' -MinAgeHours 1
        }
        $category = [pscustomobject]@{ Id = 'UserTemp'; Group = 'Safe'; Kind = 'Files'; Builder = 'Get-MixedTestTarget'; RequiresAdmin = $false }
        $scan = New-CategoryScan -Category $category
        Invoke-FilesCategoryScan -Scan $scan -Context (New-FakeContext -Policy $script:FakePolicy)

        $scan.State | Should -Be 'Aborted'
        $scan.Trees.Count | Should -Be 0
        $scan.Files | Should -Be 0
        Test-Path -LiteralPath (Join-Path $good 'old.tmp') | Should -BeTrue
    }

    It 'skips targets that need administrator rights when not elevated' {
        $category = [pscustomobject]@{ Id = 'WindowsTemp'; Group = 'Safe'; Kind = 'Files'; Builder = 'Get-WindowsTempTarget'; RequiresAdmin = $true }
        $scan = Invoke-CategoryScan -Category $category -Context (New-FakeContext -Policy $script:FakePolicy -IsAdmin $false)
        $scan.State | Should -Be 'NeedsAdmin'
    }
}

Describe 'Scanner and cleaner on fixtures' {
    BeforeEach {
        # "Now" is pushed 30 days ahead: anything created during the test looks 30 days old
        # unless its timestamp is moved forward on purpose to look recent.
        $script:Reference = [datetime]::UtcNow.AddDays(30)
        $recentStamp = $script:Reference.AddMinutes(-30)
        $oldStamp = [datetime]::UtcNow.AddDays(-10)

        $script:Root = Join-Path $TestDrive ('temp-' + [guid]::NewGuid().ToString('N'))
        $script:Outside = Join-Path $TestDrive ('outside-' + [guid]::NewGuid().ToString('N'))

        $script:Old = @(
            (New-TextFile (Join-Path $Root 'old.tmp') 100),
            (New-TextFile (Join-Path $Root 'name with spaces.tmp') 200),
            (New-TextFile (Join-Path $Root 'ação ünïcødé 文件.tmp') 300),
            (New-TextFile (Join-Path $Root 'readonly.tmp') 400),
            (New-TextFile (Join-Path $Root 'nested\a\b\deep.log') 500),
            (New-TextFile (Join-Path $Root 'big.bin') (2MB)),
            (New-TextFile (Join-Path $Root 'crash.dmp') 600)
        )
        $script:Recent = New-TextFile (Join-Path $Root 'recent.tmp') 50
        $script:Precious = New-TextFile (Join-Path $Outside 'precious.txt') 70
        $script:Precious2 = New-TextFile (Join-Path $Outside 'sub\precious2.txt') 80
        [void][IO.Directory]::CreateDirectory((Join-Path $Root 'empty-old'))
        [void][IO.Directory]::CreateDirectory((Join-Path $Root 'empty-new'))

        New-DirectoryLink -Path (Join-Path $Root 'link-to-outside') -Target $Outside
        $script:FileLinkCreated = $false
        try {
            New-Item -ItemType SymbolicLink -Path (Join-Path $Root 'file-link.tmp') -Target $Precious -ErrorAction Stop | Out-Null
            $script:FileLinkCreated = $true
        }
        catch { Write-Verbose 'File symbolic links need extra privileges on Windows' }

        foreach ($file in $Old + @($Precious, $Precious2)) { Set-EntryTime $file $oldStamp }
        [IO.File]::SetAttributes((Join-Path $Root 'readonly.tmp'), [IO.FileAttributes]::ReadOnly)
        Set-EntryTime $Recent $recentStamp
        foreach ($dir in @('nested\a\b', 'nested\a', 'nested', 'empty-old')) { Set-EntryTime (Join-Path $Root $dir) $oldStamp }
        Set-EntryTime (Join-Path $Root 'empty-new') $recentStamp
        $script:OldBytes = ($Old | ForEach-Object { (Get-Item -LiteralPath $_).Length } | Measure-Object -Sum).Sum
    }

    It 'finds old files, protects recent ones and never descends into links' {
        $tree = Invoke-TreeScan -RootPath $Root -MinAgeHours 24 -ReferenceTimeUtc $Reference
        $tree.Files.Count | Should -Be $Old.Count
        $tree.Bytes | Should -Be $OldBytes
        $tree.RecentFiles | Should -Be 1
        $tree.Links | Should -BeGreaterOrEqual 1
        $tree.Files.FullName | Should -Not -Contain $Precious
        @($tree.Files.FullName | Where-Object { $_ -like '*precious*' }).Count | Should -Be 0
    }

    It 'removes only old files and empty old folders, and keeps the root' {
        $target = New-CleanupTarget -Path $Root -MinAgeHours 24
        $tree = Invoke-TreeScan -RootPath $Root -MinAgeHours 24 -ReferenceTimeUtc $Reference
        $result = New-CleanResult -Scan $null
        Invoke-TreeClean -Result $result -Tree $tree -Target $target -ReferenceTimeUtc $Reference

        foreach ($file in $Old) { Test-Path -LiteralPath $file | Should -BeFalse -Because $file }
        $result.RemovedFiles | Should -Be $Old.Count
        $result.RemovedBytes | Should -Be $OldBytes
        $result.Errors | Should -Be 0

        Test-Path -LiteralPath $Root | Should -BeTrue
        Test-Path -LiteralPath $Recent | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $Root 'nested') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $Root 'empty-old') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $Root 'empty-new') | Should -BeTrue

        # Links and everything they point to stay intact.
        Test-Path -LiteralPath (Join-Path $Root 'link-to-outside') | Should -BeTrue
        Test-Path -LiteralPath $Precious | Should -BeTrue
        Test-Path -LiteralPath $Precious2 | Should -BeTrue
        if ($FileLinkCreated) { Test-Path -LiteralPath (Join-Path $Root 'file-link.tmp') | Should -BeTrue }
    }

    It 'deletes nothing in dry run' {
        $category = [pscustomobject]@{ Id = 'UserTemp'; Group = 'Safe'; Kind = 'Files'; Builder = $null; RequiresAdmin = $false }
        $scan = New-CategoryScan -Category $category
        $tree = Invoke-TreeScan -RootPath $Root -MinAgeHours 24 -ReferenceTimeUtc $Reference
        $scan.Trees.Add([pscustomobject]@{ Target = (New-CleanupTarget -Path $Root); Tree = $tree })
        $scan.Files = $tree.Files.Count
        $scan.Bytes = $tree.Bytes

        $result = Invoke-CategoryClean -Scan $scan -Context (New-FakeContext -Policy $script:FakePolicy -ReferenceTimeUtc $Reference) -DryRun
        $result.State | Should -Be 'Simulated'
        $result.RemovedBytes | Should -Be $OldBytes
        foreach ($file in $Old) { Test-Path -LiteralPath $file | Should -BeTrue }
    }

    It 'applies include patterns (crash dumps only)' {
        $target = New-CleanupTarget -Path $Root -Include '*.dmp' -RemoveEmptyDirs $false -MinAgeHours 24
        $tree = Invoke-TreeScan -RootPath $Root -Include $target.Include -MinAgeHours 24 -ReferenceTimeUtc $Reference
        $tree.Files.Count | Should -Be 1
        $result = New-CleanResult -Scan $null
        Invoke-TreeClean -Result $result -Tree $tree -Target $target -ReferenceTimeUtc $Reference
        Test-Path -LiteralPath (Join-Path $Root 'crash.dmp') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $Root 'old.tmp') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $Root 'empty-old') | Should -BeTrue
    }

    It 'does not recurse when asked not to' {
        $tree = Invoke-TreeScan -RootPath $Root -Recurse $false -MinAgeHours 24 -ReferenceTimeUtc $Reference
        $tree.Files.FullName | Should -Not -Contain (Join-Path $Root 'nested\a\b\deep.log')
    }

    It 'protects files scheduled for a rename at restart' {
        $set = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        [void]$set.Add((ConvertTo-CanonicalPath (Join-Path $Root 'old.tmp')))
        $tree = Invoke-TreeScan -RootPath (ConvertTo-CanonicalPath $Root) -MinAgeHours 24 -ReferenceTimeUtc $Reference -ProtectedFiles $set
        $tree.ProtectedPending | Should -Be 1
        $tree.Files.FullName | Should -Not -Contain (ConvertTo-CanonicalPath (Join-Path $Root 'old.tmp'))
    }

    It 'skips a file that became recent after the scan' {
        $target = New-CleanupTarget -Path $Root -MinAgeHours 24
        $tree = Invoke-TreeScan -RootPath $Root -MinAgeHours 24 -ReferenceTimeUtc $Reference
        Set-EntryTime (Join-Path $Root 'old.tmp') $Reference.AddMinutes(-5)
        $result = New-CleanResult -Scan $null
        Invoke-TreeClean -Result $result -Tree $tree -Target $target -ReferenceTimeUtc $Reference
        Test-Path -LiteralPath (Join-Path $Root 'old.tmp') | Should -BeTrue
        $result.Recent | Should -Be 1
    }

    It 'does not follow a folder swapped for a link after the scan (TOCTOU)' {
        $target = New-CleanupTarget -Path $Root -MinAgeHours 24
        $tree = Invoke-TreeScan -RootPath $Root -MinAgeHours 24 -ReferenceTimeUtc $Reference

        $decoy = Join-Path $TestDrive ('decoy-' + [guid]::NewGuid().ToString('N'))
        $victim = New-TextFile (Join-Path $decoy 'a\b\deep.log') 10
        Set-EntryTime $victim ([datetime]::UtcNow.AddDays(-10))
        [IO.Directory]::Move((Join-Path $Root 'nested'), (Join-Path $Root 'nested-moved'))
        New-DirectoryLink -Path (Join-Path $Root 'nested') -Target $decoy

        $result = New-CleanResult -Scan $null
        Invoke-TreeClean -Result $result -Tree $tree -Target $target -ReferenceTimeUtc $Reference
        Test-Path -LiteralPath $victim | Should -BeTrue
        $result.Links | Should -BeGreaterOrEqual 1
    }

    It 'resolves a missing folder as NotFound without error' {
        $target = New-CleanupTarget -Path (Join-Path $TestDrive 'does-not-exist')
        (Resolve-CleanupTarget -Target $target -Policy $script:FakePolicy).Status | Should -Be 'NotFound'
    }

    It 'rejects a cleanup root that is itself a link' {
        $link = Join-Path $TestDrive ('rootlink-' + [guid]::NewGuid().ToString('N'))
        New-DirectoryLink -Path $link -Target $Outside
        $result = Resolve-CleanupTarget -Target (New-CleanupTarget -Path $link) -Policy $script:FakePolicy
        $result.Status | Should -Be 'Rejected'
        Test-Path -LiteralPath $Precious | Should -BeTrue
    }

    It 'handles an empty folder' {
        $empty = Join-Path $TestDrive ('empty-' + [guid]::NewGuid().ToString('N'))
        [void][IO.Directory]::CreateDirectory($empty)
        $tree = Invoke-TreeScan -RootPath $empty -MinAgeHours 0 -ReferenceTimeUtc $Reference
        $tree.Files.Count | Should -Be 0
        $tree.Bytes | Should -Be 0
    }

    It 'skips a locked file and keeps going' -Skip:(-not $OnWindows) {
        $target = New-CleanupTarget -Path $Root -MinAgeHours 24
        $tree = Invoke-TreeScan -RootPath $Root -MinAgeHours 24 -ReferenceTimeUtc $Reference
        $locked = Join-Path $Root 'old.tmp'
        $stream = [IO.File]::Open($locked, 'Open', 'Read', 'None')
        try {
            $result = New-CleanResult -Scan $null
            Invoke-TreeClean -Result $result -Tree $tree -Target $target -ReferenceTimeUtc $Reference
        }
        finally {
            $stream.Dispose()
        }
        Test-Path -LiteralPath $locked | Should -BeTrue
        $result.InUse | Should -Be 1
        $result.RemovedFiles | Should -Be ($Old.Count - 1)
        $result.Errors | Should -Be 0
    }

    It 'reports access denied without failing' -Skip:(-not $OnWindows) {
        $denied = Join-Path $Root 'denied'
        $file = New-TextFile (Join-Path $denied 'x.tmp') 10
        Set-EntryTime $file ([datetime]::UtcNow.AddDays(-10))
        $acl = Get-Acl -LiteralPath $denied
        $rule = New-Object Security.AccessControl.FileSystemAccessRule([Security.Principal.WindowsIdentity]::GetCurrent().User, 'ListDirectory', 'Deny')
        $acl.AddAccessRule($rule)
        Set-Acl -LiteralPath $denied -AclObject $acl
        try {
            $tree = Invoke-TreeScan -RootPath $Root -MinAgeHours 24 -ReferenceTimeUtc $Reference
            $tree.DeniedDirs | Should -BeGreaterOrEqual 1
        }
        finally {
            $acl.RemoveAccessRule($rule) | Out-Null
            Set-Acl -LiteralPath $denied -AclObject $acl
        }
    }
}

Describe 'Error classification' {
    It 'maps <Name>' -ForEach @(
        @{ Name = 'sharing violation'; Exception = (New-Object IO.IOException('x', [int]0x80070020)); Expected = 'InUse' }
        @{ Name = 'lock violation'; Exception = (New-Object IO.IOException('x', [int]0x80070021)); Expected = 'InUse' }
        @{ Name = 'access denied'; Exception = (New-Object UnauthorizedAccessException('x')); Expected = 'AccessDenied' }
        @{ Name = 'missing file'; Exception = (New-Object IO.FileNotFoundException('x')); Expected = 'Gone' }
        @{ Name = 'missing folder'; Exception = (New-Object IO.DirectoryNotFoundException('x')); Expected = 'Gone' }
        @{ Name = 'long path'; Exception = (New-Object IO.PathTooLongException('x')); Expected = 'PathTooLong' }
        @{ Name = 'other'; Exception = (New-Object InvalidOperationException('x')); Expected = 'Error' }
    ) {
        Get-IoFailureKind $Exception | Should -Be $Expected
    }

    It 'unwraps PowerShell method invocation errors' {
        try { [IO.File]::Delete('') } catch { $caught = $_.Exception }
        $wrapped = New-Object Management.Automation.MethodInvocationException('wrapped', (New-Object UnauthorizedAccessException('inner')))
        Get-IoFailureKind $wrapped | Should -Be 'AccessDenied'
        $caught | Should -Not -BeNullOrEmpty
    }
}

Describe 'Formatting' {
    It 'formats <Bytes> bytes as <Expected>' -ForEach @(
        @{ Bytes = 0; Expected = '0 B' }
        @{ Bytes = 1023; Expected = '1,023 B' }
        @{ Bytes = 1024; Expected = '1.0 KB' }
        @{ Bytes = 1536; Expected = '1.5 KB' }
        @{ Bytes = 157286400; Expected = '150 MB' }
        @{ Bytes = 1073741824; Expected = '1.00 GB' }
        @{ Bytes = 1649267441664; Expected = '1.50 TB' }
    ) {
        Format-ByteSize -Bytes $Bytes -Culture ([Globalization.CultureInfo]::InvariantCulture) | Should -BeExactly $Expected
    }

    It 'uses the Brazilian decimal separator in pt-BR' {
        Format-ByteSize -Bytes 1536 -Culture ([Globalization.CultureInfo]::GetCultureInfo('pt-BR')) | Should -BeExactly '1,5 KB'
    }

    It 'has every UI string in both languages' {
        $missing = @($script:Text.en.Keys | Where-Object { -not $script:Text.pt.ContainsKey($_) }) +
            @($script:Text.pt.Keys | Where-Object { -not $script:Text.en.ContainsKey($_) })
        $missing | Should -BeNullOrEmpty
    }
}

Describe 'Elevation arguments' {
    It 'quotes <Value> as <Expected>' -ForEach @(
        @{ Value = 'abc'; Expected = 'abc' }
        @{ Value = ''; Expected = '""' }
        @{ Value = 'a b'; Expected = '"a b"' }
        @{ Value = 'C:\Path With Space\'; Expected = '"C:\Path With Space\\"' }
        @{ Value = 'say "hi"'; Expected = '"say \"hi\""' }
        @{ Value = 'C:\Users\João Silva\AppData\Local'; Expected = '"C:\Users\João Silva\AppData\Local"' }
    ) {
        ConvertTo-CommandLineArgument $Value | Should -BeExactly $Expected
    }

    It 'preserves the user options and marks the child to avoid loops' {
        $bound = @{
            DryRun      = [switch]$true
            Mode        = 'Advanced'
            Include     = @('RecycleBin', 'CrashDumps')
            LogPath     = 'C:\Log Folder\run.log'
            NoColor     = [switch]$false
            PauseOnExit = [switch]$true
            Relaunched  = [switch]$true
        }
        $arguments = Get-RelaunchArgument -BoundParameters $bound -ScriptPath 'C:\Tools\clean-win-temp-files.ps1' -LocalAppData 'C:\Users\Joao\AppData\Local'
        $arguments | Should -Contain '-DryRun'
        $arguments | Should -Contain 'RecycleBin,CrashDumps'
        $arguments | Should -Contain 'C:\Log Folder\run.log'
        $arguments | Should -Not -Contain '-NoColor'
        @($arguments | Where-Object { $_ -eq '-Relaunched' }).Count | Should -Be 1
        @($arguments | Where-Object { $_ -eq '-PauseOnExit' }).Count | Should -Be 1
        $arguments[$arguments.IndexOf('-TargetLocalAppData') + 1] | Should -Be 'C:\Users\Joao\AppData\Local'
    }

    It 'only accepts a target %LOCALAPPDATA% that belongs to a registered profile' {
        Test-TargetLocalAppData -Path 'C:\Windows\System32' -ProfileRoots @('C:\Users\Joao') | Should -BeNullOrEmpty
        Test-TargetLocalAppData -Path 'C:\Users\Joao\AppData' -ProfileRoots @('C:\Users\Joao') | Should -BeNullOrEmpty
        Test-TargetLocalAppData -Path '%LOCALAPPDATA%' -ProfileRoots @('C:\Users\Joao') | Should -BeNullOrEmpty
    }
}

Describe 'Selection and catalog' {
    BeforeAll {
        function New-TestScan {
            param([string]$Id, [string]$Group, [string]$State, [long]$Bytes = 1000, [string]$Kind = 'Files')
            $scan = New-CategoryScan -Category ([pscustomobject]@{ Id = $Id; Group = $Group; Kind = $Kind; Builder = $null; RequiresAdmin = $false })
            $scan.State = $State
            $scan.Bytes = $Bytes
            return $scan
        }
    }

    It 'pre-selects only ready Safe items' {
        $scans = @(
            (New-TestScan 'UserTemp' 'Safe' 'Ready'),
            (New-TestScan 'WindowsTemp' 'Safe' 'NeedsAdmin'),
            (New-TestScan 'DeliveryOptimization' 'Safe' 'Ready' 10MB 'DeliveryOptimization'),
            (New-TestScan 'RecycleBin' 'Advanced' 'Ready' 5GB 'RecycleBin'),
            (New-TestScan 'CrashDumps' 'Advanced' 'Ready')
        )
        $selection = Get-DefaultSelection -Scans $scans -Include @() -Exclude @()
        $selection.UserTemp | Should -BeTrue
        $selection.WindowsTemp | Should -BeFalse
        $selection.DeliveryOptimization | Should -BeFalse -Because 'small caches are left to Windows'
        $selection.RecycleBin | Should -BeFalse -Because 'the Recycle Bin is never emptied by default'
        $selection.CrashDumps | Should -BeFalse

        $selection = Get-DefaultSelection -Scans $scans -Include @('CrashDumps', 'WindowsTemp') -Exclude @('UserTemp')
        $selection.CrashDumps | Should -BeTrue
        $selection.WindowsTemp | Should -BeFalse -Because 'an item that needs administrator cannot be forced'
        $selection.UserTemp | Should -BeFalse
    }

    It 'never offers Prefetch, WinSxS, Windows Update or personal folders' {
        $context = New-FakeContext -Policy $script:FakePolicy
        $paths = foreach ($category in (Get-CategoryCatalog | Where-Object { $_.Builder })) {
            foreach ($target in @(& $category.Builder $context)) { $target.Path }
        }
        $paths | Should -Not -BeNullOrEmpty
        foreach ($path in $paths) {
            $path | Should -Not -Match 'Prefetch|WinSxS|SoftwareDistribution|\\Installer|Downloads|Documents|Desktop|OneDrive|Roaming'
        }
        (Get-CategoryCatalog).Id | Should -Not -Contain 'Prefetch'
        $script:SafeCategoryIds | Should -Not -Contain 'RecycleBin'
    }

    It 'keeps every built-in target inside the allowed area' {
        $context = New-FakeContext -Policy $script:FakePolicy
        foreach ($category in (Get-CategoryCatalog | Where-Object { $_.Builder })) {
            foreach ($target in @(& $category.Builder $context)) {
                $check = if ($target.Kind -eq 'File') { Test-CleanupFileAllowed -Path $target.Path -Policy $script:FakePolicy } else { Test-CleanupRootAllowed -Path $target.Path -Policy $script:FakePolicy }
                $check.Allowed | Should -BeTrue -Because "$($category.Id): $($target.Path)"
            }
        }
    }

    It 'parses category lists (comma-joined values arrive as one string through -File)' {
        @(ConvertTo-CategoryList @('RecycleBin,CrashDumps', ' ShaderCache ')) | Should -Be @('RecycleBin', 'CrashDumps', 'ShaderCache')
        # Regression: an empty list must stay empty, not become a single $null category.
        @(ConvertTo-CategoryList @()).Count | Should -Be 0
        @(@(ConvertTo-CategoryList @()) + @(ConvertTo-CategoryList @())).Count | Should -Be 0
    }

    It 'wraps long notes inside the console width' {
        $lines = Split-TextLine -Text 'Cache only: logins, cookies, history and bookmarks are kept. Sites load slower at first' -Width 30
        $lines.Count | Should -BeGreaterThan 2
        foreach ($line in $lines) { $line.Length | Should -BeLessOrEqual 30 }
    }

    It 'parses pending rename operations' {
        $set = ConvertFrom-PendingRenameValue -Entries @('\??\C:\Windows\Temp\new.dll', '!\??\C:\Windows\System32\old.dll', '', '\??\C:\Users\Joao\AppData\Local\Temp\x.tmp')
        $set.GetType().Name | Should -Be 'HashSet`1'
        $set.Contains('C:\Windows\Temp\new.dll') | Should -BeTrue
        $set.Contains('c:\windows\system32\old.dll') | Should -BeTrue
        $set.Count | Should -Be 3
    }
}

Describe 'Source code guard rails' {
    BeforeAll {
        $script:Source = Get-Content -LiteralPath ([IO.Path]::Combine($PSScriptRoot, '..', 'clean-win-temp-files.ps1')) -Raw
        $script:Code = ($script:Source -split "`n" | Where-Object { $_ -notmatch '^\s*#' -and $_ -notmatch "^\s*'[A-Za-z.]+'\s+=" }) -join "`n"
    }

    It 'never uses recursive Remove-Item, rd /s, del /s or format' {
        $Code | Should -Not -Match 'Remove-Item'
        $Code | Should -Not -Match '(?i)\brd\s+/s|\brmdir\s+/s|\bdel\s+/s'
        $Code | Should -Not -Match '(?i)Directory\]::Delete\([^)]*\$true'
    }

    It 'never passes /ResetBase to DISM' {
        $Code | Should -Not -Match "'/ResetBase'"
    }

    It 'does not flush DNS, touch services or edit the registry' {
        $Code | Should -Not -Match '(?i)flushdns|Stop-Service|Set-Service|sc\.exe|Set-ItemProperty|Remove-ItemProperty|New-ItemProperty|reg\s+(add|delete)'
    }

    It 'is saved as UTF-8 with BOM (required by Windows PowerShell 5.1)' {
        $bytes = [IO.File]::ReadAllBytes([IO.Path]::Combine($PSScriptRoot, '..', 'clean-win-temp-files.ps1'))
        $bytes[0..2] | Should -Be @(0xEF, 0xBB, 0xBF)
    }
}
