import AppKit
import SwiftUI
import ProfileCore

/// Camera styles: Ricoh recipes → what the 450D needs in User Def. 1–3 (registered Picture Styles or
/// Canon Monochrome), exported as CFPSTYLE.BIN + SLOTS.txt. Assignments live in CameraStyles.json,
/// separate from the Effects slots in Recipes.json and from the native companion.
struct CameraStylesState: Codable, Equatable {
 var schema = 1
 var slots: [UUID?] = [nil, nil, nil]
 var calibrationModelPath: String?
 /// Set when the user chose interim rules; otherwise the built-in model (Resources/CalibrationModel.json) is the default.
 var useInterimRules: Bool?
 static func load(_ url: URL) throws -> Self {
  let attributes: [FileAttributeKey: Any]
  do { attributes = try FileManager.default.attributesOfItem(atPath: url.path) }
  catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
   return Self()
  }
  guard attributes[.type] as? FileAttributeType == .typeRegular else {
   throw ProfileError.invalid("Camera styles settings must be a regular file.")
  }
  let handle = try FileHandle(forReadingFrom: url)
  defer { try? handle.close() }
  guard let data = try handle.read(upToCount: 65_537), data.count <= 65_536 else {
   throw ProfileError.invalid("Camera styles settings are empty or too large.")
  }
  let value = try JSONDecoder().decode(Self.self, from: data)
  guard value.schema == 1, value.slots.count == 3 else {
   throw ProfileError.invalid("Unsupported camera styles settings format.")
  }
  return value
 }
}

