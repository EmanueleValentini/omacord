import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The bar label: where you are in voice, and how many mentions are waiting.
//
// Both halves disappear when they have nothing to say — an empty voice
// state and no mentions means no widget at all, which is the honest reading
// for a Discord you are not currently in. `alwaysShow` keeps a dim glyph in
// the bar for people who would rather see the slot stay put.
//
// Left click opens the panel, right click toggles the mic, middle click
// toggles deafen — the two things worth reaching for without looking.
BarWidget {
  id: root
  moduleName: "io.github.emanuelevalentini.omacord"

  // The bridge lives in the plugin's service instance so one Discord
  // connection serves a bar on every monitor. A plugin enabled as a bar
  // widget only — or one whose service has not finished loading — falls
  // back to a local bridge so the widget is never blank.
  readonly property var sharedRpc: bar && bar.shell && typeof bar.shell.serviceFor === "function"
    ? bar.shell.serviceFor(root.moduleName)
    : null
  readonly property var rpc: sharedRpc || localRpc.item

  readonly property var display: Model.normalizeDisplay(setting("display", ["voice", "mentions"]))
  readonly property bool showIcons: setting("showIcons", true) === true
  readonly property bool alwaysShow: setting("alwaysShow", false) === true
  readonly property int channelNameLimit: Math.max(4, setting("channelNameLimit", 18))

  readonly property var state: rpc ? rpc.state : null
  readonly property int mentions: rpc ? rpc.mentions : 0

  // Two sources, one shape. RPC wins when it is authorized and connected;
  // otherwise the web app's window title carries the readings it can.
  readonly property var view: Model.viewModel(state, webapp.state, mentions)

  readonly property var segments: Model.barSegments(view, {
    display: display,
    showIcons: showIcons,
    alwaysShow: alwaysShow,
    channelNameLimit: channelNameLimit
  })

  readonly property string tooltipSummary: Model.tooltipText(view)

  // Cheap: one toplevel lookup, no process, no socket. Runs even when RPC
  // is authorized, so a web app left open still answers when the desktop
  // client is closed.
  WebApp { id: webapp }

  // ---- Bridge lifetime. One retain per mounted widget; the bridge stops
  //      when the last of them goes away.
  property var retainTarget: null

  function updateRetain() {
    if (retainTarget === rpc) return
    if (retainTarget) retainTarget.release()
    retainTarget = rpc
    if (retainTarget) retainTarget.retain()
  }

  onRpcChanged: {
    updateRetain()
    injectPanel()
  }
  onViewChanged: injectPanel()
  Component.onCompleted: updateRetain()
  Component.onDestruction: if (retainTarget) retainTarget.release()

  // ---- Panel. Shape contract for the bar's summon/hide routing:
  //      open/close/opened have to live on the bar-widget root.
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  function open() { if (panelLoader.item) panelLoader.item.open() }
  function close() { if (panelLoader.item) panelLoader.item.close() }
  function togglePanel() { if (panelLoader.item) panelLoader.item.toggle() }
  function closeForPopoutSwitch() { if (panelLoader.item) panelLoader.item.closeForPopoutSwitch() }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
    if ("rpc" in target) target.rpc = root.rpc
    if ("webapp" in target) target.webapp = webapp
    if ("view" in target) target.view = root.view
  }

  readonly property real openPanelIndicatorWidth: contentRow.width
  readonly property real openPanelIndicatorHeight: Math.max(Style.space(10), Math.round(Style.bar.iconSlot * 0.55))

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight
  visible: segments.length > 0

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  Loader {
    id: localRpc
    active: !root.sharedRpc
    source: Qt.resolvedUrl("Rpc.qml")
  }

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  // The bar mounts one widget per monitor plus a placeholder slot, and an
  // IPC target only ever routes to whichever of them registered first. So
  // the handler asks the bar which copy a hotkey should act on instead of
  // acting on itself — the same choice `omarchy-shell shell summon` makes.
  function routeOpen() {
    if (root.bar && typeof root.bar.summonBarWidget === "function" && root.bar.summonBarWidget(root.moduleName)) return
    root.open()
  }

  function routeClose() {
    if (root.bar && typeof root.bar.hideBarWidget === "function" && root.bar.hideBarWidget(root.moduleName)) return
    root.close()
  }

  function routeToggle() {
    if (root.bar && typeof root.bar.isBarWidgetOpen === "function") {
      if (root.bar.isBarWidgetOpen(root.moduleName)) routeClose()
      else routeOpen()
      return
    }
    root.togglePanel()
  }

  // Voice actions go straight to the shared bridge, so they do not need the
  // broadcast dance the panel routing does.
  function toggleMute() { if (rpc) rpc.toggleMute() }
  function focusDiscord() {
    if (webapp.present) webapp.activate()
    else if (bar) bar.run("omarchy-launch-or-focus discord")
  }
  function toggleDeaf() { if (rpc) rpc.toggleDeaf() }
  function leaveVoice() { if (rpc) rpc.leaveVoice() }
  function clearMentions() { if (rpc) rpc.clearMentions() }

  IpcHandler {
    target: "omacord"

    function open(): void { root.routeOpen() }
    function close(): void { root.routeClose() }
    function show(): void { root.routeOpen() }
    function hide(): void { root.routeClose() }
    function toggle(): void { root.routeToggle() }
    function toggleMute(): void { root.toggleMute() }
    function toggleDeafen(): void { root.toggleDeaf() }
    function leaveVoice(): void { root.leaveVoice() }
    function clearMentions(): void { root.clearMentions() }
    function reconnect(): void { if (root.rpc) root.rpc.reconnect() }
    function focusDiscord(): void { root.focusDiscord() }
  }

  function segmentColor(level) {
    if (level === "critical") return button.activeColor
    if (level === "warn") return Style.hoverStateColor(button.foreground, Color.accent)
    if (level === "dim") return Qt.darker(button.foreground, 1.6)
    return button.foreground
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    // Drawn per segment below so a live mention can colour itself without
    // dragging the channel name with it.
    labelVisible: false
    hasVisualContent: root.segments.length > 0
    tooltipText: root.tooltipSummary
    horizontalMargin: 8.75
    verticalPadding: 8.75
    fixedWidth: root.vertical ? -1 : Math.round(contentRow.implicitWidth + scaledHorizontalMargin * 2)
    fixedHeight: root.vertical ? Math.round(contentRow.implicitHeight + scaledVerticalPadding * 2) : -1

    onPressed: function(pressedButton) {
      if (pressedButton === Qt.RightButton) {
        if (root.view.source === "rpc") root.toggleMute()
        else root.focusDiscord()
      }
      else if (pressedButton === Qt.MiddleButton) root.toggleDeaf()
      else root.togglePanel()
    }

    // One row of segments horizontally; one stacked block per segment when
    // the bar runs down the side of the screen.
    Grid {
      id: contentRow
      anchors.centerIn: parent
      columns: root.vertical ? 1 : Math.max(1, root.segments.length)
      rows: root.vertical ? Math.max(1, root.segments.length) : 1
      horizontalItemAlignment: Grid.AlignHCenter
      verticalItemAlignment: Grid.AlignVCenter
      spacing: root.vertical ? Style.space(4) : Style.space(11)

      Repeater {
        model: root.segments

        Column {
          required property var modelData
          spacing: Style.space(1)

          Text {
            // Horizontally the icon is part of the label's own text run, so
            // it only gets a line of its own on a vertical bar.
            visible: root.vertical && modelData.icon !== ""
            anchors.horizontalCenter: root.vertical ? parent.horizontalCenter : undefined
            text: modelData.icon
            color: root.segmentColor(modelData.level)
            font.family: button.fontFamily
            font.pixelSize: Style.bar.iconFont
            renderType: Text.NativeRendering
          }

          Text {
            anchors.horizontalCenter: root.vertical ? parent.horizontalCenter : undefined
            visible: text !== ""
            // A vertical bar has no room for a channel name beside a glyph,
            // so it keeps the number/name only and lets the icon carry the
            // rest of the meaning.
            text: root.vertical ? modelData.text : modelData.label
            color: root.segmentColor(modelData.level)
            font.family: button.fontFamily
            font.pixelSize: root.vertical ? Math.round(Style.font.bodySmall * 0.92) : button.fontSize
            horizontalAlignment: Text.AlignHCenter
            renderType: Text.NativeRendering

            Behavior on color {
              enabled: !root.bar || root.bar.foregroundAnimationEnabled
              ColorAnimation { duration: 160 }
            }
          }
        }
      }
    }
  }
}
