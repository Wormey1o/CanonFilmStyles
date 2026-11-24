import CoreFoundation
import CryptoKit
import Darwin
import Foundation

/// Compiles a `.pf2` into the EOS 450D's registered-style record by calling Canon's own converter,
/// the `EdsCFParse` bundle installed with EOS Utility 3 / Picture Style Editor on this Mac.
///
/// Canon's library is located at run time and never copied, bundled or redistributed (owner
/// decision, 24 Nov 2026: "OK to have the app call the installed Canon library"). If it is not
/// installed, `locate` throws and nothing is produced.
///
/// The call sequence is exactly the proven host harness
/// `experiments/film-native-style-storage-v1/host-cfparse/cfp_convert.c` (itself EU2 2.14.31c's
/// `+[UPSE cameraDataFromPSEFile:]`): `EdsCfpInitialize`, `EdsCfpCreateRefEx(fileURL, 2, 0, &ref)`,
/// `EdsCfpSetPropertyData(ref, 0x1000001, 0, 4, &model)`, `EdsCfpGetPropertySize/Data(prop)`,
/// `EdsCfpRelease`, `EdsCfpTerminate`; once for 0x1000203 (UserPictureStyleData) and once for
/// 0x115 (detail descriptor = the UD slider row), as the harness produced `*.camdata` / `*.desc115`.
///
/// Default isolation is a child process (the app's own executable in `helperFlag` mode): Canon's
/// code then never runs in the GUI process, a crash in it cannot take the app down, and each
/// conversion gets a fresh process-wide bundle registry (see `CanonCFParseLibrary`).
public struct CanonStyleCompiler: Sendable {
    public enum Isolation: Sendable, Equatable {
        /// Load Canon's bundle into this process. Used by the helper itself and by checks.
        case inProcess
        /// Run `executable helperFlag <bundle> <workdir>`; the executable must route that flag to `runHelper`.
        case helper(executable: URL)
    }

    public static let helperFlag = "--compile-picture-style"
    public static let helperTimeout: TimeInterval = 60
    /// Name prefix of the private per-conversion directory under the user's temporary directory.
    public static let temporaryPrefix = "CanonStyleCompiler."

    public let installation: CanonCFParseInstallation
    public let isolation: Isolation

    /// - Parameter installation: a specific converter; `nil` runs `CanonCFParseInstallation.locate()`.
    public init(installation: CanonCFParseInstallation? = nil, isolation: Isolation) throws {
        self.installation = try installation ?? CanonCFParseInstallation.locate()
        self.isolation = isolation
    }

    /// `.pf2` bytes (as stored on disk) → validated 450D record, X value and detail row.
    /// The file must parse with `PictureStyleFile` before Canon's code sees it.
    public func compile(_ pf2: Data) throws -> CanonCompiledPictureStyle {
        _ = try PictureStyleFile(encoded: pf2)
        let work = try PrivateWorkDirectory()
        defer { work.remove() }
        let input = work.url.appendingPathComponent("input.pf2")
        try work.writeNew(pf2, to: input)
        switch isolation {
        case .inProcess:
            let library = try CanonCFParseLibrary.shared(for: installation)
            return try library.compile(fileURL: input)
        case .helper(let executable):
            return try Self.runChild(executable: executable, bundle: installation.bundleURL, work: work)
        }
    }

    // MARK: Helper process

    static let recordFile = "0x1000203.bin"
    static let detailFile = "0x115.bin"

