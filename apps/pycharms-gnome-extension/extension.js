import Meta from 'gi://Meta';
import GLib from 'gi://GLib';
import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';

const PYCHARM_RE = /pycharm|jetbrains[-_. ]?pycharm/i;
const STATE_DIR = GLib.build_filenamev([
    GLib.get_home_dir(),
    '.local', 'state', 'dev-automation', 'pycharms',
]);
const MAP_PATH = GLib.build_filenamev([STATE_DIR, 'workspaces.tsv']);
const BATCH_PATH = GLib.build_filenamev([STATE_DIR, 'batch-opening']);
const RECONCILE_PATH = GLib.build_filenamev([STATE_DIR, 'reconcile.request']);
const RECONCILE_READY_PATH = GLib.build_filenamev([STATE_DIR, 'reconcile.ready']);
const RECONCILE_RESULT_PATH = GLib.build_filenamev([STATE_DIR, 'reconcile.result']);
const OPEN_PROJECTS_PATH = GLib.build_filenamev([STATE_DIR, 'open-projects.tsv']);
const OPEN_PROJECTS_REQUEST_PATH = GLib.build_filenamev([STATE_DIR, 'open-projects.request']);
const OPEN_PROJECTS_READY_PATH = GLib.build_filenamev([STATE_DIR, 'open-projects.ready']);
const CLOSE_REQUEST_PATH = GLib.build_filenamev([STATE_DIR, 'close.request']);
const CLOSE_READY_PATH = GLib.build_filenamev([STATE_DIR, 'close.ready']);
const CLOSE_RESULT_PATH = GLib.build_filenamev([STATE_DIR, 'close.result']);

export default class PyCharmsMonitorExtension extends Extension {
    enable() {
        this._signalIds = [];
        this._timeouts = new Set();
        this._reconcileRounds = 0;
        this._lastRequestToken = this._readRequestToken();
        this._lastOpenProjectsRequestToken = this._readOpenProjectsRequestToken();
        this._lastCloseRequestToken = this._readCloseRequestToken();
        // Movimento de janelas é exclusivamente explícito. A extensão NÃO
        // reage a window-created e NÃO reorganiza ao ser habilitada. Isso evita
        // disputar com o startup assíncrono do JetBrains. O backend só envia
        // reconcile.request quando uma nova chamada de `pycharms` confirma que
        // todos os projetos já estão carregados.
        this._controlTimer = GLib.timeout_add(GLib.PRIORITY_DEFAULT, 1000, () => {
            const batchActive = this._batchActive();

            const token = this._readRequestToken();
            if (token && token !== this._lastRequestToken) {
                this._lastRequestToken = token;
                const result = this._reconcileAll();
                this._writeReconcileResult(token, result);
                // Algumas janelas JetBrains ainda podem atualizar título/estado logo
                // após o pedido. Repetimos poucas vezes, mas somente porque houve
                // uma solicitação explícita do backend.
                this._startReconcile(8);
            }

            const openProjectsToken = this._readOpenProjectsRequestToken();
            if (openProjectsToken && openProjectsToken !== this._lastOpenProjectsRequestToken) {
                this._lastOpenProjectsRequestToken = openProjectsToken;
                this._writeOpenProjectsSnapshot(openProjectsToken);
            }

            const closeToken = this._readCloseRequestToken();
            if (closeToken && closeToken !== this._lastCloseRequestToken) {
                this._lastCloseRequestToken = closeToken;
                this._closePyCharmWindows(closeToken);
            }

            if (!batchActive && this._reconcileRounds > 0) {
                this._reconcileAll();
                this._reconcileRounds--;
            }
            return GLib.SOURCE_CONTINUE;
        });
    }

    disable() {
        for (const [object, id] of this._signalIds ?? []) {
            try {
                object.disconnect(id);
            } catch (_) {
                // objeto já destruído
            }
        }
        this._signalIds = [];

        if (this._controlTimer) {
            GLib.source_remove(this._controlTimer);
            this._controlTimer = 0;
        }
        for (const id of this._timeouts ?? [])
            GLib.source_remove(id);
        this._timeouts?.clear();
        this._timeouts = new Set();
        this._reconcileRounds = 0;
    }

