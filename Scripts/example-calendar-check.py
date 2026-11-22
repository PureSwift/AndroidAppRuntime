#!/usr/bin/env python3
"""Drives AppRuntime's ExampleCalendar, and Android's permission dialog, on
the connected emulator or device (Documentation/Plan.md §6.15), through UI
Automator, and reads the calendar provider with `adb shell content`.

    Scripts/example-calendar-check.py [--adb PATH]

ExampleCalendar is November 2026's agenda: a `month`, a `status` line,
Allow, Previous, Next, Add Standup, Add Day Off, Move Second, Cancel From
Third, and a line per occurrence, in UTC. The check puts two calendars on
the device, on an account of its own with no sync adapter: Personal, which
can be written, and Holidays, which can't and has Thanksgiving, all day.
Then:

- Allow asks with Android's dialog, and the app lists Thanksgiving on its
  day, though the device is in another zone than UTC;
- Add Standup saves a weekly series in Personal, the default, with its rule,
  its length, its place and its alarm where Android keeps them, and the
  provider's expansion gives its four Tuesdays;
- Add Day Off saves an all-day event at UTC midnight;
- Move Second makes an exception for the second Tuesday, and the series'
  other occurrences are still there;
- Cancel From Third ends the series' rule before the third Tuesday;
- an event another app adds is listed, as the store says it changed;
- Next and Previous show December, with nothing on, and November again.

The check removes its calendars, and their events, first and when it's
done.

Exits non-zero if any check fails.
"""

import argparse
import importlib.util
import os
import re
import sys
import time

PACKAGE = "org.pureswift.ExampleCalendar"
AUTHORITY = "content://com.android.calendar"
ACCOUNT = "AppRuntimeCheck"
ADAPTER = f"caller_is_syncadapter=true&account_name={ACCOUNT}&account_type=LOCAL"

DAY = 86_400_000
HOUR = 3_600_000
# 2026-11-03 09:00 UTC, the month's first Tuesday.
TUESDAY = 1_793_696_400_000
WEEK = 7 * DAY
# 2026-11-09 and 2026-11-26, 00:00 UTC.
NINTH = 1_794_182_400_000
THANKSGIVING = 1_795_651_200_000

# The media check's device helpers, for this app.
_spec = importlib.util.spec_from_file_location("example_media_check",
                                               os.path.join(os.path.dirname(__file__), "example-media-check.py"))
media = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(media)
media.PACKAGE = PACKAGE


def content(device, *arguments):
    return device.run("shell", "content", *arguments, check=False)


def rows(output):
    """`content query`'s rows, as dictionaries."""
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
    """Removes the check's calendars, which takes their events."""
    device.run("shell", f"content delete --uri '{AUTHORITY}/calendars?{ADAPTER}' --where \"account_name='{ACCOUNT}'\"",
               check=False)


def calendar(device, name, access, owner):
    """A calendar on the check's account; gives its identifier."""
    device.run("shell", f"content insert --uri '{AUTHORITY}/calendars?{ADAPTER}' --bind account_name:s:{ACCOUNT} "
               f"--bind account_type:s:LOCAL --bind name:s:{name} --bind calendar_displayName:s:{name} "
               f"--bind calendar_color:i:-16744448 --bind calendar_access_level:i:{access} --bind ownerAccount:s:{owner} "
               f"--bind visible:i:1 --bind sync_events:i:1")
    found = rows(content(device, "query", "--uri", f"{AUTHORITY}/calendars", "--projection", "_id:calendar_displayName"))
    return next(row["_id"] for row in found if row["calendar_displayName"] == name)


def add(device, calendar, title, start, end, all_day=False):
    """An event, as another app adds it."""
    device.run("shell", f"content insert --uri {AUTHORITY}/events --bind calendar_id:i:{calendar} --bind title:s:{title} "
               f"--bind dtstart:l:{start} --bind dtend:l:{end} --bind allDay:i:{1 if all_day else 0} "
               f"--bind eventTimezone:s:{'UTC' if all_day else 'America/New_York'}")


def events(device, title):
    """The rows of `Events` with this title, by identifier."""
    projection = ("_id:calendar_id:title:dtstart:dtend:duration:rrule:allDay:eventTimezone:eventLocation:"
                  "original_id:originalInstanceTime:_sync_id:deleted")
    # One command, so that the device's shell keeps the clause whole.
    found = rows(device.run("shell", f"content query --uri {AUTHORITY}/events --projection {projection} "
                            f"--where \"title='{title}' AND deleted=0\"", check=False))
    return sorted(found, key=lambda row: int(row["_id"]))


def reminders(device, event):
    found = rows(content(device, "query", "--uri", f"{AUTHORITY}/reminders", "--projection", "minutes:method",
                         "--where", f"event_id={event}"))
    return [(row["minutes"], row["method"]) for row in found]


def lines(device):
    """The agenda, as the app writes it."""
    return [node["text"] for node in device.nodes() if re.match(r"\d{4}-\d\d-\d\d ", node["text"])]


def status(device, test, timeout=15):
    return device.text("status", test, timeout=timeout)


def agenda(device, expected, timeout=15):
    """Waits for the agenda to read `expected`; gives what it reads."""
    deadline = time.time() + timeout
    shown = lines(device)
    while shown != expected and time.time() < deadline:
        time.sleep(1)
        shown = lines(device)
    return shown


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--adb", default="adb")
    arguments = parser.parse_args()
    device = media.Device(arguments.adb)
    forget(device)
    personal = calendar(device, "Personal", 700, ACCOUNT)
    holidays = calendar(device, "Holidays", 200, "holidays@example.com")
    add(device, holidays, "Thanksgiving", THANKSGIVING, THANKSGIVING + DAY, all_day=True)
    try:
        return run(device, personal)
    finally:
        forget(device)


