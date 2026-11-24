import Foundation

/// INTERIM translation rules, used until the stage-3 calibration model exists. Not calibrated.
///
/// Derived from (24 Nov 2026, experiments/film-native-picture-style-route-v1):
/// - `fit/RECIPE_FIT_v1.md` and NOTES.md: two hand-tuned styles fitted to GR IIIx frames on four
///   scenes. `styles/Portra160.pf2` (Negative Film anchor; sha256 3e03f3d2…0d0a) and
///   `styles/PosFilmRR2.pf2` (Positive Film anchor; b90090a2…408f), read with `pf2.py show`.
/// - The IAC Tri-X mapping installed in UD3 and confirmed by Canon's MakerNotes (IMG_6659/6660):
///   Monochrome, filter Orange, contrast +2, sharpness 2.
///
/// A recipe on an anchored base gets the anchor's style plus slider deltas from the anchor recipe; other
/// bases start from Canon Standard with rule-of-thumb offsets. Confidence: moderate for the anchors
/// themselves (direction checked against GR frames, magnitude low), low for every delta rule and for
/// unanchored bases.
public struct InterimRules: RecipeToCanonStyleModel {
    public static let version = "v2 (25 Nov 2026)"
    public let source = CanonStyleModelSource(kind: .interim, name: "Interim rules", version: version,
                                              confidence: "INTERIM, not calibrated: hand-tuned on four scenes; moderate for anchored looks, low for slider deltas and other bases")
    public init() {}

    // MARK: Anchors

    /// A hand-made style and the Ricoh recipe it was fitted to.
    public struct Anchor: Sendable {
        public var base: String
        public var label: String
        public var recipe: RicohRecipeSnapshot
        public var style: CanonRegisteredStylePlan
        /// Canon WB shift added to the scaled Ricoh shift for this base (reproduces the anchor's hand WB).
        public var tint: (ab: Int, gm: Int)
        public var confidence: String
        public var assumptions: [String]
    }

    public static let anchors: [Anchor] = [portra160, posFilmRR2]

    /// Portra 160 (Chrizz Ocampo; `Recipe.portra160`) → styles/Portra160.pf2. Camera WB Shade A2 G0.
    public static let portra160: Anchor = {
        var r = RicohRecipeSnapshot(name: "Portra 160", base: "Negative Film")
        r.saturation = 3; r.hue = -1; r.key = 3; r.contrast = -1; r.highlightContrast = 2; r.shadowContrast = -3
        r.clarity = -4; r.whiteBalance = "Shade"; r.amberBlue = 3; r.greenMagenta = 3
        let style = CanonRegisteredStylePlan(
            caption: "Portra160", sharpness: 2, contrast: -1, saturation: 2, colourTone: 0,
            curve: [.init(0, 0), .init(64, 92), .init(128, 146), .init(129, 147), .init(190, 206), .init(255, 255)],
            colourPoints: [
                .init(hue: 42, saturation: 22, luminosity: 51, hueLow: 12, hueHigh: 72, hueShift: 8, saturationShift: 12, luminosityShift: 0,
                      adobeRGB: [53, 16, 51, 15, 0, 0, 81, 86, 100, 9, 10, 0]),
                .init(hue: 81, saturation: 21, luminosity: 27, hueLow: 51, hueHigh: 111, hueShift: -11, saturationShift: 8, luminosityShift: 0,
                      adobeRGB: [90, 20, 27, 63, 0, 0, 113, 86, 100, -10, 8, 0]),
                .init(hue: 150, saturation: 17, luminosity: 31, hueLow: 120, hueHigh: 180, hueShift: -27, saturationShift: 8, luminosityShift: 0,
                      adobeRGB: [145, 14, 31, 120, 0, 0, 180, 62, 100, -23, 10, 0]),
            ], editorState: "5544200000")
        // Ricoh Shade A3 G3 → hand Canon Shade A2 G0: round(0.64·3) = 2, so Negative Film adds (0, −2).
        return Anchor(base: "Negative Film", label: "Portra 160 v1 (styles/Portra160.pf2)", recipe: r, style: style, tint: (0, -2),
                      confidence: "hand-tuned v1; median ΔE to GR 12.5/17.4 vs Standard-Shade 11.4/21.1 (same-time pairs)",
                      assumptions: [])
    }()

