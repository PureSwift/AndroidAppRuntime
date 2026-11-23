#!/usr/bin/env python3
"""Drives AppRuntime's ExampleCamera, and Android's permission dialogs, on
the connected emulator or device (Documentation/Plan.md §6.19), through UI
Automator, reading what it saved with `adb shell content`.

    Scripts/example-camera-check.py [--adb PATH]

ExampleCamera is a viewfinder: a `CameraPreview`, a `camera` line (which
camera, its state, its zoom, and whether it has a flash), a `recording`
line, Allow, Shoot, Record (or Stop), Flip and Zoom, the `last` thing
taken, and a `status` line. It saves what it takes to the user's photos,
which it may only add to. The emulator's back camera is a rendered room
and its front camera a pattern. Then:

- Allow asks with Android's dialog, and the back camera comes on, and the
  preview shows its picture;
- Shoot writes a photo, upright, which is added to the user's photos;
- Zoom keeps the back camera, which can't zoom on the emulator, at 1;
  Flip turns the front camera on, with its flash, and Zoom doubles its
  zoom;
- Record asks for the microphone, records with sound, and Stop gives the
  video, which is added to the user's photos;
- leaving the app during a recording turns the camera off and keeps the
  video, cut short, and coming back turns the camera on again.

The check removes what the app saved when it's done.

Exits non-zero if any check fails.
"""

import argparse
import importlib.util
import io
import os
import re
import subprocess
import sys
import time

from PIL import Image, ImageStat

PACKAGE = "org.pureswift.ExampleCamera"

# The media check's device helpers, for this app.
_spec = importlib.util.spec_from_file_location("example_media_check",
                                               os.path.join(os.path.dirname(__file__), "example-media-check.py"))
media = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(media)
media.PACKAGE = PACKAGE


def saved(device):
    """What the app added to the user's photos: each file's name and type."""
    output = device.run("shell", "content query --uri content://media/external/file --projection _display_name:mime_type "
                        f"--where \"owner_package_name='{PACKAGE}'\"", check=False)
    return re.findall(r"_display_name=([^,]+), mime_type=(\S+)", output)


def forget(device):
    device.run("shell", f"content delete --uri content://media/external/file --where \"owner_package_name='{PACKAGE}'\"",
               check=False)


def allow(device):
    """Taps Android's "While using the app"; whether it asked."""
    button = device.wait(lambda node: node["id"] in ("permission_allow_foreground_only_button", "permission_allow_button")
                         or node["text"].lower() == "while using the app", timeout=15)
    if button:
        device.tap(button)
    return button is not None


def preview(device):
    """The preview's part of the screen: how much its pixels vary."""
    png = subprocess.run([device.adb, "exec-out", "screencap", "-p"], capture_output=True).stdout
    image = Image.open(io.BytesIO(png)).convert("L")
    # The preview is the first 320 points under the status bar.
    region = image.crop((60, 200, image.width - 60, 900))
    return ImageStat.Stat(region).stddev[0], region.tobytes()


def camera(device, test, timeout=20):
    return device.text("camera", test, timeout=timeout)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--adb", default="adb")
    arguments = parser.parse_args()
    device = media.Device(arguments.adb)
    forget(device)
    try:
        return run(device)
    finally:
        forget(device)