def run(device, personal):
    zone = device.run("shell", "getprop", "persist.sys.timezone").strip()
    shown = status(device, lambda text: text == "Not asked", timeout=60)
    device.check(shown == "Not asked", f"the app starts without access ({shown!r})")

    # Access, with Android's dialog.
    device.check(device.button("Allow"), "Allow")
    allow = device.wait(lambda node: node["id"] == "permission_allow_button", timeout=15)
    device.check(allow is not None, "Android asks for the calendars")
    if allow:
        device.tap(allow)
    shown = status(device, lambda text: text.endswith("events"))
    device.check(shown == "1 events", f"once allowed, the app lists the month ({shown!r})")
    device.check(agenda(device, ["2026-11-26 all day Thanksgiving"]) == ["2026-11-26 all day Thanksgiving"],
                 f"an all-day event is on its day, in {zone} too ({lines(device)})")

    # A weekly series.
    device.check(device.button("Add Standup"), "Add Standup")
    standups = [f"2026-11-{day:02} 09:00 Standup, weekly" for day in (3, 10, 17, 24)]
    expected = standups[:3] + [standups[3], "2026-11-26 all day Thanksgiving"]
    shown = agenda(device, expected)
    device.check(shown == expected, f"the provider's expansion gives its four Tuesdays ({shown})")
    series = events(device, "Standup")
    row = series[0] if series else {}
    device.check(len(series) == 1 and row["calendar_id"] == personal,
                 f"one series, in Personal, the default ({[(row['_id'], row['calendar_id']) for row in series]})")
    device.check((row.get("rrule"), row.get("dtstart"), row.get("duration"), row.get("dtend"), row.get("eventLocation"))
                 == ("FREQ=WEEKLY;BYDAY=TU;COUNT=4", str(TUESDAY), "P1800S", "NULL", "Room 4"),
                 f"with its rule, its start, its length and its place ({row})")
    device.check(reminders(device, row.get("_id")) == [("10", "1")], f"and its alarm ({reminders(device, row.get('_id'))})")

    # An all-day event.
    device.check(device.button("Add Day Off"), "Add Day Off")
    expected = standups[:1] + ["2026-11-09 all day Day off"] + standups[1:] + ["2026-11-26 all day Thanksgiving"]
    shown = agenda(device, expected)
    device.check(shown == expected, f"a day off on the ninth ({shown})")
    day = (events(device, "Day off") or [{}])[0]
    device.check((day.get("allDay"), day.get("dtstart"), day.get("dtend"), day.get("eventTimezone"))
                 == ("1", str(NINTH), str(NINTH + DAY), "UTC"), f"from UTC midnight to the next ({day})")

    # One occurrence, by itself.
    device.check(device.button("Move Second"), "Move Second")
    moved = [standups[0], "2026-11-09 all day Day off", "2026-11-10 10:00 Standup, moved", standups[2], standups[3],
             "2026-11-26 all day Thanksgiving"]
    shown = agenda(device, moved)
    device.check(shown == moved, f"the second Tuesday an hour later, and the others still there ({shown})")
    series = events(device, "Standup")
    exceptions = [(row["original_id"], row["originalInstanceTime"], row["dtstart"]) for row in series[1:]]
    device.check(exceptions == [(series[0]["_id"], str(TUESDAY + WEEK), str(TUESDAY + WEEK + HOUR))],
                 f"an exception to the series, for the occurrence it replaces ({exceptions})")
    device.check(series[0]["_sync_id"].startswith("appruntime-"),
                 f"the series has a sync identifier, as its calendar has no sync adapter ({series[0]['_sync_id']})")

    # This and what follows.
    device.check(device.button("Cancel From Third"), "Cancel From Third")
    cancelled = moved[:3] + ["2026-11-26 all day Thanksgiving"]
    shown = agenda(device, cancelled)
    device.check(shown == cancelled, f"the series ends before the third Tuesday ({shown})")
    rule = (events(device, "Standup") or [{}])[0].get("rrule")
    device.check(rule == "FREQ=WEEKLY;BYDAY=TU;UNTIL=20261117T085959Z", f"its rule has an end ({rule})")

    # Another app's change.
    add(device, personal, "Dentist", TUESDAY + 16 * DAY + 5 * HOUR, TUESDAY + 16 * DAY + 6 * HOUR)
    shown = status(device, lambda text: text == "5 events")
    device.check(shown == "5 events" and "2026-11-19 14:00 Dentist" in lines(device),
                 f"an event another app adds is listed ({shown!r}, {lines(device)})")

    # Another month.
    device.check(device.button("Next"), "Next")
    shown = status(device, lambda text: text == "Nothing on")
    device.check(shown == "Nothing on" and device.text("month", timeout=5) == "2026-12",
                 f"December has nothing on ({shown!r})")
    device.check(device.button("Previous"), "Previous")
    shown = status(device, lambda text: text == "5 events")
    device.check(shown == "5 events", f"and November is as it was ({shown!r})")

    errors = device.run("logcat", "-d", "-s", "AppRuntime:E").splitlines()
    errors = [line for line in errors if " E " in line or "error" in line.lower()]
    device.check(not errors, "no errors in logcat" + "".join(f"\n       {line}" for line in errors))
    print("ok" if device.failures == 0 else f"{device.failures} failed")
    return 1 if device.failures else 0


if __name__ == "__main__":
    sys.exit(main())
