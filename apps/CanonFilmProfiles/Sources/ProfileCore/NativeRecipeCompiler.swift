import Foundation

public struct NativeAuthoringReport: Codable, Equatable, Sendable {
    public let schema: Int
    public let status: String
    public let nativeInterface: String
    public let sourceRecipeID: String?
    public let sourceRevision: UInt32?
    public let sourceDigest: String?
    public let authoredRecipeDigest: String?
    public let tupleDigest: String?
    public let mappingVersion: String?
    public let selectedSlot: Int?
    public let selectedNativeRecipeID: UInt32
    public let attemptLimit: Int
    public let effectiveMode: String
    public let enabledRecordCount: Int
    public let slots: [NativeSlotProvenance]
    public let differences: [NativeDifference]
    public let approvalCurrent: Bool
    public let requiredCapabilities: [String]
    public let physicalQualification: Bool
    public let bootable: Bool
}

public struct NativeSlotProvenance: Codable, Equatable, Sendable {
    public let slotIndex: Int
    public let nativeRecipeID: UInt32
    public let sourceRecipeID: String?
    public let sourceRevision: UInt32?
    public let sourceDigest: String?
    public let authoredRecipeDigest: String?
    public let tupleDigest: String?
    public let mappingVersion: String?
    public let enabled: Bool
    public let approvalCurrent: Bool
    public let differences: [NativeDifference]
}

public struct NativeCompiledExport: Equatable, Sendable {
    public let sidecar: Data
    public let report: NativeAuthoringReport
    init(sidecar: Data, report: NativeAuthoringReport) { self.sidecar = sidecar; self.report = report }
}

/// Host compiler for the separate Architecture v2 CNATIV v1 bank. The app does
/// not install this file; the matching native runtime/package contract is separate.
public enum NativeRecipeCompiler {
    public static let sidecarBytes = 512
    public static let headerBytes = 32
    public static let recordBytes = 160
    public static let targetModel: UInt32 = 450
    public static let interface = "CNATIV.BIN-v1-host-authoring"
    private static let magic = Data([0x43, 0x4e, 0x52, 0x50]) // CNRP

    private static let effectBits: [String: UInt32] = [
        "base": 1 << 0, "saturation": 1 << 1, "hue": 1 << 2, "key": 1 << 3,
        "contrast": 1 << 4, "highlights": 1 << 5, "shadows": 1 << 6,
        "sharpness": 1 << 7, "shading": 1 << 8, "clarity": 1 << 9,
        "whiteBalance": 1 << 10, "grain": 1 << 11, "monoFilter": 1 << 12,
        "monoToning": 1 << 13, "colorTone": 1 << 14
    ]

