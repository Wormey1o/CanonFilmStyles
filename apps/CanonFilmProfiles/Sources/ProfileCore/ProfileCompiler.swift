import Foundation
import FilmProfileEngine
public struct CompiledProfile: Sendable { public let recipe:Recipe;public let body:Data;public let stock:String }
/// Compiles the Effects renderer input shared by Mac preview and the Effects camera worker.
/// The Camera Styles and native authoring workflows use their own compilers.
public struct ProfileCompiler: Sendable {
 public let factoryBook:Data
 public init(factoryBook:Data) throws {
  guard factoryBook.count==21176,factoryBook.u32(0)==0x4b4c4657,factoryBook.u32(4)==1,factoryBook.u32(8)==23,factoryBook.u32(12)==904 else {throw ProfileError.invalid("The bundled factory look book is invalid.")}
  self.factoryBook=factoryBook
 }
 private struct Base {
  var strength:Double, lift:Double, sat:Double
  var hs:[Int],hr:[Int],hl:[Int],sh:[Int],hi:[Int]
  var mono=false
 }
 private func base(_ name:String)->Base {
  switch name {
  case "Standard":return Base(strength:0,lift:0,sat:100,hs:Array(repeating:100,count:6),hr:Array(repeating:0,count:6),hl:Array(repeating:100,count:6),sh:[0,0,0],hi:[0,0,0])
  case "Negative Film": return Base(strength:0.7,lift:6,sat:88,hs:[92,96,88,104,96,90],hr:[0,-4,6,0,0,0],hl:[100,102,96,100,100,100],sh:[-6,3,3],hi:[6,4,-4])
  case "Positive Film": return Base(strength:1.1,lift:0,sat:110,hs:[112,108,104,108,106,104],hr:[0,-2,0,0,0,0],hl:[100,100,98,98,96,100],sh:[0,0,0],hi:[8,4,-6])
  case "Vivid": return Base(strength:1.2,lift:0,sat:124,hs:[108,104,106,108,110,106],hr:Array(repeating:0,count:6),hl:Array(repeating:100,count:6),sh:[0,0,0],hi:[0,0,0])
  case "Retro": return Base(strength:0.8,lift:8,sat:82,hs:[100,108,86,90,84,96],hr:[0,-4,-6,0,0,0],hl:[100,102,96,100,96,100],sh:[8,4,-8],hi:[10,8,-10])
  case "Bleach Bypass": return Base(strength:1.5,lift:0,sat:34,hs:[110,84,80,102,108,94],hr:[0,-5,-7,5,7,0],hl:[103,95,90,95,93,100],sh:[-6,0,10],hi:[6,4,-2])
  // Unmeasured starting look: gentle contrast, slightly subdued colour and
  // yellow highlights. This is not Ricoh's Cinema transform or its Toning control.
  case "Cinema (Yellow)": return Base(strength:0.9,lift:3,sat:96,hs:Array(repeating:100,count:6),hr:Array(repeating:0,count:6),hl:Array(repeating:100,count:6),sh:[0,0,0],hi:[8,6,-10])
  case "Soft Monotone":return Base(strength:0.5,lift:4,sat:0,hs:Array(repeating:100,count:6),hr:Array(repeating:0,count:6),hl:Array(repeating:100,count:6),sh:[0,0,0],hi:[0,0,0],mono:true)
  case "Hard Monotone","Hi-Contrast B&W","BW Monotone": return Base(strength:name=="Hi-Contrast B&W" ? 2.0 : name=="Hard Monotone" ? 1.4 : 0.9,lift:0,sat:0,hs:Array(repeating:100,count:6),hr:Array(repeating:0,count:6),hl:Array(repeating:100,count:6),sh:[0,0,0],hi:[0,0,0],mono:true)
  default: return Base(strength:0,lift:0,sat:100,hs:Array(repeating:100,count:6),hr:Array(repeating:0,count:6),hl:Array(repeating:100,count:6),sh:[0,0,0],hi:[0,0,0])
  }
 }
 private func roundInt(_ x:Double)->Int { Int(x.rounded(.toNearestOrEven)) }
 public func masterCurve(_ r:Recipe)->[(Int,Int)] {
  let b=base(r.factoryID == nil ? r.base : "Identity")
  let xs=[0,16,32,64,96,128,160,192,224,240,255]
  if r.factoryID != nil && r.key==0 && r.contrast==0 && r.highlights==0 && r.shadows==0 {return xs.map{($0,$0)}}
  let gamma=pow(2.0,-0.07*Double(r.key)),flat=1+0.05*Double(min(r.contrast,0))
  var previous=0
  return xs.map { x in
   let t=pow(Double(x)/255,gamma)-0.5
   let a=max(0.05,b.strength+0.22*Double(r.contrast)+0.18*Double(t<0 ? r.shadows:r.highlights))
   var y=0.5+0.5*tanh(2*a*t)/tanh(a)
   y=0.5+(y-0.5)*flat+b.lift/255*pow(1-Double(x)/255,3)
   let v=max(previous,min(255,max(0,roundInt(y*255))));previous=v;return(x,v)
  }
 }
 public func gains(_ r:Recipe)->[Double] {
  if r.wbPolicy=="Set on camera" {return [1,1,1]}
  // Auto (Warmth Priority) retains the source mode but uses the same as-shot
  // baseline as Auto. No scene-dependent AWB algorithm is simulated here.
  let temperature=r.whiteBalance == "Kelvin" ? r.kelvin.flatMap{RecipeWhiteBalance.kelvinRange.contains($0) ? Double($0):nil}:RecipeWhiteBalance.fixedKelvin[r.whiteBalance]
  let warm=(temperature.map{1e6/5200-1e6/$0} ?? 0)+5*Double(r.amberBlue)
  let tint=Double(r.greenMagenta)+(r.whiteBalance.hasPrefix("Fluorescent") ? -4:0)
  let g=[1+0.0016*warm,1+0.010*tint,1-0.0020*warm],l=0.299*(1+0.0016*warm)+0.587*(1+0.010*tint)+0.114*(1-0.0020*warm)
  return g.map{min(1.6,max(0.55,$0/l))}
 }
 public func compile(_ r:Recipe,requireAcknowledgement:Bool=true)throws->CompiledProfile {
  try r.validate(forCamera:requireAcknowledgement)
  var b=base(r.factoryID == nil ? r.base : "Identity")
  let g=gains(r)
  if let tone=r.effectiveToning,tone != .off {b.sh=tone.shadowSplit;b.hi=tone.highlightSplit}
  let cv=masterCurve(r).map{"\($0.0),\($0.1)"}.joined(separator:" ")
  var lines=["# Canon interpretation; entered by the owner. Source: \(r.creator.replacingOccurrences(of:"\n",with:" "))","VERSION 3","NAME \(r.name)","DESC CANON RECIPE INTERPRETATION V1","WB AS_SHOT","CURVE \(cv)"]
  for c in 0..<3 {lines.append("CURVE_\(["R","G","B"][c]) "+[0,64,128,192,255].map{"\($0),\(min(255,roundInt(Double($0)*g[c])))"}.joined(separator:" "))}
  var sat=b.sat*(1+0.08*Double(r.saturation));let peak=sat*Double(b.hs.max() ?? 100)/10000
  if peak>1.6 {sat *= 1.6/peak}
  lines += ["SAT \(b.mono ? 0:roundInt(sat))","HUE_SAT "+b.hs.map(String.init).joined(separator:","),"HUE_ROT "+b.hr.map{String($0+3*r.hue)}.joined(separator:","),"HUE_LUM "+b.hl.map(String.init).joined(separator:","),"SPLIT_SH "+b.sh.map(String.init).joined(separator:","),"SPLIT_HI "+b.hi.map(String.init).joined(separator:",")]
  let grains=[(0,0),(12,14),(22,20),(32,26)],gr=grains[r.grain ?? 0]
  let detail=r.effectiveGrain?.cameraParameters
  lines += ["GRAIN \(detail?.amount ?? gr.0)","GRAIN_SIZE \(detail.map{($0.cell-1)*12} ?? gr.1)"]
  let text=lines.joined(separator:"\n")+"\n";var baked=Data(count:904)
  let rc=text.withCString{str in baked.withUnsafeMutableBytes{out in cfp_bake(str,text.utf8.count,out.bindMemory(to:UInt8.self).baseAddress!)}}
  guard rc==0 else {throw ProfileError.invalid("The recipe could not be compiled (\(rc)).")}
  if let id=r.factoryID {
   let body=try factoryBody(id)
   let overlay=baked
   for c in 0..<3 {for x in 0..<256 {baked[c*256+x]=overlay[c*256+Int(body[c*256+x])]}}
   func scalar(_ d:Data,_ i:Int)->Int {Int(Int32(bitPattern:d.u32(768+i*4)))}
   func put(_ i:Int,_ v:Int){baked.put32(UInt32(bitPattern:Int32(v)),768+i*4)}
   put(0,min(512,scalar(body,0)*scalar(baked,0)/256))
   for i in 1...18 {if (7...12).contains(i) {put(i,max(-1536,min(1536,scalar(body,i)+scalar(baked,i))))} else {put(i,min(512,scalar(body,i)*scalar(baked,i)/256))}}
   for i in 20...25 {put(i,max(-64,min(64,scalar(body,i)+scalar(baked,i))))}
   put(19,(1...18).contains{scalar(baked,$0) != ((7...12).contains($0) ? 0:256)} ? 1:0)
   for i in 26...31 {put(i,scalar(body,i))}
   if r.grain==nil && r.effectiveGrain==nil {put(32,scalar(body,32));put(33,scalar(body,33))}
  }
  let mixer=r.effectiveBWFilter
  if let mixer,mixer.enabled {for (i,v) in [mixer.red,mixer.green,mixer.blue].enumerated(){baked.put32(UInt32(bitPattern:Int32(v)),768+(29+i)*4)}}
  try Self.validateBody(baked,mixerEnabled:mixer?.enabled == true)
  return CompiledProfile(recipe:r,body:baked,stock:text)
 }
 public func factoryBody(_ id:Int)throws->Data {
  for i in 0..<23 {let p=16+i*16;if factoryBook.u32(p)==UInt32(id) {let a=Int(factoryBook.u32(p+4));guard a>=384,a+904<=factoryBook.count else {break};let d=factoryBook.subdata(in:a..<a+904);guard d.fnv32()==factoryBook.u32(p+12) else {break};return d}}
  throw ProfileError.invalid("Unknown or damaged factory look.")
 }
 public static func validateBody(_ d:Data,mixerEnabled:Bool=false)throws {
  guard d.count==904 else {throw ProfileError.invalid("Invalid look length.")}
  let v=(0..<34).map{Int(Int32(bitPattern:d.u32(768+$0*4)))}
  func bounded(_ i:Int,_ a:Int,_ b:Int)->Bool {(a...b).contains(v[i])}
  let ok=bounded(0,0,512) && (1...6).allSatisfy{bounded($0,0,512)} && (7...12).allSatisfy{bounded($0,-1536,1536)} && (13...18).allSatisfy{bounded($0,0,512)} && (20...25).allSatisfy{bounded($0,-64,64)} && v[26]==0 && bounded(27,0,255) && bounded(28,0,48) && (29...31).allSatisfy{bounded($0,mixerEnabled ? -200:0,mixerEnabled ? 200:255)} && (!mixerEnabled || v[0]==0) && bounded(32,0,100) && bounded(33,1,9)
  let any=(1...18).contains{v[$0] != ((7...12).contains($0) ? 0:256)}
  guard ok,v[19]==(any ? 1:0) else {throw ProfileError.invalid("Look contains unsupported or out-of-range rendering parameters.")}
 }
 /// Encodes the three Effects slots as the v3 CUPROF.BIN pack.
 /// Keep the record layout, checksums and version rules in sync with Runtime/source/users/profiles.c.
 public func pack(_ library:RecipeLibrary)throws->Data {
  try library.validate();var out=Data(count:2896);out.put32(0x46505543,0);out.put32(3,4);out.put32(3,8);out.put32(960,12)
  for slot in 0..<3 {
   var record=Data(count:960);record.put16(UInt16(60001+slot),0)
   if let id=library.slots[slot],let recipe=library.recipes.first(where:{$0.id==id}) {
    let p=try compile(recipe);record.put16(UInt16(1 | (recipe.omissions.isEmpty ? 0:2) | (recipe.wbPolicy=="Creative tint" ? 4:0) | (recipe.effectiveBWFilter?.enabled == true ? 8:0) | ((recipe.shading+4)<<4) | ((recipe.sharpness+4)<<8) | ((recipe.clarity+4)<<12)),2);record.put32(recipe.revision,4);record.put32(p.body.fnv32(),8)
    record.replaceSubrange(12..<12+recipe.name.utf8.count,with:recipe.name.utf8);record.replaceSubrange(36..<36+recipe.cameraShortName.utf8.count,with:recipe.cameraShortName.utf8);record.replaceSubrange(56..<960,with:p.body)
   }
   record.put32((record.subdata(in:0..<52)+record.subdata(in:56..<960)).fnv32(),52)
   out.replaceSubrange(16+slot*960..<16+(slot+1)*960,with:record)
  }
  try Self.validatePack(out);return out
 }
 public static func validatePack(_ p:Data)throws {
  guard p.count==2896,p.u32(0)==0x46505543,(1...3).contains(p.u32(4)),p.u32(8)==3,p.u32(12)==960 else {throw ProfileError.invalid("Invalid camera profile pack.")}
  for s in 0..<3 {
   let r=p.subdata(in:16+s*960..<16+(s+1)*960),flags=r.u16(2)
   guard r.u16(0)==60001+s,(p.u32(4)==1 ? flags & ~7 == 0:((p.u32(4)==3 || flags & 10 == 0) && ((flags>>4)&15)<=8 && ((flags>>8)&15)<=8 && ((flags>>12)&15)<=8)),(r.subdata(in:0..<52)+r.subdata(in:56..<960)).fnv32()==r.u32(52) else {throw ProfileError.invalid("Profile record checksum or slot is invalid.")}
   if flags&1==0 {guard flags==0,r.u32(4)==0,r.u32(8)==0,r.subdata(in:12..<52).allSatisfy({$0==0}),r.subdata(in:56..<960).allSatisfy({$0==0}) else {throw ProfileError.invalid("Inactive camera slot is not empty.")};continue}
   for (a,n) in [(12,24),(36,16)] {let str=r.subdata(in:a..<a+n);guard let z=str.firstIndex(of:0),z>0,str.prefix(z).allSatisfy({$0>=32 && $0<=126}),str.suffix(from:z).allSatisfy({$0==0}),a != 36 || z<=14 else {throw ProfileError.invalid("Invalid camera profile label.")}}
   let body=r.subdata(in:56..<960);guard r.u32(4)>0,body.fnv32()==r.u32(8) else {throw ProfileError.invalid("Invalid profile revision or look checksum.")};try validateBody(body,mixerEnabled:p.u32(4)==3 && flags&8 != 0)
  }
 }
}
