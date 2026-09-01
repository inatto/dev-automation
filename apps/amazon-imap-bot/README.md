# Amazon IMAP Bot

Monitor de caixas IMAP Amazon com painel TUI navegável, confirmação automática gerada pela OpenAI e envio via Amazon SES.

## Fluxo

1. Abre a pasta IMAP configurada e consulta `ALL`; o servidor IMAP é a fonte autoritativa da `ENTRADA`.
2. Identifica a pasta por `UIDVALIDITY` + UID e sincroniza as mensagens no Oracle.
3. Na primeira sincronização, importa o estado atual sem responder retroativamente. Nos polls seguintes, somente UIDs novos entram no fluxo de resposta.
4. Se uma mensagem desaparecer da pasta IMAP (apagada ou movida por outro cliente), ela também some da `ENTRADA` do bot no próximo poll.
5. Ignora mensagens automáticas, listas, bounces e remetentes próprios. Mensagens sem corpo continuam válidas.
6. Toca `assets/sounds/soft-notification.wav` para mensagem nova elegível.
7. Gera a confirmação pela OpenAI.
8. Para destinatários sempre liberados, enfileira o SES imediatamente. Para clientes/terceiros, grava a resposta no Oracle como pendente e exige liberação individual; além disso, o envio externo precisa estar globalmente liberado.
9. Envia via Amazon SES somente depois de todas as regras de liberação.
10. Entradas, respostas, eventos, chamadas de API, estado de sincronização IMAP e controles de envio ficam no Oracle. Não há SQLite em runtime.

## TUI

O painel possui seis áreas no menu superior:

- `ENTRADA`: mensagens recebidas pelo monitor, com data, remetente, assunto e status.
- `RESPOSTAS`: respostas geradas/enviadas, inclusive tentativas com erro.
- `CONSOLE`: chamadas IMAP, GPT e SES, sem exibir senhas, API keys ou credenciais AWS.
- `CONTAS`: estado de cada caixa monitorada.
- `API`: configuração efetiva da OpenAI e pilha/histórico das chamadas de API (e-mail e teste ZIP), com estado, modelo, nível de raciocínio, tempo, Response ID e arquivo de retorno.
- `FUNÇÕES`: leitura do catálogo Oracle carregado pela camada de aplicação, mostrando funções, estado, descrição, níveis, parâmetros e permissões por remetente.

As teclas `F1`, `F2`, `F3`, `F4` e `F6` ficam livres para uso futuro. No menu superior, use `←/→` para escolher uma área e `↓` ou `Enter` para entrar. Dentro da área, use `↑/↓`, `PgUp/PgDn` e `Enter` quando houver detalhes; `Esc` ou `↑` no primeiro item retorna ao menu. `F5` é global e executa imediatamente a mesma verificação IMAP do poll automático de 30 segundos. `R` permanece como atalho alternativo. `Q` sai. Na área `API`, `T` executa o teste de ZIP.

Na área `ENTRADA`, `N` marca a mensagem no Oracle como `NÃO RESPONDER`; se houver resposta pendente, liberada aguardando o bloqueio global ou ainda na fila, ela é cancelada. Uma resposta já em envio ou já enviada não pode ser desfeita. `D` remove a mensagem do IMAP. A TUI sempre exige confirmação e diferencia visualmente os casos:

- `RESPONDIDO`: confirmação verde informando que a resposta já foi enviada.
- `ERRO RESPOSTA` ou qualquer mensagem ainda não respondida: alerta vermelho antes da remoção.
- `IGNORADO` / `AGUARDANDO CONF.`: alerta amarelo informando que não houve resposta.
- Estados em processamento (`ANALISANDO`, `ENTENDIDO`, `ENVIANDO`, `EXECUTANDO`) bloqueiam a remoção até a etapa terminar.

A remoção move o e-mail no servidor IMAP para a pasta marcada como `\Trash`. Se o servidor não anunciar essa pasta, usa `Deleted Items`. O IMAP é mandatório: a `ENTRADA` mostra somente mensagens que continuam presentes na pasta monitorada. Se um e-mail for removido ou movido diretamente no Outlook/cliente IMAP, o próximo poll marca o registro Oracle como ausente e o retira do grid. O histórico de respostas continua em `RESPOSTAS`.

O controle de clientes aparece em destaque no topo:

