allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
// Ditto's transports-android requires compileSdk 36+; ditto_flutter_tools pins
// 35. Force every library subproject to compile against 36 (compileSdk only
// gates which APIs are visible — it doesn't change runtime behavior). This
// block must run BEFORE evaluationDependsOn below, or some plugins are
// already evaluated when the hook registers.
subprojects {
    afterEvaluate {
        val library = extensions.findByName("android") as? com.android.build.gradle.LibraryExtension
        library?.compileSdk = 36
    }
}

subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
