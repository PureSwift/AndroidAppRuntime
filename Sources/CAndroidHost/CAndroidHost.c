// The C the host needs beside the NDK's headers.
#include "CAndroidHost.h"

#ifdef __ANDROID__
int32_t candroid_sensor_read(ASensorEventQueue *queue, CAndroidSensorSample *samples, int32_t capacity) {
    ASensorEvent events[16];
    int32_t total = 0;
    while (total < capacity) {
        int32_t wanted = capacity - total < 16 ? capacity - total : 16;
        ssize_t count = ASensorEventQueue_getEvents(queue, events, (size_t)wanted);
        if (count <= 0) {
            break;
        }
        for (ssize_t index = 0; index < count; index++) {
            const ASensorEvent *event = &events[index];
            CAndroidSensorSample *sample = &samples[total++];
            sample->type = event->type;
            sample->timestamp = event->timestamp;
            sample->count = 5;
            for (int value = 0; value < 5; value++) {
                sample->values[value] = event->data[value];
            }
            sample->status = event->vector.status;
            sample->steps = event->type == ASENSOR_TYPE_STEP_COUNTER ? event->u64.step_counter : 0;
        }
    }
    return total;
}
#endif

// MARK: Surfaces

static uint32_t gl_generation;

uint32_t rt_gl_context_generation(void) {
    return gl_generation;
}

#ifdef __ANDROID__
#include <EGL/egl.h>
#include <android/choreographer.h>
#include <android/native_window_jni.h>
#include <dlfcn.h>

static EGLDisplay gl_display = EGL_NO_DISPLAY;
static EGLConfig gl_config;
static EGLContext gl_context = EGL_NO_CONTEXT;

void *candroid_window_from_surface(void *env, void *surface) {
    return ANativeWindow_fromSurface((JNIEnv *)env, (jobject)surface);
}

void candroid_window_release(void *window) {
    ANativeWindow_release((ANativeWindow *)window);
}

// RGBA8888 with a depth buffer, and a stencil buffer when there is one,
// for GLES 2.0 windows.
static int gl_choose_config(void) {
    const EGLint stencils[] = { 8, 0 };
    for (int index = 0; index < 2; index++) {
        const EGLint attributes[] = {
            EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT, EGL_SURFACE_TYPE, EGL_WINDOW_BIT,
            EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8,
            EGL_DEPTH_SIZE, 16, EGL_STENCIL_SIZE, stencils[index], EGL_NONE,
        };
        EGLint count = 0;
        if (eglChooseConfig(gl_display, attributes, &gl_config, 1, &count) && count > 0) {
            return 1;
        }
    }
    return 0;
}

static int gl_make_context(void) {
    const EGLint attributes[] = { EGL_CONTEXT_CLIENT_VERSION, 2, EGL_NONE };
    gl_context = eglCreateContext(gl_display, gl_config, EGL_NO_CONTEXT, attributes);
    return gl_context != EGL_NO_CONTEXT;
}

static int gl_setup(void) {
    if (gl_context != EGL_NO_CONTEXT) {
        return 1;
    }
    if (gl_display == EGL_NO_DISPLAY) {
        EGLDisplay display = eglGetDisplay(EGL_DEFAULT_DISPLAY);
        if (display == EGL_NO_DISPLAY || !eglInitialize(display, NULL, NULL)) {
            __android_log_print(ANDROID_LOG_ERROR, "AppRuntime", "no EGL display (0x%x)", eglGetError());
            return 0;
        }
        gl_display = display;
        if (!gl_choose_config()) {
            __android_log_print(ANDROID_LOG_ERROR, "AppRuntime", "no EGL config for GLES 2.0 windows");
            return 0;
        }
    }
    if (!gl_make_context()) {
        __android_log_print(ANDROID_LOG_ERROR, "AppRuntime", "no GLES 2.0 context (0x%x)", eglGetError());
        return 0;
    }
    return 1;
}

void *candroid_gl_drawable_make(void *window) {
    if (!gl_setup()) {
        return NULL;
    }
    EGLSurface drawable = eglCreateWindowSurface(gl_display, gl_config, (ANativeWindow *)window, NULL);
    if (drawable == EGL_NO_SURFACE) {
        __android_log_print(ANDROID_LOG_ERROR, "AppRuntime", "no EGL window surface (0x%x)", eglGetError());
        return NULL;
    }
    return drawable;
}

