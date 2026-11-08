#Requires -Version 5.1
<#
.SYNOPSIS
    Read-only health check: why does this PC shut down, sleep or hibernate by itself?

.DESCRIPTION
    Reads the Windows event logs, the battery report, the temperature sensors that the
    firmware exposes to Windows, the CPU throttling counters and the disk health, then
    explains the most likely cause of sudden shutdowns and whether there is evidence of
    overheating (for example, to decide whether the thermal paste needs replacing).

    Nothing on the computer is changed. Checks:
      - unexpected shutdowns (Kernel-Power 41, EventLog 6008) and blue screens (BugCheck 1001)
      - shutdowns or hibernations caused by critical temperature (Kernel-Power 85-88)
      - why the PC went to sleep or hibernated (Kernel-Power 42), including critical battery
      - battery wear (powercfg /batteryreport) and the critical battery action
      - temperatures (ACPI thermal zones, when the firmware exposes them)
      - CPU limited by the firmware (Kernel-Processor-Power 37) and an optional load test
      - disk health, disk/NTFS errors, WHEA hardware errors, memory, uptime and BIOS age
      - maintenance: pending restart, Fast Startup, Windows Update failures, programs that
        start with Windows (optional ones are pointed out), Storage Sense and Defender status

.PARAMETER Days
    How many days of event log to analyze. Default: 30.

.PARAMETER LoadTest
    Seconds of full CPU load used to measure throttling (0 = no test, maximum 300).
    The notebook gets warm and the fan speeds up; that is the point of the test.

.PARAMETER ReportPath
    Folder for the report files. Default: %LOCALAPPDATA%\CleanWinTempFiles\Reports

.PARAMETER NoReport
    Do not write the .txt and .json report files.

.PARAMETER Language
    Interface language: Auto (default), en or pt.

.PARAMETER NoColor
    Disable colors (the NO_COLOR environment variable is also honored).

.PARAMETER PauseOnExit
    Wait for Enter before closing (the .bat launcher sets this on double-click).

.EXAMPLE
    .\system-health-check.ps1
    Analyzes the last 30 days and saves a report.

.EXAMPLE
    .\system-health-check.ps1 -LoadTest 60
    Also runs the CPU for 60 seconds at full load to detect thermal throttling.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Interactive, colored terminal report.')]
