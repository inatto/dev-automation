import Meta from 'gi://Meta';
import GLib from 'gi://GLib';

import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';

const STATE_DIR = GLib.build_filenamev([
    GLib.get_home_dir(), '.local', 'state', 'dev-automation', 'desktops',
]);
const CLOSE_REQUEST_PATH = GLib.build_filenamev([STATE_DIR, 'close.request']);
const CLOSE_READY_PATH = GLib.build_filenamev([STATE_DIR, 'close.ready']);
const CLOSE_RESULT_PATH = GLib.build_filenamev([STATE_DIR, 'close.result']);
const CHROMES_REQUEST_PATH = GLib.build_filenamev([STATE_DIR, 'chromes.request']);
const CHROMES_READY_PATH = GLib.build_filenamev([STATE_DIR, 'chromes.ready']);
const CHROMES_RESULT_PATH = GLib.build_filenamev([STATE_DIR, 'chromes.result']);
const TERMINALS_REQUEST_PATH = GLib.build_filenamev([STATE_DIR, 'terminals.request']);
const TERMINALS_READY_PATH = GLib.build_filenamev([STATE_DIR, 'terminals.ready']);
const TERMINALS_RESULT_PATH = GLib.build_filenamev([STATE_DIR, 'terminals.result']);
const EXTENSION_READY_PATH = GLib.build_filenamev([STATE_DIR, 'extension.ready']);
const EXTENSION_VERSION = 8;

const BROWSER_RE = /google[-_. ]?chrome|chromium/i;
const NAUTILUS_RE = /org\.gnome\.nautilus|nautilus/i;
const TERMINAL_RE = /gnome[-_. ]?terminal|org\.gnome\.terminal|ptyxis|org\.gnome\.ptyxis|kgx|org\.gnome\.console|xterm/i;

function nowSeconds() {
    return Math.floor(GLib.get_real_time() / 1000000);
}

export default class DevAutomationWorkspaceControllerExtension extends Extension {
    enable() {
        this._lastCloseRequestToken = this._readToken(CLOSE_REQUEST_PATH);
        this._lastChromesRequestToken = this._readToken(CHROMES_REQUEST_PATH);
        this._lastTerminalsRequestToken = this._readToken(TERMINALS_REQUEST_PATH);
        this._chromeSession = null;
        this._terminalSession = null;
        this._handledWindows = new Set();
        this._timeouts = new Set();

        this._windowCreatedId = global.display.connect('window-created', (_display, window) => {
            this._inspectNewWindow(window, 24);
        });

        this._controlTimer = GLib.timeout_add(GLib.PRIORITY_DEFAULT, 150, () => {
            this._pollRequests();
            return GLib.SOURCE_CONTINUE;
        });

        this._writeExtensionReady();
    }

    disable() {
        this._removeExtensionReady();

        if (this._windowCreatedId) {
            try {
                global.display.disconnect(this._windowCreatedId);
            } catch (_) {
                // Shell pode já estar desmontando o display.
            }
            this._windowCreatedId = 0;
        }
        if (this._controlTimer) {
            GLib.source_remove(this._controlTimer);
            this._controlTimer = 0;
        }
        for (const id of this._timeouts ?? [])
            GLib.source_remove(id);
        this._timeouts?.clear();
        this._timeouts = new Set();
        this._handledWindows?.clear();
        this._handledWindows = new Set();
        this._chromeSession = null;
        this._terminalSession = null;
    }

    _pollRequests() {
        const closeToken = this._readToken(CLOSE_REQUEST_PATH);
        if (closeToken && closeToken !== this._lastCloseRequestToken) {
            this._lastCloseRequestToken = closeToken;
            this._closeManagedWorkspaceWindows(closeToken);
        }

        const chromesToken = this._readToken(CHROMES_REQUEST_PATH);
        if (chromesToken && chromesToken !== this._lastChromesRequestToken) {
            this._lastChromesRequestToken = chromesToken;
            this._prepareChromes(chromesToken);
        }

        const terminalsToken = this._readToken(TERMINALS_REQUEST_PATH);
        if (terminalsToken && terminalsToken !== this._lastTerminalsRequestToken) {
            this._lastTerminalsRequestToken = terminalsToken;
            this._prepareTerminals(terminalsToken);
        }

        const now = nowSeconds();
        if (this._chromeSession && now > this._chromeSession.expiresAt)
            this._chromeSession = null;
        if (this._terminalSession && now > this._terminalSession.expiresAt) {
            this._writeTerminalResult(this._terminalSession, false);
            this._terminalSession = null;
        }
    }

