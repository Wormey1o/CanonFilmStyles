import Foundation
import CryptoKit

/// Host-only, source-linked Canon interpretation. This model is separate from the
/// Effects Recipe and its three CUPROF slots.
public enum NativeStyleKind: UInt8, Codable, Sendable { case color = 0, mono = 1 }
public enum NativeStyle: UInt8, Codable, CaseIterable, Sendable {
    case standard = 0, portrait, landscape, neutral, faithful, monochrome, user1, user2, user3
}
public enum NativeWhiteBalance: UInt8, Codable, CaseIterable, Sendable {
    case auto = 0, daylight, shade, cloudy, tungsten, whiteFluorescent, flash
}
public enum NativeMonoFilter: UInt8, Codable, CaseIterable, Sendable { case none = 0, yellow, orange, red, green }
public enum NativeMonoToning: UInt8, Codable, CaseIterable, Sendable { case none = 0, sepia, blue, purple, green }

public struct NativeCanonTuple: Codable, Equatable, Sendable {
    public var style: NativeStyle
    public var kind: NativeStyleKind
    public var sharpness: Int
    public var contrast: Int
    public var saturation: Int
    public var tone: Int
    public var whiteBalance: NativeWhiteBalance
    public var amberBlue: Int
    public var greenMagenta: Int
    public var monoFilter: NativeMonoFilter
    public var monoToning: NativeMonoToning

    public init(style: NativeStyle = .standard, kind: NativeStyleKind = .color,
                sharpness: Int = 3, contrast: Int = 0, saturation: Int = 0, tone: Int = 0,
                whiteBalance: NativeWhiteBalance = .auto, amberBlue: Int = 0, greenMagenta: Int = 0,
                monoFilter: NativeMonoFilter = .none, monoToning: NativeMonoToning = .none) {
        self.style = style; self.kind = kind; self.sharpness = sharpness
        self.contrast = contrast; self.saturation = saturation; self.tone = tone
        self.whiteBalance = whiteBalance; self.amberBlue = amberBlue; self.greenMagenta = greenMagenta
        self.monoFilter = monoFilter; self.monoToning = monoToning
    }

    /// The one physically demonstrated tuple. This is a settings reference, not
    /// an assertion that its appearance is calibrated.
    public static let warm1 = NativeCanonTuple(sharpness: 3, contrast: -1, saturation: -1,
                                               tone: 0, whiteBalance: .daylight,
                                               amberBlue: 2, greenMagenta: 1)

    public func validate() throws {
        guard (0...7).contains(sharpness), (-4...4).contains(contrast),
              (-9...9).contains(amberBlue), (-9...9).contains(greenMagenta) else {
            throw ProfileError.invalid("Native sharpness must be 0–7, contrast −4…4 and WB shifts −9…9.")
        }
        if kind == .color {
            guard style != .monochrome, (-4...4).contains(saturation), (-4...4).contains(tone),
                  monoFilter == .none, monoToning == .none else {
                throw ProfileError.invalid("Colour tuples require saturation/tone −4…4 and empty monochrome controls.")
            }
        } else {
            guard style == .monochrome, saturation == 0, tone == 0 else {
                throw ProfileError.invalid("Monochrome tuples cannot also carry colour saturation/tone values.")
            }
        }
    }

    public var isRuntimeV1Supported: Bool {
        kind == .color && style == .standard && (whiteBalance == .auto || whiteBalance == .daylight)
    }

    public var canonicalDigest: String { NativeCanonical.digest(self) }
}

public struct NativeSourceField: Codable, Equatable, Sendable {
    public let key: String
    public let rawValue: String?
    public let confidence: Double?
    public let requiresReview: Bool
    public init(key: String, rawValue: String?, confidence: Double? = nil, requiresReview: Bool = false) {
        self.key = key; self.rawValue = rawValue; self.confidence = confidence; self.requiresReview = requiresReview
    }
}

public enum NativeSourceCompleteness: String, Codable, Sendable { case importedSnapshot, authoredBaseline, legacyCurrentValuesOnly }

