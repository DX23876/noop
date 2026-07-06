# NOOP — R8 / ProGuard rules.
#
# The app is offline and reflection-light, but the release build now runs R8 (minify +
# resource shrink; full-mode OFF — see gradle.properties). These keeps pin the handful of
# reflective survivors so a shrunk release matches the debug build's runtime behaviour.

# Keep Room-generated database implementation classes (Room embeds its own rules too,
# but this is an explicit safety net for the *_Impl classes it generates).
-keep class com.noop.data.** { *; }

# Protocol enums are matched by Int rawValue via fromRaw(...); keep their members so a
# future reflective/serialized path can't be broken by minification. They are small.
-keep class com.noop.protocol.** { *; }

# --- Reflective survivors that R8 would otherwise strip/rename ---

# Google Tink (via androidx.security:security-crypto → EncryptedSharedPreferences for the
# encrypted key store). Tink registers KeyManagers reflectively and uses protobuf-generated
# classes; strip/rename either and the encrypted store throws at first use. Keep both.
-keep class com.google.crypto.tink.** { *; }
-keep class com.google.protobuf.** { *; }
-dontwarn com.google.crypto.tink.**
-dontwarn com.google.protobuf.**

# WorkManager instantiates ListenableWorker subclasses reflectively via the default
# WorkerFactory: Class.forName(name).getConstructor(Context, WorkerParameters). Keep every
# Worker's (Context, WorkerParameters) constructor or a background job dies with a ClassNotFound.
-keep public class * extends androidx.work.ListenableWorker {
    public <init>(android.content.Context, androidx.work.WorkerParameters);
}

# enum values()/valueOf() are reached reflectively (and by R8's own enum handling). Full-mode
# is off, but keep them explicitly so ordinal/name round-trips (settings, exports) stay intact.
-keepclassmembers enum * {
    public static **[] values();
    public static ** valueOf(java.lang.String);
}

# Parcelable CREATOR fields are read reflectively by the framework.
-keepclassmembers class * implements android.os.Parcelable {
    public static final ** CREATOR;
}

# JNI-bound methods must keep their names.
-keepclasseswithmembernames class * {
    native <methods>;
}

# okhttp/okio ship consumer rules but reference optional platform classes not on-device.
-dontwarn okhttp3.internal.platform.**
-dontwarn org.conscrypt.**
-dontwarn org.bouncycastle.**
-dontwarn org.openjsse.**

# Tink (pulled in by androidx.security:security-crypto for the encrypted AI-key store)
# references errorprone annotations that aren't on the runtime classpath. They're
# compile-time only and safe to ignore under R8.
-dontwarn com.google.errorprone.annotations.CanIgnoreReturnValue
-dontwarn com.google.errorprone.annotations.CheckReturnValue
-dontwarn com.google.errorprone.annotations.Immutable
-dontwarn com.google.errorprone.annotations.RestrictedApi

# Preserve line numbers for readable stack traces, then hide the original source file name.
-keepattributes SourceFile,LineNumberTable
-renamesourcefileattribute SourceFile
