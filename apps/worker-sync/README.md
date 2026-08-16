# worker-sync

Esteira de arquivos do `dev-automation`:

- `~/worker/to` -> `danielmaiax:worker/to`: somente upload dos backups gerados localmente.
- `danielmaiax:worker/from` -> `~/worker/from`: somente download da fila de entrada, consultada por timer systemd a cada 2s.
- `danielmaiax:worker/from/backup`: histórico remoto dos ZIPs já processados; **não é baixado para a fila local**.

## Esteira FROM

O nome de entrada deve ser descritivo e começar pelo projeto:

```text
<projeto>--<o-que-faz>.zip
<projeto-pai>--<subprojeto>--<o-que-faz>.zip
```

Exemplos:

```text
dev-automation--worker-from-backup-esteira.zip
dev-automation--exec-agent--corrige-timeout.zip
orbital-app--corrige-login-tenant.zip
```

Depois que o Auto Code Manager processa e remove o ZIP local da fila, o watcher **não apaga o original remoto**. Ele move o arquivo para:

```text
worker/from/backup/<nome-original>--AAAAMMDD-HHMMSS--PROCESSED.zip
```

Exemplo:

```text
dev-automation--worker-from-backup-esteira--20260816-195500--PROCESSED.zip
```

Assim `worker/from` fica sendo apenas fila pendente e `worker/from/backup` vira o histórico da esteira.

O Auto Code Manager usa as mesmas pastas:

- backups dos projetos são gerados em `~/worker/to`;
- ZIPs recebidos são importados exclusivamente da raiz de `~/worker/from`;
- `backup/` nunca entra novamente na fila.

`Downloads` e ZIPs dentro de `Code` não fazem mais parte do fluxo.

## Integração com dev-manager

Ao executar `dev-manager`, o comando chama `worker-sync ensure` internamente antes do Auto Code Manager. A operação é idempotente e reinstala/reinicia o worker quando scripts ou units do próprio `worker-sync` mudam. A TUI mostra `WORKER TO: OK/PARADO` e `WORKER FROM: OK/PARADO`.
