import Foundation
public enum ProfileError: LocalizedError {
 case invalid(String)
 public var errorDescription: String? { if case .invalid(let s) = self { return s }; return nil }
}
/// Source-card data is retained separately from controls the renderer can apply.
public struct ImportedSetting: Codable, Equatable, Sendable {
 public var key: String
 public var label: String
 public var value: String?
 public var needsReview: Bool
 public init(key: String, label: String, value: String?, needsReview: Bool = false) {
  self.key=key;self.label=label;self.value=value;self.needsReview=needsReview
 }
 public var isOff: Bool {
  guard let value else{return false}
  return ["OFF","NONE"].contains(value.trimmingCharacters(in:.whitespacesAndNewlines).uppercased())
 }
 public var isOptional:Bool {value?.trimmingCharacters(in:.whitespacesAndNewlines).lowercased().hasSuffix("(optional)") == true}
}
/// Deliberate starting approximation, not a measured Ricoh-to-Canon calibration.
/// Our three presets couple grain amount and size, so two source axes are quantized.
public enum RecipeGrainMapping {
 public static func name(_ value: Int) -> String { ["None","Weak","Medium","Strong"][max(0,min(3,value))] }
 public static func level(size: Int, intensity: Int) -> Int? {
  guard (1...3).contains(size),(0...3).contains(intensity) else{return nil}
  if intensity == 0 {return 0}
  let score=size+intensity
  return score<=3 ? 1 : score==4 ? 2 : 3
 }
 public static func approximate(_ source: String) -> Int? {
  let text=source.trimmingCharacters(in:.whitespacesAndNewlines).uppercased()
  if ["OFF","NONE","-","–","—","0"].contains(text) {return 0}
  if let n=Int(text),(1...3).contains(n) {return n}
  if let index=["WEAK","MEDIUM","STRONG"].firstIndex(of:text) {return index+1}
  // Accept only a complete known grammar; trailing garbage is never guessed away.
  let pattern=#"^SIZE\s+(1|2|3|SMALL|MEDIUM|LARGE)\s*/\s*(?:INTENSITY|STRENGTH)\s+(0|1|2|3|OFF|WEAK|MEDIUM|STRONG)$"#
  guard let regex=try? NSRegularExpression(pattern:pattern),let m=regex.firstMatch(in:text,range:NSRange(text.startIndex...,in:text)) else{return nil}
  let ns=text as NSString,s=ns.substring(with:m.range(at:1)),i=ns.substring(with:m.range(at:2))
  let sizes=["SMALL":1,"MEDIUM":2,"LARGE":3],intensities=["OFF":0,"WEAK":1,"MEDIUM":2,"STRONG":3]
  guard let size=Int(s) ?? sizes[s],let intensity=Int(i) ?? intensities[i] else{return nil}
  return level(size:size,intensity:intensity)
 }
}
public struct Recipe: Codable, Identifiable, Equatable, Sendable {
 public var id: UUID = UUID()
 public var revision: UInt32 = 1
 public var name = "New recipe"
 public var shortName = "New recipe"
 public var creator = ""
 public var sourceURL = ""
 public var family = "Ricoh GR III / IIIx"
 public var base = "Negative Film"
 public var factoryID: Int? = nil
 public var saturation = 0, hue = 0, key = 0, contrast = 0, highlights = 0, shadows = 0
 public var sharpness = 0, shading = 0, clarity = 0
 public var whiteBalance = "Auto"
 public var kelvin: Int? = nil
 public var amberBlue = 0, greenMagenta = 0
 public var wbPolicy = "Creative tint"
 public var grain: Int? = nil
 // Optional overrides keep older libraries readable. Source-card effects can
 // also be resolved without rewriting a user's existing recipes.
 public var bwFilter: BWFilter? = nil
 public var toning: MonochromeToning? = nil
 public var grainSettings: RecipeGrain? = nil
 public var notes = ""
 // Optional for compatibility with libraries saved before card metadata existed.
 public var sourceSettings: [ImportedSetting]? = nil
 public var allowPartial = false
 public init() {}
 public static var portra160: Recipe {
  var r = Recipe(); r.name = "Portra 160"; r.shortName = "Portra 160"; r.creator = "Chrizz Ocampo"; r.sourceURL = "https://ricohcookbook.com"; r.saturation = 3; r.hue = -1; r.key = 3; r.contrast = -1; r.highlights = 2; r.shadows = -3; r.clarity = -4; r.whiteBalance = "Shade"; r.amberBlue = 3; r.greenMagenta = 3
  return r
 }
 public static let monochromeBases: Set<String> = ["BW Monotone","Soft Monotone","Hard Monotone","Hi-Contrast B&W"]
 public var isMonochrome: Bool {factoryID == nil && Self.monochromeBases.contains(base)}
 public var isCinemaYellow: Bool {factoryID == nil && base == "Cinema (Yellow)"}
 public var usesWarmthPriority: Bool {whiteBalance == "Auto (Warmth Priority)"}
 public var usesSceneDependentWB:Bool {RecipeWhiteBalance.automaticLimitation(whiteBalance) != nil}
 public var baseInterpretationDescription: String {
  isCinemaYellow ? "Canon starting approximation with subdued colour and yellow highlights. Ricoh Cinema rendering is not calibrated; source Toning values are retained separately." : "Canon interpretation of Ricoh-style controls; equal values do not guarantee a Ricoh match."
 }
 public var wbApplicationDescription: String {
  if usesSceneDependentWB {
   let mode=RecipeWhiteBalance.label(whiteBalance)
   return wbPolicy == "Creative tint" ? "Uses the Canon JPEG’s as-shot white balance plus the entered shifts. Ricoh’s scene-dependent \(mode) algorithm is not reproduced; camera WB is not changed." : "Use Canon Auto WB as a starting point and set the shifts manually. Ricoh’s \(mode) algorithm is not reproduced."
  }
  if whiteBalance == "Kelvin" {return wbPolicy == "Creative tint" ? "Uses an approximate post-JPEG tint for \(kelvin ?? 5200) K plus the entered shifts. This is not a calibrated RAW white-balance conversion and does not set camera WB.":"Match \(kelvin ?? 5200) K and the shifts with camera/custom white balance before capture. No Kelvin command is sent to the camera, and the grade does not apply the tint again."}
  return wbPolicy == "Creative tint" ? "A post-JPEG colour interpretation, assuming a neutral Canon source. It does not change the camera’s white balance." : "Set the shown preset and shifts on the Canon before capture. The custom grade will not apply the tint again."
 }
 public var interpretationOmissions: [String] {
  var result=(isCinemaYellow ? ["Cinema (Yellow) base (approximate)"] : []) + (RecipeWhiteBalance.automaticLimitation(whiteBalance).map{[$0]} ?? [])
  if effectiveBWFilter?.enabled == true && sourceValue("filterEffect") == nil {result.append("B&W filter (approximate)")}
  if let tone=effectiveToning,tone != .off,sourceValue("toning") == nil {result.append("Toning (reference approximation)")}
  if let detail=effectiveGrain,detail.intensity>0,sourceValue("grain") == nil {result.append("Ricoh grain (approximate)")}
  return result
 }
 public var sourceOmissions: [String] {
  (sourceSettings ?? []).compactMap { setting in
   if setting.needsReview {return "Review \(setting.label)"}
   guard ["grain","filterEffect","toning","colorTone","hdrToneLevel"].contains(setting.key) else{return nil}
   if setting.key == "grain",setting.isOptional,grain == nil,grainSettings == nil {return nil}
   if setting.key == "filterEffect",let filter=effectiveBWFilter {return filter.enabled ? "B&W filter (approximate)":nil}
   if setting.key == "toning",let tone=effectiveToning {return tone == .off ? nil:"Toning (reference approximation)"}
   if setting.key == "grain",let detail=effectiveGrain {return detail.intensity>0 ? "Ricoh grain (approximate)":nil}
   if setting.isOff {return nil}
   if setting.key == "grain",let source=setting.value,RecipeGrainMapping.approximate(source) == 0 {return nil}
   return setting.key == "grain" && grain != nil ? "Ricoh grain (approximate)":setting.label
  }
 }
 public var omissions: [String] {
  interpretationOmissions + sourceOmissions
 }
 public func sourceDisposition(_ setting: ImportedSetting) -> String {
  if setting.needsReview {return "Check against the card before upload."}
  if setting.key == "imageControl" {return isCinemaYellow ? baseInterpretationDescription : "Original Image Control retained; the selected Canon starting look is \(base)."}
  if setting.key == "whiteBalance" {return wbApplicationDescription}
  if setting.key == "grain",setting.isOptional,grain == nil,grainSettings == nil {return "Optional suggestion retained; no grain is added. Use the grain controls to enable it."}
  if ["colorTone","hdrToneLevel"].contains(setting.key) {return "Retained from the card; this rendering control is not applied."}
  if ["grain","filterEffect","toning"].contains(setting.key) {
   if setting.key == "filterEffect",let filter=effectiveBWFilter {return filter.enabled ? "Applied as a direct signed RGB mix: \(filter.summary). The original signed percentages are retained; the Ricoh working space and tonal response may differ.":"Current B&W filter: Off."}
   if setting.key == "toning",let tone=effectiveToning {return tone == .off ? "Current monochrome toning: Off.":"Applied: \(tone.rawValue), using GR IIIx 1.50 measured channel differences. Canon appearance remains approximate."}
   if setting.key == "grain",let detail=effectiveGrain {return detail.intensity == 0 ? "Current grain: Off.":"Applied: \(detail.summary). \(detail.mode == .grIIIx ? "Strength fitted from the GR IIIx references at Canon output size.":"Size and intensity are kept separate; this combination is an extrapolation from the GR IIIx strengths.")"}
   if setting.isOff {return "Off on the source card."}
   if setting.key == "grain",let grain {
    return "Canon grain: \(RecipeGrainMapping.name(grain)) — starting approximation, not calibrated. Original Ricoh settings retained; change Added grain to override."
   }
   return "Retained from the card; not applied by this renderer."
  }
  return "Reference only; not set on the camera by this app."
 }
 public var cameraShortName: String { String(shortName.prefix(omissions.isEmpty ? 14 : 13)) + (omissions.isEmpty ? "" : "*") }
 public var wbDescription: String {
  "\(whiteBalance == "Kelvin" ? "\(kelvin ?? 5200) K":RecipeWhiteBalance.label(whiteBalance)) · \(amberBlue >= 0 ? "A" : "B")\(abs(amberBlue)) / \(greenMagenta >= 0 ? "G" : "M")\(abs(greenMagenta))"
 }
 public func validate(forCamera: Bool = false) throws {
  func ascii(_ s:String,_ count:Int)->Bool { !s.isEmpty && s.utf8.count<=count && s.utf8.allSatisfy{ $0>=32 && $0<=126 } }
  guard ascii(name,23), ascii(shortName,14) else { throw ProfileError.invalid("Use 1–23 printable English characters for the camera name and 1–14 for the shooting-screen label.") }
  guard revision > 0 else { throw ProfileError.invalid("Recipe revision must be positive.") }
  guard kelvin == nil || RecipeWhiteBalance.kelvinRange.contains(kelvin!),whiteBalance != "Kelvin" || kelvin != nil else {throw ProfileError.invalid("Kelvin white balance requires a temperature from 2500 K to 10000 K.")}
  for v in [saturation,hue,key,contrast,highlights,shadows,sharpness,shading,clarity] { guard (-4...4).contains(v) else { throw ProfileError.invalid("Image Control adjustments must be between −4 and +4.") } }
  guard (-14...14).contains(amberBlue),(-14...14).contains(greenMagenta),grain == nil || (0...3).contains(grain!) else { throw ProfileError.invalid("White-balance shifts must be within ±14; grain must be unspecified or 0–3.") }
  if let filter=bwFilter {guard [filter.red,filter.green,filter.blue].allSatisfy({(-200...200).contains($0)}) else {throw ProfileError.invalid("B&W filter percentages must be within −200…200.")}}
  if let detail=grainSettings {guard (0...3).contains(detail.intensity),(1...3).contains(detail.size) else {throw ProfileError.invalid("Grain intensity must be 0–3 and size 1–3.")}}
  guard Self.bases.contains(base),Self.whiteBalances.contains(whiteBalance),["Creative tint","Set on camera"].contains(wbPolicy),factoryID == nil || Self.factoryNames[factoryID!] != nil else { throw ProfileError.invalid("This recipe uses an unknown base or white-balance policy.") }
  if let settings=sourceSettings {
   guard settings.count<=32,Set(settings.map(\.key)).count==settings.count,
    settings.allSatisfy({!$0.key.isEmpty && $0.key.utf8.count<=128 && !$0.label.isEmpty && $0.label.utf8.count<=256 && ($0.value?.utf8.count ?? 0)<=2048}) else {throw ProfileError.invalid("The imported card settings are invalid or too large.")}
  }
  if forCamera && !omissions.isEmpty && !allowPartial { throw ProfileError.invalid("\(omissions.joined(separator:", ")) are not reproduced exactly. Enable ‘Allow approximate interpretation’ to upload while retaining the source settings.") }
 }
 public static let bases = ["Standard","Negative Film","Positive Film","Vivid","Retro","Bleach Bypass","Soft Monotone","Hard Monotone","Hi-Contrast B&W","BW Monotone","Cinema (Yellow)"]
 public static let whiteBalances = RecipeWhiteBalance.modes
 public static let factoryNames: [Int:String] = [1001:"Positive Film",1002:"Kodachrome",1003:"Hi-Contrast B&W",2001:"B&W Neg + Red Filter",2002:"Dramatic Monochrome",2003:"Monochrome Film",2004:"Moody Monochrome",2005:"Black & White Negative",2006:"Positive Film (RR)",2007:"Reggie's Color Negative",2008:"Ektacolor",2009:"Vibrant Nostalgia",2010:"B&W Film",2011:"Classic Emulsion",2012:"Positive Emulsion",2013:"Kodak Print",2014:"Film Look",2015:"Vintage Film",2016:"Vibrant Analog",2017:"Vibrant Teal",2018:"Vintage Print",2019:"Chrome Slide",2020:"Aged & Faded"]
}
public struct RecipeLibrary: Codable, Equatable, Sendable {
 public var schema = 1
 public var recipes: [Recipe]
 public var slots: [UUID?]
 public init(recipes:[Recipe] = [.portra160], slots:[UUID?] = [nil,nil,nil]) { self.recipes=recipes;self.slots=slots }
 public func validate() throws {
  guard schema==1,recipes.count<=256,slots.count==3,Set(recipes.map(\.id)).count==recipes.count else { throw ProfileError.invalid("Invalid recipe library format.") }
  for r in recipes { try r.validate() }
  for id in slots.compactMap({$0}) { guard recipes.contains(where:{$0.id==id}) else { throw ProfileError.invalid("A camera slot refers to a missing recipe.") } }
 }
 // The larger shared limit recovers valid libraries written by versions whose reader stopped at 1 MiB.
 private static let maximumFileBytes = 32 * 1024 * 1024