    /// PosFilm RR → styles/PosFilmRR2.pf2 (caption PosFilmRR). Camera WB Shade A0 G2 in the v2 test.
    /// The Ricoh slider values of this recipe are not recorded in the project: the GR EXIF of the fitted
    /// frames (R0000576/580/592) says Positive Film, Contrast High, Saturation High, Sharpness Normal,
    /// WB Multi Auto. The anchor assumes saturation +2, contrast +2, others 0.
    public static let posFilmRR2: Anchor = {
        var r = RicohRecipeSnapshot(name: "PosFilm RR", base: "Positive Film")
        r.saturation = 2; r.contrast = 2; r.whiteBalance = "Multi Auto"
        let style = CanonRegisteredStylePlan(
            caption: "PosFilmRR", sharpness: 3, contrast: 1, saturation: 1, colourTone: 2,
            curve: [.init(0, 0), .init(60, 62), .init(166, 180), .init(255, 255)],
            colourPoints: [
                .init(hue: 33, saturation: 23, luminosity: 53, hueLow: 3, hueHigh: 63, hueShift: 6, saturationShift: 0, luminosityShift: 0,
                      adobeRGB: [41, 17, 53, 4, 0, 0, 74, 86, 100, 8, 0, 0]),
                .init(hue: 68, saturation: 25, luminosity: 24, hueLow: 38, hueHigh: 98, hueShift: 6, saturationShift: 0, luminosityShift: 0,
                      adobeRGB: [79, 24, 24, 47, 0, 0, 103, 86, 100, 5, 0, 0]),
                .init(hue: 153, saturation: 13, luminosity: 20, hueLow: 123, hueHigh: 183, hueShift: 6, saturationShift: 0, luminosityShift: 0,
                      adobeRGB: [148, 10, 20, 122, 0, 0, 186, 62, 100, 6, 0, 0]),
            ], editorState: "5544200001")
        return Anchor(base: "Positive Film", label: "PosFilm RR v2 (styles/PosFilmRR2.pf2)", recipe: r, style: style, tint: (0, 2),
                      confidence: "hand-tuned v2; median ΔE to GR 10.9/18.3 vs Standard-Shade 10.1/17.8; chroma ~1.4× GR",
                      assumptions: ["PosFilm RR anchor sliders assumed (saturation +2, contrast +2; GR EXIF says High/High, magnitudes not recorded)"])
    }()

    /// IAC Tri-X → Canon Monochrome, Orange, contrast +2, sharpness 2 (installed in UD3; MakerNotes confirm).
    public static let triXMapping = CanonMonochromePlan(contrast: 2, sharpness: 2, filter: .orange, toning: .none)

    // MARK: Plan

