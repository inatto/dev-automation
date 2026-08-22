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
const TERMINALS_BATCH_PATH = GLib.build_filenamev([STATE_DIR, 'terminals.batch']);
const EXTENSION_READY_PATH = GLib.build_filenamev([STATE_DIR, 'extension.ready']);
const EXTENSION_VERSION = 12;

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

        // O GNOME pode chamar disable()/enable() da extensão sem encerrar a sessão
        // (por exemplo em transições de modo). O lote é vinculado ao PID do próprio
        // gnome-shell: sobrevive a re-enable, mas é invalidado após logout/login.
        this._ensureTerminalBatchSession();

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

        const chromesRequest = this._readRequest(CHROMES_REQUEST_PATH);
        if (chromesRequest.token && chromesRequest.token !== this._lastChromesRequestToken) {
            this._lastChromesRequestToken = chromesRequest.token;
            this._prepareChromes(chromesRequest.token, chromesRequest.fields);
        }

        const terminalRequest = this._readRequest(TERMINALS_REQUEST_PATH);
        if (terminalRequest.token && terminalRequest.token !== this._lastTerminalsRequestToken) {
            this._lastTerminalsRequestToken = terminalRequest.token;
            this._prepareTerminals(
                terminalRequest.token,
                terminalRequest.fields.action || 'status',
                this._positiveInteger(terminalRequest.fields.count)
            );
        }

        const now = nowSeconds();
        if (this._chromeSession && now > this._chromeSession.expiresAt)
            this._chromeSession = null;
        if (this._terminalSession && now > this._terminalSession.expiresAt) {
            if (!this._terminalSession.complete) {
                this._writeTerminalResult(
                    this._terminalSession.token,
                    this._terminalSession.captured,
                    this._terminalSession.expected,
                    false
                );
            }
            this._terminalSession = null;
        }
    }

    _prepareChromes(token, fields = {}) {
        const requestedWorkspace = this._positiveInteger(fields.workspace);
        const workspaceCount = Math.max(1, global.workspace_manager.n_workspaces);
        const workspaceIndex = requestedWorkspace > 0
            ? Math.min(requestedWorkspace, workspaceCount) - 1
            : global.workspace_manager.get_active_workspace_index();
        const monitor = this._leftmostMonitor();
        const maximize = String(fields.maximize ?? '0') === '1';
        this._chromeSession = {
            token,
            workspaceIndex,
            monitor,
            maximize,
            expiresAt: nowSeconds() + 18,
            browsers: 0,
            nautilus: 0,
        };

        try {
            GLib.mkdir_with_parents(STATE_DIR, 0o700);
            GLib.file_set_contents(
                CHROMES_READY_PATH,
                `${token}\tworkspace=${workspaceIndex + 1}\tmonitor=${monitor}\tmaximize=${maximize ? 1 : 0}\n`
            );
            this._writeChromeResult();
        } catch (error) {
            console.error(`[workspace-controller] falha ao preparar chromes: ${error}`);
        }
    }

    _prepareTerminals(token, action, projectCount) {
        const monitor = this._rightmostMonitor();
        const target = Math.min(projectCount, Math.max(0, global.workspace_manager.n_workspaces - 1));
        const status = this._terminalStatus(target);
        if (action !== 'open')
            this._terminalSession = null;

        switch (action) {
        case 'status':
            this._writeTerminalReady(token, action, target, status.managed.length, status.untracked, status.overflow.length, monitor);
            this._writeTerminalResult(token, status.managed.length, status.managed.length, true);
            return;

        case 'open': {
            const missing = Math.max(0, target - status.managed.length);
            this._writeTerminalReady(token, action, target, status.managed.length, status.untracked, status.overflow.length, monitor);
            if (missing === 0) {
                this._writeTerminalResult(token, 0, 0, true);
                this._terminalSession = null;
                return;
            }

            const existingSequences = new Set(
                this._allTerminalWindows()
                    .map(window => this._stableSequence(window))
                    .filter(sequence => sequence > 0)
            );
            this._terminalSession = {
                token,
                target,
                expected: missing,
                captured: 0,
                complete: false,
                managedSequences: status.managed.map(window => this._stableSequence(window)),
                overflowSequences: status.overflow.map(window => this._stableSequence(window)),
                seenSequences: existingSequences,
                expiresAt: nowSeconds() + Math.max(45, missing * 5),
            };
            this._writeTerminalResult(token, 0, missing, false);
            return;
        }

        case 'reconcile': {
            const missing = Math.max(0, target - status.managed.length);
            this._writeTerminalReady(token, action, target, status.managed.length, status.untracked, status.overflow.length, monitor);
            if (missing > 0) {
                this._writeTerminalResult(token, status.managed.length, target, false);
                return;
            }

            const assignments = this._terminalAssignments(status.managed, target);
            for (const [workspaceIndex, window] of assignments)
                this._scheduleTerminalPlacement(window, workspaceIndex, monitor, 12);

            // Fecha apenas excedentes comprovadamente criados pelo lote. Terminais
            // manuais não gerenciados continuam preservados.
            this._closeTerminalWindows(status.overflow);
            this._writeTerminalBatch(
                assignments.map(([, window]) => this._stableSequence(window)),
                []
            );
            this._writeTerminalResult(token, assignments.length, target, assignments.length === target);
            return;
        }

        case 'managed-reset': {
            // Usado automaticamente quando a lista/ordem de projetos muda.
            // Fecha SOMENTE o lote que o próprio `terminals` gerencia; terminais
            // manuais existentes nos workspaces continuam intocados.
            const targets = new Set([...status.managed, ...status.overflow]);
            this._writeTerminalReady(token, action, target, status.managed.length, status.untracked, status.overflow.length, monitor);
            this._writeTerminalResult(token, targets.size, targets.size, true);
            this._removeFile(TERMINALS_BATCH_PATH);
            this._terminalSession = null;
            this._closeTerminalWindows([...targets]);
            return;
        }

        case 'reset': {
            const targets = new Set([...status.managed, ...status.overflow]);
            for (const window of this._projectTerminalWindows(target))
                targets.add(window);
            this._writeTerminalReady(token, action, target, status.managed.length, status.untracked, status.overflow.length, monitor);
            this._writeTerminalResult(token, targets.size, targets.size, true);
            this._removeFile(TERMINALS_BATCH_PATH);
            this._terminalSession = null;
            this._closeTerminalWindows([...targets]);
            return;
        }

        default:
            this._writeTerminalReady(token, action, target, status.managed.length, status.untracked, status.overflow.length, monitor);
            this._writeTerminalResult(token, 0, target, false);
        }
    }

    _inspectNewWindow(window, attemptsLeft) {
        if (!window || this._handledWindows.has(window))
            return;
        if (window.get_window_type?.() !== Meta.WindowType.NORMAL)
            return;

        const now = nowSeconds();
        const terminalSession = this._terminalSession;
        if (terminalSession && now <= terminalSession.expiresAt && this._isTerminal(window)) {
            const sequence = this._stableSequence(window);
            if (sequence && !terminalSession.seenSequences.has(sequence)) {
                terminalSession.seenSequences.add(sequence);
                this._handledWindows.add(window);

                if (terminalSession.captured < terminalSession.expected) {
                    terminalSession.managedSequences.push(sequence);
                    terminalSession.captured += 1;
                } else {
                    // Ptyxis pode criar mais de uma janela durante uma inicialização
                    // concorrente. O excedente fica marcado para fechamento seguro na
                    // próxima fase, em vez de ser deixado espalhado pelos workspaces.
                    terminalSession.overflowSequences.push(sequence);
                }

                this._writeTerminalBatch(
                    terminalSession.managedSequences,
                    terminalSession.overflowSequences
                );
                terminalSession.complete = terminalSession.captured >= terminalSession.expected;
                this._writeTerminalResult(
                    terminalSession.token,
                    terminalSession.captured,
                    terminalSession.expected,
                    terminalSession.complete
                );
                if (terminalSession.complete)
                    terminalSession.expiresAt = now + 4;
                return;
            }
        }

        const chromeSession = this._chromeSession;
        if (chromeSession && now <= chromeSession.expiresAt) {
            if (this._isBrowser(window)) {
                chromeSession.browsers += 1;
                this._handledWindows.add(window);
                this._schedulePlacement(window, chromeSession.workspaceIndex, chromeSession.monitor, 10, chromeSession.maximize);
                this._writeChromeResult();
                return;
            }
            if (this._isNautilus(window)) {
                chromeSession.nautilus += 1;
                this._handledWindows.add(window);
                this._schedulePlacement(window, chromeSession.workspaceIndex, chromeSession.monitor, 10, chromeSession.maximize);
                this._writeChromeResult();
                return;
            }
        }

        // Algumas aplicações definem WM_CLASS/GTK application id alguns ciclos após
        // window-created. Reconsulta por poucos segundos apenas durante pedidos explícitos.
        if (attemptsLeft > 0 && (this._chromeSession || this._terminalSession)) {
            const id = GLib.timeout_add(GLib.PRIORITY_DEFAULT, 100, () => {
                this._timeouts.delete(id);
                this._inspectNewWindow(window, attemptsLeft - 1);
                return GLib.SOURCE_REMOVE;
            });
            this._timeouts.add(id);
        }
    }

    _terminalStatus(target) {
        const allTerminals = this._allTerminalWindows();
        const bySequence = new Map(allTerminals.map(window => [this._stableSequence(window), window]));
        const batch = this._readTerminalBatch();
        const managed = [];
        const overflow = [];
        const managedSet = new Set();
        const overflowSet = new Set();

        for (const sequence of batch.managed) {
            const window = bySequence.get(sequence);
            if (!window)
                continue;
            if (managed.length < target) {
                managed.push(window);
                managedSet.add(sequence);
            } else if (!overflowSet.has(sequence)) {
                overflow.push(window);
                overflowSet.add(sequence);
            }
        }
        for (const sequence of batch.overflow) {
            const window = bySequence.get(sequence);
            if (!window || managedSet.has(sequence) || overflowSet.has(sequence))
                continue;
            overflow.push(window);
            overflowSet.add(sequence);
        }

        // Somente janelas capturadas explicitamente pelo lote de `terminals`
        // podem ser gerenciadas. Um terminal manual já aberto em algum workspace
        // nunca conta como projeto, pois isso deslocava toda a lista em +1/-1.

        this._writeTerminalBatch(
            managed.map(window => this._stableSequence(window)),
            overflow.map(window => this._stableSequence(window))
        );
        const untracked = this._projectTerminalWindows(target)
            .filter(window => {
                const sequence = this._stableSequence(window);
                return !managedSet.has(sequence) && !overflowSet.has(sequence);
            }).length;
        return {managed, overflow, untracked};
    }

    _terminalAssignments(managed, target) {
        // `managed` já vem na ordem persistida pelo lote, que é exatamente a
        // ordem em que terminals.sh abriu os projetos. Workspace do GNOME é
        // zero-based: índice 0 = LAZER; projeto 0 = workspace índice 1.
        // Nunca inferimos a identidade do projeto pela posição atual da janela.
        return managed
            .slice(0, target)
            .map((window, projectIndex) => [projectIndex + 1, window]);
    }

    _allTerminalWindows() {
        const windows = [];
        for (const actor of global.get_window_actors()) {
            const window = actor.meta_window;
            if (!window || window.get_window_type?.() !== Meta.WindowType.NORMAL)
                continue;
            if (window.is_on_all_workspaces?.())
                continue;
            if (this._isTerminal(window))
                windows.push(window);
        }
        return windows;
    }

    _projectTerminalWindows(target) {
        return this._allTerminalWindows().filter(window => {
            const workspace = window.get_workspace?.();
            const index = workspace?.index?.() ?? -1;
            return index >= 1 && index <= target;
        });
    }

    _schedulePlacement(window, workspaceIndex, monitor, roundsLeft, maximize = false) {
        const place = () => {
            if (!window)
                return;
            try {
                const workspace = window.get_workspace?.();
                if (!workspace || workspace.index() !== workspaceIndex)
                    window.change_workspace_by_index(workspaceIndex, false);
                if (!maximize && (window.get_maximize_flags?.() ?? 0) !== 0)
                    window.unmaximize(Meta.MaximizeFlags.BOTH);
                if (window.get_monitor?.() !== monitor)
                    window.move_to_monitor(monitor);
                if (maximize && !window.is_maximized?.())
                    window.maximize();
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
                this._schedulePlacement(window, workspaceIndex, monitor, roundsLeft - 1, maximize);
            return GLib.SOURCE_REMOVE;
        });
        this._timeouts.add(id);
    }

    _scheduleTerminalPlacement(window, workspaceIndex, monitor, roundsLeft) {
        const place = () => {
            if (!window)
                return;
            try {
                const workspace = window.get_workspace?.();
                if (!workspace || workspace.index() !== workspaceIndex)
                    window.change_workspace_by_index(workspaceIndex, false);
                if (window.get_monitor?.() !== monitor)
                    window.move_to_monitor(monitor);
                // GNOME/Mutter 49+ usa maximize() sem MaximizeFlags, igual ao
                // controlador estável do pycharms neste mesmo projeto.
                if (!window.is_maximized?.())
                    window.maximize();
            } catch (error) {
                console.error(`[workspace-controller] falha ao posicionar/maximizar terminal: ${error}`);
            }
        };

        place();
        if (roundsLeft <= 0)
            return;
        const id = GLib.timeout_add(GLib.PRIORITY_DEFAULT, 180, () => {
            this._timeouts.delete(id);
            place();
            if (roundsLeft > 1)
                this._scheduleTerminalPlacement(window, workspaceIndex, monitor, roundsLeft - 1);
            return GLib.SOURCE_REMOVE;
        });
        this._timeouts.add(id);
    }

    _closeTerminalWindows(windows) {
        if (!windows || windows.length === 0)
            return;
        GLib.idle_add(GLib.PRIORITY_DEFAULT_IDLE, () => {
            const timestamp = global.get_current_time();
            for (const window of windows) {
                try {
                    if (window?.can_close?.() !== false)
                        window.delete(timestamp);
                } catch (error) {
                    console.error(`[workspace-controller] falha ao fechar terminal excedente: ${error}`);
                }
            }
            return GLib.SOURCE_REMOVE;
        });
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

    _stableSequence(window) {
        try {
            return Number(window.get_stable_sequence?.() ?? 0);
        } catch (_) {
            return 0;
        }
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

    _writeTerminalReady(token, action, target, managed, untracked, overflow, monitor) {
        try {
            GLib.mkdir_with_parents(STATE_DIR, 0o700);
            const missing = Math.max(0, target - managed);
            GLib.file_set_contents(
                TERMINALS_READY_PATH,
                `${token}\taction=${action}\tcount=${target}\tmanaged=${managed}\tmissing=${missing}\tuntracked=${untracked}\toverflow=${overflow}\tfirst_workspace=2\tmonitor=${monitor}\n`
            );
        } catch (error) {
            console.error(`[workspace-controller] falha ao preparar terminals: ${error}`);
        }
    }

    _writeTerminalResult(token, placed, expected, complete) {
        try {
            GLib.mkdir_with_parents(STATE_DIR, 0o700);
            GLib.file_set_contents(
                TERMINALS_RESULT_PATH,
                `${token}\tplaced=${placed}\texpected=${expected}\tcomplete=${complete ? 1 : 0}\n`
            );
        } catch (error) {
            console.error(`[workspace-controller] falha ao gravar resultado de terminals: ${error}`);
        }
    }

    _shellProcessId() {
        try {
            const [ok, bytes] = GLib.file_get_contents('/proc/self/stat');
            if (!ok)
                return 'unknown';
            return new TextDecoder('utf-8').decode(bytes).trim().split(/\s+/, 1)[0] || 'unknown';
        } catch (_) {
            return 'unknown';
        }
    }

    _ensureTerminalBatchSession() {
        const shell = this._shellProcessId();
        try {
            GLib.mkdir_with_parents(STATE_DIR, 0o700);
            const [ok, bytes] = GLib.file_get_contents(TERMINALS_BATCH_PATH);
            if (ok) {
                const first = new TextDecoder('utf-8').decode(bytes).split(/\n/, 1)[0].trim();
                if (first === `shell=${shell}`)
                    return;
            }
            GLib.file_set_contents(TERMINALS_BATCH_PATH, `shell=${shell}\n`);
        } catch (_) {
            try {
                GLib.file_set_contents(TERMINALS_BATCH_PATH, `shell=${shell}\n`);
            } catch (error) {
                console.error(`[workspace-controller] falha ao inicializar lote de terminals: ${error}`);
            }
        }
    }

    _readTerminalBatch() {
        const shell = this._shellProcessId();
        try {
            const [ok, bytes] = GLib.file_get_contents(TERMINALS_BATCH_PATH);
            if (!ok)
                return {managed: [], overflow: []};
            const lines = new TextDecoder('utf-8').decode(bytes).split(/\n/);
            if ((lines.shift() || '').trim() !== `shell=${shell}`) {
                this._removeFile(TERMINALS_BATCH_PATH);
                return {managed: [], overflow: []};
            }

            const managed = [];
            const overflow = [];
            for (const raw of lines) {
                const line = raw.trim();
                if (!line)
                    continue;
                if (/^managed=\d+$/.test(line)) {
                    managed.push(Number(line.slice('managed='.length)));
                } else if (/^overflow=\d+$/.test(line)) {
                    overflow.push(Number(line.slice('overflow='.length)));
                } else if (/^\d+$/.test(line)) {
                    // Compatibilidade com o formato v9: números puros eram
                    // sequências gerenciadas.
                    managed.push(Number(line));
                }
            }
            return {
                managed: [...new Set(managed.filter(value => Number.isInteger(value) && value > 0))],
                overflow: [...new Set(overflow.filter(value => Number.isInteger(value) && value > 0))],
            };
        } catch (_) {
            return {managed: [], overflow: []};
        }
    }

    _writeTerminalBatch(managedSequences, overflowSequences) {
        try {
            GLib.mkdir_with_parents(STATE_DIR, 0o700);
            const managed = [...new Set(managedSequences.filter(value => Number.isInteger(value) && value > 0))];
            const overflow = [...new Set(overflowSequences.filter(value => Number.isInteger(value) && value > 0))]
                .filter(value => !managed.includes(value));
            const shell = this._shellProcessId();
            const rows = [
                ...managed.map(value => `managed=${value}`),
                ...overflow.map(value => `overflow=${value}`),
            ];
            const body = rows.length ? `${rows.join('\n')}\n` : '';
            GLib.file_set_contents(TERMINALS_BATCH_PATH, `shell=${shell}\n${body}`);
        } catch (error) {
            console.error(`[workspace-controller] falha ao persistir lote de terminals: ${error}`);
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
        this._removeFile(EXTENSION_READY_PATH);
    }

    _removeFile(path) {
        try {
            GLib.unlink(path);
        } catch (_) {
            // Arquivo pode não existir.
        }
    }

    _readToken(path) {
        return this._readRequest(path).token;
    }

    _readRequest(path) {
        try {
            const [ok, bytes] = GLib.file_get_contents(path);
            if (!ok)
                return {token: '', fields: {}};
            const text = new TextDecoder('utf-8').decode(bytes).trim();
            const parts = text.split(/[\t\n]/).filter(Boolean);
            const token = parts.shift() || '';
            const fields = {};
            for (const part of parts) {
                const pos = part.indexOf('=');
                if (pos > 0)
                    fields[part.slice(0, pos)] = part.slice(pos + 1);
            }
            return {token, fields};
        } catch (_) {
            return {token: '', fields: {}};
        }
    }

    _positiveInteger(value) {
        const parsed = Number.parseInt(String(value ?? ''), 10);
        return Number.isInteger(parsed) && parsed >= 0 ? parsed : 0;
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
