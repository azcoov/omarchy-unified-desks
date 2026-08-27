import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import qs.Commons
import qs.Ui

// Unified Desks bar widget -- TWO MONITORS ONLY.
//
// Shows 5 desks instead of 10 workspaces. A desk is a pair: left = ws N,
// right = ws N + 5. Clicking one moves both monitors together, exactly as
// SUPER+N does.
//
// Omarchy's stock widget highlights Hyprland.focusedWorkspace, which is a
// GLOBAL value, so every monitor's bar draws the same cell regardless of what
// that monitor is actually showing. Here each bar resolves its OWN monitor and
// derives the desk from that monitor's active workspace, so the two bars agree
// when the desks are in sync and honestly differ when they are not.
BarWidget {
  id: root
  moduleName: "io.github.azcoov.unified-desks"

  // Desk count comes from the same one-line config file the Lua side reads, so
  // the bar and the keybindings can never disagree. Absent or invalid -> 5.
  //
  // This widget never opens that file, or any other predictable path, itself.
  // Quickshell is one long-running process hosting the whole shell, so a path
  // swapped for a FIFO would block it and an oversized file would exhaust it.
  // scripts/read-state.py does the reading behind O_NONBLOCK | O_NOFOLLOW with
  // fstat validation and capped reads, and hands back only this parsed state.
  readonly property int defaultDeskCount: 5
  property int deskCount: defaultDeskCount
  readonly property int requiredMonitors: 2

  readonly property string ctl:
    Quickshell.env("HOME") + "/.config/omarchy/plugins/io.github.azcoov.unified-desks/scripts/desks-ctl"

  // --- monitor resolution -------------------------------------------------

  // Horizontal position of a monitor. Quickshell may expose this directly or
  // only on the raw Hyprland IPC payload, so try both before giving up.
  function monitorX(monitor) {
    if (!monitor) return 0
    if (monitor.x !== undefined && monitor.x !== null) return Number(monitor.x) || 0
    var ipc = monitor.lastIpcObject
    if (ipc && ipc.x !== undefined && ipc.x !== null) return Number(ipc.x) || 0
    return 0
  }

  function monitorDisabled(monitor) {
    if (!monitor) return true
    if (monitor.disabled !== undefined) return !!monitor.disabled
    var ipc = monitor.lastIpcObject
    return !!(ipc && ipc.disabled)
  }

  // Connected, non-mirrored monitors ordered left to right, matching the Lua
  // side's ordering so desk numbers line up.
  readonly property var orderedMonitors: {
    var all = (Hyprland.monitors && Hyprland.monitors.values) ? Hyprland.monitors.values : []
    var usable = []
    for (var i = 0; i < all.length; i++) {
      if (all[i] && !root.monitorDisabled(all[i])) usable.push(all[i])
    }
    usable.sort(function(a, b) { return root.monitorX(a) - root.monitorX(b) })
    return usable
  }

  readonly property bool supported: root.orderedMonitors.length === root.requiredMonitors

  // This bar surface's own monitor. One bar exists per screen, which is what
  // makes the widget honest instead of global.
  readonly property string screenName: {
    var win = root.QsWindow ? root.QsWindow.window : null
    return (win && win.screen) ? String(win.screen.name) : ""
  }

  // --- desk state ---------------------------------------------------------

  function workspaceById(id) {
    var values = Hyprland.workspaces.values
    for (var i = 0; i < values.length; i++) {
      if (values[i].id === id) return values[i]
    }
    return null
  }

  function occupiedById(id) {
    var ws = workspaceById(id)
    return ws !== null && ws.toplevels.values.length > 0
  }

  // Workspace shown on THIS bar's monitor, falling back to the global focused
  // workspace when the monitor cannot be resolved.
  readonly property int monitorWorkspaceId: {
    var mons = root.orderedMonitors
    for (var i = 0; i < mons.length; i++) {
      if (String(mons[i].name) === root.screenName) {
        var aw = mons[i].activeWorkspace
        if (aw && aw.id) return Number(aw.id)
      }
    }
    var fw = Hyprland.focusedWorkspace
    return fw ? Number(fw.id) : 0
  }

  // ws 1..5 -> desk 1..5; ws 6..10 -> desk 1..5.
  readonly property int activeDesk: {
    var id = root.monitorWorkspaceId
    if (id <= 0) return 0
    return id > root.deskCount ? id - root.deskCount : id
  }

  function deskIds() {
    var ids = []
    for (var i = 1; i <= root.deskCount; i++) ids.push(i)
    return ids
  }

  function switchDesk(desk) {
    if (!root.bar || !root.supported) return
    root.bar.run("bash " + Util.shellQuote(root.ctl) + " switch " + desk)
  }

  // --- setup state --------------------------------------------------------
  //
  // The plugin writes nothing on startup. Until someone clicks the setup pill
  // below, ~/.config/hypr is untouched.

  property bool hyprInstalled: false

  readonly property string reader:
    Quickshell.env("HOME") + "/.config/omarchy/plugins/io.github.azcoov.unified-desks/scripts/read-state.py"

  function applyState(raw) {
    try {
      var data = JSON.parse(String(raw))
      var count = Number(data.desks)
      root.deskCount = (count >= 1 && count <= 10) ? count : root.defaultDeskCount
      root.hyprInstalled = data.installed === true
    } catch (e) {
      root.deskCount = root.defaultDeskCount
      root.hyprInstalled = false
    }
  }

  function refreshState() {
    if (!stateProc.running) stateProc.running = true
  }

  Process {
    id: stateProc
    command: ["python3", root.reader]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyState(text)
    }
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        root.deskCount = root.defaultDeskCount
        root.hyprInstalled = false
      }
    }
  }

  // Polled rather than watched: a filesystem watch would mean holding these
  // predictable paths open inside the shell process, which is the problem the
  // helper exists to avoid. The state changes rarely, so this is cheap.
  Timer {
    interval: 10000
    running: true
    repeat: true
    onTriggered: root.refreshState()
  }

  Component.onCompleted: root.refreshState()

  function runSetup() {
    if (!root.bar) return
    root.bar.run("bash " + Util.shellQuote(root.ctl) + " install")
    setupSettle.restart()
  }

  // Setup runs detached, so re-read shortly after to flip the widget over.
  Timer {
    id: setupSettle
    interval: 1200
    repeat: false
    onTriggered: root.refreshState()
  }

  // --- layout -------------------------------------------------------------

  readonly property real trailingGap: root.vertical ? 0 : Style.spaceReal(1.5)

  // Three states: needs setup, wrong monitor count, or the desks themselves.
  readonly property bool showDesks: root.hyprInstalled && root.supported
  readonly property bool showNotice: root.hyprInstalled && !root.supported

  implicitWidth: (root.showDesks ? grid.implicitWidth
                                 : (root.showNotice ? notice.implicitWidth : setup.implicitWidth))
                 + trailingGap
  implicitHeight: root.showDesks ? grid.implicitHeight
                                 : (root.showNotice ? notice.implicitHeight : setup.implicitHeight)

  // Shown until the user opts in. Clicking runs desks-ctl install -- the only
  // thing that ever writes outside the plugin directory.
  WidgetButton {
    id: setup
    visible: !root.hyprInstalled
    bar: root.bar
    text: "\uDB85\uDCFB Set up desks"
    horizontalMargin: 6
    verticalPadding: 6
    fixedHeight: root.barSize
    tooltipText: "Click to set up Unified Desks. This installs "
                 + "~/.config/hypr/unified-desks.lua and adds one fenced require() line "
                 + "to hyprland.lua, backing up the original first. Nothing outside this "
                 + "plugin is touched until you click."
    onPressed: function() { root.runSetup() }
  }

  // Shown when set up but the machine does not have exactly two monitors. The
  // Lua side stays inert in that case, so stock workspace keys still work.
  WidgetButton {
    id: notice
    visible: root.showNotice
    bar: root.bar
    text: "\uDB85\uDCFB 2✕"
    opacity: 0.5
    horizontalMargin: 6
    verticalPadding: 6
    fixedHeight: root.barSize
    tooltipText: "Unified Desks needs exactly 2 monitors (found "
                 + root.orderedMonitors.length + "). Stock workspace keys are unchanged."
  }

  GridLayout {
    id: grid
    visible: root.showDesks
    anchors.fill: parent
    anchors.rightMargin: root.trailingGap
    columns: root.vertical ? 1 : root.deskIds().length
    columnSpacing: root.vertical ? 0 : Style.space(1)
    rowSpacing: root.vertical ? Style.space(2) : 0

    Repeater {
      model: root.showDesks ? root.deskIds() : []

      WidgetButton {
        required property int modelData

        // A desk counts as occupied if either half holds windows.
        readonly property bool occupied: root.occupiedById(modelData)
                                         || root.occupiedById(modelData + root.deskCount)
        readonly property bool focused: root.activeDesk === modelData

        bar: root.bar
        text: focused ? "\uDB85\uDCFB" : String(modelData)
        opacity: occupied || focused ? 1 : 0.5
        horizontalMargin: 6
        verticalPadding: 6
        fixedWidth: root.vertical ? root.barSize : Style.space(20)
        fixedHeight: root.barSize
        tooltipText: "Desk " + modelData + "  (ws " + modelData
                     + " + ws " + (modelData + root.deskCount) + ")"
        onPressed: function() { root.switchDesk(modelData) }
      }
    }
  }
}