    _batchActive() {
        try {
            const [ok, bytes] = GLib.file_get_contents(BATCH_PATH);
            if (!ok)
                return false;
            const expiry = Number.parseInt(new TextDecoder('utf-8').decode(bytes).trim(), 10);
            if (!Number.isFinite(expiry))
                return false;
            return Math.floor(GLib.get_real_time() / 1000000) <= expiry;
        } catch (_) {
            return false;
        }
    }

    _readRequestToken() {
        try {
            const [ok, bytes] = GLib.file_get_contents(RECONCILE_PATH);
            if (!ok)
                return '';
            return new TextDecoder('utf-8').decode(bytes).trim();
        } catch (_) {
            return '';
        }
    }

    _readOpenProjectsRequestToken() {
        try {
            const [ok, bytes] = GLib.file_get_contents(OPEN_PROJECTS_REQUEST_PATH);
            if (!ok)
                return '';
            return new TextDecoder('utf-8').decode(bytes).trim();
        } catch (_) {
            return '';
        }
    }

    _readCloseRequestToken() {
        try {
            const [ok, bytes] = GLib.file_get_contents(CLOSE_REQUEST_PATH);
            if (!ok)
                return '';
            return new TextDecoder('utf-8').decode(bytes).trim();
        } catch (_) {
            return '';
        }
    }

    _closePyCharmWindows(token) {
        this._reconcileRounds = 0;
        let requested = 0;
        let skipped = 0;
        const timestamp = global.get_current_time();

        for (const actor of global.get_window_actors()) {
            const window = actor.meta_window;
            if (!window || window.get_window_type() !== Meta.WindowType.NORMAL)
                continue;
            if (!this._isPyCharm(window))
                continue;
            if (window.can_close?.() === false) {
                skipped++;
                continue;
            }
            try {
                window.delete(timestamp);
                requested++;
            } catch (error) {
                skipped++;
                console.error(`[pycharms-monitor] falha ao fechar janela PyCharm: ${error}`);
            }
        }

        try {
            GLib.mkdir_with_parents(STATE_DIR, 0o700);
            GLib.file_set_contents(CLOSE_RESULT_PATH, `solicitadas=${requested} ignoradas=${skipped}\n`);
            GLib.file_set_contents(CLOSE_READY_PATH, `${token}\n`);
        } catch (error) {
            console.error(`[pycharms-monitor] falha ao confirmar pycharms --close: ${error}`);
        }
    }

    _writeOpenProjectsSnapshot(token) {
        const seen = new Set();
        const rows = [];
        for (const actor of global.get_window_actors()) {
            const window = actor.meta_window;
            if (!window || window.get_window_type() !== Meta.WindowType.NORMAL)
                continue;
            if (!this._isPyCharm(window))
                continue;
            const target = this._projectTarget(window);
            if (!target || seen.has(target.path))
                continue;
            seen.add(target.path);
            rows.push(`${target.workspace}\t${target.name}\t${target.path}`);
        }

        try {
            GLib.mkdir_with_parents(STATE_DIR, 0o700);
            const body = rows.length > 0 ? `${rows.join('\n')}\n` : '';
            GLib.file_set_contents(OPEN_PROJECTS_PATH, body);
            GLib.file_set_contents(OPEN_PROJECTS_READY_PATH, `${token}\n`);
        } catch (error) {
            console.error(`[pycharms-monitor] falha ao gravar snapshot de projetos abertos: ${error}`);
        }
    }

    _startReconcile(rounds = 45) {
        this._reconcileRounds = Math.max(this._reconcileRounds, rounds);
    }

    _reconcileAll() {
        let pycharmWindows = 0;
        let matched = 0;
        let changed = 0;
        let alreadyCorrect = 0;
        let unmatched = 0;
        let errors = 0;

        for (const actor of global.get_window_actors()) {
            const window = actor.meta_window;
            if (!window || window.get_window_type() !== Meta.WindowType.NORMAL)
                continue;
            if (!this._isPyCharm(window))
                continue;

            pycharmWindows++;
            const target = this._projectTarget(window);
            if (!target) {
                unmatched++;
                continue;
            }

            matched++;
            const placement = this._place(window, target);
            if (placement?.error)
                errors++;
            else if (placement?.changed)
                changed++;
            else
                alreadyCorrect++;
        }

        return {pycharmWindows, matched, changed, alreadyCorrect, unmatched, errors};
    }

