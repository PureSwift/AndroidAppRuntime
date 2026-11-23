#!/usr/bin/env python3
"""Drives AppRuntime's ExampleText on the connected emulator or device
(Documentation/Plan.md §6.16), through UI Automator and `adb shell input`.

    Scripts/example-text-check.py [--adb PATH]

ExampleText is a small editor: a `title`, a `position` and a `format` line,
the text in a `TextEditor` with `@FocusState`, Edit (or Done), Undo, Redo,
Rule and Save, a Find and a Replace field with Find Next and Replace All, a
note in a second `TextEditor` through a binding, its `note` line, and a
`status` line. The bundle's welcome.txt has CRLF line breaks. Then:

- the text opens in an `EditText`, with `\\n` only, and the app knows it
  was CRLF;
- Edit gives the text the keyboard, typing goes in at the caret, and the
  app hears of each key;
- Undo takes the typing back in one step, and Redo puts it back;
- Rule puts a line in at the caret;
- Done takes the keyboard away;
- Find Next selects the match, and Replace All replaces in the text;
- Save writes the text in CRLF again, and it's no longer edited;
- typing in the note's editor reaches the app through its binding, and
  moving the keyboard there takes it from the text, which the app hears.

Exits non-zero if any check fails.
"""

import argparse
import importlib.util
import os
import re
import subprocess
import sys
import time
import xml.etree.ElementTree as ElementTree

PACKAGE = "org.pureswift.ExampleText"

WELCOME = "Hello, editor.\nThe second line.\n"

# The media check's device helpers, for this app.
_spec = importlib.util.spec_from_file_location("example_media_check",
                                               os.path.join(os.path.dirname(__file__), "example-media-check.py"))
media = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(media)
media.PACKAGE = PACKAGE


def editors(device):
    """The text fields on screen, top to bottom: the text, Find, Replace, and the note."""
    return device.fields()


def editor(device, index=0):
    fields = editors(device)
    return fields[index]["text"] if len(fields) > index else None


def wait_editor(device, test, index=0, timeout=15):
    deadline = time.time() + timeout
    text = editor(device, index)
    while not (text is not None and test(text)) and time.time() < deadline:
        time.sleep(1)
        text = editor(device, index)
    return text


def focused(device):
    """The class of the view with the focus, and its text; None if none has it."""
    try:
        device.run("shell", "rm", "-f", "/sdcard/example-text.xml")
        device.run("shell", "uiautomator", "dump", "/sdcard/example-text.xml")
        tree = ElementTree.fromstring(device.run("shell", "cat", "/sdcard/example-text.xml"))
    except (subprocess.CalledProcessError, ElementTree.ParseError):
        return None
    for node in tree.iter("node"):
        if node.get("focused") == "true":
            return node.get("class"), node.get("text", "")
    return None


def keyboard(device):
    """Whether the on-screen keyboard is up."""
    output = device.run("shell", "dumpsys", "input_method", check=False)
    return "mInputShown=true" in output


def wait_keyboard(device, shown, timeout=10):
    deadline = time.time() + timeout
    while keyboard(device) != shown and time.time() < deadline:
        time.sleep(0.5)
    return keyboard(device) == shown


def enabled(device, title):
    node = device.wait(lambda node: node["text"] == title, timeout=5)
    return node is not None and node["enabled"]


