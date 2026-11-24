import Foundation

/// Canon Picture Style `.pf2` reader/writer, byte-compatible with
/// `experiments/film-native-picture-style-route-v1/pf2.py` (Stage 1, 24 Nov 2026).
///
/// Format (verified on four files saved by Picture Style Editor 1.33.10 and two generated files
/// that registered through EOS Utility 2 and changed the 450D camera JPEG):
/// - bytes 0..<12: plain header; 0..<4 format id `00 00 20 01`, 4..<8 `"PSP\0"`, 8..<12 big-endian
///   length of everything after the header.
/// - bytes 12...: XOR-obfuscated with `KEY_1[i % 512] ^ KEY_2[i % 513] ^ 0x37` at absolute offset `i`;
///   decoded content is a sequence of big-endian blocks `u16 tag, u16 type, u32 length, data`.
/// - block 0xFFFE (Finalize): u32 byte sum of the decoded bytes from offset 12 up to the start of
///   the Finalize block. Block 0xFFFF terminates with length 0.
///
/// The writer is template based: start from a real PSE-saved file (`standardTemplate()` embeds
/// TESTCURVE.pf2) and change only caption, sliders, the LAB luminance curve and colour points.
/// The 3x20 matrices are constant across all observed files and are never touched.
public struct PictureStyleFile: Equatable, Sendable {
    public struct Block: Equatable, Sendable {
        public var tag: UInt16
        public var type: UInt16
        public var data: Data
    }

    public enum Tag {
        public static let caption: UInt16 = 0x1002
        public static let workData: UInt16 = 0x1008
        public static let baseStyle: UInt16 = 0x1009
        /// 0x100D, 5 bytes `55 44 20 00 xx`; meaning unknown. PSE wrote xx = 01 in PosFilmRR2.pf2 and 00 in the
        /// other files; Canon's converter carries it into record +0x45 (0x9F vs 0x9E).
        public static let editorState: UInt16 = 0x100D
        public static let labGamma: UInt16 = 0x1019
        public static let matrixSRGB: UInt16 = 0x1021
        public static let partialInfoSRGB: UInt16 = 0x1023
        public static let matrixAdobeRGB: UInt16 = 0x1029
        public static let partialInfoAdobeRGB: UInt16 = 0x102B
        public static let finalize: UInt16 = 0xFFFE
        public static let terminator: UInt16 = 0xFFFF
    }

    public enum Slider: UInt16, CaseIterable, Sendable {
        case sharpness = 0x1030, contrast = 0x1031, saturation = 0x1032, colourTone = 0x1033

        /// 450D in-camera ranges. (PSE 1.33.10's sharpness slider runs 0–10 for newer bodies.)
        public var range: ClosedRange<Int> { self == .sharpness ? 0...7 : -4...4 }
    }

    public static let headerSize = 12
    public static let standardBase: UInt16 = 0x0081
    public static let captionBlockSize = 32
    /// LAB Gamma (0x1019) is three 100-byte channels (L*, a*, b*), each `u32 count` + 12 `(u32 in, u32 out)`.
    public static let labChannelSize = 100
    /// 12 pairs per channel: PSE's "up to 10 adjustment points" plus the two endpoints.
    public static let maxCurvePoints = 12
    /// PSE allows 100 colour points; the 450D's capacity is unknown and 3 are camera-proven.
    /// 10 is a conservative cap until a camera test with more points is run.
    public static let maxColourPoints = 10
    /// Specific Colors shift sliders in PSE 1.33.10 (`English.lproj/MainMenu.nib`, the pane holding the
    /// luminance curve): H −90…+90, S −100…+100, L −100…+100. Camera-proven magnitudes so far:
    /// |dH| ≤ 27, |dS| ≤ 30, |dL| ≤ 1.
    public static let hueShiftRange = -90...90
    public static let saturationShiftRange = -100...100
    public static let luminosityShiftRange = -100...100

    public private(set) var header: Data
    /// Stored blocks. The Finalize data and the header length are recomputed by `decoded()`, so
    /// they may be stale here after an edit; equality therefore compares decoded bytes.
    public private(set) var blocks: [Block]

