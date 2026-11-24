import AppKit
import SwiftUI
import UniformTypeIdentifiers
import ProfileCore
import RecipeCardImport
enum AppWorkflow:String {case effects,native,cameraStyles}

// Effects assignments live in the shared recipe library. Native drafts and Camera Styles
// assignments have separate stores keyed by the recipe UUIDs.
@MainActor final class AppModel:ObservableObject {
 let hostBatch = HostBatchSession()
 let batchGrainDraft = BatchGrainDraft()
 @Published var workflow:AppWorkflow = .effects
 @Published var nativeAcknowledged=Set<String>()
 @Published var nativeStore=NativeRecipeStore()
 @Published var nativeStartupSlot:Int?=nil
 @Published var nativeAttemptLimit=0
 @Published var nativeSessionMode:NativeSessionMode = .finiteStartup
 @Published var nativeUserDefAttemptLimit=Int(Int32.max)
 @Published var nativeStoreProblem:String?
 let nativeStoreURL:URL
 @Published var cameraStyleSlots:[UUID?]=[nil,nil,nil]
 @Published var cameraStylesSettingsProblem:String?
 @Published var calibrationModelProblem:String?
 @Published var calibrationModel:CalibrationModel?
 @Published var calibrationModelPath:String?
 @Published var useInterimRules=false
 @Published var exportingCameraStyles=false
 @Published var cameraStylesIncludePF2=false
 @Published var cameraStylesWBBlock=true
 let cameraStylesURL:URL
 @Published var library:RecipeLibrary
 @Published var selected:UUID? {didSet{nativeAcknowledged=[]}}
 @Published var cards:[CameraCardDevice]=[]
 @Published var selectedCard:String?
 @Published var status="Changes save automatically."
 @Published var error:String?
 @Published var uploading=false
 @Published var showFactory=false
 @Published var importingCard=false
 @Published var exportingLUTs=false
 @Published var cardImportNotices:[String]=[]
 @Published var importedCardID:UUID?
 let resources:URL
 let libraryURL:URL
 let compiler:ProfileCompiler
 var lastSavedLibraryDigest=""
 private var pendingSave:DispatchWorkItem?
 private var libraryNeedsSave = false
 init(preview:Bool=false,storageURL:URL?=nil)throws {
  let bundle=Bundle.main.resourceURL!
  let override=ProcessInfo.processInfo.environment["CANON_PROFILE_RESOURCES"]
  resources=override.map{URL(fileURLWithPath:$0)} ?? bundle
  compiler=try ProfileCompiler(factoryBook:Data(contentsOf:resources.appendingPathComponent("CFLOOKS.BIN")))
  let base=storageURL ?? (preview ? URL(fileURLWithPath:"/private/tmp/canon-consolidated-preview"):FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("CanonFilmProfiles"))
  try FileManager.default.createDirectory(at:base,withIntermediateDirectories:true)
  libraryURL=base.appendingPathComponent("Recipes.json")
  nativeStoreURL=base.appendingPathComponent("NativeAuthoring.json")
  cameraStylesURL=base.appendingPathComponent("CameraStyles.json")
  library=FileManager.default.fileExists(atPath:libraryURL.path) ? try RecipeLibrary.load(from:libraryURL):RecipeLibrary()
  lastSavedLibraryDigest=NativeCanonical.digest(library)
  selected=library.recipes.first?.id
  if FileManager.default.fileExists(atPath:nativeStoreURL.path) {
   do {
    let companion=try NativeAppCompanion.load(nativeStoreURL)
    nativeStore=companion.store;nativeStartupSlot=companion.startupSlot;nativeAttemptLimit=companion.attemptLimit
    nativeSessionMode=companion.sessionMode;nativeUserDefAttemptLimit=companion.userDefAttemptLimit
   }catch{nativeStoreProblem="Native companion could not be read; it has been retained: "+error.localizedDescription}
  }
  if nativeStoreProblem == nil {reconcileNative()}
  loadCameraStyles()
  if !preview && hasEffectsRuntime {scan()}
 }
 var current:Recipe? {library.recipes.first{$0.id==selected}}
 func binding<T>(_ key:WritableKeyPath<Recipe,T>)->Binding<T> {
  Binding(get:{self.current![keyPath:key]},set:{new in guard let i=self.library.recipes.firstIndex(where:{$0.id==self.selected}) else{return};var r=self.library.recipes[i];r[keyPath:key]=new;if r.revision<UInt32.max {r.revision+=1};self.library.recipes[i]=r;self.nativeAcknowledged=[];self.reconcileNative();self.saveSoon()})
 }
 func saveSoon() {
  libraryNeedsSave = true
  pendingSave?.cancel()
  let job = DispatchWorkItem { [weak self] in self?.save() }
  pendingSave = job
  DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: job)
 }

 @discardableResult
 func save() -> Bool {
  do {
   try writeLibrary()
   return true
  } catch {
   status = "Draft kept in memory: " + error.localizedDescription
   return false
  }
 }

 func flushLibraryOnQuit() throws {
  if libraryNeedsSave { try writeLibrary() }
 }

 private func writeLibrary() throws {
  pendingSave?.cancel()
  pendingSave = nil
  libraryNeedsSave = true
  try library.save(to: libraryURL)
  lastSavedLibraryDigest = NativeCanonical.digest(library)
  try saveNative()
  libraryNeedsSave = false
  status = "Saved on this Mac."
 }
 func newRecipe(){let r=Recipe();library.recipes.append(r);selected=r.id;reconcileNative();saveSoon()}
 func duplicate(){guard var r=current else{return};let originalID=r.id;r.id=UUID();r.revision=1;r.name=String((r.name+" copy").prefix(23));library.recipes.append(r);selected=r.id;duplicateNative(from:originalID,to:r);reconcileNative();saveSoon()}
 func factory(_ id:Int){var r=Recipe();r.factoryID=id;r.name=String((Recipe.factoryNames[id] ?? "Factory copy").prefix(23));r.shortName=String(r.name.prefix(14));r.creator="Factory look, editable copy";library.recipes.append(r);selected=r.id;showFactory=false;reconcileNative();saveSoon()}
 func remove(){guard let id=selected else{return};library.recipes.removeAll{$0.id==id};library.slots=library.slots.map{$0==id ? nil:$0};if cameraStyleSlots.contains(id) {cameraStyleSlots=cameraStyleSlots.map{$0==id ? nil:$0};saveCameraStyles()};selected=library.recipes.first?.id;reconcileNative();saveSoon()}
 func assign(_ slot:Int,_ id:UUID?){library.slots[slot]=id;saveSoon()}
 func importRecipes(){
  let panel=NSOpenPanel();panel.allowedContentTypes=[.json]
  guard panel.runModal() == .OK,let url=panel.url else{return}
  do {try addImportedLibrary(RecipeLibrary.load(from:url),companionURL:url.deletingPathExtension().appendingPathExtension("native-authoring.json"))}catch{self.error=error.localizedDescription}
 }
 func addImportedLibrary(_ incoming:RecipeLibrary,companionURL:URL?=nil)throws {
  let incomingCompanion:NativeAppCompanion?
  if let url=companionURL,FileManager.default.fileExists(atPath:url.path) {incomingCompanion=try NativeAppCompanion.load(url)}else{incomingCompanion=nil}
  guard nativeStoreProblem == nil || incomingCompanion == nil else{throw ProfileError.invalid(nativeStoreProblem!)}
  var proposed=library;var proposedNative=nativeStore;var last:UUID?
  for var recipe in incoming.recipes {
   let originalID=recipe.id
   let duplicate=proposed.recipes.contains{$0.id==originalID}
   if duplicate {recipe.id=UUID();recipe.revision=1}
   proposed.recipes.append(recipe);last=recipe.id
   if var record=incomingCompanion?.store.records.first(where:{$0.sourceRecipeID==originalID}) {
    if duplicate {record=try NativeRecipeAuthoring.duplicate(record:record,for:recipe,compiler:compiler)}
    else{record=try NativeRecipeAuthoring.refresh(record:record,for:recipe,compiler:compiler)}
    record.displayName=recipe.name;record.shortName=recipe.shortName
    proposedNative.records.append(record)
   }
  }
  try proposed.validate()
  library=proposed;nativeStore=proposedNative
  if let last {selected=last}
  // Existing Effects/native slot assignments are preserved. Imported duplicates are drafts.
  reconcileNative();saveSoon()
  status=incomingCompanion == nil ? "Recipe library imported; native provenance is unavailable for these entries.":"Recipe library and native source companion imported. Existing slots are unchanged."
 }

 func importRecipeCard(){
  guard !importingCard else{return}
  let panel=NSOpenPanel();panel.allowedContentTypes=[.jpeg,.png,.heic,.tiff]
  panel.allowsMultipleSelection=false;panel.canChooseDirectories=false
  panel.message="Choose a downloaded Ricoh Cookbook recipe card."
  guard panel.runModal() == .OK,let url=panel.url else{return}
  importingCard=true;status="Reading recipe card…"
  Task {
   defer{importingCard=false}
   do {
    let result=try await Task.detached(priority:.userInitiated){try RecipeCardImporter.read(url)}.value
    try addImportedCard(result)
   }catch{self.error=error.localizedDescription;status="Card import stopped; your library is unchanged."}
  }
 }
 func addImportedCard(_ result:RecipeCardImportResult)throws {
  var proposed=library
  var recipe=result.recipe;recipe.id=UUID();recipe.revision=1
  proposed.recipes.append(recipe);try proposed.validate()
  let record:NativeRecipeRecord?
  if nativeStoreProblem == nil {
   // Raw OCR is provenance. The strict importer rejects ambiguous critical fields;
   // retained semantic sourceSettings.needsReview values gate native approval.
   var fields=result.recognizedText.enumerated().map { index,block in
    NativeSourceField(key:"ocr.\(index)",rawValue:block.text,confidence:Double(block.confidence))
   }
   fields += [NativeSourceField(key:"source.base",rawValue:recipe.base),NativeSourceField(key:"source.whiteBalance",rawValue:recipe.whiteBalance)]
   for (key,value) in [("saturation",recipe.saturation),("hue",recipe.hue),("key",recipe.key),("contrast",recipe.contrast),("highlights",recipe.highlights),("shadows",recipe.shadows),("sharpness",recipe.sharpness),("shading",recipe.shading),("clarity",recipe.clarity),("amberBlue",recipe.amberBlue),("greenMagenta",recipe.greenMagenta)] {fields.append(NativeSourceField(key:"source."+key,rawValue:String(value)))}
   fields += (recipe.sourceSettings ?? []).map{NativeSourceField(key:"card."+$0.key,rawValue:$0.value,requiresReview:$0.needsReview)}
   record=try NativeRecipeAuthoring.draft(from:recipe,normalizedImport:fields,compiler:compiler)
  }else{record=nil}
  try proposed.save(to:libraryURL);lastSavedLibraryDigest=NativeCanonical.digest(proposed)
  pendingSave?.cancel();pendingSave=nil;libraryNeedsSave=false
  library=proposed;selected=recipe.id;importedCardID=recipe.id;cardImportNotices=result.notices
  if let record {
   nativeStore.records.removeAll{$0.sourceRecipeID==recipe.id};nativeStore.records.append(record)
   do{try saveNative()}catch{nativeStoreProblem="Imported source is retained in memory; native companion could not be saved: "+error.localizedDescription;self.error=nativeStoreProblem}
  }
  status="Imported \(recipe.name). Review the settings against the card."
 }

 func exportRecipes(){let p=NSSavePanel();p.allowedContentTypes=[.json];p.nameFieldStringValue="Film Recipes.json";guard p.runModal() == .OK,let url=p.url else{return};do {try library.save(to:url);try exportNativeCompanion(to:url.deletingPathExtension().appendingPathExtension("native-authoring.json"));status="Recipe library and separate native companion exported."}catch{self.error=error.localizedDescription}}
 func exportLUTs(all:Bool,nativePresets:Bool=false){
  guard !exportingLUTs else{return}
  let recipes=all ? library.recipes:current.map{[$0]} ?? []
  guard !recipes.isEmpty else{return}
  let url:URL
  if all || nativePresets {
   let panel=NSOpenPanel();panel.canChooseFiles=false;panel.canChooseDirectories=true;panel.canCreateDirectories=true
   panel.prompt=nativePresets ? "Export presets":"Export LUTs";panel.message=nativePresets ? "Choose a folder for the Nitro presets and their companion LUTs. Colour and tone are included; grain, sharpness, clarity and shading are omitted.":"Choose a folder for the Nitro LUT collection. Colour and tone are included; grain, sharpness, clarity and shading are omitted."
   guard panel.runModal() == .OK,let parent=panel.url else{return}
   let date=DateFormatter();date.locale=Locale(identifier:"en_US_POSIX");date.dateFormat="yyyy-MM-dd HH.mm.ss"
   url=parent.appendingPathComponent("Canon Film Profiles Nitro "+(nativePresets ? "Presets ":"LUTs ")+date.string(from:Date()),isDirectory:true)
  }else{
   let panel=NSSavePanel();panel.allowedContentTypes=[UTType(filenameExtension:"cube") ?? .data]
   panel.nameFieldStringValue=recipes[0].name.replacingOccurrences(of:"/",with:"-")+".cube"
   panel.message="Export colour and tone for Nitro. Grain, sharpness, clarity and shading are omitted."
   guard panel.runModal() == .OK,let selected=panel.url else{return};url=selected
  }
  let compiler=self.compiler
  exportingLUTs=true;status=nativePresets ? "Exporting Nitro presets…":"Exporting Nitro LUTs…"
  Task {
   defer{exportingLUTs=false}
   do {
    try await Task.detached(priority:.userInitiated){
     if nativePresets {_ = try NitroPresetExporter.export(recipes,compiler:compiler,to:url)}
     else if all {_ = try CubeLUTExporter.export(recipes,compiler:compiler,to:url)}
     else {try CubeLUTExporter.cube(for:recipes[0],compiler:compiler).write(to:url,options:.atomic)}
    }.value
    status="Exported \(recipes.count) Nitro \(nativePresets ? "preset":"LUT")\(recipes.count==1 ? "":"s") — colour and tone only."
    NSWorkspace.shared.activateFileViewerSelecting([url])
   }catch{self.error=error.localizedDescription;status="LUT export stopped: "+error.localizedDescription}
  }
 }
 var hasEffectsRuntime:Bool {LocalCameraResources.hasEffects(in:Bundle.main.resourceURL)}
 func exportPack(){let p=NSSavePanel();p.nameFieldStringValue="CUPROF.BIN";guard p.runModal() == .OK,let url=p.url else{return};do {try compiler.pack(library).write(to:url,options:.atomic);status="Effects pack exported. Use it with a matching Effects runtime."}catch{self.error=error.localizedDescription}}
 func scan(){
  guard hasEffectsRuntime else{return}
  Task {do {let found=try await Task.detached{try DiskUtility.devices()}.value;self.cards=found;if !found.contains(where:{$0.id==self.selectedCard}){self.selectedCard=found.first?.id};if found.isEmpty {self.status="Insert the camera’s configured FAT16 Effects card to upload."}}catch{self.error=error.localizedDescription}}
 }
 func upload(prepareWorking:Bool=false){
  guard hasEffectsRuntime else{error="The matching Effects runtime is unavailable in this build.";return}
  guard !uploading,let card=cards.first(where:{$0.id==selectedCard}) else{return}
  do {
   let pack=try compiler.pack(prepareWorking ? RecipeLibrary(recipes:[],slots:[nil,nil,nil]):library)
   var request=UploadRequest(device:card,profiles:pack);request.prepareWorkingInstallation=prepareWorking
   let folder=libraryURL.deletingLastPathComponent().appendingPathComponent("Uploads").appendingPathComponent(UUID().uuidString)
   try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
   try library.save(to:folder.appendingPathComponent("Recipes.json"));let path=folder.appendingPathComponent("Request.json");try JSONEncoder().encode(request).write(to:path,options:.atomic)
   uploading=true;status="Uploading profiles and checking readback…"
   let executable=Bundle.main.executableURL!
   Task {
    defer {uploading=false}
    do {
     let result=try await Task.detached{try PrivilegedUpload.run(executable:executable,request:path)}.value
     let receipt=try JSONDecoder().decode(UploadReceipt.self,from:result)
     var messages=[receipt.message]
     if receipt.verified && prepareWorking && (receipt.phase == .eject || receipt.status == "PASS") {
      library.slots=[nil,nil,nil]
      if !save() {messages.append(status)}
     }
     if receipt.ejected {cards.removeAll{$0.id==card.id};selectedCard=nil}
     do {try result.write(to:folder.appendingPathComponent("Receipt.json"),options:.atomic)}
     catch {messages.append("The Mac could not save the receipt: "+error.localizedDescription)}
     status=messages.joined(separator:" ")
     if receipt.status != "PASS" || messages.count>1 {self.error=status}
    }catch{self.error=error.localizedDescription;status="Upload stopped. The request and any receipt are retained."}
   }
  }catch{self.error=error.localizedDescription}
 }
}
enum PrivilegedUpload {
 static func shellQuote(_ s:String)->String {"'"+s.replacingOccurrences(of:"'",with:"'\\''")+"'"}
 static func appleQuote(_ s:String)->String {"\""+s.replacingOccurrences(of:"\\",with:"\\\\").replacingOccurrences(of:"\"",with:"\\\"")+"\""}
 static func run(executable:URL,request:URL)throws->Data {
  let sudo=URL(fileURLWithPath:"/usr/bin/sudo")
  let auth=try ProcessOutput.capture(executable:sudo,arguments:["-n","-v"])
  if auth.status==0 {
   let result=try ProcessOutput.capture(executable:sudo,arguments:["-n",executable.path,"--helper",request.path])
   guard result.status==0 else {throw ProfileError.invalid(String(decoding:result.stderr,as:UTF8.self))}
   return result.stdout
  }
  let command=shellQuote(executable.path)+" --helper "+shellQuote(request.path)
  let script=NSAppleScript(source:"do shell script "+appleQuote(command)+" with administrator privileges")!
  var error:NSDictionary?;let result=script.executeAndReturnError(&error)
  guard error==nil else {throw ProfileError.invalid(error?[NSAppleScript.errorMessage] as? String ?? "Authentication cancelled.")}
  guard let text=result.stringValue,let data=text.data(using:.utf8) else {throw ProfileError.invalid("No upload receipt was returned.")};return data
 }
}
