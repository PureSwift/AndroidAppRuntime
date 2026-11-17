#!/usr/bin/env python3
"""Drives AppRuntime's ExampleDefaults on the connected emulator or device
(Documentation/Plan.md §6.6), through UI Automator.

    Scripts/example-defaults-check.py [--adb PATH]

ExampleDefaults is a settings screen kept with @AppStorage: the count of
launches (`launches`), a Sound toggle, a volume slider, a Name field and a
greeting (`greeting`), a Theme button that cycles, a Reset button, and the
keys that are set (`keys`).

- the first launch counts 1, and the count is in the app's
  SharedPreferences file, shared_prefs/org.pureswift.appruntime.defaults.xml;
- turning Sound off, typing a name and picking a theme show at once, and
  are written to the file, under keys marked with their kind;
- after the app goes to the background and starts again, the launches are
  2 and the other settings are as they were;
- Reset removes every key, from the screen and from the file.

Exits non-zero if any check fails.
"""

import argparse
import re
import subprocess
import sys
import time
import xml.etree.ElementTree as ElementTree

PACKAGE = "org.pureswift.ExampleDefaults"
PREFERENCES = "shared_prefs/org.pureswift.appruntime.defaults.xml"


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
            self.run("shell", "uiautomator", "dump", "/sdcard/example-defaults.xml")
            tree = ElementTree.fromstring(self.run("shell", "cat", "/sdcard/example-defaults.xml"))
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


def stored(device, wait_for=None, timeout=10):
    """The app's preferences file as {key: value}, once `wait_for` accepts it."""
    deadline = time.time() + timeout
    values = {}
    while True:
        text = device.app("cat", PREFERENCES)
        values = {}
        try:
            for element in ElementTree.fromstring(text):
                values[element.get("name")] = element.text if element.tag == "string" else element.get("value")
        except ElementTree.ParseError:
            pass
        if wait_for is None or wait_for(values) or time.time() > deadline:
            return values
        time.sleep(0.5)


def leave_and_restart(device):
    """Home first, so the Activity stops and Android finishes the writes;
    then a new process."""
    device.run("shell", "input", "keyevent", "KEYCODE_HOME")
    time.sleep(2)
    device.run("shell", "am", "force-stop", PACKAGE)
    device.run("shell", "monkey", "-p", PACKAGE, "-c", "android.intent.category.LAUNCHER", "1")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--adb", default="adb")
    arguments = parser.parse_args()
    device = Device(arguments.adb)

    launches = device.text("launches", timeout=60)
    device.check(launches == "Launches: 1", f"the first launch counts 1 ({launches!r})")
    values = stored(device, lambda values: "s:launches" in values)
    device.check(values.get("s:launches") == "1", f"the count is in SharedPreferences as text ({values!r})")

    sound = device.wait(lambda node: node["checkable"], timeout=10)
    device.check(sound is not None and sound["checked"], "Sound starts on")
    if sound:
        device.tap(sound)
    device.check(device.wait(lambda node: node["checkable"] and not node["checked"], timeout=10) is not None,
                 "Sound turns off")
    device.check(device.field(0, "Ada"), "a name is typed")
    greeting = device.text("greeting", lambda text: text == "Hello, Ada", timeout=10)
    device.check(greeting == "Hello, Ada", f"the greeting uses the name ({greeting!r})")
    device.check(device.button("Theme: system"), "the theme starts as system")
    device.check(device.wait(lambda node: node["text"] == "Theme: light", timeout=10) is not None, "the theme moves to light")
    keys = device.text("keys", lambda text: text == "launches, name, soundOn, theme", timeout=10)
    device.check(keys == "launches, name, soundOn, theme", f"the keys are listed, sorted ({keys!r})")

    expected = {"s:launches": "1", "s:soundOn": "false", "s:name": "Ada", "s:theme": "light"}
    values = stored(device, lambda values: values == expected)
    device.check(values == expected, f"each is in SharedPreferences under its marked key ({values!r})")

    leave_and_restart(device)
    launches = device.text("launches", lambda text: text != "Launches: 1", timeout=60)
    device.check(launches == "Launches: 2", f"the second launch counts 2 ({launches!r})")
    greeting = device.text("greeting", timeout=10)
    device.check(greeting == "Hello, Ada", f"the name is kept ({greeting!r})")
    device.check(device.wait(lambda node: node["text"] == "Theme: light", timeout=5) is not None, "the theme is kept")
    sound = device.wait(lambda node: node["checkable"], timeout=5)
    device.check(sound is not None and not sound["checked"], "Sound is still off")

    device.check(device.button("Reset"), "Reset is there")
    launches = device.text("launches", lambda text: text == "Launches: 0", timeout=10)
    device.check(launches == "Launches: 0", f"Reset clears the count on screen ({launches!r})")
    keys = device.text("keys", lambda text: text == "", timeout=3)
    device.check(device.wait(lambda node: node["id"] == "keys" and node["text"], timeout=2) is None, "no keys are listed")
    values = stored(device, lambda values: not values)
    device.check(not values, f"Reset empties SharedPreferences ({values!r})")

    errors = device.run("logcat", "-d", "-s", "AppRuntime:E").splitlines()
    errors = [line for line in errors if "efault" in line or "reference" in line]
    device.check(not errors, "no errors in logcat" + "".join(f"\n       {line}" for line in errors))
    print("ok" if device.failures == 0 else f"{device.failures} failed")
    return 1 if device.failures else 0


if __name__ == "__main__":
    sys.exit(main())
