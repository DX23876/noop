import java.util.Properties

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

// Optional release signing. Credentials live in `keystore.properties` (git-ignored, never
// committed); when it's absent — clones, CI without secrets — release falls back to the debug
// key so `assembleRelease` always produces an installable APK. See docs/BUILD.md.
val keystorePropsFile = rootProject.file("keystore.properties")
val keystoreProps = Properties().apply {
    if (keystorePropsFile.exists()) keystorePropsFile.inputStream().use { load(it) }
}
val isStagingRelease = project.hasProperty("stagingRelease")
val forkMinify = (project.findProperty("noop.minify") as String?)?.toBoolean() ?: true
val requestedReleaseBuild = gradle.startParameter.taskNames.any {
    it.contains("Release", ignoreCase = true)
}

// Fork (DX23876): the version name is the Apple app's MARKETING_VERSION, read from project.yml so the two
// cannot disagree; versionCode is Android's own counter (Android plan D11).
val forkMarketingVersion: String = rootProject.file("../project.yml").readLines()
    .firstNotNullOfOrNull { Regex("""^\s*MARKETING_VERSION:\s*"([^"]+)"""").find(it)?.groupValues?.get(1) }
    ?: error("MARKETING_VERSION not found in project.yml")

android {
    namespace = "com.noop"
    compileSdk = 35

    defaultConfig {
        // Fork (DX23876): its own id, so NOOP Forge installs beside ryanbr's com.noop.whoop (plan D11).
        applicationId = "io.github.dx23876.noop"
        minSdk = 26
        targetSdk = 34
        versionCode = 1
        versionName = forkMarketingVersion

        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        vectorDrawables {
            useSupportLibrary = true
        }
    }

    signingConfigs {
        getByName("debug") {
            val forkDebugKeystore = rootProject.file("fork-debug.keystore")
            if (forkDebugKeystore.exists()) {
                storeFile = forkDebugKeystore
                storePassword = "android"
                keyAlias = "androiddebugkey"
                keyPassword = "android"
            }
        }
        create("release") {
            if (keystorePropsFile.exists()) {
                storeFile = rootProject.file(keystoreProps.getProperty("storeFile"))
                storePassword = keystoreProps.getProperty("storePassword")
                keyAlias = keystoreProps.getProperty("keyAlias")
                keyPassword = keystoreProps.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        debug {
            isMinifyEnabled = false
            applicationIdSuffix = ".debug"
            versionNameSuffix = "-debug"
        }
        release {
            // Fork (DX23876), Android plan D24: R8 and resource shrinking are on, 57 MB down to 41 MB. Upstream
            // shipped unminified because a minified build died right after the terms gate on a real device; the
            // cause was "CompositionLocal LocalLifecycleOwner not present", lifecycle-runtime-compose 2.8.2 beside
            // Compose UI 1.6 under R8, fixed by Lifecycle 2.8.3 (2026-10-26). With it the minified build went through
            // terms, onboarding, every Forge screen, pairing, backup, the strap log and every classic screen on an
            // emulator without a crash; real devices are the testers' (D9). `-Pnoop.minify=false` builds without it.
            isMinifyEnabled = forkMinify
            isShrinkResources = forkMinify
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
            if (!keystorePropsFile.exists() && !isStagingRelease && requestedReleaseBuild) {
                throw GradleException(
                    "Refusing to build a real release without keystore.properties. " +
                        "Use -PstagingRelease for debug-key staging artifacts only."
                )
            }
            // Real release key when keystore.properties is present. The debug-key fallback is allowed
            // only for explicit fork/staging artifacts that install under their own application id.
            signingConfig = if (keystorePropsFile.exists()) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
            // Fork staging release: built with -PstagingRelease (the fork testing-build CI only), the
            // release APK gets its own id/name so it installs BESIDE both the official app and the
            // .debug staging build. A real release (no property) keeps the plain io.github.dx23876.noop id.
            if (isStagingRelease) {
                applicationIdSuffix = ".staging"
                versionNameSuffix = "-staging"
            }
        }
    }

    // Two clearly-distinct apps that install side-by-side:
    //   • full → "NOOP Forge"      (io.github.dx23876.noop)      — the real app, starts empty, pair a strap.
    //   • demo → "NOOP Forge Demo"  (io.github.dx23876.noop.demo) — preloaded with 120 days of synthetic data and
    //                          a visible DEMO badge, so anyone can explore every screen with no strap.
    // Build e.g. ./gradlew assembleFullRelease assembleDemoRelease.
    flavorDimensions += "tier"
    productFlavors {
        create("full") {
            dimension = "tier"
            buildConfigField("String", "TIER", "\"full\"")
            buildConfigField("boolean", "ENABLE_DEMO", "false")
        }
        create("demo") {
            dimension = "tier"
            applicationIdSuffix = ".demo"
            versionNameSuffix = "-demo"
            buildConfigField("String", "TIER", "\"demo\"")
            buildConfigField("boolean", "ENABLE_DEMO", "true")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }

    buildFeatures {
        compose = true
        buildConfig = true
    }

    composeOptions {
        // Compose Compiler extension matched to Kotlin 1.9.24 (see the official
        // Compose-to-Kotlin compatibility map). Bumping Kotlin requires bumping this.
        kotlinCompilerExtensionVersion = "1.5.14"
    }

    packaging {
        resources {
            excludes += "/META-INF/{AL2.0,LGPL2.1}"
        }
    }
}

// Fork (DX23876), Android plan D-5: the shared Swift core. Every build compiles Packages/NoopCoreJNI for arm64 with
// the Swift SDK for Android (android/swift-core/build-swift-core.sh, which names what it needs) and packs
// libNoopCore.so with the Swift runtime into the APK. `-Pnoop.swiftCore=false` leaves it out for a machine without
// the toolchain; the app then runs as before and `SwiftCore.available` is false.
val forkSwiftCore = (findProperty("noop.swiftCore") as String?)?.toBoolean() ?: true
val forkSwiftCoreLibs = layout.buildDirectory.dir("swift-core/jniLibs")
val buildSwiftCore by tasks.registering(Exec::class) {
    description = "Builds the shared Swift core for Android into build/swift-core/jniLibs."
    onlyIf { forkSwiftCore }
    // The package sources and manifests, not their .build directories.
    inputs.files(fileTree(rootProject.file("../Packages")) {
        include("*/Package.swift", "*/Package.resolved", "*/Sources/**")
    }).withPropertyName("packages")
    inputs.dir(rootProject.file("swift-core")).withPropertyName("buildScripts")
    outputs.dir(forkSwiftCoreLibs)
    commandLine("bash", rootProject.file("swift-core/build-swift-core.sh").path,
                forkSwiftCoreLibs.get().asFile.path)
}
// The Apple String Catalog split per language for the text the shared core writes itself (`CoreLocalization`):
// `core-l10n/<language>.l10n`, JSON `{"source key": "translation"}`, only the reviewed translations. Android picks the
// file of the wearer's language at start (`CoreShadow.installResources`).
val forkCoreLocalization = layout.buildDirectory.dir("generated/core-l10n")
val buildCoreLocalization by tasks.registering {
    description = "Splits the Apple String Catalogs per language for the shared Swift core on Android."
    val catalogs = listOf(rootProject.file("../Strand/Resources/Localizable.xcstrings"),
                          rootProject.file("../Packages/StrandDesign/Sources/StrandDesign/Resources/Localizable.xcstrings"))
    inputs.files(catalogs).withPropertyName("catalogs")
    outputs.dir(forkCoreLocalization)
    doLast {
        val languages = mapOf("de" to "de", "fr" to "fr", "es" to "es", "pt-PT" to "pt", "pl" to "pl", "it" to "it",
                              "ru" to "ru", "zh-Hans" to "zh")
        val tables = languages.values.associateWith { sortedMapOf<String, String>() }
        @Suppress("UNCHECKED_CAST")
        for (catalog in catalogs) {
            val strings = (groovy.json.JsonSlurper().parse(catalog) as Map<String, Any?>)["strings"] as Map<String, Any?>
            for ((key, entry) in strings) {
                val localizations = (entry as? Map<String, Any?>)?.get("localizations") as? Map<String, Any?> ?: continue
                for ((apple, file) in languages) {
                    val unit = (localizations[apple] as? Map<String, Any?>)?.get("stringUnit") as? Map<String, Any?> ?: continue
                    val value = unit["value"] as? String ?: continue
                    if (unit["state"] == "new" || value.isEmpty()) continue
                    tables.getValue(file).putIfAbsent(key, value)
                }
            }
        }
        val dir = forkCoreLocalization.get().asFile.resolve("core-l10n").apply { deleteRecursively(); mkdirs() }
        // Not `.json`: the core's JSON assets are stored uncompressed, and these tables compress to a third.
        val json = groovy.json.JsonGenerator.Options().disableUnicodeEscaping().build()
        for ((file, table) in tables) dir.resolve("$file.l10n").writeText(json.toJson(table))
    }
}
if (forkSwiftCore) {
    android.sourceSets.getByName("main").jniLibs.srcDir(forkSwiftCoreLibs)
    android.sourceSets.getByName("main").assets.srcDir(forkCoreLocalization)
    // The core's packaged resources as assets, straight from the package that owns them;
    // `CoreShadow.installResources` unpacks them for the core, which has no SwiftPM resource bundle on Android.
    android.sourceSets.getByName("main").assets.srcDir(rootProject.file("../Packages/StrandTraining/Sources/StrandTraining/Resources"))
    android.sourceSets.getByName("main").assets.srcDir(rootProject.file("../Packages/WhoopProtocol/Sources/WhoopProtocol/Resources"))
    android.androidResources.noCompress += "json"
    // Compressed in the APK and extracted at install: the download is about a third of the size (D24 measured
    // 31 MB), which matters for an app that is only ever sideloaded.
    android.packaging.jniLibs.useLegacyPackaging = true
    tasks.named("preBuild") { dependsOn(buildSwiftCore, buildCoreLocalization) }
}

// Fork (DX23876): unit tests run in English wherever they run. Several assert formatted text ("8.6",
// "13 Jan") and passed only on runners whose locale happened to be English.
tasks.withType<Test>().configureEach {
    systemProperty("user.language", "en")
    systemProperty("user.country", "US")
    jvmArgs("-Duser.language=en", "-Duser.country=US")
}

// Fork (DX23876): the cross-platform parity contract is retired here (docs/fork/AGENT_RULES.md, 2026-07-23).
// These upstream tests compare Android with the fork's iOS sources, which differ on purpose; the deep core
// (Android plan phase D-5) replaces the Kotlin code they guard.
// Every method listed reads a Swift source or the iOS string catalogue; its Kotlin-only neighbours still run.
// Left in, they would turn this suite red on a later, unrelated push whenever the fork edits the iOS side.
val forkRetiredParityTests = listOf(
    "com.noop.data.SchemaOracleTest.oracleCopiesAreIdentical",
    "com.noop.testcentre.RawDataCollectorParityTest.androidAndAppleOracleCopiesAreByteIdentical",
    "com.noop.ui.CoachStaleTranscriptSurfaceTest.ios retires the stale transcript between the restore and the brief",
    "com.noop.ui.CoachStaleTranscriptSurfaceTest.both scheduled-brief paths date the transcript they create",
    "com.noop.ui.TodayWorkoutTapTest.iosTodayOpensTheSameDetailComponent",
    "com.noop.ui.TodayWorkoutTapTest.bothPlatformsWindowTheFeedToTheSameFourteenDays",
    "com.noop.ui.SleepStageRowOrderTest.apple sleep detail lists both its row stacks in chart-depth order",
    "com.noop.ui.SleepStageRowOrderTest.apple hosted stages card lists both its row stacks in chart-depth order",
    "com.noop.ui.SleepStageRowOrderTest.every stage row stack agrees, so no two screens can disagree",
    "com.noop.ui.HrEmptyMessageTest.neitherPlatformStillNamesAnUncheckedCause",
    "com.noop.ui.StressPersonalBaselineSurfaceTest.Apple detail and both Today implementations share the selected lens",
    "com.noop.ui.Spo2MissingCaptionTest.bothCaptionsMatchTheSwiftCatalogueWordForWord",
    "com.noop.ble.OuraInterruptedDrainCursorTest",
    "com.noop.widget.StressWidgetStoredGateTest.everyStressGateUsesTheUnionWitness",
)
// Two half-tie cases expect exactly -0.5 from exp/log arithmetic; on Apple silicon the JVM's maths differs in the
// last bit (-0.4999999999999929), the same 1 to 2 ulp gap the Android plan's decision D23 records. CI on Linux
// still runs them; only a local run on a Mac with an ARM chip leaves them out, so local test gates can pass.
val forkAppleSiliconUlpTests = listOf(
    "com.noop.analytics.RecoveryDriversTest.driverPointRoundingUsesNearestWithHalfTiesAwayFromZero",
    "com.noop.analytics.RecoveryDriversTest.issue51NegativeHalfTieUsesDefaultArg8WithoutChangingScoreOrDriverFields",
)
val forkOnAppleSilicon = System.getProperty("os.name").startsWith("Mac") && System.getProperty("os.arch") == "aarch64"
tasks.withType<Test>().configureEach {
    filter {
        forkRetiredParityTests.forEach { excludeTestsMatching(it) }
        if (forkOnAppleSilicon) forkAppleSiliconUlpTests.forEach { excludeTestsMatching(it) }
    }
}

// Resolve every external module to the exact version recorded in app/gradle.lockfile. Direct
// dependencies are already pinned below; this also freezes the transitive graph selected through
// AndroidX POMs and the Compose BOM. Update intentionally with `./gradlew :app:dependencies
// --write-locks` and review the lockfile diff alongside the dependency declaration change (#658).
dependencyLocking {
    lockAllConfigurations()
}

dependencies {
    // --- Compose (BOM pins all Compose artifact versions in lockstep) ---
    val composeBom = platform("androidx.compose:compose-bom:2024.06.00")
    implementation(composeBom)
    androidTestImplementation(composeBom)

    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.ui:ui-graphics")
    implementation("androidx.compose.ui:ui-tooling-preview")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-extended")

    // --- Home-screen widget (1.1.x: last line compatible with compileSdk 34) ---
    implementation("androidx.glance:glance-appwidget:1.1.1")
    // Glance's own POM pins work-runtime 2.7.1 (Oct 2021) — pre-Android-14. Pin a current one
    // explicitly so the widget scheduler runs on a WorkManager that's maintained for targetSdk 34.
    // (2.10+ needs compileSdk 35; 2.9.x is the ceiling for this module.)
    implementation("androidx.work:work-runtime-ktx:2.9.0")

    // --- Activity / lifecycle / navigation ---
    implementation("androidx.core:core-ktx:1.13.1")
    implementation("androidx.activity:activity-compose:1.9.0")
    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.8.3")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.8.3")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.8.3") // collectAsStateWithLifecycle
    implementation("androidx.navigation:navigation-compose:2.7.7")

    // --- Coroutines ---
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-core:1.8.1")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.8.1")

    // Fork (DX23876): no Room. The store is the shared core's; `data/CoreWhoopDao.kt` (generated by
    // Tools/gen_core_dao.py) runs the data access there (docs/fork/android/CORE-ONLY-PLAN.md). WorkManager keeps
    // its own job queue in Room, so Room stays a transitive dependency, held at the version already verified.
    constraints {
        implementation("androidx.room:room-runtime:2.6.1")
        implementation("androidx.room:room-ktx:2.6.1")
        implementation("androidx.sqlite:sqlite-framework:2.4.0")
    }

    // --- AI Coach (opt-in, bring-your-own-key). HTTP client + Keystore-backed key storage. ---
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
    implementation("androidx.security:security-crypto:1.1.0-alpha06")

    // --- Health Connect (optional native Android import of steps/HR/HRV/sleep/etc.) ---
    // Pinned to alpha07: alpha11+ require compileSdk 35; this module is compileSdk 34.
    implementation("androidx.health.connect:connect-client:1.1.0-alpha07")

    // --- Unit / instrumentation tests ---
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.jacoco:org.jacoco.core:0.8.12")
    testImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.8.1")
    testImplementation("org.json:json:20240303") // real org.json for JVM unit tests (android.jar ships throwing stubs)
    testImplementation("net.sf.kxml:kxml2:2.3.0") // real XmlPullParser for JVM tests (android.util.Xml is a throwing stub)
    testImplementation("org.xerial:sqlite-jdbc:3.41.2.2") // execute DAO aggregate SQL in plain-JVM tests
    testImplementation("org.robolectric:robolectric:4.13") // run the real Room open/migration in Linux CI (#1803)
    androidTestImplementation("androidx.test.ext:junit:1.1.5")
    androidTestImplementation("androidx.test.espresso:espresso-core:3.5.1")
    androidTestImplementation("androidx.compose.ui:ui-test-junit4")
    // Keep the Kotlin metadata module in the instrumentation runtime's lock. Without an explicit edge AGP's
    // tested-app graph resolves it only during APK assembly, after the dependency-report graph omitted it.
    androidTestRuntimeOnly("org.jetbrains.kotlin:kotlin-stdlib-common:1.9.24")

    // --- Compose tooling (debug-only) ---
    debugImplementation("androidx.compose.ui:ui-tooling")
    debugImplementation("androidx.compose.ui:ui-test-manifest")
}