extension AppModel {
 func loadCameraStyles() {
  let state: CameraStylesState
  do { state = try CameraStylesState.load(cameraStylesURL) }
  catch {
   cameraStylesSettingsProblem = "CameraStyles.json could not be read and has been kept. Repair it or move it aside, then reopen the app to save settings. " + error.localizedDescription
   loadBuiltInCalibrationModel()
   return
  }
  cameraStyleSlots = state.slots.map { id in id.flatMap { id in library.recipes.contains { $0.id == id } ? id : nil } }
  useInterimRules = state.useInterimRules ?? false
  calibrationModelPath = state.calibrationModelPath
  if let path = calibrationModelPath {
   do { calibrationModel = try CalibrationModel(contentsOf: URL(fileURLWithPath: path)) }
   catch {
    calibrationModel = nil
    calibrationModelProblem = "Could not load \(URL(fileURLWithPath: path).lastPathComponent). Interim rules apply until the model becomes available or you choose another. " + error.localizedDescription
   }
  } else if !useInterimRules { loadBuiltInCalibrationModel() }
 }
 /// The calibration model shipped with the app (default since Set D, 25 Nov 2026).
 var builtInCalibrationModelURL: URL { resources.appendingPathComponent("CalibrationModel.json") }
 func loadBuiltInCalibrationModel() {
  calibrationModelPath = nil
  do {
   calibrationModel = try CalibrationModel(contentsOf: builtInCalibrationModelURL)
   calibrationModelProblem = nil
  } catch {
   calibrationModel = nil
   calibrationModelProblem = "Could not load the built-in calibration model. Interim rules apply. " + error.localizedDescription
  }
 }
 func saveCameraStyles() {
  guard cameraStylesSettingsProblem == nil else {
   status = "Camera styles settings kept in memory."
   return
  }
  let state = CameraStylesState(slots: cameraStyleSlots, calibrationModelPath: calibrationModelPath, useInterimRules: useInterimRules ? true : nil)
  do { let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]; try e.encode(state).write(to: cameraStylesURL, options: .atomic) }
  catch { status = "Camera style slots kept in memory: " + error.localizedDescription }
 }
 func assignCameraStyle(_ slot: Int, _ id: UUID?) { cameraStyleSlots[slot] = id; saveCameraStyles() }

 /// The plan for User Def. slot+1, or why there is none. Recomputed from the current recipe each time.
 func cameraStylePlan(_ slot: Int) -> Result<CanonSlotPlan, Error>? {
  guard let id = cameraStyleSlots[slot], let recipe = library.recipes.first(where: { $0.id == id }) else { return nil }
  return Result { try RecipeToCanonStyle.plan(recipe: recipe, slot: slot + 1, calibration: calibrationModel) }
 }

 func chooseCalibrationModel() {
  let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
  panel.message = "Choose calibration_model.json written by fit_model.py fit."
  guard panel.runModal() == .OK, let url = panel.url else { return }
  do {
   let model = try CalibrationModel(contentsOf: url)
   calibrationModel = model
   calibrationModelPath = url.path
   calibrationModelProblem = nil
   useInterimRules = false
   status = "Calibration model \(model.source.version) loaded."
   saveCameraStyles()
  } catch { self.error = error.localizedDescription }
 }
 func clearCalibrationModel() {
  calibrationModel = nil
  calibrationModelPath = nil
  calibrationModelProblem = nil
  useInterimRules = true
  status = "Using interim rules."
  saveCameraStyles()
 }
 func useBuiltInCalibrationModel() {
  useInterimRules = false
  loadBuiltInCalibrationModel()
  status = calibrationModel.map { "Built-in calibration model \($0.source.version) in use." } ?? "Using interim rules."
  saveCameraStyles()
 }

 func exportCameraStyles() {exportStyles(forEOSUtility:false)}
 func exportEOSUtilityStyles() {exportStyles(forEOSUtility:true)}

 private func exportStyles(forEOSUtility:Bool) {
  guard !exportingCameraStyles else { return }
  var plans: [CanonSlotPlan?] = []
  for slot in 0..<3 {
   switch cameraStylePlan(slot) {
   case .none: plans.append(nil)
   case .success(let plan)?: plans.append(plan)
   case .failure(let e)?: self.error = "User Def. \(slot + 1): " + e.localizedDescription; return
   }
  }
  guard plans.contains(where: { $0 != nil }) else { return }
  let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
  panel.prompt = "Export"
  panel.message = forEOSUtility ? "Choose a fresh Mac folder for the .pf2 files and manual slot settings." : "Choose a fresh folder for CFPSTYLE.BIN and SLOTS.txt."
  guard panel.runModal() == .OK, let folder = panel.url else { return }
  let includePF2 = cameraStylesIncludePF2, includeWB = cameraStylesWBBlock, executable = Bundle.main.executableURL!
  let needsConverter = !forEOSUtility && plans.contains { $0?.isRegistered == true }
  exportingCameraStyles = true; status = forEOSUtility ? "Exporting EOS Utility styles…" : needsConverter ? "Compiling styles with Canon’s converter…" : "Writing CFPSTYLE.BIN…"
  Task {
   defer { exportingCameraStyles = false }
   do {
    if forEOSUtility {
     let files=try await Task.detached(priority:.userInitiated) {
      try CameraStyleCardExporter.exportForEOSUtility(plans,to:folder)
     }.value
     status="Exported \(files.joined(separator:", "))."
     NSWorkspace.shared.activateFileViewerSelecting([folder.appendingPathComponent(CameraStyleCardExporter.slotsFileName)])
     return
    }
    let receipt = try await Task.detached(priority: .userInitiated) { () throws -> CameraStyleCardExporter.Receipt in
     let compiler = needsConverter ? try CanonStyleCompiler(isolation: .helper(executable: executable)) : nil
     let compiled = try CameraStyleCardExporter.compile(plans, compiler: compiler)
     return try CameraStyleCardExporter.export(compiled, to: folder, includeWhiteBalanceBlock: includeWB, includePictureStyleFiles: includePF2, converter: compiler?.installation)
    }.value
    status = "Exported \(receipt.files.joined(separator: ", "))" + (receipt.withWBBlock ? " with the WB block — see SLOTS.txt." : " — set white balance by hand (see SLOTS.txt).")
    NSWorkspace.shared.activateFileViewerSelecting([folder.appendingPathComponent(CameraStyleCardExporter.fileName)])
   } catch { self.error = error.localizedDescription; status = "Camera style export failed." }
  }
 }
}

struct CameraStylesPlanView: View {
 @ObservedObject var model: AppModel
 var body: some View {
  ScrollView {
   VStack(alignment: .leading, spacing: 20) {
    VStack(alignment: .leading, spacing: 7) {
     Text("Camera styles").font(.system(size: 30, weight: .semibold))
     Text("What the 450D needs in User Def. 1–3, using Canon’s own JPEG processing. Colour recipes become registered Picture Styles; monochrome recipes use Canon Monochrome. White balance is camera-wide: the card file asks the camera to set it when a slot is selected (if the camera payload supports it); otherwise set it by hand.").font(.subheadline).fpSecondaryText()
    }
    if model.calibrationModel == nil {
     FPCautionCard {
      FPCautionTitle(text: "Interim translation rules")
      Text("Plans use hand-tuned starting styles and estimated slider adjustments. Review each slot before exporting.").font(.caption).fpSecondaryText().padding(.bottom, 12)
     }
    }
    ForEach(0..<3, id: \.self) { slot in CameraStyleSlotCard(model: model, slot: slot) }
   }.padding(24)
  }
 }
}

