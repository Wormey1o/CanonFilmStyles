import Foundation

/// Signed source percentages are preserved verbatim; they are never normalised.
public struct BWFilter: Codable, Equatable, Sendable {
 public var enabled: Bool
 public var red: Int, green: Int, blue: Int
 public init(enabled: Bool = true, red: Int = 30, green: Int = 59, blue: Int = 11) {
  self.enabled=enabled;self.red=red;self.green=green;self.blue=blue
 }
 public static let off = BWFilter(enabled:false)
 public static let references = [BWFilter(red:10,green:70,blue:20),BWFilter(red:40,green:50,blue:10),BWFilter(red:90,green:20,blue:-10),BWFilter(red:120,green:-10,blue:-10)]
 public var summary: String {enabled ? "R \(red)% / G \(green)% / B \(blue)%" : "Off"}
 public static func parse(_ source: String) -> BWFilter? {
  let text=source.uppercased().replacingOccurrences(of:"−",with:"-").replacingOccurrences(of:"–",with:"-").trimmingCharacters(in:.whitespacesAndNewlines)
  if ["OFF","NONE","—","-","0"].contains(text) {return .off}
  let pattern=#"^(?:(?:CUSTOM\s*)?[1-4]\s*[-:]?\s*|ON\s*)?R\s*([+-]?\d{1,3})\s*%\s*[/,:]?\s*G\s*([+-]?\d{1,3})\s*%\s*[/,:]?\s*B\s*([+-]?\d{1,3})\s*%$"#
  guard let re=try? NSRegularExpression(pattern:pattern),let m=re.firstMatch(in:text,range:NSRange(text.startIndex...,in:text)) else{return nil}
  let ns=text as NSString,values=(1...3).compactMap{Int(ns.substring(with:m.range(at:$0)))}
  guard values.count==3,values.allSatisfy({(-200...200).contains($0)}) else{return nil}
  return BWFilter(red:values[0],green:values[1],blue:values[2])
 }
 /// Six hue-brightness nodes supported by the existing camera profile format.
 /// This is a bounded approximation, not an exact signed RGB matrix.
 public var hueBrightness: [Int] {
  guard enabled else{return Array(repeating:100,count:6)}
  func analytical(_ f:BWFilter)->[Double] {
   let colours=[[255.0,0,0],[255,255,0],[0,255,0],[0,255,255],[0,0,255],[255,0,255]]
   return colours.map {rgb in
    let normal=(77*rgb[0]+150*rgb[1]+29*rgb[2])/256
    return (Double(f.red)*rgb[0]+Double(f.green)*rgb[1]+Double(f.blue)*rgb[2])/normal
   }
  }
  // Independent bounded fits to the four measured filter photographs. Other
  // triples smoothly interpolate residuals around the analytical hue response.
  let anchors=Self.references+[BWFilter()]
  let nodes=[[77,107,120,111,91,83],[108,112,115,96,83,99],[148,123,111,46,62,123],[166,127,87,11,66,137],[100,100,100,100,100,100]]
  let original=analytical(self)
  var correction=Array(repeating:0.0,count:6),total=1.0/2500
  for (i,a) in anchors.enumerated() {
   let dr=Double(red-a.red),dg=Double(green-a.green),db=Double(blue-a.blue)
   let distance=dr*dr+dg*dg+db*db
   if distance == 0 {return nodes[i]}
   let weight=1/distance,expected=analytical(a);total+=weight
   for c in 0..<6 {correction[c]+=weight*(Double(nodes[i][c])-expected[c])}
  }
  return (0..<6).map{max(0,min(200,Int((original[$0]+correction[$0]/total).rounded())))}
 }
}

