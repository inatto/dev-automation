from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def test_fastapi_routes_cover_terminal_features():
    source = (ROOT / "main.py").read_text(encoding="utf-8")
    required = [
        '/api/v1/overview', '/api/v1/messages', '/reply', '/approve', '/no-reply',
        '/api/v1/events', '/api/v1/api-runs', '/api/v1/functions', '/actions/refresh',
        '/actions/api-zip-test', '/api/v1/context-files', '/api/v1/external-delivery',
    ]
    for item in required:
        assert item in source


def test_delete_uses_async_monitor_queue():
    source = (ROOT / "service.py").read_text(encoding="utf-8")
    assert "queue_delete_inbound" in source
    assert "self.monitor.delete_inbound(" not in source


def test_version_is_project_file():
    import re
    version = (ROOT.parents[1] / "VERSION").read_text(encoding="utf-8").strip()
    assert re.fullmatch(r"\d{4}\.\d{2}\.\d{2}-V\d+", version)


def test_no_terminal_dependencies_in_new_api_entrypoint():
    source = (ROOT / "main.py").read_text(encoding="utf-8").lower()
    assert "curses" not in source
    assert "tui" not in source


def test_shutdown_aborts_imap_and_has_bounded_grace():
    monitor = (ROOT / "monitor.py").read_text(encoding="utf-8")
    mailbox = (ROOT / "mailbox.py").read_text(encoding="utf-8")
    main = (ROOT / "main.py").read_text(encoding="utf-8")
    assert "self.mailbox.abort_all()" in monitor
    assert "timeout=self.settings.imap_timeout_seconds" in mailbox
    assert "timeout_graceful_shutdown=3" in main
    assert "thread.join(timeout=2.0)" in main


def test_global_command_is_not_owned_by_subproject():
    project = ROOT.parents[1]
    assert not (project / "run.sh").exists()
    assert not (project / "install.sh").exists()


def test_reply_enqueue_has_synchronous_preflight_and_action_lookup():
    service = (ROOT / "service.py").read_text(encoding="utf-8")
    main = (ROOT / "main.py").read_text(encoding="utf-8")
    monitor = (ROOT / "monitor.py").read_text(encoding="utf-8")
    assert "validate_reply_generation(row, manual_force=True)" in service
    assert "def validate_reply_generation" in monitor
    assert "create_new = True" in monitor
    assert '/api/v1/actions/{action_id}' in main

def test_action_keeps_structured_reply_result():
    source = (ROOT / "service.py").read_text(encoding="utf-8")
    assert 'result=result if result is not None else ""' in source
    assert 'return self.monitor.generate_or_regenerate_reply' in source


def test_actions_are_durable_in_oracle_not_memory_only():
    source = (ROOT / "service.py").read_text(encoding="utf-8")
    assert 'kind=f"action:{kind}"' in source
    assert 'return self._action_from_api_run(row)' in source
    assert 'self.store.get_api_run(run_id)' in source
    assert 'self.store.add_api_run(' in source
    assert 'uuid.uuid4' not in source


def test_internal_action_rows_are_hidden_from_openai_history():
    source = (ROOT / "service.py").read_text(encoding="utf-8")
    assert 'startswith("action:")' in source
    assert 'não poluem o histórico OpenAI' in source


def test_manual_reply_can_create_new_after_sent_but_automatic_stays_idempotent():
    monitor = (ROOT / "monitor.py").read_text(encoding="utf-8")
    service = (ROOT / "service.py").read_text(encoding="utf-8")
    assert "manual_force: bool = False" in monitor
    assert 'if current_status == "sent"' in monitor
    assert "if manual_force:" in monitor
    assert "create_new = True" in monitor
    assert '"reply-followup"' in monitor
    assert "outbound is None or create_new" in monitor
    assert "validate_reply_generation(row, manual_force=True)" in service
    assert "manual_force=True" in service


def test_inflight_reply_still_blocks_manual_duplicate():
    monitor = (ROOT / "monitor.py").read_text(encoding="utf-8")
    assert 'current_status in {"send-queued", "sending"}' in monitor
    assert "aguarde o envio terminar antes de gerar outra" in monitor
