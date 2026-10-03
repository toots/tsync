import java.util.concurrent.atomic.AtomicLong

plugins {
    id("org.jetbrains.kotlin.jvm")
}

kotlin {
    jvmToolchain(21)
    compilerOptions { jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17) }
}

java {
    sourceCompatibility = JavaVersion.VERSION_17
    targetCompatibility = JavaVersion.VERSION_17
}

dependencies {
    // The platform ships org.json; the JVM suites bring their own.
    compileOnly("org.json:json:20250517")
    testImplementation("org.json:json:20250517")
    testImplementation(kotlin("test"))
}

tasks.test {
    useJUnitPlatform()
    val wireBinary = providers.environmentVariable("TSYNC_BIN")
    inputs.property("tsyncBin", wireBinary.orElse(""))
    // The binary is not a tracked input: its tests must run again against a rebuilt one.
    outputs.upToDateWhen { !wireBinary.isPresent }
    val wireTests = AtomicLong()
    addTestListener(object : TestListener {
        override fun beforeSuite(suite: TestDescriptor) {}
        override fun afterSuite(suite: TestDescriptor, result: TestResult) {}
        override fun beforeTest(test: TestDescriptor) {}
        override fun afterTest(test: TestDescriptor, result: TestResult) {
            val wire = test.className?.endsWith(".WireTest") == true
            if (wire && result.resultType != TestResult.ResultType.SKIPPED) wireTests.incrementAndGet()
        }
    })
    doFirst { wireTests.set(0) }
    doLast {
        if (!wireBinary.isPresent) {
            logger.warn("\n*** WIRE SUITE NOT RUN: TSYNC_BIN is unset, so no request or reply shape was checked against a real tsync. ***\n")
        } else if (wireTests.get() == 0L) {
            throw GradleException("TSYNC_BIN is set but the wire suite executed no test")
        } else {
            logger.lifecycle("wire suite executed ${wireTests.get()} tests against ${wireBinary.get()}")
        }
    }
}
