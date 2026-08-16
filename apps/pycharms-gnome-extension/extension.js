import Meta from 'gi://Meta';
import GLib from 'gi://GLib';
import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';

const PYCHARM_RE = /pycharm|jetbrains[-_. ]?pycharm/i;
const MAP_PATH = GLib.build_filenamev([
    GLib.get_home_dir(),
    '.local', 'state', 'dev-automation', 'pycharms', 'workspaces.tsv',
]);

export default class PyCharmsMonitorExtension extends Extension {
    enable() {
        this._signalIds = [];
        this._timeouts = new Set();
        this._signalIds.push([
            global.display,
            global.display.connect('window-created', (_display, window) => {
                this._schedulePlacement(window);
            }),
        ]);

        for (const actor of global.get_window_actors()) {
            const window = actor.meta_window;
            if (window)
                this._schedulePlacement(window);
        }
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
        for (const id of this._timeouts ?? [])
            GLib.source_remove(id);
        this._timeouts?.clear();
        this._timeouts = new Set();
    }

    _schedulePlacement(window) {
        let attempts = 0;
        const id = GLib.timeout_add(GLib.PRIORITY_DEFAULT, 200, () => {
            attempts++;
            if (!window || window.get_window_type() !== Meta.WindowType.NORMAL) {
                this._timeouts.delete(id);
                return GLib.SOURCE_REMOVE;
            }

            if (this._isPyCharm(window)) {
                const target = this._projectTarget(window);
                if (target) {
                    this._place(window, target);
                    this._timeouts.delete(id);
                    return GLib.SOURCE_REMOVE;
                }
            }

            // JetBrains pode demorar para preencher título/WM_CLASS no Wayland.
            if (attempts >= 60) {
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
            // O índice do Mutter é zero-based; nosso mapa é 1-based e mantém
            // Workspace 1 = LAZER. Não ativamos a janela, portanto o usuário
            // continua no workspace em que já estava.
            window.change_workspace_by_index(target.workspace - 1, false);

            const monitor = this._targetMonitor();
            if (window.get_monitor() !== monitor)
                window.move_to_monitor(monitor);
            window.maximize(Meta.MaximizeFlags.BOTH);
        } catch (error) {
            console.error(`[pycharms-monitor] falha ao posicionar ${target.name}: ${error}`);
        }
    }
}