- `G` alterna o bloqueio geral de envio externo.
- Toda resposta para cliente/terceiro exige também liberação individual em `RESPOSTAS` com `L`.
- Se `G` estiver desligado, a liberação individual deixa a resposta em `LIBERADO/BLOQ. GLOBAL`. Ao ligar `G`, essas respostas já aprovadas entram na fila.
- Destinatários cadastrados em `IMAP_BOT_ALWAYS_ALLOWED_RECIPIENTS` ignoram esses dois bloqueios e seguem direto para a fila de envio.
- A `ENTRADA` mostra `RESP. PEND. ENVIO`, `RESP. LIBERADA/BLOQ.`, `RESP. NA FILA`, `RESPONDIDO` e `NÃO RESPONDER`, deixando o estado visível.
- A marcação `NÃO RESPONDER` é persistente no Oracle (`REPLY_SUPPRESSED`, data e usuário) e continua valendo após reinício do bot.

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


### Catálogo de funções no Oracle

A conexão do catálogo fica separada em `.config/amazon-imap-bot/database.env`:

```env
DB_TYPE=oracle
DB_USER=WKSP_SINDICATTO
DB_JDBC_URL=jdbc:oracle:thin:@sindicatto_tpurgent
DB_TNS_ADMIN=$HOME/.oracle/Wallet_sindicatto
DB_SCHEMA=WKSP_SINDICATTO
DB_PASSWORD=
# Opcional: somente se a wallet PEM exigir senha.
DB_WALLET_PASSWORD=
# Inicialização fail-fast: evita ficar dezenas de segundos em retries do descriptor do wallet.
DB_CONNECT_TIMEOUT_SECONDS=8
DB_CONNECT_RETRY_COUNT=0
DB_CONNECT_RETRY_DELAY_SECONDS=1
```

Preencha a senha somente nesse arquivo local. O bot usa o driver Python `oracledb` no mesmo padrão do Orbital App: `DB_TNS_ADMIN` é passado como `config_dir` para resolver o alias TNS e também como `wallet_location` para carregar a wallet/mTLS. `DB_WALLET_PASSWORD` é opcional para wallets sem chave PEM criptografada; se `ewallet.pem` contiver `ENCRYPTED PRIVATE KEY`, use a mesma senha de wallet configurada no Orbital App. Por compatibilidade, o bot também aceita a chave `ORACLE_WALLET_PASSWORD` no `database.env`.

Na inicialização, o terminal mostra cada etapa com tempo acumulado, inclusive resolução do DSN, host/porta/service do Oracle (sem senha), política de retry/timeout, abertura da conexão e leitura de cada parte do catálogo. Os valores `DB_CONNECT_*` sobrescrevem os retries do descriptor apenas no processo do bot, para que falhas de rede/ACL apareçam rapidamente em vez de deixarem a tela aparentemente travada.

O projeto não distribui arquivos `.sql`. Mudanças de schema são aplicadas manualmente fora do ZIP com o SQL fornecido no atendimento. O bot não executa DDL automaticamente.

Além do catálogo de funções, o runtime usa tabelas Oracle próprias para mensagens, eventos, chamadas de API, estado da pasta IMAP e regras de liberação de envio. O SQLite antigo não é lido nem criado.

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

As definições e autorizações são carregadas do Oracle pela camada de aplicação do Amazon IMAP Bot. `functions.json` não é usado nem distribuído no funcionamento normal; o catálogo vem do Oracle.

O catálogo é composto pelas tabelas:

- `IMAP_BOT_FUNCTION_CATALOG`
- `IMAP_BOT_REASONING_LEVELS`
- `IMAP_BOT_FUNCTIONS`
- `IMAP_BOT_FUNCTION_REASONING`
- `IMAP_BOT_FUNCTION_PARAMETERS`
- `IMAP_BOT_FUNCTION_PARAM_OPTIONS`
- `IMAP_BOT_FUNCTION_SENDERS`
- `IMAP_BOT_SENDER_FUNCTIONS`

O armazenamento operacional usa também:

- `IMAP_BOT_MESSAGES`
- `IMAP_BOT_EVENTS`
- `IMAP_BOT_API_RUNS`
- `IMAP_BOT_MAILBOX_STATE`
- `IMAP_BOT_CONTROL`
- `IMAP_BOT_ALWAYS_ALLOWED_RECIPIENTS`

O banco não armazena schema, parâmetros nem níveis permitidos em JSON. Cada dado fica em coluna própria e, quando há múltiplos valores, em tabela filha relacional. O schema exigido pela API da OpenAI é montado somente em memória a partir dessas linhas; ele não é persistido no Oracle.

As funções atuais `api_zip_test`, `project_zip_edit` e `function_catalog_admin`, seus parâmetros, opções, níveis e autorizações permanecem no catálogo relacional Oracle.

