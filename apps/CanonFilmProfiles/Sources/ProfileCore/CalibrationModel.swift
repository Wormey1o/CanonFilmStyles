import Foundation
import CoreFoundation

/// Translation from a measured model: `calibration_model.json` in the schema written by
/// `experiments/film-native-picture-style-route-v1/calibration/fit_model.py` (schema
/// "ricoh-gr3x150-to-canon450d-calibration" v1). `FitModelPort.predict` is a line-by-line port of that
/// script's `predict()` and the helpers it calls (fit_model.py and calib_colour.py, pinned in
/// `Tests/RecipeToCanonStyleChecks`), checked against the script on its own synthetic model.
///
/// Port conventions: Python `round` is ties-to-even; `round(x, n)` is correctly rounded on the exact
/// binary value; dictionary iteration in `wb_canon_best` follows fit_model's CANON_PRESETS order (the order
/// `fit()` inserts them), since JSON object order is not kept by Foundation.
public struct CalibrationModel: RecipeToCanonStyleModel {
    public static let schema = "ricoh-gr3x150-to-canon450d-calibration"
    public let model: FitModelPort.Model
    public let source: CanonStyleModelSource

    public init(json data: Data) throws {
        guard data.count <= 16_777_216 else { throw ProfileError.invalid("Calibration model is too large.") }
        let model = try FitModelPort.Model(json: data)
        self.model = model
        let frames = model.frames.map { "\($0) frames" } ?? "frame count not recorded"
        source = CanonStyleModelSource(kind: .calibration, name: "Calibration model", version: model.modelVersion,
                                       confidence: "fitted from the stage-3 chart shoot (\(frames)); colour points use assumption A2 with PSE units taken 1:1 (not yet confirmed in camera)")
    }

    public init(contentsOf url: URL) throws { try self.init(json: Data(contentsOf: url)) }

    /// The fit_model.py recipe dictionary for a snapshot.
    public static func fitModelRecipe(_ r: RicohRecipeSnapshot) -> FitModelPort.Recipe {
        var x = FitModelPort.Recipe(base: r.base)
        x.saturation = r.saturation; x.hue = r.hue; x.key = r.key; x.contrast = r.contrast
        x.highlightContrast = r.highlightContrast; x.shadowContrast = r.shadowContrast; x.sharpness = r.sharpness
        x.wb = r.whiteBalance; x.ab = r.amberBlue; x.gm = r.greenMagenta; x.kelvin = r.kelvin.map(Double.init)
        x.clarity = r.clarity; x.shading = r.shading; x.grain = r.grain
        if let n = r.filterOption, (1...FitModelPort.ricohFiltersGuess.count).contains(n) { x.filter = FitModelPort.ricohFiltersGuess[n - 1] }
        if let t = r.toningStep { x.toning = t }
        return x
    }

    public func plan(for r: RicohRecipeSnapshot, slot: Int) throws -> CanonSlotPlan {
        guard model.ricohBases[r.base] != nil else { throw CanonStyleNotCovered("base \(r.base) not calibrated") }
        let p: FitModelPort.Prediction
        do { p = try FitModelPort.predict(model, Self.fitModelRecipe(r)) }
        catch let e as FitModelPort.Missing { throw CanonStyleNotCovered(e.what) }
        var approximated = p.approximated
        var notes: [String] = []
        guard FitModelPort.canonPresetName(p.wb.preset) != nil else { throw CanonStyleNotCovered("WB preset \(p.wb.preset) unknown") }
        // White balance stays on the interim rule (preset by name, shift × 0.64, anchor base tint). The model's WB
        // pairing was measured under one studio lamp (shoot-1: GR Daylight renders it a*+6.5 b*+7.3, Canon Daylight
        // renders it neutral), so it is shown as a note until outdoor scenes (Set D) confirm it.
        var wbApprox: [String] = []
        let wb = InterimRules.whiteBalance(r, tint: InterimRules.anchors.first { $0.base == r.base }?.tint ?? (0, 0), notes: &wbApprox)
        approximated += wbApprox
        approximated.removeAll { $0.contains("WB derived from the GR's gain table") }
        if p.wb.preset != "Auto" || wb.preset != "Auto" {
            notes.append("lamp-measured WB would be \(p.wb.preset) \(p.wb.ab >= 0 ? "A" : "B")\(abs(p.wb.ab)) \(p.wb.gm >= 0 ? "G" : "M")\(abs(p.wb.gm))"
                         + (p.wb.residual.map { String(format: " (residual %.2f a*b*)", $0) } ?? "") + "; not used until outdoor validation, interim WB rule applied")
        }
        if p.canonStyle == "Monochrome" {
            var filter = CanonMonochromePlan.Filter(name: p.filter ?? "None") ?? .none
            var toning = CanonMonochromePlan.Toning(name: p.toning ?? "None") ?? .none
            if r.filterOption == nil, let mix = r.filterMix {
                filter = InterimRules.monochromeFilter(mix)
                approximated.append("filter from RGB mix \(mix.summary) by interim nearest-mix rule (no option number for the calibration lookup)")
            }
            if r.toningStep == nil, let name = r.toningName, name != .off {
                if let c = model.monoToning[name.rawValue], let t = CanonMonochromePlan.Toning(name: c) {
                    toning = t
                    notes.append("named toning \(name.rawValue) → Canon \(c) (measured, nearest a*b*)")
                } else {
                    toning = InterimRules.monochromeToning(name)
                    approximated.append("named toning \(name.rawValue) by interim rule (not in the calibration model)")
                }
            }
            if r.filterOption == nil, r.filterMix == nil, model.monoFiltersByName { notes.append("Ricoh filter → Canon filter by name (not measured)") }
            if r.filterOption != nil { notes.append("Ricoh filter option \(r.filterOption!) read as “\(Self.fitModelRecipe(r).filter ?? "?")” (fit_model's option-order guess)") }
            let mono = CanonMonochromePlan(contrast: p.contrast, sharpness: p.sharpness, filter: filter, toning: toning)
            return CanonSlotPlan(slot: slot, recipeName: r.name, source: source, registered: nil, monochrome: mono, whiteBalance: wb,
                                 dropped: RecipeToCanonStyle.dropped(r),
                                 approximated: approximated, notes: notes)
        }
        let curve = p.curve.map { CanonCurvePoint($0[0], $0[1]) }
        let points = p.colourPoints.map {
            CanonColourPointPlan.centred(hue: $0.sourceHSL[0], saturation: $0.sourceHSL[1], luminosity: $0.sourceHSL[2], hueRange: $0.hueRangeDeg,
                                         hueShift: $0.hueShiftDeg, saturationShift: $0.satShift, luminosityShift: $0.lumShift)
        }
        approximated.append("colour points: HSL shifts written 1:1 as PSE units (assumption A2); AdobeRGB copy = sRGB record")
        if let d = p.fitDE00 { notes.append(String(format: "chart fit ΔE00 median: Canon Standard %.2f → this style %.2f (p95 %.2f, %d patches)", d.standardMedian, d.modelMedian, d.modelP95, d.patches)) }
        let style = CanonRegisteredStylePlan(caption: RecipeToCanonStyle.caption(for: r.name, slot: slot), sharpness: p.sharpness,
                                             contrast: p.contrast, saturation: p.saturation ?? 0, colourTone: p.colourTone ?? 0,
                                             curve: curve, colourPoints: points)
        return CanonSlotPlan(slot: slot, recipeName: r.name, source: source, registered: style, monochrome: nil, whiteBalance: wb,
                             dropped: RecipeToCanonStyle.dropped(r), approximated: approximated, notes: notes)
    }
}

