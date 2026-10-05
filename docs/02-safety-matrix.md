# 02 — Matriz de segurança

Classificação de cada local investigado:

- **SAFE**: pré-selecionado na Limpeza segura.
- **OPTIONAL**: só na Limpeza avançada, nunca pré-selecionado, com o efeito colateral exibido.
- **DO NOT CLEAN**: a ferramenta não oferece.

A pergunta usada em cada item foi: *apagar isto libera espaço de verdade, ou só obriga o Windows a recriar algo útil?*

Fontes consultadas em 2026-10-05; links ao final.

## Resumo

| Local | Classe | Implementação | Justificativa |
| --- | --- | --- | --- |
| `%TEMP%` / `%TMP%` / `%LOCALAPPDATA%\Temp` | **SAFE** | Conteúdo, arquivos com 24 h ou mais, sem seguir links; a pasta fica | Área temporária do usuário. Normalmente as três variáveis apontam para a mesma pasta, que é analisada uma única vez |
| `%SystemRoot%\Temp` | **SAFE** (admin) | Conteúdo, arquivos com 72 h ou mais | Temporários de serviços e instaladores; prazo maior porque pode haver operações aguardando reinicialização |
| Store apps `TempState`, `AC\Temp` | **SAFE** | Conteúdo, arquivos com 24 h ou mais | A Microsoft documenta que o sistema pode apagar essa pasta "a qualquer momento" [5] |
| Delivery Optimization | **SAFE** (admin), pré-selecionado se ≥ 100 MB | `Delete-DeliveryOptimizationCache -Force` (sem `-IncludePinnedFiles`) | Mecanismo oficial [4]. O Windows já limita o cache (3 dias, 20% do disco), então só vale a pena quando está grande |
| Lixeira | **OPTIONAL** | `SHQueryRecycleBin` / `SHEmptyRecycleBin` [8], com confirmação explícita | O usuário pode precisar restaurar algo |
| `MEMORY.DMP`, `Minidump`, `LiveKernelReports` | **OPTIONAL** (admin) | Só `*.dmp` com 30 dias ou mais | Ocupam GB, mas são evidência de telas azuis e travamentos |
| `%LOCALAPPDATA%\CrashDumps` | **OPTIONAL** | Só `*.dmp` com 30 dias ou mais | Dumps locais de apps (WER LocalDumps [11]); o Windows já mantém 10 por padrão |
| WER `ReportArchive` / `ReportQueue` | **OPTIONAL** | Arquivos com 30 dias ou mais (`%ProgramData%` exige admin) | A pasta de sistema é documentada [11]; a por usuário existe na prática, mas não é documentada. O WER já limita a quantidade (1000/50 relatórios) |
| Cache de navegadores | **OPTIONAL** | Só `Cache`, `Code Cache`, `GPUCache` (Chromium) e `cache2` (Firefox), com o navegador **fechado** | O cache é reconstruído; os dados pessoais ficam em outras pastas, que nunca são tocadas |
| DirectX / shader cache | **OPTIONAL** | `D3DSCache` e caches NVIDIA, AMD e Intel, arquivos com 1 h ou mais | Reconstruído, mas causa engasgos e recompilação. Útil após trocar de driver |
| Component Store (WinSxS) | **OPTIONAL** (admin) | `DISM /English /Online /Cleanup-Image /AnalyzeComponentStore`; só se "Cleanup Recommended: Yes", então `/StartComponentCleanup` | Método suportado [1][2]. **Nunca `/ResetBase`**, que impede desinstalar atualizações [1] |
| **Prefetch** | **DO NOT CLEAN** | Não implementado | Ver seção abaixo |
| `SoftwareDistribution` | **DO NOT CLEAN** | Recusado pela política | Estado do Windows Update. A limpeza suportada de componentes antigos é o DISM. Parar `wuauserv` e apagar a pasta é procedimento de *reparo*, não de limpeza |
| WinSxS direto | **DO NOT CLEAN** | Recusado pela política | "pode danificar seriamente o sistema" [1] |
| `Windows\Installer`, `$PatchCache$` | **DO NOT CLEAN** | Recusado | Sem esses arquivos, reparar, atualizar e desinstalar programas MSI falha |
| DriverStore, System32, SysWOW64, `servicing`, `Fonts`, `INF`, `assembly` | **DO NOT CLEAN** | Recusado | Arquivos do sistema |
| `Windows\Logs`, `Panther`, CBS | **DO NOT CLEAN** | Recusado | Diagnóstico de atualizações e instalação. O lixo grande conhecido (`cab_*.cab` do CBS) fica em `Windows\Temp`, que já é tratado |
| Windows.old, `$WINDOWS.~BT/~WS`, `$WinREAgent` | **DO NOT CLEAN** | Recusado | Permitem voltar à versão anterior; o Windows apaga o Windows.old sozinho após 10 dias [12] |
| Recovery, System Volume Information, pontos de restauração, cópias de sombra | **DO NOT CLEAN** | Recusado | Recuperação do sistema |
| `pagefile.sys`, `swapfile.sys`, `hiberfil.sys` | **DO NOT CLEAN** | Recusado (arquivo avulso só `MEMORY.DMP`) | Memória virtual e hibernação; desativar a hibernação muda configuração do sistema, não é limpeza |
| Cache de miniaturas (`thumbcache_*.db`) | **DO NOT CLEAN** | Não implementado | O Explorador mantém o banco aberto e o reconstrói. Apagar exigiria encerrar o Explorador, o que não fazemos; o handler oficial do Disk Cleanup/Storage Sense é o caminho certo |
| Cache de ícones (`iconcache_*.db`) | **DO NOT CLEAN** | Não implementado | Sempre em uso; apagar com o Explorador aberto não tem efeito, e o ganho é desprezível |
| INetCache (WinINet) | **DO NOT CLEAN** | Não implementado | Contém `Content.Outlook`, onde ficam anexos abertos no Outlook, possivelmente editados e não salvos. O Storage Sense cuida desse cache |
| Downloads, Documentos, Desktop, Imagens, Vídeos, Músicas, Favoritos, OneDrive | **DO NOT CLEAN** | Recusado (NoTouch) | Dados pessoais nunca são lixo, mesmo que antigos |
| `AppData\Roaming`, perfis de navegador (cookies, senhas, sessões, histórico, favoritos, Local Storage, IndexedDB, Service Worker) | **DO NOT CLEAN** | Recusado / fora do escopo | Dados de aplicativos e credenciais |
| Placeholders do OneDrive (atributos de nuvem) | **DO NOT CLEAN** | Ignorados na varredura e na exclusão | Apagar um placeholder pode apagar o arquivo na nuvem |
| Registro, SAM, hives | **DO NOT CLEAN** | Só leitura de `ProfileList`, `Shell Folders`, `PendingFileRenameOperations` e chaves de reboot | Nada de "registry cleaner" |
| Serviços (SysMain, Search, Update, Defender, BITS, DO, telemetria) | **DO NOT CLEAN** | Nenhuma chamada a serviços | Ferramenta de limpeza de arquivos, não de "tuning" |
| DNS (`ipconfig /flushdns`) | **DO NOT CLEAN** | Não implementado | Limpa o cache do resolvedor na memória [13]; não libera disco e força novas resoluções |

