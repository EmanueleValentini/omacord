#!/usr/bin/env python3
"""Run with: python3 tests/bridge.test.py

Drives bin/omacord-rpc against a fake Discord: a unix socket that speaks the
same framing the real client does. Everything the bridge is responsible for —
handshake, authentication, subscriptions, voice bookkeeping, notifications,
and the commands the panel sends back — is exercised without Discord being
installed.
"""

import json
import os
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BRIDGE = os.path.join(ROOT, "bin", "omacord-rpc")

OP_HANDSHAKE = 0
OP_FRAME = 1

failures = []


def check(name, condition, detail=""):
    if not condition:
        failures.append("%s%s" % (name, " — " + detail if detail else ""))


def eq(name, actual, expected):
    check(name, actual == expected, "got %r, want %r" % (actual, expected))


class FakeDiscord:
    """The other end of the socket: frames in, frames out, nothing clever."""

    def __init__(self, path):
        self.server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.server.bind(path)
        self.server.listen(1)
        self.conn = None
        self.buffer = b""

    def accept(self, timeout=10):
        self.server.settimeout(timeout)
        self.conn, _ = self.server.accept()
        self.conn.settimeout(timeout)

    def send(self, payload, opcode=OP_FRAME):
        blob = json.dumps(payload).encode()
        self.conn.sendall(struct.pack("<II", opcode, len(blob)) + blob)

    def recv(self, timeout=10):
        deadline = time.monotonic() + timeout
        while True:
            if len(self.buffer) >= 8:
                opcode, length = struct.unpack("<II", self.buffer[:8])
                if len(self.buffer) >= 8 + length:
                    body = self.buffer[8:8 + length]
                    self.buffer = self.buffer[8 + length:]
                    return opcode, json.loads(body.decode())
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError("no frame from the bridge")
            self.conn.settimeout(remaining)
            chunk = self.conn.recv(65536)
            if not chunk:
                raise ConnectionError("bridge disconnected")
            self.buffer += chunk

    def recv_cmd(self, cmd, timeout=10):
        """Next frame carrying `cmd`, skipping whatever else arrives first."""
        deadline = time.monotonic() + timeout
        skipped = []
        while True:
            _, frame = self.recv(max(0.1, deadline - time.monotonic()))
            if frame.get("cmd") == cmd:
                return frame
            skipped.append(frame)
            if time.monotonic() > deadline:
                raise TimeoutError("never saw %s, got %s" % (cmd, skipped))

    def close(self):
        if self.conn:
            self.conn.close()
        self.server.close()


class BridgeProcess:
    def __init__(self, env):
        self.process = subprocess.Popen(
            [sys.executable, BRIDGE],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            env=env, text=True, bufsize=1)
        self.lines = []
        self.lock = threading.Lock()
        self.reader = threading.Thread(target=self._read, daemon=True)
        self.reader.start()

    def _read(self):
        for line in self.process.stdout:
            line = line.strip()
            if not line:
                continue
            with self.lock:
                self.lines.append(json.loads(line))

    def send(self, command):
        self.process.stdin.write(json.dumps(command) + "\n")
        self.process.stdin.flush()

    def wait_for(self, predicate, timeout=10):
        """First emitted object matching `predicate`, or None on timeout."""
        deadline = time.monotonic() + timeout
        index = 0
        while time.monotonic() < deadline:
            with self.lock:
                pending = self.lines[index:]
                index = len(self.lines)
            for item in pending:
                if predicate(item):
                    return item
            time.sleep(0.05)
        return None

    def stop(self):
        try:
            self.process.stdin.close()
        except OSError:
            pass
        try:
            self.process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.process.kill()


def base_env(runtime_dir, state_dir):
    env = dict(os.environ)
    env["XDG_RUNTIME_DIR"] = runtime_dir
    env["XDG_STATE_HOME"] = state_dir
    # Keep the fallbacks from finding a real Discord on the developer's box.
    env["TMPDIR"] = runtime_dir
    env["TMP"] = runtime_dir
    env["TEMP"] = runtime_dir
    return env


def write_credentials(state_dir):
    directory = os.path.join(state_dir, "omacord")
    os.makedirs(directory, exist_ok=True)
    with open(os.path.join(directory, "credentials.json"), "w") as handle:
        json.dump({
            "client_id": "123456789012345678",
            "client_secret": "secret",
            "access_token": "token",
            "refresh_token": "refresh",
            # Far future: a near-expiry token would send the bridge to
            # Discord's token endpoint, and these tests never touch network.
            "expires_at": time.time() + 30 * 86400,
        }, handle)


def test_no_credentials():
    with tempfile.TemporaryDirectory() as tmp:
        runtime = os.path.join(tmp, "run")
        os.makedirs(runtime)
        bridge = BridgeProcess(base_env(runtime, os.path.join(tmp, "state")))
        state = bridge.wait_for(lambda item: item.get("type") == "state", 5)
        check("unauthorized: emits a state", state is not None)
        if state:
            eq("unauthorized: flags authRequired", state.get("authRequired"), True)
            eq("unauthorized: not running", state.get("running"), False)
        bridge.stop()