    _writeReconcileResult(token, result) {
        try {
            GLib.mkdir_with_parents(STATE_DIR, 0o700);
            const summary = [
                `janelas=${result?.pycharmWindows ?? 0}`,
                `mapeadas=${result?.matched ?? 0}`,
                `alteradas=${result?.changed ?? 0}`,
                `já_corretas=${result?.alreadyCorrect ?? 0}`,
                `sem_mapa=${result?.unmatched ?? 0}`,
                `erros=${result?.errors ?? 0}`,
            ].join(' ');
            GLib.file_set_contents(RECONCILE_RESULT_PATH, `${summary}\n`);
            GLib.file_set_contents(RECONCILE_READY_PATH, `${token}\n`);
        } catch (error) {
            console.error(`[pycharms-monitor] falha ao confirmar reconciliação: ${error}`);
        }
    }

    _isPyCharm(window) {
        const values = [
            window.get_wm_class?.(),
            window.get_wm_class_instance?.(),
            window.get_gtk_application_id?.(),
            window.get_title?.(),
        ];
        return values.some(value => value && PYCHARM_RE.test(String(value)));
    }

    _windowText(window) {
        return [
            window.get_title?.(),
            window.get_description?.(),
            window.get_wm_class?.(),
            window.get_wm_class_instance?.(),
            window.get_gtk_application_id?.(),
        ]
            .filter(Boolean)
            .map(value => String(value).toLocaleLowerCase())
            .join('\n');
    }

    _loadTargets() {
        try {
            const [ok, bytes] = GLib.file_get_contents(MAP_PATH);
            if (!ok)
                return [];
            const text = new TextDecoder('utf-8').decode(bytes);
            const targets = [];
            for (const raw of text.split('\n')) {
                const line = raw.trim();
                if (!line)
                    continue;
                const parts = line.split('\t');
                if (parts.length < 3)
                    continue;
                const workspace = Number.parseInt(parts[0], 10);
                const name = parts[1];
                const path = parts.slice(2).join('\t');
                if (!Number.isInteger(workspace) || workspace < 2 || !name)
                    continue;
                targets.push({workspace, name, path});
            }
            // Nome mais específico primeiro evita colisões tipo app / orbital-app.
            targets.sort((a, b) => b.name.length - a.name.length);
            return targets;
        } catch (_) {
            return [];
        }
    }

    _projectTarget(window) {
        const haystack = this._windowText(window);
        if (!haystack)
            return null;
        for (const target of this._loadTargets()) {
            const name = target.name.toLocaleLowerCase();
            const path = target.path.toLocaleLowerCase();
            if (haystack.includes(name) || haystack.includes(path))
                return target;
        }
        return null;
    }

    _targetMonitor() {
        // Maior monitor por área. No layout atual: DP-6, 3840x2160, central.
        const count = global.display.get_n_monitors();
        let best = 0;
        let bestArea = -1;
        for (let i = 0; i < count; i++) {
            const rect = global.display.get_monitor_geometry(i);
            const area = rect.width * rect.height;
            if (area > bestArea) {
                bestArea = area;
                best = i;
            }
        }
        return best;
    }

    _place(window, target) {
        let changed = false;
        try {
            // Workspaces são garantidos pelo comando desktops antes do lote.
            // Não ativamos a janela, então o usuário permanece onde está.
            const workspaceIndex = target.workspace - 1;
            const currentWorkspace = window.get_workspace?.();
            if (!currentWorkspace || currentWorkspace.index() !== workspaceIndex) {
                window.change_workspace_by_index(workspaceIndex, false);
                changed = true;
            }

            const monitor = this._targetMonitor();
            if (window.get_monitor() !== monitor) {
                window.move_to_monitor(monitor);
                changed = true;
            }

            // GNOME/Mutter 49+ removeu MaximizeFlags do argumento de maximize().
            if (!window.is_maximized?.()) {
                window.maximize();
                changed = true;
            }
            return {changed};
        } catch (error) {
            console.error(`[pycharms-monitor] falha ao posicionar ${target.name}: ${error}`);
            return {changed, error: String(error)};
        }
    }
}
