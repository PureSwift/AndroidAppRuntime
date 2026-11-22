#!/usr/bin/env python3
"""Drives AppRuntime's ExampleDocuments, and Android's own pickers, on the
connected emulator or device (Documentation/Plan.md §6.8), through UI
Automator.

    Scripts/example-documents-check.py [--adb PATH]

ExampleDocuments is a small text editor for the user's files: the open
file's `name`, its `text`, Open, Save, Save a Copy, Open Folder, a button
per name in the folder that was picked, and a `status` line.

The check puts `notes.txt` and a folder `Notes` (`a.txt`, `b.txt`) in
`Documents/ExampleDocuments` on shared storage, and then:

- Open shows the system's picker, and the picked file is read through its
  content URI;
- Save writes the change back to the user's file;
- Save a Copy shows the save picker, which suggests a name; the copy is
  made where the user says, and later saves go to it, not the original;
- Open Folder shows the folder picker; the folder is listed, and a file in
  it is read by its path under the folder;
- a cancelled picker changes nothing, and the next one shows;
- Attach Photo shows Android's own photo picker, with the app holding no
  media permission; the photo it picks is read, and cancelling it picks
  nothing. The app's buttons don't all fit a phone held upright, so this
  part runs in landscape;
- `ACTION_EDIT` from another app opens a file while the app runs, and
  `ACTION_VIEW` opens one, read-only, as it starts.

Exits non-zero if any check fails.
"""

import argparse
import os
import re
import subprocess
import sys
import struct
import time
import xml.etree.ElementTree as ElementTree

PACKAGE = "org.pureswift.ExampleDocuments"
ACTIVITY = PACKAGE + "/org.pureswift.appruntime.AppRuntimeActivity"
SHARED = "/sdcard/Documents/ExampleDocuments"
FILES = {"notes.txt": "Hello from the user", "Notes/a.txt": "apples", "Notes/b.txt": "bananas"}
PICTURES = "/sdcard/Pictures/ExampleDocuments"


def photo_png():
    """A 64x48 PNG, for the photo picker."""
    import zlib

    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
    pixels = b"".join(b"\x00" + bytes(value for x in range(64) for value in (x * 4 % 256, y * 5 % 256, 128))
                      for y in range(48))
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 64, 48, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(pixels)) + chunk(b"IEND", b""))


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
            self.run("shell", "rm", "-f", "/sdcard/example-documents.xml")
            self.run("shell", "uiautomator", "dump", "/sdcard/example-documents.xml")
            tree = ElementTree.fromstring(self.run("shell", "cat", "/sdcard/example-documents.xml"))
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


def shared(device, path):
    """A file on shared storage, or None."""
    output = subprocess.run([device.adb, "shell", "cat", f"'{SHARED}/{path}'"], capture_output=True, text=True)
    return output.stdout if output.returncode == 0 else None


def prepare(device):
    """The user's files, fresh, and indexed so another app can send one."""
    device.run("shell", "rm", "-rf", SHARED)
    device.run("shell", "mkdir", "-p", SHARED + "/Notes")
    for path, text in FILES.items():
        device.run("shell", f"printf '{text}' > '{SHARED}/{path}'")
    device.run("shell", "am", "broadcast", "-a", "android.intent.action.MEDIA_SCANNER_SCAN_FILE",
               "-d", f"file://{SHARED}/notes.txt", check=False)
    # The newest photo, so the photo picker shows it first.
    local = os.path.join(os.environ.get("TMPDIR", "/tmp"), "example-documents-photo.png")
    with open(local, "wb") as file:
        file.write(photo_png())
    # Through MediaStore, which would list a photo removed with rm.
    where = f"\"_data LIKE '{PICTURES.replace('/sdcard', '/storage/emulated/0')}/%'\""
    device.run("shell", "content", "delete", "--uri", "content://media/external/images/media", "--where", where, check=False)
    device.run("shell", "rm", "-rf", PICTURES)
    device.run("shell", "mkdir", "-p", PICTURES)
    device.run("push", local, PICTURES + "/photo.png")
    os.remove(local)
    device.run("shell", "am", "broadcast", "-a", "android.intent.action.MEDIA_SCANNER_SCAN_FILE",
               "-d", f"file://{PICTURES}/photo.png", check=False)


def photo_picker(device, timeout=20):
    """The photo picker's newest photo, once the picker has come up and
    stopped moving; None if it didn't show."""
    is_photo = lambda node: node["desc"].startswith("Photo taken on")
    photo = device.wait(is_photo, timeout)
    while photo:
        time.sleep(1)
        settled = device.wait(is_photo, timeout=5)
        if settled is None or settled["center"] == photo["center"]:
            return settled
        photo = settled
    return None