def test_full_session():
    with tempfile.TemporaryDirectory() as tmp:
        runtime = os.path.join(tmp, "run")
        state_dir = os.path.join(tmp, "state")
        os.makedirs(runtime)
        write_credentials(state_dir)

        discord = FakeDiscord(os.path.join(runtime, "discord-ipc-0"))
        bridge = BridgeProcess(base_env(runtime, state_dir))
        discord.accept()

        opcode, handshake = discord.recv()
        eq("handshake: opcode", opcode, OP_HANDSHAKE)
        eq("handshake: version", handshake.get("v"), 1)
        eq("handshake: client id", handshake.get("client_id"), "123456789012345678")

        discord.send({"cmd": "DISPATCH", "evt": "READY", "data": {"v": 1}})

        auth = discord.recv_cmd("AUTHENTICATE")
        eq("auth: sends the stored token", auth["args"].get("access_token"), "token")
        discord.send({"cmd": "AUTHENTICATE", "evt": None, "nonce": auth["nonce"],
                      "data": {"user": {"id": "42", "username": "terry",
                                        "global_name": "Terry"}}})

        state = bridge.wait_for(lambda item: item.get("type") == "state" and item.get("authed"))
        check("auth: reports authed", state is not None)
        if state:
            eq("auth: keeps the user", (state.get("user") or {}).get("globalName"), "Terry")
            eq("auth: clears authRequired", state.get("authRequired"), False)

        # Subscriptions and the initial reads, in whatever order they land.
        subscribed = set()
        commands = set()
        deadline = time.monotonic() + 5
        pending = []
        while time.monotonic() < deadline and not {"GET_VOICE_SETTINGS",
                                                   "GET_SELECTED_VOICE_CHANNEL"} <= commands:
            _, frame = discord.recv(5)
            if frame.get("cmd") == "SUBSCRIBE":
                subscribed.add(frame.get("evt"))
            else:
                commands.add(frame.get("cmd"))
                pending.append(frame)

        check("subscribe: voice channel select", "VOICE_CHANNEL_SELECT" in subscribed, str(subscribed))
        check("subscribe: voice settings", "VOICE_SETTINGS_UPDATE" in subscribed, str(subscribed))
        check("subscribe: notifications", "NOTIFICATION_CREATE" in subscribed, str(subscribed))

        for frame in pending:
            if frame["cmd"] == "GET_VOICE_SETTINGS":
                discord.send({"cmd": "GET_VOICE_SETTINGS", "nonce": frame["nonce"],
                              "data": {"mute": False, "deaf": False,
                                       "mode": {"type": "VOICE_ACTIVITY"}}})
            elif frame["cmd"] == "GET_SELECTED_VOICE_CHANNEL":
                discord.send({"cmd": "GET_SELECTED_VOICE_CHANNEL", "nonce": frame["nonce"],
                              "data": None})

        state = bridge.wait_for(lambda item: item.get("type") == "state"
                                and (item.get("voiceSettings") or {}).get("mode") == "VOICE_ACTIVITY")
        check("voice settings: reported", state is not None)
        eq("voice settings: idle means no channel", (state or {}).get("voice"), None)

        # ---- joining a channel
        discord.send({"cmd": "DISPATCH", "evt": "VOICE_CHANNEL_SELECT",
                      "data": {"channel_id": "9", "guild_id": "5"}})
        get_channel = discord.recv_cmd("GET_CHANNEL")
        eq("voice: asks about the channel it was told about",
           get_channel["args"].get("channel_id"), "9")
        discord.send({"cmd": "GET_CHANNEL", "nonce": get_channel["nonce"], "data": {
            "id": "9", "name": "General", "guild_id": "5",
            "voice_states": [
                {"user": {"id": "42", "username": "terry", "global_name": "Terry"},
                 "voice_state": {"mute": False, "self_mute": False, "deaf": False}},
                {"nick": "Ann", "user": {"id": "7", "username": "ann"},
                 "voice_state": {"mute": True, "deaf": False}},
            ]}})

        state = bridge.wait_for(lambda item: item.get("type") == "state" and item.get("voice"))
        check("voice: channel reported", state is not None)
        if state:
            voice = state["voice"]
            eq("voice: channel name", voice.get("channelName"), "General")
            eq("voice: participant count", len(voice.get("participants", [])), 2)
            names = sorted(p["name"] for p in voice["participants"])
            eq("voice: participant names", names, ["Ann", "Terry"])
            mine = [p for p in voice["participants"] if p["id"] == "42"][0]
            eq("voice: own entry marked self", mine.get("self"), True)
            ann = [p for p in voice["participants"] if p["id"] == "7"][0]
            eq("voice: mute state carried", ann.get("mute"), True)

        guild = discord.recv_cmd("GET_GUILD")
        discord.send({"cmd": "GET_GUILD", "nonce": guild["nonce"],
                      "data": {"id": "5", "name": "Omarchy"}})
        state = bridge.wait_for(lambda item: item.get("type") == "state"
                                and (item.get("voice") or {}).get("guildName") == "Omarchy")
        check("voice: guild name resolved", state is not None)

        # ---- speaking
        discord.send({"cmd": "DISPATCH", "evt": "SPEAKING_START", "data": {"user_id": "7"}})
        state = bridge.wait_for(lambda item: item.get("type") == "state" and any(
            p.get("speaking") for p in ((item.get("voice") or {}).get("participants") or [])))
        check("speaking: start marks the speaker", state is not None)

        discord.send({"cmd": "DISPATCH", "evt": "SPEAKING_STOP", "data": {"user_id": "7"}})
        state = bridge.wait_for(lambda item: item.get("type") == "state" and not any(
            p.get("speaking") for p in ((item.get("voice") or {}).get("participants") or [])))
        check("speaking: stop clears it", state is not None)

        # ---- someone leaves
        discord.send({"cmd": "DISPATCH", "evt": "VOICE_STATE_DELETE",
                      "data": {"user": {"id": "7", "username": "ann"}, "voice_state": {}}})
        state = bridge.wait_for(lambda item: item.get("type") == "state"
                                and len(((item.get("voice") or {}).get("participants") or [])) == 1)
        check("voice: leaver removed", state is not None)

        # ---- notifications
        discord.send({"cmd": "DISPATCH", "evt": "NOTIFICATION_CREATE", "data": {
            "channel_id": "9", "title": "Ann", "body": "are you there?",
            "icon_url": "https://cdn.discordapp.com/x.png",
            "message": {"id": "m1", "author": {"username": "ann", "global_name": "Ann"}}}})
        note = bridge.wait_for(lambda item: item.get("type") == "notification")
        check("notification: emitted", note is not None)
        if note:
            eq("notification: id from the message", note.get("id"), "m1")
            eq("notification: body carried", note.get("body"), "are you there?")
            eq("notification: author resolved", note.get("author"), "Ann")

        # ---- commands from the shell
        bridge.send({"cmd": "setMute", "value": None})
        set_settings = discord.recv_cmd("SET_VOICE_SETTINGS")
        eq("command: toggle mutes when unmuted", set_settings["args"].get("mute"), True)
        discord.send({"cmd": "SET_VOICE_SETTINGS", "nonce": set_settings["nonce"],
                      "data": {"mute": True, "deaf": False, "mode": {"type": "VOICE_ACTIVITY"}}})
        state = bridge.wait_for(lambda item: item.get("type") == "state"
                                and (item.get("voiceSettings") or {}).get("mute") is True)
        check("command: mute reflected in state", state is not None)

        bridge.send({"cmd": "setDeaf", "value": True})
        set_settings = discord.recv_cmd("SET_VOICE_SETTINGS")
        eq("command: explicit deafen value honoured", set_settings["args"].get("deaf"), True)

        bridge.send({"cmd": "leaveVoice"})
        leave = discord.recv_cmd("SELECT_VOICE_CHANNEL")
        eq("command: leave sends a null channel", leave["args"].get("channel_id"), None)
        discord.send({"cmd": "SELECT_VOICE_CHANNEL", "nonce": leave["nonce"], "data": None})
        state = bridge.wait_for(lambda item: item.get("type") == "state"
                                and item.get("voice") is None)
        check("command: leaving clears the channel", state is not None)

        # ---- Discord going away
        discord.close()
        state = bridge.wait_for(lambda item: item.get("type") == "state"
                                and item.get("running") is False, 8)
        check("disconnect: reported as not running", state is not None)

        bridge.stop()


