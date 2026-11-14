package org.pureswift.appruntime.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyHorizontalGrid
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.pureswift.swiftui.ComposableRegistry
import com.pureswift.swiftui.RenderChild
import com.pureswift.swiftui.SwiftBridge

/**
 * A lazy `LazyVGrid` or `LazyHGrid`: composeui's grids render their children
 * eagerly, so a lazy one is this view, registered with composeui's
 * `ComposableRegistry`. It fetches the rows Compose shows, one
 * `itemNode` call each, and fetches them again when the revision changes.
 */
object LazyGridView {

    const val NAME = "org.pureswift.appruntime.LazyGrid"

    fun register() {
        ComposableRegistry.register(NAME) { props, _ ->
            Grid(
                provider = props.string("itemProvider")?.toLongOrNull() ?: return@register,
                version = props.string("contentVersion")?.toLongOrNull() ?: 0,
                count = props.int("count") ?: 0,
                vertical = props.bool("vertical") ?: true,
                spacing = props.double("spacing") ?: 8.0,
                adaptiveMin = props.double("adaptiveMin"),
                tracks = props.int("trackCount") ?: 1,
            )
        }
    }

    @Composable
    private fun Grid(provider: Long, version: Long, count: Int, vertical: Boolean, spacing: Double, adaptiveMin: Double?, tracks: Int) {
        val cells = adaptiveMin?.let { GridCells.Adaptive(it.dp) } ?: GridCells.Fixed(maxOf(tracks, 1))
        val arrangement = Arrangement.spacedBy(spacing.dp)
        if (vertical) {
            LazyVerticalGrid(columns = cells, verticalArrangement = arrangement, horizontalArrangement = arrangement, modifier = Modifier) {
                items(count) { index -> Item(provider, version, index) }
            }
        } else {
            LazyHorizontalGrid(rows = cells, verticalArrangement = arrangement, horizontalArrangement = arrangement, modifier = Modifier) {
                items(count) { index -> Item(provider, version, index) }
            }
        }
    }

    @Composable
    private fun Item(provider: Long, version: Long, index: Int) {
        val item = remember(provider, version, index) { SwiftBridge.sink.itemNode(provider, index) }
        item?.let { RenderChild(it) }
    }
}
