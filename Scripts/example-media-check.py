#!/usr/bin/env python3
"""Drives AppRuntime's ExampleMedia on the connected emulator or device
(Documentation/Plan.md §6.10), through UI Automator.

    Scripts/example-media-check.py [--adb PATH]
    Scripts/example-media-check.py --make-resources DIR

ExampleMedia is a small music player over three songs in its bundle: the
song's `title`, its `state` (Playing or Paused), the `reason` for a pause,
Previous, Play or Pause, Next, Show Video, a VideoPlayer, and a `status`
line. Example-media.sh makes the songs, eight-second tones, with
`--make-resources`, and encodes them as MP3.

- the first song loads from the APK's assets, and plays and pauses, and
  Android's audio service sees the app's player start;
- Next and Previous change songs, and a song that ends starts the next;
- when the app leaves the front, the song pauses, and says why;
- the video player is Media3's PlayerView.

Exits non-zero if any check fails.
"""

import argparse
import math
import os
import re
import struct
import subprocess
import sys
import time
import wave
import xml.etree.ElementTree as ElementTree
import zlib

PACKAGE = "org.pureswift.ExampleMedia"

SONGS = {"morning": 440.0, "noon": 554.37, "night": 659.25}

SECONDS = 8


def make_resources(directory):
    """The songs, as WAV for LAME, and a small cover."""
    os.makedirs(os.path.join(directory, "music"), exist_ok=True)
    rate = 22050
    for name, frequency in SONGS.items():
        with wave.open(os.path.join(directory, "music", name + ".wav"), "wb") as song:
            song.setnchannels(1)
            song.setsampwidth(2)
            song.setframerate(rate)
            frames = bytearray()
            for index in range(rate * SECONDS):
                frames += struct.pack("<h", int(8000 * math.sin(2 * math.pi * frequency * index / rate)))
            song.writeframes(bytes(frames))
    # A 2x2 PNG.
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
    pixels = b"".join(b"\x00" + b"\xff\x80\x00" * 2 for _ in range(2))
    png = (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 2, 2, 8, 2, 0, 0, 0))
           + chunk(b"IDAT", zlib.compress(pixels)) + chunk(b"IEND", b""))
    with open(os.path.join(directory, "music", "cover.png"), "wb") as cover:
        cover.write(png)


