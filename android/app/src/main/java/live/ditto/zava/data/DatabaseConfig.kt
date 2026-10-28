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

    /// The sync-websocket endpoint to pin via
    /// `transportConfig.connect.websocketUrls`, or null when the SDK's own
    /// derivation is already correct.
    ///
    /// The Ditto SDK derives the *sync websocket* URL from the server URL by
    /// upgrading the scheme to `wss://` — unconditionally. Against a
    /// plaintext Big Peer (`http://host:port`) that sends a TLS ClientHello to
    /// a plain-HTTP port: nginx answers 400 and the SDK loops forever on
    /// "received corrupt message of type InvalidContentType" without ever
    /// reaching `/_ditto/ws`. The websocket client itself accepts `ws://`
    /// (ditto-transport-websocket: "Websocket scheme wasn't 'ws://' or
    /// 'wss://'"), so for a plaintext server we pin the endpoint explicitly.
    ///
    /// The *auth* endpoint keeps using [serverURL] verbatim — reqwest only
    /// speaks http/https, so a `ws://` server URL breaks login outright
    /// ("URL scheme is not allowed"). Hence the split: http for auth, ws for
    /// sync.
    fun plaintextSyncWebSocketURL(): String? {
        val uri = try {
            URI(serverURL)
        } catch (e: Exception) {
            null
        } ?: return null
        val scheme = uri.scheme?.lowercase() ?: return null
        val host = uri.host?.takeIf { it.isNotEmpty() } ?: return null
        // https/wss → the SDK's default wss:// derivation is already right.
        // Leave the Ditto Cloud path untouched.
        if (scheme != "http" && scheme != "ws") return null
        val port = if (uri.port > 0) ":${uri.port}" else ""
        return "ws://$host$port"
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
