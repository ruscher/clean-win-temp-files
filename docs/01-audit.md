# 01 — Auditoria

Data: 2026-10-05 · Versão auditada: a reescrita em PowerShell existente antes da 2.0.0 (sem número de versão)

## Estado encontrado

| Arquivo | Conteúdo |
| --- | --- |
| `clean-win-temp-files.bat` | Launcher de 37 linhas que chamava `powershell` pelo `PATH` |
| `clean-win-temp-files.ps1` | 784 linhas: modos Safe/Advanced, `-DryRun`, `-LogPath` |
| `tests/clean-win-temp-files.Tests.ps1` | 3 blocos Pester |
| `docs/01..06` | Documentação de uma rodada anterior |

A pasta **não é um repositório git**, então não há histórico para comparar. A documentação anterior descrevia um BAT original destrutivo (`del` com curingas em `C:\Windows\Logs`, `SoftwareDistribution`, perfis de navegador), mas esse arquivo não existe mais e essa descrição não pôde ser verificada.

## O que o programa fazia de fato

**Na prática, não limpava nada.** O motivo:

```powershell
Normalize-PathForComparison 'C:\'   # GetFullPath('C:\').TrimEnd('\') => 'C:'
$resolved.StartsWith('C:' + '\')    # verdadeiro para QUALQUER caminho em C:
```

Com `C:\` na lista de bloqueio, comparada por prefixo, todo caminho em `C:` era bloqueado, inclusive `%TEMP%` e `C:\Windows\Temp`. As raízes eram descartadas e a ferramenta terminava com "0 B" sem explicar o motivo. Isso foi confirmado executando a lógica no parser do PowerShell.

## Defeitos encontrados

### Críticos (segurança ou função principal)

1. **Nenhuma limpeza ocorria** (descrito acima). Os documentos `05-test-results.md` e `06-release-checklist.md` afirmavam o contrário.
2. **A Lixeira era esvaziada sem pergunta** no modo Advanced (`Clear-RecycleBin -Force` dentro do loop de categorias), violando a exigência de opção separada e explícita.
3. **Travessia de junctions**: a enumeração usava `Get-ChildItem -Recurse`. No Windows PowerShell 5.1 a recursão entra em junctions e links de diretório; o filtro `ReparsePoint` descartava só o próprio link, não os arquivos de dentro, cujo `FullName` continua "dentro" da pasta Temp e passaria na validação por prefixo. Se a limpeza funcionasse, arquivos fora da árvore poderiam ser apagados.
4. **Dumps "antigos" = mais de 1 hora**: o limite global `RecentFileThresholdHours = 1` valia também para despejos de memória e relatórios WER, que deveriam ficar para diagnóstico.
5. **Cache de navegador apagado com o navegador aberto** e só do perfil `Default`.

### Funcionais

6. `(Get-CleanupRoots + Get-AdvancedCleanupRoots)` é interpretado como **um comando com argumentos** (`+` e o nome da outra função), então as raízes avançadas nunca eram incluídas. O mesmo ocorria em `@(Get-EdgeCachePaths + Get-GoogleChromeCachePaths)`: o Chrome nunca entrava.
7. A regex `'^[A-Za-z]:\$'` exige um `$` literal e nunca casava com `C:\`.
8. Sem elevação: `C:\Windows\Temp` não pode ser listado por usuário comum, e o script não explicava nem pedia privilégios.
9. `-SkipAdminCheck` também desligava a verificação de versão do Windows (nome enganoso).
10. Caminhos curtos 8.3 (`C:\Users\JOAOSI~1\...`, comuns quando o nome do usuário tem espaço) não eram expandidos: a deduplicação de `%TEMP%` e `%LOCALAPPDATA%\Temp` falhava.
11. O DISM era chamado sem `/English`, sem checar o código de saída, sem tratar 32/64 bits (`Sysnative`) e com toda a saída despejada no console.
12. O log era sobrescrito a cada execução, só existia com `-LogPath`, era gravado antes da etapa DISM e não registrava erros.
13. Os erros eram todos contados como "Skipped", sem distinguir em uso, acesso negado, inexistente ou inesperado.
14. `$children.Count` em `$null` sob `Set-StrictMode -Version Latest` lança exceção.
15. Arquivo `.ps1` sem BOM e com caracteres não ASCII: o Windows PowerShell 5.1 lê como ANSI.

### Testes e documentação

16. Os testes chamavam `Invoke-SafeCleanup`, que não existe.
17. O dot-source do script nos testes executava o fluxo principal e terminava em `exit 0`, encerrando o Pester.
18. `docs/05-test-results.md` registrava validações que nunca rodaram.

### Launcher (.bat)

19. `where powershell` e a execução de `powershell` pelo nome procuram primeiro no diretório atual e no `PATH`, o que permite sequestro do executável.
20. Um `cmd.exe` de 32 bits iniciaria o PowerShell de 32 bits (redirecionamento de `System32`).
21. Com duplo clique, a janela fechava antes de o usuário ler o resultado.

## Itens que não eram problema

- O launcher já repassava `%*` e citava o caminho do script.
- Prefetch, WinSxS e `SoftwareDistribution` já estavam fora da limpeza.
- Não havia uso de serviços, registro nem `ipconfig /flushdns`.

## Conclusão

A estrutura (BAT fino, lógica em PowerShell) estava correta e foi mantida. O motor de caminhos, a enumeração, a classificação de erros, a elevação, a interface, os logs e os testes foram reescritos. As decisões de arquitetura estão em [03-architecture.md](03-architecture.md).
