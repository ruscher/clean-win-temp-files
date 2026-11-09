#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
    Tests for system-health-check.ps1 (read-only diagnostics).

    Run:  Invoke-Pester -Path .\tests -Output Detailed
    Only the pure analysis functions are tested here; the collectors read the real event
    logs and sensors and are exercised end to end by tests/ci-validate.ps1.
#>

BeforeAll {
    $script:HealthScript = [IO.Path]::Combine($PSScriptRoot, '..', 'system-health-check.ps1')
    . $script:HealthScript
}

Describe 'Battery report parsing' {
    It 'reads the capacities and computes the health' {
        $xml = [xml]@'
<?xml version="1.0" encoding="utf-8"?>
<BatteryReport xmlns="http://schemas.microsoft.com/battery/2012">
  <Batteries>
    <Battery><Id>DELL FW8KR9C</Id><Manufacturer>BYD</Manufacturer><Chemistry>LION</Chemistry><DesignCapacity>41998</DesignCapacity><FullChargeCapacity>1345</FullChargeCapacity><CycleCount>0</CycleCount></Battery>
  </Batteries>
</BatteryReport>
'@
        $batteries = @(ConvertFrom-BatteryReportXml -Xml $xml)
        $batteries | Should -HaveCount 1
        $batteries[0].Name | Should -Be 'DELL FW8KR9C'
        $batteries[0].DesignCapacity | Should -Be 41998
        $batteries[0].FullChargeCapacity | Should -Be 1345
        $batteries[0].HealthPercent | Should -Be 3.2
    }

    It 'handles two batteries, a missing design capacity and no battery at all' {
        $xml = [xml]@'
<BatteryReport xmlns="http://schemas.microsoft.com/battery/2012">
  <Batteries>
    <Battery><Id>A</Id><DesignCapacity>50000</DesignCapacity><FullChargeCapacity>45000</FullChargeCapacity><CycleCount>120</CycleCount></Battery>
    <Battery><Id>B</Id><DesignCapacity></DesignCapacity><FullChargeCapacity>1000</FullChargeCapacity></Battery>
  </Batteries>
</BatteryReport>
'@
        $batteries = @(ConvertFrom-BatteryReportXml -Xml $xml)
        $batteries | Should -HaveCount 2
        $batteries[0].HealthPercent | Should -Be 90
        $batteries[0].CycleCount | Should -Be 120
        $batteries[1].HealthPercent | Should -BeNullOrEmpty

        $empty = [xml]'<BatteryReport xmlns="http://schemas.microsoft.com/battery/2012"><Batteries /></BatteryReport>'
        @(ConvertFrom-BatteryReportXml -Xml $empty) | Should -HaveCount 0
    }

    It 'classifies <Health>% as <Expected>' -ForEach @(
        @{ Health = 95; Expected = 'Ok' },
        @{ Health = 70; Expected = 'Ok' },
        @{ Health = 69.9; Expected = 'Warn' },
        @{ Health = 40; Expected = 'Warn' },
        @{ Health = 39.9; Expected = 'Critical' },
        @{ Health = 3.2; Expected = 'Critical' }
    ) {
        Get-BatteryHealthStatus $Health | Should -Be $Expected
    }

    It 'reports an unknown health as information' {
        Get-BatteryHealthStatus $null | Should -Be 'Info'
    }
}

Describe 'Sleep and hibernation reasons (Kernel-Power 42)' {
    It 'classifies code <Code> / "<Text>" as <Expected>' -ForEach @(
        @{ Code = '2'; Text = 'Battery'; Expected = 'Battery' },
        @{ Code = ''; Text = 'Bateria'; Expected = 'Battery' },
        @{ Code = '7'; Text = 'System Idle'; Expected = 'Idle' },
        @{ Code = '0'; Text = 'Button or Lid'; Expected = 'Lid' },
        @{ Code = '4'; Text = 'Application API'; Expected = 'App' },
        @{ Code = '6'; Text = 'Hibernate from Sleep - Fixed Timeout'; Expected = 'HibernateTimer' },
        @{ Code = '9'; Text = 'Thermal Zone'; Expected = 'Thermal' },
        @{ Code = '99'; Text = ''; Expected = 'Other' }
    ) {
        Get-SleepReasonKind -Code $Code -Text $Text | Should -Be $Expected
    }
}

