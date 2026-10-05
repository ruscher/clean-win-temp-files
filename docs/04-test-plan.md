# 04 — Plano de testes

## Princípios

- Nenhum teste destrutivo aponta para dados reais: todos os arquivos ficam no `TestDrive` do Pester.
- A "idade" dos arquivos é simulada com um *relógio de referência* (`ReferenceTimeUtc` = agora + 30 dias). Assim o teste funciona até em sistemas de arquivos onde a data de criação não pode ser alterada.
- As funções de segurança de caminho são **puras** e recebem o ambiente como parâmetro, então podem ser testadas com um Windows simulado (Windows em `D:`, variáveis vazias, usuário com acento) em qualquer sistema.
- Os testes que dependem do Windows (arquivo bloqueado, ACL negada, ambiente real) são pulados automaticamente em outros sistemas.

## Suíte automatizada (`tests/clean-win-temp-files.Tests.ps1`, Pester 5)

| Bloco | Cobertura |
| --- | --- |
| Path canonicalization | Normalização (barras, `..`, `.`, pontos e espaços finais, Unicode) e rejeição (vazio, `%VAR%`, `C:`, `C:foo`, relativo, UNC, `\\?\`, `\\.\`, `..` acima da raiz, curingas, ADS, aspas, quebra de linha). Prefixo traiçoeiro `C:\Windows2`; nomes 8.3 |
| **CRITICAL: dangerous roots** | Recusa de `C:\`, `C:`, `%SystemDrive%`, `%SystemRoot%`, `C:\Windows` (e variações), System32, SysWOW64, WinSxS, Prefetch, SoftwareDistribution, Installer, Logs, `C:\Users`, o perfil, Public, AppData, Local, Roaming, Documentos, Downloads, Desktop, Imagens, OneDrive, Program Files (x86), ProgramData, Recovery, SVI, `$Recycle.Bin`, Windows.old, `$WINDOWS.~BT`. Windows em `D:`; todas as variáveis vazias; perfil com espaço e Unicode; arquivos avulsos (só `MEMORY.DMP`); exigência de nome Temp; ambiente real (Windows) |
| Category abort | Um alvo ruim aborta a categoria inteira e o alvo bom fica intacto; categoria administrativa sem privilégio vira `NeedsAdmin` |
| Scanner/cleaner em fixtures | Arquivos antigos e recentes, nome com espaço, Unicode (`ação ünïcødé 文件`), somente leitura, aninhados, 2 MB, pasta vazia antiga e nova, link de diretório para fora, link de arquivo para fora. Verifica: só os antigos saem, a raiz fica, as pastas vazias antigas saem, os links e seus alvos ficam. Também: dry run sem exclusão, filtro `*.dmp`, sem recursão, renomeação pendente protegida, arquivo que ficou recente após a varredura, **pasta trocada por link após a varredura (TOCTOU)**, pasta inexistente, raiz que é link, pasta vazia. No Windows: **arquivo bloqueado** e **ACL negada** |
| Error classification | Violação de compartilhamento e de bloqueio → InUse; acesso negado; arquivo e pasta inexistentes; caminho longo; desconhecido; desembrulho de `MethodInvocationException` |
| Formatting | B/KB/MB/GB/TB invariante, pt-BR com vírgula, chaves de texto iguais em en/pt |
| Elevation arguments | Citação `CommandLineToArgvW` (espaço, aspas, barra final, Unicode); preservação de opções; `-Relaunched` e `-PauseOnExit` uma única vez; validação de `-TargetLocalAppData` |
| Selection and catalog | Pré-seleção (só Safe pronta; DO pequeno e Lixeira desmarcados; `-Include` não força item que requer admin); nenhum alvo contém Prefetch, WinSxS, SoftwareDistribution, Installer ou pastas pessoais; todos os alvos embutidos passam na política; lista de categorias (regressão do `-Include` vazio); quebra de notas; parsing de `PendingFileRenameOperations` |
| Source guard rails | Proibidos no código: `Remove-Item`, `rd /s`, `del /s`, `Directory.Delete(..., $true)`, `'/ResetBase'`, `flushdns`, `Stop-Service`/`Set-Service`/`sc.exe`, escrita no registro. Exige UTF-8 com BOM |

Execução:

```powershell
Install-Module Pester -MinimumVersion 5.0 -Scope CurrentUser -SkipPublisherCheck
Invoke-Pester -Path .\tests -Output Detailed
```

## Teste de fumaça do fluxo completo

O harness (fora do repositório) carrega o script, substitui só as funções dependentes do Windows (`Test-IsWindowsHost`, `Get-WindowsInfo`, `Test-IsAdministrator`, `New-RunContext`) por versões que apontam para uma árvore de fixtures e executa o `Invoke-Main` real em três cenários:

1. `-Yes`: limpa a seleção segura e confere arquivos removidos e mantidos, link intacto, log e JSON válidos.
2. `-DryRun -Mode Advanced -Include CrashDumps -Language pt`: nada apagado; maiores itens listados; log com cultura invariante.
3. `%TEMP%` apontando para `Documentos\Temp`: categoria abortada, documento intacto, motivo no log.

## Análise estática

- Parser do PowerShell sem erros.
- PSScriptAnalyzer com perfis de compatibilidade: Windows 10 1809 + PowerShell 5.1 (Desktop) e PowerShell 7.0.

## Launcher

Sob o `cmd.exe` do Wine (prefixo isolado), com a chamada final trocada por `echo`:

- arquivo `.ps1` ausente: mensagem e pausa;
- linha de comando montada: caminho absoluto, argumentos repassados, `&` entre aspas;
- duplo clique (`cmd /c`) → `-PauseOnExit`; cmd interativo → sem pausa;
- pasta com `&`, parênteses, `!` e acentos.

## Roteiro manual no Windows 10 e no Windows 11 (antes de publicar)

Execute em uma VM ou máquina de teste, uma vez no Windows 10 22H2 e uma no Windows 11 24H2.

| # | Passo | Esperado |
| --- | --- | --- |
| 1 | `Invoke-Pester .\tests` no PowerShell 5.1 e no 7 | 0 falhas, 0 pulados |
| 2 | Duplo clique no `.bat`, responder **N** à elevação | Só "sua conta" e Store; Windows Temp aparece como "requer administrador"; janela pausa no fim |
| 3 | Duplo clique, Enter na elevação, **cancelar o UAC** | Mensagem "não concedida", continua sem loop |
| 4 | Duplo clique, aceitar o UAC | Janela elevada com tudo; janela original fecha; a pausa ocorre só na elevada |
| 5 | `.bat -DryRun` | Nada apagado (comparar contagem do `%TEMP%` antes e depois) |
| 6 | Abrir um arquivo de `%TEMP%` com mais de 24 h no Word/Notepad++ e limpar | "Ignorados — em uso" ≥ 1; demais removidos |
| 7 | `mklink /J %TEMP%\j C:\Users\<você>\Documents` e limpar | Documentos intactos; "Ignorados — links" ≥ 1 |
| 8 | `set TEMP=C:\Users\<você>\Documents` e executar o `.ps1` no mesmo console | "Arquivos temporários (sua conta)" ignorado por segurança |
| 9 | Com o Edge aberto, `-Mode Advanced` | Navegadores: "Microsoft Edge aberto — o cache dele será ignorado" |
| 10 | Selecionar a Lixeira (com itens) | Pede confirmação; o tamanho da Lixeira cai para 0 |
| 11 | `-Include ComponentStore -Yes` (admin) | DISM analisa e só limpa se recomendar; sem `/ResetBase` |
| 12 | `-Yes` em uma tarefa agendada (usuário logado) | Sem perguntas; código de saída 0; log gravado |
| 13 | Windows em pt-BR e en-US | Interface no idioma; números formatados; DISM interpretado corretamente |
| 14 | Usuário com espaço e acento no nome | `%TEMP%` limpo; deduplicação 8.3 funcionando (uma linha só) |
| 15 | Conferir `C:\Windows\Prefetch` antes e depois | Inalterado |
| 16 | Abrir o log e o JSON | Sem nomes de arquivos apagados; perfil como `%USERPROFILE%` |