    public func plan(for r: RicohRecipeSnapshot, slot: Int) throws -> CanonSlotPlan {
        var approximated: [String] = [], notes: [String] = []
        let wb = Self.whiteBalance(r, tint: Self.anchors.first { $0.base == r.base }?.tint ?? (0, 0), notes: &approximated)
        if r.isMonochrome {
            let offset = Self.monochromeContrastOffset[r.base] ?? 0
            var filter = CanonMonochromePlan.Filter.none, toning = CanonMonochromePlan.Toning.none
            if let mix = r.filterMix {
                filter = Self.monochromeFilter(mix)
                if filter != .none { approximated.append("Ricoh filter \(mix.summary) → Canon \(filter.name) (nearest-mix rule)") }
            } else if let n = r.filterOption {
                notes.append("Ricoh filter option \(n) has no RGB mix on the card; Canon filter left at None — set by hand if wanted")
            }
            if let name = r.toningName, name != .off {
                toning = Self.monochromeToning(name)
                if name == .red { approximated.append("toning Red → Canon Sepia (Canon has no red toning)") }
            } else if let step = r.toningStep, step != 0 {
                toning = step > 0 ? .sepia : .blue
                approximated.append("Ricoh toning \(signed(step)) → Canon \(toning.name) (sign only)")
            }
            if r.key != 0 || r.highlightContrast != 0 || r.shadowContrast != 0 {
                approximated.append("key/highlight/shadow contrast not carried: Canon Monochrome has no tone curve (PF2 cannot base on Monochrome)")
            }
            let mono = CanonMonochromePlan(contrast: clamp(r.contrast + offset, -4, 4), sharpness: Self.sharpness(r.sharpness, anchor: 3, from: 0),
                                           filter: filter, toning: toning)
            if offset != 0 { notes.append("\(r.base) → Canon contrast offset \(signed(offset)) (rule of thumb)") }
            return CanonSlotPlan(slot: slot, recipeName: r.name, source: source, registered: nil, monochrome: mono, whiteBalance: wb,
                                 dropped: RecipeToCanonStyle.dropped(r), approximated: approximated, notes: notes)
        }
        let caption = RecipeToCanonStyle.caption(for: r.name, slot: slot)
        let style: CanonRegisteredStylePlan
        if let anchor = Self.anchors.first(where: { $0.base == r.base }) {
            let a = anchor.recipe, s = anchor.style
            approximated += anchor.assumptions
            notes.append("Anchored on \(anchor.label): \(anchor.confidence)")
            let curve = Self.adjustedCurve(s.curve, key: r.key - a.key, highlight: r.highlightContrast - a.highlightContrast,
                                           shadow: r.shadowContrast - a.shadowContrast)
            // A recipe with exactly the anchor's style-relevant controls gets the anchor's style unchanged, caption
            // included, so its compiled record equals the one already registered from the hand-made file.
            let exact = [r.saturation, r.hue, r.key, r.contrast, r.highlightContrast, r.shadowContrast, r.sharpness]
                == [a.saturation, a.hue, a.key, a.contrast, a.highlightContrast, a.shadowContrast, a.sharpness]
            if exact { notes.append("Same style controls as the anchor recipe: the hand-made style is used unchanged (caption “\(s.caption)”)") }
            style = CanonRegisteredStylePlan(caption: exact ? s.caption : caption, sharpness: Self.sharpness(r.sharpness, anchor: s.sharpness, from: a.sharpness),
                                             contrast: clamp(s.contrast + Self.scaled(r.contrast - a.contrast, 0.75), -4, 4),
                                             saturation: clamp(s.saturation + Self.scaled(r.saturation - a.saturation, 0.75), -4, 4),
                                             colourTone: clamp(s.colourTone + Self.scaled(r.hue - a.hue, 0.5), -4, 4),
                                             curve: curve, colourPoints: s.colourPoints, editorState: s.editorState)
            if curve != s.curve { approximated.append("key/highlight/shadow deltas from the anchor applied to its L* curve (assumed slider shapes)") }
        } else {
            let o = Self.baseOffsets[r.base] ?? (0, 0, 0, [CanonCurvePoint(0, 0), CanonCurvePoint(255, 255)], "")
            if !o.note.isEmpty { notes.append(o.note) }
            approximated.append("\(r.base): no hand-made anchor; Canon Standard plus rule-of-thumb offsets")
            let curve = Self.adjustedCurve(o.curve, key: r.key, highlight: r.highlightContrast, shadow: r.shadowContrast)
            style = CanonRegisteredStylePlan(caption: caption, sharpness: Self.sharpness(r.sharpness, anchor: 3, from: 0),
                                             contrast: clamp(o.contrast + Self.scaled(r.contrast, 0.75), -4, 4),
                                             saturation: clamp(o.saturation + Self.scaled(r.saturation, 0.75), -4, 4),
                                             colourTone: clamp(o.tone + Self.scaled(r.hue, 0.5), -4, 4),
                                             curve: curve, colourPoints: [])
        }
        return CanonSlotPlan(slot: slot, recipeName: r.name, source: source, registered: style, monochrome: nil, whiteBalance: wb,
                             dropped: RecipeToCanonStyle.dropped(r), approximated: approximated, notes: notes)
    }

    // MARK: Rules

    /// Ricoh step → Canon step, rounded half away from zero.
    static func scaled(_ delta: Int, _ factor: Double) -> Int { Int((Double(delta) * factor).rounded()) }

