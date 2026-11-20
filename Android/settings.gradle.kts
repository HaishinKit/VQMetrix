pluginManagement { repositories { google(); mavenCentral(); gradlePluginPortal() } }
dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories { google(); mavenCentral() }
}
rootProject.name = "VQMetrixAndroid"
include(":producer", ":haishinkit")
project(":haishinkit").projectDir = file("../../HaishinKit.kt/haishinkit")
