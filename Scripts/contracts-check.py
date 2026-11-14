#!/usr/bin/env python3
"""Reads Examples/ContractsCheck's lines on the connected emulator and makes
the things it waits for happen (Documentation/Plan.md §10).

    Scripts/contracts-check.py [--adb PATH]

The lines come from the player's trace in logcat (`log.tag.AppRuntime`
DEBUG), which has every tree the app sends, so nothing needs scrolling.
Each `ok` or `FAIL` line is a check; `·` lines are notes. Exits non-zero if
any check fails or an expected line doesn't come.
"""

import argparse
import re
import subprocess
import sys
import time
import xml.etree.ElementTree as ElementTree

PACKAGE = "org.pureswift.ContractsCheck"
TEXT = re.compile(r"text=Str\(value=(.*)\)\}?$")


class Device:

    def __init__(self, adb):
        self.adb = adb
        self.lines = []

    def run(self, *arguments):
        return subprocess.run([self.adb, *arguments], check=True, capture_output=True, text=True).stdout

    def emulator(self, *command):
        """An emulator console command (`adb emu`)."""
        self.run("emu", *command)

    def read(self):
        """Every line the app has shown, in order, without repeats."""
        for entry in self.run("logcat", "-d", "-s", "AppRuntime:D").splitlines():
            match = TEXT.search(entry)
            if match and match.group(1) not in self.lines:
                self.lines.append(match.group(1))
        return self.lines

    def tap(self, *texts, timeout=10):
        """Taps the first view whose text is one of `texts`, such as a system
        dialog's button; whether it found one."""
        deadline = time.time() + timeout
        while time.time() < deadline:
            self.run("shell", "uiautomator", "dump", "/sdcard/contracts-check.xml")
            tree = ElementTree.fromstring(self.run("shell", "cat", "/sdcard/contracts-check.xml"))
            for node in tree.iter("node"):
                if node.get("text") in texts:
                    left, top, right, bottom = map(int, re.findall(r"\d+", node.get("bounds")))
                    self.run("shell", "input", "tap", str((left + right) // 2), str((top + bottom) // 2))
                    return True
            time.sleep(0.5)
        return False

    def wait(self, prefix, timeout=20):
        """The first line starting with `prefix`, once it shows."""
        deadline = time.time() + timeout
        while time.time() < deadline:
            for line in self.read():
                if line.startswith(prefix) or line.startswith("FAIL " + prefix.removeprefix("ok ")):
                    return line
            time.sleep(0.5)
        return None


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--adb", default="adb")
    arguments = parser.parse_args()
    device = Device(arguments.adb)
    missing = []

    def expect(prefix, timeout=20):
        line = device.wait(prefix, timeout)
        if line is None:
            missing.append(prefix)
        return line

    def expect_match(pattern, name, timeout=20):
        deadline = time.time() + timeout
        while time.time() < deadline:
            if any(re.fullmatch(pattern, line) for line in device.read()):
                return True
            time.sleep(0.5)
        missing.append(name)
        return False

    # The checks that run at launch.
    expect("ok device.systemName")
    expect("ok locale.unknown")

    # Device: the battery listener, from the emulator's console.
    device.emulator("power", "ac", "on")
    device.emulator("power", "capacity", "42")
    expect("ok device.didChangeBatteryLevel 42%")
    device.emulator("power", "capacity", "100")
    expect("ok device.didChangeOrientation")

    # Location: answer the prompt, then move the emulator's GPS.
    if expect("· location.requesting"):
        if not device.tap("While using the app", "Only this time"):
            missing.append("the location prompt")
        expect("ok location.didChangeAuthorization 4 0")
        device.emulator("geo", "fix", "2.294500", "48.858400")
        expect("ok location.update 1 488584 22945", timeout=30)
        device.emulator("geo", "fix", "-122.084000", "37.422000")
        expect_match(r"ok location\.update \d+ 374220 -1220840", "ok location.update … 374220 -1220840", timeout=30)
        if "· location.isHeadingAvailable true" in device.read():
            expect("ok location.didUpdateHeading")

    # Bluetooth: the Nearby devices prompt, then a scan. What it finds
    # depends on what's around: those lines are notes.
    if expect("· bluetooth.requesting"):
        if not device.tap("Allow"):
            missing.append("the Nearby devices prompt")
        expect("ok bluetooth.didChangeAuthorization 3")
        expect("ok bluetooth.isScanning")

    # Motion: the first samples, then the activity recognition prompt.
    expect("ok motion.didUpdateAcceleration")
    if expect("· motion.requesting"):
        if not device.tap("Allow"):
            missing.append("the physical activity prompt")
        expect("ok motion.pedometer didChangeAuthorization 3")

    # NFC: the emulator has none, so the session fails as it should.
    expect("· nfc.done")
    device.wait("· bluetooth.discovered", timeout=10)

    # Networking runs by itself, one request at a time.
    expect("· network.done", timeout=90)

    lines = device.read()
    for line in lines:
        print(line)
    failures = [line for line in lines if line.startswith("FAIL ")]
    for prefix in missing:
        print(f"missing: {prefix}", file=sys.stderr)
    checks = sum(1 for line in lines if line.startswith(("ok ", "FAIL ")))
    print(f"{checks - len(failures)} of {checks} checks passed; {len(missing)} expected lines missing")
    sys.exit(1 if failures or missing else 0)


if __name__ == "__main__":
    main()
