import AndroidHostModules
import Foundation
import RuntimeABI
import RuntimeHost

/// What this host implements: the built-ins and its modules' contracts.
public enum HostContracts {

    /// The modules `libapp.so` registers.
    nonisolated(unsafe) public static let modules: [any HostModule.Type] = AndroidHostModules.all

    public static var provided: [String: ContractDescriptor] {
        AppCompatibility.providedContracts(modules)
    }

    /// Capabilities some contract here serves. The others still get their
    /// permissions, so `Permissions` can ask for them.
    public static let capabilities: Set<Capability> = [.audio, .bluetooth, .contacts, .graphics, .location, .motion, .nfc, .notifications, .secrets, .userFiles]

    /// Capabilities with nothing to serve: no contract needs them.
    public static let unserved: Set<Capability> = [.network]
}

/// The packager's checks (`Plan.md` §8): the app's keys, its contracts, its
/// slices, and the bundle's integrity.
public struct Validator {

    public var bundle: UniversalBundle

    public var abis: [AndroidABI]

    /// Missing contracts warn instead of failing; the guest sees them as
    /// absent.
    public var allowMissingContracts = false

    public var provided: [String: ContractDescriptor] = HostContracts.provided

    /// `--engine`; nil chooses per ABI (`UniversalBundle.engine`).
    public var engine: Engine?

    public init(bundle: UniversalBundle, abis: [AndroidABI]) {
        self.bundle = bundle
        self.abis = abis
    }

    public func validate() -> [Diagnostic] {
        var diagnostics: [Diagnostic] = []
        let info = bundle.info

        if !Self.isApplicationID(info.identifier) {
            diagnostics.append(.error("CFBundleIdentifier \"\(info.identifier)\" can't be an Android application ID: it needs two or more parts of letters, digits and _, each starting with a letter"))
        }
        if Self.versionCode(info.build) == nil {
            diagnostics.append(.error("CFBundleVersion \"\(info.build)\" isn't a build number from 1 to 2100000000, which Android's versionCode needs"))
        }
        if info.abiVersion > runtimeABIVersion {
            diagnostics.append(.error("the app needs rt ABI \(info.abiVersion); this host provides \(runtimeABIVersion)"))
        }

        // The manifest's platforms.
        if let platforms = bundle.platforms {
            if !platforms.contains("android") {
                diagnostics.append(.error("the app's manifest doesn't list the android platform"))
            }
        } else {
            diagnostics.append(.warning("the bundle has no manifest platforms; using minSdk \(AndroidABI.minimumAPI) and targetSdk \(Self.defaultTargetSDK)"))
        }
        if let minSDK = bundle.minSDK, minSDK < AndroidABI.minimumAPI {
            diagnostics.append(.warning("minSDK \(minSDK) is raised to \(AndroidABI.minimumAPI), the Swift SDK for Android's"))
        }

        for contract in info.contracts {
            guard let descriptor = provided[contract.name] else {
                let message = "\(contract.name) isn't implemented on Android"
                diagnostics.append(allowMissingContracts ? .warning(message + "; the app sees it as absent") : .error(message))
                continue
            }
            if descriptor.kind != contract.kind {
                diagnostics.append(.error("\(contract.name) is a different kind of interface on Android"))
            } else if descriptor.version < contract.version {
                diagnostics.append(.warning("\(contract.name) is version \(descriptor.version) on Android; the app was built against \(contract.version)"))
            }
        }
        for problem in bundle.codeResourceProblems() {
            diagnostics.append(.error("the bundle doesn't match its CodeResources: \(problem)"))
        }

        if abis.isEmpty {
            diagnostics.append(.error("the bundle has no Android slices or App.wasm; build it with guest.py bundle --target android"))
        }
        for abi in abis {
            if !abi.isSupported {
                diagnostics.append(.warning("\(abi.rawValue) isn't tested on hardware yet"))
            }
            switch bundle.engine(for: abi, preferred: engine) {
            case .native:
                guard let slice = bundle.slice(abi) else {
                    diagnostics.append(.error("the bundle has no \(abi.target) slice; App.wasm can stand in with --engine wasm2c"))
                    continue
                }
                for problem in SliceInspector.problems(slice, abi: abi) {
                    diagnostics.append(.error("\(abi.target) slice: \(problem)"))
                }
            case .wasm2c:
                guard bundle.wasm != nil else {
                    diagnostics.append(.error("the bundle has no wasm32/App.wasm for wasm2c"))
                    continue
                }
                if engine == nil {
                    diagnostics.append(.warning("the bundle has no \(abi.target) slice; App.wasm is translated with wasm2c"))
                }
            case nil:
                diagnostics.append(.error("the bundle has no \(abi.target) slice, and no App.wasm for wasm2c"))
            }
        }

        let unsupported = info.capabilities.subtracting(HostContracts.capabilities).subtracting(HostContracts.unserved)
        for capability in unsupported.sorted(by: { $0.rawValue < $1.rawValue }) {
            diagnostics.append(.warning("the app declares \(capability.rawValue), which the Android host doesn't serve yet; it gets the permissions only"))
        }
        return diagnostics
    }

