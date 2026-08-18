// Run with: node tests/model.test.mjs
// Covers what the bar and panel draw from either source — the desktop RPC
// client and the web app's window title — so a wrong label is caught here
// rather than in the bar.
import { createRequire } from "node:module"

const require = createRequire(import.meta.url)
const M = require("../Model.js")

let failures = 0
function check(name, condition, detail) {
  if (condition) return
  failures++
  console.error(`FAIL ${name}${detail ? " — " + detail : ""}`)
}
function eq(name, actual, expected) {
  check(name, actual === expected, `got ${JSON.stringify(actual)}, want ${JSON.stringify(expected)}`)
}

// ---- fixtures
const noRpc = { running: false, connected: false, authed: false, authRequired: true,
                voiceSettings: { mute: false, deaf: false } }
const rpcNeedsAuth = { ...noRpc, running: true, connected: true }
function rpcLive(extra = {}) {
  return {
    running: true, connected: true, authed: true, authRequired: false,
    user: { id: "1", globalName: "terry" },
    voice: null,
    voiceSettings: { mute: false, deaf: false, mode: "VOICE_ACTIVITY" },
    error: "",
    ...extra
  }
}
const voiceState = {
  channelId: "9", channelName: "General", guildId: "5", guildName: "Omarchy",
  participants: [
    { id: "1", name: "terry", self: true, mute: false, deaf: false, speaking: false },
    { id: "2", name: "Ann", self: false, mute: false, deaf: false, speaking: true }
  ]
}
const web = (title) => ({ present: true, title })
const noWeb = { present: false, title: "" }

// ---- web title parsing
const full = M.parseWebTitle("(4) Discord | GAMING DI TIPO TOPO😌 | WORLD ON FREEZE")
eq("title: badge", full.badge, 4)
eq("title: channel", full.channel, "GAMING DI TIPO TOPO😌")
eq("title: guild", full.guild, "WORLD ON FREEZE")
eq("title: guild means not a dm", full.dm, false)

const quiet = M.parseWebTitle("Discord | general | Omarchy")
eq("title: no badge reads as zero", quiet.badge, 0)
eq("title: channel without badge", quiet.channel, "general")

const dm = M.parseWebTitle("(1) Discord | @ann")
eq("title: dm badge", dm.badge, 1)
eq("title: dm has no guild", dm.guild, "")
eq("title: dm flagged", dm.dm, true)

eq("title: bare app name has no channel", M.parseWebTitle("Discord").channel, "")
eq("title: empty title is nothing", M.parseWebTitle(""), null)
eq("title: null is nothing", M.parseWebTitle(null), null)
eq("title: stray spaces trimmed", M.parseWebTitle("(2)  Discord |  general ").channel, "general")

// ---- source selection
eq("source: rpc wins when authed",
   M.viewModel(rpcLive(), web("(4) Discord | general | Omarchy"), 0).source, "rpc")
eq("source: web app when rpc is not live",
   M.viewModel(noRpc, web("(4) Discord | general | Omarchy"), 0).source, "web")
eq("source: nothing at all", M.viewModel(noRpc, noWeb, 0).source, "none")
eq("source: web app counts as live", M.viewModel(noRpc, web("Discord"), 0).live, true)

// The web app has nothing to authorize, so the warning must not follow it.
eq("auth: no nag while the web app carries the load",
   M.viewModel(noRpc, web("(1) Discord | general | Omarchy"), 0).authRequired, false)
eq("auth: no nag when no client is running at all",
   M.viewModel(noRpc, noWeb, 0).authRequired, false)
eq("auth: nag when the desktop client is there but unauthorized",
   M.viewModel(rpcNeedsAuth, noWeb, 0).authRequired, true)

// ---- badges
eq("badge: web app publishes its own count",
   M.viewModel(noRpc, web("(7) Discord | general | Omarchy"), 0).badge, 7)
eq("badge: rpc uses the plugin's counter", M.viewModel(rpcLive(), noWeb, 3).badge, 3)

// ---- display normalization
eq("display: unknown keys dropped", M.normalizeDisplay(["voice", "nope"]).join(","), "voice")
eq("display: empty falls back", M.normalizeDisplay([]).join(","), "voice,mentions")
eq("display: junk falls back", M.normalizeDisplay(null).join(","), "voice,mentions")
eq("display: duplicates collapse", M.normalizeDisplay(["voice", "voice"]).length, 1)
eq("display: channel is a valid key", M.normalizeDisplay(["channel"]).join(","), "channel")

// ---- truncation
eq("truncate: short text untouched", M.truncate("General", 18), "General")
eq("truncate: long text elided", M.truncate("a-very-long-channel-name", 10), "a-very-lo…")
eq("truncate: null is empty", M.truncate(null, 10), "")

// ---- bar segments, RPC source
const inVoice = M.viewModel(rpcLive({ voice: voiceState }), noWeb, 0)
const voiceOnly = M.barSegments(inVoice, {})
eq("bar: voice segment shown", voiceOnly.length, 1)
eq("bar: voice text is the channel", voiceOnly[0].text, "General")
eq("bar: someone speaking warns", voiceOnly[0].level, "warn")

const mutedView = M.viewModel(rpcLive({ voice: voiceState, voiceSettings: { mute: true, deaf: false } }), noWeb, 0)
eq("bar: muted uses the muted glyph", M.barSegments(mutedView, {})[0].icon, M.ICON_MUTED)
const deafView = M.viewModel(rpcLive({ voice: voiceState, voiceSettings: { mute: true, deaf: true } }), noWeb, 0)
eq("bar: deafened is critical", M.barSegments(deafView, {})[0].level, "critical")
eq("bar: showIcons off drops the glyph",
   M.barSegments(inVoice, { showIcons: false })[0].label, "General")

