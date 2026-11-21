#!/usr/bin/env python3
"""Drives AppRuntime's ExampleNotifications, and the notification shade, on
the connected emulator or device (Documentation/Plan.md §6.9), through UI
Automator.

    Scripts/example-notifications-check.py [--adb PATH]

ExampleNotifications is kitchen timers: a `permission` line, Allow, Start
5 min, Notify Now, Register, a Cancel button per timer still running, the
`response` to the last notification, what was `received` while the app
was open, the push `address`, and a `status` line. Its category `timer`
has Repeat and Stop buttons.

- Allow shows Android's prompt, once, and the answer is the app's;
- Register answers `unsupported` (4): the host has no push service;
- Notify Now posts a notification in the default channel, which the app
  hears while it's open; tapping it in the shade opens the app with it;
- Start 5 min sets an alarm, and Cancel takes it away;
- a timer rings with the app's process gone: the alarm starts the process
  and posts the notification in the timer channel, with its buttons; Stop
  opens the app, which stops it.

The last part waits for a real alarm: five minutes, and up to four more,
since the app doesn't ask for exact timing. Exits non-zero if any check
fails.
"""

import argparse
import re
import subprocess
import sys
import time
import xml.etree.ElementTree as ElementTree

PACKAGE = "org.pureswift.ExampleNotifications"


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
            self.run("shell", "rm", "-f", "/sdcard/example-notifications.xml")
            self.run("shell", "uiautomator", "dump", "/sdcard/example-notifications.xml")
            tree = ElementTree.fromstring(self.run("shell", "cat", "/sdcard/example-notifications.xml"))
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


def notifications(device):
    """The app's notifications showing now: tag and channel of each."""
    output = device.run("shell", "dumpsys", "notification", "--noredact")
    found = re.findall(r"pkg=" + re.escape(PACKAGE) + r" user=\S+ id=21076 tag=(\S+) .*?Notification\(channel=(\S+)", output)
    return dict(found)


def alarms(device):
    """How many of the app's notification alarms are set."""
    output = device.run("shell", "dumpsys", "alarm")
    # The pending alarms, between the next alarm clock and the store's stats.
    start = output.find("Next alarm clock information")
    end = output.find("LazyAlarmStore stats")
    pending = output[max(start, 0):end if end > start else len(output)]
    return len(re.findall(r"RTC_WAKEUP #\d+: Alarm\{\S+ type \d+ origWhen \d+ whenElapsed \d+ " + re.escape(PACKAGE) + r"\}", pending))


def pid(device):
    return device.run("shell", "pidof", PACKAGE, check=False).strip() or None


def shade(device, title):
    """Opens the shade, and the notification titled `title` in it."""
    device.run("shell", "cmd", "statusbar", "expand-notifications")
    return device.wait(lambda node: node["text"] == title and node["id"] == "title", timeout=10)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--adb", default="adb")
    arguments = parser.parse_args()
    device = Device(arguments.adb)

    permission = device.text("permission", lambda text: text == "Not asked", timeout=60)
    device.check(permission == "Not asked", f"the app starts with permission not asked ({permission!r})")
    device.check(device.button("Allow"), "Allow")
    allow = device.wait(lambda node: node["id"] == "permission_allow_button", timeout=10)
    device.check(allow is not None, "Android asks")
    if allow:
        device.tap(allow)
    permission = device.text("permission", lambda text: text != "Not asked", timeout=10)
    device.check(permission == "Allowed", f"and the answer is the app's ({permission!r})")

    device.check(device.button("Register"), "Register")
    address = device.text("address", timeout=10)
    device.check(address == "Push: error 4", f"push is unsupported here ({address!r})")

    # Now, while the app is open.
    device.check(device.button("Notify Now"), "Notify Now")
    status = device.text("status", lambda text: text == "Shown", timeout=10)
    device.check(status == "Shown", f"is shown ({status!r})")
    received = device.text("received", timeout=10)
    device.check(received == "Rang: Timers", f"the app hears of it ({received!r})")
    showing = notifications(device)
    device.check(showing.get("now") == "rt.default", f"it's in the shade, in the default channel ({showing!r})")
    title = shade(device, "Timers")
    device.check(title is not None, "the shade shows it")
    if title:
        device.tap(title)
    response = device.text("response", lambda text: text.startswith("Opened"), timeout=10)
    device.check(response == "Opened now", f"a tap opens the app with it ({response!r})")
    time.sleep(1)
    device.check("now" not in notifications(device), "and takes it out of the shade")

    # Scheduled, and cancelled.
    device.check(device.button("Start 5 min"), "Start 5 min")
    status = device.text("status", lambda text: text.startswith("Started"), timeout=10)
    device.check(status == "Started timer-1", f"a timer starts ({status!r})")
    device.check(alarms(device) == 1, "an alarm is set")
    device.check(device.button("Cancel timer-1"), "Cancel timer-1")
    status = device.text("status", lambda text: text.startswith("Cancelled"), timeout=10)
    device.check(status == "Cancelled timer-1", f"cancels it ({status!r})")
    device.check(alarms(device) == 0, "and its alarm")

    # Scheduled, and rung with the app's process gone.
    device.check(device.button("Start 5 min"), "Start 5 min again")
    status = device.text("status", lambda text: text == "Started timer-2", timeout=10)
    device.check(status == "Started timer-2", f"a second timer starts ({status!r})")
    device.run("shell", "input", "keyevent", "KEYCODE_HOME")
    time.sleep(2)
    running = pid(device)
    if running:
        # Not force-stop, which would cancel the app's alarms.
        device.run("shell", "run-as", PACKAGE, "kill", "-9", running, check=False)
    time.sleep(2)
    device.check(pid(device) is None, "the app's process is gone")
    print("     waiting for the alarm: up to ten minutes")
    deadline = time.time() + 600
    while time.time() < deadline and "timer-2" not in notifications(device):
        time.sleep(10)
    showing = notifications(device)
    device.check(showing.get("timer-2") == "rt.c.timer", f"the alarm posts it, in the timer channel ({showing!r})")
    device.check(pid(device) is not None, "the alarm started the app's process")
    title = shade(device, "Timer 2")
    device.check(title is not None, "the shade shows it")
    stop = device.wait(lambda node: node["text"].lower() == "stop", timeout=10)
    device.check(stop is not None, "with its Stop button")
    if stop:
        device.tap(stop)
    response = device.text("response", lambda text: text.startswith("Stopped"), timeout=30)
    device.check(response == "Stopped timer-2", f"Stop opens the app, which stops it ({response!r})")
    time.sleep(1)
    device.check("timer-2" not in notifications(device), "and it leaves the shade")

    errors = device.run("logcat", "-d", "-s", "AppRuntime:E").splitlines()
    errors = [line for line in errors if " E " in line or "error" in line.lower()]
    device.check(not errors, "no errors in logcat" + "".join(f"\n       {line}" for line in errors))
    print("ok" if device.failures == 0 else f"{device.failures} failed")
    return 1 if device.failures else 0


if __name__ == "__main__":
    sys.exit(main())