Describe 'powercfg parsing' {
    It 'reads the current AC and DC values from localized output' {
        $lines = @(
            'GUID do Esquema de Energia: 381b4222-f694-41f0-9685-ff5bb260df2e  (Equilibrado)',
            '  GUID do Subgrupo: e73a048d-bf27-4f12-9731-8b2076e8891f  (Bateria)',
            '    GUID da Configuração de Energia: 637ea02f-bbcb-4015-8e2c-a1c7b9c0b546  (Ação de bateria crítica)',
            '      Índice de Configurações Possíveis: 000',
            '      Nome Amigável de Configuração Possível: Nada a fazer',
            '      Índice de Configurações Possíveis: 002',
            '      Nome Amigável de Configuração Possível: Hibernar',
            '    Índice de Configurações de Correntes Alternadas Atuais: 0x00000002',
            '    Índice de Configurações de Correntes Contínuas Atuais: 0x00000003'
        )
        $value = ConvertFrom-PowerCfgSetting -Lines $lines
        $value.Ac | Should -Be 2
        $value.Dc | Should -Be 3
    }

    It 'returns nothing when the setting does not exist' {
        ConvertFrom-PowerCfgSetting -Lines @('Invalid parameters -- try "/?" for help') | Should -BeNullOrEmpty
    }

    It 'keeps the error output of Windows tools out of the report (PCs without a battery)' {
        # powercfg prints "Unable to perform operation" on stderr when there is no battery.
        $result = Invoke-QuietTool -FilePath $env:ComSpec -Arguments @('/d', '/c', 'echo visible & echo hidden 1>&2 & exit /b 3')
        $result.ExitCode | Should -Be 3
        $result.Output | Should -Match 'visible'
        $result.Output | Should -Not -Match 'hidden'
        $result.TimedOut | Should -BeFalse
    }

    It 'kills a Windows tool that hangs instead of blocking the health check' {
        $ping = Join-Path $env:SystemRoot 'System32\PING.EXE'
        $timer = [Diagnostics.Stopwatch]::StartNew()
        $result = Invoke-QuietTool -FilePath $ping -Arguments @('-n', '30', '127.0.0.1') -TimeoutSeconds 2
        $timer.Stop()
        $result.TimedOut | Should -BeTrue
        $result.ExitCode | Should -Be -1
        $timer.Elapsed.TotalSeconds | Should -BeLessThan 10 -Because 'the 30-second ping must be killed after 2 seconds'
    }

    It 'reports a timeout when the tool exits but a child process keeps its output open' {
        # cmd exits at once; the background ping inherits the pipes and keeps them open.
        $marker = '127.0.0.3'
        try {
            $timer = [Diagnostics.Stopwatch]::StartNew()
            $result = Invoke-QuietTool -FilePath $env:ComSpec -Arguments @('/d', '/c', "start /b ping -n 20 $marker") -TimeoutSeconds 10 -StreamTimeoutSeconds 1
            $timer.Stop()
            $result.TimedOut | Should -BeTrue -Because 'the output may be incomplete'
            $result.ExitCode | Should -Be -1
            $result.Output | Should -BeNullOrEmpty
            $timer.Elapsed.TotalSeconds | Should -BeLessThan 8
        }
        finally {
            Get-CimInstance Win32_Process -Filter "Name = 'PING.EXE'" -ErrorAction SilentlyContinue |
                Where-Object { $_.CommandLine -like "*$marker*" } |
                ForEach-Object { [void](Invoke-CimMethod -InputObject $_ -MethodName Terminate) }
        }
    }
}

