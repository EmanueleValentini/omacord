# Omacord

Discord in the [Omarchy](https://omarchy.org) bar: what is unread, where you
are, and — with the desktop client — whether your mic is live.

## Two modes

Which readings you get depends on which Discord you run. Omacord picks the
better source on its own, per moment.

| | Web app (Omarchy's default) | Desktop client |
|---|---|---|
| Unread count | ✅ | ✅ |
| Current channel and server | ✅ | ✅ (voice channel) |
| Voice channel and who is in it | ❌ | ✅ |
| Mute / deafen state and toggles | ❌ | ✅ |
| Mention feed with message bodies | ❌ | ✅ |
| Setup | none | register an app, authorize once |

**Web app** — the readings come from the window title, which Discord keeps
current: `(4) Discord | #general | Server`. Nothing to install, nothing to
authorize, no token anywhere.

**Desktop client** — Discord opens a local RPC socket that answers real
questions. Omacord talks to it through `bin/omacord-rpc`, a small Python
bridge; the protocol is length-prefixed binary frames, which QML's text-only
`Socket` cannot carry. The socket hands out nothing without an OAuth token,
and Discord only issues one through a consent dialog raised by its own
client — hence the one-time setup below. Nothing leaves the machine except
that token exchange.

The bar stays empty when neither is running. With Discord open and quiet it
keeps a single glyph; unread messages add a count; in a voice call it shows
the channel name, coloured while someone else is talking and marked when you
are muted or deafened. Clicking opens the panel.

## Requirements

- Omarchy 4.x (`omarchy-shell`)
- Discord, either way: the web app (`omarchy-launch-webapp`, as Omarchy
  installs it) or the desktop client — `discord`, Vesktop, WebCord, flatpak
  and snap builds are all found
- `python3` (already present on Omarchy) — only used by the desktop path

## Install

```bash
omarchy plugin add https://github.com/EmanueleValentini/omacord --enable
```

Or manually:

```bash
git clone https://github.com/EmanueleValentini/omacord \
  ~/.config/omarchy/plugins/io.github.emanuelevalentini.omacord
omarchy plugin enable io.github.emanuelevalentini.omacord right
omarchy-restart-shell
```

The second argument to `enable` is the bar section (`left`, `center`,
`right`).

## Authorize (desktop client only)

Skip this entirely if you use the web app.

1. Open <https://discord.com/developers/applications> and create an
   application. Any name; you are the only one who will ever see it.
2. On the **OAuth2** page add a redirect URI — `http://localhost` — and save.
   The value is never visited, but the token exchange is refused without one.
3. Copy the **Application ID** and, from the same page, a **Client secret**.
4. Run, with Discord open:

```bash
~/.config/omarchy/plugins/io.github.emanuelevalentini.omacord/bin/omacord-auth \
  --client-id <APPLICATION_ID>
```

   Paste the secret when prompted, then approve the dialog that appears in
   Discord.

5. `omarchy-restart-shell`

Credentials land in `~/.local/state/omacord/credentials.json`, mode 600. The
access token is refreshed automatically; `--status` shows what is stored and
`--logout` removes it.

Until this is done — and only when a desktop client is actually running — the
bar shows a warning glyph, and the panel repeats these steps. A web app user
is never nagged, because there is nothing there to authorize.

> The `rpc` scopes are approved automatically for the account that owns the
> application — which is you. Handing the same application to someone else
> requires Discord's approval, so give people the setup steps, not your
> credentials.

## Usage

| Action | Result |
|---|---|
| Left click | Open / close the panel |
| Right click | Toggle microphone mute (desktop client) / focus Discord (web app) |
| Middle click | Toggle deafen |
| `↑` / `↓` in the panel | Scroll |
| `Esc` | Close the panel |

Opening the panel clears the mention counter. The web app's own count is
Discord's, so it clears when you read the messages.

From a script or a keybinding:

```bash
omarchy-shell omacord toggle          # open/close the panel
omarchy-shell omacord toggleMute
omarchy-shell omacord toggleDeafen
omarchy-shell omacord leaveVoice
omarchy-shell omacord clearMentions
omarchy-shell omacord focusDiscord
omarchy-shell omacord reconnect       # force the bridge to start over
```

A Hyprland binding, for the mute you actually reach for mid-call:

```
bindd = SUPER, M, Toggle Discord mute, exec, omarchy-shell omacord toggleMute
```

## Configuration

Settings live in the widget's own entry in `~/.config/omarchy/shell.json`:

```json
{
  "id": "io.github.emanuelevalentini.omacord",
  "display": ["voice", "mentions"],
  "showIcons": true,
  "alwaysShow": false,
  "channelNameLimit": 18
}
```

| Key | Default | Meaning |
|---|---|---|
| `display` | `["voice", "mentions"]` | What the bar shows, in order |
| `showIcons` | `true` | Show the glyph in front of each reading |
| `alwaysShow` | `false` | Keep a dim glyph in the bar when idle |
| `channelNameLimit` | `18` | Characters of channel name before eliding |

Available `display` values:

| Value | Web app | Desktop client |
|---|---|---|
| `voice` | nothing to show | voice channel, mute/deafen state |
| `mentions` | unread count from the title | mentions since the shell started |
| `channel` | channel you are reading | voice channel |
| `status` | `Web app` | your Discord display name |

Web app users who want the channel in the bar:

```json
{ "id": "io.github.emanuelevalentini.omacord", "display": ["mentions", "channel"] }
```

## Troubleshooting

| Symptom | Cause |
|---|---|
| Warning glyph in the bar | Not authorized yet — run `omacord-auth` |
| Nothing at all in the bar | Neither Discord is running. Set `alwaysShow` to keep the slot |
| Panel says "Discord web app" | Working as intended — install the desktop client for voice readings |
| Web app open but nothing shows | Its window must be open, not just the tab; check `hyprctl clients` names it `chrome-discord.com...` |
| "Unauthorized" after a while | Token could not be refreshed; run `omacord-auth` again |
| `token exchange rejected (403): error code: 1010` | Cloudflare, not Discord: it blocks requests without a browser-like `User-Agent`. Both scripts send one; if you see this, the header was lost (a proxy, a patched copy) — it is not a redirect URI problem |

The bridge reconnects on its own — every few seconds at first, backing off to
every 30 — so starting Discord after the shell is fine.

## Development

```bash
./dev-install.sh            # copy into ~/.config/omarchy/plugins and restart the shell
./dev-install.sh --no-restart
node tests/model.test.mjs   # bar labels, tooltips, notification feed
python3 tests/bridge.test.py  # the RPC bridge, against a fake Discord socket
```

The bridge tests stand up a unix socket that speaks Discord's framing, so the
handshake, authentication, subscriptions, voice bookkeeping and panel
commands are all covered without the desktop client installed. The window
title parsing and the source selection between the two modes are covered by
the model tests.

`Model.js` holds every formatting decision as plain functions with no QML
imports, which is what lets the display be tested under node.

## License

MIT
