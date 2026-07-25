# dev-automation

Automação local dos projetos em `/home/daniel/Code`, com execução direta em
primeiro plano e encerramento por `Ctrl+C`.

## Comandos globais

Depois da instalação:

```bash
auto-code-manager
dev-manager
chromes
phpstorms
phpstorm-dev
orbital-app
station-app
inst-app
```

### `auto-code-manager`

Monitora a pasta Downloads e associa cada ZIP ao projeto pelo começo do nome.
Além dos formatos comuns, aceita sufixos gerados ou codificados pelo navegador:

```text
dev-automation.zip
dev-automation(15).zip
dev-automation%23232-3434.zip
dev-automation#revisado.zip
```

O primeiro caractere depois do nome do projeto precisa ser um separador não
alfanumérico. Assim, `dev-automation2.zip` não é confundido com
`dev-automation.zip`.

Para testar somente o reconhecimento, sem importar o arquivo:

```bash
auto-code-manager --identify-zip 'dev-automation%23232-3434.zip'
```

Resultado esperado:

```text
bots/dev-automation
```

#### Backups de grupos com dois níveis

Quando os projetos configurados estão dentro de uma pasta agrupadora, o monitor
mantém os ZIPs individuais e também gera o ZIP da pasta pai. Exemplo:

```text
orgs/orbital/orbital-app     -> orbital-app.zip
orgs/orbital/orbital-assets  -> orbital-assets.zip
orgs/orbital/orbital-fin     -> orbital-fin.zip
orgs/orbital/orbital-mail    -> orbital-mail.zip
orgs/orbital/orbital-reports -> orbital-reports.zip
orgs/orbital                  -> orbital.zip
```

O `orbital.zip` representa diretamente a raiz de `orgs/orbital`. Ele contém:

- os arquivos próprios da pasta pai, como configurações compartilhadas;
- `orbital-app.zip`, `orbital-assets.zip`, `orbital-fin.zip`,
  `orbital-mail.zip` e `orbital-reports.zip`.

As pastas completas dos módulos não são duplicadas dentro do ZIP pai. Ao receber
`orbital.zip`, o importador valida primeiro todos os ZIPs filhos e depois extrai
cada um diretamente em seu módulo correspondente. Os ZIPs filhos não ficam
soltos em `orgs/orbital` e o ZIP pai só é apagado após todas as conferências.
Todos os ZIPs individuais e o ZIP pai também são incluídos no `Code.zip`.

Para conferir os alvos inferidos:

```bash
auto-code-manager --list-backup-targets
```

Para gerar uma rodada imediatamente, sem iniciar o monitor contínuo:

```bash
auto-code-manager --backup-once
```

Para testar/importar diretamente um único ZIP sem iniciar o monitor contínuo:

```bash
auto-code-manager --import-one '/caminho/orbital.zip'
```

### `dev-manager`

Executa o `auto-code-manager` diretamente no terminal atual:

```bash
dev-manager
```

Para encerrar, pressione `Ctrl+C`. Não existe sessão separada para anexar ou
manter em segundo plano.

### `chromes`

Abre duas janelas do Chrome:

- perfil `Default`, somente em `https://chatgpt.com/`;
- perfil `Profile 2`, em uma nova aba vazia.

```bash
chromes
```

### `phpstorm-dev`

Abre somente `/home/daniel/Code/bots/dev-automation` no PhpStorm. O comando
`phpstorms` ignora esse projeto para evitar abrir duas vezes.

```bash
phpstorm-dev
```

### `phpstorms`

Lê os projetos ativos de `config/auto-code-manager.projects`.

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
orbital-app             # setup.sh + start.sh
orbital-app start       # somente start.sh
orbital-app setup       # somente setup.sh
orbital-app run         # setup.sh + start.sh
orbital-app test        # test.sh
orbital-app scripts     # lista ações disponíveis
orbital-app dir         # mostra a pasta
```

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
`phpstorms`, `phpstorm-dev` e os comandos dos projetos listados na configuração.

## Oracle Local Monitor

Projeto isolado em `apps/oracle-monitor`, instalado como comando global
`oracle-monitor`. Consulte `apps/oracle-monitor/README.md`.