def type_text(device, text):
    """Types with key events, as a hardware keyboard would."""
    device.run("shell", "input", "text", text.replace(" ", "%s"))


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--adb", default="adb")
    arguments = parser.parse_args()
    device = media.Device(arguments.adb)

    # Opening the bundle's text.
    shown = device.text("status", lambda text: text.startswith("Opened") or "error" in text, timeout=60)
    device.check(shown == "Opened welcome.txt", f"the app opens its text ({shown!r})")
    text = wait_editor(device, lambda text: text == WELCOME)
    device.check(text == WELCOME, f"in an EditText, with \\n only ({text!r})")
    shown = device.text("format", lambda text: "CRLF" in text, timeout=5)
    device.check(shown == "32 units, 3 lines, utf-8, CRLF, 1 edits", f"and the app knows it was CRLF ({shown!r})")
    shown = device.text("position", timeout=5)
    device.check(shown == "Line 1, column 1", f"with the caret at the start ({shown!r})")

    # The keyboard, with @FocusState.
    device.check(device.button("Edit"), "Edit")
    device.check(device.wait(lambda node: node["text"] == "Done", timeout=10) is not None, "the app's focus is true")
    device.check(wait_keyboard(device, True), "the text has the keyboard")
    where = focused(device)
    device.check(where is not None and where[1] == WELCOME, f"and the focus ({where})")

    # Typing, at the caret.
    type_text(device, "Hi ")
    typed = "Hi " + WELCOME
    text = wait_editor(device, lambda text: text == typed)
    device.check(text == typed, f"typing goes in at the caret ({text!r})")
    shown = device.text("position", lambda text: text == "Line 1, column 4", timeout=10)
    device.check(shown == "Line 1, column 4", f"the app hears where the caret went ({shown!r})")
    shown = device.text("format", lambda text: text.endswith("4 edits"), timeout=5)
    device.check(shown == "35 units, 3 lines, utf-8, CRLF, 4 edits", f"and of each key ({shown!r})")
    shown = device.text("title", lambda text: text.endswith("edited"), timeout=5)
    device.check(shown == "welcome.txt, edited", f"the text is edited ({shown!r})")

    # The history.
    device.check(device.button("Undo"), "Undo")
    text = wait_editor(device, lambda text: text == WELCOME)
    device.check(text == WELCOME, f"takes the typing back in one step ({text!r})")
    time.sleep(1)
    device.check(not enabled(device, "Undo") and enabled(device, "Redo"), "with nothing more to undo, and something to redo")
    device.check(device.button("Redo"), "Redo")
    text = wait_editor(device, lambda text: text == typed)
    device.check(text == typed, f"puts it back ({text!r})")

    # The guest's edit, at the caret.
    device.check(device.button("Rule"), "Rule")
    ruled = "Hi \n----\n" + WELCOME
    text = wait_editor(device, lambda text: text == ruled)
    device.check(text == ruled, f"Rule puts a line in at the caret ({text!r})")
    shown = device.text("position", lambda text: text == "Line 3, column 1", timeout=10)
    device.check(shown == "Line 3, column 1", f"after it ({shown!r})")

    device.check(device.button("Done"), "Done")
    device.check(device.wait(lambda node: node["text"] == "Edit", timeout=10) is not None, "the app's focus is false")
    device.check(wait_keyboard(device, False), "the keyboard is put away")
    where = focused(device)
    device.check(where is None or where[1] != ruled, f"and the text hasn't the focus ({where})")

    # Finding and replacing: the host's search.
    device.check(device.field(1, "second"), "Find: second")
    device.check(device.button("Find Next"), "Find Next")
    shown = device.text("status", lambda text: text.startswith("Found") or text.startswith("No"), timeout=10)
    device.check(shown == "Found at 28", f"finds it ({shown!r})")
    shown = device.text("position", lambda text: "selected" in text, timeout=10)
    device.check(shown == "Line 4, column 5, 6 selected", f"and selects it ({shown!r})")
    device.check(device.field(2, "2nd"), "Replace: 2nd")
    device.check(device.button("Replace All"), "Replace All")
    shown = device.text("status", lambda text: text.startswith("Replaced"), timeout=10)
    device.check(shown == "Replaced 1", f"replaces it ({shown!r})")
    replaced = ruled.replace("second", "2nd")
    text = wait_editor(device, lambda text: text == replaced)
    device.check(text == replaced, f"in the text ({text!r})")

    # Saving, in the text's line breaks.
    device.check(device.button("Save"), "Save")
    shown = device.text("status", lambda text: text in ("Saved",) or "error" in text, timeout=15)
    device.check(shown == "Saved", f"saves ({shown!r})")
    shown = device.text("title", lambda text: text == "welcome.txt", timeout=5)
    device.check(shown == "welcome.txt", f"and it's no longer edited ({shown!r})")
    saved = subprocess.run([arguments.adb, "exec-out", "run-as", PACKAGE, "cat", "files/Documents/edited.txt"],
                           capture_output=True).stdout
    device.check(saved == replaced.replace("\n", "\r\n").encode(), f"in CRLF, as it was opened ({saved!r})")

    # The note, through a binding, and the keyboard moving.
    device.check(device.button("Edit"), "Edit again")
    device.check(wait_keyboard(device, True), "the text has the keyboard again")
    fields = editors(device)
    device.check(len(fields) == 4, f"a text field for the note ({len(fields)} fields)")
    if len(fields) == 4:
        device.tap(fields[3])
        time.sleep(1)
        device.run("shell", "input", "keyevent", "KEYCODE_MOVE_END")
        type_text(device, " milk")
        text = wait_editor(device, lambda text: text == "Remember milk", index=3)
        device.check(text == "Remember milk", f"typing goes in the note's editor ({text!r})")
        device.check(device.wait(lambda node: node["text"] == "Edit", timeout=10) is not None,
                     "the text gave the keyboard to the note, and the app heard")
        # With the keyboard up, the window is too short for the app's last lines.
        device.run("shell", "input", "keyevent", "KEYCODE_BACK")
        shown = device.text("note", lambda text: text == "Note: Remember milk", timeout=15)
        device.check(shown == "Note: Remember milk", f"and reaches the app through its binding ({shown!r})")

    errors = device.run("logcat", "-d", "-s", "AppRuntime:E").splitlines()
    errors = [line for line in errors if " E " in line or "error" in line.lower()]
    device.check(not errors, "no errors in logcat" + "".join(f"\n       {line}" for line in errors))
    print("ok" if device.failures == 0 else f"{device.failures} failed")
    return 1 if device.failures else 0


if __name__ == "__main__":
    sys.exit(main())