public struct NativeSourceSnapshot: Codable, Equatable, Sendable {
    public let sourceRecipeID: UUID
    public let sourceRevision: UInt32
    public let originalRecipe: Recipe
    public let completeness: NativeSourceCompleteness
    public let normalizedImport: [NativeSourceField]
    public let recipeAtImportSHA256: String
    public let resolvedFactoryBodySHA256: String?
    public let resolvedFactoryHasGrain: Bool
    public let sourceDigest: String

    private struct DigestInput: Codable {
        let sourceRecipeID: UUID
        let sourceRevision: UInt32
        let originalRecipe: Recipe
        let completeness: NativeSourceCompleteness
        let normalizedImport: [NativeSourceField]
        let recipeAtImportSHA256: String
        let resolvedFactoryBodySHA256: String?
        let resolvedFactoryHasGrain: Bool
    }

    public static func capture(recipe: Recipe, normalizedImport: [NativeSourceField]?,
                               legacyCurrentValuesOnly: Bool = false,
                               compiler: ProfileCompiler? = nil) throws -> NativeSourceSnapshot {
        guard recipe.revision > 0 else { throw ProfileError.invalid("Native source revision must be positive.") }
        let recipeDigest = NativeCanonical.digest(recipe)
        var factoryDigest: String?
        var factoryHasGrain = false
        if let id = recipe.factoryID, let compiler {
            let body = try compiler.factoryBody(id)
            factoryDigest = NativeCanonical.sha256(body)
            factoryHasGrain = Int(Int32(bitPattern: body.u32(768 + 32 * 4))) > 0
        }
        let complete = normalizedImport != nil && !legacyCurrentValuesOnly
        let fields = normalizedImport ?? []
        guard fields.count <= 512, fields.allSatisfy({ !$0.key.isEmpty && $0.key.utf8.count <= 128 && ($0.rawValue?.utf8.count ?? 0) <= 4096 && ($0.confidence == nil || (0...1).contains($0.confidence!)) }) else {
            throw ProfileError.invalid("Native source snapshot fields are malformed or exceed bounds.")
        }
        let input = DigestInput(sourceRecipeID: recipe.id, sourceRevision: recipe.revision,
                                originalRecipe: recipe,
                                completeness: complete ? .importedSnapshot : .legacyCurrentValuesOnly,
                                normalizedImport: fields, recipeAtImportSHA256: recipeDigest,
                                resolvedFactoryBodySHA256: factoryDigest,
                                resolvedFactoryHasGrain: factoryHasGrain)
        return NativeSourceSnapshot(sourceRecipeID: recipe.id, sourceRevision: recipe.revision,
                                    originalRecipe: recipe,
                                    completeness: input.completeness, normalizedImport: fields,
                                    recipeAtImportSHA256: recipeDigest,
                                    resolvedFactoryBodySHA256: factoryDigest,
                                    resolvedFactoryHasGrain: factoryHasGrain,
                                    sourceDigest: NativeCanonical.digest(input))
    }

    public static func adoptCurrentAuthoredValues(recipe: Recipe, compiler: ProfileCompiler? = nil) throws -> NativeSourceSnapshot {
        var captured = try capture(recipe: recipe, normalizedImport: [], compiler: compiler)
        let input = DigestInput(sourceRecipeID: recipe.id, sourceRevision: recipe.revision,
                                originalRecipe: recipe, completeness: .authoredBaseline,
                                normalizedImport: [], recipeAtImportSHA256: captured.recipeAtImportSHA256,
                                resolvedFactoryBodySHA256: captured.resolvedFactoryBodySHA256,
                                resolvedFactoryHasGrain: captured.resolvedFactoryHasGrain)
        captured = NativeSourceSnapshot(sourceRecipeID: recipe.id, sourceRevision: recipe.revision,
                                        originalRecipe: recipe, completeness: .authoredBaseline,
                                        normalizedImport: [], recipeAtImportSHA256: captured.recipeAtImportSHA256,
                                        resolvedFactoryBodySHA256: captured.resolvedFactoryBodySHA256,
                                        resolvedFactoryHasGrain: captured.resolvedFactoryHasGrain,
                                        sourceDigest: NativeCanonical.digest(input))
        return captured
    }

