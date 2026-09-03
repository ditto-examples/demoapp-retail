package live.ditto.zava

import live.ditto.zava.model.MulticastConfig
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/// Multicast settings validation (sidecar-proven rules): the group must be
/// IPv4 class-D and the port 1..65535 — 0 is rejected because the SDK reads
/// it as "pick any port", silently breaking rendezvous between peers.
class MulticastConfigTests {

    @Test
    fun validGroupAddresses() {
        assertTrue(MulticastConfig.isValidGroupAddress("224.1.2.3"))
        assertTrue(MulticastConfig.isValidGroupAddress("224.0.0.0"))
        assertTrue(MulticastConfig.isValidGroupAddress("239.255.255.255"))
        assertTrue(MulticastConfig.isValidGroupAddress("239.0.0.1"))
    }

    @Test
    fun invalidGroupAddresses() {
        // Not class D
        assertFalse(MulticastConfig.isValidGroupAddress("223.255.255.255"))
        assertFalse(MulticastConfig.isValidGroupAddress("240.0.0.1"))
        assertFalse(MulticastConfig.isValidGroupAddress("192.168.1.1"))
        // Malformed
        assertFalse(MulticastConfig.isValidGroupAddress(""))
        assertFalse(MulticastConfig.isValidGroupAddress("224.1.2"))
        assertFalse(MulticastConfig.isValidGroupAddress("224.1.2.3.4"))
        assertFalse(MulticastConfig.isValidGroupAddress("224.1.2.256"))
        assertFalse(MulticastConfig.isValidGroupAddress("224.1.2.-1"))
        assertFalse(MulticastConfig.isValidGroupAddress("224.1.2.x"))
        assertFalse(MulticastConfig.isValidGroupAddress("224.1.2.03a"))
        assertFalse(MulticastConfig.isValidGroupAddress("224..2.3"))
    }

    @Test
    fun portParsing() {
        assertEquals(6003, MulticastConfig.parsePort("6003"))
        assertEquals(1, MulticastConfig.parsePort("1"))
        assertEquals(65535, MulticastConfig.parsePort("65535"))
        assertNull(MulticastConfig.parsePort("0")) // "any port" silently breaks rendezvous
        assertNull(MulticastConfig.parsePort("65536"))
        assertNull(MulticastConfig.parsePort("-1"))
        assertNull(MulticastConfig.parsePort("abc"))
        assertNull(MulticastConfig.parsePort(""))
        assertNull(MulticastConfig.parsePort("6003.5"))
    }

    @Test
    fun defaultsMatchSdk() {
        val config = MulticastConfig()
        assertFalse(config.enabled)
        assertEquals("224.1.2.3", config.groupAddress)
        assertEquals(6003, config.port)
        assertNull(config.interfaceName)
    }
}