    public static func == (lhs: PictureStyleFile, rhs: PictureStyleFile) -> Bool { lhs.decoded() == rhs.decoded() }

    // MARK: Parse / encode

    /// Parses an obfuscated `.pf2` exactly as stored on disk.
    public init(encoded: Data) throws {
        try self.init(decoded: Self.xor(encoded))
    }

    /// Parses decoded bytes. Rejects bad magic, length mismatch, trailing data and a wrong checksum.
    public init(decoded: Data) throws {
        let bytes = [UInt8](decoded)
        guard bytes.count >= Self.headerSize, bytes[4..<8] == [0x50, 0x53, 0x50, 0x00] else {
            throw ProfileError.invalid("Not a Picture Style file (missing PSP header)")
        }
        guard Self.u32(bytes, 8) == UInt32(bytes.count - Self.headerSize) else {
            throw ProfileError.invalid("Picture Style header length does not match the file")
        }
        var blocks: [Block] = []
        var position = Self.headerSize
        var finalizeOffset: Int?
        while position < bytes.count {
            guard position + 8 <= bytes.count else { throw ProfileError.invalid("Truncated Picture Style block header") }
            let tag = UInt16(bytes[position]) << 8 | UInt16(bytes[position + 1])
            let type = UInt16(bytes[position + 2]) << 8 | UInt16(bytes[position + 3])
            let length = Int(Self.u32(bytes, position + 4))
            guard length <= bytes.count - position - 8 else { throw ProfileError.invalid("Truncated Picture Style block \(Self.hex(tag))") }
            guard !blocks.contains(where: { $0.tag == tag }) else { throw ProfileError.invalid("Duplicate Picture Style block \(Self.hex(tag))") }
            if tag == Tag.finalize { finalizeOffset = position }
            blocks.append(Block(tag: tag, type: type, data: Data(bytes[(position + 8)..<(position + 8 + length)])))
            position += 8 + length
            if tag == Tag.terminator { break }
        }
        guard position == bytes.count, blocks.last?.tag == Tag.terminator, blocks.last?.data.isEmpty == true else {
            throw ProfileError.invalid("Picture Style file does not end with an empty terminator block")
        }
        guard let finalizeOffset, blocks.count >= 2, blocks[blocks.count - 2].tag == Tag.finalize,
              blocks[blocks.count - 2].data.count == 4 else {
            throw ProfileError.invalid("Picture Style Finalize block missing or misplaced")
        }
        let sum = bytes[Self.headerSize..<finalizeOffset].reduce(UInt32(0)) { $0 &+ UInt32($1) }
        guard Self.u32(bytes, finalizeOffset + 8) == sum else {
            throw ProfileError.invalid("Picture Style Finalize checksum mismatch")
        }
        header = Data(bytes[0..<Self.headerSize])
        self.blocks = blocks
    }

    /// The embedded PSE-saved Standard template (TESTCURVE.pf2, unchanged).
    public static func standardTemplate() -> PictureStyleFile {
        // The embedded bytes are pinned by PictureStyleChecks against the real file; failure is a build defect.
        try! PictureStyleFile(decoded: Data(PictureStyleConstants.standardTemplateDecoded))
    }

    /// A neutral Standard style: Canon defaults (sharpness 3, others 0), identity L* curve, no colour points.
    public static func newStandard(caption: String) throws -> PictureStyleFile {
        var file = standardTemplate()
        try file.setCaption(caption)
        for slider in Slider.allCases { try file.setSlider(slider, slider == .sharpness ? 3 : 0) }
        try file.setLuminanceCurve([CurvePoint(input: 0, output: 0), CurvePoint(input: 255, output: 255)])
        try file.setColourPoints([])
        return file
    }

