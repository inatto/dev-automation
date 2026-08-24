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
