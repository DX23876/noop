// The JNI types and function table for the Android entry points in NoopCore, and the bridge that lets Swift's
// main actor run on Android's main thread. Empty off Android.
#if __has_include(<jni.h>)
#include <jni.h>
#endif

#if defined(__ANDROID__)
/// Hooks libdispatch's main queue into the calling thread's ALooper, so work for DispatchQueue.main (and with it
/// Swift's @MainActor) runs there. Call once, on Android's main thread. Returns 0 on success, a negative value when
/// the thread has no looper or the hook cannot be registered; calling it again after success does nothing.
int noop_install_main_queue_drain(void);
#endif
