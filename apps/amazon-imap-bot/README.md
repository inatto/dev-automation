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
10. Mantém estados visíveis durante o fluxo: `RECEBIDO`, `ANALISANDO`, `ENTENDIDO`, `AGUARDANDO CONF.`, `ENVIANDO`, `RESPONDIDO`, `IGNORADO` e `ERRO RESPOSTA`.

## TUI

O painel possui cinco áreas:

- `F1 ENTRADA`: mensagens recebidas pelo monitor, com data, remetente, assunto e status.
- `F2 RESPOSTAS`: respostas geradas/enviadas, inclusive tentativas com erro.
- `F3 CONSOLE`: chamadas IMAP, GPT e SES, sem exibir senhas, API keys ou credenciais AWS.
- `F4 CONTAS`: estado de cada caixa monitorada.
- `F6 API`: configuração efetiva da OpenAI e pilha/histórico das chamadas de API (e-mail e teste ZIP), com estado, modelo, nível de raciocínio, tempo, Response ID e arquivo de retorno.

Use `↑/↓` para navegar, `Enter` para abrir detalhes, `PgUp/PgDn` para paginação, `F5` ou `R` para verificar o IMAP imediatamente e `Q` para sair. `Tab` ou `←/→` também alternam as áreas. Na aba `F6 API`, pressione `T` para executar o teste de ZIP.

Na aba `F1 ENTRADA`, `D` remove a mensagem. A TUI sempre exige confirmação e diferencia visualmente os casos:

- `RESPONDIDO`: confirmação verde informando que a resposta já foi enviada.
- `ERRO RESPOSTA` ou qualquer mensagem ainda não respondida: alerta vermelho antes da remoção.
- `IGNORADO` / `AGUARDANDO CONF.`: alerta amarelo informando que não houve resposta.
- Estados em processamento (`ANALISANDO`, `ENTENDIDO`, `ENVIANDO`, `EXECUTANDO`) bloqueiam a remoção até a etapa terminar.

A remoção move o e-mail no servidor IMAP para a pasta marcada como `\Trash`. Se o servidor não anunciar essa pasta, usa `Deleted Items`. A linha fica oculta da Entrada, mas o registro de deduplicação é preservado no SQLite para impedir reprocessamento acidental. As respostas continuam em `F2 RESPOSTAS` como histórico do que foi enviado.

## Configuração

Edite `.config/amazon-imap-bot/settings.env`. A chave OpenAI pode ficar vazia: nesse caso o app lê `OPENAI_API_KEY` de `.config/gpt-console/settings.env`.

Exemplo de múltiplas caixas:

```env
IMAP_ACCOUNTS_JSON='[{"email":"suporte@example.com","password":"SENHA","display_name":"Suporte","enabled":true}]'
# Opcional. Deixe vazio para detectar a pasta \Trash automaticamente.
IMAP_TRASH_FOLDER=
```

Configuração da OpenAI disponível em `settings.env`:

```env
OPENAI_MODEL=gpt-5.6
OPENAI_REASONING_EFFORT=medium
OPENAI_BASE_URL=https://api.openai.com/v1
OPENAI_TIMEOUT_SECONDS=300
OPENAI_OUTPUT_DIR=~/Downloads
# Opcional. Se não existir, o teste cria automaticamente um ZIP mínimo aqui.
OPENAI_TEST_ZIP=.config/amazon-imap-bot/api-test-input.zip
```

`gpt-5.6` é o alias do modelo flagship GPT-5.6 Sol. O nível de raciocínio fica explícito e configurável. O teste ZIP faz upload como `user_data`, disponibiliza o ZIP para o Code Interpreter, exige a criação de um novo ZIP, localiza a `container_file_citation` retornada e baixa imediatamente o arquivo para `OPENAI_OUTPUT_DIR`. Por padrão, em `/home/daniel`, isso resulta em `/home/daniel/Downloads/amazon-imap-bot-api-test-return.zip`. Se o nome já existir, adiciona data/hora para não sobrescrever.

A aba API registra também as chamadas normais usadas para responder e-mails. Assim é possível ver uma chamada em `AGUARDANDO`, seguida de `CONCLUÍDO` ou `ERRO`, e o tempo total ao finalizar. A chave da API nunca é exibida; aparece apenas `CONFIGURADA` ou `AUSENTE`.

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

## Funções acionadas por e-mail

As funções executáveis por e-mail são autorizadas fora do prompt da IA, em um mapa local:

```text
.config/amazon-imap-bot/functions.json
```

O caminho pode ser alterado em `settings.env` com:

```env
FUNCTIONS_CONFIG=.config/amazon-imap-bot/functions.json
```

A configuração inicial autoriza `danielmaiax@gmail.com` somente para `api_zip_test`. Outros remetentes não executam essa função, mesmo que escrevam o mesmo comando. O arquivo foi estruturado para que cada remetente possa receber uma lista diferente de funções no futuro.

Níveis numéricos aceitos para chamadas da API:

```text
0 = none
1 = low
2 = medium
3 = high
4 = xhigh
5 = max
```

Exemplo de comando no corpo ou assunto do e-mail:

```text
Mande o arquivo teste usando o nível 1 e peça como retorno qual é a capital da África do Sul
```

Fluxo desse comando:

1. O Python reconhece `api_zip_test` pelas frases configuradas em `functions.json`.
2. Confere o endereço exato do remetente e se ele possui permissão para a função.
3. Valida o nível `0..5`; nível fora desse intervalo não chama a API.
4. Converte `1` para `low` e usa esse nível apenas nessa chamada, sem alterar o nível global.
5. Usa o mesmo ZIP de teste da aba `F6 API`.
6. Envia o ZIP à API e pede que a solicitação indicada após `peça como retorno` seja respondida.
7. O retorno inclui `RETORNO_OPENAI.txt` dentro de um novo ZIP.
8. Baixa o ZIP para `OPENAI_OUTPUT_DIR`, por padrão `~/Downloads`.
9. A chamada aparece normalmente na pilha da aba `F6 API`, inclusive enquanto estiver aguardando.
10. Ao concluir, o bot responde ao e-mail informando a função, nível utilizado, caminho do arquivo e o resumo textual retornado pela API.

Durante esse fluxo o e-mail passa por `EXECUTANDO`, `CONCLUÍDO`, `ENVIANDO` e finalmente `RESPONDIDO`. Falhas da função aparecem como `ERRO FUNÇÃO`.

A autorização atual é baseada no endereço `From` recebido. Para funções futuras que tenham permissão para alterar projetos, banco ou sistema operacional, deve-se acrescentar uma autenticação mais forte além do endereço de remetente.
