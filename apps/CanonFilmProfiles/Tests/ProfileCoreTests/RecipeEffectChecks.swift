import Foundation
import ProfileCore
import FilmProfileEngine

extension ProfileCoreTests {
 func rendered(_ body:Data,_ pixels:[UInt8],width:Int,height:Int,mixerEnabled:Bool=false,shading:Int=0,sharpness:Int=0,clarity:Int=0)throws->[UInt8] {
  try ProfileCompiler.validateBody(body,mixerEnabled:mixerEnabled)
  var out=[UInt8](repeating:0,count:pixels.count)
  let rc=body.withUnsafeBytes{b in pixels.withUnsafeBufferPointer{p in out.withUnsafeMutableBufferPointer{o in cfp_render_effects(b.bindMemory(to:UInt8.self).baseAddress!,p.baseAddress!,Int32(width),Int32(height),Int32(shading),Int32(sharpness),Int32(clarity),mixerEnabled ? 1:0,o.baseAddress!)}}}
  XCTAssertEqual(rc,0,"Host rendering failed")
  return out
 }
 func testReferenceEffects()throws {
  let c=try ProfileCompiler(factoryBook:book)
  var neutral=Recipe();neutral.base="BW Monotone"
  let plain=try c.compile(neutral).body
  let fixtures=URL(fileURLWithPath:"/private/tmp/canon-effects-v3/compiled-fixtures")
  try FileManager.default.createDirectory(at:fixtures,withIntermediateDirectories:true)
  try plain.write(to:fixtures.appendingPathComponent("baseline.look"))
  for (i,filter) in BWFilter.references.enumerated() {var r=neutral;r.bwFilter=filter;r.allowPartial=true;try c.compile(r).body.write(to:fixtures.appendingPathComponent("filter-\(i+1).look"))}
  for tone in MonochromeToning.allCases {var r=neutral;r.toning=tone;r.allowPartial=true;try c.compile(r).body.write(to:fixtures.appendingPathComponent("tone-\(tone.rawValue).look"))}
  for level in 0...3 {var r=neutral;r.grainSettings=RecipeGrain(intensity:level);r.allowPartial=true;try c.compile(r).body.write(to:fixtures.appendingPathComponent("grain-\(level).look"))}
  if let path=ProcessInfo.processInfo.environment["CANON_CHECK_LIBRARY"] {let existing=try RecipeLibrary.load(from:URL(fileURLWithPath:path));print("PASS existing owner library read-only: \(existing.recipes.count) recipes, \(existing.slots.compactMap{$0}.count) assigned slots")}
  let colours:[UInt8]=[170,40,50,30,70,170,40,160,70,128,128,128]
  let before=try rendered(plain,colours,width:4,height:1)
  let triples=[[10,70,20],[40,50,10],[90,20,-10],[120,-10,-10]]
  let nodes=[[77,107,120,111,91,83],[108,112,115,96,83,99],[148,123,111,46,62,123],[166,127,87,11,66,137]]
  for i in 0..<4 {
   let filter=BWFilter.parse("\(i+1) - R \(triples[i][0])% / G \(triples[i][1])% / B \(triples[i][2])%")!
   XCTAssertEqual([filter.red,filter.green,filter.blue],triples[i]);XCTAssertEqual(filter.hueBrightness,nodes[i]) // retained only as v1 compatibility data
   var r=neutral;r.bwFilter=filter;r.allowPartial=true
   let compiled=try c.compile(r),after=try rendered(compiled.body,colours,width:4,height:1,mixerEnabled:true)
   check(after != before,"Filter must affect actual rendered pixels")
   XCTAssertEqual(Array(after[9..<12]),Array(before[9..<12]),"Filter should preserve neutral grey")
   for p in stride(from:0,to:after.count,by:3) {check(after[p]==after[p+1] && after[p]==after[p+2],"Filtered output must be monochrome")}
  }
  var r=neutral;r.bwFilter=BWFilter.references[3];r.allowPartial=true
  let redFilter=try rendered(c.compile(r).body,colours,width:4,height:1,mixerEnabled:true)
  check(redFilter[0]>before[0] && redFilter[3]<before[3],"Red reference should lighten red and darken blue")
  r.bwFilter = .off
  XCTAssertEqual(try c.compile(r).body,plain,"Off must restore the baseline bytes")
  let arbitrary=BWFilter.parse("3 - R 50% / G 20% / B −10%")!
  XCTAssertEqual(arbitrary.red+arbitrary.green+arbitrary.blue,60,"Do not normalise signed source percentages")
  for value in ["3","R 50% / G 20%","R 50% G 20% B ?%","R 900% G 20% B 10%","R 50% G 20% B -10% trailing"] {check(BWFilter.parse(value)==nil,"Refuse ambiguous filter: \(value)")}
  let chroma:[[Int]]=[[0,0],[7,-10],[14,0],[-12,-4],[-3,9],[3,9]]
  for (i,tone) in MonochromeToning.allCases.enumerated() {
   var toned=neutral;toned.toning=tone;toned.allowPartial=true
   let pixel=try rendered(c.compile(toned).body,[128,128,128],width:1,height:1)
   print("TONE",tone,pixel,chroma[i]);check(abs(Int(pixel[0])-Int(pixel[1])-chroma[i][0])<=1,"Measured R-G: \(tone)")
   check(abs(Int(pixel[2])-Int(pixel[1])-chroma[i][1])<=1,"Measured B-G: \(tone)")
  }
  check(MonochromeToning.parse("2")==nil,"Cinema numeric toning must not be guessed as a named tone")
  for base in ["Negative Film","Cinema (Yellow)"] {
   var colour=Recipe();colour.base=base;colour.allowPartial=true
   let original=try c.compile(colour).body;colour.bwFilter=BWFilter.references[0];colour.toning = .red
   XCTAssertEqual(try c.compile(colour).body,original,"B&W effects must stay inactive on colour bases")
  }
  var deviation:[Double]=[]
  let pixels=[UInt8](repeating:128,count:128*128*3)
  for level in 0...3 {
   var grained=neutral;grained.grainSettings=RecipeGrain(intensity:level);grained.allowPartial=true
   let compiled=try c.compile(grained);XCTAssertEqual(compiled.body.u32(768+32*4),UInt32([0,11,16,27][level]));XCTAssertEqual(compiled.body.u32(768+33*4),1)
   let out=try rendered(compiled.body,pixels,width:128,height:128),values=stride(from:0,to:out.count,by:3).map{Double(out[$0])},mean=values.reduce(0,+)/Double(values.count)
   deviation.append(sqrt(values.map{pow($0-mean,2)}.reduce(0,+)/Double(values.count)))
  }
  check(deviation[0]==0 && deviation[1]>0 && deviation[2]>deviation[1] && deviation[3]>deviation[2],"Grain must visibly increase at each reference strength")
  var bodies=Set<Data>()
  for size in 1...3 {for intensity in 1...3 {
   let source="Size \(size) / Intensity \(intensity)",detail=RecipeGrain.parse(source)!
   XCTAssertEqual(detail.size,size);XCTAssertEqual(detail.intensity,intensity)
   var r=neutral;r.grainSettings=detail;r.allowPartial=true
   let body=try c.compile(r).body;bodies.insert(body)
   XCTAssertEqual(body.u32(768+33*4),UInt32(size))
  }}
  XCTAssertEqual(bodies.count,9,"Separate size/intensity combinations must not collapse to three presets")
  var imported=neutral;imported.sourceSettings=[.init(key:"filterEffect",label:"FILTER EFFECT",value:"3 - R 50% / G 20% / B -10%"),.init(key:"toning",label:"TONING",value:"Sepia"),.init(key:"grain",label:"GRAIN",value:"Size 2 / Intensity 1")];imported.grain=1
  var object=try JSONSerialization.jsonObject(with:JSONEncoder().encode(imported)) as! [String:Any]
  for key in ["bwFilter","toning","grainSettings"] {object.removeValue(forKey:key)}
  var restored=try JSONDecoder().decode(Recipe.self,from:JSONSerialization.data(withJSONObject:object))
  XCTAssertEqual(restored.effectiveBWFilter,arbitrary);XCTAssertEqual(restored.effectiveToning,.sepia);XCTAssertEqual(restored.effectiveGrain?.size,2)
  XCTAssertThrowsError(try c.compile(restored));restored.allowPartial=true
  let pack=try c.pack(RecipeLibrary(recipes:[restored],slots:[restored.id,nil,nil]));try ProfileCompiler.validatePack(pack)
  restored.bwFilter = .off;restored.toning = .off;restored.grainSettings=RecipeGrain(intensity:0)
  XCTAssertEqual(restored.effectiveBWFilter,.off);XCTAssertEqual(restored.effectiveToning,.off);XCTAssertEqual(restored.effectiveGrain?.intensity,0)
  XCTAssertEqual(try c.compile(restored).body,plain,"Explicit Off must override saved source-card effects")
  restored.bwFilter=BWFilter(red:201);XCTAssertThrowsError(try restored.validate())
  restored.bwFilter=nil;restored.grainSettings=RecipeGrain(intensity:4);XCTAssertThrowsError(try restored.validate())
  var edited=imported;edited.bwFilter=BWFilter.references[3];edited.toning = .blue;edited.grainSettings=RecipeGrain(mode:.sizeIntensity,intensity:3,size:3)
  let saved=try JSONDecoder().decode(Recipe.self,from:JSONEncoder().encode(edited));XCTAssertEqual(saved,edited)
  print("PASS measured filter/toning fixtures, rendered pixels, independent grain axes, legacy source recovery, Off overrides and effect persistence")
 }
}
