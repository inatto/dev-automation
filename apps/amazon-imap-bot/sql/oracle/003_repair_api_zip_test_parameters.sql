-- Amazon IMAP Bot - corrige apenas o JSON de parameters da função api_zip_test.
-- Execução MANUAL. Idempotente. Não é executado pelo bot automaticamente.

MERGE INTO WKSP_SINDICATTO.IMAP_BOT_FUNCTIONS t
USING (
  SELECT
    'api_zip_test' function_name,
    q'~{"type":"object","properties":{"reasoning_level":{"type":"integer","enum":[0,1,2,3,4,5],"description":"Nível solicitado: 0=none, 1=low, 2=medium, 3=high, 4=xhigh, 5=max."},"request_text":{"type":"string","description":"Pergunta ou instrução que deve ser respondida dentro do teste ZIP."}},"required":["reasoning_level","request_text"],"additionalProperties":false}~' parameters_json
  FROM dual
) s
ON (t.function_name = s.function_name)
WHEN MATCHED THEN UPDATE SET
  t.parameters_json = s.parameters_json,
  t.updated_at = SYSTIMESTAMP
WHEN NOT MATCHED THEN INSERT (
  function_name, enabled, description, default_reasoning_level,
  allowed_reasoning_levels_json, parameters_json
) VALUES (
  s.function_name,
  'Y',
  'Executa semanticamente o teste ZIP da API.',
  2,
  '[0,1,2,3,4,5]',
  s.parameters_json
);
