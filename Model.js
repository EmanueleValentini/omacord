// Pure formatting and reduction for Omacord. Nothing in here touches QML or
// the socket, so the whole display layer can be exercised from node — see
// tests/model.test.mjs.

// Nerd Font glyphs, matched to the bar's built-in widgets.
var ICON_VOICE = "󰕾"
var ICON_MUTED = "󰍭"
var ICON_DEAF = "󰋐"
var ICON_MENTION = "󰂚"
var ICON_DISCORD = "󰙯"
var ICON_OFFLINE = "󰙯"
var ICON_CHANNEL = "󰐣"
var ICON_WARN = "󰀦"

var DISPLAY_KEYS = ["voice", "mentions", "channel", "status"]

function normalizeDisplay(value) {
  var wanted = Array.isArray(value) ? value : [value]
  var out = []
  for (var i = 0; i < wanted.length; i++) {
    var key = String(wanted[i] || "").trim()
    if (DISPLAY_KEYS.indexOf(key) >= 0 && out.indexOf(key) < 0) out.push(key)
  }
  return out.length > 0 ? out : ["voice", "mentions"]
}

function truncate(text, limit) {
  var value = String(text === undefined || text === null ? "" : text)
  if (!isFinite(limit) || limit <= 0 || value.length <= limit) return value
  return value.slice(0, Math.max(1, limit - 1)) + "…"
}

// ---- Sources
//
// Two of them, and they are not equal. The desktop client exposes an RPC
// socket that answers questions (who is in this voice channel, mute me);
// the web app exposes nothing but its window title, which still carries the
// unread count, the channel and the server. Everything below reduces
// whichever is available into one shape the bar and panel can draw.

// True when the RPC bridge has a client, a handshake and an accepted token.
function isLive(state) {
  return !!(state && state.running && state.connected && state.authed)
}

function voiceOf(state) {
  return state && state.voice ? state.voice : null
}

function selfMuted(state) {
  var settings = state && state.voiceSettings ? state.voiceSettings : {}
  return settings.mute === true || settings.deaf === true
}

function selfDeafened(state) {
  var settings = state && state.voiceSettings ? state.voiceSettings : {}
  return settings.deaf === true
}

// Discord's web title is "(4) Discord | #channel | Server", losing the
// leading count when nothing is unread and the trailing halves when nothing
// is open. A direct message has no server, so it arrives one field short.
function parseWebTitle(title) {
  var text = String(title === undefined || title === null ? "" : title).trim()
  if (text === "") return null

  var badge = 0
  var counted = text.match(/^\((\d+)\)\s*/)
  if (counted) {
    badge = parseInt(counted[1], 10)
    text = text.slice(counted[0].length)
  }

  var parts = []
  var raw = text.split("|")
  for (var i = 0; i < raw.length; i++) {
    var piece = raw[i].replace(/^\s+|\s+$/g, "")
    if (piece !== "") parts.push(piece)
  }
  // The app name leads the title whether or not a channel follows it.
  if (parts.length > 0 && /^discord$/i.test(parts[0])) parts.shift()

  var channel = parts.length > 0 ? parts[0] : ""
  var guild = parts.length > 1 ? parts[1] : ""
  return {
    badge: isFinite(badge) ? badge : 0,
    channel: channel,
    guild: guild,
    // No server means a DM or the friends list, not a channel in a guild.
    dm: channel !== "" && guild === ""
  }
}

