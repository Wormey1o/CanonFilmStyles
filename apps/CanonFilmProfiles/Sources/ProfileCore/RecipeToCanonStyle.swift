import Foundation

/// Ricoh GR IIIx recipe → what the EOS 450D needs in one User Def. slot (execution plan
/// `01_Plans/CANON_RecipeToPictureStyle_ExecutionPlan_v1.md`, stage 4).
///
/// A slot is either a registered Picture Style (Standard base 0x81 + four sliders + L* curve + colour
/// points, written as a `.pf2` and compiled by Canon's converter) or Canon's built-in Monochrome (base
/// 0x86 with a slider/filter/toning row). White balance is camera-wide on the 450D and is set by hand,
/// so every plan carries a WB instruction for the photographer.
///
/// Two model sources sit behind `RecipeToCanonStyleModel`: `InterimRules` (hand-tuned, uncalibrated)
/// and `CalibrationModel` (a port of `fit_model.py predict()` reading `calibration_model.json`).
public protocol RecipeToCanonStyleModel: Sendable {
    var source: CanonStyleModelSource { get }
    /// - Parameter slot: User Def. 1–3.
    func plan(for recipe: RicohRecipeSnapshot, slot: Int) throws -> CanonSlotPlan
}

public struct CanonStyleModelSource: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case interim, calibration }
    public var kind: Kind
    public var name: String
    public var version: String
    /// One-line confidence statement shown with every plan from this source.
    public var confidence: String
    public init(kind: Kind, name: String, version: String, confidence: String) {
        self.kind = kind; self.name = name; self.version = version; self.confidence = confidence
    }
    public var label: String { "\(name) \(version)" }
}

/// Thrown by a model that does not cover a recipe (e.g. a base the calibration did not measure).
public struct CanonStyleNotCovered: LocalizedError, Sendable {
    public var reason: String
    public init(_ reason: String) { self.reason = reason }
    public var errorDescription: String? { reason }
}

// MARK: - Ricoh source snapshot

/// The Ricoh controls a translation reads, taken from a stored `Recipe`.
public struct RicohRecipeSnapshot: Codable, Equatable, Sendable {
    public static let colourBases = ["Standard", "Vivid", "Positive Film", "Negative Film", "Bleach Bypass", "Retro",
                                     "HDR Tone", "Cross Processing 1", "Cross Processing 2", "Cross Processing 3", "Cinema (Yellow)"]
    public static let monochromeBases = ["Monotone", "Soft Monotone", "Hard Monotone", "Hi-Contrast B&W"]

    public var name: String
    /// Ricoh Image Control name in calibration vocabulary ("Monotone", not the app's "BW Monotone").
    public var base: String
    public var saturation = 0, hue = 0, key = 0, contrast = 0, highlightContrast = 0, shadowContrast = 0
    public var sharpness = 0, clarity = 0, shading = 0
    /// App vocabulary (`RecipeWhiteBalance.modes`), shifts ±14, positive = Amber / Green.
    public var whiteBalance = "Auto"
    public var kelvin: Int?
    public var amberBlue = 0, greenMagenta = 0
    /// Ricoh Filter Effect option number from the card (1–8), when the card gives one.
    public var filterOption: Int?
    /// Signed RGB mix of the filter, when known (card text or the editor's B&W filter).
    public var filterMix: BWFilter?
    public var toningName: MonochromeToning?
    /// Numeric Ricoh toning step (−4…+4) from the card, when given as a number.
    public var toningStep: Int?
    /// Added grain intensity 0–3 (dropped: grain stays at Mac import).
    public var grain = 0

    public var isMonochrome: Bool { Self.monochromeBases.contains(base) }

    public init(name: String, base: String) { self.name = name; self.base = base }

