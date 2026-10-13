plugins {
    alias(libs.plugins.kotlin.jvm)
    alias(libs.plugins.kotlin.serialization)
}

kotlin { jvmToolchain(17) }

dependencies {
    api(project(":core:session"))
    testImplementation(libs.junit)
    testImplementation(testFixtures(project(":core:session")))
    testImplementation(libs.kotlinx.coroutines.test)
    testImplementation(libs.turbine)
}
