import Foundation
import RecipeCardImport
import ProfileCore

func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
}
func rejects(_ message: String, _ body: () throws -> Void) {
    do { try body(); fatalError("Expected rejection: \(message)") } catch {}
}

@main struct RecipeCardChecks {
    static func fixture(wb: String = "Auto WB A14 G2") -> [CardTextBlock] {
        var b: [CardTextBlock] = [
            .init(text:"IMAGE CONTROL",x:0.16,y:0.92),
            .init(text:"NEGATIVE FILM",x:0.20,y:0.90),
            .init(text:"Bennet 800",x:0.34,y:0.84,height:0.06),
            .init(text:"by Bennet",x:0.16,y:0.78,height:0.025),
            .init(text:"RicohCookBook.com",x:0.25,y:0.08)
        ]
        let labels = ["SAT","HUE","KEY","CONTRAST","CTR·H","CTR·S","SHARP","SHADING","CLARITY"]
        let values = ["+3","−1","0","+2","–2","-4","0","0","-1"]
        for i in 0..<9 {
            let x = [0.22,0.50,0.78][i % 3], y = [0.59,0.46,0.33][i / 3]
            b.append(.init(text:labels[i],x:x,y:y))
            b.append(.init(text:values[i],x:x,y:y+0.045,height:0.035))
        }
        for (i,pair) in [("WHITE BALANCE",wb),("HIGHLIGHT DR","On"),("SHADOW DR","Off"),("ISO","Auto ISO")].enumerated() {
            let y = 0.27 - Double(i)*0.04
            b.append(.init(text:pair.0,x:0.16,y:y));b.append(.init(text:pair.1,x:0.80,y:y))
        }
        return b
    }
    static func verifyBennet(_ r: Recipe) throws {
        check(r.name == "Bennet 800" && r.creator == "Bennet" && r.base == "Negative Film", "Identity mismatch")
        check([r.saturation,r.hue,r.key,r.contrast,r.highlights,r.shadows,r.sharpness,r.shading,r.clarity] == [3,-1,0,2,-2,-4,0,0,-1], "Adjustment or sign mismatch")
        check(r.whiteBalance == "Auto" && r.amberBlue == 14 && r.greenMagenta == 2, "WB mismatch")
        check(r.grain == nil && !r.allowPartial && r.factoryID == nil, "Import must not invent grain, acknowledge omissions or use a factory base")
        check(r.notes.contains("HIGHLIGHT DR: On") && r.notes.contains("SHADOW DR: Off") && r.notes.contains("ISO: Auto ISO"), "Reference settings lost")
        check(r.omissions.isEmpty, "Unsupported detail lost")
        try r.validate()
    }
    static func monochromeFixture(trix: Bool) -> [CardTextBlock] {
        let old = fixture()
        var b = old.filter { $0.y > 0.28 || $0.text.contains("RicohCookBook") }
        b = b.map { block in
            let text: String
            switch block.text {
            case "NEGATIVE FILM": text = "MONOTONE"
            case "Bennet 800": text = trix ? "IAC Tri-X" : "Bennet's BW800"
            case "by Bennet": text = trix ? "by I Am a Camera" : block.text
            default: text = block.text
            }
            return CardTextBlock(text:text,x:block.x,y:block.y,width:block.width,height:block.height,confidence:block.confidence)
        }
        let values = trix ? ["—","—","-1","+2","0","-2","-1","0","+1"] : ["—","—","-2","+4","-2","-4","-1","0","0"]
        for i in 0..<9 {
            let x = [0.22,0.50,0.78][i % 3], y = [0.59,0.46,0.33][i / 3] + 0.045
            b.removeAll { abs($0.x-x)<0.01 && abs($0.y-y)<0.01 }
            b.append(.init(text:values[i],x:x,y:y,height:0.035))
        }
        let rows = trix ? [("WHITE BALANCE","Auto WB A0 G0"),("TONING","Off"),("GRAIN","Size 2 / Intensity 1"),("FILTER EFFECT","3 - R 50% / G 20% / B -10%"),("METERING","Matrix / Highlight-Weighted")] : [("WHITE BALANCE","Daylight A14 G2"),("TONING","Off"),("HIGHLIGHT DR","On"),("SHADOW DR","Medium"),("PERIPHERAL ILLUM.","On"),("NOISE REDUCTION","Off"),("ISO","ISO 800 base, up to 6400"),("EXPOSURE COMP","+0.3")]
        for (i,row) in rows.enumerated() {
            let y = 0.27 - Double(i)*0.022
            b.append(.init(text:row.0,x:0.16,y:y,height:0.012))
            b.append(.init(text:row.1,x:0.75,y:y,width:0.40,height:0.012))
        }
        return b
    }
    static func verifyMonochrome(_ r: Recipe, trix: Bool) throws {
        check(r.name == (trix ? "IAC Tri-X" : "Bennet's BW800"),"Monochrome title mismatch: \(r.name)")
        check(r.creator == (trix ? "I Am a Camera" : "Bennet"),"Monochrome author mismatch")
        check(r.isMonochrome && r.base == "BW Monotone" && r.factoryID == nil,"Wrong monochrome base")
        check(r.saturation == 0 && r.hue == 0,"Inapplicable controls must remain neutral internally")
        let expected = trix ? [-1,2,0,-2,-1,0,1] : [-2,4,-2,-4,-1,0,0]
        check([r.key,r.contrast,r.highlights,r.shadows,r.sharpness,r.shading,r.clarity] == expected,"Monochrome tone/detail mismatch")
        check(r.whiteBalance == (trix ? "Auto" : "Daylight") && r.amberBlue == (trix ? 0:14) && r.greenMagenta == (trix ? 0:2),"Monochrome WB mismatch")
        check(r.grain == (trix ? 1:nil) && !r.allowPartial,"Grain approximation or acknowledgement mismatch")
        let settings = Dictionary(uniqueKeysWithValues:(r.sourceSettings ?? []).map{($0.key,$0)})
        check(settings["toning"]?.value?.lowercased() == "off","Toning lost")
        check(settings.values.allSatisfy{!$0.needsReview},"Clear reference settings incorrectly flagged")
        if trix {
            let grain=settings["grain"]?.value?.filter{!$0.isWhitespace}.lowercased()
            check(grain == "size2/intensity1","Ricoh grain parameters lost: \(grain ?? "nil")")
            let filter=settings["filterEffect"]?.value?.replacingOccurrences(of:"−",with:"-").filter{!$0.isWhitespace}
            check(filter == "3-R50%/G20%/B-10%","Filter settings lost: \(filter ?? "nil")")
            check(r.effectiveBWFilter == BWFilter(red:50,green:20,blue:-10),"Signed B&W filter was not applied on import")
            check(r.grainSettings == RecipeGrain(mode:.sizeIntensity,intensity:1,size:2),"Independent grain axes were not imported")
            check(r.sourceDisposition(settings["filterEffect"]!).contains("Applied"),"Filter status must describe applied interpretation")
            check(settings["metering"]?.value?.lowercased().contains("matrix") == true,"Metering lost")
            check(settings["highlightDR"] == nil && settings["shadowDR"] == nil && settings["iso"] == nil,"Invented absent rows")
            check(r.sourceOmissions.count == 2 && r.omissions.count == 2,"Grain/filter/detail omissions must be persistent")
        } else {
            for (key,value) in [("highlightDR","On"),("shadowDR","Medium"),("peripheralIllumination","On"),("noiseReduction","Off"),("exposureCompensation","+0.3")] {
                check(settings[key]?.value == value,"Lost capture recommendation: \(key)")
            }
            check(settings["iso"]?.value?.contains("6400") == true,"ISO range lost")
            check(r.sourceOmissions.isEmpty && r.omissions.isEmpty,"Wrong BW800 omissions")
        }
        check(r.cameraShortName.hasSuffix("*") == trix,"Approximate source effects need the camera marker")
        try r.validate()
    }
    static func cinemaFixture(wb: String = "AWB (Warmth Priority) A0 G0") -> [CardTextBlock] {
        var blocks=fixture(wb:wb).filter{$0.y>0.28 || $0.text.contains("RicohCookBook")}
        blocks=blocks.map {b in
            let text=b.text == "NEGATIVE FILM" ? "CINEMA (YELLOW)" : b.text == "Bennet 800" ? "Lanzarote" : b.text == "by Bennet" ? "by I Am a Camera" : b.text
            return CardTextBlock(text:text,x:b.x,y:b.y,width:b.width,height:b.height,confidence:b.confidence)
        }
        let values=["0","-1","+1","0","-2","-1","0","0","0"]
        for i in 0..<9 {
            let x=[0.22,0.50,0.78][i%3],y=[0.59,0.46,0.33][i/3]+0.045
            blocks.removeAll{abs($0.x-x)<0.01 && abs($0.y-y)<0.01}
            blocks.append(.init(text:values[i],x:x,y:y,height:0.035))
        }
        for (i,row) in [("WHITE BALANCE",wb),("TONING","2"),("GRAIN","Size 1 / Intensity 1")].enumerated() {
            let y=0.27-Double(i)*0.04
            blocks.append(.init(text:row.0,x:0.16,y:y));blocks.append(.init(text:row.1,x:0.75,y:y,width:0.4))
        }
        return blocks
    }
    static func verifyCinema(_ r: Recipe) throws {
        check(r.name == "Lanzarote" && r.creator == "I Am a Camera","Cinema identity mismatch")
        check(r.isCinemaYellow && !r.isMonochrome && r.family == "Ricoh GR IV","Cinema mode/family lost")
        check([r.saturation,r.hue,r.key,r.contrast,r.highlights,r.shadows,r.sharpness,r.shading,r.clarity] == [0,-1,1,0,-2,-1,0,0,0],"Cinema adjustments/signs changed")
        check(r.whiteBalance == "Auto (Warmth Priority)" && r.amberBlue == 0 && r.greenMagenta == 0,"Warmth Priority must be retained explicitly")
        check(r.grain == 1 && !r.allowPartial && r.factoryID == nil,"Cinema grain/acknowledgement mismatch")
        let source=Dictionary(uniqueKeysWithValues:(r.sourceSettings ?? []).map{($0.key,$0)})
        check(source["imageControl"]?.value == "Cinema (Yellow)","Original Image Control not retained")
        check(source["toning"]?.value == "2","Source Toning lost")
        check(source["grain"]?.value?.filter{!$0.isWhitespace} == "Size1/Intensity1","Original grain lost")
        check(r.omissions.contains("Cinema (Yellow) base (approximate)") && r.omissions.contains("AWB Warmth Priority (not reproduced)"),"Cinema/WB approximation must be explicit")
        check(r.sourceOmissions.count == 2 && r.omissions.count == 4,"Cinema limitations missing")
        check(r.cameraShortName == "Lanzarote*","Cinema camera label needs partial marker")
        check(r.sourceDisposition(source["whiteBalance"]!).contains("not reproduced"),"Warmth Priority must not be described as fully applied")
        try r.validate()
    }
    static func checkPersistenceAndCompile(_ recipe: Recipe) throws {
        let folder=URL(fileURLWithPath:"/private/tmp/card-import-check-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:folder)}
        let lib=RecipeLibrary(recipes:[recipe]);let path=folder.appendingPathComponent("Recipes.json")
        try lib.save(to:path);let restored=try RecipeLibrary.load(from:path)
        check(restored == lib && restored.recipes[0].omissions == recipe.omissions,"Saved import or warnings changed")
        let resources=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources")
        let compiler=try ProfileCompiler(factoryBook:Data(contentsOf:resources.appendingPathComponent("CFLOOKS.BIN")))
        if !recipe.omissions.isEmpty {rejects("approximate effects require acknowledgement") { _ = try compiler.compile(restored.recipes[0]) }} else {_ = try compiler.compile(restored.recipes[0])}
        var acknowledged=restored.recipes[0];acknowledged.allowPartial=true
        let compiled=try compiler.compile(acknowledged)
        if recipe.isMonochrome {check(compiled.body.u32(768) == 0,"Monochrome compile must have zero saturation")}
        let pack=try compiler.pack(RecipeLibrary(recipes:[acknowledged],slots:[acknowledged.id,nil,nil]))
        try ProfileCompiler.validatePack(pack)
        check(pack.count == 2896,"Camera pack format changed")
    }
    static func main() throws {
        setbuf(stdout,nil)
        let sample = fixture()
        try verifyBennet(RecipeCardImporter.parse(sample,filename:"bennet-800.jpg").recipe)
        let cool = try RecipeCardImporter.parse(fixture(wb:"Shade B4 M3"),filename:"test.jpg").recipe
        check(cool.whiteBalance == "Shade" && cool.amberBlue == -4 && cool.greenMagenta == -3, "Blue/magenta directions reversed")
        let neutral = try RecipeCardImporter.parse(fixture(wb:"Daylight"),filename:"test.jpg").recipe
        check(neutral.amberBlue == 0 && neutral.greenMagenta == 0, "Neutral preset mismatch")
        let zeroOCR = try RecipeCardImporter.parse(fixture(wb:"Auto WB AO GO"),filename:"test.jpg").recipe
        check(zeroOCR.whiteBalance == "Auto" && zeroOCR.amberBlue == 0 && zeroOCR.greenMagenta == 0,"Axis-only OCR zero normalization failed")
        rejects("missing value") { _ = try RecipeCardImporter.parse(sample.filter{!($0.text == "-4")},filename:"test.jpg") }
        rejects("missing label") { _ = try RecipeCardImporter.parse(sample.filter{$0.text != "CLARITY"},filename:"test.jpg") }
        rejects("out-of-range WB") { _ = try RecipeCardImporter.parse(fixture(wb:"Auto WB A15 G2"),filename:"test.jpg") }
        rejects("unknown WB") { _ = try RecipeCardImporter.parse(fixture(wb:"Unknown WB A3 G2"),filename:"test.jpg") }
        rejects("conflicting shift") { _ = try RecipeCardImporter.parse(fixture(wb:"Auto WB A3 B2"),filename:"test.jpg") }
        rejects("unbranded image") { _ = try RecipeCardImporter.parse(sample.filter{!$0.text.contains("RicohCookBook")},filename:"test.jpg") }
        var ambiguous = sample;ambiguous.append(.init(text:"-2",x:0.78,y:0.376,height:0.035))
        rejects("ambiguous value") { _ = try RecipeCardImporter.parse(ambiguous,filename:"test.jpg") }
        var outOfRange = sample;outOfRange.removeAll{$0.text == "+3"};outOfRange.append(.init(text:"+7",x:0.22,y:0.635))
        rejects("out-of-range adjustment") { _ = try RecipeCardImporter.parse(outOfRange,filename:"test.jpg") }
        rejects("missing file") { _ = try RecipeCardImporter.read(URL(fileURLWithPath:"/private/tmp/missing-card-\(UUID()).jpg")) }
        for trix in [true,false] {
            let result=try RecipeCardImporter.parse(monochromeFixture(trix:trix),filename:"mono.jpg")
            try verifyMonochrome(result.recipe,trix:trix)
            try checkPersistenceAndCompile(result.recipe)
        }
        let grainTable=[[1,1,2],[1,2,3],[2,3,3]]
        for size in 1...3 {for intensity in 1...3 {
            check(RecipeGrainMapping.level(size:size,intensity:intensity) == grainTable[size-1][intensity-1],"Grain heuristic table changed")
            check(RecipeGrainMapping.approximate("Size \(size) / Intensity \(intensity)") == grainTable[size-1][intensity-1],"Grain grammar/table mismatch")
        }}
        for (text,value) in [("Off",0),("—",0),("1",1),("Medium",2),("Strong",3),("Size 2 / Intensity 0",0),("Size Large / Strength Weak",2)] {
            check(RecipeGrainMapping.approximate(text) == value,"Grain mapping mismatch")
        }
        for text in ["Size 9 / Intensity 1","Size 2 / Intensity 4","Size 2 / Intensity 1 extra","Size 2","Unknown"] {
            check(RecipeGrainMapping.approximate(text) == nil,"Invalid grain must not be guessed")
        }
        var unsupportedOnly=try RecipeCardImporter.parse(monochromeFixture(trix:true),filename:"test.jpg").recipe
        unsupportedOnly.sharpness=0;unsupportedOnly.clarity=0
        try checkPersistenceAndCompile(unsupportedOnly)
        let mono=monochromeFixture(trix:true)
        // Applicability comes from Image Control, including when pale labels/dashes are not recognized.
        let noColourCells=mono.filter{!["SAT","HUE","—"].contains($0.text)}
        try verifyMonochrome(RecipeCardImporter.parse(noColourCells,filename:"mono.jpg").recipe,trix:true)
        rejects("missing monochrome contrast") { _ = try RecipeCardImporter.parse(mono.filter{$0.text != "CONTRAST"},filename:"test.jpg") }
        var missingColour=sample;missingColour.removeAll{$0.text == "+3"}
        missingColour.append(.init(text:"—",x:0.22,y:0.635))
        rejects("colour saturation dash") { _ = try RecipeCardImporter.parse(missingColour,filename:"test.jpg") }
        var uncertainBase=mono;uncertainBase.append(.init(text:"NEGATIVE FILM",x:0.20,y:0.91))
        rejects("conflicting bases") { _ = try RecipeCardImporter.parse(uncertainBase,filename:"test.jpg") }
        rejects("missing WB") { _ = try RecipeCardImporter.parse(mono.filter{$0.text != "WHITE BALANCE"},filename:"test.jpg") }
        var multiBlock=mono;multiBlock.removeAll{$0.text == "Size 2 / Intensity 1"}
        for (text,x) in [("Size 2",0.55),("/ Intensity 1",0.82)] {multiBlock.append(.init(text:text,x:x,y:0.226,height:0.012))}
        try verifyMonochrome(RecipeCardImporter.parse(multiBlock,filename:"test.jpg").recipe,trix:true)
        let unreadable=mono.filter{$0.text != "Size 2 / Intensity 1"}
        let unreadableRecipe=try RecipeCardImporter.parse(unreadable,filename:"test.jpg").recipe
        check(unreadableRecipe.sourceSettings?.first(where:{$0.key == "grain"})?.needsReview == true,"Unreadable optional row must be visible")
        check(unreadableRecipe.omissions.contains("Review GRAIN"),"Unreadable row must require review")
        var extra=mono;extra.append(.init(text:"CUSTOM EFFECT",x:0.16,y:0.10,height:0.012));extra.append(.init(text:"Special",x:0.75,y:0.10,height:0.012))
        let extraRecipe=try RecipeCardImporter.parse(extra,filename:"test.jpg").recipe
        check(extraRecipe.sourceSettings?.first(where:{$0.key == "other-CUSTOMEFFECT"})?.value == "Special","Unknown row lost")
        check(extraRecipe.omissions.contains("Review CUSTOM EFFECT"),"Unknown setting must not look applied")
        var numericMono=mono;numericMono.append(.init(text:"+2",x:0.22,y:0.635))
        let unexpected=try RecipeCardImporter.parse(numericMono,filename:"test.jpg").recipe
        check(unexpected.saturation == 0 && unexpected.omissions.contains("Review Saturation"),"Unexpected monochrome colour value must be retained for review")
        for base in ["HARD MONOTONE","HI-CONTRAST B&W"] {
            let alternate=mono.map {b in b.text == "MONOTONE" ? CardTextBlock(text:base,x:b.x,y:b.y,height:b.height) : b}
            let alternateRecipe=try RecipeCardImporter.parse(alternate,filename:"test.jpg").recipe
            check(alternateRecipe.isMonochrome,"Monochrome alias not recognized")
        }
        for tone in MonochromeToning.allCases {
            let named=mono.map {b in b.text == "Off" ? CardTextBlock(text:tone.rawValue,x:b.x,y:b.y,width:b.width,height:b.height) : b}
            let recipe=try RecipeCardImporter.parse(named,filename:"named-tone.jpg").recipe
            check(recipe.toning == tone,"Named tone lost on import")
        }
        let unreadableFilter=mono.map {b in b.text == "3 - R 50% / G 20% / B -10%" ? CardTextBlock(text:"3 - R ?% / G 20% / B -10%",x:b.x,y:b.y,width:b.width,height:b.height) : b}
        let retained=try RecipeCardImporter.parse(unreadableFilter,filename:"bad-filter.jpg").recipe
        check(retained.effectiveBWFilter == nil && retained.sourceOmissions.contains("FILTER EFFECT"),"Unrecognised filter must be retained as unapplied")
        var legacy=try JSONSerialization.jsonObject(with:JSONEncoder().encode(RecipeLibrary())) as! [String:Any]
        var oldRecipes=legacy["recipes"] as! [[String:Any]];oldRecipes[0].removeValue(forKey:"sourceSettings");legacy["recipes"]=oldRecipes
        let oldLibrary=try JSONDecoder().decode(RecipeLibrary.self,from:JSONSerialization.data(withJSONObject:legacy))
        check(oldLibrary.recipes[0].sourceSettings == nil,"Old libraries must load without source metadata")
        let cinema=try RecipeCardImporter.parse(cinemaFixture(),filename:"lanzarote-cinema-yellow.jpg").recipe
        check(cinema.toning == nil && cinema.effectiveToning == nil,"Numeric Cinema toning must remain unapplied")
        check(cinema.grainSettings == RecipeGrain(mode:.sizeIntensity,intensity:1,size:1),"Cinema grain axes must survive import")
        try verifyCinema(cinema);try checkPersistenceAndCompile(cinema)
        for wb in ["AWB (Warmth Priority) AO GO","Auto WB (Warm Priority) A0 G0","Auto WB (Warmth Priority) A0 G0"] {
            try verifyCinema(RecipeCardImporter.parse(cinemaFixture(wb:wb),filename:"test.jpg").recipe)
        }
        let compiler=try ProfileCompiler(factoryBook:Data(contentsOf:URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/CFLOOKS.BIN")))
        var auto=cinema;auto.whiteBalance="Auto"
        check(compiler.gains(cinema) == compiler.gains(auto),"Must not invent a scene-dependent WB gain")
        let warm=try compiler.compile(cinema,requireAcknowledgement:false).body
        check(Int32(bitPattern:warm.u32(768+23*4))>0 && Int32(bitPattern:warm.u32(768+24*4))>0 && Int32(bitPattern:warm.u32(768+25*4))<0,"Cinema approximation should warm highlights")
        var manuallyCreated=Recipe();manuallyCreated.base="Cinema (Yellow)"
        rejects("manual Cinema base must require acknowledgement") { _=try compiler.compile(manuallyCreated) }
        manuallyCreated.base="Negative Film";manuallyCreated.whiteBalance="Auto (Warmth Priority)"
        rejects("manual priority mode must require acknowledgement") { _=try compiler.compile(manuallyCreated) }
        let unsupported=cinemaFixture().map {b in b.text == "CINEMA (YELLOW)" ? CardTextBlock(text:"CINEMA (GREEN)",x:b.x,y:b.y,height:b.height) : b}
        do {_ = try RecipeCardImporter.parse(unsupported,filename:"test.jpg");fatalError("Unknown mode must not silently fall back")}
        catch {check(error.localizedDescription.contains("CINEMA (GREEN)") && error.localizedDescription.contains("not supported"),"Unsupported mode should be named clearly")}
        try testPredictableCards()
        // Optional real JPEG exercises image decode, Apple Vision, geometry parsing and library persistence.
        for path in CommandLine.arguments.dropFirst() {
            print("CHECK real \(URL(fileURLWithPath:path).lastPathComponent)")
            let result = try RecipeCardImporter.read(URL(fileURLWithPath:path))
            if ["photo-stuff-leica-look.jpg","candy-color-400.jpg","asakura-negative.jpg","bw-negative-red-filter.jpg"].contains(URL(fileURLWithPath:path).lastPathComponent) {try verifyReportedCard(result.recipe,file:URL(fileURLWithPath:path).lastPathComponent)}
            else if result.recipe.base == "Negative Film" {try verifyBennet(result.recipe)}
            else if result.recipe.isCinemaYellow {try verifyCinema(result.recipe)}
            else {try verifyMonochrome(result.recipe,trix:URL(fileURLWithPath:path).lastPathComponent == "iac-tri-x.jpg")}
            try checkPersistenceAndCompile(result.recipe)
            print("PASS real \(URL(fileURLWithPath:path).lastPathComponent) OCR, values, saved warnings and bounded profile compilation")
        }
        print("PASS colour/monochrome applicability, variable footer, reference/unsupported settings, legacy libraries and strict refusal checks")
    }
}
