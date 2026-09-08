plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.android)
    alias(libs.plugins.kotlin.compose)
    alias(libs.plugins.kotlin.serialization)
}

// Root .env → BuildConfig (mflix pattern, PLAN §4.3). Tolerant parsing like
// swift/buildEnv.sh: optional `export ` prefix, quotes stripped, CRLF ok,
// `#` comments skipped. Only the three SDK keys are read — never the loader's.
val envFile = rootDir.parentFile.resolve(".env")
val envValues: Map<String, String> =
    if (envFile.exists()) {
        envFile.readLines().mapNotNull { raw ->
            val line = raw.trim().removePrefix("export ").trim()
            if (line.isEmpty() || line.startsWith("#") || '=' !in line) return@mapNotNull null
            val key = line.substringBefore('=').trim()
            val value = line.substringAfter('=').trim().trim('"', '\'')
            key to value
        }.toMap()
    } else {
        emptyMap()
    }

fun envValue(key: String): String = envValues[key] ?: System.getenv(key) ?: ""

fun String.asBuildConfigLiteral(): String =
    "\"" + replace("\\", "\\\\").replace("\"", "\\\"") + "\""

android {
    namespace = "live.ditto.zava"
    compileSdk = 37

    defaultConfig {
        applicationId = "live.ditto.zava"
        minSdk = 26 // ditto-tools-android requires API 26; the Ditto SDK itself supports 24
        targetSdk = 36
        versionCode = 1
        versionName = "0.1.0"

        buildConfigField("String", "DITTO_DATABASE_ID", envValue("DITTO_DATABASE_ID").asBuildConfigLiteral())
        buildConfigField("String", "DITTO_DEVELOPMENT_TOKEN", envValue("DITTO_DEVELOPMENT_TOKEN").asBuildConfigLiteral())
        buildConfigField("String", "DITTO_SERVER_URL", envValue("DITTO_SERVER_URL").asBuildConfigLiteral())
    }

    buildTypes {
        release {
            isMinifyEnabled = false
        }
    }

    buildFeatures {
        compose = true
        buildConfig = true
    }

    // The 96-query benchmark catalog for the Query Runner tab — bundled like
    // the Swift app bundles shared/benchmarks.json. (Module-relative:
    // android/app → repo root is ../../.)
    sourceSets {
        getByName("main").assets.srcDir("../../shared")
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
    implementation(libs.androidx.compose.material.icons.extended)
    implementation(libs.androidx.compose.material3.adaptive.navigation.suite)
    implementation(libs.androidx.lifecycle.viewmodel.compose)
    implementation(libs.androidx.lifecycle.runtime.compose)
    implementation(libs.androidx.navigation3.runtime)
    implementation(libs.androidx.navigation3.ui)

    // Ditto SDK + official tools viewer (Ditto tab).
    implementation(libs.ditto.kotlin)
    implementation(libs.ditto.tools.android)

    implementation(libs.kotlinx.serialization.json)
    implementation(libs.kotlinx.coroutines.android)

    // Vendored Anvil design system — substituted by the composite build
    // (includeBuild in settings.gradle.kts). Swap for the published
    // coordinates once Anvil ships to Maven.
    implementation(libs.anvil.material3)

    testImplementation(libs.junit)
    testImplementation(libs.kotlinx.coroutines.test)
    testImplementation(libs.kotlinx.serialization.json)
}
