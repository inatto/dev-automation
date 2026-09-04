# Amazon IMAP Bot — Web ERP

Versão: `2026.09.02-V3`

A interface de terminal foi substituída por Web + FastAPI. O monitor IMAP continua no backend Python e o Oracle continua sendo o armazenamento operacional e o catálogo relacional de funções.

## Estrutura

- `apps/api`: FastAPI, monitor IMAP, OpenAI, SES, Oracle, filas e ações.
- `apps/web`: Astro, interface ERP responsiva e proxy same-origin `/api`.
- `deploy/local`: setup/start/test local.
- `deploy/remote`: rsync, setup/start/test remoto e services systemd.
- `VERSION`: versão exibida permanentemente no canto inferior direito da Web.
- `scripts/bump-version.py`: atualiza a data e incrementa `Vn`.

## Portas

- Web: `4115`
- API: `8115`

## Local

```bash
cd /home/daniel/Code/bots/dev-automation/apps/amazon-imap-bot
./deploy/local/setup.sh
```

Depois acesse `http://127.0.0.1:4115/`.

## Fluxos disponíveis na Web

Entrada IMAP, detalhes, geração/refação de respostas, contexto por arquivos da pasta Code, não responder, remoção assíncrona, aprovação individual, chave global de envio externo, respostas, console de eventos, histórico de API, teste ZIP, catálogo de funções e estado das contas.

## Arquivos legados que podem ser removidos depois de validar a Web

Na raiz antiga `apps/amazon-imap-bot/`, se ainda existirem após a aplicação do ZIP, podem ser apagados: `tui.py`, `cli.py`, `mobile_api.py`, `__main__.py`, `entrada.txt`, `RETORNO_OPENAI.txt`, `tests/test_core.py` e a `.venv` antiga. `run.sh` e `install.sh` foram removidos deste subprojeto. O comando global `amazon-imap-bot` é responsabilidade exclusiva do Dev Automation e deve apontar para `deploy/local/start.sh`. Os módulos Python de negócio antigos da raiz também podem ser removidos depois da validação porque agora vivem em `apps/api`.



## Encerramento local

O encerramento cancela conexões IMAP ativas, limita o timeout de rede IMAP a 5 segundos por padrão, dá até 3 segundos para o Uvicorn encerrar requisições e força os processos locais somente se ignorarem o encerramento normal.


## Fila Web durável

As ações assíncronas iniciadas pela Web são registradas no Oracle antes do HTTP 202. O identificador `db-N` pode ser consultado em `/api/v1/actions/{id}` mesmo se outra instância/processo atender o polling ou após perda do cache em memória. Os registros internos `action:*` não aparecem no histórico visual de execuções OpenAI.


## Respostas manuais repetidas (2026.09.02-V6)

O fluxo automático continua idempotente e não responde novamente a uma mensagem
que já teve resposta enviada.

A ação manual **Gerar novamente** é deliberadamente diferente: depois que a
resposta anterior estiver `SENT`, o operador pode gerar outra resposta para o
mesmo e-mail original. Cada geração manual posterior cria um novo registro de
saída; a resposta anterior permanece intacta no histórico.

Enquanto uma resposta estiver `send-queued` ou `sending`, uma nova geração é
bloqueada até o envio atual terminar. Para destinatário externo, cada nova
resposta volta a exigir aprovação individual.


## Correção Web 2026.09.03-V7

Corrigida a renderização da Entrada: a variável legada `terminalReply` havia sido
removida na V6, mas uma referência residual permanecia no botão de geração.
Mensagem já `REPLIED` volta a exibir **Gerar novamente**; somente envio em
andamento ou `NÃO RESPONDER` desabilitam a ação.