def attach_photo(device):
    """Attach Photo, with the phone on its side so the button fits, and the
    rotation put back after."""
    rotation = [device.run("shell", "settings", "get", "system", key).strip() for key in ("accelerometer_rotation", "user_rotation")]
    device.run("shell", "settings", "put", "system", "accelerometer_rotation", "0")
    device.run("shell", "settings", "put", "system", "user_rotation", "1")
    try:
        time.sleep(2)
        permissions = device.run("shell", "dumpsys", "package", PACKAGE)
        held = [name for name in ("READ_MEDIA_IMAGES", "READ_MEDIA_VIDEO", "READ_EXTERNAL_STORAGE") if name in permissions]
        device.check(not held, f"the app asks for no media permission ({held})")
        device.check(device.button("Attach Photo"), "Attach Photo")
        photo = photo_picker(device)
        device.check(photo is not None, "Android's photo picker shows")
        # Tapped again where the picker took the first tap as it came up.
        for _ in range(3):
            if not photo:
                break
            device.tap(photo)
            time.sleep(3)
            photo = photo_picker(device, timeout=2)
        size = len(photo_png())
        status = device.text("status", lambda text: text.startswith(("Attached", "Couldn't", "No photo")), timeout=20)
        device.check(re.fullmatch(rf"Attached \d+\.png, {size} bytes", status or "") is not None,
                     f"the photo is picked, and read ({status!r})")
        device.check(device.button("Attach Photo"), "Attach Photo again")
        device.check(photo_picker(device) is not None, "the photo picker shows again")
        device.run("shell", "input", "keyevent", "KEYCODE_BACK")
        status = device.text("status", lambda text: text == "No photo picked", timeout=20)
        device.check(status == "No photo picked", f"Back cancels it ({status!r})")
    finally:
        device.run("shell", "settings", "put", "system", "user_rotation", rotation[1] if rotation[1].isdigit() else "0")
        device.run("shell", "settings", "put", "system", "accelerometer_rotation", rotation[0] if rotation[0].isdigit() else "1")
        time.sleep(2)


def media_id(device, name):
    """The file's row in MediaStore, which other apps share it by."""
    for _ in range(10):
        output = device.run("shell", "content", "query", "--uri", "content://media/external/file",
                            "--projection", "_id:_data", "--where", f"\"_data='{SHARED.replace('/sdcard', '/storage/emulated/0')}/{name}'\"",
                            check=False)
        found = re.search(r"_id=(\d+)", output)
        if found:
            return found.group(1)
        time.sleep(1)
    return None


def into(device, *folders):
    """In a picker: to the device's storage, by its breadcrumb where the
    picker is already in it and by its roots otherwise, then down through
    `folders`. The folder picker has no roots, and opens where the last
    picker was."""
    storage_names = (device.run("shell", "getprop", "ro.product.model").strip(), "Internal storage")
    start = device.wait(lambda node: node["desc"] == "Show roots"
                        or (node["id"] == "breadcrumb_text" and node["text"] in storage_names), timeout=20)
    if not start:
        return False
    if start["id"] != "breadcrumb_text":
        crumb = [node for node in device.nodes() if node["id"] == "breadcrumb_text" and node["text"] in storage_names]
        if crumb:
            start = crumb[0]
    if start["id"] == "breadcrumb_text":
        device.tap(start)
    else:
        device.tap(start)
        storage = device.wait(lambda node: node["text"] in storage_names and node["id"] == "title", timeout=10)
        if not storage:
            return False
        device.tap(storage)
    time.sleep(1)
    for folder in folders:
        found = device.wait(lambda node: node["text"] == folder and node["id"] == "title", timeout=10)
        if not found:
            return False
        device.tap(found)
        time.sleep(1)
    return True


def picker_button(device, title, timeout=10):
    """Taps a picker's button, whatever its case."""
    node = device.wait(lambda node: node["text"].upper() == title.upper() and node["id"] == "button1", timeout)
    if node:
        device.tap(node)
    return node is not None


