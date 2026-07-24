# dev-automation

Automação local dos projetos em `/home/daniel/Code`, sem `tmux`.

## Comandos globais

Depois da instalação:

```bash
auto-code-manager
chromes
phpstorms
phpstorm-dev
orbital-app
station-app
inst-app
```

### `chromes`

Abre duas janelas do Chrome:

- perfil `Default`, somente em `https://chatgpt.com/`;
- perfil `Profile 2`, em uma nova aba vazia.

```bash
chromes
```

### `phpstorm-dev`

Abre somente `/home/daniel/Code/bots/dev-automation` no PhpStorm. O comando `phpstorms` ignora esse projeto para evitar abrir duas vezes.

```bash
phpstorm-dev
```

### `phpstorms`

Lê todos os projetos ativos de:

```text
config/auto-code-manager.projects
```

Para cada linha não comentada cuja pasta exista em `/home/daniel/Code`, abre uma janela separada do PhpStorm usando `--new-instance`.

```bash
phpstorms
```

O intervalo entre as janelas pode ser alterado:

```bash
PHPSTORMS_OPEN_DELAY_SECONDS=2 phpstorms
```

Linhas comentadas com `#` são ignoradas. Projetos inexistentes são informados e ignorados.

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

## Instalar ou atualizar

```bash
cd /home/daniel/Code/bots/dev-automation
chmod +x scripts/*.sh deploy/local/*.sh
./deploy/local/install-commands.sh
source ~/.bashrc
```

O instalador cria os comandos `auto-code-manager`, `chromes`, `phpstorms`, `phpstorm-dev` e recria os comandos dos projetos listados na configuração.

## Oracle Local Monitor

Projeto isolado em `apps/oracle-monitor`, instalado como comando global `oracle-monitor`. Consulte `apps/oracle-monitor/README.md`.
