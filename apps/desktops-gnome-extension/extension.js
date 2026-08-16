import Clutter from 'gi://Clutter';
import Meta from 'gi://Meta';
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import St from 'gi://St';

import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';

const STATE_DIR = GLib.build_filenamev([
    GLib.get_home_dir(), '.local', 'state', 'dev-automation', 'desktops',
]);
const CLOSE_REQUEST_PATH = GLib.build_filenamev([STATE_DIR, 'close.request']);
const CLOSE_READY_PATH = GLib.build_filenamev([STATE_DIR, 'close.ready']);
const CLOSE_RESULT_PATH = GLib.build_filenamev([STATE_DIR, 'close.result']);

export default class DevAutomationWorkspaceNameExtension extends Extension {
    enable() {
        this._workspaceManager = global.workspace_manager;
        this._settings = new Gio.Settings({schema_id: 'org.gnome.desktop.wm.preferences'});
        this._idleId = 0;
        this._lastCloseRequestToken = this._readCloseRequestToken();

        this._label = new St.Label({
            style_class: 'dev-automation-workspace-name',
            opacity: 0,
            reactive: false,
        });
        Main.uiGroup.add_child(this._label);

        this._workspaceSignalId = this._workspaceManager.connect(
            'active-workspace-changed',
            () => this._showActiveWorkspaceName()
        );

        this._controlTimer = GLib.timeout_add(GLib.PRIORITY_DEFAULT, 500, () => {
            const token = this._readCloseRequestToken();
            if (token && token !== this._lastCloseRequestToken) {
                this._lastCloseRequestToken = token;
                this._closeManagedWorkspaceWindows(token);
            }
            return GLib.SOURCE_CONTINUE;
        });
    }

    disable() {
        if (this._workspaceSignalId) {
            this._workspaceManager?.disconnect(this._workspaceSignalId);
            this._workspaceSignalId = 0;
        }
        if (this._idleId) {
            GLib.source_remove(this._idleId);
            this._idleId = 0;
        }
        if (this._controlTimer) {
            GLib.source_remove(this._controlTimer);
            this._controlTimer = 0;
        }
        this._label?.remove_all_transitions();
        this._label?.destroy();
        this._label = null;
        this._settings = null;
        this._workspaceManager = null;
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

    _closeManagedWorkspaceWindows(token) {
        const targets = [];
        let skipped = 0;

        for (const actor of global.get_window_actors()) {
            const window = actor.meta_window;
            if (!window || window.get_window_type() !== Meta.WindowType.NORMAL)
                continue;
            if (window.is_on_all_workspaces?.()) {
                skipped++;
                continue;
            }
            const workspace = window.get_workspace?.();
            if (!workspace || workspace.index() <= 0)
                continue; // Workspace 1 = LAZER, sempre preservado.
            if (window.can_close?.() === false) {
                skipped++;
                continue;
            }
            targets.push(window);
        }

        // Confirma o pedido antes de fechar as janelas. Assim, se o comando
        // desktops --close foi disparado de um terminal em um workspace de
        // projeto, o shell recebe a confirmação antes de o próprio terminal
        // receber o pedido de fechamento.
        try {
            GLib.mkdir_with_parents(STATE_DIR, 0o700);
            GLib.file_set_contents(CLOSE_RESULT_PATH, `solicitadas=${targets.length} ignoradas=${skipped}\n`);
            GLib.file_set_contents(CLOSE_READY_PATH, `${token}\n`);
        } catch (error) {
            console.error(`[workspace-name-osd] falha ao confirmar desktops --close: ${error}`);
            return;
        }

        GLib.idle_add(GLib.PRIORITY_DEFAULT_IDLE, () => {
            const timestamp = global.get_current_time();
            for (const window of targets) {
                try {
                    window.delete(timestamp);
                } catch (error) {
                    console.error(`[workspace-name-osd] falha ao fechar janela: ${error}`);
                }
            }
            return GLib.SOURCE_REMOVE;
        });
    }

    _showActiveWorkspaceName() {
        if (!this._label || !this._workspaceManager)
            return;

        const index = this._workspaceManager.get_active_workspace_index();
        const names = this._settings.get_strv('workspace-names');
        const name = names[index] || `Desktop ${index + 1}`;

        this._label.remove_all_transitions();
        this._label.text = `${index + 1}  ${name}`;
        this._label.opacity = 0;
        this._label.show();

        if (this._idleId)
            GLib.source_remove(this._idleId);

        this._idleId = GLib.idle_add(GLib.PRIORITY_DEFAULT_IDLE, () => {
            this._idleId = 0;
            if (!this._label)
                return GLib.SOURCE_REMOVE;

            const monitor = Main.layoutManager.primaryMonitor;
            const [, naturalWidth] = this._label.get_preferred_width(-1);
            const [, naturalHeight] = this._label.get_preferred_height(naturalWidth);
            const x = monitor.x + Math.round((monitor.width - naturalWidth) / 2);
            const y = monitor.y + Math.round(Math.max(48, monitor.height * 0.10));
            this._label.set_position(x, y);
            this._label.set_size(naturalWidth, naturalHeight);

            this._label.ease({
                opacity: 255,
                duration: 120,
                mode: Clutter.AnimationMode.EASE_OUT_QUAD,
                onComplete: () => {
                    this._label?.ease({
                        opacity: 0,
                        duration: 260,
                        delay: 850,
                        mode: Clutter.AnimationMode.EASE_IN_QUAD,
                    });
                },
            });
            return GLib.SOURCE_REMOVE;
        });
    }
}