    _prepareChromes(token) {
        const workspaceIndex = global.workspace_manager.get_active_workspace_index();
        const monitor = this._leftmostMonitor();
        this._chromeSession = {
            token,
            workspaceIndex,
            monitor,
            expiresAt: nowSeconds() + 18,
            browsers: 0,
            nautilus: 0,
        };

        try {
            GLib.mkdir_with_parents(STATE_DIR, 0o700);
            GLib.file_set_contents(
                CHROMES_READY_PATH,
                `${token}\tworkspace=${workspaceIndex + 1}\tmonitor=${monitor}\n`
            );
            this._writeChromeResult();
        } catch (error) {
            console.error(`[workspace-controller] falha ao preparar chromes: ${error}`);
        }
    }

    _prepareTerminals(token) {
        const totalWorkspaces = global.workspace_manager.n_workspaces;
        const monitor = this._rightmostMonitor();
        // Workspace 1 (índice 0) é LAZER. Terminais automáticos pertencem apenas
        // aos workspaces de projeto, começando no workspace 2.
        const queue = Array.from(
            {length: Math.max(0, totalWorkspaces - 1)},
            (_value, index) => index + 1
        );
        const expected = queue.length;
        this._terminalSession = {
            token,
            monitor,
            queue,
            expected,
            placed: 0,
            expiresAt: nowSeconds() + Math.max(45, expected * 3),
        };

        try {
            GLib.mkdir_with_parents(STATE_DIR, 0o700);
            GLib.file_set_contents(
                TERMINALS_READY_PATH,
                `${token}\tcount=${expected}\tfirst_workspace=2\tmonitor=${monitor}\n`
            );
            this._writeTerminalResult(this._terminalSession, expected === 0);
            if (expected === 0)
                this._terminalSession = null;
        } catch (error) {
            console.error(`[workspace-controller] falha ao preparar terminals: ${error}`);
        }
    }

    _inspectNewWindow(window, attemptsLeft) {
        if (!window || this._handledWindows.has(window))
            return;
        if (window.get_window_type?.() !== Meta.WindowType.NORMAL)
            return;

        const now = nowSeconds();
        const terminalSession = this._terminalSession;
        if (terminalSession && now <= terminalSession.expiresAt && terminalSession.queue.length > 0 && this._isTerminal(window)) {
            const workspaceIndex = terminalSession.queue.shift();
            terminalSession.placed += 1;
            this._handledWindows.add(window);
            this._schedulePlacement(window, workspaceIndex, terminalSession.monitor, 10);
            this._writeTerminalResult(terminalSession, terminalSession.queue.length === 0);
            if (terminalSession.queue.length === 0)
                terminalSession.expiresAt = now + 3;
            return;
        }

        const chromeSession = this._chromeSession;
        if (chromeSession && now <= chromeSession.expiresAt) {
            if (this._isBrowser(window)) {
                chromeSession.browsers += 1;
                this._handledWindows.add(window);
                this._schedulePlacement(window, chromeSession.workspaceIndex, chromeSession.monitor, 10);
                this._writeChromeResult();
                return;
            }
            if (this._isNautilus(window)) {
                chromeSession.nautilus += 1;
                this._handledWindows.add(window);
                this._schedulePlacement(window, chromeSession.workspaceIndex, chromeSession.monitor, 10);
                this._writeChromeResult();
                return;
            }
        }

        // Algumas aplicações definem WM_CLASS/GTK application id alguns ciclos após
        // window-created. Reconsulta por poucos segundos, apenas durante pedidos explícitos.
        if (attemptsLeft > 0 && (this._chromeSession || this._terminalSession)) {
            const id = GLib.timeout_add(GLib.PRIORITY_DEFAULT, 100, () => {
                this._timeouts.delete(id);
                this._inspectNewWindow(window, attemptsLeft - 1);
                return GLib.SOURCE_REMOVE;
            });
            this._timeouts.add(id);
        }
    }

    _schedulePlacement(window, workspaceIndex, monitor, roundsLeft) {
        const place = () => {
            if (!window)
                return;
            try {
                const workspace = window.get_workspace?.();
                if (!workspace || workspace.index() !== workspaceIndex)
                    window.change_workspace_by_index(workspaceIndex, false);
                // Não herdar estado maximizado salvo pelo terminal. O objetivo é
                // uma janela normal no monitor direito, não uma tela inteira por projeto.
                if (window.get_maximized?.())
                    window.unmaximize(Meta.MaximizeFlags.BOTH);
                if (window.get_monitor?.() !== monitor)
                    window.move_to_monitor(monitor);
            } catch (error) {
                console.error(`[workspace-controller] falha ao posicionar janela: ${error}`);
            }
        };

        place();
        if (roundsLeft <= 0)
            return;

        const id = GLib.timeout_add(GLib.PRIORITY_DEFAULT, 180, () => {
            this._timeouts.delete(id);
            place();
            if (roundsLeft > 1)
                this._schedulePlacement(window, workspaceIndex, monitor, roundsLeft - 1);
            return GLib.SOURCE_REMOVE;
        });
        this._timeouts.add(id);
    }

