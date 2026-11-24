import Foundation
import AppKit
import SwiftUI
import ProfileCore
import RecipeCardImport
@MainActor struct FilmProfilesApp:App {
 @StateObject private var model:AppModel
 @NSApplicationDelegateAdaptor(HostBatchQuitGuard.self) private var hostBatchQuitGuard
 init(){do {let initial=try AppModel();_model=StateObject(wrappedValue:initial)}catch{let alert=NSAlert();alert.messageText="Unable to open your recipe library";alert.informativeText=error.localizedDescription+" Your library has not been changed.";alert.runModal();exit(1)}}
 var body:some Scene {WindowGroup("Canon Film Profiles"){
  MainView(model:model).onAppear{hostBatchQuitGuard.model=model}
 }.defaultSize(width:1120,height:820).commands{CommandGroup(replacing:.newItem){Button("New recipe"){model.newRecipe()}.keyboardShortcut("n");Button("Save library"){model.save()}.keyboardShortcut("s")}}}
}
@MainActor
private final class HostBatchQuitGuard: NSObject, NSApplicationDelegate {
 weak var model: AppModel?

 func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
  if model?.hostBatch.canQuit == false {
   let alert = NSAlert()
   alert.messageText = "A host batch is running"
   alert.informativeText = "Wait for the batch to finish or request cancellation from Host batch status, then quit."
   alert.addButton(withTitle: "Keep app open")
   alert.runModal()
   return .terminateCancel
  }
  do {
   try model?.flushLibraryOnQuit()
   return .terminateNow
  } catch {
   let alert = NSAlert()
   alert.messageText = "Unable to save library changes"
   alert.informativeText = error.localizedDescription
   alert.addButton(withTitle: "Keep app open")
   alert.addButton(withTitle: "Quit with unsaved changes")
   return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
  }
 }
}
@main enum Launcher {
 @MainActor static func main(){
  let args=CommandLine.arguments
  // Isolated Canon converter: loads the installed EdsCFParse in this child process only (CanonStyleCompiler).
  if args.count>=2 && args[1]==CanonStyleCompiler.helperFlag {exit(CanonStyleCompiler.runHelper(arguments:Array(args.dropFirst(2))))}
  if args.count==4 && ["--export-nitro-luts","--export-nitro-presets"].contains(args[1]) {
   do {
    let resources=ProcessInfo.processInfo.environment["CANON_PROFILE_RESOURCES"].map{URL(fileURLWithPath:$0)} ?? Bundle.main.resourceURL!
    let compiler=try ProfileCompiler(factoryBook:Data(contentsOf:resources.appendingPathComponent("CFLOOKS.BIN")))
    let library=try RecipeLibrary.load(from:URL(fileURLWithPath:args[2]))
    let destination=URL(fileURLWithPath:args[3],isDirectory:true)
    if args[1]=="--export-nitro-presets" {
     let entries=try NitroPresetExporter.export(library.recipes,compiler:compiler,to:destination)
     print("Exported \(entries.count) native Nitro presets with companion LUTs to \(args[3]).")
    }else{
     let entries=try CubeLUTExporter.export(library.recipes,compiler:compiler,to:destination)
     print("Exported \(entries.count) Nitro LUTs (33 × 33 × 33, sRGB, colour and tone only) to \(args[3]).")
    }
   }catch{fputs(error.localizedDescription+"\n",stderr);exit(1)};return
  }
  if args.count==5 && args[1]=="--consolidate-library" {
   do {let library=try LibraryConsolidation.consolidate(mainURL:URL(fileURLWithPath:args[2]),trialURL:URL(fileURLWithPath:args[3]),backupURL:URL(fileURLWithPath:args[4]));print("PASS preserved main recipes and slots; consolidated \(library.recipes.count) recipes.")}
   catch{fputs(error.localizedDescription+"\n",stderr);exit(1)};return
  }
  if args.count==3 && args[1]=="--read-recipe-card" {
   do {let result=try RecipeCardImporter.read(URL(fileURLWithPath:args[2]));let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys];print(String(decoding:try encoder.encode(result),as:UTF8.self))}
   catch{fputs(error.localizedDescription+"\n",stderr);exit(1)};return
  }
  if args.count==3 && args[1]=="--card-info" {do {let info=try DiskUtility.info(args[2]);print(String(decoding:try JSONSerialization.data(withJSONObject:info,options:[.sortedKeys]),as:UTF8.self))}catch{fputs(error.localizedDescription+"\n",stderr)};return}
  if args.count>=2 && ["--helper","--preflight-upload"].contains(args[1]) {
   exit(uploadCommand(arguments:args))
  }
  if args.count==3 && args[1]=="--render-preview" {
   do {let app=NSApplication.shared;app.setActivationPolicy(.accessory)
    let appearance=ProcessInfo.processInfo.environment["CANON_PROFILE_PREVIEW_APPEARANCE"] ?? "light"
    app.appearance=NSAppearance(named:appearance=="dark" ? .darkAqua:appearance=="contrast" ? .accessibilityHighContrastAqua:.aqua)
    let previewStorage=ProcessInfo.processInfo.environment["CANON_PROFILE_PREVIEW_STORAGE"].map{URL(fileURLWithPath:$0,isDirectory:true)}
    let model=try AppModel(preview:true,storageURL:previewStorage)
    if let path=ProcessInfo.processInfo.environment["CANON_PROFILE_PREVIEW_LIBRARY"] {
     model.library=try RecipeLibrary.load(from:URL(fileURLWithPath:path));model.selected=model.library.recipes.first?.id
     if let name=ProcessInfo.processInfo.environment["CANON_PROFILE_PREVIEW_SELECTION"] {model.selected=model.library.recipes.first{$0.name==name}?.id ?? model.selected}
    }
    if ProcessInfo.processInfo.environment["CANON_PROFILE_BRAND_FIXTURE"]=="1" {
     var factory=Recipe();factory.factoryID=1002;factory.name="Mac Kodachrome";factory.shortName="Mac Chrome"
     var portra=Recipe.portra160;portra.allowPartial=true
     var bennet=Recipe();bennet.name="Bennet 800";bennet.shortName="Bennet 800";bennet.clarity = -1;bennet.allowPartial=true;bennet.amberBlue=14;bennet.greenMagenta=2
     model.library=RecipeLibrary(recipes:[factory,portra,bennet],slots:[factory.id,bennet.id,portra.id]);model.selected=bennet.id;model.status="Saved on this Mac."
     if ProcessInfo.processInfo.environment["CANON_PROFILE_MULTI_SLOT_FIXTURE"]=="1" {model.library.slots=[bennet.id,bennet.id,bennet.id]}
    }
    if let path=ProcessInfo.processInfo.environment["CANON_PROFILE_PREVIEW_RECIPE_CARD"] {
     try model.addImportedCard(RecipeCardImporter.read(URL(fileURLWithPath:path)))
    }
    if ProcessInfo.processInfo.environment["CANON_PROFILE_CARD_FIXTURE"]=="1" {
     let card=CameraCardDevice(id:"preview",label:"SDDR-409",bytes:2_030_000_000,partition:"preview",volumeUUID:"preview",deviceTree:"preview")
     model.cards=[card];model.selectedCard=card.id
    }
    if ProcessInfo.processInfo.environment["CANON_PROFILE_PREVIEW_NATIVE"]=="1" {model.workflow = .native;model.reconcileNative()}
    if ProcessInfo.processInfo.environment["CANON_PROFILE_PREVIEW_CAMERA_STYLES"]=="1" {model.workflow = .cameraStyles;let ids=model.library.recipes.filter{$0.factoryID == nil}.prefix(3).map{$0.id as UUID?};model.cameraStyleSlots=Array(ids)+Array(repeating:nil,count:3-ids.count)}
    let cameraExamples=try ProcessInfo.processInfo.environment["CANON_PROFILE_PREVIEW_CAMERA_EXAMPLES"].map{try NativeCameraExampleLoader.load(URL(fileURLWithPath:$0))}
    let active=ProcessInfo.processInfo.environment["CANON_PROFILE_PREVIEW_ACTIVE"]=="1"
    let view=NSHostingView(rootView:MainView(model:model,cameraExamples:cameraExamples).environment(\.controlActiveState,active ? .active:.inactive).allowsHitTesting(false));view.frame=NSRect(x:0,y:0,width:1120,height:900);let window=NSWindow(contentRect:view.frame,styleMask:[.titled],backing:.buffered,defer:false);window.contentView=view
    view.layoutSubtreeIfNeeded();RunLoop.main.run(until:Date().addingTimeInterval(1))
    func scrollViews(_ root:NSView)->[NSScrollView] { (root as? NSScrollView).map{[$0]} ?? root.subviews.flatMap{scrollViews($0)} }
    if let amount=ProcessInfo.processInfo.environment["CANON_PROFILE_PREVIEW_SCROLL"].flatMap(Double.init) {
     for scroll in scrollViews(view) where (scroll.documentView?.bounds.height ?? 0)>scroll.contentView.bounds.height {
      guard let document=scroll.documentView else{continue}
      let y=min(max(0,amount),max(0,document.bounds.height-scroll.contentView.bounds.height))
      scroll.contentView.scroll(to:NSPoint(x:0,y:document.isFlipped ? y:document.bounds.height-scroll.contentView.bounds.height-y));scroll.reflectScrolledClipView(scroll.contentView)
     }
     RunLoop.main.run(until:Date().addingTimeInterval(0.3))
    }
    guard let bitmap=view.bitmapImageRepForCachingDisplay(in:view.bounds) else{throw ProfileError.invalid("Preview render failed.")};view.cacheDisplay(in:view.bounds,to:bitmap);try bitmap.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:args[2]));print("PASS native editor preview") }catch{fputs(error.localizedDescription+"\n",stderr)};return
  }
  FilmProfilesApp.main()
 }

 private static func uploadCommand(arguments:[String])->Int32 {
  let preflight=arguments[1]=="--preflight-upload"
  do {
   guard arguments.count==3 else {throw ProfileError.invalid("Supply exactly one upload request file.")}
   let url=URL(fileURLWithPath:arguments[2])
   let handle=try FileHandle(forReadingFrom:url)
   defer {try? handle.close()}
   guard let data=try handle.read(upToCount:16385),data.count<=16384 else {throw ProfileError.invalid("Invalid upload request.")}
   let request=try JSONDecoder().decode(UploadRequest.self,from:data)
   let (support,firmware)=try LocalCameraResources.loadEffects(in:Bundle.main.resourceURL)
   if preflight {
    let report=try CardDeployment.preview(request,support:support,firmware:firmware)
    print(String(decoding:try JSONSerialization.data(withJSONObject:report,options:[.sortedKeys]),as:UTF8.self))
   } else {
    let backup=url.deletingLastPathComponent().appendingPathComponent("CardBackup")
    let receipt=try CardDeployment.perform(request,support:support,firmware:firmware,backupDirectory:backup)
    print(String(decoding:try JSONEncoder().encode(receipt),as:UTF8.self))
   }
   return 0
  } catch {
   let receipt=(error as? UploadFailure)?.receipt ?? UploadReceipt(status:"FAIL",device:"",profileSHA256:"",
      firmwareSHA256:"",firmwareInstalled:false,writeCount:0,verified:false,ejected:false,
      message:error.localizedDescription,phase:.preflight)
   do {
    print(String(decoding:try JSONEncoder().encode(receipt),as:UTF8.self))
   } catch {
    fputs(error.localizedDescription+"\n",stderr)
    return 1
   }
   // The GUI's privileged call expects JSON even when an upload fails. A
   // read-only preflight is also used by shell callers that check exit status.
   return preflight ? 1 : 0
  }
 }
}
