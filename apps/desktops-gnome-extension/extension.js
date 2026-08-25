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
const TERMINALS_PROJECTS_PATH = GLib.build_filenamev([STATE_DIR, 'terminals.projects.tsv']);
const EXTENSION_READY_PATH = GLib.build_filenamev([STATE_DIR, 'extension.ready']);
const EXTENSION_VERSION = 13;

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
            this._prepareTerminals(terminalRequest.token, terminalRequest.fields);
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

    _prepareTerminals(token, fields = {}) {
        const action = fields.action || 'status';
        const projectCount = this._positiveInteger(fields.count);
        const monitor = this._rightmostMonitor();
        const target = Math.min(projectCount, Math.max(0, global.workspace_manager.n_workspaces - 1));
        const status = this._terminalStatus(target);
        if (action !== 'open')
            this._terminalSession = null;

        switch (action) {
        case 'status':
            this._writeTerminalReady(token, action, target, status, monitor);
            this._writeTerminalResult(token, status.assignments.size, status.assignments.size, true);
            return;

        case 'open': {
            const requestedProject = Number.parseInt(String(fields.project ?? ''), 10);
            if (!Number.isInteger(requestedProject) || requestedProject < 0 || requestedProject >= target) {
                this._writeTerminalReady(token, action, target, status, monitor);
                this._writeTerminalResult(token, 0, 1, false);
                return;
            }

            this._writeTerminalReady(token, action, target, status, monitor);
            if (status.assignments.has(requestedProject)) {
                // Outra janela pode ter aparecido entre status e open. Não duplica.
                this._writeTerminalResult(token, 1, 1, true);
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
                projectIndex: requestedProject,
                expected: 1,
                captured: 0,
                complete: false,
                overflowSequences: [...status.overflowSequences],
                seenSequences: existingSequences,
                expiresAt: nowSeconds() + 45,
                monitor,
            };
            this._writeTerminalResult(token, 0, 1, false);
            return;
        }

        case 'reconcile': {
            this._writeTerminalReady(token, action, target, status, monitor);
            if (status.missingIndices.length > 0) {
                this._writeTerminalResult(token, status.assignments.size, target, false);
                return;
            }

            for (const [projectIndex, window] of status.assignments)
                this._scheduleTerminalPlacement(window, projectIndex + 1, monitor, 12);

            // Somente excedentes explicitamente capturados pelo próprio lote são
            // fechados. Terminais manuais sem projeto reconhecido são preservados.
            this._closeTerminalWindows(status.overflow);
            this._writeTerminalBatch(status.assignments, []);
            this._writeTerminalResult(token, status.assignments.size, target, status.assignments.size === target);
            return;
        }

        case 'managed-reset': {
            const targets = new Set([...status.assignments.values(), ...status.overflow]);
            this._writeTerminalReady(token, action, target, status, monitor);
            this._writeTerminalResult(token, targets.size, targets.size, true);
            this._removeFile(TERMINALS_BATCH_PATH);
            this._terminalSession = null;
            this._closeTerminalWindows([...targets]);
            return;
        }

        case 'reset': {
            const targets = new Set([...status.assignments.values(), ...status.overflow]);
            for (const window of this._projectTerminalWindows(target))
                targets.add(window);
            this._writeTerminalReady(token, action, target, status, monitor);
            this._writeTerminalResult(token, targets.size, targets.size, true);
            this._removeFile(TERMINALS_BATCH_PATH);
            this._terminalSession = null;
            this._closeTerminalWindows([...targets]);
            return;
        }

        default:
            this._writeTerminalReady(token, action, target, status, monitor);
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

                const batch = this._readTerminalBatch();
                if (terminalSession.captured < terminalSession.expected) {
                    batch.projects.set(terminalSession.projectIndex, sequence);
                    terminalSession.captured += 1;
                    // Já nasce no desktop correto. A reconciliação final repete a
                    // operação para absorver ajustes assíncronos do terminal/Mutter.
                    this._scheduleTerminalPlacement(
                        window,
                        terminalSession.projectIndex + 1,
                        terminalSession.monitor,
                        12
                    );
                } else {
                    // Um backend pode criar uma janela extra. Marca somente essa
                    // janela como overflow do lote; terminais manuais não são tocados.
                    terminalSession.overflowSequences.push(sequence);
                }

                this._writeTerminalBatch(batch.projects, terminalSession.overflowSequences);
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
        const projects = this._readTerminalProjects(target);
        const batch = this._readTerminalBatch();
        const assignments = new Map();
        const usedSequences = new Set();
        const overflow = [];
        const overflowSequences = new Set();

        const assign = (projectIndex, window) => {
            if (!window || projectIndex < 0 || projectIndex >= target || assignments.has(projectIndex))
                return false;
            const sequence = this._stableSequence(window);
            if (!sequence || usedSequences.has(sequence))
                return false;
            assignments.set(projectIndex, window);
            usedSequences.add(sequence);
            return true;
        };

        // 1) Verdade principal: a pasta real exibida pelo terminal. Isso permite
        // reparar uma janela movida para o desktop errado e também adotar um
        // terminal aberto manualmente dentro da pasta de um projeto.
        for (const window of allTerminals) {
            const projectIndex = this._terminalProjectIndex(window, projects);
            if (projectIndex >= 0)
                assign(projectIndex, window);
        }

        // 2) Vínculo persistido. Necessário para lrdp1/lrdp2 (HOME não distingue
        // os dois) e como fallback quando o backend não expõe cwd/título útil.
        for (const [projectIndex, sequence] of batch.projects) {
            if (assignments.has(projectIndex))
                continue;
            const window = bySequence.get(sequence);
            if (!window || usedSequences.has(sequence))
                continue;
            const detectedProject = this._terminalProjectIndex(window, projects);
            if (detectedProject >= 0 && detectedProject !== projectIndex)
                continue; // mudou de pasta: a pasta vence o vínculo antigo.
            assign(projectIndex, window);
        }

        // 3) Upgrade transparente do formato antigo (v12): a ordem do lote era a
        // identidade. Só usamos esse fallback quando a pasta não contradiz a ordem.
        for (let projectIndex = 0; projectIndex < Math.min(target, batch.managed.length); projectIndex++) {
            if (assignments.has(projectIndex))
                continue;
            const sequence = batch.managed[projectIndex];
            const window = bySequence.get(sequence);
            if (!window || usedSequences.has(sequence))
                continue;
            const detectedProject = this._terminalProjectIndex(window, projects);
            if (detectedProject >= 0 && detectedProject !== projectIndex)
                continue;
            assign(projectIndex, window);
        }

        for (const sequence of batch.overflow) {
            const window = bySequence.get(sequence);
            if (!window || usedSequences.has(sequence) || overflowSequences.has(sequence))
                continue;
            overflow.push(window);
            overflowSequences.add(sequence);
        }

        const missingIndices = [];
        for (let projectIndex = 0; projectIndex < target; projectIndex++) {
            if (!assignments.has(projectIndex))
                missingIndices.push(projectIndex);
        }

        const untracked = this._projectTerminalWindows(target).filter(window => {
            const sequence = this._stableSequence(window);
            return !usedSequences.has(sequence) && !overflowSequences.has(sequence);
        }).length;

        // Regrava sempre no formato novo, já reparado por identidade de pasta.
        this._writeTerminalBatch(assignments, [...overflowSequences]);
        return {
            assignments,
            overflow,
            overflowSequences: [...overflowSequences],
            untracked,
            missingIndices,
        };
    }

    _readTerminalProjects(target) {
        const projects = [];
        try {
            const [ok, bytes] = GLib.file_get_contents(TERMINALS_PROJECTS_PATH);
            if (!ok)
                return projects;
            const text = new TextDecoder('utf-8').decode(bytes);
            for (const raw of text.split(/\n/)) {
                if (!raw.trim())
                    continue;
                const parts = raw.split('\t');
                if (parts.length < 3)
                    continue;
                const index = Number.parseInt(parts[0], 10);
                if (!Number.isInteger(index) || index < 0 || index >= target)
                    continue;
                const name = parts[1] || '';
                const path = parts.slice(2).join('\t').trim();
                projects.push({index, name, path: path === '-' ? '' : path.replace(/\/+$/, '')});
            }
        } catch (_) {
            return [];
        }
        return projects.sort((a, b) => b.path.length - a.path.length || a.index - b.index);
    }

    _terminalProjectIndex(window, projects) {
        const title = String(window.get_title?.() ?? '');
        let cwd = '';
        try {
            const pid = Number(window.get_pid?.() ?? 0);
            if (pid > 0)
                cwd = String(GLib.file_read_link(`/proc/${pid}/cwd`) ?? '').replace(/\/+$/, '');
        } catch (_) {
            cwd = '';
        }

        const home = GLib.get_home_dir().replace(/\/+$/, '');
        for (const project of projects) {
            const path = project.path;
            if (!path)
                continue;

            if (cwd && (cwd === path || cwd.startsWith(`${path}/`)))
                return project.index;

            const titlePaths = [path];
            if (home && path.startsWith(`${home}/`))
                titlePaths.push(`~/${path.slice(home.length + 1)}`);
            if (titlePaths.some(value => title.includes(value)))
                return project.index;
        }
        return -1;
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

    _writeTerminalReady(token, action, target, status, monitor) {
        try {
            GLib.mkdir_with_parents(STATE_DIR, 0o700);
            const managed = status.assignments.size;
            const missingIndices = status.missingIndices.join(',');
            GLib.file_set_contents(
                TERMINALS_READY_PATH,
                `${token}\taction=${action}\tcount=${target}\tmanaged=${managed}\tmissing=${status.missingIndices.length}\tmissing_indices=${missingIndices}\tuntracked=${status.untracked}\toverflow=${status.overflow.length}\tfirst_workspace=2\tmonitor=${monitor}\n`
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
                return {managed: [], projects: new Map(), overflow: []};
            const lines = new TextDecoder('utf-8').decode(bytes).split(/\n/);
            if ((lines.shift() || '').trim() !== `shell=${shell}`) {
                this._removeFile(TERMINALS_BATCH_PATH);
                return {managed: [], projects: new Map(), overflow: []};
            }

            const managed = [];
            const projects = new Map();
            const overflow = [];
            for (const raw of lines) {
                const line = raw.trim();
                if (!line)
                    continue;
                let match = line.match(/^project=(\d+):(\d+)$/);
                if (match) {
                    projects.set(Number(match[1]), Number(match[2]));
                    continue;
                }
                if (/^managed=\d+$/.test(line)) {
                    managed.push(Number(line.slice('managed='.length)));
                } else if (/^overflow=\d+$/.test(line)) {
                    overflow.push(Number(line.slice('overflow='.length)));
                } else if (/^\d+$/.test(line)) {
                    // Compatibilidade v9: números puros eram sequências gerenciadas.
                    managed.push(Number(line));
                }
            }
            return {
                managed: [...new Set(managed.filter(value => Number.isInteger(value) && value > 0))],
                projects: new Map([...projects].filter(([index, sequence]) =>
                    Number.isInteger(index) && index >= 0 && Number.isInteger(sequence) && sequence > 0)),
                overflow: [...new Set(overflow.filter(value => Number.isInteger(value) && value > 0))],
            };
        } catch (_) {
            return {managed: [], projects: new Map(), overflow: []};
        }
    }

    _writeTerminalBatch(projectAssignments, overflowSequences) {
        try {
            GLib.mkdir_with_parents(STATE_DIR, 0o700);
            const pairs = projectAssignments instanceof Map
                ? [...projectAssignments.entries()]
                : [];
            const normalizedPairs = pairs
                .map(([projectIndex, value]) => {
                    const sequence = typeof value === 'number' ? value : this._stableSequence(value);
                    return [Number(projectIndex), Number(sequence)];
                })
                .filter(([projectIndex, sequence]) =>
                    Number.isInteger(projectIndex) && projectIndex >= 0 && Number.isInteger(sequence) && sequence > 0)
                .sort((a, b) => a[0] - b[0]);
            const managedSequences = normalizedPairs.map(([, sequence]) => sequence);
            const managedSet = new Set(managedSequences);
            const overflow = [...new Set((overflowSequences ?? [])
                .map(value => Number(value))
                .filter(value => Number.isInteger(value) && value > 0 && !managedSet.has(value)))];
            const shell = this._shellProcessId();
            const rows = [
                ...normalizedPairs.map(([projectIndex, sequence]) => `project=${projectIndex}:${sequence}`),
                // Mantém as linhas managed para rollback/compatibilidade com v12.
                ...managedSequences.map(value => `managed=${value}`),
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
