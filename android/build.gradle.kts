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
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}


// flutter_plugin_android_lifecycle 按 flutter.compileSdkVersion(36) 构建，
// file_picker 自带 compileSdk 34 → :file_picker:checkDebugAarMetadata 报 minCompileSdk 36。
// 强制所有 Android 模块 compileSdk 36（afterEvaluate + 已求值守卫，兼容
// evaluationDependsOn(":app") 的求值序）。
fun Project.forceCompileSdk36() {
    extensions.findByType<com.android.build.api.dsl.LibraryExtension>()?.compileSdk = 36
    extensions.findByType<com.android.build.api.dsl.ApplicationExtension>()?.compileSdk = 36
}

subprojects {
    if (state.executed) {
        forceCompileSdk36()
    } else {
        afterEvaluate { forceCompileSdk36() }
    }
}
