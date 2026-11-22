#!/usr/bin/env python3
"""Drives AppRuntime's ExampleMedia, packaged to play in the background,
with its media session and notification, on the connected emulator or
device (Documentation/Plan.md §6.13), through UI Automator and dumpsys.

    Scripts/example-nowplaying-check.py [--adb PATH]

ExampleMedia is a small music player over three eight-second songs (see
Scripts/example-media-check.py). Scripts/ExampleNowPlaying/App.swift gives
it `.audio(background: true)`, and it says what it plays, with a cover;
offers next, previous and ten-second skips; and plays on in the
background. The check:

- the session shows the song, its artist and album, and the notification
  its title, artist and cover;
- playing puts the session's service in the foreground, as a
  `mediaPlayback` service;
- the media keys pause, play, change songs and skip back, and the app
  hears a pause from them as the user's;
- with the app in the background the song plays on, the media keys still
  change songs, and the app goes on to the next song when one ends;
- paused, the service leaves the foreground, and the app is as the keys
  left it when it's back in front.

Exits non-zero if any check fails.
"""

import argparse
import importlib.util
import os
import re
import sys
import time

PACKAGE = "org.pureswift.ExampleNowPlaying"

# The media check's helpers, for this app.
_spec = importlib.util.spec_from_file_location("example_media_check",
                                               os.path.join(os.path.dirname(__file__), "example-media-check.py"))
media = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(media)
media.PACKAGE = PACKAGE


def session(device):
    """The app's media session: its state, position in milliseconds, and
    description; None while there's none."""
    output = device.run("shell", "dumpsys", "media_session")
    start = output.find(f"package={PACKAGE}")
    if start < 0:
        return None
    section = output[start:start + 2000]
    state = re.search(r"state=PlaybackState \{state=(\w+)\(\d+\), position=(-?\d+)", section)
    description = re.search(r"metadata: size=\d+, description=(.*)", section)
    if not state or not description:
        return None
    return {"state": state.group(1), "position": int(state.group(2)), "description": description.group(1).strip()}


def wait_session(device, test, timeout=15):
    """The session once `test` accepts it, or the last one seen."""
    deadline = time.time() + timeout
    found = None
    while time.time() < deadline:
        found = session(device)
        if found and test(found):
            return found
        time.sleep(1)
    return found


def notification(device):
    """The app's notification: its title, text, and whether it has a
    picture; None while there's none."""
    output = device.run("shell", "dumpsys", "notification", "--noredact")
    start = output.find(f"pkg={PACKAGE}")
    if start < 0:
        return None
    end = output.find("NotificationRecord(", start + 1)
    section = output[start:end if end > 0 else start + 6000]
    title = re.search(r"android\.title=String \((.*)\)", section)
    text = re.search(r"android\.text=String \((.*)\)", section)
    return {
        "title": title.group(1) if title else None,
        "text": text.group(1) if text else None,
        "picture": re.search(r"android\.largeIcon=Icon \(Icon\(typ=BITMAP", section) is not None,
    }


def service(device):
    """Whether the now-playing service is in the foreground, and its types."""
    output = device.run("shell", "dumpsys", "activity", "services", PACKAGE)
    found = re.search(r"isForeground=(\w+) foregroundId=\d+ types=(0x[0-9a-f]+)", output)
    return (found.group(1) == "true", int(found.group(2), 16)) if found else (False, 0)


def key(device, name):
    device.run("shell", "input", "keyevent", "KEYCODE_MEDIA_" + name)


