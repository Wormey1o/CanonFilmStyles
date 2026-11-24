import Foundation

/// Shared vocabulary for recipe cards, stored recipes, the editor and compiler.
/// Automatic Ricoh algorithms remain explicitly distinct from Canon's as-shot WB.
public enum RecipeWhiteBalance {
 public static let kelvinRange=2500...10000
 public static let modes=["Auto","Auto (Warmth Priority)","Auto (White Priority)","Multi Auto","CTE","Daylight","Cloudy","Shade","Tungsten","Fluorescent D","Fluorescent N","Fluorescent W","Fluorescent L","Kelvin"]
 public static let fixedKelvin:[String:Double]=["Daylight":5200,"Cloudy":6000,"Shade":7000,"Tungsten":3200,"Fluorescent D":6500,"Fluorescent N":5000,"Fluorescent W":4200,"Fluorescent L":3000]
 private static func key(_ text:String)->String {text.uppercased().filter{$0.isASCII && ($0.isLetter || $0.isNumber)}}
 public static func label(_ mode:String)->String {
  ["Multi Auto":"Multi-Auto WB","Fluorescent D":"Fluorescent (Daylight)","Fluorescent N":"Fluorescent (Daylight White)","Fluorescent W":"Fluorescent (Cool White)","Fluorescent L":"Fluorescent (Warm White)"][mode] ?? mode
 }
 public static func automaticLimitation(_ mode:String)->String? {
  switch mode {
  case "Auto (Warmth Priority)":return "AWB Warmth Priority (not reproduced)"
  case "Auto (White Priority)":return "AWB White Priority (not reproduced)"
  case "Multi Auto":return "Multi-Auto WB (not reproduced)"
  case "CTE":return "CTE WB (not reproduced)"
  default:return nil
  }
 }
 public struct CardValue:Equatable,Sendable {
  public let mode:String
  public let amberBlue:Int
  public let greenMagenta:Int
  public let kelvin:Int?
 }
 public static func parseCardValue(_ text:String)throws->CardValue {
  var normalized=text.uppercased().replacingOccurrences(of:"−",with:"-").replacingOccurrences(of:"–",with:"-")
  // Separate adjacent complete axis tokens (A0M2), without changing any digits.
  normalized=normalized.replacingOccurrences(of:#"([0-9O])([ABGM])(?=[0-9O])"#,with:"$1 $2",options:.regularExpression)
  let axisRegex=try NSRegularExpression(pattern:#"\b([ABGM])\s*([0-9O]{1,2})\b"#)
  let range=NSRange(normalized.startIndex...,in:normalized),ns=normalized as NSString
  var axes=Set<String>(),ab=0,gm=0
  for match in axisRegex.matches(in:normalized,range:range) {
   let letter=ns.substring(with:match.range(at:1)),axis=["A","B"].contains(letter) ? "AB":"GM"
   // Restrict O-to-zero correction to axis tokens; never guess a Kelvin digit.
   let digits=ns.substring(with:match.range(at:2)).replacingOccurrences(of:"O",with:"0")
   guard axes.insert(axis).inserted,let number=Int(digits),number<=14 else{throw ProfileError.invalid("The white-balance shifts are ambiguous or outside ±14.")}
   if axis=="AB"{ab=letter=="A" ? number : -number}else{gm=letter=="G" ? number : -number}
  }
  let remaining=axisRegex.stringByReplacingMatches(in:normalized,range:range,withTemplate:" ")
  let temperatureRegex=try NSRegularExpression(pattern:#"\b([0-9]{4,5})\s*°?\s*K?\b"#)
  let temperatureRange=NSRange(remaining.startIndex...,in:remaining),temperatures=temperatureRegex.matches(in:remaining,range:temperatureRange)
  let preset=key(temperatureRegex.stringByReplacingMatches(in:remaining,range:temperatureRange,withTemplate:" "))
  if !temperatures.isEmpty {
   guard temperatures.count==1,["","KELVIN","COLORTEMPERATURE","COLOURTEMPERATURE"].contains(preset),let value=Int((remaining as NSString).substring(with:temperatures[0].range(at:1))),kelvinRange.contains(value) else{throw ProfileError.invalid("Use one unambiguous Kelvin temperature from 2500 K to 10000 K, with shifts within ±14.")}
   return CardValue(mode:"Kelvin",amberBlue:ab,greenMagenta:gm,kelvin:value)
  }
  let names=["AUTO":"Auto","AUTOWB":"Auto","AWB":"Auto",
   "AWBWARMTHPRIORITY":"Auto (Warmth Priority)","AWBWARMPRIORITY":"Auto (Warmth Priority)","AUTOWBWARMTHPRIORITY":"Auto (Warmth Priority)","AUTOWBWARMPRIORITY":"Auto (Warmth Priority)","AUTOWARMTHPRIORITY":"Auto (Warmth Priority)",
   "AWBWHITEPRIORITY":"Auto (White Priority)","AUTOWBWHITEPRIORITY":"Auto (White Priority)","AUTOWHITEPRIORITY":"Auto (White Priority)",
   "MULTIAUTO":"Multi Auto","MULTIAUTOWB":"Multi Auto","MULTIAWB":"Multi Auto","CTE":"CTE",
   "DAYLIGHT":"Daylight","CLOUDY":"Cloudy","SHADE":"Shade","TUNGSTEN":"Tungsten","INCANDESCENT":"Tungsten",
   "FLUORESCENTD":"Fluorescent D","FLUORESCENTDAYLIGHT":"Fluorescent D",
   "FLUORESCENTN":"Fluorescent N","FLUORESCENTDAYLIGHTWHITE":"Fluorescent N","FLUORESCENTNATURALWHITE":"Fluorescent N","FLUORESCENTNEUTRALWHITE":"Fluorescent N",
   "FLUORESCENTW":"Fluorescent W","FLUORESCENTCOOLWHITE":"Fluorescent W",
   "FLUORESCENTL":"Fluorescent L","FLUORESCENTWARMWHITE":"Fluorescent L"]
  guard let mode=names[preset] else{throw ProfileError.invalid("The card’s white-balance preset is unreadable or unsupported: \(text)")}
  return CardValue(mode:mode,amberBlue:ab,greenMagenta:gm,kelvin:nil)
 }
}
