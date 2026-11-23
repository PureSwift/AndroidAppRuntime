package org.pureswift.appruntime.ui

import androidx.compose.material3.LocalContentColor
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.TextUnitType
import com.pureswift.swiftui.LocalInheritedColor
import com.pureswift.swiftui.LocalInheritedFontSize
import com.pureswift.swiftui.LocalInheritedFontWeight
import com.pureswift.swiftui.LocalTint

/**
 * The `font`, `foregroundColor` and `tint` a view the shell draws itself
 * inherits, as composeui keeps them for its own text: the size in sp, the
 * weight as bold or not, and the colors as ARGB. A `TextEditor`'s
 * `EditText` takes them.
 */
data class InheritedTextStyle(val size: Float, val bold: Boolean, val color: Int, val tint: Int?) {

    companion object {

        /** SwiftUI's `body`, without a font. */
        const val BODY = 17f

        @Composable
        fun current(): InheritedTextStyle {
            val size = LocalInheritedFontSize.current
            val weight = LocalInheritedFontWeight.current
            val color = LocalInheritedColor.current
            return InheritedTextStyle(
                size = if (size.type == TextUnitType.Sp) size.value else BODY,
                bold = weight != null && weight >= FontWeight.SemiBold,
                color = (if (color == Color.Unspecified) LocalContentColor.current else color).toArgb(),
                tint = LocalTint.current?.toArgb(),
            )
        }
    }
}