struct CameraStyleSlotCard: View {
 @ObservedObject var model: AppModel
 let slot: Int
 var body: some View {
  VStack(alignment: .leading, spacing: 10) {
   HStack(spacing: 8) {
    FPSlotBadge(slot: slot + 1)
    Text("User Def. \(slot + 1)").font(.system(size: 15, weight: .semibold))
    Spacer()
    if case .success(let plan)? = model.cameraStylePlan(slot) {
     if plan.source.kind == .interim { FPCautionChip(text: "Interim rules") } else { Text(plan.source.label).font(.caption2.weight(.semibold)).fpSecondaryText() }
    }
   }
   switch model.cameraStylePlan(slot) {
   case .none:
    Text("Empty — the camera slot is left as it is. Choose a recipe in the panel on the right.").font(.callout).fpSecondaryText()
   case .failure(let error)?:
    Label(error.localizedDescription, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(FP.cautionText)
   case .success(let plan)?:
    CameraStylePlanDetail(plan: plan)
   }
  }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(FP.slotCard, in: RoundedRectangle(cornerRadius: 10))
 }
}

struct CameraStylePlanDetail: View {
 let plan: CanonSlotPlan
 private func signed(_ v: Int) -> String { v > 0 ? "+\(v)" : "\(v)" }
 var body: some View {
  VStack(alignment: .leading, spacing: 10) {
   Text(plan.recipeName).font(.title3.weight(.semibold))
   if let style = plan.registered {
    Text("Registered Picture Style “\(style.caption)” · base Standard").font(.callout)
    Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 4) {
     GridRow { Text("Sharpness").fpSecondaryText(); Text("\(style.sharpness)").monospacedDigit(); Text("Contrast").fpSecondaryText(); Text(signed(style.contrast)).monospacedDigit() }
     GridRow { Text("Saturation").fpSecondaryText(); Text(signed(style.saturation)).monospacedDigit(); Text("Colour tone").fpSecondaryText(); Text(signed(style.colourTone)).monospacedDigit() }
    }.font(.system(.callout, design: .monospaced))
    HStack(alignment: .top, spacing: 14) {
     VStack(alignment: .leading, spacing: 4) {
      Text("L* curve").font(.caption.weight(.medium))
      ToneCurve(curve: style.curve.map { ($0.input, $0.output) }).frame(width: 150, height: 110)
      Text(style.curve.map { "\($0.input)→\($0.output)" }.joined(separator: "  ")).font(FP.cameraString(.caption2)).fpSecondaryText().frame(width: 150, alignment: .leading)
     }
     VStack(alignment: .leading, spacing: 4) {
      Text("Colour points (\(style.colourPoints.count))").font(.caption.weight(.medium))
      if style.colourPoints.isEmpty { Text("None").font(.caption).fpSecondaryText() }
      ForEach(Array(style.colourPoints.enumerated()), id: \.offset) { _, p in
       HStack(spacing: 6) {
        Circle().fill(Color(hue: Double(p.hue) / 360, saturation: 0.7, brightness: 0.85)).frame(width: 10, height: 10)
        Text("H\(p.hue) (\(p.hueLow)–\(p.hueHigh))  →  H\(signed(p.hueShift)) S\(signed(p.saturationShift)) L\(signed(p.luminosityShift))").font(FP.cameraString(.caption))
       }
      }
     }
    }
   } else if let mono = plan.monochrome {
    Text("Canon Monochrome (built-in) · no curve or colour points").font(.callout)
    Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 4) {
     GridRow { Text("Contrast").fpSecondaryText(); Text(signed(mono.contrast)).monospacedDigit(); Text("Sharpness").fpSecondaryText(); Text("\(mono.sharpness)").monospacedDigit() }
     GridRow { Text("Filter").fpSecondaryText(); Text(mono.filter.name); Text("Toning").fpSecondaryText(); Text(mono.toning.name) }
    }.font(.system(.callout, design: .monospaced))
   }
   HStack(spacing: 8) {
    Image(systemName: "hand.point.up.left").foregroundStyle(FP.controlAccent)
    (Text(plan.whiteBalance.applyOnSlotSelect ? "WB on slot select (else by hand): " : "WB left as is · recipe: ") + Text(plan.whiteBalance.summary).font(FP.cameraString(.callout).weight(.semibold))).font(.callout)
   }.padding(.vertical, 6).padding(.horizontal, 10).background(FP.chipFill, in: RoundedRectangle(cornerRadius: 7))
   if let note = plan.whiteBalance.note { Text(note).font(.caption).fpSecondaryText() }
   Text("Model: \(plan.source.label) — \(plan.source.confidence)").font(.caption).fpSecondaryText()
   if !plan.dropped.isEmpty { Text("Dropped: " + plan.dropped.joined(separator: " · ")).font(.caption).fpSecondaryText() }
   if !plan.approximated.isEmpty { Text("Approximated: " + plan.approximated.joined(separator: " · ")).font(.caption).fpSecondaryText() }
   ForEach(plan.notes, id: \.self) { Text($0).font(.caption).fpSecondaryText() }
  }
 }
}

