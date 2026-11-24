import AppKit
import SwiftUI
import ProfileCore

enum NativeSessionMode:String,Codable,CaseIterable,Equatable {
 case finiteStartup
 case capturedUserDef
 var title:String {
  switch self {
  case .finiteStartup:return "Host-selected finite startup"
  case .capturedUserDef:return "Captured Canon User Def. selector"
  }
 }
}

/// App metadata lives outside Recipes.json so older Effects editors cannot erase it.
/// Schema 2 adds a separate captured-style session policy; schema 1 remains readable.
struct NativeAppCompanion:Codable {
 var schema:Int
 var store:NativeRecipeStore
 var startupSlot:Int?
 var attemptLimit:Int
 var sessionMode:NativeSessionMode
 var userDefAttemptLimit:Int
 private enum CodingKeys:String,CodingKey {case schema,store,startupSlot,attemptLimit,sessionMode,userDefAttemptLimit}
 init(store:NativeRecipeStore,startupSlot:Int?,attemptLimit:Int,
      sessionMode:NativeSessionMode = .finiteStartup,userDefAttemptLimit:Int = Int(Int32.max)) {
  self.schema=2;self.store=store;self.startupSlot=startupSlot;self.attemptLimit=attemptLimit
  self.sessionMode=sessionMode;self.userDefAttemptLimit=userDefAttemptLimit
 }
 init(from decoder:Decoder)throws {
  let c=try decoder.container(keyedBy:CodingKeys.self)
  schema=try c.decode(Int.self,forKey:.schema)
  guard schema==1 || schema==2 else{throw ProfileError.invalid("Unsupported native companion schema.")}
  store=try c.decode(NativeRecipeStore.self,forKey:.store)
  startupSlot=try c.decodeIfPresent(Int.self,forKey:.startupSlot)
  attemptLimit=try c.decode(Int.self,forKey:.attemptLimit)
  if schema == 1 {
   guard !c.contains(.sessionMode),!c.contains(.userDefAttemptLimit) else {
    throw ProfileError.invalid("Schema 1 native companions cannot contain schema 2 session fields.")
   }
   sessionMode = .finiteStartup;userDefAttemptLimit = Int(Int32.max)
  }else{
   sessionMode=try c.decode(NativeSessionMode.self,forKey:.sessionMode)
   userDefAttemptLimit=try c.decode(Int.self,forKey:.userDefAttemptLimit)
  }
 }
 static func load(_ url:URL)throws->Self {
  let data=try Data(contentsOf:url)
  guard data.count<=8_388_608 else{throw ProfileError.invalid("Native companion is too large.")}
  let value=try JSONDecoder().decode(Self.self,from:data)
  try value.store.validate()
  guard value.store.slots.count==3,(0...8).contains(value.attemptLimit),
        value.userDefAttemptLimit>=1,value.userDefAttemptLimit<=Int(Int32.max),
        value.startupSlot == nil || (0..<3).contains(value.startupSlot!),
        Set(value.store.records.map(\.sourceRecipeID)).count==value.store.records.count else{throw ProfileError.invalid("Invalid native companion metadata.")}
  return value
 }
 func encode(to encoder:Encoder)throws {
  var c=encoder.container(keyedBy:CodingKeys.self)
  try c.encode(2,forKey:.schema);try c.encode(store,forKey:.store)
  try c.encodeIfPresent(startupSlot,forKey:.startupSlot);try c.encode(attemptLimit,forKey:.attemptLimit)
  try c.encode(sessionMode,forKey:.sessionMode);try c.encode(userDefAttemptLimit,forKey:.userDefAttemptLimit)
 }
 func save(_ url:URL)throws {
  let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
  try encoder.encode(self).write(to:url,options:.atomic)
 }
}

