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

## Logitech G512 RGB

O auxiliar RGB do Logitech G512 agora pertence ao `dev-automation`, em
`scripts/g512-rgb.sh`. Ao iniciar, o `dev-manager` garante esse helper de forma
independente: uma falha do RGB não derruba nem bloqueia o monitor principal.

Na primeira execução em uma máquina que ainda tenha `g512-rgb.service`, o helper
interrompe a unit legada, lê o `ExecStart`, copia o script Python real e seus
arquivos auxiliares para `scripts/g512/`, cria
`dev-automation-g512-rgb.service` e remove a unit antiga depois de uma migração
bem-sucedida. O serviço novo usa limite de reinícios para nunca repetir o loop
de falha a cada poucos segundos que a unit antiga podia produzir.

Comandos úteis:

```bash
g512-rgb status
g512-rgb migrate
g512-rgb restart
g512-rgb stop
```

Depois que `g512-rgb status` mostrar o código incorporado em
`dev-automation/scripts/g512/`, o projeto externo do G512 não é mais necessário.

O ícone do `Dev Automation` na bandeja do Windows também aceita botão direito:

- `Pausar dev-manager`: termina apenas a operação indivisível já em andamento e
  não inicia a próxima etapa/projeto;
- `Despausar dev-manager`: retoma o mesmo processo, sem reiniciar o monitor.

Enquanto estiver efetivamente pausado, o ícone mostra `P` e o status `Pausado`.
O controle é cooperativo para nunca interromper no meio uma gravação ou
substituição de ZIP.

Quando toda a rodada de backups configurados termina com sucesso, o monitor pode
tocar `C:\\Windows\\Media\\ding.wav` uma única vez. `Code.zip` só participa
da rodada quando estiver explicitamente listado em `auto-code-manager.projects`.

## Projetos e agregadores explícitos

O arquivo `config/auto-code-manager.projects` aceita caminhos relativos a
`/home/daniel/Code` e é a única fonte da verdade para backup.

- `bots/dev-automation` é um projeto e gera `dev-automation.zip`;
- `bots/dev-automation/apps/amazon-imap-bot` é outro projeto e gera `dev-automation-amazon-imap-bot.zip`;
- como o segundo está dentro do primeiro, `apps/amazon-imap-bot/` é excluído de
  `dev-automation.zip` para não existir em dois backups;
- o ZIP filho mantém a raiz `apps/amazon-imap-bot/`, e o unzip do pai também
  ignora esse caminho para nunca sobrescrever o subprojeto;
- `bots/dev-automation/apps.zip` habilita opcionalmente `apps.zip`;
- `orgs/orbital.zip` habilita opcionalmente `orbital.zip`;
- `Code.zip` habilita opcionalmente o agregador geral.

Nenhum agregador é inferido. Ao remover/comentar uma entrada `.zip`, aquele ZIP
deixa de ser atualizado. Como a saída é a própria pasta `Code`, ZIPs antigos ou
manuais nunca são apagados automaticamente. Agregadores contêm
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
do ZIP do pai. Após `BACKUP_EVERY` segundos sem novas alterações (1s na
configuração atual), o manager compacta apenas os projetos marcados e os
agregadores explícitos que dependem deles.

Diretórios do ignore global, como `.git/`, `.venv/`, `venv/` e
`node_modules/`, são removidos da própria árvore de watches (`@path`), reduzindo
uso de memória/watches e impedindo que atividade de dependências dispare backup.
Novos diretórios ignorados criados durante a execução fazem o watcher se
reconfigurar e podar a nova subárvore.

Em Linux nativo, `Zone.Identifier` não recebe tratamento especial. A compatibilidade
para esse sidecar continua restrita ao WSL.

Dependência no Ubuntu/WSL:

```bash
sudo apt-get install -y inotify-tools
```

## Cores dos ciclos

Quando a saída está em um terminal compatível, cada contexto do ciclo usa uma
cor fixa para facilitar a leitura:

- ciclo completo: ciano;
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

O nome da última pasta de cada projeto normal é sua chave lógica global. Dois projetos cadastrados não podem ter a mesma chave, mesmo sob pais diferentes; o `dev-manager` aborta antes de gerar backups quando encontra duplicidade.

Subprojetos cadastrados usam nome qualificado no ZIP para evitar colisões. Exemplo: `bots/dev-automation` + `bots/dev-automation/apps/amazon-imap-bot` gera `dev-automation.zip` e `dev-automation-amazon-imap-bot.zip`, com os arquivos do filho dentro de `apps/amazon-imap-bot/`.
