# dev-automation

Automação local dos projetos em `/home/daniel/Code`, com execução direta em
primeiro plano e encerramento por `Ctrl+C`.

## Comandos globais

Depois da instalação:

```bash
auto-code-manager
dev-manager
desktops
chromes
phpstorms
phpstorm-dev
local-nginx
worker-sync
orbital-app
station-app
inst-app
```

### `worker-sync`

Gerencia o canal Google Drive do worker com direção fixa:

```text
/home/daniel/worker/to -> danielmaiax:worker/to
danielmaiax:worker/from -> /home/daniel/worker/from
```

`to` somente sobe por evento local (`inotifywait`). `from` somente baixa, verificado a cada 10 segundos.

```bash
worker-sync restart
worker-sync status
worker-sync test
worker-sync logs
worker-sync stop
```

O `restart` para units antigos, reinstala os units mantidos dentro deste repositório e inicia a configuração nova.

### `auto-code-manager`

Monitora a pasta Downloads e associa cada ZIP ao projeto pelo começo do nome. Todos os ZIPs encontrados no início da rodada são capturados em um único lote e importados em sequência antes de o ciclo seguir para limpeza, backup ou espera.
Além dos formatos comuns, aceita sufixos gerados ou codificados pelo navegador:

```text
dev-automation.zip
dev-automation(15).zip
dev-automation%23232-3434.zip
dev-automation#revisado.zip
```

O primeiro caractere depois do nome do projeto precisa ser um separador não
alfanumérico. Assim, `dev-automation2.zip` não é confundido com
`dev-automation.zip`.

Para testar somente o reconhecimento, sem importar o arquivo:

```bash
auto-code-manager --identify-zip 'dev-automation%23232-3434.zip'
```

Resultado esperado:

```text
bots/dev-automation
```

#### Projetos e agregadores explícitos

`config/auto-code-manager.projects` é a única fonte da verdade para os backups.
Nenhum `apps.zip`, `orbital.zip`, `Code.zip` ou outro ZIP de pasta é inferido
automaticamente.

Uma entrada normal representa um projeto real:

```text
bots/dev-automation
bots/dev-automation/apps/exec-agent
orgs/orbital/orbital-app
```

Se um projeto cadastrado estiver fisicamente dentro de outro projeto cadastrado,
o diretório do filho é excluído do ZIP do pai. Assim `dev-automation.zip` não
duplica `apps/exec-agent/`, enquanto `exec-agent.zip` é gerado separadamente.
Pastas irmãs não cadastradas, como outros utilitários em `apps/`, continuam no ZIP
do pai.

Uma entrada terminada em `.zip` habilita explicitamente um agregador da pasta
correspondente:

```text
bots/dev-automation/apps.zip  -> apps.zip
orgs/orbital.zip               -> orbital.zip
Code.zip                       -> Code.zip
```

O agregador contém somente os ZIPs configurados abaixo daquela pasta. Se houver
um agregador mais específico, ele representa o ramo inteiro e evita duplicação.
Por exemplo, com `orgs/orbital.zip` ativo, um `Code.zip` também ativo inclui
`orbital.zip`, e não repete todos os `orbital-*.zip` dentro dele. Se a linha
`orgs/orbital.zip` não existir, `orbital.zip` não é criado nem reconhecido na
importação. O mesmo vale para `Code.zip` e `apps.zip`.

Para conferir exatamente os alvos ativos:

```bash
auto-code-manager --list-backup-targets
```

Para gerar uma rodada imediatamente, sem iniciar o monitor contínuo:

```bash
auto-code-manager --backup-once
```

Ao final de uma rodada completa e bem-sucedida, o monitor toca uma única vez
o som nativo `C:\\Windows\\Media\\ding.wav`. Não há som por projeto nem
por ZIP individual. O som pode ser testado separadamente:

```bash
auto-code-manager --test-backup-sound
```

