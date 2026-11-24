import Foundation
import ProfileCore
import RecipeCardImport

extension RecipeCardChecks {
 static func verifyReportedCard(_ recipe:Recipe,file:String)throws {
  let values:[Int],base:String,wb:String,ab:Int,gm:Int,temperature:Int?
  switch file {
  case "photo-stuff-leica-look.jpg":
   values=[2,0,-2,1,1,1,1,-1,2];base="Standard";wb="Auto";ab=0;gm=0;temperature=nil
   check(recipe.name=="Leica Look" && recipe.creator=="Photo Stuff","Leica identity lost")
  case "candy-color-400.jpg":
   values=[4,-2,0,4,4,4,4,1,4];base="Positive Film";wb="Kelvin";ab=0;gm = -2;temperature=5700
   check(recipe.name=="Candy Color 400" && recipe.creator=="Luke Taylor","Candy identity lost")
   check(recipe.wbDescription.contains("5700 K"),"Kelvin missing from editor description")
  case "asakura-negative.jpg":
   values=[-2,0,0,3,4,-4,0,0,0];base="Negative Film";wb="Multi Auto";ab = -5;gm=0;temperature=nil
   check(recipe.name=="Asakura Negative Film" && recipe.creator.contains("Ricoh"),"Wrapped Asakura title or author lost: \(recipe.name)")
   check(recipe.omissions.contains("Multi-Auto WB (not reproduced)"),"Multi-Auto limitation hidden")
  case "bw-negative-red-filter.jpg":
   values=[0,0,1,2,4,-4,2,-1,-2];base="Hard Monotone";wb="Fluorescent D";ab = -2;gm = -14;temperature=nil
   check(recipe.name==String("B&W Negative + Red Filter".prefix(23)),"Long B&W title lost: \(recipe.name)")
   check(recipe.grain==2 && recipe.effectiveBWFilter==nil && recipe.sourceValue("filterEffect")=="2","Numeric filter must be retained without guessing its RGB mix")
   check(recipe.sourceOmissions.contains("FILTER EFFECT"),"Unmapped numeric filter hidden")
  default:fatalError("Unknown reported card")
  }
  let actual=[recipe.saturation,recipe.hue,recipe.key,recipe.contrast,recipe.highlights,recipe.shadows,recipe.sharpness,recipe.shading,recipe.clarity]
  check(actual==values,"Reported card slider values changed: \(file): \(actual), expected \(values)")
  check(recipe.base==base && recipe.whiteBalance==wb && recipe.amberBlue==ab && recipe.greenMagenta==gm && recipe.kelvin==temperature,"Reported card base/WB mismatch: \(file)")
  check(!recipe.allowPartial && recipe.factoryID==nil,"Import must not grant camera acknowledgement")
  try checkPersistenceAndCompile(recipe)
 }
 static func predictableFixture(name:String,base:String,wb:String,values:[Int],rows:[(String,String)]=[])->[CardTextBlock] {
  var blocks=fixture(wb:wb).filter{$0.y>0.28 || $0.text.contains("RicohCookBook")}
  blocks=blocks.map{b in
   let text=b.text=="NEGATIVE FILM" ? base:b.text=="Bennet 800" ? name:b.text
   return CardTextBlock(text:text,x:b.x,y:b.y,width:b.width,height:b.height,confidence:b.confidence)
  }
  for i in 0..<9 {
   let x=[0.22,0.50,0.78][i%3],y=[0.59,0.46,0.33][i/3]+0.045
   blocks.removeAll{abs($0.x-x)<0.01 && abs($0.y-y)<0.01}
   let mono=["Monotone","Soft Monotone","Hard Monotone","Hi-Contrast B&W"].contains(base)
   blocks.append(.init(text:mono && i<2 ? "—":String(values[i]),x:x,y:y,height:0.035))
  }
  for(i,row) in ([("WHITE BALANCE",wb)]+rows).enumerated() {
   let y=0.27-Double(i)*0.025
   blocks.append(.init(text:row.0,x:0.16,y:y,height:0.012));blocks.append(.init(text:row.1,x:0.75,y:y,width:0.4,height:0.012))
  }
  return blocks
 }
 static func testPredictableCards()throws {
  let aliases:[(String,String,Int?,Int,Int)]=[
   ("Kelvin A0 M2 5700K","Kelvin",5700,0,-2),("5700 K A0 M2","Kelvin",5700,0,-2),
   ("Kelvin 2500K G14:B14","Kelvin",2500,-14,14),("Kelvin A0 G0 10000K","Kelvin",10000,0,0),
   ("Kelvin\u{202f}5700\u{a0}K A0M2","Kelvin",5700,0,-2),
   ("Multi-Auto WB B5 G0","Multi Auto",nil,-5,0),("Multi AWB B5 G0","Multi Auto",nil,-5,0),
   ("AWB (White Priority) A0 G0","Auto (White Priority)",nil,0,0),("Auto WB (White Priority) A0 G0","Auto (White Priority)",nil,0,0),
   ("CTE A3 G2","CTE",nil,3,2),("Incandescent B1 M1","Tungsten",nil,-1,-1),
   ("Fluorescent (Daylight) B2 M14","Fluorescent D",nil,-2,-14),
   ("Fluorescent (Daylight White) A1 G2","Fluorescent N",nil,1,2),
   ("Fluorescent (Cool White) A1 G2","Fluorescent W",nil,1,2),
   ("Fluorescent (Warm White) A1 G2","Fluorescent L",nil,1,2)]
  for(text,mode,temperature,ab,gm) in aliases {
   let result=try RecipeWhiteBalance.parseCardValue(text)
   check(result.mode==mode && result.kelvin==temperature && result.amberBlue==ab && result.greenMagenta==gm,"WB vocabulary mismatch: \(text)")
   try checkPersistenceAndCompile(RecipeCardImporter.parse(fixture(wb:text),filename:"variant.jpg").recipe)
  }
  for text in ["Kelvin A0 G0","Kelvin A0 G0 2499K","Kelvin A0 G0 10001K","Kelvin A0 G0 5500K 5700K","Auto WB 5700K","Kelvin 57OOK","Auto WB A3 B2","Auto WB A15 G0","Fluorescent (Unknown) A0 G0","Auto WB A-1 G0"] {
   rejects("ambiguous/unsupported WB: \(text)"){_ = try RecipeWhiteBalance.parseCardValue(text)}
  }
  let app=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
  let compiler=try ProfileCompiler(factoryBook:Data(contentsOf:app.appendingPathComponent("Resources/CFLOOKS.BIN")))
  var kelvin=Recipe();kelvin.whiteBalance="Kelvin";kelvin.kelvin=5200
  check(compiler.gains(kelvin).allSatisfy{abs($0-1)<1e-12},"Neutral Kelvin tint drift")
  kelvin.kelvin=5700;check(compiler.gains(kelvin)[0]>compiler.gains(kelvin)[2],"Kelvin tint not applied")
  kelvin.wbPolicy="Set on camera";check(compiler.gains(kelvin)==[1,1,1],"Manual WB double applied")
  kelvin.kelvin=nil;rejects("missing stored temperature"){try kelvin.validate()}
  var standard=Recipe();standard.base="Standard"
  check(compiler.masterCurve(standard).allSatisfy{$0.0==$0.1},"Standard should be a neutral starting curve")
  for mode in ["Auto (White Priority)","Multi Auto","CTE"] {
   var automatic=Recipe();automatic.whiteBalance=mode
   check(compiler.gains(automatic).allSatisfy{abs($0-1)<1e-12},"Invented scene-dependent automatic WB gain")
   rejects("unreproduced automatic WB needs acknowledgement"){_ = try compiler.compile(automatic)}
  }
  // Public Ricoh Cookbook examples, transcribed into independent layout fixtures.
  let cases:[(String,String,String,[Int],[(String,String)])]=[
   ("Dramatic Monochrome","Hi-Contrast B&W","Kelvin A0 M14 10000K",[0,0,-1,3,-3,-3,0,0,1],[("GRAIN","Strong"),("FILTER EFFECT","2")]),
   ("Le Marais","Cinema (Yellow)","Kelvin B3 M3 6000K",[3,-3,0,3,-4,-2,0,-2,1],[("TONING","1"),("GRAIN","Off"),("SNAP FOCUS","2.5m at f/5.6")]),
   ("Retro Chrome (1600)","Retro","Daylight A0 G1",[4,-4,0,2,0,0,-3,3,2],[("ISO","ISO 1600 fixed"),("EXPOSURE COMP","0")]),
   ("Rich Tone Monochrome","Monotone","Auto WB A0 G0",[0,0,-1,2,2,2,0,-2,1],[("TONING","Off"),("HIGHLIGHT DR","Off")]),
   ("Ninzaburo Monotone","Monotone","Auto WB A0 G0",[0,0,-2,2,0,0,0,4,0],[("GRAIN","3"),("FILTER EFFECT","3")]),
   ("Sedona","Positive Film","AWB (Warmth Priority) A10 G14",[4,-4,-1,3,-1,-2,0,0,0],[("GRAIN","Off"),("HDF","On")]),
   ("Dante Sisofo Street B&W","Hi-Contrast B&W","Auto WB A0 G0",[0,0,-2,4,-4,0,4,4,4],[("GRAIN","3"),("SNAP FOCUS","Snap focus, 2m"),("ISO","ISO Auto 400-6400, minimum shutter 1/500")]),
   ("Cotton Color 400","Positive Film","Auto WB B2 G3",[0,0,2,1,-1,-4,-2,2,-2],[("HIGHLIGHT DR","On"),("ISO","Up to ISO 6400")])]
  for(name,base,wb,values,rows) in cases {
   let result=try RecipeCardImporter.parse(predictableFixture(name:name,base:base,wb:wb,values:values,rows:rows),filename:"cookbook-audit.jpg")
   check(result.recipe.name==name,"Audit recipe title lost")
   check([result.recipe.saturation,result.recipe.hue,result.recipe.key,result.recipe.contrast,result.recipe.highlights,result.recipe.shadows,result.recipe.sharpness,result.recipe.shading,result.recipe.clarity]==values,"Audit sliders lost")
   for row in rows {check(result.recipe.sourceSettings?.contains{$0.value==row.1 && !$0.needsReview} == true,"Known reference row lost or incorrectly unreadable")}
   try checkPersistenceAndCompile(result.recipe)
  }
  let optional=try RecipeCardImporter.parse(predictableFixture(name:"Optional grain",base:"Positive Film",wb:"Auto WB A0 G0",values:Array(repeating:0,count:9),rows:[("GRAIN","Size 1 / Intensity 1 (optional)")]),filename:"optional.jpg").recipe
  check(optional.sourceValue("grain")=="Size 1 / Intensity 1 (optional)" && optional.effectiveGrain==nil && optional.grain==nil,"Optional grain silently enabled or lost")
  check(optional.sourceOmissions.isEmpty && optional.sourceDisposition(optional.sourceSettings!.first{$0.key=="grain"}!).contains("Optional"),"Optional grain treated as an import failure")
  var wrapped=fixture().filter{$0.text != "Bennet 800" && $0.text != "by Bennet"}
  wrapped += [.init(text:"Asakura Negative",x:0.45,y:0.84,width:0.66,height:0.055),.init(text:"Film",x:0.22,y:0.77,width:0.20,height:0.055),.init(text:"by Ricoh",x:0.16,y:0.70,height:0.025)]
  let wrappedRecipe=try RecipeCardImporter.parse(wrapped,filename:"wrapped.jpg").recipe
  check(wrappedRecipe.name=="Asakura Negative Film","Wrapped title not joined in reading order")
  let titleEqualsMode=fixture().map{b in b.text=="Bennet 800" ? CardTextBlock(text:"Negative Film",x:b.x,y:b.y,width:b.width,height:b.height):b}
  let sameNameRecipe=try RecipeCardImporter.parse(titleEqualsMode,filename:"same-name.jpg").recipe
  check(sameNameRecipe.name=="Negative Film","Title confused with Image Control")
  let aliasesInGrid=["SAT":"Saturation","KEY":"High/Low Key","CTR·H":"Contrast (Highlight)","CTR·S":"Contrast (Shadow)","SHARP":"Sharpness"]
  let grid=fixture().map{b in CardTextBlock(text:aliasesInGrid[b.text] ?? b.text,x:b.x,y:b.y,width:b.width,height:b.height,confidence:b.confidence)}
  try verifyBennet(RecipeCardImporter.parse(grid,filename:"grid-labels.jpg").recipe)
  let soft=try RecipeCardImporter.parse(predictableFixture(name:"Soft mono",base:"Soft Monotone",wb:"Auto WB A0 G0",values:Array(repeating:0,count:9)),filename:"soft.jpg").recipe
  check(soft.isMonochrome && soft.saturation==0,"Soft Monotone applicability wrong");try checkPersistenceAndCompile(soft)
  for mode in ["Cross Processing","Cinema (Green)","HDR Tone"] {
   var blocks=predictableFixture(name:"Unsupported",base:mode,wb:"Auto WB A0 G0",values:Array(repeating:0,count:9))
   if mode=="HDR Tone"{blocks.removeAll{b in ["KEY","CONTRAST","CTRH","CTRS","SHARP","SHADING","CLARITY"].contains(b.text.filter{$0.isLetter}.uppercased())}}
   do{_ = try RecipeCardImporter.parse(blocks,filename:"unsupported.jpg");fatalError("Unsupported renderer silently substituted")}
   catch{check(error.localizedDescription.contains(mode) && error.localizedDescription.contains("not supported"),"Valid unsupported mode reported as unreadable")}
  }
  print("PASS shared WB vocabulary, Kelvin boundaries/persistence/tint, Standard/Soft Monotone, wrapped/eponymous titles, grid aliases, eight Cookbook layout fixtures, optional grain, reference settings and explicit unsupported renderers")
 }
}
