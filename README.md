# dev-automation

Automação local dos projetos em `/home/daniel/Code`, sem `tmux`.

## O que fica disponível globalmente

Depois da instalação, estes comandos podem ser executados de qualquer pasta do WSL:

```bash
auto-code-manager
orbital-app
station-app
inst-app
```

Cada comando de projeto entra automaticamente na pasta correta e usa os scripts em `deploy/local`:

```bash
orbital-app             # start.sh
orbital-app start       # start.sh
orbital-app setup       # setup.sh
orbital-app run         # setup.sh + start.sh
orbital-app test        # test.sh
orbital-app start-api   # start-api.sh, quando existir
orbital-app scripts     # lista as ações disponíveis
orbital-app dir         # mostra a pasta do projeto
```

## Instalar ou atualizar comandos

```bash
cd /home/daniel/Code/bots/dev-automation
chmod +x scripts/*.sh deploy/local/*.sh
./deploy/local/install-commands.sh
source ~/.bashrc
```

O instalador:

- cria `~/.local/bin/auto-code-manager`;
- recria os comandos dos projetos listados em `config/auto-code-manager.projects`;
- remove atalhos antigos gerados anteriormente quando um projeto sai da lista;
- não instala nem utiliza `tmux`.

Sempre que alterar `config/auto-code-manager.projects`, execute novamente:

```bash
cd /home/daniel/Code/bots/dev-automation
./deploy/local/install-commands.sh
source ~/.bashrc
```

## Estrutura

- `scripts/auto-code-manager.sh`: monitora, compacta e restaura projetos.
- `scripts/project-command.sh`: executa ações locais de cada projeto.
- `config/auto-code-manager.projects`: projetos monitorados e usados para gerar comandos.
- `deploy/local/install-commands.sh`: instala tudo globalmente.
- `deploy/local/install-project-commands.sh`: gerador interno dos comandos de projeto.