class Device:

    def __init__(self, adb):
        self.adb = adb
        self.failures = 0

    def run(self, *arguments, check=True):
        return subprocess.run([self.adb, *arguments], check=check, capture_output=True, text=True).stdout

    def app(self, *command):
        """A shell command run as the app, in its data directory."""
        return self.run("shell", "run-as", PACKAGE, *command, check=False)

    def nodes(self):
        """Every view on screen; none while UI Automator has nothing to dump."""
        try:
            # A dump that fails leaves the last one: never read that.
            self.run("shell", "rm", "-f", "/sdcard/example-media.xml")
            self.run("shell", "uiautomator", "dump", "/sdcard/example-media.xml")
            tree = ElementTree.fromstring(self.run("shell", "cat", "/sdcard/example-media.xml"))
        except (subprocess.CalledProcessError, ElementTree.ParseError):
            return []
        found = []

        def visit(element, enabled):
            for node in element.findall("node"):
                inside = enabled and node.get("enabled") == "true"
                bounds = list(map(int, re.findall(r"\d+", node.get("bounds", ""))))
                if len(bounds) == 4:
                    found.append({
                        "text": node.get("text", ""),
                        "desc": node.get("content-desc", ""),
                        "id": node.get("resource-id", "").split("/")[-1],
                        "class": node.get("class", ""),
                        "enabled": inside,
                        "checkable": node.get("checkable") == "true",
                        "checked": node.get("checked") == "true",
                        "center": ((bounds[0] + bounds[2]) // 2, (bounds[1] + bounds[3]) // 2),
                    })
                visit(node, inside)

        visit(tree, True)
        return found

    def wait(self, test, timeout=30):
        """The first view `test` accepts, waiting for one; None if none came."""
        deadline = time.time() + timeout
        while time.time() < deadline:
            for node in self.nodes():
                if test(node):
                    return node
            time.sleep(1)
        return None

    def text(self, identifier, test=lambda text: bool(text), timeout=30):
        """The text of the view `identifier` once `test` accepts it, or None."""
        node = self.wait(lambda node: node["id"] == identifier and test(node["text"]), timeout)
        return node["text"] if node else None

    def tap(self, node):
        self.run("shell", "input", "tap", *map(str, node["center"]))

    def button(self, title, timeout=10):
        """Taps the enabled button titled `title`; whether there was one."""
        node = self.wait(lambda node: node["text"] == title and node["enabled"], timeout)
        if node:
            self.tap(node)
        return node is not None

    def fields(self):
        return [node for node in self.nodes() if node["class"] == "android.widget.EditText"]

    def field(self, index, text):
        """Types `text` (no spaces) into the `index`th text field, until it
        says just that: the first keys after the app starts can repeat."""
        for _ in range(3):
            fields = self.fields()
            if len(fields) <= index:
                time.sleep(1)
                continue
            self.tap(fields[index])
            time.sleep(1)
            self.run("shell", "input", "keyevent", "KEYCODE_MOVE_END")
            self.run("shell", "input", "keyevent", *(["KEYCODE_DEL"] * 30))
            self.run("shell", "input", "text", text)
            time.sleep(0.5)
            typed = self.fields()
            if len(typed) > index and typed[index]["text"] == text:
                self.run("shell", "input", "keyevent", "KEYCODE_BACK")  # the keyboard
                time.sleep(0.5)
                return True
        return False

    def check(self, condition, message):
        print(("ok   " if condition else "FAIL ") + message)
        if not condition:
            self.failures += 1
        return condition


def audio_players(device):
    """The states of the app's players in Android's audio service."""
    uid = re.search(r"appId=(\d+)", device.run("shell", "dumpsys", "package", PACKAGE))
    if not uid:
        return []
    output = device.run("shell", "dumpsys", "audio")
    section = output[output.find("players:"):]
    return re.findall(r"u/pid:" + uid.group(1) + r"/\d+ .*?state:(\w+)", section)


def song(device, title, timeout=20):
    return device.text("title", lambda text: text.startswith(title), timeout=timeout)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--adb", default="adb")
    parser.add_argument("--make-resources", metavar="DIR")
    arguments = parser.parse_args()
    if arguments.make_resources:
        make_resources(arguments.make_resources)
        return 0
    device = Device(arguments.adb)

    title = song(device, "Morning", timeout=60)
    device.check(title == "Morning, The Examples", f"the first song loads ({title!r})")
    state = device.text("state", timeout=10)
    device.check(state == "Paused", f"paused at its start ({state!r})")
    status = device.text("status", timeout=10)
    device.check(status == "Plays in front only", f"in front only, as the manifest says ({status!r})")

    device.check(device.button("Play"), "Play")
    state = device.text("state", lambda text: text == "Playing", timeout=10)
    device.check(state == "Playing", f"it plays ({state!r})")
    time.sleep(1)
    players = audio_players(device)
    device.check("started" in players, f"and Android's audio service hears it ({players!r})")
    device.check(device.button("Pause"), "Pause")
    state = device.text("state", lambda text: text == "Paused", timeout=10)
    reason = device.text("reason", lambda text: True, timeout=2)
    device.check((state, reason or "") == ("Paused", ""), f"it pauses, as asked ({state!r}, {reason!r})")

    device.check(device.button("Next"), "Next")
    title = song(device, "Noon")
    state = device.text("state", lambda text: text == "Playing", timeout=10)
    device.check((title, state) == ("Noon, The Examples", "Playing"), f"the next song plays ({title!r}, {state!r})")
    title = song(device, "Night", timeout=SECONDS + 15)
    state = device.text("state", lambda text: text == "Playing", timeout=10)
    device.check((title, state) == ("Night, The Examples", "Playing"), f"when it ends, the one after it plays ({title!r}, {state!r})")
    device.check(device.button("Previous"), "Previous")
    title = song(device, "Noon")
    device.check(title == "Noon, The Examples", f"goes back ({title!r})")

    # The app leaves the front, and comes back.
    device.run("shell", "input", "keyevent", "KEYCODE_HOME")
    time.sleep(2)
    players = audio_players(device)
    device.check("started" not in players, f"leaving the front pauses it ({players!r})")
    device.run("shell", "monkey", "-p", PACKAGE, "-c", "android.intent.category.LAUNCHER", "1")
    state = device.text("state", timeout=20)
    reason = device.text("reason", timeout=10)
    device.check((state, reason) == ("Paused", "Paused for the background"), f"and says why ({state!r}, {reason!r})")

    device.check(device.button("Show Video"), "Show Video")
    view = device.wait(lambda node: node["class"] == "androidx.media3.ui.PlayerView" or node["id"].startswith("exo_"), timeout=10)
    device.check(view is not None, "the video player is a PlayerView")

    errors = device.run("logcat", "-d", "-s", "AppRuntime:E").splitlines()
    errors = [line for line in errors if " E " in line or "error" in line.lower()]
    device.check(not errors, "no errors in logcat" + "".join(f"\n       {line}" for line in errors))
    print("ok" if device.failures == 0 else f"{device.failures} failed")
    return 1 if device.failures else 0


if __name__ == "__main__":
    sys.exit(main())