    public init(recipe: Recipe) throws {
        guard recipe.factoryID == nil else {
            throw CanonStyleNotCovered("“\(recipe.name)” is a Canon Film Profiles factory look, not a Ricoh recipe; it has no Canon Picture Style translation.")
        }
        self.init(name: recipe.name, base: recipe.base == "BW Monotone" ? "Monotone" : recipe.base)
        guard Self.colourBases.contains(base) || Self.monochromeBases.contains(base) else {
            throw CanonStyleNotCovered("Image Control “\(recipe.base)” is not known to the Canon style translation.")
        }
        saturation = recipe.saturation; hue = recipe.hue; key = recipe.key; contrast = recipe.contrast
        highlightContrast = recipe.highlights; shadowContrast = recipe.shadows
        sharpness = recipe.sharpness; clarity = recipe.clarity; shading = recipe.shading
        whiteBalance = recipe.whiteBalance; kelvin = recipe.kelvin
        amberBlue = recipe.amberBlue; greenMagenta = recipe.greenMagenta
        grain = recipe.effectiveGrain?.intensity ?? recipe.grain ?? recipe.sourceValue("grain").flatMap(RecipeGrainMapping.approximate) ?? 0
        if isMonochrome {
            let filterText = recipe.bwFilter == nil ? recipe.sourceValue("filterEffect") : nil
            if let text = filterText, let match = text.range(of: #"^\s*([1-8])(?![0-9])"#, options: .regularExpression) {
                filterOption = Int(text[match].trimmingCharacters(in: .whitespaces))
            }
            let mix = recipe.effectiveBWFilter
            filterMix = mix?.enabled == true ? mix : nil
            if recipe.toning == nil, let text = recipe.sourceValue("toning")?.trimmingCharacters(in: .whitespaces),
               let step = Int(text.replacingOccurrences(of: "+", with: "")), (-4...4).contains(step) {
                toningStep = step
            } else {
                toningName = recipe.effectiveToning
            }
        }
    }
}

// MARK: - Slot plan

public struct CanonCurvePoint: Codable, Equatable, Sendable {
    public var input: Int, output: Int
    public init(_ input: Int, _ output: Int) { self.input = input; self.output = output }
}

/// One Specific Colors point (PSE units: hue degrees, saturation/luminosity 0–100; shifts H ±90, S/L ±100).
public struct CanonColourPointPlan: Codable, Equatable, Sendable {
    public var hue: Int, saturation: Int, luminosity: Int
    public var hueLow: Int, hueHigh: Int
    public var hueShift: Int, saturationShift: Int, luminosityShift: Int
    /// AdobeRGB copy written to block 0x102B. `nil` copies the sRGB record (PSE's own conversion is not
    /// reproduced; the hand-made anchors carry the copy PSE saved).
    public var adobeRGB: [Int]?

    public init(hue: Int, saturation: Int, luminosity: Int, hueLow: Int, hueHigh: Int,
                hueShift: Int, saturationShift: Int, luminosityShift: Int, adobeRGB: [Int]? = nil) {
        self.hue = hue; self.saturation = saturation; self.luminosity = luminosity
        self.hueLow = hueLow; self.hueHigh = hueHigh
        self.hueShift = hueShift; self.saturationShift = saturationShift; self.luminosityShift = luminosityShift
        self.adobeRGB = adobeRGB
    }

    /// A point centred on `hue` with PSE's ±range/2 hue window, clipped inside 0…359 (wrapping windows
    /// have not been observed in a PSE file, so their encoding is unknown and never written).
    public static func centred(hue h: Double, saturation s: Double, luminosity l: Double, hueRange: Double,
                               hueShift: Double, saturationShift: Double, luminosityShift: Double) -> CanonColourPointPlan {
        let hue = Int(pyRound(h)) % 360, half = max(15, Int(pyRound(hueRange / 2)))
        var low = hue - half, high = hue + half
        if low < 0 { low = 0; high = max(high, 30) }
        if high > 359 { high = 359; low = min(low, 329) }
        return CanonColourPointPlan(hue: hue, saturation: clamp(Int(pyRound(s)), 0, 100), luminosity: clamp(Int(pyRound(l)), 0, 100),
                                    hueLow: low, hueHigh: high,
                                    hueShift: clamp(Int(pyRound(hueShift)), -90, 90),
                                    saturationShift: clamp(Int(pyRound(saturationShift)), -100, 100),
                                    luminosityShift: clamp(Int(pyRound(luminosityShift)), -100, 100))
    }

