#!/usr/bin/env python3
"""Drives AppRuntime's ExampleClipboard on the connected emulator or device
(Documentation/Plan.md §6.11), through UI Automator.

    Scripts/example-clipboard-check.py [--adb PATH]
    Scripts/example-clipboard-check.py --make-resources DIR

ExampleClipboard copies and pastes from code: a selectable `result`, Copy,
Copy Link, Copy Code, Copy Logo, Clear and Look, what there is to paste
(`offer`), Paste, Paste Link and Paste Image, what was `pasted`, and a
`status` line. Example-clipboard.sh makes its logo with `--make-resources`.

- text, a link with its title, and a sensitive code are copied, and
  pasted back through Android's clipboard;
- the logo is copied from the APK's assets as an image, and pasted;
- what there is to paste is known without reading it, and Clear empties
  it;
- a long press selects the result's text, which the platform copies.

Exits non-zero if any check fails.
"""

import argparse
import os
import re
import struct
import subprocess
import sys
import time
import xml.etree.ElementTree as ElementTree
import zlib

PACKAGE = "org.pureswift.ExampleClipboard"


def make_resources(directory):
    """A 16x16 PNG logo."""
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
    pixels = b"".join(b"\x00" + b"\xf0\x50\x20" * 16 for _ in range(16))
    png = (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 16, 16, 8, 2, 0, 0, 0))
           + chunk(b"IDAT", zlib.compress(pixels)) + chunk(b"IEND", b""))
    os.makedirs(directory, exist_ok=True)
    with open(os.path.join(directory, "logo.png"), "wb") as logo:
        logo.write(png)


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
            self.run("shell", "rm", "-f", "/sdcard/example-clipboard.xml")
            self.run("shell", "uiautomator", "dump", "/sdcard/example-clipboard.xml")
            tree = ElementTree.fromstring(self.run("shell", "cat", "/sdcard/example-clipboard.xml"))
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


def press(device, title, status):
    """Taps `title`, and gives the status once it starts with `status`."""
    if not device.button(title):
        return None
    return device.text("status", lambda text: text.startswith(status), timeout=10)


def offer(device, expected):
    """Looks again, and gives what there is to paste once it's `expected`."""
    device.button("Look")
    return device.text("offer", lambda text: text == expected, timeout=10)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--adb", default="adb")
    parser.add_argument("--make-resources", metavar="DIR")
    arguments = parser.parse_args()
    if arguments.make_resources:
        make_resources(arguments.make_resources)
        return 0
    device = Device(arguments.adb)
    # In landscape: the app's row of six buttons is wider than a phone held
    # upright, and Clear and Look would be off the screen.
    rotation = [device.run("shell", "settings", "get", "system", key).strip() for key in ("accelerometer_rotation", "user_rotation")]
    device.run("shell", "settings", "put", "system", "accelerometer_rotation", "0")
    device.run("shell", "settings", "put", "system", "user_rotation", "1")
    try:
        return run(device)
    finally:
        device.run("shell", "settings", "put", "system", "user_rotation", rotation[1] if rotation[1].isdigit() else "0")
        device.run("shell", "settings", "put", "system", "accelerometer_rotation", rotation[0] if rotation[0].isdigit() else "1")


def run(device):
    time.sleep(2)
    result = device.text("result", timeout=60)
    device.check(result == "6 × 7 = 42", f"the app starts ({result!r})")
    status = press(device, "Clear", "Cleared")
    device.check(status == "Cleared", f"Clear ({status!r})")
    seen = offer(device, "Nothing to paste")
    device.check(seen == "Nothing to paste", f"leaves nothing to paste ({seen!r})")

    status = press(device, "Copy", "Copied")
    device.check(status == "Copied the sum", f"Copy ({status!r})")
    seen = offer(device, "To paste: text")
    device.check(seen == "To paste: text", f"there's text to paste, known without reading it ({seen!r})")
    device.check(device.button("Paste"), "Paste")
    pasted = device.text("pasted", lambda text: text != "", timeout=10)
    device.check(pasted == "6 × 7 = 42", f"pastes it ({pasted!r})")

    status = press(device, "Copy Link", "Copied")
    device.check(status == "Copied the link", f"Copy Link ({status!r})")
    seen = offer(device, "To paste: a link, text")
    device.check(seen == "To paste: a link, text", f"there's a link, and text ({seen!r})")
    device.check(device.button("Paste Link"), "Paste Link")
    pasted = device.text("pasted", lambda text: text.startswith("https"), timeout=10)
    device.check(pasted == "https://swift.org", f"pastes the link ({pasted!r})")
    device.check(device.button("Paste"), "Paste")
    pasted = device.text("pasted", lambda text: text == "Swift", timeout=10)
    device.check(pasted == "Swift", f"and its title as text ({pasted!r})")

    status = press(device, "Copy Code", "Copied")
    device.check(status == "Copied the code", f"Copy Code ({status!r})")
    device.check(device.button("Paste"), "Paste")
    pasted = device.text("pasted", lambda text: text == "493 201", timeout=10)
    device.check(pasted == "493 201", f"pastes the code ({pasted!r})")

    status = press(device, "Copy Logo", "Copied")
    device.check(status == "Copied the logo", f"Copy Logo, from the APK's assets ({status!r})")
    seen = offer(device, "To paste: an image")
    device.check(seen == "To paste: an image", f"there's an image to paste ({seen!r})")
    status = press(device, "Paste Image", "Pasted")
    device.check(status == "Pasted an image: image/png", f"pastes it, as PNG ({status!r})")

    # The platform's own selection, with no code of the app's. A long press
    # selects the word under it, the 7. Its menu is a window UI Automator
    # doesn't dump, so the selection is copied with the platform's
    # shortcut.
    status = press(device, "Clear", "Cleared")
    device.check(status == "Cleared", f"Clear ({status!r})")
    node = device.wait(lambda node: node["id"] == "result", timeout=10)
    device.check(node is not None, "the result")
    if node:
        device.run("shell", "input", "swipe", *map(str, node["center"]), *map(str, node["center"]), "1200")
        time.sleep(1)
        device.run("shell", "input", "keycombination", "KEYCODE_CTRL_LEFT", "KEYCODE_C")
        time.sleep(1)
    seen = offer(device, "To paste: text")
    device.check(seen == "To paste: text", f"a long press selects the result, and it's copied ({seen!r})")
    device.check(device.button("Paste"), "Paste")
    pasted = device.text("pasted", lambda text: text == "7", timeout=10)
    device.check(pasted == "7", f"the selected word ({pasted!r})")

    errors = device.run("logcat", "-d", "-s", "AppRuntime:E").splitlines()
    errors = [line for line in errors if " E " in line or "error" in line.lower()]
    device.check(not errors, "no errors in logcat" + "".join(f"\n       {line}" for line in errors))
    print("ok" if device.failures == 0 else f"{device.failures} failed")
    return 1 if device.failures else 0


if __name__ == "__main__":
    sys.exit(main())
