#!/usr/bin/env python3
"""Looks at AppRuntime's ExampleGL on the connected emulator or device
(Documentation/Plan.md §6.3), by the screen's pixels and UI Automator.

    Scripts/example-gl-check.py [--adb PATH] [--screens DIR]

ExampleGL draws a triangle that turns one radian a second on a dark
background, between the text "OpenGL ES 2.0" and the direction it turns.
A tap on it reverses the turn, Space pauses it, and the Pause button
toggles the same. The checks:

- the surface is dark at its corner and colored at its center: GL drew;
- two screenshots apart differ inside it: frames keep coming;
- a tap on it says "Clockwise": pointers reach the guest;
- Space (a key event) says "Resume", and the surface stops changing: keys
  reach the guest, which has focus from the tap;
- after Home and back, it draws and turns again: the surface reattaches.

Exits non-zero if any check fails. --screens keeps the screenshots.
"""

import argparse
import re
import struct
import subprocess
import sys
import time
import xml.etree.ElementTree as ElementTree
from pathlib import Path

PACKAGE = "org.pureswift.ExampleGL"
BACKGROUND = (20, 20, 26)


class Device:

    def __init__(self, adb, screens):
        self.adb = adb
        self.screens = screens
        self.failures = 0
        self.shots = 0

    def run(self, *arguments, binary=False):
        result = subprocess.run([self.adb, *arguments], check=True, capture_output=True, text=not binary)
        return result.stdout

    def nodes(self):
        """The screen's views; none while the app is still starting, when
        UI Automator has nothing to dump."""
        try:
            self.run("shell", "uiautomator", "dump", "/sdcard/example-gl.xml")
            tree = ElementTree.fromstring(self.run("shell", "cat", "/sdcard/example-gl.xml"))
        except (subprocess.CalledProcessError, ElementTree.ParseError):
            return []
        return list(tree.iter("node"))

    @staticmethod
    def bounds(node):
        return tuple(map(int, re.findall(r"\d+", node.get("bounds"))))

    def find(self, text, timeout=15):
        """The bounds of the first view showing `text`, or None."""
        deadline = time.time() + timeout
        while time.time() < deadline:
            for node in self.nodes():
                if node.get("text") == text:
                    return self.bounds(node)
            time.sleep(0.5)
        return None

    def tap(self, x, y):
        self.run("shell", "input", "tap", str(x), str(y))

    def screenshot(self):
        """The screen as (width, height, RGBA bytes)."""
        data = self.run("exec-out", "screencap", binary=True)
        width, height = struct.unpack_from("<II", data)
        header = len(data) - width * height * 4
        pixels = data[header:]
        self.shots += 1
        if self.screens:
            self.screens.mkdir(parents=True, exist_ok=True)
            path = self.screens / f"{self.shots}.ppm"
            rgb = bytearray()
            for index in range(0, len(pixels), 4):
                rgb += pixels[index:index + 3]
            path.write_bytes(f"P6\n{width} {height}\n255\n".encode() + bytes(rgb))
        return width, height, pixels

    def check(self, condition, message):
        print(("ok   " if condition else "FAIL ") + message)
        if not condition:
            self.failures += 1
        return condition


def pixel(shot, x, y):
    width, _, pixels = shot
    index = (y * width + x) * 4
    return tuple(pixels[index:index + 3])


def is_background(color):
    return all(abs(a - b) <= 6 for a, b in zip(color, BACKGROUND))


def region(shot, box):
    """The pixels inside `box`, every fourth row and column."""
    left, top, right, bottom = box
    return [pixel(shot, x, y) for y in range(top, bottom, 4) for x in range(left, right, 4)]


def differs(first, second, box):
    a, b = region(first, box), region(second, box)
    return sum(1 for p, q in zip(a, b) if p != q)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--adb", default="adb")
    parser.add_argument("--screens", type=Path)
    arguments = parser.parse_args()
    device = Device(arguments.adb, arguments.screens)

    # The surface fills the width between the headline and the direction.
    headline = device.find("OpenGL ES 2.0", timeout=30)
    direction = device.find("Counter-clockwise")
    if not device.check(headline is not None and direction is not None, "the app shows its text around the surface"):
        return 1
    # Its edges: where ExampleGL's background starts, from the left of the
    # gap between them and down from the headline.
    shot = device.screenshot()
    width = shot[0]
    middle_row = (headline[3] + direction[1]) // 2
    left = next((x for x in range(width // 2) if is_background(pixel(shot, x, middle_row))), None)
    top = next((y for y in range(headline[3], direction[1]) if is_background(pixel(shot, 4 + (left or 0), y))), None)
    if not device.check(left is not None and top is not None, "the surface is on screen between them"):
        return 1
    right = width - left
    bottom = next((y for y in range(direction[1], top, -1) if is_background(pixel(shot, left + 4, y))), direction[1])
    box = (left, top, right, bottom)
    center = ((left + right) // 2, (top + bottom) // 2)
    print(f"·    surface {box}, center {center}")

    time.sleep(1)
    first = device.screenshot()
    corner = pixel(first, box[0] + 2, box[1] + 2)
    middle = pixel(first, *center)
    print(f"·    corner {corner}, center {middle}")
    device.check(is_background(corner), "GL cleared the surface to ExampleGL's background")
    device.check(not is_background(middle) and max(middle) > 60, "the triangle is drawn at the center")

    time.sleep(0.5)
    second = device.screenshot()
    device.check(differs(first, second, box) > 20, "the triangle turns: frames keep coming")

    device.tap(*center)
    device.check(device.find("Clockwise", timeout=5) is not None, "a tap on the surface reverses the turn")

    device.run("shell", "input", "keyevent", "KEYCODE_SPACE")
    device.check(device.find("Resume", timeout=5) is not None, "Space pauses it: keys reach the focused surface")
    time.sleep(0.3)
    paused = device.screenshot()
    time.sleep(0.5)
    still = device.screenshot()
    device.check(differs(paused, still, box) == 0, "while paused, the frames are the same")

    resume = device.find("Resume")
    if resume:
        device.tap((resume[0] + resume[2]) // 2, (resume[1] + resume[3]) // 2)
    device.check(device.find("Pause", timeout=5) is not None, "the Pause button resumes it")

    device.run("shell", "input", "keyevent", "KEYCODE_HOME")
    time.sleep(1.5)
    device.run("shell", "monkey", "-p", PACKAGE, "-c", "android.intent.category.LAUNCHER", "1")
    device.find("OpenGL ES 2.0")
    time.sleep(1)
    back = device.screenshot()
    time.sleep(0.5)
    later = device.screenshot()
    device.check(not is_background(pixel(back, *center)) and differs(back, later, box) > 20,
                 "after Home and back, it draws and turns again")

    errors = [line for line in device.run("logcat", "-d", "-s", "AppRuntime:E").splitlines() if "GLSurface" in line or "GL context" in line]
    device.check(not errors, "no surface errors in logcat" + ("".join(f"\n       {line}" for line in errors)))
    print("ok" if device.failures == 0 else f"{device.failures} failed")
    return 1 if device.failures else 0


if __name__ == "__main__":
    sys.exit(main())
