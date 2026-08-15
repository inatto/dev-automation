import Meta from 'gi://Meta';
import GLib from 'gi://GLib';
import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';

const PYCHARM_RE = /pycharm|jetbrains[-_. ]?pycharm/i;

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

        // Também corrige janelas PyCharm que já estavam abertas quando a
        // extensão foi habilitada/recarregada.
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
                // objeto já destruído; nada a fazer
            }
        }
        this._signalIds = [];

        for (const id of this._timeouts ?? [])
            GLib.source_remove(id);
        this._timeouts?.clear();
        this._timeouts = new Set();
    }

    _schedulePlacement(window) {
        // JetBrains pode preencher WM_CLASS/título alguns milissegundos depois
        // de window-created. Tentamos algumas vezes sem bloquear o Shell.
        let attempts = 0;
        const id = GLib.timeout_add(GLib.PRIORITY_DEFAULT, 180, () => {
            attempts++;
            if (!window || window.get_window_type() !== Meta.WindowType.NORMAL) {
                this._timeouts.delete(id);
                return GLib.SOURCE_REMOVE;
            }

            if (this._isPyCharm(window)) {
                this._place(window);
                this._timeouts.delete(id);
                return GLib.SOURCE_REMOVE;
            }

            if (attempts >= 30) {
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

    _targetMonitor() {
        // Regra Ubuntu deste projeto: PyCharm vai para o monitor de maior área.
        // No layout do Daniel isso seleciona o DP-6 3840x2160 central.
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

    _place(window) {
        const monitor = this._targetMonitor();
        try {
            if (window.get_monitor() !== monitor)
                window.move_to_monitor(monitor);
            window.maximize(Meta.MaximizeFlags.BOTH);
            window.activate(global.get_current_time());
        } catch (error) {
            console.error(`[pycharms-monitor] falha ao posicionar PyCharm: ${error}`);
        }
    }
}
