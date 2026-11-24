import Foundation
import CryptoKit
import FilmProfileEngine
import ProfileCore

@main struct LUTExportChecks {
 static func check(_ condition:Bool,_ message:String)throws {
  if !condition{throw ProfileError.invalid(message)}
 }
 static func reject(_ message:String,_ operation:()throws->Void)throws {
  do {try operation()}catch{return}
  throw ProfileError.invalid(message)
 }
 /// Parse the published text independently of the exporter.
 static func parse(_ data:Data)throws->[Double] {
  var nodes=[Double](),titles=0,sizes=0,minimums=0,maximums=0
  for line in String(decoding:data,as:UTF8.self).split(separator:"\n") {
   if line.hasPrefix("#"){continue}
   if line.hasPrefix("TITLE "){titles+=1;continue}
   if line=="LUT_3D_SIZE 33"{sizes+=1;continue}
   if line=="DOMAIN_MIN 0.0 0.0 0.0"{minimums+=1;continue}
   if line=="DOMAIN_MAX 1.0 1.0 1.0"{maximums+=1;continue}
   let values=line.split(whereSeparator:{$0.isWhitespace}).compactMap{Double($0)}
   try check(values.count==3 && values.allSatisfy{$0.isFinite && (0...1).contains($0)},"Invalid cube row")
   nodes+=values
  }
  try check(titles==1 && sizes==1 && minimums==1 && maximums==1 && nodes.count==33*33*33*3,"Invalid cube headers or node count")
  return nodes
 }
 static func oracle(_ recipe:Recipe,_ compiler:ProfileCompiler,_ input:[UInt8],width:Int)throws->[UInt8] {
  var body=try compiler.compile(recipe,requireAcknowledgement:false).body
  // Independently disable the wire-format grain amount; all colour words remain intact.
  body.put32(0,768+32*4)
  var out=[UInt8](repeating:0,count:input.count)
  let rc=body.withUnsafeBytes{b in input.withUnsafeBufferPointer{i in out.withUnsafeMutableBufferPointer{o in
   cfp_render_effects(b.bindMemory(to:UInt8.self).baseAddress,i.baseAddress,Int32(width),Int32(input.count/3/width),0,0,0,recipe.effectiveBWFilter?.enabled == true ? 1:0,o.baseAddress)
  }}}
  try check(rc==0,"Oracle rendering failed")
  return out
 }
 static func interpolate(_ nodes:[Double],_ rgb:ArraySlice<UInt8>,_ c:Int)->Double {
  let p=rgb.map{Double($0)*32/255},lo=p.map{min(31,Int($0))},f=(0..<3).map{p[$0]-Double(lo[$0])}
  var result=0.0
  for b in 0...1 {for g in 0...1 {for r in 0...1 {
   let weight=(r==0 ? 1-f[0]:f[0])*(g==0 ? 1-f[1]:f[1])*(b==0 ? 1-f[2]:f[2])
   result+=nodes[((lo[2]+b)*1089+(lo[1]+g)*33+lo[0]+r)*3+c]*weight
  }}}
  return result*255
 }
 static func main()throws {
  setbuf(stdout,nil)
  let app=URL(fileURLWithPath:CommandLine.arguments[1]),compiler=try ProfileCompiler(factoryBook:Data(contentsOf:app.appendingPathComponent("Resources/CFLOOKS.BIN")))
  var recipes=[Recipe.portra160]
  if CommandLine.arguments.count>2 {recipes=try RecipeLibrary.load(from:URL(fileURLWithPath:CommandLine.arguments[2])).recipes}
  var signed=Recipe();signed.name="Signed mono tone";signed.base="BW Monotone";signed.bwFilter=BWFilter(red:120,green:-10,blue:-10);signed.toning = .sepia;signed.grainSettings=RecipeGrain(intensity:3)
  var factory=Recipe();factory.name="Factory grain";factory.factoryID=1002
  recipes += [signed,factory]
  var grid=[UInt8]();grid.reserveCapacity(33*33*33*3)
  for index in 0..<(33*33*33) {
   for coordinate in [index%33,(index/33)%33,index/1089] {grid.append(UInt8((Double(coordinate)*255/32).rounded()))}
  }
  var random=[UInt8](),seed:UInt32=0x63414e4f
  for _ in 0..<(4096*3){seed=seed &* 1664525 &+ 1013904223;random.append(UInt8(truncatingIfNeeded:seed>>24))}
  for recipe in recipes {
   let before=recipe,data=try CubeLUTExporter.cube(for:recipe,compiler:compiler),nodes=try parse(data)
   let expected=try oracle(recipe,compiler,grid,width:33)
   try check(zip(nodes,expected).allSatisfy{abs($0.0-Double($0.1)/255)<=0.00000051},"Grid parity or RGB ordering failed for \(recipe.name)")
   try check(before==recipe,"Recipe mutated")
   try check(data == CubeLUTExporter.cube(for:recipe,compiler:compiler),"Non-deterministic LUT export")
   var spatial=recipe;spatial.shading=4;spatial.sharpness = -4;spatial.clarity=4;spatial.grain=3;spatial.grainSettings=RecipeGrain(intensity:3,size:3)
   // Comments are identical because name/id/revision are unchanged.
   try check(data == CubeLUTExporter.cube(for:spatial,compiler:compiler),"Spatial effects leaked into LUT")
   let reference=try oracle(recipe,compiler,random,width:64)
   var errors=[Double]();errors.reserveCapacity(reference.count)
   for i in 0..<4096 {for c in 0..<3 {errors.append(abs(interpolate(nodes,random[(i*3)..<(i*3+3)],c)-Double(reference[i*3+c])))}}
   errors.sort();let mean=errors.reduce(0,+)/Double(errors.count),p99=errors[Int(Double(errors.count-1)*0.99)],maximum=errors.last!
   try check(mean<4 && p99<16,"Unexpected interpolation error for \(recipe.name)")
   print(String(format:"PASS %@: 35,937 nodes match renderer; interpolation mean %.3f, p99 %.3f, max %.3f / 255",recipe.name,mean,p99,maximum))
  }
  var filtered=signed;filtered.toning = .off
  let filteredNodes=try parse(CubeLUTExporter.cube(for:filtered,compiler:compiler))
  try check(stride(from:0,to:filteredNodes.count,by:3).allSatisfy{filteredNodes[$0]==filteredNodes[$0+1] && filteredNodes[$0]==filteredNodes[$0+2]},"Un-toned monochrome is not neutral")
  filtered.bwFilter = .off
  try check(filteredNodes != parse(CubeLUTExporter.cube(for:filtered,compiler:compiler)),"Signed mixer ignored")
  var manual=Recipe.portra160;manual.wbPolicy="Set on camera"
  let manualNodes=try parse(CubeLUTExporter.cube(for:manual,compiler:compiler))
  manual.whiteBalance="Tungsten";manual.amberBlue = -14;manual.greenMagenta=14
  try check(manualNodes == parse(CubeLUTExporter.cube(for:manual,compiler:compiler)),"Manual camera WB double-applied")
  manual.wbPolicy="Creative tint"
  try check(manualNodes != parse(CubeLUTExporter.cube(for:manual,compiler:compiler)),"Creative WB tint missing")
  let temp=FileManager.default.temporaryDirectory.appendingPathComponent("lut-checks-"+UUID().uuidString,isDirectory:true)
  try FileManager.default.createDirectory(at:temp,withIntermediateDirectories:false)
  defer{try? FileManager.default.removeItem(at:temp)}
  var quoted=Recipe.portra160;quoted.name="../ \"same\" /";var duplicate=quoted;duplicate.id=UUID()
  let library=RecipeLibrary(recipes:[quoted,duplicate],slots:[quoted.id,nil,duplicate.id]),libraryURL=temp.appendingPathComponent("Recipes.json")
  try library.save(to:libraryURL);let original=try Data(contentsOf:libraryURL),destination=temp.appendingPathComponent("Export")
  let entries=try CubeLUTExporter.export(library.recipes,compiler:compiler,to:destination)
  try check(entries.count==2 && Set(entries.map(\.file)).count==2,"Duplicate names collided")
  let manifest=try JSONDecoder().decode(CubeLUTExporter.Manifest.self,from:Data(contentsOf:destination.appendingPathComponent("Manifest.json")))
  try check(manifest.lutSize==33 && manifest.looks.map(\.recipe)==library.recipes,"Manifest lost recipe values")
  for entry in entries {
   try check(!entry.file.contains("/") && !entry.file.contains(".."),"Unsafe export filename")
   let bytes=try Data(contentsOf:destination.appendingPathComponent(entry.file));_=try parse(bytes)
   try check(entry.sha256==SHA256.hash(data:bytes).map{String(format:"%02x",$0)}.joined(),"Manifest hash mismatch")
  }
  let prior=try Data(contentsOf:destination.appendingPathComponent(entries[0].file))
  try reject("Existing export overwritten"){_ = try CubeLUTExporter.export([quoted],compiler:compiler,to:destination)}
  try check(prior == Data(contentsOf:destination.appendingPathComponent(entries[0].file)),"Existing file changed")
  try reject("Empty library exported"){_ = try CubeLUTExporter.export([],compiler:compiler,to:temp.appendingPathComponent("Empty"))}
  var invalid=quoted;invalid.hue=99
  let failed=temp.appendingPathComponent("Failed")
  try reject("Invalid look exported"){_ = try CubeLUTExporter.export([quoted,invalid],compiler:compiler,to:failed)}
  try check(!FileManager.default.fileExists(atPath:failed.path),"Partial export published")
  try check(!(try FileManager.default.contentsOfDirectory(atPath:temp.path)).contains{$0.hasPrefix(".canon-luts-")},"Staging folder leaked")
  try check(original == Data(contentsOf:libraryURL) && library == RecipeLibrary.load(from:libraryURL),"Source library or slots changed")
  print("PASS signed monochrome, toning, camera/creative WB, spatial exclusions, deterministic exports, safe duplicate filenames, manifest hashes, unchanged library/slots and failed-export preservation")
 }
}
