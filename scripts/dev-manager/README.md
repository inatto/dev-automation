# Dev Manager — módulos do Auto Code Manager

`../auto-code-manager.sh` é apenas o entrypoint compatível. A implementação foi separada por contexto para reduzir acoplamento e facilitar revisão.

A ordem de carregamento é explícita no entrypoint; não carregamos `*.sh` automaticamente. O módulo `900-main.sh` fica por último porque contém os traps, comandos one-shot, inicialização e loop principal.

- `00-runtime.sh`: configuração/estado/validações
- `10-tui-legacy.sh`: fallback ANSI da TUI
- `20-status-logging.sh`: logs/status/lock/pausa
- `30-sounds.sh`: sons
- `40-files-safety.sh`: saída local dos ZIPs e segurança
- `50-project-registry.sh`: catálogo de projetos/agregadores
- `60-project-runtime.sh`: helpers de importação/ZIP
- `70-imports.sh`: importação local de Downloads
- `80-backup-filters.sh`: filtros rsync
- `90-sql-zip.sh`: ZIPs SQL somente por comando manual
- `110-removal-markers.sh`: validação/aplicação de `.remover`
- `130-backups.sh`: geração de backups
- `140-light-monitor.sh`: monitor leve
- `150-inotify-plan.sh`: plano de watches
- `160-dirty-backups.sh`: debounce/alvos sujos
- `170-inotify-runtime.sh`: watcher/eventos
- `180-lifecycle.sh`: encerramento
- `190-config-gitcrypt-guard.sh`: check git-crypt, autocorreção com chave padrão quando necessário e check final
- `900-main.sh`: execução principal
