import Testing
import DynamicDefaults
import RuntimeHost
@testable import AndroidHostDefaults

/// `SharedPreferences` in memory: strings, plus whatever else another part
/// of the app might have put in the file.
final class FakePreferences: PreferencesSystem {

    var values: [String: String] = [:]

    /// Keys holding something that isn't a string, such as an `Int`.
    var others: Set<String> = []

    var edits = 0

    func contains(_ key: String) -> Bool {
        values[key] != nil || others.contains(key)
    }

    func string(_ key: String) -> String {
        values[key] ?? ""
    }

    func set(_ key: String, value: String, removing: String) {
        values[key] = value
        values[removing] = nil
        edits += 1
    }

    func remove(_ keys: [String]) {
        for key in keys {
            values[key] = nil
            others.remove(key)
        }
        edits += 1
    }

    func keys() -> [String] {
        Array(values.keys) + Array(others)
    }
}

/// Serialized: `HostDefaults.storage` is shared.
@Suite(.serialized) struct AndroidDefaultsTests {

    let preferences = FakePreferences()

    let storage: AndroidDefaultsStorage

    init() {
        let preferences = self.preferences
        storage = AndroidDefaultsStorage(maximumValueSize: 16) { preferences }
    }

    @Test func eachKindHasItsMark() {
        #expect(storage.setString("true", key: "soundOn"))
        #expect(storage.setData([0, 1, 2, 255], key: "blob"))
        #expect(preferences.values == ["s:soundOn": "true", "d:blob": "AAEC/w=="])
        #expect(storage.string("soundOn") == "true")
        #expect(storage.data("blob") == [0, 1, 2, 255])
    }

    @Test func aKeyHoldsOneKind() {
        #expect(storage.setString("text", key: "k"))
        #expect(storage.setData([7], key: "k"))
        #expect(storage.string("k") == nil)
        #expect(storage.data("k") == [7])
        #expect(preferences.values == ["d:k": "Bw=="])
        #expect(storage.setString("again", key: "k"))
        #expect(storage.data("k") == nil)
        #expect(preferences.values == ["s:k": "again"])
    }

    @Test func emptyValuesAreValues() {
        #expect(storage.string("e") == nil)
        #expect(storage.setString("", key: "e"))
        #expect(storage.string("e") == "")
        #expect(storage.setData([], key: "d"))
        #expect(storage.data("d") == [])
    }

    @Test func removingTakesBothKinds() {
        _ = storage.setString("x", key: "a")
        storage.remove("a")
        storage.remove("never set")
        #expect(storage.string("a") == nil)
        #expect(preferences.values.isEmpty)
    }

    @Test func valuesOverTheLimitAreRefused() {
        #expect(storage.setString("sixteen bytes ok", key: "fits"))
        #expect(!storage.setString("seventeen bytes!!", key: "fits"))
        #expect(storage.string("fits") == "sixteen bytes ok", "the old value stays")
        #expect(storage.setData([UInt8](repeating: 1, count: 16), key: "bytes"))
        #expect(!storage.setData([UInt8](repeating: 1, count: 17), key: "bytes"))
    }

    @Test func keysAreTheAppsOnly() {
        _ = storage.setString("1", key: "launches")
        _ = storage.setData([1], key: "blob")
        _ = storage.setString("colon", key: "s:tricky")
        preferences.values["unmarked"] = "from elsewhere"
        preferences.others.insert("s:number")
        #expect(Set(storage.keys()) == ["launches", "blob", "s:tricky", "number"])
        // A key of another type reads as no string.
        #expect(storage.string("number") == "")
    }

    @Test func bytesThatArentBase64ReadAsMissing() {
        preferences.values["d:bad"] = "not base64!"
        #expect(storage.data("bad") == nil)
    }

    @Test func theSystemIsMadeOnFirstUse() {
        var made = 0
        let preferences = self.preferences
        let storage = AndroidDefaultsStorage { made += 1; return preferences }
        #expect(made == 0)
        _ = storage.string("a")
        _ = storage.keys()
        #expect(made == 1)
    }

    @Test func withoutASystemNothingIsKept() {
        let storage = AndroidDefaultsStorage { nil }
        #expect(!storage.setString("x", key: "a"))
        #expect(storage.string("a") == nil)
        #expect(storage.keys().isEmpty)
    }

    @Test func throughHostDefaults() {
        HostDefaults.storage = storage
        defer { HostDefaults.storage = nil }
        let defaults = HostDefaults.standard()
        #expect(!defaults.setString("x", key: ""), "an empty key is refused")
        #expect(defaults.setString("b", key: "b"))
        #expect(defaults.setString("é", key: "é"))
        #expect(defaults.setData([1], key: "B"))
        #expect(defaults.keys() == ["B", "b", "é"])
    }

    @Test func base64RoundTrips() {
        for count in 0..<40 {
            let bytes = (0..<count).map { UInt8(($0 * 37 + count) & 0xFF) }
            #expect(Base64.decode(Base64.encode(bytes)) == bytes, "\(count) bytes")
        }
        #expect(Base64.encode(Array("Man".utf8)) == "TWFu")
        #expect(Base64.encode(Array("Ma".utf8)) == "TWE=")
        #expect(Base64.encode(Array("M".utf8)) == "TQ==")
        #expect(Base64.decode("TQ==") == Array("M".utf8))
        for bad in ["T", "TQ=", "TQ=A", "T===", "TQ==TQ==", "TQ@=", "TWFu\n"] {
            #expect(Base64.decode(bad) == nil, "\(bad)")
        }
    }
}
