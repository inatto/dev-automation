# LRDP Control Center

`lrdp` abre a interface fullscreen de gerenciamento do FreeRDP. Não há dependências Python externas: a interface usa `curses` da biblioteca padrão.

## Tela principal

- Descobre automaticamente `apps/lrdp/lrdp1`, `lrdp2`, `lrdp3` etc.
- Exibe destino/IP, porta, login efetivo, áudio, microfone e monitor principal.
- Testa a porta RDP em segundo plano sem travar a interface.
- Detecta processo `xfreerdp3` local já ativo para cada destino.
- Desenha os monitores proporcionalmente a partir de `xfreerdp3 /list:monitor`, respeitando resolução e coordenadas X/Y.
- Mostra o principal local (`LOCAL★`) e o principal da sessão RDP (`RDP★`).
- Mostra saídas físicas conectadas/desconectadas por `/sys/class/drm`.
- Mostra IP de origem, interface, gateway e rota até o RDP.
- Mostra o comando FreeRDP efetivo sem revelar senha.

## Teclas

- `↑`/`↓`: selecionar RDP.
- `1`..`9`: seleção rápida.
- `Enter`: conectar com a configuração salva.
- `F2`: configuração estilo BIOS. O campo **IP de destino** abre a edição com `Enter`; `←`/`→` altera as demais opções; `F10` ou `S` salva; `Esc` cancela.
- `F3`: mapa de monitores. `←`/`→` escolhe e `Enter` define o principal.
- `F4`: diagnóstico de rede/Ubuntu.
- `F5`: redetectar RDPs, monitores, DRM e rede.
- `F1`: ajuda.
- `Q`: sair da TUI. Sessões RDP abertas continuam rodando.

## Persistência

Cada RDP grava login/áudio/microfone/monitor em `~/.config/dev-automation/lrdp/lrdpN.conf`. Quando o IP é alterado pelo F2 e salvo com `F10/S`, a TUI atualiza diretamente a linha `LRDP_TARGET` do respectivo `apps/lrdp/lrdpN`. As credenciais continuam definidas no script; a TUI recebe apenas metadados sem senha por `--metadata`.

A TUI abre o RDP com `--saved`, que evita qualquer prompt no terminal. Logs de lançamento ficam em `~/.local/state/dev-automation/lrdp/lrdpN.log`.

## Adicionar outro RDP

Copie um dos scripts `apps/lrdp/lrdpN`, ajuste `LRDP_NAME`, `LRDP_LABEL`, `LRDP_TARGET` e `LOGIN_PROFILES`, e use um novo número. A TUI e o instalador global descobrem o novo arquivo automaticamente.
