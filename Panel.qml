import QtQuick
import Quickshell
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The full read-out. What it can show depends on where the readings came
// from, and the panel says which: the desktop client answers questions (who
// is in this channel, mute me), the web app only publishes its window title
// (unread count, channel, server). The setup that would upgrade one to the
// other is spelled out rather than assumed.
Panel {
  id: root
  moduleName: "io.github.emanuelevalentini.omacord"
  ipcTarget: "omacord"
  manageIpc: false

  property var anchorItem: null
  property var rpc: null
  property var webapp: null
  property var view: null

  // The bar tracks the widget mounted in its slot, not this nested panel,
  // so everything the bar identifies a panel by has to be that widget.
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  readonly property color contentForeground: bar ? bar.foreground : Color.foreground
  readonly property string contentFontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color dimForeground: Qt.darker(contentForeground, 1.5)
  readonly property color fainterForeground: Qt.darker(contentForeground, 1.9)

  readonly property int panelWidth: Style.space(420)

  readonly property string source: view ? view.source : "none"
  readonly property bool onRpc: source === "rpc"
  readonly property bool onWeb: source === "web"
  readonly property var voice: view ? view.voice : null
  readonly property var participants: voice && voice.participants ? voice.participants : []
  readonly property var notifications: rpc ? rpc.notifications : []
  readonly property bool authRequired: view ? view.authRequired === true : false
  readonly property bool muted: view ? view.mute === true : false
  readonly property bool deafened: view ? view.deaf === true : false

  // Recomputed on a slow tick so "3m ago" ages while the panel stays open.
  property real nowSeconds: Date.now() / 1000

  onOpenedChanged: {
    if (opened) {
      nowSeconds = Date.now() / 1000
      if (rpc) rpc.clearMentions()
      Qt.callLater(root.scrollToTop)
    }
  }

  property var flickable: null

  function scrollBy(delta) {
    if (!flickable) return
    var limit = Math.max(0, flickable.contentHeight - flickable.height)
    flickable.contentY = Math.max(0, Math.min(limit, flickable.contentY + delta))
  }

  function scrollToTop() {
    if (flickable) flickable.contentY = 0
  }

  function open() {
    root.controller.show()
    Qt.callLater(root.scrollToTop)
  }
  function close() { root.controller.hide() }
  function toggle() { root.opened ? root.close() : root.open() }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  function focusDiscord() {
    if (webapp && webapp.present) webapp.activate()
    else if (root.bar) root.bar.run("omarchy-launch-or-focus discord")
    root.close()
  }

  readonly property string heroIcon: {
    if (authRequired) return "\u{F0026}"          // alert
    if (deafened) return "\u{F02D0}"              // headphones off
    if (muted) return "\u{F036D}"                 // microphone off
    return "\u{F066F}"                            // discord
  }

  readonly property string heroTitle: {
    if (authRequired) return "Not authorized"
    if (onRpc) return view.user && view.user.globalName ? view.user.globalName : "Connected"
    if (onWeb) return "Discord web app"
    return "Discord offline"
  }

  readonly property string heroSubtitle: {
    if (authRequired) return "Run omacord-auth to link your Discord application"
    if (onRpc) {
      if (!voice) return "Not in a voice channel"
      var where = voice.channelName || "voice"
      if (voice.guildName) where = voice.guildName + " · " + where
      return where + " · " + Model.participantSummary(view)
    }
    if (onWeb) {
      if (view.channel === "") return "Open, nothing selected"
      var viewing = Model.channelLabel(view, 40)
      return view.guild !== "" ? view.guild + " · " + viewing : viewing
    }
    return "Neither the desktop client nor the web app is running"
  }

  Timer {
    running: root.opened
    interval: 30000
    repeat: true
    onTriggered: root.nowSeconds = Date.now() / 1000
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    centerOnBar: false
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(root.panelWidth)
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onMoveRequested: function(dx, dy) {
        if (dy !== 0) root.scrollBy(dy * Style.space(120))
      }

      Flickable {
        id: content
        anchors.fill: parent
        Component.onCompleted: root.flickable = content
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height

        Column {
          id: column
          width: content.width
          spacing: Style.space(12)

          // ---- Hero: where the readings come from, because everything
          //      below it depends on that answer.
          Item {
            width: parent.width
            height: Math.max(heroIcon.height, heroText.height)

            Text {
              id: heroIcon
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              text: root.heroIcon
              color: root.authRequired ? Color.urgent
                : (root.source !== "none" ? root.contentForeground : root.fainterForeground)
              font.family: root.contentFontFamily
              // Decorative, deliberately outside the Style.font.* scale.
              font.pixelSize: 34
            }

            Column {
              id: heroText
              anchors.left: heroIcon.right
              anchors.leftMargin: Style.space(14)
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(3)

              Text {
                width: parent.width
                text: root.heroTitle
                color: root.contentForeground
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.body
                font.bold: true
                elide: Text.ElideRight
              }

              Text {
                width: parent.width
                text: root.heroSubtitle
                color: root.dimForeground
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.bodySmall
                wrapMode: Text.WordWrap
              }

              Text {
                visible: root.view && root.view.badge > 0
                width: parent.width
                text: root.view ? root.view.badge + (root.view.badge === 1 ? " unread" : " unread") : ""
                color: Style.hoverStateColor(root.contentForeground, Color.accent)
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
              }
            }
          }

          // ---- Authorization. The plugin cannot fix this for you: Discord
          //      only hands out a token through a consent dialog raised by
          //      its own client, which is what omacord-auth asks for.
          Rectangle {
            visible: root.authRequired
            width: parent.width
            height: authText.implicitHeight + Style.space(18)
            radius: Style.cornerRadius
            color: Qt.rgba(Color.urgent.r, Color.urgent.g, Color.urgent.b, 0.12)

            Text {
              id: authText
              anchors.fill: parent
              anchors.margins: Style.space(9)
              text: "Register an application at discord.com/developers, then run:\n"
                + "  omacord-auth --client-id <APPLICATION_ID>\n"
                + "Approve the prompt in Discord and reopen this panel."
              color: root.contentForeground
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.caption
              // The bar font ligates "--" into an em dash, which would print
              // a command nobody can retype. Off for this block only.
              font.features: ({ "liga": 0, "calt": 0 })
              wrapMode: Text.WordWrap
            }
          }

          // ---- Web app. Everything the title carries is already in the
          //      hero, so this section exists to say what is missing and
          //      what it would take to get it.
          Rectangle {
            visible: root.onWeb
            width: parent.width
            height: webText.implicitHeight + Style.space(18)
            radius: Style.cornerRadius
            color: Qt.rgba(root.contentForeground.r, root.contentForeground.g,
                           root.contentForeground.b, 0.06)

            Text {
              id: webText
              anchors.fill: parent
              anchors.margins: Style.space(9)
              text: "Readings come from the web app's window title: unread count, "
                + "channel and server.\nVoice state, the people in your call and the "
                + "mute controls need the desktop client — install it, then run "
                + "omacord-auth."
              color: root.dimForeground
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
          }

          PanelSeparator {
            visible: root.onRpc
            width: parent.width
            foreground: root.contentForeground
          }

          // ---- Voice, desktop client only.
          PanelSectionHeader {
            visible: root.onRpc
            text: "VOICE"
            foreground: root.contentForeground
            fontFamily: root.contentFontFamily
          }

          Text {
            visible: root.onRpc && !root.voice
            width: parent.width
            text: "Join a voice channel in Discord and it shows up here."
            color: root.fainterForeground
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          Repeater {
            model: root.onRpc && root.voice ? root.participants : []

            Item {
              required property var modelData

              width: column.width
              height: participantName.implicitHeight + Style.space(5)

              Text {
                id: participantState
                anchors.left: parent.left
                width: Style.space(20)
                // Deafened outranks muted: someone who cannot hear you is a
                // different situation from someone who cannot answer.
                text: modelData.deaf ? "󰋐" : (modelData.mute ? "󰍭" : (modelData.speaking ? "󰕾" : "󰀄"))
                color: modelData.speaking
                  ? Style.hoverStateColor(root.contentForeground, Color.accent)
                  : (modelData.mute || modelData.deaf ? root.fainterForeground : root.dimForeground)
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
              }

              Text {
                id: participantName
                anchors.left: participantState.right
                anchors.right: parent.right
                text: modelData.name + (modelData.self ? "  (you)" : "")
                color: modelData.speaking
                  ? Style.hoverStateColor(root.contentForeground, Color.accent)
                  : root.contentForeground
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
              }
            }
          }

          // ---- Voice controls. Mute and deafen are Discord's own global
          //      settings, not the local mic, so they apply whether or not
          //      you are currently in a channel.
          Row {
            visible: root.onRpc
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: Style.space(10)

            PanelActionButton {
              iconText: root.muted ? "\u{F036D}" : "\u{F036C}"
              tooltipText: root.muted ? "Unmute microphone" : "Mute microphone"
              foreground: root.muted ? Color.urgent : root.contentForeground
              fontFamily: root.contentFontFamily
              onClicked: if (root.rpc) root.rpc.toggleMute()
            }

            PanelActionButton {
              iconText: root.deafened ? "\u{F02D0}" : "\u{F02CB}"
              tooltipText: root.deafened ? "Undeafen" : "Deafen"
              foreground: root.deafened ? Color.urgent : root.contentForeground
              fontFamily: root.contentFontFamily
              onClicked: if (root.rpc) root.rpc.toggleDeaf()
            }

            PanelActionButton {
              enabled: root.voice !== null && root.voice !== undefined
              iconText: "\u{F0A48}"
              tooltipText: "Leave voice channel"
              foreground: root.voice ? root.contentForeground : root.fainterForeground
              fontFamily: root.contentFontFamily
              onClicked: if (root.rpc) root.rpc.leaveVoice()
            }
          }

          PanelSeparator {
            visible: root.onRpc || root.notifications.length > 0
            width: parent.width
            foreground: root.contentForeground
          }

          // ---- Mentions. Only the desktop client raises these; the web
          //      app's count lives in the hero instead.
          PanelSectionHeader {
            visible: root.onRpc || root.notifications.length > 0
            text: "MENTIONS"
            foreground: root.contentForeground
            fontFamily: root.contentFontFamily
          }

          Text {
            visible: root.onRpc && root.notifications.length === 0
            width: parent.width
            text: "Nothing since the shell started."
            color: root.fainterForeground
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          Repeater {
            model: root.notifications

            Item {
              required property var modelData

              width: column.width
              height: notificationBody.y + notificationBody.implicitHeight + Style.space(4)

              Text {
                id: notificationTitle
                anchors.left: parent.left
                anchors.right: notificationAge.left
                anchors.rightMargin: Style.space(8)
                text: modelData.title || modelData.author || "Discord"
                color: root.contentForeground
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
              }

              Text {
                id: notificationAge
                anchors.right: parent.right
                anchors.top: parent.top
                text: Model.relativeTime(modelData.timestamp, root.nowSeconds)
                color: root.fainterForeground
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
              }

              Text {
                id: notificationBody
                y: notificationTitle.implicitHeight + Style.space(1)
                anchors.left: parent.left
                anchors.right: parent.right
                text: String(modelData.body || "").replace(/\s+/g, " ").trim()
                visible: text !== ""
                color: root.dimForeground
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
                maximumLineCount: 2
                elide: Text.ElideRight
              }
            }
          }

          // ---- Footer: raise Discord itself, or force the bridge to start
          //      over when something looks stuck.
          Item {
            width: parent.width
            height: footerRow.height + Style.space(4)

            Row {
              id: footerRow
              anchors.horizontalCenter: parent.horizontalCenter
              spacing: Style.space(8)

              PanelActionButton {
                iconText: "\u{F066F}"
                tooltipText: root.webapp && root.webapp.present ? "Focus Discord" : "Open Discord"
                foreground: root.contentForeground
                fontFamily: root.contentFontFamily
                onClicked: root.focusDiscord()
              }

              PanelActionButton {
                iconText: "\u{F0450}"
                tooltipText: "Reconnect"
                foreground: root.contentForeground
                fontFamily: root.contentFontFamily
                onClicked: if (root.rpc) root.rpc.reconnect()
              }
            }
          }
        }
      }
    }
  }
}
