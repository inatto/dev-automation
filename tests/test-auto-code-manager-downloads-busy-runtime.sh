#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
command -v inotifywait >/dev/null || { echo 'SKIP: inotifywait não instalado'; exit 0; }
python3 - "$ROOT" <<'PY'
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import zipfile

root = Path(sys.argv[1])
with tempfile.TemporaryDirectory(prefix='devauto-download-busy-') as temp:
    temp = Path(temp)
    manager = temp / 'manager'
    shutil.copytree(root, manager, symlinks=True)
    code = temp / 'Code'
    downloads = temp / 'Downloads'
    downloads.mkdir()
    projects = [f'orgs/alpha{i:02}' for i in range(21)]
    for project in projects:
        dest = code / project
        dest.mkdir(parents=True)
        (dest / 'value.txt').write_text('baseline\n')
    cfg = manager / 'config'
    catalog = cfg / 'projects' / 'default.projects'
    catalog.write_text('\n'.join(projects) + '\n')
    (cfg / 'auto-code-manager.ignore-zip').write_text('.git/\n.venv/\nvenv/\nnode_modules/\n*.log\n')
    (cfg / 'auto-code-manager.ignore-unzip').write_text('')
    (cfg / 'auto-code-manager.folder-sql-watch').write_text('')
    (cfg / 'auto-code-manager.folder-sql-zip').write_text('')
    (cfg / 'auto-code-manager.env').write_text(
        'BACKUP_EVERY=3600\nDOWNLOAD_SCAN_INTERVAL=1\nSTABLE_WAIT=1\n'
        'BEEP_MODE=none\nBEEP_REPEATS=1\nBEEP_GAP_MS=1\nBEEP_VOLUME=0\n'
        'BACKUP_BEEP_ENABLED=false\nTASKBAR_STATUS_ENABLED=false\nAUTO_CODE_MONITOR_MODE=inotify\n')
    env = os.environ.copy()
    env.update(HOME=str(temp / 'home'), CODE_ROOT=str(code), DOWNLOADS_DIR=str(downloads),
               DEV_MANAGER_PROJECTS_FILE=str(catalog), AUTO_CODE_STATE_DIR=str(temp / 'state'),
               AUTO_CODE_TUI='off')
    # Este teste exercita Linux nativo; WSL tem teste próprio.
    env.pop('WSL_INTEROP', None)
    env.pop('WSL_DISTRO_NAME', None)
    log_path = temp / 'monitor.log'

    def make_zip(path: Path, value: str) -> None:
        with zipfile.ZipFile(path, 'w') as archive:
            archive.writestr('value.txt', value + '\n')

    def wait_for(predicate, description: str, timeout: float = 20.0) -> None:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if predicate():
                return
            if proc.poll() is not None:
                break
            time.sleep(0.05)
        print(log_path.read_text(errors='replace'), file=sys.stderr)
        raise AssertionError(description)

    def log_has(text: str) -> bool:
        return text in log_path.read_text(errors='replace')

    with log_path.open('w') as log:
        proc = subprocess.Popen(['bash', str(manager / 'scripts/auto-code-manager.sh')],
                                env=env, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        try:
            wait_for(lambda: log_has('IDLE event-driven'), 'monitor não ficou pronto', 120)
            noise = code / projects[0] / 'noise'
            noise.mkdir()
            for i in range(1500):
                (noise / f'event-{i:04}.txt').write_text('event\n')

            old = downloads / 'alpha20--z-antigo.zip'
            new = downloads / 'alpha20--a-novo.zip'
            make_zip(temp / old.name, 'old')
            make_zip(temp / new.name, 'new')
            os.utime(temp / old.name, ns=(1700000000100000000, 1700000000100000000))
            os.utime(temp / new.name, ns=(1700000000900000000, 1700000000900000000))
            start = time.monotonic()
            os.replace(temp / old.name, old)
            os.replace(temp / new.name, new)
            target = code / projects[-1] / 'value.txt'
            wait_for(lambda: target.read_text() == 'new\n' and not new.exists() and not old.exists(),
                     'Downloads ficou atrás da fila de eventos / ordem invertida', 30)
            elapsed = time.monotonic() - start
            output = log_path.read_text(errors='replace')
            assert output.index(f'FILA DE DOWNLOADS [1]: {old.name}') < output.index(new.name)
            with zipfile.ZipFile(code / 'alpha20.zip') as archive:
                assert archive.read('value.txt') == b'old\n', 'backup pré-importação não preservou o estado anterior'

            # Corrupção bloqueia a cabeça sem apagar nem aplicar o ZIP mais novo.
            bad = downloads / 'alpha20--z-bad.zip'
            newer = downloads / 'alpha20--a-next.zip'
            (temp / bad.name).write_bytes(b'invalid archive\n')
            make_zip(temp / newer.name, 'newest')
            os.utime(temp / bad.name, (1700000020, 1700000020))
            os.utime(temp / newer.name, (1700000021, 1700000021))
            os.replace(temp / bad.name, bad)
            os.replace(temp / newer.name, newer)
            wait_for(lambda: log_has('FILA DE DOWNLOADS PAUSADA:'), 'erro não bloqueou a fila')
            assert target.read_text() == 'new\n' and bad.exists() and newer.exists()
            # Corrigir a cabeça muda o mtime, mas NÃO muda sua posição na fila.
            make_zip(temp / 'fixed.zip', 'corrected older')
            os.replace(temp / 'fixed.zip', bad)
            wait_for(lambda: target.read_text() == 'newest\n' and not newer.exists() and not bad.exists(),
                     'a cabeça corrigida perdeu a posição FIFO', 30)
            assert (code / projects[0] / 'value.txt').read_text() == 'baseline\n'
            print(f'OK: 21 projetos + 1.500 arquivos gerando eventos; 2 ZIPs importados em {elapsed:.2f}s; '
                  'ordem, backup, corrupção e recuperação FIFO confirmados com extração real')
        finally:
            try:
                os.killpg(proc.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                proc.wait(timeout=3)
            except subprocess.TimeoutExpired:
                os.killpg(proc.pid, signal.SIGKILL)
                proc.wait()
PY
