import Foundation

public enum LibraryConsolidation {
 /// Keep the canonical identities and slots. Differing trial edits get a new identity.
 public static func merge(main:RecipeLibrary,trial:RecipeLibrary)throws->RecipeLibrary {
  try main.validate();try trial.validate();var merged=main
  for var recipe in trial.recipes {
   if let existing=merged.recipes.first(where:{$0.id==recipe.id}) {
    if existing==recipe {continue}
    recipe.id=UUID();recipe.name=String(recipe.name.prefix(16))+" (test)";recipe.shortName=String(recipe.shortName.prefix(14))
   }
   merged.recipes.append(recipe)
  }
  try merged.validate();return merged
 }
 /// An explicit one-time operation, never an automatic startup replacement.
 public static func consolidate(mainURL:URL,trialURL:URL,backupURL:URL)throws->RecipeLibrary {
  let original=try Data(contentsOf:mainURL),trialData=try Data(contentsOf:trialURL)
  let main=try RecipeLibrary.load(from:mainURL),trial=try RecipeLibrary.load(from:trialURL)
  let result=try merge(main:main,trial:trial)
  try FileManager.default.createDirectory(at:backupURL,withIntermediateDirectories:true)
  // Refuse to overwrite an earlier backup. Save both originals before touching the main file.
  let originalBackup=backupURL.appendingPathComponent("Main-Recipes.json"),trialBackup=backupURL.appendingPathComponent("EffectsTest-Recipes.json")
  guard !FileManager.default.fileExists(atPath:originalBackup.path),!FileManager.default.fileExists(atPath:trialBackup.path) else{throw ProfileError.invalid("A consolidation backup already exists at this location.")}
  try original.write(to:originalBackup,options:.withoutOverwriting);try trialData.write(to:trialBackup,options:.withoutOverwriting)
  let proposed=backupURL.appendingPathComponent("Consolidated-Recipes.json");try result.save(to:proposed)
  guard try Data(contentsOf:mainURL)==original,try Data(contentsOf:trialURL)==trialData else{throw ProfileError.invalid("A recipe library changed during consolidation. Close the other app and retry with a new backup location.")}
  try Data(contentsOf:proposed).write(to:mainURL,options:.atomic)
  return result
 }
}
