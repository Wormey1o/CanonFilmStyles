import CryptoKit
import Foundation
import ProfileCore

func verify(_ condition: Bool, _ description: String) throws {
    guard condition else { throw ProfileError.invalid(description) }
}

func rejects(_ description: String, operation: () throws -> Void) throws {
    do { try operation() } catch { return }
    throw ProfileError.invalid("Expected rejection: \(description)")
}

func data(hex: String) -> Data {
    Data(stride(from: 0, to: hex.count, by: 2).map { offset in
        let start = hex.index(hex.startIndex, offsetBy: offset)
        return UInt8(hex[start..<hex.index(start, offsetBy: 2)], radix: 16)!
    })
}

guard CommandLine.arguments.count == 2 else {
    throw ProfileError.invalid("Usage: BatchGrainChecks <shared golden.cbatch>")
}
let fixture = URL(fileURLWithPath: CommandLine.arguments[1])
let settings = try BatchGrainSettings(amount: .amount16, cell: 1, seed: 24301)
let sourceHash = data(hex: "592c469061f6633a10b56d8976e815f85ab12162e0eef97cc6c39ad277248d54")
let goldenJob = try BatchGrainJob(path: "DCIM/100CANON/IMG_6600.JPG", sourceBytes: 3114560,
                                sourceSHA256: sourceHash, settings: settings)
let encoded = try BatchGrainManifest.encode([goldenJob])
try verify(encoded == Data(contentsOf: fixture), "Shared C/Swift fixture differs")
try verify(encoded[248..<280] == data(hex: "f96f3bf1eccd86d3e584a7bbbff6c42b052e30ecfe263cdccfaf778887b379f6"),
           "Golden job identity differs")

let off = try BatchGrainSettings(amount: .off, cell: 3, seed: .max)
let foldedAlias = try BatchGrainJob(path: goldenJob.path.lowercased(), sourceBytes: 1,
                                   sourceSHA256: sourceHash, settings: off)
try rejects("case-insensitive duplicate regardless of settings") {
    _ = try BatchGrainManifest.encode([goldenJob, foldedAlias])
}
try rejects("empty queue") { _ = try BatchGrainManifest.encode([]) }
try rejects("oversized queue") { _ = try BatchGrainManifest.encode(Array(repeating: goldenJob, count: 65)) }
for invalid in ["../file.jpg", "/file.jpg", "sub//file.jpg", "sub/./file.jpg", "a\\file.jpg", "é.jpg",
                "file.CR2", "a.jpg/", String(repeating: "a", count: 124) + ".jpg"] {
    try rejects(invalid) {
        _ = try BatchGrainJob(path: invalid, sourceBytes: 1, sourceSHA256: sourceHash, settings: off)
    }
}
try rejects("empty source") {
    _ = try BatchGrainJob(path: "a.jpg", sourceBytes: 0, sourceSHA256: sourceHash, settings: off)
}
try rejects("oversize source") {
    _ = try BatchGrainJob(path: "a.jpg", sourceBytes: BatchGrainManifest.maxSourceBytes + 1,
                         sourceSHA256: sourceHash, settings: off)
}
try rejects("short digest") {
    _ = try BatchGrainJob(path: "a.jpg", sourceBytes: 1, sourceSHA256: Data(), settings: off)
}
try rejects("unsupported cell") { _ = try BatchGrainSettings(amount: .amount11, cell: 4, seed: 1) }
let offJob = try BatchGrainJob(path: goldenJob.path, sourceBytes: goldenJob.sourceBytes,
                              sourceSHA256: sourceHash, settings: off)
let offManifest = try BatchGrainManifest.encode([offJob])
try verify(offManifest[248..<280] != encoded[248..<280], "Output-affecting settings must change identity")
try verify(offManifest[232..<244] == Data([0, 0, 0, 0, 3, 0, 0, 0, 255, 255, 255, 255]),
           "Off, cell and seed wire fields differ")

let files = FileManager.default
let temp = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("canon-batch-checks-" + UUID().uuidString)
try files.createDirectory(at: temp, withIntermediateDirectories: false)
defer { try? files.removeItem(at: temp) }
let source = temp.appendingPathComponent("image.JPG")
let output = temp.appendingPathComponent("queue.cbatch")
let jpeg = Data([0xff, 0xd8, 0xff, 0xd9])
try jpeg.write(to: source)
try BatchGrainExporter.export(sourceRoot: temp, sources: [source], settings: settings, to: output)
let expected = try BatchGrainJob(path: "image.JPG", sourceBytes: UInt32(jpeg.count),
                                 sourceSHA256: Data(SHA256.hash(data: jpeg)), settings: settings)
try verify(Data(contentsOf: output) == BatchGrainManifest.encode([expected]), "Export must pin exact source bytes")
try rejects("no overwrite") {
    try BatchGrainExporter.export(sourceRoot: temp, sources: [source], settings: off, to: output)
}
try verify(Data(contentsOf: output) == BatchGrainManifest.encode([expected]), "Existing manifest changed")
try verify(Data(contentsOf: source) == jpeg, "Source changed")

let rejectedOutput = temp.appendingPathComponent("rejected.cbatch")
let linkedSource = temp.appendingPathComponent("link.JPG")
try files.createSymbolicLink(at: linkedSource, withDestinationURL: source)
try rejects("source symlink") {
    try BatchGrainExporter.export(sourceRoot: temp, sources: [linkedSource], settings: off, to: rejectedOutput)
}
try files.removeItem(at: linkedSource)
try files.linkItem(at: source, to: linkedSource)
try rejects("hardlink alias") {
    try BatchGrainExporter.export(sourceRoot: temp, sources: [source], settings: off, to: rejectedOutput)
}
try files.removeItem(at: linkedSource)
let linkedDirectory = temp.appendingPathComponent("redirect")
try files.createSymbolicLink(at: linkedDirectory, withDestinationURL: temp)
try rejects("output directory symlink") {
    try BatchGrainExporter.export(sourceRoot: temp, sources: [source], settings: off,
                                 to: linkedDirectory.appendingPathComponent("other.cbatch"))
}
try verify(!files.fileExists(atPath: temp.appendingPathComponent("other.cbatch").path), "Redirected export created output")
print("Batch grain manifest and host export checks passed.")
