plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.plugin.compose")
}

val buildNumber = providers.environmentVariable("BUILD_NUMBER").map { it.toInt() }.getOrElse(1)
val commit = providers.exec { commandLine("git", "rev-parse", "--short=12", "HEAD") }
    .standardOutput.asText.map { it.trim() }.getOrElse("unknown")
val keystore = providers.environmentVariable("ANDROID_KEYSTORE_FILE").orNull
val keystorePassword = providers.environmentVariable("ANDROID_KEYSTORE_PASSWORD").orNull
val noCore = providers.gradleProperty("noCore").isPresent

android {
    namespace = "org.feverdreamtv.tsync"
    compileSdk = 35

    defaultConfig {
        applicationId = "org.feverdreamtv.tsync"
        // Equals the API level the core is cross-built against (app §12).
        minSdk = 26
        targetSdk = 35
        versionCode = buildNumber
        versionName = "1.0.$buildNumber-$commit"
        buildConfigField("String", "COMMIT", "\"$commit\"")
        // One ABI is shipped. The device suite's package carries no core and runs on an
        // emulator of another ABI, so it keeps every ABI of its other libraries.
        if (!noCore) ndk { abiFilters += "arm64-v8a" }
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }

    signingConfigs {
        if (keystore != null && keystorePassword != null) {
            create("tsync") {
                storeFile = file(keystore)
                storePassword = keystorePassword
                keyAlias = "tsync"
                keyPassword = keystorePassword
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            signingConfig = signingConfigs.findByName("tsync") ?: signingConfigs.getByName("debug")
        }
    }

    buildFeatures {
        compose = true
        buildConfig = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    testOptions {
        unitTests.isIncludeAndroidResources = true
    }
}

dependencies {
    implementation(project(":core"))
    implementation(platform("androidx.compose:compose-bom:2025.04.01"))
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.activity:activity-compose:1.10.1")
    implementation("androidx.core:core-ktx:1.16.0")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.9.0")
    implementation("androidx.work:work-runtime:2.10.1")

    testImplementation("junit:junit:4.13.2")
    testImplementation("org.robolectric:robolectric:4.15.1")
    testImplementation("androidx.test:core:1.6.1")

    androidTestImplementation("androidx.test.ext:junit:1.2.1")
    androidTestImplementation("androidx.test:runner:1.6.2")
}

// app §12: the package carries the core cross-built from this commit, and no built library is
// kept in the repository. The device suite's package (-PnoCore) carries none, deliberately.
val coreLibrary = rootProject.file("../_build/default.android/lib/frontends/android/jni/libtsyncjni.so")
val stagedLibrary = layout.projectDirectory.file("src/main/jniLibs/arm64-v8a/libtsyncjni.so").asFile
val ndkHome = providers.environmentVariable("ANDROID_NDK_HOME").orNull

val stageCore by tasks.registering {
    inputs.property("noCore", noCore)
    inputs.files(coreLibrary).optional()
    outputs.upToDateWhen { false }
    doLast {
        if (noCore) {
            if (stagedLibrary.exists()) throw GradleException("-PnoCore: $stagedLibrary is staged, and this package must carry no core")
            return@doLast
        }
        if (!coreLibrary.exists()) {
            throw GradleException("The core library is missing: build $coreLibrary from this commit, or pass -PnoCore for a package without it")
        }
        coreLibrary.copyTo(stagedLibrary, overwrite = true)
        if (ndkHome != null) {
            val strip = fileTree(ndkHome) { include("toolchains/llvm/prebuilt/*/bin/llvm-strip") }.singleFile
            // Drops the symbol table and debug sections; the dynamic symbols JNI resolves stay.
            providers.exec { commandLine(strip.path, "--strip-unneeded", stagedLibrary.path) }.result.get().assertNormalExitValue()
        }
    }
}

tasks.matching { it.name.startsWith("merge") && it.name.endsWith("JniLibFolders") }.configureEach {
    dependsOn(stageCore)
}

tasks.withType<Test>().configureEach {
    // Robolectric runs the platform's SQLite and resources on the JVM.
    systemProperty("robolectric.logging", "stderr")
}
