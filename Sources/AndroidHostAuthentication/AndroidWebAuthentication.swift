import AndroidHost
import DynamicAuthentication
import DynamicRuntime
import RuntimeAuthentication
import RuntimeHost

/// What `AndroidWebAuthenticationPresenter` asks Android, through the
/// Kotlin `org.pureswift.appruntime.contracts.AuthenticationSystem`
/// (`AndroidHostApp` binds it). Main thread only.
public protocol AuthenticationSystem: AnyObject {

    /// Shows the page in the system's browser; false when it can't.
    func present(_ url: String, ephemeral: Bool) -> Bool

    /// Brings the app back over the page.
    func close()
}

/// Sign-in on Android (`Plan.md` §6.12): the provider's page in a Custom
/// Tab, and its redirect caught by an activity the packager declares for
/// each of the app's schemes, under AppRuntime's `HostWebAuthentication`.
///
/// The page is closed without a sign-in when the app comes back to the
/// front with no redirect: the user pressed Back, or closed the tab.
/// Main thread only.
public final class AndroidWebAuthenticationPresenter: WebAuthenticationPresenter {

    let system: any AuthenticationSystem

    /// The page showing, and whether the app has left the front for it.
    private var showing: (completion: (Result<String, WebAuthenticationError>) -> Void, left: Bool)?

    public init(system: any AuthenticationSystem) {
        self.system = system
    }

    public func present(_ url: String, redirect: String, ephemeral: Bool, completion: @escaping (Result<String, WebAuthenticationError>) -> Void) {
        guard system.present(url, ephemeral: ephemeral) else {
            completion(.failure(.notAllowed))
            return
        }
        showing = (completion, false)
    }

    public func cancel() {
        guard showing != nil else { return }
        showing = nil
        system.close()
    }

    // MARK: From Android

    /// The browser redirected to one of the app's schemes.
    public func redirected(_ url: String) {
        guard let (completion, _) = showing else { return }
        showing = nil
        completion(.success(url))
    }

    /// The app left the front: the page is over it.
    public func didResignActive() {
        showing?.left = true
    }

    /// The app is in front again. With no redirect, the user left the page.
    public func didBecomeActive() {
        guard let (completion, left) = showing, left else { return }
        showing = nil
        completion(.failure(.canceledLogin))
    }
}

/// The sign-in module (`Plan.md` §6.12).
public enum AndroidHostAuthentication: HostModule {

    nonisolated(unsafe) public private(set) static var presenter: AndroidWebAuthenticationPresenter?

    /// Points `HostWebAuthentication` at the browser; `schemes` are the
    /// manifest's `RTAuthenticationSchemes`. Main thread.
    public static func configure(_ presenter: AndroidWebAuthenticationPresenter, schemes: [String]) {
        Self.presenter = presenter
        HostWebAuthentication.presenter = presenter
        HostWebAuthentication.declaredSchemes = Set(schemes)
        HostWebAuthentication.deliver = { job in MainLooper.shared.post(job) }
    }

    public static var contracts: [ContractDescriptor] {
        HostWebAuthenticationModule.contracts
    }

    public static func register(in registrar: some ContractRegistrar) {
        HostWebAuthenticationModule.register(in: registrar)
    }

    public static func permissionProviders() -> [Capability: any PermissionProvider] {
        HostWebAuthenticationModule.permissionProviders()
    }
}