const withMentions = M.barSegments(M.viewModel(rpcLive({ voice: voiceState }), noWeb, 4), {})
eq("bar: mentions follow voice", withMentions.length, 2)
eq("bar: mention count is the text", withMentions[1].text, "4")
eq("bar: channel name limit honoured",
   M.barSegments(M.viewModel(rpcLive({ voice: { channelName: "long-channel-name", participants: [] } }), noWeb, 0),
                 { channelNameLimit: 6 })[0].text, "long-…")

// ---- bar segments, web source
const webView = M.viewModel(noRpc, web("(4) Discord | general | Omarchy"), 0)
const webSegments = M.barSegments(webView, { display: ["voice", "mentions", "channel"] })
eq("bar: web app has no voice reading", webSegments.length, 2)
eq("bar: web mention count", webSegments[0].text, "4")
eq("bar: web channel gets a hash", webSegments[1].text, "#general")
eq("bar: dm keeps its own prefix",
   M.barSegments(M.viewModel(noRpc, web("Discord | @ann"), 0), { display: ["channel"] })[0].text, "@ann")

// ---- fallbacks
const quietWeb = M.viewModel(noRpc, web("Discord"), 0)
eq("bar: live but quiet still marks the slot", M.barSegments(quietWeb, {}).length, 1)
eq("bar: quiet mark is the discord glyph", M.barSegments(quietWeb, {})[0].icon, M.ICON_DISCORD)
eq("bar: nothing running renders nothing", M.barSegments(M.viewModel(noRpc, noWeb, 0), {}).length, 0)
eq("bar: alwaysShow keeps the slot",
   M.barSegments(M.viewModel(noRpc, noWeb, 0), { alwaysShow: true }).length, 1)
eq("bar: unauthorized shows without alwaysShow",
   M.barSegments(M.viewModel(rpcNeedsAuth, noWeb, 0), {}).length, 1)
eq("bar: unauthorized is urgent",
   M.barSegments(M.viewModel(rpcNeedsAuth, noWeb, 0), {})[0].level, "critical")

// ---- status and tooltip
eq("status: rpc names the user", M.statusText(M.viewModel(rpcLive(), noWeb, 0)), "terry")
eq("status: web app says so", M.statusText(webView), "Web app")
eq("status: nothing running", M.statusText(M.viewModel(noRpc, noWeb, 0)), "Offline")
eq("status: authorize", M.statusText(M.viewModel(rpcNeedsAuth, noWeb, 0)), "Authorize")

eq("tooltip: offline is plain", M.tooltipText(M.viewModel(noRpc, noWeb, 0)), "Discord is not running")
eq("tooltip: unauthorized points at the fix", M.tooltipText(M.viewModel(rpcNeedsAuth, noWeb, 0)),
   "Omacord: run omacord-auth to authorize")
const voiceTooltip = M.tooltipText(M.viewModel(rpcLive({ voice: voiceState }), noWeb, 2))
check("tooltip: names the guild and channel", voiceTooltip.indexOf("Omarchy · General") >= 0, voiceTooltip)
check("tooltip: lists who is speaking", voiceTooltip.indexOf("speaking: Ann") >= 0, voiceTooltip)
check("tooltip: counts unread", voiceTooltip.indexOf("2 unread") >= 0, voiceTooltip)
check("tooltip: self is never 'speaking'",
      M.tooltipText(M.viewModel(rpcLive({ voice: { channelName: "General",
        participants: [{ id: "1", name: "terry", self: true, speaking: true }] } }), noWeb, 0))
        .indexOf("speaking") < 0)
check("tooltip: deafened beats muted", M.tooltipText(deafView).indexOf("deafened") >= 0)
check("tooltip: web app names where you are",
      M.tooltipText(webView).indexOf("Omarchy · #general") >= 0, M.tooltipText(webView))

// ---- notification feed
let feed = []
feed = M.pushNotification(feed, { id: "a", body: "one" }, 3)
feed = M.pushNotification(feed, { id: "b", body: "two" }, 3)
eq("feed: newest first", feed[0].id, "b")
feed = M.pushNotification(feed, { id: "a", body: "one, edited" }, 3)
eq("feed: repeated id is not duplicated", feed.length, 2)
eq("feed: repeated id moves to the top", feed[0].body, "one, edited")
feed = M.pushNotification(feed, { id: "c" }, 2)
eq("feed: capped", feed.length, 2)
eq("feed: cap drops the oldest", feed.map(e => e.id).join(","), "c,a")

// ---- relative time
const now = 1_000_000
eq("time: seconds read as now", M.relativeTime(now - 10, now), "now")
eq("time: minutes", M.relativeTime(now - 300, now), "5m")
eq("time: hours", M.relativeTime(now - 7200, now), "2h")
eq("time: days", M.relativeTime(now - 172800, now), "2d")
eq("time: future clamps to now", M.relativeTime(now + 500, now), "now")

// ---- participants
eq("participants: empty channel",
   M.participantSummary(M.viewModel(rpcLive({ voice: { participants: [] } }), noWeb, 0)), "empty")
eq("participants: plural", M.participantSummary(inVoice), "2 people")
eq("participants: singular",
   M.participantSummary(M.viewModel(rpcLive({ voice: { participants: [{ id: "1", name: "a" }] } }), noWeb, 0)),
   "1 person")

if (failures > 0) {
  console.error(`${failures} model test(s) failed`)
  process.exit(1)
}
console.log("all model tests passed")