Describe 'Load test summary' {
    BeforeAll {
        function New-Sample([double]$Mhz, [double]$Limit = 100) { [pscustomobject]@{ Mhz = $Mhz; LimitPercent = $Limit } }
    }

    It 'sees no throttling when the sustained clock stays above the base clock' {
        $samples = @((New-Sample 3400), (New-Sample 3300), (New-Sample 2000 89), (New-Sample 2050 89), (New-Sample 2100 89), (New-Sample 2080 89))
        $summary = Get-LoadTestSummary -Samples $samples -BaseMhz 1800
        $summary.PeakMhz | Should -Be 3400
        [Math]::Round($summary.SustainedMhz) | Should -Be 2077
        $summary.MinLimitPercent | Should -Be 89
        $summary.Throttled | Should -BeFalse
    }

    It 'flags throttling when the sustained clock falls below the base clock' {
        $samples = @((New-Sample 2500), (New-Sample 1200 60), (New-Sample 1100 55), (New-Sample 1000 50))
        $summary = Get-LoadTestSummary -Samples $samples -BaseMhz 1800
        $summary.Throttled | Should -BeTrue
        $summary.SustainedPercent | Should -BeLessThan 95
    }

    It 'returns nothing without samples' {
        Get-LoadTestSummary -Samples @() -BaseMhz 1800 | Should -BeNullOrEmpty
    }
}

Describe 'Diagnosis' {
    It 'blames a worn-out battery that forces hibernation' {
        $diagnosis = Get-Diagnosis -Facts @{ BatterySleeps = 19; BatteryHealth = 3.2; LoadTestRan = $true; Throttled = $false }
        $diagnosis.Causes | Should -Contain 'Battery'
        $diagnosis.ThermalPaste | Should -Be 'Preventive'
    }

    It 'separates a healthy battery that simply ran out' {
        (Get-Diagnosis -Facts @{ BatterySleeps = 3; BatteryHealth = 90 }).Causes | Should -Be @('BatteryOk')
    }

    It 'blames overheating and asks for new thermal paste after a thermal shutdown' {
        $diagnosis = Get-Diagnosis -Facts @{ ThermalEvents = 2; PowerLossShutdowns = 2 }
        $diagnosis.Causes | Should -Contain 'Thermal'
        $diagnosis.Causes | Should -Not -Contain 'PowerLoss' -Because 'the power loss is explained by the thermal shutdown'
        $diagnosis.ThermalPaste | Should -Be 'Needed'
    }

    It 'asks for new thermal paste when the CPU throttles or runs too hot' {
        (Get-Diagnosis -Facts @{ LoadTestRan = $true; Throttled = $true }).ThermalPaste | Should -Be 'Needed'
        (Get-Diagnosis -Facts @{ MaxTemperature = 95 }).ThermalPaste | Should -Be 'Needed'
        (Get-Diagnosis -Facts @{ MaxTemperature = 60 }).ThermalPaste | Should -Be 'Preventive'
    }

    It 'reports blue screens and power loss' {
        $diagnosis = Get-Diagnosis -Facts @{ BlueScreens = 1; PowerLossShutdowns = 1; MaxTemperature = 55 }
        $diagnosis.Causes | Should -Contain 'BlueScreen'
        $diagnosis.Causes | Should -Contain 'PowerLoss'
    }

    It 'treats a Kernel-Power 41 with a stop code as a blue screen even without BugCheck 1001' {
        $diagnosis = Get-Diagnosis -Facts @{ UnexpectedShutdowns = 1; BugCheckShutdowns = 1 }
        $diagnosis.Causes | Should -Contain 'BlueScreen'
        $diagnosis.Causes | Should -Not -Contain 'Unexplained'
    }

    It 'never says "nothing found" after an unclean shutdown the logs cannot explain' {
        # Only EventLog 6008: no Kernel-Power 41 details, no blue screen, no thermal event.
        $diagnosis = Get-Diagnosis -Facts @{ UnexpectedShutdowns = 2 }
        $diagnosis.Causes | Should -Be @('Unexplained')

        $withBattery = Get-Diagnosis -Facts @{ UnexpectedShutdowns = 1; BatterySleeps = 4; BatteryHealth = 3 }
        $withBattery.Causes | Should -Contain 'Battery'
        $withBattery.Causes | Should -Contain 'Unexplained' -Because 'battery hibernations do not explain an unclean shutdown'

        (Get-Diagnosis -Facts @{ UnexpectedShutdowns = 1; PowerLossShutdowns = 1 }).Causes | Should -Not -Contain 'Unexplained'
    }

    It 'does not say "nothing found" when part of the event log could not be read' {
        (Get-Diagnosis -Facts @{ EventLogIncomplete = $true }).Causes | Should -Be @('Incomplete')
        $withCause = Get-Diagnosis -Facts @{ EventLogIncomplete = $true; BatterySleeps = 3; BatteryHealth = 3 }
        $withCause.Causes | Should -Be @('Battery') -Because 'a cause that was found is still reported; the warning is shown apart'
    }

    It 'finds nothing on a healthy PC and says the temperature was not measured' {
        $diagnosis = Get-Diagnosis -Facts @{}
        $diagnosis.Causes | Should -Be @('None')
        $diagnosis.ThermalPaste | Should -Be 'Unconfirmed'
    }
}

