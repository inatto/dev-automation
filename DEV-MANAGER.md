# Dev Manager

Orquestra os projetos locais em uma única sessão `tmux`.

## Primeira instalação em um WSL novo

```bash
cd /home/daniel/Code/dev-automation
chmod +x install-dev-manager.sh dev-manager.sh
./install-dev-manager.sh
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
create_first_window "automation" "$HOME/Code/dev-automation" "bash ./auto-code-manager.sh"
add_window          "sinproprev" "$HOME/Code/site-sinproprev-v2" "bash ./deploy/local.dev.sh"
add_window          "asaclub"    "$HOME/Code/site-asaclub-2026"  "bash ./deploy/local.dev.sh"
add_window          "site-inst"  "$HOME/Code/site-inst"          "bash ./deploy/local.dev.sh anpprev"
add_window          "murm-app"   "$HOME/Code/murm-app"           "flutter run -d linux"
```


## Projetos e pastas agrupadoras

O arquivo `auto-code-manager.projects` aceita caminhos relativos a `/home/daniel/Code`.

```text
infra
sindicatto/station-app
siteverso/site-foto
```

- `infra` gera `/home/daniel/Code/infra.zip` com toda a pasta.
- `sindicatto/station-app` gera `/home/daniel/Code/station-app.zip`.
- Ao compactar uma pasta agrupadora, todos os arquivos `auto-code-manager.ignore-zip` encontrados dentro dela são aplicados no respectivo subdiretório.
- Na importação, todos os arquivos `auto-code-manager.ignore-unzip` já existentes no destino também são aplicados recursivamente.
- Duas entradas com o mesmo nome final de pasta são recusadas, pois gerariam o mesmo nome de ZIP.
