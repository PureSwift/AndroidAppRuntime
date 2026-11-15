@testable import AndroidPackager
import Crypto
import Foundation

/// A temporary directory, removed when the fixture goes.
final class TemporaryDirectory {

    let url: URL

    init() {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("AndroidPackagerTests-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    func write(_ data: Data, to path: String) {
        let file = url.appendingPathComponent(path)
        try! FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! data.write(to: file)
    }

    func write(_ text: String, to path: String) {
        write(Data(text.utf8), to: path)
    }
}

/// Builds universal bundles like `guest.py bundle`'s.
enum Fixtures {

    static var renderer: [String: Any] { ["Name": "org.pureswift.ui.Renderer", "Version": 1, "Kind": "contract"] }

    static var rendererDelegate: [String: Any] { ["Name": "org.pureswift.ui.RendererDelegate", "Version": 1, "Kind": "callback"] }

    static func info(_ changes: [String: Any] = [:]) -> [String: Any] {
        var info: [String: Any] = [
            "CFBundleIdentifier": "org.example.Weather",
            "CFBundleName": "Weather",
            "CFBundleDisplayName": "Weather",
            "CFBundleExecutable": "Weather",
            "CFBundleShortVersionString": "1.2",
            "CFBundleVersion": "7",
            "RTABIVersion": 1,
            "RTCapabilities": [String](),
            "RTContracts": [renderer, rendererDelegate],
            "RTTargets": ["android-arm64-v8a"],
            "RTPlatforms": ["android": ["MinSDK": 26, "TargetSDK": 35], "ios": ["Minimum": "15.0"]],
        ]
        info.merge(changes) { $1 }
        return info
    }

    /// An `ar` archive with one ELF object for `machine`.
    static func archive(machine: UInt16) -> Data {
        var object = [UInt8](repeating: 0, count: 64)
        object[0...3] = [0x7F, 0x45, 0x4C, 0x46]
        object[18] = UInt8(machine & 0xFF)
        object[19] = UInt8(machine >> 8)
        var header = "app.o/".padding(toLength: 16, withPad: " ", startingAt: 0)
        header += "0".padding(toLength: 12, withPad: " ", startingAt: 0)
        header += "0".padding(toLength: 6, withPad: " ", startingAt: 0)
        header += "0".padding(toLength: 6, withPad: " ", startingAt: 0)
        header += "644".padding(toLength: 8, withPad: " ", startingAt: 0)
        header += String(object.count).padding(toLength: 10, withPad: " ", startingAt: 0)
        header += "`\n"
        return Data("!<arch>\n".utf8) + Data(header.utf8) + Data(object)
    }

    /// A wasm module with only custom sections.
    static func wasm(sections: [String: [UInt8]]) -> Data {
        var bytes: [UInt8] = [0, 0x61, 0x73, 0x6D, 1, 0, 0, 0]
        for (name, contents) in sections.sorted(by: { $0.key < $1.key }) {
            let body = [UInt8(name.utf8.count)] + Array(name.utf8) + contents
            bytes += [0, UInt8(body.count)] + body
        }
        return Data(bytes)
    }

    /// Writes a bundle into `directory`; with `wasm`, an `App.wasm`; with
    /// `sign`, a CodeResources that matches it.
    static func bundle(in directory: TemporaryDirectory, info: [String: Any] = Fixtures.info(),
                       slices: [AndroidABI: UInt16] = [.arm64: 183], icon: Bool = false, wasm: Bool = false,
                       names: [String: String] = [:], sign: Bool = false) -> URL {
        let root = "Weather.app"
        var info = info
        directory.write(try! PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0), to: "\(root)/Info.plist")
        if wasm {
            directory.write(Self.wasm(sections: ["rt.abi": [1, 0, 0, 0], "rt.contracts": [2]]), to: "\(root)/wasm32/App.wasm")
        }
        for (abi, machine) in slices {
            directory.write(archive(machine: machine), to: "\(root)/lib/\(abi.target)/libapp.a")
        }
        if icon {
            directory.write(Data([0x89, 0x50, 0x4E, 0x47]), to: "\(root)/icon.png")
        }
        if !names.isEmpty {
            info["RTDisplayNameKey"] = "app.name"
            info["CFBundleLocalizations"] = Array(names.keys).sorted()
            directory.write(try! PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0), to: "\(root)/Info.plist")
            for (language, name) in names {
                let table = try! PropertyListSerialization.data(fromPropertyList: ["app.name": name], format: .xml, options: 0)
                directory.write(table, to: "\(root)/resources/\(language).lproj/Manifest.strings")
            }
        }
        let url = directory.url.appendingPathComponent(root)
        if sign {
            var files: [String: Data] = [:]
            for path in UniversalBundle.files(under: url) {
                files[path] = Data(SHA256.hash(data: try! Data(contentsOf: url.appendingPathComponent(path))))
            }
            directory.write(try! PropertyListSerialization.data(fromPropertyList: ["files": files], format: .xml, options: 0),
                            to: "\(root)/_CodeSignature/CodeResources")
        }
        return url
    }

    /// A stand-in for AndroidAppRuntime's checkout: the files the Gradle
    /// project copies.
    static func hostPackage(in directory: TemporaryDirectory) -> URL {
        for path in ["Android/build.gradle.kts", "Android/gradle.properties", "Android/gradlew", "Android/gradlew.bat",
                     "Android/gradle/wrapper/gradle-wrapper.jar", "Android/gradle/wrapper/gradle-wrapper.properties"] {
            directory.write("// \(path)\n", to: "host/\(path)")
        }
        return directory.url.appendingPathComponent("host")
    }
}

/// Records commands and answers them, so the packager runs without the tools.
final class FakeRunner: CommandRunning {

    var commands: [[String]] = []

    var environments: [[String: String]] = []

    var answer: ([String]) throws(PackagerError) -> String = { _ in "" }

    func run(_ arguments: [String], directory: URL?, environment: [String: String]) throws(PackagerError) -> String {
        commands.append(arguments)
        environments.append(environment)
        return try answer(arguments)
    }
}