    public var sRGBRecord: PictureStyleFile.ColourRecord {
        PictureStyleFile.ColourRecord(hue: hue, saturation: saturation, luminosity: luminosity, hueLow: hueLow, hueHigh: hueHigh,
                                      hueShift: hueShift, saturationShift: saturationShift, luminosityShift: luminosityShift)
    }
    /// `adobeRGB` holds the 12 values `[H, S, L, Hlo, Slo, Llo, Hhi, Shi, Lhi, dH, dS, dL]`.
    public var adobeRGBRecord: PictureStyleFile.ColourRecord {
        guard let v = adobeRGB, v.count == 12 else { return sRGBRecord }
        return PictureStyleFile.ColourRecord(hue: v[0], saturation: v[1], luminosity: v[2], hueLow: v[3], saturationLow: v[4], luminosityLow: v[5],
                                             hueHigh: v[6], saturationHigh: v[7], luminosityHigh: v[8],
                                             hueShift: v[9], saturationShift: v[10], luminosityShift: v[11])
    }
}

/// A Standard-based registered Picture Style (what the `.pf2` holds).
public struct CanonRegisteredStylePlan: Codable, Equatable, Sendable {
    public var caption: String
    public var sharpness: Int, contrast: Int, saturation: Int, colourTone: Int
    public var curve: [CanonCurvePoint]
    public var colourPoints: [CanonColourPointPlan]
    /// Block 0x100D copied from an anchor .pf2 (hex); nil keeps the template's `5544200000`.
    public var editorState: String?

    public init(caption: String, sharpness: Int, contrast: Int, saturation: Int, colourTone: Int,
                curve: [CanonCurvePoint], colourPoints: [CanonColourPointPlan], editorState: String? = nil) {
        self.caption = caption; self.sharpness = sharpness; self.contrast = contrast; self.saturation = saturation
        self.colourTone = colourTone; self.curve = curve; self.colourPoints = colourPoints; self.editorState = editorState
    }

    /// The `.pf2` (Picture Style Editor layout; a*/b* identity curves kept; Wk Data regenerated).
    public func pictureStyleFile() throws -> PictureStyleFile {
        var file = try PictureStyleFile.newStandard(caption: caption)
        try file.setSlider(.sharpness, sharpness)
        try file.setSlider(.contrast, contrast)
        try file.setSlider(.saturation, saturation)
        try file.setSlider(.colourTone, colourTone)
        try file.setLuminanceCurve(curve.map { PictureStyleFile.CurvePoint(input: $0.input, output: $0.output) })
        try file.setColourPoints(colourPoints.map { PictureStyleFile.ColourPoint(sRGB: $0.sRGBRecord, adobeRGB: $0.adobeRGBRecord) })
        if let hex = editorState {
            let bytes = stride(from: 0, to: hex.count, by: 2).compactMap { i -> UInt8? in
                let a = hex.index(hex.startIndex, offsetBy: i); return UInt8(hex[a..<hex.index(a, offsetBy: 2, limitedBy: hex.endIndex)!], radix: 16)
            }
            guard bytes.count * 2 == hex.count else { throw ProfileError.invalid("Block 0x100D hex is malformed") }
            try file.setEditorState(Data(bytes))
        }
        return file
    }
}

