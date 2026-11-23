import AndroidHost
import AndroidHostBackgroundTasks
import SwiftJava

/// The Kotlin `BackgroundTaskSystem` (`:appruntime-contracts`): the app's
/// tasks as `WorkManager` work.
@JavaClass("org.pureswift.appruntime.contracts.BackgroundTaskSystem")
open class JavaBackgroundTaskSystem: JavaObject {

    @JavaMethod
    @_nonoverride public convenience init(environment: JNIEnvironment? = nil)

    @JavaMethod open func restricted() -> Bool
    @JavaMethod open func submit(_ identifier: String, _ kind: Int32, _ earliest: Double, _ interval: Double, _ requirements: Int32) -> Int32
    @JavaMethod open func cancel(_ identifier: String)
    @JavaMethod open func cancelAll()
    @JavaMethod open func pending(_ request: Int32)
    @JavaMethod open func finished(_ token: Int32, _ success: Bool)
}

extension JavaBackgroundTaskSystem: BackgroundTaskSystem {

    public func submit(_ identifier: String, kind: Int32, earliest: Double, interval: Double, requirements: Int32) -> Int32 {
        submit(identifier, kind, earliest, interval, requirements)
    }

    public func finished(_ token: Int32, success: Bool) {
        finished(token, success)
    }
}

/// What `WorkManager` does with the app's tasks, on the main thread.
@JavaClass("org.pureswift.appruntime.contracts.BackgroundTaskNatives")
open class BackgroundTaskNatives: JavaObject {}

@JavaImplementation("org.pureswift.appruntime.contracts.BackgroundTaskNatives")
extension BackgroundTaskNatives {

    @JavaMethod
    public func run(_ identifier: String, _ token: Int32) -> Int32 {
        BackgroundTaskHub.shared.run(identifier, token: token)
    }

    @JavaMethod
    public func expire(_ run: Int32) {
        BackgroundTaskHub.shared.expire(run)
    }

    @JavaMethod
    public func listed(_ request: Int32, _ identifiers: String) {
        BackgroundTaskHub.shared.listed(request, identifiers: identifiers)
    }
}

/// `RTBackgroundTasks` from the bundle's `Info.plist`: the tasks the
/// manifest names.
struct BackgroundTaskEntries: Decodable {

    var entries: [[String: String]]

    enum CodingKeys: String, CodingKey {
        case entries = "RTBackgroundTasks"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        entries = try container.decodeIfPresent([[String: String]].self, forKey: .entries) ?? []
    }
}
