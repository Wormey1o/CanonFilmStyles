import Foundation
import Darwin
public struct CameraCardDevice: Codable, Identifiable, Equatable, Sendable {
 public var id:String
 public var label:String
 public var bytes:UInt64
 public var partition:String
 public var volumeUUID:String
 public var deviceTree:String
 public init(id:String,label:String,bytes:UInt64,partition:String,volumeUUID:String,deviceTree:String) {self.id=id;self.label=label;self.bytes=bytes;self.partition=partition;self.volumeUUID=volumeUUID;self.deviceTree=deviceTree}
 public var displayName:String {"\(label) · \(ByteCountFormatter.string(fromByteCount:Int64(bytes),countStyle:.decimal))"}
}
public enum DiskUtility {
 public static func run(_ args:[String])throws->Data {
  let output = try ProcessOutput.capture(executable: URL(fileURLWithPath: "/usr/sbin/diskutil"), arguments: args)
  guard output.status == 0 else {
   let message = String(decoding: output.stderr + output.stdout, as: UTF8.self)
   throw ProfileError.invalid("diskutil \(args.joined(separator: " ")) exited \(output.status): \(message)")
  }
  return output.stdout
 }
 public static func info(_ id:String)throws->[String:Any] {
  guard id.range(of:"^disk[0-9]+(s[0-9]+)?$",options:.regularExpression) != nil else {throw ProfileError.invalid("Invalid card device identifier.")}
  return try PropertyListSerialization.propertyList(from:run(["info","-plist",id]),format:nil) as? [String:Any] ?? [:]
 }
 public static func devices()throws->[CameraCardDevice] {
  let root=try PropertyListSerialization.propertyList(from:run(["list","-plist","external","physical"]),format:nil) as? [String:Any] ?? [:]
  var result:[CameraCardDevice]=[]
  for d in root["AllDisksAndPartitions"] as? [[String:Any]] ?? [] {
   guard let id=d["DeviceIdentifier"] as? String,let size=d["Size"] as? NSNumber,size.uint64Value>=16_000_000,size.uint64Value<=8_000_000_000 else {continue}
   let whole=try info(id);guard whole["Internal"] as? Bool != true else {continue}
   for p in d["Partitions"] as? [[String:Any]] ?? [] {
    guard let part=p["DeviceIdentifier"] as? String,(p["Content"] as? String ?? "").contains("FAT") else {continue}
    let pi=try info(part);result.append(CameraCardDevice(id:id,label:(whole["MediaName"] as? String) ?? "SD card",bytes:size.uint64Value,partition:part,volumeUUID:pi["VolumeUUID"] as? String ?? "",deviceTree:whole["DeviceTreePath"] as? String ?? ""))
   }
  };return result
 }
 public static func verify(_ device:CameraCardDevice)throws {
  let w=try info(device.id),p=try info(device.partition)
  guard w["Internal"] as? Bool != true,(w["TotalSize"] as? NSNumber)?.uint64Value==device.bytes,(w["DeviceTreePath"] as? String ?? "")==device.deviceTree,(p["VolumeUUID"] as? String ?? "")==device.volumeUUID else {throw ProfileError.invalid("The selected card or reader changed. Rescan the cards.")}
  guard w["WritableMedia"] as? Bool != false,w["ReadOnlyMedia"] as? Bool != true else {throw ProfileError.invalid("The SD card is write-protected.")}
 }
}
public struct FirmwareSupport: Codable, Sendable {
 public var schema:Int
 public var target:String
 public var payloadSHA256:String
 public var acceptedPreviousSHA256:[String]
 public var workingInstallation:Bool? = nil
 public var factoryBookSHA256:String? = nil
 public var payloadFile:String
 public init(schema:Int=1,target:String="Canon EOS 450D 1.1.0",payloadSHA256:String,acceptedPreviousSHA256:[String],payloadFile:String="AUTOEXEC.BIN") {self.schema=schema;self.target=target;self.payloadSHA256=payloadSHA256;self.acceptedPreviousSHA256=acceptedPreviousSHA256;self.payloadFile=payloadFile}
}
public struct UploadRequest: Codable, Sendable {
 public var schema=1
 public var device:CameraCardDevice
 public var profiles:Data
 public var prepareWorkingInstallation:Bool? = nil
 public var installSupport:Bool
 public var eject:Bool
 public init(device:CameraCardDevice,profiles:Data,installSupport:Bool=true,eject:Bool=true){self.device=device;self.profiles=profiles;self.installSupport=installSupport;self.eject=eject}
}
public enum UploadPhase: String, Codable, Sendable {
 case preflight, write, readback, cleanup, verifyDevice, eject, complete
}

