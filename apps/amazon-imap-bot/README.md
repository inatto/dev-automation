# Amazon IMAP Bot

Monitor de caixas IMAP Amazon com painel TUI, confirmação automática gerada pela OpenAI e envio via Amazon SES.

## Fluxo

1. Consulta mensagens `UNSEEN` via IMAP.
2. Deduplica por `Message-ID` no SQLite local.
3. Ignora mensagens automáticas, listas, bounces e remetentes próprios.
4. Toca `assets/sounds/soft-notification.wav`.
5. Envia assunto + corpo textual para a OpenAI.
6. A IA gera **somente confirmação de recebimento**, sem resolver o assunto.
7. Responde via SES usando o perfil em `~/.aws`.
8. Registra entrada, resposta e `MessageId` do SES no SQLite.

## Configuração

Edite `.config/amazon-imap-bot/settings.env`. A chave OpenAI pode ficar vazia: nesse caso o app lê `OPENAI_API_KEY` de `.config/gpt-console/settings.env`.

Exemplo de múltiplas caixas:

```env
IMAP_ACCOUNTS_JSON='[{"email":"suporte@example.com","password":"SENHA","display_name":"Suporte","enabled":true}]'
```

A `.config/**` já é protegida por git-crypt neste projeto.

## Uso

```bash
bash apps/amazon-imap-bot/install.sh
amazon-imap-bot --doctor
amazon-imap-bot
```

No painel: `R` força uma verificação; `Q` encerra.

Para teste pontual:

```bash
amazon-imap-bot --once
```