    public var hasUnresolvedSource: Bool {
        completeness == .legacyCurrentValuesOnly ||
        (completeness == .importedSnapshot && normalizedImport.isEmpty) ||
        normalizedImport.contains(where: \.requiresReview)
    }

    public func validateIntegrity() throws {
        let input = DigestInput(sourceRecipeID: sourceRecipeID, sourceRevision: sourceRevision,
                                originalRecipe: originalRecipe,
                                completeness: completeness, normalizedImport: normalizedImport,
                                recipeAtImportSHA256: recipeAtImportSHA256,
                                resolvedFactoryBodySHA256: resolvedFactoryBodySHA256,
                                resolvedFactoryHasGrain: resolvedFactoryHasGrain)
        guard sourceRevision > 0, NativeCanonical.digest(originalRecipe) == recipeAtImportSHA256,
              NativeCanonical.digest(input) == sourceDigest else {
            throw ProfileError.invalid("Immutable native source snapshot digest mismatch.")
        }
    }

    public func relinked(to recipe: Recipe) throws -> NativeSourceSnapshot {
        let input = DigestInput(sourceRecipeID: recipe.id, sourceRevision: recipe.revision,
                                originalRecipe: originalRecipe,
                                completeness: completeness, normalizedImport: normalizedImport,
                                recipeAtImportSHA256: recipeAtImportSHA256,
                                resolvedFactoryBodySHA256: resolvedFactoryBodySHA256,
                                resolvedFactoryHasGrain: resolvedFactoryHasGrain)
        return NativeSourceSnapshot(sourceRecipeID: recipe.id, sourceRevision: recipe.revision,
                                    originalRecipe: originalRecipe,
                                    completeness: completeness, normalizedImport: normalizedImport,
                                    recipeAtImportSHA256: recipeAtImportSHA256,
                                    resolvedFactoryBodySHA256: resolvedFactoryBodySHA256,
                                    resolvedFactoryHasGrain: resolvedFactoryHasGrain,
                                    sourceDigest: NativeCanonical.digest(input))
    }
}

public enum NativeDifferenceClass: String, Codable, Sendable { case represented, approximated, omitted, unresolved }
public struct NativeDifference: Codable, Equatable, Sendable {
    public let id: String
    public let sourceField: String
    public let classification: NativeDifferenceClass
    public let summary: String
    public let requiresAcknowledgement: Bool
    public init(id: String, sourceField: String, classification: NativeDifferenceClass,
                summary: String, requiresAcknowledgement: Bool = true) {
        self.id = id; self.sourceField = sourceField; self.classification = classification
        self.summary = summary; self.requiresAcknowledgement = requiresAcknowledgement
    }
}

public struct NativeApproval: Codable, Equatable, Sendable {
    public let sourceDigest: String
    public let authoredRecipeDigest: String
    public let tupleDigest: String
    public let mappingVersion: String
    public let acknowledgedDifferenceIDs: [String]
    public let disclosedDifferencesDigest: String
    public let approvalDigest: String
    public let approvedAt: Date
}

public struct NativeRecipeRecord: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID { sourceRecipeID }
    public var sourceRecipeID: UUID
    public var sourceRevision: UInt32
    public var displayName: String
    public var shortName: String
    public var tuple: NativeCanonTuple
    public var source: NativeSourceSnapshot
    public var differences: [NativeDifference]
    public var mappingVersion: String
    public var authoredRecipeDigest: String
    public var approval: NativeApproval?

    public init(sourceRecipeID: UUID, sourceRevision: UInt32, displayName: String, shortName: String,
                tuple: NativeCanonTuple, source: NativeSourceSnapshot, differences: [NativeDifference],
                mappingVersion: String = "canon-explicit-v1", authoredRecipeDigest: String,
                approval: NativeApproval? = nil) {
        self.sourceRecipeID = sourceRecipeID; self.sourceRevision = sourceRevision
        self.displayName = displayName; self.shortName = shortName; self.tuple = tuple
        self.source = source; self.differences = differences; self.mappingVersion = mappingVersion
        self.authoredRecipeDigest = authoredRecipeDigest; self.approval = approval
    }
}

