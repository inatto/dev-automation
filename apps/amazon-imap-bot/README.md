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

O painel possui seis áreas no menu superior:

- `ENTRADA`: mensagens recebidas pelo monitor, com data, remetente, assunto e status.
- `RESPOSTAS`: respostas geradas/enviadas, inclusive tentativas com erro.
- `CONSOLE`: chamadas IMAP, GPT e SES, sem exibir senhas, API keys ou credenciais AWS.
- `CONTAS`: estado de cada caixa monitorada.
- `API`: configuração efetiva da OpenAI e pilha/histórico das chamadas de API (e-mail e teste ZIP), com estado, modelo, nível de raciocínio, tempo, Response ID e arquivo de retorno.
- `FUNÇÕES`: leitura do `functions.json` atual em interface humana, mostrando funções, estado, descrição, níveis, parâmetros e permissões por remetente sem exibir JSON cru.

As teclas `F1`, `F2`, `F3`, `F4` e `F6` ficam livres para uso futuro. No menu superior, use `←/→` para escolher uma área e `↓` ou `Enter` para entrar. Dentro da área, use `↑/↓`, `PgUp/PgDn` e `Enter` quando houver detalhes; `Esc` ou `↑` no primeiro item retorna ao menu. `F5` é global e executa imediatamente a mesma verificação IMAP do poll automático de 30 segundos. `R` permanece como atalho alternativo. `Q` sai. Na área `API`, `T` executa o teste de ZIP.

Na área `ENTRADA`, `D` remove a mensagem. A TUI sempre exige confirmação e diferencia visualmente os casos:

- `RESPONDIDO`: confirmação verde informando que a resposta já foi enviada.
- `ERRO RESPOSTA` ou qualquer mensagem ainda não respondida: alerta vermelho antes da remoção.
- `IGNORADO` / `AGUARDANDO CONF.`: alerta amarelo informando que não houve resposta.
- Estados em processamento (`ANALISANDO`, `ENTENDIDO`, `ENVIANDO`, `EXECUTANDO`) bloqueiam a remoção até a etapa terminar.

A remoção move o e-mail no servidor IMAP para a pasta marcada como `\Trash`. Se o servidor não anunciar essa pasta, usa `Deleted Items`. A linha fica oculta da Entrada, mas o registro de deduplicação é preservado no SQLite para impedir reprocessamento acidental. As respostas continuam em `RESPOSTAS` como histórico do que foi enviado.

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

1. O Python lê `functions.json` e monta a lista de funções autorizadas especificamente para o endereço `From` recebido.
2. Somente essas funções autorizadas são enviadas ao GPT como *function tools* da Responses API. O GPT interpreta o pedido semanticamente; não existe mais dependência de frase exata, alias ou palavra-chave para escolher a função.
3. Se nenhuma função disponível combinar com o pedido, o GPT não chama ferramenta e o e-mail segue pelo fluxo normal de suporte.
4. Se o GPT selecionar uma função, retorna uma chamada estruturada com nome e argumentos. O Python valida novamente remetente, nome da função e parâmetros antes de executar qualquer coisa.
5. Para `api_zip_test`, valida o nível `0..5`, converte `1` para `low` e usa esse nível apenas na execução do ZIP, sem alterar o nível global.
6. A decisão semântica aparece na área `API` como uma chamada `ROUTER`, com resultado `função=...` ou `nenhuma função selecionada`.
7. Quando `api_zip_test` é escolhida, uma segunda linha `ZIP` aparece na mesma pilha e acompanha `PREPARANDO`, `ENVIANDO`, `AGUARDANDO`, `BAIXANDO`, `CONCLUÍDO` ou `ERRO`.
8. O teste usa o mesmo ZIP da tecla `T`, envia a pergunta/instrução extraída pelo GPT e gera `RETORNO_OPENAI.txt` dentro do novo ZIP.
9. O ZIP retornado é baixado para `OPENAI_OUTPUT_DIR`, por padrão `~/Downloads`.
10. Ao concluir, o bot responde ao e-mail informando a função, nível utilizado, caminho do arquivo e o resumo textual retornado pela API.

Durante esse fluxo o e-mail passa por `EXECUTANDO`, `CONCLUÍDO`, `ENVIANDO` e finalmente `RESPONDIDO`. Falhas da função aparecem como `ERRO FUNÇÃO`.

A autorização atual é baseada no endereço `From` recebido. Para funções futuras que tenham permissão para alterar projetos, banco ou sistema operacional, deve-se acrescentar uma autenticação mais forte além do endereço de remetente.


## Função `project_zip_edit`

Para remetentes autorizados em `.config/amazon-imap-bot/functions.json`, pedidos de alteração de projeto podem ser roteados para `project_zip_edit`. O fluxo usa duas chamadas independentes:

1. varre `PROJECT_ZIP_SEARCH_ROOT` (padrão `~/Code`) recursivamente por `*.zip` e envia somente a lista + pedido original ao GPT para escolher o ZIP;
2. valida localmente a escolha, envia apenas esse ZIP em uma nova chamada com o pedido original completo, baixa o ZIP final para `OPENAI_OUTPUT_DIR` (padrão `~/Downloads`).

Não existe mapeamento fixo de nomes de projetos. A seleção retornada pelo GPT só é aceita se corresponder exatamente a um arquivo descoberto sob a raiz configurada.
