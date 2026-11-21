#!/usr/bin/env python3
"""Drives AppRuntime's ExampleModel on the connected emulator or device
(Documentation/Plan.md §6.7), through UI Automator.

    Scripts/example-model-check.py [--adb PATH]

ExampleModel keeps to-dos in two lists, Home and Work, in a model store
named `todos`, with CoreModel: a `summary` of each list and its count, a
Title field, a List button that picks the list, Add, a filter between all
and open to-dos, Clear done, Count open, a button per to-do that marks it
done, one that deletes it, and a `status` line.

- the first launch makes both lists, in one batch, and the store is a
  SQLite file, databases/todos.sqlite, with the model it was made with;
- to-dos are added to either list, and are rows in the file, numbered and
  pointing at their list;
- marking one done changes only `isDone`; the filter hides it, and Count
  open counts through the to-dos' relationship to their list;
- after the app starts again, everything is as it was;
- Clear done deletes the done ones in one batch, and Delete one to-do,
  from the screen and from the file.

Exits non-zero if any check fails.
"""

import argparse
import json
import os
import re
import sqlite3
import subprocess
import sys
import tempfile
import time
import xml.etree.ElementTree as ElementTree

PACKAGE = "org.pureswift.ExampleModel"
DATABASE = "databases/todos.sqlite"
CONTROLS = {"Add", "Clear done", "Count open", "Show: all", "Show: open", "List: Home", "List: Work", "List: none", "Title"}


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
            self.run("shell", "uiautomator", "dump", "/sdcard/example-model.xml")
            tree = ElementTree.fromstring(self.run("shell", "cat", "/sdcard/example-model.xml"))
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


def rows(device, query, wait_for=None, timeout=10):
    """`query`'s rows in the app's database, once `wait_for` accepts them.
    The file is copied out with run-as, between the app's transactions."""
    deadline = time.time() + timeout
    while True:
        found = None
        data = subprocess.run([device.adb, "exec-out", "run-as", PACKAGE, "cat", DATABASE], capture_output=True).stdout
        if data.startswith(b"SQLite format 3"):
            with tempfile.TemporaryDirectory() as directory:
                path = os.path.join(directory, "todos.sqlite")
                with open(path, "wb") as file:
                    file.write(data)
                try:
                    connection = sqlite3.connect(path)
                    found = connection.execute(query).fetchall()
                    connection.close()
                except sqlite3.Error:
                    found = None
        if (found is not None and (wait_for is None or wait_for(found))) or time.time() > deadline:
            return found
        time.sleep(0.5)


def todos(device, wait_for=None, timeout=10):
    """The to-dos on screen, top to bottom, once `wait_for` accepts them."""
    deadline = time.time() + timeout
    while True:
        nodes = [node for node in device.nodes()
                 if node["text"] and node["enabled"] and node["id"] not in ("summary", "status")
                 and node["class"] != "android.widget.EditText" and node["text"] not in CONTROLS
                 and not node["text"].startswith("Delete ")]
        seen = []
        for node in sorted(nodes, key=lambda node: node["center"][1]):
            if node["text"] not in seen:
                seen.append(node["text"])
        if wait_for is None or wait_for(seen) or time.time() > deadline:
            return seen
        time.sleep(0.5)


def add(device, title):
    return device.field(0, title) and device.button("Add")


def leave_and_restart(device):
    """Home first, so the Activity stops and Android finishes the writes;
    then a new process."""
    before = pid(device)
    device.run("shell", "input", "keyevent", "KEYCODE_HOME")
    time.sleep(2)
    device.run("shell", "am", "force-stop", PACKAGE)
    device.run("shell", "monkey", "-p", PACKAGE, "-c", "android.intent.category.LAUNCHER", "1")
    deadline = time.time() + 30
    while pid(device) in (None, before) and time.time() < deadline:
        time.sleep(0.5)
    after = pid(device)
    device.check(after not in (None, before), f"the app is a new process ({before} then {after})")