// MARK: - Port of fit_model.py predict()

public enum FitModelPort {
    public static let n = 45
    static let chromatic = Array(0..<18)
    static let neutral = Array(18..<45)
    static let steps = [-4, -2, 2, 4]
    static let toneSliders = ["key", "contrast", "highlight_contrast", "shadow_contrast"]
    static let sectors: [Double] = [0, 60, 120, 180, 240, 300]
    static let canonPresets = ["Daylight", "Shade", "Cloudy", "Tungsten", "White fluorescent", "Flash"]
    static let autoWB = ["Auto", "Auto (Warmth Priority)", "Auto (White Priority)", "Multi Auto", "CTE"]
    public static let ricohFiltersGuess = ["Green", "Yellow", "Orange", "Red", "Magenta", "Blue", "Cyan", "Infrared"]

    public struct Missing: Error { public var what: String }

    static func canonPresetName(_ name: String) -> String? {
        CanonWhiteBalanceInstruction.presets.contains(name) ? name : nil
    }

    // ---- model

    public struct Base: Sendable {
        public var kind: String
        public var entriesLab: [[Double]]
        public var clipped: [Bool]
        public var tintVsStandard: [Double]
    }
    public struct ToneTable: Sendable { var nodesL: [Double]; var deltaL: [String: [Double]] }
    public struct Model: Sendable {
        public var modelVersion: String
        public var frames: Int?
        var canonRef: [[Double]]
        var canonClip: [Bool]
        var canonSliders: [String: [String: [[Double]]]]
        var canonMonoContrast: [String: [Double]]?
        public var ricohBases: [String: Base]
        var satChroma: [String: Double?]
        var satSector: [String: [Double?]]
        var hueShift: [String: Double?]
        var hueSector: [String: [Double?]]
        var tone: [String: ToneTable]
        var monoFilters: [String: String]   // Ricoh label -> nearest Canon
        var monoToning: [String: String]    // Ricoh step or tone name -> nearest Canon
        var monoFiltersByName = false        // filters mapped by name, not measured
        var ricohKelvinDerived = false       // Kelvin from the camera gain table, no Kelvin frame shot
        var ricohDerivedPresets: Set<String> = []  // presets without a frame (fluorescents via nominal CCT)
        var ricohPresets: [String: [Double]]
        var ricohKelvin: [[Double]]
        var ricohJ: [[Double]]
        var canonPresetsAB: [(String, [Double])]
        var canonJ: [[Double]]
        var stepInCanon: [[Double]]?

