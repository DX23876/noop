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
// MARK: - Shadow session (ShadowSession.swift)

private func bytes(_ env: UnsafeMutablePointer<JNIEnv?>, _ array: jbyteArray) -> [UInt8] {
    guard let fns = env.pointee?.pointee else { return [] }
    let count = Int(fns.GetArrayLength(env, array))
    var out = [UInt8](repeating: 0, count: count)
    out.withUnsafeMutableBufferPointer { buffer in
        buffer.baseAddress!.withMemoryRebound(to: jbyte.self, capacity: count) {
            fns.GetByteArrayRegion(env, array, 0, jsize(count), $0)
        }
    }
    return out
}

private func string(_ env: UnsafeMutablePointer<JNIEnv?>, _ value: jstring) -> String? {
    guard let fns = env.pointee?.pointee, let chars = fns.GetStringUTFChars(env, value, nil) else { return nil }
    defer { fns.ReleaseStringUTFChars(env, value, chars) }
    return String(cString: chars)
}

@_cdecl("Java_com_noop_core_SwiftCore_shadowStart")
public func jniShadowStart(_ env: UnsafeMutablePointer<JNIEnv?>?, _ cls: jclass?,
                           _ path: jstring?, _ deviceId: jstring?) -> jint {
    guard let env, let path, let deviceId, let p = string(env, path), let d = string(env, deviceId) else { return -3 }
    return ShadowSession.start(path: p, deviceId: d)
}

@_cdecl("Java_com_noop_core_SwiftCore_shadowFamily")
public func jniShadowFamily(_ env: UnsafeMutablePointer<JNIEnv?>?, _ cls: jclass?, _ whoop5: jboolean) {
    ShadowSession.send(.family(whoop5: whoop5 != 0))
}

@_cdecl("Java_com_noop_core_SwiftCore_shadowClock")
public func jniShadowClock(_ env: UnsafeMutablePointer<JNIEnv?>?, _ cls: jclass?, _ device: jlong, _ wall: jlong) {
    ShadowSession.send(.clock(device: Int(device), wall: Int(wall)))
}

@_cdecl("Java_com_noop_core_SwiftCore_shadowLiveFrame")
public func jniShadowLiveFrame(_ env: UnsafeMutablePointer<JNIEnv?>?, _ cls: jclass?, _ frame: jbyteArray?) {
    guard let env, let frame else { return }
    ShadowSession.send(.live(bytes(env, frame)))
}

@_cdecl("Java_com_noop_core_SwiftCore_shadowOffloadBegin")
public func jniShadowOffloadBegin(_ env: UnsafeMutablePointer<JNIEnv?>?, _ cls: jclass?, _ continued: jboolean) {
    ShadowSession.send(.offloadBegin(continuedAfterRows: continued != 0))
}

@_cdecl("Java_com_noop_core_SwiftCore_shadowOffloadFrame")
public func jniShadowOffloadFrame(_ env: UnsafeMutablePointer<JNIEnv?>?, _ cls: jclass?, _ frame: jbyteArray?) {
    guard let env, let frame else { return }
    ShadowSession.send(.offload(bytes(env, frame)))
}

@_cdecl("Java_com_noop_core_SwiftCore_shadowFlush")
public func jniShadowFlush(_ env: UnsafeMutablePointer<JNIEnv?>?, _ cls: jclass?) {
    ShadowSession.send(.flush)
}

@_cdecl("Java_com_noop_core_SwiftCore_shadowResetTally")
public func jniShadowResetTally(_ env: UnsafeMutablePointer<JNIEnv?>?, _ cls: jclass?) {
    ShadowSession.send(.resetTally)
}

@_cdecl("Java_com_noop_core_SwiftCore_shadowAnalyze")
public func jniShadowAnalyze(_ env: UnsafeMutablePointer<JNIEnv?>?, _ cls: jclass?, _ age: jint, _ sex: jstring?,
                             _ weightKg: jdouble, _ heightCm: jdouble, _ hrMaxOverride: jint) {
    guard let env, let sex, let s = string(env, sex) else { return }
    ShadowSession.send(.analyze(.init(age: Int(age), sex: s, weightKg: weightKg, heightCm: heightCm,
                                      hrMaxOverride: Int(hrMaxOverride))))
}

