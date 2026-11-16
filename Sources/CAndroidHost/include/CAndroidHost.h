#ifndef CANDROIDHOST_H
#define CANDROIDHOST_H

// The NDK APIs the host uses (Documentation/Plan.md §3.1, §6.2): the main
// thread's ALooper, an eventfd for jobs posted from other threads, a
// timerfd on CLOCK_BOOTTIME for timers, logcat, the sensors, and for
// surfaces EGL, native windows and the Choreographer.
//
// Empty elsewhere, so the package's platform-neutral code builds and tests
// on macOS.

#include <stdint.h>

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

// MARK: Surfaces (Documentation/Plan.md §6.3)
//
// One GL context for every surface, made on the main thread when the first
// window arrives; each window gets an EGL window surface (a "drawable").
// Pointers are untyped so Swift needn't import EGL's or JNI's types.

/// The `ANativeWindow` of an `android.view.Surface`, acquired; NULL if
/// there's none. `env` is the calling thread's `JNIEnv *`.
void *candroid_window_from_surface(void *env, void *surface);

/// Releases a window from `candroid_window_from_surface`.
void candroid_window_release(void *window);

/// A drawable for `window`, making the display and context first if there
/// are none; NULL if EGL can't.
void *candroid_gl_drawable_make(void *window);

void candroid_gl_drawable_destroy(void *drawable);

/// What `candroid_gl_begin` and `candroid_gl_end` report.
enum {
    CANDROID_GL_OK = 0,
    CANDROID_GL_FAILED = 1,
    /// The context is gone: replace it with `candroid_gl_replace_context`.
    CANDROID_GL_CONTEXT_LOST = 2,
};

/// Makes the context current on `drawable`.
int32_t candroid_gl_begin(void *drawable);

/// Presents `drawable` and clears the current context.
int32_t candroid_gl_end(void *drawable);

/// Destroys the context and makes a new, empty one; 1 if it could. The
/// generation `rt_gl_context_generation` reports changes.
int32_t candroid_gl_replace_context(void);

/// Asks for `callback` at the next display refresh, once, with the frame's
/// time in CLOCK_BOOTTIME nanoseconds (the `Clock` built-in's timeline).
/// 0 if there's no Choreographer on this thread.
int32_t candroid_frame_post(void (*callback)(int64_t timestamp, void *data), void *data);

/// A CLOCK_MONOTONIC time, such as an input event's, on CLOCK_BOOTTIME.
int64_t candroid_boottime_from_monotonic(int64_t nanoseconds);
#endif

/// A wasm2c slice's GL shim asks this on every GL call (AppRuntime's
/// Contracts/Graphics.md): it changes whenever the context is a new one.
uint32_t rt_gl_context_generation(void);

#endif
