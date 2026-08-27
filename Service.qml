import QtQuick
import Quickshell

// Unified Desks service.
//
// This deliberately performs NO filesystem work. Earlier revisions ran
// `desks-ctl install` on every shell start, which meant the plugin wrote to
// ~/.config/hypr on startup with no user action behind it. Setup is now an
// explicit click on the bar widget, so nothing outside the plugin directory is
// touched until someone asks for it.
Item {
  id: root

  property var barWidgetRegistry: null
  property var manifest: null
  property var shell: null
  property var component: null

  function registerWidget() {
    if (!root.barWidgetRegistry || !root.manifest) return
    try {
      root.barWidgetRegistry.register(root.manifest, root.component)
    } catch (e) {
      // Registry shape varies across Omarchy versions; the bar still resolves
      // the widget from the manifest entryPoint, so this is non-fatal.
    }
  }

  Component.onCompleted: registerWidget()
  onBarWidgetRegistryChanged: registerWidget()
}