struct CameraStyleSlotsView: View {
 @ObservedObject var model: AppModel
 var body: some View {
  ScrollView {
   VStack(alignment: .leading, spacing: 18) {
    Text("User Def. styles").font(.title3.weight(.semibold))
    Text("Choose up to three recipes. These assignments are separate from Effects and Native processing slots.").font(.callout).fpSecondaryText()
    if let problem = model.cameraStylesSettingsProblem {
     Label(problem, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(FP.cautionText)
    }
    VStack(spacing: 9) {
     ForEach(0..<3, id: \.self) { slot in
      VStack(alignment: .leading, spacing: 8) {
       HStack(spacing: 8) { FPSlotBadge(slot: slot + 1); Text("User Def. \(slot + 1)").font(.system(size: 13, weight: .semibold)); Spacer() }
       Picker("Recipe", selection: Binding(get: { model.cameraStyleSlots[slot] }, set: { model.assignCameraStyle(slot, $0) })) {
        Text("Empty").tag(nil as UUID?)
        ForEach(model.library.recipes.filter { $0.factoryID == nil }) { Text($0.name).tag($0.id as UUID?) }
       }.labelsHidden()
       if case .success(let plan)? = model.cameraStylePlan(slot) {
        Text(plan.isRegistered ? "Registered style · WB \(plan.whiteBalance.summary)" : "Monochrome · WB \(plan.whiteBalance.summary)").font(.caption).fpSecondaryText()
       }
      }.padding(12).background(FP.slotCard, in: RoundedRectangle(cornerRadius: 10))
     }
    }
    Divider()
    VStack(alignment: .leading, spacing: 6) {
     Text("Translation model").font(.subheadline.weight(.medium))
     Text(model.calibrationModel.map { "\($0.source.label) (\(model.calibrationModelPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "built in"))" } ?? "Interim rules \(InterimRules.version) — not calibrated").font(.caption).fpSecondaryText()
     if let problem = model.calibrationModelProblem {
      Label(problem, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(FP.cautionText)
     }
     HStack {
      Button { model.chooseCalibrationModel() } label: { Text("Load calibration model…").foregroundStyle(FP.brandInk) }.buttonStyle(.link)
      if !model.useInterimRules { Button { model.clearCalibrationModel() } label: { Text("Use interim rules").foregroundStyle(FP.brandInk) }.buttonStyle(.link) }
      if model.calibrationModel == nil || model.calibrationModelPath != nil { Button { model.useBuiltInCalibrationModel() } label: { Text("Use built-in model").foregroundStyle(FP.brandInk) }.buttonStyle(.link) }
     }
    }
    Divider()
    Button(action: model.exportEOSUtilityStyles) {
     Label("Export for EOS Utility…", systemImage:"square.and.arrow.up").frame(maxWidth:.infinity)
    }.buttonStyle(FPPrimaryButtonStyle()).disabled(model.exportingCameraStyles || model.cameraStyleSlots.allSatisfy { $0 == nil })
    Text("Make .pf2 files for colour styles and a slot guide for Monochrome and white balance.").font(.caption).fpSecondaryText()
    Toggle("Include WB block in card file", isOn: $model.cameraStylesWBBlock).font(.callout)
    Toggle("Also save .pf2 files for EOS Utility", isOn: $model.cameraStylesIncludePF2).font(.callout)
    Button(action: model.exportCameraStyles) {
     HStack { if model.exportingCameraStyles { ProgressView().controlSize(.small) }; Text(model.exportingCameraStyles ? "Exporting…" : "Export extension card file…"); Image(systemName: "square.and.arrow.up") }.frame(maxWidth: .infinity)
    }.buttonStyle(.bordered).disabled(model.exportingCameraStyles || model.cameraStyleSlots.allSatisfy { $0 == nil })
    Text("Writes CFPSTYLE.BIN (50,420 bytes with the WB block, 50,356 without) and SLOTS.txt to a folder or card root you choose, without AppleDouble ._ files. Registered styles are compiled by Canon’s installed Picture Style converter (EOS Utility 3 or Picture Style Editor). The card file is read by the style-install camera extension; SLOTS.txt lists each slot’s WB.").font(.caption).fpSecondaryText()
    Spacer(minLength: 0)
   }.padding(22)
  }.background(FP.inspectorBackground)
 }
}
