// Root build file — declares plugin versions once; applied per-module in app/build.gradle.kts.
// Keep these versions aligned with the shared contract:
//   Android Gradle Plugin 8.x · Kotlin 1.9.x.
plugins {
    id("com.android.application") version "8.5.2" apply false
    id("org.jetbrains.kotlin.android") version "1.9.24" apply false
}
