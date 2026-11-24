import Foundation

/// Capture both streams in files so a child can finish even when either stream is noisy.
package struct ProcessOutput {
 package let status: Int32
 package let stdout: Data
 package let stderr: Data

 package static func capture(executable: URL, arguments: [String]) throws -> ProcessOutput {
  let work = try PrivateWorkDirectory()
  defer { work.remove() }
  let outURL = work.url.appendingPathComponent("stdout")
  let errURL = work.url.appendingPathComponent("stderr")
  try work.writeNew(Data(), to: outURL)
  try work.writeNew(Data(), to: errURL)
  let out = try FileHandle(forWritingTo: outURL)
  defer { try? out.close() }
  let err = try FileHandle(forWritingTo: errURL)
  defer { try? err.close() }

  let child = Process()
  child.executableURL = executable
  child.arguments = arguments
  child.standardInput = FileHandle.nullDevice
  child.standardOutput = out
  child.standardError = err
  try child.run()
  child.waitUntilExit()
  return try ProcessOutput(status: child.terminationStatus, stdout: Data(contentsOf: outURL),
                           stderr: Data(contentsOf: errURL))
 }
}
