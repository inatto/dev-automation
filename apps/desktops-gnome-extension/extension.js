import Meta from 'gi://Meta';
import GLib from 'gi://GLib';

import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';

const STATE_DIR = GLib.build_filenamev([
    GLib.get_home_dir(), '.local', 'state', 'dev-automation', 'desktops',
]);
const CLOSE_REQUEST_PATH = GLib.build_filenamev([STATE_DIR, 'close.request']);
const CLOSE_READY_PATH = GLib.build_filenamev([STATE_DIR, 'close.ready']);
const CLOSE_RESULT_PATH = GLib.build_filenamev([STATE_DIR, 'close.result']);
const EXTENSION_READY_PATH = GLib.build_filenamev([STATE_DIR, 'extension.ready']);
const EXTENSION_VERSION = 5;

export default class DevAutomationWorkspaceControllerExtension extends Extension {
    enable() {
        this._lastCloseRequestToken = this._readCloseRequestToken();

        this._controlTimer = GLib.timeout_add(GLib.PRIORITY_DEFAULT, 500, () => {
            const token = this._readCloseRequestToken();
            if (token && token !== this._lastCloseRequestToken) {
                this._lastCloseRequestToken = token;
                this._closeManagedWorkspaceWindows(token);
            }
            return GLib.SOURCE_CONTINUE;
        });

        this._writeExtensionReady();
    }

    disable() {
        this._removeExtensionReady();

        if (this._controlTimer) {
            GLib.source_remove(this._controlTimer);
            this._controlTimer = 0;
        }
    }

    _writeExtensionReady() {
        try {
            GLib.mkdir_with_parents(STATE_DIR, 0o700);
            GLib.file_set_contents(
                EXTENSION_READY_PATH,
                `version=${EXTENSION_VERSION}\ncontroller=1\nfloating-label=0\n`
            );
        } catch (error) {
            console.error(`[workspace-name-osd] falha no self-check da extensão: ${error}`);
        }
    }

    _removeExtensionReady() {
        try {
            GLib.unlink(EXTENSION_READY_PATH);
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