    public static func compile(store: NativeRecipeStore, currentRecipes: [Recipe],
                               profileCompiler: ProfileCompiler? = nil,
                               selectedSlot: Int? = nil, attemptLimit: Int = 0) throws -> NativeCompiledExport {
        try store.validate()
        guard type(of: attemptLimit) == Int.self, (0...8).contains(attemptLimit) else {
            throw ProfileError.invalid("Native session attempt limit must be an integer from 0 through 8.")
        }
        if let selectedSlot, !(0..<3).contains(selectedSlot) {
            throw ProfileError.invalid("Native slot selection must be 0, 1 or 2; use nil for OFF.")
        }
        guard Set(currentRecipes.map(\.id)).count == currentRecipes.count else {
            throw ProfileError.invalid("Current Effects recipes contain duplicate identities.")
        }
        var enabled: [Int: (NativeRecipeRecord, Recipe)] = [:]
        for slot in 0..<3 {
            guard let id = store.slots[slot], let record = store.records.first(where: { $0.sourceRecipeID == id }),
                  let recipe = currentRecipes.first(where: { $0.id == id }) else { continue }
            if let factoryID = recipe.factoryID {
                guard let profileCompiler else { continue }
                let currentFactorySHA = NativeCanonical.sha256(try profileCompiler.factoryBody(factoryID))
                guard currentFactorySHA == record.source.resolvedFactoryBodySHA256 else { continue }
            }
            guard NativeRecipeAuthoring.isApprovalCurrent(record: record, for: recipe),
                  record.tuple.isRuntimeV1Supported else { continue }
            enabled[slot] = (record, recipe)
        }
        let effectiveSlot = attemptLimit == 0 ? nil : selectedSlot
        if attemptLimit > 0 {
            guard let effectiveSlot, enabled[effectiveSlot] != nil else {
                throw ProfileError.invalid("Active native export requires a current approved runtime-supported slot; choose OFF or approve the selected interpretation.")
            }
        }

        var bank = Data(repeating: 0, count: sidecarBytes)
        bank.replaceSubrange(0..<4, with: magic)
        bank.put16(1, 4); bank.put16(UInt16(headerBytes), 6)
        bank.put32(UInt32(sidecarBytes), 8); bank.put16(UInt16(recordBytes), 12); bank.put16(3, 14)
        bank.put32(targetModel, 16)
        bank.replaceSubrange(20..<25, with: Data("1.1.0".utf8))
        for slot in 0..<3 {
            let offset = headerBytes + slot * recordBytes
            bank.put32(UInt32(61001 + slot), offset)
            guard let (record, _) = enabled[slot] else { continue }
            try encode(record, slot: slot, into: &bank, offset: offset)
        }
        bank.put32(0, 28)
        bank.put32(bank.fnv32(), 28)
        try validate(sidecar: bank)

        let active = effectiveSlot.flatMap { enabled[$0] }
        let slotReports: [NativeSlotProvenance] = (0..<3).map { slot in
            let assignedID = store.slots[slot]
            let record = assignedID.flatMap { id in store.records.first(where: { $0.sourceRecipeID == id }) }
            let recipe = assignedID.flatMap { id in currentRecipes.first(where: { $0.id == id }) }
            let isCurrent = record != nil && recipe.map { NativeRecipeAuthoring.isApprovalCurrent(record: record!, for: $0) } == true
            let isEnabled = enabled[slot] != nil
            return NativeSlotProvenance(slotIndex: slot, nativeRecipeID: UInt32(61001 + slot),
                                         sourceRecipeID: assignedID?.uuidString.lowercased(),
                                         sourceRevision: record?.sourceRevision,
                                         sourceDigest: record?.source.sourceDigest,
                                         authoredRecipeDigest: record?.authoredRecipeDigest,
                                         tupleDigest: record?.tuple.canonicalDigest,
                                         mappingVersion: record?.mappingVersion,
                                         enabled: isEnabled, approvalCurrent: isCurrent,
                                         differences: record?.differences ?? [])
        }
        let report = NativeAuthoringReport(
            schema: 1, status: "HOST_NATIVE_AUTHORING_ONLY_NOT_BOOTABLE", nativeInterface: interface,
            sourceRecipeID: active.map { $0.0.sourceRecipeID.uuidString.lowercased() },
            sourceRevision: active?.0.sourceRevision, sourceDigest: active?.0.source.sourceDigest,
            authoredRecipeDigest: active?.0.authoredRecipeDigest,
            tupleDigest: active?.0.tuple.canonicalDigest, mappingVersion: active?.0.mappingVersion,
            selectedSlot: effectiveSlot, selectedNativeRecipeID: effectiveSlot.map { UInt32(61001 + $0) } ?? 0,
            attemptLimit: attemptLimit, effectiveMode: attemptLimit == 0 ? "OFF" : "PRESET_ATTEMPT_LIMIT",
            enabledRecordCount: enabled.count, slots: slotReports,
            differences: active?.0.differences ?? [],
            approvalCurrent: active.map { NativeRecipeAuthoring.isApprovalCurrent(record: $0.0, for: $0.1) } ?? false,
            requiredCapabilities: active.map { capabilities(for: $0.0.tuple) } ?? [],
            physicalQualification: false, bootable: false)
        return NativeCompiledExport(sidecar: bank, report: report)
    }

    private static func capabilities(for tuple: NativeCanonTuple) -> [String] {
        ["Canon EOS 450D firmware 1.1.0", "Standard colour native tuple", "WB Auto or Daylight",
         "capture-local recipe application; physical qualification is limited to the exact Warm1 tuple"]
    }

