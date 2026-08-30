plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.android)
    alias(libs.plugins.kotlin.compose)
}

android {
    namespace = "live.ditto.zava"
    compileSdk = 37

    defaultConfig {
        applicationId = "live.ditto.zava"
        minSdk = 26 // ditto-tools-android requires API 26; the Ditto SDK itself supports 24
        targetSdk = 36
        versionCode = 1
        versionName = "0.1.0"
    }

    buildTypes {
        release {
            isMinifyEnabled = false
        }
    }

    buildFeatures {
        compose = true
        // M2: enable buildConfig + inject the root .env (DITTO_DATABASE_ID /
        // DITTO_DEVELOPMENT_TOKEN / DITTO_SERVER_URL) as BuildConfig fields,
        // same pattern as mflix-mongodb-connector (PLAN §4.3).
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

kotlin {
    compilerOptions {
        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
    }
}

dependencies {
    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.activity.compose)

    implementation(platform(libs.androidx.compose.bom))
    implementation(libs.androidx.compose.ui)
    implementation(libs.androidx.compose.ui.tooling.preview)
    debugImplementation(libs.androidx.compose.ui.tooling)
    implementation(libs.androidx.compose.material3)

    // Vendored Anvil design system — substituted by the composite build
    // (includeBuild in settings.gradle.kts). Swap for the published
    // coordinates once Anvil ships to Maven.
    implementation(libs.anvil.material3)
}
