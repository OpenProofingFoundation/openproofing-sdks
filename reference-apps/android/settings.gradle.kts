pluginManagement { repositories { google(); mavenCentral(); gradlePluginPortal() } }
dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories { google(); mavenCentral() }
    versionCatalogs { create("libs") { from(files("../../biometric/android/gradle/libs.versions.toml")) } }
}
rootProject.name = "kenshiki-reference"
include(":app")
include(":biometric-contract")
