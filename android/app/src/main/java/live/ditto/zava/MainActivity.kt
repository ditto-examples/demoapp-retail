package live.ditto.zava

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import live.ditto.anvil.material3.DittoColors
import live.ditto.anvil.material3.DittoTheme

/**
 * M0 spike 1: proves the vendored Anvil design system builds and theming works
 * when consumed as a composite build (`includeBuild`) under this app's modern
 * toolchain (AGP 9 / Kotlin 2.4 / Gradle 9.7), per PLAN.md §5.
 *
 * The real Zava Retail app grows from this skeleton in M2.
 */
class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent {
            DittoTheme {
                SpikeHome()
            }
        }
    }
}

@Composable
private fun SpikeHome() {
    Scaffold { padding ->
        Column(
            modifier = Modifier
                .padding(padding)
                .fillMaxSize()
                .padding(24.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            Text("Zava Retail", style = MaterialTheme.typography.displaySmall)
            Text(
                "Anvil composite-build spike (M0)",
                style = MaterialTheme.typography.bodyLarge,
                color = DittoColors.current.foregroundSubtle,
            )

            // Anvil brand fill: black content on citrus.
            Surface(
                color = DittoColors.current.fillBrandPrimary,
                contentColor = DittoColors.current.foregroundOnBrandPrimary,
                shape = MaterialTheme.shapes.medium,
            ) {
                Text(
                    "fillBrandPrimary",
                    modifier = Modifier.padding(horizontal = 16.dp, vertical = 10.dp),
                    style = MaterialTheme.typography.titleMedium,
                )
            }

            // Anvil semantic status color (no M3 role — extended colors).
            Surface(
                color = DittoColors.current.fillSuccessSecondary,
                contentColor = DittoColors.current.fillSuccess,
                shape = MaterialTheme.shapes.medium,
            ) {
                Text(
                    "fillSuccess / fillSuccessSecondary",
                    modifier = Modifier.padding(horizontal = 16.dp, vertical = 10.dp),
                    style = MaterialTheme.typography.titleMedium,
                )
            }

            Button(onClick = {}, modifier = Modifier.fillMaxWidth()) {
                Text("Material 3 button on Anvil theme")
            }
        }
    }
}
