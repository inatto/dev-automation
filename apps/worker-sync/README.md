# worker-sync

Fila assíncrona entre a máquina local e Google Drive.

- `~/worker/to` -> `danielmaiax:worker/to`: snapshots enviados pela máquina.
- `danielmaiax:worker/from` -> `~/worker/from`: fila de entrada.
- `~/worker/from/backup` <-> `danielmaiax:worker/from/backup`: histórico.

## FROM transacional

O downloader não faz mais `rclone copy` da pasta inteira.

1. Lista apenas os ZIPs da raiz remota.
2. Antes de baixar, cria um claim local e move server-side o ZIP para
   `worker/from/.processing/<token>/<nome>`.
3. Baixa somente aquele arquivo para `~/worker/from/.incoming`.
4. Confere MD5 quando disponível e publica em `~/worker/from` por `mv` atômico.
5. O dev-manager importa o ZIP e move para `~/worker/from/backup/...--PROCESSED.zip`.
6. O backup worker sobe o histórico e apaga somente o caminho único de
   `.processing` guardado no claim.
7. Uma versão nova com o mesmo nome pode chegar à raiz remota sem ser apagada
   pelo cleanup da versão anterior.

Toda chamada de rede possui timeout. Se uma operação cair no meio, o claim e
`.processing` permitem retomada idempotente no ciclo seguinte.

A deduplicação automática do histórico atua somente em `*--PROCESSED.zip` e
remove cópias com MD5 idêntico; SAFE/ROLLBACK/SUPERSEDED não entram na limpeza.
