# Worker Sync

Canal unidirecional de arquivos via Google Drive.

```text
/home/daniel/worker/to -> danielmaiax:worker/to

danielmaiax:worker/from -> /home/daniel/worker/from
```

`to` somente sobe. `from` somente baixa. O comando usa `rclone copy`, portanto não espelha exclusões do destino.

## Comandos

```bash
worker-sync restart
worker-sync status
worker-sync test
worker-sync logs
worker-sync stop
worker-sync start
```

O upload usa `inotifywait` e dispara quando há criação/gravação/movimentação de arquivo em `/home/daniel/worker/to`. O download consulta `danielmaiax:worker/from` a cada 10 segundos.
