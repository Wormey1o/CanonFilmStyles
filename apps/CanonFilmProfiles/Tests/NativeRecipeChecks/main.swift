import Foundation
import ProfileCore

var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw ProfileError.invalid(message) }
    checks += 1
}
func fails(_ message: String, _ body: () throws -> Void) throws {
    do { try body() } catch { checks += 1; return }
    throw ProfileError.invalid("Expected rejection: \(message)")
}
func makeRecipe() -> Recipe {
    var recipe = Recipe(); recipe.name = "Source recipe"; recipe.shortName = "Source"
    recipe.base = "Standard"; recipe.whiteBalance = "Auto"
    return recipe
}

let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let profileCompiler = try ProfileCompiler(factoryBook: Data(contentsOf: app.appendingPathComponent("Resources/CFLOOKS.BIN")))

// The versioned suggestion is explicit and scaled, never copied as equal Ricoh values.
var ricoh = makeRecipe(); ricoh.base = "Negative Film"; ricoh.sharpness = -4
ricoh.contrast = -3; ricoh.saturation = 3; ricoh.hue = 2
ricoh.highlights = 2; ricoh.shadows = -1
ricoh.whiteBalance = "Fluorescent D"; ricoh.amberBlue = 14; ricoh.greenMagenta = -14
ricoh.grain = 2
let sourceFields = [
    NativeSourceField(key: "source.base", rawValue: "Negative Film"),
    NativeSourceField(key: "card.grain", rawValue: "Strong"),
    NativeSourceField(key: "card.whiteBalance", rawValue: "Fluorescent D A2 G1"),
    NativeSourceField(key: "card.imageControl", rawValue: "Negative Film"),
    NativeSourceField(key: "ocr.title", rawValue: "Negative Film", confidence: 0.99)
]
let draft = try NativeRecipeAuthoring.draft(from: ricoh, normalizedImport: sourceFields, compiler: profileCompiler)
try check(draft.mappingVersion == "ricoh-native-unmeasured-v1", "versioned unmeasured mapping")
try check(draft.tuple.sharpness == 0 && draft.tuple.contrast == -2 && draft.tuple.saturation == 2, "scaled numeric suggestion")
try check(draft.tuple.whiteBalance == .auto && draft.tuple.amberBlue == 9 && draft.tuple.greenMagenta == -9, "WB alternatives and bounded shift scaling")
try check(draft.differences.contains(where: { $0.sourceField == "base" && $0.classification == .omitted }), "base omission disclosed")
try check(draft.differences.contains(where: { $0.sourceField == "hue" && $0.classification == .omitted }), "Ricoh hue is not Canon tone")
try check(draft.differences.contains(where: { $0.sourceField == "curves" && $0.classification == .omitted }), "both curve axes disclosed")
try check(draft.differences.contains(where: { $0.sourceField == "grain" && $0.classification == .omitted }), "imported grain effect retained as semantic omission")
try check(!draft.differences.contains(where: { ["card.whiteBalance", "card.imageControl"].contains($0.sourceField) }), "recognized WB/base metadata is not reported as an unknown omission")
try check(!draft.differences.contains(where: { $0.sourceField == "ocr.title" }), "OCR provenance does not create effect acknowledgement")
try check(draft.source.originalRecipe.grain == 2, "immutable source Recipe retained")
var mapped = try NativeRecipeAuthoring.approve(record: draft, for: ricoh,
    acknowledgedDifferenceIDs: Set(draft.differences.filter(\.requiresAcknowledgement).map(\.id)))
let mappedBank = try NativeRecipeCompiler.compile(store: NativeRecipeStore(records: [mapped], slots: [ricoh.id, nil, nil]),
    currentRecipes: [ricoh], selectedSlot: 0, attemptLimit: 1).sidecar
let omittedMask = mappedBank.u32(32 + 16)
try check(omittedMask & (1 << 2) != 0 && omittedMask & (1 << 14) == 0, "Ricoh hue and Canon color tone use separate mask bits")
try check(omittedMask & (1 << 5) != 0 && omittedMask & (1 << 6) != 0, "separate highlight and shadow omissions")
try NativeRecipeCompiler.validate(sidecar: mappedBank); checks += 1

