#!/usr/bin/env python3
"""Drives AppRuntime's ExampleBackground on the connected emulator or
device (Documentation/Plan.md §6.17), through UI Automator, and has
JobScheduler run its WorkManager work with `cmd jobscheduler run -f`.

    Scripts/example-background-check.py [--adb PATH]

ExampleBackground is a feed that keeps itself fresh: `refreshes`, how
often its task ran in this process; `schedule`, whether it's asked for;
Keep Fresh, Stop, Save Later, Saved; `saving` and `status`. Then:

- the app starts with background work on, nothing scheduled, and no time
  to finish a save, since Android has nothing that gives it;
- Keep Fresh asks WorkManager for the task every quarter of an hour,
  which is a job for JobScheduler, and the first run comes at once, with
  the app open;
- with the app's process gone, and once the task's quarter of an hour is
  up, JobScheduler runs the job: Android starts the process with no
  Activity, the host starts the app in the background, and the task runs.
  Opening the app shows the run, in the same process. WorkManager runs
  periodic work no sooner, even when JobScheduler is made to, so the
  check takes about 17 minutes;
- Stop withdraws the task, and its job goes;
- with the app restricted in Settings' battery page, it says background
  work is off.

Exits non-zero if any check fails.
"""

import argparse
import importlib.util
import os
import re
import sys
import time

PACKAGE = "org.pureswift.ExampleBackground"

# WorkManager's shortest period, and a margin: when the task can next run.
PERIOD = 15 * 60 + 30

# The media check's device helpers, for this app.
_spec = importlib.util.spec_from_file_location("example_media_check",
                                               os.path.join(os.path.dirname(__file__), "example-media-check.py"))
media = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(media)
media.PACKAGE = PACKAGE


def jobs(device):
    """The app's WorkManager jobs that JobScheduler has: each its namespace,
    or None where Android has none (before API 34), and its ID."""
    output = device.run("shell", "dumpsys", "jobscheduler", PACKAGE, check=False)
    registered = output.split("Pending queue", 1)[0]
    found = re.findall(r"JOB (?:#|(\S+):)\S+/(\d+): \S+ \S*?" + re.escape(PACKAGE) + r"/androidx\.work", registered)
    return sorted(set((namespace or None, job) for namespace, job in found))


def wait_jobs(device, test, timeout=20):
    deadline = time.time() + timeout
    found = jobs(device)
    while not test(found) and time.time() < deadline:
        time.sleep(1)
        found = jobs(device)
    return found


def process(device):
    return device.run("shell", "pidof", PACKAGE, check=False).strip()


def launch(device):
    device.run("shell", "am", "start", "-W", "-n", f"{PACKAGE}/org.pureswift.appruntime.AppRuntimeActivity", check=False)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--adb", default="adb")
    arguments = parser.parse_args()
    device = media.Device(arguments.adb)
    try:
        return run(device)
    finally:
        device.run("shell", "cmd", "appops", "set", PACKAGE, "RUN_ANY_IN_BACKGROUND", "allow", check=False)


