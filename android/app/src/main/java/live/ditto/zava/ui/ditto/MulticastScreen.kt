package live.ditto.zava.ui.ditto

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.ditto.kotlin.DittoConnectionType
import live.ditto.zava.model.MulticastConfig
import live.ditto.zava.state.AppState
import live.ditto.zava.ui.components.DittoBadge
import live.ditto.zava.ui.components.DittoBadgeStatus
import live.ditto.zava.ui.components.DittoCard
import live.ditto.anvil.material3.DittoColors

/// Multicast (private beta) settings — the demo toggle for the reliable UDP
/// multicast transport. Pattern proven in the pubsec-edgesync sidecar:
/// switch applies immediately; group/port/interface edits apply via an
/// explicit Apply with field validation (port 0 is rejected — the SDK reads
/// it as "pick any port", silently breaking rendezvous between peers).
@Composable
fun MulticastScreen(appState: AppState, modifier: Modifier = Modifier) {
    val colors = DittoColors.current
    val config by appState.multicastConfig.collectAsStateWithLifecycle()
    val ditto by appState.ditto.collectAsStateWithLifecycle()

    // "Enabled" (the switch) and "connected" are different things: the live
    // truth is the presence graph — multicast sessions appear as connections
    // with connectionType == Multicast (same data the tools Peers view shows).
    val multicastConnections by produceState(initialValue = 0, ditto) {
        val instance = ditto ?: return@produceState
        instance.presence.observe().collect { graph ->
            value = graph.localPeer.connections.count { it.connectionType == DittoConnectionType.Multicast }
        }
    }

    Column(
        modifier = modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        DittoCard {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text("Multicast (beta)", style = MaterialTheme.typography.titleMedium, color = colors.foregroundNormal)
                    Text(
                        "Reliable UDP multicast over the local Wi-Fi network",
                        style = MaterialTheme.typography.bodySmall,
                        color = colors.foregroundSubtle,
                    )
                }
                Switch(
                    checked = config.enabled,
                    onCheckedChange = { enabled -> appState.setMulticastConfig(config.copy(enabled = enabled)) },
                    modifier = Modifier.padding(start = 16.dp), // M3 list-item spacing: label → control
                )
            }
            Spacer(Modifier.height(8.dp))
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                DittoBadge(if (config.enabled) "enabled" else "disabled", if (config.enabled) DittoBadgeStatus.Success else DittoBadgeStatus.Info)
                if (config.enabled) {
                    DittoBadge(
                        "${config.groupAddress}:${config.port}" + (config.interfaceName?.let { " · $it" } ?: ""),
                        DittoBadgeStatus.Promo,
                    )
                    DittoBadge(
                        "$multicastConnections connection${if (multicastConnections == 1) "" else "s"}",
                        if (multicastConnections > 0) DittoBadgeStatus.Success else DittoBadgeStatus.Warning,
                    )
                }
            }
        }

        DittoCard {
            Text("Group settings", style = MaterialTheme.typography.titleSmall, color = colors.foregroundNormal)
            Spacer(Modifier.height(8.dp))
            MulticastFields(config = config, onApply = { appState.setMulticastConfig(it) })
        }

        Text(
            "Private beta, Android only — enable in coordination with Ditto support. " +
                "All peers must share the same Wi-Fi segment and group:port. " +
                "Demo: on two devices, enable multicast (and optionally turn the other " +
                "transports off), then watch the Ditto tools Peers view — multicast " +
                "connections show up as a Multicast connection type, and data syncs " +
                "device-to-device over the LAN.",
            style = MaterialTheme.typography.bodySmall,
            color = colors.foregroundSubtle,
        )
    }
}

@Composable
private fun MulticastFields(config: MulticastConfig, onApply: (MulticastConfig) -> Unit) {
    val colors = DittoColors.current
    val appliedGroup = config.groupAddress
    val appliedPort = config.port.toString()
    val appliedInterface = config.interfaceName ?: ""

    var group by rememberSaveable(appliedGroup) { mutableStateOf(appliedGroup) }
    var port by rememberSaveable(appliedPort) { mutableStateOf(appliedPort) }
    var interfaceName by rememberSaveable(appliedInterface) { mutableStateOf(appliedInterface) }

    val groupValid = MulticastConfig.isValidGroupAddress(group.trim())
    val portValid = MulticastConfig.parsePort(port.trim()) != null
    val dirty = group.trim() != appliedGroup ||
        port.trim() != appliedPort ||
        interfaceName.trim() != appliedInterface

    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        OutlinedTextField(
            value = group,
            onValueChange = { group = it },
            label = { Text("Group address") },
            placeholder = { Text("e.g. ${MulticastConfig.DEFAULT_GROUP_ADDRESS}") },
            modifier = Modifier.fillMaxWidth(),
            singleLine = true,
            isError = !groupValid,
        )
        if (!groupValid) {
            Text(
                "Must be an IPv4 multicast address (224.0.0.0 to 239.255.255.255)",
                style = MaterialTheme.typography.bodySmall,
                color = colors.fillCritical,
            )
        }
        OutlinedTextField(
            value = port,
            onValueChange = { port = it },
            label = { Text("Port") },
            placeholder = { Text("e.g. ${MulticastConfig.DEFAULT_PORT}") },
            modifier = Modifier.fillMaxWidth(),
            singleLine = true,
            isError = !portValid,
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
        )
        if (!portValid) {
            Text(
                "Port must be 1 to 65535",
                style = MaterialTheme.typography.bodySmall,
                color = colors.fillCritical,
            )
        }
        OutlinedTextField(
            value = interfaceName,
            onValueChange = { interfaceName = it },
            label = { Text("Network interface") },
            placeholder = { Text("e.g. wlan0 (optional)") },
            modifier = Modifier.fillMaxWidth(),
            singleLine = true,
        )
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            TextButton(
                onClick = {
                    val parsedPort = MulticastConfig.parsePort(port.trim())
                    if (groupValid && parsedPort != null) {
                        onApply(
                            config.copy(
                                groupAddress = group.trim(),
                                port = parsedPort,
                                interfaceName = interfaceName.trim().ifEmpty { null },
                            ),
                        )
                    }
                },
                enabled = dirty && groupValid && portValid,
            ) {
                Text("Apply")
            }
            TextButton(
                onClick = {
                    group = appliedGroup
                    port = appliedPort
                    interfaceName = appliedInterface
                },
                enabled = dirty,
            ) {
                Text("Reset")
            }
        }
    }
}
