# Patches Oracle do catálogo de funções

Execução manual, na ordem:

1. `001_create_function_catalog.sql`
2. `002_seed_function_catalog.sql`

Os patches são idempotentes. O primeiro cria apenas a estrutura ausente; o segundo usa `MERGE` para migrar/atualizar o catálogo atual e registrar `function_catalog_admin`.

O Amazon IMAP Bot não executa estes arquivos automaticamente. Depois de aplicá-los, preencha somente `DB_PASSWORD` em `.config/amazon-imap-bot/database.env`.