# `ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK`.
MEDIA_PLAYBACK = 2


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--adb", default="adb")
    arguments = parser.parse_args()
    device = media.Device(arguments.adb)

    title = media.song(device, "Morning", timeout=60)
    device.check(title == "Morning, The Examples", f"the first song loads ({title!r})")
    status = device.text("status", timeout=10)
    device.check(status == "Plays in the background", f"it may play in the background, as the manifest says ({status!r})")
    shown = wait_session(device, lambda found: found["description"].startswith("Morning"))
    device.check(shown is not None and (shown["state"], shown["description"]) == ("PAUSED", "Morning, The Examples, Examples"),
                 f"the session shows it, paused ({shown})")

    # Playing, in the foreground.
    device.check(device.button("Play"), "Play")
    shown = wait_session(device, lambda found: found["state"] == "PLAYING")
    device.check(shown is not None and shown["state"] == "PLAYING", f"the session plays ({shown})")
    posted = notification(device)
    device.check(posted is not None and (posted["title"], posted["text"], posted["picture"]) == ("Morning", "The Examples", True),
                 f"the notification shows the song, its artist and its cover ({posted})")
    foreground, types = service(device)
    device.check(foreground and types & MEDIA_PLAYBACK, f"the service is in the foreground, for media playback ({foreground}, {types:#x})")

    # The media keys.
    key(device, "PAUSE")
    state = device.text("state", lambda text: text == "Paused", timeout=10)
    reason = device.text("reason", timeout=5)
    device.check((state, reason) == ("Paused", "Paused from the system's controls"), f"Pause pauses, as the user's ({state!r}, {reason!r})")
    key(device, "PLAY")
    state = device.text("state", lambda text: text == "Playing", timeout=10)
    device.check(state == "Playing", f"Play plays ({state!r})")
    key(device, "NEXT")
    title = media.song(device, "Noon", timeout=10)
    device.check(title == "Noon, The Examples", f"Next is the app's next song ({title!r})")
    key(device, "PREVIOUS")
    title = media.song(device, "Morning", timeout=10)
    device.check(title == "Morning, The Examples", f"Previous is the app's previous song ({title!r})")
    time.sleep(3)
    before = session(device)
    key(device, "REWIND")
    after = wait_session(device, lambda found: before and found["position"] < before["position"] - 1000, timeout=5)
    device.check(before and after and after["position"] < before["position"] - 1000,
                 f"Rewind skips back ({before and before['position']} ms to {after and after['position']} ms)")

    # In the background.
    device.run("shell", "input", "keyevent", "KEYCODE_HOME")
    time.sleep(3)
    shown = session(device)
    players = media.audio_players(device)
    device.check(shown is not None and shown["state"] == "PLAYING" and "started" in players,
                 f"the song plays on in the background ({shown and shown['state']}, {players})")
    key(device, "NEXT")
    shown = wait_session(device, lambda found: found["description"].startswith("Noon"), timeout=10)
    device.check(shown is not None and shown["description"].startswith("Noon"), f"Next changes songs there ({shown})")
    shown = wait_session(device, lambda found: found["description"].startswith("Night"), timeout=media.SECONDS + 10)
    device.check(shown is not None and shown["description"].startswith("Night") and shown["state"] == "PLAYING",
                 f"and when it ends, the app plays the one after it ({shown})")
    key(device, "PAUSE")
    shown = wait_session(device, lambda found: found["state"] == "PAUSED", timeout=10)
    device.check(shown is not None and shown["state"] == "PAUSED", f"Pause pauses it there ({shown and shown['state']})")
    time.sleep(2)
    foreground, _ = service(device)
    posted = notification(device)
    device.check(not foreground and posted is not None,
                 f"paused, the service leaves the foreground, and the notification stays ({foreground}, {posted})")

    # Back in front.
    device.run("shell", "monkey", "-p", PACKAGE, "-c", "android.intent.category.LAUNCHER", "1")
    title = media.song(device, "Night", timeout=20)
    state = device.text("state", timeout=10)
    reason = device.text("reason", timeout=5)
    device.check((title, state, reason) == ("Night, The Examples", "Paused", "Paused from the system's controls"),
                 f"the app is as the keys left it ({title!r}, {state!r}, {reason!r})")

    errors = device.run("logcat", "-d", "-s", "AppRuntime:E").splitlines()
    errors = [line for line in errors if " E " in line or "error" in line.lower()]
    device.check(not errors, "no errors in logcat" + "".join(f"\n       {line}" for line in errors))
    print("ok" if device.failures == 0 else f"{device.failures} failed")
    return 1 if device.failures else 0


if __name__ == "__main__":
    sys.exit(main())
