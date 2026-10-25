#if os(Android)
import CJNI

// JNI entry points for com.noop.core.SwiftCore (android/app/src/main/java/com/noop/core/SwiftCore.kt). Each
// converts its Java arguments and calls the matching Bridge function; nothing else happens here.

@_cdecl("Java_com_noop_core_SwiftCore_recipeVersion")
public func jniRecipeVersion(_ env: UnsafeMutablePointer<JNIEnv?>?, _ cls: jclass?) -> jint {
    Bridge.recipeVersion()
}

@_cdecl("Java_com_noop_core_SwiftCore_openStore")
public func jniOpenStore(_ env: UnsafeMutablePointer<JNIEnv?>?, _ cls: jclass?, _ path: jstring?) -> jlong {
    guard let env, let path, let fns = env.pointee?.pointee,
          let chars = fns.GetStringUTFChars(env, path, nil) else { return -3 }
    defer { fns.ReleaseStringUTFChars(env, path, chars) }
    return Bridge.openStore(path: String(cString: chars))
}
@_cdecl("Java_com_noop_core_SwiftCore_installMainActor")
public func jniInstallMainActor(_ env: UnsafeMutablePointer<JNIEnv?>?, _ cls: jclass?) -> jint {
    noop_install_main_queue_drain()
}

@_cdecl("Java_com_noop_core_SwiftCore_scheduleMainActorProbe")
public func jniScheduleMainActorProbe(_ env: UnsafeMutablePointer<JNIEnv?>?, _ cls: jclass?) {
    Bridge.scheduleMainActorProbe()
}

@_cdecl("Java_com_noop_core_SwiftCore_mainActorProbeRuns")
public func jniMainActorProbeRuns(_ env: UnsafeMutablePointer<JNIEnv?>?, _ cls: jclass?) -> jint {
    Bridge.mainActorProbeRuns
}
@_cdecl("Java_com_noop_core_SwiftCore_mainActorProbeOnMainThread")
public func jniMainActorProbeOnMainThread(_ env: UnsafeMutablePointer<JNIEnv?>?, _ cls: jclass?) -> jboolean {
    jboolean(Bridge.mainActorProbeOnMainThread ? JNI_TRUE : JNI_FALSE)
}
#endif
