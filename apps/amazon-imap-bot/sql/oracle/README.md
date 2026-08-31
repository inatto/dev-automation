# Patches Oracle do catálogo de funções

O catálogo do Amazon IMAP Bot é relacional. Nenhuma definição de função, parâmetro ou nível permitido fica persistida como JSON.

## Banco que já recebeu a versão antiga

Execute manualmente, nesta ordem:

1. `004_normalize_function_catalog.sql`
2. `005_seed_function_catalog_relational.sql`

O `004` cria as tabelas relacionais e remove de `IMAP_BOT_FUNCTIONS` as colunas legadas `ALLOWED_REASONING_LEVELS_JSON` e `PARAMETERS_JSON`. O `005` grava as funções, parâmetros, opções, níveis e autorizações nas colunas/tabelas próprias.

## Instalação nova

Execute manualmente, nesta ordem:

1. `001_create_function_catalog.sql`
2. `002_seed_function_catalog.sql`

Os scripts são idempotentes. O Amazon IMAP Bot não executa DDL ou DML do catálogo automaticamente.