def test_rejected_token():
    with tempfile.TemporaryDirectory() as tmp:
        runtime = os.path.join(tmp, "run")
        state_dir = os.path.join(tmp, "state")
        os.makedirs(runtime)
        write_credentials(state_dir)
        # No refresh possible without network, so the bridge must surface the
        # rejection rather than retry forever.
        discord = FakeDiscord(os.path.join(runtime, "discord-ipc-0"))
        bridge = BridgeProcess(base_env(runtime, state_dir))
        discord.accept()
        discord.recv()
        discord.send({"cmd": "DISPATCH", "evt": "READY", "data": {"v": 1}})
        auth = discord.recv_cmd("AUTHENTICATE")
        discord.send({"cmd": "AUTHENTICATE", "nonce": auth["nonce"], "evt": "ERROR",
                      "data": {"code": 4009, "message": "Invalid token"}})

        state = bridge.wait_for(lambda item: item.get("type") == "state"
                                and item.get("authRequired") is True, 30)
        check("rejected token: asks for re-authorization", state is not None)
        if state:
            eq("rejected token: keeps the reason", state.get("error"), "Invalid token")
        bridge.stop()
        discord.close()


def main():
    test_no_credentials()
    test_full_session()
    test_rejected_token()

    if failures:
        for failure in failures:
            print("FAIL %s" % failure, file=sys.stderr)
        print("%d bridge test(s) failed" % len(failures), file=sys.stderr)
        return 1
    print("all bridge tests passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
