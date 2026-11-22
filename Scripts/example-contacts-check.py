#!/usr/bin/env python3
"""Drives AppRuntime's ExampleContacts, and Android's permission dialog, on
the connected emulator or device (Documentation/Plan.md §6.14), through UI
Automator, and reads the contacts provider with `adb shell content`.

    Scripts/example-contacts-check.py [--adb PATH]

ExampleContacts is an address book: a `status` line, Allow, Add Ada,
Promote Ada, Remove Ada, a `search` field, a line per person, and the first
person's `detail`. The check puts Grace Hopper, with a work phone, in the
device's contacts, and then:

- Allow asks with Android's dialog, and the app lists Grace, with her
  phone's label;
- Add Ada saves a person with a mobile phone, a work email, a home address
  in London with its country's code, and a birthday, each where Android
  keeps it, and the app lists her by the name Android made;
- Promote Ada changes her: a job and a second email, keeping the rows she
  had;
- a search is Android's own, by the start of a name;
- a person added by another app is listed, as the store says it changed;
- Remove Ada removes her from the device's contacts.

The check removes these three people from the device's contacts first, and
when it's done.

Exits non-zero if any check fails.
"""

import argparse
import importlib.util
import os
import re
import sys
import time

PACKAGE = "org.pureswift.ExampleContacts"
PEOPLE = ("Ada Lovelace", "Grace Hopper", "Alan Turing")
AUTHORITY = "content://com.android.contacts"

# The media check's device helpers, for this app.
_spec = importlib.util.spec_from_file_location("example_media_check",
                                               os.path.join(os.path.dirname(__file__), "example-media-check.py"))
media = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(media)
media.PACKAGE = PACKAGE


def content(device, *arguments):
    return device.run("shell", "content", *arguments, check=False)


def rows(output):
    """`content query`'s rows, as dictionaries. A value may run on to the
    next line, as an address does."""
    found = []
    for chunk in re.split(r"(?m)^Row: \d+ ", output):
        if not chunk.strip() or "=" not in chunk:
            continue
        row = {}
        for match in re.finditer(r"(\w+)=(.*?)(?=, \w+=|\Z)", chunk.strip(), re.S):
            row[match.group(1)] = match.group(2)
        found.append(row)
    return found


def forget(device):
    """Removes the check's people from the device's contacts, for good."""
    names = ",".join(f"'{name}'" for name in PEOPLE)
    device.run("shell", f"content delete --uri '{AUTHORITY}/raw_contacts?caller_is_syncadapter=true' "
               f"--where \"display_name IN ({names})\"", check=False)


def add(device, given, family, phone=None):
    """A person on the device's own account, as another app adds them."""
    content(device, "insert", "--uri", f"{AUTHORITY}/raw_contacts", "--bind", "account_type:n:", "--bind", "account_name:n:")
    raw = max(int(row["_id"]) for row in rows(content(device, "query", "--uri", f"{AUTHORITY}/raw_contacts", "--projection", "_id")))
    content(device, "insert", "--uri", f"{AUTHORITY}/data", "--bind", f"raw_contact_id:i:{raw}",
            "--bind", "mimetype:s:vnd.android.cursor.item/name", "--bind", f"data2:s:{given}", "--bind", f"data3:s:{family}")
    if phone:
        content(device, "insert", "--uri", f"{AUTHORITY}/data", "--bind", f"raw_contact_id:i:{raw}",
                "--bind", "mimetype:s:vnd.android.cursor.item/phone_v2", "--bind", f"data1:s:'{phone}'", "--bind", "data2:i:3")


def data(device, name):
    """A person's data rows on the device, by kind."""
    people = rows(content(device, "query", "--uri", f"{AUTHORITY}/contacts", "--projection", "_id:display_name"))
    ids = [row["_id"] for row in people if row.get("display_name") == name]
    if not ids:
        return None
    found = rows(content(device, "query", "--uri", f"{AUTHORITY}/data",
                         "--projection", "_id:mimetype:data1:data2:data4:data7:data10", "--where", f"contact_id={ids[0]}"))
    for row in found:
        row["kind"] = row.get("mimetype", "").split("/")[-1]
    return found


def kinds(found, kind):
    return [row for row in found or [] if row["kind"] == kind]


def status(device, test, timeout=15):
    return device.text("status", test, timeout=timeout)


def lines(device):
    """The people listed, as the app writes them."""
    names = PEOPLE
    return [node["text"] for node in device.nodes() if node["text"].startswith(names)]


def search(device, text):
    """Types into the search field a letter at a time, as a person does, or
    empties it."""
    field = device.wait(lambda node: node["id"] == "search", timeout=10)
    if not field:
        return False
    device.tap(field)
    time.sleep(1)
    if text:
        for letter in text:
            device.run("shell", "input", "text", letter)
            time.sleep(1)
    else:
        device.run("shell", "input", "keyevent", "KEYCODE_MOVE_END")
        device.run("shell", "input", "keyevent", *(["KEYCODE_DEL"] * 10))
    device.run("shell", "input", "keyevent", "KEYCODE_BACK")  # the keyboard
    time.sleep(2)
    return True


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--adb", default="adb")
    arguments = parser.parse_args()
    device = media.Device(arguments.adb)
    forget(device)
    add(device, "Grace", "Hopper", "+1 202 555 0143")
    try:
        return run(device)
    finally:
        forget(device)


