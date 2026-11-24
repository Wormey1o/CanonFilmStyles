import CryptoKit
import Foundation

public enum BatchGrainAmount: UInt32, CaseIterable, Sendable {
    case off = 0
    case amount11 = 11
    case amount16 = 16
    case amount27 = 27
}

public struct BatchGrainSettings: Sendable {
    public let amount: BatchGrainAmount
    public let cell: UInt32
    public let seed: UInt32

    public init(amount: BatchGrainAmount, cell: UInt32, seed: UInt32) throws {
        guard (1...3).contains(cell) else { throw ProfileError.invalid("Grain cell must be 1, 2, or 3.") }
        self.amount = amount
        self.cell = cell
        self.seed = seed
    }
}

public struct BatchGrainJob: Sendable {
    public let path: String
    public let sourceBytes: UInt32
    public let sourceSHA256: Data
    public let settings: BatchGrainSettings

    public init(path: String, sourceBytes: UInt32, sourceSHA256: Data, settings: BatchGrainSettings) throws {
        try BatchGrainManifest.validatePath(path)
        guard (1...BatchGrainManifest.maxSourceBytes).contains(sourceBytes), sourceSHA256.count == 32 else {
            throw ProfileError.invalid("A pinned source must be 1 byte through 32 MiB and carry a SHA-256 digest.")
        }
        self.path = path
        self.sourceBytes = sourceBytes
        self.sourceSHA256 = sourceSHA256
        self.settings = settings
    }
}

public enum BatchGrainManifest {
    public static let maxJobs = 64
    public static let maxSourceBytes: UInt32 = 32 * 1024 * 1024
    public static let maxOutputBytes: UInt32 = 8 * 1024 * 1024
    private static let version: UInt16 = 1
    private static let algorithm: UInt32 = 1
    private static let headerBytes: UInt16 = 64
    private static let recordBytes: UInt32 = 224
    private static let magic = Data("CBATCH1\0".utf8)
    private static let domain = Data("CanonIdleBatch/job/v1\0".utf8)

    static func validatePath(_ path: String) throws {
        let bytes = path.utf8
        let allowed = bytes.allSatisfy { byte in
            switch byte {
            case 65...90, 97...122, 48...57, 46, 95, 45, 47: return true
            default: return false
            }
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        let folded = path.lowercased()
        guard (1...127).contains(bytes.count), allowed, !components.contains(where: {
            $0.isEmpty || $0 == "." || $0 == ".."
        }), folded.hasSuffix(".jpg") || folded.hasSuffix(".jpeg") else {
            throw ProfileError.invalid("Use a relative .JPG or .JPEG path of at most 127 ASCII bytes: \(path)")
        }
    }

    public static func encode(_ jobs: [BatchGrainJob]) throws -> Data {
        guard (1...maxJobs).contains(jobs.count) else {
            throw ProfileError.invalid("Choose 1 through \(maxJobs) JPEGs for this batch.")
        }
        var records = Data()
        records.reserveCapacity(jobs.count * Int(recordBytes))
        var paths = Set<String>()
        var identities = Set<Data>()
        for job in jobs {
            guard paths.insert(job.path.lowercased()).inserted else {
                throw ProfileError.invalid("This source appears more than once: \(job.path)")
            }
            var record = Data(job.path.utf8)
            record.append(Data(count: 128 - record.count))
            append(job.sourceBytes, to: &record)
            record.append(job.sourceSHA256)
            append(algorithm, to: &record)
            append(job.settings.amount.rawValue, to: &record)
            append(job.settings.cell, to: &record)
            append(job.settings.seed, to: &record)
            append(maxOutputBytes, to: &record)
            let identity = Data(SHA256.hash(data: domain + record))
            guard identities.insert(identity).inserted else { throw ProfileError.invalid("Duplicate batch job identity.") }
            record.append(identity)
            record.append(Data(count: 8))
            records.append(record)
        }

        var manifest = magic
        append(version, to: &manifest)
        append(headerBytes, to: &manifest)
        append(recordBytes, to: &manifest)
        append(UInt32(jobs.count), to: &manifest)
        append(UInt32(0), to: &manifest)
        manifest.append(Data(SHA256.hash(data: records)))
        manifest.append(Data(count: 8))
        manifest.append(records)
        return manifest
    }

    private static func append<T: FixedWidthInteger>(_ integer: T, to data: inout Data) {
        var littleEndian = integer.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }
}