def pid(device):
    """The app's process id, or None when it isn't running."""
    output = device.run("shell", "pidof", PACKAGE, check=False).strip()
    return output or None


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--adb", default="adb")
    arguments = parser.parse_args()
    device = Device(arguments.adb)

    summary = device.text("summary", lambda text: text == "Home 0, Work 0", timeout=60)
    device.check(summary == "Home 0, Work 0", f"the first launch makes both lists ({summary!r})")
    lists = rows(device, 'SELECT id, name FROM "List" ORDER BY id', lambda found: len(found) == 2)
    device.check(lists == [("home", "Home"), ("work", "Work")], f"the lists are rows in databases/todos.sqlite ({lists!r})")
    model = rows(device, 'SELECT model FROM "_appruntime_model"')
    entities = sorted(entity["id"] for entity in json.loads(model[0][0])) if model else None
    device.check(entities == ["List", "Todo"], f"the file keeps the model it was made with ({entities!r})")

    device.check(add(device, "Milk"), "Milk is added")
    status = device.text("status", lambda text: text == "Added Milk", timeout=10)
    device.check(status == "Added Milk", f"the status says so ({status!r})")
    device.check(device.button("List: Home"), "the list moves to Work")
    device.check(add(device, "Report"), "Report is added")
    device.text("status", lambda text: text == "Added Report", timeout=10)
    device.check(add(device, "Expenses"), "Expenses is added")
    summary = device.text("summary", lambda text: text == "Home 1, Work 2", timeout=10)
    device.check(summary == "Home 1, Work 2", f"each list counts its to-dos ({summary!r})")
    shown = todos(device, lambda seen: seen == ["Milk", "Report", "Expenses"])
    device.check(shown == ["Milk", "Report", "Expenses"], f"the to-dos show in the order they were added ({shown!r})")
    stored = rows(device, 'SELECT number, title, isDone, list FROM "Todo" ORDER BY number', lambda found: len(found) == 3)
    device.check(stored == [(1, "Milk", 0, "home"), (2, "Report", 0, "work"), (3, "Expenses", 0, "work")],
                 f"each is a row, numbered and pointing at its list ({stored!r})")

    device.check(device.button("Add"), "Add with no title")
    status = device.text("status", lambda text: text == "A to-do needs a title.", timeout=10)
    device.check(status == "A to-do needs a title.", f"is refused ({status!r})")

    device.check(device.button("Report"), "Report is marked done")
    shown = todos(device, lambda seen: "Done: Report" in seen)
    device.check(shown == ["Milk", "Done: Report", "Expenses"], f"and shows as done ({shown!r})")
    stored = rows(device, 'SELECT title, isDone, list FROM "Todo" WHERE number = 2', lambda found: found and found[0][1] == 1)
    device.check(stored == [("Report", 1, "work")], f"only isDone changed in its row ({stored!r})")

    device.check(device.button("Show: all"), "the filter moves to open to-dos")
    shown = todos(device, lambda seen: seen == ["Milk", "Expenses"])
    device.check(shown == ["Milk", "Expenses"], f"the done one is hidden ({shown!r})")
    device.check(device.button("Count open"), "Count open, in Work")
    status = device.text("status", lambda text: text.endswith("open in Work"), timeout=10)
    device.check(status == "1 open in Work", f"counts through the to-dos' list ({status!r})")
    device.check(device.button("Show: open"), "the filter moves back to all")
    shown = todos(device, lambda seen: seen == ["Milk", "Done: Report", "Expenses"])
    device.check(shown == ["Milk", "Done: Report", "Expenses"], f"all three show again ({shown!r})")

    leave_and_restart(device)
    summary = device.text("summary", lambda text: text == "Home 1, Work 2", timeout=60)
    device.check(summary == "Home 1, Work 2", f"after a restart, the lists are as they were ({summary!r})")
    shown = todos(device, lambda seen: seen == ["Milk", "Done: Report", "Expenses"])
    device.check(shown == ["Milk", "Done: Report", "Expenses"], f"and so are the to-dos ({shown!r})")
    lists = rows(device, 'SELECT COUNT(*) FROM "List"')
    device.check(lists == [(2,)], f"no lists were made again ({lists!r})")

    device.check(device.button("Clear done"), "Clear done")
    status = device.text("status", lambda text: text == "Cleared 1", timeout=10)
    device.check(status == "Cleared 1", f"clears the done one ({status!r})")
    device.check(device.button("Delete Milk"), "Milk is deleted")
    shown = todos(device, lambda seen: seen == ["Expenses"])
    device.check(shown == ["Expenses"], f"only Expenses is left on screen ({shown!r})")
    summary = device.text("summary", lambda text: text == "Home 0, Work 1", timeout=10)
    device.check(summary == "Home 0, Work 1", f"and in the lists ({summary!r})")
    stored = rows(device, 'SELECT title FROM "Todo"', lambda found: found == [("Expenses",)])
    device.check(stored == [("Expenses",)], f"and in the file ({stored!r})")

    errors = device.run("logcat", "-d", "-s", "AppRuntime:E").splitlines()
    errors = [line for line in errors if " E " in line or "error" in line.lower()]
    device.check(not errors, "no errors in logcat" + "".join(f"\n       {line}" for line in errors))
    print("ok" if device.failures == 0 else f"{device.failures} failed")
    return 1 if device.failures else 0


if __name__ == "__main__":
    sys.exit(main())