// `web` is what WebApp.qml found: { present, title } for the Discord window,
// or null. `mentions` is the plugin's own counter, only meaningful for RPC —
// the web app publishes a better number in its title.
function viewModel(rpcState, web, mentions) {
  var parsed = web && web.present ? parseWebTitle(web.title) : null

  if (isLive(rpcState)) {
    var voice = voiceOf(rpcState)
    return {
      source: "rpc",
      live: true,
      authRequired: false,
      user: rpcState.user || null,
      voice: voice,
      mute: selfMuted(rpcState),
      deaf: selfDeafened(rpcState),
      badge: Math.max(0, Math.round(mentions || 0)),
      channel: voice ? (voice.channelName || "") : (parsed ? parsed.channel : ""),
      guild: voice ? (voice.guildName || "") : (parsed ? parsed.guild : ""),
      dm: false,
      error: rpcState.error || ""
    }
  }

  if (parsed) {
    return {
      source: "web",
      live: true,
      authRequired: false,
      user: null,
      voice: null,
      mute: false,
      deaf: false,
      badge: parsed.badge,
      channel: parsed.channel,
      guild: parsed.guild,
      dm: parsed.dm,
      error: ""
    }
  }

  return {
    source: "none",
    live: false,
    // Only nag when a desktop client is actually there to authorize
    // against: someone running the web app has nothing to authorize.
    authRequired: !!(rpcState && rpcState.running && rpcState.authRequired),
    user: null,
    voice: null,
    mute: false,
    deaf: false,
    badge: 0,
    channel: "",
    guild: "",
    dm: false,
    error: rpcState ? (rpcState.error || "") : ""
  }
}

function voiceIcon(view) {
  if (view && view.deaf) return ICON_DEAF
  if (view && view.mute) return ICON_MUTED
  return ICON_VOICE
}

// Who is audible right now, self excluded — the bar shows the room, not you.
function speakingNames(view) {
  var voice = view ? view.voice : null
  if (!voice) return []
  var names = []
  var participants = voice.participants || []
  for (var i = 0; i < participants.length; i++) {
    var entry = participants[i]
    if (entry && entry.speaking && !entry.self) names.push(entry.name || "")
  }
  return names
}

function channelLabel(view, limit) {
  if (!view || view.channel === "") return ""
  var prefix = view.source === "web" && !view.dm ? "#" : ""
  return prefix + truncate(view.channel, isFinite(limit) ? limit : 18)
}

function statusText(view) {
  if (!view) return "Starting…"
  if (view.authRequired) return "Authorize"
  if (view.source === "rpc") return view.user && view.user.globalName ? view.user.globalName : "Connected"
  if (view.source === "web") return "Web app"
  return "Offline"
}

// One entry per thing the bar draws. `level` picks the colour: normal rides
// the bar foreground, warn is the accent, critical is the urgent colour.
function barSegments(view, options) {
  var opts = options || {}
  var display = normalizeDisplay(opts.display)
  var showIcons = opts.showIcons !== false
  var nameLimit = isFinite(opts.channelNameLimit) ? opts.channelNameLimit : 18
  var segments = []

  for (var i = 0; i < display.length; i++) {
    var key = display[i]

    if (key === "voice") {
      // Voice is an RPC-only reading; the web app's title says nothing
      // about whether you are in a call.
      if (!view || view.source !== "rpc" || !view.voice) continue
      var speaking = speakingNames(view)
      var label = truncate(view.voice.channelName || "voice", nameLimit)
      segments.push({
        key: "voice",
        icon: showIcons ? voiceIcon(view) : "",
        text: label,
        label: (showIcons ? voiceIcon(view) + " " : "") + label,
        level: view.deaf ? "critical" : (speaking.length > 0 ? "warn" : "normal")
      })
    } else if (key === "mentions") {
      if (!view || view.badge <= 0) continue
      segments.push({
        key: "mentions",
        icon: showIcons ? ICON_MENTION : "",
        text: String(view.badge),
        label: (showIcons ? ICON_MENTION + " " : "") + String(view.badge),
        level: "warn"
      })
    } else if (key === "channel") {
      var where = channelLabel(view, nameLimit)
      if (where === "") continue
      segments.push({
        key: "channel",
        icon: showIcons ? ICON_CHANNEL : "",
        text: where,
        label: (showIcons ? ICON_CHANNEL + " " : "") + where,
        level: "normal"
      })
    } else if (key === "status") {
      var text = statusText(view)
      var icon = view && view.authRequired ? ICON_WARN : (view && view.live ? ICON_DISCORD : ICON_OFFLINE)
      segments.push({
        key: "status",
        icon: showIcons ? icon : "",
        text: text,
        label: (showIcons ? icon + " " : "") + text,
        level: view && view.authRequired ? "critical" : (view && view.live ? "normal" : "dim")
      })
    }
  }

  if (segments.length > 0) return segments

  // An unauthorized plugin is the one silence worth breaking: the bar is
  // the only place the user finds out that setup is still pending.
  if (view && view.authRequired) {
    segments.push({
      key: "auth",
      icon: showIcons ? ICON_WARN : "",
      text: "Discord",
      label: (showIcons ? ICON_WARN + " " : "") + "Discord",
      level: "critical"
    })
    return segments
  }

  // A live source with nothing to report still deserves a mark: Discord is
  // open and quiet, which is different from Discord not being there.
  if (view && view.live) {
    segments.push({
      key: "idle",
      icon: showIcons ? ICON_DISCORD : "",
      text: showIcons ? "" : "Discord",
      label: showIcons ? ICON_DISCORD : "Discord",
      level: "normal"
    })
    return segments
  }

  // Nothing running at all. The slot disappears unless asked to stay.
  if (opts.alwaysShow) {
    segments.push({
      key: "offline",
      icon: showIcons ? ICON_OFFLINE : "",
      text: showIcons ? "" : "Offline",
      label: showIcons ? ICON_OFFLINE : "Offline",
      level: "dim"
    })
  }

  return segments
}