Describe 'Maintenance helpers' {
    It 'reads the Task Manager startup state (<Bytes> -> <Expected>)' -ForEach @(
        @{ Bytes = @(2, 0, 0, 0); Expected = $true },
        @{ Bytes = @(6, 0, 0, 0); Expected = $true },
        @{ Bytes = @(3, 0, 0, 0, 1, 2, 3, 4, 5, 6, 7, 8); Expected = $false },
        @{ Bytes = @(7, 0, 0, 0); Expected = $false }
    ) {
        Test-StartupApprovedEnabled ([byte[]]$Bytes) | Should -Be $Expected
    }

    It 'treats a program without a StartupApproved entry as enabled' {
        Test-StartupApprovedEnabled $null | Should -BeTrue
    }

    It 'reads Store startup task state <State> as enabled=<Expected>' -ForEach @(
        @{ State = 0; Expected = $false }, @{ State = 1; Expected = $false }, @{ State = 2; Expected = $true },
        @{ State = 3; Expected = $false }, @{ State = 4; Expected = $true }
    ) {
        Test-StartupTaskEnabled $State | Should -Be $Expected
    }

    It 'names Store packages <Package> as <Expected>' -ForEach @(
        @{ Package = '5319275A.WhatsAppDesktop_cv1g1gvanyjgm'; Expected = 'WhatsApp' },
        @{ Package = 'MSTeams_8wekyb3d8bbwe'; Expected = 'Microsoft Teams' },
        @{ Package = 'Microsoft.YourPhone_8wekyb3d8bbwe'; Expected = 'Phone Link' },
        @{ Package = '7EE7776C.LinkedInforWindows_w1wdnht996qgy'; Expected = 'LinkedInforWindows' },
        @{ Package = 'Microsoft.6365217CE6EB4_8wekyb3d8bbwe'; Expected = 'Microsoft Defender' },
        @{ Package = 'Contoso.Notes_abc123'; Expected = 'Contoso.Notes' }
    ) {
        ConvertTo-StartupTaskName $Package | Should -Be $Expected
    }

    It 'suggests only optional startup programs: <Name> -> <Expected>' -ForEach @(
        @{ Name = 'Adobe Acrobat Synchronizer'; Expected = $true },
        @{ Name = 'Microsoft.Lists'; Expected = $true },
        @{ Name = 'Phone Link'; Expected = $true },
        @{ Name = 'Intel Graphics Command Center'; Expected = $true },
        @{ Name = 'OneDrive'; Expected = $false },
        @{ Name = 'Dropbox'; Expected = $false },
        @{ Name = 'SecurityHealth'; Expected = $false },
        @{ Name = 'RtkAudUService'; Expected = $false },
        @{ Name = 'PJeOffice Pro'; Expected = $false },
        @{ Name = 'SACMonitor'; Expected = $false },
        @{ Name = 'Microsoft Teams'; Expected = $false }
    ) {
        Test-OptionalStartupItem $Name | Should -Be $Expected
    }

    It 'classifies Windows Update error <Code> as <Expected>' -ForEach @(
        @{ Code = '0x80073D02'; Expected = 'AppInUse' },
        @{ Code = '0x80240016'; Expected = 'Busy' },
        @{ Code = '0x80072EE2'; Expected = 'Network' },
        @{ Code = '0x8024402C'; Expected = 'Network' },
        @{ Code = '0x80070005'; Expected = 'Other' }
    ) {
        Get-WindowsUpdateErrorKind $Code | Should -Be $Expected
    }

    It 'lists the programs that start with Windows without failing' {
        $programs = @(Get-StartupProgram)
        foreach ($program in $programs) {
            $program.Name | Should -Not -BeNullOrEmpty
            $program.Enabled | Should -BeOfType [bool]
        }
        @($programs | Group-Object Name | Where-Object { $_.Count -gt 1 }).Count | Should -Be 0 -Because 'each program is listed once'
    }

    It 'runs the maintenance section and reports Windows Update, Storage Sense and antivirus' {
        $facts = @{ UptimeDays = 1.0; MemoryUsedPercent = 50.0 }
        $findings = @(Invoke-MaintenanceCheck -Since ([datetime]::Now.AddDays(-7)) -Facts $facts)
        $findings.Count | Should -BeGreaterThan 0
        foreach ($finding in $findings) { $finding.Area | Should -Be 'Maintenance' }
        @($findings | Where-Object { $_.Text -match 'Storage Sense' }).Count | Should -Be 1
        @($findings | Where-Object { $_.Text -match 'Defender|Antivirus' }).Count | Should -Be 1
    }
}

