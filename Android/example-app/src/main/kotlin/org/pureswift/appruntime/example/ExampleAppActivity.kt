package org.pureswift.appruntime.example

import android.app.Activity
import android.graphics.Typeface
import android.os.Bundle
import android.util.Log
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
        setContentView(ScrollView(this).apply { addView(text) })
    }

    companion object {
        const val TAG = "ExampleApp"
    }
}