@_cdecl("Java_com_noop_core_SwiftCore_shadowToday")
public func jniShadowToday(_ env: UnsafeMutablePointer<JNIEnv?>?, _ cls: jclass?) -> jstring? {
    guard let env, let fns = env.pointee?.pointee, let line = ShadowSession.today else { return nil }
    return line.withCString { fns.NewStringUTF(env, $0) }
}

@_cdecl("Java_com_noop_core_SwiftCore_shadowTally")
public func jniShadowTally(_ env: UnsafeMutablePointer<JNIEnv?>?, _ cls: jclass?) -> jstring? {
    guard let env, let fns = env.pointee?.pointee else { return nil }
    return ShadowSession.tally.line.withCString { fns.NewStringUTF(env, $0) }
}
// MARK: - Reads for the screens (Android plan E-2): JSON, or null when no session runs or nothing is stored.
// They block the calling thread until the store answers, so Kotlin calls them off the main thread.

private func json(_ env: UnsafeMutablePointer<JNIEnv?>, _ value: String?) -> jstring? {
    guard let fns = env.pointee?.pointee, let value else { return nil }
    return value.withCString { fns.NewStringUTF(env, $0) }
}

@_cdecl("Java_com_noop_core_SwiftCore_readDay")
public func jniReadDay(_ env: UnsafeMutablePointer<JNIEnv?>?, _ cls: jclass?, _ day: jstring?) -> jstring? {
    guard let env, let day, let d = string(env, day) else { return nil }
    return json(env, Bridge.readDay(d))
}

@_cdecl("Java_com_noop_core_SwiftCore_readNights")
public func jniReadNights(_ env: UnsafeMutablePointer<JNIEnv?>?, _ cls: jclass?, _ from: jlong,
                          _ to: jlong) -> jstring? {
    guard let env else { return nil }
    return json(env, Bridge.readNights(from: Int(from), to: Int(to)))
}

@_cdecl("Java_com_noop_core_SwiftCore_readSeries")
public func jniReadSeries(_ env: UnsafeMutablePointer<JNIEnv?>?, _ cls: jclass?, _ metric: jstring?,
                          _ from: jstring?, _ to: jstring?) -> jstring? {
    guard let env, let metric, let from, let to, let m = string(env, metric), let f = string(env, from),
          let t = string(env, to) else { return nil }
    return json(env, Bridge.readSeries(m, from: f, to: t))
}

@_cdecl("Java_com_noop_core_SwiftCore_seedDemo")
public func jniSeedDemo(_ env: UnsafeMutablePointer<JNIEnv?>?, _ cls: jclass?) -> jint {
    jint(Bridge.seedDemo())
}

@_cdecl("Java_com_noop_core_SwiftCore_exportBackup")
public func jniExportBackup(_ env: UnsafeMutablePointer<JNIEnv?>?, _ cls: jclass?, _ dest: jstring?, _ scratch: jstring?,
                            _ version: jstring?, _ build: jstring?) -> jstring? {
    guard let env, let dest, let scratch, let version, let build, let d = string(env, dest),
          let s = string(env, scratch), let v = string(env, version), let b = string(env, build) else { return nil }
    return json(env, Bridge.exportBackup(to: d, scratch: s, appVersion: v, appBuild: b))
}

@_cdecl("Java_com_noop_core_SwiftCore_importBackup")
public func jniImportBackup(_ env: UnsafeMutablePointer<JNIEnv?>?, _ cls: jclass?, _ source: jstring?,
                            _ scratch: jstring?, _ allowOversize: jboolean) -> jstring? {
    guard let env, let source, let scratch, let src = string(env, source), let s = string(env, scratch) else { return nil }
    return json(env, Bridge.importBackup(from: src, scratch: s, allowOversize: allowOversize != 0))
}

@_cdecl("Java_com_noop_core_SwiftCore_shadowAwaitBanked")
public func jniShadowAwaitBanked(_ env: UnsafeMutablePointer<JNIEnv?>?, _ cls: jclass?, _ endData: jbyteArray?,
                                 _ timeoutMs: jlong) -> jboolean {
    guard let env, let endData else { return 0 }
    return ShadowSession.awaitBanked(endData: bytes(env, endData), timeout: Double(timeoutMs) / 1000) ? 1 : 0
}
#endif