void candroid_gl_drawable_destroy(void *drawable) {
    if (eglGetCurrentSurface(EGL_DRAW) == (EGLSurface)drawable) {
        eglMakeCurrent(gl_display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
    }
    eglDestroySurface(gl_display, (EGLSurface)drawable);
}

static int32_t gl_result(void) {
    return eglGetError() == EGL_CONTEXT_LOST ? CANDROID_GL_CONTEXT_LOST : CANDROID_GL_FAILED;
}

int32_t candroid_gl_begin(void *drawable) {
    if (gl_context == EGL_NO_CONTEXT) {
        return CANDROID_GL_CONTEXT_LOST;
    }
    if (!eglMakeCurrent(gl_display, (EGLSurface)drawable, (EGLSurface)drawable, gl_context)) {
        return gl_result();
    }
    return CANDROID_GL_OK;
}

int32_t candroid_gl_end(void *drawable) {
    int32_t result = eglSwapBuffers(gl_display, (EGLSurface)drawable) ? CANDROID_GL_OK : gl_result();
    eglMakeCurrent(gl_display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
    return result;
}

int32_t candroid_gl_replace_context(void) {
    if (gl_display == EGL_NO_DISPLAY) {
        return 0;
    }
    eglMakeCurrent(gl_display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
    if (gl_context != EGL_NO_CONTEXT) {
        eglDestroyContext(gl_display, gl_context);
        gl_context = EGL_NO_CONTEXT;
    }
    gl_generation++;
    return gl_make_context();
}

// The Choreographer reports CLOCK_MONOTONIC times. AChoreographer_postFrameCallback64
// is API 29 and the host's minimum is 28, so it's looked up; the older
// callback's `long` is too short on 32-bit ABIs, so there the time is now.
static void (*frame_callback)(int64_t, void *);
static void *frame_data;

static int64_t clock_nanoseconds(clockid_t clock) {
    struct timespec time;
    clock_gettime(clock, &time);
    return (int64_t)time.tv_sec * 1000000000 + time.tv_nsec;
}

int64_t candroid_boottime_from_monotonic(int64_t nanoseconds) {
    return nanoseconds + (clock_nanoseconds(CLOCK_BOOTTIME) - clock_nanoseconds(CLOCK_MONOTONIC));
}

static void frame_fire(int64_t monotonic) {
    void (*callback)(int64_t, void *) = frame_callback;
    frame_callback = NULL;
    if (callback) {
        callback(candroid_boottime_from_monotonic(monotonic), frame_data);
    }
}

static void frame_fired64(int64_t time, void *data) {
    frame_fire(time);
}

static void frame_fired(long time, void *data) {
    frame_fire(sizeof(long) >= 8 ? (int64_t)time : clock_nanoseconds(CLOCK_MONOTONIC));
}

typedef void (*post64_function)(AChoreographer *, void (*)(int64_t, void *), void *);

int32_t candroid_frame_post(void (*callback)(int64_t timestamp, void *data), void *data) {
    AChoreographer *choreographer = AChoreographer_getInstance();
    if (!choreographer) {
        return 0;
    }
    int pending = frame_callback != NULL;
    frame_callback = callback;
    frame_data = data;
    if (pending) {
        return 1;
    }
    static post64_function post64;
    static int looked;
    if (!looked) {
        post64 = (post64_function)dlsym(RTLD_DEFAULT, "AChoreographer_postFrameCallback64");
        looked = 1;
    }
    if (post64) {
        post64(choreographer, frame_fired64, NULL);
    } else {
        AChoreographer_postFrameCallback(choreographer, frame_fired, NULL);
    }
    return 1;
}
#endif

#ifdef __ANDROID__
#include <android/asset_manager_jni.h>

// MARK: Assets

void *candroid_assets_from_java(void *env, void *assetManager) {
    return AAssetManager_fromJava((JNIEnv *)env, (jobject)assetManager);
}

int64_t candroid_asset_length(void *assets, const char *path) {
    AAsset *asset = AAssetManager_open((AAssetManager *)assets, path, AASSET_MODE_UNKNOWN);
    if (asset == NULL) {
        return -1;
    }
    int64_t length = AAsset_getLength64(asset);
    AAsset_close(asset);
    return length;
}

int64_t candroid_asset_read(void *assets, const char *path, int64_t offset, void *buffer, int64_t length) {
    AAsset *asset = AAssetManager_open((AAssetManager *)assets, path, AASSET_MODE_RANDOM);
    if (asset == NULL) {
        return -1;
    }
    int64_t done = 0;
    if (offset > 0 && AAsset_seek64(asset, offset, SEEK_SET) < 0) {
        AAsset_close(asset);
        return -2;
    }
    while (done < length) {
        int64_t want = length - done;
        // AAsset_read takes a size_t but returns an int.
        if (want > (1 << 30)) {
            want = 1 << 30;
        }
        int count = AAsset_read(asset, (char *)buffer + done, (size_t)want);
        if (count < 0) {
            AAsset_close(asset);
            return -2;
        }
        if (count == 0) {
            break;
        }
        done += count;
    }
    AAsset_close(asset);
    return done;
}
#endif
