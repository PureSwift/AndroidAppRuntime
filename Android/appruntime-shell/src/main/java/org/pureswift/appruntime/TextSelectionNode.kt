package org.pureswift.appruntime

import androidx.compose.foundation.text.selection.DisableSelection
import androidx.compose.foundation.text.selection.SelectionContainer
import com.pureswift.swiftui.ComposableRegistry
import org.pureswift.appruntime.ui.IRAdapter

/**
 * `textSelection` (Documentation/Plan.md §6.11): the node it's on, in a
 * [SelectionContainer], so its text can be selected and copied with the
 * platform's menu; or in [DisableSelection], when it's turned off inside.
 */
object TextSelectionNode {

    fun register() {
        ComposableRegistry.register(IRAdapter.TEXT_SELECTION) { _, children ->
            SelectionContainer { children() }
        }
        ComposableRegistry.register(IRAdapter.NO_TEXT_SELECTION) { _, children ->
            DisableSelection { children() }
        }
    }
}
