// CameraStyleExportTool: the app's Camera styles export without the UI.
// usage: CameraStyleExportTool [--pf2] MODEL.json|interim RECIPES.json OUT_DIR
//   RECIPES.json: array of up to 3 Recipe objects (the app's library format; null = empty slot).
// Plans with RecipeToCanonStyle.plan, compiles with Canon's converter in process, writes CFPSTYLE.BIN + SLOTS.txt.
import Foundation
import ProfileCore

let arguments = CommandLine.arguments
// --find-card: read-only report of what "Copy to card" would choose.
if arguments.dropFirst().first == "--find-card" {
    let cards = CameraStyleCard.find()
    for c in cards { print("card \(c.volumeName) at \(c.root.path): AUTOEXEC.BIN \(c.extensionSHA256) → \(c.knownExtension?.name ?? "not a style extension")") }
    switch CameraStyleCard.choose(cards) {
    case .card(let c): print("would copy to \(c.root.path)"); print(CameraStyleCard.cameraSteps(c.knownExtension!)); exit(0)
    case .problem(let why): print("refused: \(why)"); exit(1)
    }
}
let stock = arguments.dropFirst().first == "--pf2"
let a = stock ? [arguments[0]] + Array(arguments.dropFirst(2)) : arguments
guard a.count == 4 else { FileHandle.standardError.write("usage: CameraStyleExportTool [--pf2] MODEL.json|interim RECIPES.json OUT_DIR\n".data(using: .utf8)!); exit(2) }
do {
    let model = a[1] == "interim" ? nil : try CalibrationModel(contentsOf: URL(fileURLWithPath: a[1]))
    let recipes = try JSONDecoder().decode([Recipe?].self, from: Data(contentsOf: URL(fileURLWithPath: a[2])))
    guard (1...3).contains(recipes.count) else { throw NSError(domain: "tool", code: 1, userInfo: [NSLocalizedDescriptionKey: "1–3 recipes"]) }
    var plans: [CanonSlotPlan?] = []
    for (i, r) in recipes.enumerated() {
        guard let r else { plans.append(nil); continue }
        let p = try RecipeToCanonStyle.plan(recipe: r, slot: i + 1, calibration: model)
        plans.append(p)
        print("User Def. \(i + 1): \(r.name) [\(p.source.kind)] WB \(p.whiteBalance.preset) \(p.whiteBalance.amberBlue)/\(p.whiteBalance.greenMagenta)")
        for n in p.notes { print("    note: \(n)") }
        for n in p.approximated { print("    approx: \(n)") }
    }
    plans += Array(repeating:nil,count:3-plans.count)
    let out = URL(fileURLWithPath: a[3])
    if stock {
        try FileManager.default.createDirectory(at:out,withIntermediateDirectories:true)
        let written = try CameraStyleCardExporter.exportForEOSUtility(plans,to:out)
        print("wrote",written.joined(separator:", "),"to",out.path)
        exit(0)
    }
    let needs = plans.contains { $0?.isRegistered == true }
    let compiler = needs ? try CanonStyleCompiler(isolation: .inProcess) : nil
    let compiled = try CameraStyleCardExporter.compile(plans, compiler: compiler)
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    let receipt = try CameraStyleCardExporter.export(compiled, to: out, includeWhiteBalanceBlock: true, includePictureStyleFiles: true, converter: compiler?.installation)
    print("wrote", receipt.files.joined(separator: ", "), "to", out.path)
} catch { FileHandle.standardError.write("error: \(error.localizedDescription)\n".data(using: .utf8)!); exit(1) }
