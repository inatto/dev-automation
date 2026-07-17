# Padrão de portas das aplicações

Orientação para a futura padronização. Este documento não altera as portas atuais.

## Faixas

| Uso | Astro | API |
|---|---:|---:|
| Aplicações base | `4000–4099` | `8000–8099` |
| Instâncias white-label e tenants | `4100–4999` | `8100–8999` |

- A mesma porta deve ser usada no ambiente local e no remoto.
- Cada processo que roda simultaneamente no mesmo servidor precisa de uma porta própria.
- Um tenant pode compartilhar a API da aplicação base. A faixa `8100–8999` só será usada quando o tenant tiver API isolada.
- As portas devem ficar no `.env` de cada aplicação, nunca fixas no código.

## Numeração inicial

| Aplicação | Tipo | Astro | API |
|---|---|---:|---:|
| `orbital-app` | Base | `4001` | `8001` |
| `station-app` | Base | `4002` | `8002` |
| `site-inst` | Base | `4003` | `8003` |
| `site-murm` | Base | `4004` | — |
| `site-inst/anpprev` | Tenant | `4100` | Compartilha `8003` |
| `site-inst/sinproprev` | Tenant | `4101` | Compartilha `8003` |
| `site-asaclub-2026` | Cliente | `4102` | — |
| `site-sinproprev-v2` | Cliente | `4103` | — |

As próximas aplicações base seguem a partir de `4005`/`8005`. Os próximos tenants e projetos de clientes seguem a partir de `4104`.

## Migração futura

Para cada aplicação:

1. Atualizar as portas no `.env` e no `.env.example` correspondente.
2. Remover portas fixas de scripts, configurações e URLs internas.
3. Atualizar CORS, Nginx, systemd ou PM2 quando existirem.
4. Confirmar que a porta está livre e testar site, API e integração entre eles.

Não entram nessa numeração: `sind-infra`, `general-crawler` e outros projetos que não mantêm servidor de aplicação ativo.
