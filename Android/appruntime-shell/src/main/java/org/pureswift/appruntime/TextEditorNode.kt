package org.pureswift.appruntime

import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.ui.Modifier
import androidx.compose.ui.viewinterop.AndroidView
import com.pureswift.swiftui.ComposableRegistry
import org.pureswift.appruntime.contracts.TextEditorView
import org.pureswift.appruntime.ui.IRAdapter
import org.pureswift.appruntime.ui.InheritedTextStyle

/**
 * A `TextEditor` node (Documentation/Plan.md §6.16): the text it names, in
 * a [TextEditorView] that takes the space SwiftUI offers, with the font,
 * colors and keyboard the node has or inherits, and its focus. When the
 * node goes, the text leaves the view and keeps its content, selection and
 * history.
 */
object TextEditorNode {

    fun register() {
        ComposableRegistry.register(IRAdapter.TEXT_EDITOR) { props, _ ->
            val text = props.int("buffer") ?: return@register
            val style = InheritedTextStyle.current()
            val configuration = TextEditorView.Configuration(
                editable = props.bool("editable") != false,
                wraps = props.bool("wraps") != false,
                autocorrects = props.bool("autocorrects") != false,
                capitalization = props.string("capitalization"),
                size = style.size,
                bold = style.bold,
                design = props.string("design"),
                color = style.color,
                tint = style.tint,
            )
            val focused = props.bool("focused")
            val onFocus = props.boolAction("onFocus")
            AndroidView(
                factory = { TextEditorView(it) },
                modifier = Modifier.fillMaxSize(),
                update = { view ->
                    view.text = text
                    view.configure(configuration)
                    view.onFocus = onFocus
                    view.focus(focused)
                },
                onRelease = { it.text = 0 },
            )
        }
    }
}
