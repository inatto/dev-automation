# dev-automation

## Primeiro passo em uma máquina nova

O bootstrap distingue automaticamente as duas camadas: **Windows + WSL** e **Ubuntu/Linux nativo**. No WSL ele instala `wslu` e abre a autenticação do GitHub no navegador do Windows; no Ubuntu nativo não usa nenhuma integração do Windows.

Comando único, idempotente, para uma máquina nova:

```bash
sudo apt update && sudo apt install -y git gh python3 && if grep -qiE '(microsoft|wsl)' /proc/sys/kernel/osrelease /proc/version 2>/dev/null; then sudo apt install -y wslu && GH_LOGIN='GH_BROWSER=wslview gh auth login --hostname github.com --web'; else GH_LOGIN='gh auth login --hostname github.com --web'; fi && (gh auth status --hostname github.com >/dev/null 2>&1 || eval "$GH_LOGIN") && mkdir -p "$HOME/Code/bots" && if [ -d "$HOME/Code/bots/dev-automation/.git" ]; then git -C "$HOME/Code/bots/dev-automation" pull --ff-only; elif [ -e "$HOME/Code/bots/dev-automation" ]; then echo "ERRO: ~/Code/bots/dev-automation existe mas não é um repositório Git." >&2; false; else gh repo clone inatto/dev-automation "$HOME/Code/bots/dev-automation"; fi && cd "$HOME/Code/bots/dev-automation"
```

Depois, instale/atualize os comandos globais:

```bash
./deploy/local/install-commands.sh && source ~/.bashrc
```

Por fim, prepare os projetos desta máquina. O `dev-gitsetup` identifica automaticamente o computador por `/etc/machine-id`; na primeira execução real, cria `config/projects/<machine-id>.projects` a partir de `config/projects/default.projects` e baixa somente os projetos definidos para essa máquina:

```bash
dev-gitsetup --dry-run
dev-gitsetup
```

Automação local dos projetos em `/home/daniel/Code`, com execução direta em
primeiro plano e encerramento por `Ctrl+C`.

## Comandos globais

Depois da instalação:

```bash
auto-code-manager
dev-manager
gpt-console
desktops
chromes
phpstorms
phpstorm-dev
local-nginx
orbital-app
station-app
inst-app
```

### `gpt-console`

Abre uma TUI tipo BIOS para testar a OpenAI API com catálogos de ações por
projeto, texto, transcrição de áudio, uso local/remoto e edição controlada dos
ZIPs existentes em `/home/daniel/Code`. A configuração fica exclusivamente em
`dev-automation/.config/gpt-console/`; o ZIP devolvido pela API é validado e
salvo em `~/Downloads` para o Dev Manager importar no fluxo normal.

```bash
bash apps/gpt-console/install.sh
gpt-console
gpt-console --doctor
```

Atalhos principais: `F2` configuração, `F3` projetos/ações, `F4` texto, `F5`
voz, `F6` ZIP, `F7` uso, `F9` diagnóstico e `Q` sair.

### `auto-code-manager`

ZIPs locais: cada projeto normal configurado é monitorado por `inotify`; após 1 segundo de silêncio, somente o projeto alterado é compactado diretamente em `/home/daniel/Code/<projeto>.zip`. Não há upload/download nem Google Drive.

#### Projetos e agregadores explícitos

A lista ativa é específica por computador: `config/projects/<machine-id>.projects`,
onde `<machine-id>` vem automaticamente de `/etc/machine-id`. Na primeira execução
real do `dev-gitsetup`, o arquivo da máquina é criado a partir de
`config/projects/default.projects`. O `default.projects` é apenas o modelo para criar um arquivo novo de máquina; não é compatibilidade com formato antigo. Nenhum `apps.zip`, `orbital.zip`, `Code.zip` ou outro
ZIP de pasta é inferido automaticamente.

Uma entrada normal representa um projeto real:

```text
bots/dev-automation
bots/dev-automation/apps/amazon-imap-bot
orgs/orbital/orbital-app
```

