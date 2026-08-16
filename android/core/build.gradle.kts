// The half of the app with no Android in it: storage keys, the daemon's wire,
// and everything that decides what a camera backup should do.
//
// A module of its own so those decisions are tested on a plain JVM. It is also
// what lets the protocol test drive a real daemon over a unix socket: android.jar
// carries its own java.nio and java.lang, and inside the app module it shadows
// the JDK classes that test needs.
import java.util.concurrent.atomic.AtomicInteger

plugins {
    kotlin("jvm") version "2.0.21"
}

repositories { mavenCentral() }

kotlin { jvmToolchain(17) }

dependencies {
    // Supplied by the platform on a device, so it is not packaged from here.
    compileOnly("org.json:json:20240303")

    testImplementation("org.json:json:20240303")
    testImplementation("junit:junit:4.13.2")
}

tasks.withType<Test>().configureEach {
    // The daemon the protocol test drives, when the caller has not said.
    systemProperty("tsync.repo", rootProject.projectDir.parent)

    // A test task reports success when it ran nothing at all.
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
