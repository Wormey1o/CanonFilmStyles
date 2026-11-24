import Foundation

/// Host-only authoring export. This intentionally does not create AUTOEXEC.BIN,
/// stage files or call either existing camera installer.
public enum NativeRecipeExporter {
    public static func compile(store: NativeRecipeStore, currentRecipes: [Recipe],
                               profileCompiler: ProfileCompiler? = nil,
                               selectedSlot: Int? = nil, attemptLimit: Int = 0) throws -> NativeCompiledExport {
        try NativeRecipeCompiler.compile(store: store, currentRecipes: currentRecipes,
                                         profileCompiler: profileCompiler,
                                         selectedSlot: selectedSlot, attemptLimit: attemptLimit)
    }

    /// Writes a distinct host-only sidecar and authoring report to a new folder.
    /// It is not a bootable package or an installation operation.
    @discardableResult
    public static func export(store: NativeRecipeStore, currentRecipes: [Recipe],
                              profileCompiler: ProfileCompiler? = nil,
                              selectedSlot: Int? = nil, attemptLimit: Int = 0,
                              to folder: URL) throws -> URL {
        guard folder.isFileURL else { throw ProfileError.invalid("Choose a local folder for the host-only native authoring export.") }
        let compiled = try compile(store: store, currentRecipes: currentRecipes,
                                  profileCompiler: profileCompiler,
                                  selectedSlot: selectedSlot, attemptLimit: attemptLimit)
        let destination = folder.standardizedFileURL
        var node = destination
        while node.path != "/" {
            if FileManager.default.fileExists(atPath: node.path) {
                let values = try node.resourceValues(forKeys: [.isSymbolicLinkKey])
                guard values.isSymbolicLink != true else { throw ProfileError.invalid("Native export path contains a symbolic link.") }
            }
            node.deleteLastPathComponent()
        }
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw ProfileError.invalid("Choose a new, unused folder; native export never overwrites.")
        }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var report = try encoder.encode(compiled.report); report.append(10)
        do {
            try compiled.sidecar.write(to: destination.appendingPathComponent("CNATIV.BIN"), options: .withoutOverwriting)
            try report.write(to: destination.appendingPathComponent("native-authoring.json"), options: .withoutOverwriting)
        } catch {
            // Preserve partial output for review; it has no manifest and is not bootable.
            throw error
        }
        return destination
    }
}