// Effects edits made after the import snapshot remain visible as omissions.
var authoredEffects = makeRecipe()
let effectsSourceFields = [NativeSourceField(key: "ocr.caption", rawValue: "Film card", confidence: 0.99)]
let effectsDraft = try NativeRecipeAuthoring.draft(from: authoredEffects, normalizedImport: effectsSourceFields)
authoredEffects.revision += 1; authoredEffects.grain = 2; authoredEffects.highlights = 1
authoredEffects.shadows = -1; authoredEffects.shading = 1; authoredEffects.clarity = 2
authoredEffects.bwFilter = BWFilter(red: 90, green: 20, blue: -10); authoredEffects.toning = .sepia
let effectsUpdated = try NativeRecipeAuthoring.refresh(record: effectsDraft, for: authoredEffects)
for field in ["grain", "curves", "shading", "clarity", "bwFilter", "toning"] {
    try check(effectsUpdated.differences.contains(where: { $0.sourceField == field && $0.classification == .omitted }), "new Effects \(field) remains disclosed")
}
try check(effectsUpdated.approval == nil, "Effects edits revoke earlier native approval")
let effectsApproved = try NativeRecipeAuthoring.approve(record: effectsUpdated, for: authoredEffects,
    acknowledgedDifferenceIDs: Set(effectsUpdated.differences.filter(\.requiresAcknowledgement).map(\.id)))
let effectsBank = try NativeRecipeCompiler.compile(store: NativeRecipeStore(records: [effectsApproved], slots: [authoredEffects.id,nil,nil]),
    currentRecipes: [authoredEffects], selectedSlot: 0, attemptLimit: 1).sidecar
let effectsOmitted = effectsBank.u32(32 + 16)
for bit in [5, 6, 8, 9, 11, 12, 13] {
    try check(effectsOmitted & (1 << bit) != 0, "compiled omitted-effect bit \(bit)")
}

// Approval blocks unresolved OCR, then becomes valid after explicit resolution and complete acknowledgements.
var unresolved = try NativeRecipeAuthoring.draft(from: makeRecipe(), normalizedImport: [
    NativeSourceField(key: "ocr.sharpness", rawValue: "?", confidence: 0.2, requiresReview: true)
])
try fails("unresolved OCR") {
    unresolved = try NativeRecipeAuthoring.approve(record: unresolved, for: unresolved.source.originalRecipe,
        acknowledgedDifferenceIDs: Set(unresolved.differences.map(\.id)))
}

// Legacy values can be explicitly adopted as a disclosed new authored baseline.
let legacyRecipe = makeRecipe()
var legacy = try NativeRecipeAuthoring.draft(from: legacyRecipe, normalizedImport: nil)
try check(legacy.source.completeness == .legacyCurrentValuesOnly, "old record remains provenance-incomplete")
legacy = try NativeRecipeAuthoring.adoptCurrentAuthoredValuesAsSource(record: legacy, for: legacyRecipe)
try check(legacy.source.completeness == .authoredBaseline, "explicit authored baseline")
try check(legacy.differences.contains(where: { $0.sourceField == "sourceSnapshot" && $0.classification == .approximated }), "missing original provenance disclosed")
legacy = try NativeRecipeAuthoring.approve(record: legacy, for: legacyRecipe,
    acknowledgedDifferenceIDs: Set(legacy.differences.filter(\.requiresAcknowledgement).map(\.id)))
try check(NativeRecipeAuthoring.isApprovalCurrent(record: legacy, for: legacyRecipe), "current approval")
var changedRecipe = legacyRecipe; changedRecipe.sharpness = 1; changedRecipe.revision += 1
try check(!NativeRecipeAuthoring.isApprovalCurrent(record: legacy, for: changedRecipe), "edited recipe invalidates approval")
let refreshed = try NativeRecipeAuthoring.refresh(record: legacy, for: changedRecipe)
try check(refreshed.approval == nil, "refresh clears stale approval")

// Approval binds disclosure text and source snapshot contents, not only IDs.
var altered = legacy
altered.differences[0] = NativeDifference(id: legacy.differences[0].id,
    sourceField: legacy.differences[0].sourceField, classification: legacy.differences[0].classification,
    summary: "Changed disclosure")
try check(!NativeRecipeAuthoring.approvalMatches(altered), "changed disclosure invalidates approval")
let storeEncoder = JSONEncoder(); var storeData = try storeEncoder.encode(NativeRecipeStore(records: [draft], slots: [ricoh.id, nil, nil]))
var storeJSON = try JSONSerialization.jsonObject(with: storeData) as! [String: Any]
var recordsJSON = storeJSON["records"] as! [[String: Any]]
var recordJSON = recordsJSON[0]
var sourceJSON = recordJSON["source"] as! [String: Any]
var fieldsJSON = sourceJSON["normalizedImport"] as! [[String: Any]]
fieldsJSON[0]["rawValue"] = "tampered"
sourceJSON["normalizedImport"] = fieldsJSON; recordJSON["source"] = sourceJSON
recordsJSON[0] = recordJSON; storeJSON["records"] = recordsJSON
storeData = try JSONSerialization.data(withJSONObject: storeJSON)
let tamperedStore = try JSONDecoder().decode(NativeRecipeStore.self, from: storeData)
try fails("modified source snapshot") { try tamperedStore.validate() }

