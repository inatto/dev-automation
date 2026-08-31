-- Amazon IMAP Bot - seed relacional do catálogo de funções
-- Execução MANUAL. MERGE torna o seed idempotente.
-- Nenhuma definição de função é armazenada como JSON.

MERGE INTO WKSP_SINDICATTO.IMAP_BOT_FUNCTION_CATALOG t
USING (SELECT 'DEFAULT' catalog_key, 3 catalog_version FROM dual) s
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
  SELECT 'api_zip_test' function_name, 'Y' enabled,
         q'~Executa semanticamente o teste ZIP da API.~' description,
         2 default_reasoning_level FROM dual UNION ALL
  SELECT 'project_zip_edit', 'Y',
         q'~Seleciona um ZIP de projeto e permite modificar, revisar, analisar, explicar, resumir ou investigar seu conteúdo.~',
         2 FROM dual UNION ALL
  SELECT 'function_catalog_admin', 'Y',
         q'~Lista o catálogo de funções ou sincroniza a camada de aplicação recarregando as definições e autorizações do Oracle.~',
         1 FROM dual
) s
ON (t.function_name = s.function_name)
WHEN MATCHED THEN UPDATE SET
  t.enabled = s.enabled,
  t.description = s.description,
  t.default_reasoning_level = s.default_reasoning_level,
  t.updated_at = SYSTIMESTAMP
WHEN NOT MATCHED THEN INSERT (
  function_name, enabled, description, default_reasoning_level
) VALUES (
  s.function_name, s.enabled, s.description, s.default_reasoning_level
);

MERGE INTO WKSP_SINDICATTO.IMAP_BOT_FUNCTION_REASONING t
USING (
  SELECT f.function_name, l.level_id
  FROM (
    SELECT 'api_zip_test' function_name FROM dual UNION ALL
    SELECT 'project_zip_edit' FROM dual UNION ALL
    SELECT 'function_catalog_admin' FROM dual
  ) f
  CROSS JOIN (
    SELECT 0 level_id FROM dual UNION ALL
    SELECT 1 FROM dual UNION ALL
    SELECT 2 FROM dual UNION ALL
    SELECT 3 FROM dual UNION ALL
    SELECT 4 FROM dual UNION ALL
    SELECT 5 FROM dual
  ) l
) s
ON (t.function_name = s.function_name AND t.level_id = s.level_id)
WHEN MATCHED THEN UPDATE SET t.enabled = 'Y', t.updated_at = SYSTIMESTAMP
WHEN NOT MATCHED THEN INSERT (function_name, level_id, enabled)
VALUES (s.function_name, s.level_id, 'Y');

MERGE INTO WKSP_SINDICATTO.IMAP_BOT_FUNCTION_PARAMETERS t
USING (
  SELECT 'api_zip_test' function_name, 'reasoning_level' parameter_name, 'integer' data_type,
         'Y' required,
         q'~Nível solicitado: 0=none, 1=low, 2=medium, 3=high, 4=xhigh, 5=max.~' description,
         'FUNCTION_REASONING_LEVELS' option_source, 10 sort_order FROM dual UNION ALL
  SELECT 'api_zip_test', 'request_text', 'string', 'Y',
         q'~Pergunta ou instrução que deve ser respondida dentro do teste ZIP.~',
         'NONE', 20 FROM dual UNION ALL

  SELECT 'project_zip_edit', 'reasoning_level', 'integer', 'Y',
         q'~Nível solicitado: 0=none, 1=low, 2=medium, 3=high, 4=xhigh, 5=max.~',
         'FUNCTION_REASONING_LEVELS', 10 FROM dual UNION ALL
  SELECT 'project_zip_edit', 'request_text', 'string', 'Y',
         q'~Pedido original sobre o projeto, preservando o sentido e os detalhes do remetente.~',
         'NONE', 20 FROM dual UNION ALL
  SELECT 'project_zip_edit', 'operation', 'string', 'Y',
         q'~modify altera o ZIP; query apenas analisa, explica ou responde.~',
         'STATIC', 30 FROM dual UNION ALL

  SELECT 'function_catalog_admin', 'operation', 'string', 'Y',
         q'~list consulta o catálogo carregado; sync recarrega o catálogo a partir do Oracle.~',
         'STATIC', 10 FROM dual UNION ALL
  SELECT 'function_catalog_admin', 'reasoning_level', 'integer', 'N',
         q'~Nível de raciocínio solicitado para a operação.~',
         'FUNCTION_REASONING_LEVELS', 20 FROM dual UNION ALL
  SELECT 'function_catalog_admin', 'request_text', 'string', 'N',
         q'~Contexto opcional do pedido de administração do catálogo.~',
         'NONE', 30 FROM dual
) s
ON (t.function_name = s.function_name AND t.parameter_name = s.parameter_name)
WHEN MATCHED THEN UPDATE SET
  t.data_type = s.data_type,
  t.required = s.required,
  t.description = s.description,
  t.option_source = s.option_source,
  t.sort_order = s.sort_order,
  t.enabled = 'Y',
  t.updated_at = SYSTIMESTAMP
WHEN NOT MATCHED THEN INSERT (
  function_name, parameter_name, data_type, required, description,
  option_source, sort_order, enabled
) VALUES (
  s.function_name, s.parameter_name, s.data_type, s.required, s.description,
  s.option_source, s.sort_order, 'Y'
);

MERGE INTO WKSP_SINDICATTO.IMAP_BOT_FUNCTION_PARAM_OPTIONS t
USING (
  SELECT 'project_zip_edit' function_name, 'operation' parameter_name, 'modify' option_value, 10 sort_order FROM dual UNION ALL
  SELECT 'project_zip_edit', 'operation', 'query', 20 FROM dual UNION ALL
  SELECT 'function_catalog_admin', 'operation', 'list', 10 FROM dual UNION ALL
  SELECT 'function_catalog_admin', 'operation', 'sync', 20 FROM dual
) s
ON (
  t.function_name = s.function_name
  AND t.parameter_name = s.parameter_name
  AND t.option_value = s.option_value
)
WHEN MATCHED THEN UPDATE SET
  t.sort_order = s.sort_order,
  t.enabled = 'Y',
  t.updated_at = SYSTIMESTAMP
WHEN NOT MATCHED THEN INSERT (
  function_name, parameter_name, option_value, sort_order, enabled
) VALUES (
  s.function_name, s.parameter_name, s.option_value, s.sort_order, 'Y'
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
