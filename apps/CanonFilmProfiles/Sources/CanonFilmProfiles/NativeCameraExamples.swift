import AppKit
import SwiftUI
import ImageIO
import UniformTypeIdentifiers
import ProfileCore

/// Descriptive archive metadata, kept outside recipe, approval and package models.
struct NativeCameraExampleCapture:Codable,Equatable,Sendable {
 let file:String
 let sha256:String
 let tuple:NativeCanonTuple
 let pictureStyleRaw:Int
 let whiteBalanceRaw:Int
 let capturedLocal:String
 let exposureMode:String
 let iso:Int
 let fNumber:Double
 let shutter:String
 var exposureDescription:String {"\(exposureMode) · ISO \(iso) · f/\(fNumber.formatted(.number.precision(.fractionLength(0...1)))) · \(shutter) s"}
 var tupleDescription:String {
  func signed(_ n:Int)->String {n>0 ? "+\(n)":"\(n)"}
  let wb=String(describing:tuple.whiteBalance).capitalized
  return "\(String(describing:tuple.style).capitalized) · sharp \(tuple.sharpness) · contrast \(signed(tuple.contrast)) · sat \(signed(tuple.saturation)) · tone \(signed(tuple.tone)) · \(wb) WB · A/B \(signed(tuple.amberBlue)) · G/M \(signed(tuple.greenMagenta))"
 }
}
struct NativeCameraExampleManifest:Codable,Equatable,Sendable {
 let schema:Int
 let kind:String
 let title:String
 let recipeID:UUID
 let recipeContentSHA256:String
 let sourceDigest:String
 let mappingVersion:String
 let approvalDigest:String?
 let trialID:String
 let payloadSHA256:String
 let target:NativeCameraExampleCapture
 let neutral:NativeCameraExampleCapture
 enum Match:Equatable {case capturedSettings,earlierSettings,differentRecipe}
 func match(recipe:Recipe,record:NativeRecipeRecord?)->Match {
  guard recipe.id==recipeID else{return .differentRecipe}
  guard let record,record.sourceRecipeID==recipeID,
   NativeCanonical.digest(recipe)==recipeContentSHA256.lowercased(),
   record.source.sourceDigest==sourceDigest.lowercased(),record.mappingVersion==mappingVersion,
   record.tuple==target.tuple else{return .earlierSettings}
  if let approvalDigest {
   guard record.approval?.approvalDigest==approvalDigest.lowercased(),NativeRecipeAuthoring.isApprovalCurrent(record:record,for:recipe) else{return .earlierSettings}
  }
  return .capturedSettings
 }
 func validate()throws {
  func text(_ value:String,_ limit:Int)->Bool {!value.isEmpty && value.utf8.count<=limit && !value.unicodeScalars.contains{CharacterSet.controlCharacters.contains($0)}}
  func digest(_ value:String)->Bool {value.utf8.count==64 && value.utf8.allSatisfy{(48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)}}
  guard schema==1,kind=="canon-native-camera-example-pair",text(title,160),text(trialID,160),text(mappingVersion,48),
   digest(recipeContentSHA256),digest(sourceDigest),digest(payloadSHA256),approvalDigest.map(digest) ?? true,
   target.file.caseInsensitiveCompare(neutral.file) != .orderedSame,target.sha256.lowercased() != neutral.sha256.lowercased() else{throw ProfileError.invalid("Unsupported or invalid camera example manifest.")}
  for capture in [target,neutral] {
   let name=capture.file
   guard text(name,128),!name.contains("/"),!name.contains("\\"),name != ".",name != "..",
    ["jpg","jpeg"].contains((name as NSString).pathExtension.lowercased()),digest(capture.sha256),
    (0...255).contains(capture.pictureStyleRaw),(0...255).contains(capture.whiteBalanceRaw),
    text(capture.capturedLocal,64),text(capture.exposureMode,16),text(capture.shutter,32),
    (1...10_240_000).contains(capture.iso),capture.fNumber.isFinite,(0.7...128).contains(capture.fNumber) else{
     throw ProfileError.invalid("Camera example metadata or sibling JPEG filename is invalid.")
   }
   try capture.tuple.validate()
   // Schema 1 covers the native backend's observed Standard/Auto-Daylight codes.
   guard capture.tuple.style == .standard,capture.tuple.kind == .color,
    capture.tuple.whiteBalance == .auto || capture.tuple.whiteBalance == .daylight,
    capture.pictureStyleRaw == 129,capture.whiteBalanceRaw == Int(capture.tuple.whiteBalance.rawValue) else{
     throw ProfileError.invalid("Camera example schema 1 requires matching recorded Standard/style129 and Auto/WB0 or Daylight/WB1 settings.")
   }
  }
 }
}
struct NativeCameraExampleImage {
 let capture:NativeCameraExampleCapture
 let thumbnail:CGImage
 let width:Int
 let height:Int
}
struct LoadedNativeCameraExamples {
 let manifest:NativeCameraExampleManifest
 let target:NativeCameraExampleImage
 let neutral:NativeCameraExampleImage
}
enum NativeCameraExampleLoader {
 static let manifestFile="camera-examples.json"
 private static func bytes(_ url:URL,limit:Int)throws->Data {
  let info=try url.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey])
  guard info.isRegularFile==true,info.isSymbolicLink != true,let size=info.fileSize,(1...limit).contains(size) else{
   throw ProfileError.invalid("Choose regular local camera-example files within the size limit; symbolic links are not accepted.")
  }
  let data=try Data(contentsOf:url)
  guard data.count<=limit else{throw ProfileError.invalid("Camera example file exceeds its size limit.")}
  return data
 }
 static func load(_ selected:URL)throws->LoadedNativeCameraExamples {
  guard selected.isFileURL,selected.host == nil || selected.host == "" || selected.host == "localhost" else{throw ProfileError.invalid("Choose a local camera example folder or manifest.")}
  let selection=try selected.resourceValues(forKeys:[.isDirectoryKey,.isSymbolicLinkKey])
  guard selection.isSymbolicLink != true else{throw ProfileError.invalid("Choose the actual camera example folder or manifest rather than a symbolic link.")}
  let manifestURL=(selection.isDirectory==true ? selected.appendingPathComponent(manifestFile):selected).standardizedFileURL
  let manifest=try JSONDecoder().decode(NativeCameraExampleManifest.self,from:bytes(manifestURL,limit:65_536))
  try manifest.validate()
  let folder=manifestURL.deletingLastPathComponent().resolvingSymlinksInPath()
  func image(_ capture:NativeCameraExampleCapture)throws->NativeCameraExampleImage {
   let url=folder.appendingPathComponent(capture.file)
   let data=try bytes(url,limit:50_000_000)
   guard NativeCanonical.sha256(data)==capture.sha256.lowercased() else{throw ProfileError.invalid("Camera example JPEG checksum does not match the archive: "+capture.file)}
   guard let source=CGImageSourceCreateWithData(data as CFData,[kCGImageSourceShouldCache:false] as CFDictionary),
    CGImageSourceGetType(source) as String? == UTType.jpeg.identifier,CGImageSourceGetCount(source)==1,
    let properties=CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any],
    let width=properties[kCGImagePropertyPixelWidth] as? Int,let height=properties[kCGImagePropertyPixelHeight] as? Int,
    (1...24_000).contains(width),(1...24_000).contains(height),width*height<=120_000_000,
    let thumbnail=CGImageSourceCreateThumbnailAtIndex(source,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceCreateThumbnailWithTransform:true,kCGImageSourceThumbnailMaxPixelSize:1600] as CFDictionary) else{
     throw ProfileError.invalid("The camera example is not a supported JPEG: "+capture.file)
   }
   return NativeCameraExampleImage(capture:capture,thumbnail:thumbnail,width:width,height:height)
  }
  return LoadedNativeCameraExamples(manifest:manifest,target:try image(manifest.target),neutral:try image(manifest.neutral))
 }
}
@MainActor final class NativeCameraExamplesModel:ObservableObject {
 @Published var loaded:LoadedNativeCameraExamples?
 @Published var busy=false
 @Published var error:String?
 private var loading:Task<Void,Never>?
 init(initial:LoadedNativeCameraExamples?=nil){loaded=initial}
 func choose() {
  let panel=NSOpenPanel();panel.allowedContentTypes=[.json];panel.canChooseFiles=true;panel.canChooseDirectories=true;panel.allowsMultipleSelection=false
  panel.message="Choose a camera example folder or camera-examples.json. Its two JPEGs are opened read-only."
  guard panel.runModal() == .OK,let url=panel.url else{return}
  loading?.cancel();busy=true;error=nil
  loading=Task {
   do {
    let result=try await Task.detached(priority:.userInitiated){try NativeCameraExampleLoader.load(url)}.value
    guard !Task.isCancelled else{return};loaded=result;busy=false
   }catch{guard !Task.isCancelled else{return};self.error=error.localizedDescription;busy=false}
  }
 }
 func clear(){loading?.cancel();loaded=nil;busy=false;error=nil}
}
@MainActor struct NativeCameraExamplesView:View {
 let recipe:Recipe
 let record:NativeRecipeRecord
 @StateObject private var examples:NativeCameraExamplesModel
 init(recipe:Recipe,record:NativeRecipeRecord,initial:LoadedNativeCameraExamples?=nil){self.recipe=recipe;self.record=record;_examples=StateObject(wrappedValue:NativeCameraExamplesModel(initial:initial))}
 private func photo(_ image:NativeCameraExampleImage,title:String)->some View {
  VStack(alignment:.leading,spacing:6) {
   Text(title).font(.subheadline.weight(.semibold))
   Image(decorative:image.thumbnail,scale:1).resizable().scaledToFit().frame(maxWidth:.infinity).background(Color.black.opacity(0.06)).accessibilityLabel(title+" imported JPEG")
   Text(image.capture.file+" · \(image.width) × \(image.height)").font(.caption).fpSecondaryText()
   Text("Settings recorded with this example").font(.caption.weight(.medium))
   Text(image.capture.exposureDescription).font(.caption)
   Text(image.capture.tupleDescription).font(.caption).fixedSize(horizontal:false,vertical:true)
   Text("Archive: Canon style \(image.capture.pictureStyleRaw) / WB \(image.capture.whiteBalanceRaw) · "+image.capture.capturedLocal).font(.caption).fpSecondaryText().fixedSize(horizontal:false,vertical:true)
  }.frame(maxWidth:.infinity,alignment:.topLeading)
 }
 var body:some View {
  VStack(alignment:.leading,spacing:12) {
   HStack {Button(examples.loaded == nil ? "Open camera examples…":"Open another pair…",action:examples.choose);if examples.busy {ProgressView().controlSize(.small)};Spacer();if examples.loaded != nil {Button("Close examples",action:examples.clear).buttonStyle(.link)}}
   if let pair=examples.loaded {
    Text("Imported camera example").font(.caption.weight(.semibold)).fpSecondaryText()
    Text(pair.manifest.title).font(.headline)
    let match=pair.manifest.match(recipe:recipe,record:record)
    Text(match == .capturedSettings ? "Recorded settings match this recipe" : match == .differentRecipe ? "Different recipe — imported example":"Earlier settings — imported example").font(.subheadline.weight(.semibold)).foregroundStyle(match == .capturedSettings ? Color.primary:Color.orange)
    HStack(alignment:.top,spacing:12){photo(pair.target,title:"Target example");photo(pair.neutral,title:"Neutral example")}
    Text("Imported JPEGs and capture settings supplied by this archive. Framing, backlight and Auto WB can vary between captures; Ricoh colour matching remains unmeasured.").font(.caption).fpSecondaryText().fixedSize(horizontal:false,vertical:true)
    DisclosureGroup("Archived trial provenance") {
     Text("Trial: "+pair.manifest.trialID).font(.caption).textSelection(.enabled)
     Text("Payload SHA-256: "+pair.manifest.payloadSHA256).font(.caption).textSelection(.enabled)
     Text("Captured recipe: "+pair.manifest.recipeID.uuidString).font(.caption).textSelection(.enabled)
     Text("This imported manifest describes an archived trial; it does not independently establish camera provenance. Native approval and current runtime qualification remain separate.").font(.caption).fpSecondaryText()
    }
   }else{
    Text("Load an archived native target and neutral JPEG pair to compare actual camera photographs alongside these controls.").font(.caption).fpSecondaryText()
   }
   if let error=examples.error {Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)}
  }.padding(.vertical,6)
 }
}