public struct UploadReceipt: Codable, Sendable {
 public var status:String
 public var device:String
 public var profileSHA256:String
 public var firmwareSHA256:String
 public var firmwareInstalled:Bool
 public var writeCount:Int
 public var verified:Bool
 public var ejected:Bool
 public var message:String
 /// Optional for compatibility with receipts written by older app builds.
 public var phase:UploadPhase?
 public init(status:String,device:String,profileSHA256:String,firmwareSHA256:String,firmwareInstalled:Bool,writeCount:Int,verified:Bool,ejected:Bool,message:String,phase:UploadPhase?=nil){self.status=status;self.device=device;self.profileSHA256=profileSHA256;self.firmwareSHA256=firmwareSHA256;self.firmwareInstalled=firmwareInstalled;self.writeCount=writeCount;self.verified=verified;self.ejected=ejected;self.message=message;self.phase=phase}
}
public struct UploadFailure:LocalizedError {
 public let receipt:UploadReceipt
 public var errorDescription:String? {receipt.message}
}
public enum CardDeployment {
 public static func preview(_ request:UploadRequest,support:FirmwareSupport,firmware:Data)throws->[String:Any] {
  try validateRequest(request,support:support,firmware:firmware)
  try DiskUtility.verify(request.device)
  let part=try DiskUtility.info(request.device.partition)
  guard part["Mounted"] as? Bool != true, (part["MountPoint"] as? String ?? "").isEmpty else {throw ProfileError.invalid("Card is mounted.")}
  let io=try BlockFile(path:"/dev/r"+request.device.id,writable:false,bytes:request.device.bytes);defer{io.close()}
  let card=try CanonCard(disk:io),current=sha256(try card.contents("AUTOEXEC.BIN",maximum:131072))
  let install = current != support.payloadSHA256
  guard !install || request.installSupport else {throw ProfileError.invalid("Install the profile-enabled camera support build before uploading recipes.")}
  let plan=try card.plan(profile:request.profiles,firmware:install ? firmware:nil,acceptedFirmware:Set(support.acceptedPreviousSHA256+[support.payloadSHA256]))
  var removals:[String]=[]
  if request.prepareWorkingInstallation == true, let bookHash=support.factoryBookSHA256 {
   removals=try card.workingRemovals(expectedBookSHA256:bookHash)
   _ = try card.planWorkingCleanup(expectedBookSHA256:bookHash)
  }
  return ["status":"PASS_READ_ONLY_PREFLIGHT","firmwareSHA256":support.payloadSHA256,"profileSHA256":sha256(request.profiles),"existingEntries":card.entries.count,"cleanupAfterVerifiedRuntime":removals,"mutations":plan.map{["purpose":$0.purpose,"offset":$0.offset,"bytes":$0.after.count] as [String:Any]}]
 }
 private static func validateRequest(_ request:UploadRequest,support:FirmwareSupport,firmware:Data)throws {
  guard getuid()==0,request.schema==1,support.schema==1,support.target=="Canon EOS 450D 1.1.0",support.payloadFile=="AUTOEXEC.BIN",sha256(firmware)==support.payloadSHA256,firmware.count==130640 else {
   throw ProfileError.invalid("Camera support package or authorisation is invalid.")
  }
  try ProfileCompiler.validatePack(request.profiles)
  try validatePreparation(request,support:support)
 }
 private static func validatePreparation(_ request:UploadRequest,support:FirmwareSupport)throws {
  if request.prepareWorkingInstallation == true {
   guard support.workingInstallation == true,support.factoryBookSHA256?.count==64 else {throw ProfileError.invalid("A working-installation runtime is required for card cleanup.")}
   guard (0..<3).allSatisfy({request.profiles.u16(16+$0*960+2)==0}) else {throw ProfileError.invalid("Preparing a working card requires an empty user-profile pack.")}
  }
 }
 private static func backup(_ changes:[CardMutation],files:[String:Data],to url:URL)throws {
  let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
  struct Archive:Codable {let schema:Int;let mutations:[CardMutation];let files:[String:Data]}
  guard !FileManager.default.fileExists(atPath:url.path) else {throw ProfileError.invalid("The card backup already exists; use a new upload request.")}
  try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
  try encoder.encode(Archive(schema:1,mutations:changes,files:files)).write(to:url,options:.atomic)
  let handle=try FileHandle(forWritingTo:url);try handle.synchronize();try handle.close()
 }
 /// Runs the Effects upload after the privileged helper has decoded the request.
 /// Verify the target before opening it and verify the installed files before optional cleanup and eject.
 public static func perform(_ request:UploadRequest,support:FirmwareSupport,firmware:Data,backupDirectory:URL?=nil)throws->UploadReceipt {
  try validateRequest(request,support:support,firmware:firmware)
  guard request.prepareWorkingInstallation != true || backupDirectory != nil else {throw ProfileError.invalid("A Mac backup destination is required before preparing the card.")}
  try DiskUtility.verify(request.device)
  let part=try DiskUtility.info(request.device.partition)
  if part["Mounted"] as? Bool == true || !(part["MountPoint"] as? String ?? "").isEmpty { _ = try DiskUtility.run(["unmountDisk",request.device.id]) }
  try DiskUtility.verify(request.device)
  // macOS withdraws partition nodes while the whole raw device is open for
  // writing. Complete partition identity/mount checks before that open.
  let refreshed=try DiskUtility.info(request.device.partition)
  guard !(refreshed["Mounted"] as? Bool ?? false),(refreshed["MountPoint"] as? String ?? "").isEmpty else {throw ProfileError.invalid("The card remounted during preparation. Upload stopped.")}
  let io=try BlockFile(path:"/dev/r"+request.device.id,writable:true,bytes:request.device.bytes)
  return try performOnPreparedCard(request,support:support,firmware:firmware,disk:io,backupDirectory:backupDirectory,
                                   verifyDevice: {try DiskUtility.verify(request.device)},
                                   ejectDevice: {_ = try DiskUtility.run(["eject",request.device.id])})
 }

