package org.pureswift.appruntime.example

/** The Swift side, in `libExampleAppHost.so` (`Sources/ExampleAppHost`). */
class NativeHost {

    /** Runs ExampleApp once per process, and returns its report: the verdict first, then the lines it recorded. */
    external fun runExampleApp(): String

    companion object {
        init {
            System.loadLibrary("ExampleAppHost")
        }
    }
}
