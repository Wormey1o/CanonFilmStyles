// swift-tools-version: 5.9
import Foundation
import PackageDescription

let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let privateRuntime = [
 "Resources/AUTOEXEC.BIN",
 "Tests/ProfileCoreTests/WorkingCardChecks.swift",
 "Tests/ProfileCoreTests/PairedRollbackChecks.swift"
].allSatisfy { FileManager.default.fileExists(atPath: packageRoot.appendingPathComponent($0).path) }

var targets: [Target] = [
 .target(name: "FilmProfileEngine", publicHeadersPath: "include", cSettings: [
  .define("SE_HOSTED"), .unsafeFlags(["-ffp-contract=off"])
 ]),
 .target(name: "ProfileCore", dependencies: ["FilmProfileEngine"]),
 .target(name: "RecipeCardImport", dependencies: ["ProfileCore"]),
 .executableTarget(name: "CanonFilmProfiles", dependencies: ["ProfileCore", "RecipeCardImport"]),
 .executableTarget(name: "CameraStyleExportTool", dependencies: ["ProfileCore"], path: "Tools/CameraStyleExportTool"),
 .executableTarget(name: "RecipeCardChecks", dependencies: ["ProfileCore", "RecipeCardImport"], path: "Tests/RecipeCardImportChecks"),
 .executableTarget(name: "LUTExportChecks", dependencies: ["ProfileCore", "FilmProfileEngine"], path: "Tests/LUTExportChecks"),
 .executableTarget(name: "BatchGrainChecks", dependencies: ["ProfileCore"], path: "Tests/BatchGrainChecks"),
 .executableTarget(name: "NativeRecipeChecks", dependencies: ["ProfileCore"], path: "Tests/NativeRecipeChecks"),
 .executableTarget(name: "ProfileChecks", dependencies: ["ProfileCore", "FilmProfileEngine"], path: "Tests/ProfileCoreTests",
                   swiftSettings: privateRuntime ? [.define("CANON_PRIVATE_RUNTIME_CHECKS")] : [])
]

// These tools use the research checkout's captured images, converter references or runtime fixtures.
let researchChecks: [(name: String, path: String, exclude: [String])] = [
 ("PhotoPreviewChecks", "Tests/PhotoPreviewChecks", []),
 ("NitroPresetChecks", "Tests/NitroPresetChecks", []),
 ("NativeBootPackageChecks", "Tests/NativeBootPackageChecks", []),
 ("NativeUserDefSessionChecks", "Tests/NativeUserDefSessionChecks", []),
 ("PictureStyleChecks", "Tests/PictureStyleChecks", []),
 ("CanonStyleCompilerChecks", "Tests/CanonStyleCompilerChecks", []),
 ("RecipeToCanonStyleChecks", "Tests/RecipeToCanonStyleChecks", ["Fixtures"])
]
for check in researchChecks where FileManager.default.fileExists(atPath: packageRoot.appendingPathComponent(check.path).path) {
 targets.append(.executableTarget(name: check.name, dependencies: ["ProfileCore"], path: check.path, exclude: check.exclude))
}

let package = Package(
 name: "CanonFilmProfiles", platforms: [.macOS(.v14)],
 products: [.executable(name: "CanonFilmProfiles", targets: ["CanonFilmProfiles"])],
 targets: targets
)