## Prefetch: decisão técnica

**Decisão: não limpar, nem em modo avançado.**

1. **Função**: o Prefetch (com o SysMain) registra quais arquivos cada programa e a inicialização usam, para pré-carregá-los. Ele existe para *reduzir* o tempo de abertura.
2. **Efeito de apagar**: na execução seguinte de cada programa e na próxima inicialização, o Windows volta a coletar os traços. Esse é exatamente o período em que tudo fica mais lento. Um engenheiro da Microsoft descreveu a limpeza periódica como "uma má ideia", que provoca "uma queda temporária no desempenho" [6]. É um texto antigo (era XP) e informal, mas o mecanismo continua o mesmo.
3. **Espaço**: os arquivos `.pf` são pequenos (normalmente dezenas de MB no total), e o Windows limita e recicla a quantidade sozinho [6].
4. **Cenários "legítimos"** encontrados (traços corrompidos, análise forense) são de diagnóstico e não justificam um botão num limpador. Corrupção é tratada pelo próprio Windows, e análise forense pede *preservar* os arquivos.
5. **Conclusão**: não há ganho técnico real, só um custo temporário. Pela regra do projeto ("se não existir vantagem técnica real: não limpe Prefetch"), a opção não existe. Os testes garantem que nenhum alvo do catálogo contém `Prefetch` e que `C:\Windows\Prefetch` é recusado pela política.

## Idade mínima por categoria