Para desativar, altere `BACKUP_BEEP_ENABLED`. O caminho pode ser configurado
em `BACKUP_WINDOWS_WAVE_FILE`; o volume segue o volume geral do Windows.
`BACKUP_BEEP_VOLUME` é usado somente pelo WAV de fallback.

Para testar/importar diretamente um único ZIP sem iniciar o monitor contínuo:

```bash
auto-code-manager --import-one '/caminho/orbital.zip'
```

Para executar uma única rodada completa sobre todos os ZIPs presentes em Downloads:

```bash
auto-code-manager --import-downloads-once
```


### `dev-status`

Indicador nativo C++/Win32 do `auto-code-manager` na taskbar do Windows. O código fica em `apps/dev-status` e o monitor o usa automaticamente quando o executável estiver compilado.

```bash
dev-status --build
dev-status backup
dev-status unzip
dev-status done
```

Sem o executável, o `auto-code-manager` continua funcionando normalmente; o indicador é observabilidade e nunca bloqueia backup/importação.

Ao executar `dev-manager`, se `apps/dev-status/bin/dev-status.exe` ainda não existir, o build C++ é tentado automaticamente uma única vez. Depois de gerado, os próximos starts reutilizam o executável existente.

### `dev-manager`

Executa o `auto-code-manager` diretamente no terminal atual:

```bash
dev-manager
```

Antes de iniciar o monitor, o comando executa automaticamente
`deploy/local/install-commands.sh`. Esse é o instalador principal: atualiza os
comandos fixos (`auto-code-manager`, `dev-manager`, `chromes`, `phpstorms`,
`phpstorm-dev` e `oracle-monitor`) e chama `install-project-commands.sh` para recriar os comandos
dos projetos configurados. Para atualizar sem iniciar o monitor:

```bash
dev-manager commands
```

Os mesmos projetos ativos (linhas descomentadas de `config/auto-code-manager.projects`)
podem ser executados em sequência pelos comandos gerais. Cada comando ignora projetos
sem o respectivo `deploy/<modo>/setup.sh`, preserva a ordem do arquivo e interrompe na
primeira falha:

```bash
local-all           # executa o setup local de todos os projetos ativos compatíveis
local-all test      # executa o test local de todos, na mesma ordem
remote-all          # executa o setup remoto de todos os projetos ativos compatíveis
remote-all test     # executa o test remoto de todos, na mesma ordem
```

A tela é limpa uma única vez no início de `local-all`/`remote-all`, para preservar o
log completo da sequência.

O instalador geral também cria o comando global `local-nginx`, dedicado somente
ao gateway Nginx local:

```bash
local-nginx            # gera, instala, valida e recarrega o Nginx
local-nginx --validate # somente valida os arquivos de configuração
local-nginx --render   # mostra a configuração gerada sem instalar
```

Para encerrar, pressione `Ctrl+C`. Não existe sessão separada para anexar ou
manter em segundo plano.

### `desktops`

Sincroniza os desktops virtuais do Windows com os projetos ativos de
`config/auto-code-manager.projects`. O Desktop 1 é sempre preservado para uso
pessoal. A partir do Desktop 2, cada projeto ativo recebe um desktop na mesma
ordem do arquivo. Linhas comentadas com `#` são ignoradas.

Para conferir a ordem sem alterar o Windows:

```bash
desktops --list
```

Para criar os desktops que faltam e aplicar os nomes:

```bash
desktops
```

No Ubuntu/GNOME, `desktops` usa workspaces fixos, mostra o nome ao alternar e reserva `lrdp1` e `lrdp2` como os dois últimos workspaces. O comando não abre aplicativos.

O mesmo pode ser executado pelo comando geral:

```bash
dev-manager desktops
```

A ordem e os nomes dos projetos continuam vindo apenas de `config/auto-code-manager.projects`. Desktops extras existentes não são removidos automaticamente.

### `chromes`

Abre duas janelas do Chrome:

- perfil `Default`, somente em `https://chatgpt.com/`;
- perfil `Profile 2`, em uma nova aba vazia.

```bash
chromes
```

### `phpstorm-dev`

