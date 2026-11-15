import Foundation

/// How an ABI's `libapp.a` is made (`Plan.md` §8).
public enum Engine: String, CaseIterable, Sendable {
    /// The bundle's sealed slice for the ABI.
    case native
    /// `App.wasm`, translated to C by WABT's wasm2c and compiled for the ABI.
    case wasm2c
}

/// The wasm2c engine: `App.wasm` as a library with the same exports and
/// imports as a native slice, for any ABI (DynamicRuntime.md §7.5).
///
/// AppRuntime's `Scripts/wasm2c-shim.py` generates the shim between the
/// translated module and `rt.h`; this compiles it with the NDK's clang and
/// seals it like a slice, since the shim's own `build` targets Apple and
/// Linux hosts. The translated code keeps the guest in its linear memory,
/// so it's unaffected by Android's tagged heap pointers.
public struct Wasm2c {

    /// AppRuntime's checkout: the shim and `rt.h`.
    public var appRuntime: URL

    public var toolchain: Toolchain

    /// WABT's `wasm2c`, its runtime sources and its headers; found on
    /// `PATH` when nil.
    public var wabt: WABT?

    public struct WABT: Sendable {
        public var wasm2c: URL
        /// `wasm-rt-impl.c` and the other runtime sources.
        public var runtime: URL
        /// `wasm-rt.h`: `include/` in Homebrew's WABT, else the runtime's.
        public var include: URL

        public init(wasm2c: URL, runtime: URL, include: URL? = nil) {
            self.wasm2c = wasm2c
            self.runtime = runtime
            self.include = include ?? runtime
        }
    }

    /// The exports a slice has.
    static let exports = ["rt_main", "rt_dispatch", "rt_finalize"]

    /// The custom sections copied into the object, as a native slice has
    /// them.
    static let sections = ["rt.abi", "rt.contracts", "rt.manifest"]

    /// wasm-rt without signal handlers, as the shim builds it: explicit
    /// bounds checks and stack depth counting.
    static let defines = [
        "-DWASM_RT_MEMCHECK_GUARD_PAGES=0",
        "-DWASM_RT_MEMCHECK_BOUNDS_CHECK=1",
        "-DWASM_RT_STACK_DEPTH_COUNT=1",
        "-DWASM_RT_SKIP_SIGNAL_RECOVERY=1",
    ]

    public init(appRuntime: URL, toolchain: Toolchain) {
        self.appRuntime = appRuntime
        self.toolchain = toolchain
    }

    var shim: URL {
        appRuntime.appendingPathComponent("Scripts/wasm2c-shim.py")
    }

    var rtInclude: URL {
        appRuntime.appendingPathComponent("Sources/CRuntime/include")
    }

