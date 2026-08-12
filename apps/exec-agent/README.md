# Exec Agent

Agente pessoal multitarefa dentro do `dev-automation`.

Primeira missão: autenticar na ContaJá, buscar automaticamente o código de verificação no Gmail e abrir o fluxo **Emitir NFS-e**. Nesta etapa o agente para antes de preencher ou emitir qualquer nota.

## Comandos

```bash
exec-agent setup
exec-agent contaja-login
exec-agent test
```

## Gmail

Use OAuth do Google com escopo somente de leitura (`gmail.readonly`). Informe o JSON OAuth em `GMAIL_CLIENT_SECRET_FILE`. No primeiro uso o Google abrirá a autorização; depois o token fica apenas em `var/gmail-token.json` e não entra no ZIP/Git.
