# Dev Manager

Orquestra os projetos locais em uma única sessão `tmux`.

## Primeira instalação em um WSL novo

```bash
cd /home/daniel/Code/sind-infra
chmod +x deploy/install-dev-manager.sh deploy/dev-manager.sh
./deploy/install-dev-manager.sh
```

O instalador:

- instala o `tmux`;
- cria o comando global `~/.local/bin/dev-manager`;
- adiciona `~/.local/bin` ao `PATH` no `.bashrc`;
- mantém o script real versionado em `sind-infra/deploy/dev-manager.sh`.

## Uso em qualquer pasta

```bash
dev-manager start
dev-manager status
dev-manager attach
dev-manager restart
dev-manager stop
```

## Atalhos do tmux

Pressione `Ctrl+B`, solte e então pressione:

- `N`: próxima janela;
- `P`: janela anterior;
- `W`: lista de janelas;
- `0` a `9`: janela pelo número;
- `D`: sair da sessão sem encerrar os processos.

## Ordem dos projetos

A ordem das chamadas dentro de `start_session` define a ordem das janelas. Para alterar, mova uma linha inteira:

```bash
create_first_window "infra"      "$HOME/Code/sind-infra"          "bash ./deploy/auto-code-manager.sh"
add_window          "sinproprev" "$HOME/Code/site-sinproprev-v2" "bash ./deploy/local.dev.sh"
add_window          "asaclub"    "$HOME/Code/site-asaclub-2026"  "bash ./deploy/local.dev.sh"
add_window          "site-inst"  "$HOME/Code/site-inst"          "bash ./deploy/local.dev.sh anpprev"
add_window          "murm-app"   "$HOME/Code/murm-app"           "flutter run -d linux"
```
