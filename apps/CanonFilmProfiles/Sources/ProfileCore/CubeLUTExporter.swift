import Foundation
import CryptoKit
import FilmProfileEngine

/// Samples the existing 8-bit sRGB colour renderer. A 33-point cube is an
/// interpolated approximation between grid nodes, not a RAW camera profile.
public enum CubeLUTExporter {
 public static let size=33
 public static let limitations=[
  "Colour and tone only. Grain, sharpness, clarity, shading and halation are not included.",
  "Input and output are display-referred sRGB (gamma encoded), with values from 0 to 1. This is not a Log-to-display LUT.",
  "The source renderer is 8-bit. The 33-point cube samples its nearest 8-bit grid values; interpolation between nodes is approximate.",
  "Creative white-balance tint is included. A recipe using Set on camera needs its white balance set before the LUT is applied.",
  "Apply to a neutral, normally developed image. RAW development may differ from Canon's embedded JPEG. Applying to an already film-processed image applies the look twice.",
  "Ricoh interpretations and unsupported source-card settings retain the same limitations as Canon Film Profiles."
 ]
 private static let values=(0...255).map{String(format:"%.6f",locale:Locale(identifier:"en_US_POSIX"),Double($0)/255)}

 public static func cube(for recipe:Recipe,compiler:ProfileCompiler)throws->Data {
  let profile=try compiler.compile(recipe,requireAcknowledgement:false)
  let count=size*size*size
  var input=[UInt8]();input.reserveCapacity(count*3)
  // Adobe .cube ordering: red changes fastest, then green, then blue.
  for b in 0..<size {for g in 0..<size {for r in 0..<size {
   for v in [r,g,b] {input.append(UInt8((v*255+16)/32))}
  }}}
  var output=[UInt8](repeating:0,count:input.count)
  let rc=profile.body.withUnsafeBytes{body in input.withUnsafeBufferPointer{rgb in output.withUnsafeMutableBufferPointer{out in
   cfp_render_color(body.bindMemory(to:UInt8.self).baseAddress,rgb.baseAddress,Int32(size),Int32(size*size),recipe.effectiveBWFilter?.enabled == true ? 1:0,out.baseAddress)
  }}}
  guard rc==0 else{throw ProfileError.invalid("Could not export \(recipe.name) as a LUT (\(rc)).")}
  let title=recipe.name.replacingOccurrences(of:"\\",with:"/").replacingOccurrences(of:"\"",with:"'")
  var lines=["# Canon Film Profiles — colour and tone only", "# Recipe ID: \(recipe.id.uuidString); revision: \(recipe.revision)"]
  lines += limitations.map{"# "+$0}
  lines += ["TITLE \"\(title)\"","LUT_3D_SIZE \(size)","DOMAIN_MIN 0.0 0.0 0.0","DOMAIN_MAX 1.0 1.0 1.0"]
  lines.reserveCapacity(count+lines.count)
  for i in stride(from:0,to:output.count,by:3) {lines.append("\(values[Int(output[i])]) \(values[Int(output[i+1])]) \(values[Int(output[i+2])])")}
  return Data((lines.joined(separator:"\n")+"\n").utf8)
 }

 public struct Entry:Codable,Sendable {
  public let file:String
  public let sha256:String
  public let recipe:Recipe
  public let sourceLimitations:[String]
 }
 public struct Manifest:Codable,Sendable {
  public let schema:Int
  public let lutSize:Int
  public let limitations:[String]
  public let looks:[Entry]
 }

 /// Publishes a complete new folder. Existing folders and files are never replaced.
 @discardableResult public static func export(_ recipes:[Recipe],compiler:ProfileCompiler,to destination:URL)throws->[Entry] {
  guard !recipes.isEmpty,recipes.count<=256 else{throw ProfileError.invalid("Choose at least one look to export (maximum 256).")}
  let fm=FileManager.default
  guard !fm.fileExists(atPath:destination.path) else{throw ProfileError.invalid("The export folder already exists. Choose a new folder name.")}
  let stage=destination.deletingLastPathComponent().appendingPathComponent(".canon-luts-"+UUID().uuidString,isDirectory:true)
  try fm.createDirectory(at:stage,withIntermediateDirectories:false)
  defer{try? fm.removeItem(at:stage)}
  var entries=[Entry]()
  for (index,recipe) in recipes.enumerated() {
   let safe=String(recipe.name.unicodeScalars.filter{CharacterSet.alphanumerics.union(CharacterSet(charactersIn:" -_()")).contains($0)}).trimmingCharacters(in:.whitespaces)
   let file=String(format:"%02d",index+1)+" "+(safe.isEmpty ? "Look":safe)+".cube"
   let data=try cube(for:recipe,compiler:compiler)
   try data.write(to:stage.appendingPathComponent(file),options:.withoutOverwriting)
   entries.append(Entry(file:file,sha256:SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined(),recipe:recipe,sourceLimitations:recipe.omissions))
  }
  let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
  try encoder.encode(Manifest(schema:1,lutSize:size,limitations:limitations,looks:entries)).write(to:stage.appendingPathComponent("Manifest.json"),options:.withoutOverwriting)
  let names=entries.map{"- \($0.recipe.name): \($0.file)"}.joined(separator:"\n")
  let readme="""
  Canon Film Profiles — Nitro LUTs

  \(entries.count) looks, Adobe .cube format, 33 × 33 × 33, sRGB input/output.

  In Nitro on Mac: open a photo in Edit, open LUTs, click Import and choose
  a .cube file. Select the look and adjust its intensity. To combine it
  with other adjustments, use Save in Presets and include the LUT adjustment.
  On iPad use the … menu for LUT import and preset saving.

  \(limitations.map{"- "+$0}.joined(separator:"\n"))

  Exported looks
  \(names)

  Manifest.json records each source recipe, revision, source limitations
  and exported file SHA-256. The .cube files are the files to import.

  Nitro instructions: https://www.gentlemencoders.com/nitro/user-manual/index.html
  """
  try Data((readme+"\n").utf8).write(to:stage.appendingPathComponent("READ ME.txt"),options:.withoutOverwriting)
  try fm.moveItem(at:stage,to:destination)
  return entries
 }
}
