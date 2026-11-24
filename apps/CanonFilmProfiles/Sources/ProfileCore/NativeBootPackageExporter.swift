import Foundation
import CryptoKit
import Darwin

/// A separate export interface for the capture-local native backend. It never opens a device.
public enum NativeBootPackageExporter {
 public static let interface = "native-embedded-profile-bank-v1"
 public static let templateFile = "NativeProfileTemplate.BIN"
 // Replaced only when a newly reviewed runtime template is built, never read from a manifest.
 public static let templateSHA256 = "e2cd67459175da56fbb615c8cbdd8fbda7ffa38f52db1867921682ceaf131675"
 public static let imageBytes = 130280
 public static let bankOffset = 0x2600
 public static let descriptorOffset = 0x3dc0
 public static let remainingOffset = 0x3f04
 private static func sha(_ data: Data) -> String { SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined() }
 private static func read32(_ data:Data,_ offset:Int)->UInt32 {
  (0..<4).reduce(UInt32(0)){$0 | UInt32(data[offset+$1]) << (8*$1)}
 }
 private static func put32(_ data:inout Data,_ offset:Int,_ value:UInt32) {
  for i in 0..<4 {data[offset+i]=UInt8(truncatingIfNeeded:value >> (8*i))}
 }
 private static func encoded<T:Encodable>(_ value:T)throws->Data {
  let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys,.withoutEscapingSlashes]
  var result=try encoder.encode(value);result.append(10);return result
 }
 /// The compile result must come from the native authoring compiler, never the Effects packer.
 public static func files(compiled:NativeCompiledExport,template:Data)throws->[String:Data] {
  guard template.count==imageBytes,sha(template)==templateSHA256 else {
   throw ProfileError.invalid("The bundled native runtime template is missing or does not match this app. Effects export remains available.")
  }
  try NativeRecipeCompiler.validate(sidecar:compiled.sidecar)
  let report=compiled.report
  guard (0...8).contains(report.attemptLimit),report.physicalQualification==false,report.bootable==false else {
   throw ProfileError.invalid("Invalid native authoring report.")
  }
  guard report.schema==1,report.slots.count==3 else{throw ProfileError.invalid("Native report slot inventory is invalid.")}
  var enabledCount=0
  for slot in 0..<3 {
   let offset=32+slot*160,row=report.slots[slot]
   let enabled=compiled.sidecar[offset+22]==1
   guard row.slotIndex==slot,row.nativeRecipeID==UInt32(61001+slot),row.enabled==enabled else {
    throw ProfileError.invalid("Native report and table slot identities differ.")
   }
   if enabled {
    enabledCount+=1
    let bytes=compiled.sidecar
    let tuple=NativeCanonTuple(sharpness:Int(bytes[offset+26]),contrast:Int(Int8(bitPattern:bytes[offset+27])),
       saturation:Int(Int8(bitPattern:bytes[offset+28])),tone:Int(Int8(bitPattern:bytes[offset+29])),
       whiteBalance:bytes[offset+30]==0 ? .auto:.daylight,
       amberBlue:Int(Int8(bitPattern:bytes[offset+31])),greenMagenta:Int(Int8(bitPattern:bytes[offset+32])))
    guard row.sourceRevision==read32(bytes,offset+4),row.tupleDigest==tuple.canonicalDigest,row.approvalCurrent else {
     throw ProfileError.invalid("Native approval report does not describe the exact enabled tuple and revision.")
    }
   }
  }
  guard enabledCount==report.enabledRecordCount else{throw ProfileError.invalid("Native enabled-slot count differs from its report.")}
  let cap=report.attemptLimit,id=report.selectedNativeRecipeID
  if cap==0 {
   guard id==0 else{throw ProfileError.invalid("An OFF package must have no effective startup recipe.")}
  } else {
   guard (61001...61003).contains(id),report.approvalCurrent,
         report.selectedSlot==Int(id-61001) else {
    throw ProfileError.invalid("Choose a current, approved native slot before exporting an active package.")
   }
   let selectedRow=report.slots[Int(id-61001)]
   guard report.sourceRecipeID==selectedRow.sourceRecipeID,report.sourceRevision==selectedRow.sourceRevision,
         report.sourceDigest==selectedRow.sourceDigest,report.authoredRecipeDigest==selectedRow.authoredRecipeDigest,
         report.tupleDigest==selectedRow.tupleDigest,report.mappingVersion==selectedRow.mappingVersion,
         report.differences==selectedRow.differences else {
    throw ProfileError.invalid("Native selected approval summary differs from its slot record.")
   }
   let offset=32+Int(id-61001)*160
   guard read32(compiled.sidecar,offset)==id,compiled.sidecar[offset+22]==1 else {
    throw ProfileError.invalid("The selected native slot is not enabled in the compiled table.")
   }
  }
  var image=template
  image.replaceSubrange(bankOffset..<bankOffset+512,with:compiled.sidecar)
  put32(&image,descriptorOffset+8,id)
  put32(&image,descriptorOffset+12,UInt32(cap))
  put32(&image,descriptorOffset+16,read32(compiled.sidecar,28))
  put32(&image,remainingOffset,UInt32(cap))
  // Normalize every configurable byte back to the pinned template. No other code/data change is allowed.
  var normalized=image
  for range in [bankOffset..<bankOffset+512,descriptorOffset+8..<descriptorOffset+20,remainingOffset..<remainingOffset+4] {
   normalized.replaceSubrange(range,with:template.subdata(in:range))
  }
  guard sha(normalized)==templateSHA256 else{throw ProfileError.invalid("Native runtime normalization failed.")}
  let authoring=try encoded(report)
  let bodies:[String:Data]=["AUTOEXEC.BIN":image,"CNATIV.BIN":compiled.sidecar,"native-authoring.json":authoring]
  let inventory=bodies.keys.sorted().map { name in
   ["name":name,"bytes":bodies[name]!.count,"sha256":sha(bodies[name]!)] as [String:Any]
  }
  let profiles:[[String:Any]]=(0..<3).map { slot in
   let offset=32+slot*160
   var value:[String:Any]=["slot":slot,"nativeRecipeID":61001+slot,"enabled":compiled.sidecar[offset+22]==1]
   if compiled.sidecar[offset+22]==1 {
    let bytes=compiled.sidecar
    let label=bytes.subdata(in:offset+36..<offset+60).prefix{ $0 != 0 }
    value["name"]=String(decoding:label,as:UTF8.self)
    value["canonTuple"]=["style":"Standard","whiteBalance":bytes[offset+30]==0 ? "Auto":"Daylight",
       "sharpness":Int(bytes[offset+26]),"contrast":Int(Int8(bitPattern:bytes[offset+27])),
       "saturation":Int(Int8(bitPattern:bytes[offset+28])),"colourTone":Int(Int8(bitPattern:bytes[offset+29])),
       "amberBlue":Int(Int8(bitPattern:bytes[offset+31])),"greenMagenta":Int(Int8(bitPattern:bytes[offset+32]))]
   }
   return value
  }
  let manifest:[String:Any]=[
   "schema":4,"interface":interface,"backend":"NativeOnly",
   "target":["model":"Canon EOS 450D / Rebel XSi","firmware":"1.1.0"],
   "qualification":"OFFLINE_ONLY_REQUIRES_REVIEWED_PHYSICAL_TRIAL",
   "runtimeTemplateSHA256":templateSHA256,"files":inventory,"profiles":profiles,
   "operatorPreconditions":["Canon Standard","Single","RAW + Large/Fine JPEG","sRGB","HTP off","WB bracketing off","Mirror lockup off"],
   "configuration":["selectedNativeRecipeID":id,"attemptLimit":cap,"generation":1,
      "sidecarFNV1a32":read32(compiled.sidecar,28),"bankOffset":bankOffset,
      "descriptorOffset":descriptorOffset,"remainingOffset":remainingOffset],
   "execution":["tableSource":"embedded immutable copy of CNATIV.BIN",
      "startupSidecarRead":false,"selection":"host-selected startup preset",
      "globalCanonSettingsChanged":false,"customPixelRendering":false,
      "attemptLimitIsCameraShotLimit":false,"freshBootReloadsBudget":true,
      "runtimeRearm":false,"onCameraPresetMenu":false],
   "deployment":"Export only; this app does not install native packages."
  ]
  var files=bodies
  var manifestData=try JSONSerialization.data(withJSONObject:manifest,options:[.prettyPrinted,.sortedKeys,.withoutEscapingSlashes]);manifestData.append(10)
  files["manifest.json"]=manifestData
  return files
 }
 /// Creates a new package folder. Existing files, cards and the legacy Effects installer are untouched.
 @discardableResult public static func export(compiled:NativeCompiledExport,template:Data,to folder:URL)throws->URL {
  guard folder.isFileURL else{throw ProfileError.invalid("Choose a local export folder.")}
  let bodies=try files(compiled:compiled,template:template)
  let destination=folder.standardizedFileURL
  guard mkdir(destination.path,0o700)==0 else{throw ProfileError.invalid("Choose a new, unused native package folder.")}
  // Publish the manifest last. A partial export has no complete package manifest.
  for name in ["AUTOEXEC.BIN","CNATIV.BIN","native-authoring.json","manifest.json"] {
   try bodies[name]!.write(to:destination.appendingPathComponent(name),options:.withoutOverwriting)
  }
  return destination
 }
}
