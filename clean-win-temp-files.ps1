#Requires -Version 5.1
<#
.SYNOPSIS
    Safely removes genuinely disposable temporary files on Windows 10 and Windows 11.

.DESCRIPTION
    Scans well-known temporary locations, shows how much space can be recovered and
    removes only files that are old enough, not in use and located inside validated
    folders. Junctions and symbolic links are never followed or deleted.

    Safe cleanup (pre-selected):
        UserTemp, WindowsTemp, StoreAppTemp, DeliveryOptimization
    Advanced cleanup (never pre-selected):
        RecycleBin, CrashDumps, BrowserCache, ShaderCache, ComponentStore

    Never touched: Prefetch, WinSxS (only through DISM), SoftwareDistribution, the Windows
    Installer cache, personal folders, browser profiles (cookies, passwords, history),
    restore points and the registry.

.PARAMETER Mode
    Safe (default) scans the recommended items. Advanced also scans the optional items
    up front (they are still not selected unless you select them or use -Include).

.PARAMETER DryRun
    Scan and report what would be removed without deleting anything.

.PARAMETER Include
    Additional category IDs to select, e.g. -Include RecycleBin,CrashDumps.
    Run with -ListCategories to see every ID.

.PARAMETER Exclude
    Category IDs to unselect, e.g. -Exclude WindowsTemp.

.PARAMETER Yes
    Unattended: no questions. Cleans the default selection plus -Include minus -Exclude.

.PARAMETER NoElevate
    Never offer to restart as administrator.

.PARAMETER ListCategories
    Print the categories and exit.

.PARAMETER LogPath
    Log file path. Default: %LOCALAPPDATA%\CleanWinTempFiles\Logs\cleanup-<timestamp>.log
    A machine-readable .json summary is written next to it.

.PARAMETER NoLog
    Do not write log files.

.PARAMETER NoColor
    Disable colors (the NO_COLOR environment variable is also honored).

.PARAMETER Ascii
    Use only ASCII symbols.

.PARAMETER Language
    Interface language: Auto (default), en or pt.

.PARAMETER PauseOnExit
    Wait for Enter before closing (the .bat launcher sets this on double-click).

.EXAMPLE
    .\clean-win-temp-files.ps1 -DryRun
    Shows what would be removed. Nothing is deleted.

.EXAMPLE
    .\clean-win-temp-files.ps1 -Mode Advanced
    Interactive cleanup with the optional categories already scanned.

.EXAMPLE
    .\clean-win-temp-files.ps1 -Yes -Include CrashDumps
    Unattended safe cleanup plus crash dumps older than 30 days.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Interactive, colored terminal UI.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Internal helpers; -DryRun is the simulation switch.')]
[CmdletBinding()]
param(
    [ValidateSet('Safe', 'Advanced')]
    [string]$Mode = 'Safe',

    [switch]$DryRun,

    [string[]]$Include = @(),

    [string[]]$Exclude = @(),

    [switch]$Yes,

    [switch]$NoElevate,

    [switch]$ListCategories,

    [string]$LogPath,

    [switch]$NoLog,

    [switch]$NoColor,

    [switch]$Ascii,

    [ValidateSet('Auto', 'en', 'pt')]
    [string]$Language = 'Auto',

    [switch]$PauseOnExit,

    # Internal: set by the elevation relaunch. Validated against the profile list.
    [Parameter(DontShow = $true)]
    [string]$TargetLocalAppData,

    # Internal: marks the elevated child so it never tries to elevate again.
    [Parameter(DontShow = $true)]
    [switch]$Relaunched
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#region Constants

$script:AppName = 'Clean Windows Temp Files'
$script:AppVersion = '2.0.0'
$script:ScriptPath = $PSCommandPath
$script:ExitCode = 0

$script:SafeCategoryIds = @('UserTemp', 'WindowsTemp', 'StoreAppTemp', 'DeliveryOptimization')
$script:AdvancedCategoryIds = @('RecycleBin', 'CrashDumps', 'BrowserCache', 'ShaderCache', 'ComponentStore')

# Minimum age (hours since the newest of creation / last write) before a file is a candidate.
$script:MinAgeHours = @{
    UserTemp     = 24     # apps and installers may still need files from the current session
    WindowsTemp  = 72     # services and installers awaiting a restart use this folder
    StoreAppTemp = 24
    CrashDumps   = 720    # 30 days: recent dumps are evidence for diagnosing crashes
    BrowserCache = 0      # only cleaned while the browser is closed
    ShaderCache  = 1
}

$script:DeliveryOptimizationMinBytes = 100MB
$script:LogRetentionCount = 30
$script:AllowedSingleFiles = @('MEMORY.DMP')

# FILE_ATTRIBUTE_OFFLINE | RECALL_ON_OPEN | RECALL_ON_DATA_ACCESS: cloud placeholders are never touched.
$script:CloudAttributes = 0x1000 -bor 0x40000 -bor 0x400000

$script:NativeReady = $null
$script:Ui = $null
$script:Context = $null
$script:SkipPause = $false
$script:StatusPrefix = ''
$script:ProgressBaseFiles = 0L
$script:ProgressBaseBytes = 0L

#endregion

#region Text

$script:Text = @{
    en = @{
        'Header.Admin'            = 'Administrator'
        'Header.User'             = 'Standard user'
        'Header.DryRun'           = 'DRY RUN — nothing will be deleted'
        'Header.RebootPending'    = 'A Windows restart is pending. Restarting before cleaning is recommended.'
        'Header.Server'           = 'Windows Server detected: only Windows 10 and 11 are officially supported.'
        'Header.OtherUser'        = 'Cleaning the files of the account that started the tool.'
        'Error.NotWindows'        = 'This tool runs on Windows 10 and Windows 11 only.'
        'Error.Unsupported'       = 'Unsupported Windows version (build {0}). Windows 10 or Windows 11 is required.'
        'Error.Language'          = 'PowerShell is running in {0} mode. This tool needs FullLanguage mode.'
        'Error.UnknownCategory'   = 'Unknown category: {0}. Valid categories: {1}'
        'Error.Fatal'             = 'Unexpected error: {0}'
        'Elevate.Explain'         = 'Windows temporary files, the Delivery Optimization cache and system crash dumps need administrator rights.'
        'Elevate.Prompt'          = '[Enter/Y] Restart as administrator (recommended)   [N] Continue with your own files only'
        'Elevate.Cancelled'       = 'Administrator permission was not granted. Continuing with your own files only.'
        'Elevate.Failed'          = 'Could not restart as administrator ({0}). Continuing with your own files only.'
        'Elevate.Done'            = 'The cleanup ran in the administrator window.'
        'Elevate.StillUser'       = 'Still running without administrator rights; items that need it will be skipped.'
        'Elevate.TargetRejected'  = 'The user folder passed by the launcher was not accepted; using this account''s folders.'
        'Scan.Title'              = 'Scanning'
        'Section.Safe'            = 'SAFE CLEANUP · recommended'
        'Section.Advanced'        = 'ADVANCED · optional — read each note'
        'Row.Files'               = '{0} files'
        'Row.File'                = '1 file'
        'Row.Items'               = '{0} items'
        'Row.Item'                = '1 item'
        'State.Empty'             = 'nothing to clean'
        'State.NeedsAdmin'        = 'needs administrator'
        'State.Unavailable'       = 'not available on this PC'
        'State.Deferred'          = 'size is checked by Windows during cleanup'
        'State.Aborted'           = 'skipped for safety'
        'State.BlockedProcess'    = '{0} open — close it to include'
        'State.RebootPending'     = 'restart Windows first'
        'State.Small'             = 'small — Windows already manages it'
        'State.OtherUser'         = 'only available to the signed-in account'
        'Note.PartialAdmin'       = 'some locations need administrator'
        'Note.Blocked'            = '{0} open — its cache will be skipped'
        'Note.Aborted'            = 'A folder resolved to a protected location ({0}). Nothing in this category will be touched.'
        'Total.Selected'          = 'Selected'
        'Total.Advanced'          = 'Available in advanced options'
        'Total.Kept'              = 'Kept for safety: {0} recent files ({1}) — they may still be in use'
        'Menu.Clean'              = 'Clean selected'
        'Menu.Simulate'           = 'Simulate'
        'Menu.Toggle'             = 'Select/unselect'
        'Menu.Advanced'           = 'Advanced options'
        'Menu.Quit'               = 'Quit'
        'Menu.Prompt'             = 'Choice'
        'Menu.Invalid'            = 'Not recognized: {0}'
        'Menu.NotSelectable'      = '{0}: {1}'
        'Confirm.RecycleBin'      = 'Empty the Recycle Bin? {0} ({1} items) will be permanently deleted. [Y/N]'
        'Confirm.ComponentStore'  = 'Windows component cleanup can take 5 to 30 minutes. Select it? [Y/N]'
        'Confirm.NotInteractive'  = 'Input is not interactive. Run with -Yes to clean without questions.'
        'Nothing.Selected'        = 'Nothing selected. No changes were made.'
        'Quit'                    = 'No changes were made.'
        'Clean.Title'             = 'Cleaning'
        'Clean.Simulating'        = 'Simulating'
        'Clean.DismAnalyze'       = 'Windows is analyzing its component store'
        'Clean.DismCleanup'       = 'Windows is cleaning its component store — this can take a while'
        'Result.Freed'            = '{0} freed'
        'Result.WouldFree'        = '{0} would be freed'
        'Result.Approx'           = 'about {0} freed'
        'Result.Nothing'          = 'nothing removed'
        'Result.NotRecommended'   = 'Windows reports that no cleanup is needed'
        'Result.Recommended'      = 'Windows recommends cleanup ({0} reclaimable packages)'
        'Result.DismFailed'       = 'DISM failed (exit code {0})'
        'Result.DismBusy'         = 'Windows is busy servicing or needs a restart; try again after restarting'
        'Result.RestartAdvised'   = 'restart Windows to finish'
        'Result.RecycleFailed'    = 'Windows could not empty the Recycle Bin (0x{0:X8})'
        'Result.DoFailed'         = 'Delivery Optimization did not accept the request: {0}'
        'Result.Blocked'          = '{0} was opened — skipped'
        'Summary.Done'            = 'Cleaning completed in {0}'
        'Summary.DryRun'          = 'Simulation completed in {0} — nothing was deleted'
        'Summary.Recovered'       = 'Recovered'
        'Summary.WouldRecover'    = 'Would recover'
        'Summary.FilesRemoved'    = 'Files removed'
        'Summary.FilesWould'      = 'Files that would be removed'
        'Summary.DirsRemoved'     = 'Empty folders removed'
        'Summary.InUse'           = 'Skipped — in use'
        'Summary.Denied'          = 'Skipped — access denied'
        'Summary.Recent'          = 'Kept — recent'
        'Summary.Links'           = 'Ignored — links (never followed)'
        'Summary.Pending'         = 'Released when the app closes'
        'Summary.LongPath'        = 'Skipped — path too long'
        'Summary.Errors'          = 'Unexpected errors'
        'Summary.FreeSpace'       = 'Free space on {0}'
        'Summary.Largest'         = 'Largest items'
        'Summary.Log'             = 'Log'
        'Summary.LogFailed'       = 'The log could not be written: {0}'
        'Summary.Tip'             = 'Tip: Storage Sense (Settings > System > Storage) keeps temporary files under control automatically.'
        'Pause'                   = 'Press Enter to close'
        'List.Safe'               = 'Safe (pre-selected)'
        'List.Advanced'           = 'Advanced (opt-in)'
        'List.Admin'              = 'needs administrator'
        'Cat.UserTemp.Name'             = 'Temporary files (your account)'
        'Cat.UserTemp.Note'             = 'Files older than 24 hours in %TEMP%'
        'Cat.WindowsTemp.Name'          = 'Windows temporary files'
        'Cat.WindowsTemp.Note'          = 'Files older than 3 days in the Windows Temp folder'
        'Cat.StoreAppTemp.Name'         = 'Microsoft Store app temporary files'
        'Cat.StoreAppTemp.Note'         = 'Temporary folders of Store apps, older than 24 hours'
        'Cat.DeliveryOptimization.Name' = 'Delivery Optimization cache'
        'Cat.DeliveryOptimization.Note' = 'Update downloads kept for sharing; removed through Windows itself'
        'Cat.RecycleBin.Name'           = 'Recycle Bin'
        'Cat.RecycleBin.Note'           = 'Deleted items can no longer be restored'
        'Cat.CrashDumps.Name'           = 'Old crash dumps and error reports'
        'Cat.CrashDumps.Note'           = 'Only older than 30 days; recent ones are kept for diagnosis'
        'Cat.BrowserCache.Name'         = 'Browser caches'
        'Cat.BrowserCache.Note'         = 'Cache only: logins, cookies, history and bookmarks are kept. Sites load slower at first'
        'Cat.ShaderCache.Name'          = 'DirectX and GPU shader caches'
        'Cat.ShaderCache.Note'          = 'Games may stutter for a while as shaders are rebuilt'
        'Cat.ComponentStore.Name'       = 'Windows component cleanup (DISM)'
        'Cat.ComponentStore.Note'       = 'Slow (5-30 min). Removes superseded update components; never uses /ResetBase'
    }
    pt = @{
        'Header.Admin'            = 'Administrador'
        'Header.User'             = 'Usuário padrão'
        'Header.DryRun'           = 'SIMULAÇÃO — nada será apagado'
        'Header.RebootPending'    = 'Há uma reinicialização pendente. Recomenda-se reiniciar o Windows antes de limpar.'
        'Header.Server'           = 'Windows Server detectado: apenas Windows 10 e 11 são oficialmente suportados.'
        'Header.OtherUser'        = 'Limpando os arquivos da conta que abriu a ferramenta.'
        'Error.NotWindows'        = 'Esta ferramenta funciona apenas no Windows 10 e no Windows 11.'
        'Error.Unsupported'       = 'Versão do Windows não suportada (build {0}). É necessário Windows 10 ou Windows 11.'
        'Error.Language'          = 'O PowerShell está no modo {0}. Esta ferramenta precisa do modo FullLanguage.'
        'Error.UnknownCategory'   = 'Categoria desconhecida: {0}. Categorias válidas: {1}'
        'Error.Fatal'             = 'Erro inesperado: {0}'
        'Elevate.Explain'         = 'Os temporários do Windows, o cache da Otimização de Entrega e os despejos de memória do sistema exigem privilégios de administrador.'
        'Elevate.Prompt'          = '[Enter/S] Reiniciar como administrador (recomendado)   [N] Continuar só com seus arquivos'
        'Elevate.Cancelled'       = 'A permissão de administrador não foi concedida. Continuando só com seus arquivos.'
        'Elevate.Failed'          = 'Não foi possível reiniciar como administrador ({0}). Continuando só com seus arquivos.'
        'Elevate.Done'            = 'A limpeza foi executada na janela de administrador.'
        'Elevate.StillUser'       = 'Ainda sem privilégios de administrador; os itens que precisam deles serão ignorados.'
        'Elevate.TargetRejected'  = 'A pasta de usuário recebida do iniciador não foi aceita; usando as pastas desta conta.'
        'Scan.Title'              = 'Analisando'
        'Section.Safe'            = 'LIMPEZA SEGURA · recomendada'
        'Section.Advanced'        = 'AVANÇADA · opcional — leia cada observação'
        'Row.Files'               = '{0} arquivos'
        'Row.File'                = '1 arquivo'
        'Row.Items'               = '{0} itens'
        'Row.Item'                = '1 item'
        'State.Empty'             = 'nada para limpar'
        'State.NeedsAdmin'        = 'requer administrador'
        'State.Unavailable'       = 'indisponível neste PC'
        'State.Deferred'          = 'o tamanho é verificado pelo Windows na limpeza'
        'State.Aborted'           = 'ignorado por segurança'
        'State.BlockedProcess'    = '{0} aberto — feche para incluir'
        'State.RebootPending'     = 'reinicie o Windows primeiro'
        'State.Small'             = 'pequeno — o Windows já gerencia'
        'State.OtherUser'         = 'disponível só para a conta conectada'
        'Note.PartialAdmin'       = 'alguns locais requerem administrador'
        'Note.Blocked'            = '{0} aberto — o cache dele será ignorado'
        'Note.Aborted'            = 'Uma pasta apontou para um local protegido ({0}). Nada nesta categoria será tocado.'
        'Total.Selected'          = 'Selecionado'
        'Total.Advanced'          = 'Disponível nas opções avançadas'
        'Total.Kept'              = 'Mantidos por segurança: {0} arquivos recentes ({1}) — podem estar em uso'
        'Menu.Clean'              = 'Limpar selecionados'
        'Menu.Simulate'           = 'Simular'
        'Menu.Toggle'             = 'Marcar/desmarcar'
        'Menu.Advanced'           = 'Opções avançadas'
        'Menu.Quit'               = 'Sair'
        'Menu.Prompt'             = 'Opção'
        'Menu.Invalid'            = 'Não reconhecido: {0}'
        'Menu.NotSelectable'      = '{0}: {1}'
        'Confirm.RecycleBin'      = 'Esvaziar a Lixeira? {0} ({1} itens) serão apagados permanentemente. [S/N]'
        'Confirm.ComponentStore'  = 'A limpeza de componentes do Windows pode levar de 5 a 30 minutos. Selecionar? [S/N]'
        'Confirm.NotInteractive'  = 'A entrada não é interativa. Use -Yes para limpar sem perguntas.'
        'Nothing.Selected'        = 'Nada selecionado. Nenhuma alteração foi feita.'
        'Quit'                    = 'Nenhuma alteração foi feita.'
        'Clean.Title'             = 'Limpando'
        'Clean.Simulating'        = 'Simulando'
        'Clean.DismAnalyze'       = 'O Windows está analisando o repositório de componentes'
        'Clean.DismCleanup'       = 'O Windows está limpando o repositório de componentes — pode demorar'
        'Result.Freed'            = '{0} liberados'
        'Result.WouldFree'        = '{0} seriam liberados'
        'Result.Approx'           = 'cerca de {0} liberados'
        'Result.Nothing'          = 'nada removido'
        'Result.NotRecommended'   = 'o Windows informa que não há limpeza necessária'
        'Result.Recommended'      = 'o Windows recomenda a limpeza ({0} pacotes recuperáveis)'
        'Result.DismFailed'       = 'o DISM falhou (código {0})'
        'Result.DismBusy'         = 'o Windows está ocupado com manutenção ou precisa reiniciar; tente após reiniciar'
        'Result.RestartAdvised'   = 'reinicie o Windows para concluir'
        'Result.RecycleFailed'    = 'o Windows não conseguiu esvaziar a Lixeira (0x{0:X8})'
        'Result.DoFailed'         = 'a Otimização de Entrega recusou o pedido: {0}'
        'Result.Blocked'          = '{0} foi aberto — ignorado'
        'Summary.Done'            = 'Limpeza concluída em {0}'
        'Summary.DryRun'          = 'Simulação concluída em {0} — nada foi apagado'
        'Summary.Recovered'       = 'Espaço recuperado'
        'Summary.WouldRecover'    = 'Seria recuperado'
        'Summary.FilesRemoved'    = 'Arquivos removidos'
        'Summary.FilesWould'      = 'Arquivos que seriam removidos'
        'Summary.DirsRemoved'     = 'Pastas vazias removidas'
        'Summary.InUse'           = 'Ignorados — em uso'
        'Summary.Denied'          = 'Ignorados — acesso negado'
        'Summary.Recent'          = 'Mantidos — recentes'
        'Summary.Links'           = 'Ignorados — links (nunca seguidos)'
        'Summary.Pending'         = 'Liberados quando o app fechar'
        'Summary.LongPath'        = 'Ignorados — caminho longo demais'
        'Summary.Errors'          = 'Erros inesperados'
        'Summary.FreeSpace'       = 'Espaço livre em {0}'
        'Summary.Largest'         = 'Maiores itens'
        'Summary.Log'             = 'Log'
        'Summary.LogFailed'       = 'Não foi possível gravar o log: {0}'
        'Summary.Tip'             = 'Dica: o Sensor de Armazenamento (Configurações > Sistema > Armazenamento) controla os temporários automaticamente.'
        'Pause'                   = 'Pressione Enter para fechar'
        'List.Safe'               = 'Segura (pré-selecionada)'
        'List.Advanced'           = 'Avançada (opcional)'
        'List.Admin'              = 'requer administrador'
        'Cat.UserTemp.Name'             = 'Arquivos temporários (sua conta)'
        'Cat.UserTemp.Note'             = 'Arquivos com mais de 24 horas em %TEMP%'
        'Cat.WindowsTemp.Name'          = 'Arquivos temporários do Windows'
        'Cat.WindowsTemp.Note'          = 'Arquivos com mais de 3 dias na pasta Temp do Windows'
        'Cat.StoreAppTemp.Name'         = 'Temporários de apps da Microsoft Store'
        'Cat.StoreAppTemp.Note'         = 'Pastas temporárias dos apps da Store, com mais de 24 horas'
        'Cat.DeliveryOptimization.Name' = 'Cache da Otimização de Entrega'
        'Cat.DeliveryOptimization.Note' = 'Downloads de atualizações guardados para compartilhar; removidos pelo próprio Windows'
        'Cat.RecycleBin.Name'           = 'Lixeira'
        'Cat.RecycleBin.Note'           = 'Os itens apagados não poderão mais ser restaurados'
        'Cat.CrashDumps.Name'           = 'Despejos de falha e relatórios antigos'
        'Cat.CrashDumps.Note'           = 'Só com mais de 30 dias; os recentes ficam para diagnóstico'
        'Cat.BrowserCache.Name'         = 'Cache dos navegadores'
        'Cat.BrowserCache.Note'         = 'Só o cache: logins, cookies, histórico e favoritos são mantidos. Sites carregam mais devagar no início'
        'Cat.ShaderCache.Name'          = 'Cache de shaders DirectX e GPU'
        'Cat.ShaderCache.Note'          = 'Jogos podem engasgar por um tempo enquanto os shaders são recompilados'
        'Cat.ComponentStore.Name'       = 'Limpeza de componentes (DISM)'
        'Cat.ComponentStore.Note'       = 'Lento (5-30 min). Remove componentes substituídos por atualizações; nunca usa /ResetBase'
    }
}

function Get-UiText {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Key,

        [object[]]$Arguments = @()
    )

    $language = 'en'
    if ($script:Ui) { $language = $script:Ui.Language }

    $table = $script:Text[$language]
    $template = $table[$Key]
    if ($null -eq $template) { $template = $script:Text['en'][$Key] }
    if ($null -eq $template) { $template = $Key }

    if ($Arguments.Count -eq 0) { return $template }
    return [string]::Format([Globalization.CultureInfo]::CurrentCulture, $template, $Arguments)
}

