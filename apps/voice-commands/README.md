# Voice Commands

Reconhecimento local de comandos curtos de voz para controlar o desktop/workspace.

## Comandos iniciais

Próximo desktop: `vai`, `pode ir`, `avança`, `pode avançar`, `pra frente`, `continua`, `próximo desktop`.

Desktop anterior: `volta`, `pode voltar`, `recua`, `recuar`, `pra trás`, `desktop anterior`.

## Instalação

```bash
cd /home/daniel/Code/bots/dev-automation/apps/voice-commands
./install.sh
```

O `dev-automation` instala o comando global `voice-commands` pelo instalador normal de comandos.

## Uso

```bash
voice-commands
```

Em terminal interativo a TUI é aberta automaticamente. Ela mostra:

- estado do microfone e nível de áudio;
- tudo que o Whisper transcreveu;
- comando reconhecido e confiança;
- ação executada e backend usado;
- falhas, cooldowns e falas ignoradas;
- modelo, device e compute type atuais;
- histórico navegável com setas para cima/baixo.

## Precisão e gravação de diagnóstico

A configuração padrão usa `medium`, português fixo (`pt`), CPU `int8` e busca por feixe (`beam_size=5`). Isso melhora bastante a transcrição em relação ao `tiny` sem reintroduzir a dependência quebrada de CUDA/cuBLAS.

Toda fala que gerar texto é persistida automaticamente em uma pasta por dia:

```text
apps/voice-commands/logs/YYYY-MM-DD/
  HH-MM-SS-micros.wav
  events.jsonl
  transcriptions.tsv
```

O WAV é exatamente o trecho entregue ao Whisper. `events.jsonl` guarda transcrição, comando casado, similaridade e resultado; `transcriptions.tsv` é uma visão simples para leitura. A pasta `logs/` fica fora do Git.

Teclas: `Q`/`Esc` encerra, `↑`/`↓` percorre o histórico e `End` volta ao evento mais recente.

Para log simples, útil em systemd ou depuração:

```bash
voice-commands --no-tui
```

Para validar reconhecimento sem enviar atalhos:

```bash
voice-commands --dry-run
```

Para testar frases digitadas:

```bash
voice-commands --stdin --dry-run
```

Diagnóstico:

```bash
voice-commands --doctor
```

## Serviço

```bash
./install-service.sh
```

O serviço usa log textual porque não possui terminal interativo.
