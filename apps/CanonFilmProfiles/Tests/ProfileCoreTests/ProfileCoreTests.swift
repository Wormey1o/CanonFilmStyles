import Foundation
import Darwin
import ProfileCore
func check(_ value:Bool,_ message:String="Check failed",file:StaticString=#filePath,line:UInt=#line){if !value{fatalError("\(message) at \(file):\(line)")}}
func XCTAssertEqual<T:Equatable>(_ a:T,_ b:T,_ message:String=""){check(a==b,message)}
func XCTAssertEqual(_ a:Double,_ b:Double,accuracy:Double){check(abs(a-b)<=accuracy)}
func XCTAssertThrowsError<T>(_ body:@autoclosure ()throws->T){do{_ = try body();fatalError("Expected rejection")}catch{}}
@main struct ProfileCoreTests {
 var book:Data {try! Data(contentsOf:URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/CFLOOKS.BIN"))}
 func testPortraRetainsUnsupportedAndRequiresAcknowledgement()throws {
  let c=try ProfileCompiler(factoryBook:book);var r=Recipe.portra160
  XCTAssertEqual(r.omissions,[]);_ = try c.compile(r);r.allowPartial=true
  let p=try c.compile(r);XCTAssertEqual(p.body.count,904);XCTAssertEqual(r.clarity,-4);XCTAssertEqual(r.cameraShortName,"Portra 160")
  XCTAssertEqual(c.masterCurve(r).map{$0.1},[12,33,51,82,112,143,176,206,230,240,249])
  XCTAssertEqual(c.gains(r)[0],1.0671,accuracy:0.0001)
  var lib=RecipeLibrary(recipes:[r]);lib.slots[0]=r.id;let pack=try c.pack(lib);XCTAssertEqual(pack.count,2896);try ProfileCompiler.validatePack(pack)
  var corrupt=pack;corrupt[100]^=1;XCTAssertThrowsError(try ProfileCompiler.validatePack(corrupt))
 }
 func testFactoryCopiesAreByteIdentical()throws {
  let c=try ProfileCompiler(factoryBook:book)
  for id in Recipe.factoryNames.keys {var r=Recipe();r.factoryID=id;r.grain=nil;let a=try c.compile(r);XCTAssertEqual(a.body,try c.factoryBody(id),"Factory \(id)")}
 }
 func testAllControlsBounded()throws {
  let c=try ProfileCompiler(factoryBook:book)
  for base in Recipe.bases {for step in [-4,0,4] {var r=Recipe();r.base=base;r.allowPartial=true;r.saturation=step;r.hue=step;r.key=step;r.contrast=step;r.highlights=step;r.shadows=step;r.amberBlue=step>0 ? 14:-14;r.greenMagenta=14;r.grain=3;try ProfileCompiler.validateBody(c.compile(r).body)}}
 }
 func testSetOnCameraDoesNotDoubleApplyWB()throws {let c=try ProfileCompiler(factoryBook:book);var r=Recipe.portra160;r.wbPolicy="Set on camera";XCTAssertEqual(c.gains(r),[1,1,1])}
 func testUnsafeScalarRejected()throws {let c=try ProfileCompiler(factoryBook:book);var d=try c.factoryBody(1001);d.put32(1,768+26*4);XCTAssertThrowsError(try ProfileCompiler.validateBody(d))}
 func testLibraryRoundTrip()throws {let a=RecipeLibrary();let b=try JSONDecoder().decode(RecipeLibrary.self,from:JSONEncoder().encode(a));XCTAssertEqual(a,b)}
 func testLibraryFileSizePolicy() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent("recipe-size-" + UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
  defer { try? FileManager.default.removeItem(at: directory) }
  let url = directory.appendingPathComponent("Recipes.json")

  var recipe = Recipe()
  recipe.notes = String(repeating: "a", count: 1_048_576)
  let legacy = RecipeLibrary(recipes: [recipe], slots: [recipe.id, nil, nil])
  let legacyBytes = try JSONEncoder().encode(legacy)
  check(legacyBytes.count > 1_048_576)
  try legacyBytes.write(to: url)
  XCTAssertEqual(try RecipeLibrary.load(from: url), legacy)
  try legacy.save(to: url)
  XCTAssertEqual(try RecipeLibrary.load(from: url), legacy)
  let saved = try Data(contentsOf: url)

  recipe.notes = String(repeating: "b", count: 32 * 1024 * 1024)
  let oversized = RecipeLibrary(recipes: [recipe])
  XCTAssertThrowsError(try oversized.save(to: url))
  XCTAssertEqual(try Data(contentsOf: url), saved)
  let handle = try FileHandle(forWritingTo: url)
  try handle.truncate(atOffset: 32 * 1024 * 1024 + 1)
  try handle.close()
  XCTAssertThrowsError(try RecipeLibrary.load(from: url))
  print("PASS library size policy, legacy recovery and preservation on failed save")
 }
 func testCardTransactions()throws {
  let dir=URL(fileURLWithPath:"/private/tmp/canon-profile-check-"+UUID().uuidString);try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:dir)}
  let url=dir.appendingPathComponent("owned-fixture.raw"),total=UInt64(65537*512)
  FileManager.default.createFile(atPath:url.path,contents:nil);let handle=try FileHandle(forWritingTo:url);try handle.truncate(atOffset:total);try handle.close()
  let io=try BlockFile(path:url.path,writable:true,bytes:total)
  var mbr=Data(count:512);mbr[450]=6;mbr.put32(1,454);mbr.put32(65536,458);mbr[510]=85;mbr[511]=170;try io.write(0,mbr)
  var boot=Data(count:512);boot.put16(512,11);boot[13]=8;boot.put16(1,14);boot[16]=2;boot.put16(512,17);boot.put32(65536,32);boot.put16(32,22);boot.replaceSubrange(64..<72,with:Data("BOOTDISK".utf8));boot[510]=85;boot[511]=170;try io.write(512,boot)
  var fat=Data(count:16384);fat.put16(0xfff8,0);fat.put16(0xffff,2);var root=Data(count:16384),cluster=2
  let fw=Data(repeating:0x5a,count:130640),photo=Data("ORIGINAL PHOTO SENTINEL".utf8)
  for (slot,pair) in [("AUTOEXECBIN",fw),("CFLOOKS BIN",book),("IMG_0001JPG",photo)].enumerated(){let (name,body)=pair,n=(body.count+4095)/4096;root.replaceSubrange(slot*32..<slot*32+11,with:Data(name.utf8));root[slot*32+11]=32;root.put16(UInt16(cluster),slot*32+26);root.put32(UInt32(body.count),slot*32+28);for j in 0..<n{fat.put16(j==n-1 ? 0xffff:UInt16(cluster+j+1),(cluster+j)*2)};try io.write(UInt64(98*512+(cluster-2)*4096),body);cluster+=n}
  try io.write(1024,fat);try io.write(34*512,fat);try io.write(66*512,root)
  let compiler=try ProfileCompiler(factoryBook:book);var r=Recipe();r.factoryID=1002;r.name="Mac Kodachrome";r.shortName="Mac Chrome";var lib=RecipeLibrary(recipes:[r]);lib.slots[0]=r.id;let pack=try compiler.pack(lib)
  let before=try CanonCard(disk:io),old=sha256(fw),updated=Data(repeating:0xa5,count:130640)
  XCTAssertThrowsError(try before.plan(profile:pack,firmware:updated,acceptedFirmware:[]))
  let plan=try before.plan(profile:pack,firmware:updated,acceptedFirmware:[old]);check(plan.count>=5);let photoEntry=before.entries["IMG_0001.JPG"]!
  try before.apply(plan)
  let after=try CanonCard(disk:io);XCTAssertEqual(try after.contents("CUPROF.BIN",maximum:2896),pack);XCTAssertEqual(try after.contents("AUTOEXEC.BIN",maximum:131072),updated);XCTAssertEqual(try after.contents("IMG_0001.JPG",maximum:100),photo);XCTAssertEqual(after.entries["IMG_0001.JPG"]!.clusters,photoEntry.clusters)
  let noChanges=try after.plan(profile:pack,firmware:nil,acceptedFirmware:[sha256(updated)]);check(noChanges.isEmpty)
  r.saturation=2;lib.recipes=[r];let changed=try compiler.pack(lib),update=try after.plan(profile:changed,firmware:nil,acceptedFirmware:[sha256(updated)]);check(update.count==1 && update[0].purpose=="Update user profiles");try after.apply(update)
  let fresh=try CanonCard(disk:io),stale=try fresh.plan(profile:pack,firmware:nil,acceptedFirmware:[sha256(updated)]);var altered=try io.read(stale[0].offset,4096);altered[3000]^=1;try io.write(stale[0].offset,altered);XCTAssertThrowsError(try fresh.apply(stale))
  var broken=fresh.fat;broken[400]^=1;try io.write(34*512,broken);XCTAssertThrowsError(try CanonCard(disk:io))
  // Restore the FAT mirror before exercising the actual transaction receipt path on this image.
  try io.write(34*512,fresh.fat)
  io.close()
  let uploadIO=try BlockFile(path:url.path,writable:true,bytes:total)
  let nextFirmware=Data(repeating:0x3c,count:130640)
  let support=FirmwareSupport(payloadSHA256:sha256(nextFirmware),acceptedPreviousSHA256:[sha256(updated)])
  let device=CameraCardDevice(id:"owned-image",label:"Owned fixture",bytes:total,partition:"",volumeUUID:"",deviceTree:"")
  let req=UploadRequest(device:device,profiles:pack)
  var deviceChecked=false
  do {
   _ = try CardDeployment.performOnPreparedCard(req,support:support,firmware:nextFirmware,disk:uploadIO,
          backupDirectory:nil,verifyDevice:{
     XCTAssertThrowsError(try uploadIO.read(0,512))
     deviceChecked=true
    },ejectDevice:{throw ProfileError.invalid("Simulated eject failure")})
   fatalError("Expected the simulated eject to fail")
  } catch let failure as UploadFailure {
   let receipt=failure.receipt
   XCTAssertEqual(receipt.status,"FAIL")
   XCTAssertEqual(receipt.phase,.eject)
   check(deviceChecked && receipt.verified && receipt.firmwareInstalled && !receipt.ejected && receipt.writeCount>0)
  }
  let readOnly=try BlockFile(path:url.path,writable:false,bytes:total)
  let verified=try CanonCard(disk:readOnly)
  XCTAssertEqual(try verified.contents("AUTOEXEC.BIN",maximum:131072),nextFirmware)
  XCTAssertEqual(try verified.contents("CUPROF.BIN",maximum:2896),pack)
  let noisy=try ProcessOutput.capture(executable:URL(fileURLWithPath:"/bin/sh"),
      arguments:["-c","/bin/dd if=/dev/zero bs=131072 count=1 >&2; /bin/dd if=/dev/zero bs=131072 count=1; exit 7"])
  XCTAssertEqual(noisy.status,7)
  check(noisy.stdout.count==131072 && noisy.stderr.count>131072,"Both diagnostic streams must drain.")
  print("PASS verified image upload retains readback on eject failure, and subprocess captures both streams")
  // This exact Mac-generated pack is exercised by the ARM reader and pipeline.
  let output=ProcessInfo.processInfo.environment["CANON_CHECK_OUTPUT"] ?? "/private/tmp/canon-profile-check-output";let out=URL(fileURLWithPath:output);try FileManager.default.createDirectory(at:out,withIntermediateDirectories:true);try pack.write(to:out.appendingPathComponent("CUPROF.BIN"));lib.recipes[0].saturation=0;try lib.save(to:out.appendingPathComponent("Recipes.json"));try compiler.compile(Recipe.portra160,requireAcknowledgement:false).body.write(to:out.appendingPathComponent("Portra160.look"))
 }

 static func main() throws {
  let checks = Self()
  #if CANON_PRIVATE_RUNTIME_CHECKS
  try checks.testWorkingCard()
  try checks.testPairedRuntimeRollback()
  #endif
  try checks.testReferenceEffects()
  try checks.testV3PackAndTrial()
  try checks.testPortraRetainsUnsupportedAndRequiresAcknowledgement()
  try checks.testFactoryCopiesAreByteIdentical()
  try checks.testAllControlsBounded()
  try checks.testSetOnCameraDoesNotDoubleApplyWB()
  try checks.testUnsafeScalarRejected()
  try checks.testLibraryRoundTrip()
  try checks.testLibraryFileSizePolicy()
  try checks.testCardTransactions()
  print("PASS compiler, profile validation, factory parity, library and bounded FAT upload checks")
 }

}