public struct NativeRecipeStore: Codable, Equatable, Sendable {
    public var schema: Int
    public var records: [NativeRecipeRecord]
    /// UUID references in the separate native namespace; does not modify Effects slots.
    public var slots: [UUID?]
    public init(schema: Int = 1, records: [NativeRecipeRecord] = [], slots: [UUID?] = [nil, nil, nil]) {
        self.schema = schema; self.records = records; self.slots = slots
    }
    public func validate() throws {
        guard schema == 1, slots.count == 3, records.count <= 256,
              Set(records.map(\.sourceRecipeID)).count == records.count else {
            throw ProfileError.invalid("Invalid native recipe companion store.")
        }
        let ids = Set(records.map(\.sourceRecipeID))
        guard slots.compactMap({ $0 }).allSatisfy(ids.contains) else {
            throw ProfileError.invalid("A native slot refers to a missing source recipe.")
        }
        for record in records { try NativeRecipeAuthoring.validate(record) }
    }
    public func save(to url: URL) throws {
        try validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
    public static func load(from url: URL) throws -> NativeRecipeStore {
        let info = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard info.isRegularFile == true, let size = info.fileSize, size <= 4_194_304 else {
            throw ProfileError.invalid("Native companion store is missing, not a regular file, or too large.")
        }
        let store = try JSONDecoder().decode(NativeRecipeStore.self, from: Data(contentsOf: url))
        try store.validate(); return store
    }
}

public enum NativeCanonical {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
    public static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    public static func digest<T: Encodable>(_ value: T) -> String { (try? sha256(encode(value))) ?? "" }
}

public enum NativeRecipeAuthoring {
    public static func draft(from recipe: Recipe, normalizedImport: [NativeSourceField]?,
                             compiler: ProfileCompiler? = nil) throws -> NativeRecipeRecord {
        let source = try NativeSourceSnapshot.capture(recipe: recipe, normalizedImport: normalizedImport,
                                                      legacyCurrentValuesOnly: normalizedImport == nil, compiler: compiler)
        let tuple = suggestedTuple(from: recipe)
        return NativeRecipeRecord(sourceRecipeID: recipe.id, sourceRevision: recipe.revision,
                                  displayName: recipe.name,
                                  shortName: String(recipe.shortName.prefix(14)), tuple: tuple,
                                  source: source, differences: differences(for: recipe, source: source, tuple: tuple),
                                  mappingVersion: "ricoh-native-unmeasured-v1",
                                  authoredRecipeDigest: NativeCanonical.digest(recipe))
    }

    public static func adoptCurrentAuthoredValuesAsSource(record: NativeRecipeRecord, for recipe: Recipe,
                                                          compiler: ProfileCompiler? = nil) throws -> NativeRecipeRecord {
        guard record.sourceRecipeID == recipe.id else {
            throw ProfileError.invalid("Native interpretation source identity does not match the Effects recipe.")
        }
        let snapshot = try NativeSourceSnapshot.adoptCurrentAuthoredValues(recipe: recipe, compiler: compiler)
        let adopted = NativeRecipeRecord(sourceRecipeID: recipe.id, sourceRevision: recipe.revision,
                                         displayName: record.displayName, shortName: record.shortName,
                                         tuple: record.tuple, source: snapshot,
                                         differences: differences(for: recipe, source: snapshot, tuple: record.tuple),
                                         mappingVersion: record.mappingVersion,
                                         authoredRecipeDigest: NativeCanonical.digest(recipe), approval: nil)
        return try refresh(record: adopted, for: recipe, compiler: compiler)
    }