    /// Decoded bytes with the header length and Finalize checksum recomputed.
    public func decoded() -> Data {
        var body: [UInt8] = []
        for block in blocks {
            var data = [UInt8](block.data)
            if block.tag == Tag.finalize {
                data = Self.be32(body.reduce(UInt32(0)) { $0 &+ UInt32($1) })
            }
            body += [UInt8(block.tag >> 8), UInt8(block.tag & 0xFF), UInt8(block.type >> 8), UInt8(block.type & 0xFF)]
            body += Self.be32(UInt32(data.count)) + data
        }
        return Data([UInt8](header[header.startIndex..<header.startIndex + 8]) + Self.be32(UInt32(body.count)) + body)
    }

    /// Bytes ready to save as `.pf2`.
    public func encoded() -> Data { Self.xor(decoded()) }

    /// Applies (and removes) the obfuscation layer; the 12-byte header is left plain.
    public static func xor(_ data: Data) -> Data {
        var bytes = [UInt8](data)
        let key1 = PictureStyleConstants.key1, key2 = PictureStyleConstants.key2
        var index = headerSize
        while index < bytes.count {
            bytes[index] ^= key1[index % 512] ^ key2[index % 513] ^ 0x37
            index += 1
        }
        return Data(bytes)
    }

    // MARK: Fields

    public func blockData(_ tag: UInt16) throws -> Data {
        guard let block = blocks.first(where: { $0.tag == tag }) else {
            throw ProfileError.invalid("Picture Style block \(Self.hex(tag)) is missing")
        }
        return block.data
    }

    private mutating func replace(_ tag: UInt16, with data: [UInt8]) throws {
        guard let index = blocks.firstIndex(where: { $0.tag == tag }) else {
            throw ProfileError.invalid("Picture Style block \(Self.hex(tag)) is missing")
        }
        blocks[index].data = Data(data)
    }

    public var baseStyle: UInt16 {
        get throws {
            let data = [UInt8](try blockData(Tag.baseStyle))
            guard data.count == 2 else { throw ProfileError.invalid("Base style block has an unexpected size") }
            return UInt16(data[0]) << 8 | UInt16(data[1])
        }
    }