/// Produces a complete proposal before the UI assigns or persists any imported record.
enum NativeCompanionImport {
 static func merging(_ incoming:NativeRecipeStore,into current:NativeRecipeStore,recipes:[Recipe],compiler:ProfileCompiler)throws->NativeRecipeStore {
  try incoming.validate();try current.validate()
  guard incoming.records.allSatisfy({record in recipes.contains{$0.id==record.sourceRecipeID}}) else{throw ProfileError.invalid("Import the matching recipe library first. Native records refer to recipe UUIDs not present here.")}
  var proposed=current
  for record in incoming.records {
   guard let recipe=recipes.first(where:{$0.id==record.sourceRecipeID}) else{continue}
   if let existing=proposed.records.first(where:{$0.sourceRecipeID==record.sourceRecipeID}) {
    if existing == record {continue}
    let pristine=try NativeRecipeAuthoring.draft(from:recipe,normalizedImport:nil,compiler:compiler)
    guard existing == pristine else{throw ProfileError.invalid("A different native record already exists for "+recipe.name+". Import as a duplicated recipe library to preserve both drafts.")}
   }
   let updated=try NativeRecipeAuthoring.refresh(record:record,for:recipe,compiler:compiler)
   proposed.records.removeAll{$0.sourceRecipeID==record.sourceRecipeID};proposed.records.append(updated)
  }
  return proposed
 }
}

extension AppModel {
 var currentNative:NativeRecipeRecord? {nativeStore.records.first{$0.sourceRecipeID==selected}}
 var nativeSourceRecoveryMessage:String? {
  guard let record=currentNative,record.source.completeness == .importedSnapshot,record.differences.contains(where:{$0.classification == .unresolved}) else{return nil}
  return "Correct the card/import and re-import; the original snapshot is preserved."
 }
 var currentNativeApproved:Bool {
  guard let record=currentNative,let recipe=current else{return false}
  return NativeRecipeAuthoring.isApprovalCurrent(record:record,for:recipe)
 }
 func reconcileNative() {
  guard nativeStoreProblem == nil else{return}
  do {
   let ids=Set(library.recipes.map(\.id))
   nativeStore.records.removeAll{!ids.contains($0.sourceRecipeID)}
   nativeStore.slots=nativeStore.slots.map{ id in id.flatMap{ids.contains($0) ? $0:nil} }
   for recipe in library.recipes {
    if let index=nativeStore.records.firstIndex(where:{$0.sourceRecipeID==recipe.id}) {
     nativeStore.records[index]=try NativeRecipeAuthoring.refresh(record:nativeStore.records[index],for:recipe,compiler:compiler)
    }else{
     nativeStore.records.append(try NativeRecipeAuthoring.draft(from:recipe,normalizedImport:nil,compiler:compiler))
    }
   }
   if let slot=nativeStartupSlot,nativeStore.slots[slot] == nil {nativeStartupSlot=nil;nativeAttemptLimit=0}
  }catch{nativeStoreProblem=error.localizedDescription}
 }
 func verifyNativeLibraryUnchangedOnDisk()throws {
  guard FileManager.default.fileExists(atPath:libraryURL.path) else{return}
  let disk=try RecipeLibrary.load(from:libraryURL)
  guard NativeCanonical.digest(disk)==lastSavedLibraryDigest else{throw ProfileError.invalid("The recipe library changed in another editor. Reopen the app to review its current contents before native approval or export.")}
 }
 func saveNative()throws {
  guard nativeStoreProblem == nil else{return}
  if !FileManager.default.fileExists(atPath:libraryURL.path) {try library.save(to:libraryURL);lastSavedLibraryDigest=NativeCanonical.digest(library)}
  try NativeAppCompanion(store:nativeStore,startupSlot:nativeStartupSlot,attemptLimit:nativeAttemptLimit,
                         sessionMode:nativeSessionMode,userDefAttemptLimit:nativeUserDefAttemptLimit).save(nativeStoreURL)
 }
 func duplicateNative(from id:UUID,to recipe:Recipe) {
  guard nativeStoreProblem == nil,let record=nativeStore.records.first(where:{$0.sourceRecipeID==id}) else{return}
  do{nativeStore.records.append(try NativeRecipeAuthoring.duplicate(record:record,for:recipe,compiler:compiler))}catch{nativeStoreProblem=error.localizedDescription}
 }