    private static func suggestedTuple(from recipe: Recipe) -> NativeCanonTuple {
        let sourceSharp = max(-4, min(4, recipe.sharpness))
        let sharp = sourceSharp <= 0
            ? Int((Double(sourceSharp + 4) * 0.75).rounded())
            : 3 + sourceSharp
        func scaled(_ value: Int, by numerator: Double, bounded: ClosedRange<Int>) -> Int {
            max(bounded.lowerBound, min(bounded.upperBound, Int((Double(value) * numerator).rounded())))
        }
        let wb: NativeWhiteBalance = recipe.whiteBalance == "Daylight" ? .daylight : .auto
        return NativeCanonTuple(sharpness: sharp,
                                contrast: scaled(recipe.contrast, by: 0.5, bounded: -4...4),
                                saturation: scaled(recipe.saturation, by: 0.5, bounded: -4...4),
                                tone: 0, whiteBalance: wb,
                                amberBlue: scaled(recipe.amberBlue, by: 9.0 / 14.0, bounded: -9...9),
                                greenMagenta: scaled(recipe.greenMagenta, by: 9.0 / 14.0, bounded: -9...9))
    }

    public static func refresh(record: NativeRecipeRecord, for recipe: Recipe,
                               compiler: ProfileCompiler? = nil) throws -> NativeRecipeRecord {
        guard record.sourceRecipeID == recipe.id, record.source.sourceRecipeID == recipe.id else {
            throw ProfileError.invalid("Native interpretation source identity does not match the Effects recipe.")
        }
        var updated = record
        try record.source.validateIntegrity()
        if let factoryID = recipe.factoryID, let compiler {
            let currentFactoryDigest = NativeCanonical.sha256(try compiler.factoryBody(factoryID))
            guard currentFactoryDigest == record.source.resolvedFactoryBodySHA256 else {
                throw ProfileError.invalid("Resolved factory source changed; create a new native interpretation review.")
            }
        }
        updated.sourceRevision = recipe.revision
        updated.displayName = recipe.name
        updated.shortName = String(recipe.shortName.prefix(14))
        updated.authoredRecipeDigest = NativeCanonical.digest(recipe)
        updated.differences = differences(for: recipe, source: record.source, tuple: record.tuple)
        if !approvalMatches(updated) { updated.approval = nil }
        try validate(updated)
        return updated
    }

    public static func duplicate(record: NativeRecipeRecord, for recipe: Recipe,
                                 compiler: ProfileCompiler? = nil) throws -> NativeRecipeRecord {
        guard record.sourceRecipeID != recipe.id else {
            throw ProfileError.invalid("A native interpretation duplicate must have a new recipe UUID.")
        }
        try record.source.validateIntegrity()
        let linkedSource = try record.source.relinked(to: recipe)
        let copy = NativeRecipeRecord(sourceRecipeID: recipe.id, sourceRevision: recipe.revision,
                                      displayName: record.displayName, shortName: record.shortName,
                                      tuple: record.tuple, source: linkedSource,
                                      differences: differences(for: recipe, source: linkedSource, tuple: record.tuple),
                                      mappingVersion: record.mappingVersion,
                                      authoredRecipeDigest: NativeCanonical.digest(recipe), approval: nil)
        return try refresh(record: copy, for: recipe, compiler: compiler)
    }

