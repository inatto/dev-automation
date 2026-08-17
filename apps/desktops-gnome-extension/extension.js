import Clutter from 'gi://Clutter';
import Meta from 'gi://Meta';
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import St from 'gi://St';

import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import * as PanelMenu from 'resource:///org/gnome/shell/ui/panelMenu.js';

const STATE_DIR = GLib.build_filenamev([
    GLib.get_home_dir(), '.local', 'state', 'dev-automation', 'desktops',
]);
const CLOSE_REQUEST_PATH = GLib.build_filenamev([STATE_DIR, 'close.request']);
const CLOSE_READY_PATH = GLib.build_filenamev([STATE_DIR, 'close.ready']);
const CLOSE_RESULT_PATH = GLib.build_filenamev([STATE_DIR, 'close.result']);
const UI_READY_PATH = GLib.build_filenamev([STATE_DIR, 'ui.ready']);
const UI_VERSION = 3;
const OVERVIEW_ROWS = 2;

export default class DevAutomationWorkspaceNameExtension extends Extension {
    enable() {
        this._workspaceManager = global.workspace_manager;
        this._settings = new Gio.Settings({schema_id: 'org.gnome.desktop.wm.preferences'});
        this._idleId = 0;
        this._overviewLayoutIdleId = 0;
        this._lastCloseRequestToken = this._readCloseRequestToken();
        this._overviewVisible = false;
        this._overviewButtons = [];
        this._overviewBadges = [];

        this._createPanelIndicator();
        this._createWorkspaceOsd();
        this._createOverviewUi();

        this._workspaceSignalId = this._workspaceManager.connect(
            'active-workspace-changed',
            () => this._onActiveWorkspaceChanged()
        );
        this._workspaceCountSignalId = this._workspaceManager.connect(
            'notify::n-workspaces',
            () => this._rebuildOverviewUi()
        );
        this._settingsSignalId = this._settings.connect(
            'changed::workspace-names',
            () => this._rebuildOverviewUi()
        );
        this._overviewShowingId = Main.overview.connect('showing', () => {
            this._setOverviewVisible(true);
        });
        this._overviewHidingId = Main.overview.connect('hiding', () => {
            this._setOverviewVisible(false);
        });
        this._monitorsChangedId = Main.layoutManager.connect('monitors-changed', () => {
            this._rebuildOverviewBadges();
            this._queueOverviewLayout();
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
        this._setOverviewVisible(Boolean(Main.overview.visible));
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
        if (this._overviewShowingId) {
            Main.overview.disconnect(this._overviewShowingId);
            this._overviewShowingId = 0;
        }
        if (this._overviewHidingId) {
            Main.overview.disconnect(this._overviewHidingId);
            this._overviewHidingId = 0;
        }
        if (this._monitorsChangedId) {
            Main.layoutManager.disconnect(this._monitorsChangedId);
            this._monitorsChangedId = 0;
        }
        if (this._idleId) {
            GLib.source_remove(this._idleId);
            this._idleId = 0;
        }
        if (this._overviewLayoutIdleId) {
            GLib.source_remove(this._overviewLayoutIdleId);
            this._overviewLayoutIdleId = 0;
        }
        if (this._controlTimer) {
            GLib.source_remove(this._controlTimer);
            this._controlTimer = 0;
        }

        this._label?.remove_all_transitions();
        this._label?.destroy();
        this._label = null;

        this._panelButton?.destroy();
        this._panelButton = null;
        this._panelLabel = null;

        this._overviewGrid?.destroy();
        this._overviewGrid = null;
        this._overviewButtons = [];

        for (const badge of this._overviewBadges)
            badge.destroy();
        this._overviewBadges = [];

        this._settings = null;
        this._workspaceManager = null;
    }

    _createPanelIndicator() {
        this._panelButton = new PanelMenu.Button(0.0, 'Workspace atual', true);
        this._panelButton.add_style_class_name('dev-automation-workspace-panel');
        this._panelLabel = new St.Label({
            style_class: 'dev-automation-workspace-panel-label',
            y_align: Clutter.ActorAlign.CENTER,
        });
        this._panelButton.add_child(this._panelLabel);
        Main.panel.addToStatusArea(this.uuid, this._panelButton, 0, 'left');
    }

    _createWorkspaceOsd() {
        this._label = new St.Label({
            style_class: 'dev-automation-workspace-name',
            opacity: 0,
            reactive: false,
        });
        Main.uiGroup.add_child(this._label);
    }

    _createOverviewUi() {
        this._overviewGrid = new St.BoxLayout({
            vertical: true,
            style_class: 'dev-automation-workspace-overview-grid',
            reactive: true,
            visible: false,
        });
        Main.uiGroup.add_child(this._overviewGrid);
        this._rebuildOverviewGrid();
        this._rebuildOverviewBadges();
    }

    _workspaceInfo(index = this._workspaceManager.get_active_workspace_index()) {
        const names = this._settings.get_strv('workspace-names');
        const name = names[index] || `Desktop ${index + 1}`;
        return {index, name, title: `${index + 1}  ${name}`};
    }

    _onActiveWorkspaceChanged() {
        this._updateWorkspaceUi();
        this._showActiveWorkspaceName();
    }

    _updateWorkspaceUi() {
        if (!this._workspaceManager || !this._settings)
            return;

        const {index, title} = this._workspaceInfo();
        if (this._panelLabel)
            this._panelLabel.text = title;

        for (let i = 0; i < this._overviewButtons.length; i++) {
            const button = this._overviewButtons[i];
            if (!button)
                continue;
            if (i === index)
                button.add_style_class_name('dev-automation-workspace-overview-button-active');
            else
                button.remove_style_class_name('dev-automation-workspace-overview-button-active');
        }

        for (const badge of this._overviewBadges)
            badge.text = title;

        this._queueOverviewLayout();
    }

    _rebuildOverviewUi() {
        this._rebuildOverviewGrid();
        this._rebuildOverviewBadges();
        this._updateWorkspaceUi();
    }

    _rebuildOverviewGrid() {
        if (!this._overviewGrid || !this._workspaceManager || !this._settings)
            return;

        for (const child of this._overviewGrid.get_children())
            child.destroy();
        this._overviewButtons = [];

        const count = this._workspaceManager.n_workspaces;
        const columns = Math.max(1, Math.ceil(count / OVERVIEW_ROWS));

        for (let rowIndex = 0; rowIndex < OVERVIEW_ROWS; rowIndex++) {
            const row = new St.BoxLayout({
                style_class: 'dev-automation-workspace-overview-row',
                x_align: Clutter.ActorAlign.CENTER,
            });
            this._overviewGrid.add_child(row);

            const start = rowIndex * columns;
            const end = Math.min(count, start + columns);
            for (let index = start; index < end; index++) {
                const {title} = this._workspaceInfo(index);
                const button = new St.Button({
                    label: title,
                    style_class: 'dev-automation-workspace-overview-button',
                    can_focus: true,
                    reactive: true,
                    track_hover: true,
                });
                button.connect('clicked', () => {
                    const workspace = this._workspaceManager?.get_workspace_by_index(index);
                    workspace?.activate(global.get_current_time());
                });
                row.add_child(button);
                this._overviewButtons[index] = button;
            }
        }

        this._queueOverviewLayout();
    }

    _rebuildOverviewBadges() {
        for (const badge of this._overviewBadges)
            badge.destroy();
        this._overviewBadges = [];

        if (!this._workspaceManager || !this._settings)
            return;

        const {title} = this._workspaceInfo();
        for (const _monitor of Main.layoutManager.monitors) {
            const badge = new St.Label({
                text: title,
                style_class: 'dev-automation-workspace-overview-current',
                reactive: false,
                visible: this._overviewVisible,
            });
            Main.uiGroup.add_child(badge);
            this._overviewBadges.push(badge);
        }

        this._queueOverviewLayout();
    }

    _setOverviewVisible(visible) {
        this._overviewVisible = Boolean(visible);
        if (this._overviewGrid)
            this._overviewGrid.visible = this._overviewVisible;
        for (const badge of this._overviewBadges)
            badge.visible = this._overviewVisible;
        if (this._overviewVisible)
            this._queueOverviewLayout();
    }

    _queueOverviewLayout() {
        if (this._overviewLayoutIdleId || !this._overviewGrid)
            return;

        this._overviewLayoutIdleId = GLib.idle_add(GLib.PRIORITY_DEFAULT_IDLE, () => {
            this._overviewLayoutIdleId = 0;
            this._layoutOverviewUi();
            return GLib.SOURCE_REMOVE;
        });
    }

    _layoutOverviewUi() {
        if (!this._overviewGrid)
            return;

        const monitors = Main.layoutManager.monitors;
        if (!monitors?.length)
            return;

        const panelHeight = Math.max(0, Main.panel?.height || 0);
        const currentBadges = this._overviewBadges;

        for (let i = 0; i < currentBadges.length && i < monitors.length; i++) {
            const badge = currentBadges[i];
            const monitor = monitors[i];
            const [, width] = badge.get_preferred_width(-1);
            const [, height] = badge.get_preferred_height(width);
            badge.set_position(
                monitor.x + Math.round((monitor.width - width) / 2),
                monitor.y + panelHeight + 10
            );
            badge.set_size(width, height);
        }

        const monitor = Main.layoutManager.primaryMonitor || monitors[0];
        const [, gridWidth] = this._overviewGrid.get_preferred_width(-1);
        const [, gridHeight] = this._overviewGrid.get_preferred_height(gridWidth);
        const primaryIndex = monitors.indexOf(monitor);
        const primaryBadge = currentBadges[Math.max(0, primaryIndex)];
        let badgeHeight = 0;
        if (primaryBadge) {
            const [, width] = primaryBadge.get_preferred_width(-1);
            [, badgeHeight] = primaryBadge.get_preferred_height(width);
        }

        const horizontalMargin = 24;
        const width = Math.min(gridWidth, Math.max(1, monitor.width - horizontalMargin * 2));
        const x = monitor.x + Math.round((monitor.width - width) / 2);
        const y = monitor.y + panelHeight + 18 + badgeHeight;
        this._overviewGrid.set_position(x, y);
        this._overviewGrid.set_size(width, gridHeight);
    }

    _writeUiReady() {
        try {
            const panelAttached = Boolean(this._panelButton?.get_parent());
            const overviewAttached = Boolean(this._overviewGrid?.get_parent());
            const osdAttached = Boolean(this._label?.get_parent());
            if (!panelAttached || !overviewAttached || !osdAttached)
                throw new Error('atores visuais não foram anexados ao GNOME Shell');

            GLib.mkdir_with_parents(STATE_DIR, 0o700);
            GLib.file_set_contents(UI_READY_PATH,
                `version=${UI_VERSION}\npanel=1\noverview=1\nosd=1\n`);
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

    _showActiveWorkspaceName() {
        if (!this._label || !this._workspaceManager)
            return;

        const {title} = this._workspaceInfo();
        this._label.remove_all_transitions();
        this._label.text = title;
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
