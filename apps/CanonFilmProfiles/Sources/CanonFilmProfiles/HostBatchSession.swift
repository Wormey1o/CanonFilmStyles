import Combine
import CryptoKit
import Foundation

struct HostBatchRequest: Equatable, Sendable {
    let manifest: URL
    let sourceRoot: URL
    let digest: String
    let jobCount: Int
}

enum HostBatchHelper {
    private struct Metadata: Decodable {
        let protocolVersion: Int
        let helperSHA256: String
    }

    static func executable(in bundleURL: URL) throws -> URL {
        let bundle = bundleURL.resolvingSymlinksInPath()
        let executable = bundle.appendingPathComponent("Contents/Helpers/CanonBatchHost")
        let metadata = bundle.appendingPathComponent("Contents/Resources/HostBatchHelper.json")
        guard executable == executable.resolvingSymlinksInPath(),
              metadata == metadata.resolvingSymlinksInPath(),
              FileManager.default.isExecutableFile(atPath: executable.path),
              let record = try? JSONDecoder().decode(Metadata.self, from: read(metadata, maximum: 64 * 1024)),
              record.protocolVersion == HostBatchProtocol.version,
              let bytes = try? read(executable, maximum: 16 * 1024 * 1024),
              digest(bytes) == record.helperSHA256 else {
            throw Failure.unavailable
        }
        return executable
    }

    private static func read(_ url: URL, maximum: Int) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let size = values.fileSize, (1...maximum).contains(size) else {
            throw Failure.unavailable
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard let data = try handle.read(upToCount: maximum + 1), data.count == size else {
            throw Failure.unavailable
        }
        return data
    }

    static func digest(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    private enum Failure: LocalizedError {
        case unavailable

        var errorDescription: String? {
            "The bundled host batch helper is missing or failed verification. Use a packaged copy of Canon Film Profiles."
        }
    }
}

/// One session for the app. The owning model outlives recipe selection and editor views.
@MainActor
final class HostBatchSession: ObservableObject {
    @Published private(set) var request: HostBatchRequest?
    @Published private(set) var report: HostBatchProtocol?
    @Published private(set) var isActive = false
    @Published private(set) var cancelRequested = false
    @Published private(set) var diagnostic: String?
    @Published private(set) var message: String?
    @Published private(set) var hasRun = false

    private let bundleURL: URL
    private var child: HostBatchChild?
    private var sentInterrupt = false
    private var canLaunchFresh = true
    private var canRestart = false

    init(bundleURL: URL = Bundle.main.bundleURL) {
        self.bundleURL = bundleURL
    }

    var canQuit: Bool { !isActive }
    var readyToRun: Bool { request != nil && !isActive && canLaunchFresh }
    var readyToRestart: Bool { !isActive && canRestart && report?.scratch != nil }

    var scratchPath: String? {
        (report?.scratch ?? report?.restart).map { "/private/tmp/" + $0 }
    }

    func prepare(_ request: HostBatchRequest) {
        guard !isActive else { return }
        self.request = request
        report = nil
        diagnostic = nil
        message = nil
        cancelRequested = false
        hasRun = false
        canLaunchFresh = true
        canRestart = false
    }

    func run() {
        guard readyToRun else { return }
        start(restart: nil)
    }

    func restart() {
        guard readyToRestart, let name = report?.scratch, HostBatchProtocol.isScratchName(name) else { return }
        start(restart: name)
    }

    func cancel() {
        guard isActive, report?.terminal == nil else { return }
        cancelRequested = true
        interruptIfReady()
    }

    private func start(restart: String?) {
        guard !isActive, let request else { return }
        hasRun = true
        do {
            let executable = try HostBatchHelper.executable(in: bundleURL)
            var arguments = ["run-json", request.manifest.path, request.sourceRoot.path, request.digest]
            if let restart { arguments.append(restart) }
            let launched = try HostBatchChild(executable: executable, arguments: arguments)

            child = launched
            report = HostBatchProtocol(jobCount: request.jobCount, restart: restart)
            diagnostic = nil
            message = nil
            cancelRequested = false
            sentInterrupt = false
            canLaunchFresh = false
            canRestart = false
            isActive = true
            // Deliberately retain this session until the child exits and both pipes drain.
            Task {
                for await event in launched.events { consume(event) }
                retire()
            }
        } catch {
            message = error.localizedDescription
        }
    }

    private func consume(_ event: HostBatchChild.Event) {
        switch event {
        case .record(let bytes, let acknowledgement):
            report?.consume(bytes)
            acknowledgement.signal()
        case .invalidOutput:
            report?.reject()
        case .diagnostic(let text):
            diagnostic = text
        case .exit(let status, let signalled):
            report?.exited(status: status, signalled: signalled)
        }
        if report?.invalid == true { cancelRequested = true }
        interruptIfReady()
    }

    private func interruptIfReady() {
        guard cancelRequested, !sentInterrupt, report?.ready == true, let child else { return }
        sentInterrupt = true
        child.interrupt()
    }

    private func retire() {
        child = nil
        if let result = report?.verifiedResult {
            message = result == .hold && scratchPath == nil
                ? "Host batch held during setup or validation." : result.message
            canRestart = result == .finished || result == .cancelled
        } else {
            message = "Host batch held. The helper’s final status could not be verified."
        }
        isActive = false
        cancelRequested = false
    }
}
