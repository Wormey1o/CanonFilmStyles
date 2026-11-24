import CryptoKit
import Darwin
import Foundation

/// One User Def. entry of `CFPSTYLE.BIN`.
public enum CameraStyleCardSlot: Equatable, Sendable {
    /// No entry: flags 0 and all-zero fields (the camera-side reader must leave the slot unchanged).
    case empty
    /// A Canon-compiled registered style (flags 3, base 0x41 + slot index, row from Canon's 0x115 descriptor).
    case registered(CanonCompiledPictureStyle)
    /// A Canon built-in style (flags 7, base 0x81/0x86, explicit row, zero record).
    case builtin(base: UInt32, row: [Int32])
}

/// Writes the card data file that the Camera Styles extension reads. The base layout matches
/// the configuration block of
/// `experiments/film-native-style-install-v1/candidate-install-v1/build.py` (lines 64–101):
///
/// - bytes 0..<24: `<6I` magic 0x31445653 ("SVD1"), version 1, mode 0x54534E49 ("INST"), count 3,
///   record size 16,680, reserved 0;
/// - 3 × 96 bytes: `<II6i` flags, base, row[6] (contrast, sharpness, saturation, colour tone, filter,
///   toning), 32-byte SHA-256 of the record, 32-byte caption (record bytes 4..<36; zeros for built-in);
/// - FNV-1a 32 of the preceding 312 bytes;
/// - three 16,680-byte records (zeros for built-in or empty). Little-endian throughout; 50,356 bytes.
/// - optional 64-byte WB block at 50,356 (on by default), 50,420 bytes total:
///   "CFWB", u16 version 1, u16 size 64, u32 count 3; 3 × 12 bytes {u8 flags (bit0 mode, bit1 shift;
///   0 = leave WB), u8 Canon mode, i8 B/A (A +), i8 G/M (G +), 8 zero}; u32 the v1 config FNV (file bytes
///   312..<316); 8 zero; u32 FNV-1a 32 of block bytes 0..<60. Reference: film-native-style-wb-v1
///   candidate-wb-v1/build/wb-block.bin.
public enum CameraStyleCardExporter {
    public static let fileName = "CFPSTYLE.BIN"
    public static let slotsFileName = "SLOTS.txt"
    public static let magic: UInt32 = 0x3144_5653
    public static let version: UInt32 = 1
    public static let modeInstall: UInt32 = 0x5453_4E49
    public static let slotCount = 3
    public static let recordSize = CanonCompiledPictureStyle.recordSize   // 16,680
    public static let configSize = 316
    public static let fileSize = configSize + slotCount * recordSize      // 50,356
    public static let flagsRegistered: UInt32 = 3
    public static let flagsBuiltin: UInt32 = 1 | 2 | 4
    public static let wbMagic: UInt32 = 0x4257_4643   // "CFWB"
    public static let wbBlockSize = 64
    public static let fileSizeWithWB = fileSize + wbBlockSize   // 50,420
    /// Canon 450D WB mode values (no Kelvin entry on this body).
    public static let wbModes: [String: UInt8] = ["Auto": 0, "Daylight": 1, "Cloudy": 2, "Tungsten": 3, "White fluorescent": 4, "Flash": 5, "Custom": 6, "Shade": 8]

    /// One WB block slot entry.
    public struct WBEntry: Equatable, Sendable {
        public var flags: UInt8, mode: UInt8, amberBlue: Int8, greenMagenta: Int8
        public init(flags: UInt8, mode: UInt8, amberBlue: Int8, greenMagenta: Int8) {
            self.flags = flags; self.mode = mode; self.amberBlue = amberBlue; self.greenMagenta = greenMagenta
        }
        public static let leave = WBEntry(flags: 0, mode: 0, amberBlue: 0, greenMagenta: 0)
        /// Sets mode and shift (flags 3), or leaves WB alone (flags 0) when the plan says so.
        public init(_ wb: CanonWhiteBalanceInstruction) throws {
            guard wb.applyOnSlotSelect else { self = .leave; return }
            guard let mode = CameraStyleCardExporter.wbModes[wb.preset] else { throw ProfileError.invalid("WB preset \(wb.preset) has no 450D mode value.") }
            self.init(flags: 3, mode: mode, amberBlue: Int8(clamp(wb.amberBlue, -9, 9)), greenMagenta: Int8(clamp(wb.greenMagenta, -9, 9)))
        }
    }

