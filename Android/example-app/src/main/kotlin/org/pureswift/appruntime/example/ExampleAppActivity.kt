package org.pureswift.appruntime.example

import android.app.Activity
import android.graphics.Typeface
import android.os.Build
import android.os.Bundle
import android.util.Log
import android.view.WindowInsets
import android.widget.ScrollView
import android.widget.TextView

/**
 * Runs ExampleApp on the main thread, as a host would call `rt_main`, and
 * shows its report. Each line also goes to logcat, under `ExampleApp`.
 */
class ExampleAppActivity : Activity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val report = NativeHost().runExampleApp()
        report.lines().forEach { Log.i(TAG, it) }
        val text = TextView(this).apply {
            typeface = Typeface.MONOSPACE
            setPadding(32, 32, 32, 32)
            setText(report)
        }
        val scroll = ScrollView(this).apply { addView(text) }
        // Apps targeting API 35 draw edge to edge on Android 15 and later:
        // keep the report clear of the status and navigation bars.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            scroll.setOnApplyWindowInsetsListener { view, insets ->
                val bars = insets.getInsets(WindowInsets.Type.systemBars() or WindowInsets.Type.displayCutout())
                view.setPadding(bars.left, bars.top, bars.right, bars.bottom)
                insets
            }
        }
        setContentView(scroll)
    }

    companion object {
        const val TAG = "ExampleApp"
    }
}
