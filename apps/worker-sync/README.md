# worker-sync

Sincronização fixa do dev-automation:

- `~/worker/to` -> `danielmaiax:worker/to`: upload dos backups gerados localmente.
- `danielmaiax:worker/from` -> `~/worker/from`: download da fila de entrada.
- `~/worker/from/backup` <-> `danielmaiax:worker/from/backup`: histórico preservado nos dois lados.

## Esteira FROM

O contrato é deliberadamente simples:

1. ChatGPT/Drive coloca `<projeto>--<finalidade>.zip` apenas em `worker/from/`.
2. O worker baixa o ZIP para `~/worker/from/`.
3. O dev-manager importa e confere os arquivos no projeto local.
4. Depois da confirmação, o ZIP **não é apagado**: ele é movido localmente para:

   `~/worker/from/backup/<nome>--AAAAMMDD-HHMMSS--PROCESSED.zip`

5. O worker de backup sobe exatamente esse arquivo para:

   `danielmaiax:worker/from/backup/<mesmo-nome>`

6. Só depois de o backup remoto ser confirmado, o original é removido da raiz remota `worker/from/`.
7. Ao iniciar, o worker de backup reconcilia o histórico remoto e local nos dois sentidos sem apagar histórico.

Se uma importação falhar, o ZIP sai da fila para não entrar em loop, mas continua preservado como:

`<nome>--AAAAMMDD-HHMMSS--FAILED.zip`

Assim as duas raízes ficam limpas e os dois `backup/` convergem para o mesmo histórico. Nenhum ZIP processado depende de uma exclusão local para existir no backup.

Ao executar `dev-manager`, `worker-sync ensure` verifica fingerprint dos scripts/units. Se esta lógica mudar, reinstala e reinicia os workers para a versão atual.
