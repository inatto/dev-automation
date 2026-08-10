# Dev Status

Indicador nativo do `dev-automation` na taskbar do Windows 10/11.

- C++20 + Win32/COM, sem .NET, Electron ou Python em runtime.
- Uma única instância residente.
- IPC local por Named Pipe com acesso restrito ao usuário atual e clientes remotos rejeitados.
- Ícone persistente na área de notificação (system tray) via `Shell_NotifyIcon`, visível em qualquer desktop virtual.
- Overlay e título mudam conforme `backup`, `unzip`, `zip`, `sync`, `clean`, `done` e `error`.
- O cliente inicia o servidor automaticamente quando necessário.

## Build

No WSL:

```bash
dev-status --build
```

Requer Visual Studio Build Tools com o workload **Desktop development with C++**. O executável fica em:

```text
apps/dev-status/bin/dev-status.exe
```

## Teste manual

```bash
dev-status backup
dev-status unzip
dev-status zip 40
dev-status sync
dev-status done
dev-status error
dev-status idle
dev-status exit
```

O `auto-code-manager` usa o indicador automaticamente quando o `.exe` existe. A ausência do executável nunca bloqueia backup/importação.

Ao executar `dev-manager`, se `apps/dev-status/bin/dev-status.exe` ainda não existir, o build C++ é tentado automaticamente uma única vez. Depois de gerado, os próximos starts reutilizam o executável existente.
