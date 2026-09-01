package live.ditto.zava.ui.components

import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Surface
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import live.ditto.anvil.material3.DittoColors

/// Ghost placeholders shown while a screen's first emission for the current
/// store is in flight (never render another store's data).

@Composable
fun SkeletonBox(height: Dp = 18.dp, cornerRadius: Dp = 6.dp, modifier: Modifier = Modifier) {
    val transition = rememberInfiniteTransition(label = "skeleton")
    val alpha by transition.animateFloat(
        initialValue = 1f,
        targetValue = 0.45f,
        animationSpec = infiniteRepeatable(tween(800), RepeatMode.Reverse),
        label = "skeletonAlpha",
    )
    Surface(
        modifier = modifier.height(height).alpha(alpha),
        color = DittoColors.current.surfaceSecondary,
        shape = RoundedCornerShape(cornerRadius),
    ) {}
}

@Composable
fun SkeletonRows(count: Int = 6, modifier: Modifier = Modifier) {
    Column(modifier = modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
        repeat(count) {
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) {
                SkeletonBox(16.dp, modifier = Modifier.weight(1f))
                SkeletonBox(16.dp, modifier = Modifier.width(80.dp))
            }
        }
    }
}

/// Matches a dashboard KPI grid cell.
@Composable
fun SkeletonCard(modifier: Modifier = Modifier) {
    DittoCard(modifier = modifier) {
        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            SkeletonBox(12.dp, modifier = Modifier.width(90.dp))
            SkeletonBox(28.dp, modifier = Modifier.fillMaxWidth(0.6f))
        }
    }
}
