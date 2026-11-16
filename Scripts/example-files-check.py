#!/usr/bin/env python3
"""Drives AppRuntime's ExampleFiles on the connected emulator or device
(Documentation/Plan.md §6.5), through UI Automator.

    Scripts/example-files-check.py [--adb PATH] [--apk PATH]

ExampleFiles is a notebook kept as text files: a welcome text from the
bundle (`welcome`), Title and Text fields, Save and Export buttons, a
button for each note and one to delete it, the opened note's text
(`opened`) and a status line (`status`).

- the APK has the resources, including ones named with "." and "_", and
  the index Files lists them from;
- the welcome text is read from the bundle;
- a saved note is listed, and its file is in filesDir/Documents/notes;
- opening it shows its text;
- Export writes every note into cacheDir/Caches/exports/all.txt;
- Delete removes it, from the list and from the disk;
- after the app starts again, the notes are still there and temporary
  (cacheDir/tmp) is empty.

Exits non-zero if any check fails.
"""

import argparse
import re
import subprocess
import sys
import time
import xml.etree.ElementTree as ElementTree

PACKAGE = "org.pureswift.ExampleFiles"


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
            self.run("shell", "uiautomator", "dump", "/sdcard/example-files.xml")
            tree = ElementTree.fromstring(self.run("shell", "cat", "/sdcard/example-files.xml"))
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


def check_apk(device, apk):
    try:
        listing = subprocess.run(["unzip", "-l", apk], check=True, capture_output=True, text=True).stdout
    except (subprocess.CalledProcessError, FileNotFoundError) as error:
        device.check(False, f"the APK can be listed ({error})")
        return
    for path in ["assets/rt/resources.index", "assets/rt/resources/welcome.txt", "assets/rt/resources/.hidden",
                 "assets/rt/resources/levels/_extra/2.map"]:
        device.check(path in listing, f"the APK has {path}")


def save(device, title, text):
    device.check(device.field(0, title) and device.field(1, text), f"a title and text are typed for {title}")
    device.check(device.button("Save"), "Save is there")
    status = device.text("status", lambda value: value.startswith("Saved") or value.startswith("Couldn't"), timeout=15)
    device.check(status == f"Saved {title}", f"{title} is saved ({status!r})")
    device.check(device.wait(lambda node: node["text"] == title, timeout=10) is not None, f"{title} is listed")
    on_disk = device.app("cat", f"files/Documents/notes/{title}.txt")
    device.check(on_disk == text, f"{title}'s file is in filesDir/Documents/notes ({on_disk!r})")


def restart(device):
    device.run("shell", "am", "force-stop", PACKAGE)
    device.run("shell", "monkey", "-p", PACKAGE, "-c", "android.intent.category.LAUNCHER", "1")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--adb", default="adb")
    parser.add_argument("--apk")
    arguments = parser.parse_args()
    device = Device(arguments.adb)
    if arguments.apk:
        check_apk(device, arguments.apk)

    welcome = device.text("welcome", timeout=60)
    device.check(welcome == "Welcome to the notebook, from the bundle.", f"the welcome text is read from the bundle ({welcome!r})")

    save(device, "first", "hello")
    save(device, "second", "world")

    device.check(device.button("first"), "first can be opened")
    opened = device.text("opened", lambda value: value == "hello", timeout=10)
    device.check(opened == "hello", f"opening first shows its text ({opened!r})")

    device.check(device.button("Export"), "Export is there")
    status = device.text("status", lambda value: value.startswith("Export") or value.startswith("Couldn't"), timeout=15)
    exported = device.app("cat", "cache/Caches/exports/all.txt")
    device.check(status is not None and status.startswith("Exported 2 notes"), f"Export reports the notes ({status!r})")
    device.check(exported == "# first\nhello\n# second\nworld\n", f"the export is in cacheDir/Caches ({exported!r})")

    device.check(device.button("Delete first"), "first can be deleted")
    status = device.text("status", lambda value: value.startswith("Deleted") or value.startswith("Couldn't"), timeout=15)
    device.check(status == "Deleted first", f"first is deleted ({status!r})")
    time.sleep(1)
    device.check(device.wait(lambda node: node["text"] == "first", timeout=2) is None, "first isn't listed")
    listing = device.app("ls", "files/Documents/notes")
    device.check(listing.split() == ["second.txt"], f"first's file is gone ({listing.split()!r})")

    # Something left in temporary, which the next start empties.
    device.app("mkdir", "-p", "cache/tmp")
    device.app("touch", "cache/tmp/leftover")
    restart(device)
    welcome = device.text("welcome", timeout=60)
    device.check(device.wait(lambda node: node["text"] == "second", timeout=15) is not None, "second is still listed after a restart")
    leftover = device.app("ls", "cache/tmp")
    device.check(leftover.strip() == "", f"temporary is emptied at start ({leftover.strip()!r})")

    errors = [line for line in device.run("logcat", "-d", "-s", "AppRuntime:E").splitlines() if "Files" in line or "file" in line]
    device.check(not errors, "no file errors in logcat" + "".join(f"\n       {line}" for line in errors))
    print("ok" if device.failures == 0 else f"{device.failures} failed")
    return 1 if device.failures else 0


if __name__ == "__main__":
    sys.exit(main())