    private static func encode(_ record: NativeRecipeRecord, slot: Int, into bank: inout Data, offset: Int) throws {
        guard record.displayName.utf8.count <= 23, record.shortName.utf8.count <= 14,
              record.displayName.utf8.allSatisfy({ 32...126 ~= $0 }),
              record.shortName.utf8.allSatisfy({ 32...126 ~= $0 }) else {
            throw ProfileError.invalid("Native display names must be printable ASCII within their fixed fields.")
        }
        try record.tuple.validate()
        guard record.tuple.isRuntimeV1Supported, NativeRecipeAuthoring.approvalMatches(record) else {
            throw ProfileError.invalid("Only approved Standard colour Auto/Daylight tuples can be enabled in v1.")
        }
        guard record.sourceRevision > 0, record.sourceRevision <= UInt32.max else {
            throw ProfileError.invalid("Native source revision is outside the sidecar field range.")
        }
        let categories = effectCategories(record.differences)
        let nativeMask = categories.native
        let approximateMask = categories.approximate
        let omittedMask = categories.omitted
        guard nativeMask & omittedMask == 0, approximateMask & ~nativeMask == 0,
              omittedMask == 0 || record.approval?.acknowledgedDifferenceIDs.isEmpty == false else {
            throw ProfileError.invalid("Native effect accounting masks are inconsistent or unacknowledged.")
        }
        bank.put32(UInt32(61001 + slot), offset)
        bank.put32(record.sourceRevision, offset + 4)
        bank.put32(nativeMask, offset + 8); bank.put32(approximateMask, offset + 12); bank.put32(omittedMask, offset + 16)
        bank[offset + 20] = 2; bank[offset + 21] = record.tuple.kind.rawValue
        bank[offset + 22] = 1; bank[offset + 23] = omittedMask == 0 ? 0 : 1
        encode(record.tuple, into: &bank, offset: offset + 24)
        putASCII(record.displayName, into: &bank, offset: offset + 36, width: 24)
        putASCII(record.shortName, into: &bank, offset: offset + 60, width: 16)
        // Built-in Canon style; no installed PF payload or provenance label is asserted.
        bank.put32(0, offset + 132) // no additional capture-condition requirements asserted
        bank.put32(0, offset + 136); bank.put32(0, offset + 140); bank.put32(0, offset + 144)
    }

    private static func encode(_ tuple: NativeCanonTuple, into bank: inout Data, offset: Int) {
        bank[offset] = tuple.style.rawValue; bank[offset + 1] = tuple.kind.rawValue
        bank[offset + 2] = UInt8(tuple.sharpness); bank[offset + 3] = UInt8(bitPattern: Int8(tuple.contrast))
        if tuple.kind == .color {
            bank[offset + 4] = UInt8(bitPattern: Int8(tuple.saturation))
            bank[offset + 5] = UInt8(bitPattern: Int8(tuple.tone))
        } else {
            bank[offset + 4] = tuple.monoFilter.rawValue; bank[offset + 5] = tuple.monoToning.rawValue
        }
        bank[offset + 6] = tuple.whiteBalance.rawValue
        bank[offset + 7] = UInt8(bitPattern: Int8(tuple.amberBlue))
        bank[offset + 8] = UInt8(bitPattern: Int8(tuple.greenMagenta))
    }

    private static func putASCII(_ text: String, into data: inout Data, offset: Int, width: Int) {
        let bytes = Array(text.utf8); data.replaceSubrange(offset..<(offset + bytes.count), with: bytes)
        data[offset + bytes.count] = 0
    }

    private static func effectCategories(_ differences: [NativeDifference]) -> (native: UInt32, approximate: UInt32, omitted: UInt32) {
        var native: UInt32 = 0, approximate: UInt32 = 0, omitted: UInt32 = 0
        for difference in differences {
            let key: String
            switch difference.sourceField {
            case "base": key = "base"
            case "sharpness": key = "sharpness"
            case "contrast": key = "contrast"
            case "saturation": key = "saturation"
            case "whiteBalance": key = "whiteBalance"
            case "amberBlue", "greenMagenta": key = "whiteBalance"
            case "hue": key = "hue"
            case "colorTone": key = "colorTone"
            case "key": key = "key"
            case "curves": omitted |= effectBits["highlights"]! | effectBits["shadows"]!; continue
            case "highlights": key = "highlights"
            case "shadows": key = "shadows"
            case "shading": key = "shading"
            case "clarity": key = "clarity"
            case "grain", "factory.grain": key = "grain"
            case "bwFilter", "filterEffect": key = "monoFilter"
            case "toning": key = "monoToning"
            case "hdrToneLevel": key = "colorTone"
            case "imageControl": key = "base"
            default: continue
            }
            guard let bit = effectBits[key] else { continue }
            switch difference.classification {
            case .represented: native |= bit
            case .approximated: native |= bit; approximate |= bit
            case .omitted, .unresolved: omitted |= bit
            }
        }
        // The selected Canon tuple is native even when the source had a different
        // field value; omission describes the source effect, not tuple validity.
        let tupleBits = effectBits["base"]! | effectBits["sharpness"]! | effectBits["contrast"]! |
                        effectBits["saturation"]! | effectBits["whiteBalance"]!
        native |= tupleBits & ~omitted
        return (native, approximate & native, omitted)
    }