 public func save(to url: URL) throws {
  try validate()
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
  let data = try encoder.encode(self)
  guard data.count <= Self.maximumFileBytes else {
   throw ProfileError.invalid("The recipe library exceeds 32 MiB. Shorten notes or export smaller libraries before saving.")
  }
  try data.write(to: url, options: .atomic)
 }

 public static func load(from url: URL) throws -> Self {
  let file = try FileHandle(forReadingFrom: url)
  defer { try? file.close() }
  let data = try file.read(upToCount: maximumFileBytes + 1) ?? Data()
  guard data.count <= maximumFileBytes else {
   throw ProfileError.invalid("The recipe library exceeds 32 MiB. Make a copy and divide its recipes and slot assignments into smaller libraries.")
  }
  let library = try JSONDecoder().decode(Self.self, from: data)
  try library.validate()
  return library
 }
}
public extension Data {
 func u16(_ at:Int)->UInt16 { UInt16(self[at]) | UInt16(self[at+1])<<8 }
 func u32(_ at:Int)->UInt32 { UInt32(u16(at)) | UInt32(u16(at+2))<<16 }
 mutating func put16(_ v:UInt16,_ at:Int) { self[at]=UInt8(truncatingIfNeeded:v);self[at+1]=UInt8(truncatingIfNeeded:v>>8) }
 mutating func put32(_ v:UInt32,_ at:Int) { put16(UInt16(truncatingIfNeeded:v),at);put16(UInt16(truncatingIfNeeded:v>>16),at+2) }
 func fnv32()->UInt32 { reduce(UInt32(2166136261)){($0 ^ UInt32($1)) &* 16777619} }
}
