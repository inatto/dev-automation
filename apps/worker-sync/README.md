# worker-sync

Fila de arquivos do `dev-automation`:

- `~/worker/to` -> `danielmaiax:worker/to`: somente upload. Mudança local dispara `rclone copyto` do arquivo alterado.
- `danielmaiax:worker/from` -> `~/worker/from`: somente download, consultado por timer systemd a cada 5s após o término da rodada anterior.

O Auto Code Manager usa as mesmas pastas:

- backups ZIP são gerados em `~/worker/to`;
- ZIPs recebidos são importados exclusivamente de `~/worker/from`.

`Downloads` e ZIPs dentro de `Code` não fazem mais parte do fluxo.

## Integração com dev-manager

Ao executar `dev-manager`, o comando chama `worker-sync ensure` internamente antes
do Auto Code Manager. A operação é idempotente: units corretos e workers já ativos
não são reiniciados. A TUI mostra `WORKER TO: OK/PARADO` e `WORKER FROM: OK/PARADO`.
