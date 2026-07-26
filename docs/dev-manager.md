# Dev Manager

O `dev-manager` atualiza todos os comandos globais e depois executa o
`auto-code-manager` diretamente em primeiro plano. Não existe sessão separada
nem processo intermediário: `Ctrl+C` chega ao monitor e encerra o loop de forma
limpa.

## Instalar ou atualizar

O instalador principal já cria o comando global:

```bash
cd /home/daniel/Code/bots/dev-automation
chmod +x scripts/*.sh deploy/local/*.sh
./deploy/local/install-commands.sh
source ~/.bashrc
```

Também é possível instalar somente este comando:

```bash
./deploy/local/install-dev-manager.sh
source ~/.bashrc
```

## Uso

```bash
dev-manager              # inicia em primeiro plano
dev-manager start        # equivalente
dev-manager commands     # apenas atualiza todos os comandos globais
dev-manager status       # procura um monitor ativo
dev-manager --test-sound # testa o aviso sonoro
dev-manager help         # ajuda
```

Ao iniciar, o `dev-manager` chama `deploy/local/install-commands.sh`. Esse
script atualiza os comandos fixos, incluindo `oracle-monitor`, e chama
`install-project-commands.sh`, que
recria os comandos dos projetos listados em `config/auto-code-manager.projects`.

Para parar, volte ao terminal em execução e pressione `Ctrl+C`.

Quando toda a rodada de backups termina com sucesso, incluindo a validação do
`Code.zip`, o monitor toca `C:\\Windows\\Media\\ding.wav` uma única vez.
Não toca após cada projeto individual.

## Projetos e pastas agrupadoras

O arquivo `config/auto-code-manager.projects` aceita caminhos relativos a
`/home/daniel/Code`. As entradas continuam sendo usadas pelo backup e pelos
comandos globais individuais dos projetos.

Quando houver entradas com exatamente três segmentos, como
`orgs/orbital/orbital-app`, o backup também inclui automaticamente a pasta pai
`orgs/orbital`, gerando `orbital.zip` além dos ZIPs individuais. O ZIP pai leva
os arquivos próprios da pasta agrupadora e os ZIPs dos módulos. Na importação,
os ZIPs filhos são validados e extraídos em suas respectivas pastas antes de o
ZIP pai ser removido.

## Lote de Downloads

Em cada ciclo, todos os arquivos `.zip` já presentes em Downloads são capturados
numa lista única. O monitor mostra `LOTE [1/N]`, processa do primeiro ao último e
só depois segue para limpeza de `Zone.Identifier`, backups e espera do próximo
ciclo. Para testar uma rodada sem deixar o monitor contínuo aberto:

```bash
auto-code-manager --import-downloads-once
```