Abre somente `/home/daniel/Code/bots/dev-automation` no PhpStorm. O comando
`phpstorms` também inclui esse projeto quando ele estiver ativo em `config/auto-code-manager.projects`.

```bash
phpstorm-dev
```

### `phpstorms`

Lê os projetos ativos de `config/auto-code-manager.projects`.

A regra de abertura é:

```text
orgs/orbital/orbital-app
orgs/orbital/orbital-assets
orgs/orbital/orbital-fin
```

Esses irmãos são agrupados e abrem uma única janela em:

```text
orgs/orbital
```

Projetos de um nível abaixo da categoria continuam individuais:

```text
orgs/asaclub-app
orgs/email-app
orgs/inst-app
```

Para conferir sem abrir o PhpStorm:

```bash
phpstorms --list
```

Para abrir normalmente:

```bash
phpstorms
```

O intervalo entre as janelas pode ser alterado:

```bash
PHPSTORMS_OPEN_DELAY_SECONDS=2 phpstorms
```

Linhas comentadas com `#` são ignoradas. Projetos inexistentes são informados e
ignorados.

## Comandos individuais dos projetos

Cada comando entra automaticamente na pasta correta e usa `deploy/local`:

```bash
orbital-app             # setup.sh + start.sh
orbital-app start       # somente start.sh
orbital-app setup       # somente setup.sh
orbital-app run         # setup.sh + start.sh
orbital-app test        # test.sh
orbital-app scripts     # lista ações disponíveis
orbital-app dir         # mostra a pasta
```

Os scripts de execução usam `exec` no processo de longa duração, permitindo
encerrar normalmente com `Ctrl+C`.

## Instalar ou atualizar

```bash
cd /home/daniel/Code/bots/dev-automation
chmod +x scripts/*.sh deploy/local/*.sh
./deploy/local/install-commands.sh
source ~/.bashrc
```

O instalador cria ou atualiza `auto-code-manager`, `dev-manager`, `chromes`,
`phpstorms`, `phpstorm-dev`, `oracle-monitor` e os comandos dos projetos listados na configuração.

## Oracle Local Monitor

Projeto isolado em `apps/oracle-monitor`, instalado como comando global
`oracle-monitor`. Consulte `apps/oracle-monitor/README.md`.

#### ZIP automático de arquivos SQL

O arquivo `config/auto-code-manager.folder-sql-zip` informa as pastas que o
monitor deve observar, uma por linha. São aceitos caminhos absolutos, caminhos
com `~/` e caminhos relativos a `/home/daniel/Code`.

Exemplo:

```text
~/Code/orgs/asaclub-app/exports/ddl/
~/Code/infra/oracle-infra/exports/ddl/
```

Em cada ciclo, todos os arquivos `*.sql` estáveis encontrados diretamente em
cada pasta são agrupados em um ZIP com a data e hora de criação:

```text
20260728-1729.zip
```

O nome original do SQL não interfere no nome do ZIP. Se novos SQLs chegarem no
mesmo minuto, eles são adicionados ao ZIP daquele minuto. O ZIP é validado antes
da instalação e os SQLs incluídos só são apagados depois da validação. Em caso
de falha, os SQLs permanecem na pasta.

Para executar somente essa tarefa uma vez:

```bash
auto-code-manager --sql-zip-once
```


## Chave lógica global de projeto

O nome da última pasta de cada projeto normal é sua chave lógica global. Dois projetos cadastrados não podem ter a mesma chave, mesmo sob pais diferentes; o `dev-manager` aborta antes de importar ou gerar backups quando encontra duplicidade.

Subprojetos cadastrados usam nome qualificado apenas no backup automático. Exemplo: `bots/dev-automation` + `bots/dev-automation/apps/exec-agent` gera `dev-automation.zip` e `dev-automation--exec-agent.zip`. Na importação, tanto `exec-agent.zip`/`exec-agent-incremental.zip` quanto `dev-automation--exec-agent.zip` resolvem para o mesmo projeto `exec-agent`.
