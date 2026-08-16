import Clutter from 'gi://Clutter';
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import St from 'gi://St';

import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';

export default class DevAutomationWorkspaceNameExtension extends Extension {
    enable() {
        this._workspaceManager = global.workspace_manager;
        this._settings = new Gio.Settings({schema_id: 'org.gnome.desktop.wm.preferences'});
        this._idleId = 0;

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
        this._label?.remove_all_transitions();
        this._label?.destroy();
        this._label = null;
        this._settings = null;
        this._workspaceManager = null;
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
