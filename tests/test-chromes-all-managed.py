#!/usr/bin/env python3
"""Integração dos scripts reais, com Chrome e protocolo GNOME simulados."""
from __future__ import annotations

import fcntl
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parent.parent


def check_case(name: str, counts: tuple[int, int, int, int], *, expect_ok: bool,
               expected_actions: list[str], register: bool = False,
               invalid: bool = False, wrong_protocol: bool = False,
               placement_fails: bool = False, locked: bool = False) -> None:
    with tempfile.TemporaryDirectory(prefix="chromes-all-managed-") as temp:
        base = Path(temp)
        home, binary, state = base / "home", base / "bin", base / "state" / "desktops"
        for folder in (home, binary, state):
            folder.mkdir(parents=True, exist_ok=True)
        (base / "projects").write_text("bots/dev-automation\norgs/orbital-app\n")
        (base / "services.csv").write_text(
            "application;type;web_port;api_port;host;path\norbital-app;base;4001;8001;admin.localhost;/\n")
        profile = home / ".config" / "google-chrome"
        profile.mkdir(parents=True)
        (profile / "Local State").write_text(
            '{"profile":{"info_cache":{"Default":{"name":"danielmaiax"},"Profile 3":{"name":"Sindicatto"}}}}')
        for item in ("Default", "Profile 3", "Profile 12"):
            (profile / item).mkdir()
        scripts = {
            "gnome-shell": "#!/bin/bash\nprintf 'GNOME Shell 50.1\\n'\n",
            "gnome-extensions": "#!/bin/bash\nprintf '  Version: 17\\n  State: ACTIVE\\n'\n",
            "fake-desktops": "#!/bin/bash\nexit 0\n",
            "sleep": "#!/bin/bash\ncase \"$1\" in 1|0.1) exec /bin/sleep 0.01 ;; *) exec /bin/sleep \"$@\" ;; esac\n",
            "google-chrome-stable": """#!/bin/bash
if [[ -n "${CHROMES_LOCK_FD:-}" && -e "/proc/$$/fd/$CHROMES_LOCK_FD" ]]; then
  printf 'LOCK_LEAK\\n' >> "$CHROMES_TEST_LOG"
fi
printf '%s|%s|%s\\n' "${CHROMES_MANAGED_PROJECT:-}" "${CHROMES_TARGET_WORKSPACE:-}" "$*" >> "$CHROMES_TEST_LOG"
""",
        }
        for filename, contents in scripts.items():
            target = binary / filename
            target.write_text(contents)
            target.chmod(0o755)
        (state / "extension.ready").write_text(
            "version=17\ncontroller=1\nfloating-label=0\nwindow-placement=1\nterminal-direct=1\nterminal-placement-verified=1\n")
        launch_log = base / "chrome.log"
        launch_log.touch()
        env = {**os.environ, "HOME": str(home), "PATH": f"{binary}:{os.environ['PATH']}",
               "AUTO_CODE_STATE_DIR": str(state.parent), "XDG_SESSION_TYPE": "wayland",
               "CHROMES_PLATFORM": "ubuntu", "PROJECTS_FILE": str(base / "projects"),
               "SERVICES_FILE": str(base / "services.csv"), "DESKTOPS_COMMAND": str(binary / "fake-desktops"),
               "CHROMES_TEST_LOG": str(launch_log)}
        for key in ("CHROMES_LOCAL_URLS", "CHROMES_SKIP_SECOND", "CHROMES_COMMAND", "CHROMES_LOCK_OWNER",
                    "CHROMES_LOCK_FD", "CHROMES_MANAGED_PROJECT", "CHROMES_MANAGED_EXPECTED"):
            env.pop(key, None)
        stop = threading.Event()
        actions: list[str] = []
        errors: list[BaseException] = []

        def write(name: str, value: str) -> None:
            tmp = state / f"{name}.mock"
            tmp.write_text(value)
            tmp.replace(state / name)

        def controller() -> None:
            last = ""
            launched = 0
            try:
                while not stop.wait(0.003):
                    request = state / "chromes.request"
                    if not request.exists():
                        continue
                    fields = request.read_text().strip().split("\t")
                    token = fields[0]
                    if not token or token == last:
                        continue
                    last = token
                    data = dict(field.split("=", 1) for field in fields[1:])
                    action = data["action"]
                    actions.append(action)
                    if action in ("status", "reconcile", "register"):
                        plan = Path(data["plan"]).read_text()
                        assert plan == "bots/dev-automation\t2\t1\norgs/orbital-app\t3\t3\n", plan
                        managed, missing, untracked, overflow = counts
                        if wrong_protocol:
                            write("chromes.ready", f"{token}\tworkspace=2\tmonitor=0\n")
                            continue
                        write("chromes.ready", f"{token}\taction={action}\tvalid={0 if invalid else 1}"
                              f"\tmanaged={managed}\tmissing={missing}\tuntracked={untracked}\toverflow={overflow}\n")
                        if action == "reconcile":
                            write("chromes.result", f"{token}\tplaced={managed}\texpected={managed}"
                                  f"\tcomplete={0 if placement_fails else 1}\n")
                    elif action == "default":
                        assert data["project"] in ("bots/dev-automation", "orgs/orbital-app")
                        assert data["expected"] == ("1" if data["project"] == "bots/dev-automation" else "3")
                        assert data.get("force") == "1", data
                        write("chromes.ready", f"{token}\taction=default\tvalid=1\tworkspace={data['workspace']}\tmonitor=0\tmaximize=1\n")
                        target = launched + int(data["expected"])
                        deadline = time.monotonic() + 4
                        while time.monotonic() < deadline and not stop.wait(0.005):
                            lines = launch_log.read_text().splitlines()
                            if len(lines) >= target:
                                break
                        assert len(launch_log.read_text().splitlines()) >= target, "Chrome não foi lançado"
                        launched = target
                        write("chromes.result", f"{token}\tbrowsers={data['expected']}\tnautilus=0\n")
                    else:
                        raise AssertionError(f"ação inesperada/perigosa: {action}")
            except BaseException as exc:
                errors.append(exc)

        lock_handle = None
        if locked:
            lock_handle = (state / "chromes.lock").open("w")
            fcntl.flock(lock_handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        watcher = threading.Thread(target=controller, daemon=True)
        watcher.start()
        try:
            command = ["bash", str(ROOT / "scripts/chromes-all.sh")]
            if register:
                command.append("--register-existing")
            completed = subprocess.run(command, env=env, text=True, capture_output=True, timeout=15)
            if locked:
                manual = subprocess.run(["bash", str(ROOT / "scripts/chromes/ubuntu.sh")],
                                        env=env, text=True, capture_output=True, timeout=5)
                assert manual.returncode != 0, "chromes manual deve respeitar o mesmo lock"
        finally:
            stop.set()
            watcher.join(timeout=2)
            if lock_handle:
                lock_handle.close()
        assert not watcher.is_alive(), "controlador de teste não encerrou"
        assert not errors, errors
        assert (completed.returncode == 0) == expect_ok, (name, completed.stdout, completed.stderr)
        assert actions == expected_actions, (name, actions)
        launches = launch_log.read_text().splitlines()
        assert not any("LOCK_LEAK" in line for line in launches), "navegador herdou o lock"
        if "default" in actions:
            assert len(launches) == 4, launches
            assert "bots/dev-automation|2|" in launches[0]
            assert "--profile-directory=Default --new-window https://chatgpt.com/" in launches[0]
            assert "orgs/orbital-app|3|" in launches[1]
            assert "--profile-directory=Profile 3 --new-window https://admin.localhost/" in launches[2]
            assert "--profile-directory=Profile 12 --new-window https://admin.localhost/" in launches[3]
        else:
            assert not launches, (name, launches)
        if not locked:
            # O término do comando deve liberar o lock para a próxima execução.
            with (state / "chromes.lock").open("a") as probe:
                fcntl.flock(probe, fcntl.LOCK_EX | fcntl.LOCK_NB)
        print(f"OK: {name}")


def main() -> None:
    check_case("primeira abertura registra o projeto e mantém perfis/URLs", (0, 4, 0, 0),
               expect_ok=True, expected_actions=["status", "default", "default"])
    check_case("reexecução só faz status e reconcile", (4, 0, 0, 0),
               expect_ok=True, expected_actions=["status", "reconcile"])
    check_case("lote completo ignora Chrome extra não gerenciado", (4, 0, 2, 0),
               expect_ok=True, expected_actions=["status", "reconcile"])
    check_case("lote parcial abre novo conjunto sem exigir registro", (3, 1, 0, 0),
               expect_ok=True, expected_actions=["status", "reconcile", "default", "default"])
    check_case("Chrome desconhecido não bloqueia nova abertura", (0, 4, 1, 0),
               expect_ok=True, expected_actions=["status", "default", "default"])
    check_case("janelas extras não bloqueiam nova abertura", (5, 0, 0, 1),
               expect_ok=True, expected_actions=["status", "reconcile", "default", "default"])
    check_case("registro explícito não lança navegadores", (4, 0, 0, 0), register=True,
               expect_ok=True, expected_actions=["register"])
    check_case("registro inválido não bloqueia abertura normal", (0, 4, 4, 0), register=True, invalid=True,
               expect_ok=True, expected_actions=["register", "default", "default"])
    check_case("protocolo antigo não bloqueia abertura normal", (4, 0, 0, 0), wrong_protocol=True,
               expect_ok=True, expected_actions=["status", "default", "default"])
    check_case("falha de confirmação cai para abertura normal", (4, 0, 0, 0), placement_fails=True,
               expect_ok=True, expected_actions=["status", "reconcile", "default", "default"])
    check_case("execuções simultâneas e chromes manual respeitam o lock", (0, 4, 0, 0), locked=True,
               expect_ok=False, expected_actions=[])
    print("11 cenários de integração Chrome aprovados, sem dependência de register-existing.")


if __name__ == "__main__":
    main()
