# Clean Windows Temp Files

Limpeza **segura** de arquivos temporários para **Windows 10 e Windows 11**.

A ferramenta analisa os locais onde o Windows e os programas deixam lixo de verdade, mostra quanto espaço pode ser recuperado e só apaga o que você autorizar. Ela não é um "otimizador": não mexe em serviços, registro, Prefetch nem em caches que deixam o Windows mais rápido.

> Liberar espaço ajuda principalmente computadores com o disco quase cheio. Apagar caches de forma indiscriminada **não** deixa um computador mais rápido; muitas vezes deixa mais lento até o Windows reconstruí-los.

---

## Como usar

1. Baixe a pasta do projeto (mantenha `clean-win-temp-files.bat` e `clean-win-temp-files.ps1` juntos).
2. Dê **duplo clique** em `clean-win-temp-files.bat`.
3. Se o Windows perguntar, aceite executar como administrador (recomendado; veja [por quê](#por-que-ele-pede-administrador)).
4. Revise a lista e pressione **Enter** para limpar o que está marcado.

```
  Clean Windows Temp Files  2.0.0
  Windows 11 Pro 24H2 · build 26100.2033 · Administrador

  LIMPEZA SEGURA · recomendada
  [x]  1  Arquivos temporários (sua conta)           852 MB  12.034 arquivos
  [x]  2  Arquivos temporários do Windows            331 MB  402 arquivos
  [x]  3  Temporários de apps da Microsoft Store    12,4 MB  88 arquivos
  [ ]  4  Cache da Otimização de Entrega            42,9 MB  pequeno — o Windows já gerencia

  ──────────────────────────────────────────────────────────────────────────
  Selecionado                                       1,17 GB
  Mantidos por segurança: 233 arquivos recentes (53,4 MB) — podem estar em uso

  [Enter] Limpar selecionados   [1-4] Marcar/desmarcar   [A] Opções avançadas   [Q] Sair
```

Ao final aparece um resumo: espaço recuperado, arquivos removidos, arquivos ignorados por estarem em uso e o espaço livre do disco antes e depois.

A interface fica em português ou inglês conforme o idioma do Windows (`-Language pt` ou `-Language en` forçam um deles).

### Pelo PowerShell

```powershell
.\clean-win-temp-files.ps1                     # interativo (igual ao duplo clique)
.\clean-win-temp-files.ps1 -DryRun             # simulação: mostra o que seria apagado, não apaga nada
.\clean-win-temp-files.ps1 -Mode Advanced      # já mostra as opções avançadas
.\clean-win-temp-files.ps1 -Yes                # sem perguntas: limpa só a seleção segura
.\clean-win-temp-files.ps1 -Yes -Include CrashDumps -Exclude WindowsTemp
.\clean-win-temp-files.ps1 -ListCategories     # lista as categorias e seus IDs
Get-Help .\clean-win-temp-files.ps1 -Detailed  # ajuda completa
```

Os mesmos parâmetros funcionam no `.bat`: `clean-win-temp-files.bat -DryRun`.

Se o PowerShell bloquear o script por política de execução, use o `.bat` (ele usa `-ExecutionPolicy Bypass` somente para esse processo) ou execute `powershell -ExecutionPolicy Bypass -File .\clean-win-temp-files.ps1`.

---

## Windows suportados

| Sistema | Situação |
| --- | --- |
| Windows 11 (todas as versões) | Suportado |
| Windows 10 (build 10240 ou superior) | Suportado |
| Windows Server | Funciona, com aviso; não é oficialmente suportado |
| Windows 8.1 ou anterior | Recusado |

Requer o **Windows PowerShell 5.1**, que já vem no Windows 10 e 11. Também funciona no PowerShell 7. Windows instalado em outra unidade (por exemplo `D:\Windows`), nomes de usuário com espaços ou acentos e Windows em qualquer idioma são suportados: os caminhos vêm das variáveis e APIs do sistema, nunca de `C:\` fixo.

---

## Por que ele pede administrador

O próprio script pergunta, uma única vez, se pode reiniciar como administrador. Os privilégios só são necessários para:

- **Temporários do Windows** (`%SystemRoot%\Temp`);
- **Cache da Otimização de Entrega** (só o próprio Windows pode limpá-lo);
- **Despejos de memória do sistema** (`MEMORY.DMP`, `Minidump`) e relatórios de erro de todo o computador;
- **Limpeza de componentes (DISM)**.

Se você recusar ou cancelar o UAC, a ferramenta continua só com os seus arquivos. Ela nunca entra em loop pedindo elevação.

---

## Limpeza segura (padrão)

Itens com risco extremamente baixo. São pré-selecionados.

| Categoria | O que remove | Regra de segurança |
| --- | --- | --- |
| Arquivos temporários (sua conta) | Conteúdo de `%TEMP%`, `%TMP%` e `%LOCALAPPDATA%\Temp` (a mesma pasta é analisada uma única vez) | Só arquivos com **mais de 24 horas**; a pasta Temp em si nunca é apagada |
| Arquivos temporários do Windows | Conteúdo de `%SystemRoot%\Temp` | Só arquivos com **mais de 3 dias** (instaladores e serviços podem aguardar uma reinicialização) |
| Temporários de apps da Microsoft Store | `Packages\*\TempState` e `Packages\*\AC\Temp` | Pastas que, por contrato, o Windows pode esvaziar a qualquer momento; só arquivos com mais de 24 horas |
| Cache da Otimização de Entrega | Pacotes de atualização guardados para compartilhar com outros PCs | Removido **pelo próprio Windows** (`Delete-DeliveryOptimizationCache`); só é pré-selecionado acima de 100 MB, porque o Windows já gerencia esse cache |

## Limpeza avançada (opcional)

Pressione **A** na tela principal. Nada aqui é pré-selecionado, e cada item mostra o efeito colateral.

| Categoria | O que remove | Efeito colateral |
| --- | --- | --- |
| Lixeira | Todos os itens da Lixeira (API oficial do Windows) | **Os itens não poderão mais ser restaurados.** Pede confirmação |
| Despejos de falha e relatórios antigos | `MEMORY.DMP`, `Minidump`, `LiveKernelReports`, `CrashDumps` e relatórios do Windows Error Reporting | Só com **mais de 30 dias**; os recentes ficam para diagnosticar telas azuis e travamentos |
| Cache dos navegadores | Somente `Cache`, `Code Cache` e `GPUCache` (Chrome, Edge, Brave, Vivaldi, Opera) e `cache2` (Firefox) | Sites carregam mais devagar no início. **Logins, cookies, senhas, histórico e favoritos não são tocados.** Navegador aberto é ignorado |
| Cache de shaders DirectX e GPU | `D3DSCache` e caches de shaders dos drivers NVIDIA, AMD e Intel | Jogos podem engasgar até os shaders serem recompilados. Útil após trocar de driver ou se houver problemas gráficos |
| Limpeza de componentes (DISM) | Versões substituídas de componentes do Windows Update, via `DISM /StartComponentCleanup` | Lenta (5 a 30 min). Antes, o Windows analisa e só limpa se recomendar. **Nunca usa `/ResetBase`**, então as atualizações continuam desinstaláveis |

---

## O que nunca é apagado

| Item | Por quê |
| --- | --- |
| **Prefetch** | O Windows usa esses arquivos para acelerar a inicialização e a abertura de programas, e ele mesmo os mantém e limita. Apagá-los força uma reconstrução e deixa o sistema temporariamente **mais lento**. Não há ganho real, então a ferramenta não oferece essa opção |
| WinSxS (Component Store) | Só é reduzido pela ferramenta oficial (DISM); apagar arquivos ali quebra o Windows |
| `SoftwareDistribution` (Windows Update) | Esta é uma ferramenta de limpeza, não de reparo do Windows Update |
| `Windows\Installer`, DriverStore, System32, SysWOW64 | Necessários para reparar e desinstalar programas e drivers |
| Windows.old, `$WINDOWS.~BT` | Permitem voltar à versão anterior; o Windows remove sozinho no prazo |
| Downloads, Documentos, Área de Trabalho, Imagens, Vídeos, Músicas, OneDrive | Dados pessoais nunca são "lixo", mesmo que antigos |
| Senhas, cookies, sessões, histórico, favoritos | Só o cache descartável dos navegadores é opcional |
| Cache de miniaturas e de ícones | O Explorador os mantém abertos e os reconstrói; apagar só deixa as pastas mais lentas por um tempo |
| Pontos de restauração, cópias de sombra, `pagefile.sys`, `hiberfil.sys`, `swapfile.sys` | Recuperação e funcionamento do sistema |
| Registro, serviços, DNS | Nada de "registry cleaner", desativação de serviços ou `ipconfig /flushdns`: não liberam espaço e podem causar problemas |

A justificativa técnica de cada item está em [docs/02-safety-matrix.md](docs/02-safety-matrix.md).

---

## Segurança

- **Simulação (`-DryRun`)**: analisa, calcula e mostra os maiores itens que seriam apagados, sem apagar nada.
- **Lista de proteção**: o script recusa como pasta de limpeza a raiz de qualquer unidade, `%SystemRoot%`, `C:\Windows`, `C:\Users`, `Program Files`, `ProgramData`, perfis, `AppData`, as pastas pessoais e tudo o que estiver acima delas. Isso vale mesmo se as variáveis de ambiente estiverem vazias ou erradas, ou se o Windows estiver em outra unidade.
- **Categoria abortada por inteiro**: se uma variável (como `%TEMP%`) apontar para um local protegido, nada daquela categoria é tocado e o motivo aparece na tela e no log.
- **Links nunca são seguidos**: junctions, links simbólicos e pontos de montagem são ignorados. Antes de apagar cada arquivo, o caminho é conferido de novo para detectar uma pasta trocada por link depois da análise.
- **Caminhos tratados como dados**: nada de `Remove-Item -Recurse`, `rd /s` ou comandos montados com texto. Cada arquivo é apagado individualmente pela API do .NET e cada pasta só é removida se estiver vazia.
- **Arquivos em uso são ignorados**: um arquivo bloqueado nunca é forçado e não interrompe a limpeza.
- **Arquivos recentes são mantidos**: a idade considera a data de criação *e* de modificação, então um arquivo recém-extraído com data antiga também é protegido.
- **Operações pendentes de reinicialização**: arquivos listados em `PendingFileRenameOperations` não são apagados.
- **Placeholders do OneDrive/nuvem** nunca são tocados.
- **Espaço real**: o espaço recuperado conta apenas arquivos cuja remoção foi confirmada.

## Logs

Cada execução grava, em `%LOCALAPPDATA%\CleanWinTempFiles\Logs\`:

- `cleanup-AAAAMMDD-HHMMSS.log`: log legível (versão, Windows, categorias, arquivos e bytes removidos, ignorados, erros, duração);
- `cleanup-AAAAMMDD-HHMMSS.json`: o mesmo resumo em formato estruturado.

Os caminhos do perfil aparecem como `%USERPROFILE%`/`%LOCALAPPDATA%`, e os nomes de arquivos apagados não são registrados. As 30 execuções mais recentes são mantidas. Use `-LogPath <arquivo>` para outro local ou `-NoLog` para desativar.

## Parâmetros

| Parâmetro | Descrição |
| --- | --- |
| `-DryRun` | Simulação; nada é apagado |
| `-Mode Safe\|Advanced` | `Advanced` já analisa e exibe as opções avançadas |
| `-Include <IDs>` | Seleciona categorias extras (ex.: `RecycleBin,CrashDumps`) |
| `-Exclude <IDs>` | Desmarca categorias |
| `-Yes` | Sem perguntas (para tarefas agendadas). Sem `-Include`, só limpa a seleção segura |
| `-NoElevate` | Não oferece reiniciar como administrador |
| `-ListCategories` | Lista os IDs: `UserTemp`, `WindowsTemp`, `StoreAppTemp`, `DeliveryOptimization`, `RecycleBin`, `CrashDumps`, `BrowserCache`, `ShaderCache`, `ComponentStore` |
| `-LogPath`, `-NoLog` | Local do log / desativa o log |
| `-Language Auto\|en\|pt` | Idioma da interface |
| `-NoColor`, `-Ascii` | Sem cores / só caracteres ASCII (a variável `NO_COLOR` também é respeitada) |

Códigos de saída: `0` concluído (arquivos em uso ignorados não contam como erro), `1` concluído com erros inesperados, `2` ambiente não suportado ou parâmetro inválido.

## Testes

```powershell
Install-Module Pester -MinimumVersion 5.0 -Scope CurrentUser -SkipPublisherCheck
Invoke-Pester -Path .\tests -Output Detailed
```

A cada push, o GitHub Actions roda a suíte e uma validação de ponta a ponta com o programa real (`tests/ci-validate.ps1`) no Windows Server 2022 e 2025, com PowerShell 5.1 e 7. **Não execute `ci-validate.ps1` no seu computador**: ele faz uma limpeza real.

Os testes criam fixtures temporárias (arquivos antigos e recentes, somente leitura, nomes com espaço e Unicode, links, pastas aninhadas e vazias, arquivos bloqueados) e nunca tocam em dados reais. O plano e os resultados estão em [docs/04-test-plan.md](docs/04-test-plan.md) e [docs/05-test-results.md](docs/05-test-results.md).

A pasta `docs/` é só documentação de desenvolvimento: o programa não depende dela.

## Dica

Para manter os temporários sob controle automaticamente, ative o **Sensor de Armazenamento** em *Configurações > Sistema > Armazenamento*. Esta ferramenta complementa esse recurso, sem substituí-lo.

---

## English summary

A safe temporary-file cleaner for Windows 10/11. Double-click `clean-win-temp-files.bat`, review the list and press Enter. The safe cleanup removes old files (24 h+) from your `%TEMP%`, old files (3 days+) from `%SystemRoot%\Temp`, Store app temp folders and, through Windows itself, a large Delivery Optimization cache. Optional items (Recycle Bin, 30-day-old crash dumps, browser caches, shader caches, DISM component cleanup without `/ResetBase`) are never pre-selected. Prefetch, WinSxS, Windows Update data, personal folders and browser profiles are never touched. Junctions and symlinks are never followed, locked files are skipped, and `-DryRun` shows what would be removed without deleting anything. The UI follows the Windows language (English or Portuguese).
