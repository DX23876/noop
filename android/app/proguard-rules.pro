# NOOP — R8 / ProGuard rules.
#
# The app is offline and reflection-light. Room generates its own keep rules, and
# Compose ships consumer rules, so this file is mostly empty by design. Add keeps
# here only if a release build strips something the BLE/protocol layer needs at runtime.
#
# NOTE: release currently ships UNMINIFIED (build.gradle.kts) because R8 crashed it at
# runtime even with broad keeps — so these rules are dormant until minify is re-enabled.

# Keep Room-generated database implementation classes (Room embeds its own rules too,
# but this is an explicit safety net for the *_Impl classes it generates).
-keep class com.noop.data.** { *; }

# Protocol enums are matched by Int rawValue via fromRaw(...); keep their members so a
# future reflective/serialized path can't be broken by minification. They are small.
-keep class com.noop.protocol.** { *; }

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
