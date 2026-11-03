plugins { id("com.android.library") }

// Reference-host integration builds the same independently tested SDK sources
// using the host's AGP 9 built-in Kotlin. No copied implementation or runtime dependency.
extensions.configure<com.android.build.api.dsl.LibraryExtension> {
    namespace = "com.kenshikilabs.biometric"
    compileSdk = 36
    defaultConfig { minSdk = 26 }
    sourceSets["main"].apply {
        kotlin.directories.addAll(listOf("../../../biometric/android/biometric-sdk/src/main/kotlin"))
        manifest.srcFile("../../../biometric/android/biometric-sdk/src/main/AndroidManifest.xml")
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}
kotlin { jvmToolchain(17); compilerOptions { allWarningsAsErrors.set(true) } }
