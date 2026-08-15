#!/usr/bin/env bash
# Contexto: merge .external e materialização de configs protegidas

merge_import_external_configs() {
  local project_dir="$1"
  local source_root="$2"
  local result

  if ! result="$(python3 - "$project_dir" "$source_root" <<'PY_EXTERNAL_MERGE'
import os
import re
import stat
import sys
from pathlib import Path

project_root = Path(sys.argv[1])
source_root = Path(sys.argv[2])
placeholder = "********"
assignment = re.compile(
    r"^(?P<prefix>\s*(?:export\s+)?(?P<key>[A-Za-z_][A-Za-z0-9_.-]*)\s*=\s*)(?P<value>.*?)(?P<ending>\r?\n?)$"
)
url_password = re.compile(
    r"(?P<prefix>\b[A-Za-z][A-Za-z0-9+.-]*://[^\s:/@]+:)(?P<password>[^\s@]*)(?P<suffix>@)"
)


def protected(rel: str) -> bool:
    parts = rel.split("/")
    for i in range(len(parts) - 2):
        if parts[i] == "config" and parts[i + 1] in {"local", "remote", "production"}:
            return True
    return False


def target_rel_for_external(rel: str) -> str:
    while rel.endswith(".external"):
        rel = rel[: -len(".external")]
    return rel


def decode_text(path: Path) -> str:
    raw = path.read_bytes()
    if b"\x00" in raw:
        raise ValueError(f"arquivo binário não pode ser reconciliado: {path}")
    try:
        return raw.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise ValueError(f"arquivo não UTF-8 não pode ser reconciliado: {path}") from exc


def assignments(text: str):
    values = {}
    for line in text.splitlines(keepends=True):
        m = assignment.match(line)
        if m:
            values[m.group("key")] = m.group("value")
    return values


def local_url_password(value: str):
    m = url_password.search(value)
    return m.group("password") if m else None


def merge_value(incoming: str, local: str, key: str) -> str:
    if placeholder not in incoming:
        return incoming

    # Caso normal de segredo inteiro mascarado (com ou sem aspas): mantenha o
    # valor local completo, inclusive quoting/comentário inline do valor.
    core = incoming.strip()
    unquoted = core
    if len(core) >= 2 and core[0] == core[-1] and core[0] in {"'", '"'}:
        unquoted = core[1:-1]
    if unquoted == placeholder:
        return local

    # URLs podem ter apenas a senha mascarada. Nesse caso preservamos somente
    # a senha local e aceitamos host/path/query novos vindos no ZIP.
    if f":{placeholder}@" in incoming:
        password = local_url_password(local)
        if password is not None:
            merged = incoming.replace(f":{placeholder}@", f":{password}@")
            if placeholder not in merged:
                return merged

    # Qualquer outra forma mascarada é conservadora: se há valor local para a
    # mesma chave, preserva-o inteiro para nunca substituir segredo por *****.
    if local is not None:
        return local

    raise ValueError(f"segredo mascarado sem valor local para a chave {key}")


merged_count = 0
unpaired_count = 0
externals = sorted(
    (p for p in source_root.rglob("*") if p.is_file() and p.name.endswith(".external")),
    key=lambda p: str(p),
)

for external in externals:
    rel = external.relative_to(source_root).as_posix()
    target_rel = target_rel_for_external(rel)

    # Só reconciliamos os .external que pertencem ao contrato de config
    # protegido. Outros .external legítimos continuam intocados.
    if not protected(target_rel):
        continue

    if not target_rel or target_rel.startswith("/") or ".." in Path(target_rel).parts:
        raise ValueError(f"caminho .external inválido: {rel}")

    staged_target = source_root / target_rel
    local_target = project_root / target_rel

    if staged_target.exists() or staged_target.is_symlink():
        raise ValueError(f"ZIP contém config normal e .external para o mesmo alvo: {target_rel}")

    incoming_text = decode_text(external)
    mode = stat.S_IMODE(external.stat().st_mode)

    if local_target.exists() and local_target.is_file():
        local_text = decode_text(local_target)
        local_values = assignments(local_text)
        output = []

        for line in incoming_text.splitlines(keepends=True):
            m = assignment.match(line)
            if not m:
                if placeholder in line:
                    raise ValueError(
                        f"placeholder fora de KEY=VALUE em {rel}; merge automático recusado"
                    )
                output.append(line)
                continue

            key = m.group("key")
            incoming_value = m.group("value")
            if placeholder in incoming_value:
                if key not in local_values:
                    raise ValueError(
                        f"segredo mascarado sem correspondente local: {target_rel}:{key}"
                    )
                value = merge_value(incoming_value, local_values[key], key)
            else:
                value = incoming_value
            output.append(f"{m.group('prefix')}{value}{m.group('ending')}")

        # Merge real, não substituição cega: o arquivo local é também a
        # fonte de chaves que não vieram no .external. Isso evita perder
        # segredos/configs locais quando o ZIP traz apenas um subconjunto.
        incoming_keys = set()
        for line in incoming_text.splitlines(keepends=True):
            m = assignment.match(line)
            if m:
                incoming_keys.add(m.group("key"))

        local_only = []
        for line in local_text.splitlines(keepends=True):
            m = assignment.match(line)
            if m and m.group("key") not in incoming_keys:
                local_only.append(line)

        if local_only:
            if output and output[-1] and not output[-1].endswith(("\n", "\r")):
                output[-1] += "\n"
            output.extend(local_only)

        merged_text = "".join(output)
        if placeholder in merged_text:
            raise ValueError(f"placeholder de segredo permaneceu após merge: {target_rel}")
        merged_count += 1
    else:
        # Sem o par real não existe segredo local para recuperar. Mantém o
        # .external como pendência explícita em vez de adivinhar ou bloquear
        # todo o ZIP. Ele será copiado normalmente e poderá ser resolvido depois.
        unpaired_count += 1
        continue

    staged_target.parent.mkdir(parents=True, exist_ok=True)
    tmp = staged_target.with_name(staged_target.name + f".merge-tmp-{os.getpid()}")
    tmp.write_text(merged_text, encoding="utf-8", newline="")
    os.chmod(tmp, mode)
    os.replace(tmp, staged_target)
    external.unlink()

print(f"{merged_count}:{unpaired_count}")
PY_EXTERNAL_MERGE
)"; then
    log "ERRO: falha ao reconciliar configs .external; importação cancelada antes do rsync."
    return 1
  fi

  local merged="${result%%:*}"
  local unpaired="${result##*:}"
  if [ "${merged:-0}" -gt 0 ] || [ "${unpaired:-0}" -gt 0 ]; then
    log "ENV EXTERNAL RECONCILIADO: ${merged:-0} merge(s) com segredo local preservado; ${unpaired:-0} sem par mantido(s) como .external."
  fi

  return 0
}

materialize_changed_protected_configs() {
  local project="$1"
  local source_root="$2"
  local filtered_root="$3"
  local baseline_dir rel baseline_rel baseline external_rel external changed=0 unchanged=0

  baseline_dir="$(protected_config_baseline_dir "$project")"

  while IFS= read -r -d '' rel; do
    protected_config_relpath "$rel" || continue

    external_rel="$(canonical_external_relpath "$rel")"
    baseline_rel="$rel"
    if [[ "$rel" == *.external ]]; then
      baseline_rel="$external_rel"
    fi
    baseline="$baseline_dir/$baseline_rel"

    if [ -f "$baseline" ] && cmp -s -- "$source_root/$rel" "$baseline"; then
      unchanged=$((unchanged + 1))
      continue
    fi

    external="$filtered_root/$external_rel"
    mkdir -p -- "$(dirname -- "$external")"
    cp -p -- "$source_root/$rel" "$external"
    changed=$((changed + 1))
    log "ENV EXTERNAL: $rel -> $external_rel"
  done < <(find "$source_root" -type f -printf '%P\0')

  log "ENV protegidos: $changed alterado(s)/novo(s), $unchanged sem mudança."
}

