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
orbital-app
station-app
inst-app
```

### `auto-code-manager`

ZIPs locais: cada projeto normal configurado é monitorado por `inotify`; após 1 segundo de silêncio, somente o projeto alterado é compactado diretamente em `/home/daniel/Code/<projeto>.zip`. Não há upload/download nem Google Drive.

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
`orbital.zip`, e não repete todos os `orbital-*.zip` dentro dele. Se a linha `orgs/orbital.zip` não existir, `orbital.zip` não é gerado. O mesmo vale para `Code.zip` e `apps.zip`.

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


### `dev-status`

Indicador nativo C++/Win32 do `auto-code-manager` na taskbar do Windows. O código fica em `apps/dev-status` e o monitor o usa automaticamente quando o executável estiver compilado.

```bash
dev-status --build
dev-status backup
dev-status unzip
dev-status done
```

Sem o executável, o `auto-code-manager` continua funcionando normalmente; o indicador é observabilidade e nunca bloqueia backup.

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

No Ubuntu/GNOME, `desktops` usa workspaces fixos, mostra somente o nome do workspace atual no canto inferior direito do monitor principal e reserva `lrdp1` e `lrdp2` como os dois últimos workspaces. O comando não abre aplicativos.

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

#### SQL

O `dev-manager` **não compacta nem apaga SQL automaticamente**. Um arquivo
`*.sql` dentro de um projeto é tratado como qualquer outro arquivo: a mudança
apenas dispara o ZIP normal do projeto.

A rotina antiga ainda existe somente como comando manual explícito, para quem
realmente quiser executá-la:

```bash
auto-code-manager --sql-zip-once
```

Ela usa `config/auto-code-manager.folder-sql-zip`, mas esse arquivo não é criado
nem observado automaticamente pelo `dev-manager`.


## Chave lógica global de projeto

O nome da última pasta de cada projeto normal é sua chave lógica global. Dois projetos cadastrados não podem ter a mesma chave, mesmo sob pais diferentes; o `dev-manager` aborta antes de gerar backups quando encontra duplicidade.

Subprojetos cadastrados usam nome qualificado no ZIP para evitar colisões. Exemplo: `bots/dev-automation` + `bots/dev-automation/apps/exec-agent` gera `dev-automation.zip` e `dev-automation--exec-agent.zip`.

### Efeitos colaterais permitidos do dev-manager (v39)

O comando `dev-manager` também não reinstala comandos globais, não recompila
`dev-status` e não garante/inicia G512 automaticamente ao subir. Essas ações só
acontecem quando chamadas explicitamente pelos comandos próprios.

No diretório dos projetos, o monitor só pode fazer o seguinte:

- copiar arquivos vindos de um ZIP reconhecido em `~/Downloads`;
- remover o alvo correspondente a um marcador `arquivo.remover` recebido nesse ZIP;
- nunca deixar o próprio `.remover` dentro do projeto;
- auditar git-crypt em **somente leitura** (`--check`), sem criar/editar `.gitattributes`, sem `git add`, sem reescrever índice e sem `git-crypt unlock`.

Fora da árvore do projeto, ele gera o backup local `/home/daniel/Code/<projeto>.zip`
como cópia real do projeto após aplicar apenas os ignores de backup, e mantém
apenas arquivos temporários/estado do próprio manager. Não mascara/sanitiza
config no ZIP, não cria baseline de config e não existe mais materialização/merge
automático de `.external`, compactação automática de SQL, restart/sinal automático
de processos após importação, worker, rclone ou Drive.

Pastas de código como `apps/web/src/config` não são consideradas secretas apenas
por se chamarem `config`; por exemplo, `apps/web/src/config/api-url.ts` não entra
no git-crypt automaticamente.

Quando a auditoria git-crypt encontra problema, o log mostra o repositório, cada
pasta `config` afetada e cada arquivo problemático. Para erro de atributos, mostra
também os valores efetivos de `filter` e `diff`; para plaintext, lista os caminhos
exatos no índice e/ou no HEAD.

## Importação automática local por Downloads

O `auto-code-manager` observa `/home/daniel/Downloads` por `inotify`, sem Google Drive, rclone ou worker.

- Só processa `.zip` cujo nome resolva para um alvo cadastrado em `config/auto-code-manager.projects` **e cuja pasta já exista** em `/home/daniel/Code`.
- Aceita `projeto.zip` e complementos iniciados por separador, por exemplo `orbital-legal--ajuste-importador.zip`, `orbital-legal-fix.zip` ou `orbital-legal(2).zip`.
- ZIP desconhecido fica intocado em Downloads.
- Aguarda o fim da gravação (`CLOSE_WRITE`/`MOVED_TO`), valida integridade e recusa caminhos absolutos, `..`, symlinks e tipos especiais.
- Antes de aplicar, gera/valida o backup atual do projeto em `/home/daniel/Code/<projeto>.zip`.
- Extrai em staging temporário, aplica `config/auto-code-manager.ignore-unzip`, preserva `config/local`, `config/remote` e `config/production` sem gerar `.external`, e valida marcadores `.remover`.
- Copia e confere arquivo a arquivo. O ZIP de entrada é apagado **somente depois** de tudo ser confirmado.
- Se houver qualquer falha, o ZIP permanece em Downloads.
- Depois da importação, alterações do projeto passam pelo mesmo debounce normal e o ZIP local do projeto é atualizado.

Comandos úteis:

```bash
auto-code-manager --identify-zip ~/Downloads/orbital-legal--fix.zip
auto-code-manager --import-downloads-once
auto-code-manager --import-one ~/Downloads/orbital-legal--fix.zip
```
