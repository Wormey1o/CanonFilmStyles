import SwiftUI
import AppKit
import CoreImage
import UniformTypeIdentifiers
import ProfileCore

@MainActor final class PhotoPreviewModel:ObservableObject {
 @Published var source:PhotoPreviewSource?
 @Published var sourceVersion=0
 @Published var original:NSImage?
 @Published var rendered:NSImage?
 @Published var busy=false
 @Published var error:String?
 @Published var showOriginal=false
 @Published var expanded=true
 @Published var showPixels=false
 private var loading:Task<Void,Never>?
 private var cancellation:PhotoPreviewCancellation?
 private var generation=0
 private static func image(_ jpeg:Data,orientation:UInt32?=nil)->NSImage? {
  guard var ci=CIImage(data:jpeg,options:[.applyOrientationProperty:true]) else{return nil}
  if let orientation {ci=ci.oriented(forExifOrientation:Int32(orientation))}
  guard let cg=CIContext().createCGImage(ci,from:ci.extent) else{return nil}
  return NSImage(cgImage:cg,size:.zero)
 }
 func choosePhoto(){
  let panel=NSOpenPanel();panel.allowedContentTypes=[.jpeg,UTType(filenameExtension:"cr2") ?? .rawImage];panel.allowsMultipleSelection=false;panel.canChooseDirectories=false
  panel.message="Choose a Canon CR2 or a JPEG to preview your recipe."
  guard panel.runModal() == .OK,let url=panel.url else{return}
  loading?.cancel();cancellation?.cancel();generation+=1;let request=generation;busy=true;rendered=nil;error=nil
  loading=Task {
   do {let loaded=try await Task.detached(priority:.userInitiated){try PhotoPreviewSource.load(url)}.value
    guard !Task.isCancelled,request==generation else{return}
    source=loaded;original=Self.image(loaded.jpeg,orientation:loaded.orientation);sourceVersion+=1
   }catch{guard !Task.isCancelled,request==generation else{return};self.error=error.localizedDescription;busy=false}
  }
 }
 func update(recipe:Recipe,compiler:ProfileCompiler)async {
  let request=generation
  cancellation?.cancel();rendered=nil
  guard let source else{return}
  busy=true;error=nil
  do {
   try await Task.sleep(for:.milliseconds(200));try Task.checkCancellation()
   let profile=try compiler.compile(recipe,requireAcknowledgement:false),token=try PhotoPreviewCancellation()
   cancellation=token
   let jpeg=try await withTaskCancellationHandler(operation:{try await PhotoPreviewRenderer.shared.render(source,profile:profile,cancellation:token)},onCancel:{token.cancel()})
   try Task.checkCancellation();guard request==generation else{return};rendered=Self.image(jpeg);busy=false
  }catch{if !Task.isCancelled,request==generation{self.error=error.localizedDescription;busy=false}}
 }
}

struct PhotoPreviewView:View {
 @StateObject private var preview = PhotoPreviewModel()
 let recipe:Recipe
 let compiler:ProfileCompiler
 @Environment(\.displayScale) private var displayScale
 init(recipe:Recipe,compiler:ProfileCompiler){self.recipe=recipe;self.compiler=compiler}
 private struct Request:Equatable {let recipe:Recipe;let sourceVersion:Int}
 var body:some View {
  VStack(alignment:.leading,spacing:9){
   HStack {
    Button{preview.expanded.toggle()}label:{Label("Photo preview",systemImage:preview.expanded ? "chevron.down":"chevron.right").font(.headline)}.buttonStyle(.plain)
    Spacer()
    if preview.expanded {Picker("View",selection:$preview.showOriginal){Text("Original").tag(true);Text("Recipe").tag(false)}.pickerStyle(.segmented).frame(width:150).labelsHidden()}
    if preview.expanded {Button(preview.showPixels ? "Fit":"100%"){preview.showPixels.toggle()}.controlSize(.small).help("Inspect grain and detail at one photo pixel per screen pixel")}
    Button("Open photo…",action:preview.choosePhoto).controlSize(.small)
   }
   if preview.expanded {
    ZStack {
     RoundedRectangle(cornerRadius:8).fill(Color.black.opacity(0.9))
     if let image=preview.showOriginal ? preview.original:preview.rendered {
      if preview.showPixels {
       ScrollView([.horizontal,.vertical]){Image(nsImage:image).resizable().frame(width:image.size.width/displayScale,height:image.size.height/displayScale)}
      }else{Image(nsImage:image).resizable().scaledToFit().padding(2)}
     }else if preview.busy {ProgressView("Rendering recipe…").tint(.white).foregroundStyle(.white)}
    }.frame(height:240).accessibilityLabel(preview.showOriginal ? "Original photo":"Recipe applied to photo")
    if let error=preview.error {Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)}
    HStack {Text(preview.source?.name ?? "Choose a photo").lineLimit(1);Spacer();if preview.busy {ProgressView().controlSize(.mini)}}.font(.caption).fpSecondaryText()
    if let source = preview.source {
     Text(source.isCameraInput ? "Camera renderer · 2256 × 1504 · Uses the photo’s captured white balance." : "Approximate preview from a resized JPEG. A CR2 gives the camera’s actual input.").font(.caption).fpSecondaryText()
    }
   }
  }.padding(16).background(Color(nsColor:.controlBackgroundColor))
  .task(id:Request(recipe:recipe,sourceVersion:preview.sourceVersion)){await preview.update(recipe:recipe,compiler:compiler)}
 }
}
