# Amazon IMAP Bot

Monitor de caixas IMAP Amazon com painel TUI navegável, confirmação automática gerada pela OpenAI e envio via Amazon SES.

## Fluxo

1. Consulta mensagens `UNSEEN` via IMAP.
2. Deduplica por `Message-ID` no SQLite local.
3. Ignora mensagens automáticas, listas, bounces e remetentes próprios. Mensagens sem corpo continuam válidas e recebem confirmação genérica.
4. Toca `assets/sounds/soft-notification.wav`.
5. Envia remetente, assunto e corpo textual para a OpenAI.
6. A IA gera **somente confirmação de recebimento**, sem resolver o assunto.
7. Sanitiza cabeçalhos externos antes de construir a resposta para impedir CR/LF em Subject, Message-ID, References e endereços.
8. Responde via SES usando o perfil em `~/.aws`.
9. Registra entrada, resposta, erros, UID IMAP, `MessageId` do SES e console operacional no SQLite.

## TUI

O painel possui quatro áreas:

- `F1 ENTRADA`: mensagens recebidas pelo monitor, com data, remetente, assunto e status.
- `F2 RESPOSTAS`: respostas geradas/enviadas, inclusive tentativas com erro.
- `F3 CONSOLE`: chamadas IMAP, GPT e SES, sem exibir senhas, API keys ou credenciais AWS.
- `F4 CONTAS`: estado de cada caixa monitorada.

Use `↑/↓` para navegar, `Enter` para abrir o conteúdo completo de um e-mail, `PgUp/PgDn` para paginação, `R` para verificar imediatamente e `Q` para sair. `Tab` ou `←/→` também alternam as áreas.

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

Para teste pontual:

```bash
amazon-imap-bot --once
```
