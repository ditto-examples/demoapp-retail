pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
    }
}

rootProject.name = "zava-retail-android"
include(":app")

// Vendored Anvil design system (unpublished upstream) — composite build.
// Substitution: the app declares
//   implementation("live.ditto.anvil:anvil-material3:0.1.0-SNAPSHOT")
// and Gradle substitutes the included build's :anvil-material3 project.
// See PLAN.md §5 and vendor/anvil/COMMIT for provenance.
includeBuild("../vendor/anvil/android")
