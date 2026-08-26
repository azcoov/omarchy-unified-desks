import QtQuick
import Quickshell
import Quickshell.Io

// Installs the Hyprland side of Unified Desks and keeps it in step with the
// plugin payload. Everything it writes is fenced or restorable; see
// scripts/desks-ctl restore.
Item {
  id: root

  property var barWidgetRegistry: null
  property var manifest: null
  property var shell: null
  property var component: null

  readonly property string ctl:
    Quickshell.env("HOME") + "/.config/omarchy/plugins/io.github.azcoov.unified-desks/scripts/desks-ctl"

  function registerWidget() {
    if (!root.barWidgetRegistry || !root.manifest) return
    try {
      root.barWidgetRegistry.register(root.manifest, root.component)
    } catch (e) {
      // Registry shape varies across Omarchy versions; the bar still resolves
      // the widget from the manifest entryPoint, so this is non-fatal.
    }
  }

  // Runs desks-ctl install on every shell start. It is idempotent: the Lua file
  // is refreshed from the plugin payload and the hyprland.lua hook is only
  // appended when absent, so a plugin update picks up new logic automatically.
  // Invoked through bash rather than relying on the executable bit, which some
  // archive downloads strip.
  Process {
    id: installProc
    command: ["bash", root.ctl, "install"]
    running: false
  }

  Component.onCompleted: {
    registerWidget()
    installProc.running = true
  }

  onBarWidgetRegistryChanged: registerWidget()
}
