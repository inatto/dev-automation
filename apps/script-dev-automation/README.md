# Script Dev Automation

TUI global para auditar e proteger com GitCrypt todas as pastas `.config` dos projetos habilitados no arquivo `.projects` da máquina.

```bash
script-dev-automation
```

- `R`/`F2`: refaz a auditoria.
- `P`: protege a pasta selecionada, após confirmação textual.
- `A`/`F5`: protege todas as pendentes, após confirmação textual.
- `C`: substitui a chave antiga do repositório pela chave correta fixa, com backup e confirmação forte.
- `Q`: encerra.

A chave padrão é fixa em `/home/daniel/static/reverse-crypt.key`. GitCrypt mantém a cópia de trabalho legível quando o repositório está desbloqueado e criptografa os blobs adicionados ao Git. O app prepara `.gitattributes` e as pastas `.config` no índice, mas não cria commits e não reescreve o histórico anterior.

A lista mostra somente projetos que realmente possuem ao menos uma pasta `.config`; agregadores ZIP, projetos ausentes e projetos sem `.config` são examinados e omitidos da interface.