    /// fit_model.py's sharpness rule (Canon = 3 + round(0.75 · Ricoh)), taken relative to an anchor.
    static func sharpness(_ ricoh: Int, anchor: Int, from anchorRicoh: Int) -> Int {
        clamp(anchor + scaled(ricoh - anchorRicoh, 0.75), 0, 7)
    }

    static let monochromeContrastOffset: [String: Int] = ["Monotone": 0, "Soft Monotone": -2, "Hard Monotone": 1, "Hi-Contrast B&W": 3]

    /// Unanchored colour bases: Canon contrast, saturation, colour tone, starting curve. Very low confidence.
    static let baseOffsets: [String: (contrast: Int, saturation: Int, tone: Int, curve: [CanonCurvePoint], note: String)] = [
        "Standard": (0, 0, 0, [.init(0, 0), .init(255, 255)], "Ricoh Standard → Canon Standard (neutral starting point)"),
        "Vivid": (1, 2, 0, [.init(0, 0), .init(255, 255)], ""),
        "Bleach Bypass": (2, -3, 0, [.init(0, 0), .init(255, 255)], ""),
        "Retro": (-1, -2, 1, [.init(0, 16), .init(128, 132), .init(255, 244)], "Retro: lifted blacks, lowered whites (guess)"),
        "Cinema (Yellow)": (0, -1, 1, [.init(0, 6), .init(255, 250)], "Cinema (Yellow): subdued, warm (guess)"),
        "HDR Tone": (-2, 0, 0, [.init(0, 0), .init(255, 255)], "HDR Tone: global tone only"),
        "Cross Processing 1": (1, 0, 2, [.init(0, 0), .init(255, 255)], "Cross Processing: colour shift not modelled"),
        "Cross Processing 2": (1, 0, -2, [.init(0, 0), .init(255, 255)], "Cross Processing: colour shift not modelled"),
        "Cross Processing 3": (1, 0, 0, [.init(0, 0), .init(255, 255)], "Cross Processing: colour shift not modelled"),
    ]

    /// Ricoh tone sliders on the L* curve, in L* units, evaluated on the curve's output:
    /// key `1.6·k·sin(πL/100)`; highlight `+0.05·h·(L−50)(100−L)/25` above L 50; shadow `−0.05·s·(50−L)L/25`
    /// below it (the response shapes fit_model.py's self-test assumes for the GR; unmeasured).
    public static func adjustedCurve(_ curve: [CanonCurvePoint], key: Int, highlight: Int, shadow: Int) -> [CanonCurvePoint] {
        if key == 0 && highlight == 0 && shadow == 0 { return curve }
        let xs0 = curve.map { Double($0.input) }, ys0 = curve.map { Double($0.output) }
        let grid = Set(curve.map(\.input) + Array(stride(from: 0, through: 255, by: 16)) + [255]).sorted()
        var xs: [Double] = [], ys: [Double] = []
        for x in grid {
            let y0 = FitModelPort.interp(Double(x), xs0, ys0)
            let L = y0 / 2.55
            var dL = 1.6 * Double(key) * sin(Double.pi * min(max(L, 0), 100) / 100)
            if L > 50 { dL += 0.05 * Double(highlight) * (L - 50) * (100 - L) / 25 }
            else { dL -= 0.05 * Double(shadow) * (50 - L) * L / 25 }
            xs.append(Double(x)); ys.append(min(255, max(0, y0 + 2.55 * dL)))
        }
        return FitModelPort.fitCurve(xs, ys, maxPoints: PictureStyleFile.maxCurvePoints, tol: 0.75).map { CanonCurvePoint($0[0], $0[1]) }
    }

