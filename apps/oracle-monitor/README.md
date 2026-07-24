# Oracle Local Monitor

Aplicação isolada do `dev-automation` para visualizar sessões, transações abertas e bloqueios Oracle dos aplicativos executados no localhost.

## Configuração

1. Copie as credenciais Oracle para `apps/api/.env`.
2. O usuário Oracle precisa conseguir consultar `V$SESSION` e `V$TRANSACTION`.
3. Ajuste `ORACLE_LOCAL_MACHINE_FILTER` conforme o valor exibido em `V$SESSION.MACHINE`.

## Comandos

```bash
oracle-monitor setup
oracle-monitor start
oracle-monitor test
```

Página: `http://localhost:4010`

A aplicação abre uma conexão curta por atualização, identifica a própria sessão como `oracle-monitor-local` e a fecha após cada coleta. Ela não reutiliza nem interfere nos pools dos demais projetos.