    public static func approve(record: NativeRecipeRecord, for recipe: Recipe,
                               acknowledgedDifferenceIDs: Set<String>,
                               compiler: ProfileCompiler? = nil) throws -> NativeRecipeRecord {
        var current = try refresh(record: record, for: recipe, compiler: compiler)
        guard !current.source.hasUnresolvedSource else {
            throw ProfileError.invalid("Approval is blocked until the immutable imported source and all inputs are resolved.")
        }
        if recipe.factoryID != nil && compiler == nil {
            throw ProfileError.invalid("Approval requires resolving the current inherited factory body.")
        }
        guard current.source.resolvedFactoryBodySHA256 != nil || recipe.factoryID == nil else {
            throw ProfileError.invalid("Approval is blocked because inherited factory effects were not resolved.")
        }
        try current.tuple.validate()
        guard current.tuple.isRuntimeV1Supported else {
            throw ProfileError.invalid("This valid Canon tuple is a draft; current v1 execution supports Standard colour with Auto or Daylight WB only.")
        }
        let required = Set(current.differences.filter(\.requiresAcknowledgement).map(\.id))
        guard required.isSubset(of: acknowledgedDifferenceIDs),
              !current.differences.contains(where: { $0.classification == .unresolved }) else {
            throw ProfileError.invalid("Acknowledge every disclosed difference and resolve unknown source fields before approval.")
        }
        let ids = required.sorted()
        let input = ApprovalInput(sourceDigest: current.source.sourceDigest,
                                  authoredRecipeDigest: NativeCanonical.digest(recipe),
                                  tupleDigest: current.tuple.canonicalDigest,
                                  mappingVersion: current.mappingVersion,
                                  acknowledgedDifferenceIDs: ids,
                                  disclosedDifferencesDigest: NativeCanonical.digest(current.differences),
                                  displayName: current.displayName, shortName: current.shortName)
        let approval = NativeApproval(sourceDigest: input.sourceDigest,
                                      authoredRecipeDigest: input.authoredRecipeDigest,
                                      tupleDigest: input.tupleDigest,
                                      mappingVersion: input.mappingVersion,
                                      acknowledgedDifferenceIDs: ids,
                                      disclosedDifferencesDigest: input.disclosedDifferencesDigest,
                                      approvalDigest: NativeCanonical.digest(input), approvedAt: Date())
        current.approval = approval
        return current
    }

    private struct ApprovalInput: Codable {
        let sourceDigest, authoredRecipeDigest, tupleDigest, mappingVersion: String
        let acknowledgedDifferenceIDs: [String]
        let disclosedDifferencesDigest: String
        let displayName: String
        let shortName: String
    }

    public static func isApprovalCurrent(record: NativeRecipeRecord, for recipe: Recipe) -> Bool {
        record.sourceRecipeID == recipe.id && record.sourceRevision == recipe.revision &&
        record.authoredRecipeDigest == NativeCanonical.digest(recipe) && approvalMatches(record)
    }

    public static func approvalMatches(_ record: NativeRecipeRecord) -> Bool {
        guard let approval = record.approval else { return false }
        guard (try? record.source.validateIntegrity()) != nil else { return false }
        let input = ApprovalInput(sourceDigest: record.source.sourceDigest,
                                  authoredRecipeDigest: record.authoredRecipeDigest,
                                  tupleDigest: record.tuple.canonicalDigest,
                                  mappingVersion: record.mappingVersion,
                                  acknowledgedDifferenceIDs: approval.acknowledgedDifferenceIDs.sorted(),
                                  disclosedDifferencesDigest: NativeCanonical.digest(record.differences),
                                  displayName: record.displayName, shortName: record.shortName)
        return record.source.sourceDigest == approval.sourceDigest &&
               record.authoredRecipeDigest == approval.authoredRecipeDigest &&
               record.tuple.canonicalDigest == approval.tupleDigest &&
               record.mappingVersion == approval.mappingVersion &&
               approval.disclosedDifferencesDigest == NativeCanonical.digest(record.differences) &&
               approval.approvalDigest == NativeCanonical.digest(input) &&
               Set(approval.acknowledgedDifferenceIDs).count == approval.acknowledgedDifferenceIDs.count &&
               Set(record.differences.filter(\.requiresAcknowledgement).map(\.id)).isSubset(of: Set(approval.acknowledgedDifferenceIDs))
    }

    public static func validate(_ record: NativeRecipeRecord) throws {
        try record.source.validateIntegrity()
        guard record.sourceRecipeID == record.source.sourceRecipeID,
              record.sourceRevision > 0, record.source.sourceRevision > 0,
              record.mappingVersion.utf8.count <= 48, !record.mappingVersion.isEmpty,
              record.displayName.utf8.count <= 23, record.shortName.utf8.count <= 14,
              record.displayName.utf8.allSatisfy({ 32...126 ~= $0 }),
              record.shortName.utf8.allSatisfy({ 32...126 ~= $0 }),
              Set(record.differences.map(\.id)).count == record.differences.count else {
            throw ProfileError.invalid("Native record identity, mapping version or difference IDs are invalid.")
        }
        try record.tuple.validate()
        if record.approval != nil && !approvalMatches(record) {
            throw ProfileError.invalid("Native approval digest is stale or invalid.")
        }
    }