Fluxo:

1. Na inicialização, o repositório Oracle carrega o catálogo para a camada de aplicação.
2. O monitor, o roteador, a TUI e a API mobile consomem o mesmo `FunctionMap`.
3. `GET /api/v1/functions` recarrega e retorna o catálogo do Oracle.
4. O GPT recebe somente as funções autorizadas para o endereço `From`.
5. O Python revalida remetente, função, nível e parâmetros antes de executar.
6. O Oracle é a fonte autoritativa do catálogo em runtime; parâmetros ausentes ou inconsistentes no banco geram erro explícito.

A classe ainda aceita uma fonte JSON somente quando ela é fornecida explicitamente por código, para rollback/importação controlada; esse modo legado não é usado pela inicialização normal do bot e não grava JSON no Oracle.

### Função `function_catalog_admin`

A nova função administra o catálogo em memória sem fazer DDL/DML:

- `operation=list`: lista versão, funções ativas e remetentes autorizados.
- `operation=sync`: descarta o snapshot atual e recarrega definições e autorizações do Oracle.

A mesma sincronização está disponível para clientes da API em `POST /api/v1/actions/functions-sync`. Alterações persistentes do schema/dados administrativos continuam sendo feitas por comandos SQL manuais fornecidos fora do projeto.


## Função `project_zip_edit`

Para remetentes autorizados no catálogo Oracle, pedidos de alteração de projeto podem ser roteados para `project_zip_edit`. O fluxo usa duas chamadas independentes:

1. lista somente `*.zip` diretamente em `PROJECT_ZIP_SEARCH_ROOT` (padrão `~/Code`), sem entrar em subdiretórios e envia somente a lista + pedido original ao GPT para escolher o ZIP;
2. valida localmente a escolha, envia apenas esse ZIP em uma nova chamada com o pedido original completo, baixa o ZIP final para `OPENAI_OUTPUT_DIR` (padrão `~/Downloads`).

Não existe mapeamento fixo de nomes de projetos. A seleção retornada pelo GPT só é aceita se corresponder exatamente a um arquivo descoberto sob a raiz configurada.


## API mobile e aplicativo Flutter

A interface Flutter fica em `apps/amazon-imap-bot-mobile` e reproduz as áreas e operações relevantes da TUI por uma API própria: resumo/status e filas em processamento, entradas e respostas com detalhes, console persistente, contas, histórico/detalhes de chamadas da API, catálogo Oracle de funções, atualização IMAP imediata, remoção confirmada de e-mail e teste ZIP.

Configure em `.config/amazon-imap-bot/settings.env`:

```env
# Obrigatório. Gere um segredo longo e aleatório.
MOBILE_API_TOKEN=troque-por-um-segredo-forte
# Seguro por padrão: apenas loopback. Para reverse proxy/rede interna, altere conscientemente.
MOBILE_API_HOST=127.0.0.1
MOBILE_API_PORT=8765
```

Inicie o backend:

```bash
amazon-imap-bot --api
```

Todas as rotas funcionais em `/api/v1` exigem `Authorization: Bearer <token>`. A API não retorna senhas IMAP, chave OpenAI nem credenciais AWS. Para acesso fora do host, use TLS em um reverse proxy e restrinja a origem por firewall/VPN.

Principais rotas:

- `GET /api/v1/overview`, `/accounts`, `/events`, `/functions`, `/actions`
- `GET /api/v1/messages?direction=in|out` e `/messages/{id}`
- `GET /api/v1/api-runs` e `/api-runs/{id}`
- `POST /api/v1/actions/refresh`
- `POST /api/v1/actions/api-zip-test`
- `POST /api/v1/actions/functions-sync`
- `DELETE /api/v1/messages/{id}`

### Responsividade da TUI e diagnóstico de crash

A TUI não consulta o Oracle na thread do curses. Um feed em segundo plano mantém o snapshot exibido; navegação e abertura de detalhes usam memória local. A sincronização IMAP carrega o índice de UIDs do Oracle uma única vez por ciclo, evitando SELECT/UPDATE por mensagem já conhecida.

Diagnóstico persistente:

- `.config/amazon-imap-bot/runtime.log`: tempos de consultas Oracle, ciclos IMAP, atualização do feed da TUI e threads.
- `.config/amazon-imap-bot/crash.log`: faulthandler com stack de todas as threads em falhas fatais. Em Linux, `kill -USR1 <pid>` também grava um dump das stacks nesse arquivo sem encerrar o processo.
