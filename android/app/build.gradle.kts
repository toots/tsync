// Imported rather than spelled out at the use site: `java` there resolves to the
// Java plugin extension, not the package.
import java.util.concurrent.atomic.AtomicInteger

plugins {
    id("com.android.application") version "8.7.3"
    kotlin("android") version "2.0.21"
}

android {
    namespace = "org.feverdreamtv.tsync"
    compileSdk = 35

    defaultConfig {
        applicationId = "org.feverdreamtv.tsync"
        // openProxyFileDescriptor (ranged reads, a later milestone) is API 26,
        // and the daemon is built against the android26 NDK headers. Both floors
        // have to agree.
        minSdk = 26
        targetSdk = 35
        // A nightly has to outrank the one before it or installing over it is
        // refused as a downgrade.
        versionCode = (System.getenv("BUILD_NUMBER") ?: "1").toInt()
        versionName = "0.1"
        ndk { abiFilters += "arm64-v8a" }
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }

    buildTypes {
        release { isMinifyEnabled = false }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }

    testOptions {
        unitTests {
            isIncludeAndroidResources = true
            isReturnDefaultValues = true
        }
    }
}

dependencies {
    // api, not implementation: keys and the wire's error type are part of what
    // the app's own classes hand each other.
    api(project(":core"))
    implementation("androidx.work:work-runtime-ktx:2.10.1")

    testImplementation("junit:junit:4.13.2")
    // The real thing: android.jar is stubbed for unit tests, and the protocol
    // test reads replies rather than asserting against a default-valued object.
    testImplementation("org.json:json:20240303")
    testImplementation("org.robolectric:robolectric:4.14.1")
    testImplementation("androidx.test:core:1.6.1")
    testImplementation("androidx.work:work-testing:2.10.1")
    testImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.8.1")

    androidTestImplementation("androidx.test:core:1.6.1")
    androidTestImplementation("androidx.test:runner:1.6.2")
    androidTestImplementation("androidx.test:rules:1.6.1")
    androidTestImplementation("androidx.test.ext:junit:1.2.1")
}

// A test task reports success when it ran nothing at all — a missing source set,
// a filter that matched no class, a runner that never started. Count what
// actually executed and refuse to call zero a pass.
tasks.withType<Test>().configureEach {
    val executed = AtomicInteger()
    addTestListener(object : TestListener {
        override fun beforeSuite(suite: TestDescriptor) {}
        override fun afterSuite(suite: TestDescriptor, result: TestResult) {}
        override fun beforeTest(test: TestDescriptor) {}
        override fun afterTest(test: TestDescriptor, result: TestResult) {
            executed.incrementAndGet()
        }
    })
    doLast {
        if (executed.get() == 0) throw GradleException("$path ran zero tests")
    }
}

// The domain is built by dune, not gradle. Stage it straight out of the cross
// build so the APK can never ship a stale library, and so a 14MB artifact stays
// out of git.
// One prebuilt directory per host platform, so it is looked up rather than
// spelled out: a CI runner's NDK is not where a homebrew cask puts one.
val ndkStrip: File by lazy {
    val ndk = file(System.getenv("ANDROID_NDK_ROOT")
        ?: System.getenv("ANDROID_NDK_LATEST_HOME")
        ?: "/opt/homebrew/share/android-ndk")
    val strip = ndk.resolve("toolchains/llvm/prebuilt").listFiles().orEmpty()
        .map { it.resolve("bin/llvm-strip") }.firstOrNull { it.exists() }
    requireNotNull(strip) { "no llvm-strip under $ndk — set ANDROID_NDK_ROOT" }
}

// An APK without the domain is useless, but a *test* without it is not: the unit
// suites drive the protocol against a natively built binary, or against a fake.
// So a missing cross build skips the staging rather than failing every task in
// the project, and the release build asks for the hard failure with
// -PrequireDaemon.
val requireDaemon = providers.gradleProperty("requireDaemon").isPresent

// A FileCollection, not inputs.file: that one fails the task outright when the
// path does not exist, which is the case the gate exists to allow.
fun stage(name: String, from: String, to: String) =
    tasks.register(name) {
        val built = rootProject.file(from)
        val staged = file(to)
        inputs.files(built)
        outputs.file(staged)
        onlyIf { built.exists() || requireDaemon }
        doLast {
            require(built.exists()) {
                "missing $built — run `dune build -x android $from` first"
            }
            staged.parentFile.mkdirs()
            built.copyTo(staged, overwrite = true)
            staged.setWritable(true)
            // llvm-strip drops .symtab and the debug sections but keeps
            // .dynsym, so the Java_* entry points still resolve.
            exec { commandLine(ndkStrip.absolutePath, staged.absolutePath) }
        }
    }

val stageLibrary = stage(
    "stageLibrary",
    "../_build/default.android/lib/app/frontends/android/jni/libtsyncjni.so",
    "src/main/jniLibs/arm64-v8a/libtsyncjni.so"
)

tasks.named("preBuild") { dependsOn(stageLibrary) }
