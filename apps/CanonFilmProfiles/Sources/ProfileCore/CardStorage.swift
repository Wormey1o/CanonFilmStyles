import Foundation
import CryptoKit
import Darwin
public func sha256(_ data:Data)->String {SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()}
public final class BlockFile {
 private var fd:Int32
 public let bytes:UInt64
 public init(path:String,writable:Bool,bytes:UInt64)throws {
  fd=Darwin.open(path,(writable ? O_RDWR:O_RDONLY)|O_NOFOLLOW);self.bytes=bytes
  guard fd>=0 else {throw ProfileError.invalid("Cannot open card: \(String(cString:strerror(errno)))")}
 }
 deinit {close()}
 public func close(){if fd>=0 {Darwin.close(fd);fd = -1}}
 public func read(_ offset:UInt64,_ count:Int)throws->Data {
  guard fd>=0,count>=0,offset<=bytes,UInt64(count)<=bytes-offset else {throw ProfileError.invalid("Read exceeds the selected card.")}
  var d=Data(count:count);let got=d.withUnsafeMutableBytes{Darwin.pread(fd,$0.baseAddress,count,off_t(offset))}
  guard got==count else {throw ProfileError.invalid("Short card read; the upload stopped.")};return d
 }
 public func write(_ offset:UInt64,_ data:Data)throws {
  guard fd>=0,offset<=bytes,UInt64(data.count)<=bytes-offset else {throw ProfileError.invalid("Write exceeds the selected card.")}
  let n=data.withUnsafeBytes{Darwin.pwrite(fd,$0.baseAddress,data.count,off_t(offset))}
  guard n==data.count else {throw ProfileError.invalid("Short card write. Leave the card in the reader; do not retry.")}
  guard fsync(fd)==0 else {throw ProfileError.invalid("Card sync failed. Leave the card in the reader.")}
  guard try read(offset,data.count)==data else {throw ProfileError.invalid("Card readback differs. Leave the card in the reader.")}
 }
}
public struct CardEntry: Sendable {
 public let name:String,attributes:UInt8,start:UInt16,size:Int,rootSlot:Int?,clusters:[UInt16]
}
public struct CardMutation: Codable, Sendable {
 public let purpose:String,offset:UInt64,before:Data,after:Data
}
public final class CanonCard {
 public let disk:BlockFile
 public let mbr:Data,boot:Data,fat:Data,root:Data
 public let fatOffset:UInt64,rootOffset:UInt64,dataOffset:UInt64,clusterBytes:Int,fatBytes:Int,clusterCount:Int
 public private(set) var entries:[String:CardEntry]=[:]
 private var owners:[UInt16:String]=[:]
 public init(disk:BlockFile)throws {
  self.disk=disk;mbr=try disk.read(0,512)
  guard mbr[510]==0x55,mbr[511]==0xaa,[6,14].contains(Int(mbr[450])) else {throw ProfileError.invalid("Select the Canon FAT16 SD card.")}
  for i in 1..<4 {guard mbr[446+i*16+4]==0 else {throw ProfileError.invalid("Cards with multiple partitions are unsupported.")}}
  let start=UInt64(mbr.u32(454));boot=try disk.read(start*512,512)
  guard boot.u16(11)==512,boot[16]==2,boot.u16(17)>0,boot.u16(22)>0,boot[510]==0x55,boot[511]==0xaa,boot.subdata(in:64..<72)==Data("BOOTDISK".utf8) else {throw ProfileError.invalid("This is not the configured Canon boot card.")}
  let sectors=Int(boot.u16(19)==0 ? boot.u32(32):UInt32(boot.u16(19))),reserved=Int(boot.u16(14)),rootSectors=(Int(boot.u16(17))*32+511)/512,spc=Int(boot[13])
  guard spc>0,spc & (spc-1)==0 else {throw ProfileError.invalid("Invalid cluster geometry.")}
  clusterBytes=spc*512;fatBytes=Int(boot.u16(22))*512;clusterCount=(sectors-reserved-2*Int(boot.u16(22))-rootSectors)/spc
  guard clusterBytes>=4096,clusterBytes<=65536,clusterCount>=4085,clusterCount<65525,sectors>0,UInt64(sectors)*512<=disk.bytes-start*512,fatBytes>=2*(clusterCount+2) else {throw ProfileError.invalid("Unsupported or inconsistent FAT16 geometry.")}
  fatOffset=(start+UInt64(reserved))*512;rootOffset=fatOffset+UInt64(2*fatBytes);dataOffset=rootOffset+UInt64(rootSectors*512)
  fat=try disk.read(fatOffset,fatBytes);guard fat == (try disk.read(fatOffset+UInt64(fatBytes),fatBytes)) else {throw ProfileError.invalid("The card allocation tables disagree. Upload stopped.")}
  root=try disk.read(rootOffset,rootSectors*512)
  try walk(root,prefix:"",depth:0,isRoot:true)
  guard entries["AUTOEXEC.BIN"] != nil else {throw ProfileError.invalid("The Film camera files were not found.")}
 }
 public func clusterOffset(_ c:UInt16)->UInt64 {dataOffset+UInt64(Int(c)-2)*UInt64(clusterBytes)}
 private func chain(_ start:UInt16,_ owner:String)throws->[UInt16] {
  guard start>=2,Int(start)<clusterCount+2 else {throw ProfileError.invalid("Invalid allocation for \(owner).")}
  var result:[UInt16]=[],seen=Set<UInt16>(),c=start
  while true {
   guard c>=2,Int(c)<clusterCount+2,seen.insert(c).inserted,owners[c]==nil,result.count<clusterCount else {throw ProfileError.invalid("Overlapping or cyclic card allocation; upload stopped.")}
   owners[c]=owner;result.append(c);let next=fat.u16(Int(c)*2)
   if next>=0xfff8 {return result};guard next<0xfff0 else {throw ProfileError.invalid("Invalid card allocation marker.")};c=next
  }
 }
 private func walk(_ data:Data,prefix:String,depth:Int,isRoot:Bool)throws {
  guard depth<=16,data.count<=4_194_304 else {throw ProfileError.invalid("Card directory exceeds limits.")}
  for i in stride(from:0,to:data.count,by:32) {
   if data[i]==0 {break};if data[i]==0xe5 || data[i+11]==15 || data[i+11]&8 != 0 {continue}
   let stem=String(decoding:data[i..<i+8],as:UTF8.self).trimmingCharacters(in:.whitespaces),ext=String(decoding:data[i+8..<i+11],as:UTF8.self).trimmingCharacters(in:.whitespaces)
   if stem=="." || stem==".." {continue}
   let name=prefix+stem+(ext.isEmpty ? "":"."+ext),size=Int(data.u32(i+28)),start=data.u16(i+26),attr=data[i+11]
   guard entries[name]==nil,entries.count<65536 else {throw ProfileError.invalid("Duplicate or excessive card directory entries.")}
   let clusters=(size>0 || attr&16 != 0) ? try chain(start,name):[]
   guard attr&16 != 0 || size<=clusters.count*clusterBytes else {throw ProfileError.invalid("File exceeds its card allocation.")}
   let entry=CardEntry(name:name,attributes:attr,start:start,size:size,rootSlot:isRoot ? i/32:nil,clusters:clusters);entries[name]=entry
   if attr&16 != 0 {
    guard clusters.count*clusterBytes<=4_194_304 else {throw ProfileError.invalid("Directory too large.")}
    var dir=Data();for c in clusters {dir+=try disk.read(clusterOffset(c),clusterBytes)};try walk(dir,prefix:name+"/",depth:depth+1,isRoot:false)
   }
  }
 }
 public func contents(_ name:String,maximum:Int)throws->Data {
  guard let entry=entries[name],entry.attributes&16==0,entry.size<=maximum else {throw ProfileError.invalid("Missing or oversized \(name).")}
  var data=Data();for c in entry.clusters {data+=try disk.read(clusterOffset(c),clusterBytes)};return Data(data.prefix(entry.size))
 }
 private func bodyMutations(_ entry:CardEntry,_ body:Data,purpose:String)throws->[CardMutation] {
  guard entry.size==body.count,entry.attributes&0x19==0,entry.clusters.count==(body.count+clusterBytes-1)/clusterBytes else {throw ProfileError.invalid("Unexpected allocation for \(entry.name).")}
  var result:[CardMutation]=[]
  for (i,c) in entry.clusters.enumerated() {
   let off=clusterOffset(c),before=try disk.read(off,clusterBytes);var after=Data(repeating:0,count:clusterBytes);let a=i*clusterBytes,b=min(body.count,a+clusterBytes);after.replaceSubrange(0..<b-a,with:body[a..<b])
   if before != after {
    if let last=result.last,last.offset+UInt64(last.after.count)==off {result.removeLast();result.append(CardMutation(purpose:purpose,offset:last.offset,before:last.before+before,after:last.after+after))}
    else {result.append(CardMutation(purpose:purpose,offset:off,before:before,after:after))}
   }
  };return result
 }
 /// Plans bounded changes on an already configured Effects card.
 /// Each extent retains its original bytes for stale-state checks and recovery.
 public func plan(profile:Data,firmware:Data?,acceptedFirmware:Set<String>)throws->[CardMutation] {
  try ProfileCompiler.validatePack(profile)
  let oldFirmware=try contents("AUTOEXEC.BIN",maximum:131072)
  guard acceptedFirmware.contains(sha256(oldFirmware)) else {throw ProfileError.invalid("This card has an unrecognised firmware build. Its firmware was not changed.")}
  var plan:[CardMutation]=[]
  if let entry=entries["CUPROF.BIN"] {guard entry.size==2896,entry.clusters.count==1 else {throw ProfileError.invalid("Unexpected user-profile allocation; upload stopped.")};plan+=try bodyMutations(entry,profile,purpose:"Update user profiles")}
  else {
   guard let free=(2..<clusterCount+2).first(where:{fat.u16($0*2)==0 && owners[UInt16($0)]==nil}) else {throw ProfileError.invalid("No free card cluster for user profiles.")}
   guard let slot=stride(from:0,to:root.count,by:32).first(where:{root[$0]==0 || root[$0]==0xe5}) else {throw ProfileError.invalid("The card root directory is full.")}
   let cluster=UInt16(free),offset=clusterOffset(cluster),old=try disk.read(offset,clusterBytes);var body=Data(repeating:0,count:clusterBytes);body.replaceSubrange(0..<profile.count,with:profile)
   plan.append(CardMutation(purpose:"Create user-profile body",offset:offset,before:old,after:body))
   let fatSector=(free*2/512)*512
   for copy in [1,0] {let at=fatOffset+UInt64(copy*fatBytes+fatSector),before=try disk.read(at,512);var after=before;after.put16(0xffff,free*2-fatSector);plan.append(CardMutation(purpose:"Allocate profile cluster (FAT \(copy+1))",offset:at,before:before,after:after))}
   let firstSector=slot/512,lastByte=(root[slot]==0 && slot+32<root.count) ? slot+32:slot+31,lastSector=lastByte/512,start=firstSector*512,end=(lastSector+1)*512
   let before=Data(root[start..<end]);var after=before;let local=slot-start
   after.replaceSubrange(local..<local+32,with:Data(repeating:0,count:32));after.replaceSubrange(local..<local+11,with:Data("CUPROF  BIN".utf8));after[local+11]=0x20;after.put16(cluster,local+26);after.put32(2896,local+28)
   if root[slot]==0 && slot+32<root.count {after[local+32]=0}
   plan.append(CardMutation(purpose:"Publish user-profile directory entry",offset:rootOffset+UInt64(start),before:before,after:after))
  }
  if let firmware {
   guard firmware.count==130640,let entry=entries["AUTOEXEC.BIN"],entry.size==130640 else {throw ProfileError.invalid("Unsupported firmware allocation.")}
   plan+=try bodyMutations(entry,firmware,purpose:"Install compatible Film firmware")
  }
  for i in plan.indices {guard plan[i].before.count==plan[i].after.count else {throw ProfileError.invalid("Internal write-size mismatch.")};for j in plan.indices where j<i {let a=plan[i].offset..<plan[i].offset+UInt64(plan[i].after.count),b=plan[j].offset..<plan[j].offset+UInt64(plan[j].after.count);guard !a.overlaps(b) else {throw ProfileError.invalid("Overlapping upload extents.")}}}
  return plan
 }
 /// Only recognised Film look data and timing probes are cleanup candidates.
 /// Photos, publication proofs, recovery spools and unknown files are preserved.
 public func workingRemovals(expectedBookSHA256:String)throws->[String] {
  var names:[String]=[]
  if entries["CFLOOKS.BIN"] != nil {
   guard sha256(try contents("CFLOOKS.BIN",maximum:21176))==expectedBookSHA256 else {throw ProfileError.invalid("The card's bundled look file is not recognised. Cleanup stopped.")}
   names.append("CFLOOKS.BIN")
  }
  for name in entries.keys.sorted() where name.range(of:"^T[0-9]{7}\\.BIN$",options:.regularExpression) != nil {
   guard let entry=entries[name],entry.size>=16,entry.size<=512 else{continue}
   let body=try contents(name,maximum:512)
   let timing=body.u32(0)==0x57464a31 && body.u32(4)==1 && body.u32(8)==UInt32(body.count)
   let bootProbe=name=="T9989991.BIN" && body.count==320 && body.u32(0)==0x334c4244 && body.u32(4)==3 && body.u32(8)==320
   if timing || bootProbe {names.append(name)}
  }
  return names
 }
 public func planWorkingCleanup(expectedBookSHA256:String)throws->[CardMutation] {
  let names=try workingRemovals(expectedBookSHA256:expectedBookSHA256)
  var roots:[Int:Data]=[:],fats:[Int:Data]=[:]
  for name in names {
   guard let entry=entries[name],entry.attributes&0x19==0,let slot=entry.rootSlot else {throw ProfileError.invalid("Unexpected cleanup allocation for \(name).")}
   let byte=slot*32
   // An adjacent long-name chain requires a separate inventory, not a guess.
   guard byte==0 || root[byte-32]==0xe5 || root[byte-32+11] != 15 else {throw ProfileError.invalid("A long filename precedes \(name); cleanup stopped.")}
   let sector=byte/512*512
   var directory=roots[sector] ?? Data(root[sector..<sector+512]);directory[byte-sector]=0xe5;roots[sector]=directory
   for cluster in entry.clusters {
    let at=Int(cluster)*2,sector=at/512*512
    var allocation=fats[sector] ?? Data(fat[sector..<sector+512]);allocation.put16(0,at-sector);fats[sector]=allocation
   }
  }
  var changes:[CardMutation]=[]
  // Retire directory names before releasing their allocations.
  for sector in roots.keys.sorted() {changes.append(CardMutation(purpose:"Remove recognised Film support/test entries",offset:rootOffset+UInt64(sector),before:Data(root[sector..<sector+512]),after:roots[sector]!))}
  for copy in [1,0] {for sector in fats.keys.sorted() {changes.append(CardMutation(purpose:"Release removed support allocations (FAT \(copy+1))",offset:fatOffset+UInt64(copy*fatBytes+sector),before:Data(fat[sector..<sector+512]),after:fats[sector]!))}}
  return changes
 }
 /// Checks the full plan before writing, then checks each extent again immediately before its write.
 /// Each write syncs and reads back its bytes. An interruption can leave earlier extents committed.
 public func apply(_ mutations:[CardMutation],progress:(String)->Void = {_ in})throws {
  for m in mutations {guard try disk.read(m.offset,m.before.count)==m.before else {throw ProfileError.invalid("Card changed after inspection. Upload stopped.")}}
  for m in mutations {progress(m.purpose);guard try disk.read(m.offset,m.before.count)==m.before else {throw ProfileError.invalid("Card changed during upload. Leave it in the reader.")};try disk.write(m.offset,m.after)}
 }
}
