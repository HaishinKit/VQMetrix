plugins {
    alias(libs.plugins.androidLibrary)
    alias(libs.plugins.jetbrainsKotlinAndroid)
    alias(libs.plugins.jetbrainsDokka)
}
val releaseVersion = providers.gradleProperty("appVersionName").orElse("0.1.0").get()
require(releaseVersion.matches(Regex("[0-9]+[.][0-9]+[.][0-9]+(?:-[0-9A-Za-z.-]+)?")))

android {
    namespace = "com.haishinkit.vqmetrix"
    compileSdk = 37
    defaultConfig {
        minSdk = 29
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        buildConfigField("String", "VQMETRIX_VERSION", "\"$releaseVersion\"")
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlin { compilerOptions { jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17) } }
    buildFeatures { buildConfig = true }
    testOptions { unitTests.isIncludeAndroidResources = true }
}
dependencies {
    implementation(project(":haishinkit"))
    implementation(libs.kotlinx.coroutines.core)
    testImplementation(libs.junit)
    testImplementation(libs.robolectric)
    androidTestImplementation(libs.androidx.junit)
    androidTestImplementation(libs.androidx.test.runner)
}
dokka {
    moduleName.set("VQMetrix Android")
    moduleVersion.set(releaseVersion)
    dokkaPublications.html { outputDirectory.set(layout.buildDirectory.dir("dokka/html")) }
    dokkaSourceSets.configureEach {
        suppress.set(name != "release")
        includes.from(project.layout.projectDirectory.file("module-docs.md"))
    }
}
