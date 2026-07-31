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
        versionCode = 1
        versionName = "0.1"
        ndk { abiFilters += "arm64-v8a" }
    }

    // The daemon is an executable, not a library: it has to be unpacked to disk
    // before it can be exec'd. Pairs with extractNativeLibs in the manifest.
    packaging { jniLibs { useLegacyPackaging = true } }

    buildTypes {
        release { isMinifyEnabled = false }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }
}

// The daemon is built by dune, not gradle. Stage it straight out of the cross
// build so the APK can never ship a stale binary, and so a 14MB artifact stays
// out of git.
val ndkStrip = "/opt/homebrew/share/android-ndk/toolchains/llvm/prebuilt/darwin-x86_64/bin/llvm-strip"

val stageDaemon by tasks.registering {
    val built = rootProject.file("../_build/default.android/bin/tsync.exe")
    val staged = file("src/main/jniLibs/arm64-v8a/libtsync.so")
    inputs.file(built)
    outputs.file(staged)
    doLast {
        require(built.exists()) {
            "missing $built — run `dune build -x android bin/tsync.exe` first"
        }
        staged.parentFile.mkdirs()
        built.copyTo(staged, overwrite = true)
        staged.setWritable(true)
        exec { commandLine(ndkStrip, staged.absolutePath) }
    }
}

tasks.named("preBuild") { dependsOn(stageDaemon) }
