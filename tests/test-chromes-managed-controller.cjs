#!/usr/bin/env node
'use strict';
// Executa o controlador real com janelas/GLib simulados, sem sessão gráfica.
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const source = fs.readFileSync(path.join(__dirname, '../apps/desktops-gnome-extension/extension.js'), 'utf8')
    .replace(/^import .*;\s*$/gm, '')
    .replace('export default class ', 'class ');
let tests = 0;
function environment() {
    const files = new Map();
    const timers = new Map();
    const state = {windows: [], active: 0, primaryOnly: false, writesFail: false, timer: 0, moves: []};
    const base = '/fake/.local/state/dev-automation/desktops/';
    const put = (name, text) => files.set(base + name, text);
    const read = name => files.get(base + name);
    files.set('/proc/self/stat', `500 (gnome-shell) ${['S', ...Array(18).fill('0'), '12345'].join(' ')}`);
    files.set('/proc/sys/kernel/random/boot_id', 'boot-one\n');
    const GLib = {
        build_filenamev: xs => xs.join('/'), get_home_dir: () => '/fake',
        get_real_time: () => Date.now() * 1000, mkdir_with_parents() {},
        file_test: name => files.has(name), FileTest: {EXISTS: 1},
        file_get_contents(name) {
            if (!files.has(name)) throw Error('ENOENT');
            return [true, new TextEncoder().encode(files.get(name))];
        },
        file_set_contents(name, text) {
            if (state.writesFail && name.endsWith('chromes.batch.json')) throw Error('disk full');
            files.set(name, text); return true;
        },
        timeout_add(_priority, _ms, fn) { const id = ++state.timer; timers.set(id, fn); return id; },
        source_remove: id => timers.delete(id), unlink: name => files.delete(name),
        PRIORITY_DEFAULT: 0, SOURCE_REMOVE: false, SOURCE_CONTINUE: true,
    };
    const global = {
        get_window_actors: () => state.windows.map(meta_window => ({meta_window})),
        get_current_time: () => 1,
        workspace_manager: {
            n_workspaces: 6,
            get_active_workspace_index: () => state.active,
            get_workspace_by_index: index => ({activate() { state.active = index; }}),
        },
        display: {
            get_n_monitors: () => 3,
            // Índices de monitores não são necessariamente a ordem horizontal.
            get_monitor_geometry: i => ({x: [1000, 2000, 0][i]}),
        },
    };
    const context = vm.createContext({GLib, Meta: {WindowType: {NORMAL: 0}, MaximizeFlags: {BOTH: 3},
        prefs_get_workspaces_only_on_primary: () => state.primaryOnly}, global, Extension: class {},
        console: {error() {}}, TextDecoder, TextEncoder, Date});
    vm.runInContext(source + '\nglobalThis.Controller = DevAutomationWorkspaceControllerExtension;', context);
    function controller() {
        const c = new context.Controller();
        c._timeouts = new Set(); c._handledWindows = new Set(); c._chromeSession = null; c._terminalSession = null;
        return c;
    }
    function window(sequence, workspace, kind = 'Google-chrome', profile = 'Default') {
        const w = {sequence, workspace, monitor: 0, maximized: false, profile, tabs: ['untouched'], blocked: false,
            get_window_type: () => 0, get_stable_sequence: () => sequence, get_wm_class: () => kind,
            get_title: () => 'ChatGPT — generic title', get_workspace() { return {index: () => this.workspace}; },
            get_monitor() { return this.monitor; }, is_maximized() { return this.maximized; },
            is_on_all_workspaces: () => false,
            change_workspace_by_index(index) { state.moves.push([sequence, 'workspace', index]); if (!this.blocked) this.workspace = index; },
            move_to_monitor(index) { state.moves.push([sequence, 'monitor', index]); if (!this.blocked) this.monitor = index; },
            maximize() { state.moves.push([sequence, 'maximize']); this.maximized = true; },
            delete() { throw Error('PROIBIDO fechar janela'); },
        };
        state.windows.push(w); return w;
    }
    function drain() {
        let guard = 1000;
        while (timers.size && guard-- > 0) {
            const [id, fn] = timers.entries().next().value; timers.delete(id); fn();
        }
        assert.ok(guard > 0, 'timeout infinito');
    }
    let serial = 0;
    function request(c, action, extra = {}) {
        c._lastChromesRequestToken = `test-${++serial}`;
        c._prepareChromes(c._lastChromesRequestToken, {action, ...extra}); drain();
        const data = read('chromes.ready') || '';
        return Object.fromEntries(data.trim().split('\t').slice(1).map(s => s.split('=')));
    }
    function result() {
        return Object.fromEntries((read('chromes.result') || '').trim().split('\t').slice(1).map(s => s.split('=')));
    }
    put('chromes.plan', 'bots/a\t2\t1\norgs/b\t3\t2\n');
    return {state, files, put, read, controller, window, drain, request, result};
}
function test(name, fn) { fn(); tests++; console.log(`OK: ${name}`); }

