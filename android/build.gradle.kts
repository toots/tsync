import java.util.concurrent.atomic.AtomicLong

plugins {
    id("com.android.application") version "9.4.1" apply false
    id("org.jetbrains.kotlin.jvm") version "2.4.20" apply false
    id("org.jetbrains.kotlin.plugin.compose") version "2.4.20" apply false
}

// app §12: a suite that ran nothing fails.
subprojects {
    tasks.withType<Test>().configureEach {
        val executed = AtomicLong()
        addTestListener(object : TestListener {
            override fun beforeSuite(suite: TestDescriptor) {}
            override fun afterSuite(suite: TestDescriptor, result: TestResult) {}
            override fun beforeTest(test: TestDescriptor) {}
            override fun afterTest(test: TestDescriptor, result: TestResult) {
                if (result.resultType != TestResult.ResultType.SKIPPED) executed.incrementAndGet()
            }
        })
        doFirst { executed.set(0) }
        doLast {
            if (executed.get() == 0L) throw GradleException("$path executed no test")
            logger.lifecycle("$path executed ${executed.get()} tests")
        }
    }
}