    /// Android's default `targetSdk` (`Plan.md` §1.5).
    public static let defaultTargetSDK = 35

    /// A Java package name: two or more parts of letters, digits and `_`,
    /// each starting with a letter.
    static func isApplicationID(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count >= 2 && parts.allSatisfy { part in
            guard let first = part.first, first.isASCII, first.isLetter else { return false }
            return part.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }
        }
    }

    /// `versionCode` from `CFBundleVersion`.
    static func versionCode(_ build: String) -> Int? {
        guard let code = Int(build), (1...2_100_000_000).contains(code) else { return nil }
        return code
    }
}

/// Reads a slice's archive: every ELF object in it must be for the ABI.
public enum SliceInspector {

    public static func problems(_ archive: URL, abi: AndroidABI) -> [String] {
        guard let data = FileManager.default.contents(atPath: archive.path) else {
            return ["can't read \(archive.path)"]
        }
        let machines: [UInt16]
        do {
            machines = try elfMachines(Array(data))
        } catch {
            return [error.message]
        }
        if machines.isEmpty {
            return ["the archive has no ELF objects"]
        }
        let wrong = Set(machines.filter { $0 != abi.elfMachine })
        return wrong.isEmpty ? [] : ["objects are for ELF machine \(wrong.sorted()), not \(abi.elfMachine) (\(abi.arch))"]
    }

    /// `e_machine` of each ELF member of a `!<arch>` archive.
    static func elfMachines(_ bytes: [UInt8]) throws(PackagerError) -> [UInt16] {
        let magic = Array("!<arch>\n".utf8)
        guard bytes.starts(with: magic) else {
            throw PackagerError("not an ar archive")
        }
        var machines: [UInt16] = []
        var offset = magic.count
        while offset + 60 <= bytes.count {
            let header = bytes[offset..<offset + 60]
            guard header.suffix(2).elementsEqual([0x60, 0x0A]) else {
                throw PackagerError("malformed archive member at \(offset)")
            }
            let sizeField = String(decoding: header.dropFirst(48).prefix(10), as: UTF8.self).trimmingCharacters(in: .whitespaces)
            guard let size = Int(sizeField), offset + 60 + size <= bytes.count else {
                throw PackagerError("malformed archive member size at \(offset)")
            }
            let body = bytes[(offset + 60)..<(offset + 60 + size)]
            if body.count >= 20, body.starts(with: [0x7F, 0x45, 0x4C, 0x46]) {
                let start = body.startIndex
                machines.append(UInt16(body[start + 18]) | UInt16(body[start + 19]) << 8)
            }
            offset += 60 + size + (size % 2)
        }
        return machines
    }
}