test('captura por projeto, confirmação real e fim da captura no limite esperado', () => {
    const e = environment(), c = e.controller();
    assert.equal(e.request(c, 'status').missing, '3');
    assert.equal(e.request(c, 'status').untracked, '0');
    assert.equal(e.state.moves.length, 0);
    assert.equal(e.request(c, 'default', {project: 'bots/a', expected: '1', workspace: '2', maximize: '1'}).valid, '1');
    c._inspectNewWindow(e.window(10, 4, 'org.gnome.Nautilus'), 0);
    assert.equal(c._chromeSession.captured, 0);
    const a = e.window(101, 4); c._inspectNewWindow(a, 0); e.drain();
    assert.equal(e.result().browsers, '1');
    assert.equal(c._chromeSession, null);
    assert.equal(a.workspace, 1); assert.equal(a.monitor, 2); assert.ok(a.maximized);
    const leisure = e.window(9, 0);
    const manual = e.window(999, 0); c._inspectNewWindow(manual, 0);
    assert.equal(JSON.parse(e.read('chromes.batch.json')).windows.length, 1);
    assert.equal(leisure.workspace, 0); assert.equal(manual.workspace, 0);
    assert.equal(e.request(c, 'default', {project: 'orgs/b', expected: '2', workspace: '3', maximize: '1'}).valid, '1');
    c._inspectNewWindow(leisure, 0); c._inspectNewWindow(a, 0);
    assert.equal(c._chromeSession.captured, 0);
    const b1 = e.window(102, 4), b2 = e.window(103, 5, 'Google-chrome', 'Profile 3');
    c._inspectNewWindow(b1, 0); c._inspectNewWindow(b2, 0); e.drain();
    assert.equal(e.result().browsers, '2');
    assert.equal(e.request(c, 'status').managed, '3');
    assert.equal(e.request(c, 'default', {project: 'orgs/b', expected: '2', workspace: '3'}).valid, '0');
    assert.equal(b2.profile, 'Profile 3'); assert.deepEqual(b2.tabs, ['untouched']);
});

test('suspensão e re-enable: restaura por chave, mesmo com todas as posições trocadas', () => {
    const e = environment(); let c = e.controller();
    const a = e.window(201, 1), b1 = e.window(202, 2), b2 = e.window(203, 2);
    assert.equal(e.request(c, 'register').valid, '1');
    assert.equal(e.state.moves.length, 0, 'registro não move janelas');
    a.workspace = 0; b1.workspace = 4; b2.workspace = 3;
    c = e.controller(); // Nova instância, mesmo processo/sessão: usa o disco.
    assert.equal(e.request(c, 'status').managed, '3');
    e.request(c, 'reconcile');
    assert.equal(e.result().complete, '1'); assert.equal(e.result().placed, '3');
    assert.equal(a.workspace, 1); assert.equal(b1.workspace, 2); assert.equal(b2.workspace, 2);
    assert.ok([a, b1, b2].every(w => w.monitor === 2 && w.maximized));
    e.put('chromes.plan', 'orgs/b\t2\t2\nbots/a\t3\t1\n');
    e.request(c, 'reconcile');
    assert.equal(a.workspace, 2); assert.equal(b1.workspace, 1); assert.equal(b2.workspace, 1);
    assert.deepEqual(a.tabs, ['untouched']);
});

test('lote parcial mantém a identidade e ignora Chrome manual/terminal', () => {
    const e = environment(), c = e.controller();
    const a = e.window(301, 1), b1 = e.window(302, 2), b2 = e.window(303, 2);
    e.request(c, 'register');
    e.state.windows = e.state.windows.filter(w => w !== b1);
    a.workspace = 4; b2.workspace = 4;
    const manual = e.window(399, 3), terminal = e.window(398, 4, 'org.gnome.Terminal');
    const status = e.request(c, 'status');
    assert.equal(status.managed, '2'); assert.equal(status.missing, '1'); assert.equal(status.untracked, '1');
    e.request(c, 'reconcile');
    assert.equal(a.workspace, 1); assert.equal(b2.workspace, 2);
    assert.equal(manual.workspace, 3); assert.equal(terminal.workspace, 4);
    assert.equal(manual.maximized, false); assert.equal(terminal.maximized, false);
});