| Categoria | Idade | Comparação com o Windows |
| --- | --- | --- |
| Temp do usuário | 24 h | Disk Cleanup: arquivos não modificados há 7 dias [7]. Storage Sense: arquivos "que não estão em uso", sem idade [7]. Os 24 h, somados ao bloqueio de arquivos em uso, à data de criação e à proteção de renomeações pendentes, ficam entre os dois |
| Temp do Windows | 72 h | Mais conservador porque serviços, MSI e atualizações usam a pasta entre reinicializações |
| Store `TempState` | 24 h | O sistema pode apagar a qualquer momento [5]; o prazo só evita atrapalhar um app aberto |
| Dumps / WER | 30 dias | Preserva evidência recente; o WER já limita a quantidade [11] |
| Shader cache | 1 h | Arquivos de um jogo aberto estão em uso e são ignorados de qualquer forma |
| Cache de navegador | 0 | Só é limpo com o navegador fechado, verificado na varredura e de novo na limpeza |

## Arquivos em uso e acesso negado

O comportamento esperado num Windows ativo é: violação de compartilhamento ou de bloqueio → "em uso"; `UnauthorizedAccessException` → "acesso negado" (inclui executáveis em execução e ACLs de sistema). Esses casos são contados, mostrados no resumo e **nunca** forçados: a ferramenta não toma posse de arquivos, não altera ACLs, não encerra processos e não agenda exclusão para a reinicialização.

## Fontes

1. Microsoft Learn — *Clean Up the WinSxS Folder*: https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/clean-up-the-winsxs-folder
2. Microsoft Learn — *Determine the Actual Size of the WinSxS Folder*: https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/determine-the-actual-size-of-the-winsxs-folder · *DISM global options* (`/English`): https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/dism-global-options-for-command-line-syntax
3. Microsoft Learn — *DISM Operating System Package Servicing Command-Line Options*: https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/dism-operating-system-package-servicing-command-line-options
4. Microsoft Learn — *Monitor Delivery Optimization* (`Delete-DeliveryOptimizationCache` desde o Windows 10 1903; `CacheSizeBytes`): https://learn.microsoft.com/en-us/windows/deployment/do/waas-delivery-optimization-monitor · *Delivery Optimization reference* (DOMaxCacheAge 3 dias, DOMaxCacheSize 20%): https://learn.microsoft.com/en-us/windows/deployment/do/waas-delivery-optimization-reference
5. Microsoft Learn — *Store and retrieve settings and other app data* (TemporaryFolder): https://learn.microsoft.com/en-us/windows/apps/develop/data/store-and-retrieve-app-data
6. Microsoft Learn (blog arquivado, 2005) — *Misinformation and the The Prefetch Flag*: https://learn.microsoft.com/en-us/archive/blogs/ryanmy/misinformation-and-the-the-prefetch-flag
7. Microsoft Learn — *cleanmgr*: https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/cleanmgr · *Policy CSP – Storage* (Storage Sense): https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-storage
8. Microsoft Learn — `SHEmptyRecycleBinW`: https://learn.microsoft.com/en-us/windows/win32/api/shellapi/nf-shellapi-shemptyrecyclebinw · `SHQueryRecycleBinW`: https://learn.microsoft.com/en-us/windows/win32/api/shellapi/nf-shellapi-shqueryrecyclebinw
9. Microsoft Learn — `GetFinalPathNameByHandleW`: https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-getfinalpathnamebyhandlew · `CreateFileW` (`FILE_FLAG_BACKUP_SEMANTICS`): https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-createfilew
10. Microsoft Learn — `MoveFileExA` (`PendingFileRenameOperations`): https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-movefileexa
11. Microsoft Learn — *Troubleshooting using WER reports*: https://learn.microsoft.com/en-us/windows-server/failover-clustering/troubleshooting-using-wer-reports · *WER Settings* (LocalDumps, MaxArchiveCount, MaxQueueCount): https://learn.microsoft.com/en-us/windows/win32/wer/wer-settings
12. Microsoft Support — *Delete your previous version of Windows*: https://support.microsoft.com/en-us/windows/deployment/install-upgrade/delete-your-previous-version-of-windows
13. Microsoft Learn — `ipconfig`: https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/ipconfig
14. Microsoft Tech Community (blog da equipe de Storage, 2019) — *Windows 10 and Storage Sense*, que anunciou a substituição gradual do Disk Cleanup pelo Storage Sense: https://techcommunity.microsoft.com/blog/filecab/windows-10-and-storage-sense/428270
