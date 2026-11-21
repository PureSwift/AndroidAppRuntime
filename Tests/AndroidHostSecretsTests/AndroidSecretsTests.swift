import Testing
import DynamicAuthentication
import DynamicSecrets
import RuntimeAuthentication
import RuntimeHost
import RuntimeSecrets
@testable import AndroidHostAuthentication
@testable import AndroidHostSecrets

/// The Kotlin side's secrets, in memory: as the Keystore keeps them, and
/// failing when it's told to.
final class ScriptedSecrets: SecretSystem {

    var stored: [String: [UInt8]] = [:]

    /// The error every call leaves; 0 for none.
    var failing: Int32 = 0

    private var lastFound = false

    func error() -> Int32 { failing }
    func found() -> Bool { lastFound }

    func set(_ key: String, value: [UInt8]) {
        if failing == 0 { stored[key] = value }
    }

    func value(_ key: String) -> [UInt8] {
        lastFound = stored[key] != nil
        return stored[key] ?? []
    }

    func remove(_ key: String) { stored[key] = nil }
    func removeAll() { stored = [:] }
    func keys() -> [String] { Array(stored.keys) }
}

final class SecretAnswer: SecretCallback {

    var events: [String] = []

    func didComplete() { events.append("complete") }
    func didGet(_ value: [UInt8], found: Bool) { events.append(found ? "got \(String(decoding: value, as: UTF8.self))" : "none") }
    func didList(_ keys: [String]) { events.append("keys \(keys)") }
    func didFail(_ error: Int32) { events.append("fail \(error)") }
}

/// The browser, scripted.
final class ScriptedBrowser: AuthenticationSystem {

    var calls: [String] = []

    var canShow = true

    func present(_ url: String, ephemeral: Bool) -> Bool {
        calls.append("present \(url) ephemeral:\(ephemeral)")
        return canShow
    }

    func close() {
        calls.append("close")
    }
}

final class SignInAnswer: WebAuthenticationCallback {

    var events: [String] = []

    func didAuthenticate(_ url: String) { events.append("signed in \(url)") }
    func didFail(_ error: Int32) { events.append("fail \(error)") }
}

/// `HostSecrets` over `KeystoreSecretStore`, and `HostWebAuthentication`
/// over `AndroidWebAuthenticationPresenter`, answering at once.
///
/// Serialized: both are shared.
@Suite(.serialized) final class AndroidSecretsTests {

    let secrets = ScriptedSecrets()

    let browser = ScriptedBrowser()

    let presenter: AndroidWebAuthenticationPresenter

    init() {
        HostSecrets.reset()
        AndroidHostSecrets.configure(KeystoreSecretStore(system: secrets))
        HostSecrets.work = { $0() }
        HostSecrets.deliver = { $0() }
        HostWebAuthentication.reset()
        presenter = AndroidWebAuthenticationPresenter(system: browser)
        AndroidHostAuthentication.configure(presenter, schemes: ["org.example.signin"])
        HostWebAuthentication.deliver = { $0() }
    }

    deinit {
        HostSecrets.reset()
        HostWebAuthentication.reset()
    }

    // MARK: Secrets

    @Test func secretsAreKeptByKey() {
        let answer = SecretAnswer()
        let shared = HostSecrets.shared()
        shared.set("token", value: Array("abc".utf8), accessibility: 1, callback: answer)
        shared.set("b", value: Array("2".utf8), accessibility: 0, callback: answer)
        shared.get("token", callback: answer)
        shared.get("none", callback: answer)
        shared.keys(answer)
        shared.remove("token", callback: answer)
        shared.get("token", callback: answer)
        shared.removeAll(answer)
        shared.keys(answer)
        #expect(answer.events == [
            "complete", "complete", "got abc", "none", #"keys ["b", "token"]"#,
            "complete", "none", "complete", "keys []",
        ])
    }

    @Test func aKeystoreThatCantBeReadIsUnavailable() {
        let answer = SecretAnswer()
        secrets.stored = ["token": [1]]
        secrets.failing = KeychainError.unavailable.rawValue
        HostSecrets.shared().get("token", callback: answer)
        HostSecrets.shared().set("token", value: [2], accessibility: 0, callback: answer)
        #expect(answer.events == ["fail 2", "fail 2"])
        #expect(secrets.stored == ["token": [1]])
    }

    // MARK: Sign-in

    var signIn: HostWebAuthentication { HostWebAuthentication.shared() }

    static let page = "https://id.example.com/authorize?state=1"

    @Test func theRedirectIsTheSignIn() {
        let answer = SignInAnswer()
        let redirect = signIn.redirectURL("org.example.signin", path: "oauth")
        #expect(redirect == "org.example.signin:/oauth")
        signIn.authenticate(Self.page, redirect: redirect, ephemeral: true, callback: answer)
        #expect(browser.calls == ["present \(Self.page) ephemeral:true"])
        presenter.didResignActive()
        // The redirect comes before the app is in front again.
        presenter.redirected("org.example.signin:/oauth?code=x&state=1")
        presenter.didBecomeActive()
        #expect(answer.events == ["signed in org.example.signin:/oauth?code=x&state=1"])
    }

    @Test func comingBackWithNoRedirectIsCancelled() {
        let answer = SignInAnswer()
        signIn.authenticate(Self.page, redirect: "org.example.signin:/oauth", ephemeral: false, callback: answer)
        // Still in front: the page hasn't shown yet.
        presenter.didBecomeActive()
        #expect(answer.events.isEmpty)
        presenter.didResignActive()
        presenter.didBecomeActive()
        #expect(answer.events == ["fail \(WebAuthenticationError.canceledLogin.rawValue)"])
        // A redirect no page waits for is dropped.
        presenter.redirected("org.example.signin:/oauth?code=late")
        #expect(answer.events.count == 1)
    }

    @Test func theGuestCancels() {
        let answer = SignInAnswer()
        signIn.authenticate(Self.page, redirect: "org.example.signin:/oauth", ephemeral: false, callback: answer)
        signIn.cancel()
        #expect(answer.events == ["fail \(WebAuthenticationError.canceledLogin.rawValue)"])
        #expect(browser.calls.last == "close")
    }

    @Test func withoutABrowserItsNotAllowed() {
        browser.canShow = false
        let answer = SignInAnswer()
        signIn.authenticate(Self.page, redirect: "org.example.signin:/oauth", ephemeral: false, callback: answer)
        #expect(answer.events == ["fail \(WebAuthenticationError.notAllowed.rawValue)"])
        // A scheme the manifest doesn't declare.
        browser.canShow = true
        let other = SignInAnswer()
        signIn.authenticate(Self.page, redirect: "com.other:/oauth", ephemeral: false, callback: other)
        #expect(other.events.count == 1)
        #expect(browser.calls.count == 1)
    }
}
