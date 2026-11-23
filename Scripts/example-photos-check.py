#!/usr/bin/env python3
"""Drives AppRuntime's ExamplePhotos, Android's permission dialog and its
question before deleting, on the connected emulator or device
(Documentation/Plan.md §6.18), through UI Automator, with photos and a
video the check puts in the shared storage.

    Scripts/example-photos-check.py [--adb PATH]

ExamplePhotos is a gallery: a `status` line, Allow, All, a button per
album, a grid of `PhotoView`s four at a time, More, and, for the photo
tapped, a `large` view, its `detail`, Original, Delete and Close. The check
puts four photos in Pictures/Holiday, each a JPEG of one colour with its
own date, and a screen recording in Movies/Clips, which is newer. Then:

- Allow asks with Android's dialog, and the app shows four of what the
  device has, the check's and any already there, with the check's two
  albums, and More shows four more;
- the Holiday album shows its photos newest first, drawn from Android's
  thumbnails: the screen has their colours, in that order;
- a photo tapped is shown large, with its size, and its original is the
  file the check put there, byte for byte;
- the Clips album has the video;
- a photo added by another app is seen, as the library says it changed;
- Delete asks with Android's question, and the photo goes.

The check removes its photos when it's done.

Exits non-zero if any check fails.
"""

import argparse
import importlib.util
import io
import os
import re
import subprocess
import sys
import tempfile
import time

from PIL import Image

PACKAGE = "org.pureswift.ExamplePhotos"
PICTURES = "/sdcard/Pictures/Holiday"
MOVIES = "/sdcard/Movies/Clips"

# Each photo's colour and date, oldest first.
PHOTOS = [
    ("beach.jpg", (220, 40, 40), "2025:01:01 10:00:00"),
    ("hill.jpg", (40, 180, 60), "2025:01:02 10:00:00"),
    ("sea.jpg", (40, 70, 220), "2025:01:03 10:00:00"),
    ("sky.jpg", (240, 200, 30), "2025:01:04 10:00:00"),
]

# The media check's device helpers, for this app.
_spec = importlib.util.spec_from_file_location("example_media_check",
                                               os.path.join(os.path.dirname(__file__), "example-media-check.py"))
media = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(media)
media.PACKAGE = PACKAGE


def jpeg(colour, date, size=(640, 480)):
    """A photo of one colour, taken at `date`."""
    image = Image.new("RGB", size, colour)
    exif = image.getexif()
    exif[0x0132] = date
    exif.get_ifd(0x8769)[0x9003] = date
    output = io.BytesIO()
    image.save(output, "JPEG", quality=90, exif=exif)
    return output.getvalue()


def scan(device):
    device.run("shell", "content", "call", "--uri", "content://media", "--method", "scan_volume", "--arg", "external_primary",
               check=False)


def forget(device):
    device.run("shell", "rm", "-rf", PICTURES, MOVIES, check=False)
    scan(device)


def push(device, name, data):
    with tempfile.NamedTemporaryFile(suffix=os.path.splitext(name)[1], delete=False) as file:
        file.write(data)
    try:
        device.run("push", file.name, f"{PICTURES}/{name}")
    finally:
        os.unlink(file.name)


def colours(device):
    """How many pixels of the screen are each photo's colour."""
    png = subprocess.run([device.adb, "exec-out", "screencap", "-p"], capture_output=True).stdout
    image = Image.open(io.BytesIO(png)).convert("RGB").resize((270, 585))
    counts = {name: 0 for name, _, _ in PHOTOS}
    for pixel in image.getdata():
        for name, colour, _ in PHOTOS:
            if all(abs(a - b) < 24 for a, b in zip(pixel, colour)):
                counts[name] += 1
    return counts


def status(device, test, timeout=20):
    return device.text("status", test, timeout=timeout)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--adb", default="adb")
    arguments = parser.parse_args()
    device = media.Device(arguments.adb)
    forget(device)
    others = existing(device)
    device.run("shell", "mkdir", "-p", PICTURES, MOVIES)
    for name, colour, date in PHOTOS:
        push(device, name, jpeg(colour, date))
    device.run("shell", "screenrecord", "--time-limit", "2", f"{MOVIES}/clip.mp4", check=False)
    scan(device)
    try:
        return run(device, others)
    finally:
        forget(device)


def existing(device):
    """How many photos and videos the device has besides the check's."""
    output = device.run("shell", "content query --uri content://media/external/file --projection _id "
                        "--where \"media_type IN (1,3)\"", check=False)
    return len(re.findall(r"(?m)^Row: ", output))