 func nativeBinding<T>(_ key:WritableKeyPath<NativeCanonTuple,T>)->Binding<T> {
  Binding(get:{(self.currentNative?.tuple ?? NativeCanonTuple())[keyPath:key]},set:{value in
   guard self.nativeStoreProblem == nil,let index=self.nativeStore.records.firstIndex(where:{$0.sourceRecipeID==self.selected}),let recipe=self.current else{return}
   var record=self.nativeStore.records[index];record.tuple[keyPath:key]=value;record.approval=nil;self.nativeAcknowledged=[]
   do {self.nativeStore.records[index]=try NativeRecipeAuthoring.refresh(record:record,for:recipe,compiler:self.compiler);try self.saveNative();self.status="Native draft saved; approve the current interpretation before executable export."}catch{self.error=error.localizedDescription}
  })
 }
 var nativeStyleBinding:Binding<NativeStyle> {
  Binding(get:{self.currentNative?.tuple.style ?? .standard},set:{style in
   guard var tuple=self.currentNative?.tuple else{return}
   tuple.style=style;tuple.kind=style == .monochrome ? .mono:.color
   tuple.monoFilter = .none;tuple.monoToning = .none
   if tuple.kind == .mono {tuple.saturation=0;tuple.tone=0}
   self.replaceNativeTuple(tuple)
  })
 }
 func replaceNativeTuple(_ tuple:NativeCanonTuple) {
  guard nativeStoreProblem == nil,let index=nativeStore.records.firstIndex(where:{$0.sourceRecipeID==selected}),let recipe=current else{return}
  do {
   var record=nativeStore.records[index];record.tuple=tuple;record.approval=nil;nativeAcknowledged=[]
   nativeStore.records[index]=try NativeRecipeAuthoring.refresh(record:record,for:recipe,compiler:compiler)
   try saveNative();status="Native tuple saved as an unapproved interpretation."
  }catch{self.error=error.localizedDescription}
 }
 func adoptCurrentNativeSource() {
  guard nativeStoreProblem == nil,let index=nativeStore.records.firstIndex(where:{$0.sourceRecipeID==selected}),let recipe=current,nativeStore.records[index].source.completeness == .legacyCurrentValuesOnly else{return}
  do {
   nativeAcknowledged=[]
   nativeStore.records[index]=try NativeRecipeAuthoring.adoptCurrentAuthoredValuesAsSource(record:nativeStore.records[index],for:recipe,compiler:compiler)
   try saveNative();status="Current authored values adopted as the native source. Original card provenance remains unavailable; review and approve separately."
  }catch{self.error=error.localizedDescription}
 }
 func approveNative(_ ids:Set<String>) {
  guard nativeStoreProblem == nil,let index=nativeStore.records.firstIndex(where:{$0.sourceRecipeID==selected}),let recipe=current else{return}
  do {try verifyNativeLibraryUnchangedOnDisk();nativeStore.records[index]=try NativeRecipeAuthoring.approve(record:nativeStore.records[index],for:recipe,acknowledgedDifferenceIDs:ids,compiler:compiler);try saveNative();status="Approved this exact native interpretation and its disclosed differences."}catch{self.error=error.localizedDescription}
 }
 func revokeNativeApproval() {
  guard let index=nativeStore.records.firstIndex(where:{$0.sourceRecipeID==selected}) else{return}
  nativeStore.records[index].approval=nil;nativeAcknowledged=[]
  do{try saveNative()}catch{self.error=error.localizedDescription}
 }
 func assignNative(_ slot:Int,_ id:UUID?) {
  guard nativeStoreProblem == nil,(0..<3).contains(slot) else{return}
  nativeStore.slots[slot]=id
  if id == nil,nativeStartupSlot==slot {nativeStartupSlot=nil;nativeAttemptLimit=0}
  do{try saveNative()}catch{self.error=error.localizedDescription}
 }
 func exportNativeCompanion(to url:URL)throws {
  guard nativeStoreProblem == nil else{throw ProfileError.invalid(nativeStoreProblem!)}
  try verifyNativeLibraryUnchangedOnDisk()
  reconcileNative()
  guard nativeStoreProblem == nil else{throw ProfileError.invalid(nativeStoreProblem!)}
  try NativeAppCompanion(store:nativeStore,startupSlot:nativeStartupSlot,attemptLimit:nativeAttemptLimit,
                         sessionMode:nativeSessionMode,userDefAttemptLimit:nativeUserDefAttemptLimit).save(url)
 }
 func exportNativeCompanion() {
  let panel=NSSavePanel();panel.allowedContentTypes=[.json];panel.nameFieldStringValue="Film Recipes.native-authoring.json"
  guard panel.runModal() == .OK,let url=panel.url else{return}
  do{try exportNativeCompanion(to:url);status="Native companion exported with drafts, source snapshots and separate slots."}catch{self.error=error.localizedDescription}
 }
 func exportNativePlan() {
  guard nativeStoreProblem == nil else{error=nativeStoreProblem;return}
  let panel=NSOpenPanel();panel.canChooseFiles=false;panel.canChooseDirectories=true;panel.canCreateDirectories=true
  panel.prompt="Export host plan";panel.message="Export CNATIV.BIN and native-authoring.json to a new folder on this Mac. This is not a bootable camera package."
  guard panel.runModal() == .OK,let parent=panel.url else{return}
  let folder=parent.appendingPathComponent("Canon Native Plan "+UUID().uuidString,isDirectory:true)
  do {
   try verifyNativeLibraryUnchangedOnDisk()
   reconcileNative()
   guard nativeStoreProblem == nil else{throw ProfileError.invalid(nativeStoreProblem!)}
   let compiled=try NativeRecipeCompiler.compile(store:nativeStore,currentRecipes:library.recipes,profileCompiler:compiler,selectedSlot:nativeStartupSlot,attemptLimit:nativeAttemptLimit)
   guard !FileManager.default.fileExists(atPath:folder.path) else{throw ProfileError.invalid("Choose a new, unused native export folder.")}
   try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:false)
   try compiled.sidecar.write(to:folder.appendingPathComponent("CNATIV.BIN"),options:.withoutOverwriting)
   let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
   try encoder.encode(compiled.report).write(to:folder.appendingPathComponent("native-authoring.json"),options:.withoutOverwriting)
   status="Native host plan exported. A matching runtime package is required before camera installation."
   NSWorkspace.shared.activateFileViewerSelecting([folder])
  }catch{self.error=error.localizedDescription}
 }
 var hasNativeTemplate:Bool {
  let name = nativeSessionMode == .finiteStartup ? NativeBootPackageExporter.templateFile : NativeUserDefSessionPackageExporter.templateFile
  return FileManager.default.isReadableFile(atPath:resources.appendingPathComponent(name).path)
 }
 func exportNativeBootPackage() {
  guard hasNativeTemplate else {error="The matching native runtime template is unavailable in this build.";return}
  guard nativeStoreProblem == nil else{error=nativeStoreProblem;return}
  let panel=NSOpenPanel();panel.canChooseFiles=false;panel.canChooseDirectories=true;panel.canCreateDirectories=true
  panel.prompt="Export native package";panel.message="Create a matched native runtime package in a new folder on this Mac. This offline build requires a separately approved physical trial."
  guard panel.runModal() == .OK,let parent=panel.url else{return}
  let folder=parent.appendingPathComponent("Canon Native Package "+UUID().uuidString,isDirectory:true)
  do {
   try verifyNativeLibraryUnchangedOnDisk()
   reconcileNative()
   guard nativeStoreProblem == nil else{throw ProfileError.invalid(nativeStoreProblem!)}
   if nativeSessionMode == .finiteStartup {
    let compiled=try NativeRecipeCompiler.compile(store:nativeStore,currentRecipes:library.recipes,profileCompiler:compiler,selectedSlot:nativeStartupSlot,attemptLimit:nativeAttemptLimit)
    let template=try Data(contentsOf:resources.appendingPathComponent(NativeBootPackageExporter.templateFile))
    _ = try NativeBootPackageExporter.export(compiled:compiled,template:template,to:folder)
   }else{
    guard (1...Int(Int32.max)).contains(nativeUserDefAttemptLimit) else{throw ProfileError.invalid("User Def. session bound must be 1…2,147,483,647.")}
    let compiled=try NativeRecipeCompiler.compile(store:nativeStore,currentRecipes:library.recipes,profileCompiler:compiler,selectedSlot:nil,attemptLimit:0)
    let template=try Data(contentsOf:resources.appendingPathComponent(NativeUserDefSessionPackageExporter.templateFile))
    _ = try NativeUserDefSessionPackageExporter.export(compiled:compiled,template:template,attemptLimit:nativeUserDefAttemptLimit,to:folder)
   }
   status="Matched native package exported for offline review; no card was installed."
   NSWorkspace.shared.activateFileViewerSelecting([folder])
  }catch{self.error=error.localizedDescription}
 }
 func importNativeCompanion() {
  let panel=NSOpenPanel();panel.allowedContentTypes=[.json]
  panel.message="Choose the native companion exported alongside this recipe library. Sources must already exist with matching UUIDs and contents."
  guard panel.runModal() == .OK,let url=panel.url else{return}
  do {
   let incoming=try NativeAppCompanion.load(url)
   guard nativeStoreProblem == nil else{throw ProfileError.invalid(nativeStoreProblem!)}
   let proposed=try NativeCompanionImport.merging(incoming.store,into:nativeStore,recipes:library.recipes,compiler:compiler)
   // Import records without replacing the user's native assignments or session policy.
   nativeStore=proposed;try saveNative();status="Native companion imported; content changes invalidate earlier approvals."
  }catch{self.error=error.localizedDescription}
 }
}