    public var caption: String {
        get throws {
            let data = [UInt8](try blockData(Tag.caption))
            return String(decoding: data.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    /// Printable ASCII, 1–31 bytes, NUL padded to the template's 32-byte block.
    public mutating func setCaption(_ text: String) throws {
        let raw = [UInt8](text.utf8)
        let size = try blockData(Tag.caption).count
        guard size == Self.captionBlockSize else { throw ProfileError.invalid("Caption block has an unexpected size") }
        guard !raw.isEmpty, raw.count < size, raw.allSatisfy({ (0x20...0x7E).contains($0) }) else {
            throw ProfileError.invalid("Caption must be 1–\(size - 1) printable ASCII characters")
        }
        try replace(Tag.caption, with: raw + [UInt8](repeating: 0, count: size - raw.count))
    }

    /// Copies block 0x100D from a PSE-saved file verbatim (same length as the template's block).
    public mutating func setEditorState(_ data: Data) throws {
        guard data.count == (try blockData(Tag.editorState)).count else { throw ProfileError.invalid("Block 0x100D has an unexpected size") }
        try replace(Tag.editorState, with: [UInt8](data))
    }

    public func slider(_ slider: Slider) throws -> Int {
        let data = [UInt8](try blockData(slider.rawValue))
        guard data.count == 4 else { throw ProfileError.invalid("Slider block has an unexpected size") }
        return Int(Int32(bitPattern: Self.u32(data, 0)))
    }

    public mutating func setSlider(_ slider: Slider, _ value: Int) throws {
        guard slider.range.contains(value) else {
            throw ProfileError.invalid("\(slider) \(value) is outside \(slider.range)")
        }
        try requireStandardBase()
        try replace(slider.rawValue, with: Self.be32(UInt32(bitPattern: Int32(value))))
    }

    private func requireStandardBase() throws {
        guard try baseStyle == Self.standardBase else {
            throw ProfileError.invalid("Only Standard-based (0x0081) Picture Style files are written")
        }
    }

    // MARK: LAB luminance curve

    public struct CurvePoint: Equatable, Sendable {
        public var input: Int
        public var output: Int
        public init(input: Int, output: Int) { self.input = input; self.output = output }
    }

    public enum LabChannel: Int, CaseIterable, Sendable { case lightness = 0, a = 1, b = 2 }

    /// How `setLuminanceCurve` treats the a* and b* channels that follow L* in block 0x1019.
    public enum CurveLayout: Sendable {
        /// Picture Style Editor layout: only the L* channel changes; a*/b* keep their identity curves.
        case editor
        /// `pf2.py` as of 24 Nov 2026: the whole 300-byte block is rewritten with zeros after the L* points,
        /// which leaves a*/b* with count 0. GENTEST1 was made this way and worked in camera. Use only to
        /// reproduce that file; new files should use `.editor`.
        case stage1PythonZeroFill
    }

    public func labCurve(_ channel: LabChannel = .lightness) throws -> [CurvePoint] {
        let data = [UInt8](try blockData(Tag.labGamma))
        guard data.count == 3 * Self.labChannelSize else { throw ProfileError.invalid("LAB Gamma block has an unexpected size") }
        let base = channel.rawValue * Self.labChannelSize
        let count = Int(Self.u32(data, base))
        guard count <= Self.maxCurvePoints else { throw ProfileError.invalid("LAB Gamma channel has too many points") }
        return (0..<count).map {
            CurvePoint(input: Int(Self.u32(data, base + 4 + 8 * $0)), output: Int(Self.u32(data, base + 8 + 8 * $0)))
        }
    }

    /// 2–12 points, inputs strictly increasing from 0 to 255, outputs 0–255.
    public mutating func setLuminanceCurve(_ points: [CurvePoint], layout: CurveLayout = .editor) throws {
        guard (2...Self.maxCurvePoints).contains(points.count) else {
            throw ProfileError.invalid("Luminance curve needs 2–\(Self.maxCurvePoints) points")
        }
        guard points.first?.input == 0, points.last?.input == 255 else {
            throw ProfileError.invalid("Luminance curve must start at input 0 and end at input 255")
        }
        guard zip(points, points.dropFirst()).allSatisfy({ $0.input < $1.input }) else {
            throw ProfileError.invalid("Luminance curve inputs must be strictly increasing")
        }
        guard points.allSatisfy({ (0...255).contains($0.output) }) else {
            throw ProfileError.invalid("Luminance curve outputs must be 0–255")
        }
        try requireStandardBase()
        var data = [UInt8](try blockData(Tag.labGamma))
        guard data.count == 3 * Self.labChannelSize else { throw ProfileError.invalid("LAB Gamma block has an unexpected size") }
        var channel = Self.be32(UInt32(points.count))
        for point in points { channel += Self.be32(UInt32(point.input)) + Self.be32(UInt32(point.output)) }
        switch layout {
        case .editor:
            channel += [UInt8](repeating: 0, count: Self.labChannelSize - channel.count)
            data.replaceSubrange(0..<Self.labChannelSize, with: channel)
        case .stage1PythonZeroFill:
            data = channel + [UInt8](repeating: 0, count: data.count - channel.count)
        }
        try replace(Tag.labGamma, with: data)
    }

    // MARK: Colour points (Specific Colors, Partial Info 0x1023 sRGB / 0x102B AdobeRGB)

    /// One Partial Info record. The file stores it as 17 big-endian i32:
    /// `[4, 0, H, S, L, 1, Hlo, Slo, Llo, 2, Hhi, Shi, Lhi, 3, dH, dS, dL]` — four tagged triples
    /// (0 centre, 1 lower bound, 2 upper bound, 3 shift) preceded by their count.
    public struct ColourRecord: Equatable, Sendable {
        public var hue: Int, saturation: Int, luminosity: Int
        public var hueLow: Int, saturationLow: Int, luminosityLow: Int
        public var hueHigh: Int, saturationHigh: Int, luminosityHigh: Int
        public var hueShift: Int, saturationShift: Int, luminosityShift: Int

        public init(hue: Int, saturation: Int, luminosity: Int,
                    hueLow: Int, saturationLow: Int = 0, luminosityLow: Int = 0,
                    hueHigh: Int, saturationHigh: Int = 100, luminosityHigh: Int = 100,
                    hueShift: Int = 0, saturationShift: Int = 0, luminosityShift: Int = 0) {
            self.hue = hue; self.saturation = saturation; self.luminosity = luminosity
            self.hueLow = hueLow; self.saturationLow = saturationLow; self.luminosityLow = luminosityLow
            self.hueHigh = hueHigh; self.saturationHigh = saturationHigh; self.luminosityHigh = luminosityHigh
            self.hueShift = hueShift; self.saturationShift = saturationShift; self.luminosityShift = luminosityShift
        }

        var values: [Int] {
            [4, 0, hue, saturation, luminosity, 1, hueLow, saturationLow, luminosityLow,
             2, hueHigh, saturationHigh, luminosityHigh, 3, hueShift, saturationShift, luminosityShift]
        }

        init(values v: [Int]) throws {
            guard v.count == 17, v[0] == 4, v[1] == 0, v[5] == 1, v[9] == 2, v[13] == 3 else {
                throw ProfileError.invalid("Partial Info record has an unknown layout")
            }
            self.init(hue: v[2], saturation: v[3], luminosity: v[4], hueLow: v[6], saturationLow: v[7], luminosityLow: v[8],
                      hueHigh: v[10], saturationHigh: v[11], luminosityHigh: v[12],
                      hueShift: v[14], saturationShift: v[15], luminosityShift: v[16])
        }

        /// `editorRanges`: the sRGB record is what PSE edits directly, so its range widths must be within
        /// PSE's documented 30–180° / 30–100 / 30–100. The AdobeRGB copy is PSE's colour-space conversion and
        /// is narrower or uncentred in real files (e.g. S 0…62), so only ordering and bounds are checked.
        func validate(editorRanges: Bool) throws {
            func ordered(_ low: Int, _ centre: Int, _ high: Int, _ bound: ClosedRange<Int>, _ width: ClosedRange<Int>, _ name: String) throws {
                guard bound.contains(low), bound.contains(high), low <= centre, centre <= high else {
                    throw ProfileError.invalid("Colour point \(name) range \(low)…\(high) must contain \(centre) within \(bound)")
                }
                guard (editorRanges ? width : 0...width.upperBound).contains(high - low) else {
                    throw ProfileError.invalid("Colour point \(name) range width \(high - low) is outside \(width)")
                }
            }
            guard (0...359).contains(hue), (0...100).contains(saturation), (0...100).contains(luminosity) else {
                throw ProfileError.invalid("Colour point centre must be H 0–359, S 0–100, L 0–100")
            }
            // Hue ranges that wrap past 0°/360° have not been observed; their encoding is unknown, so they are refused.
            try ordered(hueLow, hue, hueHigh, 0...359, 30...180, "hue")
            try ordered(saturationLow, saturation, saturationHigh, 0...100, 30...100, "saturation")
            try ordered(luminosityLow, luminosity, luminosityHigh, 0...100, 30...100, "luminosity")
            guard PictureStyleFile.hueShiftRange.contains(hueShift),
                  PictureStyleFile.saturationShiftRange.contains(saturationShift),
                  PictureStyleFile.luminosityShiftRange.contains(luminosityShift) else {
                throw ProfileError.invalid("Colour point shift must be H ±90, S ±100, L ±100")
            }
        }
    }

    /// A colour point as PSE stores it: one record per colour space. PSE derives the AdobeRGB record from the
    /// sRGB one with a conversion that is not reproduced here (H and S differ, L is equal in every observed
    /// file), so callers supply both.
    public struct ColourPoint: Equatable, Sendable {
        public var sRGB: ColourRecord
        public var adobeRGB: ColourRecord
        public init(sRGB: ColourRecord, adobeRGB: ColourRecord) { self.sRGB = sRGB; self.adobeRGB = adobeRGB }
    }

    /// What `setColourPoints` does with block 0x1008 (PSE work data).
    public enum WorkDataPolicy: Sendable {
        /// Rewrite it from the sRGB records, as PSE does (formula reproduces all four PSE files byte for byte).
        case regenerate
        /// Leave it as in the template. GENTEST2 did this and worked in camera; needed to reproduce it.
        case leaveUnchanged
    }

    public func colourPoints() throws -> [ColourPoint] {
        let sRGB = try records(Tag.partialInfoSRGB), adobe = try records(Tag.partialInfoAdobeRGB)
        guard sRGB.count == adobe.count else { throw ProfileError.invalid("sRGB and AdobeRGB colour point counts differ") }
        return zip(sRGB, adobe).map { ColourPoint(sRGB: $0, adobeRGB: $1) }
    }

    private func records(_ tag: UInt16) throws -> [ColourRecord] {
        let data = [UInt8](try blockData(tag))
        guard data.count % 4 == 0, data.count >= 8 else { throw ProfileError.invalid("Partial Info block has an unexpected size") }
        let values = stride(from: 0, to: data.count, by: 4).map { Int(Int32(bitPattern: Self.u32(data, $0))) }
        let count = values[1]
        if count == 0 {
            guard values.allSatisfy({ $0 == 0 }) else { throw ProfileError.invalid("Empty Partial Info block has unknown content") }
            return []
        }
        // values[0] is 0 in every observed file; its meaning is unknown, so anything else is refused.
        guard values[0] == 0, count > 0, values.count == 2 + 17 * count else {
            throw ProfileError.invalid("Partial Info block has an unknown layout")
        }
        return try (0..<count).map { try ColourRecord(values: Array(values[(2 + 17 * $0)..<(19 + 17 * $0)])) }
    }

    public mutating func setColourPoints(_ points: [ColourPoint], workData: WorkDataPolicy = .regenerate) throws {
        guard points.count <= Self.maxColourPoints else {
            throw ProfileError.invalid("At most \(Self.maxColourPoints) colour points are written")
        }
        for point in points {
            try point.sRGB.validate(editorRanges: true)
            try point.adobeRGB.validate(editorRanges: false)
        }
        try requireStandardBase()
        if workData == .regenerate {
            let old = [UInt8](try blockData(Tag.workData))
            // Only the one observed Wk Data layout is rewritten: [0x00100004, 4 + 60n, n, …, -1, 0].
            guard old.count >= 20, Self.u32(old, 0) == 0x0010_0004,
                  Int(Self.u32(old, 4)) == old.count - 16, old.suffix(8) == [0xFF, 0xFF, 0xFF, 0xFF, 0, 0, 0, 0] else {
                throw ProfileError.invalid("Work data block has an unknown layout")
            }
            var values: [Int32] = [0x0010_0004, Int32(4 + 60 * points.count), Int32(points.count)]
            for point in points {
                let r = point.sRGB
                values += [1, 1, 1] + [r.hue, r.saturation, r.luminosity, r.hueLow, r.saturationLow, r.luminosityLow,
                                       r.hueHigh, r.saturationHigh, r.luminosityHigh,
                                       r.hueShift, r.saturationShift, r.luminosityShift].map { Int32($0) * 65536 }
            }
            values += [-1, 0]
            try replace(Tag.workData, with: values.flatMap { Self.be32(UInt32(bitPattern: $0)) })
        }
        try replace(Tag.partialInfoSRGB, with: Self.partialInfo(points.map(\.sRGB)))
        try replace(Tag.partialInfoAdobeRGB, with: Self.partialInfo(points.map(\.adobeRGB)))
    }

    private static func partialInfo(_ records: [ColourRecord]) -> [UInt8] {
        // PSE writes an empty block as 28 zero bytes (seven i32), not as an 8-byte header.
        let values = records.isEmpty ? [Int](repeating: 0, count: 7) : [0, records.count] + records.flatMap(\.values)
        return values.flatMap { be32(UInt32(bitPattern: Int32($0))) }
    }

    // MARK: Byte helpers

    private static func u32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16 | UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3])
    }

    private static func be32(_ value: UInt32) -> [UInt8] {
        [UInt8(value >> 24), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
    }

    private static func hex(_ tag: UInt16) -> String { "0x" + String(tag, radix: 16, uppercase: true) }
}
