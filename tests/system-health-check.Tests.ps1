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

    It 'finds nothing on a healthy PC and says the temperature was not measured' {
        $diagnosis = Get-Diagnosis -Facts @{}
        $diagnosis.Causes | Should -Be @('None')
        $diagnosis.ThermalPaste | Should -Be 'Unconfirmed'
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
