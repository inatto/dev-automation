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

O ícone do `Dev Automation` na bandeja do Windows também aceita botão direito:

- `Pausar dev-manager`: termina apenas a operação indivisível já em andamento e
  não inicia a próxima etapa/projeto;
- `Despausar dev-manager`: retoma o mesmo processo, sem reiniciar o monitor.

Enquanto estiver efetivamente pausado, o ícone mostra `P` e o status `Pausado`.
O controle é cooperativo para nunca interromper no meio uma gravação/importação
ou substituição de ZIP.

Quando toda a rodada de backups configurados termina com sucesso, o monitor pode
tocar `C:\\Windows\\Media\\ding.wav` uma única vez. `Code.zip` só participa
da rodada quando estiver explicitamente listado em `auto-code-manager.projects`.

## Projetos e agregadores explícitos

O arquivo `config/auto-code-manager.projects` aceita caminhos relativos a
`/home/daniel/Code` e é a única fonte da verdade para backup/importação.

- `bots/dev-automation` é um projeto e gera `dev-automation.zip`;
- `bots/dev-automation/apps/exec-agent` é outro projeto e gera `dev-automation--exec-agent.zip`;
- como o segundo está dentro do primeiro, `apps/exec-agent/` é excluído de
  `dev-automation.zip` para não existir em dois backups;
- `bots/dev-automation/apps.zip` habilita opcionalmente `apps.zip`;
- `orgs/orbital.zip` habilita opcionalmente `orbital.zip`;
- `Code.zip` habilita opcionalmente o agregador geral.

Nenhum agregador é inferido. Ao remover/comentar uma entrada `.zip`, aquele ZIP
deixa de ser gerenciado e é removido na limpeza de backups. Agregadores contêm
somente ZIPs de alvos configurados abaixo da pasta e um agregador mais específico
substitui seus descendentes no agregador acima, evitando duplicação.

## Backup inteligente por inotify

O monitor usa `inotifywait` (`inotify-tools`) para detectar alterações reais nas
raízes dos projetos. Ao iniciar, faz uma única baseline completa para cobrir
alterações feitas enquanto o manager estava desligado. Depois da baseline, não
existe mais backup completo periódico por relógio.

Cada evento é atribuído ao projeto normal mais específico. Assim, uma alteração
em `bots/dev-automation/apps/exec-agent` marca somente `exec-agent`; o pai
`dev-automation` não é recompactado porque o subprojeto cadastrado já é excluído
do ZIP do pai. Após `BACKUP_EVERY` segundos sem novas alterações (20s na
configuração atual), o manager compacta apenas os projetos marcados e os
agregadores explícitos que dependem deles.

Diretórios do ignore global, como `.git/`, `.venv/`, `venv/` e
`node_modules/`, são removidos da própria árvore de watches (`@path`), reduzindo
uso de memória/watches e impedindo que atividade de dependências dispare backup.
Novos diretórios ignorados criados durante a execução fazem o watcher se
reconfigurar e podar a nova subárvore.

`Zone.Identifier` é removido por evento dentro dos projetos monitorados. A
varredura completa de segurança continua existindo, mas agora é rara
(`ZONE_EVERY=300`) em vez de percorrer `/home/daniel/Code` a cada poucos
segundos.

Dependência no Ubuntu/WSL:

```bash
sudo apt-get install -y inotify-tools
```

## Lote de Downloads

Em cada ciclo, todos os arquivos `.zip` já presentes em Downloads são capturados
numa lista única. O monitor mostra `LOTE [1/N]`, processa do primeiro ao último e
só depois segue para limpeza de `Zone.Identifier`, backups e espera do próximo
ciclo. Para testar uma rodada sem deixar o monitor contínuo aberto:

```bash
auto-code-manager --import-downloads-once
```

## Cores dos ciclos

Quando a saída está em um terminal compatível, cada contexto do ciclo usa uma
cor fixa para facilitar a leitura:

- ciclo completo: ciano;
- Downloads/importação: azul;
- SQL para ZIP: magenta;
- limpeza de `Zone.Identifier`: amarelo;
- backups configurados: verde;
- espera até o próximo ciclo: cinza;
- erros: vermelho.

Cada etapa mostra uma faixa explícita de `INÍCIO` e `CONCLUÍDO`. Para desativar
as cores sem mudar o restante do comportamento:

```bash
NO_COLOR=1 dev-manager
```

## Som pela bandeja

No ícone do Dev Automation, use o botão direito e escolha `Desativar som` ou `Ativar som`. A preferência fica persistida entre execuções.


## Chave lógica global de projeto

O nome da última pasta de cada projeto normal é sua chave lógica global. Dois projetos cadastrados não podem ter a mesma chave, mesmo sob pais diferentes; o `dev-manager` aborta antes de importar ou gerar backups quando encontra duplicidade.

Subprojetos cadastrados usam nome qualificado apenas no backup automático. Exemplo: `bots/dev-automation` + `bots/dev-automation/apps/exec-agent` gera `dev-automation.zip` e `dev-automation--exec-agent.zip`. Na importação, tanto `exec-agent.zip`/`exec-agent-incremental.zip` quanto `dev-automation--exec-agent.zip` resolvem para o mesmo projeto `exec-agent`.