struct NativeRecipeView:View {
 @ObservedObject var model:AppModel
 let recipe:Recipe
 var initialExamples:LoadedNativeCameraExamples?=nil
 var body:some View {
  ScrollView {
   VStack(alignment:.leading,spacing:18) {
    Text(recipe.name).font(.system(size:30,weight:.semibold))
    Text("Canon native interpretation").font(.headline)
    Text("Native controls apply to subsequent eligible captures. They do not change the Canon shooting-screen controls. The Effects image preview does not simulate this rendering.").font(.callout).fpSecondaryText()
    if let problem=model.nativeStoreProblem {Text(problem).foregroundStyle(.red)}
    if let record=model.currentNative {
     FPCautionCard {
      FPCautionTitle(text:model.currentNativeApproved ? "Approved interpretation" : "Draft interpretation")
      Text("Equal Ricoh and Canon slider values do not guarantee matching colour. Approval records your accepted interpretation. Imported camera examples and qualification of the current runtime remain separate.").font(.caption).fpSecondaryText().fixedSize(horizontal:false,vertical:true).padding(.bottom,10)
     }
     Form {
      Section("Source provenance") {
       Text(record.source.completeness == .legacyCurrentValuesOnly ? "Current authored values only — the original import was not preserved." : record.source.completeness == .authoredBaseline ? "Explicit authored baseline — original card provenance remains unavailable." : "The original imported source snapshot is preserved separately.").font(.callout)
       if record.source.completeness == .legacyCurrentValuesOnly {
        Text("You can deliberately use the current recipe as a new native source baseline. This does not recover the original Ricoh card or approve its interpretation.").font(.caption).fpSecondaryText()
        Button("Use current recipe values as native source",action:model.adoptCurrentNativeSource)
       }
       if let message=model.nativeSourceRecoveryMessage {Text(message).font(.caption).foregroundStyle(.orange)}
       DisclosureGroup("Preserved source inputs") {
       Text("Recipe UUID: "+recipe.id.uuidString+" · revision "+String(recipe.revision)).font(.caption).textSelection(.enabled).fpSecondaryText()
        Text("Preserved base: "+record.source.originalRecipe.base+" · WB: "+record.source.originalRecipe.whiteBalance).font(.caption).fpSecondaryText()
        ForEach(Array(record.source.normalizedImport.enumerated()),id:\.offset) {_,field in
         VStack(alignment:.leading,spacing:3) {
          Text(field.key).font(.caption.weight(.medium))
          Text(field.rawValue ?? "Unresolved input").font(.caption).textSelection(.enabled)
          if field.key.hasPrefix("ocr."),let confidence=field.confidence {Text("OCR confidence: \(Int((confidence*100).rounded()))% · provenance only").font(.caption).fpSecondaryText()}
          if field.requiresReview && !field.key.hasPrefix("ocr.") {Text("Requires source review").font(.caption).foregroundStyle(.orange)}
         }.padding(.vertical,3)
        }
       }
      }
      Section("Native Canon controls") {
       Picker("Picture Style",selection:model.nativeStyleBinding) {ForEach(NativeStyle.allCases,id:\.self){style in Text(String(describing:style).capitalized+(style == .standard ? "":" (draft)")).tag(style)}}
       Button("Use Warm1 reference settings"){model.replaceNativeTuple(.warm1)}
       Text("Standard colour is the initial editable backend. Other styles remain drafts until runtime support is qualified.").font(.caption).fpSecondaryText()
       AdjustmentRow(title:"Sharpness",value:model.nativeBinding(\.sharpness),range:0...7)
       AdjustmentRow(title:"Contrast",value:model.nativeBinding(\.contrast))
       if record.tuple.kind == .color {
        AdjustmentRow(title:"Saturation",value:model.nativeBinding(\.saturation))
        AdjustmentRow(title:"Canon colour tone",value:model.nativeBinding(\.tone))
       }else{
        Text("Monochrome authoring is a draft; this runtime exports Standard colour only.").font(.caption).fpSecondaryText()
       }
       Text("Ricoh source Hue is disclosed separately; it is not automatically Canon colour tone.").font(.caption).fpSecondaryText()
       Picker("White balance",selection:model.nativeBinding(\.whiteBalance)) {
        Text("Auto").tag(NativeWhiteBalance.auto);Text("Daylight").tag(NativeWhiteBalance.daylight)
        if record.tuple.whiteBalance != .auto && record.tuple.whiteBalance != .daylight {Text(String(describing:record.tuple.whiteBalance)+" (draft)").tag(record.tuple.whiteBalance)}
       }
       AdjustmentRow(title:"Blue ← → Amber",value:model.nativeBinding(\.amberBlue),range:-9...9)
       AdjustmentRow(title:"Magenta ← → Green",value:model.nativeBinding(\.greenMagenta),range:-9...9)
      }
      Section("Execution status") {
       LabeledContent("Native controls",value:record.tuple.isRuntimeV1Supported ? "Supported":"Draft only — unsupported style or WB")
       Text("Approval records the settings you accepted. Camera examples show a particular saved setup and do not approve later edits.").font(.caption).fpSecondaryText()
      }
      BatchGrainView(draft: model.batchGrainDraft, session: model.hostBatch)
      Section("Camera examples") {NativeCameraExamplesView(recipe:recipe,record:record,initial:initialExamples)}
      Section("Source accounting") {
       Text("Every source effect has a separate disposition. Unresolved source or provenance blocks approval; omitted and approximate effects require your explicit acknowledgement.").font(.caption).fpSecondaryText()
       ForEach(record.differences,id:\.id) {difference in
        VStack(alignment:.leading,spacing:5) {
         Text(difference.sourceField+" · "+String(describing:difference.classification).capitalized).font(.subheadline.weight(.medium))
         Text(difference.summary).font(.caption).fpSecondaryText()
         if difference.requiresAcknowledgement && difference.classification != .unresolved {
          if model.currentNativeApproved {Text("Accepted in the current native approval").font(.caption).fpSecondaryText()}else{
           Toggle("Accept this interpretation",isOn:Binding(get:{model.nativeAcknowledged.contains(difference.id)},set:{if $0{model.nativeAcknowledged.insert(difference.id)}else{model.nativeAcknowledged.remove(difference.id)}})).font(.caption)
          }
         }
        }.padding(.vertical,5)
       }
      }
      Section("Native approval") {
       Text("Approval is tied to this recipe's contents, original source snapshot, native tuple, mapping version and disclosed differences. Effects ‘Allow approximate interpretation’ does not approve native output.").font(.caption).fpSecondaryText()
       if model.currentNativeApproved {Button("Revoke native approval",action:model.revokeNativeApproval)}else{
        Button("Approve this native interpretation"){model.approveNative(model.nativeAcknowledged)}.disabled(record.differences.contains{$0.classification == .unresolved} || !Set(record.differences.filter(\.requiresAcknowledgement).map(\.id)).isSubset(of:model.nativeAcknowledged) || model.nativeStoreProblem != nil)
       }
       Button("Export native draft / companion…",action:model.exportNativeCompanion)
      }
     }.formStyle(.grouped).disabled(model.nativeStoreProblem != nil)
    }
   }.padding(24)
  }.id(recipe.id).onChange(of:model.currentNative?.tuple){_,_ in model.nativeAcknowledged=[]}.onChange(of:recipe){_,_ in model.nativeAcknowledged=[]}.onChange(of:model.currentNative?.source){_,_ in model.nativeAcknowledged=[]}
 }
}