[CmdletBinding()]
param(
    [ValidateRange(1, 365)]
    [int]$Days = 30,

    [ValidateRange(0, 300)]
    [int]$LoadTest = 0,

    [string]$ReportPath,

    [switch]$NoReport,

    [ValidateSet('Auto', 'en', 'pt')]
    [string]$Language = 'Auto',

    [switch]$NoColor,

    [switch]$PauseOnExit
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#region Constants and text

$script:AppVersion = '2.1.0'
$script:ExitCode = 0
$script:Ui = $null
$script:Report = New-Object System.Collections.Generic.List[string]
$script:EventFailures = New-Object System.Collections.Generic.List[string]

# Battery health (full charge capacity / design capacity).
$script:BatteryWarnPercent = 70
$script:BatteryCriticalPercent = 40
# Temperatures in °C.
$script:TempWarnCelsius = 80
$script:TempCriticalCelsius = 90

$script:Text = @{
    en = @{
        'App'                    = 'System Health Check'
        'Header.Admin'           = 'Administrator'
        'Header.User'            = 'Standard user'
        'Header.ReadOnly'        = 'Read-only: nothing is changed on this computer. Last {0} days analyzed.'
        'Header.NotAdmin'        = 'Without administrator rights some temperatures and disk details may not be available.'
        'Section.System'         = 'SYSTEM'
        'Section.Shutdowns'      = 'SHUTDOWNS, SLEEP AND HIBERNATION'
        'Section.Power'          = 'BATTERY AND POWER'
        'Section.Thermal'        = 'TEMPERATURE AND PERFORMANCE'
        'Section.Hardware'       = 'DISKS AND HARDWARE'
        'Section.Maintenance'    = 'MAINTENANCE AND PERFORMANCE'
        'Sys.MemoryTop'          = '{0}: {1}'
        'Sys.MemorySmall.Advice' = 'With 8 GB, Teams, browsers and other apps open together fill the memory: close what you are not using, remove unneeded startup apps or, if the model allows it, add RAM.'
        'Maint.RestartUpdates'   = 'Windows is waiting for a restart to finish installing updates.'
        'Maint.RestartFiles'     = 'There are files waiting to be replaced at the next restart.'
        'Maint.Restart.Advice'   = 'Save your work and use Start > Power > Restart (not Shut down).'
        'Maint.FastStartup'      = 'Fast Startup is on: "Shut down" saves the Windows session instead of closing it, so only "Restart" really restarts Windows. Restart at least once a week.'
        'Maint.UpdatesOk'        = 'Windows Update: {0} update(s) installed, no failures.'
        'Maint.UpdatesFailed'    = 'Windows Update: {0} failed install(s) and {1} successful one(s).'
        'Maint.UpdateCode'       = '{0,4}x  {1} — {2}'
        'Maint.UpdateKind.AppInUse' = 'the app was open during its update (it retries; closing the app or restarting solves it)'
        'Maint.UpdateKind.Busy'  = 'another installation was in progress (a restart solves it)'
        'Maint.UpdateKind.Network' = 'could not reach the update server (check the internet connection)'
        'Maint.UpdateKind.Other' = 'other error'
        'Maint.Updates.Advice'   = 'Restart, then open Settings > Windows Update and click "Check for updates". If an error repeats, run Settings > System > Troubleshoot > Other troubleshooters > Windows Update.'
        'Maint.Startup'          = '{0} program(s) start with Windows; {1} of them are optional (marked with *).'
        'Maint.Startup.Advice'   = 'Turn off the optional ones you do not use every day in Settings > Apps > Startup: {0}. They still open normally when you click them.'
        'Maint.StorageSenseOn'   = 'Storage Sense is on.'
        'Maint.StorageSenseOff'  = 'Storage Sense is off.'
        'Maint.StorageSense.Advice' = 'Turn it on in Settings > System > Storage to remove temporary files automatically; set the Recycle Bin and Downloads options to "Never" if you prefer to decide yourself.'
        'Maint.DefenderOk'       = 'Microsoft Defender: real-time protection on, definitions {0} day(s) old.'
        'Maint.DefenderOld'      = 'Microsoft Defender definitions are {0} days old.'
        'Maint.DefenderOff'      = 'Microsoft Defender real-time protection is off.'
        'Maint.DefenderOff.Advice' = 'Turn it on in Windows Security > Virus & threat protection, unless another antivirus is installed.'
        'Maint.DefenderUnknown'  = 'Antivirus status unavailable (another antivirus may be installed).'
        'Bat.Bios.Advice'        = 'Replace the battery before updating the BIOS: manufacturers require a healthy battery during the update, and a power loss in the middle of it can leave the PC unable to start.'
        'Section.Verdict'        = 'DIAGNOSIS'
        'Sys.Model'              = '{0} {1} · BIOS {2} ({3})'
        'Sys.Cpu'                = '{0} · {1} cores / {2} threads'
        'Sys.Os'                 = '{0} · build {1}'
        'Sys.Uptime'             = 'On for {0:N1} days without a restart (since {1})'
        'Sys.Uptime.Advice'      = 'Restart now and then: with Fast Startup, "Shut down" does not really restart Windows.'
        'Sys.Memory'             = 'Memory: {0} free of {1} ({2:N0}% in use)'
        'Sys.Memory.Advice'      = 'Memory is almost full: close programs and browser tabs you are not using.'
        'Sys.Disk'               = 'Free space on drive {0} {1} of {2}'
        'Sys.Disk.Advice'        = 'Less than 10% free: run clean-win-temp-files.bat -Mode Deep.'
        'Sys.Bios.Advice'        = 'The BIOS is from {0}: check the manufacturer''s site for an update (fixes for battery, charging and fans).'
        'Shut.None'              = 'No unexpected shutdown recorded (Kernel-Power 41 / EventLog 6008).'
        'Shut.Found'             = '{0} unexpected shutdown(s): Windows did not shut down cleanly.'
        'Shut.PowerLoss'         = '{0}: power lost without a blue screen'
        'Shut.BugCheck'          = '{0}: blue screen, stop code 0x{1:X8}'
        'Shut.PowerLoss.Advice'  = 'Power lost without a blue screen means: power cut, battery/charger failure, overheating or the power button held down.'
        'Shut.BlueScreens'       = '{0} blue screen(s) recorded (BugCheck 1001).'
        'Shut.BlueScreen.Advice' = 'Update Windows and drivers; if it continues, test the RAM (Windows Memory Diagnostic).'
        'Thermal.None'           = 'No shutdown or hibernation caused by temperature (Kernel-Power 85-88).'
        'Thermal.Found'          = '{0} shutdown(s)/hibernation(s) caused by CRITICAL TEMPERATURE (last: {1}).'
        'Sleep.Summary'          = 'Went to sleep or hibernated {0} times. Reasons:'
        'Sleep.Row'              = '{0,6}x  {1}'
        'Sleep.Battery'          = '{0} hibernation(s) forced by CRITICAL BATTERY (last: {1}). To the user it looks like the PC turned off by itself.'
        'Sleep.BatteryOnAc'      = 'In the same period Windows saw the charger disconnect only {0} time(s): it happens even while plugged in.'
        'Sleep.Thermal'          = '{0} sleep/hibernation(s) triggered by a thermal zone (overheating).'
        'Reason.Battery'         = 'Critical battery'
        'Reason.Thermal'         = 'Temperature (thermal zone)'
        'Reason.Idle'            = 'Idle timeout'
        'Reason.Lid'             = 'Power button or lid'
        'Reason.App'             = 'Requested by a program or the Start menu'
        'Reason.HibernateTimer'  = 'Hibernation after sleep (timer)'
        'Bat.None'               = 'No battery found.'
        'Bat.Health'             = 'Battery {0} ({1}): holds {2} of the original {3} — {4:N0}% health'
        'Bat.Cycles'             = 'Charge cycles: {0}'
        'Bat.Dead.Advice'        = 'Replace the battery (original or compatible with this model). A worn-out battery cannot hold the voltage when the load spikes or the charger flickers, so Windows hibernates or the PC turns off.'
        'Bat.Worn.Advice'        = 'The battery is worn; plan a replacement.'
        'Bat.Charger.Advice'     = 'Also check the charger: original wattage, cable without kinks and a firm connector.'
        'Bat.Critical'           = 'Critical battery action: {0} at {1}%'
        'Bat.Ac'                 = 'Charger connected/disconnected {0} time(s)'
        'Action.0'               = 'do nothing'
        'Action.1'               = 'sleep'
        'Action.2'               = 'hibernate'
        'Action.3'               = 'shut down'
        'Temp.Reading'           = '{0}: {1:N0} °C'
        'Temp.Hot.Advice'        = 'Clean the fan and air vents; if it stays hot, replace the thermal paste.'
        'Temp.None'              = 'This computer does not expose temperature sensors to Windows (common on notebooks).'
        'Temp.None.Advice'       = 'To read CPU temperatures use HWiNFO or LibreHardwareMonitor, or the manufacturer''s diagnostics (Dell: F12 at power-on > Diagnostics).'
        'Cpu.Now'                = 'CPU now: about {0:N0} MHz ({1:N0}% of the {2:N0} MHz base clock), {3:N0}% busy'
        'Cpu.Limited'            = 'The firmware is limiting the CPU to {0:N0}% of its performance.'
        'Cpu.FirmwareEvents'     = 'Windows logged {0} time(s) that the firmware limited the CPU speed (Kernel-Processor-Power 37).'
        'Cpu.Limited.Advice'     = 'Firmware limits come from heat or from power: a worn battery or a weak/non-original charger also make notebooks slow the CPU down.'
        'Load.Running'           = 'Load test: {0} s at 100% on {1} threads'
        'Load.Result'            = 'Load test ({0} s): peak {1:N0} MHz · sustained {2:N0} MHz ({3:N0}% of base) · lowest firmware limit {4:N0}%'
        'Load.TempMax'           = 'Highest temperature during the test: {0:N0} °C'
        'Load.Ok'                = 'Under full load the CPU stays at or above its base clock: no sign of thermal throttling.'
        'Load.Throttled'         = 'Under full load the CPU drops below its base clock: thermal or power throttling.'
        'Load.Throttled.Advice'  = 'Clean the fan and vents and replace the thermal paste; if it persists, check the charger and battery.'
        'Load.Hint'              = 'Tip: run with -LoadTest 60 to measure throttling under full load.'
        'Load.NoSamples'         = 'The load test collected no CPU samples (too short?). Run it for at least 10 seconds.'
        'Disk.Row'               = '{0} ({1}, {2}): {3}'
        'Disk.Smart'             = '{0}: {1} °C · wear {2}% · uncorrected read errors {3}'
        'Disk.Bad.Advice'        = 'Back up your files now and replace this disk.'
        'Disk.Events'            = '{0} disk/file-system warning(s) or error(s) in the event log.'
        'Disk.NoEvents'          = 'No disk or file-system errors in the event log.'
        'Whea.None'              = 'No hardware errors reported by the processor/chipset (WHEA).'
        'Whea.Found'             = '{0} hardware error(s) reported by WHEA (last: {1}).'
        'Whea.Advice'            = 'Hardware errors can come from overheating, RAM or unstable power. Run the manufacturer''s hardware diagnostics.'
        'Rtc.Found'              = 'The firmware failed to read or set the clock {0} time(s) (HAL 20/21).'
        'Verdict.Battery'        = 'Most likely cause: the battery is worn out ({0:N0}% health) and Windows hibernates when it reports a critical state, even while plugged in. It looks like the PC turned off.'
        'Verdict.BatteryOk'      = 'Most likely cause: the battery reached the critical level and Windows hibernated the PC.'
        'Verdict.Thermal'        = 'Most likely cause: overheating. The PC shut down or hibernated because of critical temperature.'
        'Verdict.BlueScreen'     = 'Blue screens were recorded: check drivers, Windows updates and the RAM.'
        'Verdict.PowerLoss'      = 'The PC lost power without a blue screen: battery, charger, power outlet or the power button held down.'
        'Verdict.Unexplained'    = 'Windows did not shut down cleanly {0} time(s), but the logs do not say why (no power-loss or blue-screen record). Watch whether it happens again and run the manufacturer''s hardware diagnostics.'
        'Verdict.Incomplete'     = 'No cause was found, but part of the event log could not be read, so this result may be incomplete.'
        'Log.Failed'             = 'Part of the event log could not be read ({0} query(ies)); causes that depend on it may be missing.'
        'Verdict.None'           = 'No unexpected shutdown, forced hibernation or crash in the last {0} days.'
        'Paste.Needed'           = 'Thermal paste: there IS evidence of overheating. Clean the fan and vents and replace the thermal paste.'
        'Paste.Unconfirmed'      = 'Thermal paste: no sign of overheating in the logs, but the temperature could not be measured here. Run -LoadTest 60 or HWiNFO to confirm.'
        'Paste.Preventive'       = 'Thermal paste: no evidence of overheating. Replacing it is preventive maintenance (every 2-3 years), not the cause. If the notebook is opened (for example to replace the battery), clean the fan and replace the paste then.'
        'Report.Saved'           = 'Report: {0}'
        'Report.Failed'          = 'The report could not be written: {0}'
        'Error.NotWindows'       = 'This tool runs on Windows 10 and Windows 11 only.'
        'Error.Fatal'            = 'Unexpected error: {0}'
        'Pause'                  = 'Press Enter to close'
    }
    pt = @{
        'App'                    = 'Diagnóstico do Sistema'
        'Header.Admin'           = 'Administrador'
        'Header.User'            = 'Usuário padrão'
        'Header.ReadOnly'        = 'Somente leitura: nada é alterado no computador. Últimos {0} dias analisados.'
        'Header.NotAdmin'        = 'Sem privilégios de administrador algumas temperaturas e detalhes dos discos podem não aparecer.'
        'Section.System'         = 'SISTEMA'
        'Section.Shutdowns'      = 'DESLIGAMENTOS, SUSPENSÃO E HIBERNAÇÃO'
        'Section.Power'          = 'BATERIA E ENERGIA'
        'Section.Thermal'        = 'TEMPERATURA E DESEMPENHO'
        'Section.Hardware'       = 'DISCOS E HARDWARE'
        'Section.Maintenance'    = 'MANUTENÇÃO E DESEMPENHO'
        'Sys.MemoryTop'          = '{0}: {1}'
        'Sys.MemorySmall.Advice' = 'Com 8 GB, Teams, navegadores e outros apps abertos ao mesmo tempo enchem a memória: feche o que não estiver usando, tire da inicialização o que não precisa ou, se o modelo permitir, amplie a RAM.'
        'Maint.RestartUpdates'   = 'O Windows está esperando uma reinicialização para concluir atualizações.'
        'Maint.RestartFiles'     = 'Há arquivos esperando para ser substituídos na próxima reinicialização.'
        'Maint.Restart.Advice'   = 'Salve o que estiver fazendo e use Iniciar > Energia > Reiniciar (não Desligar).'
        'Maint.FastStartup'      = 'A Inicialização Rápida está ativa: "Desligar" guarda a sessão do Windows em vez de encerrá-la, então só "Reiniciar" reinicia o Windows de verdade. Reinicie pelo menos uma vez por semana.'
        'Maint.UpdatesOk'        = 'Windows Update: {0} atualização(ões) instalada(s), nenhuma falha.'
        'Maint.UpdatesFailed'    = 'Windows Update: {0} instalação(ões) com falha e {1} com sucesso.'
        'Maint.UpdateCode'       = '{0,4}x  {1} — {2}'
        'Maint.UpdateKind.AppInUse' = 'o app estava aberto durante a atualização (ela tenta de novo; fechar o app ou reiniciar resolve)'
        'Maint.UpdateKind.Busy'  = 'havia outra instalação em andamento (reiniciar resolve)'
        'Maint.UpdateKind.Network' = 'não conseguiu falar com o servidor de atualizações (verifique a internet)'
        'Maint.UpdateKind.Other' = 'outro erro'
        'Maint.Updates.Advice'   = 'Reinicie e depois abra Configurações > Windows Update > "Verificar se há atualizações". Se um erro se repetir, use Configurações > Sistema > Solução de problemas > Outros solucionadores > Windows Update.'
        'Maint.Startup'          = '{0} programa(s) abrem junto com o Windows; {1} deles são opcionais (marcados com *).'
        'Maint.Startup.Advice'   = 'Desative os opcionais que você não usa todo dia em Configurações > Aplicativos > Inicialização: {0}. Eles continuam abrindo normalmente quando você clica neles.'
        'Maint.StorageSenseOn'   = 'O Sensor de Armazenamento está ativo.'
        'Maint.StorageSenseOff'  = 'O Sensor de Armazenamento está desligado.'
        'Maint.StorageSense.Advice' = 'Ative em Configurações > Sistema > Armazenamento para apagar temporários automaticamente; deixe as opções da Lixeira e de Downloads em "Nunca" se preferir decidir por conta própria.'
        'Maint.DefenderOk'       = 'Microsoft Defender: proteção em tempo real ativa, definições de {0} dia(s).'
        'Maint.DefenderOld'      = 'As definições do Microsoft Defender têm {0} dias.'
        'Maint.DefenderOff'      = 'A proteção em tempo real do Microsoft Defender está desligada.'
        'Maint.DefenderOff.Advice' = 'Ative em Segurança do Windows > Proteção contra vírus e ameaças, a não ser que outro antivírus esteja instalado.'
        'Maint.DefenderUnknown'  = 'Estado do antivírus indisponível (outro antivírus pode estar instalado).'
        'Bat.Bios.Advice'        = 'Troque a bateria antes de atualizar a BIOS: os fabricantes exigem bateria em bom estado durante a atualização, e uma queda de energia no meio dela pode deixar o PC sem ligar.'
        'Section.Verdict'        = 'DIAGNÓSTICO'
        'Sys.Model'              = '{0} {1} · BIOS {2} ({3})'
        'Sys.Cpu'                = '{0} · {1} núcleos / {2} threads'
        'Sys.Os'                 = '{0} · build {1}'
        'Sys.Uptime'             = 'Ligado há {0:N1} dias sem reiniciar (desde {1})'
        'Sys.Uptime.Advice'      = 'Reinicie de vez em quando: com a Inicialização Rápida, "Desligar" não reinicia o Windows de verdade.'
        'Sys.Memory'             = 'Memória: {0} livres de {1} ({2:N0}% em uso)'
        'Sys.Memory.Advice'      = 'Memória quase cheia: feche programas e abas do navegador que não estiver usando.'
        'Sys.Disk'               = 'Espaço livre no disco {0} {1} de {2}'
        'Sys.Disk.Advice'        = 'Menos de 10% livre: execute clean-win-temp-files.bat -Mode Deep.'
        'Sys.Bios.Advice'        = 'A BIOS é de {0}: veja no site do fabricante se há atualização (correções de bateria, carregamento e ventoinha).'
        'Shut.None'              = 'Nenhum desligamento inesperado registrado (Kernel-Power 41 / EventLog 6008).'
        'Shut.Found'             = '{0} desligamento(s) inesperado(s): o Windows não foi desligado corretamente.'
        'Shut.PowerLoss'         = '{0}: perda de energia sem tela azul'
        'Shut.BugCheck'          = '{0}: tela azul, código 0x{1:X8}'
        'Shut.PowerLoss.Advice'  = 'Perda de energia sem tela azul indica: queda de energia, falha de bateria/carregador, superaquecimento ou botão liga/desliga segurado.'
        'Shut.BlueScreens'       = '{0} tela(s) azul(is) registrada(s) (BugCheck 1001).'
        'Shut.BlueScreen.Advice' = 'Atualize o Windows e os drivers; se continuar, teste a memória RAM (Diagnóstico de Memória do Windows).'
        'Thermal.None'           = 'Nenhum desligamento ou hibernação causado por temperatura (Kernel-Power 85-88).'
        'Thermal.Found'          = '{0} desligamento(s)/hibernação(ões) por TEMPERATURA CRÍTICA (último: {1}).'
        'Sleep.Summary'          = 'Entrou em suspensão ou hibernação {0} vezes. Motivos:'
        'Sleep.Row'              = '{0,6}x  {1}'
        'Sleep.Battery'          = '{0} hibernação(ões) forçada(s) por BATERIA CRÍTICA (última: {1}). Para quem usa, parece que o PC desligou sozinho.'
        'Sleep.BatteryOnAc'      = 'No mesmo período o Windows viu o carregador desconectar só {0} vez(es): acontece mesmo ligado na tomada.'
        'Sleep.Thermal'          = '{0} suspensão(ões)/hibernação(ões) causada(s) por zona térmica (superaquecimento).'
        'Reason.Battery'         = 'Bateria crítica'
        'Reason.Thermal'         = 'Temperatura (zona térmica)'
        'Reason.Idle'            = 'Tempo de inatividade'
        'Reason.Lid'             = 'Botão liga/desliga ou tampa'
        'Reason.App'             = 'Pedido de um programa ou do menu Iniciar'
        'Reason.HibernateTimer'  = 'Hibernação após suspensão (temporizador)'
        'Bat.None'               = 'Nenhuma bateria encontrada.'
        'Bat.Health'             = 'Bateria {0} ({1}): armazena {2} dos {3} originais — saúde de {4:N0}%'
        'Bat.Cycles'             = 'Ciclos de carga: {0}'
        'Bat.Dead.Advice'        = 'Troque a bateria (original ou compatível com este modelo). Uma bateria gasta não segura a tensão quando a carga sobe ou o carregador oscila, e o Windows hiberna ou o PC desliga.'
        'Bat.Worn.Advice'        = 'A bateria está desgastada; planeje a troca.'
        'Bat.Charger.Advice'     = 'Verifique também o carregador: potência original, cabo sem dobras e conector firme, sem mau contato.'
        'Bat.Critical'           = 'Ação de bateria crítica: {0} em {1}%'
        'Bat.Ac'                 = 'Carregador conectado/desconectado {0} vez(es)'
        'Action.0'               = 'nada a fazer'
        'Action.1'               = 'suspender'
        'Action.2'               = 'hibernar'
        'Action.3'               = 'desligar'
        'Temp.Reading'           = '{0}: {1:N0} °C'
        'Temp.Hot.Advice'        = 'Limpe a ventoinha e as saídas de ar; se continuar quente, troque a pasta térmica.'
        'Temp.None'              = 'Este computador não expõe sensores de temperatura ao Windows (comum em notebooks).'
        'Temp.None.Advice'       = 'Para ver a temperatura da CPU use o HWiNFO ou o LibreHardwareMonitor, ou o diagnóstico do fabricante (Dell: F12 ao ligar > Diagnostics).'
        'Cpu.Now'                = 'CPU agora: cerca de {0:N0} MHz ({1:N0}% da frequência base de {2:N0} MHz), {3:N0}% de uso'
        'Cpu.Limited'            = 'O firmware está limitando a CPU a {0:N0}% do desempenho.'
        'Cpu.FirmwareEvents'     = 'O Windows registrou {0} vez(es) que o firmware limitou a velocidade da CPU (Kernel-Processor-Power 37).'
        'Cpu.Limited.Advice'     = 'O firmware limita a CPU por calor ou por energia: bateria gasta ou carregador fraco/não original também fazem o notebook reduzir a CPU.'
        'Load.Running'           = 'Teste de carga: {0} s a 100% em {1} threads'
        'Load.Result'            = 'Teste de carga ({0} s): pico {1:N0} MHz · sustentado {2:N0} MHz ({3:N0}% da base) · menor limite do firmware {4:N0}%'
        'Load.TempMax'           = 'Maior temperatura durante o teste: {0:N0} °C'
        'Load.Ok'                = 'Sob carga total a CPU fica na frequência base ou acima: sem sinal de estrangulamento térmico.'
        'Load.Throttled'         = 'Sob carga total a CPU cai abaixo da frequência base: estrangulamento térmico ou de energia.'
        'Load.Throttled.Advice'  = 'Limpe a ventoinha e as saídas de ar e troque a pasta térmica; se continuar, verifique carregador e bateria.'
        'Load.Hint'              = 'Dica: use -LoadTest 60 para medir o estrangulamento sob carga total.'
        'Load.NoSamples'         = 'O teste de carga não coletou amostras da CPU (curto demais?). Rode por pelo menos 10 segundos.'
        'Disk.Row'               = '{0} ({1}, {2}): {3}'
        'Disk.Smart'             = '{0}: {1} °C · desgaste {2}% · erros de leitura não corrigidos {3}'
        'Disk.Bad.Advice'        = 'Faça backup dos seus arquivos agora e troque este disco.'
        'Disk.Events'            = '{0} aviso(s) ou erro(s) de disco/sistema de arquivos no log de eventos.'
        'Disk.NoEvents'          = 'Nenhum erro de disco ou de sistema de arquivos no log de eventos.'
        'Whea.None'              = 'Nenhum erro de hardware informado pelo processador/chipset (WHEA).'
        'Whea.Found'             = '{0} erro(s) de hardware informado(s) pelo WHEA (último: {1}).'
        'Whea.Advice'            = 'Erros de hardware podem vir de superaquecimento, memória RAM ou energia instável. Rode o diagnóstico de hardware do fabricante.'
        'Rtc.Found'              = 'O firmware falhou ao ler ou acertar o relógio {0} vez(es) (HAL 20/21).'
        'Verdict.Battery'        = 'Causa mais provável: a bateria está gasta ({0:N0}% de saúde) e o Windows hiberna quando ela informa estado crítico, mesmo ligado na tomada. Parece que o PC desligou.'
        'Verdict.BatteryOk'      = 'Causa mais provável: a bateria chegou ao nível crítico e o Windows hibernou o PC.'
        'Verdict.Thermal'        = 'Causa mais provável: superaquecimento. O PC desligou ou hibernou por temperatura crítica.'
        'Verdict.BlueScreen'     = 'Houve telas azuis: verifique drivers, atualizações do Windows e a memória RAM.'
        'Verdict.PowerLoss'      = 'O PC perdeu energia sem tela azul: bateria, carregador, tomada ou botão liga/desliga segurado.'
        'Verdict.Unexplained'    = 'O Windows não foi desligado corretamente {0} vez(es), mas os logs não dizem por quê (sem registro de perda de energia nem de tela azul). Observe se volta a acontecer e rode o diagnóstico de hardware do fabricante.'
        'Verdict.Incomplete'     = 'Nenhuma causa foi encontrada, mas parte do log de eventos não pôde ser lida; o resultado pode estar incompleto.'
        'Log.Failed'             = 'Parte do log de eventos não pôde ser lida ({0} consulta(s)); causas que dependem dele podem não aparecer.'
        'Verdict.None'           = 'Nenhum desligamento inesperado, hibernação forçada ou travamento nos últimos {0} dias.'
        'Paste.Needed'           = 'Pasta térmica: HÁ sinais de superaquecimento. Limpe a ventoinha e as saídas de ar e troque a pasta térmica.'
        'Paste.Unconfirmed'      = 'Pasta térmica: nenhum sinal de superaquecimento nos logs, mas a temperatura não pôde ser medida aqui. Rode com -LoadTest 60 ou use o HWiNFO para confirmar.'
        'Paste.Preventive'       = 'Pasta térmica: nenhum sinal de superaquecimento. A troca é manutenção preventiva (a cada 2-3 anos), não a causa. Se o notebook for aberto (por exemplo, para trocar a bateria), aproveite para limpar a ventoinha e trocar a pasta.'
        'Report.Saved'           = 'Relatório: {0}'
        'Report.Failed'          = 'Não foi possível gravar o relatório: {0}'
        'Error.NotWindows'       = 'Esta ferramenta funciona apenas no Windows 10 e no Windows 11.'
        'Error.Fatal'            = 'Erro inesperado: {0}'
        'Pause'                  = 'Pressione Enter para fechar'
    }
}

function Get-Text {
    param([Parameter(Mandatory = $true)][string]$Key, [object[]]$Arguments = @())
    $language = 'en'
    if ($script:Ui) { $language = $script:Ui.Language }
    $template = $script:Text[$language][$Key]
    if ($null -eq $template) { $template = $script:Text['en'][$Key] }
    if ($null -eq $template) { $template = $Key }
    if ($Arguments.Count -eq 0) { return $template }
    return [string]::Format([Globalization.CultureInfo]::CurrentCulture, $template, $Arguments)
}

#endregion

#region Output

function Initialize-Ui {
    param([switch]$NoColor, [string]$Language = 'Auto')

    $selected = $Language
    if ($selected -eq 'Auto') {
        $selected = 'en'
        try { if ((Get-UICulture).TwoLetterISOLanguageName -eq 'pt') { $selected = 'pt' } } catch { $selected = 'en' }
    }
    $utf8Console = $false
    try { $utf8Console = [Console]::OutputEncoding.CodePage -eq 65001 } catch { $utf8Console = $false }
    $unicode = [bool]$env:WT_SESSION -or [bool]$env:TERM_PROGRAM -or $utf8Console

    $script:Ui = [pscustomobject]@{
        Color    = (-not $NoColor) -and (-not $env:NO_COLOR)
        Unicode  = $unicode
        Language = $selected
    }
}

function ConvertTo-ConsoleText {
    param([string]$Text)
    if ($null -eq $script:Ui -or $script:Ui.Unicode) { return $Text }
    return $Text.Replace('—', '-').Replace('·', '|').Replace('…', '...').Replace('→', '->')
}

function Write-Line {
    # Writes to the console and to the report buffer.
    param([string]$Text = '', [ConsoleColor]$Color = [ConsoleColor]::Gray)
    $script:Report.Add($Text)
    $value = ConvertTo-ConsoleText $Text
    if ($script:Ui -and $script:Ui.Color) { Write-Host $value -ForegroundColor $Color }
    else { Write-Host $value }
}

function Get-StatusStyle {
    param([string]$Status)
    switch ($Status) {
        'Critical' { return @('[X]', [ConsoleColor]::Red) }
        'Warn' { return @('[!]', [ConsoleColor]::Yellow) }
        'Ok' { return @('[OK]', [ConsoleColor]::Green) }
        default { return @('[i]', [ConsoleColor]::Gray) }
    }
}

function New-Finding {
    param(
        [string]$Area,
        [ValidateSet('Ok', 'Info', 'Warn', 'Critical')][string]$Status,
        [string]$Text,
        [string[]]$Details = @(),
        [string[]]$Advice = @()
    )
    return [pscustomobject]@{ Area = $Area; Status = $Status; Text = $Text; Details = @($Details); Advice = @($Advice) }
}

function Write-Finding {
    param($Finding)
    $style = Get-StatusStyle $Finding.Status
    Write-Line ('  {0,-4} {1}' -f $style[0], $Finding.Text) $style[1]
    foreach ($detail in $Finding.Details) { Write-Line ('         ' + $detail) DarkGray }
    foreach ($advice in $Finding.Advice) { Write-Line ('         → ' + $advice) Cyan }
}

function Write-Section {
    param([string]$Title)
    Write-Line ''
    Write-Line ('  ' + $Title) White
}

function Format-ByteSize {
    param([double]$Bytes)
    $culture = [Globalization.CultureInfo]::CurrentCulture
    if ($Bytes -ge 1TB) { return [string]::Format($culture, '{0:N2} TB', $Bytes / 1TB) }
    if ($Bytes -ge 1GB) { return [string]::Format($culture, '{0:N1} GB', $Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return [string]::Format($culture, '{0:N0} MB', $Bytes / 1MB) }
    return [string]::Format($culture, '{0:N0} KB', $Bytes / 1KB)
}

function Format-EnergyWh {
    param([double]$MilliwattHours)
    return [string]::Format([Globalization.CultureInfo]::CurrentCulture, '{0:N1} Wh', $MilliwattHours / 1000)
}

function Format-Time {
    param([datetime]$Time)
    return $Time.ToString('g', [Globalization.CultureInfo]::CurrentCulture)
}

#endregion

#region Pure analysis (unit tested)

function ConvertFrom-BatteryReportXml {
    # Parses the XML written by "powercfg /batteryreport /xml". Capacities are in mWh.
    param([Parameter(Mandatory = $true)][xml]$Xml)

    $batteries = New-Object System.Collections.Generic.List[object]
    $root = $Xml.DocumentElement
    $node = $root.SelectSingleNode("*[local-name()='Batteries']")
    if ($node) {
        foreach ($battery in $node.SelectNodes("*[local-name()='Battery']")) {
            $value = { param($Name) $child = $battery.SelectSingleNode("*[local-name()='$Name']"); if ($child) { $child.InnerText.Trim() } else { '' } }
            $design = 0L; $full = 0L; $cycles = 0
            [void][long]::TryParse((& $value 'DesignCapacity'), [ref]$design)
            [void][long]::TryParse((& $value 'FullChargeCapacity'), [ref]$full)
            [void][int]::TryParse((& $value 'CycleCount'), [ref]$cycles)
            $health = $null
            if ($design -gt 0) { $health = [Math]::Round(100.0 * $full / $design, 1) }
            $batteries.Add([pscustomobject]@{
                    Name               = & $value 'Id'
                    Manufacturer       = & $value 'Manufacturer'
                    Chemistry          = & $value 'Chemistry'
                    DesignCapacity     = $design
                    FullChargeCapacity = $full
                    CycleCount         = $cycles
                    HealthPercent      = $health
                })
        }
    }
    return $batteries.ToArray()
}

function Get-BatteryHealthStatus {
    param([AllowNull()][object]$HealthPercent)
    if ($null -eq $HealthPercent) { return 'Info' }
    if ($HealthPercent -lt $script:BatteryCriticalPercent) { return 'Critical' }
    if ($HealthPercent -lt $script:BatteryWarnPercent) { return 'Warn' }
    return 'Ok'
}

function Get-SleepReasonKind {
    <#
        Classifies a Kernel-Power 42 event. The numeric Reason values observed on Windows 10/11:
        0 button or lid, 2 critical battery, 4 application API, 6 hibernate after sleep,
        7 system idle. The reason text comes from the provider and is matched as a fallback.
    #>
    param([string]$Code, [string]$Text)
    if ($Text -match '(?i)thermal|t[ée]rmic') { return 'Thermal' }
    if ($Code -eq '2' -or $Text -match '(?i)battery|bateria') { return 'Battery' }
    if ($Code -eq '7' -or $Text -match '(?i)idle|inativ') { return 'Idle' }
    if ($Code -eq '0' -or $Text -match '(?i)button|lid|bot[ãa]o|tampa') { return 'Lid' }
    if ($Code -eq '6' -or $Text -match '(?i)hibernate from sleep|fixed timeout') { return 'HibernateTimer' }
    if ($Code -eq '4' -or $Text -match '(?i)application api') { return 'App' }
    return 'Other'
}

function ConvertFrom-PowerCfgSetting {
    # "powercfg /q" prints the current AC and DC values as the last two 0x######## numbers.
    param([string[]]$Lines)
    $values = @([regex]::Matches(($Lines -join "`n"), '0x([0-9A-Fa-f]{8})') | ForEach-Object { [Convert]::ToInt32($_.Groups[1].Value, 16) })
    if ($values.Count -lt 2) { return $null }
    return [pscustomobject]@{ Ac = $values[-2]; Dc = $values[-1] }
}

function Get-LoadTestSummary {
    # Samples: objects with Mhz, PerformancePercent (actual / base * 100) and LimitPercent.
    param([object[]]$Samples, [double]$BaseMhz)

    $valid = @($Samples | Where-Object { $_ -and $_.Mhz -gt 0 })
    if ($valid.Count -eq 0) { return $null }
    $peak = ($valid | Measure-Object -Property Mhz -Maximum).Maximum
    $tail = @($valid | Select-Object -Last ([Math]::Max(1, [int][Math]::Ceiling($valid.Count / 2))))
    $sustained = ($tail | Measure-Object -Property Mhz -Average).Average
    $limit = ($valid | Measure-Object -Property LimitPercent -Minimum).Minimum
    $percent = 0
    if ($BaseMhz -gt 0) { $percent = 100.0 * $sustained / $BaseMhz }
    return [pscustomobject]@{
        PeakMhz          = [double]$peak
        SustainedMhz     = [double]$sustained
        SustainedPercent = [double]$percent
        MinLimitPercent  = [double]$limit
        # 5% tolerance: sampling is coarse and turbo is not guaranteed on all cores.
        Throttled        = ($BaseMhz -gt 0 -and $percent -lt 95)
    }
}

function Get-Diagnosis {
    <#
        Turns the collected facts into the likely causes and a thermal-paste verdict.
        Facts: UnexpectedShutdowns, PowerLossShutdowns, BugCheckShutdowns, BlueScreens,
        ThermalEvents, BatterySleeps, ThermalSleeps, BatteryHealth, MaxTemperature,
        LoadTestRan, Throttled.
    #>
    param([Parameter(Mandatory = $true)][hashtable]$Facts)

    $get = { param($Name, $Default) if ($Facts.ContainsKey($Name) -and $null -ne $Facts[$Name]) { $Facts[$Name] } else { $Default } }
    $thermalEvents = [int](& $get 'ThermalEvents' 0) + [int](& $get 'ThermalSleeps' 0)
    $batterySleeps = [int](& $get 'BatterySleeps' 0)
    # A Kernel-Power 41 with a stop code is a blue screen even when no BugCheck 1001 was written.
    $blueScreens = [int](& $get 'BlueScreens' 0) + [int](& $get 'BugCheckShutdowns' 0)
    $powerLoss = [int](& $get 'PowerLossShutdowns' 0)
    $unexpected = [int](& $get 'UnexpectedShutdowns' 0)
    $logIncomplete = [bool](& $get 'EventLogIncomplete' $false)
    $health = & $get 'BatteryHealth' $null
    $maxTemp = & $get 'MaxTemperature' $null
    $throttled = [bool](& $get 'Throttled' $false)
    $loadTestRan = [bool](& $get 'LoadTestRan' $false)

    $causes = New-Object System.Collections.Generic.List[string]
    if ($thermalEvents -gt 0) { $causes.Add('Thermal') }
    if ($batterySleeps -gt 0) {
        if ($null -ne $health -and $health -lt $script:BatteryCriticalPercent) { $causes.Add('Battery') } else { $causes.Add('BatteryOk') }
    }
    if ($blueScreens -gt 0) { $causes.Add('BlueScreen') }
    if ($powerLoss -gt 0 -and $thermalEvents -eq 0) { $causes.Add('PowerLoss') }
    # Unclean shutdowns the logs cannot explain (for example only EventLog 6008): never say "none".
    if ($unexpected -gt 0 -and -not ($causes.Contains('Thermal') -or $causes.Contains('BlueScreen') -or $causes.Contains('PowerLoss'))) {
        $causes.Add('Unexplained')
    }
    # Nothing found is only "none" when the event log could actually be read.
    if ($causes.Count -eq 0) { $causes.Add($(if ($logIncomplete) { 'Incomplete' } else { 'None' })) }

    $paste = 'Preventive'
    if ($thermalEvents -gt 0 -or $throttled -or ($null -ne $maxTemp -and $maxTemp -ge $script:TempCriticalCelsius)) { $paste = 'Needed' }
    elseif ($null -eq $maxTemp -and -not $loadTestRan) { $paste = 'Unconfirmed' }

    return [pscustomobject]@{ Causes = $causes.ToArray(); ThermalPaste = $paste }
}

function Test-StartupApprovedEnabled {
    # Explorer\StartupApproved values: the first byte is even (02, 06) when the entry is
    # enabled and odd (03, 07) when the user disabled it in Task Manager or Settings.
    param([AllowNull()][object]$Value)
    $bytes = @($Value)
    if ($bytes.Count -eq 0 -or $null -eq $bytes[0]) { return $true }
    return ([int]$bytes[0] % 2) -eq 0
}

function Test-StartupTaskEnabled {
    # Store app startup tasks: 2 = enabled, 4 = enabled by policy; 0, 1, 3 = disabled.
    param([AllowNull()][object]$State)
    return @(2, 4) -contains [int]$State
}

function ConvertTo-StartupTaskName {
    # Friendly name for a Store package family (5319275A.WhatsAppDesktop_cv1g... -> WhatsApp).
    param([string]$PackageFamily)
    $known = [ordered]@{
        'MSTeams'                 = 'Microsoft Teams'
        'WhatsAppDesktop'         = 'WhatsApp'
        'YourPhone'               = 'Phone Link'
        'CrossDevice'             = 'Phone Link (CrossDevice)'
        'IntelGraphicsExperience' = 'Intel Graphics Command Center'
        'SpotifyMusic'            = 'Spotify'
        'GamingApp'               = 'Xbox'
        'MicrosoftOfficeHub'      = 'Microsoft 365 (Office)'
        'WindowsTerminal'         = 'Windows Terminal'
    }
    $name = ($PackageFamily -split '_')[0]
    foreach ($key in $known.Keys) { if ($name -like "*$key*") { return $known[$key] } }
    $parts = $name -split '\.'
    if ($parts.Count -gt 1 -and $parts[0] -match '^[0-9A-F]{6,}$') { return ($parts | Select-Object -Skip 1) -join '.' }
    return $name
}

function Test-OptionalStartupItem {
    <#
        Apps that are commonly started with Windows but are not needed for the PC to work and
        open quickly on demand. Sync clients, security, audio, drivers and digital-certificate
        tools are never suggested.
    #>
    param([string]$Name)
    $keep = 'OneDrive|Dropbox|GoogleDrive|Google Drive|SecurityHealth|Defender|Realtek|RtkAud|Waves|Synaptics|ELAN|Intel.*(Audio|Bluetooth)|PJe|SafeNet|SACMonitor|Certificate|aetcrss|Token'
    $optional = 'Acrobat Synchronizer|AdobeCollabSync|AdobeARM|Microsoft\.Lists|Phone Link|YourPhone|CrossDevice|Intel Graphics|Spotify|Steam|Discord|Skype|EpicGames|CCleaner|LinkedIn|Xbox|MicrosoftEdgeAutoLaunch|iTunesHelper|Zoom|Cortana|Opera Browser Assistant'
    if ($Name -match $keep) { return $false }
    return $Name -match $optional
}

function Get-WindowsUpdateErrorKind {
    # Groups Windows Update install errors (event 20) by what the user can do about them.
    param([string]$Code)
    switch -Regex ($Code) {
        '(?i)^0x80073D02$' { return 'AppInUse' }                       # the app was running during its update
        '(?i)^0x(80240016|8024001E)$' { return 'Busy' }                # another install in progress / shutting down
        '(?i)^0x(80072EE2|80072EE7|80072EFD|80072EFE|8024402C|80244022|8024401C|80240438)$' { return 'Network' }
        default { return 'Other' }
    }
}

#endregion

#region Collectors (read-only)

function Test-IsAdministrator {
    try {
        $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    catch { return $false }
}

function Get-EventSafe {
    <#
        Get-WinEvent reports "no events found" as an error; here it is just an empty result.
        Any other failure (missing log, access denied, event log service unavailable) is
        recorded in $script:EventFailures, so the diagnosis never presents missing data as
        "nothing happened".
    #>
    param([hashtable]$Filter)
    try { return @(Get-WinEvent -FilterHashtable $Filter -ErrorAction Stop) }
    catch {
        if ([string]$_.FullyQualifiedErrorId -notlike 'NoMatchingEventsFound*') {
            $source = ('{0} {1}' -f $Filter['LogName'], (@($Filter['ProviderName']) -join ',')).Trim()
            $script:EventFailures.Add(('{0}: {1}' -f $source, $_.Exception.Message))
        }
        return @()
    }
}

function Get-EventDataMap {
    param($Event)
    $map = @{}
    try {
        $xml = [xml]$Event.ToXml()
        foreach ($data in @($xml.Event.EventData.Data)) {
            if ($data -and $data.Name) { $map[$data.Name] = [string]$data.'#text' }
        }
    }
    catch { Write-Verbose "Event data unavailable: $($_.Exception.Message)" }
    return $map
}

function Get-CimSafe {
    param([string]$ClassName, [string]$Namespace = 'root/cimv2', [string]$Filter)
    try {
        $arguments = @{ ClassName = $ClassName; Namespace = $Namespace; ErrorAction = 'Stop' }
        if ($Filter) { $arguments.Filter = $Filter }
        return @(Get-CimInstance @arguments)
    }
    catch { return @() }
}

function Invoke-QuietTool {
    <#
        Runs a Windows tool and returns its exit code and standard output. The error output is
        captured and discarded: powercfg prints "Unable to perform operation" on PCs without a
        battery, which must not leak into the report, and Windows PowerShell 5.1 turns a
        redirected native error stream into a terminating error under ErrorAction Stop.
        A tool that hangs (for example a faulty battery driver) is killed after the timeout and
        reported with TimedOut and exit code -1, so the health check never blocks. The same
        result is returned when the tool exits but its output does not finish in time (a child
        process still holding the pipes): that output may be incomplete.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$Arguments = @(),
        [int]$TimeoutSeconds = 60,
        [int]$StreamTimeoutSeconds = 5
    )

    $quoted = foreach ($argument in $Arguments) {
        if ($argument -match '[\s"]') { '"' + $argument.Replace('"', '\"') + '"' } else { $argument }
    }
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $FilePath
    $info.Arguments = @($quoted) -join ' '
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true

    $process = [Diagnostics.Process]::Start($info)
    try {
        # Both streams are read in the background (no pipe deadlock) and every wait is bounded.
        $output = $process.StandardOutput.ReadToEndAsync()
        $errors = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            try { $process.Kill() } catch { Write-Verbose "Could not stop $FilePath" }
            # Never wait on the read tasks here: a child process may still hold the pipes open.
            return [pscustomobject]@{ ExitCode = -1; Output = ''; TimedOut = $true }
        }
        $streamWait = $StreamTimeoutSeconds * 1000
        if (-not ($output.Wait($streamWait) -and $errors.Wait($streamWait))) {
            return [pscustomobject]@{ ExitCode = -1; Output = ''; TimedOut = $true }
        }
        return [pscustomobject]@{ ExitCode = $process.ExitCode; Output = $output.Result; TimedOut = $false }
    }
    finally { $process.Dispose() }
}

function Get-BatteryReport {
    $file = Join-Path ([IO.Path]::GetTempPath()) ('cwtf-battery-{0}.xml' -f [guid]::NewGuid().ToString('N'))
    try {
        $powercfg = Join-Path $env:SystemRoot 'System32\powercfg.exe'
        $run = Invoke-QuietTool -FilePath $powercfg -Arguments @('/batteryreport', '/xml', '/output', $file, '/duration', '1')
        # A failed or killed run leaves no report (or a partial one): treat it as no battery data.
        if ($run.ExitCode -ne 0 -or -not [IO.File]::Exists($file)) { return @() }
        return ConvertFrom-BatteryReportXml -Xml ([xml][IO.File]::ReadAllText($file))
    }
    catch { return @() }
    finally {
        try { if ([IO.File]::Exists($file)) { [IO.File]::Delete($file) } } catch { Write-Verbose 'Temporary battery report kept' }
    }
}

function Get-CriticalBatteryPolicy {
    $powercfg = Join-Path $env:SystemRoot 'System32\powercfg.exe'
    try {
        $action = Invoke-QuietTool -FilePath $powercfg -Arguments @('/q', 'SCHEME_CURRENT', 'SUB_BATTERY', 'BATACTIONCRIT')
        $level = Invoke-QuietTool -FilePath $powercfg -Arguments @('/q', 'SCHEME_CURRENT', 'SUB_BATTERY', 'BATLEVELCRIT')
        if ($action.ExitCode -ne 0 -or $level.ExitCode -ne 0) { return $null }
        $actionValue = ConvertFrom-PowerCfgSetting -Lines @($action.Output -split "`r?`n")
        $levelValue = ConvertFrom-PowerCfgSetting -Lines @($level.Output -split "`r?`n")
        if (-not $actionValue -or -not $levelValue) { return $null }
        return [pscustomobject]@{ ActionDc = $actionValue.Dc; LevelDc = $levelValue.Dc }
    }
    catch { return $null }
}

function Get-ThermalReading {
    # ACPI thermal zones (usually needs administrator), then the performance counters.
    $readings = New-Object System.Collections.Generic.List[object]
    foreach ($zone in (Get-CimSafe -Namespace 'root/wmi' -ClassName 'MSAcpi_ThermalZoneTemperature')) {
        $celsius = [Math]::Round($zone.CurrentTemperature / 10.0 - 273.15, 1)
        if ($celsius -gt 0 -and $celsius -lt 130) { $readings.Add([pscustomobject]@{ Name = [string]$zone.InstanceName; Celsius = $celsius }) }
    }
    if ($readings.Count -eq 0) {
        foreach ($zone in (Get-CimSafe -ClassName 'Win32_PerfFormattedData_Counters_ThermalZoneInformation')) {
            $tenths = [double]$zone.HighPrecisionTemperature
            if ($tenths -le 0) { $tenths = [double]$zone.Temperature * 10 }
            $celsius = [Math]::Round($tenths / 10.0 - 273.15, 1)
            if ($celsius -gt 0 -and $celsius -lt 130) { $readings.Add([pscustomobject]@{ Name = [string]$zone.Name; Celsius = $celsius }) }
        }
    }
    return $readings.ToArray()
}

function Get-CpuSample {
    $counter = Get-CimSafe -ClassName 'Win32_PerfFormattedData_Counters_ProcessorInformation' -Filter "Name='_Total'" | Select-Object -First 1
    if (-not $counter) { return $null }
    $base = [double]$counter.ProcessorFrequency
    $performance = [double]$counter.PercentProcessorPerformance
    return [pscustomobject]@{
        BaseMhz            = $base
        PerformancePercent = $performance
        Mhz                = $base * $performance / 100.0
        LimitPercent       = [double]$counter.PercentPerformanceLimit
        BusyPercent        = [double]$counter.PercentProcessorTime
    }
}

function Invoke-CpuLoadTest {
    # Keeps every logical processor busy for $Seconds and samples clock, limit and temperature.
    param([int]$Seconds)

    $threads = [Environment]::ProcessorCount
    $samples = New-Object System.Collections.Generic.List[object]
    $maxTemp = $null
    $pool = [runspacefactory]::CreateRunspacePool(1, $threads)
    $pool.Open()
    $workers = New-Object System.Collections.Generic.List[object]
    try {
        $end = [datetime]::UtcNow.AddSeconds($Seconds)
        $burn = {
            param([datetime]$Until)
            $x = 0.0
            while ([datetime]::UtcNow -lt $Until) { for ($i = 0; $i -lt 50000; $i++) { $x = [Math]::Sqrt($x + $i) } }
        }
        for ($i = 0; $i -lt $threads; $i++) {
            $shell = [powershell]::Create()
            $shell.RunspacePool = $pool
            [void]$shell.AddScript($burn).AddArgument($end)
            $workers.Add([pscustomobject]@{ Shell = $shell; Handle = $shell.BeginInvoke() })
        }
        Start-Sleep -Seconds 2   # let the load ramp up before sampling
        while ([datetime]::UtcNow -lt $end) {
            $sample = Get-CpuSample
            if ($sample) { $samples.Add($sample) }
            foreach ($reading in (Get-ThermalReading)) {
                if ($null -eq $maxTemp -or $reading.Celsius -gt $maxTemp) { $maxTemp = $reading.Celsius }
            }
            Start-Sleep -Seconds 2
        }
    }
    finally {
        foreach ($worker in $workers) {
            # Stop first: after Ctrl+C the workers would otherwise keep the CPU at 100% until
            # the deadline. Stop() does nothing on a pipeline that already finished.
            try { $worker.Shell.Stop() } catch { Write-Verbose 'Load worker could not be stopped' }
            try { [void]$worker.Shell.EndInvoke($worker.Handle) } catch { Write-Verbose 'Load worker ended with an error' }
            $worker.Shell.Dispose()
        }
        $pool.Close()
        $pool.Dispose()
    }
    return [pscustomobject]@{ Samples = $samples.ToArray(); MaxTemperature = $maxTemp; Threads = $threads }
}

#endregion

#region Checks

function Invoke-SystemCheck {
    param([hashtable]$Facts)
    $findings = New-Object System.Collections.Generic.List[object]

    $computer = Get-CimSafe -ClassName 'Win32_ComputerSystem' | Select-Object -First 1
    $bios = Get-CimSafe -ClassName 'Win32_BIOS' | Select-Object -First 1
    $os = Get-CimSafe -ClassName 'Win32_OperatingSystem' | Select-Object -First 1
    $cpu = Get-CimSafe -ClassName 'Win32_Processor' | Select-Object -First 1

    if ($computer -and $bios) {
        $biosDate = ''
        $advice = @()
        if ($bios.ReleaseDate) {
            $biosDate = ([datetime]$bios.ReleaseDate).ToString('d', [Globalization.CultureInfo]::CurrentCulture)
            if (([datetime]::Now - [datetime]$bios.ReleaseDate).TotalDays -gt 3 * 365) { $advice = @(Get-Text 'Sys.Bios.Advice' @($biosDate)) }
        }
        $findings.Add((New-Finding 'System' 'Info' (Get-Text 'Sys.Model' @($computer.Manufacturer, $computer.Model, $bios.SMBIOSBIOSVersion, $biosDate)) -Advice $advice))
    }
    if ($cpu) { $findings.Add((New-Finding 'System' 'Info' (Get-Text 'Sys.Cpu' @($cpu.Name.Trim(), $cpu.NumberOfCores, $cpu.NumberOfLogicalProcessors)))) }
    if ($os) {
        $findings.Add((New-Finding 'System' 'Info' (Get-Text 'Sys.Os' @($os.Caption, $os.BuildNumber))))
        $boot = [datetime]$os.LastBootUpTime
        $uptime = ([datetime]::Now - $boot).TotalDays
        $Facts.UptimeDays = $uptime
        $status = if ($uptime -gt 14) { 'Warn' } else { 'Ok' }
        $advice = @(); if ($uptime -gt 14) { $advice = @(Get-Text 'Sys.Uptime.Advice') }
        $findings.Add((New-Finding 'System' $status (Get-Text 'Sys.Uptime' @($uptime, (Format-Time $boot))) -Advice $advice))

        $total = [double]$os.TotalVisibleMemorySize * 1KB
        $free = [double]$os.FreePhysicalMemory * 1KB
        if ($total -gt 0) {
            $used = 100.0 * (1 - $free / $total)
            $Facts.MemoryUsedPercent = $used
            $status = if ($used -ge 90) { 'Warn' } else { 'Ok' }
            $advice = New-Object System.Collections.Generic.List[string]
            if ($used -ge 90) { $advice.Add((Get-Text 'Sys.Memory.Advice')) }
            if ($used -ge 75 -and $total -le 8.5GB) { $advice.Add((Get-Text 'Sys.MemorySmall.Advice')) }
            $details = @()
            if ($used -ge 75) {
                # Which apps use the memory, grouped by name (a browser runs as many processes).
                $details = @(Get-Process -ErrorAction SilentlyContinue | Group-Object ProcessName |
                        ForEach-Object { [pscustomobject]@{ Name = $_.Name; Bytes = [double]($_.Group | Measure-Object WorkingSet64 -Sum).Sum } } |
                        Where-Object { $_.Name -notin @('Idle', 'System', 'Registry', 'Memory Compression') } |
                        Sort-Object Bytes -Descending | Select-Object -First 5 |
                        ForEach-Object { Get-Text 'Sys.MemoryTop' @($_.Name, (Format-ByteSize $_.Bytes)) })
            }
            $findings.Add((New-Finding 'System' $status (Get-Text 'Sys.Memory' @((Format-ByteSize $free), (Format-ByteSize $total), $used)) -Details $details -Advice $advice.ToArray()))
        }
    }
    try {
        $drive = New-Object IO.DriveInfo(([IO.Path]::GetPathRoot($env:SystemRoot)))
        $percent = 100.0 * $drive.AvailableFreeSpace / $drive.TotalSize
        $status = if ($percent -lt 10) { 'Warn' } else { 'Ok' }
        $advice = @(); if ($percent -lt 10) { $advice = @(Get-Text 'Sys.Disk.Advice') }
        $findings.Add((New-Finding 'System' $status (Get-Text 'Sys.Disk' @($drive.Name.TrimEnd('\'), (Format-ByteSize $drive.AvailableFreeSpace), (Format-ByteSize $drive.TotalSize))) -Advice $advice))
    }
    catch { Write-Verbose "Free space unavailable: $($_.Exception.Message)" }

    return $findings.ToArray()
}

function Invoke-ShutdownCheck {
    param([datetime]$Since, [hashtable]$Facts)
    $findings = New-Object System.Collections.Generic.List[object]

    # Unexpected shutdowns: Kernel-Power 41 (with the stop code when there was a blue screen).
    $kernel41 = @(Get-EventSafe @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Kernel-Power'; Id = 41; StartTime = $Since })
    $dirty = @(Get-EventSafe @{ LogName = 'System'; ProviderName = 'EventLog'; Id = 6008; StartTime = $Since })
    $powerLoss = 0
    $bugCheck = 0
    $details = New-Object System.Collections.Generic.List[string]
    foreach ($event in ($kernel41 | Sort-Object TimeCreated -Descending)) {
        $data = Get-EventDataMap $event
        $code = 0L
        [void][long]::TryParse([string]$data['BugcheckCode'], [ref]$code)
        if ($code -eq 0) { $powerLoss++ } else { $bugCheck++ }
        if ($details.Count -lt 6) {
            if ($code -eq 0) { $details.Add((Get-Text 'Shut.PowerLoss' @((Format-Time $event.TimeCreated)))) }
            else { $details.Add((Get-Text 'Shut.BugCheck' @((Format-Time $event.TimeCreated), $code))) }
        }
    }
    $unexpected = [Math]::Max($kernel41.Count, $dirty.Count)
    $Facts.UnexpectedShutdowns = $unexpected
    $Facts.PowerLossShutdowns = $powerLoss
    $Facts.BugCheckShutdowns = $bugCheck
    if ($unexpected -eq 0) { $findings.Add((New-Finding 'Shutdown' 'Ok' (Get-Text 'Shut.None'))) }
    else {
        $advice = @(); if ($powerLoss -gt 0) { $advice = @(Get-Text 'Shut.PowerLoss.Advice') }
        $findings.Add((New-Finding 'Shutdown' 'Critical' (Get-Text 'Shut.Found' @($unexpected)) -Details $details.ToArray() -Advice $advice))
    }

    $bugChecks = @(Get-EventSafe @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WER-SystemErrorReporting'; Id = 1001; StartTime = $Since })
    $Facts.BlueScreens = $bugChecks.Count
    if ($bugChecks.Count -gt 0) {
        $findings.Add((New-Finding 'Shutdown' 'Critical' (Get-Text 'Shut.BlueScreens' @($bugChecks.Count)) -Advice @(Get-Text 'Shut.BlueScreen.Advice')))
    }

    # Critical temperature: Kernel-Power 85/86 (shutdown) and 87/88 (hibernation).
    $thermal = @(Get-EventSafe @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Kernel-Power'; Id = 85, 86, 87, 88; StartTime = $Since })
    $Facts.ThermalEvents = $thermal.Count
    if ($thermal.Count -eq 0) { $findings.Add((New-Finding 'Shutdown' 'Ok' (Get-Text 'Thermal.None'))) }
    else {
        $last = ($thermal | Sort-Object TimeCreated -Descending | Select-Object -First 1).TimeCreated
        $findings.Add((New-Finding 'Shutdown' 'Critical' (Get-Text 'Thermal.Found' @($thermal.Count, (Format-Time $last))) -Advice @(Get-Text 'Temp.Hot.Advice')))
    }

    # Why the PC went to sleep or hibernated: Kernel-Power 42.
    $sleeps = @(Get-EventSafe @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Kernel-Power'; Id = 42; StartTime = $Since })
    $kinds = @{}
    $lastBattery = $null
    $thermalSleeps = 0
    foreach ($event in $sleeps) {
        $data = Get-EventDataMap $event
        $line = @(([string]$event.Message) -split "`r?`n" | Where-Object { $_ -match ':\s*\S' } | Select-Object -Last 1)
        $text = ''
        if ($line.Count -gt 0 -and $line[0]) { $text = ($line[0] -split ':', 2)[1].Trim() }
        $kind = Get-SleepReasonKind -Code ([string]$data['Reason']) -Text $text
        if (-not $kinds.ContainsKey($kind)) { $kinds[$kind] = 0 }
        $kinds[$kind]++
        if ($kind -eq 'Battery' -and ($null -eq $lastBattery -or $event.TimeCreated -gt $lastBattery)) { $lastBattery = $event.TimeCreated }
        if ($kind -eq 'Thermal') { $thermalSleeps++ }
    }
    $Facts.BatterySleeps = 0
    if ($kinds.ContainsKey('Battery')) { $Facts.BatterySleeps = $kinds['Battery'] }
    $Facts.ThermalSleeps = $thermalSleeps

    if ($sleeps.Count -gt 0) {
        $rows = foreach ($entry in ($kinds.GetEnumerator() | Sort-Object Value -Descending)) {
            $label = if ($entry.Key -eq 'Other') { '?' } else { Get-Text "Reason.$($entry.Key)" }
            Get-Text 'Sleep.Row' @($entry.Value, $label)
        }
        $findings.Add((New-Finding 'Shutdown' 'Info' (Get-Text 'Sleep.Summary' @($sleeps.Count)) -Details @($rows)))
    }
    if ($Facts.BatterySleeps -gt 0) {
        $acChanges = @(Get-EventSafe @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Kernel-Power'; Id = 105; StartTime = $Since })
        $Facts.AcChanges = $acChanges.Count
        $details = @()
        if ($acChanges.Count -lt $Facts.BatterySleeps) { $details = @(Get-Text 'Sleep.BatteryOnAc' @($acChanges.Count)) }
        $findings.Add((New-Finding 'Shutdown' 'Critical' (Get-Text 'Sleep.Battery' @($Facts.BatterySleeps, (Format-Time $lastBattery))) -Details $details))
    }
    if ($thermalSleeps -gt 0) {
        $findings.Add((New-Finding 'Shutdown' 'Critical' (Get-Text 'Sleep.Thermal' @($thermalSleeps)) -Advice @(Get-Text 'Temp.Hot.Advice')))
    }
    return $findings.ToArray()
}

function Invoke-PowerCheck {
    param([datetime]$Since, [hashtable]$Facts)
    $findings = New-Object System.Collections.Generic.List[object]

    $batteries = @(Get-BatteryReport)
    if ($batteries.Count -eq 0) {
        $findings.Add((New-Finding 'Power' 'Info' (Get-Text 'Bat.None')))
        return $findings.ToArray()
    }
    foreach ($battery in $batteries) {
        $status = Get-BatteryHealthStatus $battery.HealthPercent
        if ($null -ne $battery.HealthPercent -and ($null -eq $Facts.BatteryHealth -or $battery.HealthPercent -lt $Facts.BatteryHealth)) { $Facts.BatteryHealth = $battery.HealthPercent }
        $label = (@($battery.Manufacturer, $battery.Chemistry) | Where-Object { $_ }) -join ' '
        $details = @(); if ($battery.CycleCount -gt 0) { $details = @(Get-Text 'Bat.Cycles' @($battery.CycleCount)) }
        $advice = @()
        if ($status -eq 'Critical') { $advice = @((Get-Text 'Bat.Dead.Advice'), (Get-Text 'Bat.Charger.Advice'), (Get-Text 'Bat.Bios.Advice')) }
        elseif ($status -eq 'Warn') { $advice = @(Get-Text 'Bat.Worn.Advice') }
        $health = 0; if ($null -ne $battery.HealthPercent) { $health = $battery.HealthPercent }
        $text = Get-Text 'Bat.Health' @($battery.Name, $label, (Format-EnergyWh $battery.FullChargeCapacity), (Format-EnergyWh $battery.DesignCapacity), $health)
        $findings.Add((New-Finding 'Power' $status $text -Details $details -Advice $advice))
    }

    $policy = Get-CriticalBatteryPolicy
    if ($policy) {
        $findings.Add((New-Finding 'Power' 'Info' (Get-Text 'Bat.Critical' @((Get-Text "Action.$($policy.ActionDc)"), $policy.LevelDc))))
    }
    if (-not $Facts.ContainsKey('AcChanges')) {
        $Facts.AcChanges = @(Get-EventSafe @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Kernel-Power'; Id = 105; StartTime = $Since }).Count
    }
    $findings.Add((New-Finding 'Power' 'Info' (Get-Text 'Bat.Ac' @($Facts.AcChanges))))
    return $findings.ToArray()
}

function Invoke-ThermalCheck {
    param([datetime]$Since, [hashtable]$Facts, [int]$LoadSeconds)
    $findings = New-Object System.Collections.Generic.List[object]

    $readings = @(Get-ThermalReading)
    if ($readings.Count -eq 0) {
        $findings.Add((New-Finding 'Thermal' 'Info' (Get-Text 'Temp.None') -Advice @(Get-Text 'Temp.None.Advice')))
    }
    foreach ($reading in $readings) {
        if ($null -eq $Facts.MaxTemperature -or $reading.Celsius -gt $Facts.MaxTemperature) { $Facts.MaxTemperature = $reading.Celsius }
        $status = 'Ok'
        if ($reading.Celsius -ge $script:TempCriticalCelsius) { $status = 'Critical' } elseif ($reading.Celsius -ge $script:TempWarnCelsius) { $status = 'Warn' }
        $advice = @(); if ($status -ne 'Ok') { $advice = @(Get-Text 'Temp.Hot.Advice') }
        $findings.Add((New-Finding 'Thermal' $status (Get-Text 'Temp.Reading' @($reading.Name, $reading.Celsius)) -Advice $advice))
    }

    $sample = Get-CpuSample
    if ($sample -and $sample.BaseMhz -gt 0) {
        $findings.Add((New-Finding 'Thermal' 'Info' (Get-Text 'Cpu.Now' @($sample.Mhz, $sample.PerformancePercent, $sample.BaseMhz, $sample.BusyPercent))))
    }
    $firmware = @(Get-EventSafe @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Kernel-Processor-Power'; Id = 37; StartTime = $Since })
    $limited = $sample -and $sample.LimitPercent -gt 0 -and $sample.LimitPercent -lt 100
    if ($limited -or $firmware.Count -gt 0) {
        $details = New-Object System.Collections.Generic.List[string]
        if ($firmware.Count -gt 0) { $details.Add((Get-Text 'Cpu.FirmwareEvents' @($firmware.Count))) }
        $text = if ($limited) { Get-Text 'Cpu.Limited' @($sample.LimitPercent) } else { Get-Text 'Cpu.FirmwareEvents' @($firmware.Count) }
        if (-not $limited) { $details.Clear() }
        $findings.Add((New-Finding 'Thermal' 'Warn' $text -Details $details.ToArray() -Advice @(Get-Text 'Cpu.Limited.Advice')))
    }

    if ($LoadSeconds -gt 0 -and $sample -and $sample.BaseMhz -gt 0) {
        Write-Line ('  ' + (Get-Text 'Load.Running' @($LoadSeconds, [Environment]::ProcessorCount))) DarkGray
        $test = Invoke-CpuLoadTest -Seconds $LoadSeconds
        $summary = Get-LoadTestSummary -Samples $test.Samples -BaseMhz $sample.BaseMhz
        # The temperature is measured separately from the CPU samples: keep it either way.
        if ($null -ne $test.MaxTemperature -and ($null -eq $Facts.MaxTemperature -or $test.MaxTemperature -gt $Facts.MaxTemperature)) { $Facts.MaxTemperature = $test.MaxTemperature }
        if (-not $summary) {
            # No usable samples (for example a 1-second test): it cannot support a verdict.
            if ($null -ne $test.MaxTemperature) {
                $status = 'Ok'
                if ($test.MaxTemperature -ge $script:TempCriticalCelsius) { $status = 'Critical' } elseif ($test.MaxTemperature -ge $script:TempWarnCelsius) { $status = 'Warn' }
                $advice = @(); if ($status -ne 'Ok') { $advice = @(Get-Text 'Temp.Hot.Advice') }
                $findings.Add((New-Finding 'Thermal' $status (Get-Text 'Load.TempMax' @($test.MaxTemperature)) -Advice $advice))
            }
            $findings.Add((New-Finding 'Thermal' 'Info' (Get-Text 'Load.NoSamples')))
        }
        if ($summary) {
            $Facts.LoadTestRan = $true
            $Facts.Throttled = $summary.Throttled
            $details = New-Object System.Collections.Generic.List[string]
            $details.Add((Get-Text 'Load.Result' @($LoadSeconds, $summary.PeakMhz, $summary.SustainedMhz, $summary.SustainedPercent, $summary.MinLimitPercent)))
            if ($null -ne $test.MaxTemperature) { $details.Add((Get-Text 'Load.TempMax' @($test.MaxTemperature))) }
            if ($summary.Throttled) { $findings.Add((New-Finding 'Thermal' 'Critical' (Get-Text 'Load.Throttled') -Details $details.ToArray() -Advice @(Get-Text 'Load.Throttled.Advice'))) }
            else { $findings.Add((New-Finding 'Thermal' 'Ok' (Get-Text 'Load.Ok') -Details $details.ToArray())) }
        }
    }
    elseif ($LoadSeconds -eq 0) {
        $findings.Add((New-Finding 'Thermal' 'Info' (Get-Text 'Load.Hint')))
    }
    return $findings.ToArray()
}

function Invoke-HardwareCheck {
    param([datetime]$Since, [hashtable]$Facts)
    $findings = New-Object System.Collections.Generic.List[object]

    $disks = @()
    try { $disks = @(Get-PhysicalDisk -ErrorAction Stop) } catch { $disks = @() }
    foreach ($disk in $disks) {
        $health = [string]$disk.HealthStatus
        $status = if ($health -eq 'Healthy') { 'Ok' } elseif ($health -eq 'Warning') { 'Warn' } else { 'Critical' }
        $advice = @(); if ($status -ne 'Ok') { $advice = @(Get-Text 'Disk.Bad.Advice') }
        $details = @()
        try {
            $smart = $disk | Get-StorageReliabilityCounter -ErrorAction Stop
            if ($smart -and ($smart.Temperature -or $smart.Wear -or $smart.ReadErrorsUncorrected)) {
                $details = @(Get-Text 'Disk.Smart' @($disk.FriendlyName, $smart.Temperature, $smart.Wear, $smart.ReadErrorsUncorrected))
            }
        }
        catch { Write-Verbose 'Reliability counters need administrator rights' }
        $findings.Add((New-Finding 'Hardware' $status (Get-Text 'Disk.Row' @($disk.FriendlyName, $disk.MediaType, (Format-ByteSize $disk.Size), $health)) -Details $details -Advice $advice))
    }

    $diskEvents = @(Get-EventSafe @{ LogName = 'System'; ProviderName = 'disk', 'Ntfs', 'stornvme', 'storahci', 'iaStorAC', 'iaStorAVC', 'volmgr'; Level = 1, 2, 3; StartTime = $Since })
    if ($diskEvents.Count -eq 0) { $findings.Add((New-Finding 'Hardware' 'Ok' (Get-Text 'Disk.NoEvents'))) }
    else {
        $rows = @($diskEvents | Group-Object ProviderName, Id | Sort-Object Count -Descending | Select-Object -First 5 | ForEach-Object { '{0,5}x  {1}' -f $_.Count, $_.Name })
        $findings.Add((New-Finding 'Hardware' 'Warn' (Get-Text 'Disk.Events' @($diskEvents.Count)) -Details $rows))
    }

    $whea = @(Get-EventSafe @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WHEA-Logger'; StartTime = $Since })
    if ($whea.Count -eq 0) { $findings.Add((New-Finding 'Hardware' 'Ok' (Get-Text 'Whea.None'))) }
    else {
        $last = ($whea | Sort-Object TimeCreated -Descending | Select-Object -First 1).TimeCreated
        $fatal = @($whea | Where-Object { $_.Level -le 2 }).Count -gt 0
        $findings.Add((New-Finding 'Hardware' $(if ($fatal) { 'Critical' } else { 'Warn' }) (Get-Text 'Whea.Found' @($whea.Count, (Format-Time $last))) -Advice @(Get-Text 'Whea.Advice')))
    }

    $rtc = @(Get-EventSafe @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-HAL'; Id = 20, 21; StartTime = $Since })
    if ($rtc.Count -gt 0) { $findings.Add((New-Finding 'Hardware' 'Info' (Get-Text 'Rtc.Found' @($rtc.Count)))) }
    return $findings.ToArray()
}

function Get-RegistryValueMap {
    # Name -> value of a registry key (read-only); empty when the key does not exist.
    param([string]$Path)
    $map = @{}
    try {
        $item = Get-ItemProperty -LiteralPath $Path -ErrorAction Stop
        foreach ($property in $item.PSObject.Properties) {
            if ($property.Name -notmatch '^PS(Path|ParentPath|ChildName|Drive|Provider)$') { $map[$property.Name] = $property.Value }
        }
    }
    catch { Write-Verbose "Registry key not available: $Path" }
    return $map
}

function Get-StartupProgram {
    # Programs started at sign-in: Run keys, Startup folders and Store app startup tasks.
    $items = New-Object System.Collections.Generic.List[object]
    $approvedRoot = 'Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved'
    $runKeys = @(
        @{ Run = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'; Approved = "HKCU:\$approvedRoot\Run" },
        @{ Run = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run'; Approved = "HKLM:\$approvedRoot\Run" },
        @{ Run = 'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'; Approved = "HKLM:\$approvedRoot\Run32" }
    )
    foreach ($key in $runKeys) {
        $approved = Get-RegistryValueMap $key.Approved
        foreach ($name in @((Get-RegistryValueMap $key.Run).Keys)) {
            $enabled = $true
            if ($approved.ContainsKey($name)) { $enabled = Test-StartupApprovedEnabled $approved[$name] }
            $items.Add([pscustomobject]@{ Name = [string]$name; Enabled = $enabled })
        }
    }
    $folders = @(
        @{ Path = [Environment]::GetFolderPath('Startup'); Approved = "HKCU:\$approvedRoot\StartupFolder" },
        @{ Path = [Environment]::GetFolderPath('CommonStartup'); Approved = "HKLM:\$approvedRoot\StartupFolder" }
    )
    foreach ($folder in $folders) {
        if (-not $folder.Path -or -not [IO.Directory]::Exists($folder.Path)) { continue }
        $approved = Get-RegistryValueMap $folder.Approved
        foreach ($file in (New-Object IO.DirectoryInfo($folder.Path)).GetFiles()) {
            if ($file.Name -ieq 'desktop.ini') { continue }
            $enabled = $true
            if ($approved.ContainsKey($file.Name)) { $enabled = Test-StartupApprovedEnabled $approved[$file.Name] }
            $items.Add([pscustomobject]@{ Name = [IO.Path]::GetFileNameWithoutExtension($file.Name); Enabled = $enabled })
        }
    }
    $appModel = 'HKCU:\Software\Classes\Local Settings\Software\Microsoft\Windows\CurrentVersion\AppModel\SystemAppData'
    foreach ($package in @(Get-ChildItem -LiteralPath $appModel -ErrorAction SilentlyContinue)) {
        foreach ($task in @(Get-ChildItem -LiteralPath $package.PSPath -ErrorAction SilentlyContinue)) {
            if ($task.PSChildName -match '^\{?[0-9a-fA-F]{8}-') { continue }   # GUID keys are not startup tasks
            $state = (Get-RegistryValueMap $task.PSPath)['State']
            if ($null -eq $state) { continue }
            $items.Add([pscustomobject]@{ Name = (ConvertTo-StartupTaskName $package.PSChildName); Enabled = (Test-StartupTaskEnabled $state) })
        }
    }
    # One line per program: a program listed in two places counts once, enabled if either is.
    $aliases = @{ 'Teams' = 'Microsoft Teams'; 'com.squirrel.Teams.Teams' = 'Microsoft Teams' }
    foreach ($item in $items) { if ($aliases.ContainsKey($item.Name)) { $item.Name = $aliases[$item.Name] } }
    return @($items | Group-Object Name | ForEach-Object {
            [pscustomobject]@{ Name = $_.Name; Enabled = [bool](@($_.Group | Where-Object { $_.Enabled }).Count) }
        })
}

function Invoke-MaintenanceCheck {
    param([datetime]$Since, [hashtable]$Facts)
    $findings = New-Object System.Collections.Generic.List[object]

    # Restart pending and Fast Startup.
    $session = Get-RegistryValueMap 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager'
    $updatesPending = (Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') -or
        (Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')
    $filesPending = $session.ContainsKey('PendingFileRenameOperations') -and @($session['PendingFileRenameOperations'] | Where-Object { $_ }).Count -gt 0
    $fastStartup = (Get-RegistryValueMap 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power')['HiberbootEnabled'] -eq 1
    $uptime = 0.0; if ($Facts.ContainsKey('UptimeDays') -and $Facts.UptimeDays) { $uptime = [double]$Facts.UptimeDays }
    if ($updatesPending) { $findings.Add((New-Finding 'Maintenance' 'Warn' (Get-Text 'Maint.RestartUpdates') -Advice @(Get-Text 'Maint.Restart.Advice'))) }
    elseif ($filesPending) { $findings.Add((New-Finding 'Maintenance' 'Info' (Get-Text 'Maint.RestartFiles') -Advice @(Get-Text 'Maint.Restart.Advice'))) }
    if ($fastStartup -and ($uptime -gt 7 -or $updatesPending -or $filesPending)) {
        $findings.Add((New-Finding 'Maintenance' 'Info' (Get-Text 'Maint.FastStartup')))
    }

    # Windows Update: failed installs (event 20) and successful ones (event 19).
    $updates = @(Get-EventSafe @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WindowsUpdateClient'; Id = 19, 20; StartTime = $Since })
    $failed = @($updates | Where-Object { $_.Id -eq 20 })
    $succeeded = @($updates | Where-Object { $_.Id -eq 19 })
    if ($failed.Count -eq 0) {
        if ($succeeded.Count -gt 0) { $findings.Add((New-Finding 'Maintenance' 'Ok' (Get-Text 'Maint.UpdatesOk' @($succeeded.Count)))) }
    }
    else {
        $codes = @($failed | ForEach-Object { if ([string]$_.Message -match '0x[0-9A-Fa-f]{8}') { $Matches[0].ToUpperInvariant().Replace('0X', '0x') } else { '?' } })
        $kinds = @($codes | ForEach-Object { Get-WindowsUpdateErrorKind $_ })
        $details = @($codes | Group-Object | Sort-Object Count -Descending | Select-Object -First 4 | ForEach-Object {
                Get-Text 'Maint.UpdateCode' @($_.Count, $_.Name, (Get-Text "Maint.UpdateKind.$(Get-WindowsUpdateErrorKind $_.Name)"))
            })
        $benign = @($kinds | Where-Object { $_ -notin @('AppInUse', 'Busy') }).Count -eq 0
        $advice = if ($benign) { @(Get-Text 'Maint.Restart.Advice') } else { @(Get-Text 'Maint.Updates.Advice') }
        $findings.Add((New-Finding 'Maintenance' $(if ($benign) { 'Info' } else { 'Warn' }) (Get-Text 'Maint.UpdatesFailed' @($failed.Count, $succeeded.Count)) -Details $details -Advice $advice))
    }

    # Programs started with Windows.
    $startup = @(Get-StartupProgram | Where-Object { $_.Enabled } | Sort-Object Name)
    if ($startup.Count -gt 0) {
        $optional = @($startup | Where-Object { Test-OptionalStartupItem $_.Name })
        $memory = 0.0; if ($Facts.ContainsKey('MemoryUsedPercent') -and $Facts.MemoryUsedPercent) { $memory = [double]$Facts.MemoryUsedPercent }
        $status = if ($optional.Count -gt 0 -and $memory -ge 75) { 'Warn' } else { 'Info' }
        $names = @($startup | ForEach-Object { if (Test-OptionalStartupItem $_.Name) { $_.Name + ' *' } else { $_.Name } })
        $advice = @(); if ($optional.Count -gt 0) { $advice = @(Get-Text 'Maint.Startup.Advice' @((($optional | Select-Object -ExpandProperty Name) -join ', '))) }
        $findings.Add((New-Finding 'Maintenance' $status (Get-Text 'Maint.Startup' @($startup.Count, $optional.Count)) -Details @($names -join ', ') -Advice $advice))
    }

    # Storage Sense.
    $storageSense = (Get-RegistryValueMap 'HKCU:\Software\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy')['01']
    if ($storageSense -eq 1) { $findings.Add((New-Finding 'Maintenance' 'Ok' (Get-Text 'Maint.StorageSenseOn'))) }
    else { $findings.Add((New-Finding 'Maintenance' 'Info' (Get-Text 'Maint.StorageSenseOff') -Advice @(Get-Text 'Maint.StorageSense.Advice'))) }

    # Microsoft Defender.
    try {
        $defender = Get-MpComputerStatus -ErrorAction Stop
        if (-not $defender.RealTimeProtectionEnabled) {
            $findings.Add((New-Finding 'Maintenance' 'Warn' (Get-Text 'Maint.DefenderOff') -Advice @(Get-Text 'Maint.DefenderOff.Advice')))
        }
        elseif ($defender.AntivirusSignatureAge -gt 7) {
            $findings.Add((New-Finding 'Maintenance' 'Warn' (Get-Text 'Maint.DefenderOld' @($defender.AntivirusSignatureAge)) -Advice @(Get-Text 'Maint.Updates.Advice')))
        }
        else { $findings.Add((New-Finding 'Maintenance' 'Ok' (Get-Text 'Maint.DefenderOk' @($defender.AntivirusSignatureAge)))) }
    }
    catch { $findings.Add((New-Finding 'Maintenance' 'Info' (Get-Text 'Maint.DefenderUnknown'))) }

    return $findings.ToArray()
}

#endregion

#region Main

function Write-Diagnosis {
    param($Diagnosis, [hashtable]$Facts, [int]$Days)
    foreach ($cause in $Diagnosis.Causes) {
        switch ($cause) {
            'Battery' { Write-Finding (New-Finding 'Verdict' 'Critical' (Get-Text 'Verdict.Battery' @($Facts.BatteryHealth)) -Advice @((Get-Text 'Bat.Dead.Advice'), (Get-Text 'Bat.Charger.Advice'))) }
            'BatteryOk' { Write-Finding (New-Finding 'Verdict' 'Warn' (Get-Text 'Verdict.BatteryOk') -Advice @(Get-Text 'Bat.Charger.Advice')) }
            'Thermal' { Write-Finding (New-Finding 'Verdict' 'Critical' (Get-Text 'Verdict.Thermal') -Advice @(Get-Text 'Temp.Hot.Advice')) }
            'BlueScreen' { Write-Finding (New-Finding 'Verdict' 'Critical' (Get-Text 'Verdict.BlueScreen')) }
            'PowerLoss' { Write-Finding (New-Finding 'Verdict' 'Warn' (Get-Text 'Verdict.PowerLoss')) }
            'Unexplained' { Write-Finding (New-Finding 'Verdict' 'Warn' (Get-Text 'Verdict.Unexplained' @($Facts.UnexpectedShutdowns))) }
            'Incomplete' { Write-Finding (New-Finding 'Verdict' 'Warn' (Get-Text 'Verdict.Incomplete') -Details @($script:EventFailures | Select-Object -First 3)) }
            default { Write-Finding (New-Finding 'Verdict' 'Ok' (Get-Text 'Verdict.None' @($Days))) }
        }
    }
    if ($Facts.ContainsKey('EventLogIncomplete') -and $Facts.EventLogIncomplete -and $Diagnosis.Causes -notcontains 'Incomplete') {
        Write-Finding (New-Finding 'Verdict' 'Warn' (Get-Text 'Log.Failed' @($script:EventFailures.Count)) -Details @($script:EventFailures | Select-Object -First 3))
    }
    $status = switch ($Diagnosis.ThermalPaste) { 'Needed' { 'Critical' } 'Unconfirmed' { 'Info' } default { 'Ok' } }
    Write-Finding (New-Finding 'Verdict' $status (Get-Text "Paste.$($Diagnosis.ThermalPaste)"))
}

function Save-Report {
    param([string]$Folder, [object[]]$Findings, [hashtable]$Facts, $Diagnosis, [datetime]$Started)
    if (-not $Folder) {
        $Folder = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'CleanWinTempFiles\Reports'
    }
    [void][IO.Directory]::CreateDirectory($Folder)
    $stamp = $Started.ToString('yyyyMMdd-HHmmss', [Globalization.CultureInfo]::InvariantCulture)
    $text = Join-Path $Folder "health-$stamp.txt"
    $utf8 = New-Object Text.UTF8Encoding($true)
    [IO.File]::WriteAllLines($text, $script:Report.ToArray(), $utf8)
    $json = [ordered]@{
        tool      = 'system-health-check'
        version   = $script:AppVersion
        started   = $Started.ToString('o')
        facts     = $Facts
        diagnosis = $Diagnosis
        findings  = @($Findings | ForEach-Object { [ordered]@{ area = $_.Area; status = $_.Status; text = $_.Text; details = $_.Details; advice = $_.Advice } })
    }
    [IO.File]::WriteAllText([IO.Path]::ChangeExtension($text, '.json'), ($json | ConvertTo-Json -Depth 6), $utf8)
    return $text
}

function Invoke-HealthCheck {
    param([int]$Days, [int]$LoadSeconds, [string]$ReportFolder, [switch]$NoReport)

    $started = Get-Date
    $since = $started.AddDays(-$Days)
    $isAdmin = Test-IsAdministrator
    $facts = @{ BatteryHealth = $null; MaxTemperature = $null; LoadTestRan = $false; Throttled = $false }
    $all = New-Object System.Collections.Generic.List[object]
    $script:EventFailures.Clear()

    Write-Line ''
    Write-Line ('  {0}  {1}' -f (Get-Text 'App'), $script:AppVersion) White
    $role = if ($isAdmin) { Get-Text 'Header.Admin' } else { Get-Text 'Header.User' }
    Write-Line ('  {0} · {1}' -f (Format-Time $started), $role) DarkGray
    Write-Line ('  ' + (Get-Text 'Header.ReadOnly' @($Days))) DarkGray
    if (-not $isAdmin) { Write-Line ('  ' + (Get-Text 'Header.NotAdmin')) DarkGray }

    $sections = @(
        @{ Title = 'Section.System'; Run = { Invoke-SystemCheck -Facts $facts } },
        @{ Title = 'Section.Shutdowns'; Run = { Invoke-ShutdownCheck -Since $since -Facts $facts } },
        @{ Title = 'Section.Power'; Run = { Invoke-PowerCheck -Since $since -Facts $facts } },
        @{ Title = 'Section.Thermal'; Run = { Invoke-ThermalCheck -Since $since -Facts $facts -LoadSeconds $LoadSeconds } },
        @{ Title = 'Section.Maintenance'; Run = { Invoke-MaintenanceCheck -Since $since -Facts $facts } },
        @{ Title = 'Section.Hardware'; Run = { Invoke-HardwareCheck -Since $since -Facts $facts } }
    )
    foreach ($section in $sections) {
        Write-Section (Get-Text $section.Title)
        try {
            foreach ($finding in @(& $section.Run)) { if ($finding) { $all.Add($finding); Write-Finding $finding } }
        }
        catch {
            $finding = New-Finding 'Error' 'Warn' (Get-Text 'Error.Fatal' @($_.Exception.Message))
            $all.Add($finding)
            Write-Finding $finding
        }
    }

    if ($script:EventFailures.Count -gt 0) {
        $facts.EventLogIncomplete = $true
        $facts.EventLogFailures = $script:EventFailures.Count
    }
    $diagnosis = Get-Diagnosis -Facts $facts
    Write-Section (Get-Text 'Section.Verdict')
    Write-Diagnosis -Diagnosis $diagnosis -Facts $facts -Days $Days
    Write-Line ''

    if (-not $NoReport) {
        try {
            $file = Save-Report -Folder $ReportFolder -Findings $all.ToArray() -Facts $facts -Diagnosis $diagnosis -Started $started
            Write-Host ('  ' + (Get-Text 'Report.Saved' @($file))) -ForegroundColor DarkGray
        }
        catch { Write-Host ('  ' + (Get-Text 'Report.Failed' @($_.Exception.Message))) -ForegroundColor Yellow }
        Write-Host ''
    }
    if (@($all | Where-Object { $_.Status -eq 'Critical' }).Count -gt 0) { $script:ExitCode = 3 }
}

#endregion

# Run only when executed, not when dot-sourced by the tests.
if ($MyInvocation.InvocationName -ne '.') {
    Initialize-Ui -NoColor:$NoColor -Language $Language
    try {
        if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
            Write-Line ('  ' + (Get-Text 'Error.NotWindows')) Red
            $script:ExitCode = 2
        }
        else {
            # .NET resolves relative paths against the process directory, which Set-Location
            # does not change in Windows PowerShell 5.1: resolve against the PowerShell location.
            $reportFolder = $ReportPath
            if ($reportFolder) { $reportFolder = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($reportFolder) }
            Invoke-HealthCheck -Days $Days -LoadSeconds $LoadTest -ReportFolder $reportFolder -NoReport:$NoReport
        }
    }
    catch {
        Write-Line ('  ' + (Get-Text 'Error.Fatal' @($_.Exception.Message))) Red
        $script:ExitCode = 1
    }
    finally {
        if ($PauseOnExit) {
            $redirected = $true
            try { $redirected = [Console]::IsInputRedirected } catch { $redirected = $true }
            if (-not $redirected) { Write-Host ('  ' + (Get-Text 'Pause')) -NoNewline; [void](Read-Host) }
        }
    }
    exit $script:ExitCode
}
