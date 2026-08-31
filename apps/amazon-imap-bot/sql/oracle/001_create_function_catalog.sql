-- Amazon IMAP Bot - catálogo de funções no Oracle
-- Execução MANUAL. O aplicativo não executa DDL/DML automaticamente.
-- Patch idempotente para o schema WKSP_SINDICATTO.

BEGIN
  EXECUTE IMMEDIATE q'[
    CREATE TABLE WKSP_SINDICATTO.IMAP_BOT_FUNCTION_CATALOG (
      catalog_key       VARCHAR2(30) PRIMARY KEY,
      catalog_version   NUMBER(10) NOT NULL,
      updated_at        TIMESTAMP DEFAULT SYSTIMESTAMP NOT NULL
    )
  ]';
EXCEPTION
  WHEN OTHERS THEN
    IF SQLCODE != -955 THEN RAISE; END IF;
END;
/

BEGIN
  EXECUTE IMMEDIATE q'[
    CREATE TABLE WKSP_SINDICATTO.IMAP_BOT_REASONING_LEVELS (
      level_id      NUMBER(1) PRIMARY KEY,
      effort_name   VARCHAR2(20) NOT NULL UNIQUE,
      enabled       CHAR(1) DEFAULT 'Y' NOT NULL,
      CONSTRAINT CK_IMAP_BOT_REASON_ENABLED CHECK (enabled IN ('Y','N'))
    )
  ]';
EXCEPTION
  WHEN OTHERS THEN
    IF SQLCODE != -955 THEN RAISE; END IF;
END;
/

BEGIN
  EXECUTE IMMEDIATE q'[
    CREATE TABLE WKSP_SINDICATTO.IMAP_BOT_FUNCTIONS (
      function_name                    VARCHAR2(100) PRIMARY KEY,
      enabled                          CHAR(1) DEFAULT 'Y' NOT NULL,
      description                      VARCHAR2(2000) NOT NULL,
      default_reasoning_level          NUMBER(1) NOT NULL,
      allowed_reasoning_levels_json    CLOB NOT NULL,
      parameters_json                  CLOB NOT NULL,
      updated_at                       TIMESTAMP DEFAULT SYSTIMESTAMP NOT NULL,
      CONSTRAINT CK_IMAP_BOT_FUNC_ENABLED CHECK (enabled IN ('Y','N')),
      CONSTRAINT CK_IMAP_BOT_FUNC_LEVEL CHECK (default_reasoning_level BETWEEN 0 AND 5),
      CONSTRAINT CK_IMAP_BOT_FUNC_ALLOWED_JSON CHECK (allowed_reasoning_levels_json IS JSON),
      CONSTRAINT CK_IMAP_BOT_FUNC_PARAMS_JSON CHECK (parameters_json IS JSON)
    )
  ]';
EXCEPTION
  WHEN OTHERS THEN
    IF SQLCODE != -955 THEN RAISE; END IF;
END;
/

BEGIN
  EXECUTE IMMEDIATE q'[
    CREATE TABLE WKSP_SINDICATTO.IMAP_BOT_FUNCTION_SENDERS (
      sender_email    VARCHAR2(320) PRIMARY KEY,
      enabled         CHAR(1) DEFAULT 'Y' NOT NULL,
      updated_at      TIMESTAMP DEFAULT SYSTIMESTAMP NOT NULL,
      CONSTRAINT CK_IMAP_BOT_SENDER_ENABLED CHECK (enabled IN ('Y','N'))
    )
  ]';
EXCEPTION
  WHEN OTHERS THEN
    IF SQLCODE != -955 THEN RAISE; END IF;
END;
/

BEGIN
  EXECUTE IMMEDIATE q'[
    CREATE TABLE WKSP_SINDICATTO.IMAP_BOT_SENDER_FUNCTIONS (
      sender_email    VARCHAR2(320) NOT NULL,
      function_name   VARCHAR2(100) NOT NULL,
      enabled         CHAR(1) DEFAULT 'Y' NOT NULL,
      updated_at      TIMESTAMP DEFAULT SYSTIMESTAMP NOT NULL,
      CONSTRAINT PK_IMAP_BOT_SENDER_FUNCTION PRIMARY KEY (sender_email, function_name),
      CONSTRAINT FK_IMAP_BOT_SF_SENDER FOREIGN KEY (sender_email)
        REFERENCES WKSP_SINDICATTO.IMAP_BOT_FUNCTION_SENDERS(sender_email),
      CONSTRAINT FK_IMAP_BOT_SF_FUNCTION FOREIGN KEY (function_name)
        REFERENCES WKSP_SINDICATTO.IMAP_BOT_FUNCTIONS(function_name),
      CONSTRAINT CK_IMAP_BOT_SF_ENABLED CHECK (enabled IN ('Y','N'))
    )
  ]';
EXCEPTION
  WHEN OTHERS THEN
    IF SQLCODE != -955 THEN RAISE; END IF;
END;
/