 /// Applies the validated request to an already-open card. Offline checks use an owned image
 /// and substitute the two device operations that run after the descriptor is closed.
 package static func performOnPreparedCard(_ request:UploadRequest,support:FirmwareSupport,firmware:Data,
                                          disk io:BlockFile,backupDirectory:URL?,
                                          verifyDevice:()throws->Void,ejectDevice:()throws->Void)throws->UploadReceipt {
  defer {io.close()}
  var receipt=UploadReceipt(status:"FAIL",device:request.device.id,profileSHA256:sha256(request.profiles),
                            firmwareSHA256:support.payloadSHA256,firmwareInstalled:false,writeCount:0,
                            verified:false,ejected:false,message:"",phase:.preflight)
  do {
   let card=try CanonCard(disk:io)
   let existing=try card.contents("AUTOEXEC.BIN",maximum:131072)
   let install=sha256(existing) != support.payloadSHA256
   guard !install || request.installSupport else {throw ProfileError.invalid("Install the profile-enabled camera support build before uploading recipes.")}
   let allowed=Set(support.acceptedPreviousSHA256+[support.payloadSHA256])
   let changes=try card.plan(profile:request.profiles,firmware:install ? firmware:nil,acceptedFirmware:allowed)
   let prepare=request.prepareWorkingInstallation == true
   let cleanupInputs: (bookHash:String, backup:URL)?
   if prepare {
    guard let hash=support.factoryBookSHA256, let backupDirectory else {
     throw ProfileError.invalid("Card preparation requires the factory lookup hash and Mac backup destination.")
    }
    cleanupInputs=(hash,backupDirectory)
   } else {
    cleanupInputs=nil
   }
   let removals=try cleanupInputs.map{try card.workingRemovals(expectedBookSHA256:$0.bookHash)} ?? []
   if let cleanupInputs {_ = try card.planWorkingCleanup(expectedBookSHA256:cleanupInputs.bookHash)}
   if let backupDirectory {
    var files:[String:Data]=[:]
    for name in removals {files[name]=try card.contents(name,maximum:21176)}
    try backup(changes,files:files,to:backupDirectory.appendingPathComponent("01-runtime-and-profiles.json"))
   }

   receipt.phase = .write
   try card.apply(changes){_ in receipt.writeCount+=1}
   receipt.phase = .readback
   let installed=try CanonCard(disk:io)
   guard try installed.contents("CUPROF.BIN",maximum:2896)==request.profiles,try installed.contents("AUTOEXEC.BIN",maximum:131072)==firmware else {
    throw ProfileError.invalid("Runtime/profile readback failed.")
   }
   receipt.firmwareInstalled=install
   if let cleanupInputs {
    receipt.phase = .cleanup
    let cleanup=try installed.planWorkingCleanup(expectedBookSHA256:cleanupInputs.bookHash)
    try backup(cleanup,files:[:],to:cleanupInputs.backup.appendingPathComponent("02-cleanup.json"))
    try installed.apply(cleanup){_ in receipt.writeCount+=1}
   }
   receipt.phase = .readback
   let checked=try CanonCard(disk:io)
   guard checked.mbr==card.mbr,checked.boot==card.boot,removals.allSatisfy({checked.entries[$0]==nil}),try checked.contents("CUPROF.BIN",maximum:2896)==request.profiles,try checked.contents("AUTOEXEC.BIN",maximum:131072)==firmware else {
    throw ProfileError.invalid("Final upload verification failed.")
   }
   for (name,before) in card.entries where name != "AUTOEXEC.BIN" && name != "CUPROF.BIN" && !removals.contains(name) {
    guard let after=checked.entries[name],before.size==after.size,before.attributes==after.attributes,before.clusters==after.clusters else {throw ProfileError.invalid("Existing card allocation changed unexpectedly.")}
   }
   receipt.verified=true
   io.close()

   receipt.phase = .verifyDevice
   try verifyDevice()
   if request.eject {
    receipt.phase = .eject
    try ejectDevice()
    receipt.ejected=true
   }
   receipt.phase = .complete
   receipt.status="PASS"
   receipt.message=prepare ? "Working installation verified; all card looks cleared." : "Profiles verified."
   if receipt.ejected {receipt.message += " Card safely ejected."}
   return receipt
  } catch {
   let prefix = receipt.verified
    ? "Card contents verified. Safe eject could not be confirmed. Keep the receipt and leave the card in the reader."
    : "Upload stopped after \(receipt.writeCount) attempted write operation(s). Leave the card in the reader and keep the receipt."
   receipt.message = "\(prefix) \(error.localizedDescription)"
   throw UploadFailure(receipt:receipt)
  }
 }
}
