#!/usr/bin/env python3
"""Drives ExampleUI on the connected emulator or device, as a user would
(Documentation/Plan.md §10): it finds views with UI Automator's dump, taps
and types with `adb shell input`, and checks that each action reached the
guest and came back as an update. Takes a screenshot of each screen.

    Scripts/example-ui-check.py [--adb PATH] [--screens DIR]

Views are found by their text, or by their accessibilityIdentifier, which
the player turns into a resource ID.
"""

import argparse
import os
import re
import subprocess
import sys
import time
import xml.etree.ElementTree as ElementTree

PACKAGE = "org.pureswift.ExampleUI"
ACTIVITY = "org.pureswift.appruntime.AppRuntimeActivity"


class Device:

    def __init__(self, adb, screens):
        self.adb = adb
        self.screens = screens
        self.shots = 0
        self.failures = []

    def run(self, *arguments, capture=False):
        result = subprocess.run([self.adb, *arguments], check=True, capture_output=True)
        return result.stdout if capture else None

    def shell(self, *arguments):
        self.run("shell", *arguments)

    def nodes(self):
        """Every view on screen, as (text, resource ID, bounds center)."""
        for _ in range(5):
            self.shell("uiautomator", "dump", "/sdcard/window.xml")
            data = self.run("exec-out", "cat", "/sdcard/window.xml", capture=True)
            try:
                tree = ElementTree.fromstring(data)
                break
            except ElementTree.ParseError:
                time.sleep(0.5)
        else:
            raise RuntimeError("UI Automator's dump didn't parse")
        found = []
        for node in tree.iter("node"):
            bounds = re.findall(r"\d+", node.get("bounds", ""))
            if len(bounds) != 4:
                continue
            left, top, right, bottom = map(int, bounds)
            found.append({
                "text": node.get("text", ""),
                "id": node.get("resource-id", "").split("/")[-1],
                "class": node.get("class", ""),
                "center": ((left + right) // 2, (top + bottom) // 2),
            })
        return found

    def find(self, text=None, identifier=None, timeout=10, last=False):
        """The first view with `text` or `identifier`; the lowest on screen with `last`."""
        deadline = time.time() + timeout
        while True:
            matches = [
                node for node in self.nodes()
                if (text is not None and node["text"] == text)
                or (identifier is not None and node["id"] == identifier)
            ]
            if matches:
                return max(matches, key=lambda node: node["center"][1]) if last else matches[0]
            if time.time() > deadline:
                return None
            time.sleep(0.5)

    def text_of(self, identifier):
        """The text of the view with `identifier`, or of the first text inside it."""
        nodes = self.nodes()
        for index, node in enumerate(nodes):
            if node["id"] == identifier:
                if node["text"]:
                    return node["text"]
                for inner in nodes[index + 1:index + 4]:
                    if inner["text"]:
                        return inner["text"]
        return None

    def tap(self, node):
        x, y = node["center"]
        self.shell("input", "tap", str(x), str(y))

    def screenshot(self, name):
        if not self.screens:
            return
        os.makedirs(self.screens, exist_ok=True)
        self.shots += 1
        path = os.path.join(self.screens, f"{self.shots}-{name}.png")
        with open(path, "wb") as file:
            file.write(self.run("exec-out", "screencap", "-p", capture=True))

    def expect(self, condition, message):
        print(("ok   " if condition else "FAIL ") + message)
        if not condition:
            self.failures.append(message)

    def wait_for_text(self, identifier, expected, timeout=10):
        deadline = time.time() + timeout
        value = None
        while time.time() < deadline:
            value = self.text_of(identifier)
            if value == expected:
                return value
            time.sleep(0.5)
        return value


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--adb", default="adb")
    parser.add_argument("--screens")
    options = parser.parse_args()
    device = Device(options.adb, options.screens)

    device.run("logcat", "-c")
    device.shell("am", "force-stop", PACKAGE)
    device.shell("am", "start", "-W", "-n", f"{PACKAGE}/{ACTIVITY}")

    # It renders: rt_main's first tree is on screen.
    greeting = device.wait_for_text("greeting", "Hello, World!", timeout=20)
    device.expect(greeting == "Hello, World!", f"the greeting shows (found {greeting!r})")
    device.expect(device.find(text="Example") is not None, "the navigation title shows")
    device.screenshot("start")
    if greeting is None:
        crash = device.run("logcat", "-d", "-b", "crash", capture=True).decode(errors="replace")
        log = device.run("logcat", "-d", "-s", "AppRuntime:*", capture=True).decode(errors="replace")
        print(crash[-4000:] + log[-4000:], file=sys.stderr)
        return 1

    # Taps reach the guest, and its update comes back.
    plus = device.find(text="+")
    device.expect(plus is not None, "the + button shows")
    if plus:
        device.tap(plus)
        device.tap(plus)
        count = device.wait_for_text("count", "2")
        device.expect(count == "2", f"two taps on + count to 2 (found {count!r})")

    # Typing: the text field's changes update the greeting.
    field = device.find(text="World")
    device.expect(field is not None, "the name field shows")
    if field:
        device.tap(field)
        time.sleep(0.5)
        device.shell("input", "keyevent", "KEYCODE_MOVE_END")
        for _ in range(5):
            device.shell("input", "keyevent", "KEYCODE_DEL")
        device.shell("input", "text", "Ada")
        greeting = device.wait_for_text("greeting", "Hello, Ada!")
        device.expect(greeting == "Hello, Ada!", f"typing Ada updates the greeting (found {greeting!r})")
        device.shell("input", "keyevent", "KEYCODE_BACK")  # the keyboard
    device.screenshot("edited")

    # The lazy list: its rows come from the guest one at a time.
    # The picker has the same names, above the list: the rows are the lowest.
    rows = [device.find(text=name, timeout=5, last=True) for name in ("Apple", "Banana", "Cherry")]
    device.expect(all(rows), "the lazy list shows Apple, Banana and Cherry")

    # Navigation: a row pushes a level, its button reaches the guest, and
    # the system back gesture pops it.
    banana = device.find(text="Banana", last=True)
    if banana:
        device.tap(banana)
        like = device.find(text="Like (0)")
        device.expect(like is not None, "tapping Banana pushes its detail")
        device.screenshot("detail")
        if like:
            device.tap(like)
            device.expect(device.find(text="Like (1)") is not None, "Like counts in the detail")
        device.shell("input", "keyevent", "KEYCODE_BACK")
        device.expect(device.find(identifier="greeting") is not None, "back pops to the list")
        device.screenshot("back")

    print("PASS: ExampleUI" if not device.failures else f"FAIL: ExampleUI, {len(device.failures)} failed")
    return 0 if not device.failures else 1


if __name__ == "__main__":
    sys.exit(main())
