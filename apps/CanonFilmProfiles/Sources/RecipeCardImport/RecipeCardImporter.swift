import Foundation
import ImageIO
import CoreText
import Vision
import ProfileCore

public struct CardTextBlock: Codable, Sendable {
    public let text: String
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double
    public let confidence: Float
    public init(text: String, x: Double, y: Double, width: Double = 0.1,
                height: Double = 0.02, confidence: Float = 1) {
        self.text = text; self.x = x; self.y = y; self.width = width
        self.height = height; self.confidence = confidence
    }
}

public struct RecipeCardImportResult: Codable, Sendable {
    public var recipe: Recipe
    public let notices: [String]
    public let recognizedText: [CardTextBlock]
}

/// Local OCR and strict parsing for the labelled RicohCookBook download-card layout.
/// Images are data only; no recognized text is executed or treated as instructions.
public enum RecipeCardImporter {
    private static let fields: [(String, WritableKeyPath<Recipe, Int>)] = [
        ("SAT", \.saturation), ("HUE", \.hue), ("KEY", \.key),
        ("CONTRAST", \.contrast), ("CTRH", \.highlights), ("CTRS", \.shadows),
        ("SHARP", \.sharpness), ("SHADING", \.shading), ("CLARITY", \.clarity)
    ]
    private static func applicableFields(_ base: String) -> [(String, WritableKeyPath<Recipe, Int>)] {
        Recipe.monochromeBases.contains(base) ? Array(fields.dropFirst(2)) : fields
    }
    private static func identity(_ blocks: [CardTextBlock]) throws -> (base: String, header: [CardTextBlock]) {
        guard blocks.contains(where: { key($0.text).contains("RICOHCOOKBOOK") }) else {
            throw invalid("This does not look like a Ricoh Cookbook download card.")
        }
        // Common tone labels establish the header without requiring colour-only cells.
        let common = Set(fields.map(\.0))
        guard let gridTop = blocks.filter({ common.contains(gridKey($0.text)) }).map(\.y).max() else {
            throw invalid("Could not locate the card’s adjustment grid.")
        }
        let header = blocks.filter { $0.y > gridTop + 0.10 }
        let controlHeaders = header.filter({ key($0.text) == "IMAGECONTROL" })
        guard controlHeaders.count == 1, let controlHeader = controlHeaders.first else {
            throw invalid("Could not identify the card’s Image Control header.")
        }
        // Only the value directly below IMAGE CONTROL determines the mode.
        // A recipe title can itself be "Negative Film" or "Standard".
        let printedControls = header.filter { $0.y < controlHeader.y && $0.y > controlHeader.y - 0.065 }
        let matches = printedControls.compactMap { block in baseName(block.text) }
        if matches.isEmpty {
            if printedControls.count == 1, let printed = printedControls.first, printed.confidence >= 0.5 {
                let reasons=["HDRTONE":"It needs an HDR tone-mapping renderer; its shorter slider list is valid.","CROSSPROCESSING":"Its colour-variant renderer is not implemented.","CROSSPROCESS":"Its colour-variant renderer is not implemented.","CINEMAGREEN":"Its green-shadow rendering is not implemented.","SOLID":"This is a GR IV Monochrome-specific mode.","SOFT":"This is a GR IV Monochrome-specific mode.","HIGHCONTRAST":"This is a GR IV Monochrome-specific mode.","GRAINY":"This is a GR IV Monochrome-specific mode."]
                let explanation=reasons[key(printed.text)].map{" "+$0} ?? ""
                throw invalid("Image Control ‘\(printed.text)’ is not supported by this app yet.\(explanation) Your library was not changed.")
            }
        }
        guard matches.count == 1, let base = matches.first else {
            throw invalid("The card’s Image Control is unreadable, ambiguous or unsupported.")
        }
        return (base, header)
    }
    private static func baseName(_ text: String) -> String? {
        if key(text) == "MONOTONE" { return "BW Monotone" }
        return Recipe.bases.first { key($0) == key(text) }
    }
    public static func read(_ url: URL) throws -> RecipeCardImportResult {
        guard url.isFileURL else { throw invalid("Choose a downloaded image file.") }
        let info = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard info.isRegularFile == true, let bytes = info.fileSize, bytes > 0, bytes <= 25_000_000 else {
            throw invalid("Choose an image smaller than 25 MB.")
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 3200
              ] as CFDictionary), image.width >= 400, image.height >= 400 else {
            throw invalid("The image could not be read clearly. Use the original downloaded recipe card.")
        }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        request.usesLanguageCorrection = false // Preserve signs and camera abbreviations.
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        let blocks = (request.results ?? []).compactMap { observation -> CardTextBlock? in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let box = observation.boundingBox
            return CardTextBlock(text: candidate.string, x: box.midX, y: box.midY,
                                 width: box.width, height: box.height, confidence: candidate.confidence)
        }
        let completed = try readNumberCells(image, blocks: blocks)
        return try parse(completed, filename: url.lastPathComponent)
    }

    /// Vision can omit single digits. Normalize the original numeric ink into labelled
    /// lines for a second OCR pass. Only the fixed word VALUE is drawn; digits/signs
    /// are copied from the card, and any disagreement with the first pass rejects it.
    private static func readNumberCells(_ image: CGImage, blocks: [CardTextBlock]) throws -> [CardTextBlock] {
        let names = applicableFields(try identity(blocks).base).map(\.0)
        var anchors: [CardTextBlock] = []
        for name in names {
            let matches = blocks.filter { gridKey($0.text) == name }
            guard matches.count == 1, let match = matches.first else {
                throw invalid("Could not identify \(name) unambiguously. Use the original downloaded card.")
            }
            anchors.append(match)
        }
        let canvasWidth = 800, rowHeight = 150, canvasHeight = anchors.count * rowHeight + 40
        let bitmap = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let canvas = CGContext(data: nil, width: canvasWidth, height: canvasHeight, bitsPerComponent: 8,
                                     bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: bitmap) else {
            throw invalid("Could not prepare the card for text recognition.")
        }
        canvas.setFillColor(CGColor(gray: 1, alpha: 1))
        canvas.fill(CGRect(x: 0, y: 0, width: canvasWidth, height: canvasHeight))
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 120, nil)
        let cue = NSAttributedString(string: "VALUE", attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)
        ])
        let cueLine = CTLineCreateWithAttributedString(cue)
        let cueWidth = CTLineGetTypographicBounds(cueLine, nil, nil, nil)
        let digitX = cueWidth + 30
        var numericInkBounds: [CGRect] = []
        for (index, anchor) in anchors.enumerated() {
            // Proportions are relative to each detected label, not fixed image pixels.
            let rect = CGRect(x: (anchor.x - 0.07) * Double(image.width),
                              y: (1 - anchor.y - 0.083) * Double(image.height),
                              width: 0.14 * Double(image.width), height: 0.068 * Double(image.height)).integral
            guard let crop = image.cropping(to: rect),
                  let raw = CGContext(data: nil, width: crop.width, height: crop.height, bitsPerComponent: 8,
                                      bytesPerRow: crop.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: bitmap),
                  let memory = raw.data else { throw invalid("Could not locate the \(names[index]) number cell.") }
            raw.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
            let pixels = memory.assumingMemoryBound(to: UInt8.self)
            var left = crop.width, top = crop.height, right = -1, bottom = -1
            for y in 0..<crop.height { for x in 0..<crop.width {
                let offset = (y * crop.width + x) * 4
                // Remove pale card icons/background while retaining the dark numeric ink.
                let ink = pixels[offset] < 110 && pixels[offset + 1] < 110 && pixels[offset + 2] < 110
                let value: UInt8 = ink ? 0 : 255
                pixels[offset] = value; pixels[offset + 1] = value; pixels[offset + 2] = value; pixels[offset + 3] = 255
                if ink { left = min(left, x); right = max(right, x); top = min(top, y); bottom = max(bottom, y) }
            } }
            guard right > left, bottom > top, let binary = raw.makeImage(),
                  let ink = binary.cropping(to: CGRect(x: left, y: top, width: right - left + 1, height: bottom - top + 1)) else {
                throw invalid("The \(names[index]) number cell is blank or unreadable.")
            }
            // Convert the measured dark-ink bounds back to Vision's normalized
            // bottom-left coordinates. Pale icons are outside this region.
            numericInkBounds.append(CGRect(
                x: (rect.minX + Double(left)) / Double(image.width),
                y: 1 - (rect.minY + Double(bottom + 1)) / Double(image.height),
                width: Double(right - left + 1) / Double(image.width),
                height: Double(bottom - top + 1) / Double(image.height)))
            let baseline = Double((anchors.count - index - 1) * rowHeight + 30)
            let digitWidth = Double(ink.width) * 90 / Double(ink.height)
            guard digitWidth < Double(canvasWidth) - digitX - 10 else {
                throw invalid("The \(names[index]) number cell does not match the supported card layout.")
            }
            canvas.draw(ink, in: CGRect(x: digitX, y: baseline + 5, width: digitWidth, height: 90))
            canvas.textPosition = CGPoint(x: 10, y: baseline)
            CTLineDraw(cueLine, canvas)
        }
        guard let normalizedImage = canvas.makeImage() else { throw invalid("Could not read the card’s numbers.") }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate; request.usesLanguageCorrection = false; request.recognitionLanguages = ["en-US"]
        try VNImageRequestHandler(cgImage: normalizedImage, options: [:]).perform([request])
        var output = blocks
        for (index, anchor) in anchors.enumerated() {
            let center = Double((anchors.count - index - 1) * rowHeight + 80)
            let matches = (request.results ?? []).filter { abs($0.boundingBox.midY * Double(canvasHeight) - center) < 65 }
            guard matches.count == 1, let text = matches.first?.topCandidates(1).first,
                  text.confidence >= 0.5, text.string.uppercased().hasPrefix("VALUE") else {
                throw invalid("Could not read the \(names[index]) number unambiguously.")
            }
            // In an isolated numeric cell, OCR O/I/l are the digit shapes 0/1.
            let suffix = String(text.string.dropFirst(5)).uppercased()
                .replacingOccurrences(of: "O", with: "0").replacingOccurrences(of: "I", with: "1")
                .replacingOccurrences(of: "L", with: "1")
            guard let value = number(suffix), (-4...4).contains(value) else {
                throw invalid("Could not read a valid −4…+4 value for \(names[index]). Nothing was imported.")
            }
            func inCell(_ b: CardTextBlock) -> Bool {
                // Match the actual cropped numeric rectangle. The broader area
                // also includes pale icons, which Vision can misread as digits.
                abs(b.x - anchor.x) < 0.07 && b.y > anchor.y + 0.015 && b.y < anchor.y + 0.083
            }
            // Full-page OCR can read a pale icon as a number (“60” for
            // the glasses), or combine it with the digit below. Corroborate
            // only observations centered on the measured original dark ink.
            // Disagreements in that numeric region still stop the import.
            let inkBounds = numericInkBounds[index].insetBy(dx: -0.01, dy: -0.004)
            let originals = blocks.filter {
                inCell($0) && number($0.text) != nil &&
                inkBounds.contains(CGPoint(x: $0.x, y: $0.y))
            }
            guard originals.allSatisfy({ number($0.text) == value }) else {
                throw invalid("The two text reads disagree on \(names[index]): \(originals.map(\.text).joined(separator:" / ")) versus \(value). Nothing was imported.")
            }
            output.removeAll { inCell($0) && number($0.text) != nil }
            output.append(CardTextBlock(text: String(value), x: anchor.x, y: anchor.y + 0.04,
                                        height: 0.035, confidence: text.confidence))
        }
        return output
    }

    public static func parse(_ blocks: [CardTextBlock], filename: String) throws -> RecipeCardImportResult {
        let (base, header) = try identity(blocks)
        var recipe = Recipe()
        recipe.base = base
        if recipe.isCinemaYellow { recipe.family = "Ricoh GR IV" }
        var usedNumbers = Set<Int>()
        var labels: [CardTextBlock] = []
        for (label, path) in applicableFields(base) {
            let matches = blocks.filter { gridKey($0.text) == label }
            guard matches.count == 1, let anchor = matches.first else {
                throw invalid("Could not identify \(label) unambiguously. Use the original full-size card.")
            }
            labels.append(anchor)
            // Vision coordinates start at the bottom-left. Values sit above their labels.
            let candidates = blocks.enumerated().filter { _, block in
                number(block.text) != nil && abs(block.x - anchor.x) < 0.07 &&
                block.y > anchor.y + 0.015 && block.y < anchor.y + 0.083
            }.sorted { score($0.element, anchor) < score($1.element, anchor) }
            guard let value = candidates.first, !usedNumbers.contains(value.offset),
                  value.element.confidence >= 0.5, let n = number(value.element.text),
                  (-4...4).contains(n) else {
                throw invalid("Could not read a valid −4…+4 value for \(label). Nothing was imported.")
            }
            if candidates.count > 1 && score(candidates[1].element, anchor) - score(value.element, anchor) < 0.015 {
                throw invalid("The \(label) value is ambiguous. Nothing was imported.")
            }
            usedNumbers.insert(value.offset)
            recipe[keyPath: path] = n
        }
        let controlY=header.first{key($0.text)=="IMAGECONTROL"}!.y
        let names = header.filter {
            return $0.y < controlY-0.065 &&
                !$0.text.lowercased().hasPrefix("by ")
        }.sorted { $0.height > $1.height }
        guard let title = names.first, title.confidence >= 0.5,
              title.height > 0 else {
            throw invalid("Could not read the recipe name unambiguously.")
        }
        let titleLines=names.filter{$0.height>=title.height*0.70}.sorted{$0.y>$1.y}
        for line in titleLines {guard line.confidence>=0.5 else{throw invalid("Could not read the recipe name unambiguously.")}}
        if titleLines.count>1 {
            for index in 1..<titleLines.count {
                let a=titleLines[index-1],b=titleLines[index],gap=a.y-b.y
                guard abs((a.x-a.width/2)-(b.x-b.width/2))<0.045,gap>max(a.height,b.height)*0.65,gap<max(a.height,b.height)*2.2 else {
                    throw invalid("The recipe title is ambiguous. Use the original full-size card.")
                }
            }
        }
        let originalName = titleLines.map(\.text).joined(separator:" ").replacingOccurrences(of:#"\s+"#,with:" ",options:.regularExpression).trimmingCharacters(in:.whitespacesAndNewlines)
        recipe.name = cameraName(originalName, limit: 23)
        recipe.shortName = cameraName(originalName, limit: 14)
        guard !recipe.name.isEmpty else { throw invalid("The recipe name needs printable English characters.") }
        recipe.creator = header.first(where: { $0.text.lowercased().hasPrefix("by ") })
            .map { String($0.text.dropFirst(3)).trimmingCharacters(in: .whitespaces) } ?? ""
        recipe.sourceURL = "https://ricohcookbook.com"
        var settings = try footerRows(blocks, below: labels.map(\.y).min()!)
        if recipe.isCinemaYellow {
            settings.insert(ImportedSetting(key: "imageControl", label: "IMAGE CONTROL", value: base), at: 0)
        }
        guard let wbSetting = settings.first(where: { $0.key == "whiteBalance" }),
              !wbSetting.needsReview, let wb = wbSetting.value else {
            throw invalid("Could not read WHITE BALANCE. Use the original downloaded card.")
        }
        let parsed = try RecipeWhiteBalance.parseCardValue(wb)
        recipe.whiteBalance = parsed.mode; recipe.amberBlue = parsed.amberBlue; recipe.greenMagenta = parsed.greenMagenta;recipe.kelvin=parsed.kelvin
        var notices = ["Review the imported settings against the card before uploading."]
        var notes = ["Imported from Ricoh Cookbook card: \(filename)", "Original recipe name: \(originalName)",
                     "White balance on card: \(wb)"]
        if recipe.isCinemaYellow {
            notices.append(recipe.baseInterpretationDescription)
            notes.append("Image Control on card: \(base) — \(recipe.baseInterpretationDescription)")
        }
        if recipe.usesSceneDependentWB || recipe.whiteBalance == "Kelvin" { notices.append(recipe.wbApplicationDescription) }
        if recipe.name != originalName || recipe.shortName != originalName {
            notices.append("Camera labels were shortened or transliterated; the original name is retained in Notes.")
        }
        if recipe.isMonochrome {
            notices.append("Saturation and Hue are not applicable to this monochrome Image Control.")
            // A printed numeric colour control is unexpected on a monochrome card.
            // Retain it for review rather than silently changing the monochrome grade.
            for (label, _) in fields.prefix(2) {
                for anchor in blocks.filter({ gridKey($0.text) == label }) {
                    let values = blocks.filter { number($0.text) != nil && abs($0.x-anchor.x)<0.07 && $0.y>anchor.y+0.015 && $0.y<anchor.y+0.083 }
                    if !values.isEmpty {
                        settings.append(ImportedSetting(key: label.lowercased(), label: label == "SAT" ? "Saturation" : "Hue",
                                                        value: values.map(\.text).joined(separator: " / "), needsReview: true))
                    }
                }
            }
        }
        recipe.sourceSettings = settings
        if recipe.isMonochrome {
            recipe.bwFilter = recipe.sourceValue("filterEffect").flatMap(BWFilter.parse)
            recipe.toning = recipe.sourceValue("toning").flatMap(MonochromeToning.parse)
        }
        recipe.grainSettings = recipe.sourceValue("grain").flatMap(RecipeGrain.parse)
        if let grain = settings.first(where: { $0.key == "grain" && !$0.needsReview }),
           let value = grain.value, let mapped = RecipeGrainMapping.approximate(value) {
            recipe.grain = mapped
            if let detail=recipe.grainSettings,detail.intensity>0 {notices.append("Grain imported as \(detail.summary); its Canon texture is approximate.")}
        }
        for setting in settings {
            notes.append("\(setting.label): \(setting.value ?? "Unreadable") — \(recipe.sourceDisposition(setting))")
        }
        notices.append("Additional card settings are retained with their application status in the editor.")
        if !recipe.omissions.isEmpty {
            notices.append("\(recipe.omissions.joined(separator: ", ")) are not reproduced exactly by the current renderer.")
        }
        notes.append("Imported values use the existing Canon interpretation; they are not a calibrated Ricoh match. White balance uses the existing approximate creative tint; this does not set camera WB.")
        notes.append("Recognized card text:\n" + blocks.sorted {
            let rowA = Int(($0.y * 100).rounded()), rowB = Int(($1.y * 100).rounded())
            return rowA == rowB ? $0.x < $1.x : rowA > rowB
        }.map(\.text).joined(separator: "\n"))
        recipe.notes = notes.joined(separator: "\n\n")
        // Keep the existing explicit acknowledgement for unsupported detail controls.
        recipe.allowPartial = false
        try recipe.validate()
        return RecipeCardImportResult(recipe: recipe, notices: notices, recognizedText: blocks)
    }

    private static func invalid(_ message: String) -> ProfileError { .invalid(message) }
    private static func key(_ text: String) -> String {
        text.uppercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }
    private static func gridKey(_ text:String)->String {
        let normalized=key(text)
        return ["SATURATION":"SAT","HIGHLOWKEY":"KEY","SHARPNESS":"SHARP","CONTRASTHIGHLIGHT":"CTRH","CONTRASTHIGHLIGHTS":"CTRH","HIGHLIGHTCONTRAST":"CTRH","CONTRASTSHADOW":"CTRS","CONTRASTSHADOWS":"CTRS","SHADOWCONTRAST":"CTRS"][normalized] ?? normalized
    }
    private static func normalize(_ text: String) -> String {
        text.replacingOccurrences(of: "−", with: "-").replacingOccurrences(of: "–", with: "-")
            .replacingOccurrences(of: "—", with: "-").replacingOccurrences(of: "＋", with: "+")
    }
    private static func number(_ text: String) -> Int? {
        let t = normalize(text).filter { !$0.isWhitespace }
        guard t.range(of: #"^[+-]?\d{1,2}$"#, options: .regularExpression) != nil else { return nil }
        return Int(t)
    }
    private static func score(_ value: CardTextBlock, _ label: CardTextBlock) -> Double {
        abs(value.x - label.x) * 3 + value.y - label.y
    }
    private static func cameraName(_ text: String, limit: Int) -> String {
        let latin = (text.applyingTransform(.toLatin, reverse: false) ?? text)
            .folding(options: [.diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        return String(latin.filter { $0.isASCII && $0.asciiValue! >= 32 && $0.asciiValue! <= 126 }.prefix(limit))
            .trimmingCharacters(in: .whitespaces)
    }
    private static let footerLabels: [(String, String)] = [
        ("WHITEBALANCE", "whiteBalance"), ("HIGHLIGHTDR", "highlightDR"),
        ("SHADOWDR", "shadowDR"), ("TONING", "toning"), ("GRAIN", "grain"),
        ("FILTEREFFECT", "filterEffect"), ("METERING", "metering"),
        ("PERIPHERALILLUMINATION", "peripheralIllumination"), ("PERIPHERALILLUM", "peripheralIllumination"),
        ("NOISEREDUCTION", "noiseReduction"), ("EXPOSURECOMPENSATION", "exposureCompensation"),
        ("EXPOSURECOMP", "exposureCompensation"), ("ISO", "iso"),
        ("SNAPFOCUS","snapFocus"),("HDF","hdf"),("COLORTONE","colorTone"),("COLOURTONE","colorTone"),("HDRTONELEVEL","hdrToneLevel")
    ]
    private static func afterLabel(_ text: String, normalizedLabel: String) -> String? {
        var prefix = ""
        for i in text.indices {
            prefix += key(String(text[i]))
            if prefix == normalizedLabel {
                let rest = text[text.index(after: i)...].trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ":.")))
                return rest.isEmpty ? nil : rest
            }
        }
        return nil
    }
    private static func footerRows(_ blocks: [CardTextBlock], below gridBottom: Double) throws -> [ImportedSetting] {
        let footer = blocks.filter { $0.y < gridBottom - 0.018 && !key($0.text).contains("RICOHCOOKBOOK") }
        let anchors = footer.filter { block in
            let text = key(block.text)
            guard !text.isEmpty else { return false }
            if block.x < 0.40 { return true }
            // Vision may combine a label and value into one line. Its left edge
            // must still start in the label column, not the right-hand value column.
            return block.x - block.width / 2 < 0.20 && footerLabels.contains(where: { text.hasPrefix($0.0) })
        }.sorted { $0.y > $1.y }
        var result: [ImportedSetting] = []
        for anchor in anchors {
            let text = key(anchor.text)
            let known = footerLabels.first { text.hasPrefix($0.0) }
            let settingKey = known?.1 ?? "other-" + text
            let sameLine = footer.filter {
                $0.x > anchor.x + 0.12 && abs($0.y - anchor.y) < max(0.014, anchor.height * 0.8)
            }.sorted { $0.x < $1.x }
            let inline = known.flatMap { afterLabel(anchor.text, normalizedLabel: $0.0) }
            let value = inline ?? (sameLine.isEmpty ? nil : sameLine.map(\.text).joined(separator: " "))
            let label = inline == nil ? anchor.text : known!.0
            let review = anchor.confidence < 0.5 || value == nil || (inline == nil && sameLine.contains(where: { $0.confidence < 0.5 })) || known == nil
            if let index = result.firstIndex(where: { $0.key == settingKey }) {
                // Duplicates are not silently resolved. Mandatory WB fails below;
                // optional settings remain visible and require an owner's review.
                result[index].value = [result[index].value, value].compactMap { $0 }.joined(separator: " / ")
                result[index].needsReview = true
            } else {
                result.append(ImportedSetting(key: settingKey, label: label, value: value, needsReview: review))
            }
        }
        return result
    }
}
