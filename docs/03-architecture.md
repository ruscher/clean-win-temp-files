# 03 — Arquitetura

## Visão geral

```
clean-win-temp-files.bat   launcher: acha o PowerShell 64-bit, detecta duplo clique, repassa argumentos
        │
        ▼
clean-win-temp-files.ps1   toda a lógica (um único arquivo, sem dependências externas)
  ├─ Path safety      funções puras: canonicalização, política de proteção, regras de raiz/arquivo
  ├─ Environment      Windows, admin, perfis, pastas conhecidas, renomeações pendentes, processos
  ├─ Catalog          categorias e seus "target builders" (onde procurar, idade mínima, filtros)
  ├─ Scanner          resolve e valida alvos, varre árvores sem seguir links (somente leitura)
  ├─ Cleaner          revalida e apaga arquivo a arquivo; mecanismos oficiais (Lixeira, DO, DISM)
  ├─ Terminal UI      cabeçalho, revisão, menu, progresso, resumo (cores/Unicode com fallback)
  ├─ Logging          log legível + JSON, invariantes, sem dados pessoais
  └─ Elevation        relançamento via UAC preservando argumentos, sem loop
```

O `.bat` é necessário para o duplo clique, porque o Windows não executa `.ps1` com dois cliques e a política de execução padrão bloqueia scripts baixados. Toda a lógica fica em PowerShell, que oferece tratamento de exceções, objetos, APIs de caminho e testes. Um único `.ps1` evita a quebra que ocorreria se o usuário copiasse só parte de um módulo.

## Fluxo

```
Header → (oferta de elevação) → Scan → Review → Clean → Verify → Report/Log
```

| Etapa | Função | Apaga algo? |
| --- | --- | --- |
| Scan | `Invoke-ScanBatch` → `Invoke-CategoryScan` → `Invoke-FilesCategoryScan` / handlers | Não |
| Review | `Show-Review` + menu em `Invoke-Main` | Não |
| Clean | `Invoke-CategoryClean` → `Invoke-TreeClean` / `Remove-CandidateFile` / handlers oficiais | Sim, exceto em `-DryRun` |
| Verify | Dentro do Clean: `File.Exists` após cada exclusão; nova consulta da Lixeira e do cache DO; espaço livre antes e depois | Não |
| Report | `Show-CleanLine`, `Show-Summary`, `Write-RunLog` | Não |

O `-DryRun` usa o mesmo caminho até o Clean, que devolve o resultado da varredura como "seria liberado" sem chamar nenhuma exclusão. No caso do DISM, roda somente a análise (`/AnalyzeComponentStore`, que apenas gera um relatório).

## Modelo de dados

- **Category**: `Id`, `Group` (Safe/Advanced), `Kind` (Files, RecycleBin, DeliveryOptimization, ComponentStore), `Builder`, `RequiresAdmin`.
- **Target**: `Path`, `Kind` (Tree/File), `Include` (curingas), `Recurse`, `RemoveEmptyDirs`, `MinAgeHours`, `RequiresAdmin`, `RequireTempName`, `AvoidRoots`, `Guard` (processos que bloqueiam o alvo).
- **CategoryScan**: estado (`Ready`, `Empty`, `NeedsAdmin`, `Unavailable`, `Blocked`, `Deferred`, `RebootPending`, `OtherUser`, `Aborted`, `Error`), bytes, arquivos, recentes, links, pastas negadas e as árvores varridas.
- **CleanResult**: removidos (arquivos, bytes, pastas), em uso, acesso negado, recentes, links, pendentes, caminho longo, erros (com até 10 amostras sanitizadas).

## Validação de caminhos (defesa em camadas)