def edit(device, text):
    return device.field(0, text)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--adb", default="adb")
    arguments = parser.parse_args()
    device = Device(arguments.adb)
    prepare(device)

    name = device.text("name", lambda text: text == "Untitled", timeout=60)
    device.check(name == "Untitled", f"the app starts with nothing open ({name!r})")

    # Open, change, save back.
    device.check(device.button("Open"), "Open")
    device.check(into(device, "Documents", "ExampleDocuments"), "the picker shows the user's folder")
    device.check(device.button("notes.txt"), "notes.txt is picked")
    status = device.text("status", lambda text: text.startswith("Opened"), timeout=20)
    device.check(status == "Opened notes.txt", f"it opens, writable ({status!r})")
    text = device.text("text", lambda text: text == FILES["notes.txt"], timeout=5)
    device.check(text == FILES["notes.txt"], f"its text is the file's ({text!r})")
    device.check(edit(device, "Changed"), "the text is changed")
    device.check(device.button("Save"), "Save")
    status = device.text("status", lambda text: text.startswith("Saved"), timeout=20)
    device.check(status == "Saved notes.txt", f"saves ({status!r})")
    saved = shared(device, "notes.txt")
    device.check(saved == "Changed", f"into the user's file ({saved!r})")

    # A copy where the user says.
    device.check(device.button("Save a Copy"), "Save a Copy")
    suggested = device.wait(lambda node: node["text"] == "Copy of notes.txt" and node["class"] == "android.widget.EditText", timeout=20)
    device.check(suggested is not None, "the save picker suggests Copy of notes.txt")
    device.check(into(device, "Documents", "ExampleDocuments"), "the save picker goes to the user's folder")
    device.check(picker_button(device, "Save"), "Save in the picker")
    status = device.text("status", lambda text: text.startswith("Saved"), timeout=20)
    device.check(status == "Saved as Copy of notes.txt", f"the copy is saved ({status!r})")
    copy = shared(device, "Copy of notes.txt")
    device.check(copy == "Changed", f"with the text ({copy!r})")
    device.check(edit(device, "Copied"), "the text is changed again")
    device.check(device.button("Save"), "Save")
    status = device.text("status", lambda text: text == "Saved Copy of notes.txt", timeout=20)
    device.check(status == "Saved Copy of notes.txt", f"saves the copy ({status!r})")
    copy, original = shared(device, "Copy of notes.txt"), shared(device, "notes.txt")
    device.check((copy, original) == ("Copied", "Changed"), f"into the copy, not the original ({copy!r}, {original!r})")

    # A folder.
    device.check(device.button("Open Folder"), "Open Folder")
    device.check(into(device, "Documents", "ExampleDocuments", "Notes"), "the folder picker goes to Notes")
    device.check(picker_button(device, "Use this folder"), "Use this folder")
    device.check(picker_button(device, "Allow"), "Allow")
    status = device.text("status", lambda text: text.endswith("in Notes"), timeout=20)
    device.check(status == "2 in Notes", f"the folder is listed ({status!r})")
    device.check(device.button("b.txt"), "b.txt, from the folder")
    status = device.text("status", lambda text: text.startswith("Read"), timeout=20)
    text = device.text("text", lambda text: text == "bananas", timeout=5)
    device.check((status, text) == ("Read b.txt from Notes", "bananas"), f"is read under the folder ({status!r}, {text!r})")

    # A photo, from Android's own photo picker.
    attach_photo(device)

    # Cancelled, then picked.
    device.check(device.button("Open"), "Open")
    device.check(device.wait(lambda node: node["desc"] == "Show roots", timeout=20) is not None, "the picker shows")
    # Back goes up the picker's folders first, then closes it.
    for _ in range(6):
        device.run("shell", "input", "keyevent", "KEYCODE_BACK")
        time.sleep(1)
        if device.wait(lambda node: node["id"] == "name", timeout=2):
            break
    name = device.text("name", timeout=10)
    device.check(name == "b.txt", f"cancelling it changes nothing ({name!r})")
    device.check(device.button("Open"), "Open again")
    device.check(into(device, "Documents", "ExampleDocuments"), "a picker shows again")
    device.check(device.button("notes.txt"), "notes.txt is picked")
    status = device.text("status", lambda text: text == "Opened notes.txt", timeout=20)
    device.check(status == "Opened notes.txt", f"and opens ({status!r})")

    # From another app.
    identifier = media_id(device, "Copy of notes.txt")
    device.check(identifier is not None, f"the copy is in MediaStore ({identifier})")
    device.run("shell", "am", "start", "-W", "-a", "android.intent.action.EDIT", "-d", f"content://media/external/file/{identifier}",
               "-t", "text/plain", "--grant-read-uri-permission", "--grant-write-uri-permission", "-n", ACTIVITY)
    status = device.text("status", lambda text: text.startswith("Opened Copy"), timeout=20)
    device.check(status == "Opened Copy of notes.txt", f"ACTION_EDIT opens it while the app runs ({status!r})")
    text = device.text("text", lambda text: text == "Copied", timeout=5)
    device.check(text == "Copied", f"with its text ({text!r})")
    device.run("shell", "am", "force-stop", PACKAGE)
    device.run("shell", "am", "start", "-W", "-a", "android.intent.action.VIEW", "-d", f"content://media/external/file/{identifier}",
               "-t", "text/plain", "--grant-read-uri-permission", "-n", ACTIVITY)
    status = device.text("status", lambda text: text.startswith("Opened"), timeout=60)
    device.check(status == "Opened Copy of notes.txt, read-only", f"ACTION_VIEW opens it as the app starts ({status!r})")

    errors = device.run("logcat", "-d", "-s", "AppRuntime:E").splitlines()
    errors = [line for line in errors if " E " in line or "error" in line.lower()]
    device.check(not errors, "no errors in logcat" + "".join(f"\n       {line}" for line in errors))
    print("ok" if device.failures == 0 else f"{device.failures} failed")
    return 1 if device.failures else 0


if __name__ == "__main__":
    sys.exit(main())
