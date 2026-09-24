# Downloads: fila e prioridade

## Comportamento

Somente ZIPs de projetos/agregadores cadastrados e existentes localmente entram na fila. Arquivos alheios e extensões temporárias, como `.crdownload` e `.part`, ficam intactos.

Na descoberta inicial, os ZIPs são ordenados pela última gravação (`mtime`, com nanossegundos), com `ctime` e nome como desempate. No WSL, as caixas Linux e Windows são combinadas antes da ordenação. A data embutida no nome do ZIP não é usada.

A posição é fixada quando o arquivo entra na fila. Novos arquivos são acrescentados ao final entre importações, inclusive se preservarem uma data antiga. A fila é sequencial, no mesmo processo do monitor: um ZIP termina antes de começar o seguinte. Essa ordem é mantida em memória durante a sessão; após reiniciar, os pendentes são reconstruídos pelos metadados dos arquivos. Isso não mede a ordem de cliques no navegador: downloads ainda incompletos não são importados.

Arquivo em gravação permanece na cabeça até estabilizar. A verificação considera identidade, tamanho, mtime e ctime, detectando também regravação com tamanho igual. Falha de validação, backup ou aplicação preserva o ZIP e pausa a fila; nenhum ZIP mais novo o ultrapassa. O timer não reexecuta indefinidamente um ZIP que falhou sem mudar. Corrigir/substituir/remover esse ZIP libera a fila; reiniciar o monitor também permite nova tentativa. Corrigir a cabeça durante a sessão não muda a posição dela.

## Trabalho reduzido

O catálogo de caminhos, aliases, hierarquia e configurações irmãs fica em memória. A assinatura do arquivo `.projects` invalida o cache ao editar ou substituir o catálogo, e a validação de nomes continua obrigatória antes da fila importar com a nova configuração. A existência local dos projetos é conferida ao vivo.

O inotify continua ativo. Uma reconciliação de segurança consulta apenas os metadados das caixas de Downloads a cada segundo por padrão. Sem mudanças, não lista novamente todos os ZIPs. Não percorre os arquivos dos projetos nesse timer.

Downloads têm prioridade antes de tratar eventos de projetos e entre backups. Na inicialização, a fila existente é atendida antes do baseline completo. Um backup/extração já em execução não é interrompido: a prioridade se aplica no próximo ponto seguro, não é promessa de latência máxima de um segundo.

Backup pré-importação, validação de ZIP/caminhos/permissões, proteção de symlinks e segredos, confirmação da cópia e remoção somente após sucesso continuam ativos. Nenhuma janela Chrome/terminal é alterada por esta mudança.

## Configuração

Padrão no módulo `scripts/dev-manager/00-runtime.sh`:

```bash
DOWNLOAD_SCAN_INTERVAL=1
```

Para personalizar sem alterar o script, adicione ou ajuste somente essa variável em `config/auto-code-manager.env`, preservando as demais linhas. O valor deve ser um inteiro positivo. `STABLE_WAIT` e `BACKUP_EVERY` continuam independentes e não foram reduzidos para acelerar a extração.

Implementação principal: `scripts/dev-manager/70-imports.sh`; índice: `50-project-registry.sh`; identificação: `60-project-runtime.sh`; prioridade: `900-main.sh`, `130-backups.sh`, `160-dirty-backups.sh` e `170-inotify-runtime.sh`.

## Aplicar e verificar

Após importar o pacote e aguardar a conclusão da importação atual, reinicie somente o monitor (não os terminais dos projetos):

```bash
cd /home/daniel/Code/bots/dev-automation
bash scripts/dev-manager/dev-manager.sh stop
bash scripts/dev-manager/dev-manager.sh
```

O comando de início já atualiza os comandos globais pelo instalador existente.

Testes específicos usam diretórios temporários, não os projetos reais:

```bash
cd /home/daniel/Code/bots/dev-automation
bash tests/test-auto-code-manager-project-lookup-cache.sh
bash tests/test-auto-code-manager-downloads-fifo.sh
bash tests/test-auto-code-manager-downloads-priority.sh
bash tests/test-auto-code-manager-downloads-stability.sh
bash tests/test-auto-code-manager-downloads-busy-runtime.sh
```

Resultados e limites dos testes estão em `docs/downloads-optimization-tests.md`.