// Duplicate identity relinks provenance, but never copies approval.
var duplicateRecipe = legacyRecipe; duplicateRecipe.id = UUID()
let duplicate = try NativeRecipeAuthoring.duplicate(record: legacy, for: duplicateRecipe)
try check(duplicate.sourceRecipeID == duplicateRecipe.id && duplicate.source.sourceRecipeID == duplicateRecipe.id, "duplicate source link")
try check(duplicate.approval == nil, "duplicate starts as draft")

// Separate native slots compile to the exact fixed 512-byte format and leave Effects data untouched.
let effectsLibrary = RecipeLibrary(recipes: [legacyRecipe], slots: [nil, nil, nil])
let effectsJSONBefore = try NativeCanonical.encode(effectsLibrary)
var warm = try NativeRecipeAuthoring.draft(from: legacyRecipe, normalizedImport: sourceFields, compiler: profileCompiler)
warm.tuple = .warm1
warm = try NativeRecipeAuthoring.refresh(record: warm, for: legacyRecipe, compiler: profileCompiler)
warm = try NativeRecipeAuthoring.approve(record: warm, for: legacyRecipe,
    acknowledgedDifferenceIDs: Set(warm.differences.filter(\.requiresAcknowledgement).map(\.id)), compiler: profileCompiler)
let nativeStore = NativeRecipeStore(records: [warm], slots: [legacyRecipe.id, nil, nil])
let compiled = try NativeRecipeCompiler.compile(store: nativeStore, currentRecipes: [legacyRecipe],
    profileCompiler: profileCompiler, selectedSlot: 0, attemptLimit: 2)
try check(compiled.sidecar.count == 512, "fixed bank size")
try NativeRecipeCompiler.validate(sidecar: compiled.sidecar); checks += 1
try check(compiled.report.selectedNativeRecipeID == 61001 && compiled.report.attemptLimit == 2 && compiled.report.approvalCurrent, "selected identity and attempt policy")
try check(compiled.report.slots.count == 3 && compiled.report.slots[0].sourceRecipeID == legacyRecipe.id.uuidString.lowercased(), "slot provenance mapping")
let effectsJSONAfter = try NativeCanonical.encode(effectsLibrary)
try check(effectsJSONAfter == effectsJSONBefore, "native storage does not mutate Effects library/slots")
let off = try NativeRecipeCompiler.compile(store: nativeStore, currentRecipes: [legacyRecipe], selectedSlot: 0, attemptLimit: 0)
try check(off.report.selectedNativeRecipeID == 0 && off.report.selectedSlot == nil && off.report.attemptLimit == 0, "zero cap forces effective OFF")
try check(off.report.slots[0].enabled, "OFF startup may retain separately reviewed bank entries")
try fails("active unapproved draft") {
    _ = try NativeRecipeCompiler.compile(store: NativeRecipeStore(records: [draft], slots: [ricoh.id, nil, nil]),
        currentRecipes: [ricoh], selectedSlot: 0, attemptLimit: 1)
}
var corrupt = compiled.sidecar; corrupt[48] ^= 1
try fails("sidecar checksum") { try NativeRecipeCompiler.validate(sidecar: corrupt) }
var reserved = compiled.sidecar; reserved[32 + 148] = 1; reserved.put32(0, 28); reserved.put32(reserved.fnv32(), 28)
try fails("reserved sidecar byte") { try NativeRecipeCompiler.validate(sidecar: reserved) }
try fails("invalid Canon range") { try NativeCanonTuple(sharpness: 8).validate() }
try fails("unsupported runtime style") {
    var unsupported = warm; unsupported.tuple.style = .portrait
    _ = try NativeRecipeCompiler.compile(store: NativeRecipeStore(records: [unsupported], slots: [legacyRecipe.id, nil, nil]),
        currentRecipes: [legacyRecipe], selectedSlot: 0, attemptLimit: 1)
}

print("PASS \(checks) native authoring/compiler checks")
