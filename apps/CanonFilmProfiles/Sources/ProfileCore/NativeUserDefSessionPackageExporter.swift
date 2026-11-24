import Foundation
import CryptoKit
import Darwin

/// Schema-5 export for Canon's captured User Def. 1–3 selector. This is separate
/// from the schema-4 host-selected finite startup package and has no installer.
public enum NativeUserDefSessionPackageExporter {
    public static let interface = "native-captured-userdef-session-v1"
    public static let templateFile = "NativeUserDefBootTemplate.bin"
    /// Filled only from the independently reviewed User Def runtime template.
    public static let templateSHA256 = "d0fb2f79efcb783b3cd0d01264c3e2124f119bb2d3db6f859fc0cf15a3dcef72"
    public static let imageBytes = 130280
    public static let bankOffset = 0x2600
    public static let descriptorOffset = 0x3dc0
    public static let remainingOffset = 0x3f04
    public static let sessionMagic: UInt32 = 0x53465333 // Numeric field; little-endian on disk.
    public static let sessionVersion: UInt32 = 3
    public static let capturedUserDefPolicy: UInt32 = 2
    public static let maximumAttemptLimit = Int(Int32.max)

    /// Finalize only after the linked runtime and actual naming routes are qualified.
    public static let assignmentNameScopes = ["picture-style-main-menu-list", "picture-style-shortcut-initial", "picture-style-shortcut-move"]
    public static let assignmentNameMaxSourceBytes = 10
    public static let assignmentNameTruncationMarker = "~"
    public static let assignmentNameLabelFormat: [String: Any] = [
        "maxSourceBytes": assignmentNameMaxSourceBytes,
        "truncationMarker": assignmentNameTruncationMarker,
        "truncationMarkerOnlyIfLonger": true, "literalASCII": true,
        "slotIdentity": "stock Canon icons", "fullBankNamePreserved": true
    ]
    public static let runtimeCapabilities: [String: Any] = [
        "capturedSingleDriveGuard": true,
        "onCameraAssignmentNames": ["scopes": assignmentNameScopes,
            "labelFormat": assignmentNameLabelFormat,
            "meaning": "recipe-assignment-only", "indicatesCaptureApplied": false,
            "canonFallbackIfUnavailable": true],
        "sleepWakeQualified": false
    ]

    /// Preview the runtime's literal assignment text; the full bank name is unchanged.
    public static func assignmentLabelPreview(for nativeDisplayName: String) -> String? {
        let bytes = Array(nativeDisplayName.utf8)
        guard (1...23).contains(bytes.count), bytes.allSatisfy({ 32...126 ~= $0 }) else { return nil }
        return String(decoding: bytes.prefix(assignmentNameMaxSourceBytes), as: UTF8.self) +
            (bytes.count > assignmentNameMaxSourceBytes ? assignmentNameTruncationMarker : "")
    }

    private static func sha(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    private static func read32(_ data: Data, _ offset: Int) -> UInt32 {
        (0..<4).reduce(0) { $0 | UInt32(data[offset + $1]) << (8 * $1) }
    }
    private static func put32(_ data: inout Data, _ offset: Int, _ value: UInt32) {
        for i in 0..<4 { data[offset + i] = UInt8(truncatingIfNeeded: value >> (8 * i)) }
    }
    private static func encoded<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(value)
        data.append(10)
        return data
    }

    private struct SlotMapping: Codable {
        let slotIndex: Int
        let capturedUserDefStyleCode: UInt32
        let nativeRecipeID: UInt32
        let sourceRecipeID: String?
        let sourceRevision: UInt32?
        let sourceDigest: String?
        let authoredRecipeDigest: String?
        let tupleDigest: String?
        let mappingVersion: String?
        let displayName: String?
        let canonTuple: NativeCanonTuple?
        let enabled: Bool
        let approvalCurrent: Bool
        let disabledReason: String?
        let baseStyleRequirement: String
    }

    private struct UserDefSessionReport: Codable {
        let schema: Int
        let status: String
        let interface: String
        let sessionPolicy: String
        let sessionLimit: Int
        let selection: String
        let ownerCameraStyleDefinitionsModified: Bool
        let globalCanonSettingsChanged: Bool
        let bootable: Bool
        let physicalQualification: Bool
        let bankFNV1a32: UInt32
        let mappings: [SlotMapping]
        let authoring: NativeAuthoringReport
    }

