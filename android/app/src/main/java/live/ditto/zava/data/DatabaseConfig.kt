package live.ditto.zava.data

import com.ditto.kotlin.DittoConfig
import live.ditto.zava.BuildConfig
import live.ditto.zava.model.AppError
import java.net.URI

/// The three SDK keys, read from the root .env via BuildConfig (gradle
/// buildConfigField at app/build.gradle.kts). Missing config is a UI state,
/// never a crash.
data class DatabaseConfig(
    val databaseID: String,
    val developmentToken: String,
    val serverURL: String,
) {
    companion object {
        /** Null when any of the three keys is empty. */
        fun load(): DatabaseConfig? {
            val config = DatabaseConfig(
                databaseID = BuildConfig.DITTO_DATABASE_ID,
                developmentToken = BuildConfig.DITTO_DEVELOPMENT_TOKEN,
                serverURL = BuildConfig.DITTO_SERVER_URL,
            )
            if (config.databaseID.isEmpty() || config.developmentToken.isEmpty() || config.serverURL.isEmpty()) {
                return null
            }
            return config
        }
    }

    fun makeDittoConfig(persistenceDirectory: String): DittoConfig {
        val uri = try {
            URI(serverURL)
        } catch (e: Exception) {
            null
        }
        val scheme = uri?.scheme?.lowercase()
        if (scheme !in listOf("https", "http", "wss", "ws") || uri?.host.isNullOrEmpty()) {
            throw AppError(
                "DITTO_SERVER_URL must be an absolute URL like " +
                    "https://<cluster>.cloud.dittolive.app (got: '$serverURL')"
            )
        }
        return DittoConfig(
            databaseId = databaseID,
            connect = DittoConfig.Connect.Server(url = serverURL),
            persistenceDirectory = persistenceDirectory,
        )
    }
}
