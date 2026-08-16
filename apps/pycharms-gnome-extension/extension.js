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

export default class PyCharmsMonitorExtension extends Extension {
    enable() {
        this._signalIds = [];
        this._timeouts = new Set();
        this._reconcileRounds = 0;
        this._lastRequestToken = this._readRequestToken();
        this._batchWasActive = this._batchActive();

        this._signalIds.push([
            global.display,
            global.display.connect('window-created', (_display, window) => {
                this._schedulePlacement(window);
            }),
        ]);

        // Controle leve: detecta fim do lote e pedidos explícitos de revisão.
        this._controlTimer = GLib.timeout_add(GLib.PRIORITY_DEFAULT, 1000, () => {
            const batchActive = this._batchActive();
            if (this._batchWasActive && !batchActive)
                this._startReconcile(45);
            this._batchWasActive = batchActive;

            const token = this._readRequestToken();
            if (token && token !== this._lastRequestToken) {
                this._lastRequestToken = token;
                this._startReconcile(45);
            }

            if (!batchActive && this._reconcileRounds > 0) {
                this._reconcileAll();
                this._reconcileRounds--;
            }
            return GLib.SOURCE_CONTINUE;
        });

        // Corrige janelas que já existiam quando a extensão entrou na sessão,
        // mas só se não houver um lote de abertura em andamento.
        if (!this._batchWasActive)
            this._startReconcile(12);
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

    _startReconcile(rounds = 45) {
        this._reconcileRounds = Math.max(this._reconcileRounds, rounds);
    }

    _reconcileAll() {
        for (const actor of global.get_window_actors()) {
            const window = actor.meta_window;
            if (!window || window.get_window_type() !== Meta.WindowType.NORMAL)
                continue;
            if (!this._isPyCharm(window))
                continue;
            const target = this._projectTarget(window);
            if (target)
                this._place(window, target);
        }
    }

    _schedulePlacement(window) {
        let attempts = 0;
        let stableTarget = '';
        let stableHits = 0;
        const id = GLib.timeout_add(GLib.PRIORITY_DEFAULT, 500, () => {
            attempts++;
            if (!window || window.get_window_type() !== Meta.WindowType.NORMAL) {
                this._timeouts.delete(id);
                return GLib.SOURCE_REMOVE;
            }

            // Durante a abertura em lote não encostamos nas janelas. JetBrains
            // ainda pode estar trocando splash, título, tamanho e sessão nesse ponto.
            if (this._batchActive()) {
                if (attempts >= 360) {
                    this._timeouts.delete(id);
                    return GLib.SOURCE_REMOVE;
                }
                return GLib.SOURCE_CONTINUE;
            }

            if (this._isPyCharm(window)) {
                const target = this._projectTarget(window);
                if (target) {
                    if (stableTarget === target.name)
                        stableHits++;
                    else {
                        stableTarget = target.name;
                        stableHits = 1;
                    }
                    // Exige o mesmo projeto por 2 s antes de mover uma janela
                    // criada fora do lote normal do comando pycharms.
                    if (stableHits >= 4) {
                        this._place(window, target);
                        this._timeouts.delete(id);
                        return GLib.SOURCE_REMOVE;
                    }
                } else {
                    stableTarget = '';
                    stableHits = 0;
                }
            }

            if (attempts >= 180) {
                this._timeouts.delete(id);
                return GLib.SOURCE_REMOVE;
            }
            return GLib.SOURCE_CONTINUE;
        });
        this._timeouts.add(id);
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
        try {
            // Workspaces são garantidos pelo comando desktops antes do lote.
            // Não ativamos a janela, então o usuário permanece onde está.
            const workspaceIndex = target.workspace - 1;
            const currentWorkspace = window.get_workspace?.();
            if (!currentWorkspace || currentWorkspace.index() !== workspaceIndex)
                window.change_workspace_by_index(workspaceIndex, false);

            const monitor = this._targetMonitor();
            if (window.get_monitor() !== monitor)
                window.move_to_monitor(monitor);

            // GNOME/Mutter 49+ removeu MaximizeFlags do argumento de maximize().
            if (!window.is_maximized?.())
                window.maximize();
        } catch (error) {
            console.error(`[pycharms-monitor] falha ao posicionar ${target.name}: ${error}`);
        }
    }
}
