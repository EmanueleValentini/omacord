import QtQml
import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// The plugin's single connection to Discord.
//
// Everything on screen comes from `bin/omacord-rpc`, a small python bridge
// that speaks Discord's length-prefixed IPC framing and prints newline JSON.
// QML cannot do that framing itself — `Socket` is a text stream, and the
// frame header is raw little-endian bytes — so the bridge is not an
// indirection, it is the only way in.
//
// Consumers retain()/release() so the bridge only runs while something is
// showing its output, and dies with the shell either way.
Item {
  id: root
  visible: false

  // The plugin is installed as a folder; the bridge sits next to the QML.
  readonly property string pluginDir: String(Qt.resolvedUrl(".")).replace(/^file:\/\//, "").replace(/\/$/, "")

  property int subscribers: 0
  property int notificationLimit: 25

  // Last snapshot from the bridge. Shape mirrors what omacord-rpc emits;
  // the defaults are what "nothing known yet" looks like.
  property var state: ({
    running: false,
    connected: false,
    authed: false,
    authRequired: false,
    user: null,
    voice: null,
    voiceSettings: { mute: false, deaf: false, mode: "" },
    error: ""
  })

  property var notifications: []
  property int mentions: 0
  property string lastError: ""

  readonly property bool live: Model.isLive(state)
  readonly property bool authRequired: state && state.authRequired === true
  readonly property var voice: state ? state.voice : null

  signal notificationReceived(var item)

  function retain() { subscribers += 1; updateRunning() }
  function release() { subscribers = Math.max(0, subscribers - 1); updateRunning() }

  function clearMentions() { mentions = 0 }

  function setMute(value) { send({ cmd: "setMute", value: value === undefined ? null : value }) }
  function setDeaf(value) { send({ cmd: "setDeaf", value: value === undefined ? null : value }) }
  function toggleMute() { setMute(null) }
  function toggleDeaf() { setDeaf(null) }
  function leaveVoice() { send({ cmd: "leaveVoice" }) }
  function reconnect() { send({ cmd: "reconnect" }) }

  function send(command) {
    if (!bridge.running) return
    bridge.write(JSON.stringify(command) + "\n")
  }

  // ---- Bridge lifetime. `running` is assigned rather than bound: a binding
  //      would hold the process at "should be running" while it is dead,
  //      leaving nothing to restart it after a crash.
  function updateRunning() {
    var want = subscribers > 0
    if (want === bridge.running) return
    if (want) bridge.running = true
    else {
      restartTimer.stop()
      bridge.running = false
      resetState()
    }
  }

  function resetState() {
    var next = {}
    for (var key in root.state) next[key] = root.state[key]
    next.running = false
    next.connected = false
    next.authed = false
    next.voice = null
    root.state = next
  }

  function handleLine(line) {
    var text = String(line).trim()
    if (text === "") return

    var payload
    try {
      payload = JSON.parse(text)
    } catch (error) {
      root.lastError = text
      return
    }

    if (payload.type === "state") {
      root.state = payload
    } else if (payload.type === "notification") {
      root.notifications = Model.pushNotification(root.notifications, payload, root.notificationLimit)
      root.mentions += 1
      root.notificationReceived(payload)
    } else if (payload.type === "log") {
      root.lastError = String(payload.message || "")
    }
  }

  Process {
    id: bridge
    command: [root.pluginDir + "/bin/omacord-rpc"]
    stdinEnabled: true

    stdout: SplitParser { onRead: function(line) { root.handleLine(line) } }
    stderr: SplitParser { onRead: function(line) { root.lastError = String(line) } }

    onExited: function(exitCode, exitStatus) {
      root.resetState()
      // The bridge already retries the socket internally, so an exit means
      // it actually failed. Come back slowly rather than in a hot loop.
      if (root.subscribers > 0) restartTimer.restart()
    }
  }

  Timer {
    id: restartTimer
    interval: 3000
    repeat: false
    onTriggered: if (root.subscribers > 0 && !bridge.running) bridge.running = true
  }

  Component.onDestruction: bridge.running = false
}
