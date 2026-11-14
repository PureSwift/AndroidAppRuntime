#ifndef CANDROIDHOST_H
#define CANDROIDHOST_H

// The NDK APIs the host's main looper and log use (Documentation/Plan.md
// §3.1): the main thread's ALooper, an eventfd for jobs posted from other
// threads, a timerfd on CLOCK_BOOTTIME for timers, and logcat.
//
// Empty elsewhere, so the package's platform-neutral code builds and tests
// on macOS.

#ifdef __ANDROID__
#include <android/log.h>
#include <android/looper.h>
#include <errno.h>
#include <sys/eventfd.h>
#include <sys/timerfd.h>
#include <time.h>
#include <unistd.h>
#endif

#endif