    /// The 64-byte WB block for the v1 configuration whose FNV word is `configFNV`.
    public static func wbBlock(_ entries: [WBEntry], configFNV: UInt32) throws -> Data {
        guard entries.count == slotCount else { throw ProfileError.invalid("The WB block needs exactly three entries.") }
        var b = Data()
        b.appendLE(wbMagic); b.appendLE16(1); b.appendLE16(UInt16(wbBlockSize)); b.appendLE(UInt32(slotCount))
        for e in entries {
            guard e.flags & ~3 == 0, wbModes.values.contains(e.mode), (-9...9).contains(e.amberBlue), (-9...9).contains(e.greenMagenta) else {
                throw ProfileError.invalid("WB entry \(e) is outside the format (flags 0–3, modes 0–6/8, shifts ±9).")
            }
            b.append(contentsOf: [e.flags, e.mode, UInt8(bitPattern: e.amberBlue), UInt8(bitPattern: e.greenMagenta)])
            b.append(Data(count: 8))
        }
        b.appendLE(configFNV); b.append(Data(count: 8))
        b.appendLE(fnv1a32(b))
        precondition(b.count == wbBlockSize)
        return b
    }

    // MARK: Format

    /// The 316-byte configuration block (build.py's `cfg`, the words of `sv_config_data`).
    public static func configBlock(_ slots: [CameraStyleCardSlot]) throws -> Data {
        guard slots.count == slotCount else { throw ProfileError.invalid("CFPSTYLE.BIN needs exactly three slot entries (use .empty).") }
        var cfg = Data()
        for v in [magic, version, modeInstall, UInt32(slotCount), UInt32(recordSize), 0] { cfg.appendLE(v) }
        for (index, slot) in slots.enumerated() {
            let flags: UInt32, base: UInt32, row: [Int32], digest: Data, caption: Data
            switch slot {
            case .empty:
                flags = 0; base = 0; row = Array(repeating: 0, count: 6); digest = Data(count: 32); caption = Data(count: 32)
            case .registered(let style):
                try validateRegistered(style)
                let record = style.record
                flags = flagsRegistered; base = 0x41 + UInt32(index)
                row = Array(style.detailValues.prefix(6))
                digest = Data(SHA256.hash(data: record)); caption = record.subdata(in: 4..<36)
            case .builtin(let b, let r):
                try validateBuiltin(base: b, row: r)
                flags = flagsBuiltin; base = b; row = r; digest = Data(count: 32); caption = Data(count: 32)
            }
            cfg.appendLE(flags); cfg.appendLE(base)
            for v in row { cfg.appendLE(UInt32(bitPattern: v)) }
            cfg.append(digest); cfg.append(caption)
        }
        cfg.appendLE(fnv1a32(cfg))
        precondition(cfg.count == configSize)
        return cfg
    }

    /// The record bytes for one entry (zeros unless registered).
    public static func record(_ slot: CameraStyleCardSlot) -> Data {
        if case .registered(let style) = slot { return style.record }
        return Data(count: recordSize)
    }

    /// The whole file: 50,356 bytes (v1), or 50,420 with a WB block when `wb` is given.
    public static func cardFile(_ slots: [CameraStyleCardSlot], wb: [WBEntry]? = nil) throws -> Data {
        var data = try configBlock(slots)
        for slot in slots { data.append(record(slot)) }
        precondition(data.count == fileSize)
        if let wb { data.append(try wbBlock(wb, configFNV: data.u32le(312))) }
        return data
    }