def run(device, others):
    total = others + 5
    shown = status(device, lambda text: text == "Not asked", timeout=60)
    device.check(shown == "Not asked", f"the app starts without leave to read ({shown!r})")

    # Access, with Android's dialog.
    device.check(device.button("Allow"), "Allow")
    allow = device.wait(lambda node: node["text"].lower() == "allow all" or node["id"] == "permission_allow_all_button", timeout=15)
    device.check(allow is not None, "Android asks for the photos and videos")
    if allow:
        device.tap(allow)
    shown = status(device, lambda text: " of " in text)
    device.check(shown == f"4 of {total}", f"once allowed, the app shows four of the {total} on the device ({shown!r})")
    albums = [node["text"] for node in device.nodes() if re.match(r".* \(\d+\)$", node["text"])]
    device.check("Clips (1)" in albums and "Holiday (4)" in albums, f"with the check's two albums ({albums})")
    if total > 4:
        device.check(device.button("More"), "More")
        shown = status(device, lambda text: text != f"4 of {total}")
        device.check(shown == f"{min(8, total)} of {total}", f"and More the next four ({shown!r})")

    # An album, newest first, drawn by the host.
    device.check(device.button("Holiday (4)"), "Holiday")
    shown = status(device, lambda text: "Holiday" in text)
    device.check(shown == "4 of 4 in Holiday", f"an album shows its photos ({shown!r})")
    time.sleep(3)
    counts = colours(device)
    device.check(all(count > 300 for count in counts.values()), f"drawn from their thumbnails ({counts})")
    order = sorted(counts, key=lambda name: tile_of(device, name)[::-1])
    device.check(order == ["sky.jpg", "sea.jpg", "hill.jpg", "beach.jpg"], f"newest first ({order})")

    # One photo, large, and its original.
    device.run("shell", "input", "tap", *map(str, tile_of(device, "beach.jpg")))
    shown = device.text("detail", lambda text: text.startswith("Photo") or text.startswith("Video"), timeout=10)
    device.check(shown == "Photo 640x480", f"a photo tapped says its size ({shown!r})")
    time.sleep(3)
    before = counts["beach.jpg"]
    counts = colours(device)
    device.check(counts["beach.jpg"] > before * 3, f"and is shown large ({counts['beach.jpg']} pixels of it)")
    device.check(device.button("Original"), "Original")
    size = len(jpeg(PHOTOS[0][1], PHOTOS[0][2]))
    shown = device.text("detail", lambda text: "bytes" in text, timeout=15)
    device.check(shown == f"beach.jpg, image/jpeg, {size} bytes", f"its original is the file itself ({shown!r})")
    device.check(device.button("Close"), "Close")

    # The video.
    device.check(device.button("Clips (1)"), "Clips")
    shown = status(device, lambda text: "Clips" in text)
    device.check(shown == "1 of 1 in Clips", f"the other album has the video ({shown!r})")
    device.check(device.button("Holiday (4)"), "Holiday again")
    status(device, lambda text: text == "4 of 4 in Holiday")

    # Another app's photo.
    push(device, "dusk.jpg", jpeg((150, 60, 200), "2025:01:05 10:00:00"))
    scan(device)
    shown = status(device, lambda text: text.endswith("of 5 in Holiday"), timeout=30)
    device.check(shown == "4 of 5 in Holiday", f"a photo another app adds is seen ({shown!r})")

    # Deleting, with Android's question.
    time.sleep(2)
    device.run("shell", "input", "tap", *map(str, tile_of(device, "sky.jpg")))
    device.text("detail", lambda text: text.startswith("Photo"), timeout=10)
    device.check(device.button("Delete"), "Delete")
    allow = device.wait(lambda node: node["text"] == "Allow", timeout=15)
    device.check(allow is not None, "Android asks before deleting")
    if allow:
        device.tap(allow)
    shown = status(device, lambda text: text.endswith("of 4 in Holiday"), timeout=30)
    device.check(shown == "4 of 4 in Holiday", f"and the photo goes ({shown!r})")
    gone = device.run("shell", "ls", f"{PICTURES}/sky.jpg", check=False)
    device.check("sky.jpg" not in gone or "No such file" in gone, f"from the device too ({gone.strip()!r})")

    errors = device.run("logcat", "-d", "-s", "AppRuntime:E").splitlines()
    errors = [line for line in errors if " E " in line or "error" in line.lower()]
    device.check(not errors, "no errors in logcat" + "".join(f"\n       {line}" for line in errors))
    print("ok" if device.failures == 0 else f"{device.failures} failed")
    return 1 if device.failures else 0


def tile_of(device, name):
    """Where on the screen the photo `name` is drawn most: its tile's middle."""
    colour = next(colour for photo, colour, _ in PHOTOS if photo == name)
    png = subprocess.run([device.adb, "exec-out", "screencap", "-p"], capture_output=True).stdout
    image = Image.open(io.BytesIO(png)).convert("RGB")
    small = image.resize((image.width // 10, image.height // 10))
    points = [(x * 10, y * 10) for y in range(small.height) for x in range(small.width)
              if all(abs(a - b) < 24 for a, b in zip(small.getpixel((x, y)), colour))]
    if not points:
        return (0, 0)
    return (sum(x for x, _ in points) // len(points), sum(y for _, y in points) // len(points))


if __name__ == "__main__":
    sys.exit(main())
