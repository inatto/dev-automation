# worker-sync

Fila simples entre a máquina local e o Google Drive.

- `~/worker/to` -> `danielmaiax:worker/to`: snapshots enviados pela máquina.
- `danielmaiax:worker/from` -> `~/worker/from`: fila de entrada.
- `~/worker/from/backup` -> `danielmaiax:worker/from/backup`: histórico processado.

## FROM: uma regra, um nome

O nome do ZIP não muda em nenhuma etapa. Use sempre um codinome único, por
exemplo `dev-automation-worker-nome-unico.zip`.

1. Drive: `worker/from/dev-automation-worker-nome-unico.zip`.
2. Downloader copia para `~/worker/from/dev-automation-worker-nome-unico.zip`.
3. O dev-manager extrai/importa o ZIP.
4. O mesmo arquivo é movido localmente para
   `~/worker/from/backup/dev-automation-worker-nome-unico.zip`.
5. O worker de backup sobe o mesmo arquivo para
   `worker/from/backup/dev-automation-worker-nome-unico.zip`.
6. Depois de confirmar o backup remoto, remove da raiz remota
   `worker/from/dev-automation-worker-nome-unico.zip`.

Não existe `.processing`, claim remoto, timestamp no nome, `--PROCESSED`,
`--FAILED`, dedupe com renomeação nem criação automática de nome alternativo.
Se um nome já existir no backup com conteúdo diferente, isso é colisão de
codinome e o worker para naquele arquivo em vez de inventar outro nome.
