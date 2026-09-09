from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
LOCAL = ROOT / "deploy" / "local"


def text(name: str) -> str:
    return (LOCAL / name).read_text(encoding="utf-8")


def test_parent_launches_service_wrappers_as_own_sessions():
    start = text("start.sh")
    assert 'setsid "$SCRIPT_DIR/start-api.sh"' in start
    assert 'setsid "$SCRIPT_DIR/start-web.sh"' in start
    assert 'kill -TERM "$pid"' in start


def test_readiness_is_tied_to_spawned_process_group_not_just_http_200():
    runtime = text("runtime.sh")
    assert "runtime_port_owned_by_group" in runtime
    assert "runtime_wait_http_owned" in runtime
    assert 'runtime_port_owned_by_group "$port" "$pgid"' in runtime


def test_stale_listener_cleanup_is_restricted_to_this_application_root():
    runtime = text("runtime.sh")
    assert "runtime_is_under_root" in runtime
    assert "porta $port ocupada por processo externo" in runtime
    assert "instância local anterior detectada" in runtime


def test_api_and_web_use_shared_runtime_guard():
    for name in ("start-api.sh", "start-web.sh"):
        script = text(name)
        assert 'source "$SCRIPT_DIR/runtime.sh"' in script
        assert "runtime_stop_port_owner" in script
        assert "runtime_wait_http_owned" in script
        assert "runtime_stop_session" in script
