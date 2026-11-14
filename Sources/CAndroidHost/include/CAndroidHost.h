#ifndef CANDROIDHOST_H
#define CANDROIDHOST_H

// The NDK APIs the host uses (Documentation/Plan.md §3.1, §6.2): the main
// thread's ALooper, an eventfd for jobs posted from other threads, a
// timerfd on CLOCK_BOOTTIME for timers, logcat, and the sensors.
//
// Empty elsewhere, so the package's platform-neutral code builds and tests
// on macOS.

#ifdef __ANDROID__
#include <android/log.h>
#include <android/looper.h>
#include <android/sensor.h>
#include <errno.h>
#include <stdint.h>
#include <sys/eventfd.h>
#include <sys/timerfd.h>
#include <time.h>
#include <unistd.h>

/// One ASensorEvent's values, without its unions, for Swift.
typedef struct {
    int32_t type;
    int64_t timestamp;
    /// The first `count` values the sensor type defines.
    float values[5];
    int32_t count;
    /// SENSOR_STATUS_* (magnetic field and vectors).
    int8_t status;
    /// ASENSOR_TYPE_STEP_COUNTER's count.
    uint64_t steps;
} CAndroidSensorSample;

/// Up to `capacity` waiting events from `queue`; how many, or 0.
int32_t candroid_sensor_read(ASensorEventQueue *queue, CAndroidSensorSample *samples, int32_t capacity);
#endif

#endif
