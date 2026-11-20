plugins {
    alias(libs.plugins.androidLibrary)
    alias(libs.plugins.jetbrainsKotlinAndroid)
    alias(libs.plugins.jetbrainsDokka)
    `maven-publish`
}
val releaseVersion = providers.gradleProperty("publishVersion").orElse(providers.provider { projectDir.resolve("../../VERSION").readText().trim() }).get()
require(releaseVersion.matches(Regex("(?:[0-9]+[.][0-9]+[.][0-9]+(?:-[0-9A-Za-z.-]+)?|[0-9a-f]{7,40})")))
group = "com.github.HaishinKit"
version = releaseVersion

android {
    namespace = "com.haishinkit.vqmetrix"
    compileSdk = 37
    defaultConfig {
        minSdk = 26
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlin { compilerOptions { jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17) } }
    testOptions { unitTests.isIncludeAndroidResources = true }
    publishing { singleVariant("release") { withSourcesJar() } }
}
dependencies {
    implementation(libs.kotlinx.coroutines.core)
    testImplementation(libs.junit)
    testImplementation(libs.robolectric)
    androidTestImplementation(libs.androidx.junit)
    androidTestImplementation(libs.androidx.test.runner)
}
afterEvaluate {
    publishing {
        publications {
            create<MavenPublication>("release") {
                from(components["release"])
                artifactId = "VQMetrix"
                pom {
                    name.set("VQMetrix Android Transfer")
                    description.set("LAN upload and Bonjour discovery for VQMetrix evaluation samples")
                    url.set("https://github.com/HaishinKit/VQMetrix")
                    licenses { license { name.set("BSD 3-Clause License"); url.set("https://opensource.org/license/bsd-3-clause") } }
                    developers { developer { id.set("shogo4405"); name.set("Shogo Endo") } }
                    scm { url.set("https://github.com/HaishinKit/VQMetrix"); connection.set("scm:git:https://github.com/HaishinKit/VQMetrix.git") }
                }
            }
        }
        repositories { maven { name = "verification"; url = rootProject.layout.buildDirectory.dir("maven-repository").get().asFile.toURI() } }
    }
}
dokka {
    moduleName.set("VQMetrix Android Transfer")
    moduleVersion.set(releaseVersion)
    dokkaPublications.html { outputDirectory.set(layout.buildDirectory.dir("dokka/html")) }
    dokkaSourceSets.configureEach {
        suppress.set(name != "release")
        includes.from(project.layout.projectDirectory.file("module-docs.md"))
    }
}

tasks.withType<Jar>().configureEach {
    from(layout.projectDirectory.file("../../LICENSE.md")) {
        into("META-INF")
        rename { "VQMetrix-LICENSE.txt" }
    }
}
