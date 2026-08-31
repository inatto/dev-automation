#!/usr/bin/env bash
# Contexto: merge seguro de configs sanitizadas recebidas do chat.
# Regra: quando já existe segredo local, ele sempre vence o valor recebido no ZIP.
# Quando não existe correspondente local, o ZIP é aplicado com AVISO em vez de abortar
# a importação (inclusive valor vazio/placeholder), permitindo bootstrap em máquina nova.
# Nenhum .external é persistido no projeto.

materialize_changed_protected_configs() {
  local project="$1"
  local source_root="$2"
  local filtered_root="$3"
  local destination_root="${4:-}"
  local allow_parent_config="${5:-false}"
  local project_dir baseline_dir rel baseline destination local_target result changed=0 unchanged=0 redacted=0 isolated=0

  project_dir="${destination_root:-$(project_path "$project")}"
  baseline_dir="$(protected_config_baseline_dir "$project")"

  while IFS= read -r -d '' rel; do
    protected_config_relpath "$rel" || continue

    # No ZIP de um subprojeto, .config/<filho>/ fica fora de apps/<filho>/.
    # A importação principal nunca pode mapeá-la para <filho>/.config; ela é
    # tratada separadamente contra a raiz do projeto-pai.
    if [ "$allow_parent_config" != "true" ] && declare -F project_relpath_is_parent_config >/dev/null 2>&1 && project_relpath_is_parent_config "$project" "$rel"; then
      isolated=$((isolated + 1))
      continue
    fi

    if project_relpath_belongs_to_registered_subproject "$project" "$rel"; then
      isolated=$((isolated + 1))
      continue
    fi

    local_target="$project_dir/$rel"
    baseline="$baseline_dir/$rel"
    # Se o arquivo local sumiu, a baseline não pode fazê-lo desaparecer também:
    # materializa o recebido para permitir bootstrap/restauração da estrutura.
    if [ -e "$local_target" ] && [ -f "$baseline" ] && cmp -s -- "$source_root/$rel" "$baseline"; then
      unchanged=$((unchanged + 1))
      continue
    fi

    # Formato protegido que não tem merge KEY=VALUE seguro nunca sobrescreve o
    # original. O ZIP mostra o arquivo como ******** só para conferência de estrutura.
    if ! mergeable_protected_config_relpath "$rel"; then
      redacted=$((redacted + 1))
      log "CONFIG PROTEGIDO PRESERVADO: $rel (formato não reconciliável automaticamente)"
      continue
    fi

    destination="$filtered_root/$rel"
    mkdir -p -- "$(dirname -- "$destination")"

    if ! result="$(python3 - "$source_root/$rel" "$local_target" "$destination" <<'PY_MERGE'
import json
import os
import re
import stat
import sys
from pathlib import Path

incoming_path = Path(sys.argv[1])
local_path = Path(sys.argv[2])
out_path = Path(sys.argv[3])
masked_token = re.compile(r"\*{3,}")
secret_key = re.compile(
    r"(?:^|_)(?:PASSWORD|PASSWD|PWD|SECRET|TOKEN|API_KEY|ADMIN_KEY|ACCESS_KEY|PRIVATE_KEY)(?:$|_)",
    re.IGNORECASE,
)
assignment = re.compile(
    r"^(?P<prefix>\s*(?:export\s+)?(?P<key>[A-Za-z_][A-Za-z0-9_.-]*)\s*=\s*)(?P<value>.*?)(?P<ending>\r?\n?)$"
)
url_password = re.compile(
    r"(?P<prefix>\b[A-Za-z][A-Za-z0-9+.-]*://[^\s:/@]+:)(?P<password>[^\s@]*)(?P<suffix>@)"
)


def decode(path: Path) -> str:
    raw = path.read_bytes()
    if b"\x00" in raw:
        raise ValueError(f"config binário não pode ser reconciliado: {path}")
    try:
        return raw.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise ValueError(f"config não UTF-8 não pode ser reconciliado: {path}") from exc


def values(text: str):
    out = {}
    for line in text.splitlines(keepends=True):
        m = assignment.match(line)
        if m:
            out[m.group("key")] = m.group("value")
    return out


def warn(message: str) -> None:
    print(f"AVISO CONFIG PROTEGIDO: {message}", file=sys.stderr)


def replace_url_password_with_local(incoming: str, local: str) -> str:
    inc = url_password.search(incoming)
    loc = url_password.search(local)
    if inc is None or loc is None:
        return incoming
    return incoming[:inc.start("password")] + loc.group("password") + incoming[inc.end("password"):]


incoming_text = decode(incoming_path)
mode = stat.S_IMODE(incoming_path.stat().st_mode)

if incoming_path.suffix.lower() == ".json":
    # Um JSON que não pôde ser sanitizado no backup é substituído integralmente
    # por ********. Na importação isso significa "preserve o arquivo local", não
    # "tente interpretar o placeholder como JSON".
    if masked_token.fullmatch(incoming_text.strip()):
        warn(f"{local_path}: JSON totalmente redigido no ZIP; preservando configuração local")
        print("preserved-redacted-json")
        raise SystemExit(0)

    try:
        incoming_json = json.loads(incoming_text)
    except json.JSONDecodeError as exc:
        raise ValueError(f"JSON protegido inválido: {incoming_path}: {exc}") from exc

    if not local_path.exists():
        if masked_token.search(incoming_text):
            warn(f"{local_path}: placeholder JSON sem correspondente local; mantendo valor recebido")
            result = "new-warning"
        else:
            result = "new-safe"
        out_path.write_text(incoming_text, encoding="utf-8", newline="")
        os.chmod(out_path, mode)
        print(result)
        raise SystemExit(0)

    if not local_path.is_file():
        raise ValueError(f"alvo local não é arquivo regular: {local_path}")

    local_text = decode(local_path)
    try:
        local_json = json.loads(local_text)
    except json.JSONDecodeError as exc:
        raise ValueError(f"JSON local protegido inválido: {local_path}: {exc}") from exc

    missing = object()

    def contains_sensitive(value, key=None):
        if key is not None and secret_key.search(str(key)):
            return True
        if isinstance(value, dict):
            return any(contains_sensitive(v, k) for k, v in value.items())
        if isinstance(value, list):
            return any(contains_sensitive(v) for v in value)
        if isinstance(value, str):
            return bool(masked_token.search(value) or url_password.search(value))
        return False

    def merge_json(incoming, local=missing, key=None):
        if key is not None and secret_key.search(str(key)):
            if local is missing:
                warn(f"{local_path}:{key}: chave sensível JSON nova sem correspondente local; mantendo valor recebido")
                return incoming
            return local

        if isinstance(incoming, dict):
            local_dict = local if isinstance(local, dict) else {}
            merged = {
                k: merge_json(v, local_dict.get(k, missing), k)
                for k, v in incoming.items()
            }
            # Chaves locais ausentes no JSON recebido só são preservadas quando
            # contêm material sensível; campos comuns removidos pelo ZIP permanecem removidos.
            for k, v in local_dict.items():
                if k not in incoming and contains_sensitive(v, k):
                    merged[k] = v
            return merged

        if isinstance(incoming, list):
            local_list = local if isinstance(local, list) else []
            return [
                merge_json(v, local_list[i] if i < len(local_list) else missing)
                for i, v in enumerate(incoming)
            ]

        if isinstance(incoming, str):
            if masked_token.search(incoming):
                if local is missing:
                    warn(f"{local_path}: placeholder JSON sem correspondente local; mantendo valor recebido")
                    return incoming
                return local
            if url_password.search(incoming):
                if isinstance(local, str) and url_password.search(local):
                    return replace_url_password_with_local(incoming, local)
                if local is missing:
                    warn(f"{local_path}: URL JSON com credencial sem correspondente local; mantendo valor recebido")
            return incoming

        return incoming

    merged_json = merge_json(incoming_json, local_json)
    out_path.write_text(
        json.dumps(merged_json, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    os.chmod(out_path, mode)
    print("merged-json")
    raise SystemExit(0)

if not local_path.exists():
    # Bootstrap em máquina nova: não existe segredo local para preservar.
    # O arquivo recebido entra como veio e qualquer campo sensível gera apenas aviso.
    warned = False
    for line in incoming_text.splitlines(keepends=True):
        m = assignment.match(line)
        if not m:
            if masked_token.search(line):
                warn(f"{local_path}: placeholder sem correspondente local; mantendo valor recebido")
                warned = True
            continue
        key, value = m.group("key"), m.group("value")
        if secret_key.search(key) or masked_token.search(value) or url_password.search(value):
            warn(f"{local_path}:{key}: sem correspondente local; mantendo valor recebido")
            warned = True
    out_path.write_text(incoming_text, encoding="utf-8", newline="")
    os.chmod(out_path, mode)
    print("new-warning" if warned else "new-safe")
    raise SystemExit(0)

if not local_path.is_file():
    raise ValueError(f"alvo local não é arquivo regular: {local_path}")

local_text = decode(local_path)
local_values = values(local_text)
output = []
incoming_keys = set()

for line in incoming_text.splitlines(keepends=True):
    m = assignment.match(line)
    if not m:
        if masked_token.search(line):
            warn(f"{local_path}: placeholder fora de KEY=VALUE; mantendo linha recebida")
        output.append(line)
        continue

    key = m.group("key")
    incoming_keys.add(key)
    incoming_value = m.group("value")
    local_value = local_values.get(key)

    # Se já existe valor local sensível, ele continua vencendo. Se a chave é nova
    # nesta máquina, aceita o valor recebido e apenas alerta; isso é necessário para
    # bootstrap de configs/bancos ainda não existentes.
    if secret_key.search(key):
        if local_value is None:
            warn(f"{local_path}:{key}: chave sensível nova sem correspondente local; mantendo valor recebido")
            value = incoming_value
        else:
            value = local_value
    elif masked_token.search(incoming_value):
        if local_value is None:
            warn(f"{local_path}:{key}: placeholder sem correspondente local; mantendo valor recebido")
            value = incoming_value
        # URL mascarada: permite host/path/query novos, mas recupera a senha local.
        elif re.search(r":\*{3,}@", incoming_value):
            value = replace_url_password_with_local(incoming_value, local_value)
        else:
            value = local_value
    elif url_password.search(incoming_value):
        if local_value is None:
            warn(f"{local_path}:{key}: URL com credencial sem correspondente local; mantendo valor recebido")
            value = incoming_value
        else:
            # Mesmo que o ZIP traga uma senha real, ela é descartada e a senha local vence.
            value = replace_url_password_with_local(incoming_value, local_value)
    else:
        value = incoming_value

    output.append(f"{m.group('prefix')}{value}{m.group('ending')}")

# Chaves que existem somente no local são preservadas.
for line in local_text.splitlines(keepends=True):
    m = assignment.match(line)
    if m and m.group("key") not in incoming_keys:
        if output and output[-1] and not output[-1].endswith(("\n", "\r")):
            output[-1] += "\n"
        output.append(line)

merged_text = "".join(output)
if masked_token.search(merged_text):
    warn(f"{local_path}: placeholder permaneceu porque não havia valor local correspondente")

out_path.write_text(merged_text, encoding="utf-8", newline="")
os.chmod(out_path, mode)
print("merged")
PY_MERGE
)"; then
      log "ERRO: merge seguro de config protegido falhou: $rel"
      rm -f -- "$destination"
      return 1
    fi

    changed=$((changed + 1))
    log "CONFIG PROTEGIDO: $rel -> ${result:-merge concluído}"
  done < <(find "$source_root" -type f -printf '%P\0')

  log "Configs protegidos: $changed reconciliado(s), $unchanged sem mudança, $redacted preservado(s) sem merge, $isolated isolado(s) por pertencer a subprojeto; nenhum .external persistido."
  return 0
}
