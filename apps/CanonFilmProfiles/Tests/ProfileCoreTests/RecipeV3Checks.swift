import Foundation
import ProfileCore

extension ProfileCoreTests {
 func testV3PackAndTrial()throws {
  let c=try ProfileCompiler(factoryBook:book)
  var spatial=Recipe();spatial.name="Spatial Test";spatial.shortName="Spatial Test";spatial.shading = -4;spatial.sharpness=4;spatial.clarity = -4
  var mono=Recipe();mono.name="Mono Mixer";mono.shortName="Mono Mixer";mono.base="BW Monotone";mono.bwFilter=BWFilter.references[3];mono.toning = .sepia;mono.grainSettings=RecipeGrain(intensity:1);mono.allowPartial=true;mono.shading = -2;mono.sharpness=2;mono.clarity = -2
  var neutral=Recipe();neutral.name="Neutral Check";neutral.shortName="Neutral Check";neutral.factoryID=1002
  let lib=RecipeLibrary(recipes:[spatial,mono,neutral],slots:[spatial.id,mono.id,neutral.id]),pack=try c.pack(lib)
  XCTAssertEqual(pack.count,2896);XCTAssertEqual(pack.u32(4),3)
  let flags=pack.u16(16+960+2);check(flags&8 != 0,"Mixer flag missing");XCTAssertEqual((flags>>4)&15,2);XCTAssertEqual((flags>>8)&15,6);XCTAssertEqual((flags>>12)&15,2)
  let body=try c.compile(mono).body
  for (i,value) in [120,-10,-10].enumerated(){XCTAssertEqual(Int32(bitPattern:body.u32(768+(29+i)*4)),Int32(value))}
  func reseal(_ data:Data)->Data {var p=data;for s in 0..<3 {let a=16+s*960;var r=p.subdata(in:a..<a+960);if r.u16(2)&1 != 0 {r.put32(r.subdata(in:56..<960).fnv32(),8)};r.put32((r.subdata(in:0..<52)+r.subdata(in:56..<960)).fnv32(),52);p.replaceSubrange(a..<a+960,with:r)};return p}
  for (name,offset,value) in [("coefficient",16+960+56+768+29*4,201),("SAT",16+960+56+768,1),("halation",16+960+56+768+26*4,1)] {
   var invalid=pack;invalid.put32(UInt32(value),offset);XCTAssertThrowsError(try ProfileCompiler.validatePack(reseal(invalid)));print("PASS resealed v3 rejection:",name)
  }
  var clear=pack;clear.put16(flags & ~8,16+960+2);XCTAssertThrowsError(try ProfileCompiler.validatePack(reseal(clear)))
  var nibble=pack;nibble.put16((pack.u16(18)&0xff0f)|0x90,18);XCTAssertThrowsError(try ProfileCompiler.validatePack(reseal(nibble)))
  // Legacy records preserve their original admitted flags and render path.
  for version in [1,2] {
   var legacy=try c.pack(RecipeLibrary(recipes:[neutral],slots:[neutral.id,nil,nil]));legacy.put32(UInt32(version),4);legacy.put16(version==1 ? 5:0x4445,18);try ProfileCompiler.validatePack(reseal(legacy))
  }
  let folder=URL(fileURLWithPath:ProcessInfo.processInfo.environment["CANON_EFFECTS_CHECK_OUTPUT"] ?? "/private/tmp/canon-effects-v3");try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
  try pack.write(to:folder.appendingPathComponent("CUPROF.BIN"));try lib.save(to:folder.appendingPathComponent("TrialRecipes.json"))
  try FileManager.default.createDirectory(at:folder.appendingPathComponent("compiled-fixtures"),withIntermediateDirectories:true)
  try body.write(to:folder.appendingPathComponent("compiled-fixtures/mixer-toned-grain.look"))
  print("PASS v3 flags, sealed signed-coefficient bounds, legacy versions and isolated trial profile pack")
 }
}