1. **`ConvertTo-CanonicalPath`** (pura) aceita só caminhos absolutos `X:\...` e rejeita vazio, `%VAR%` não resolvida, curingas, aspas, `C:` e `C:foo`, UNC, `\\?\`, ADS (`:`) e `..` acima da raiz. Também remove pontos e espaços finais de cada segmento, como o Win32 faz (`C:\Windows. ` ≡ `C:\Windows`).
2. **`New-ProtectionPolicy`** (pura) monta duas listas a partir do ambiente:
   - *Critical*: a raiz pode estar **dentro**, nunca ser igual nem estar **acima** (`%SystemRoot%`, `Users`, perfis, `%LOCALAPPDATA%`, `ProgramData`...);
   - *NoTouch*: proibido igual, dentro ou acima (`System32`, `WinSxS`, `Installer`, `SoftwareDistribution`, `Prefetch`, `Program Files`, `AppData\Roaming`, pastas pessoais, OneDrive, `Recovery`...).

   As pastas de topo bem conhecidas são protegidas na unidade do sistema, na unidade do `%SystemRoot%` e em `C:`, mesmo sem nenhuma variável de ambiente.
3. **`Test-CleanupRootAllowed` / `Test-CleanupFileAllowed`** aplicam a política. Arquivo avulso só pode ser `MEMORY.DMP`.
4. **`Resolve-CleanupTarget`** (toca o disco) confere a existência e expande nomes 8.3 (`GetLongPathNameW`), revalidando o resultado. Recusa a raiz se ela for um link ou se o caminho final (`GetFinalPathNameByHandleW`, que resolve links em qualquer ponto do caminho) cair em local protegido. Para `%TEMP%`/`%TMP%`, exige uma pasta chamada `Temp` ou `Tmp` no caminho.
5. **Abortar a categoria**: qualquer `Rejected` zera a categoria inteira.
6. **`Invoke-TreeScan`** percorre a árvore iterativamente com `DirectoryInfo.GetFileSystemInfos()` e **nunca desce** em reparse points nem os apaga.
7. **`Test-SafeParentChain`**, imediatamente antes de cada exclusão, confere que nenhuma pasta entre o arquivo e a raiz virou link depois da varredura (proteção TOCTOU, com cache por pasta).
8. **`Remove-CandidateFile`** atualiza os atributos e reconfere existência, link, placeholder de nuvem e idade. Só então remove o somente-leitura (restaurando-o em caso de falha) e chama `File.Delete`; depois confirma com `File.Exists`.
9. As pastas são removidas com `Directory.Delete(path, $false)` (nunca recursivo), da mais funda para a mais rasa, nunca a raiz, e só se já eram antigas na varredura.

Nenhum caminho vindo do usuário chega ao cleaner. O único valor externo é `-TargetLocalAppData`, passado do processo não elevado ao elevado, e ele só é aceito se for exatamente `<ProfileImagePath>\AppData\Local` de um perfil registrado e não for link.

## Idade mínima

A idade é calculada como `agora − max(CreationTime, LastWriteTime)`, em UTC. `LastAccessTime` não é confiável no NTFS. A data de criação protege arquivos recém-copiados ou extraídos que preservam uma data de modificação antiga.

| Categoria | Idade | Motivo |
| --- | --- | --- |
| Temp do usuário / apps da Store | 24 h | Arquivos da sessão atual e de instaladores em andamento |
| Temp do Windows | 72 h | Serviços e instaladores aguardando reinicialização |
| Dumps e relatórios | 30 dias | Evidência para diagnóstico |
| Shader cache | 1 h | Jogo possivelmente aberto (arquivos em uso também são ignorados) |
| Cache de navegador | 0 | Só é limpo com o navegador fechado (verificado na varredura e de novo na limpeza) |

## Elevação

- **Detecção**: `WindowsPrincipal.IsInRole(Administrator)`, que considera o token filtrado do UAC e não depende do idioma.
- **Quando oferecer**: somente no modo interativo, sem administrador, sem `-NoElevate` e sem `-Relaunched`. Enter aceita a opção recomendada; o UAC é a confirmação real.
- **Relançamento**: `Start-Process -Verb RunAs -Wait`, com o mesmo executável do PowerShell (ou o de 64 bits via `Sysnative`) e os argumentos reconstruídos de `$PSBoundParameters`, citados pelas regras do `CommandLineToArgvW`. `-LogPath` relativo é convertido para absoluto antes, porque o processo elevado começa em `System32`.
- **Sem loop**: o filho recebe `-Relaunched` e nunca oferece elevação de novo.
- **UAC cancelado** (`Win32Exception` 1223): o script continua sem privilégios e avisa.
- **Elevação com outra conta** ("over-the-shoulder"): o filho recebe `-TargetLocalAppData` e limpa os temporários da conta que abriu a ferramenta. A Lixeira fica indisponível nesse caso, porque pertence a outra conta.

## Interface

- Cores com `Write-Host -ForegroundColor`, que funciona no conhost e no Windows Terminal sem depender de VT/ANSI. `-NoColor` e `NO_COLOR` desativam as cores.
- Glifos Unicode (`✓ ─ → ·`) só no Windows Terminal, VS Code, ConEmu ou console UTF-8; nos outros casos (conhost clássico), ASCII. `-Ascii` força ASCII.
- Uma linha de status com `\r` mostra o progresso, atualizada a cada 2.000 arquivos na varredura e 500 na limpeza. Sem animação, para não atrasar a execução.
- Textos em inglês e português (`Get-UiText`), escolhidos pelo idioma da interface do Windows.
- A pausa final só ocorre quando o console vai fechar (duplo clique ou janela elevada), verificada com `GetConsoleProcessList`.

## Desempenho

- Cada categoria é varrida uma vez; a lista de candidatos é reaproveitada na limpeza (sem segunda varredura).
- `%TEMP%`, `%TMP%` e `%LOCALAPPDATA%\Temp` são deduplicados, inclusive quando um está aninhado no outro.
- O laço quente evita chamadas de função e usa `List<T>` (sem `+=` em arrays).
- As categorias avançadas só são varridas quando pedidas (`A`, `-Mode Advanced` ou `-Include`).
- Processos externos: apenas o DISM, e só se selecionado.
- O tipo nativo (P/Invoke) é compilado uma vez por sessão (`Add-Type`, cerca de 1 s no 5.1). Se falhar, a ferramenta passa a um modo conservador: recusa qualquer pai que seja link, e a Lixeira fica indisponível.

## Compatibilidade

- `#Requires -Version 5.1`; a sintaxe foi verificada para 5.1 e 7.x pelo PSScriptAnalyzer (`PSUseCompatibleSyntax`, `PSUseCompatibleCommands` e `PSUseCompatibleTypes` com os perfis do Windows 10 e PowerShell 5.1/7.0).
- O `.ps1` é gravado em UTF-8 com BOM e CRLF; o `.bat` em ASCII com CRLF (`.gitattributes`).
- O modo `ConstrainedLanguage` (AppLocker/WDAC) é detectado e recusado com mensagem.
- A saída do DISM é forçada para inglês com `/English`, então nenhuma decisão depende do idioma do Windows.