        public init(json data: Data) throws {
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ProfileError.invalid("Calibration model is not a JSON object.") }
            func bad(_ what: String) -> ProfileError { .invalid("Calibration model: \(what) missing or malformed.") }
            guard root["schema"] as? String == CalibrationModel.schema, try num(root["schema_version"], "schema_version") == 1 else {
                throw ProfileError.invalid("Calibration model schema is not \(CalibrationModel.schema) v1.")
            }
            func dict(_ v: Any?, _ w: String) throws -> [String: Any] { guard let d = v as? [String: Any] else { throw bad(w) }; return d }
            func num(_ v: Any?, _ w: String) throws -> Double {
                guard let x = v as? NSNumber, CFGetTypeID(x) != CFBooleanGetTypeID(), x.doubleValue.isFinite else {
                    throw bad(w)
                }
                return x.doubleValue
            }
            func optNum(_ v: Any, _ w: String) throws -> Double? {
                if v is NSNull { return nil }
                return try num(v, w)
            }
            func vec(_ v: Any?, _ w: String) throws -> [Double] { guard let a = v as? [Any] else { throw bad(w) }; return try a.map { try num($0, w) } }
            func mat(_ v: Any?, _ w: String) throws -> [[Double]] { guard let a = v as? [Any] else { throw bad(w) }; return try a.map { try vec($0, w) } }
            func bool(_ v: Any?, _ w: String) throws -> Bool {
                guard let x = v as? NSNumber, CFGetTypeID(x) == CFBooleanGetTypeID() else { throw bad(w) }
                return x.boolValue
            }
            func bools(_ v: Any?, _ w: String) throws -> [Bool] { guard let a = v as? [Any] else { throw bad(w) }; return try a.map { try bool($0, w) } }
            func optVec(_ v: Any?, _ w: String) throws -> [Double?] { guard let a = v as? [Any] else { throw bad(w) }; return try a.map { try optNum($0, w) } }
            func lab45(_ v: Any?, _ w: String) throws -> [[Double]] {
                let m = try mat(v, w); guard m.count == FitModelPort.n, m.allSatisfy({ $0.count == 3 }) else { throw bad(w) }; return m
            }
            modelVersion = root["model_version"] as? String ?? "unversioned"
            frames = ((root["capture"] as? [String: Any])?["frames"] as? NSNumber)?.intValue
            let cref = try dict(root["canon_reference"], "canon_reference")
            canonRef = try lab45(cref["entries_lab"], "canon_reference.entries_lab")
            canonClip = try bools(cref["clipped"], "canon_reference.clipped")
            guard canonClip.count == FitModelPort.n else { throw bad("canon_reference.clipped") }
            var cs: [String: [String: [[Double]]]] = [:]
            let sl = try dict(root["canon_sliders"], "canon_sliders")
            for name in ["saturation", "color_tone"] {
                let t = try dict(sl[name], "canon_sliders.\(name)")
                var out: [String: [[Double]]] = [:]
                for k in FitModelPort.steps.map(String.init) { out[k] = try lab45(t[k], "canon_sliders.\(name).\(k)") }
                cs[name] = out
            }
            canonSliders = cs
            if let cm = root["canon_mono"] as? [String: Any], let c = cm["contrast"] as? [String: Any] {
                canonMonoContrast = try c.mapValues { try vec($0, "canon_mono.contrast") }
            }
            var bases: [String: Base] = [:]
            for (name, v) in try dict(root["ricoh_bases"], "ricoh_bases") {
                let b = try dict(v, "ricoh_bases.\(name)")
                let clip = try bools(b["clipped"], "ricoh_bases.\(name).clipped")
                let tint = try vec(b["tint_vs_standard"], "ricoh_bases.\(name).tint_vs_standard")
                guard clip.count == FitModelPort.n, tint.count == 2 else { throw bad("ricoh_bases.\(name)") }
                bases[name] = Base(kind: b["kind"] as? String ?? "colour", entriesLab: try lab45(b["entries_lab"], "ricoh_bases.\(name).entries_lab"),
                                   clipped: clip, tintVsStandard: tint)
            }
            ricohBases = bases
            let rs = try dict(root["ricoh_sliders"], "ricoh_sliders")
            let sat = try dict(rs["saturation"], "ricoh_sliders.saturation"), hue = try dict(rs["hue"], "ricoh_sliders.hue")
            satChroma = try dict(sat["chroma_ratio"], "saturation.chroma_ratio").mapValues { try optNum($0, "saturation.chroma_ratio") }
            satSector = try dict(sat["by_sector"], "saturation.by_sector").mapValues { try optVec($0, "saturation.by_sector") }
            hueShift = try dict(hue["hue_shift_deg"], "hue.hue_shift_deg").mapValues { try optNum($0, "hue.hue_shift_deg") }
            hueSector = try dict(hue["by_sector"], "hue.by_sector").mapValues { try optVec($0, "hue.by_sector") }
            for table in [satChroma, hueShift] { guard FitModelPort.steps.allSatisfy({ table[String($0)] != nil }) else { throw bad("ricoh_sliders step table") } }
            for table in [satSector, hueSector] {
                guard FitModelPort.steps.allSatisfy({ table[String($0)]?.count == 6 }) else { throw bad("ricoh_sliders by_sector") }
            }
            var tone: [String: ToneTable] = [:]
            for name in FitModelPort.toneSliders {
                let t = try dict(rs[name], "ricoh_sliders.\(name)")
                let nodes = try vec(t["nodes_L"], "\(name).nodes_L")
                guard nodes.count >= 2, zip(nodes, nodes.dropFirst()).allSatisfy({ $0.0 < $0.1 }) else {
                    throw bad("\(name).nodes_L")
                }
                let d = try dict(t["delta_L"], "\(name).delta_L").mapValues { try vec($0, "\(name).delta_L") }
                guard FitModelPort.steps.allSatisfy({ d[String($0)]?.count == nodes.count }) else { throw bad("\(name).delta_L") }
                tone[name] = ToneTable(nodesL: nodes, deltaL: d)
            }
            self.tone = tone
            var mf: [String: String] = [:], mt: [String: String] = [:]
            if let rm = root["ricoh_mono"] as? [String: Any] {
                for (k, v) in (rm["filters"] as? [String: Any]) ?? [:] { if let c = (v as? [String: Any])?["nearest_canon"] as? String { mf[k] = c } }
                for (k, v) in (rm["toning"] as? [String: Any]) ?? [:] { if let c = (v as? [String: Any])?["nearest_canon"] as? String { mt[k] = c } }
            }
            monoFilters = mf; monoToning = mt
            monoFiltersByName = ((root["ricoh_mono"] as? [String: Any])?["filters"] as? [String: Any])?.values
                .contains { (($0 as? [String: Any])?["method"] as? String)?.hasPrefix("by name") == true } ?? false
            let wb = try dict(root["white_balance"], "white_balance")
            let r = try dict(wb["ricoh"], "white_balance.ricoh"), c = try dict(wb["canon"], "white_balance.canon")
            ricohPresets = try dict(r["presets"], "ricoh.presets").mapValues { try vec($0, "ricoh.presets") }
            ricohKelvin = try r["kelvin"].map { try mat($0, "white_balance.ricoh.kelvin") } ?? []
            guard ricohKelvin.isEmpty || (ricohKelvin.count >= 2 && ricohKelvin.allSatisfy({ $0.count == 3 && $0[0] > 0 })) else {
                throw bad("white_balance.ricoh.kelvin")
            }
            ricohKelvinDerived = try r["kelvin_derived"].map { try bool($0, "white_balance.ricoh.kelvin_derived") } ?? false
            ricohDerivedPresets = Set((((r["gain_model"] as? [String: Any])?["derived_presets"]) as? [String: Any])?.keys.map { $0 } ?? [])
            ricohJ = try mat(r["shift_jacobian"], "ricoh.shift_jacobian")
            let cp = try dict(c["presets"], "canon.presets").mapValues { try vec($0, "canon.presets") }
            let ordered = FitModelPort.canonPresets.filter { cp[$0] != nil } + cp.keys.filter { !FitModelPort.canonPresets.contains($0) }.sorted()
            canonPresetsAB = ordered.map { ($0, cp[$0]!) }
            canonJ = try mat(c["shift_jacobian"], "canon.shift_jacobian")
            stepInCanon = try wb["ricoh_step_in_canon_steps"].map { try mat($0, "white_balance.ricoh_step_in_canon_steps") }
            for (name, matrix) in [("ricoh.shift_jacobian", ricohJ), ("canon.shift_jacobian", canonJ),
                                   ("ricoh_step_in_canon_steps", stepInCanon)].compactMap({ name, matrix in matrix.map { (name, $0) } }) {
                guard matrix.count == 2, matrix.allSatisfy({ $0.count == 2 }) else { throw bad("white_balance.\(name)") }
            }
            guard ricohPresets.values.allSatisfy({ $0.count == 2 }), canonPresetsAB.allSatisfy({ $0.1.count == 2 }), !canonPresetsAB.isEmpty else { throw bad("WB presets") }
        }
    }

    // ---- recipe and prediction

    public struct Recipe: Sendable {
        public var base: String
        public var saturation = 0, hue = 0, key = 0, contrast = 0, highlightContrast = 0, shadowContrast = 0, sharpness = 0
        public var wb = "Auto"
        public var ab = 0, gm = 0
        public var kelvin: Double?
        public var filter: String?
        public var toning: Int?
        public var clarity = 0, shading = 0, grain = 0
        public init(base: String) { self.base = base }
        func tone(_ name: String) -> Int {
            switch name { case "key": return key; case "contrast": return contrast; case "highlight_contrast": return highlightContrast; default: return shadowContrast }
        }
    }
    public struct ColourPoint: Equatable, Sendable {
        public var sourceHSL: [Double], hueRangeDeg: Double, hueShiftDeg: Double, satShift: Double, lumShift: Double
    }
    public struct DE00: Equatable, Sendable { public var standardMedian, modelMedian, modelP95: Double; public var patches: Int }
    public struct WB: Equatable, Sendable { public var preset: String; public var ab: Int, gm: Int; public var residual: Double?; public var atLimit: Bool }
    public struct Prediction: Sendable {
        public var sharpness: Int
        public var canonStyle: String
        public var contrast: Int
        public var saturation: Int?, colourTone: Int?
        public var curve: [[Int]] = []
        public var colourPoints: [ColourPoint] = []
        public var fitDE00: DE00?
        public var filter: String?, toning: String?
        public var wb: WB
        public var dropped: [String]
        public var approximated: [String]
    }

    public static func predict(_ model: Model, _ recipe: Recipe) throws -> Prediction {
        guard let base = model.ricohBases[recipe.base] else { throw Missing(what: "base not calibrated: \(recipe.base)") }
        var dropped: [String] = []
        if recipe.clarity != 0 { dropped.append("clarity") }
        if recipe.shading != 0 { dropped.append("shading") }
        if recipe.grain != 0 { dropped.append("grain") }
        var approx: [String] = []
        let sharp = max(0, min(7, 3 + Int(pyRound(0.75 * Double(recipe.sharpness)))))
        var out = Prediction(sharpness: sharp, canonStyle: "", contrast: 0, wb: WB(preset: "", ab: 0, gm: 0, atLimit: false), dropped: [], approximated: [])
        var tint = [0.0, 0.0]
        if base.kind == "mono" {
            var toneOnly = Recipe(base: recipe.base)
            toneOnly.key = recipe.key; toneOnly.contrast = recipe.contrast
            toneOnly.highlightContrast = recipe.highlightContrast; toneOnly.shadowContrast = recipe.shadowContrast
            let target = applyRicohSliders(base.entriesLab, toneOnly, model)
            guard let cm = model.canonMonoContrast, !cm.isEmpty else { throw Missing(what: "no Canon Monochrome frames in the model") }
            let tr = (24..<45).map { target[$0][0] }
            var best = -4, bestScore = Double.infinity
            for k in -4...4 {
                let ramp = stepInterpContrast(cm, k)
                let s = pySum(zip(ramp, tr).map { pow($0 - $1, 2) })
                if s < bestScore { bestScore = s; best = k }
            }
            out.canonStyle = "Monochrome"; out.contrast = best
            if let f = recipe.filter, f != "Off" { out.filter = model.monoFilters[f] ?? "None" } else { out.filter = "None" }
            if let t = recipe.toning, t != 0 { out.toning = model.monoToning[String(t)] ?? "None" } else { out.toning = "None" }
            approx.append("monochrome tone curve via Canon contrast slider only")
        } else {
            let target = applyRicohSliders(base.entriesLab, recipe, model)
            let f = fitColourTarget(model, target, base.clipped)
            out.canonStyle = "Standard (PF2 user style)"; out.contrast = 0
            out.saturation = f.ks; out.colourTone = f.kt; out.curve = f.curve; out.colourPoints = f.points; out.fitDE00 = f.de00
            tint = base.tintVsStandard
        }
        let wb = recipe.wb
        if autoWB.contains(wb) {
            let M = model.stepInCanon ?? [[0.64, 0], [0, 0.64]]
            let ab = Double(recipe.ab), gm = Double(recipe.gm)
            out.wb = WB(preset: "Auto", ab: max(-9, min(9, Int(pyRound(M[0][0] * ab + M[0][1] * gm)))),
                        gm: max(-9, min(9, Int(pyRound(M[1][0] * ab + M[1][1] * gm)))), residual: nil, atLimit: false)
            approx.append("\(wb) is scene-dependent; Canon Auto used")
        } else {
            let n = try ricohNeutral(model, wb, Double(recipe.ab), Double(recipe.gm), recipe.kelvin)
            out.wb = wbCanonBest([n[0] + tint[0], n[1] + tint[1]], model)
            if (wb == "Kelvin" && model.ricohKelvinDerived) || model.ricohDerivedPresets.contains(wb) {
                approx.append("\(wb) WB derived from the GR's gain table (no calibration frame)")
            }
        }
        out.dropped = dropped
        out.approximated = approx
        return out
    }

    /// CPython 3.14 `math.hypot` (vector_norm: lossless scaling, double-length sums, one correction step).
    /// libm `hypot` differs in the last bit on ~16% of inputs; this matches CPython on 200,000 test pairs.
    static func pyHypot(_ a: Double, _ b: Double) -> Double {
        let v = [abs(a), abs(b)], mx = max(v[0], v[1])
        if mx.isInfinite { return mx }
        if a.isNaN || b.isNaN { return .nan }
        if mx == 0 { return mx }
        precondition(mx >= Double.leastNormalMagnitude, "subnormal hypot not ported")
        let scale = Foundation.ldexp(1.0, -(Int(mx.exponent) + 1))
        var csum = 1.0, frac1 = 0.0, frac2 = 0.0
        for x0 in v {
            let x = x0 * scale
            let prHi = x * x, prLo = (-prHi).addingProduct(x, x)
            let smHi = csum + prHi, smLo = (csum - smHi) + prHi
            csum = smHi; frac1 += prLo; frac2 += smLo
        }
        var h = (csum - 1.0 + (frac1 + frac2)).squareRoot()
        let prHi = -h * h, prLo = (-prHi).addingProduct(-h, h)
        let smHi = csum + prHi, smLo = (csum - smHi) + prHi
        csum = smHi; frac1 += prLo; frac2 += smLo
        h += (csum - 1.0 + (frac1 + frac2)) / (2.0 * h)
        return h / scale
    }
    /// CPython 3.12+ `sum()` of floats (Neumaier compensated summation).
    static func pySum(_ items: [Double]) -> Double {
        var result = 0.0, c = 0.0
        for x in items {
            let t = result + x
            if abs(result) >= abs(x) { c += (result - t) + x } else { c += (x - t) + result }
            result = t
        }
        if c != 0 && c.isFinite { result += c }
        return result
    }

    // ---- calib_colour.py

    static let white: [Double] = [0.95047, 1.0, 1.08883]
    static let mXYZ: [[Double]] = [[0.4124564, 0.3575761, 0.1804375], [0.2126729, 0.7151522, 0.0721750], [0.0193339, 0.1191920, 0.9503041]]
    static let mRGB: [[Double]] = [[3.2404542, -1.5371385, -0.4985314], [-0.9692660, 1.8760108, 0.0415560], [0.0556434, -0.2040259, 1.0572252]]

    @inline(__always) static func pyMod(_ a: Double, _ b: Double) -> Double {
        var m = fmod(a, b)
        if m != 0 { if (b < 0) != (m < 0) { m += b } } else { m = copysign(0, b) }
        return m
    }
    @inline(__always) static func degrees(_ x: Double) -> Double { x * (180.0 / Double.pi) }
    @inline(__always) static func radians(_ x: Double) -> Double { x * (Double.pi / 180.0) }

    static func srgbToLinear(_ v: Double) -> Double { let c = v / 255.0; return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
    static func linearToSrgb(_ c: Double) -> Double {
        let v: Double = c <= 0.0031308 ? 12.92 * c : (c > 0 ? 1.055 * pow(c, 1 / 2.4) - 0.055 : 0.0)
        return v * 255.0
    }
    static func srgbToLab(_ rgb: [Double]) -> [Double] {
        let r = srgbToLinear(rgb[0]), g = srgbToLinear(rgb[1]), b = srgbToLinear(rgb[2])
        let xyz = mXYZ.map { $0[0] * r + $0[1] * g + $0[2] * b }
        var f: [Double] = []
        for (v, w) in zip(xyz, white) {
            let t = v / w
            f.append(t > 216.0 / 24389.0 ? pow(t, 1.0 / 3.0) : (24389.0 / 27.0 * t + 16) / 116)
        }
        return [116 * f[1] - 16, 500 * (f[0] - f[1]), 200 * (f[1] - f[2])]
    }
    static func labToSrgb(_ lab: [Double]) -> [Double] {
        let fy = (lab[0] + 16) / 116, fx = fy + lab[1] / 500, fz = fy - lab[2] / 200
        var o: [Double] = []
        for (f, w) in zip([fx, fy, fz], white) {
            let t = pow(f, 3) > 216.0 / 24389.0 ? pow(f, 3) : (116 * f - 16) / (24389.0 / 27.0)
            o.append(t * w)
        }
        let lin = mRGB.map { $0[0] * o[0] + $0[1] * o[1] + $0[2] * o[2] }
        return lin.map { min(255.0, max(0.0, linearToSrgb(max(0.0, $0)))) }
    }
    static func labToLch(_ lab: [Double]) -> [Double] { [lab[0], pyHypot(lab[1], lab[2]), pyMod(degrees(atan2(lab[2], lab[1])), 360)] }
    static func lchToLab(_ lch: [Double]) -> [Double] { [lch[0], lch[1] * cos(radians(lch[2])), lch[1] * sin(radians(lch[2]))] }
    static func hueDiff(_ h2: Double, _ h1: Double) -> Double { let d = pyMod(h2 - h1, 360); return d > 180 ? d - 360 : d }
    static func rgbToHsl(_ rgb: [Double]) -> [Double] {
        let c = rgb.map { min(255.0, max(0.0, $0)) / 255.0 }
        let r = c[0], g = c[1], b = c[2]
        let mx = max(r, g, b), mn = min(r, g, b)
        let l = (mx + mn) / 2
        if mx == mn { return [0.0, 0.0, l * 100] }
        let d = mx - mn
        let s = l > 0.5 ? d / (2 - mx - mn) : d / (mx + mn)
        let h: Double
        if mx == r { h = pyMod((g - b) / d, 6) } else if mx == g { h = (b - r) / d + 2 } else { h = (r - g) / d + 4 }
        return [pyMod(h * 60, 360), s * 100, l * 100]
    }
    static func hslToRgb(_ hsl: [Double]) -> [Double] {
        let h = pyMod(hsl[0], 360), s = min(100.0, max(0.0, hsl[1])) / 100, l = min(100.0, max(0.0, hsl[2])) / 100
        let c = (1 - abs(2 * l - 1)) * s
        let x = c * (1 - abs(pyMod(h / 60, 2) - 1))
        let m = l - c / 2
        let table: [[Double]] = [[c, x, 0], [x, c, 0], [0, c, x], [0, x, c], [x, 0, c], [c, 0, x]]
        let k = Int(pyMod((h / 60).rounded(.down), 6))
        let t = table[k]
        return [(t[0] + m) * 255, (t[1] + m) * 255, (t[2] + m) * 255]
    }
    public static func de2000(_ lab1: [Double], _ lab2: [Double]) -> Double {
        let L1 = lab1[0], a1 = lab1[1], b1 = lab1[2], L2 = lab2[0], a2 = lab2[1], b2 = lab2[2]
        let C1 = pyHypot(a1, b1), C2 = pyHypot(a2, b2)
        let Cb = (C1 + C2) / 2
        let G = 0.5 * (1 - sqrt(pow(Cb, 7) / (pow(Cb, 7) + 6103515625.0)))
        let a1p = (1 + G) * a1, a2p = (1 + G) * a2
        let C1p = pyHypot(a1p, b1), C2p = pyHypot(a2p, b2)
        let h1p = (a1p != 0 || b1 != 0) ? pyMod(degrees(atan2(b1, a1p)), 360) : 0.0
        let h2p = (a2p != 0 || b2 != 0) ? pyMod(degrees(atan2(b2, a2p)), 360) : 0.0
        let dLp = L2 - L1, dCp = C2p - C1p
        var dhp: Double
        if C1p * C2p == 0 { dhp = 0.0 } else {
            dhp = h2p - h1p
            if dhp > 180 { dhp -= 360 } else if dhp < -180 { dhp += 360 }
        }
        let dHp = 2 * sqrt(C1p * C2p) * sin(radians(dhp / 2))
        let Lbp = (L1 + L2) / 2, Cbp = (C1p + C2p) / 2
        let hbp: Double
        if C1p * C2p == 0 { hbp = h1p + h2p } else if abs(h1p - h2p) <= 180 { hbp = (h1p + h2p) / 2 }
        else if h1p + h2p < 360 { hbp = (h1p + h2p + 360) / 2 } else { hbp = (h1p + h2p - 360) / 2 }
        let T = 1 - 0.17 * cos(radians(hbp - 30)) + 0.24 * cos(radians(2 * hbp)) + 0.32 * cos(radians(3 * hbp + 6)) - 0.20 * cos(radians(4 * hbp - 63))
        let dth = 30 * exp(-pow((hbp - 275) / 25, 2))
        let Rc = 2 * sqrt(pow(Cbp, 7) / (pow(Cbp, 7) + 6103515625.0))
        let Sl = 1 + 0.015 * pow(Lbp - 50, 2) / sqrt(20 + pow(Lbp - 50, 2))
        let Sc = 1 + 0.045 * Cbp
        let Sh = 1 + 0.015 * Cbp * T
        let Rt = -sin(radians(2 * dth)) * Rc
        return sqrt(pow(dLp / Sl, 2) + pow(dCp / Sc, 2) + pow(dHp / Sh, 2) + Rt * (dCp / Sc) * (dHp / Sh))
    }
    static func median(_ v: [Double]) -> Double {
        let s = v.sorted(), n = s.count
        precondition(n > 0, "median of empty list")
        return n % 2 == 1 ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2
    }
    public static func interp(_ x: Double, _ xs: [Double], _ ys: [Double]) -> Double {
        let i: Int
        if x <= xs[0] { i = 0 } else if x >= xs[xs.count - 1] { i = xs.count - 2 }
        else { i = (0..<(xs.count - 1)).filter { xs[$0] <= x }.max()! }
        let x0 = xs[i], x1 = xs[i + 1], y0 = ys[i], y1 = ys[i + 1]
        return x1 == x0 ? y0 : y0 + (y1 - y0) * (x - x0) / (x1 - x0)
    }

    // ---- neutral reference

    static func neutralAB(_ labs: [[Double]], _ clip: [Bool]?) -> [Double] {
        var idx = neutral.filter { labs[$0][0] >= 25 && labs[$0][0] <= 85 && !((clip.map { !$0.isEmpty } ?? false) && clip![$0]) }
        if idx.count < 3 { idx = neutral.filter { labs[$0][0] >= 10 && labs[$0][0] <= 95 } }
        return [median(idx.map { labs[$0][1] }), median(idx.map { labs[$0][2] })]
    }
    static func rel(_ labs: [[Double]], _ clip: [Bool]?) -> [[Double]] {
        let n = neutralAB(labs, clip)
        return labs.map { [$0[0], $0[1] - n[0], $0[2] - n[1]] }
    }

    // ---- curve fitting

    static func pava(_ ys: [Double]) -> [Double] {
        var blocks = ys.map { (y: $0, w: 1.0, n: 1) }
        var i = 0
        while i < blocks.count - 1 {
            if blocks[i].y > blocks[i + 1].y {
                let (y0, w0, n0) = blocks[i], (y1, w1, n1) = blocks[i + 1]
                blocks[i] = ((y0 * w0 + y1 * w1) / (w0 + w1), w0 + w1, n0 + n1)
                blocks.remove(at: i + 1)
                i = max(0, i - 1)
            } else { i += 1 }
        }
        return blocks.flatMap { Array(repeating: $0.y, count: $0.n) }
    }

    /// fit_curve: monotone curve on 0–255 through (xs, ys), ≤ maxPoints knots including 0 and 255.
    public static func fitCurve(_ xs: [Double], _ ys: [Double], maxPoints: Int = 8, tol: Double = 0.75) -> [[Int]] {
        let pts = zip(xs, ys).sorted { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1 < $1.1 }
        var mx: [Double] = [], my: [Double] = []
        for (x, y) in pts {
            if let last = mx.last, abs(x - last) < 0.5 { my[my.count - 1] = (my[my.count - 1] + y) / 2 } else { mx.append(x); my.append(y) }
        }
        my = pava(my)
        // end slopes: least squares over the 3 end points, clamped to [0.5, 1.5] (fit_model.py end_slope);
        // the curve is extended along the measured trend, never flattened, so highlights are not clipped
        func endSlope(_ sel: [Int]) -> Double {
            if sel.count < 2 { return 1.0 }
            let ax = pySum(sel.map { mx[$0] }) / Double(sel.count)
            let ay = pySum(sel.map { my[$0] }) / Double(sel.count)
            let den = pySum(sel.map { pow(mx[$0] - ax, 2) })
            let sl = den != 0 ? pySum(sel.map { (mx[$0] - ax) * (my[$0] - ay) }) / den : 1.0
            return min(1.5, max(0.5, sl))
        }
        let c = mx.count
        let n3 = min(3, c)
        let s0 = endSlope(Array(0..<n3))
        let s1 = endSlope(Array((c - n3)..<c))
        let y0 = min(max(0.0, my[0] - s0 * mx[0]), my[0])
        let y255 = max(min(255.0, my[c - 1] + s1 * (255 - mx[c - 1])), my[c - 1])
        let dx = [0.0] + mx + [255.0], dy = [y0] + my + [y255]
        var knots = [0, dx.count - 1]
        while knots.count < maxPoints {
            let kx = knots.map { dx[$0] }, ky = knots.map { dy[$0] }
            var best: (Double, Int)?
            for i in 0..<dx.count where !knots.contains(i) {
                let e = abs(dy[i] - interp(dx[i], kx, ky))
                if best == nil || e > best!.0 || (e == best!.0 && i > best!.1) { best = (e, i) }
            }
            guard let (e, i) = best else { break }
            if e < tol { break }
            knots = (knots + [i]).sorted()
        }
        var out: [[Int]] = []
        for k in knots {
            let x = Int(pyRound(dx[k]))
            var y = Int(pyRound(min(255, max(0, dy[k]))))
            if let last = out.last, x <= last[0] { continue }
            if let last = out.last, y < last[1] { y = last[1] }
            out.append([x, y])
        }
        return out
    }
    static func curveEval(_ curve: [[Int]], _ x: Double) -> Double { interp(x, curve.map { Double($0[0]) }, curve.map { Double($0[1]) }) }

    // ---- Canon forward model (A1, A2)

    static func stepInterp(_ table: [String: Double], _ k0: Int) -> Double {
        let ks = [-4, -2, 0, 2, 4], k = max(-4, min(4, k0))
        func get(_ s: Int) -> Double { s == 0 ? 0.0 : table[String(s)]! }
        for (a, b) in zip(ks, ks.dropFirst()) where a <= k && k <= b {
            let t = Double(k - a) / Double(b - a)
            return get(a) + (get(b) - get(a)) * t
        }
        fatalError("unreachable")
    }
    static func stepInterpVec(_ table: [String: [Double]], _ k0: Int) -> [Double] {
        let ks = [-4, -2, 0, 2, 4], k = max(-4, min(4, k0))
        let width = table[String(steps[0])]!.count
        func get(_ s: Int) -> [Double] { s == 0 ? Array(repeating: 0.0, count: width) : table[String(s)]! }
        for (a, b) in zip(ks, ks.dropFirst()) where a <= k && k <= b {
            let t = Double(k - a) / Double(b - a), va = get(a), vb = get(b)
            return zip(va, vb).map { $0 + ($1 - $0) * t }
        }
        fatalError("unreachable")
    }
    static func stepInterpMat(_ table: [String: [[Double]]], _ k0: Int) -> [[Double]] {
        let ks = [-4, -2, 0, 2, 4], k = max(-4, min(4, k0))
        let ref = table[String(steps[0])]!
        func get(_ s: Int) -> [[Double]] { s == 0 ? ref.map { Array(repeating: 0.0, count: $0.count) } : table[String(s)]! }
        for (a, b) in zip(ks, ks.dropFirst()) where a <= k && k <= b {
            let t = Double(k - a) / Double(b - a), va = get(a), vb = get(b)
            return zip(va, vb).map { zip($0, $1).map { $0 + ($1 - $0) * t } }
        }
        fatalError("unreachable")
    }

    static func applyPoints(_ lab: [Double], _ points: [ColourPoint]) -> [Double] {
        if points.isEmpty { return lab }
        let hsl = rgbToHsl(labToSrgb(lab))
        let h = hsl[0], s = hsl[1], l = hsl[2]
        var dh = 0.0, ds = 0.0, dl = 0.0
        for p in points {
            var w = max(0.0, 1 - abs(hueDiff(h, p.sourceHSL[0])) / (p.hueRangeDeg / 2))
            if s < 5 { w = 0.0 }
            dh += w * p.hueShiftDeg; ds += w * p.satShift; dl += w * p.lumShift
        }
        if dh == 0 && ds == 0 && dl == 0 { return lab }
        return srgbToLab(hslToRgb([h + dh, s + ds, l + dl]))
    }

    static func canonRender(_ refRel: [[Double]], _ model: Model, _ ks: Int, _ kt: Int, _ curve: [[Int]], _ points: [ColourPoint], _ idx: [Int]) -> [Int: [Double]] {
        var out: [Int: [Double]] = [:]
        let dsat = stepInterpMat(model.canonSliders["saturation"]!, ks)
        let dtone = stepInterpMat(model.canonSliders["color_tone"]!, kt)
        for i in idx {
            let v = (0..<3).map { refRel[i][$0] + dsat[i][$0] + dtone[i][$0] }
            let L = curveEval(curve, v[0] * 2.55) / 2.55
            out[i] = applyPoints([L, v[1], v[2]], points)
        }
        return out
    }

    static func fitPoints(_ pred: [Int: [Double]], _ target: [Int: [Double]], _ idx: [Int], maxPoints: Int = 6, hueRange: Double = 60.0) -> [ColourPoint] {
        var hslP: [Int: [Double]] = [:], hslT: [Int: [Double]] = [:]
        for i in idx { hslP[i] = rgbToHsl(labToSrgb(pred[i]!)); hslT[i] = rgbToHsl(labToSrgb(target[i]!)) }
        var elig = idx.filter { hslP[$0]![1] >= 15 }
        var points: [ColourPoint] = []

        func resid(_ i: Int, _ pts: [ColourPoint]) -> [Double] {
            let cur = rgbToHsl(labToSrgb(applyPoints(pred[i]!, pts)))
            return [hueDiff(hslT[i]![0], cur[0]), hslT[i]![1] - cur[1], hslT[i]![2] - cur[2]]
        }
        func weight(_ i: Int, _ p: ColourPoint) -> Double { max(0.0, 1 - abs(hueDiff(hslP[i]![0], p.sourceHSL[0])) / (p.hueRangeDeg / 2)) }
        func solvePoint(_ p: inout ColourPoint, _ others: [ColourPoint]) {
            var num = [0.0, 0.0, 0.0], den = 0.0
            for i in elig {
                let w = weight(i, p)
                if w <= 0 { continue }
                let r = resid(i, others)
                for c in 0..<3 { num[c] += w * r[c] }
                den += w * w
            }
            if den == 0 { return }
            let lim = [30.0, 40.0, 25.0]
            let v = (0..<3).map { max(-lim[$0], min(lim[$0], num[$0] / den)) }
            p.hueShiftDeg = v[0]; p.satShift = v[1]; p.lumShift = v[2]
        }
        func err(_ pts: [ColourPoint]) -> Double {
            pySum(idx.map { de2000(applyPoints(pred[$0]!, pts), target[$0]!) })
        }
        for _ in 0..<maxPoints {
            var cand = elig.map { (de2000(applyPoints(pred[$0]!, points), target[$0]!), $0) }
            cand.sort { $0.0 != $1.0 ? $0.0 > $1.0 : $0.1 > $1.1 }
            cand = cand.filter { c in points.allSatisfy { abs(hueDiff(hslP[c.1]![0], $0.sourceHSL[0])) > 20 } }
            guard let first = cand.first, first.0 >= 2.0 else { break }
            let i = first.1
            var p = ColourPoint(sourceHSL: hslP[i]!.map { pyRound($0, 1) }, hueRangeDeg: hueRange, hueShiftDeg: 0, satShift: 0, lumShift: 0)
            let before = err(points)
            solvePoint(&p, points)
            if err(points + [p]) >= before - 0.5 {
                if let at = elig.firstIndex(of: i) { elig.remove(at: at) }
                continue
            }
            points.append(p)
            for _ in 0..<2 {
                for j in points.indices {
                    var q = points[j]
                    solvePoint(&q, Array(points[..<j]) + Array(points[(j + 1)...]))
                    points[j] = q
                }
            }
        }
        return points.map { ColourPoint(sourceHSL: $0.sourceHSL.map { pyRound($0, 2) }, hueRangeDeg: pyRound($0.hueRangeDeg, 2),
                                        hueShiftDeg: pyRound($0.hueShiftDeg, 2), satShift: pyRound($0.satShift, 2), lumShift: pyRound($0.lumShift, 2)) }
    }

    static func fitColourTarget(_ model: Model, _ targetLabs: [[Double]], _ targetClip: [Bool]) -> (curve: [[Int]], ks: Int, kt: Int, points: [ColourPoint], de00: DE00) {
        let ref = model.canonRef, rclip = model.canonClip
        let refRel = rel(ref, rclip), tgtRel = rel(targetLabs, targetClip)
        let ok = (0..<n).filter { !rclip[$0] && !targetClip[$0] }
        var neu = neutral.filter { ok.contains($0) }
        if neu.isEmpty { neu = neutral }
        let curve = fitCurve(neu.map { ref[$0][0] * 2.55 }, neu.map { targetLabs[$0][0] * 2.55 })
        let chrom = chromatic.filter { ok.contains($0) }
        var tgt: [Int: [Double]] = [:]
        for i in chrom { tgt[i] = tgtRel[i] }
        var best: (Double, Int, Int, [Int: [Double]])?
        for ks in -4...4 {
            for kt in -4...4 {
                let pr = canonRender(refRel, model, ks, kt, curve, [], chrom)
                let sum = pySum(chrom.map { de2000(pr[$0]!, tgt[$0]!) })
                let score = sum / Double(max(1, chrom.count)) + 0.05 * Double(abs(ks) + abs(kt))
                if best == nil || score < best!.0 { best = (score, ks, kt, pr) }
            }
        }
        let (_, ks, kt, pr) = best!
        let points = fitPoints(pr, tgt, chrom)
        let final = canonRender(refRel, model, ks, kt, curve, points, chrom)
        let std = chrom.map { de2000(refRel[$0], tgt[$0]!) }
        let mod = chrom.map { de2000(final[$0]!, tgt[$0]!) }.sorted()
        let de = DE00(standardMedian: pyRound(median(std), 2), modelMedian: pyRound(median(mod), 2),
                      modelP95: pyRound(mod[min(mod.count - 1, Int(0.95 * Double(mod.count)))], 2), patches: chrom.count)
        return (curve, ks, kt, points, de)
    }

    // ---- Ricoh slider operators (A4)

    static func sectorValue(_ bySector: [Double?], _ glob: Double, _ h: Double) -> Double {
        let vals = bySector.map { $0 ?? glob }
        for k in 0..<6 {
            let d = pyMod(h - sectors[k], 360)
            if d < 60 { return vals[k] + (vals[(k + 1) % 6] - vals[k]) * d / 60 }
        }
        return glob
    }
    static func ratioInterp(_ table: [String: Double?], _ v: Int) -> Double {
        var t: [String: Double] = [:]
        for (k, x) in table { if let x { t[k] = x - 1 } }
        return 1 + stepInterp(t, v)
    }
    static func sectorListInterp(_ table: [String: [Double?]], _ v: Int, _ fallback: [String: Double?], ratio: Bool) -> [Double] {
        var filled: [String: [Double]] = [:]
        for (k, lst) in table { filled[k] = lst.map { ($0 ?? (fallback[k]!!)) - (ratio ? 1 : 0) } }
        return stepInterpVec(filled, v).map { $0 + (ratio ? 1 : 0) }
    }

    static func applyRicohSliders(_ labs: [[Double]], _ recipe: Recipe, _ model: Model) -> [[Double]] {
        let sat = recipe.saturation, hue = recipe.hue
        var rGlob = 0.0, rSec: [Double] = [], hGlob = 0.0, hSec: [Double] = []
        if sat != 0 {
            rGlob = ratioInterp(model.satChroma, sat)
            rSec = sectorListInterp(model.satSector, sat, model.satChroma, ratio: true)
        }
        if hue != 0 {
            var t: [String: Double] = [:]
            for (k, x) in model.hueShift { if let x { t[k] = x } }
            hGlob = stepInterp(t, hue)
            hSec = sectorListInterp(model.hueSector, hue, model.hueShift, ratio: false)
        }
        return labs.map { lab in
            let L = lab[0]
            var dL = 0.0
            for name in toneSliders {
                let v = recipe.tone(name)
                if v != 0 { let tbl = model.tone[name]!; dL += interp(L, tbl.nodesL, stepInterpVec(tbl.deltaL, v)) }
            }
            let lch = labToLch(lab)
            var C = lch[1], h = lch[2]
            let h0 = h
            if sat != 0 && C > 3 { C *= sectorValue(rSec, rGlob, h0) }
            if hue != 0 && C > 3 { h += sectorValue(hSec, hGlob, h0) }
            return lchToLab([min(100.0, max(0.0, L + dL)), C, h])
        }
    }

    static func stepInterpContrast(_ tbl: [String: [Double]], _ k0: Int) -> [Double] {
        let ks = tbl.keys.compactMap { Int($0) }.sorted()
        let k = max(ks[0], min(ks[ks.count - 1], k0))
        for (a, b) in zip(ks, ks.dropFirst()) where a <= k && k <= b {
            let t = Double(k - a) / Double(b - a)
            return zip(tbl[String(a)]!, tbl[String(b)]!).map { $0 + ($1 - $0) * t }
        }
        return tbl[String(ks[0])]!
    }

    // ---- WB

    static func wbCanonBest(_ target: [Double], _ model: Model) -> WB {
        var best: (d: Double, name: String, qa: Int, qg: Int, res: Double)?
        let J = model.canonJ
        for (name, n0) in model.canonPresetsAB {
            for qa in -9...9 {
                for qg in -9...9 {
                    let a = n0[0] + J[0][0] * Double(qa) + J[0][1] * Double(qg)
                    let b = n0[1] + J[1][0] * Double(qa) + J[1][1] * Double(qg)
                    let r = pyHypot(a - target[0], b - target[1])
                    let d = r + 0.02 * Double(abs(qa) + abs(qg))
                    if best == nil || d < best!.d { best = (d, name, qa, qg, r) }
                }
            }
        }
        let b = best!
        return WB(preset: b.name, ab: b.qa, gm: b.qg, residual: pyRound(b.res, 2), atLimit: abs(b.qa) == 9 || abs(b.qg) == 9)
    }

    static func ricohNeutral(_ model: Model, _ preset: String, _ ab: Double, _ gm: Double, _ kelvin: Double?) throws -> [Double] {
        let J = model.ricohJ
        let base: [Double]
        if preset == "Kelvin" {
            let ks = model.ricohKelvin
            guard !ks.isEmpty, let kelvin else { throw Missing(what: "WB Kelvin not calibrated") }
            let mired = ks.map { 1e6 / $0[0] }
            let order = ks.indices.sorted { mired[$0] < mired[$1] }
            let xs = order.map { mired[$0] }
            base = [interp(1e6 / kelvin, xs, order.map { ks[$0][1] }), interp(1e6 / kelvin, xs, order.map { ks[$0][2] })]
        } else {
            guard let p = model.ricohPresets[preset] else { throw Missing(what: "WB \(preset) not calibrated") }
            base = p
        }
        return [base[0] + J[0][0] * ab + J[0][1] * gm, base[1] + J[1][0] * ab + J[1][1] * gm]
    }
}
