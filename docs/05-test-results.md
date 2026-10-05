# 05 — Resultados dos testes

Data: 2026-10-05 · Versão: 2.0.0

## Ambiente desta rodada

O desenvolvimento ocorreu em **Linux** (BigLinux/Manjaro), sem acesso a uma máquina Windows. Foram usados:

- PowerShell 7.6.6 portátil (tarball oficial da Microsoft), fora do repositório;
- Pester 5.7.1 e PSScriptAnalyzer (PowerShell Gallery), fora do repositório;
- `cmd.exe` do Wine 11.17 em um prefixo isolado, só para o launcher.

**O que não pôde ser executado no Linux** (coberto depois pelo CI em Windows, abaixo): Windows PowerShell 5.1 real, APIs Win32 (P/Invoke), UAC, arquivos bloqueados, ACLs, junctions NTFS, DISM, Delivery Optimization e Lixeira. Esses itens estão no roteiro manual de [04-test-plan.md](04-test-plan.md) e em aberto no [06-release-checklist.md](06-release-checklist.md).

## Resultados

| Verificação | Resultado |
| --- | --- |
| Parser do PowerShell (script e testes) | 0 erros |
| Pester 5 | **135 aprovados, 0 falhas, 3 pulados** (os 3 exigem Windows: ambiente real, arquivo bloqueado, ACL negada) |
| Bloco "CRITICAL: dangerous cleanup roots are refused" | 46 caminhos recusados + Windows em `D:` + variáveis vazias + perfil Unicode: todos aprovados |
| Links (symlinks Unix no lugar de junctions) | Não seguidos, não apagados, alvos intactos; troca de pasta por link após a varredura detectada |
| PSScriptAnalyzer (perfis Win10 1809 + PS 5.1 Desktop e PS 7.0) | Nenhuma incompatibilidade de sintaxe ou de tipos. Restam avisos esperados: `Delete-DeliveryOptimizationCache` (Windows 10 1903+) e `Get-DeliveryOptimizationPerfSnap` não existem em todas as builds, e a disponibilidade é verificada em tempo de execução |
| Fumaça `-Yes` | Antigos removidos (3 arquivos, 6000 bytes), recente mantido, pasta vazia removida, link e Documentos intactos, log e JSON válidos, código 0 |
| Fumaça `-DryRun -Mode Advanced -Include CrashDumps` (pt) | Nada apagado; "seria recuperado" correto; maiores itens listados; log com cultura invariante |
| Fumaça com `%TEMP%` → `Documentos\Temp` | Categoria "sua conta" abortada; documento intacto; `aborted: ProtectedLocation` no log; a categoria do Windows funcionou normalmente |
| Launcher (`cmd` do Wine) | `.ps1` ausente → mensagem + pausa; linha de comando com caminho absoluto e argumentos preservados; `-PauseOnExit` só com `cmd /c`; pasta com `& ( ) !` e acentos funcionando |
| Varredura de padrões destrutivos | Nenhum `Remove-Item`, `rd /s`, `del /s`, exclusão recursiva, `/ResetBase` (só no texto de aviso), serviços, escrita no registro, `takeown`/`icacls` ou `Stop-Process` |

## Windows real — GitHub Actions (run 37293431722)

Repositório privado `ruscher/clean-win-temp-files`, workflow `.github/workflows/windows-validation.yml`, script `tests/ci-validate.ps1`. Matriz de **4 ambientes**, todos verdes:

| Runner | Windows | PowerShell 5.1 | PowerShell 7 |
| --- | --- | --- | --- |
| windows-2022 | Server 2022 21H2, build 20348 (base do Windows 10 21H2) | ✅ | ✅ |
| windows-2025 | Server 2025, build 26100 (base do Windows 11 24H2) | ✅ | ✅ |

Em cada um dos 4:

- **Pester: 138 aprovados, 0 falhas, 0 pulados**, incluindo arquivo bloqueado real, ACL negada e recusa das pastas reais do sistema;
- **44 verificações de ponta a ponta aprovadas**, com o programa executado de verdade (processo filho), em fixtures plantadas em pastas reais:
  - simulação não apaga nada; categoria desconhecida → código 2; `-ListCategories` sem Prefetch;
  - limpeza real: os antigos (com espaço, Unicode `ção 文件` e somente leitura) removidos, pastas vazias antigas removidas, a pasta Temp mantida, o recente mantido, **o arquivo bloqueado mantido e contado como "em uso"**, **a junction NTFS e o link simbólico mantidos, com o conteúdo por trás intacto**;
  - `%SystemRoot%\Temp`: arquivo de 5 dias removido e de 1 dia mantido (regra de 72 h);
  - `CrashDumps`: dump de 40 dias removido, de 5 dias mantido, `.txt` mantido;
  - `%TEMP%` real em formato 8.3 (`C:\Users\RUNNER~1\...`) expandido e deduplicado;
  - `%TEMP%`/`%TMP%` apontando para `Documentos\Temp` → categoria abortada, documento intacto, log gravado;
  - launcher `.bat` com `-Language pt` → código 0, interface em português;
  - DISM: análise real interpretada nos dois desfechos (2022: "não há limpeza necessária"; 2025: "recomenda limpeza, 2 pacotes");
  - Delivery Optimization e Lixeira consultadas pelos mecanismos oficiais sem erro;
  - **usuário padrão real** (conta local criada só para o teste): detectado como "Standard user", Windows Temp marcado "requer administrador", código 0;
  - o log não contém o caminho do perfil.

Defeitos encontrados pelo CI e corrigidos:

| Defeito | Correção |
| --- | --- |
| Quando nada ficava selecionado (por exemplo, categoria abortada por segurança), o log não era gravado | O log passou a ser gravado também nesse caso |
| "Mantidos por segurança" na revisão contava categorias não selecionadas, divergindo do resumo | Passou a contar só as selecionadas |
| (script de CI) função auxiliar com o mesmo nome do `New-Fixture` do Pester | Renomeada |

### Ainda não coberto pelo CI

- **Windows 10 e 11 cliente**: os runners são Windows Server com o mesmo kernel e o mesmo PowerShell, mas sem Microsoft Store, Edge em segundo plano etc.
- **Fluxo interativo do UAC** (aceitar/cancelar o prompt): só é possível manualmente.
- Lixeira **com itens** e cache da Otimização de Entrega **com conteúdo** (nos runners ambos estavam vazios), e `StartComponentCleanup` real, que não foi executado por levar muito tempo.

## Defeitos encontrados e corrigidos durante os testes (Linux)

| Defeito | Como foi achado | Impacto se não corrigido |
| --- | --- | --- |
| `[IO.FileAttributes]0x441000` falha: os bits de placeholder de nuvem não têm nome no enum | Pester (fixtures) | **Toda varredura falharia** também no Windows |
| Sem `-Include`, a lista vazia virava `$null` → "Unknown category" | Fumaça do `Invoke-Main` | **O script sempre sairia com código 2** |
| Closures com `GetNewClosure()` não enxergam funções do script executado via `-File` | Revisão de código | Progresso e DISM quebrariam em execução real |
| `AddRange` com retorno de item único | Revisão de código | Falha com uma única categoria varrida |
| Log com vírgula decimal em pt-BR | Fumaça | Log não processável por máquina |
| `%cmdcmdline%` indefinido ativava a pausa no launcher | Wine | Pausa indevida em ambientes sem a variável |

## Limitação observada no Wine (não reproduz no Windows)

Com uma pasta chamada `100%`, o `cmd` do Wine reexpande `%~dp0` e perde o `%`. No `cmd.exe` do Windows, o resultado dessa expansão não é reprocessado. Fica como item de verificação manual no checklist.

## Como reproduzir

```powershell
Invoke-Pester -Path .\tests -Output Detailed
```

No Linux, com o PowerShell 7 e o Pester 5 instalados, o mesmo comando executa tudo, exceto os 3 testes exclusivos do Windows.
