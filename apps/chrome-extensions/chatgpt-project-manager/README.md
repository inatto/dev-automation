# GPT Project Manager

Extensão Chrome Manifest V3 que usa a hierarquia do `auto-code-manager.projects` e abre/cria Projects e novos chats no ChatGPT sem vínculo manual de URL.

## Fonte principal

Selecione diretamente, em cada máquina, o arquivo local:

```text
/home/daniel/Code/bots/dev-automation/config/auto-code-manager.projects
```

Formato:

```text
#bots/importer
bots/dev-automation
infra/amazon-infra
infra/amazon-infra/apps/monitor-app
orgs/orbital/orbital-app
orgs/orbital/orbital-mail
```

Regras:

- uma linha ativa = um projeto;
- linhas iniciadas por `#` são ignoradas;
- `/` define a hierarquia visual;
- um projeto que também é pai de outro caminho aparece uma única vez como nó expansível.

Também continuam aceitos JSON e URL HTTP/HTTPS que devolva JSON ou `.projects`.

## Projects do ChatGPT automáticos

Cada projeto da árvore tem:

- **+ Novo chat**: localiza no ChatGPT um Project com o mesmo nome; se não existir, tenta criá-lo; depois inicia um novo chat dentro desse Project;
- **Abrir GPT**: abre o Project já associado;
- **Abrir/Criar GPT**: quando ainda não há associação salva, localiza/cria automaticamente o Project.

Não existe mais necessidade de colar manualmente URL de Project/chat na tela de edição.

A associação automática `projeto local -> URL do Project ChatGPT` fica em `chrome.storage.sync`. O conteúdo real, os chats, os arquivos, as instruções e a memória continuam pertencendo ao Project real do ChatGPT.

A automação usa a interface web oficial do ChatGPT, não endpoints privados. Como a interface do ChatGPT pode mudar, seletores de UI ficam isolados em `src/content.js` para manutenção pontual.

## Vários computadores

- O arquivo/URL de origem é configurado localmente em cada máquina.
- A associação com os Projects do GPT, favoritos, pastas adicionais e notas usam `chrome.storage.sync`.
- Os chats e o contexto real sincronizam pela própria conta ChatGPT.
- Para extensão publicada na Chrome Web Store, o ID da extensão é o mesmo em todas as máquinas. Em instalação manual/descompactada, a sincronização do `chrome.storage.sync` depende de o Chrome reconhecer a mesma extensão/ID e de a sincronização da conta Chrome estar habilitada.

## Ocultar barra original

A opção apenas esconde visualmente a barra lateral do ChatGPT via CSS. Não remove dados da conta.

## Instalação/reload

1. abra `chrome://extensions`;
2. ative **Modo do desenvolvedor**;
3. carregue `apps/chrome-extensions/chatgpt-project-manager`;
4. após substituir por uma versão nova na mesma pasta, clique em **Recarregar**.


## v0.3.1

- Corrige `Could not establish connection. Receiving end does not exist` ao usar uma aba do ChatGPT que já estava aberta quando a extensão foi instalada/recarregada.
- O service worker agora injeta `src/content.js` automaticamente quando necessário e tenta novamente.
- A injeção é idempotente para não duplicar listeners.
