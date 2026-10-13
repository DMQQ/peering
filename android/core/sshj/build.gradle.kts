plugins {
    alias(libs.plugins.kotlin.jvm)
}

kotlin { jvmToolchain(17) }

dependencies {
    api(project(":core:ssh"))
    implementation(libs.sshj)
    implementation(libs.bouncycastle.prov)
    implementation(libs.bouncycastle.pkix)
    implementation(libs.slf4j.nop)
    testImplementation(libs.junit)
    testImplementation(testFixtures(project(":core:session")))
    testImplementation(libs.sshd.core)
    testImplementation(libs.sshd.sftp)
}
