pluginManagement {
    repositories {
        google {
            content {
                includeGroupByRegex("com\\.android.*")
                includeGroupByRegex("com\\.google.*")
                includeGroupByRegex("androidx.*")
            }
        }
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
        // Only for Tesseract4Android (Apache 2.0), which publishes there and nowhere else; every artifact is
        // still pinned by `gradle/verification-metadata.xml`.
        maven("https://jitpack.io") { content { includeGroup("cz.adaptech.tesseract4android") } }
    }
}

rootProject.name = "NOOP"
include(":app")