    /// Entry point for `<executable> --compile-picture-style BUNDLE WORKDIR` (arguments after the flag).
    /// Reads `WORKDIR/input.pf2`, writes `0x1000203.bin` and `0x115.bin` (never overwriting),
    /// prints one JSON line. Returns the process exit status.
    public static func runHelper(arguments: [String]) -> Int32 {
        guard arguments.count == 2 else {
            FileHandle.standardError.write(Data("usage: \(helperFlag) /path/EdsCFParse.bundle /private/workdir\n".utf8))
            return 64
        }
        do {
            let installation = try CanonCFParseInstallation(bundleURL: URL(fileURLWithPath: arguments[0], isDirectory: true))
            let work = URL(fileURLWithPath: arguments[1], isDirectory: true)
            let input = work.appendingPathComponent("input.pf2")
            _ = try PictureStyleFile(encoded: Data(contentsOf: input))
            let library = try CanonCFParseLibrary.shared(for: installation)
            let style = try library.compile(fileURL: input)
            try PrivateWorkDirectory.writeNew(style.userPictureStyleData, to: work.appendingPathComponent(recordFile))
            try PrivateWorkDirectory.writeNew(style.detail, to: work.appendingPathComponent(detailFile))
            let summary: [String: Any] = ["status": "PASS", "bundle": installation.bundleURL.path,
                                          "version": installation.version, "caption": style.caption,
                                          "recordSHA256": sha256Hex(style.record)]
            print(String(decoding: try JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys]), as: UTF8.self))
            return 0
        } catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            return 1
        }
    }

    private static func runChild(executable: URL, bundle: URL, work: PrivateWorkDirectory) throws -> CanonCompiledPictureStyle {
        let stdoutURL = work.url.appendingPathComponent("stdout.txt"), stderrURL = work.url.appendingPathComponent("stderr.txt")
        try work.writeNew(Data(), to: stdoutURL)
        try work.writeNew(Data(), to: stderrURL)
        let stdout = try FileHandle(forWritingTo: stdoutURL), stderr = try FileHandle(forWritingTo: stderrURL)
        defer { try? stdout.close(); try? stderr.close() }
        let process = Process()
        process.executableURL = executable
        process.arguments = [helperFlag, bundle.path, work.url.path]
        process.currentDirectoryURL = work.url
        process.environment = ["LC_ALL": "C"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdout
        process.standardError = stderr
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        try process.run()
        if done.wait(timeout: .now() + helperTimeout) == .timedOut {
            process.terminate()
            _ = done.wait(timeout: .now() + 5)
            throw ProfileError.invalid("Canon style converter helper did not finish within \(Int(helperTimeout)) s and was stopped.")
        }
        let diagnostic = (try? String(contentsOf: stderrURL, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            let how = process.terminationReason == .uncaughtSignal ? "crashed (signal \(process.terminationStatus))" : "failed (exit \(process.terminationStatus))"
            throw ProfileError.invalid("Canon style converter helper \(how)" + (diagnostic.isEmpty ? "." : ": \(diagnostic)"))
        }
        let record = try Data(contentsOf: work.url.appendingPathComponent(recordFile))
        let detail = try Data(contentsOf: work.url.appendingPathComponent(detailFile))
        return try CanonCompiledPictureStyle(userPictureStyleData: record, detail: detail)
    }
}

// MARK: - Output

/// The two properties Canon's converter produces for one `.pf2`, validated against the layout the
/// 450D 1.1.0 consumers read (storage study RESULT.md, Q1). Stage 5 installs, per UD slot n (1–3):
/// `x` → 0x04010000+2(n−1), `record` → 0x04010001+2(n−1), `detailRow` → 0x02060007+(n−1),
/// `cameraSlotBase(n)` → 0x0206000A+(n−1).
public struct CanonCompiledPictureStyle: Equatable, Sendable {
    public static let modelEOS450D: UInt32 = 0x8000_0176
    public static let propertyModel: UInt32 = 0x0100_0001
    public static let propertyUserPictureStyleData: UInt32 = 0x0100_0203
    public static let propertyDetail: UInt32 = 0x0000_0115
    /// EDS type of 0x1000203 (harness comment: "type must be 0xE").
    public static let userPictureStyleDataType: Int32 = 0xE
    /// EDS type the converter reports for 0x115 (observed 0x66 on EU3 3.21.10 / PSE 3.19).
    public static let detailType: Int32 = 0x66
    /// 450D registered-style record (PROP_PC_FLAVORn_PARAM), 0x4128 bytes.
    public static let recordSize = 0x4128
    /// 0x1000203 = u32 X, u32 record length, 32-byte caption, record.
    public static let userPictureStyleDataSize = 8 + 32 + recordSize
    public static let detailSize = 32
    public static let detailRowSize = 24

    /// EDS property 0x1000203 exactly as returned (16,720 bytes; equals the harness `*.camdata`).
    public let userPictureStyleData: Data
    /// EDS property 0x115 exactly as returned (32 bytes; equals the harness `*.desc115`).
    public let detail: Data

    public var x: UInt32 { Self.u32(userPictureStyleData, 0) }
    /// The 16,680-byte camera record.
    public var record: Data { userPictureStyleData.subdata(in: 40..<Self.userPictureStyleDataSize) }
    /// Base style of the file (record +2): 0x81 Standard … 0x85 Faithful.
    public var fileBase: UInt16 { Self.u16(userPictureStyleData, 42) }
    public var caption: String { String(decoding: userPictureStyleData.subdata(in: 44..<76).prefix { $0 != 0 }, as: UTF8.self) }
    /// First 24 bytes of 0x115: the UD row EU sends with D160–2.
    public var detailRow: Data { detail.prefix(Self.detailRowSize) }
    /// 0x115 as eight little-endian i32: contrast, sharpness, saturation, colour tone, filter, toning, then two trailing words.
    public var detailValues: [Int32] { (0..<8).map { Int32(bitPattern: Self.u32(detail, $0 * 4)) } }

    /// Slot base for User Defined n: PC n = 0x41–0x43 (ROM table FFC35FF8).
    public static func cameraSlotBase(userDefined slot: Int) throws -> UInt32 {
        guard (1...3).contains(slot) else { throw ProfileError.invalid("User Defined slot must be 1–3") }
        return 0x40 + UInt32(slot)
    }

    public init(userPictureStyleData data: Data, detail: Data) throws {
        let data = Data(data), detail = Data(detail)
        func require(_ ok: Bool, _ what: String) throws {
            guard ok else { throw ProfileError.invalid("Canon converter output rejected: \(what)") }
        }
        try require(data.count == Self.userPictureStyleDataSize, "UserPictureStyleData is \(data.count) bytes, expected \(Self.userPictureStyleDataSize)")
        try require(Self.u32(data, 0) == 1, "X is \(Self.u32(data, 0)), expected 1")
        try require(Self.u32(data, 4) == UInt32(Self.recordSize), "length field is not 0x4128")
        let record = data.subdata(in: 40..<data.count)
        try require(Self.u16(record, 0) == UInt16(Self.recordSize), "record size field is not 0x4128")
        try require((0x81...0x85).contains(Self.u16(record, 2)), "record base 0x\(String(Self.u16(record, 2), radix: 16)) is not 0x81–0x85")
        try require(Self.u16(record, 0x24) == 0x28 && Self.u16(record, 0x26) == 0xFC, "record header/parameter lengths are not 0x28/0xFC")
        let caption = [UInt8](record.subdata(in: 4..<36))
        guard let nul = caption.firstIndex(of: 0) else { throw ProfileError.invalid("Canon converter output rejected: caption is not NUL-terminated") }
        try require(nul > 0 && caption[..<nul].allSatisfy { (0x20...0x7E).contains($0) }, "caption is not 1–31 printable ASCII characters")
        try require(data.subdata(in: 8..<40) == record.subdata(in: 4..<36), "outer caption differs from record caption")
        try require(Self.u32(record, 0x124) == 1, "custom-table flag at +0x124 is not 1")
        try require(detail.count == Self.detailSize, "detail descriptor is \(detail.count) bytes, expected \(Self.detailSize)")
        let values = (0..<6).map { Int32(bitPattern: Self.u32(detail, $0 * 4)) }
        try require((-4...4).contains(values[0]) && (0...7).contains(values[1]) && (-4...4).contains(values[2]) && (-4...4).contains(values[3]),
                    "detail sliders \(values.prefix(4)) are outside the 450D ranges")
        try require((0...4).contains(values[4]) && (0...4).contains(values[5]), "detail filter/toning \(values[4]),\(values[5]) are outside 0–4")
        userPictureStyleData = data
        self.detail = detail
    }

    static func u32(_ data: Data, _ offset: Int) -> UInt32 {
        let b = data.startIndex + offset
        return UInt32(data[b]) | UInt32(data[b + 1]) << 8 | UInt32(data[b + 2]) << 16 | UInt32(data[b + 3]) << 24
    }
    static func u16(_ data: Data, _ offset: Int) -> UInt16 {
        let b = data.startIndex + offset
        return UInt16(data[b]) | UInt16(data[b + 1]) << 8
    }
}

// MARK: - Locating Canon's installed converter

/// An installed `EdsCFParse.bundle` that can run in this process's architecture and has Canon's
/// `MLib.bundle` beside it. EdsCFParse finds MLib by identifier among its sibling bundles; a copy
/// without that sibling (Picture Style Editor's top-level `PlugIns/EdsCFParse.bundle`) still returns
/// success but emits different tables (measured 24 Nov 2026, PosFilmRR2 `d679155f…` vs `39db77d4…`),
/// so such copies are refused here and the loaded MLib is checked after every conversion.
public struct CanonCFParseInstallation: Sendable, Equatable {
    public static let environmentKey = "CANON_EDSCFPARSE_BUNDLE"
    public static let parserIdentifier = "com.canon.edscfparse"
    public static let mlibIdentifier = "com.canon.MLib"

    /// Searched under /Applications and ~/Applications, in this order (newest arm64 first).
    public static let knownRelativePaths = [
        "Canon Utilities/EOS Utility/EU3/EOS Utility 3.app/Contents/PlugIns/EdsCFParse.bundle",
        "Canon Utilities/Picture Style Editor/PictureStyleEditor.app/Contents/PlugIns/DppCore.bundle/Contents/PlugIns/EdsCFParse.bundle",
        // x86_64/i386 only: usable only when this process runs as x86_64 (Rosetta).
        "Canon Utilities/EOS Utility/EU2/EOS Utility 2.app/Contents/PlugIns/EdsCFParse.bundle",
    ]

    public let bundleURL: URL
    public let mlibURL: URL
    public let version: String
    /// SHA-256 of the bundle executable (whole fat file), for provenance in manifests.
    public let executableSHA256: String

    /// Validates one candidate. Throws with the reason it cannot be used.
    public init(bundleURL: URL) throws {
        let bundleURL = bundleURL.standardizedFileURL.resolvingSymlinksInPath()
        func refuse(_ why: String) -> ProfileError { .invalid("Canon converter at \(bundleURL.path) cannot be used: \(why)") }
        guard let parser = Bundle(url: bundleURL) else { throw refuse("not a bundle (is Picture Style Editor or EOS Utility 3 installed?)") }
        guard parser.bundleIdentifier == Self.parserIdentifier else { throw refuse("bundle identifier is \(parser.bundleIdentifier ?? "missing"), expected \(Self.parserIdentifier)") }
        guard let executable = parser.executableURL, FileManager.default.isReadableFile(atPath: executable.path) else { throw refuse("bundle executable missing") }
        guard Self.runsHere(parser) else { throw refuse("no \(Self.currentArchitectureName) slice in the bundle executable") }
        let mlibURL = bundleURL.deletingLastPathComponent().appendingPathComponent("MLib.bundle", isDirectory: true)
        guard let mlib = Bundle(url: mlibURL), mlib.bundleIdentifier == Self.mlibIdentifier else { throw refuse("no \(Self.mlibIdentifier) MLib.bundle beside it (its output would be wrong)") }
        guard Self.runsHere(mlib) else { throw refuse("MLib.bundle has no \(Self.currentArchitectureName) slice") }
        let executableData = try Data(contentsOf: executable, options: .mappedIfSafe)
        self.bundleURL = bundleURL
        self.mlibURL = mlibURL
        version = parser.infoDictionary?["CFBundleShortVersionString"] as? String ?? parser.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
        executableSHA256 = sha256Hex(executableData)
    }

    /// Every known install location, each with its validation outcome.
    public static func survey(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> [(url: URL, result: Result<CanonCFParseInstallation, Error>)] {
        let roots = [URL(fileURLWithPath: "/Applications", isDirectory: true), homeDirectory.appendingPathComponent("Applications", isDirectory: true)]
        return roots.flatMap { root in knownRelativePaths.map { root.appendingPathComponent($0, isDirectory: true) } }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .map { url in (url, Result { try CanonCFParseInstallation(bundleURL: url) }) }
    }

    /// Resolution order: explicit path, then `CANON_EDSCFPARSE_BUNDLE`, then the first usable known install.
    /// An explicit or environment path that fails validation is an error; it never falls back silently.
    public static func locate(explicit: URL? = nil, environment: [String: String] = ProcessInfo.processInfo.environment) throws -> CanonCFParseInstallation {
        if let explicit { return try CanonCFParseInstallation(bundleURL: explicit) }
        if let path = environment[environmentKey], !path.isEmpty { return try CanonCFParseInstallation(bundleURL: URL(fileURLWithPath: path, isDirectory: true)) }
        let found = survey()
        if let usable = found.lazy.compactMap({ try? $0.result.get() }).first { return usable }
        let tried = found.isEmpty ? "none of the known locations exist" : found.map { "\($0.url.path): \(($0.result.failureMessage) ?? "")" }.joined(separator: "; ")
        throw ProfileError.invalid("Canon's Picture Style converter (EdsCFParse) is not installed on this Mac. Install Picture Style Editor or EOS Utility 3 from Canon, or set \(environmentKey). Searched /Applications and ~/Applications (\(tried)).")
    }

    static var currentArchitectureName: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }
    private static func runsHere(_ bundle: Bundle) -> Bool {
        #if arch(arm64)
        let wanted = NSBundleExecutableArchitectureARM64
        #else
        let wanted = NSBundleExecutableArchitectureX86_64
        #endif
        return bundle.executableArchitectures?.contains(NSNumber(value: wanted)) ?? false
    }
}

private extension Result where Failure == Error {
    var failureMessage: String? { if case .failure(let error) = self { return error.localizedDescription }; return nil }
}

// MARK: - In-process binding to Canon's C entry points

/// One loaded `EdsCFParse` per process. Bundle identifiers (com.canon.MLib) are resolved process-wide
/// and Canon's code cannot be unloaded safely, so a second, different installation is refused here;
/// use `.helper` isolation to compare installations. Calls are serialised.
final class CanonCFParseLibrary: @unchecked Sendable {
    private typealias Initialize = @convention(c) () -> UInt32
    private typealias CreateRefEx = @convention(c) (CFURL, Int32, Int32, UnsafeMutablePointer<UnsafeMutableRawPointer?>) -> UInt32
    private typealias SetPropertyData = @convention(c) (UnsafeMutableRawPointer, UInt32, Int32, UInt32, UnsafeRawPointer) -> UInt32
    private typealias GetPropertySize = @convention(c) (UnsafeMutableRawPointer, UInt32, Int32, UnsafeMutablePointer<Int32>, UnsafeMutablePointer<UInt32>) -> UInt32
    private typealias GetPropertyData = @convention(c) (UnsafeMutableRawPointer, UInt32, Int32, UInt32, UnsafeMutableRawPointer) -> UInt32
    private typealias Release = @convention(c) (UnsafeMutableRawPointer) -> UInt32

    private static let registry = NSLock()
    private static var loaded: CanonCFParseLibrary?

    let installation: CanonCFParseInstallation
    private let lock = NSLock()
    private let initialize: Initialize, terminate: Initialize, createRef: CreateRefEx
    private let setProperty: SetPropertyData, getSize: GetPropertySize, getData: GetPropertyData, release: Release

    static func shared(for installation: CanonCFParseInstallation) throws -> CanonCFParseLibrary {
        registry.lock(); defer { registry.unlock() }
        if let loaded {
            guard loaded.installation.bundleURL == installation.bundleURL else {
                throw ProfileError.invalid("A different Canon converter (\(loaded.installation.bundleURL.path)) is already loaded in this process; use helper isolation.")
            }
            return loaded
        }
        let library = try CanonCFParseLibrary(installation)
        loaded = library
        return library
    }

    private init(_ installation: CanonCFParseInstallation) throws {
        self.installation = installation
        guard let bundle = CFBundleCreate(kCFAllocatorDefault, installation.bundleURL as CFURL) else {
            throw ProfileError.invalid("Could not open Canon converter bundle \(installation.bundleURL.path)")
        }
        var error: Unmanaged<CFError>?
        guard CFBundleLoadExecutableAndReturnError(bundle, &error) else {
            let reason = error.map { CFErrorCopyDescription($0.takeRetainedValue()) as String } ?? "unknown reason"
            throw ProfileError.invalid("Could not load Canon converter \(installation.bundleURL.path): \(reason)")
        }
        func symbol<T>(_ name: String, _: T.Type) throws -> T {
            guard let pointer = CFBundleGetFunctionPointerForName(bundle, name as CFString) else {
                throw ProfileError.invalid("Canon converter \(installation.bundleURL.path) lacks \(name)")
            }
            return unsafeBitCast(pointer, to: T.self)
        }
        initialize = try symbol("EdsCfpInitialize", Initialize.self)
        terminate = try symbol("EdsCfpTerminate", Initialize.self)
        createRef = try symbol("EdsCfpCreateRefEx", CreateRefEx.self)
        setProperty = try symbol("EdsCfpSetPropertyData", SetPropertyData.self)
        getSize = try symbol("EdsCfpGetPropertySize", GetPropertySize.self)
        getData = try symbol("EdsCfpGetPropertyData", GetPropertyData.self)
        release = try symbol("EdsCfpRelease", Release.self)
    }

    func compile(fileURL: URL) throws -> CanonCompiledPictureStyle {
        lock.lock(); defer { lock.unlock() }
        let record = try property(CanonCompiledPictureStyle.propertyUserPictureStyleData, file: fileURL,
                                  expectedSize: CanonCompiledPictureStyle.userPictureStyleDataSize,
                                  expectedType: CanonCompiledPictureStyle.userPictureStyleDataType)
        try verifyMLib()
        let detail = try property(CanonCompiledPictureStyle.propertyDetail, file: fileURL,
                                  expectedSize: CanonCompiledPictureStyle.detailSize,
                                  expectedType: CanonCompiledPictureStyle.detailType)
        return try CanonCompiledPictureStyle(userPictureStyleData: record, detail: detail)
    }

    /// One harness run: initialise, open the file, set the model, read one property, release, terminate.
    private func property(_ id: UInt32, file: URL, expectedSize: Int, expectedType: Int32) throws -> Data {
        func fail(_ step: String, _ code: UInt32) -> ProfileError {
            .invalid("Canon converter \(step) for property 0x\(String(id, radix: 16)) returned 0x\(String(code, radix: 16))")
        }
        let initCode = initialize()
        guard initCode == 0 else { throw fail("EdsCfpInitialize", initCode) }
        defer { _ = terminate() }
        var ref: UnsafeMutableRawPointer?
        let fileURL = URL(fileURLWithPath: file.path, isDirectory: false)
        let created = createRef(fileURL as CFURL, 2, 0, &ref)
        guard created == 0, let ref else { throw fail("EdsCfpCreateRefEx", created) }
        defer { _ = release(ref) }
        var model = CanonCompiledPictureStyle.modelEOS450D
        let set = withUnsafeBytes(of: &model) { setProperty(ref, CanonCompiledPictureStyle.propertyModel, 0, 4, $0.baseAddress!) }
        guard set == 0 else { throw fail("EdsCfpSetPropertyData(model)", set) }
        var type: Int32 = -1, size: UInt32 = 0
        let sized = getSize(ref, id, 0, &type, &size)
        guard sized == 0 else { throw fail("EdsCfpGetPropertySize", sized) }
        guard Int(size) == expectedSize else {
            throw ProfileError.invalid("Canon converter property 0x\(String(id, radix: 16)) is \(size) bytes, expected \(expectedSize)")
        }
        if type != expectedType {
            throw ProfileError.invalid("Canon converter property 0x\(String(id, radix: 16)) has type 0x\(String(type, radix: 16)), expected 0x\(String(expectedType, radix: 16))")
        }
        var data = Data(count: Int(size))
        let got = data.withUnsafeMutableBytes { getData(ref, id, 0, size, $0.baseAddress!) }
        guard got == 0 else { throw fail("EdsCfpGetPropertyData", got) }
        return data
    }

    /// EdsCFParse must have loaded the MLib beside it; anything else gives silently different tables.
    private func verifyMLib() throws {
        guard let mlib = CFBundleGetBundleWithIdentifier(CanonCFParseInstallation.mlibIdentifier as CFString),
              CFBundleIsExecutableLoaded(mlib),
              let url = CFBundleCopyBundleURL(mlib) as URL?,
              url.standardizedFileURL.resolvingSymlinksInPath() == installation.mlibURL else {
            throw ProfileError.invalid("Canon converter ran without its own MLib (\(installation.mlibURL.path)); output discarded.")
        }
    }
}

// MARK: - Private temporary files

/// A 0700 directory under the user's temporary directory, removed after use.
struct PrivateWorkDirectory {
    let url: URL

    init() throws {
        let base = FileManager.default.temporaryDirectory
        url = base.appendingPathComponent(CanonStyleCompiler.temporaryPrefix + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }

    func writeNew(_ data: Data, to file: URL) throws { try Self.writeNew(data, to: file) }

    /// O_CREAT|O_EXCL, mode 0600: never follows or replaces an existing file.
    static func writeNew(_ data: Data, to file: URL) throws {
        let fd = open(file.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw ProfileError.invalid("Could not create \(file.path): \(String(cString: strerror(errno)))") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        try handle.write(contentsOf: data)
        try handle.close()
    }

    func remove() { try? FileManager.default.removeItem(at: url) }
}

func sha256Hex(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
