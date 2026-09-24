# Testes da otimização de Downloads

Base: `dev-automation(20260923-172037).zip`. Testes executados em ambiente Linux isolado, com diretórios e projetos temporários; não houve medição no Ubuntu do usuário nem nos seus projetos reais.

Resultado: 34 scripts passaram; 4 scripts retornaram falha. Os quatro que falharam também retornaram falha quando executados no ZIP de entrada, sem a alteração. Não são tratados como testes aprovados.

## Medições

- Na lista padrão (21 projetos e 1 agregador), uma identificação de ZIP levou 2,615 s no código de entrada e 0,009 s após a alteração. Identificação do projeto proprietário de um evento: 1,479 s e 0,002 s, respectivamente. São medições isoladas de roteamento, não tempos totais de extração.
- Integração real via inotify: 21 projetos e 1.500 arquivos gerando eventos; dois ZIPs pequenos do mesmo projeto importados em 9,70 s, incluindo espera de estabilidade, backup, extração e verificações. Versão mais nova permaneceu no projeto e o backup pré-importação continha a versão anterior. Corrupção e recuperação da cabeça da fila também foram verificadas.
- Prioridade testada entre backups e em uma fila carregada de eventos. Operações de backup/extração já iniciadas não são interrompidas. O intervalo de 1 s não é um limite garantido para concluir uma importação.

## Resultados por script

| Script | Resultado nesta alteração | Resultado na base, quando reexecutado |
|---|---|---|
| `test-auto-code-manager-backup-ignore-safety.sh` | PASSOU | — |
| `test-auto-code-manager-ddl-snapshot-watch.sh` | PASSOU | — |
| `test-auto-code-manager-dev-manager-auto-restart.sh` | PASSOU | — |
| `test-auto-code-manager-dot-config-secrets.sh` | PASSOU | — |
| `test-auto-code-manager-downloads-busy-runtime.sh` | PASSOU | — |
| `test-auto-code-manager-downloads-drain-runtime.sh` | PASSOU | — |
| `test-auto-code-manager-downloads-fifo.sh` | PASSOU | — |
| `test-auto-code-manager-downloads-local.sh` | PASSOU | — |
| `test-auto-code-manager-downloads-priority.sh` | PASSOU | — |
| `test-auto-code-manager-downloads-stability.sh` | PASSOU | — |
| `test-auto-code-manager-event-driven-actions.sh` | PASSOU | — |
| `test-auto-code-manager-explicit-subprojects.sh` | PASSOU | — |
| `test-auto-code-manager-inotify-smart-backup.sh` | PASSOU | — |
| `test-auto-code-manager-light-monitor.sh` | PASSOU | — |
| `test-auto-code-manager-light-subproject-config.sh` | PASSOU | — |
| `test-auto-code-manager-new-secret-unzip.sh` | PASSOU | — |
| `test-auto-code-manager-parent-backups-generic.sh` | FALHOU (código 1) | FALHOU (código 1) |
| `test-auto-code-manager-parent-backups.sh` | FALHOU (código 1) | FALHOU (código 1) |
| `test-auto-code-manager-parent-import-invalid-child.sh` | PASSOU | — |
| `test-auto-code-manager-parent-import.sh` | PASSOU | — |
| `test-auto-code-manager-project-lookup-cache.sh` | PASSOU | — |
| `test-auto-code-manager-protected-config-json.sh` | PASSOU | — |
| `test-auto-code-manager-protected-config-unzip.sh` | FALHOU (código 1) | FALHOU (código 1) |
| `test-auto-code-manager-qualified-subproject-import.sh` | PASSOU | — |
| `test-auto-code-manager-runtime-no-auto.sh` | PASSOU | — |
| `test-auto-code-manager-runtime-restart.sh` | PASSOU | — |
| `test-auto-code-manager-skills-md.sh` | PASSOU | — |
| `test-auto-code-manager-subproject-roundtrip.sh` | PASSOU | — |
| `test-auto-code-manager-symlink-portability.sh` | PASSOU | — |
| `test-auto-code-manager-unique-project-key.sh` | PASSOU | — |
| `test-auto-code-manager-unzip-permissions.sh` | PASSOU | — |
| `test-auto-code-manager-wsl-dual-downloads.sh` | PASSOU | — |
| `test-auto-code-manager-zip-names.sh` | PASSOU | — |
| `test-auto-code-manager-zip-symlink-safety.sh` | FALHOU (código 1) | FALHOU (código 1) |
| `test-chromes-rerun-managed.sh` | PASSOU | — |
| `test-dev-manager-missing-projects-no-loop.sh` | PASSOU | — |
| `test-terminals-rerun-managed-realign.sh` | PASSOU | — |
| `test-terminals-visible-tabs.sh` | PASSOU | — |

Os testes antigos de agregadores esperam listas de arquivos que não incluem `skills.md`. Os outros dois retornam falha também na base; não foram modificados para mascarar seus resultados. As rotinas de proteção de segredos, symlinks, permissões e conferência do conteúdo não foram removidas ou relaxadas.

Os scripts de `terminals` e `chromes` e as configurações de projetos da base foram preservados byte a byte. A variável `COMMAND_INTERVAL_SECONDS` da entrega anterior permanece intacta.
