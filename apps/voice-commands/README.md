# Voice Commands

Reconhecimento local de comandos curtos de voz com TUI fullscreen e catálogo editável de palavras/atalhos.

## Uso

```bash
voice-commands
```

A TUI abre em tela cheia e continua ouvindo no painel **F1 AO VIVO**. As páginas de configuração pausam o reconhecimento para evitar disparos enquanto você edita palavras.

- `F1` — ao vivo: microfone, nível, comandos ativos e histórico de reconhecimento.
- `F2` — comandos: avançar/recuar, duas telas, primeira/última tela, áudio, bloqueio, aplicativos etc.
- `F3` — desktops/projetos: lista exatamente os workspaces do comando `desktops --list`, incluindo `orbital-legal`, `orbital-content`, `lrdp1`, `lrdp2` etc.
- `F4` — diagnóstico: modelo, device, backend, JSON, logs e ferramentas disponíveis.
- `A` — adiciona uma palavra/frase ao comando selecionado.
- `Enter`/`E` — edita a palavra selecionada.
- `Del` ou `X` — remove a palavra selecionada.
- `R` — restaura as palavras padrão daquele comando.
- `Ctrl+F` — salva e volta imediatamente para **F1 AO VIVO**.
- `Q` — sai. Se houver alteração sem salvar, exige uma segunda confirmação.

`Tab`, `←` e `→` alternam o foco entre a lista de comandos/desktops e a lista de palavras. `↑`/`↓` navegam como uma BIOS. `F10` não é usado, evitando o atalho/menu do terminal.

Para abrir só a configuração sem carregar o Whisper:

```bash
voice-commands --configure
```

Para listar tudo em texto:

```bash
voice-commands --list-commands
```

## Arquivo de palavras

O padrão do projeto fica em:

```text
apps/voice-commands/commands.defaults.json
```

A configuração editável fica em:

```text
apps/voice-commands/commands.json
```

Se `commands.json` não existir, ele é reconstruído a partir do padrão. O programa preserva palavras de desktops que estejam temporariamente fora da lista e impede que a mesma frase seja vinculada a duas ações diferentes.

Exemplos iniciais:

- `jurídico` / `juridico` → desktop `orbital-legal`.
- `conteúdo` / `conteudo` → desktop `orbital-content`.
- `rdp1` / `rdp um` → desktop `lrdp1`.
- `rdp2` / `rdp dois` → desktop `lrdp2`.
- `avança duas telas` → avança dois workspaces.
- `última tela` → último workspace configurado.
- `mudo` → silencia o áudio.
- `bloquear` / `suspender` → bloqueia a tela, sem suspender a máquina.
- `calculadora`, `bloco de notas`, `e-mail`, `terminal`, `meus arquivos`, `navegador` → abrem aplicativos/handlers do Ubuntu.

A ação **Suspender computador** existe no catálogo, mas começa sem palavra vinculada para evitar suspensão acidental. Se quiser, cadastre uma frase explícita pela TUI.

## Como vai para um desktop específico

A lista de projetos é lida do mesmo `scripts/desktops.sh --list` usado pelo dev-automation. Em X11, quando possível, usa seleção absoluta. Em Wayland, sem depender de API privada do GNOME, recua até o primeiro workspace e então avança até o índice desejado. Isso evita exigir logout ou alteração da extensão GNOME apenas para o Voice Commands.

## Precisão e GPU

O Whisper usa `medium`, português fixo (`pt`) e `beam_size=5`. O padrão agora é NVIDIA CUDA:

- device principal: `cuda`;
- compute principal: `float16`;
- fallback ainda na GPU: `int8_float16`;
- fallback silencioso para CPU: desativado.

Assim, se CUDA/cuBLAS/cuDNN estiver quebrado, o programa mostra o erro em vez de fingir que está tudo bem enquanto volta para uma CPU lenta. As palavras cadastradas no JSON entram também no `initial_prompt` do Whisper, então aliases como `jurídico`, `conteúdo` e nomes de projetos ajudam a transcrição antes mesmo do matcher.

Para instalar o runtime GPU dentro do próprio `.venv`, sem trocar o driver NVIDIA do Ubuntu:

```bash
cd apps/voice-commands
./install.sh --gpu
./run.sh --doctor
```

O instalador adiciona cuBLAS para CUDA 12 e cuDNN 9 ao venv. `run.sh` inclui automaticamente essas bibliotecas no `LD_LIBRARY_PATH` antes de iniciar o CTranslate2. O serviço systemd também passa por `run.sh`, então terminal e serviço usam o mesmo runtime CUDA.

## Gravação de diagnóstico

Toda fala que gerar texto é salva por dia:

```text
apps/voice-commands/logs/YYYY-MM-DD/
  HH-MM-SS-micros.wav
  events.jsonl
  transcriptions.tsv
```

O WAV é exatamente o áudio entregue ao Whisper. O JSONL guarda transcrição, comando, frase casada, similaridade e resultado.

## Outros modos

```bash
voice-commands --stdin --dry-run
voice-commands --doctor
voice-commands --no-tui
```

## Serviço

```bash
./install-service.sh
```

O serviço usa log textual porque não possui terminal interativo e inicia via `run.sh`, preservando o runtime CUDA do venv.