public enum MonochromeToning: String, Codable, CaseIterable, Sendable {
 case off="Off", sepia="Sepia", red="Red", green="Green", blue="Blue", purple="Purple"
 public static func parse(_ source: String) -> Self? {
  let text=source.trimmingCharacters(in:.whitespacesAndNewlines)
  if ["NONE","-","—","0"].contains(text.uppercased()) {return .off}
  return allCases.first{$0.rawValue.caseInsensitiveCompare(text) == .orderedSame}
 }
 /// Fitted to measured GR IIIx 1.50 channel differences across the 24 patch
 /// brightnesses, including the renderer's split weighting and chroma rolloff.
 public var shadowSplit: [Int] {
  switch self {
  case .off:return [0,0,0]
  case .sepia:return [5,-3,-11]
  case .red:return [11,-4,-4]
  case .green:return [-8,5,0]
  case .blue:return [-1,2,10]
  case .purple:return [4,0,10]
  }
 }
 public var highlightSplit: [Int] {
  switch self {
  case .off:return [0,0,0]
  case .sepia:return [12,3,-11]
  case .red:return [13,-4,-4]
  case .green:return [-10,5,0]
  case .blue:return [-3,0,13]
  case .purple:return [2,-2,10]
  }
 }
}

/// IIIx has one strength axis; size/intensity cards retain both axes independently.
public struct RecipeGrain: Codable, Equatable, Sendable {
 public enum Mode: String, Codable, CaseIterable, Sendable {case grIIIx="GR IIIx strength", sizeIntensity="Size / intensity"}
 public var mode: Mode
 public var intensity: Int
 public var size: Int
 public init(mode:Mode = .grIIIx,intensity:Int = 0,size:Int = 1) {self.mode=mode;self.intensity=intensity;self.size=size}
 public static func parse(_ source:String)->Self? {
  let text=source.uppercased().trimmingCharacters(in:.whitespacesAndNewlines)
  if !text.hasPrefix("SIZE"),let level=RecipeGrainMapping.approximate(source) {return Self(intensity:level)}
  let pattern=#"^SIZE\s+(1|2|3|SMALL|MEDIUM|LARGE)\s*/\s*(?:INTENSITY|STRENGTH)\s+(0|1|2|3|OFF|WEAK|MEDIUM|STRONG)$"#
  guard let re=try? NSRegularExpression(pattern:pattern),let m=re.firstMatch(in:text,range:NSRange(text.startIndex...,in:text)) else{return nil}
  let ns=text as NSString,s=ns.substring(with:m.range(at:1)),i=ns.substring(with:m.range(at:2))
  guard let size=Int(s) ?? ["SMALL":1,"MEDIUM":2,"LARGE":3][s],let intensity=Int(i) ?? ["OFF":0,"WEAK":1,"MEDIUM":2,"STRONG":3][i] else{return nil}
  return Self(mode:.sizeIntensity,intensity:intensity,size:size)
 }
 public var summary:String {mode == .grIIIx ? "GR IIIx \(RecipeGrainMapping.name(intensity))" : "Size \(size) / Intensity \(intensity)"}
 // Reference fitting fills the three strength targets; size/intensity remains
 // an explicit extrapolation because this IIIx shoot does not measure GR IV.
 public var cameraParameters:(amount:Int,cell:Int) {
  let amount=[0,11,16,27][max(0,min(3,intensity))]
  return (amount,mode == .sizeIntensity ? max(1,min(3,size)) : 1)
 }
}

public extension Recipe {
 func sourceValue(_ key:String)->String? {sourceSettings?.first{$0.key==key && !$0.needsReview}?.value}
 var effectiveBWFilter:BWFilter? {isMonochrome ? (bwFilter ?? sourceValue("filterEffect").flatMap(BWFilter.parse)) : nil}
 var effectiveToning:MonochromeToning? {isMonochrome ? (toning ?? sourceValue("toning").flatMap(MonochromeToning.parse)) : nil}
 var effectiveGrain:RecipeGrain? {
  if let grainSettings{return grainSettings}
  // Previously imported cards stored only the quantised grain preset. Recover
  // both axes if the owner has not selected a different legacy preset.
  if let source=sourceValue("grain"),grain == RecipeGrainMapping.approximate(source) {return RecipeGrain.parse(source)}
  return nil
 }
}