def run(device):
    shown = device.text("status", lambda text: text.startswith("Background"), timeout=60)
    device.check(shown == "Background: on", f"the app starts with background work on ({shown!r})")
    shown = device.text("schedule", timeout=10)
    device.check(shown == "Not scheduled", f"and nothing scheduled ({shown!r})")
    device.check(device.text("refreshes", timeout=5) == "Never refreshed", "nor refreshed")

    # Time to finish something: none on Android.
    device.check(device.button("Save Later"), "Save Later")
    shown = device.text("saving", timeout=10)
    device.check(shown == "No time given", f"Android gives no time to finish a save ({shown!r})")

    # Asking for the task: WorkManager's job, and its first run, now.
    device.check(device.button("Keep Fresh"), "Keep Fresh")
    shown = device.text("schedule", lambda text: text != "Not scheduled", timeout=15)
    device.check(shown == "Scheduled", f"the task is scheduled ({shown!r})")
    found = wait_jobs(device, bool)
    device.check(len(found) == 1, f"as a job for JobScheduler ({found})")
    shown = device.text("refreshes", lambda text: text.startswith("Refreshed"), timeout=60)
    device.check(shown == "Refreshed 1 times", f"WorkManager runs it at once, with the app open ({shown!r})")

    # A run that starts the app. WorkManager doesn't run periodic work before
    # its period is up, even when JobScheduler is made to, so this waits for
    # the next one.
    first = time.time()
    device.run("shell", "input", "keyevent", "KEYCODE_HOME")
    time.sleep(2)
    device.run("shell", "am", "kill", PACKAGE, check=False)
    deadline = time.time() + 10
    while process(device) and time.time() < deadline:
        time.sleep(1)
    device.check(not process(device), "the app's process is gone")
    found = wait_jobs(device, bool)
    device.check(len(found) == 1, f"and its job is still there ({found})")
    print(f"·    waiting {int(PERIOD - (time.time() - first))} s for the task's period")
    time.sleep(max(0, PERIOD - (time.time() - first)))
    device.run("logcat", "-c")
    # The first forced run starts the process, where WorkManager reschedules
    # everything, as after a force stop, and the run is dropped; the
    # rescheduled job then runs.
    ran = False
    for _ in range(4):
        for namespace, job in jobs(device):
            device.run("shell", "cmd", "jobscheduler", "run", "-f", *(["-n", namespace] if namespace else []), PACKAGE, job,
                       check=False)
        time.sleep(6)
        log = device.run("logcat", "-d", check=False)
        if "BackgroundTaskWorker" in log and "Worker result" in log:
            ran = True
            break
    log = device.run("logcat", "-d", check=False)
    device.check(bool(process(device)), f"JobScheduler starts the process ({process(device)})")
    device.check(f"{PACKAGE} 1.0 (1) started" in log, "and the host starts the app")
    activity = re.findall(r"(?:START u0|Displayed) .*" + re.escape(PACKAGE), log)
    device.check(not activity, f"with no Activity ({activity})")
    success = re.search(r"Worker result SUCCESS for Work \[ id=.*" + re.escape("task:org.pureswift.example.background.refresh"), log)
    device.check(ran and success is not None, "the task runs, and WorkManager hears that it succeeded")

    # Opening the app: the same process, with what the run did.
    launch(device)
    shown = device.text("refreshes", lambda text: text.startswith("Refreshed"), timeout=30)
    device.check(shown == "Refreshed 1 times", f"opening the app shows the background run ({shown!r})")
    shown = device.text("schedule", timeout=10)
    device.check(shown == "Scheduled", f"and the task still scheduled ({shown!r})")

    # Withdrawing it.
    device.check(device.button("Stop"), "Stop")
    shown = device.text("schedule", lambda text: text == "Not scheduled", timeout=15)
    device.check(shown == "Not scheduled", f"Stop withdraws the task ({shown!r})")
    found = wait_jobs(device, lambda found: not found)
    device.check(found == [], f"and its job goes ({found})")

    # The user's switch.
    device.run("shell", "cmd", "appops", "set", PACKAGE, "RUN_ANY_IN_BACKGROUND", "ignore")
    device.run("shell", "am", "force-stop", PACKAGE)
    launch(device)
    shown = device.text("status", lambda text: text.startswith("Background"), timeout=60)
    device.check(shown == "Background: off", f"restricted in Settings, background work is off ({shown!r})")

    errors = device.run("logcat", "-d", "-s", "AppRuntime:E").splitlines()
    errors = [line for line in errors if " E " in line or "error" in line.lower()]
    device.check(not errors, "no errors in logcat" + "".join(f"\n       {line}" for line in errors))
    print("ok" if device.failures == 0 else f"{device.failures} failed")
    return 1 if device.failures else 0


if __name__ == "__main__":
    sys.exit(main())
