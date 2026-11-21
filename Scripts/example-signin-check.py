#!/usr/bin/env python3
"""Drives AppRuntime's ExampleSignIn, Chrome's Custom Tab, and the
provider's redirect, on the connected emulator or device
(Documentation/Plan.md §6.12), through UI Automator.

    Scripts/example-signin-check.py [--adb PATH]

ExampleSignIn signs in through the system's browser and keeps the token
it's given in the Keychain: a `status` line, whether a `token` is kept,
Sign In, Sign In Privately, Cancel and Sign Out. Its provider,
id.example.com, doesn't exist: the check plays it, reading the page's
`state` from the Custom Tab's intent and sending the redirect to the app's
scheme as the browser would.

- the first read of the Keychain finds no token, without an error;
- Sign In shows the page in a Custom Tab, and Back from it is a cancelled
  sign-in;
- the provider's redirect, with the page's `state`, reaches the app, which
  keeps its token: a file in `no_backup`, encrypted;
- the token is there after the app starts again, and Sign Out removes it;
- a private sign-in shows its page too.

Exits non-zero if any check fails.
"""

import argparse
import re
import subprocess
import sys
import time
import xml.etree.ElementTree as ElementTree

PACKAGE = "org.pureswift.ExampleSignIn"
SCHEME = "org.pureswift.example.signin"


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
            self.run("shell", "rm", "-f", "/sdcard/example-signin.xml")
            self.run("shell", "uiautomator", "dump", "/sdcard/example-signin.xml")
            tree = ElementTree.fromstring(self.run("shell", "cat", "/sdcard/example-signin.xml"))
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


def status(device, test, timeout=20):
    return device.text("status", test, timeout=timeout)


def page(device):
    """Waits for the sign-in page, past Chrome's first-run screens: the
    Custom Tab's close button, or Chrome's own address bar; None if none."""
    deadline = time.time() + 30
    while time.time() < deadline:
        for node in device.nodes():
            if node["id"] in ("signin_fre_dismiss_button", "negative_button"):
                # Stay signed out; no notifications.
                device.tap(node)
                time.sleep(2)
                break
            if node["id"] == "close_button" and node["desc"] == "Close tab":
                return "tab"
            if node["id"] == "url_bar" and node["text"].startswith("id.example.com/"):
                return "chrome"
        else:
            time.sleep(1)
    return None


def state(device):
    """The page's state, from the Custom Tab's intent."""
    output = device.run("shell", "dumpsys", "activity", "activities")
    found = re.findall(r"dat=https://id\.example\.com/authorize\?\S*?state=([0-9a-f]+)", output)
    return found[-1] if found else None


def secrets(device):
    return device.run("shell", "run-as", PACKAGE, "ls", "no_backup/appruntime-secrets", check=False).split()


def sign_in(device, button="Sign In"):
    """Taps `button` and waits for a Custom Tab. Chrome's first run may show
    the page in Chrome itself: then it's left, and the app asked again."""
    for _ in range(2):
        if not device.button(button, timeout=15):
            return None
        shown = page(device)
        if shown != "chrome":
            return shown
        device.run("shell", "input", "keyevent", "KEYCODE_BACK")
        device.run("shell", "monkey", "-p", PACKAGE, "-c", "android.intent.category.LAUNCHER", "1")
        status(device, lambda text: text != "Signing in")
    return None


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--adb", default="adb")
    arguments = parser.parse_args()
    device = Device(arguments.adb)

    found = status(device, lambda text: text.startswith("Signed"), timeout=60)
    token = device.text("token", timeout=5)
    device.check((found, token) == ("Signed out", "No token"), f"the first read of the Keychain finds no token ({found!r}, {token!r})")

    device.check(sign_in(device) == "tab", "Sign In shows the page in a Custom Tab")
    device.run("shell", "input", "keyevent", "KEYCODE_BACK")
    found = status(device, lambda text: text != "Signing in")
    device.check(found == "Sign-in cancelled", f"Back from it cancels the sign-in ({found!r})")

    device.check(sign_in(device) == "tab", "Sign In again")
    expected = state(device)
    device.check(expected is not None, f"the page carries a state ({expected})")
    device.run("shell", "am", "start", "-W", "-a", "android.intent.action.VIEW", "-c", "android.intent.category.BROWSABLE",
               "-d", f"'{SCHEME}:/oauth?code=abc123&state={expected}'")
    found = status(device, lambda text: text not in ("Signing in", "Sign-in cancelled"))
    token = device.text("token", lambda text: text != "No token", timeout=10)
    device.check((found, token) == ("Signed in", "A token is kept"), f"the redirect signs in, and the token is kept ({found!r}, {token!r})")
    kept = secrets(device)
    device.check(len(kept) == 1 and len(kept[0]) == 64, f"as one file in no_backup, named by a hash ({kept})")
    contents = subprocess.run([device.adb, "exec-out", "run-as", PACKAGE, "cat", "no_backup/appruntime-secrets/" + (kept[0] if kept else "none")],
                              capture_output=True).stdout
    device.check(bool(kept) and len(contents) > 12 and b"abc123" not in contents and b"account.token" not in contents,
                 f"encrypted: neither the token nor its key is in its {len(contents)} bytes")

    device.run("shell", "am", "force-stop", PACKAGE)
    device.run("shell", "monkey", "-p", PACKAGE, "-c", "android.intent.category.LAUNCHER", "1")
    found = status(device, lambda text: text.startswith("Signed"), timeout=60)
    device.check(found == "Signed in", f"after a restart, the Keystore gives the token back ({found!r})")
    device.check(device.button("Sign Out"), "Sign Out")
    found = status(device, lambda text: text == "Signed out")
    device.check(found == "Signed out" and secrets(device) == [], f"removes it ({found!r}, {secrets(device)})")

    device.check(sign_in(device, "Sign In Privately") == "tab", "a private sign-in shows its page too")
    device.run("shell", "input", "keyevent", "KEYCODE_BACK")
    found = status(device, lambda text: text != "Signing in")
    device.check(found == "Sign-in cancelled", f"and Back cancels it ({found!r})")

    errors = device.run("logcat", "-d", "-s", "AppRuntime:E").splitlines()
    errors = [line for line in errors if " E " in line or "error" in line.lower()]
    device.check(not errors, "no errors in logcat" + "".join(f"\n       {line}" for line in errors))
    print("ok" if device.failures == 0 else f"{device.failures} failed")
    return 1 if device.failures else 0


if __name__ == "__main__":
    sys.exit(main())