function tooltipText(view) {
  if (!view) return "Starting…"
  if (view.authRequired) return "Omacord: run omacord-auth to authorize"
  if (!view.live) return "Discord is not running"

  var parts = [statusText(view)]

  if (view.source === "rpc" && view.voice) {
    var where = view.voice.channelName || "voice"
    if (view.voice.guildName) where = view.voice.guildName + " · " + where
    parts.push(where)
    if (view.deaf) parts.push("deafened")
    else if (view.mute) parts.push("muted")
    var speaking = speakingNames(view)
    if (speaking.length > 0) parts.push("speaking: " + speaking.join(", "))
  } else if (view.source === "web" && view.channel !== "") {
    var viewing = channelLabel(view, 40)
    if (view.guild !== "") viewing = view.guild + " · " + viewing
    parts.push(viewing)
  }

  if (view.badge > 0) parts.push(view.badge + " unread")
  return parts.join("  ·  ")
}

// ---- notification feed

function pushNotification(list, item, limit) {
  var cap = isFinite(limit) && limit > 0 ? limit : 25
  var out = []
  var existing = Array.isArray(list) ? list : []
  for (var i = 0; i < existing.length; i++) {
    // Discord can resend the same message id when a notification is
    // updated; keep one entry rather than stacking duplicates.
    if (!item || existing[i].id !== item.id) out.push(existing[i])
  }
  if (item) out.unshift(item)
  return out.slice(0, cap)
}

function relativeTime(timestamp, now) {
  var then = Number(timestamp) || 0
  var reference = isFinite(now) ? now : Date.now() / 1000
  var seconds = Math.max(0, Math.round(reference - then))
  if (seconds < 45) return "now"
  if (seconds < 3600) return Math.round(seconds / 60) + "m"
  if (seconds < 86400) return Math.round(seconds / 3600) + "h"
  return Math.round(seconds / 86400) + "d"
}

function participantSummary(view) {
  var voice = view ? view.voice : null
  if (!voice) return ""
  var participants = voice.participants || []
  if (participants.length === 0) return "empty"
  return participants.length + (participants.length === 1 ? " person" : " people")
}

// Exported for the node tests; QML ignores this branch.
if (typeof module !== "undefined") {
  module.exports = {
    ICON_VOICE: ICON_VOICE,
    ICON_MUTED: ICON_MUTED,
    ICON_DEAF: ICON_DEAF,
    ICON_MENTION: ICON_MENTION,
    DISPLAY_KEYS: DISPLAY_KEYS,
    normalizeDisplay: normalizeDisplay,
    truncate: truncate,
    isLive: isLive,
    selfMuted: selfMuted,
    selfDeafened: selfDeafened,
    ICON_DISCORD: ICON_DISCORD,
    parseWebTitle: parseWebTitle,
    viewModel: viewModel,
    channelLabel: channelLabel,
    voiceIcon: voiceIcon,
    speakingNames: speakingNames,
    statusText: statusText,
    barSegments: barSegments,
    tooltipText: tooltipText,
    pushNotification: pushNotification,
    relativeTime: relativeTime,
    participantSummary: participantSummary
  }
}