    /// WABT's `wasm2c`, runtime sources (`wasm-rt-impl.c`) and headers,
    /// found from `PATH` as the shim finds them.
    static func wabt(environment: [String: String] = ProcessInfo.processInfo.environment) throws(PackagerError) -> WABT {
        let path = environment["PATH"] ?? "/usr/bin:/bin"
        for directory in path.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent("wasm2c")
            guard FileManager.default.isExecutableFile(atPath: candidate.path) else { continue }
            let prefix = candidate.resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent()
            for runtime in [prefix.appendingPathComponent("share/wabt/wasm2c"), prefix.appendingPathComponent("wasm2c")]
            where FileManager.default.fileExists(atPath: runtime.appendingPathComponent("wasm-rt-impl.c").path) {
                let include = prefix.appendingPathComponent("include")
                let hasHeader = FileManager.default.fileExists(atPath: include.appendingPathComponent("wasm-rt.h").path)
                return WABT(wasm2c: candidate, runtime: runtime, include: hasHeader ? include : runtime)
            }
            throw PackagerError("WABT's wasm-rt-impl.c isn't under \(prefix.path)")
        }
        throw PackagerError("wasm2c isn't on PATH; install WABT (brew install wabt)")
    }

    /// Translates `wasm` and compiles it for `abi` in `directory`; the
    /// sealed `libapp.a`.
    public func build(_ wasm: URL, abi: AndroidABI, in directory: URL, runner: CommandRunning) throws(PackagerError) -> URL {
        let found: WABT
        if let wabt {
            found = wabt
        } else {
            found = try Self.wabt()
        }
        let (wasm2c, runtime) = (found.wasm2c, found.runtime)
        let files = FileManager.default
        do {
            try files.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw PackagerError("can't create \(directory.path): \(error)")
        }
        let module = directory.appendingPathComponent("app.c")
        let shimSource = directory.appendingPathComponent("rt_wasm2c.c")
        try runner.run([wasm2c.path, wasm.path, "-n", "app", "-o", module.path], directory: nil, environment: [:])
        // The shim checks the module imports only what it provides.
        try runner.run(["python3", shim.path, "shim", "--wasm", wasm.path, "-o", shimSource.path], directory: nil, environment: [:])

        let clang = toolchain.llvmTool("clang").path
        let flags = ["--target=\(abi.clangTarget)", "-O2", "-fPIC", "-fvisibility=hidden", "-w"]
            + Self.defines
            + ["-I", directory.path, "-I", runtime.path, "-I", found.include.path, "-I", rtInclude.path]
        var objects: [String] = []
        for source in [module, shimSource, runtime.appendingPathComponent("wasm-rt-impl.c"), runtime.appendingPathComponent("wasm-rt-mem-impl.c")] {
            let object = directory.appendingPathComponent(source.deletingPathExtension().lastPathComponent + ".o").path
            try runner.run([clang] + flags + ["-c", source.path, "-o", object], directory: nil, environment: [:])
            objects.append(object)
        }

        // Sealed like a slice: one relocatable object, only the three
        // exports global, and the module's sections.
        let sealed = directory.appendingPathComponent("app.o").path
        try runner.run([toolchain.llvmTool("ld.lld").path, "-r", "-o", sealed] + objects, directory: nil, environment: [:])
        var objcopy = [toolchain.llvmTool("llvm-objcopy").path] + Self.exports.map { "--keep-global-symbol=\($0)" }
        let custom = (try? WasmModule.customSections(Data(contentsOf: wasm))) ?? [:]
        for name in Self.sections {
            guard let bytes = custom[name] else { continue }
            let file = directory.appendingPathComponent("\(name).bin")
            do {
                try bytes.write(to: file)
            } catch {
                throw PackagerError("can't write \(file.path): \(error)")
            }
            objcopy.append("--add-section=.\(name.replacingOccurrences(of: ".", with: "_"))=\(file.path)")
        }
        try runner.run(objcopy + [sealed], directory: nil, environment: [:])

        let archive = directory.appendingPathComponent("libapp.a")
        try? files.removeItem(at: archive)
        try runner.run([toolchain.llvmTool("llvm-ar").path, "rcs", archive.path, sealed], directory: nil, environment: [:])
        return archive
    }
}

/// The parts of a wasm module the packager reads.
enum WasmModule {

    /// The custom sections, by name; empty if `data` isn't a module.
    static func customSections(_ data: Data) -> [String: Data] {
        let bytes = [UInt8](data)
        guard bytes.count >= 8, bytes[0..<4] == [0, 0x61, 0x73, 0x6D] else { return [:] }
        var index = 8
        func leb() -> Int? {
            var result = 0, shift = 0
            while index < bytes.count, shift < 35 {
                let byte = bytes[index]
                index += 1
                result |= Int(byte & 0x7F) << shift
                shift += 7
                if byte < 0x80 {
                    return result
                }
            }
            return nil
        }
        var sections: [String: Data] = [:]
        while index < bytes.count {
            let id = bytes[index]
            index += 1
            guard let size = leb(), index + size <= bytes.count else { break }
            let end = index + size
            if id == 0, let length = leb(), index + length <= end {
                let name = String(decoding: bytes[index..<index + length], as: UTF8.self)
                sections[name] = Data(bytes[(index + length)..<end])
            }
            index = end
        }
        return sections
    }
}
