# 06 — Checklist de release

Legenda: `[x]` verificado · `[ ]` pendente (exige Windows cliente ou interação manual). CI: workflow *Windows validation* no GitHub Actions.

## Código

- [x] Launcher `.bat` mínimo, com caminho absoluto do PowerShell 64 bits e repasse de argumentos
- [x] Lógica em um único `.ps1`, UTF-8 com BOM e CRLF
- [x] Modo padrão = Limpeza segura; avançado separado e nunca pré-selecionado
- [x] `-DryRun` não chama nenhuma exclusão (teste automatizado + fumaça)
- [x] Prefetch fora do catálogo (teste automatizado)
- [x] WinSxS só via DISM, sem `/ResetBase` (guard rail no código)
- [x] `SoftwareDistribution`, `Installer`, pastas pessoais e Roaming recusados pela política (teste)
- [x] Raízes perigosas recusadas, inclusive com o Windows em `D:` e com as variáveis vazias (teste)
- [x] Categoria abortada por inteiro quando uma variável resolve para local protegido (teste + fumaça)
- [x] Links e junctions nunca seguidos nem apagados; troca por link após a varredura detectada (teste)
- [x] Arquivos recentes protegidos; idade baseada em criação/modificação (teste)
- [x] Arquivos em uso ignorados sem abortar (lógica testada com classificação de erro; bloqueio real só no Windows)
- [x] Pastas vazias removidas sem recursão; a raiz nunca é removida (teste)
- [x] Espaço "recuperado" conta só exclusões confirmadas (teste de bytes)
- [x] Log legível + JSON, invariantes, sanitizados, com retenção de 30 execuções (fumaça)
- [x] Elevação: oferta única, UAC cancelado tratado, sem loop, argumentos preservados (testes de argumentos; fluxo UAC pendente)
- [x] Sem serviços, registro (só leitura), DNS ou "otimizações" (guard rail)
- [x] PSScriptAnalyzer: sem incompatibilidades com o 5.1/7.0 além dos cmdlets de Delivery Optimization, cuja disponibilidade é verificada em tempo de execução
- [x] README atualizado; `docs/` não é necessária para executar

## Validação no Windows (antes de publicar)

Roteiro detalhado em [04-test-plan.md](04-test-plan.md#roteiro-manual-no-windows-10-e-no-windows-11-antes-de-publicar).

- [x] Pester completo no Windows PowerShell 5.1 (0 pulados) — CI, Server 2022 e 2025
- [x] Pester completo no PowerShell 7 — CI, Server 2022 e 2025
- [ ] Windows 10 22H2 cliente: roteiro manual 2–16 (kernel equivalente validado no Server 2022)
- [ ] Windows 11 24H2 cliente: roteiro manual 2–16 (kernel equivalente validado no Server 2025)
- [x] Usuário padrão (sem administrador) — CI
- [ ] Conta administradora com prompt UAC interativo (aceitar e cancelar)
- [x] Arquivo bloqueado real (`InUse`) — CI
- [x] Junction e link simbólico reais em `%TEMP%` — CI
- [ ] Windows em pt-BR (interface pt validada no CI em Windows en-US)
- [x] Delivery Optimization: consulta oficial sem erro — CI (cache vazio nos runners)
- [x] DISM: análise e interpretação ("recomendado" e "não necessário") — CI
- [ ] DISM: `StartComponentCleanup` real e código 3010
- [ ] Lixeira com itens: tamanho antes/depois (consulta vazia validada no CI)
- [ ] Pasta do projeto com `%` no nome (não verificável no Wine)

## Política de release

Publicar somente se: o modo seguro permanecer conservador, os alvos padrão forem só pastas temporárias, os testes CRITICAL passarem em Windows real e nenhum item da seção "Validação no Windows" falhar.