Se um projeto cadastrado estiver fisicamente dentro de outro projeto cadastrado,
o diretório do filho é excluído do ZIP do pai. Assim `dev-automation.zip` não
duplica `apps/amazon-imap-bot/`, enquanto `dev-automation-amazon-imap-bot.zip`
é gerado separadamente e contém seus arquivos sob `apps/amazon-imap-bot/`.
Pastas irmãs não cadastradas, como outros utilitários em `apps/`, continuam no ZIP
do pai. Na importação do ZIP pai, esses mesmos caminhos cadastrados também são
isolados, mesmo que um pacote recebido os contenha por engano.

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

Os mesmos projetos ativos (linhas descomentadas do `config/projects/<machine-id>.projects` ativo)
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
local-nginx test       # valida os arquivos de configuração
local-nginx --validate # alias explícito da validação
local-nginx --render   # mostra a configuração gerada sem instalar
```

Para encerrar, pressione `Ctrl+C`. Não existe sessão separada para anexar ou
manter em segundo plano.

### `desktops`

Sincroniza os desktops virtuais do Windows com os projetos ativos de
`config/projects/<machine-id>.projects`. O Desktop 1 é sempre preservado para uso
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

No Ubuntu/GNOME, `desktops` usa workspaces fixos, mantém os nomes via `gsettings` e não cria indicador visual próprio. Assim, o nome aparece somente na taskbar/painel já configurado. `lrdp1` e `lrdp2` continuam como os dois últimos workspaces. O comando não abre aplicativos.

O comando `lrdp` abre o **LRDP Control Center**, uma TUI fullscreen no padrão do Dev Manager. Ela descobre automaticamente `apps/lrdp/lrdpN`, portanto futuros `lrdp3`, `lrdp4` etc. entram na lista sem alterar a TUI. A tela principal mostra os RDPs, status TCP 3389, sessão FreeRDP ativa, configuração efetiva, mapa proporcional dos monitores, resolução/posição, saídas físicas DRM, IP local, interface, gateway, destino e o comando FreeRDP com a senha ocultada.

Atalhos principais da TUI: `Enter` conecta imediatamente com a configuração salva; `F2` abre a configuração tipo BIOS (IP de destino, login, áudio, microfone e monitor principal; o IP salvo atualiza `LRDP_TARGET` no arquivo `apps/lrdp/lrdpN`); `F3` abre o mapa de monitores e permite escolher o principal; `F4` mostra rede/rotas; `F5` atualiza; `F1` mostra ajuda; `Q` sai. A configuração fica em `~/.config/dev-automation/lrdp/` e os logs de lançamento ficam em `~/.local/state/dev-automation/lrdp/`.

Os comandos `lrdp1`/`lrdp2` continuam disponíveis como atalhos diretos e mantêm o modo de configuração textual legado. A TUI usa `--saved` internamente para conectar sem refazer perguntas.

O mesmo pode ser executado pelo comando geral:

```bash
dev-manager desktops
```

A ordem e os nomes dos projetos vêm apenas do `config/projects/<machine-id>.projects` ativo. Desktops extras existentes não são removidos automaticamente.

### `terminals`

No Ubuntu/GNOME/Wayland, uma única execução abre um terminal em cada workspace
de projeto e também em `lrdp1`/`lrdp2`. Somente o workspace 1 (`LAZER`) fica
fora.

```bash
terminals
```

O comando ativa o desktop de destino antes de criar cada janela, abre o terminal
já na pasta correspondente, posiciona-o no monitor direito, maximiza e aguarda
1,5 segundo antes de seguir para o próximo desktop. Não existe segunda chamada
de movimentação ou associação posterior. Uma nova execução abre um novo conjunto;
para reabrir tudo do zero, use primeiro `terminals-close`. Para fechar o lote e
limpar terminais extras dos workspaces de projeto:

```bash
terminals --reset

# fecha todos os terminais gráficos da sessão atual
terminals-close
```

### Comandos de fechamento

Os atalhos abaixo encerram somente a aplicação correspondente para permitir
uma reabertura limpa pelos comandos normais:

```bash
files-close       # Files/Nautilus da sessão gráfica atual
chromes-close     # Google Chrome/Chromium da sessão gráfica atual
pycharms-close    # todas as janelas PyCharm pelo controlador GNOME
terminals-close   # todos os terminais gráficos da sessão atual
```

O `pycharms-close` reutiliza o fechamento seguro já existente em
`pycharms --close`; ele solicita o fechamento das janelas e não mata uma JVM
genérica por nome.

### `chromes`

Abre duas janelas do Chrome:

- perfil `Default`, somente em `https://chatgpt.com/`;
- perfil `Profile 2`, em uma nova aba vazia.