    /// Nearest Canon filter by signed RGB mix. References: None = luminance mix (30/59/11); the others are
    /// chosen so the IAC Tri-X card mix (R50/G20/B−10) gives Orange, as installed and confirmed.
    static let filterReferences: [(CanonMonochromePlan.Filter, [Double])] = [
        (.none, [30, 59, 11]), (.yellow, [45, 50, 5]), (.orange, [60, 30, 10]), (.red, [100, 0, 0]), (.green, [10, 80, 10]),
    ]
    public static func monochromeFilter(_ mix: BWFilter) -> CanonMonochromePlan.Filter {
        guard mix.enabled else { return .none }
        let v = [Double(mix.red), Double(mix.green), Double(mix.blue)]
        return filterReferences.min { a, b in
            zip(a.1, v).map { pow($0 - $1, 2) }.reduce(0, +) < zip(b.1, v).map { pow($0 - $1, 2) }.reduce(0, +)
        }!.0
    }
    public static func monochromeToning(_ t: MonochromeToning) -> CanonMonochromePlan.Toning {
        switch t { case .off: return .none; case .sepia, .red: return .sepia; case .blue: return .blue; case .purple: return .purple; case .green: return .green }
    }

    /// Extra Canon amber steps per Ricoh preset (Set D outdoor/indoor/lamp comparison; about half the outdoor gap).
    static let warmthBump: [String: Int] = ["Daylight": 2, "Cloudy": 3, "Shade": 5]

    /// Ricoh preset → Canon preset; shift scaled by 0.64 (Ricoh ±14 → Canon ±9, fit_model.py's default) plus the base tint.
    static func whiteBalance(_ r: RicohRecipeSnapshot, tint: (ab: Int, gm: Int), notes: inout [String]) -> CanonWhiteBalanceInstruction {
        var preset: String, note: String?, kelvinShift = 0
        switch r.whiteBalance {
        case "Daylight", "Shade", "Cloudy", "Tungsten": preset = r.whiteBalance
        case "Fluorescent D", "Fluorescent N", "Fluorescent W", "Fluorescent L":
            preset = "White fluorescent"; note = "450D has one fluorescent preset"
        case "Kelvin":
            // Nearest preset in mired, then the remainder on the A/B axis at Canon's 5 mired per step
            // (A = warmer). Nominal preset temperatures; approximate.
            let k = Double(r.kelvin ?? 5200)
            let table: [(String, Double)] = [("Tungsten", 3200), ("White fluorescent", 4000), ("Daylight", 5200), ("Cloudy", 6000), ("Shade", 7000)]
            let best = table.min { abs(1e6 / $0.1 - 1e6 / k) < abs(1e6 / $1.1 - 1e6 / k) }!
            preset = best.0
            kelvinShift = Int(((1e6 / best.1 - 1e6 / k) / 5).rounded())
            note = "\(Int(k)) K approximated as \(best.0) \(kelvinShift >= 0 ? "A" : "B")\(abs(kelvinShift)) (5 mired per step)"
            notes.append("Kelvin WB approximated by a Canon preset plus shift")
        case "CTE":
            // CTE keeps and strengthens the scene's colour cast; a fixed Daylight balance keeps the cast.
            preset = "Daylight"; note = "CTE approximated by Daylight"
            notes.append("CTE WB (scene-dependent) approximated by Canon Daylight plus the scaled shift")
        default:
            preset = "Auto"
            if r.whiteBalance != "Auto" { notes.append("\(RecipeWhiteBalance.label(r.whiteBalance)) is scene-dependent; Canon Auto WB used") }
        }
        // Warmth bump (Set D, 25 Nov 2026): the GR's Daylight/Cloudy/Shade presets render warmer than Canon's
        // same-named presets (lamps: ~8/12/15 b*; outdoor open shade: ~6-10 b*; one indoor scene: ~2 b*).
        // The bump closes about half the outdoor gap; it applies only when the Ricoh preset itself is one of these.
        let bump = warmthBump[r.whiteBalance] ?? 0
        let ab = clamp(scaled(r.amberBlue, 0.64) + kelvinShift + tint.ab + bump, -9, 9), gm = clamp(scaled(r.greenMagenta, 0.64) + tint.gm, -9, 9)
        if tint.ab != 0 || tint.gm != 0 { note = (note.map { $0 + "; " } ?? "") + "includes the \(r.base) base tint \(signed(tint.ab))/\(signed(tint.gm))" }
        if bump != 0 { note = (note.map { $0 + "; " } ?? "") + "includes the \(r.whiteBalance) warmth bump A\(bump) (GR presets render warmer than Canon's)" }
        return CanonWhiteBalanceInstruction(preset: preset, amberBlue: ab, greenMagenta: gm, note: note)
    }
}
