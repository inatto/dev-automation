from __future__ import annotations

import json
import re
import time
from pathlib import Path
from typing import Callable, Protocol


class FunctionCatalogSource(Protocol):
    source_name: str

    def load(self) -> dict:
        ...


class JsonFunctionCatalog:
    """Fonte legada explícita para rollback/importação; não é usada pelo runtime normal."""

    def __init__(self, path: Path):
        self.path = Path(path)
        self.source_name = f"JSON legado: {self.path}"

    def load(self) -> dict:
        if not self.path.is_file():
            return {"version": 1, "reasoning_levels": {}, "senders": {}, "functions": {}}
        try:
            payload = json.loads(self.path.read_text(encoding="utf-8"))
        except json.JSONDecodeError as exc:
            raise RuntimeError(f"JSON inválido em {self.path}") from exc
        if not isinstance(payload, dict):
            raise RuntimeError(f"configuração de funções inválida em {self.path}")
        return payload


class OracleFunctionCatalog:
    """Repositório Oracle somente-leitura usado pela camada de aplicação do bot."""

    _IDENTIFIER = re.compile(r"^[A-Za-z][A-Za-z0-9_$#]*$")

    def __init__(self, database, log: Callable[[str], None] | None = None):
        self.database = database
        self.log = log or (lambda text: None)
        schema = str(database.schema or "").strip().upper()
        if not self._IDENTIFIER.fullmatch(schema):
            raise RuntimeError("DB_SCHEMA inválido em database.env")
        self.schema = schema
        self.source_name = f"Oracle: {schema}"

    @staticmethod
    def _dsn(jdbc_url: str) -> str:
        value = str(jdbc_url or "").strip()
        prefix = "jdbc:oracle:thin:@"
        if value.lower().startswith(prefix):
            value = value[len(prefix):]
        if not value:
            raise RuntimeError("DB_JDBC_URL ausente em database.env")
        return value

    @staticmethod
    def _text(value) -> str:
        if value is None:
            return ""
        reader = getattr(value, "read", None)
        return str(reader() if callable(reader) else value)

    @staticmethod
    def _cast_option_value(value, data_type: str):
        raw = str(value if value is not None else "")
        kind = str(data_type or "").strip().lower()
        if kind == "integer":
            return int(raw)
        if kind == "number":
            return float(raw)
        if kind == "boolean":
            normalized = raw.strip().lower()
            if normalized in {"1", "true", "y", "yes"}:
                return True
            if normalized in {"0", "false", "n", "no"}:
                return False
            raise RuntimeError(f"opção booleana inválida no catálogo Oracle: {raw}")
        return raw

    @staticmethod
    def _value(value) -> str:
        if isinstance(value, (list, tuple)):
            return ",".join(str(item) for item in value)
        return str(value or "-")

    @staticmethod
    def _connect_diagnosis(exc: Exception) -> str:
        text = str(exc)
        upper = text.upper()
        if "ORA-12506" in upper or ("DPY-6000" in upper and "12506" in upper):
            return (
                "listener Oracle alcançado, mas recusou a conexão; confira wallet/mTLS, alias TNS "
                "e, se necessário, a Service ACL do banco"
            )
        if "DPY-6005" in upper:
            return "falha de conexão com o banco; confira o detalhe Oracle/DPY exibido acima"
        return ""

    def _connect(self):
        if str(self.database.db_type or "").strip().lower() != "oracle":
            raise RuntimeError("DB_TYPE deve ser oracle em database.env")
        if not str(self.database.user or "").strip():
            raise RuntimeError("DB_USER ausente em database.env")
        if not str(self.database.password or ""):
            raise RuntimeError("DB_PASSWORD ausente em database.env")
        try:
            import oracledb
        except ImportError as exc:
            raise RuntimeError("dependência oracledb não instalada") from exc

        dsn = self._dsn(self.database.jdbc_url)
        config_dir = str(self.database.tns_admin) if self.database.tns_admin else None
        self.log(
            "Oracle: configuração "
            f"arquivo={self.database.env_path} user={self.database.user} schema={self.schema} "
            f"dsn={dsn} tns_admin={config_dir or '-'} senha={'OK' if self.database.password else 'AUSENTE'}"
        )
        if self.database.tns_admin:
            if not self.database.tns_admin.is_dir():
                raise RuntimeError(f"DB_TNS_ADMIN não existe: {self.database.tns_admin}")
            tnsnames = self.database.tns_admin / "tnsnames.ora"
            self.log(f"Oracle: tnsnames.ora={'OK' if tnsnames.is_file() else 'AUSENTE'} em {tnsnames}")
            if not tnsnames.is_file():
                raise RuntimeError(f"tnsnames.ora ausente em DB_TNS_ADMIN: {tnsnames}")
            wallet_files = [
                name for name in ("ewallet.pem", "cwallet.sso", "ewallet.p12", "sqlnet.ora")
                if (self.database.tns_admin / name).is_file()
            ]
            self.log(
                "Oracle: wallet=" + (", ".join(wallet_files) if wallet_files else "nenhum arquivo reconhecido")
            )
            if not any(name in wallet_files for name in ("ewallet.pem", "cwallet.sso", "ewallet.p12")):
                raise RuntimeError(
                    f"wallet Oracle ausente/incompleta em DB_TNS_ADMIN: {self.database.tns_admin}"
                )
            pem_path = self.database.tns_admin / "ewallet.pem"
            try:
                encrypted_pem = (
                    pem_path.is_file()
                    and "ENCRYPTED PRIVATE KEY" in pem_path.read_text(encoding="utf-8", errors="ignore")
                )
            except OSError:
                encrypted_pem = False
            if encrypted_pem and not str(self.database.wallet_password or "").strip():
                raise RuntimeError(
                    "ewallet.pem usa chave privada criptografada; configure DB_WALLET_PASSWORD "
                    "em database.env (mesma senha da wallet usada pelo Orbital App)"
                )

        params = oracledb.ConnectParams(
            user=self.database.user,
            password=self.database.password,
            config_dir=config_dir,
        )
        self.log(f"Oracle: resolvendo DSN {dsn}...")
        try:
            params.parse_connect_string(dsn)
        except Exception as exc:
            raise RuntimeError(f"não foi possível resolver DB_JDBC_URL/DSN {dsn}: {exc}") from exc

        descriptor_retry_count = getattr(params, "retry_count", None)
        descriptor_retry_delay = getattr(params, "retry_delay", None)
        self.log(
            "Oracle: DSN resolvido "
            f"protocol={self._value(getattr(params, 'protocol', None))} "
            f"host={self._value(getattr(params, 'host', None))} "
            f"port={self._value(getattr(params, 'port', None))} "
            f"service={self._value(getattr(params, 'service_name', None))} "
            f"retry_descriptor={self._value(descriptor_retry_count)}x/{self._value(descriptor_retry_delay)}s"
        )

        # Mesmo padrão já usado pelo Orbital App: config_dir resolve o alias TNS e
        # wallet_location faz o python-oracledb Thin carregar a wallet/mTLS.
        connect_arguments = {
            "user": self.database.user,
            "password": self.database.password,
            "dsn": dsn,
            "tcp_connect_timeout": float(self.database.connect_timeout_seconds),
            "retry_count": int(self.database.retry_count),
            "retry_delay": int(self.database.retry_delay_seconds),
        }
        if config_dir:
            connect_arguments["config_dir"] = config_dir
            connect_arguments["wallet_location"] = config_dir
        if str(self.database.wallet_password or "").strip():
            connect_arguments["wallet_password"] = self.database.wallet_password

        self.log(
            "Oracle: conectando "
            f"timeout_tcp={self.database.connect_timeout_seconds:g}s "
            f"retries={self.database.retry_count} delay={self.database.retry_delay_seconds}s "
            f"wallet_location={'OK' if config_dir else 'AUSENTE'} "
            f"wallet_password={'OK' if self.database.wallet_password else 'não configurada'}..."
        )
        started = time.monotonic()
        try:
            connection = oracledb.connect(**connect_arguments)
        except Exception as exc:
            elapsed = time.monotonic() - started
            diagnosis = self._connect_diagnosis(exc)
            self.log(f"Oracle: FALHA após {elapsed:.2f}s: {exc}")
            if diagnosis:
                self.log(f"Oracle: diagnóstico: {diagnosis}.")
                raise RuntimeError(f"{exc}\nDiagnóstico: {diagnosis}.") from exc
            raise
        self.log(f"Oracle: conexão aberta em {time.monotonic() - started:.2f}s.")
        return connection

    def load(self) -> dict:
        started = time.monotonic()
        connection = self._connect()
        cursor = connection.cursor()
        try:
            self.log("Oracle: lendo versão do catálogo DEFAULT...")
            cursor.execute(
                f"SELECT catalog_version FROM {self.schema}.IMAP_BOT_FUNCTION_CATALOG "
                "WHERE catalog_key = 'DEFAULT'"
            )
            row = cursor.fetchone()
            if row is None:
                raise RuntimeError("catálogo DEFAULT não encontrado no Oracle")
            version = int(row[0])

            self.log("Oracle: lendo níveis de raciocínio...")
            cursor.execute(
                f"SELECT level_id, effort_name FROM {self.schema}.IMAP_BOT_REASONING_LEVELS "
                "WHERE enabled = 'Y' ORDER BY level_id"
            )
            levels = {str(int(level)): str(name) for level, name in cursor.fetchall()}

            self.log("Oracle: lendo funções...")
            cursor.execute(
                f"SELECT function_name, enabled, description, default_reasoning_level "
                f"FROM {self.schema}.IMAP_BOT_FUNCTIONS ORDER BY function_name"
            )
            functions: dict[str, dict] = {}
            for name, enabled, description, default_level in cursor.fetchall():
                function_name = str(name)
                functions[function_name] = {
                    "enabled": str(enabled).upper() == "Y",
                    "description": str(description or ""),
                    "default_reasoning_level": int(default_level),
                    "allowed_reasoning_levels": [],
                    "parameters": {
                        "type": "object",
                        "properties": {},
                        "required": [],
                        "additionalProperties": False,
                    },
                }

            self.log("Oracle: lendo níveis permitidos por função...")
            cursor.execute(
                f"SELECT function_name, level_id FROM {self.schema}.IMAP_BOT_FUNCTION_REASONING "
                "WHERE enabled = 'Y' ORDER BY function_name, level_id"
            )
            for function_name, level_id in cursor.fetchall():
                name = str(function_name)
                if name not in functions:
                    raise RuntimeError(f"nível configurado para função inexistente no Oracle: {name}")
                functions[name]["allowed_reasoning_levels"].append(int(level_id))

            parameter_meta: dict[tuple[str, str], tuple[dict, str, str]] = {}
            self.log("Oracle: lendo parâmetros relacionais das funções...")
            cursor.execute(
                f"SELECT function_name, parameter_name, data_type, required, description, option_source "
                f"FROM {self.schema}.IMAP_BOT_FUNCTION_PARAMETERS "
                "WHERE enabled = 'Y' ORDER BY function_name, sort_order, parameter_name"
            )
            parameter_count = 0
            for function_name, parameter_name, data_type, required, description, option_source in cursor.fetchall():
                name = str(function_name)
                param_name = str(parameter_name)
                if name not in functions:
                    raise RuntimeError(f"parâmetro configurado para função inexistente no Oracle: {name}.{param_name}")

                kind = str(data_type or "").strip().lower()
                source = str(option_source or "NONE").strip().upper()
                prop = {"type": kind}
                if description:
                    prop["description"] = str(description)

                if source == "FUNCTION_REASONING_LEVELS":
                    prop["enum"] = list(functions[name]["allowed_reasoning_levels"])
                elif source not in {"NONE", "STATIC"}:
                    raise RuntimeError(
                        f"option_source inválido para {name}.{param_name}: {source}"
                    )

                schema = functions[name]["parameters"]
                schema["properties"][param_name] = prop
                if str(required).upper() == "Y":
                    schema["required"].append(param_name)
                parameter_meta[(name, param_name)] = (prop, kind, source)
                parameter_count += 1

            self.log("Oracle: lendo opções relacionais dos parâmetros...")
            cursor.execute(
                f"SELECT function_name, parameter_name, option_value "
                f"FROM {self.schema}.IMAP_BOT_FUNCTION_PARAM_OPTIONS "
                "WHERE enabled = 'Y' ORDER BY function_name, parameter_name, sort_order, option_value"
            )
            option_count = 0
            for function_name, parameter_name, option_value in cursor.fetchall():
                key = (str(function_name), str(parameter_name))
                meta = parameter_meta.get(key)
                if meta is None:
                    raise RuntimeError(
                        f"opção configurada para parâmetro inexistente no Oracle: {key[0]}.{key[1]}"
                    )
                prop, kind, source = meta
                if source != "STATIC":
                    raise RuntimeError(
                        f"opção estática configurada para parâmetro sem option_source=STATIC: {key[0]}.{key[1]}"
                    )
                prop.setdefault("enum", []).append(self._cast_option_value(option_value, kind))
                option_count += 1

            for name, entry in functions.items():
                allowed = entry["allowed_reasoning_levels"]
                default_level = entry["default_reasoning_level"]
                if not allowed:
                    raise RuntimeError(f"função {name} não possui níveis de raciocínio permitidos no Oracle")
                if default_level not in allowed:
                    raise RuntimeError(
                        f"nível padrão {default_level} da função {name} não está entre os níveis permitidos"
                    )
                for param_name, prop in entry["parameters"]["properties"].items():
                    meta = parameter_meta[(name, param_name)]
                    if meta[2] == "STATIC" and not prop.get("enum"):
                        raise RuntimeError(
                            f"parâmetro {name}.{param_name} usa opções estáticas mas não possui opções ativas"
                        )

            self.log("Oracle: lendo remetentes autorizados...")
            cursor.execute(
                f"SELECT sender_email, enabled FROM {self.schema}.IMAP_BOT_FUNCTION_SENDERS "
                "ORDER BY sender_email"
            )
            senders = {
                str(email).strip().lower(): {"enabled": str(enabled).upper() == "Y", "functions": []}
                for email, enabled in cursor.fetchall()
            }
            self.log("Oracle: lendo vínculos remetente x função...")
            cursor.execute(
                f"SELECT sender_email, function_name FROM {self.schema}.IMAP_BOT_SENDER_FUNCTIONS "
                "WHERE enabled = 'Y' ORDER BY sender_email, function_name"
            )
            for email, function_name in cursor.fetchall():
                key = str(email).strip().lower()
                senders.setdefault(key, {"enabled": True, "functions": []})
                senders[key]["functions"].append(str(function_name))

            self.log(
                f"Oracle: catálogo carregado em {time.monotonic() - started:.2f}s "
                f"(versão={version}, níveis={len(levels)}, funções={len(functions)}, "
                f"parâmetros={parameter_count}, opções={option_count}, remetentes={len(senders)})."
            )
            return {
                "version": version,
                "reasoning_levels": levels,
                "senders": senders,
                "functions": functions,
                "source": "oracle",
            }
        finally:
            try:
                cursor.close()
            finally:
                connection.close()

