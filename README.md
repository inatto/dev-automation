# dev-automation

Automação local dos projetos em `/home/daniel/Code`.

## Estrutura

- `scripts/`: executores e comandos internos.
- `config/`: projetos monitorados, variáveis e regras de compactação.
- `deploy/local/`: instalação e atualização dos comandos globais no WSL.
- `assets/sounds/`: recursos de áudio usados pelas notificações.
- `docs/`: documentação operacional.

## Instalação

```bash
cd /home/daniel/Code/bots/dev-automation
chmod +x scripts/*.sh deploy/local/*.sh
./deploy/local/install-dev-manager.sh
./deploy/local/install-project-commands.sh
source ~/.bashrc
```

## Execução direta

```bash
./scripts/auto-code-manager.sh
```