    public static func validate(sidecar: Data) throws {
        guard sidecar.count == sidecarBytes, sidecar.subdata(in: 0..<4) == magic,
              sidecar.u16(4) == 1, sidecar.u16(6) == headerBytes,
              sidecar.u32(8) == sidecarBytes, sidecar.u16(12) == recordBytes,
              sidecar.u16(14) == 3, sidecar.u32(16) == targetModel,
              sidecar.subdata(in: 20..<28) == Data([49, 46, 49, 46, 48, 0, 0, 0]) else {
            throw ProfileError.invalid("CNATIV header, target or version is invalid.")
        }
        var checksumData = sidecar; let expected = checksumData.u32(28); checksumData.put32(0, 28)
        guard checksumData.fnv32() == expected else { throw ProfileError.invalid("CNATIV checksum mismatch.") }
        for slot in 0..<3 {
            let offset = headerBytes + slot * recordBytes
            guard sidecar.u32(offset) == UInt32(61001 + slot) else { throw ProfileError.invalid("CNATIV slot identity mismatch.") }
            let record = sidecar.subdata(in: offset..<(offset + recordBytes))
            if record[22] == 0 {
                var expectedDisabled = Data(repeating: 0, count: recordBytes)
                expectedDisabled.put32(UInt32(61001 + slot), 0)
                guard record == expectedDisabled else { throw ProfileError.invalid("Disabled CNATIV records must have zeroed fields.") }
                continue
            }
            try validateRecord(record)
        }
    }

    private static func validateRecord(_ record: Data) throws {
        let native = record.u32(8), approximate = record.u32(12), omitted = record.u32(16)
        let knownMask: UInt32 = (1 << 15) - 1
        guard record.u32(4) > 0, record[20] == 2, record[21] <= 1, record[22] == 1,
              record[23] <= 1, native & ~knownMask == 0, approximate & ~native == 0,
              omitted & ~knownMask == 0, native & omitted == 0,
              (omitted == 0 || record[23] == 1), record[23] == (omitted == 0 ? 0 : 1),
              record.u32(132) & ~UInt32(7) == 0, record.u32(136) == 0, record.u32(140) == 0,
              record.u32(144) == 0, record.subdata(in: 148..<160).allSatisfy({ $0 == 0 }),
              record.subdata(in: 76..<132).allSatisfy({ $0 == 0 }) else {
            throw ProfileError.invalid("CNATIV record metadata, masks or reserved bytes are invalid.")
        }
        try validateTuple(record.subdata(in: 24..<36), kind: record[21])
        for (start, length, maxVisible) in [(36,24,23),(60,16,14)] {
            let field = record.subdata(in: start..<(start + length))
            guard let zero = field.firstIndex(of: 0), zero > 0, zero <= maxVisible,
                  field[..<zero].allSatisfy({ 32...126 ~= $0 }), field[zero...].allSatisfy({ $0 == 0 }) else {
                throw ProfileError.invalid("CNATIV display name is invalid.")
            }
        }
    }

    private static func validateTuple(_ tuple: Data, kind: UInt8) throws {
        guard tuple.count == 12, tuple[0] == NativeStyle.standard.rawValue, tuple[1] == kind,
              kind == NativeStyleKind.color.rawValue, tuple[2] <= 7,
              (-4...4).contains(Int(Int8(bitPattern: tuple[3]))),
              (-4...4).contains(Int(Int8(bitPattern: tuple[4]))),
              (-4...4).contains(Int(Int8(bitPattern: tuple[5]))),
              tuple[6] <= NativeWhiteBalance.daylight.rawValue,
              (-9...9).contains(Int(Int8(bitPattern: tuple[7]))),
              (-9...9).contains(Int(Int8(bitPattern: tuple[8]))),
              tuple[9...11].allSatisfy({ $0 == 0 }) else {
            throw ProfileError.invalid("CNATIV v1 executable tuple is outside the Standard colour/Auto-Daylight capability.")
        }
    }
}
