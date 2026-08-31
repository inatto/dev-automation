-- Amazon IMAP Bot - migração/seed do catálogo de funções
-- Execução MANUAL, após 001_create_function_catalog.sql.
-- MERGE torna o patch idempotente. Nenhuma senha é armazenada.

MERGE INTO WKSP_SINDICATTO.IMAP_BOT_FUNCTION_CATALOG t
USING (SELECT 'DEFAULT' catalog_key, 2 catalog_version FROM dual) s
ON (t.catalog_key = s.catalog_key)
WHEN MATCHED THEN UPDATE SET t.catalog_version = s.catalog_version, t.updated_at = SYSTIMESTAMP
WHEN NOT MATCHED THEN INSERT (catalog_key, catalog_version) VALUES (s.catalog_key, s.catalog_version);

MERGE INTO WKSP_SINDICATTO.IMAP_BOT_REASONING_LEVELS t
USING (
  SELECT 0 level_id, 'none' effort_name FROM dual UNION ALL
  SELECT 1, 'low' FROM dual UNION ALL
  SELECT 2, 'medium' FROM dual UNION ALL
  SELECT 3, 'high' FROM dual UNION ALL
  SELECT 4, 'xhigh' FROM dual UNION ALL
  SELECT 5, 'max' FROM dual
) s
ON (t.level_id = s.level_id)
WHEN MATCHED THEN UPDATE SET t.effort_name = s.effort_name, t.enabled = 'Y'
WHEN NOT MATCHED THEN INSERT (level_id, effort_name, enabled) VALUES (s.level_id, s.effort_name, 'Y');

MERGE INTO WKSP_SINDICATTO.IMAP_BOT_FUNCTIONS t
USING (
  SELECT
    'api_zip_test' function_name,
    'Y' enabled,
    q'~Executa semanticamente o teste ZIP da API.~' description,
    2 default_reasoning_level,
    '[0,1,2,3,4,5]' allowed_json,
    q'~{"type":"object","properties":{"reasoning_level":{"type":"integer","enum":[0,1,2,3,4,5],"description":"Nível solicitado: 0=none, 1=low, 2=medium, 3=high, 4=xhigh, 5=max."},"request_text":{"type":"string","description":"Pergunta ou instrução que deve ser respondida dentro do teste ZIP."}},"required":["reasoning_level","request_text"],"additionalProperties":false}~' parameters_json
  FROM dual
) s
ON (t.function_name = s.function_name)
WHEN MATCHED THEN UPDATE SET
  t.enabled = s.enabled,
  t.description = s.description,
  t.default_reasoning_level = s.default_reasoning_level,
  t.allowed_reasoning_levels_json = s.allowed_json,
  t.parameters_json = s.parameters_json,
  t.updated_at = SYSTIMESTAMP
WHEN NOT MATCHED THEN INSERT (
  function_name, enabled, description, default_reasoning_level,
  allowed_reasoning_levels_json, parameters_json
) VALUES (
  s.function_name, s.enabled, s.description, s.default_reasoning_level,
  s.allowed_json, s.parameters_json
);

MERGE INTO WKSP_SINDICATTO.IMAP_BOT_FUNCTIONS t
USING (
  SELECT
    'project_zip_edit' function_name,
    'Y' enabled,
    q'~Seleciona um ZIP de projeto e permite modificar, revisar, analisar, explicar, resumir ou investigar seu conteúdo.~' description,
    2 default_reasoning_level,
    '[0,1,2,3,4,5]' allowed_json,
    q'~{"type":"object","properties":{"reasoning_level":{"type":"integer","enum":[0,1,2,3,4,5],"description":"Nível solicitado: 0=none, 1=low, 2=medium, 3=high, 4=xhigh, 5=max."},"request_text":{"type":"string","description":"Pedido original sobre o projeto, preservando o sentido e os detalhes do remetente."},"operation":{"type":"string","enum":["modify","query"],"description":"modify altera o ZIP; query apenas analisa, explica ou responde."}},"required":["reasoning_level","request_text","operation"],"additionalProperties":false}~' parameters_json
  FROM dual
) s
ON (t.function_name = s.function_name)
WHEN MATCHED THEN UPDATE SET
  t.enabled = s.enabled,
  t.description = s.description,
  t.default_reasoning_level = s.default_reasoning_level,
  t.allowed_reasoning_levels_json = s.allowed_json,
  t.parameters_json = s.parameters_json,
  t.updated_at = SYSTIMESTAMP
WHEN NOT MATCHED THEN INSERT (
  function_name, enabled, description, default_reasoning_level,
  allowed_reasoning_levels_json, parameters_json
) VALUES (
  s.function_name, s.enabled, s.description, s.default_reasoning_level,
  s.allowed_json, s.parameters_json
);

MERGE INTO WKSP_SINDICATTO.IMAP_BOT_FUNCTIONS t
USING (
  SELECT
    'function_catalog_admin' function_name,
    'Y' enabled,
    q'~Lista o catálogo de funções ou sincroniza a camada de aplicação recarregando as definições e autorizações do Oracle.~' description,
    1 default_reasoning_level,
    '[0,1,2,3,4,5]' allowed_json,
    q'~{"type":"object","properties":{"operation":{"type":"string","enum":["list","sync"],"description":"list consulta o catálogo carregado; sync recarrega o catálogo a partir do Oracle."},"reasoning_level":{"type":"integer","enum":[0,1,2,3,4,5]},"request_text":{"type":"string","description":"Contexto opcional do pedido de administração do catálogo."}},"required":["operation"],"additionalProperties":false}~' parameters_json
  FROM dual
) s
ON (t.function_name = s.function_name)
WHEN MATCHED THEN UPDATE SET
  t.enabled = s.enabled,
  t.description = s.description,
  t.default_reasoning_level = s.default_reasoning_level,
  t.allowed_reasoning_levels_json = s.allowed_json,
  t.parameters_json = s.parameters_json,
  t.updated_at = SYSTIMESTAMP
WHEN NOT MATCHED THEN INSERT (
  function_name, enabled, description, default_reasoning_level,
  allowed_reasoning_levels_json, parameters_json
) VALUES (
  s.function_name, s.enabled, s.description, s.default_reasoning_level,
  s.allowed_json, s.parameters_json
);

MERGE INTO WKSP_SINDICATTO.IMAP_BOT_FUNCTION_SENDERS t
USING (SELECT 'danielmaiax@gmail.com' sender_email FROM dual) s
ON (t.sender_email = s.sender_email)
WHEN MATCHED THEN UPDATE SET t.enabled = 'Y', t.updated_at = SYSTIMESTAMP
WHEN NOT MATCHED THEN INSERT (sender_email, enabled) VALUES (s.sender_email, 'Y');

MERGE INTO WKSP_SINDICATTO.IMAP_BOT_SENDER_FUNCTIONS t
USING (
  SELECT 'danielmaiax@gmail.com' sender_email, 'api_zip_test' function_name FROM dual UNION ALL
  SELECT 'danielmaiax@gmail.com', 'project_zip_edit' FROM dual UNION ALL
  SELECT 'danielmaiax@gmail.com', 'function_catalog_admin' FROM dual
) s
ON (t.sender_email = s.sender_email AND t.function_name = s.function_name)
WHEN MATCHED THEN UPDATE SET t.enabled = 'Y', t.updated_at = SYSTIMESTAMP
WHEN NOT MATCHED THEN INSERT (sender_email, function_name, enabled)
VALUES (s.sender_email, s.function_name, 'Y');

COMMIT;
