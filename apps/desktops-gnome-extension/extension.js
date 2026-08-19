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
const UI_READY_PATH = GLib.build_filenamev([STATE_DIR, 'ui.ready']);
const UI_VERSION = 4;
const CORNER_MARGIN = 18;

export default class DevAutomationWorkspaceNameExtension extends Extension {
    enable() {
        this._workspaceManager = global.workspace_manager;
        this._settings = new Gio.Settings({schema_id: 'org.gnome.desktop.wm.preferences'});
        this._layoutIdleId = 0;
        this._lastCloseRequestToken = this._readCloseRequestToken();

        this._createCornerLabel();

        this._workspaceSignalId = this._workspaceManager.connect(
            'active-workspace-changed',
            () => this._updateWorkspaceUi()
        );
        this._workspaceCountSignalId = this._workspaceManager.connect(
            'notify::n-workspaces',
            () => this._updateWorkspaceUi()
        );
        this._settingsSignalId = this._settings.connect(
            'changed::workspace-names',
            () => this._updateWorkspaceUi()
        );
        this._monitorsChangedId = Main.layoutManager.connect('monitors-changed', () => {
            this._queueCornerLayout();
        });

        this._controlTimer = GLib.timeout_add(GLib.PRIORITY_DEFAULT, 500, () => {
            const token = this._readCloseRequestToken();
            if (token && token !== this._lastCloseRequestToken) {
                this._lastCloseRequestToken = token;
                this._closeManagedWorkspaceWindows(token);
            }
            return GLib.SOURCE_CONTINUE;
        });

        this._updateWorkspaceUi();
        this._writeUiReady();
    }

    disable() {
        this._removeUiReady();

        if (this._workspaceSignalId) {
            this._workspaceManager?.disconnect(this._workspaceSignalId);
            this._workspaceSignalId = 0;
        }
        if (this._workspaceCountSignalId) {
            this._workspaceManager?.disconnect(this._workspaceCountSignalId);
            this._workspaceCountSignalId = 0;
        }
        if (this._settingsSignalId) {
            this._settings?.disconnect(this._settingsSignalId);
            this._settingsSignalId = 0;
        }
        if (this._monitorsChangedId) {
            Main.layoutManager.disconnect(this._monitorsChangedId);
            this._monitorsChangedId = 0;
        }
        if (this._layoutIdleId) {
            GLib.source_remove(this._layoutIdleId);
            this._layoutIdleId = 0;
        }
        if (this._controlTimer) {
            GLib.source_remove(this._controlTimer);
            this._controlTimer = 0;
        }

        this._cornerLabel?.destroy();
        this._cornerLabel = null;

        this._settings = null;
        this._workspaceManager = null;
    }

    _createCornerLabel() {
        this._cornerLabel = new St.Label({
            style_class: 'dev-automation-workspace-corner',
            reactive: false,
        });
        Main.uiGroup.add_child(this._cornerLabel);
    }

    _workspaceInfo(index = this._workspaceManager.get_active_workspace_index()) {
        const names = this._settings.get_strv('workspace-names');
        const name = names[index] || `Desktop ${index + 1}`;
        return {index, name, title: `${index + 1}  ${name}`};
    }

    _updateWorkspaceUi() {
        if (!this._workspaceManager || !this._settings || !this._cornerLabel)
            return;

        const {title} = this._workspaceInfo();
        this._cornerLabel.text = title;
        this._cornerLabel.show();
        this._queueCornerLayout();
    }

    _queueCornerLayout() {
        if (this._layoutIdleId || !this._cornerLabel)
            return;

        this._layoutIdleId = GLib.idle_add(GLib.PRIORITY_DEFAULT_IDLE, () => {
            this._layoutIdleId = 0;
            this._layoutCornerLabel();
            return GLib.SOURCE_REMOVE;
        });
    }

    _layoutCornerLabel() {
        if (!this._cornerLabel)
            return;

        const monitors = Main.layoutManager.monitors;
        const monitor = Main.layoutManager.primaryMonitor || monitors?.[0];
        if (!monitor)
            return;

        let area = monitor;
        const primaryIndex = Math.max(0, monitors.indexOf(monitor));
        try {
            area = Main.layoutManager.getWorkAreaForMonitor(primaryIndex) || monitor;
        } catch (_) {
            area = monitor;
        }

        const [, width] = this._cornerLabel.get_preferred_width(-1);
        const [, height] = this._cornerLabel.get_preferred_height(width);
        const x = area.x + Math.max(0, area.width - width - CORNER_MARGIN);
        const y = area.y + Math.max(0, area.height - height - CORNER_MARGIN);

        this._cornerLabel.set_position(x, y);
        this._cornerLabel.set_size(width, height);
    }

    _writeUiReady() {
        try {
            const cornerAttached = Boolean(this._cornerLabel?.get_parent());
            if (!cornerAttached)
                throw new Error('indicador do canto inferior direito não foi anexado ao GNOME Shell');

            GLib.mkdir_with_parents(STATE_DIR, 0o700);
            GLib.file_set_contents(UI_READY_PATH,
                `version=${UI_VERSION}\ncorner=1\n`);
        } catch (error) {
            console.error(`[workspace-name-osd] falha no self-check visual: ${error}`);
        }
    }

    _removeUiReady() {
        try {
            GLib.unlink(UI_READY_PATH);
        } catch (_) {
            // Arquivo pode não existir durante primeiro enable/disable.
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
}