Describe 'Event log queries and the load test' {
    It 'treats "no events found" as empty and records real query failures' {
        $script:EventFailures.Clear()
        @(Get-EventSafe @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Kernel-Power'; Id = 65000 }) | Should -HaveCount 0
        $script:EventFailures.Count | Should -Be 0 -Because 'an empty result is not a failure'

        @(Get-EventSafe @{ LogName = 'CwtfNoSuchLog'; Id = 1 }) | Should -HaveCount 0
        $script:EventFailures.Count | Should -Be 1
        $script:EventFailures[0] | Should -Match 'CwtfNoSuchLog'
        $script:EventFailures.Clear()
    }

    It 'does not count a load test without CPU samples as a completed test' {
        # 1 second ends before the first sample is taken (sampling starts after 2 seconds).
        $facts = @{ MaxTemperature = $null; LoadTestRan = $false; Throttled = $false }
        $findings = @(Invoke-ThermalCheck -Since ([datetime]::Now.AddDays(-1)) -Facts $facts -LoadSeconds 1)
        $facts.LoadTestRan | Should -BeFalse
        $findings.Text | Should -Contain (Get-Text 'Load.NoSamples')
    }
}

Describe 'Text and source code guard rails' {
    BeforeAll {
        $script:Source = Get-Content -LiteralPath $script:HealthScript -Raw
        $script:Code = ($script:Source -split "`n" | Where-Object { $_ -notmatch '^\s*#' -and $_ -notmatch "^\s*'[A-Za-z.0-9]+'\s+=" }) -join "`n"
    }

    It 'has every UI string in both languages' {
        $english = @($script:Text['en'].Keys | Sort-Object)
        $portuguese = @($script:Text['pt'].Keys | Sort-Object)
        Compare-Object $english $portuguese | Should -BeNullOrEmpty
    }

    It 'only reads: no deletion, registry, service, power-plan or event-log changes' {
        $Code | Should -Not -Match 'Remove-Item|Set-ItemProperty|New-ItemProperty|Remove-ItemProperty|Stop-Process|Stop-Service|Set-Service|Clear-EventLog|wevtutil'
        $Code | Should -Not -Match '(?i)/(change|setacvalueindex|setdcvalueindex|setactive|hibernate|delete|import|duplicatescheme)\b'
        $Code | Should -Not -Match '(?i)Directory\]::Delete'
    }

    It 'is saved as UTF-8 with BOM (required by Windows PowerShell 5.1)' {
        $bytes = [IO.File]::ReadAllBytes($script:HealthScript)
        $bytes[0..2] | Should -Be @(0xEF, 0xBB, 0xBF)
    }
}