/// Canon built-in Monochrome (base 0x86). Encodings are EDSDK EdsFilterEffect / EdsTonigEffect as sent
/// by EOS Utility in the D160 row and confirmed by Canon's MakerNotes in IMG_6659/6660 (Filter Orange).
public struct CanonMonochromePlan: Codable, Equatable, Sendable {
    public enum Filter: Int, Codable, CaseIterable, Sendable {
        case none = 0, yellow = 1, orange = 2, red = 3, green = 4
        public var name: String { ["None", "Yellow", "Orange", "Red", "Green"][rawValue] }
        public init?(name: String) { guard let f = Self.allCases.first(where: { $0.name == name }) else { return nil }; self = f }
    }
    public enum Toning: Int, Codable, CaseIterable, Sendable {
        case none = 0, sepia = 1, blue = 2, purple = 3, green = 4
        public var name: String { ["None", "Sepia", "Blue", "Purple", "Green"][rawValue] }
        public init?(name: String) { guard let t = Self.allCases.first(where: { $0.name == name }) else { return nil }; self = t }
    }
    public static let base: UInt32 = 0x86
    public var contrast: Int, sharpness: Int
    public var filter: Filter, toning: Toning
    public init(contrast: Int, sharpness: Int, filter: Filter, toning: Toning) {
        self.contrast = contrast; self.sharpness = sharpness; self.filter = filter; self.toning = toning
    }
}

/// What to set on the camera by hand (WB is camera-wide on the 450D and MPU-held).
public struct CanonWhiteBalanceInstruction: Codable, Equatable, Sendable {
    public static let presets = ["Auto", "Daylight", "Shade", "Cloudy", "Tungsten", "White fluorescent", "Flash"]
    public var preset: String
    /// Canon WB shift, ±9; positive = A (amber) / G (green).
    public var amberBlue: Int, greenMagenta: Int
    public var note: String?
    /// false: the CFPSTYLE.BIN WB block leaves the camera's WB alone for this slot (flags 0).
    public var applyOnSlotSelect: Bool
    public init(preset: String, amberBlue: Int, greenMagenta: Int, note: String? = nil, applyOnSlotSelect: Bool = true) {
        self.preset = preset; self.amberBlue = amberBlue; self.greenMagenta = greenMagenta; self.note = note
        self.applyOnSlotSelect = applyOnSlotSelect
    }
    public var shiftText: String {
        (amberBlue >= 0 ? "A\(amberBlue)" : "B\(-amberBlue)") + " " + (greenMagenta >= 0 ? "G\(greenMagenta)" : "M\(-greenMagenta)")
    }
    public var summary: String { "\(preset), shift \(shiftText)" }
}

public struct CanonSlotPlan: Codable, Equatable, Sendable {
    /// User Def. 1–3.
    public var slot: Int
    public var recipeName: String
    public var source: CanonStyleModelSource
    public var registered: CanonRegisteredStylePlan?
    public var monochrome: CanonMonochromePlan?
    public var whiteBalance: CanonWhiteBalanceInstruction
    /// Ricoh controls with no Canon carrier.
    public var dropped: [String]
    /// Controls carried only approximately, or assumptions this plan rests on.
    public var approximated: [String]
    public var notes: [String]

    public init(slot: Int, recipeName: String, source: CanonStyleModelSource, registered: CanonRegisteredStylePlan?,
                monochrome: CanonMonochromePlan?, whiteBalance: CanonWhiteBalanceInstruction,
                dropped: [String] = [], approximated: [String] = [], notes: [String] = []) {
        self.slot = slot; self.recipeName = recipeName; self.source = source; self.registered = registered
        self.monochrome = monochrome; self.whiteBalance = whiteBalance
        self.dropped = dropped; self.approximated = approximated; self.notes = notes
    }

    public var isRegistered: Bool { registered != nil }
    /// Camera slot base: PC n = 0x41–0x43 for a registered style, 0x86 for Monochrome.
    public var cameraBase: UInt32 { registered != nil ? 0x40 + UInt32(slot) : CanonMonochromePlan.base }
    /// The six-value UD row (contrast, sharpness, saturation, colour tone, filter, toning).
    public var row: [Int32] {
        if let r = registered { return [r.contrast, r.sharpness, r.saturation, r.colourTone, 0, 0].map(Int32.init) }
        let m = monochrome!
        return [m.contrast, m.sharpness, 0, 0, m.filter.rawValue, m.toning.rawValue].map(Int32.init)
    }

