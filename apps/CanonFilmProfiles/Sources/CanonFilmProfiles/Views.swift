import SwiftUI
import ProfileCore
struct MainView:View {
 @ObservedObject var model:AppModel
 var cameraExamples:LoadedNativeCameraExamples?=nil
 var body:some View {
  NavigationSplitView {
   VStack(alignment:.leading,spacing:0){
    FPSidebarHeader().padding(20)
    List(selection:$model.selected){ForEach(model.library.recipes){r in VStack(alignment:.leading,spacing:4){HStack(spacing:6){Text(r.name).font(.system(size:14,weight:.medium)).lineLimit(1);Spacer(minLength:0);let activeSlots=model.workflow == .native ? model.nativeStore.slots:model.workflow == .cameraStyles ? model.cameraStyleSlots:model.library.slots;let assigned=activeSlots.indices.filter{activeSlots[$0]==r.id};HStack(spacing:5){ForEach(assigned,id:\.self){slot in FPSlotTag(slot:slot+1,compact:assigned.count>1)}}};Text(r.factoryID.flatMap{Recipe.factoryNames[$0]} ?? r.base).font(.caption).fpSecondaryText();if model.workflow == .native {if let native=model.nativeStore.records.first(where:{$0.sourceRecipeID==r.id}),!NativeRecipeAuthoring.isApprovalCurrent(record:native,for:r) {FPCautionChip(text:"Native draft")}}else if !r.omissions.isEmpty {FPCautionChip(text:"Partial interpretation")}}.padding(.vertical,6).tag(r.id)} }
    HStack{Button(action:model.newRecipe){Image(systemName:"plus")}.help("New recipe");Button(action:model.duplicate){Image(systemName:"plus.square.on.square")}.disabled(model.current==nil).help("Duplicate recipe");Spacer();Button(role:.destructive,action:model.remove){Image(systemName:"trash")}.disabled(model.current==nil)}.buttonStyle(.borderless).padding(16)
    Button{model.showFactory=true}label:{Text("Copy a factory look…").foregroundStyle(FP.brandInk)}.buttonStyle(.link).padding(.horizontal,16).padding(.bottom,16)
   }.navigationSplitViewColumnWidth(min:210,ideal:240,max:290)
  } detail: {
   HStack(spacing:0){
    if model.workflow == .cameraStyles {CameraStylesPlanView(model:model).frame(minWidth:450)}else if let recipe=model.current {if model.workflow == .native {NativeRecipeView(model:model,recipe:recipe,initialExamples:cameraExamples).frame(minWidth:450)}else{VStack(spacing:0){PhotoPreviewView(recipe:recipe,compiler:model.compiler);Divider();RecipeEditor(model:model,recipe:recipe)}.frame(minWidth:450)}}else{ContentUnavailableView("Your recipe library",systemImage:"camera.filters",description:Text("Create a recipe or make an editable copy of a factory look."))}
    Divider();if model.workflow == .cameraStyles {CameraStyleSlotsView(model:model).frame(width:300)}else if model.workflow == .native {NativeSlotsView(model:model).frame(width:300)}else{CameraSlotsView(model:model).frame(width:285)}
   }.background(Color(nsColor:.windowBackgroundColor))
  }
  .frame(minWidth:1030,minHeight:740)
  .tint(FP.controlAccent)
  .accentColor(FP.controlAccent)
  .toolbar {ToolbarItemGroup {Picker("Workflow",selection:$model.workflow){Text("Effects").tag(AppWorkflow.effects);Text("Native processing").tag(AppWorkflow.native);Text("Camera styles").tag(AppWorkflow.cameraStyles)}.pickerStyle(.segmented).frame(width:390);Menu {Button("Recipe card image…",action:model.importRecipeCard);Button("Recipe library (JSON)…",action:model.importRecipes);Button("Native companion (JSON)…",action:model.importNativeCompanion)} label:{Label("Import",systemImage:"square.and.arrow.down")}.disabled(model.importingCard);Menu {Button("Recipe library (JSON)…",action:model.exportRecipes);Button("Native authoring companion (JSON)…",action:model.exportNativeCompanion);Button("Native host plan…",action:model.exportNativePlan);Button("Native boot package…",action:model.exportNativeBootPackage).disabled(!model.hasNativeTemplate);Divider();Button("Selected look as Nitro preset…"){model.exportLUTs(all:false,nativePresets:true)}.disabled(model.current==nil || model.exportingLUTs);Button("All looks as Nitro presets…"){model.exportLUTs(all:true,nativePresets:true)}.disabled(model.library.recipes.isEmpty || model.exportingLUTs);Divider();Button("Selected look as LUT…"){model.exportLUTs(all:false)}.disabled(model.current==nil || model.exportingLUTs);Button("All looks for Nitro (LUTs)…"){model.exportLUTs(all:true)}.disabled(model.library.recipes.isEmpty || model.exportingLUTs)}label:{Label("Export",systemImage:"square.and.arrow.up")}}}
  .safeAreaInset(edge:.bottom){HStack(spacing:8){Image(systemName:model.uploading ? "arrow.triangle.2.circlepath":"checkmark.circle").foregroundStyle(FP.controlAccent);Text(model.status).font(.caption);Spacer();HostBatchFooter(session: model.hostBatch, draft: model.batchGrainDraft);FPMark(size:14);Text(model.workflow == .cameraStyles ? "Canon Picture Styles" : model.workflow == .native ? "Canon interpretation · No native preview" : "Effects preview on Mac").font(.caption).fpSecondaryText()}.padding(.horizontal,18).padding(.vertical,10).background(.bar)}
  .alert("Film Profiles",isPresented:Binding(get:{model.error != nil},set:{if !$0{model.error=nil}})){Button("OK"){model.error=nil}}message:{Text(model.error ?? "")}
  .sheet(isPresented:$model.showFactory){VStack(alignment:.leading){Text("Start from a factory look").font(.title2.bold());Text("Creates an editable copy. The camera’s factory looks stay available.").fpSecondaryText();List(Recipe.factoryNames.keys.sorted(),id:\.self){id in Button(Recipe.factoryNames[id]!){model.factory(id)}.buttonStyle(.plain)};Button("Cancel"){model.showFactory=false}}.padding(24).frame(width:420,height:520)}
 }
}
struct RecipeEditor:View {
 @ObservedObject var model:AppModel
 let recipe:Recipe
 private var whiteBalanceMode:Binding<String> {
  Binding(get:{model.current?.whiteBalance ?? "Auto"},set:{value in
   if value=="Kelvin",model.current?.kelvin == nil {model.binding(\.kelvin).wrappedValue=5200}
   model.binding(\.whiteBalance).wrappedValue=value
  })
 }
 private var kelvinValue:Binding<Int> {Binding(get:{model.current?.kelvin ?? 5200},set:{model.binding(\.kelvin).wrappedValue=$0})}
 private var filterPreset:Binding<Int> {
  Binding(get:{let f=model.current?.effectiveBWFilter ?? .off;return !f.enabled ? 0:(BWFilter.references.firstIndex(of:f).map{$0+1} ?? 5)},set:{v in
   let current=model.current?.effectiveBWFilter
   model.binding(\.bwFilter).wrappedValue=v==0 ? .off:v<=4 ? BWFilter.references[v-1]:(current?.enabled == true ? current:BWFilter())
  })
 }
 private func filterValue(_ key:WritableKeyPath<BWFilter,Int>)->Binding<Int> {
  Binding(get:{(model.current?.effectiveBWFilter ?? BWFilter())[keyPath:key]},set:{v in var f=model.current?.effectiveBWFilter ?? BWFilter();f[keyPath:key]=v;model.binding(\.bwFilter).wrappedValue=f})
 }
 private func grainValue<T>(_ key:WritableKeyPath<RecipeGrain,T>)->Binding<T> {
  Binding(get:{(model.current?.effectiveGrain ?? RecipeGrain(intensity:model.current?.grain ?? 0))[keyPath:key]},set:{v in var g=model.current?.effectiveGrain ?? RecipeGrain(intensity:model.current?.grain ?? 0);g[keyPath:key]=v;model.binding(\.grainSettings).wrappedValue=g})
 }
 var body:some View {
  ScrollView {
   VStack(alignment:.leading,spacing:22){
    VStack(alignment:.leading,spacing:7){Text(recipe.name).font(.system(size:30,weight:.semibold,design:.default)).foregroundStyle(.primary);Text("A recipe for your Canon").font(.subheadline).fpSecondaryText()}
    if recipe.sourceSettings != nil {
     FPCautionCard {
      FPCautionTitle(text:"Imported from recipe card")
      Text("Review the settings against the card before uploading. Source settings and their application status are retained below.").font(.caption).fpSecondaryText()
      if !recipe.sourceOmissions.isEmpty || !recipe.interpretationOmissions.isEmpty {Text("Some card effects are approximate, unapplied or need review.").font(.caption).fpSecondaryText().padding(.top,4)}
     }
    } else if model.importedCardID == recipe.id && !model.cardImportNotices.isEmpty {
     FPCautionCard {
      FPCautionTitle(text:"Imported from recipe card")
      ForEach(model.cardImportNotices,id:\.self){Text($0).font(.caption).fpSecondaryText().padding(.bottom,8)}
     }
    }
    Form {
     Section("Identity") {TextField("Name",text:model.binding(\.name));TextField("Shooting-screen label",text:model.binding(\.shortName));TextField("Recipe by",text:model.binding(\.creator));TextField("Source link",text:model.binding(\.sourceURL))}
     Section("Starting look") {if let id=recipe.factoryID {LabeledContent("Factory base",value:Recipe.factoryNames[id] ?? "Factory look")}else{Picker("Image Control",selection:model.binding(\.base)){ForEach(Recipe.bases,id:\.self){Text($0)}}};Text(recipe.factoryID == nil ? recipe.baseInterpretationDescription:"Adjustments are relative to the original factory look.").font(.caption).fpSecondaryText()}
     if !recipe.isMonochrome && (recipe.bwFilter?.enabled == true || (recipe.toning != nil && recipe.toning != .off)) {Text("Saved B&W filter and toning controls are inactive for this colour Image Control.").font(.caption).fpSecondaryText()}
     Section("Colour & tone") {
      if recipe.isMonochrome {
       LabeledContent("Saturation",value:"— Not applicable")
       LabeledContent("Hue",value:"— Not applicable")
       Text("Saturation and Hue are unavailable for this monochrome Image Control.").font(.caption).fpSecondaryText()
      } else {
       AdjustmentRow(title:"Saturation",value:model.binding(\.saturation))
       AdjustmentRow(title:"Hue",value:model.binding(\.hue))
      }
      AdjustmentRow(title:"High / low key",value:model.binding(\.key));AdjustmentRow(title:"Contrast",value:model.binding(\.contrast));AdjustmentRow(title:"Highlight contrast",value:model.binding(\.highlights));AdjustmentRow(title:"Shadow contrast",value:model.binding(\.shadows));ToneCurve(curve:model.compiler.masterCurve(recipe)).frame(height:92).padding(.vertical,6)
     }
     if recipe.isMonochrome {
      Section("Monochrome effects") {
       Picker("B&W filter",selection:filterPreset) {Text("Off").tag(0);ForEach(0..<4){i in Text("Reference \(i+1)").tag(i+1)};Text("Custom RGB mix").tag(5)}
       if recipe.effectiveBWFilter?.enabled == true {
        AdjustmentRow(title:"Red %",value:filterValue(\.red),range:-200...200)
        AdjustmentRow(title:"Green %",value:filterValue(\.green),range:-200...200)
        AdjustmentRow(title:"Blue %",value:filterValue(\.blue),range:-200...200)
        Text("Signed percentages are applied directly. Ricoh appearance remains approximate because its colour processing differs.").font(.caption).fpSecondaryText()
       }
       Picker("Toning",selection:Binding(get:{model.current?.effectiveToning ?? .off},set:{model.binding(\.toning).wrappedValue=$0})) {ForEach(MonochromeToning.allCases,id:\.self){Text($0.rawValue).tag($0)}}
       Text("Named tones use measured GR IIIx colour differences. Appearance on Canon remains approximate.").font(.caption).fpSecondaryText()
      }
     }
     Section("White balance") {Picker("Preset",selection:whiteBalanceMode){ForEach(Recipe.whiteBalances,id:\.self){Text(RecipeWhiteBalance.label($0)).tag($0)}};if recipe.whiteBalance=="Kelvin" {LabeledContent("Temperature"){HStack{Text("\(recipe.kelvin ?? 5200) K").monospacedDigit();Stepper("Kelvin temperature",value:kelvinValue,in:RecipeWhiteBalance.kelvinRange,step:100).labelsHidden()}}};AdjustmentRow(title:"Blue ← → Amber",value:model.binding(\.amberBlue),range:-14...14);AdjustmentRow(title:"Magenta ← → Green",value:model.binding(\.greenMagenta),range:-14...14);Text(recipe.wbDescription).font(FP.cameraString(.callout));Picker("Apply as",selection:model.binding(\.wbPolicy)){Text("Approximate creative tint").tag("Creative tint");Text(recipe.usesSceneDependentWB ? "Set Auto WB manually on camera":"Set WB manually on camera").tag("Set on camera")};Text(recipe.wbApplicationDescription).font(.caption).fpSecondaryText()}
     Section("Grain") {
      if recipe.effectiveGrain != nil || (recipe.grain == nil && recipe.factoryID == nil) {
       Picker("Controls",selection:grainValue(\.mode)) {ForEach(RecipeGrain.Mode.allCases,id:\.self){Text($0.rawValue).tag($0)}}
       Picker("Intensity",selection:grainValue(\.intensity)) {ForEach(0..<4){i in Text(RecipeGrainMapping.name(i)).tag(i)}}
       if (recipe.effectiveGrain?.mode ?? .grIIIx) == .sizeIntensity {
        Picker("Size",selection:grainValue(\.size)) {ForEach(1..<4){i in Text(String(i)).tag(i)}}
       }
       Text((recipe.effectiveGrain?.mode ?? .grIIIx) == .grIIIx ? "Strength fitted from the GR IIIx references at Canon output size. Texture remains approximate." : "Size and intensity are independent. These combinations are starting approximations; our references measure the GR IIIx strengths.").font(.caption).fpSecondaryText()
       if recipe.factoryID != nil {Button("Inherit factory grain"){model.binding(\.grainSettings).wrappedValue=nil;model.binding(\.grain).wrappedValue=nil}}
      } else {
       Picker("Added grain",selection:model.binding(\.grain)){Text(recipe.factoryID==nil ? "Unspecified → none":"Inherit factory grain").tag(nil as Int?);ForEach(0..<4){i in Text(RecipeGrainMapping.name(i)).tag(i as Int?)}}
       Button("Use Ricoh grain controls"){model.binding(\.grainSettings).wrappedValue=RecipeGrain(intensity:recipe.grain ?? 0)}
      }
     }
     Section("Texture & detail") {AdjustmentRow(title:"Sharpness",value:model.binding(\.sharpness));AdjustmentRow(title:"Shading",value:model.binding(\.shading));AdjustmentRow(title:"Clarity",value:model.binding(\.clarity));Text("Shading, sharpness and clarity are applied in camera before added grain. Their strengths are Canon interpretations of the Ricoh controls.").font(.caption).fpSecondaryText()}

     if let settings=recipe.sourceSettings {
      Section("From the recipe card") {
       ForEach(settings,id:\.key) { setting in
        VStack(alignment:.leading,spacing:4) {
         Text(setting.label).font(.subheadline.weight(.medium))
         Text(setting.value ?? "Unreadable — check the original card")
         Text(recipe.sourceDisposition(setting)).font(.caption).fpSecondaryText()
        }.padding(.vertical,3)
       }
      }
     }
     if !recipe.omissions.isEmpty {Section {FPCautionCard {FPCautionTitle(text:"Some settings are not reproduced exactly");Text(recipe.omissions.joined(separator:" · ")).font(.caption).fpSecondaryText();Divider().overlay(FP.cautionStroke);Toggle("Allow approximate interpretation",isOn:model.binding(\.allowPartial)).padding(.vertical,8);Text("The shooting-screen name ends in * so an incomplete recipe is identifiable.").font(.caption).fpSecondaryText().padding(.bottom,12)}.listRowInsets(EdgeInsets())} /* Grouped Form ignores listRowBackground on macOS 27.0.1; use the explicit card. */ }
     Section("Notes") {TextEditor(text:model.binding(\.notes)).frame(minHeight:60)}
    }.formStyle(.grouped)
   }.padding(24)
  }.id(recipe.id)
 }
}
struct AdjustmentRow:View {
 let title:String
 @Binding var value:Int
 var range:ClosedRange<Int> = -4...4
 var body:some View {LabeledContent(title){HStack(spacing:12){Text(value>0 ? "+\(value)":"\(value)").font(.system(.body,design:.monospaced)).monospacedDigit().frame(width:34,alignment:.trailing);Stepper("",value:$value,in:range).labelsHidden().fixedSize()}}}

}
struct ToneCurve:View {
 let curve:[(Int,Int)]
 var body:some View {GeometryReader{g in ZStack {RoundedRectangle(cornerRadius:8).fill(Color.primary.opacity(0.035));Path{p in p.move(to:CGPoint(x:12,y:g.size.height-12));p.addLine(to:CGPoint(x:g.size.width-12,y:12))}.stroke(.secondary.opacity(0.2),style:StrokeStyle(lineWidth:1,dash:[4,4]));Path{p in for (i,v) in curve.enumerated(){let q=CGPoint(x:12+Double(v.0)/255*(g.size.width-24),y:g.size.height-12-Double(v.1)/255*(g.size.height-24));if i==0{p.move(to:q)}else{p.addLine(to:q)}}}.stroke(FP.brandInk,lineWidth:2)}}.accessibilityLabel("Recipe tone curve")}
}
struct CameraSlotsView:View {
 @ObservedObject var model:AppModel
 var body:some View {
  VStack(alignment:.leading,spacing:20){
   Text("Effects slots").font(.title3.weight(.semibold));Text("Assign up to three recipes to an Effects profile pack.").font(.callout).fpSecondaryText()
   VStack(spacing:9){ForEach(0..<3,id:\.self){slot in VStack(alignment:.leading,spacing:8){HStack(spacing:8){FPSlotBadge(slot:slot+1);Text("User slot \(slot+1)").font(.system(size:13,weight:.semibold));Spacer()};Picker("Recipe",selection:Binding(get:{model.library.slots[slot]},set:{model.assign(slot,$0)})){Text("Empty").tag(nil as UUID?);ForEach(model.library.recipes){Text($0.name).tag($0.id as UUID?)}}.labelsHidden();if let id=model.library.slots[slot],let r=model.library.recipes.first(where:{$0.id==id}) {(Text("Screen: ")+Text(r.cameraShortName).font(FP.cameraString())).font(.caption).fpSecondaryText()}}.padding(12).background(FP.slotCard,in:RoundedRectangle(cornerRadius:10))}}
   Divider()
   if model.hasEffectsRuntime {
    HStack{Text("Configured Effects card").font(.subheadline.weight(.medium));Spacer();Button(action:model.scan){Image(systemName:"arrow.clockwise")}.buttonStyle(.borderless).disabled(model.uploading)}
    if model.cards.isEmpty {Label("Insert the camera card",systemImage:"sdcard").font(.callout).fpSecondaryText()}else{Picker("Card",selection:$model.selectedCard){ForEach(model.cards){Text($0.displayName).tag($0.id as String?)}}.labelsHidden()}
    Button(action:{model.upload()}){HStack{if model.uploading{ProgressView().controlSize(.small)};Text(model.uploading ? "Uploading…":"Upload & eject");Image(systemName:"arrow.up.to.line")}.frame(maxWidth:.infinity)}.buttonStyle(FPPrimaryButtonStyle()).disabled(model.uploading || model.selectedCard==nil)
    Text("Switch the camera off and place its configured FAT16 Effects card in the reader. macOS may request authentication.").font(.caption).fpSecondaryText()
    Button{model.upload(prepareWorking:true)}label:{Text("Reset existing Effects card…").foregroundStyle(FP.brandInk)}.buttonStyle(.link).disabled(model.selectedCard==nil || model.uploading)
    Text("Clears look assignments and recognized timing files. The previous card installation is backed up on this Mac.").font(.caption).fpSecondaryText()
   } else {
    Text("This build exports Effects packs. Card upload requires the matching Effects runtime.").font(.caption).fpSecondaryText()
   }
   Button(action:model.exportPack){Text("Export Effects pack…").foregroundStyle(FP.brandInk)}.buttonStyle(.link)
   Spacer()
   if model.hasEffectsRuntime {
    Text("The Effects runtime develops a 2256 × 1504 JPEG in camera.").font(.caption).fpSecondaryText()
   }
  }.padding(22).background(FP.inspectorBackground)
 }
}
