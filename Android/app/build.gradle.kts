plugins {
    alias(libs.plugins.androidApplication)
    alias(libs.plugins.jetbrainsKotlinAndroid)
}
android {
    namespace = "com.haishinkit.vqmetrix.launcher"
    compileSdk = 37
    defaultConfig {
        applicationId = "com.haishinkit.vqmetrix"
        minSdk = 29
        targetSdk = 37
        versionCode = 1
        versionName = providers.gradleProperty("appVersionName").orElse("0.1.0").get()
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlin { compilerOptions { jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17) } }
    testOptions { unitTests.isIncludeAndroidResources = true }
}
dependencies { implementation(project(":producer")) }