    /// Structural checks against the 450D/PSE limits. Every model's output passes through this.
    public func validate() throws {
        func fail(_ s: String) -> ProfileError { .invalid("Slot plan for “\(recipeName)”: \(s)") }
        guard (1...3).contains(slot) else { throw fail("slot must be User Def. 1–3") }
        guard (registered == nil) != (monochrome == nil) else { throw fail("must be exactly one of registered style or Monochrome") }
        if let r = registered {
            guard (0...7).contains(r.sharpness), (-4...4).contains(r.contrast), (-4...4).contains(r.saturation), (-4...4).contains(r.colourTone) else {
                throw fail("sliders outside the 450D ranges")
            }
            guard r.curve.count >= 2, r.curve.count <= PictureStyleFile.maxCurvePoints else { throw fail("curve must have 2–12 points (≤10 user points)") }
            guard r.colourPoints.count <= PictureStyleFile.maxColourPoints else { throw fail("at most \(PictureStyleFile.maxColourPoints) colour points") }
            _ = try r.pictureStyleFile()   // runs every PictureStyleFile range check
        }
        if let m = monochrome {
            guard (-4...4).contains(m.contrast), (0...7).contains(m.sharpness) else { throw fail("Monochrome sliders outside the 450D ranges") }
        }
        guard CanonWhiteBalanceInstruction.presets.contains(whiteBalance.preset),
              (-9...9).contains(whiteBalance.amberBlue), (-9...9).contains(whiteBalance.greenMagenta) else {
            throw fail("WB instruction outside the 450D presets or ±9 shift")
        }
    }

    /// Human-readable lines for SLOTS.txt and the UI. `cameraSetsWB`: a CFPSTYLE.BIN WB block is written.
    public var descriptionLines: [String] { descriptionLines(cameraSetsWB: false) }
    public func descriptionLines(cameraSetsWB: Bool) -> [String] {
        var lines: [String] = []
        if let r = registered {
            lines.append("Registered Picture Style “\(r.caption)”, base Standard (camera slot base PC \(slot) = 0x\(String(cameraBase, radix: 16)))")
            lines.append("Sliders: sharpness \(r.sharpness), contrast \(signed(r.contrast)), saturation \(signed(r.saturation)), colour tone \(signed(r.colourTone))")
            lines.append("L* curve: " + r.curve.map { "\($0.input)→\($0.output)" }.joined(separator: ", "))
            if r.colourPoints.isEmpty { lines.append("Colour points: none") }
            for p in r.colourPoints {
                lines.append("Colour point H\(p.hue) S\(p.saturation) L\(p.luminosity) (hue \(p.hueLow)…\(p.hueHigh)): shift H\(signed(p.hueShift)) S\(signed(p.saturationShift)) L\(signed(p.luminosityShift))")
            }
        } else if let m = monochrome {
            lines.append("Canon built-in Monochrome (base 0x86): contrast \(signed(m.contrast)), sharpness \(m.sharpness), filter \(m.filter.name), toning \(m.toning.name)")
        }
        let how: String
        if !whiteBalance.applyOnSlotSelect { how = cameraSetsWB ? "left as it is (WB block flags 0); recipe value, if wanted, set by hand" : "not needed for this recipe; recipe value, if wanted, set by hand" }
        else { how = cameraSetsWB ? "set by camera on slot select (if payload supports it), otherwise set by hand" : "set by hand on the camera" }
        lines.append("White balance — \(how): \(whiteBalance.summary)" + (whiteBalance.note.map { " (\($0))" } ?? ""))
        lines.append("Model: \(source.label) — \(source.confidence)")
        if !dropped.isEmpty { lines.append("Dropped (no Canon equivalent): " + dropped.joined(separator: "; ")) }
        if !approximated.isEmpty { lines.append("Approximated: " + approximated.joined(separator: "; ")) }
        lines += notes.map { "Note: " + $0 }
        return lines
    }
}

