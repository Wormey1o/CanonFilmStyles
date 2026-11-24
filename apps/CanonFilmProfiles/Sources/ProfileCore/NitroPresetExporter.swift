import Foundation
import CryptoKit

/// Nitro 2026.09.01's version-1 preset and LUT-cache formats, checked against
/// the owner's Nitro-saved Portra sample. Only the LUT adjustment is included.
public enum NitroPresetExporter {
 public static let collection="Canon Film Profiles"
 public static let compatibility="Nitro 2026.09.01; preset version 1, edit-model format 1."

 public struct Parameters:Codable,Sendable {
  public let enabled:Bool
  public let disclosed:Bool
  public let numeric:[String:Double]
  public let dataParameters:[String:String]
 }
 public struct Adjustment:Codable,Sendable {
  public let id:String
  public let json:String
 }
 public struct Version:Codable,Sendable {
  public let decoderVersionString:String
  public let adjDataArr:[Adjustment]
  public let masks:[String]
 }
 public struct EditModel:Codable,Sendable {
  public let formatVersion:Int
  public let defaultOrientation:Int
  public let versions:[Version]
  public let editingJPEGHalf:Bool
  public let lowResMask:Bool
  public let currentVersionIndex:Int
 }
 public struct Preset:Codable,Sendable {
  public let version:Int
  public let editModel:EditModel
  public let name:String
 }
 public struct Entry:Codable,Sendable {
  public let preset:String
  public let lut:String
  public let cube:String
  public let sha256:[String:String]
  public let recipe:Recipe
  public let sourceLimitations:[String]
 }
 public struct Manifest:Codable,Sendable {
  public let schema:Int
  public let compatibility:String
  public let limitations:[String]
  public let looks:[Entry]
 }
 private static func encode<T:Encodable>(_ value:T)throws->Data {
  let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys,.withoutEscapingSlashes]
  return try encoder.encode(value)
 }
 private static func hash(_ data:Data)->String {SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()}

 /// Generate Nitro's LZFSE-compressed binary plist, containing little-endian
 /// Float32 RGBA. Parsing the published decimals matches Nitro's own importer.
 public static func cache(fromCube cube:Data)throws->Data {
  guard let text=String(data:cube,encoding:.utf8) else{throw ProfileError.invalid("The LUT is not UTF-8 text.")}
  var rgba=Data();rgba.reserveCapacity(33*33*33*16)
  var sizes=0,rows=0,titles=0,minimums=0,maximums=0
  func append(_ value:Float){var bits=value.bitPattern.littleEndian;withUnsafeBytes(of:&bits){rgba.append(contentsOf:$0)}}
  for raw in text.split(separator:"\n") {
   let line=raw.trimmingCharacters(in:.whitespacesAndNewlines)
   if line.isEmpty || line.hasPrefix("#"){continue}
   if line=="LUT_3D_SIZE 33"{sizes+=1;continue}
   if line.hasPrefix("TITLE "){titles+=1;continue}
   if line=="DOMAIN_MIN 0.0 0.0 0.0"{minimums+=1;continue}
   if line=="DOMAIN_MAX 1.0 1.0 1.0"{maximums+=1;continue}
   let fields=line.split(whereSeparator:{$0.isWhitespace})
   guard rows<33*33*33,fields.count==3 else{throw ProfileError.invalid("Invalid 33-point LUT row.")}
   for field in fields {
    guard let value=Float(field),value.isFinite,(0...1).contains(value) else{throw ProfileError.invalid("Invalid LUT colour value.")}
    append(value)
   }
   append(1);rows+=1
  }
  guard sizes==1,titles==1,minimums==1,maximums==1,rows==33*33*33 else{throw ProfileError.invalid("Nitro preset export requires a complete 33-point sRGB LUT.")}
  let plist=try PropertyListSerialization.data(fromPropertyList:["cubeSize":33,"cubeData":rgba],format:.binary,options:0)
  return try (plist as NSData).compressed(using:.lzfse) as Data
 }

 public static func preset(name:String,lutStem:String)throws->Data {
  guard !lutStem.isEmpty,!lutStem.contains("/"),!lutStem.contains("\\"),!lutStem.contains("..") else{throw ProfileError.invalid("Invalid Nitro LUT filename.")}
  let params=Parameters(enabled:true,disclosed:false,numeric:["intensity":1],dataParameters:["lutName":lutStem,"encodedFilePath":"($USER_LUT)/\(collection)/\(lutStem).rawpowerCubeData"])
  let adjustment=Adjustment(id:"LUT",json:String(decoding:try encode(params),as:UTF8.self))
  let version=Version(decoderVersionString:"None",adjDataArr:[adjustment],masks:[])
  let model=EditModel(formatVersion:1,defaultOrientation:1,versions:[version],editingJPEGHalf:false,lowResMask:false,currentVersionIndex:0)
  return try encode(Preset(version:1,editModel:model,name:name))
 }

 /// Export matching My Presets and My LUTs subfolders. Existing destinations
 /// are never replaced, and no Nitro library, source recipe or camera is edited.
 @discardableResult public static func export(_ recipes:[Recipe],compiler:ProfileCompiler,to destination:URL)throws->[Entry] {
  guard !recipes.isEmpty,recipes.count<=256 else{throw ProfileError.invalid("Choose 1–256 looks to export.")}
  let fm=FileManager.default
  guard !fm.fileExists(atPath:destination.path) else{throw ProfileError.invalid("The export folder already exists. Choose a new folder name.")}
  let stage=destination.deletingLastPathComponent().appendingPathComponent(".canon-nitro-presets-"+UUID().uuidString,isDirectory:true)
  try fm.createDirectory(at:stage,withIntermediateDirectories:false)
  defer{try? fm.removeItem(at:stage)}
  let source=stage.appendingPathComponent("Source")
  let colorEntries=try CubeLUTExporter.export(recipes,compiler:compiler,to:source)
  let presetFolder=stage.appendingPathComponent("My Presets/\(collection)",isDirectory:true),lutFolder=stage.appendingPathComponent("My LUTs/\(collection)",isDirectory:true)
  try fm.createDirectory(at:presetFolder,withIntermediateDirectories:true)
  try fm.createDirectory(at:lutFolder,withIntermediateDirectories:true)
  var entries=[Entry]()
  for color in colorEntries {
   let stem=String(color.file.dropLast(5)),cube=try Data(contentsOf:source.appendingPathComponent(color.file))
   let cache=try cache(fromCube:cube),preset=try preset(name:color.recipe.name,lutStem:stem)
   let presetPath="My Presets/\(collection)/\(stem).nitropreset",lutPath="My LUTs/\(collection)/\(stem).rawpowerCubeData",cubePath="My LUTs/\(collection)/\(color.file)"
   for (path,bytes) in [(presetPath,preset),(lutPath,cache),(cubePath,cube)] {try bytes.write(to:stage.appendingPathComponent(path),options:.withoutOverwriting)}
   entries.append(Entry(preset:presetPath,lut:lutPath,cube:cubePath,sha256:[presetPath:hash(preset),lutPath:hash(cache),cubePath:hash(cube)],recipe:color.recipe,sourceLimitations:color.sourceLimitations))
  }
  try fm.removeItem(at:source)
  try encode(Manifest(schema:1,compatibility:compatibility,limitations:CubeLUTExporter.limitations,looks:entries)).write(to:stage.appendingPathComponent("Manifest.json"),options:.withoutOverwriting)
  let readme="""
  Canon Film Profiles — Nitro presets

  \(entries.count) native .nitropreset files with matching LUTs and Nitro LUT caches.
  \(compatibility)

  Install on Mac
  1. In Nitro, open My Preset and My LUTs to reveal the two library folders.
  2. Quit Nitro.
  3. Copy the Canon Film Profiles folder from this package's My Presets
     into Nitro's My Presets folder.
  4. Copy the Canon Film Profiles folder from this package's My LUTs
     into Nitro's My LUTs folder. Keep the .cube and .rawpowerCubeData
     files together. Both folders are required.
  5. Reopen Nitro. Choose a look under Presets > Canon Film Profiles.

  If Nitro asks to replace an existing Canon Film Profiles collection,
  preserve your existing collection first. Do not rename the LUT folder
  or its files: the presets reference those names.

  These presets contain only the film colour LUT at full intensity.
  The sample's Tone, Enhance and BlackAndWhite adjustments are deliberately
  excluded: they are unrelated to the individual Canon recipes and would
  change the colour looks. Each monochrome recipe already includes its own
  monochrome conversion inside its LUT. Nitro's own adjustments can be added
  afterwards and saved as a separate preset.

  \(CubeLUTExporter.limitations.map{"- "+$0}.joined(separator:"\n"))

  Manifest.json records the exact source recipes and file hashes.
  No camera, card, source recipe or installed Nitro library was changed.
  Native import and visual matching still need to be checked in Nitro.
  """
  try Data((readme+"\n").utf8).write(to:stage.appendingPathComponent("READ ME.txt"),options:.withoutOverwriting)
  try fm.moveItem(at:stage,to:destination)
  return entries
 }
}
