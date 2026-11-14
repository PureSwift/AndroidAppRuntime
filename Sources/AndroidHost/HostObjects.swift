import DynamicRuntime
import RuntimeNative

/// A host's own objects, when the guest passes them back.
///
/// An object the host handed out comes back as a proxy for its handle, not
/// as the object itself: `own` finds the object behind it, so contracts can
/// take their own peripherals, tags, requests and credentials as
/// arguments.
public enum HostObjects {

    /// `value` itself if it's a `T`, or the `T` this process exported that a
    /// proxy stands for; nil for anything else, such as an object the guest
    /// implemented.
    public static func own<T: AnyObject>(_ value: AnyObject, as type: T.Type) -> T? {
        if let object = value as? T {
            return object
        }
        guard let proxy = value as? DynamicObject else {
            return nil
        }
        return NativeRuntime.shared.swiftObject(for: proxy) as? T
    }
}