def run(device):
    shown = status(device, lambda text: text == "Not asked", timeout=60)
    device.check(shown == "Not asked", f"the app starts without access ({shown!r})")

    # Access, with Android's dialog.
    device.check(device.button("Allow"), "Allow")
    allow = device.wait(lambda node: node["id"] == "permission_allow_button", timeout=15)
    device.check(allow is not None, "Android asks for the contacts")
    if allow:
        device.tap(allow)
    shown = status(device, lambda text: text.endswith("people"))
    device.check(shown == "1 people", f"once allowed, the app lists the device's contacts ({shown!r})")
    detail = device.text("detail", timeout=5)
    device.check(lines(device) == ["Grace Hopper, +1 202 555 0143"] and detail == "work: +1 202 555 0143",
                 f"Grace, with her phone's label ({lines(device)}, {detail!r})")

    # Ada, added.
    device.check(device.button("Add Ada"), "Add Ada")
    shown = status(device, lambda text: text == "2 people")
    device.check(shown == "2 people", f"the store says it changed, and she's listed ({shown!r})")
    ada = data(device, "Ada Lovelace")
    device.check(ada is not None, "she's in the device's contacts, named by Android")
    name = kinds(ada, "name")
    phone, email = kinds(ada, "phone_v2"), kinds(ada, "email_v2")
    address, birthday = kinds(ada, "postal-address_v2"), kinds(ada, "contact_event")
    phones = [(row["data1"], row["data2"]) for row in phone]
    emails = [(row["data1"], row["data2"]) for row in email]
    device.check((phones, emails) == ([("+353 1 555 0100", "2")], [("ada@example.com", "2")]),
                 f"a mobile phone and a work email, as Android's types ({phones}, {emails})")
    addresses = [(row["data7"], row["data10"], row["data2"]) for row in address]
    device.check(addresses == [("London", "GB", "1")], f"a home address in London, with its country's code ({addresses})")
    birthdays = [(row["data1"], row["data2"]) for row in birthday]
    device.check(birthdays == [("1815-12-10", "3")], f"a birthday ({birthdays})")
    detail = device.text("detail", lambda text: text.startswith("mobile"), timeout=5)
    device.check(detail == "mobile: +353 1 555 0100; work: ada@example.com; home: London, GB; born 1815-12-10",
                 f"read back as she was saved ({detail!r})")

    # Ada, changed.
    kept = sorted(row["_id"] for row in ada or [])
    device.check(device.button("Promote Ada"), "Promote Ada")
    detail = device.text("detail", lambda text: text.startswith("Programmer"), timeout=15)
    device.check(detail == "Programmer, Analytical Engines; mobile: +353 1 555 0100; work: ada@example.com; "
                           "home: ada@lovelace.example; home: London, GB; born 1815-12-10",
                 f"she has a job and a second email ({detail!r})")
    ada = data(device, "Ada Lovelace")
    organization = [(row["data1"], row["data4"]) for row in kinds(ada, "organization")]
    device.check(organization == [("Analytical Engines", "Programmer")]
                 and all(identifier in [row["_id"] for row in ada] for identifier in kept),
                 f"in the device's contacts, keeping the rows she had ({organization})")

    # Android's search.
    device.check(search(device, "gra"), "a search for gra")
    shown = status(device, lambda text: text == "1 people")
    device.check(shown == "1 people" and lines(device) == ["Grace Hopper, +1 202 555 0143"],
                 f"finds Grace by the start of her name ({shown!r}, {lines(device)})")
    search(device, "")
    shown = status(device, lambda text: text == "2 people")
    device.check(shown == "2 people", f"and everyone without one ({shown!r})")

    # Another app's change.
    add(device, "Alan", "Turing")
    shown = status(device, lambda text: text == "3 people")
    device.check(shown == "3 people" and "Alan Turing" in lines(device),
                 f"a person another app adds is listed ({shown!r}, {lines(device)})")

    # Ada, removed.
    device.check(device.button("Remove Ada"), "Remove Ada")
    shown = status(device, lambda text: text == "2 people")
    device.check(shown == "2 people" and data(device, "Ada Lovelace") is None,
                 f"she's gone from the device's contacts ({shown!r})")

    errors = device.run("logcat", "-d", "-s", "AppRuntime:E").splitlines()
    errors = [line for line in errors if " E " in line or "error" in line.lower()]
    device.check(not errors, "no errors in logcat" + "".join(f"\n       {line}" for line in errors))
    print("ok" if device.failures == 0 else f"{device.failures} failed")
    return 1 if device.failures else 0


if __name__ == "__main__":
    sys.exit(main())