test('janelas antigas não são adotadas silenciosamente pela ordem atual', () => {
    const e = environment(), c = e.controller();
    e.window(401, 2); e.window(402, 1); e.window(403, 1);
    assert.equal(e.request(c, 'status').untracked, '3');
    assert.equal(e.request(c, 'default', {project: 'bots/a', expected: '1', workspace: '2'}).valid, '0');
    assert.equal(e.request(c, 'register').valid, '0', 'contagem errada deve impedir registro');
    assert.equal(e.read('chromes.batch.json'), undefined); assert.equal(e.state.moves.length, 0);
});

test('janelas sem vínculo restauradas todas no LAZER impedem duplicatas', () => {
    const e = environment(), c = e.controller();
    e.window(451, 0); e.window(452, 0); e.window(453, 0);
    const status = e.request(c, 'status');
    assert.equal(status.managed, '0'); assert.equal(status.untracked, '3');
    assert.equal(e.request(c, 'default', {project: 'bots/a', expected: '1', workspace: '2'}).valid, '0');
    assert.equal(e.state.moves.length, 0);
});

test('boot/sessão diferente não reutiliza IDs antigos, nem mesmo com PID igual', () => {
    const e = environment(), c = e.controller();
    e.window(501, 1); e.window(502, 2); e.window(503, 2); e.request(c, 'register');
    e.files.set('/proc/sys/kernel/random/boot_id', 'different-boot\n');
    const status = e.request(e.controller(), 'status');
    assert.equal(status.managed, '0'); assert.equal(status.untracked, '3');
    assert.equal(e.state.moves.length, 0);
});

test('estado corrompido e plano inválido falham sem alterar janelas', () => {
    const e = environment(), c = e.controller();
    e.window(601, 1); e.window(602, 2); e.window(603, 2); e.request(c, 'register');
    const registry = JSON.parse(e.read('chromes.batch.json'));
    registry.windows.push(registry.windows[0]); e.put('chromes.batch.json', JSON.stringify(registry));
    assert.equal(e.request(c, 'reconcile').valid, '0');
    e.put('chromes.plan', 'bots/a\t2\t1\nbots/a\t3\t1\n');
    assert.equal(e.request(c, 'reconcile').valid, '0');
    assert.equal(e.state.moves.length, 0);
});

test('posição não confirmada e workspace-só-no-principal não fingem sucesso', () => {
    const e = environment(), c = e.controller();
    const a = e.window(701, 1); e.window(702, 2); e.window(703, 2); e.request(c, 'register');
    a.workspace = 4; a.blocked = true;
    e.request(c, 'reconcile');
    assert.equal(e.result().complete, '0'); assert.equal(e.result().placed, '2');
    e.state.primaryOnly = true;
    assert.equal(e.request(c, 'reconcile').valid, '0');
});

test('falha na persistência bloqueia confirmação da nova janela', () => {
    const e = environment(), c = e.controller();
    e.request(c, 'default', {project: 'bots/a', expected: '1', workspace: '2', maximize: '1'});
    e.state.writesFail = true;
    const a = e.window(801, 4); c._inspectNewWindow(a, 0); e.drain();
    assert.equal(e.result().browsers, '0'); assert.equal(a.workspace, 4);
    assert.equal(e.read('chromes.batch.json'), undefined);
});

test('nova requisição cancela reposicionamento pendente do pedido anterior', () => {
    const e = environment(), c = e.controller();
    e.window(901, 1); e.window(902, 2); e.window(903, 2); e.request(c, 'register');
    c._lastChromesRequestToken = 'old';
    c._prepareChromes('old', {action: 'reconcile'});
    c._lastChromesRequestToken = 'new';
    const before = e.state.moves.length; e.drain();
    assert.equal(e.state.moves.length, before);
});


test('LAZER pode fazer parte do plano gerenciado sem duplicar na reexecução', () => {
    const e = environment(), c = e.controller();
    e.put('chromes.plan', '@lazer\t1\t1\nbots/a\t2\t1\norgs/b\t3\t2\n');
    assert.equal(e.request(c, 'status').missing, '4');
    assert.equal(e.request(c, 'default', {project: '@lazer', expected: '1', workspace: '1', maximize: '1'}).valid, '1');
    const leisure = e.window(1001, 4); c._inspectNewWindow(leisure, 0); e.drain();
    assert.equal(leisure.workspace, 0); assert.equal(leisure.monitor, 2); assert.ok(leisure.maximized);
    assert.equal(e.request(c, 'default', {project: '@lazer', expected: '1', workspace: '1'}).valid, '0');
    assert.equal(e.request(c, 'status').managed, '1');
    assert.equal(e.request(c, 'status').missing, '3');
});

console.log(`${tests} cenários do controlador Chrome aprovados.`);