    /// build.py's asserts on a converter output (`.camdata` = EDS 0x1000203, `.desc115` = EDS 0x115).
    static func validateRegistered(_ style: CanonCompiledPictureStyle) throws {
        let blob = style.userPictureStyleData, rec = style.record
        func fail(_ s: String) -> ProfileError { .invalid("Registered style rejected for CFPSTYLE.BIN: \(s)") }
        guard blob.count == 16_720, blob.u32le(0) == 1, blob.u32le(4) == 0x4128 else { throw fail("EU struct is not X=1, length 0x4128") }
        guard rec.count == recordSize, rec.u16le(0) == 0x4128, rec.u16le(2) == 0x81, rec.u16le(0x24) == 0x28, rec.u16le(0x26) == 0xFC else {
            throw fail("record header is not 0x4128/0x81/0x28/0xFC (only Standard-based styles are installed)")
        }
        guard rec.subdata(in: 4..<36) == blob.subdata(in: 8..<40), rec.subdata(in: 4..<36).contains(0) else { throw fail("caption copies differ or are not NUL-terminated") }
        guard Array(style.detailValues.suffix(2)) == [4, 4] else { throw fail("0x115 trailing words are not (4, 4)") }
    }

    static func validateBuiltin(base: UInt32, row: [Int32]) throws {
        guard base == 0x81 || base == 0x86 else { throw ProfileError.invalid("Built-in slot base 0x\(String(base, radix: 16)) is not 0x81 or 0x86.") }
        guard row.count == 6, (-4...4).contains(row[0]), (0...7).contains(row[1]), (-4...4).contains(row[2]), (-4...4).contains(row[3]),
              (0...4).contains(row[4]), (0...4).contains(row[5]) else {
            throw ProfileError.invalid("Built-in slot row \(row) is outside the 450D ranges.")
        }
    }

    public static func fnv1a32(_ data: Data) -> UInt32 { data.reduce(UInt32(0x811C_9DC5)) { ($0 ^ UInt32($1)) &* 0x0100_0193 } }

    // MARK: Plans → slots

    public struct CompiledSlot: Sendable {
        public var plan: CanonSlotPlan?
        public var slot: CameraStyleCardSlot
        /// The `.pf2` that was compiled (registered styles only).
        public var pictureStyle: Data?
    }

    /// Compiles registered plans with Canon's converter and checks that Canon's slider row equals the plan.
    /// `compiler` may be nil when no plan is a registered style.
    public static func compile(_ plans: [CanonSlotPlan?], compiler: CanonStyleCompiler?) throws -> [CompiledSlot] {
        guard plans.count <= slotCount else { throw ProfileError.invalid("At most three slot plans.") }
        let padded = plans + Array(repeating: nil, count: slotCount - plans.count)
        return try padded.enumerated().map { index, plan in
            guard let plan else { return CompiledSlot(plan: nil, slot: .empty, pictureStyle: nil) }
            guard plan.slot == index + 1 else { throw ProfileError.invalid("Plan for “\(plan.recipeName)” is for User Def. \(plan.slot), not \(index + 1).") }
            try plan.validate()
            if let style = plan.registered {
                guard let compiler else { throw ProfileError.invalid("Canon's Picture Style converter is needed for “\(plan.recipeName)”.") }
                let pf2 = try style.pictureStyleFile().encoded()
                let compiled = try compiler.compile(pf2)
                guard Array(compiled.detailValues.prefix(6)) == plan.row else {
                    throw ProfileError.invalid("Canon's converter returned row \(Array(compiled.detailValues.prefix(6))) for “\(plan.recipeName)”, plan has \(plan.row).")
                }
                guard compiled.caption == style.caption else { throw ProfileError.invalid("Canon's converter changed the caption of “\(plan.recipeName)”.") }
                return CompiledSlot(plan: plan, slot: .registered(compiled), pictureStyle: pf2)
            }
            return CompiledSlot(plan: plan, slot: .builtin(base: CanonMonochromePlan.base, row: plan.row), pictureStyle: nil)
        }
    }