    /// `compiled` must be produced with `selectedSlot:nil, attemptLimit:0`; that
    /// compiles only the immutable approved bank, not the legacy finite policy.
    public static func files(compiled: NativeCompiledExport, template: Data,
                             attemptLimit: Int) throws -> [String: Data] {
        guard template.count == imageBytes, templateSHA256 != "PENDING_FIRMWARE_TEMPLATE_PIN",
              sha(template) == templateSHA256,
              !assignmentNameScopes.isEmpty,
              !assignmentNameScopes.contains("PENDING_NATIVE_ROUTE_QUALIFICATION") else {
            throw ProfileError.invalid("The captured-User-Def runtime template is not the pinned reviewed build.")
        }
        let templateBank = template.subdata(in: bankOffset..<(bankOffset + NativeRecipeCompiler.sidecarBytes))
        try NativeRecipeCompiler.validate(sidecar: templateBank)
        guard (0..<3).allSatisfy({ templateBank[NativeRecipeCompiler.headerBytes + $0 * NativeRecipeCompiler.recordBytes + 22] == 0 }),
              read32(template, descriptorOffset) == sessionMagic,
              read32(template, descriptorOffset + 4) == sessionVersion,
              read32(template, descriptorOffset + 8) == capturedUserDefPolicy,
              read32(template, descriptorOffset + 12) == UInt32(Int32.max),
              read32(template, descriptorOffset + 16) == read32(templateBank, 28),
              read32(template, descriptorOffset + 20) == 1,
              (6..<16).allSatisfy({ read32(template, descriptorOffset + $0 * 4) == 0 }),
              read32(template, remainingOffset) == UInt32(Int32.max) else {
            throw ProfileError.invalid("The pinned User Def. template does not contain the declared all-disabled SFS3 default.")
        }
        guard type(of: attemptLimit) == Int.self, (1...maximumAttemptLimit).contains(attemptLimit) else {
            throw ProfileError.invalid("Captured-User-Def attempt bound must be 1…2,147,483,647.")
        }
        try NativeRecipeCompiler.validate(sidecar: compiled.sidecar)
        let source = compiled.report
        guard source.schema == 1, source.slots.count == 3,
              source.selectedSlot == nil, source.selectedNativeRecipeID == 0,
              source.attemptLimit == 0, source.effectiveMode == "OFF", source.physicalQualification == false,
              source.bootable == false else {
            throw ProfileError.invalid("Expected a bank-only compilation with the finite startup policy OFF.")
        }

        var mappings: [SlotMapping] = []
        var enabled = 0
        for slot in 0..<3 {
            let offset = NativeRecipeCompiler.headerBytes + slot * NativeRecipeCompiler.recordBytes
            let row = source.slots[slot]
            let expectedID = UInt32(61001 + slot)
            let isEnabled = compiled.sidecar[offset + 22] == 1
            guard row.slotIndex == slot, row.nativeRecipeID == expectedID,
                  read32(compiled.sidecar, offset) == expectedID,
                  row.enabled == isEnabled else {
                throw ProfileError.invalid("Native bank, compiler report and User Def. slot mapping disagree.")
            }
            let styleCode = UInt32(0x21 + slot)
            let name: String?
            let tuple: NativeCanonTuple?
            if isEnabled {
                enabled += 1
            guard row.approvalCurrent,
                      let sourceID = row.sourceRecipeID, UUID(uuidString: sourceID) != nil,
                      row.sourceRevision == read32(compiled.sidecar, offset + 4),
                      row.sourceDigest != nil, row.authoredRecipeDigest != nil,
                      let tupleDigest = row.tupleDigest else {
                    throw ProfileError.invalid("Assigned User Def. \(slot + 1) must have a current approved native source record.")
                }
                let parsed = try parseTuple(from: compiled.sidecar, offset: offset + 24)
                guard parsed.isRuntimeV1Supported, parsed.style == .standard, parsed.kind == .color,
                      parsed.canonicalDigest == tupleDigest else {
                    throw ProfileError.invalid("User Def. \(slot + 1) bank tuple is unsupported or differs from its approval report.")
                }
                guard let checkedName = fixedASCII(compiled.sidecar, offset: offset + 36, width: 24) else {
                    throw ProfileError.invalid("Enabled User Def. \(slot + 1) has no valid native display name.")
                }
                name = checkedName
                tuple = parsed
            } else {
                // A slot with source identity assigned but not enabled is not silently dropped.
                guard row.sourceRecipeID == nil, row.sourceRevision == nil,
                      row.sourceDigest == nil, row.authoredRecipeDigest == nil,
                      row.tupleDigest == nil, row.mappingVersion == nil,
                      row.approvalCurrent == false else {
                    throw ProfileError.invalid("Assigned User Def. \(slot + 1) is not exportable; approve a supported record or clear that native slot.")
                }
                name = nil
                tuple = nil
            }
            mappings.append(SlotMapping(slotIndex: slot, capturedUserDefStyleCode: styleCode,
                                        nativeRecipeID: expectedID, sourceRecipeID: row.sourceRecipeID,
                                        sourceRevision: row.sourceRevision, sourceDigest: row.sourceDigest,
                                        authoredRecipeDigest: row.authoredRecipeDigest,
                                        tupleDigest: row.tupleDigest, mappingVersion: row.mappingVersion,
                                        displayName: name, canonTuple: tuple, enabled: isEnabled,
                                        approvalCurrent: row.approvalCurrent,
                                        disabledReason: isEnabled ? nil : "empty native slot; use of this User Def. style follows Canon original processing",
                                        baseStyleRequirement: "direct Standard base code 0x81"))
        }
        guard enabled == source.enabledRecordCount else {
            throw ProfileError.invalid("Enabled record count or native bank checksum differs from the compiler report.")
        }

        var image = template
        image.replaceSubrange(bankOffset..<(bankOffset + NativeRecipeCompiler.sidecarBytes),
                              with: compiled.sidecar)
        put32(&image, descriptorOffset, sessionMagic)
        put32(&image, descriptorOffset + 4, sessionVersion)
        put32(&image, descriptorOffset + 8, capturedUserDefPolicy)
        put32(&image, descriptorOffset + 12, UInt32(attemptLimit))
        put32(&image, descriptorOffset + 16, read32(compiled.sidecar, 28))
        put32(&image, descriptorOffset + 20, 1) // generation
        for word in 6..<16 { put32(&image, descriptorOffset + word * 4, 0) }
        put32(&image, remainingOffset, UInt32(attemptLimit))

        var normalized = image
        for range in [bankOffset..<(bankOffset + NativeRecipeCompiler.sidecarBytes),
                      descriptorOffset..<(descriptorOffset + 64),
                      remainingOffset..<(remainingOffset + 4)] {
            normalized.replaceSubrange(range, with: template.subdata(in: range))
        }
        guard sha(normalized) == templateSHA256 else {
            throw ProfileError.invalid("User Def. template normalization failed; package modifies an unapproved image range.")
        }

        let report = UserDefSessionReport(schema: 1,
            status: "HOST_USERDEF_SESSION_PACKAGE_REQUIRES_PHYSICAL_QUALIFICATION",
            interface: interface, sessionPolicy: "captured-userdef-selection-with-finite-checked-bound",
            sessionLimit: attemptLimit, selection: "captured User Def. 1/2/3 selects native slot 1/2/3; built-in styles use original Canon processing",
            ownerCameraStyleDefinitionsModified: false, globalCanonSettingsChanged: false,
            bootable: false, physicalQualification: false,
            bankFNV1a32: read32(compiled.sidecar, 28), mappings: mappings, authoring: source)
        let reportData = try encoded(report)
        let bodies: [String: Data] = ["AUTOEXEC.BIN": image, "CNATIV.BIN": compiled.sidecar,
                                      "userdef-session.json": reportData]
        let inventory = bodies.keys.sorted().map { name in
            ["name": name, "bytes": bodies[name]!.count, "sha256": sha(bodies[name]!)] as [String: Any]
        }
        let profiles: [[String: Any]] = mappings.map { row in
            var value: [String: Any] = ["slot": row.slotIndex,
                "cameraStyleCode": row.capturedUserDefStyleCode,
                "nativeRecipeID": row.nativeRecipeID, "enabled": row.enabled,
                "sourceRecipeID": row.sourceRecipeID.map { $0 as Any } ?? NSNull(),
                "sourceRevision": row.sourceRevision.map { $0 as Any } ?? NSNull(),
                "sourceDigest": row.sourceDigest.map { $0 as Any } ?? NSNull(),
                "authoredRecipeDigest": row.authoredRecipeDigest.map { $0 as Any } ?? NSNull(),
                "tupleDigest": row.tupleDigest.map { $0 as Any } ?? NSNull()]
            if let name = row.displayName { value["name"] = name }
            if let tuple = row.canonTuple {
                value["canonTuple"] = ["style": "Standard", "whiteBalance": tuple.whiteBalance == .auto ? "Auto" : "Daylight",
                    "sharpness": tuple.sharpness, "contrast": tuple.contrast,
                    "saturation": tuple.saturation, "colourTone": tuple.tone,
                    "amberBlue": tuple.amberBlue, "greenMagenta": tuple.greenMagenta]
            }
            if let reason = row.disabledReason { value["disabledReason"] = reason }
            return value
        }
        let manifest: [String: Any] = [
            "schema": 5, "interface": interface, "backend": "NativeOnly",
            "target": ["model": "Canon EOS 450D / Rebel XSi", "firmware": "1.1.0"],
            "qualification": "OFFLINE_ONLY_REQUIRES_REVIEWED_PHYSICAL_TRIAL",
            "runtimeTemplateSHA256": templateSHA256, "runtimeCapabilities": runtimeCapabilities,
            "files": inventory, "profiles": profiles,
            "session": ["format": "SFS3", "magic": sessionMagic, "version": sessionVersion,
                "policy": capturedUserDefPolicy, "attemptLimit": attemptLimit, "generation": 1,
                "bankFNV1a32": read32(compiled.sidecar, 28), "bankOffset": bankOffset,
                "descriptorOffset": descriptorOffset, "remainingOffset": remainingOffset,
                "styleToNativeID": ["0x21": 61001, "0x22": 61002, "0x23": 61003],
                "requiredUserDefBaseStyle": "0x81", "sourceDefaultBank": "all rows disabled"],
            "execution": ["selectionSource": "captured Canon Picture Style", "builtInStylesUseOriginalCanonProcessing": true,
                "emptyOrUnsupportedUserDefUsesOriginalCanonProcessing": true, "globalCanonSettingsChanged": false,
                "cameraUserDefDefinitionsModified": false, "attemptLimitIsCameraShotLimit": false,
                "freshBootReloadsBound": true, "nativeRearm": false, "privateOnCameraMenu": false],
            "operatorPreconditions": ["Single drive", "RAW + Large/Fine JPEG", "sRGB", "HTP off",
                "WB bracketing off", "Mirror lockup off", "selected User Def. must have direct Standard base code 0x81"],
            "deployment": "Export only; this app does not install native packages."
        ]
        var files = bodies
        var manifestData = try JSONSerialization.data(withJSONObject: manifest,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        manifestData.append(10)
        files["manifest.json"] = manifestData
        return files
    }

    /// Recomputes the complete canonical package and rejects any byte-level drift,
    /// including changed metadata, reordered/duplicate JSON keys, or altered image spans.
    public static func verifyPackage(_ candidate: [String: Data], compiled: NativeCompiledExport,
                                     template: Data, attemptLimit: Int) throws {
        let expected = try files(compiled: compiled, template: template, attemptLimit: attemptLimit)
        guard candidate.keys.sorted() == expected.keys.sorted() else {
            throw ProfileError.invalid("User Def. package members differ from the canonical export.")
        }
        for (name, bytes) in expected where candidate[name] != bytes {
            throw ProfileError.invalid("User Def. package file differs from its canonical export: \(name).")
        }
    }

    @discardableResult
    public static func export(compiled: NativeCompiledExport, template: Data,
                              attemptLimit: Int, to folder: URL) throws -> URL {
        guard folder.isFileURL else { throw ProfileError.invalid("Choose a local User Def. package folder.") }
        let files = try files(compiled: compiled, template: template, attemptLimit: attemptLimit)
        let destination = folder.standardizedFileURL
        guard mkdir(destination.path, 0o700) == 0 else {
            throw ProfileError.invalid("Choose a new, unused User Def. package folder.")
        }
        for name in ["AUTOEXEC.BIN", "CNATIV.BIN", "userdef-session.json", "manifest.json"] {
            try files[name]!.write(to: destination.appendingPathComponent(name), options: .withoutOverwriting)
        }
        return destination
    }

    private static func parseTuple(from bank: Data, offset: Int) throws -> NativeCanonTuple {
        guard offset >= 0, offset + 12 <= bank.count,
              bank[offset + 1] == NativeStyleKind.color.rawValue,
              let style = NativeStyle(rawValue: bank[offset]),
              let wb = NativeWhiteBalance(rawValue: bank[offset + 6]) else {
            throw ProfileError.invalid("Malformed native tuple in User Def. bank record.")
        }
        let value = NativeCanonTuple(style: style, kind: NativeStyleKind(rawValue: bank[offset + 1])!,
            sharpness: Int(bank[offset + 2]), contrast: Int(Int8(bitPattern: bank[offset + 3])),
            saturation: Int(Int8(bitPattern: bank[offset + 4])), tone: Int(Int8(bitPattern: bank[offset + 5])),
            whiteBalance: wb, amberBlue: Int(Int8(bitPattern: bank[offset + 7])),
            greenMagenta: Int(Int8(bitPattern: bank[offset + 8])),
            monoFilter: .none, monoToning: .none)
        try value.validate()
        return value
    }

    private static func fixedASCII(_ data: Data, offset: Int, width: Int) -> String? {
        guard offset >= 0, offset + width <= data.count else { return nil }
        let bytes = data[offset..<(offset + width)].prefix { $0 != 0 }
        guard !bytes.isEmpty, bytes.allSatisfy({ 32...126 ~= $0 }) else { return nil }
        return String(decoding: bytes, as: UTF8.self)
    }
}
