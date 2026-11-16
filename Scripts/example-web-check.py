#!/usr/bin/env python3
"""Drives AppRuntime's ExampleWeb on the connected emulator or device
(Documentation/Plan.md §6.4), through UI Automator.

    Scripts/example-web-check.py [--adb PATH] [--no-network]

ExampleWeb is a small browser: Back, Forward, Reload and Count links
buttons, an address field, a WebView, and the page's title (`title`), the
last script's or refusal's status (`status`) and a load error (`error`)
below it. It starts at https://swift.org/.

With the network capability:
- swift.org loads in the WebView and its title shows;
- Count links runs a script in the page and shows a count;
- an address typed in the field loads example.com;
- Back goes to swift.org again and Forward to example.com.

With --no-network, for an app built without the capability: the page fails
with WebError.Code.notPermitted, and nothing loads.

Exits non-zero if any check fails.
"""

import argparse
import re
import subprocess
import sys
import time
import xml.etree.ElementTree as ElementTree


class Device:

    def __init__(self, adb):
        self.adb = adb
        self.failures = 0

    def run(self, *arguments):
        return subprocess.run([self.adb, *arguments], check=True, capture_output=True, text=True).stdout

    def nodes(self):
        """Every view on screen; none while UI Automator has nothing to dump."""
        try:
            self.run("shell", "uiautomator", "dump", "/sdcard/example-web.xml")
            tree = ElementTree.fromstring(self.run("shell", "cat", "/sdcard/example-web.xml"))
        except (subprocess.CalledProcessError, ElementTree.ParseError):
            return []
        found = []

        # A disabled button's label still says it's enabled: a view is
        # enabled only if every view around it is.
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

    def check(self, condition, message):
        print(("ok   " if condition else "FAIL ") + message)
        if not condition:
            self.failures += 1
        return condition


def online(device):
    title = device.text("title", timeout=60)
    device.check(title is not None, f"swift.org loads and its title shows ({title!r})")
    device.check(device.wait(lambda node: node["class"] == "android.webkit.WebView", timeout=5) is not None,
                 "the page shows in a WebView where the node is")

    device.check(device.button("Count links"), "Count links is there")
    status = device.text("status", lambda text: text.startswith("Links: ") or text.startswith("Script"), timeout=15)
    count = int(status.split(": ")[1]) if status and status.startswith("Links: ") and status.split(": ")[1].isdigit() else 0
    device.check(count > 0, f"a script in the page counts its links ({status!r})")

    field = device.wait(lambda node: node["class"] == "android.widget.EditText", timeout=10)
    if device.check(field is not None, "the address field shows"):
        device.tap(field)
        time.sleep(0.5)
        device.run("shell", "input", "keyevent", "KEYCODE_MOVE_END")
        device.run("shell", "input", "keyevent", *(["KEYCODE_DEL"] * 60))
        device.run("shell", "input", "text", "https://example.com/")
        device.run("shell", "input", "keyevent", "KEYCODE_ENTER")
        loaded = device.text("title", lambda text: text == "Example Domain", timeout=45)
        device.check(loaded is not None, "an address loads example.com")
        device.run("shell", "input", "keyevent", "KEYCODE_BACK")  # the keyboard

    device.check(device.button("Back", timeout=15), "Back is enabled after a second page")
    back = device.text("title", lambda text: text == title, timeout=45)
    device.check(back is not None, f"Back shows swift.org again ({title!r})")
    device.check(device.button("Forward", timeout=15), "Forward is enabled after Back")
    forward = device.text("title", lambda text: text == "Example Domain", timeout=45)
    device.check(forward is not None, "Forward shows example.com again")


def offline(device):
    error = device.text("error", lambda text: text.startswith("Couldn't load the page"), timeout=30)
    device.check(error is not None and "network capability" in error, f"the page fails as not permitted ({error!r})")
    time.sleep(3)
    title = device.text("title", timeout=1)
    device.check(not title, "nothing loads")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--adb", default="adb")
    parser.add_argument("--no-network", action="store_true")
    arguments = parser.parse_args()
    device = Device(arguments.adb)
    if arguments.no_network:
        offline(device)
    else:
        online(device)
    errors = [line for line in device.run("logcat", "-d", "-s", "AppRuntime:E").splitlines() if "page" in line]
    device.check(not errors, "no page errors in logcat" + "".join(f"\n       {line}" for line in errors))
    print("ok" if device.failures == 0 else f"{device.failures} failed")
    return 1 if device.failures else 0


if __name__ == "__main__":
    sys.exit(main())
