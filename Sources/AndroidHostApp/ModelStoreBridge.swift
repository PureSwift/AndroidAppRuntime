import AndroidHost
import AndroidHostModelStore

enum ModelStoreBridge {

    /// Points the model store at the app's databases directory, before the
    /// app starts. Answers go to the main looper.
    static func configure() {
        AndroidHostModelStore.configure(directory: JavaFileSystem().databaseDirectory()) { job in
            MainLooper.shared.post(job)
        }
    }
}