#endregion

#region Native helpers

$script:NativeSource = @'
using System;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace CleanWinTemp
{
    public static class NativeV2
    {
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern uint GetLongPathNameW(string shortPath, StringBuilder longPath, uint bufferLength);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern SafeFileHandle CreateFileW(string name, uint access, uint share, IntPtr security,
            uint disposition, uint flags, IntPtr template);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern uint GetFinalPathNameByHandleW(SafeFileHandle handle, StringBuilder path, uint length, uint flags);

        [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
        private static extern int SHQueryRecycleBinW(string rootPath, IntPtr info);

        [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
        private static extern int SHEmptyRecycleBinW(IntPtr window, string rootPath, uint flags);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern uint GetConsoleProcessList(uint[] processList, uint count);

        public static string GetLongPath(string path)
        {
            var buffer = new StringBuilder(1024);
            uint length = GetLongPathNameW(path, buffer, (uint)buffer.Capacity);
            if (length == 0) return null;
            if (length > buffer.Capacity)
            {
                buffer = new StringBuilder((int)length);
                length = GetLongPathNameW(path, buffer, (uint)buffer.Capacity);
                if (length == 0) return null;
            }
            return buffer.ToString();
        }

        // Resolves junctions, symbolic links and mount points of the path and all its parents.
        public static string GetFinalPath(string path)
        {
            const uint ShareAll = 0x7;                 // read | write | delete
            const uint OpenExisting = 3;
            const uint BackupSemantics = 0x02000000;  // required to open directories
            using (SafeFileHandle handle = CreateFileW(path, 0, ShareAll, IntPtr.Zero, OpenExisting, BackupSemantics, IntPtr.Zero))
            {
                if (handle.IsInvalid) return null;
                var buffer = new StringBuilder(1024);
                uint length = GetFinalPathNameByHandleW(handle, buffer, (uint)buffer.Capacity, 0);
                if (length == 0) return null;
                if (length >= buffer.Capacity)
                {
                    buffer = new StringBuilder((int)length + 1);
                    length = GetFinalPathNameByHandleW(handle, buffer, (uint)buffer.Capacity, 0);
                    if (length == 0) return null;
                }
                return buffer.ToString();
            }
        }

        // SHQUERYRBINFO is packed to 1 byte on x86 and 8 bytes on x64, so it is marshaled by hand.
        public static long[] QueryRecycleBin()
        {
            int size = IntPtr.Size == 8 ? 24 : 20;
            int offset = IntPtr.Size == 8 ? 8 : 4;
            IntPtr info = Marshal.AllocHGlobal(24);
            try
            {
                for (int i = 0; i < 24; i++) Marshal.WriteByte(info, i, 0);
                Marshal.WriteInt32(info, 0, size);
                if (SHQueryRecycleBinW(null, info) != 0) return null;
                return new long[] { Marshal.ReadInt64(info, offset), Marshal.ReadInt64(info, offset + 8) };
            }
            finally
            {
                Marshal.FreeHGlobal(info);
            }
        }

        public static int EmptyRecycleBin()
        {
            const uint NoConfirmation = 0x1, NoProgressUi = 0x2, NoSound = 0x4;
            return SHEmptyRecycleBinW(IntPtr.Zero, null, NoConfirmation | NoProgressUi | NoSound);
        }

        public static int ConsoleProcessCount()
        {
            var list = new uint[16];
            return (int)GetConsoleProcessList(list, (uint)list.Length);
        }
    }
}
'@

function Test-IsWindowsHost {
    return [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT
}

function Initialize-Native {
    if ($null -ne $script:NativeReady) { return $script:NativeReady }

    $script:NativeReady = $false
    if (-not (Test-IsWindowsHost)) { return $false }

    try {
        if (-not ('CleanWinTemp.NativeV2' -as [type])) {
            Add-Type -TypeDefinition $script:NativeSource -Language CSharp -ErrorAction Stop
        }
        $script:NativeReady = $true
    }
    catch {
        $script:NativeReady = $false
    }
    return $script:NativeReady
}

#endregion

#region Formatting

function Format-ByteSize {
    param(
        [long]$Bytes,
        [IFormatProvider]$Culture = [Globalization.CultureInfo]::CurrentCulture
    )

    if ($Bytes -lt 1024) { return [string]::Format($Culture, '{0:N0} B', $Bytes) }

    $units = @('KB', 'MB', 'GB', 'TB', 'PB')
    $value = [double]$Bytes
    $index = -1
    do {
        $value = $value / 1024
        $index++
    } while ($value -ge 1024 -and $index -lt ($units.Count - 1))

    $pattern = '{0:N1} {1}'
    if ($index -ge 2) { $pattern = '{0:N2} {1}' }
    elseif ($value -ge 100) { $pattern = '{0:N0} {1}' }
    return [string]::Format($Culture, $pattern, $value, $units[$index])
}

function Format-Count {
    param([long]$Value)
    return $Value.ToString('N0', [Globalization.CultureInfo]::CurrentCulture)
}

function Format-Duration {
    param([TimeSpan]$Duration)
    if ($Duration.TotalSeconds -lt 60) {
        return [string]::Format([Globalization.CultureInfo]::CurrentCulture, '{0:N1} s', $Duration.TotalSeconds)
    }
    return '{0}:{1:00} min' -f [int][Math]::Floor($Duration.TotalMinutes), $Duration.Seconds
}

#endregion

#region Path safety (pure functions, no file system access)

function ConvertTo-CanonicalPath {
    <#
        Returns an absolute, normalized path or $null when the input is not an acceptable
        absolute local path. Rejects: empty values, unresolved %VARIABLES%, wildcards,
        quotes, relative paths, drive-relative paths (C:foo), UNC and \\?\ device paths,
        alternate data streams and '..' escaping above the root. Trailing dots and spaces
        are stripped from each segment, exactly as Win32 does.
    #>
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }

    $value = $Path.Trim()
    if ($value.IndexOfAny([char[]]'%"*?<>|') -ge 0) { return $null }
    foreach ($character in $value.ToCharArray()) {
        if ([int]$character -lt 32) { return $null }
    }

    if ($value -match '^[A-Za-z]:[\\/]') {
        $prefix = $value.Substring(0, 2).ToUpperInvariant() + '\'
        $rest = $value.Substring(3)
        $separator = '\'
        $splitChars = [char[]]@('\', '/')
    }
    elseif ($value.StartsWith('/') -and -not (Test-IsWindowsHost)) {
        # Only used by the test-suite on non-Windows hosts.
        $prefix = '/'
        $rest = $value.Substring(1)
        $separator = '/'
        $splitChars = [char[]]@('/')
    }
    else {
        return $null
    }

    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($segment in $rest.Split($splitChars)) {
        if ($segment -eq '' -or $segment -eq '.') { continue }
        if ($segment -eq '..') {
            if ($parts.Count -eq 0) { return $null }
            $parts.RemoveAt($parts.Count - 1)
            continue
        }
        $clean = $segment
        if ($separator -eq '\') { $clean = $segment.TrimEnd('.', ' ') }
        if ($clean -eq '') { return $null }
        if ($separator -eq '\' -and $clean.Contains(':')) { return $null }
        $parts.Add($clean)
    }

    return $prefix + ($parts -join $separator)
}

function Get-PathSeparator {
    param([string]$Path)
    if ($Path -match '^[A-Za-z]:\\') { return '\' }
    return '/'
}

function Test-PathEqual {
    param([string]$Left, [string]$Right)
    if ($null -eq $Left -or $null -eq $Right) { return $false }
    return [string]::Equals($Left, $Right, [StringComparison]::OrdinalIgnoreCase)
}

function Test-PathIsSameOrUnder {
    # True when $Path equals $Parent or lies inside it. Both must be canonical.
    param([string]$Path, [string]$Parent)

    if ([string]::IsNullOrEmpty($Path) -or [string]::IsNullOrEmpty($Parent)) { return $false }
    if (Test-PathEqual $Path $Parent) { return $true }

    $separator = Get-PathSeparator $Parent
    $prefix = $Parent
    if (-not $prefix.EndsWith($separator)) { $prefix += $separator }
    return $Path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)
}

function Test-IsDriveRoot {
    param([string]$Path)
    return ($Path -match '^[A-Za-z]:\\$') -or ($Path -eq '/')
}

function Get-PathSegment {
    # Folder names after the drive (C:\a\b -> a, b).
    param([string]$Path)
    $separator = Get-PathSeparator $Path
    $segments = @($Path.Split([char[]]@($separator), [StringSplitOptions]::RemoveEmptyEntries))
    if ($separator -eq '\') { return @($segments | Select-Object -Skip 1) }
    return $segments
}

function Test-HasTempSegment {
    param([string]$Path)
    foreach ($segment in (Get-PathSegment $Path)) {
        if ($segment -ieq 'Temp' -or $segment -ieq 'Tmp') { return $true }
    }
    return $false
}

function Test-HasShortNameSegment {
    # 8.3 aliases (PROGRA~1) would let a protected folder hide behind another spelling.
    param([string]$Path)
    foreach ($segment in (Get-PathSegment $Path)) {
        if ($segment -match '~\d') { return $true }
    }
    return $false
}

function Join-PathSafe {
    # Null-propagating join that never touches the file system or PowerShell drives.
    param([string]$Base, [string]$Child)
    if ([string]::IsNullOrWhiteSpace($Base)) { return $null }
    $separator = Get-PathSeparator $Base
    return $Base.TrimEnd('\', '/') + $separator + $Child
}

function New-ProtectionPolicy {
    <#
        Builds the protection lists from an environment description (see Get-HostEnvironment).
        Critical : a cleanup root may be INSIDE these, but never equal to them or above them.
        NoTouch  : a cleanup root may not be equal to, inside, or above these.
        Drive roots are always rejected. Well-known top-level Windows folders are protected on
        the system drive, on the drive that holds %SystemRoot% and on C: even when the
        environment variables are missing or wrong.
    #>
    param([Parameter(Mandatory = $true)][hashtable]$Environment)

    $critical = New-Object System.Collections.Generic.List[string]
    $noTouch = New-Object System.Collections.Generic.List[string]

    $add = {
        param($List, $Value)
        foreach ($item in @($Value)) {
            $canonical = ConvertTo-CanonicalPath ([string]$item)
            if ($canonical -and -not $List.Contains($canonical)) { $List.Add($canonical) }
        }
    }

    $drives = New-Object System.Collections.Generic.List[string]
    foreach ($candidate in @($Environment['SystemDrive'], $Environment['SystemRoot'], 'C:')) {
        if ([string]$candidate -match '^([A-Za-z]:)') {
            $drive = $Matches[1].ToUpperInvariant()
            if (-not $drives.Contains($drive)) { $drives.Add($drive) }
        }
    }

    $windowsFolders = New-Object System.Collections.Generic.List[string]
    & $add $windowsFolders $Environment['SystemRoot']
    foreach ($drive in $drives) {
        & $add $windowsFolders "$drive\Windows"
        foreach ($name in @('Windows', 'Users', 'ProgramData', 'Documents and Settings', 'PerfLogs')) {
            & $add $critical "$drive\$name"
        }
        foreach ($name in @('Program Files', 'Program Files (x86)', 'Recovery', 'System Volume Information',
                '$Recycle.Bin', 'Windows.old', '$WINDOWS.~BT', '$WINDOWS.~WS', '$WinREAgent', 'Boot', 'EFI', 'Config.Msi')) {
            & $add $noTouch "$drive\$name"
        }
    }

    foreach ($windows in $windowsFolders) {
        & $add $critical $windows
        foreach ($name in @('System32', 'SysWOW64', 'SysArm32', 'Sysnative', 'WinSxS', 'Installer', 'SoftwareDistribution',
                'Prefetch', 'servicing', 'Boot', 'Fonts', 'assembly', 'Microsoft.NET', 'INF', 'Panther', 'Logs',
                'System', 'CSC', 'Resources', 'ShellExperiences', 'SystemApps', 'WinStore')) {
            & $add $noTouch "$windows\$name"
        }
    }

    foreach ($key in @('ProgramData', 'Public', 'ProfilesDirectory', 'UserProfile', 'LocalAppData', 'OwnLocalAppData')) {
        & $add $critical $Environment[$key]
    }
    & $add $critical $Environment['ProfileRoots']

    foreach ($key in @('ProgramFiles', 'ProgramFilesX86', 'ProgramW6432', 'AppData')) {
        & $add $noTouch $Environment[$key]
    }
    & $add $noTouch $Environment['KnownFolders']

    return [pscustomobject]@{
        Critical = $critical.ToArray()
        NoTouch  = $noTouch.ToArray()
    }
}

function Test-CleanupRootAllowed {
    # Decides whether a folder may be used as a cleanup root. Pure: does not touch the disk.
    param(
        [AllowNull()][AllowEmptyString()][string]$Path,
        [Parameter(Mandatory = $true)]$Policy
    )

    $canonical = ConvertTo-CanonicalPath $Path
    if (-not $canonical) {
        return [pscustomobject]@{ Allowed = $false; Path = $Path; Reason = 'InvalidPath' }
    }
    if (Test-IsDriveRoot $canonical) {
        return [pscustomobject]@{ Allowed = $false; Path = $canonical; Reason = 'DriveRoot' }
    }
    foreach ($protected in $Policy.Critical) {
        if (Test-PathIsSameOrUnder -Path $protected -Parent $canonical) {
            return [pscustomobject]@{ Allowed = $false; Path = $canonical; Reason = 'ProtectedLocation' }
        }
    }
    foreach ($protected in $Policy.NoTouch) {
        if ((Test-PathIsSameOrUnder -Path $canonical -Parent $protected) -or (Test-PathIsSameOrUnder -Path $protected -Parent $canonical)) {
            return [pscustomobject]@{ Allowed = $false; Path = $canonical; Reason = 'ProtectedLocation' }
        }
    }
    return [pscustomobject]@{ Allowed = $true; Path = $canonical; Reason = $null }
}

function Test-CleanupFileAllowed {
    # Single-file targets (MEMORY.DMP) live directly in protected folders, so they get their own rule.
    param(
        [AllowNull()][AllowEmptyString()][string]$Path,
        [Parameter(Mandatory = $true)]$Policy
    )

    $canonical = ConvertTo-CanonicalPath $Path
    if (-not $canonical -or (Test-IsDriveRoot $canonical)) {
        return [pscustomobject]@{ Allowed = $false; Path = $Path; Reason = 'InvalidPath' }
    }
    $leaf = @(Get-PathSegment $canonical)[-1]
    if ($script:AllowedSingleFiles -notcontains $leaf) {
        return [pscustomobject]@{ Allowed = $false; Path = $canonical; Reason = 'NotAllowedFile' }
    }
    foreach ($protected in $Policy.Critical) {
        if (Test-PathIsSameOrUnder -Path $protected -Parent $canonical) {
            return [pscustomobject]@{ Allowed = $false; Path = $canonical; Reason = 'ProtectedLocation' }
        }
    }
    foreach ($protected in $Policy.NoTouch) {
        if (Test-PathIsSameOrUnder -Path $canonical -Parent $protected) {
            return [pscustomobject]@{ Allowed = $false; Path = $canonical; Reason = 'ProtectedLocation' }
        }
    }
    return [pscustomobject]@{ Allowed = $true; Path = $canonical; Reason = $null }
}

#endregion

#region Environment

function Get-RegistryValue {
    param([string]$Path, [string]$Name)
    try {
        $item = Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction Stop
        return $item.$Name
    }
    catch {
        return $null
    }
}

function Get-ProfileRoot {
    $roots = New-Object System.Collections.Generic.List[string]
    try {
        $keys = Get-ChildItem -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList' -ErrorAction Stop
        foreach ($key in $keys) {
            $value = Get-RegistryValue -Path $key.PSPath -Name 'ProfileImagePath'
            if ($value) { $roots.Add([string]$value) }
        }
    }
    catch {
        Write-Verbose "Profile list unavailable: $($_.Exception.Message)"
    }
    return $roots.ToArray()
}

function Test-TargetLocalAppData {
    # The elevated child receives the caller's %LOCALAPPDATA%. Accept it only if it is
    # exactly <ProfileImagePath>\AppData\Local of a registered profile and is not a link.
    param([string]$Path, [string[]]$ProfileRoots)

    $canonical = ConvertTo-CanonicalPath $Path
    if (-not $canonical) { return $null }

    $matched = $false
    foreach ($root in $ProfileRoots) {
        $expected = ConvertTo-CanonicalPath (Join-PathSafe $root 'AppData\Local')
        if (Test-PathEqual $expected $canonical) { $matched = $true; break }
    }
    if (-not $matched) { return $null }
    if (-not [IO.Directory]::Exists($canonical)) { return $null }
    if ([IO.File]::GetAttributes($canonical) -band [IO.FileAttributes]::ReparsePoint) { return $null }
    return $canonical
}

function Get-HostEnvironment {
    param([string]$TargetLocalAppData)

    $ownLocal = [Environment]::GetFolderPath('LocalApplicationData')
    $localAppData = $ownLocal
    $otherUser = $false
    $targetRejected = $false
    $profileRoots = @(Get-ProfileRoot)

    if ($TargetLocalAppData) {
        $accepted = Test-TargetLocalAppData -Path $TargetLocalAppData -ProfileRoots $profileRoots
        if (-not $accepted) {
            $targetRejected = $true
        }
        elseif (-not (Test-PathEqual $accepted (ConvertTo-CanonicalPath $ownLocal))) {
            $localAppData = $accepted
            $otherUser = $true
        }
    }

    $downloads = Get-RegistryValue -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Shell Folders' -Name '{374DE290-123F-4565-9164-39C4925E467B}'
    if (-not $downloads) { $downloads = Join-PathSafe $env:USERPROFILE 'Downloads' }

    $knownFolders = @(
        [Environment]::GetFolderPath('Desktop'),
        [Environment]::GetFolderPath('MyDocuments'),
        [Environment]::GetFolderPath('MyPictures'),
        [Environment]::GetFolderPath('MyVideos'),
        [Environment]::GetFolderPath('MyMusic'),
        [Environment]::GetFolderPath('Favorites'),
        $downloads,
        $env:OneDrive,
        $env:OneDriveConsumer,
        $env:OneDriveCommercial
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

    $systemRoot = $env:SystemRoot
    if (-not $systemRoot) { $systemRoot = [Environment]::GetFolderPath('Windows') }

    return @{
        SystemRoot        = $systemRoot
        SystemDrive       = $env:SystemDrive
        ProgramFiles      = $env:ProgramFiles
        ProgramFilesX86   = ${env:ProgramFiles(x86)}
        ProgramW6432      = $env:ProgramW6432
        ProgramData       = $env:ProgramData
        Public            = $env:PUBLIC
        UserProfile       = $env:USERPROFILE
        AppData           = $env:APPDATA
        LocalAppData      = $localAppData
        OwnLocalAppData   = $ownLocal
        OtherUser         = $otherUser
        TargetRejected    = $targetRejected
        ProfilesDirectory = Get-RegistryValue -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList' -Name 'ProfilesDirectory'
        ProfileRoots      = $profileRoots
        KnownFolders      = @($knownFolders)
        TempCandidates    = @([IO.Path]::GetTempPath(), $env:TEMP, $env:TMP)
    }
}

function Get-WindowsInfo {
    $key = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $build = 0
    [void][int]::TryParse([string](Get-RegistryValue $key 'CurrentBuildNumber'), [ref]$build)
    if ($build -eq 0) { $build = [Environment]::OSVersion.Version.Build }

    $ubr = Get-RegistryValue $key 'UBR'
    $displayVersion = Get-RegistryValue $key 'DisplayVersion'
    if (-not $displayVersion) { $displayVersion = Get-RegistryValue $key 'ReleaseId' }
    $productName = [string](Get-RegistryValue $key 'ProductName')
    $installationType = [string](Get-RegistryValue $key 'InstallationType')

    $isServer = $installationType -eq 'Server' -or $productName -match 'Server'
    $family = 'Windows'
    if ($build -ge 22000) { $family = 'Windows 11' } elseif ($build -ge 10240) { $family = 'Windows 10' }

    # ProductName still says "Windows 10" on Windows 11.
    $name = $productName
    if (-not $name) { $name = $family }
    if (-not $isServer -and $build -ge 22000) { $name = $name -replace '^Windows 10', 'Windows 11' }

    $buildText = [string]$build
    if ($null -ne $ubr) { $buildText = '{0}.{1}' -f $build, $ubr }

    return [pscustomobject]@{
        Name           = $name
        DisplayVersion = [string]$displayVersion
        Build          = $build
        BuildText      = $buildText
        IsServer       = $isServer
        Supported      = ([Environment]::OSVersion.Version.Major -eq 10) -and ($build -ge 10240)
        Architecture   = $(if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { [string]$env:PROCESSOR_ARCHITECTURE })
    }
}

function Test-IsAdministrator {
    try {
        $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    catch {
        return $false
    }
}

function ConvertFrom-PendingRenameValue {
    # Entries look like "\??\C:\dir\file", "!\??\C:\dir\file" or "" (delete). Sources and
    # destinations are both kept: either may be needed by the operation at restart.
    param([string[]]$Entries)
    $set = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in $Entries) {
        if ([string]::IsNullOrWhiteSpace($entry)) { continue }
        $path = $entry.TrimStart('!')
        if ($path.StartsWith('\??\')) { $path = $path.Substring(4) }
        $canonical = ConvertTo-CanonicalPath $path
        if ($canonical) { [void]$set.Add($canonical) }
    }
    return , $set
}

function Get-PendingRenameSet {
    # Files scheduled to be moved or replaced at the next restart must survive until then.
    $key = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager'
    $entries = New-Object System.Collections.Generic.List[string]
    foreach ($name in @('PendingFileRenameOperations', 'PendingFileRenameOperations2')) {
        foreach ($entry in @(Get-RegistryValue -Path $key -Name $name)) {
            if ($null -ne $entry) { $entries.Add([string]$entry) }
        }
    }
    return ConvertFrom-PendingRenameValue -Entries $entries.ToArray()
}

function Test-RebootPending {
    return (Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') -or
        (Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')
}

function Get-RunningProcessSet {
    $set = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($process in @(Get-Process -ErrorAction SilentlyContinue)) {
        [void]$set.Add($process.ProcessName)
    }
    return , $set
}

function Get-FreeSpace {
    param([string]$Drive)
    try {
        return (New-Object IO.DriveInfo($Drive)).AvailableFreeSpace
    }
    catch {
        return $null
    }
}

function Get-SystemToolPath {
    # A 32-bit host on 64-bit Windows must use Sysnative to reach the real System32.
    param([string]$RelativePath)
    $systemRoot = $env:SystemRoot
    if (-not $systemRoot) { return $null }
    if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
        $sysnative = Join-PathSafe $systemRoot "Sysnative\$RelativePath"
        if ([IO.File]::Exists($sysnative)) { return $sysnative }
    }
    return Join-PathSafe $systemRoot "System32\$RelativePath"
}

function New-RunContext {
    param([bool]$IsAdmin, [string]$TargetLocalAppData)

    $environment = Get-HostEnvironment -TargetLocalAppData $TargetLocalAppData
    return [pscustomobject]@{
        IsAdmin          = $IsAdmin
        Environment      = $environment
        Policy           = New-ProtectionPolicy -Environment $environment
        LocalAppData     = $environment.LocalAppData
        OtherUser        = [bool]$environment.OtherUser
        WindowsTempRoot  = ConvertTo-CanonicalPath (Join-PathSafe $environment.SystemRoot 'Temp')
        PendingFiles     = Get-PendingRenameSet
        RebootPending    = Test-RebootPending
        ReferenceTimeUtc = [datetime]::UtcNow
        RunningProcesses = Get-RunningProcessSet
    }
}

#endregion

#region Categories and targets

function New-CleanupTarget {
    param(
        [string]$Path,
        [ValidateSet('Tree', 'File')]
        [string]$Kind = 'Tree',
        [string[]]$Include = @('*'),
        [bool]$Recurse = $true,
        [bool]$RemoveEmptyDirs = $true,
        [double]$MinAgeHours = 24,
        [bool]$RequiresAdmin = $false,
        [bool]$RequireTempName = $false,
        [string[]]$AvoidRoots = @(),
        [string[]]$Guard = @(),
        [string]$GuardName = ''
    )

    return [pscustomobject]@{
        Path            = $Path
        Kind            = $Kind
        Include         = $Include
        Recurse         = $Recurse
        RemoveEmptyDirs = $RemoveEmptyDirs
        MinAgeHours     = $MinAgeHours
        RequiresAdmin   = $RequiresAdmin
        RequireTempName = $RequireTempName
        AvoidRoots      = $AvoidRoots
        Guard           = $Guard
        GuardName       = $GuardName
    }
}

function Get-ChildDirectory {
    # Lists real child directories only (links are skipped).
    param([string]$Path)
    $result = New-Object System.Collections.Generic.List[string]
    if (-not $Path -or -not [IO.Directory]::Exists($Path)) { return $result.ToArray() }
    try {
        foreach ($directory in (New-Object IO.DirectoryInfo($Path)).GetDirectories()) {
            if (-not ($directory.Attributes -band [IO.FileAttributes]::ReparsePoint)) { $result.Add($directory.FullName) }
        }
    }
    catch {
        Write-Verbose "Cannot list ${Path}: $($_.Exception.Message)"
    }
    return $result.ToArray()
}

function Get-UserTempTarget {
    param($Context)

    $hours = $script:MinAgeHours.UserTemp
    $avoid = @($Context.WindowsTempRoot)
    $candidates = @(Join-PathSafe $Context.LocalAppData 'Temp')
    if (-not $Context.OtherUser) { $candidates = @($Context.Environment.TempCandidates) + $candidates }

    foreach ($path in $candidates) {
        if ([string]::IsNullOrWhiteSpace($path)) { continue }
        New-CleanupTarget -Path $path -MinAgeHours $hours -RequireTempName $true -AvoidRoots $avoid
    }
}

function Get-WindowsTempTarget {
    param($Context)
    New-CleanupTarget -Path (Join-PathSafe $Context.Environment.SystemRoot 'Temp') -MinAgeHours $script:MinAgeHours.WindowsTemp -RequiresAdmin $true
}

function Get-StoreAppTempTarget {
    # TempState is ApplicationData.TemporaryFolder: by contract the system may delete it at any time.
    param($Context)
    $hours = $script:MinAgeHours.StoreAppTemp
    foreach ($package in (Get-ChildDirectory (Join-PathSafe $Context.LocalAppData 'Packages'))) {
        foreach ($relative in @('TempState', 'AC\Temp')) {
            $path = Join-PathSafe $package $relative
            if ([IO.Directory]::Exists($path)) { New-CleanupTarget -Path $path -MinAgeHours $hours }
        }
    }
}

function Get-CrashDumpTarget {
    param($Context)
    $hours = $script:MinAgeHours.CrashDumps
    $systemRoot = $Context.Environment.SystemRoot
    $programData = $Context.Environment.ProgramData
    $local = $Context.LocalAppData

    New-CleanupTarget -Kind File -Path (Join-PathSafe $systemRoot 'MEMORY.DMP') -MinAgeHours $hours -RequiresAdmin $true
    New-CleanupTarget -Path (Join-PathSafe $systemRoot 'Minidump') -Include '*.dmp' -RemoveEmptyDirs $false -MinAgeHours $hours -RequiresAdmin $true
    New-CleanupTarget -Path (Join-PathSafe $systemRoot 'LiveKernelReports') -Include '*.dmp' -RemoveEmptyDirs $false -MinAgeHours $hours -RequiresAdmin $true
    New-CleanupTarget -Path (Join-PathSafe $programData 'Microsoft\Windows\WER\ReportArchive') -MinAgeHours $hours -RequiresAdmin $true
    New-CleanupTarget -Path (Join-PathSafe $programData 'Microsoft\Windows\WER\ReportQueue') -MinAgeHours $hours -RequiresAdmin $true
    New-CleanupTarget -Path (Join-PathSafe $local 'CrashDumps') -Include '*.dmp' -RemoveEmptyDirs $false -MinAgeHours $hours
    New-CleanupTarget -Path (Join-PathSafe $local 'Microsoft\Windows\WER\ReportArchive') -MinAgeHours $hours
    New-CleanupTarget -Path (Join-PathSafe $local 'Microsoft\Windows\WER\ReportQueue') -MinAgeHours $hours
}

function Get-BrowserCacheTarget {
    # Only the HTTP cache, the compiled-code cache and the GPU cache. Never cookies, logins,
    # history, bookmarks, Local Storage, IndexedDB or Service Worker storage.
    param($Context)
    $hours = $script:MinAgeHours.BrowserCache
    $local = $Context.LocalAppData

    $chromium = @(
        @{ Name = 'Google Chrome'; Path = 'Google\Chrome\User Data'; Process = @('chrome') },
        @{ Name = 'Microsoft Edge'; Path = 'Microsoft\Edge\User Data'; Process = @('msedge') },
        @{ Name = 'Brave'; Path = 'BraveSoftware\Brave-Browser\User Data'; Process = @('brave') },
        @{ Name = 'Vivaldi'; Path = 'Vivaldi\User Data'; Process = @('vivaldi') },
        @{ Name = 'Chromium'; Path = 'Chromium\User Data'; Process = @('chrome') }
    )
    foreach ($browser in $chromium) {
        foreach ($profileDir in (Get-ChildDirectory (Join-PathSafe $local $browser.Path))) {
            if (-not [IO.File]::Exists((Join-PathSafe $profileDir 'Preferences'))) { continue }
            foreach ($cache in @('Cache', 'Code Cache', 'GPUCache')) {
                $path = Join-PathSafe $profileDir $cache
                if ([IO.Directory]::Exists($path)) {
                    New-CleanupTarget -Path $path -MinAgeHours $hours -RemoveEmptyDirs $false -Guard $browser.Process -GuardName $browser.Name
                }
            }
        }
    }

    foreach ($opera in @('Opera Software\Opera Stable', 'Opera Software\Opera GX Stable')) {
        foreach ($relative in @('Cache', 'Default\Cache')) {
            $path = Join-PathSafe (Join-PathSafe $local $opera) $relative
            if ($path -and [IO.Directory]::Exists($path)) {
                New-CleanupTarget -Path $path -MinAgeHours $hours -RemoveEmptyDirs $false -Guard @('opera') -GuardName 'Opera'
            }
        }
    }

    foreach ($profileDir in (Get-ChildDirectory (Join-PathSafe $local 'Mozilla\Firefox\Profiles'))) {
        $path = Join-PathSafe $profileDir 'cache2'
        if ([IO.Directory]::Exists($path)) {
            New-CleanupTarget -Path $path -MinAgeHours $hours -RemoveEmptyDirs $false -Guard @('firefox') -GuardName 'Firefox'
        }
    }
}

function Get-ShaderCacheTarget {
    param($Context)
    $hours = $script:MinAgeHours.ShaderCache
    $local = $Context.LocalAppData
    $localLow = $null
    if ($local) { $localLow = Join-PathSafe ([IO.Path]::GetDirectoryName($local.TrimEnd('\'))) 'LocalLow' }

    $paths = @(
        (Join-PathSafe $local 'D3DSCache'),
        (Join-PathSafe $local 'NVIDIA\DXCache'),
        (Join-PathSafe $local 'NVIDIA\GLCache'),
        (Join-PathSafe $local 'AMD\DxCache'),
        (Join-PathSafe $local 'AMD\DxcCache'),
        (Join-PathSafe $local 'AMD\GLCache'),
        (Join-PathSafe $local 'AMD\VkCache'),
        (Join-PathSafe $local 'Intel\ShaderCache'),
        (Join-PathSafe $localLow 'NVIDIA\PerDriverVersion\DXCache'),
        (Join-PathSafe $localLow 'NVIDIA\PerDriverVersion\GLCache')
    )
    foreach ($path in $paths) {
        if ($path -and [IO.Directory]::Exists($path)) {
            New-CleanupTarget -Path $path -MinAgeHours $hours -RemoveEmptyDirs $false
        }
    }
}

function Get-CategoryCatalog {
    $definitions = @(
        @{ Id = 'UserTemp'; Group = 'Safe'; Kind = 'Files'; Builder = 'Get-UserTempTarget'; RequiresAdmin = $false },
        @{ Id = 'WindowsTemp'; Group = 'Safe'; Kind = 'Files'; Builder = 'Get-WindowsTempTarget'; RequiresAdmin = $true },
        @{ Id = 'StoreAppTemp'; Group = 'Safe'; Kind = 'Files'; Builder = 'Get-StoreAppTempTarget'; RequiresAdmin = $false },
        @{ Id = 'DeliveryOptimization'; Group = 'Safe'; Kind = 'DeliveryOptimization'; Builder = $null; RequiresAdmin = $true },
        @{ Id = 'RecycleBin'; Group = 'Advanced'; Kind = 'RecycleBin'; Builder = $null; RequiresAdmin = $false },
        @{ Id = 'CrashDumps'; Group = 'Advanced'; Kind = 'Files'; Builder = 'Get-CrashDumpTarget'; RequiresAdmin = $false },
        @{ Id = 'BrowserCache'; Group = 'Advanced'; Kind = 'Files'; Builder = 'Get-BrowserCacheTarget'; RequiresAdmin = $false },
        @{ Id = 'ShaderCache'; Group = 'Advanced'; Kind = 'Files'; Builder = 'Get-ShaderCacheTarget'; RequiresAdmin = $false },
        @{ Id = 'ComponentStore'; Group = 'Advanced'; Kind = 'ComponentStore'; Builder = $null; RequiresAdmin = $true }
    )
    foreach ($definition in $definitions) { [pscustomobject]$definition }
}

#endregion

#region Scanner

function Get-IoFailureKind {
    param([Exception]$Exception)

    # PowerShell wraps .NET exceptions thrown by method calls; look at the original one.
    $current = $Exception
    while ($current -and $current.InnerException -and $current -is [System.Management.Automation.RuntimeException]) {
        $current = $current.InnerException
    }

    if ($current -is [IO.FileNotFoundException] -or $current -is [IO.DirectoryNotFoundException]) { return 'Gone' }
    if ($current -is [IO.PathTooLongException]) { return 'PathTooLong' }
    if ($current -is [UnauthorizedAccessException] -or $current -is [Security.SecurityException]) { return 'AccessDenied' }
    if ($current -is [IO.IOException]) {
        switch ($current.HResult -band 0xFFFF) {
            32 { return 'InUse' }          # ERROR_SHARING_VIOLATION
            33 { return 'InUse' }          # ERROR_LOCK_VIOLATION
            5 { return 'AccessDenied' }
            2 { return 'Gone' }
            3 { return 'Gone' }
            206 { return 'PathTooLong' }
            145 { return 'NotEmpty' }      # ERROR_DIR_NOT_EMPTY
        }
    }
    return 'Error'
}

function Get-EntryTimestampUtc {
    # Newest of creation and last write: a file copied or extracted recently keeps an old
    # LastWriteTime but gets a new CreationTime. LastAccessTime is not reliable on NTFS.
    param([IO.FileSystemInfo]$Entry)
    $stamp = $Entry.LastWriteTimeUtc
    if ($Entry.CreationTimeUtc -gt $stamp) { $stamp = $Entry.CreationTimeUtc }
    return $stamp
}

function Invoke-TreeScan {
    <#
        Iterative, non-recursive walk that never descends into reparse points (junctions,
        symbolic links, mount points, cloud placeholders). Read-only.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$RootPath,
        [string[]]$Include = @('*'),
        [bool]$Recurse = $true,
        [double]$MinAgeHours = 24,
        [datetime]$ReferenceTimeUtc = [datetime]::UtcNow,
        $ProtectedFiles = $null,
        [scriptblock]$OnProgress = $null
    )

    $patterns = @()
    foreach ($pattern in $Include) {
        if ($pattern -and $pattern -ne '*') {
            $patterns += New-Object System.Management.Automation.WildcardPattern($pattern, [System.Management.Automation.WildcardOptions]::IgnoreCase)
        }
    }

    $minAge = [TimeSpan]::FromHours($MinAgeHours)
    $reparse = [IO.FileAttributes]::ReparsePoint
    $directoryFlag = [IO.FileAttributes]::Directory
    $cloud = [int]$script:CloudAttributes
    $checkProtected = $null -ne $ProtectedFiles -and $ProtectedFiles.Count -gt 0

    $files = New-Object System.Collections.Generic.List[System.IO.FileInfo]
    $directories = New-Object System.Collections.Generic.List[object]
    $bytes = 0L; $recentFiles = 0; $recentBytes = 0L; $links = 0; $deniedDirs = 0
    $protectedHits = 0; $cloudFiles = 0; $longPaths = 0; $errors = 0; $seen = 0

    $stack = New-Object System.Collections.Generic.Stack[object]
    $stack.Push(@((New-Object IO.DirectoryInfo($RootPath)), 0))

    while ($stack.Count -gt 0) {
        $frame = $stack.Pop()
        $directory = $frame[0]
        $depth = $frame[1]

        try {
            $entries = $directory.GetFileSystemInfos()
        }
        catch {
            switch (Get-IoFailureKind $_.Exception) {
                'AccessDenied' { $deniedDirs++ }
                'PathTooLong' { $longPaths++ }
                'Gone' { }
                default { $errors++ }
            }
            continue
        }

        foreach ($entry in $entries) {
            $attributes = $entry.Attributes
            if ($attributes -band $reparse) { $links++; continue }

            if ($attributes -band $directoryFlag) {
                if ($Recurse) {
                    $stack.Push(@($entry, ($depth + 1)))
                    $stamp = $entry.LastWriteTimeUtc
                    $created = $entry.CreationTimeUtc
                    if ($created -gt $stamp) { $stamp = $created }
                    $old = ($ReferenceTimeUtc - $stamp) -ge $minAge
                    $directories.Add([pscustomobject]@{ Info = $entry; Depth = $depth + 1; Old = $old })
                }
                continue
            }

            if ([int]$attributes -band $cloud) { $cloudFiles++; continue }

            if ($patterns.Count -gt 0) {
                $matched = $false
                foreach ($pattern in $patterns) { if ($pattern.IsMatch($entry.Name)) { $matched = $true; break } }
                if (-not $matched) { continue }
            }

            if ($checkProtected -and $ProtectedFiles.Contains($entry.FullName)) { $protectedHits++; continue }

            $length = $entry.Length
            $stamp = $entry.LastWriteTimeUtc
            $created = $entry.CreationTimeUtc
            if ($created -gt $stamp) { $stamp = $created }
            if (($ReferenceTimeUtc - $stamp) -lt $minAge) {
                $recentFiles++
                $recentBytes += $length
                continue
            }

            $files.Add($entry)
            $bytes += $length
            $seen++
            if ($OnProgress -and ($seen % 2000) -eq 0) { & $OnProgress $seen $bytes }
        }
    }

    return [pscustomobject]@{
        RootPath         = $RootPath
        MinAgeHours      = $MinAgeHours
        Files            = $files
        Directories      = $directories
        Bytes            = $bytes
        RecentFiles      = $recentFiles
        RecentBytes      = $recentBytes
        Links            = $links
        DeniedDirs       = $deniedDirs
        ProtectedPending = $protectedHits
        CloudFiles       = $cloudFiles
        LongPaths        = $longPaths
        Errors           = $errors
    }
}

function Resolve-CleanupTarget {
    <#
        Validates a target before anything is scanned. Status:
          Ready    - safe to scan/clean, Path is the canonical long path
          NotFound - nothing there, not an error
          Rejected - failed a safety rule; the whole category is aborted
    #>
    param([Parameter(Mandatory = $true)]$Target, [Parameter(Mandatory = $true)]$Policy)

    $reject = { param($Reason, $Where) [pscustomobject]@{ Status = 'Rejected'; Path = $Where; Reason = $Reason } }
    $isFile = $Target.Kind -eq 'File'

    $check = if ($isFile) { Test-CleanupFileAllowed -Path $Target.Path -Policy $Policy } else { Test-CleanupRootAllowed -Path $Target.Path -Policy $Policy }
    if (-not $check.Allowed) { return & $reject $check.Reason $check.Path }
    $path = $check.Path

    if ($Target.RequireTempName -and -not (Test-HasTempSegment $path)) { return & $reject 'NotTempFolder' $path }

    $exists = if ($isFile) { [IO.File]::Exists($path) } else { [IO.Directory]::Exists($path) }
    if (-not $exists) { return [pscustomobject]@{ Status = 'NotFound'; Path = $path; Reason = $null } }

    $native = Initialize-Native
    if ($native) {
        $long = [CleanWinTemp.NativeV2]::GetLongPath($path)
        $longCanonical = ConvertTo-CanonicalPath $long
        if ($longCanonical -and -not [string]::Equals($longCanonical, $path, [StringComparison]::Ordinal)) {
            $check = if ($isFile) { Test-CleanupFileAllowed -Path $longCanonical -Policy $Policy } else { Test-CleanupRootAllowed -Path $longCanonical -Policy $Policy }
            if (-not $check.Allowed) { return & $reject $check.Reason $longCanonical }
            $path = $longCanonical
        }
    }
    if (Test-HasShortNameSegment $path) { return & $reject 'ShortName' $path }

    try {
        if ([IO.File]::GetAttributes($path) -band [IO.FileAttributes]::ReparsePoint) { return & $reject 'Link' $path }
    }
    catch {
        return & $reject 'Unreadable' $path
    }

    if ($native) {
        $final = [CleanWinTemp.NativeV2]::GetFinalPath($path)
        if (-not $final) { return & $reject 'Unresolvable' $path }
        if ($final.StartsWith('\\?\UNC\', [StringComparison]::OrdinalIgnoreCase)) { return & $reject 'NetworkPath' $path }
        if ($final.StartsWith('\\?\')) { $final = $final.Substring(4) }
        $finalCanonical = ConvertTo-CanonicalPath $final
        if (-not $finalCanonical) { return & $reject 'Unresolvable' $path }
        if (-not (Test-PathEqual $finalCanonical $path)) {
            $check = if ($isFile) { Test-CleanupFileAllowed -Path $finalCanonical -Policy $Policy } else { Test-CleanupRootAllowed -Path $finalCanonical -Policy $Policy }
            if (-not $check.Allowed) { return & $reject $check.Reason $finalCanonical }
        }
    }
    elseif (Test-IsWindowsHost) {
        # Without the native resolver, refuse any linked parent.
        $parent = [IO.Path]::GetDirectoryName($path)
        while ($parent) {
            try {
                if ([IO.File]::GetAttributes($parent) -band [IO.FileAttributes]::ReparsePoint) { return & $reject 'Link' $parent }
            }
            catch {
                return & $reject 'Unreadable' $parent
            }
            $parent = [IO.Path]::GetDirectoryName($parent)
        }
    }

    return [pscustomobject]@{ Status = 'Ready'; Path = $path; Reason = $null }
}

function New-CategoryScan {
    param($Category)
    return [pscustomobject]@{
        Category          = $Category
        State             = 'Pending'
        Bytes             = 0L
        Files             = 0
        RecentFiles       = 0
        RecentBytes       = 0L
        Links             = 0
        DeniedDirs        = 0
        ProtectedPending  = 0
        NeedsAdminTargets = 0
        BlockedBy         = New-Object System.Collections.Generic.List[string]
        Trees             = New-Object System.Collections.Generic.List[object]
        Single            = New-Object System.Collections.Generic.List[object]
        AbortReason       = $null
        AbortPath         = $null
        Info              = @{}
        Duration          = [TimeSpan]::Zero
    }
}

function Test-AnyProcessRunning {
    param([string[]]$Names, $RunningProcesses)
    foreach ($name in $Names) {
        if ($RunningProcesses.Contains($name)) { return $true }
    }
    return $false
}

function Invoke-FilesCategoryScan {
    param($Scan, $Context, [scriptblock]$OnProgress)

    $accepted = New-Object System.Collections.Generic.List[object]
    foreach ($target in @(& $Scan.Category.Builder $Context)) {
        if ($null -eq $target) { continue }
        if ($target.RequiresAdmin -and -not $Context.IsAdmin) { $Scan.NeedsAdminTargets++; continue }
        if ($target.Guard.Count -gt 0 -and (Test-AnyProcessRunning $target.Guard $Context.RunningProcesses)) {
            if (-not $Scan.BlockedBy.Contains($target.GuardName)) { $Scan.BlockedBy.Add($target.GuardName) }
            continue
        }

        $resolved = Resolve-CleanupTarget -Target $target -Policy $Context.Policy
        if ($resolved.Status -eq 'NotFound') { continue }
        if ($resolved.Status -eq 'Rejected') {
            # A variable resolved to somewhere unexpected: abort the whole category.
            $Scan.State = 'Aborted'
            $Scan.AbortReason = $resolved.Reason
            $Scan.AbortPath = if ($resolved.Path) { $resolved.Path } else { $target.Path }
            $Scan.Trees.Clear()
            $Scan.Single.Clear()
            return
        }

        $skip = $false
        foreach ($avoid in $target.AvoidRoots) {
            if ($avoid -and (Test-PathIsSameOrUnder -Path $resolved.Path -Parent $avoid)) { $skip = $true }
        }
        if (-not $skip) { $accepted.Add([pscustomobject]@{ Target = $target; Path = $resolved.Path }) }
    }

    # %TEMP%, %TMP% and %LOCALAPPDATA%\Temp usually point to the same place: scan each folder once.
    $unique = New-Object System.Collections.Generic.List[object]
    foreach ($item in ($accepted | Sort-Object { $_.Path.Length })) {
        $nested = $false
        foreach ($kept in $unique) {
            if (Test-PathIsSameOrUnder -Path $item.Path -Parent $kept.Path) { $nested = $true; break }
        }
        if (-not $nested) { $unique.Add($item) }
    }

    foreach ($item in $unique) {
        $target = $item.Target
        if ($target.Kind -eq 'File') {
            $info = New-Object IO.FileInfo($item.Path)
            $age = $Context.ReferenceTimeUtc - (Get-EntryTimestampUtc $info)
            if ($age -lt [TimeSpan]::FromHours($target.MinAgeHours)) {
                $Scan.RecentFiles++
                $Scan.RecentBytes += $info.Length
            }
            else {
                $Scan.Single.Add([pscustomobject]@{ Target = $target; Info = $info })
                $Scan.Files++
                $Scan.Bytes += $info.Length
            }
            continue
        }

        $script:ProgressBaseFiles = $Scan.Files
        $script:ProgressBaseBytes = $Scan.Bytes
        $tree = Invoke-TreeScan -RootPath $item.Path -Include $target.Include -Recurse $target.Recurse `
            -MinAgeHours $target.MinAgeHours -ReferenceTimeUtc $Context.ReferenceTimeUtc `
            -ProtectedFiles $Context.PendingFiles -OnProgress $OnProgress
        $Scan.Trees.Add([pscustomobject]@{ Target = $target; Tree = $tree })
        $Scan.Files += $tree.Files.Count
        $Scan.Bytes += $tree.Bytes
        $Scan.RecentFiles += $tree.RecentFiles
        $Scan.RecentBytes += $tree.RecentBytes
        $Scan.Links += $tree.Links
        $Scan.DeniedDirs += $tree.DeniedDirs
        $Scan.ProtectedPending += $tree.ProtectedPending
    }

    $hasTargets = ($Scan.Trees.Count + $Scan.Single.Count) -gt 0
    if ($Scan.Files -gt 0) { $Scan.State = 'Ready' }
    elseif (-not $hasTargets -and $Scan.NeedsAdminTargets -gt 0) { $Scan.State = 'NeedsAdmin' }
    elseif (-not $hasTargets -and $Scan.BlockedBy.Count -gt 0) { $Scan.State = 'Blocked' }
    else { $Scan.State = 'Empty' }
}

function Get-DeliveryOptimizationCacheSize {
    param($Context)

    try {
        $snapshot = Get-DeliveryOptimizationPerfSnap -ErrorAction Stop -WarningAction SilentlyContinue
        $property = $snapshot.PSObject.Properties['CacheSizeBytes']
        if ($property -and $null -ne $property.Value) { return [long]$property.Value }
    }
    catch {
        Write-Verbose "Delivery Optimization snapshot unavailable: $($_.Exception.Message)"
    }

    # Read-only measurement of the default cache folder. It is never deleted directly.
    $cache = Join-PathSafe $Context.Environment.SystemRoot 'ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization\Cache'
    $check = Test-CleanupRootAllowed -Path $cache -Policy $Context.Policy
    if (-not $check.Allowed -or -not [IO.Directory]::Exists($check.Path)) { return $null }
    return (Invoke-TreeScan -RootPath $check.Path -MinAgeHours 0).Bytes
}

function Test-DeliveryOptimizationAvailable {
    try {
        Import-Module -Name DeliveryOptimization -DisableNameChecking -ErrorAction Stop -WarningAction SilentlyContinue -Verbose:$false
        return [bool](Get-Command -Name 'Delete-DeliveryOptimizationCache' -ErrorAction SilentlyContinue)
    }
    catch {
        return $false
    }
}

function Invoke-CategoryScan {
    param($Category, $Context, [scriptblock]$OnProgress)

    $timer = [Diagnostics.Stopwatch]::StartNew()
    $scan = New-CategoryScan -Category $Category

    try {
        if ($Category.RequiresAdmin -and -not $Context.IsAdmin) {
            $scan.State = 'NeedsAdmin'
        }
        else {
            switch ($Category.Kind) {
                'Files' { Invoke-FilesCategoryScan -Scan $scan -Context $Context -OnProgress $OnProgress }
                'RecycleBin' {
                    if ($Context.OtherUser) { $scan.State = 'OtherUser' }
                    elseif (-not (Initialize-Native)) { $scan.State = 'Unavailable' }
                    else {
                        $info = [CleanWinTemp.NativeV2]::QueryRecycleBin()
                        if ($null -eq $info) { $scan.State = 'Unavailable' }
                        else {
                            $scan.Bytes = [long]$info[0]
                            $scan.Files = [long]$info[1]
                            $scan.State = if ($scan.Files -gt 0) { 'Ready' } else { 'Empty' }
                        }
                    }
                }
                'DeliveryOptimization' {
                    if (-not (Test-DeliveryOptimizationAvailable)) { $scan.State = 'Unavailable' }
                    else {
                        $bytes = Get-DeliveryOptimizationCacheSize -Context $Context
                        if ($null -eq $bytes) { $scan.State = 'Unavailable' }
                        else {
                            $scan.Bytes = $bytes
                            $scan.State = if ($bytes -gt 0) { 'Ready' } else { 'Empty' }
                        }
                    }
                }
                'ComponentStore' {
                    $dism = Get-SystemToolPath 'Dism.exe'
                    if (-not $dism -or -not [IO.File]::Exists($dism)) { $scan.State = 'Unavailable' }
                    elseif ($Context.RebootPending) { $scan.State = 'RebootPending' }
                    else { $scan.State = 'Deferred' }
                }
            }
        }
    }
    catch {
        $scan.State = 'Error'
        $scan.Info['Error'] = $_.Exception.Message
    }

    $timer.Stop()
    $scan.Duration = $timer.Elapsed
    return $scan
}

#endregion

#region Cleaner

function New-CleanResult {
    param($Scan)
    return [pscustomobject]@{
        Scan          = $Scan
        State         = 'Done'
        Message       = $null
        RemovedFiles  = 0L
        RemovedBytes  = 0L
        RemovedDirs   = 0
        InUse         = 0
        AccessDenied  = 0
        Recent        = 0
        Gone          = 0
        Links         = 0
        PathTooLong   = 0
        Pending       = 0
        Errors        = 0
        ErrorSamples  = New-Object System.Collections.Generic.List[string]
        Approximate   = $false
        Largest       = @()
        Duration      = [TimeSpan]::Zero
    }
}

function Add-ErrorSample {
    param($Result, [string]$Message)
    if ($Result.ErrorSamples.Count -lt 10) { $Result.ErrorSamples.Add($Message) }
}

function Test-SafeParentChain {
    # Re-checks, right before deleting, that no folder between the file and the validated
    # root was swapped for a junction or symbolic link after the scan.
    param([string]$Directory, [string]$Root, [hashtable]$Cache)

    if ($Cache.ContainsKey($Directory)) { return $Cache[$Directory] }

    $safe = $true
    if (-not (Test-PathIsSameOrUnder -Path $Directory -Parent $Root)) {
        $safe = $false
    }
    else {
        $current = $Directory
        while ($true) {
            try {
                if ([IO.File]::GetAttributes($current) -band [IO.FileAttributes]::ReparsePoint) { $safe = $false; break }
            }
            catch {
                $safe = $false
                break
            }
            if (Test-PathEqual $current $Root) { break }
            $current = [IO.Path]::GetDirectoryName($current)
            if (-not $current -or -not (Test-PathIsSameOrUnder -Path $current -Parent $Root)) { $safe = $false; break }
        }
    }

    $Cache[$Directory] = $safe
    return $safe
}

function Remove-CandidateFile {
    # Deletes one file after re-validating it. Never forces: locked files are reported, not fought.
    param([IO.FileInfo]$File, [TimeSpan]$MinAge, [datetime]$ReferenceTimeUtc)

    try {
        $File.Refresh()
        if (-not $File.Exists) { return @('Gone', 0L) }
        $attributes = $File.Attributes
    }
    catch {
        return @((Get-IoFailureKind $_.Exception), 0L)
    }

    if ($attributes -band [IO.FileAttributes]::ReparsePoint) { return @('Link', 0L) }
    if ([int]$attributes -band $script:CloudAttributes) { return @('Link', 0L) }
    if (($ReferenceTimeUtc - (Get-EntryTimestampUtc $File)) -lt $MinAge) { return @('Recent', 0L) }

    $path = $File.FullName
    $length = $File.Length
    $readOnly = [bool]($attributes -band [IO.FileAttributes]::ReadOnly)

    try {
        if ($readOnly) { $File.Attributes = [IO.FileAttributes]([int]$attributes -band (-bnot [int][IO.FileAttributes]::ReadOnly)) }
        [IO.File]::Delete($path)
    }
    catch {
        $kind = Get-IoFailureKind $_.Exception
        if ($readOnly) {
            try { $File.Attributes = $attributes } catch { Write-Verbose "Could not restore attributes of $path" }
        }
        if ($kind -eq 'Error') { return @('Error', 0L, $_.Exception.Message) }
        return @($kind, 0L)
    }

    # A file opened with FILE_SHARE_DELETE is only marked for deletion until its last handle closes.
    if ([IO.File]::Exists($path)) { return @('Pending', 0L) }
    return @('Removed', $length)
}

function Add-FileOutcome {
    param($Result, [object[]]$Outcome, [string]$Path)
    switch ($Outcome[0]) {
        'Removed' { $Result.RemovedFiles++; $Result.RemovedBytes += [long]$Outcome[1] }
        'InUse' { $Result.InUse++ }
        'AccessDenied' { $Result.AccessDenied++ }
        'Recent' { $Result.Recent++ }
        'Gone' { $Result.Gone++ }
        'Link' { $Result.Links++ }
        'PathTooLong' { $Result.PathTooLong++ }
        'Pending' { $Result.Pending++ }
        default {
            $Result.Errors++
            $detail = 'unknown error'
            if ($Outcome.Count -gt 2) { $detail = $Outcome[2] }
            Add-ErrorSample $Result ('{0}: {1}' -f (Protect-LogText $Path), (Protect-LogText $detail))
        }
    }
}

function Invoke-TreeClean {
    param(
        $Result,
        $Tree,
        $Target,
        [datetime]$ReferenceTimeUtc,
        [scriptblock]$OnProgress = $null
    )

    $minAge = [TimeSpan]::FromHours($Target.MinAgeHours)
    $chain = @{}
    $count = 0

    foreach ($file in $Tree.Files) {
        $count++
        if ($OnProgress -and ($count % 500) -eq 0) { & $OnProgress $Result }

        if (-not (Test-SafeParentChain -Directory $file.DirectoryName -Root $Tree.RootPath -Cache $chain)) {
            $Result.Links++
            continue
        }
        $outcome = Remove-CandidateFile -File $file -MinAge $minAge -ReferenceTimeUtc $ReferenceTimeUtc
        Add-FileOutcome -Result $Result -Outcome $outcome -Path $file.FullName
    }

    if (-not $Target.RemoveEmptyDirs) { return }

    # Deepest first, never the root, only folders that were already old at scan time.
    foreach ($directory in ($Tree.Directories | Sort-Object -Property Depth -Descending)) {
        if (-not $directory.Old) { continue }
        $info = $directory.Info
        $parent = [IO.Path]::GetDirectoryName($info.FullName)
        if (-not (Test-SafeParentChain -Directory $parent -Root $Tree.RootPath -Cache $chain)) { continue }
        try {
            $info.Refresh()
            if (-not $info.Exists -or ($info.Attributes -band [IO.FileAttributes]::ReparsePoint)) { continue }
            [IO.Directory]::Delete($info.FullName, $false)
            if (-not [IO.Directory]::Exists($info.FullName)) { $Result.RemovedDirs++ }
        }
        catch {
            # Not empty, in use or protected: the folder simply stays.
            Write-Verbose "Kept folder $($info.FullName): $($_.Exception.Message)"
        }
    }
}

function Get-LargestCandidate {
    param($Scan, [int]$Count = 5)
    $all = New-Object System.Collections.Generic.List[System.IO.FileInfo]
    foreach ($entry in $Scan.Trees) { $all.AddRange($entry.Tree.Files) }
    foreach ($entry in $Scan.Single) { $all.Add($entry.Info) }
    return @($all | Sort-Object -Property Length -Descending | Select-Object -First $Count)
}

function Invoke-DeliveryOptimizationClean {
    param($Result, $Context, [switch]$DryRun)
    $before = $Result.Scan.Bytes
    if ($DryRun) {
        $Result.RemovedBytes = $before
        return
    }
    try {
        Delete-DeliveryOptimizationCache -Force -ErrorAction Stop -WarningAction SilentlyContinue | Out-Null
    }
    catch {
        $Result.State = 'Failed'
        $Result.Message = Get-UiText 'Result.DoFailed' @($_.Exception.Message)
        return
    }
    $after = Get-DeliveryOptimizationCacheSize -Context $Context
    if ($null -eq $after) { $after = 0L }
    $Result.RemovedBytes = [Math]::Max(0L, $before - $after)
}

function Invoke-RecycleBinClean {
    param($Result, [switch]$DryRun)
    $scan = $Result.Scan
    if ($DryRun) {
        $Result.RemovedBytes = $scan.Bytes
        $Result.RemovedFiles = $scan.Files
        return
    }
    $hr = [CleanWinTemp.NativeV2]::EmptyRecycleBin()
    $after = [CleanWinTemp.NativeV2]::QueryRecycleBin()
    $afterBytes = 0L; $afterItems = 0L
    if ($null -ne $after) { $afterBytes = [long]$after[0]; $afterItems = [long]$after[1] }
    $Result.RemovedBytes = [Math]::Max(0L, $scan.Bytes - $afterBytes)
    $Result.RemovedFiles = [Math]::Max(0L, $scan.Files - $afterItems)
    if ($hr -ne 0 -and $Result.RemovedFiles -eq 0) {
        $Result.State = 'Failed'
        $Result.Message = Get-UiText 'Result.RecycleFailed' @($hr)
    }
}

function ConvertTo-CommandLineArgument {
    # Quotes one argument following the CommandLineToArgvW rules.
    param([AllowEmptyString()][string]$Value)

    if ($Value -eq '') { return '""' }
    if ($Value -notmatch '[\s"]') { return $Value }

    $builder = New-Object System.Text.StringBuilder
    [void]$builder.Append('"')
    $backslashes = 0
    foreach ($character in $Value.ToCharArray()) {
        if ($character -eq '\') { $backslashes++; continue }
        if ($character -eq '"') {
            [void]$builder.Append('\', (2 * $backslashes + 1))
            [void]$builder.Append('"')
        }
        else {
            if ($backslashes -gt 0) { [void]$builder.Append('\', $backslashes) }
            [void]$builder.Append($character)
        }
        $backslashes = 0
    }
    if ($backslashes -gt 0) { [void]$builder.Append('\', (2 * $backslashes)) }
    [void]$builder.Append('"')
    return $builder.ToString()
}

function Invoke-ExternalTool {
    # Runs a fixed system tool with constant arguments, reporting elapsed time while it works.
    param(
        [string]$FilePath,
        [string[]]$Arguments,
        [scriptblock]$OnTick = $null,
        [string]$TickText = ''
    )

    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = $FilePath
    $startInfo.Arguments = (($Arguments | ForEach-Object { ConvertTo-CommandLineArgument $_ }) -join ' ')
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true

    $process = [Diagnostics.Process]::Start($startInfo)
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    $timer = [Diagnostics.Stopwatch]::StartNew()
    while (-not $process.WaitForExit(1000)) {
        if ($OnTick) { & $OnTick $TickText $timer.Elapsed }
    }
    $process.WaitForExit()

    return [pscustomobject]@{
        ExitCode = $process.ExitCode
        Output   = $stdout.Result + [Environment]::NewLine + $stderr.Result
        Duration = $timer.Elapsed
    }
}

function Invoke-ComponentStoreClean {
    # Uses only the supported DISM servicing commands. /ResetBase is never used, so installed
    # updates can still be uninstalled. /English keeps the output parseable on every language.
    param($Result, $Context, [switch]$DryRun, [scriptblock]$OnTick)

    $dism = Get-SystemToolPath 'Dism.exe'
    $analyze = Invoke-ExternalTool -FilePath $dism -Arguments @('/English', '/Online', '/Cleanup-Image', '/AnalyzeComponentStore') `
        -OnTick $OnTick -TickText (Get-UiText 'Clean.DismAnalyze')

    if ($analyze.ExitCode -ne 0) {
        $Result.State = 'Failed'
        $Result.Message = Get-DismFailureMessage $analyze.ExitCode
        return
    }

    $recommended = $analyze.Output -match 'Component Store Cleanup Recommended\s*:\s*Yes'
    $packages = 0
    if ($analyze.Output -match 'Number of Reclaimable Packages\s*:\s*(\d+)') { $packages = [int]$Matches[1] }

    if (-not $recommended) {
        $Result.State = 'Skipped'
        $Result.Message = Get-UiText 'Result.NotRecommended'
        return
    }
    if ($DryRun) {
        $Result.State = 'Simulated'
        $Result.Message = Get-UiText 'Result.Recommended' @($packages)
        return
    }

    $drive = [IO.Path]::GetPathRoot($Context.Environment.SystemRoot)
    $before = Get-FreeSpace $drive
    $cleanup = Invoke-ExternalTool -FilePath $dism -Arguments @('/English', '/Online', '/Cleanup-Image', '/StartComponentCleanup') `
        -OnTick $OnTick -TickText (Get-UiText 'Clean.DismCleanup')
    $after = Get-FreeSpace $drive

    if ($cleanup.ExitCode -ne 0 -and $cleanup.ExitCode -ne 3010) {
        $Result.State = 'Failed'
        $Result.Message = Get-DismFailureMessage $cleanup.ExitCode
        return
    }
    if ($null -ne $before -and $null -ne $after) { $Result.RemovedBytes = [Math]::Max(0L, $after - $before) }
    $Result.Approximate = $true
    if ($cleanup.ExitCode -eq 3010) { $Result.Message = Get-UiText 'Result.RestartAdvised' }
}

function Get-DismFailureMessage {
    param([int]$ExitCode)
    # 0x800F0806 pending servicing, 0x800F082F reboot pending, 0x800706BE busy RPC.
    if (@(-2146498554, -2146498513, -2147023170) -contains $ExitCode) { return Get-UiText 'Result.DismBusy' }
    return Get-UiText 'Result.DismFailed' @(('0x{0:X8}' -f $ExitCode))
}

function Invoke-CategoryClean {
    param($Scan, $Context, [switch]$DryRun, [scriptblock]$OnProgress = $null, [scriptblock]$OnTick = $null)

    $timer = [Diagnostics.Stopwatch]::StartNew()
    $result = New-CleanResult -Scan $Scan
    if ($DryRun) { $result.State = 'Simulated' }

    try {
        switch ($Scan.Category.Kind) {
            'Files' {
                if ($DryRun) {
                    $result.RemovedFiles = $Scan.Files
                    $result.RemovedBytes = $Scan.Bytes
                    $result.Largest = Get-LargestCandidate -Scan $Scan
                    break
                }
                $running = Get-RunningProcessSet
                foreach ($entry in $Scan.Trees) {
                    $target = $entry.Target
                    if ($target.Guard.Count -gt 0 -and (Test-AnyProcessRunning $target.Guard $running)) {
                        # The browser was opened after the scan: leave its cache alone.
                        $result.Message = Get-UiText 'Result.Blocked' @($target.GuardName)
                        continue
                    }
                    Invoke-TreeClean -Result $result -Tree $entry.Tree -Target $target -ReferenceTimeUtc $Context.ReferenceTimeUtc -OnProgress $OnProgress
                }
                foreach ($entry in $Scan.Single) {
                    $minAge = [TimeSpan]::FromHours($entry.Target.MinAgeHours)
                    $parent = [IO.Path]::GetDirectoryName($entry.Info.FullName)
                    if (-not (Test-SafeParentChain -Directory $parent -Root $parent -Cache @{})) { $result.Links++; continue }
                    $outcome = Remove-CandidateFile -File $entry.Info -MinAge $minAge -ReferenceTimeUtc $Context.ReferenceTimeUtc
                    Add-FileOutcome -Result $result -Outcome $outcome -Path $entry.Info.FullName
                }
            }
            'RecycleBin' { Invoke-RecycleBinClean -Result $result -DryRun:$DryRun }
            'DeliveryOptimization' { Invoke-DeliveryOptimizationClean -Result $result -Context $Context -DryRun:$DryRun }
            'ComponentStore' { Invoke-ComponentStoreClean -Result $result -Context $Context -DryRun:$DryRun -OnTick $OnTick }
        }
    }
    catch {
        $result.State = 'Failed'
        $result.Errors++
        $result.Message = Protect-LogText $_.Exception.Message
        Add-ErrorSample $result (Protect-LogText $_.Exception.Message)
    }

    $timer.Stop()
    $result.Duration = $timer.Elapsed
    return $result
}

#endregion

#region Terminal UI

function Initialize-Ui {
    param([switch]$NoColor, [switch]$Ascii, [string]$Language = 'Auto')

    $redirected = $true
    try { $redirected = [Console]::IsOutputRedirected } catch { $redirected = $true }

    $utf8Console = $false
    try { $utf8Console = [Console]::OutputEncoding.CodePage -eq 65001 } catch { $utf8Console = $false }
    $unicode = (-not $Ascii) -and ([bool]$env:WT_SESSION -or [bool]$env:TERM_PROGRAM -or $env:ConEmuANSI -eq 'ON' -or $utf8Console)

    $selected = $Language
    if ($selected -eq 'Auto') {
        $selected = 'en'
        try { if ((Get-UICulture).TwoLetterISOLanguageName -eq 'pt') { $selected = 'pt' } } catch { $selected = 'en' }
    }

    $width = 78
    if (-not $redirected) {
        try { $width = [Math]::Max(60, [Math]::Min([Console]::WindowWidth - 2, 96)) } catch { $width = 78 }
    }

    $script:Ui = [pscustomobject]@{
        Color        = (-not $NoColor) -and (-not $env:NO_COLOR)
        Unicode      = $unicode
        Language     = $selected
        Width        = $width
        CanOverwrite = -not $redirected
        Ok           = $(if ($unicode) { '✓' } else { '+' })
        Warn         = '!'
        Fail         = $(if ($unicode) { '✗' } else { 'x' })
        Line         = $(if ($unicode) { '─' } else { '-' })
    }
}

function ConvertTo-UiText {
    param([string]$Text)
    if ($null -eq $script:Ui -or $script:Ui.Unicode) { return $Text }
    return $Text.Replace('—', '-').Replace('·', '|').Replace('→', '->').Replace('…', '...').Replace('─', '-').Replace('›', '>')
}

function Write-Ui {
    param([string]$Text = '', [ConsoleColor]$Color = [ConsoleColor]::Gray, [switch]$NoNewline)
    $value = ConvertTo-UiText $Text
    if ($script:Ui -and $script:Ui.Color) {
        Write-Host $value -ForegroundColor $Color -NoNewline:$NoNewline
    }
    else {
        Write-Host $value -NoNewline:$NoNewline
    }
}

function Write-StatusLine {
    param([string]$Text)
    if (-not $script:Ui -or -not $script:Ui.CanOverwrite) { return }
    $value = ConvertTo-UiText $Text
    $width = $script:Ui.Width
    if ($value.Length -gt $width) { $value = $value.Substring(0, $width) }
    try { [Console]::Write("`r" + $value.PadRight($width)) } catch { Write-Verbose 'Status line unavailable' }
}

function Clear-StatusLine {
    if (-not $script:Ui -or -not $script:Ui.CanOverwrite) { return }
    try { [Console]::Write("`r" + (' ' * $script:Ui.Width) + "`r") } catch { Write-Verbose 'Status line unavailable' }
}

function Write-Rule {
    Write-Ui ('  ' + ($script:Ui.Line * ($script:Ui.Width - 4))) DarkGray
}

function Split-TextLine {
    # Word-wraps a note so it stays inside the console width.
    param([string]$Text, [int]$Width)
    $lines = New-Object System.Collections.Generic.List[string]
    $current = ''
    foreach ($word in ($Text -split ' ')) {
        if ($current -and ($current.Length + 1 + $word.Length) -gt $Width) {
            $lines.Add($current)
            $current = $word
        }
        elseif ($current) { $current += ' ' + $word }
        else { $current = $word }
    }
    if ($current) { $lines.Add($current) }
    return $lines.ToArray()
}

function Format-Cell {
    param([string]$Text, [int]$Width, [switch]$Right)
    $value = ConvertTo-UiText $Text
    if ($value.Length -gt $Width) { $value = $value.Substring(0, [Math]::Max(1, $Width - 1)) + '.' }
    if ($Right) { return $value.PadLeft($Width) }
    return $value.PadRight($Width)
}

function Show-Header {
    param($WindowsInfo, [bool]$IsAdmin, [switch]$DryRun, [string[]]$Notes = @())

    Write-Ui ''
    Write-Ui ('  ' + $script:AppName + '  ') White -NoNewline
    Write-Ui $script:AppVersion DarkGray
    $version = $WindowsInfo.Name
    if ($WindowsInfo.DisplayVersion) { $version += ' ' + $WindowsInfo.DisplayVersion }
    $role = if ($IsAdmin) { Get-UiText 'Header.Admin' } else { Get-UiText 'Header.User' }
    Write-Ui ('  {0} · build {1} · {2}' -f $version, $WindowsInfo.BuildText, $role) DarkGray
    if ($DryRun) { Write-Ui ('  ' + (Get-UiText 'Header.DryRun')) Yellow }
    foreach ($note in $Notes) { Write-Ui ('  ' + $script:Ui.Warn + ' ' + $note) Yellow }
    Write-Ui ''
}

function Get-ScanStateText {
    param($Scan)
    switch ($Scan.State) {
        'Empty' { return Get-UiText 'State.Empty' }
        'NeedsAdmin' { return Get-UiText 'State.NeedsAdmin' }
        'Unavailable' { return Get-UiText 'State.Unavailable' }
        'Deferred' { return Get-UiText 'State.Deferred' }
        'Aborted' { return Get-UiText 'State.Aborted' }
        'Blocked' { return Get-UiText 'State.BlockedProcess' @(($Scan.BlockedBy -join ', ')) }
        'RebootPending' { return Get-UiText 'State.RebootPending' }
        'OtherUser' { return Get-UiText 'State.OtherUser' }
        'Error' { return Get-UiText 'Error.Fatal' @($Scan.Info['Error']) }
    }
    return ''
}

function Test-ScanSelectable {
    param($Scan)
    return @('Ready', 'Deferred') -contains $Scan.State
}

function Write-CategoryRow {
    param([int]$Number, $Scan, [bool]$Selected)

    $id = $Scan.Category.Id
    $selectable = Test-ScanSelectable $Scan
    $box = if ($Selected) { '[x]' } else { '[ ]' }
    $name = Get-UiText "Cat.$id.Name"
    $nameWidth = [Math]::Max(36, $script:Ui.Width - 40)

    $size = ''
    $detail = Get-ScanStateText $Scan
    if ($Scan.State -eq 'Ready') {
        $size = Format-ByteSize $Scan.Bytes
        $countKey = if ($Scan.Category.Kind -eq 'RecycleBin') { 'Row.Items' } else { 'Row.Files' }
        if ($Scan.Files -eq 1) { $countKey = $countKey.TrimEnd('s') }
        $detail = ''
        if ($Scan.Category.Kind -ne 'DeliveryOptimization') { $detail = Get-UiText $countKey @((Format-Count $Scan.Files)) }
        elseif ($Scan.Bytes -lt $script:DeliveryOptimizationMinBytes) { $detail = Get-UiText 'State.Small' }
    }

    Write-Ui ('  ' + $box + ' ') $(if ($Selected) { 'Green' } else { 'DarkGray' }) -NoNewline
    Write-Ui ('{0,2}  ' -f $Number) DarkGray -NoNewline
    Write-Ui (Format-Cell $name $nameWidth) $(if ($selectable) { 'White' } else { 'DarkGray' }) -NoNewline
    Write-Ui (Format-Cell $size 11 -Right) Cyan -NoNewline
    Write-Ui ('  ' + $detail) DarkGray

    $notes = New-Object System.Collections.Generic.List[string]
    if ($Scan.Category.Group -eq 'Advanced') { $notes.Add((Get-UiText "Cat.$id.Note")) }
    if ($Scan.State -eq 'Aborted') { $notes.Add((Get-UiText 'Note.Aborted' @((Protect-LogText $Scan.AbortPath)))) }
    if ($Scan.State -ne 'NeedsAdmin' -and $Scan.NeedsAdminTargets -gt 0) { $notes.Add((Get-UiText 'Note.PartialAdmin')) }
    if ($Scan.State -ne 'Blocked' -and $Scan.BlockedBy.Count -gt 0) { $notes.Add((Get-UiText 'Note.Blocked' @(($Scan.BlockedBy -join ', ')))) }
    $color = if ($Scan.State -eq 'Aborted') { 'Yellow' } else { 'DarkGray' }
    foreach ($note in $notes) {
        foreach ($line in (Split-TextLine -Text $note -Width ($script:Ui.Width - 11))) { Write-Ui ('           ' + $line) $color }
    }
}

function Show-Review {
    param($Scans, [hashtable]$Selection, [bool]$AdvancedVisible, [switch]$DryRun, [switch]$Interactive)

    $numbers = @{}
    $number = 0
    $selectedBytes = 0L
    $advancedBytes = 0L
    $recentFiles = 0L
    $recentBytes = 0L

    foreach ($group in @('Safe', 'Advanced')) {
        $groupScans = @($Scans | Where-Object { $_.Category.Group -eq $group })
        if ($groupScans.Count -eq 0) { continue }
        if ($group -eq 'Advanced' -and -not $AdvancedVisible) { continue }

        $title = if ($group -eq 'Safe') { Get-UiText 'Section.Safe' } else { Get-UiText 'Section.Advanced' }
        Write-Ui ('  ' + $title) $(if ($group -eq 'Safe') { 'Green' } else { 'Yellow' })
        foreach ($scan in $groupScans) {
            $number++
            $numbers[$number] = $scan.Category.Id
            $isSelected = [bool]$Selection[$scan.Category.Id]
            Write-CategoryRow -Number $number -Scan $scan -Selected $isSelected
            if ($isSelected) { $selectedBytes += $scan.Bytes }
            elseif ($group -eq 'Advanced' -and $scan.State -eq 'Ready') { $advancedBytes += $scan.Bytes }
            $recentFiles += $scan.RecentFiles
            $recentBytes += $scan.RecentBytes
        }
        Write-Ui ''
    }

    Write-Rule
    $labelWidth = [Math]::Max(36, $script:Ui.Width - 40) + 8
    Write-Ui ('  ' + (Format-Cell (Get-UiText 'Total.Selected') $labelWidth)) White -NoNewline
    Write-Ui (Format-Cell (Format-ByteSize $selectedBytes) 11 -Right) Green
    if ($advancedBytes -gt 0) {
        Write-Ui ('  ' + (Format-Cell (Get-UiText 'Total.Advanced') $labelWidth)) DarkGray -NoNewline
        Write-Ui (Format-Cell (Format-ByteSize $advancedBytes) 11 -Right) DarkGray
    }
    if ($recentFiles -gt 0) {
        Write-Ui ('  ' + (Get-UiText 'Total.Kept' @((Format-Count $recentFiles), (Format-ByteSize $recentBytes)))) DarkGray
    }
    Write-Ui ''

    if ($Interactive) {
        $action = if ($DryRun) { Get-UiText 'Menu.Simulate' } else { Get-UiText 'Menu.Clean' }
        $menu = '  [Enter] {0}   [1-{1}] {2}' -f $action, $number, (Get-UiText 'Menu.Toggle')
        if (-not $AdvancedVisible) { $menu += '   [A] ' + (Get-UiText 'Menu.Advanced') }
        $menu += '   [Q] ' + (Get-UiText 'Menu.Quit')
        Write-Ui $menu Cyan
    }
    return $numbers
}

function Read-YesNo {
    param([string]$Question, [switch]$DefaultYes)
    Write-Ui ('  ' + $Question + ' ') Yellow -NoNewline
    $answer = ([string](Read-Host)).Trim().ToLowerInvariant()
    if ($answer -eq '') { return [bool]$DefaultYes }
    return @('y', 'yes', 's', 'sim') -contains $answer
}

function Show-CleanLine {
    param($Result, [switch]$DryRun)

    $scan = $Result.Scan
    $name = Get-UiText "Cat.$($scan.Category.Id).Name"
    $nameWidth = [Math]::Max(36, $script:Ui.Width - 40)

    $symbol = $script:Ui.Ok
    $color = 'Green'
    $text = ''
    if ($Result.State -eq 'Failed') {
        $symbol = $script:Ui.Fail; $color = 'Red'; $text = $Result.Message
    }
    elseif ($Result.State -eq 'Skipped') {
        $symbol = $script:Ui.Warn; $color = 'DarkGray'; $text = $Result.Message
    }
    elseif ($Result.RemovedBytes -gt 0 -or $Result.RemovedFiles -gt 0) {
        $key = if ($DryRun) { 'Result.WouldFree' } elseif ($Result.Approximate) { 'Result.Approx' } else { 'Result.Freed' }
        $text = Get-UiText $key @((Format-ByteSize $Result.RemovedBytes))
        if ($Result.Message) { $text += ' · ' + $Result.Message }
    }
    elseif ($Result.Message) {
        $text = $Result.Message
    }
    else {
        $text = Get-UiText 'Result.Nothing'
        $color = 'DarkGray'
    }


    Write-Ui ('  ' + $symbol + ' ') $color -NoNewline
    Write-Ui (Format-Cell $name $nameWidth) White -NoNewline
    Write-Ui ('  ' + $text) $(if ($Result.State -eq 'Failed') { 'Red' } else { 'Gray' })

    foreach ($file in $Result.Largest) {
        Write-Ui ('       {0,10}  {1}' -f (Format-ByteSize $file.Length), (Protect-LogText $file.FullName)) DarkGray
    }
}

function Show-Summary {
    param($Results, [TimeSpan]$Duration, [hashtable]$FreeBefore, [hashtable]$FreeAfter, [string]$LogFile, [string]$LogError, [switch]$DryRun)

    $totals = Get-ResultTotal $Results
    Write-Ui ''
    $title = if ($DryRun) { Get-UiText 'Summary.DryRun' @((Format-Duration $Duration)) } else { Get-UiText 'Summary.Done' @((Format-Duration $Duration)) }
    Write-Ui ('  ' + $script:Ui.Ok + ' ' + $title) Green
    Write-Ui ''

    $rows = New-Object System.Collections.Generic.List[object]
    if ($DryRun) {
        $rows.Add(@((Get-UiText 'Summary.WouldRecover'), (Format-ByteSize $totals.RemovedBytes), 'White'))
        $rows.Add(@((Get-UiText 'Summary.FilesWould'), (Format-Count $totals.RemovedFiles), 'Gray'))
    }
    else {
        $rows.Add(@((Get-UiText 'Summary.Recovered'), (Format-ByteSize $totals.RemovedBytes), 'White'))
        $rows.Add(@((Get-UiText 'Summary.FilesRemoved'), (Format-Count $totals.RemovedFiles), 'Gray'))
        if ($totals.RemovedDirs -gt 0) { $rows.Add(@((Get-UiText 'Summary.DirsRemoved'), (Format-Count $totals.RemovedDirs), 'Gray')) }
        if ($totals.InUse -gt 0) { $rows.Add(@((Get-UiText 'Summary.InUse'), (Format-Count $totals.InUse), 'DarkGray')) }
        if ($totals.AccessDenied -gt 0) { $rows.Add(@((Get-UiText 'Summary.Denied'), (Format-Count $totals.AccessDenied), 'DarkGray')) }
        if ($totals.Pending -gt 0) { $rows.Add(@((Get-UiText 'Summary.Pending'), (Format-Count $totals.Pending), 'DarkGray')) }
        if ($totals.PathTooLong -gt 0) { $rows.Add(@((Get-UiText 'Summary.LongPath'), (Format-Count $totals.PathTooLong), 'DarkGray')) }
    }
    if ($totals.Recent -gt 0) { $rows.Add(@((Get-UiText 'Summary.Recent'), (Format-Count $totals.Recent), 'DarkGray')) }
    if ($totals.Links -gt 0) { $rows.Add(@((Get-UiText 'Summary.Links'), (Format-Count $totals.Links), 'DarkGray')) }
    if ($totals.Errors -gt 0) { $rows.Add(@((Get-UiText 'Summary.Errors'), (Format-Count $totals.Errors), 'Red')) }

    if (-not $DryRun) {
        foreach ($drive in @($FreeAfter.Keys | Sort-Object)) {
            if ($null -eq $FreeBefore[$drive] -or $null -eq $FreeAfter[$drive]) { continue }
            $rows.Add(@((Get-UiText 'Summary.FreeSpace' @($drive.TrimEnd('\'))), ('{0} → {1}' -f (Format-ByteSize $FreeBefore[$drive]), (Format-ByteSize $FreeAfter[$drive])), 'Gray'))
        }
    }

    $labelWidth = 0
    foreach ($row in $rows) { $labelWidth = [Math]::Max($labelWidth, $row[0].Length) }
    foreach ($row in $rows) {
        Write-Ui ('    ' + (Format-Cell $row[0] ($labelWidth + 3))) DarkGray -NoNewline
        Write-Ui $row[1] $row[2]
    }

    Write-Ui ''
    if ($LogFile) { Write-Ui ('  {0}: {1}' -f (Get-UiText 'Summary.Log'), $LogFile) DarkGray }
    if ($LogError) { Write-Ui ('  ' + (Get-UiText 'Summary.LogFailed' @($LogError))) Yellow }
    Write-Ui ('  ' + (Get-UiText 'Summary.Tip')) DarkGray
    Write-Ui ''
}

function Get-ResultTotal {
    param($Results)
    $totals = [ordered]@{ RemovedFiles = 0L; RemovedBytes = 0L; RemovedDirs = 0; InUse = 0; AccessDenied = 0; Recent = 0; Links = 0; PathTooLong = 0; Pending = 0; Errors = 0 }
    foreach ($result in $Results) {
        foreach ($key in @($totals.Keys)) { $totals[$key] += $result.$key }
        $totals.Recent += $result.Scan.RecentFiles
        $totals.Links += $result.Scan.Links
    }
    return [pscustomobject]$totals
}

function Show-CategoryList {
    foreach ($category in (Get-CategoryCatalog)) {
        $group = if ($category.Group -eq 'Safe') { Get-UiText 'List.Safe' } else { Get-UiText 'List.Advanced' }
        $admin = ''
        if ($category.RequiresAdmin) { $admin = ' · ' + (Get-UiText 'List.Admin') }
        Write-Ui ('  {0,-22}' -f $category.Id) White -NoNewline
        Write-Ui ('{0}  ' -f (Get-UiText "Cat.$($category.Id).Name")) Gray -NoNewline
        Write-Ui ('[{0}{1}]' -f $group, $admin) DarkGray
        Write-Ui ('  {0,-22}{1}' -f '', (Get-UiText "Cat.$($category.Id).Note")) DarkGray
    }
}

#endregion

#region Logging

function Protect-LogText {
    # Replaces profile paths so logs and screens do not expose account names.
    param([AllowNull()][string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return $Text }
    $value = $Text
    $replacements = @(
        @($env:LOCALAPPDATA, '%LOCALAPPDATA%'),
        @($env:APPDATA, '%APPDATA%'),
        @($env:USERPROFILE, '%USERPROFILE%')
    )
    if ($script:Context) {
        $replacements = @(, @($script:Context.LocalAppData, '%LOCALAPPDATA%')) + $replacements
    }
    foreach ($pair in $replacements) {
        if (-not [string]::IsNullOrEmpty($pair[0])) {
            $value = [regex]::Replace($value, [regex]::Escape($pair[0]), $pair[1].Replace('$', '$$'), 'IgnoreCase')
        }
    }
    return $value
}

function Get-DefaultLogDirectory {
    $base = [Environment]::GetFolderPath('LocalApplicationData')
    if (-not $base) { return $null }
    return Join-PathSafe $base 'CleanWinTempFiles\Logs'
}

function Remove-OldLog {
    param([string]$Directory)
    foreach ($pattern in @('cleanup-*.log', 'cleanup-*.json')) {
        $files = @((New-Object IO.DirectoryInfo($Directory)).GetFiles($pattern) | Sort-Object -Property Name -Descending)
        foreach ($file in ($files | Select-Object -Skip $script:LogRetentionCount)) {
            try { [IO.File]::Delete($file.FullName) } catch { Write-Verbose "Old log kept: $($file.Name)" }
        }
    }
}

function Write-RunLog {
    param(
        [string]$Path,
        $WindowsInfo,
        $Context,
        $Scans,
        $Results,
        [hashtable]$Options,
        [datetime]$Started,
        [TimeSpan]$Duration,
        [hashtable]$FreeBefore,
        [hashtable]$FreeAfter
    )

    # The log is for machines and support: always invariant culture (dot decimals).
    $invariant = [Globalization.CultureInfo]::InvariantCulture
    $format = { param([string]$Template, [object[]]$Values) [string]::Format($invariant, $Template, $Values) }
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add(('{0} {1}' -f $script:AppName, $script:AppVersion))
    $lines.Add(('Started     {0}' -f $Started.ToString('yyyy-MM-dd HH:mm:ss zzz', $invariant)))
    $lines.Add((& $format 'Duration    {0:N1} s' @($Duration.TotalSeconds)))
    $lines.Add(('Windows     {0} {1} build {2} {3}' -f $WindowsInfo.Name, $WindowsInfo.DisplayVersion, $WindowsInfo.BuildText, $WindowsInfo.Architecture))
    $lines.Add(('PowerShell  {0} {1}' -f $PSVersionTable.PSVersion, $PSVersionTable.PSEdition))
    $lines.Add(('Elevated    {0}' -f $Context.IsAdmin))
    $lines.Add(('Options     Mode={0} DryRun={1} Unattended={2} Selected={3}' -f $Options.Mode, $Options.DryRun, $Options.Yes, ($Options.Selected -join ',')))
    $lines.Add(('RebootPending {0}' -f $Context.RebootPending))
    $lines.Add('')
    $lines.Add('[Scan]')
    foreach ($scan in $Scans) {
        $lines.Add((& $format '{0,-22} {1,-13} bytes={2} files={3} recent={4} links={5} deniedDirs={6} pendingRename={7} {8:N2}s' `
                @($scan.Category.Id, $scan.State, $scan.Bytes, $scan.Files, $scan.RecentFiles, $scan.Links, $scan.DeniedDirs, $scan.ProtectedPending, $scan.Duration.TotalSeconds)))
        if ($scan.State -eq 'Aborted') { $lines.Add(('    aborted: {0} at {1}' -f $scan.AbortReason, (Protect-LogText $scan.AbortPath))) }
    }
    $lines.Add('')
    $lines.Add('[Clean]')
    foreach ($result in $Results) {
        $lines.Add((& $format '{0,-22} {1,-10} removedFiles={2} removedBytes={3} dirs={4} inUse={5} denied={6} recent={7} links={8} pending={9} longPath={10} errors={11} {12:N2}s' `
                @($result.Scan.Category.Id, $result.State, $result.RemovedFiles, $result.RemovedBytes, $result.RemovedDirs, $result.InUse,
                $result.AccessDenied, $result.Recent, $result.Links, $result.Pending, $result.PathTooLong, $result.Errors, $result.Duration.TotalSeconds)))
        if ($result.Message) { $lines.Add(('    note: {0}' -f (Protect-LogText $result.Message))) }
        foreach ($sample in $result.ErrorSamples) { $lines.Add(('    error: {0}' -f $sample)) }
    }
    $totals = Get-ResultTotal $Results
    $lines.Add('')
    $lines.Add('[Result]')
    $lines.Add(('Recovered   {0} bytes ({1})' -f $totals.RemovedBytes, (Format-ByteSize $totals.RemovedBytes $invariant)))
    foreach ($drive in @($FreeAfter.Keys | Sort-Object)) {
        $lines.Add(('Free {0}    before={1} after={2}' -f $drive, $FreeBefore[$drive], $FreeAfter[$drive]))
    }

    $directory = [IO.Path]::GetDirectoryName($Path)
    if ($directory -and -not [IO.Directory]::Exists($directory)) { [void][IO.Directory]::CreateDirectory($directory) }
    $utf8 = New-Object Text.UTF8Encoding($true)
    [IO.File]::WriteAllLines($Path, $lines.ToArray(), $utf8)

    $json = [ordered]@{
        tool          = $script:AppName
        version       = $script:AppVersion
        started       = $Started.ToString('o', $invariant)
        durationSec   = [Math]::Round($Duration.TotalSeconds, 2)
        windows       = [ordered]@{ name = $WindowsInfo.Name; version = $WindowsInfo.DisplayVersion; build = $WindowsInfo.BuildText; arch = $WindowsInfo.Architecture }
        powershell    = [string]$PSVersionTable.PSVersion
        elevated      = $Context.IsAdmin
        dryRun        = [bool]$Options.DryRun
        rebootPending = $Context.RebootPending
        categories    = @(foreach ($scan in $Scans) {
                $result = $Results | Where-Object { $_.Scan -eq $scan } | Select-Object -First 1
                [ordered]@{
                    id           = $scan.Category.Id
                    scanState    = $scan.State
                    foundBytes   = $scan.Bytes
                    foundFiles   = $scan.Files
                    recentFiles  = $scan.RecentFiles
                    links        = $scan.Links
                    cleanState   = $(if ($result) { $result.State } else { 'NotSelected' })
                    removedFiles = $(if ($result) { $result.RemovedFiles } else { 0 })
                    removedBytes = $(if ($result) { $result.RemovedBytes } else { 0 })
                    removedDirs  = $(if ($result) { $result.RemovedDirs } else { 0 })
                    inUse        = $(if ($result) { $result.InUse } else { 0 })
                    accessDenied = $(if ($result) { $result.AccessDenied } else { 0 })
                    errors       = $(if ($result) { $result.Errors } else { 0 })
                }
            })
        recoveredBytes = $totals.RemovedBytes
    }
    $jsonPath = [IO.Path]::ChangeExtension($Path, '.json')
    if (Test-PathEqual $jsonPath $Path) { $jsonPath = $Path + '.json' }
    [IO.File]::WriteAllText($jsonPath, ($json | ConvertTo-Json -Depth 6), $utf8)
}

#endregion

#region Elevation

function Get-PowerShellHostPath {
    $current = (Get-Process -Id $PID).Path
    if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess -and $current -match '\\SysWOW64\\') {
        $native = Get-SystemToolPath 'WindowsPowerShell\v1.0\powershell.exe'
        if ($native -and [IO.File]::Exists($native)) { return $native }
    }
    return $current
}

function Get-RelaunchArgument {
    # Rebuilds the user's options for the elevated child. Arrays are joined with commas
    # because -File passes every value as plain text.
    param([hashtable]$BoundParameters, [string]$ScriptPath, [string]$LocalAppData)

    $arguments = New-Object System.Collections.Generic.List[string]
    foreach ($item in @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $ScriptPath)) { $arguments.Add($item) }

    $skip = @('PauseOnExit', 'Relaunched', 'TargetLocalAppData', 'NoElevate')
    foreach ($name in @($BoundParameters.Keys | Sort-Object)) {
        if ($skip -contains $name) { continue }
        $value = $BoundParameters[$name]
        if ($value -is [System.Management.Automation.SwitchParameter] -or $value -is [bool]) {
            if ([bool]$value) { $arguments.Add("-$name") }
            continue
        }
        if ($value -is [array]) { $value = (@($value) -join ',') }
        if ([string]::IsNullOrEmpty([string]$value)) { continue }
        $arguments.Add("-$name")
        $arguments.Add([string]$value)
    }

    $arguments.Add('-Relaunched')
    $arguments.Add('-PauseOnExit')
    if ($LocalAppData) {
        $arguments.Add('-TargetLocalAppData')
        $arguments.Add($LocalAppData)
    }
    return $arguments.ToArray()
}

function Invoke-ElevatedRelaunch {
    param([hashtable]$BoundParameters)

    $arguments = Get-RelaunchArgument -BoundParameters $BoundParameters -ScriptPath $script:ScriptPath -LocalAppData ([Environment]::GetFolderPath('LocalApplicationData'))
    $commandLine = ($arguments | ForEach-Object { ConvertTo-CommandLineArgument $_ }) -join ' '
    try {
        $process = Start-Process -FilePath (Get-PowerShellHostPath) -ArgumentList $commandLine -Verb RunAs -PassThru -Wait -ErrorAction Stop
        $code = 0
        if ($null -ne $process.ExitCode) { $code = [int]$process.ExitCode }
        return [pscustomobject]@{ Status = 'Elevated'; ExitCode = $code; Message = $null }
    }
    catch {
        $inner = $_.Exception
        while ($inner.InnerException) { $inner = $inner.InnerException }
        if ($inner -is [ComponentModel.Win32Exception] -and $inner.NativeErrorCode -eq 1223) {
            return [pscustomobject]@{ Status = 'Cancelled'; ExitCode = 0; Message = $null }
        }
        return [pscustomobject]@{ Status = 'Failed'; ExitCode = 0; Message = $inner.Message }
    }
}

#endregion

#region Main

function Get-DefaultSelection {
    param($Scans, [string[]]$Include, [string[]]$Exclude)
    $selection = @{}
    foreach ($scan in $Scans) {
        $id = $scan.Category.Id
        $selected = $false
        if ($scan.Category.Group -eq 'Safe' -and $scan.State -eq 'Ready') {
            $selected = $true
            if ($scan.Category.Kind -eq 'DeliveryOptimization' -and $scan.Bytes -lt $script:DeliveryOptimizationMinBytes) { $selected = $false }
        }
        if ($Include -contains $id -and (Test-ScanSelectable $scan)) { $selected = $true }
        if ($Exclude -contains $id) { $selected = $false }
        $selection[$id] = $selected
    }
    return $selection
}

function ConvertTo-CategoryList {
    param([string[]]$Values)
    $list = New-Object System.Collections.Generic.List[string]
    foreach ($value in $Values) {
        foreach ($part in ([string]$value).Split(',')) {
            $trimmed = $part.Trim()
            if ($trimmed) { $list.Add($trimmed) }
        }
    }
    return $list.ToArray()
}

function Invoke-ScanBatch {
    param($Categories, $Context)
    $scans = New-Object System.Collections.Generic.List[object]
    $progress = {
        param($count, $bytes)
        Write-StatusLine ('{0}… {1} · {2}' -f $script:StatusPrefix, (Format-Count ($script:ProgressBaseFiles + $count)), (Format-ByteSize ($script:ProgressBaseBytes + $bytes)))
    }
    foreach ($category in $Categories) {
        $script:StatusPrefix = '  {0} {1}' -f (Get-UiText 'Scan.Title'), (Get-UiText "Cat.$($category.Id).Name")
        Write-StatusLine ($script:StatusPrefix + '…')
        $scans.Add((Invoke-CategoryScan -Category $category -Context $Context -OnProgress $progress))
    }
    Clear-StatusLine
    return , $scans
}

function Wait-BeforeExit {
    param([switch]$Enabled)
    if (-not $Enabled) { return }
    try { if ([Console]::IsInputRedirected) { return } } catch { return }
    # Started from an open terminal (more than cmd + PowerShell share the console): no pause.
    if ((Initialize-Native) -and [CleanWinTemp.NativeV2]::ConsoleProcessCount() -gt 2) { return }
    Write-Ui ('  ' + (Get-UiText 'Pause')) DarkGray -NoNewline
    [void](Read-Host)
}

function Invoke-Main {
    param([hashtable]$Options, [hashtable]$BoundParameters)

    $started = Get-Date
    $timer = [Diagnostics.Stopwatch]::StartNew()
    Initialize-Ui -NoColor:$Options.NoColor -Ascii:$Options.Ascii -Language $Options.Language

    if (-not (Test-IsWindowsHost)) {
        Write-Ui ('  ' + (Get-UiText 'Error.NotWindows')) Red
        $script:ExitCode = 2
        return
    }
    if ($ExecutionContext.SessionState.LanguageMode -ne 'FullLanguage') {
        Write-Ui ('  ' + (Get-UiText 'Error.Language' @($ExecutionContext.SessionState.LanguageMode))) Red
        $script:ExitCode = 2
        return
    }

    # @() matters: a function returning an empty array yields $null.
    $include = @(ConvertTo-CategoryList $Options.Include)
    $exclude = @(ConvertTo-CategoryList $Options.Exclude)
    $allIds = $script:SafeCategoryIds + $script:AdvancedCategoryIds
    foreach ($id in ($include + $exclude)) {
        if ($allIds -notcontains $id) {
            Write-Ui ('  ' + (Get-UiText 'Error.UnknownCategory' @($id, ($allIds -join ', ')))) Red
            $script:ExitCode = 2
            return
        }
    }
    # Normalize spelling so later comparisons are exact.
    $include = @($include | ForEach-Object { $value = $_; $allIds | Where-Object { $_ -ieq $value } })
    $exclude = @($exclude | ForEach-Object { $value = $_; $allIds | Where-Object { $_ -ieq $value } })

    if ($Options.ListCategories) {
        Show-CategoryList
        return
    }

    $windows = Get-WindowsInfo
    if (-not $windows.Supported) {
        Write-Ui ('  ' + (Get-UiText 'Error.Unsupported' @($windows.BuildText))) Red
        $script:ExitCode = 2
        return
    }

    $inputRedirected = $false
    try { $inputRedirected = [Console]::IsInputRedirected } catch { $inputRedirected = $true }
    $interactive = -not $Options.Yes -and -not $inputRedirected
    $isAdmin = Test-IsAdministrator

    Show-Header -WindowsInfo $windows -IsAdmin $isAdmin -DryRun:$Options.DryRun

    if (-not $isAdmin -and $interactive -and -not $Options.NoElevate -and -not $Options.Relaunched) {
        Write-Ui ('  ' + (Get-UiText 'Elevate.Explain')) Gray
        if (Read-YesNo (Get-UiText 'Elevate.Prompt') -DefaultYes) {
            $relaunch = Invoke-ElevatedRelaunch -BoundParameters $BoundParameters
            switch ($relaunch.Status) {
                'Elevated' {
                    Write-Ui ('  ' + (Get-UiText 'Elevate.Done')) DarkGray
                    $script:ExitCode = $relaunch.ExitCode
                    $script:SkipPause = $true
                    return
                }
                'Cancelled' { Write-Ui ('  ' + (Get-UiText 'Elevate.Cancelled')) Yellow }
                default { Write-Ui ('  ' + (Get-UiText 'Elevate.Failed' @($relaunch.Message))) Yellow }
            }
        }
        Write-Ui ''
    }

    $context = New-RunContext -IsAdmin $isAdmin -TargetLocalAppData $Options.TargetLocalAppData
    $script:Context = $context
    $headerNotes = New-Object System.Collections.Generic.List[string]
    if ($windows.IsServer) { $headerNotes.Add((Get-UiText 'Header.Server')) }
    if (-not $isAdmin -and $Options.Relaunched) { $headerNotes.Add((Get-UiText 'Elevate.StillUser')) }
    if ($context.Environment.TargetRejected) { $headerNotes.Add((Get-UiText 'Elevate.TargetRejected')) }
    if ($context.OtherUser) { $headerNotes.Add((Get-UiText 'Header.OtherUser')) }
    if ($context.RebootPending) { $headerNotes.Add((Get-UiText 'Header.RebootPending')) }
    foreach ($note in $headerNotes) { Write-Ui ('  ' + $script:Ui.Warn + ' ' + $note) Yellow }
    if ($headerNotes.Count -gt 0) { Write-Ui '' }

    # Optional categories are scanned only when asked for: in Safe mode the first scan stays fast.
    $catalog = @(Get-CategoryCatalog)
    $advancedIncluded = @($include | Where-Object { $script:AdvancedCategoryIds -contains $_ })
    $advancedVisible = $Options.Mode -eq 'Advanced' -or ($interactive -and $advancedIncluded.Count -gt 0)
    $toScan = @($catalog | Where-Object { $_.Group -eq 'Safe' -or $advancedVisible -or $advancedIncluded -contains $_.Id })
    $scans = Invoke-ScanBatch -Categories $toScan -Context $context
    if ($advancedIncluded.Count -gt 0) { $advancedVisible = $true }

    $selection = Get-DefaultSelection -Scans $scans -Include $include -Exclude $exclude
    $quit = $false

    if ($interactive) {
        $message = $null
        while ($true) {
            if ($script:Ui.CanOverwrite) {
                try { [Console]::Clear() } catch { Write-Verbose 'Console cannot be cleared' }
                Show-Header -WindowsInfo $windows -IsAdmin $isAdmin -DryRun:$Options.DryRun -Notes $headerNotes.ToArray()
            }
            $numbers = Show-Review -Scans $scans -Selection $selection -AdvancedVisible $advancedVisible -DryRun:$Options.DryRun -Interactive
            if ($message) { Write-Ui ('  ' + $message) Yellow; $message = $null }
            Write-Ui ('  {0} › ' -f (Get-UiText 'Menu.Prompt')) White -NoNewline
            $answer = ([string](Read-Host)).Trim()

            if ($answer -eq '') { break }
            if ($answer -ieq 'q') { $quit = $true; break }
            if ($answer -ieq 'a') {
                if (-not $advancedVisible) {
                    $scannedIds = @($scans | ForEach-Object { $_.Category.Id })
                    $missing = @($catalog | Where-Object { $_.Group -eq 'Advanced' -and $scannedIds -notcontains $_.Id })
                    foreach ($scan in (Invoke-ScanBatch -Categories $missing -Context $context)) {
                        $scans.Add($scan)
                        $selection[$scan.Category.Id] = $false
                    }
                    $advancedVisible = $true
                }
                continue
            }

            foreach ($token in ($answer -split '[\s,;]+')) {
                $index = 0
                if (-not [int]::TryParse($token, [ref]$index) -or -not $numbers.ContainsKey($index)) {
                    $message = Get-UiText 'Menu.Invalid' @($token)
                    continue
                }
                $id = $numbers[$index]
                $scan = $scans | Where-Object { $_.Category.Id -eq $id } | Select-Object -First 1
                if (-not (Test-ScanSelectable $scan)) {
                    $message = Get-UiText 'Menu.NotSelectable' @((Get-UiText "Cat.$id.Name"), (Get-ScanStateText $scan))
                    continue
                }
                if ($selection[$id]) { $selection[$id] = $false; continue }
                if ($id -eq 'RecycleBin' -and -not $Options.DryRun) {
                    if (-not (Read-YesNo (Get-UiText 'Confirm.RecycleBin' @((Format-ByteSize $scan.Bytes), (Format-Count $scan.Files))))) { continue }
                }
                if ($id -eq 'ComponentStore') {
                    if (-not (Read-YesNo (Get-UiText 'Confirm.ComponentStore'))) { continue }
                }
                $selection[$id] = $true
            }
        }
    }
    else {
        [void](Show-Review -Scans $scans -Selection $selection -AdvancedVisible $advancedVisible -DryRun:$Options.DryRun)
        if (-not $Options.Yes -and -not $Options.DryRun) {
            Write-Ui ('  ' + (Get-UiText 'Confirm.NotInteractive')) Yellow
            $quit = $true
        }
    }

    if ($quit) {
        Write-Ui ('  ' + (Get-UiText 'Quit')) DarkGray
        return
    }

    $selectedScans = @($scans | Where-Object { $selection[$_.Category.Id] })
    if ($selectedScans.Count -eq 0) {
        Write-Ui ('  ' + (Get-UiText 'Nothing.Selected')) DarkGray
        return
    }

    $drives = @{}
    foreach ($path in @($context.Environment.SystemRoot, $context.LocalAppData)) {
        if ($path) { $drives[[IO.Path]::GetPathRoot($path).ToUpperInvariant()] = $true }
    }
    $freeBefore = @{}
    foreach ($drive in $drives.Keys) { $freeBefore[$drive] = Get-FreeSpace $drive }

    Write-Ui ''
    $results = New-Object System.Collections.Generic.List[object]
    $verb = if ($Options.DryRun) { Get-UiText 'Clean.Simulating' } else { Get-UiText 'Clean.Title' }
    $progress = {
        param($result)
        Write-StatusLine ('{0}… {1}' -f $script:StatusPrefix, (Format-ByteSize $result.RemovedBytes))
    }
    $tick = {
        param($text, $elapsed)
        Write-StatusLine ('  {0}… {1}' -f $text, (Format-Duration $elapsed))
    }
    foreach ($scan in $selectedScans) {
        $script:StatusPrefix = '  {0} {1}' -f $verb, (Get-UiText "Cat.$($scan.Category.Id).Name")
        Write-StatusLine ($script:StatusPrefix + '…')
        $result = Invoke-CategoryClean -Scan $scan -Context $context -DryRun:$Options.DryRun -OnProgress $progress -OnTick $tick
        Clear-StatusLine
        Show-CleanLine -Result $result -DryRun:$Options.DryRun
        $results.Add($result)
    }

    $freeAfter = @{}
    foreach ($drive in $drives.Keys) { $freeAfter[$drive] = Get-FreeSpace $drive }
    $timer.Stop()

    $logFile = $null
    $logError = $null
    if (-not $Options.NoLog) {
        try {
            $logFile = $Options.LogPath
            $defaultDirectory = $null
            if (-not $logFile) {
                $defaultDirectory = Get-DefaultLogDirectory
                $logFile = Join-PathSafe $defaultDirectory ('cleanup-{0}.log' -f $started.ToString('yyyyMMdd-HHmmss', [Globalization.CultureInfo]::InvariantCulture))
            }
            $logOptions = @{ Mode = $Options.Mode; DryRun = [bool]$Options.DryRun; Yes = [bool]$Options.Yes; Selected = @($selectedScans | ForEach-Object { $_.Category.Id }) }
            Write-RunLog -Path $logFile -WindowsInfo $windows -Context $context -Scans $scans -Results $results -Options $logOptions `
                -Started $started -Duration $timer.Elapsed -FreeBefore $freeBefore -FreeAfter $freeAfter
            if ($defaultDirectory) { Remove-OldLog -Directory $defaultDirectory }
        }
        catch {
            $logError = $_.Exception.Message
            $logFile = $null
        }
    }

    Show-Summary -Results $results -Duration $timer.Elapsed -FreeBefore $freeBefore -FreeAfter $freeAfter -LogFile (Protect-LogText $logFile) -LogError $logError -DryRun:$Options.DryRun

    $totals = Get-ResultTotal $results
    if ($totals.Errors -gt 0 -or @($results | Where-Object { $_.State -eq 'Failed' }).Count -gt 0) { $script:ExitCode = 1 }
}

#endregion

# Run only when executed, not when dot-sourced by the tests.
if ($MyInvocation.InvocationName -ne '.') {
    $script:SkipPause = $false
    $script:Context = $null

    $resolvedLogPath = $LogPath
    if ($LogPath) {
        # Relative paths are resolved now: the elevated child starts in System32.
        $resolvedLogPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($LogPath)
        $PSBoundParameters['LogPath'] = $resolvedLogPath
    }

    $options = @{
        Mode               = $Mode
        DryRun             = [bool]$DryRun
        Include            = $Include
        Exclude            = $Exclude
        Yes                = [bool]$Yes
        NoElevate          = [bool]$NoElevate
        ListCategories     = [bool]$ListCategories
        LogPath            = $resolvedLogPath
        NoLog              = [bool]$NoLog
        NoColor            = [bool]$NoColor
        Ascii              = [bool]$Ascii
        Language           = $Language
        TargetLocalAppData = $TargetLocalAppData
        Relaunched         = [bool]$Relaunched
    }

    try {
        Invoke-Main -Options $options -BoundParameters $PSBoundParameters
    }
    catch {
        Clear-StatusLine
        if (-not $script:Ui) { Initialize-Ui }
        Write-Ui ('  ' + (Get-UiText 'Error.Fatal' @((Protect-LogText $_.Exception.Message)))) Red
        $script:ExitCode = 1
    }
    finally {
        if (-not $script:SkipPause) { Wait-BeforeExit -Enabled:$PauseOnExit }
    }
    exit $script:ExitCode
}
