plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.plugin.compose")
}
android {
    namespace = "com.kenshiki.reference"
    compileSdk { version = release(37) { minorApiLevel = 0 } }
    defaultConfig {
        applicationId = "com.kenshiki.reference"
        minSdk = 28
        targetSdk = 37
        versionCode = 1
        versionName = "0.0.0"
    }
    sourceSets["main"].apply {
        kotlin.directories.addAll(listOf("../../../presentation/android/src/main/kotlin", "../../../design-system/generated/android/kotlin", "../../../design-system/generated/android/reference"))
        res.directories.add("../../../design-system/generated/android/res")
    }
    sourceSets["test"].kotlin.directories.add("../../../presentation/android/src/test/kotlin")
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    buildFeatures { compose = true; buildConfig = true }
    buildTypes {
        getByName("release") {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"))
        }
    }
    lint { abortOnError = true; warningsAsErrors = true }
}
kotlin {
    jvmToolchain(17)
    compilerOptions { allWarningsAsErrors.set(true) }
}

dependencies {
    implementation(project(":biometric-contract"))
    constraints {
        implementation("androidx.compose:compose-bom") {
            version { strictly("2026.03.01") }
            because("Retain the reviewed Compose component versions during the SDK 37 toolchain migration")
        }
    }
    implementation(platform("androidx.compose:compose-bom"))
    implementation("androidx.activity:activity-compose") {
        version { strictly("1.12.4") }
        because("Retain the reviewed Activity version during the SDK 37 toolchain migration")
    }
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.foundation:foundation")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-core")
    testImplementation(libs.junit)
}

tasks.withType<Test>().configureEach { systemProperty("kenshiki.repoRoot", rootDir.resolve("../..").canonicalPath) }
