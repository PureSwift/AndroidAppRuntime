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
