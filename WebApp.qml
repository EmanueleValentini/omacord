import QtQuick
import Quickshell
import Quickshell.Wayland
import "Model.js" as Model

// The other Discord: the web app, running as its own Chromium window.
//
// There is no socket to talk to and no token to hold — but the window title
// carries the unread count, the channel and the server, and Discord keeps it
// current. Watching a toplevel costs nothing, so this runs whether or not
// the desktop client is also around; BarWidget prefers RPC when it has it.
Item {
  id: root
  visible: false

  // Matched on app id, never on title: a browser tab that merely mentions
  // Discord would otherwise pass for the app itself.
  property string appIdPattern: "discord|vesktop|webcord"

  readonly property var toplevels: ToplevelManager.toplevels ? ToplevelManager.toplevels.values : []

  // Recomputed whenever windows come and go. Titles change far more often
  // than this list does, which is why the title is read off the found
  // toplevel below rather than captured here.
  readonly property var target: {
    var pattern = new RegExp(root.appIdPattern, "i")
    for (var i = 0; i < toplevels.length; i++) {
      var entry = toplevels[i]
      if (entry && pattern.test(String(entry.appId || ""))) return entry
    }
    return null
  }

  readonly property bool present: target !== null
  readonly property string title: target ? String(target.title || "") : ""

  // The shape viewModel() expects, and the only thing leaving this file.
  readonly property var state: ({ present: root.present, title: root.title })

  function activate() {
    if (target) target.activate()
  }
}