// MARK: - Entry point

public enum RecipeToCanonStyle {
    /// Plans one slot. The app uses the calibrated model for covered colour recipes.
    /// Monochrome uses the interim mapping because the fit only models Canon contrast.
    /// Research callers can exercise the measured monochrome model through CalibrationModel.plan.
    public static func plan(recipe: Recipe, slot: Int, calibration: CalibrationModel? = nil) throws -> CanonSlotPlan {
        let snapshot = try RicohRecipeSnapshot(recipe: recipe)
        var plan: CanonSlotPlan
        if let calibration, snapshot.isMonochrome {
            plan = try InterimRules().plan(for: snapshot, slot: slot)
            plan.notes.insert("Monochrome uses the interim mapping: calibration model \(calibration.source.version) fits monochrome with the Canon contrast slider only (weak fit).", at: 0)
        } else if let calibration {
            do { plan = try calibration.plan(for: snapshot, slot: slot) }
            catch let gap as CanonStyleNotCovered {
                plan = try InterimRules().plan(for: snapshot, slot: slot)
                plan.notes.insert("Calibration model \(calibration.source.version) does not cover this recipe (\(gap.reason)); interim rules used.", at: 0)
            }
        } else {
            plan = try InterimRules().plan(for: snapshot, slot: slot)
        }
        applyWBPolicy(&plan, snapshot)
        try plan.validate()
        return plan
    }

    /// Which slots set WB on slot select. Monochrome recipes whose card WB is automatic with no shift leave the
    /// camera WB alone (Canon Monochrome output depends little on WB and the card asks for nothing specific);
    /// every other recipe sets its WB.
    public static func applyWBPolicy(_ plan: inout CanonSlotPlan, _ r: RicohRecipeSnapshot) {
        let automatic = ["Auto", "Auto (Warmth Priority)", "Auto (White Priority)", "Multi Auto"].contains(r.whiteBalance)
        if r.isMonochrome && automatic && r.amberBlue == 0 && r.greenMagenta == 0 {
            plan.whiteBalance.applyOnSlotSelect = false
            plan.notes.append("Monochrome with automatic WB and no shift: the camera's WB is left as it is (WB block flags 0)")
        }
    }

    /// PSE caption from a recipe name: printable ASCII, 1–31 bytes.
    public static func caption(for name: String, slot: Int) -> String {
        let ascii = String(name.unicodeScalars.filter { (0x20...0x7E).contains($0.value) }.map(Character.init))
            .trimmingCharacters(in: .whitespaces)
        return ascii.isEmpty ? "UserDef\(slot)" : String(ascii.prefix(31))
    }

    /// Controls every model drops (spatial or Mac-side).
    static func dropped(_ r: RicohRecipeSnapshot) -> [String] {
        var out: [String] = []
        if r.clarity != 0 { out.append("clarity \(signed(r.clarity)) (spatial)") }
        if r.shading != 0 { out.append("shading \(signed(r.shading)) (spatial)") }
        if r.grain != 0 { out.append("grain (added at Mac import)") }
        if r.base == "HDR Tone" { out.append("HDR Tone local contrast") }
        return out
    }
}

// MARK: - Shared numeric helpers

/// Python 3 `round(x)` (ties to even).
@inline(__always) func pyRound(_ x: Double) -> Double { x.rounded(.toNearestOrEven) }
/// Python 3 `round(x, n)`: correctly rounded on the exact binary value, like `"%.nf"`.
func pyRound(_ x: Double, _ digits: Int) -> Double {
    guard x.isFinite else { return x }
    return Double(String(format: "%.\(digits)f", x))!
}
@inline(__always) func clamp(_ v: Int, _ lo: Int, _ hi: Int) -> Int { max(lo, min(hi, v)) }
func signed(_ v: Int) -> String { v > 0 ? "+\(v)" : "\(v)" }
