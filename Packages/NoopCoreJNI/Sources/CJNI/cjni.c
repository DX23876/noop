// Android only: libdispatch's main queue on Android's main looper (see cjni.h).
#include "cjni.h"

#if defined(__ANDROID__)
#include <android/looper.h>
#include <stdint.h>
#include <unistd.h>

// libdispatch exports these for CoreFoundation's run loop on Linux and Android, without a public header. The
// handle is an eventfd that becomes readable when the main queue has work; the callback drains the queue.
extern int _dispatch_get_main_queue_handle_4CF(void);
extern void _dispatch_main_queue_callback_4CF(void *msg);

static int installed = 0;

static int drain_main_queue(int fd, int events, void *data) {
    (void)events; (void)data;
    uint64_t count;
    (void)read(fd, &count, sizeof count);   // reset the eventfd before running the queued work
    _dispatch_main_queue_callback_4CF(NULL);
    return 1;                                // keep the callback registered
}

int noop_install_main_queue_drain(void) {
    if (installed) return 0;
    ALooper *looper = ALooper_forThread();
    if (looper == NULL) return -1;
    int fd = _dispatch_get_main_queue_handle_4CF();
    if (fd < 0) return -2;
    if (ALooper_addFd(looper, fd, ALOOPER_POLL_CALLBACK, ALOOPER_EVENT_INPUT, drain_main_queue, NULL) != 1) return -3;
    installed = 1;
    return 0;
}
#endif