    private static func differences(for recipe: Recipe, source: NativeSourceSnapshot,
                                    tuple: NativeCanonTuple) -> [NativeDifference] {
        var out: [NativeDifference] = []
        func add(_ field: String, _ cls: NativeDifferenceClass, _ message: String) {
            guard !out.contains(where: { $0.sourceField == field }) else { return }
            out.append(NativeDifference(id: "\(field).\(cls.rawValue)", sourceField: field,
                                        classification: cls, summary: message))
        }
        let original = source.originalRecipe
        if original.factoryID != nil && source.resolvedFactoryBodySHA256 == nil {
            add("factory", .unresolved, "Inherited factory rendering was not resolved; native approval is blocked.")
        } else if original.factoryID != nil {
            add("factory", .omitted, "The resolved factory rendering is retained in provenance, not reproduced by the native tuple.")
            if source.resolvedFactoryHasGrain { add("factory.grain", .omitted, "Inherited factory grain is not reproduced by the native tuple.") }
        }
        if original.base != "Standard" || original.factoryID != nil || recipe.base != original.base || recipe.factoryID != original.factoryID {
            add("base", .omitted, "The source base/factory ‘\(original.base)’ and current Effects base ‘\(recipe.base)’ are not Canon style mappings; the native Standard choice is separate.")
        } else {
            add("base", .represented, "Canon Standard is explicitly selected; this does not claim a Ricoh rendering match.")
        }
        for (field, sourceValue, currentValue) in [("sharpness", original.sharpness, recipe.sharpness),
                                                    ("contrast", original.contrast, recipe.contrast),
                                                    ("saturation", original.saturation, recipe.saturation),
                                                    ("amberBlue", original.amberBlue, recipe.amberBlue),
                                                    ("greenMagenta", original.greenMagenta, recipe.greenMagenta)] {
            add(field, .approximated, "Source Ricoh \(field)=\(sourceValue) has an unmeasured scaled suggestion; current Effects value=\(currentValue). This is not equal-number equivalence; review the separate Canon tuple.")
        }
        if original.hue != 0 || recipe.hue != 0 { add("hue", .omitted, "Source/current Ricoh hue (\(original.hue)/\(recipe.hue)) is not Canon colour tone and is not copied.") }
        if original.key != 0 || recipe.key != 0 { add("key", .omitted, "Source/current Ricoh key (\(original.key)/\(recipe.key)) has no standard native Canon control.") }
        if original.highlights != 0 || original.shadows != 0 || recipe.highlights != 0 || recipe.shadows != 0 {
            add("curves", .omitted, "Source/current separate highlight-shadow curves (\(original.highlights)/\(original.shadows), \(recipe.highlights)/\(recipe.shadows)) have no standard native control.")
        }
        if original.shading != 0 || recipe.shading != 0 { add("shading", .omitted, "Source/current Ricoh shading (\(original.shading)/\(recipe.shading)) is not represented in this native tuple.") }
        if original.clarity != 0 || recipe.clarity != 0 { add("clarity", .omitted, "Source/current Ricoh clarity (\(original.clarity)/\(recipe.clarity)) has no established native Canon equivalent.") }
        func activeSetting(_ settings: [ImportedSetting]?, _ key: String) -> Bool {
            (settings ?? []).contains { setting in
                guard setting.key == key, !setting.isOff else { return false }
                if key == "grain" && setting.isOptional && recipe.grain == nil && recipe.grainSettings == nil { return false }
                return true
            }
        }
        if original.grain != nil || original.grainSettings != nil || original.effectiveGrain != nil ||
           recipe.grain != nil || recipe.grainSettings != nil || recipe.effectiveGrain != nil ||
           activeSetting(original.sourceSettings, "grain") || activeSetting(recipe.sourceSettings, "grain") {
            add("grain", .omitted, "Source/current grain (\(original.effectiveGrain?.summary ?? "none") / \(recipe.effectiveGrain?.summary ?? "none")) is not reproduced by this native backend.")
        }
        if original.bwFilter?.enabled == true || original.effectiveBWFilter?.enabled == true || recipe.bwFilter?.enabled == true || recipe.effectiveBWFilter?.enabled == true ||
           activeSetting(original.sourceSettings, "filterEffect") || activeSetting(recipe.sourceSettings, "filterEffect") {
            add("bwFilter", .omitted, "Source/current Effects B&W filter is not represented in this colour native tuple.")
        }
        if original.toning.map({ $0 != .off }) == true || original.effectiveToning.map({ $0 != .off }) == true || recipe.toning.map({ $0 != .off }) == true || recipe.effectiveToning.map({ $0 != .off }) == true ||
           activeSetting(original.sourceSettings, "toning") || activeSetting(recipe.sourceSettings, "toning") {
            add("toning", .omitted, "Source/current Effects toning is not represented in this native tuple.")
        }
        for setting in (original.sourceSettings ?? []) + (recipe.sourceSettings ?? []) where
            ["colorTone", "hdrToneLevel"].contains(setting.key) && !setting.isOff {
            let cls: NativeDifferenceClass = setting.needsReview ? .unresolved : .omitted
            add("colorTone", cls, "Ricoh colour tone/HDR tone source value ‘\(setting.value ?? "unknown")’ is not Canon colour tone and is not reproduced.")
        }
        let wbMessage = "Source/current Ricoh WB ‘\(original.whiteBalance)’/‘\(recipe.whiteBalance)’ is not inferred; the editable Canon Auto/Daylight choice and scaled shifts are explicit suggestions, not claimed equivalents."
        add("whiteBalance", .approximated, wbMessage)
        if original.sourceSettings?.contains(where: \.needsReview) == true || source.normalizedImport.contains(where: \.requiresReview) {
            add("sourceInputs", .unresolved, "One or more imported source inputs still require review.")
        }
        if source.completeness == .legacyCurrentValuesOnly {
            add("sourceSnapshot", .unresolved, "This older recipe has current authored values only; original import inputs were not preserved. Adopt current values to create a disclosed baseline.")
        } else if source.completeness == .authoredBaseline {
            add("sourceSnapshot", .approximated, "Current authored values were explicitly adopted as the native source; original Ricoh card provenance is unavailable.")
        }
        let recipeSourceFields: Set<String> = ["base", "whiteBalance", "sharpness", "contrast", "saturation", "hue", "key", "highlights", "shadows", "shading", "clarity", "amberBlue", "greenMagenta"]
        let recognizedCardFields: Set<String> = ["imageControl", "whiteBalance", "grain", "filterEffect", "toning", "colorTone", "hdrToneLevel"]
        let recognizedRecipeContext: Set<String> = ["imageControl", "whiteBalance"]
        for field in source.normalizedImport {
            if field.key.hasPrefix("ocr.") { continue }
            if recognizedRecipeContext.contains(field.key) { continue }
            if field.key.hasPrefix("source."), recipeSourceFields.contains(String(field.key.dropFirst(7))) { continue }
            if field.key.hasPrefix("card."), recognizedCardFields.contains(String(field.key.dropFirst(5))) { continue }
            if field.key.hasPrefix("source."), !recipeSourceFields.contains(String(field.key.dropFirst(7))) {
                add(field.key, .unresolved, "Imported source field ‘\(field.key)’ has no recognized semantic mapping and needs review.")
                continue
            }
            let cls: NativeDifferenceClass = field.requiresReview ? .unresolved : .omitted
            add(field.key, cls, "Imported card field ‘\(field.key)’ is retained in provenance and is not reproduced by the native tuple.")
        }
        for field in source.normalizedImport where field.key.hasPrefix("ocr.") && field.requiresReview {
            add(field.key, .unresolved, "OCR input ‘\(field.key)’ requires review before this native interpretation can be approved.")
        }
        add("nativeTuple", .approximated, "This complete Canon tuple is a separate interpretation; appearance has not been visually calibrated.")
        return out
    }
}