```bash
chromes
```

### `phpstorm-dev`

Abre somente `/home/daniel/Code/bots/dev-automation` no PhpStorm. O comando
`phpstorms` também inclui esse projeto quando ele estiver ativo no `config/projects/<machine-id>.projects`.

```bash
phpstorm-dev
```

### `phpstorms`

Lê os projetos ativos da lista resolvida para a máquina (`config/projects/<machine-id>.projects`).

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
orbital-app                 # deploy local normal
orbital-app-auto            # deploy local + reinício após ZIP aplicado pelo Dev Automation
remote-orbital-app          # deploy remoto normal
remote-orbital-app-auto     # deploy remoto + novo deploy após ZIP aplicado pelo Dev Automation
orbital-app start           # somente start.sh
orbital-app-auto start      # start.sh supervisionado pelo modo auto
orbital-app setup           # somente setup.sh
orbital-app test            # test.sh
```

Os comandos terminados em `-auto` não observam alterações manuais no filesystem. Eles reagem somente ao evento emitido pelo próprio Dev Automation depois que uma importação de ZIP termina com sucesso. Os comandos sem `-auto` mantêm o comportamento normal, sem reinício automático.

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
`chromes-close`, `files-close`, `terminals-close`, `pycharms-close`, `phpstorms`,
`phpstorm-dev`, `oracle-monitor` e os comandos dos projetos listados na configuração.

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

Subprojetos cadastrados usam nome qualificado no ZIP para evitar colisões. Exemplo: `bots/dev-automation` + `bots/dev-automation/apps/amazon-imap-bot` gera `dev-automation.zip` e `dev-automation-amazon-imap-bot.zip`; dentro do ZIP filho, a raiz preservada é `apps/amazon-imap-bot/`.

### Git-crypt no dev-manager

O dev-manager **não executa git-crypt automaticamente**. Não verifica, não desbloqueia e não cria regras de criptografia ao iniciar nem durante backups. O `dev-automation` também não mantém regra ampla `config/**` em `.gitattributes`.

Quando necessário, o unlock continua disponível somente por ação manual explícita:

```bash
dev-manager git-crypt
```

Esse comando manual usa a chave padrão `/home/daniel/static/reverse-crypt.key` e apenas tenta `git-crypt unlock`. Ele não executa `git-crypt init`, não cria/edita `.gitattributes`, não usa `.git/info/attributes`, não faz `git add`, não reescreve índice/HEAD e não cria arquivos de configuração.

Para auditar e proteger todas as pastas `.config` dos projetos habilitados, use `script-dev-automation`. A TUI exige confirmação antes de alterar `.gitattributes` ou preparar os arquivos no índice Git e nunca cria commits automaticamente.

## ZIP seguro de configs (v43)

- `config/local`, `config/remote` e `config/production` entram no ZIP para conferência.
- A cópia temporária mascara senhas/tokens/chaves como `********`; o projeto original não é alterado.
- Na importação, `***` ou mais asteriscos significam **preservar o valor real local**.
- Chaves sensíveis (`PASSWORD`, `TOKEN`, `SECRET`, `API_KEY` etc.) **sempre preservam o valor local**, mesmo se o ZIP retornar outro valor em texto puro. O ZIP/chat nunca é fonte de segredo.
- Valores não secretos alterados no ZIP podem ser aplicados. Chaves existentes apenas localmente são preservadas.
- Se um config novo vier com segredo mascarado e não houver valor local para recuperar, a importação falha e o ZIP permanece em Downloads.
- Arquivos de formato não reconciliável dentro dessas pastas são enviados como `********` inteiro e nunca sobrescrevem o arquivo local.
- Nenhum `.external` é persistido no projeto.
- `.env`/`.env.*` fora das pastas de config continuam fora do fluxo por padrão.
- Git-crypt não roda automaticamente; quando necessário, use `dev-manager git-crypt` de forma explícita.