struct NativeSlotsView:View {
 @ObservedObject var model:AppModel
 var body:some View {
  ScrollView {
   VStack(alignment:.leading,spacing:18) {
    Text(model.nativeSessionMode == .finiteStartup ? "Native startup presets" : "Captured User Def. mapping").font(.title3.weight(.semibold))
      Text(model.nativeSessionMode == .finiteStartup
        ? "These three native recipe slots are separate from Effects. Choose whether the package uses a Mac-selected startup preset or Canon's captured User Def. 1–3 style as its selector."
        : "Map each captured Canon User Def. 1–3 value to the corresponding native slot. These slots are separate from Effects recipes; empty and unsupported captures keep Canon's original processing.").font(.callout).fpSecondaryText()
    ForEach(0..<3,id:\.self) {slot in
     VStack(alignment:.leading,spacing:8) {
      Text("Native slot \(slot+1)").font(.subheadline.weight(.semibold))
      Picker("Native recipe",selection:Binding(get:{model.nativeStore.slots[slot]},set:{model.assignNative(slot,$0)})) {
       Text("Empty").tag(nil as UUID?)
       ForEach(model.library.recipes){Text($0.name).tag($0.id as UUID?)}
      }.labelsHidden()
      if let id=model.nativeStore.slots[slot],let record=model.nativeStore.records.first(where:{$0.sourceRecipeID==id}),let recipe=model.library.recipes.first(where:{$0.id==id}) {
       Text(NativeRecipeAuthoring.isApprovalCurrent(record:record,for:recipe) ? "Approved interpretation" : "Draft — executable export blocked").font(.caption).fpSecondaryText()
       if model.nativeSessionMode == .capturedUserDef,
          let cameraLabel=NativeUserDefSessionPackageExporter.assignmentLabelPreview(for:record.displayName) {
        Text("Camera assignment label: \(cameraLabel)").font(.caption).fpSecondaryText()
       }
      }
     }.padding(12).background(FP.slotCard,in:RoundedRectangle(cornerRadius:10))
    }
    Divider()
    Picker("Session mode",selection:$model.nativeSessionMode) {
     ForEach(NativeSessionMode.allCases,id:\.self){mode in Text(mode.title).tag(mode)}
    }
    if model.nativeSessionMode == .finiteStartup {
     Picker("Startup",selection:$model.nativeStartupSlot) {
      Text("OFF — original Canon capture").tag(nil as Int?)
      ForEach(0..<3,id:\.self){slot in Text("Native slot \(slot+1)").tag(slot as Int?).disabled(model.nativeStore.slots[slot] == nil)}
     }
     Stepper("Attempt cap: \(model.nativeAttemptLimit)",value:$model.nativeAttemptLimit,in:0...8).disabled(model.nativeStartupSlot == nil)
     Text(model.nativeAttemptLimit == 0 || model.nativeStartupSlot == nil ? "Export startup: OFF" : "Export startup: native slot \(model.nativeStartupSlot!+1)").font(.caption.weight(.medium))
     Text("Default OFF, cap 0. A nonzero cap permits that many finite eligible attempts, up to 8; it does not enable continuous native processing or rearm an exhausted session. A fresh boot reloads the exported budget.").font(.caption).fpSecondaryText()
    }else{
     Text("Rendering base: Standard. The captured Canon User Def. 1, 2 or 3 setting selects native slot 1, 2 or 3 for that shot. This selector does not change the rendering base or camera definitions. Built-in styles and unsupported User Def. values keep Canon's original processing.").font(.caption).fpSecondaryText()
     Text("If Canon starts with a mapped User Def. selected, its preset can apply to the first eligible photo. An unsupported shot uses Canon processing; an integrity fault disables preset writes for the rest of that boot. A new boot reloads the package allowance; no camera User Def. definitions or global Canon settings are written.").font(.caption).fpSecondaryText()
     Text("Where shown, recipe labels identify assignments; Canon's slot icons identify User Def. 1, 2 and 3. Labels show up to the first 10 ASCII bytes, adding ~ when shortened; full names remain in the exported bank. A label does not confirm that a capture used the recipe. If labels are unavailable, Canon's original labels remain.").font(.caption).fpSecondaryText()
     Text("Only Single drive captures are eligible. Other drive modes keep Canon's original processing. After returning to Single, a capture can be eligible again while allowance remains and all other checks pass.").font(.caption).fpSecondaryText()
     ForEach(0..<3,id:\.self){slot in
      let id=model.nativeStore.slots[slot]
      let record=id.flatMap{key in model.nativeStore.records.first{$0.sourceRecipeID==key}}
      let recipe=id.flatMap{key in model.library.recipes.first{$0.id==key}}
      let ready=record != nil && recipe != nil && record!.tuple.isRuntimeV1Supported && NativeRecipeAuthoring.isApprovalCurrent(record:record!,for:recipe!)
      Text("User Def. \(slot+1) → native slot \(slot+1): \(id == nil ? "unassigned · Canon original fallback" : ready ? "approved" : "assigned but not exportable")").font(.caption).fpSecondaryText()
     }
    }
    if model.hasNativeTemplate {
     Button("Export native boot package…",action:model.exportNativeBootPackage).buttonStyle(FPPrimaryButtonStyle())
     Text("This native package interface is experimental and requires separate camera qualification.").font(.caption).fpSecondaryText()
    } else {
     Text("This build can export the native host plan. Boot package export requires the matching native runtime template.").font(.caption).fpSecondaryText()
    }
    Button("Export native host plan…",action:model.exportNativePlan)
    Text("Host files only: CNATIV.BIN + native-authoring.json. They are not bootable without a matching runtime package. Export does not install or write to a camera card.").font(.caption).fpSecondaryText()
    Text("Native capture uses Canon's RAW + full-size JPEG route. No exact native preview is available on this Mac.").font(.caption).fpSecondaryText()
    Text(model.nativeSessionMode == .finiteStartup ? "For the finite startup pilot, set camera manually: Standard Picture Style · Single drive · RAW + Large/Fine JPEG · sRGB · HTP off · WB bracketing off · mirror lockup off." : "For captured User Def. selection, choose User Def. 1–3 for the corresponding native slot, or a built-in Picture Style for original Canon processing. Keep Single drive · RAW + Large/Fine JPEG · sRGB · HTP off · WB bracketing off · mirror lockup off. Each selected User Def. must already have the direct Standard base.").font(.caption).fpSecondaryText()
   }.padding(22)
  }.background(FP.inspectorBackground).disabled(model.nativeStoreProblem != nil)
   .onChange(of:model.nativeStartupSlot){_,newValue in if newValue == nil {model.nativeAttemptLimit=0};do{try model.saveNative()}catch{model.error=error.localizedDescription}}
   .onChange(of:model.nativeAttemptLimit){_,_ in do{try model.saveNative()}catch{model.error=error.localizedDescription}}
   .onChange(of:model.nativeSessionMode){_,_ in do{try model.saveNative()}catch{model.error=error.localizedDescription}}
   .onChange(of:model.nativeUserDefAttemptLimit){_,_ in do{try model.saveNative()}catch{model.error=error.localizedDescription}}
 }
}
