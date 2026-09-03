package live.ditto.zava.model

/**
 * Settings for the reliable UDP multicast transport (private beta,
 * Android-only). Mirrors `DittoTransportConfig.peerToPeer.multicastBeta`.
 *
 * Validation rules lifted from the pubsec-edgesync sidecar's
 * MulticastTransportAdditionalSettings (proven in the field):
 * the group must be an IPv4 class-D address and the port 1..65535 —
 * port 0 is rejected because the SDK treats it as "pick any port", which
 * silently breaks group rendezvous between peers.
 */
data class MulticastConfig(
    val enabled: Boolean = false,
    val groupAddress: String = DEFAULT_GROUP_ADDRESS,
    val port: Int = DEFAULT_PORT,
    val interfaceName: String? = null,
) {
    companion object {
        const val DEFAULT_GROUP_ADDRESS = "224.1.2.3"
        const val DEFAULT_PORT = 6003

        /** IPv4 class-D dotted-quad: four octets 0..255, first in 224..239. */
        fun isValidGroupAddress(address: String): Boolean {
            val parts = address.split('.')
            if (parts.size != 4) return false
            val octets = parts.map { part ->
                if (part.isEmpty() || part.length > 3 || part.any { !it.isDigit() }) return false
                part.toInt()
            }
            if (octets.any { it > 255 }) return false
            return octets[0] in 224..239
        }

        /** Parses [text] as a UDP port; null unless a whole number in 1..65535. */
        fun parsePort(text: String): Int? =
            text.toIntOrNull()?.takeIf { it in 1..65535 }
    }
}