    // MARK: Export

    public struct Receipt: Sendable {
        public var folder: URL
        public var cardFileSHA256: String
        public var recordSHA256: [String?]
        public var files: [String]
        public var withWBBlock: Bool
    }

    public struct ExportFailure: LocalizedError {
        public let publishedFiles: [String]
        public let cause: Error

        public var errorDescription: String? {
            guard !publishedFiles.isEmpty else { return cause.localizedDescription }
            return "Export stopped after replacing \(publishedFiles.joined(separator: ", ")). \(cause.localizedDescription)"
        }
    }

    /// Prepare all outputs before replacing any destination. The camera reads only CFPSTYLE.BIN,
    /// so publish it last, after the human-readable summary and optional EOS Utility files.
    @discardableResult
    public static func export(_ compiled: [CompiledSlot], to folder: URL, includeWhiteBalanceBlock: Bool = true,
                              includePictureStyleFiles: Bool = false,
                              converter: CanonCFParseInstallation? = nil, date: Date = Date()) throws -> Receipt {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ProfileError.invalid("Export folder \(folder.path) does not exist.")
        }
        let slots = compiled.map(\.slot)
        let wb = includeWhiteBalanceBlock ? try compiled.map { try $0.plan.map { try WBEntry($0.whiteBalance) } ?? .leave } : nil
        let file = try cardFile(slots, wb: wb)
        let digest = sha256Hex(file)
        let recordDigests: [String?] = slots.map { if case .registered(let s) = $0 { return sha256Hex(s.record) } else { return nil } }
        var text = slotsText(compiled, cardFileSHA256: digest, recordSHA256: recordDigests, converter: converter, date: date, wb: wb)
        var outputs: [(name: String, data: Data)] = []
        if includePictureStyleFiles {
            for item in compiled {
                guard let plan = item.plan, let pf2 = item.pictureStyle, let style = plan.registered else { continue }
                let safe = style.caption.map { "/:\\".contains($0) ? "-" : $0 }
                let name = "UD\(plan.slot) \(String(safe)).pf2"
                outputs.append((name, pf2))
                text += "Saved \(name) for registration with EOS Utility (same style as record \(plan.slot)).\n"
            }
        }
        outputs.append((slotsFileName, Data(text.utf8)))
        outputs.append((fileName, file))
        let written = try publish(outputs, to: folder)
        return Receipt(folder: folder, cardFileSHA256: digest, recordSHA256: recordDigests, files: written, withWBBlock: wb != nil)
    }

    /// Generates stock EOS Utility inputs directly from slot plans without the Canon converter.
    package static func exportForEOSUtility(_ plans: [CanonSlotPlan?], to folder: URL) throws -> [String] {
        guard plans.count == slotCount, plans.contains(where: { $0 != nil }) else {
            throw ProfileError.invalid("Assign at least one User Def. slot.")
        }
        var text = """
        Canon Film Profiles — User Def. settings for EOS 450D
        Register each .pf2 in its numbered slot with EOS Utility.
        Enter built-in Monochrome settings and white balance on the camera.

        """
        var outputs: [(name: String, data: Data)] = []
        for (index, plan) in plans.enumerated() {
            let slot = index + 1
            guard let plan else {
                text += "\nUser Def. \(slot) — leave as configured\n"
                continue
            }
            guard plan.slot == slot else {
                throw ProfileError.invalid("Style plan slot does not match its export position.")
            }
            try plan.validate()
            text += "\nUser Def. \(slot) — \(plan.recipeName)\n"
            if let registered = plan.registered {
                let name = "User Def. \(slot).pf2"
                outputs.append((name, try registered.pictureStyleFile().encoded()))
                text += "Register \(name).\n"
            }
            text += plan.descriptionLines.joined(separator: "\n") + "\n"
        }
        outputs.append((slotsFileName, Data(text.utf8)))
        return try publish(outputs, to: folder)
    }

    /// Writes and verifies a standalone file using the same staged replacement as a card export.
    public static func writeFile(_ data: Data, to url: URL) throws {
        _ = try publish([(url.lastPathComponent, data)], to: url.deletingLastPathComponent())
    }

    private static func validateDestination(_ url: URL) throws {
        var info = stat()
        if lstat(url.path, &info) == 0 {
            guard info.st_mode & S_IFMT == S_IFREG else {
                throw ProfileError.invalid("\(url.path) exists and is not a regular file.")
            }
        } else if errno != ENOENT {
            throw ProfileError.invalid("Could not inspect \(url.path): \(String(cString: strerror(errno)))")
        }
    }

    private static func publish(_ outputs: [(name: String, data: Data)], to folder: URL) throws -> [String] {
        let descriptor = open(folder.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw ProfileError.invalid("Could not open export folder \(folder.path): \(String(cString: strerror(errno)))")
        }
        defer { close(descriptor) }
        // The lock covers exporters on this Mac. It is released by close, including after a crash.
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            throw ProfileError.invalid("Could not lock export folder \(folder.path): \(String(cString: strerror(errno)))")
        }

        let fm = FileManager.default
        let visibleNames = rawDirectoryEntries(folder)
        for output in outputs { try validateDestination(folder.appendingPathComponent(output.name)) }
        let temporary = try PrivateWorkDirectory()
        defer { temporary.remove() }
        // Same-volume staging lets rename replace each final file without truncating it in place.
        let stageName = ".canon-style-export-" + UUID().uuidString
        let stage = folder.appendingPathComponent(stageName, isDirectory: true)
        try fm.createDirectory(at: stage, withIntermediateDirectories: false)
        defer {
            try? fm.removeItem(at: stage)
            if rawDirectoryEntries(folder).contains("._" + stageName) {
                try? fm.removeItem(at: folder.appendingPathComponent("._" + stageName))
            }
        }
        for output in outputs {
            try copyWithoutMetadata(output.data, to: stage.appendingPathComponent(output.name), staging: temporary)
        }

        var published: [String] = []
        do {
            for output in outputs {
                let destination = folder.appendingPathComponent(output.name)
                try validateDestination(destination)
                guard rename(stage.appendingPathComponent(output.name).path, destination.path) == 0 else {
                    throw ProfileError.invalid("Could not publish \(destination.path): \(String(cString: strerror(errno)))")
                }
                published.append(output.name)
                let twin = "._" + output.name
                if !visibleNames.contains(twin) && rawDirectoryEntries(folder).contains(twin) {
                    try fm.removeItem(at: folder.appendingPathComponent(twin))
                }
                guard try Data(contentsOf: destination) == output.data else {
                    throw ProfileError.invalid("\(destination.path) did not read back identically.")
                }
            }
        } catch {
            throw ExportFailure(publishedFiles: published, cause: error)
        }
        return published
    }

    /// Directory entries as the file system stores them (Foundation hides `._` files on FAT volumes).
    public static func rawDirectoryEntries(_ folder: URL) -> [String] {
        guard let dir = opendir(folder.path) else { return [] }
        defer { closedir(dir) }
        var names: [String] = []
        while let entry = readdir(dir) {
            let name = withUnsafeBytes(of: entry.pointee.d_name) { String(decoding: $0.prefix(Int(entry.pointee.d_namlen)), as: UTF8.self) }
            if name != "." && name != ".." { names.append(name) }
        }
        return names
    }

    /// Writes `data` to `url` with `ditto --norsrc --noextattr --noqtn` from a private staging file, so no
    /// AppleDouble `._` file appears on a FAT card; an `._` twin that this write created is removed, and the
    /// result is read back.
    static func copyWithoutMetadata(_ data: Data, to url: URL, staging: PrivateWorkDirectory) throws {
        let fm = FileManager.default
        if let type = try? fm.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType, type != .typeRegular {
            throw ProfileError.invalid("\(url.path) exists and is not a regular file; nothing was written over it.")
        }
        let twin = url.deletingLastPathComponent().appendingPathComponent("._" + url.lastPathComponent)
        let twinBefore = rawDirectoryEntries(url.deletingLastPathComponent()).contains("._" + url.lastPathComponent)
        let source = staging.url.appendingPathComponent(UUID().uuidString)
        try staging.writeNew(data, to: source)
        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: source.path)
        let result = try ProcessOutput.capture(
            executable: URL(fileURLWithPath: "/usr/bin/ditto"),
            arguments: ["--norsrc", "--noextattr", "--noqtn", source.path, url.path]
        )
        guard result.status == 0 else {
            throw ProfileError.invalid("ditto could not write \(url.path): " + String(decoding: result.stderr, as: UTF8.self))
        }
        // ditto alone is not enough on FAT: the kernel tags new files with com.apple.provenance, which msdosfs
        // stores as an AppleDouble twin (verified on a FAT16 image, 24 Nov 2026). Remove a twin this write created.
        if !twinBefore && rawDirectoryEntries(url.deletingLastPathComponent()).contains("._" + url.lastPathComponent) { try fm.removeItem(at: twin) }
        guard try Data(contentsOf: url) == data else { throw ProfileError.invalid("\(url.path) did not read back identically.") }
    }

    public static func slotsText(_ compiled: [CompiledSlot], cardFileSHA256: String, recordSHA256: [String?],
                                 converter: CanonCFParseInstallation?, date: Date, wb: [WBEntry]? = nil) -> String {
        let stamp = ISO8601DateFormatter().string(from: date)
        var t = "Canon Film Profiles — camera styles for EOS 450D User Def. 1–3\n"
        t += "Exported \(stamp). \(fileName) \(wb == nil ? fileSize : fileSizeWithWB) bytes (\(wb == nil ? "v1, no WB block" : "v1 + 64-byte WB block")), SHA-256 \(cardFileSHA256)\n"
        if let converter { t += "Canon converter: EdsCFParse \(converter.version) at \(converter.bundleURL.path) (executable SHA-256 \(converter.executableSHA256))\n" }
        t += wb == nil ? "\nWhite balance is camera-wide on the 450D and this file carries no WB block: set it by hand before shooting with each slot.\n"
            : "\nWhite balance is camera-wide on the 450D. The WB block asks the camera to set each slot's WB when that slot is selected, if the camera payload supports it; otherwise set it by hand.\n"
        t += "\(fileName) is read by the style-install camera extension; nothing is applied without that extension.\n\n"
        for (index, item) in compiled.enumerated() {
            t += "User Def. \(index + 1): "
            guard let plan = item.plan else { t += "empty (flags 0; slot left unchanged)\n\n"; continue }
            t += "\(plan.recipeName)\n"
            for line in plan.descriptionLines(cameraSetsWB: wb != nil) { t += "  \(line)\n" }
            if let e = wb?[index] { t += "  WB block: flags \(e.flags), mode \(e.mode), B/A \(e.amberBlue), G/M \(e.greenMagenta)\n" }
            if let digest = recordSHA256[index] { t += "  Record SHA-256: \(digest)\n" }
            t += "  Row (contrast, sharpness, saturation, tone, filter, toning): \(plan.row.map(String.init).joined(separator: ", "))\n\n"
        }
        return t
    }
}

extension Data {
    mutating func appendLE16(_ v: UInt16) { Swift.withUnsafeBytes(of: v.littleEndian) { append(contentsOf: $0) } }
    mutating func appendLE(_ v: UInt32) { Swift.withUnsafeBytes(of: v.littleEndian) { append(contentsOf: $0) } }
    func u32le(_ at: Int) -> UInt32 { let b = startIndex + at; return UInt32(self[b]) | UInt32(self[b + 1]) << 8 | UInt32(self[b + 2]) << 16 | UInt32(self[b + 3]) << 24 }
    func u16le(_ at: Int) -> UInt16 { let b = startIndex + at; return UInt16(self[b]) | UInt16(self[b + 1]) << 8 }
}