    _windowIdentity(window) {
        return [
            window.get_wm_class?.(),
            window.get_wm_class_instance?.(),
            window.get_gtk_application_id?.(),
        ]
            .filter(Boolean)
            .map(value => String(value))
            .join('\n');
    }

    _isBrowser(window) {
        return BROWSER_RE.test(this._windowIdentity(window));
    }

    _isNautilus(window) {
        return NAUTILUS_RE.test(this._windowIdentity(window));
    }

    _isTerminal(window) {
        return TERMINAL_RE.test(this._windowIdentity(window));
    }

    _monitorByHorizontalEdge(rightmost) {
        const count = global.display.get_n_monitors();
        if (count <= 1)
            return 0;

        let best = 0;
        let bestX = global.display.get_monitor_geometry(0).x;
        for (let i = 1; i < count; i++) {
            const rect = global.display.get_monitor_geometry(i);
            if ((rightmost && rect.x > bestX) || (!rightmost && rect.x < bestX)) {
                best = i;
                bestX = rect.x;
            }
        }
        return best;
    }

    _leftmostMonitor() {
        return this._monitorByHorizontalEdge(false);
    }

    _rightmostMonitor() {
        return this._monitorByHorizontalEdge(true);
    }

    _writeChromeResult() {
        const session = this._chromeSession;
        if (!session)
            return;
        try {
            GLib.mkdir_with_parents(STATE_DIR, 0o700);
            GLib.file_set_contents(
                CHROMES_RESULT_PATH,
                `${session.token}\tbrowsers=${session.browsers}\tnautilus=${session.nautilus}\n`
            );
        } catch (error) {
            console.error(`[workspace-controller] falha ao gravar resultado de chromes: ${error}`);
        }
    }

    _writeTerminalResult(session, complete) {
        if (!session)
            return;
        try {
            GLib.mkdir_with_parents(STATE_DIR, 0o700);
            GLib.file_set_contents(
                TERMINALS_RESULT_PATH,
                `${session.token}\tplaced=${session.placed}\texpected=${session.expected}\tcomplete=${complete ? 1 : 0}\n`
            );
        } catch (error) {
            console.error(`[workspace-controller] falha ao gravar resultado de terminals: ${error}`);
        }
    }

    _writeExtensionReady() {
        try {
            GLib.mkdir_with_parents(STATE_DIR, 0o700);
            GLib.file_set_contents(
                EXTENSION_READY_PATH,
                `version=${EXTENSION_VERSION}\ncontroller=1\nfloating-label=0\nwindow-placement=1\n`
            );
        } catch (error) {
            console.error(`[workspace-controller] falha no self-check da extensão: ${error}`);
        }
    }

    _removeExtensionReady() {
        try {
            GLib.unlink(EXTENSION_READY_PATH);
        } catch (_) {
            // Arquivo pode não existir durante primeiro enable/disable.
        }
    }

    _readToken(path) {
        try {
            const [ok, bytes] = GLib.file_get_contents(path);
            if (!ok)
                return '';
            const text = new TextDecoder('utf-8').decode(bytes).trim();
            return text.split(/[\t\n]/, 1)[0] || '';
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

        // Confirma o pedido antes de fechar as janelas. Assim, se desktops --close
        // foi chamado dentro de um workspace gerenciado, o terminal recebe a
        // confirmação antes de sua própria janela ser solicitada para fechamento.
        try {
            GLib.mkdir_with_parents(STATE_DIR, 0o700);
            GLib.file_set_contents(CLOSE_RESULT_PATH, `solicitadas=${targets.length} ignoradas=${skipped}\n`);
            GLib.file_set_contents(CLOSE_READY_PATH, `${token}\n`);
        } catch (error) {
            console.error(`[workspace-controller] falha ao confirmar desktops --close: ${error}`);
            return;
        }

        GLib.idle_add(GLib.PRIORITY_DEFAULT_IDLE, () => {
            const timestamp = global.get_current_time();
            for (const window of targets) {
                try {
                    window.delete(timestamp);
                } catch (error) {
                    console.error(`[workspace-controller] falha ao fechar janela: ${error}`);
                }
            }
            return GLib.SOURCE_REMOVE;
        });
    }
}
