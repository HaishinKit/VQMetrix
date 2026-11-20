plugins {
    alias(libs.plugins.androidApplication) apply false
    alias(libs.plugins.androidLibrary) apply false
    alias(libs.plugins.jetbrainsKotlinAndroid) apply false
    alias(libs.plugins.kotlin.serialization) apply false
    alias(libs.plugins.jetbrainsDokka) apply false
}
rootProject.ext["PUBLISH_GROUP_ID"] = "com.github.HaishinKit"
rootProject.ext["PUBLISH_VERSION"] = "0.17.0"