def run(device):
    shown = device.text("status", lambda text: text == "Not asked", timeout=60)
    device.check(shown == "Not asked", f"the app starts without the camera ({shown!r})")

    # The camera, with Android's dialog.
    device.check(device.button("Allow"), "Allow")
    device.check(allow(device), "Android asks for the camera")
    shown = camera(device, lambda text: "running" in text)
    device.check(re.fullmatch(r"Back camera, running, x1\.0(, flash)?", shown or "") is not None,
                 f"the back camera comes on, at a zoom of 1 ({shown!r})")
    time.sleep(2)
    spread, _ = preview(device)
    device.check(spread > 10, f"the preview shows the camera's picture (its pixels vary by {spread:.0f})")

    # A photo, upright, saved.
    device.check(device.button("Shoot"), "Shoot")
    shown = device.text("last", lambda text: text.startswith("Photo"), timeout=20)
    size = [int(value) for value in re.findall(r"\d+", shown or "")]
    device.check(len(size) == 2 and size[0] * size[1] > 0, f"a photo is taken ({shown!r})")
    device.check(len(size) == 2 and size[1] > size[0], f"upright, as the phone is held: taller than it's wide ({shown!r})")
    shown = device.text("status", lambda text: text.startswith("Saved") or text.startswith("Not saved"), timeout=20)
    device.check(shown == "Saved to Photos", f"and added to the user's photos ({shown!r})")
    files = saved(device)
    device.check(("shot-1.jpg", "image/jpeg") in files, f"as a JPEG ({files})")

    # Zoom and the other camera. The emulator's back camera, a rendered
    # room, can't zoom, and has no flash; its front camera zooms to 8 and
    # has one.
    back = camera(device, lambda text: "running" in text, timeout=5)
    device.check(device.button("Zoom"), "Zoom")
    time.sleep(2)
    shown = camera(device, lambda text: "running" in text, timeout=5)
    device.check(shown == back, f"a camera that can't zoom stays at 1 ({shown!r})")
    device.check(device.button("Flip"), "Flip")
    shown = camera(device, lambda text: text.startswith("Front") and "running" in text)
    device.check(shown == "Front camera, running, x1.0, flash", f"Flip turns the front camera on, with its flash ({shown!r})")
    device.check(device.button("Zoom"), "Zoom the front camera")
    shown = camera(device, lambda text: "x2.0" in text, timeout=10)
    device.check(shown == "Front camera, running, x2.0, flash", f"Zoom doubles the zoom ({shown!r})")

    # A video with sound.
    device.check(device.button("Record"), "Record")
    device.check(allow(device), "Android asks for the microphone")
    shown = device.text("status", lambda text: text.startswith("Recording"), timeout=20)
    device.check(shown == "Recording with sound", f"the video records with sound ({shown!r})")
    shown = device.text("recording", lambda text: text in ("Recording 2s", "Recording 3s"), timeout=10)
    device.check(shown is not None, f"for as long as it's recording ({shown!r})")
    device.check(device.button("Stop"), "Stop")
    shown = device.text("last", lambda text: text.startswith("Video"), timeout=20)
    device.check(shown is not None and shown.endswith("video/mp4") and "cut short" not in shown, f"Stop gives the video ({shown!r})")
    shown = device.text("status", lambda text: text.startswith("Saved") or text.startswith("Not saved"), timeout=20)
    files = saved(device)
    device.check(any(name.startswith("clip-") and kind == "video/mp4" for name, kind in files), f"added to the user's photos ({files})")

    # Leaving the app during a recording.
    device.check(device.button("Record"), "Record again")
    device.text("status", lambda text: text.startswith("Recording"), timeout=20)
    time.sleep(2)
    device.run("shell", "input", "keyevent", "KEYCODE_HOME")
    time.sleep(4)
    device.run("shell", "am", "start", "-n", f"{PACKAGE}/org.pureswift.appruntime.AppRuntimeActivity")
    shown = device.text("last", lambda text: "cut short" in text, timeout=20)
    device.check(shown is not None, f"leaving cuts the recording short, and keeps it ({shown!r})")
    shown = camera(device, lambda text: "running" in text)
    device.check(shown == "Front camera, running, x1.0, flash", f"and coming back turns the camera on again ({shown!r})")

    errors = device.run("logcat", "-d", "-s", "AppRuntime:E").splitlines()
    errors = [line for line in errors if " E " in line or "error" in line.lower()]
    device.check(not errors, "no errors in logcat" + "".join(f"\n       {line}" for line in errors))
    print("ok" if device.failures == 0 else f"{device.failures} failed")
    return 1 if device.failures else 0


if __name__ == "__main__":
    sys.exit(main())
