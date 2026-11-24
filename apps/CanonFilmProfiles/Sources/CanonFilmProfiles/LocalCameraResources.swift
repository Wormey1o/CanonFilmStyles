import Foundation
import ProfileCore

enum LocalCameraResources {
 private static let effectsManifest = "FirmwareSupport.json"
 private static let effectsRuntime = "AUTOEXEC.BIN"

 static func hasEffects(in directory: URL?) -> Bool {
  guard let directory else {return false}
  return [effectsManifest,effectsRuntime].allSatisfy {
   FileManager.default.isReadableFile(atPath:directory.appendingPathComponent($0).path)
  }
 }

 static func loadEffects(in directory: URL?) throws -> (FirmwareSupport, Data) {
  guard let directory, hasEffects(in:directory) else {
   throw ProfileError.invalid("The matching Effects runtime is unavailable in this build.")
  }
  let manifest=try Data(contentsOf:directory.appendingPathComponent(effectsManifest))
  let support=try JSONDecoder().decode(FirmwareSupport.self,from:manifest)
  guard support.payloadFile == effectsRuntime else {throw ProfileError.invalid("Invalid Effects runtime manifest.")}
  return (support,try Data(contentsOf:directory.appendingPathComponent(effectsRuntime)))
 }
}
