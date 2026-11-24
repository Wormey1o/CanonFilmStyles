import Foundation

/// Checks the helper's result against the exported manifest and the observed process exit.
struct HostBatchProtocol {
    private static let phases: Set<String> = [
        "preflight-source", "preflight-resume", "namespace", "source-pin", "space", "reserve",
        "codec", "readback", "receipt", "commit", "resume-proof", "setup", "manifest",
        "finished", "ambiguous-close", "preflight", "admit"
    ]
    static let version = 1
    static let maxOutputBytes: UInt32 = 8 * 1024 * 1024
    enum JobState: String, CaseIterable, Decodable, Sendable {
        case completed = "COMPLETED"
        case off = "SKIPPED_OFF"
        case verified = "SKIPPED_VERIFIED"
        case ineligible = "CLEAN_INELIGIBLE"

        var label: String {
            switch self {
            case .completed: return "Created"
            case .off: return "Grain off"
            case .verified: return "Verified existing"
            case .ineligible: return "Ineligible"
            }
        }
    }

    enum Result: String, Decodable, Sendable {
        case finished = "FINISHED"
        case hold = "HOLD"
        case cancelled = "CANCELLED"
        case invalidManifest = "INVALID_MANIFEST"

        var status: Int32 {
            switch self {
            case .finished: return 0
            case .hold: return 1
            case .cancelled: return 3
            case .invalidManifest: return 2
            }
        }

        var message: String {
            switch self {
            case .finished: return "Host batch finished."
            case .hold: return "Host batch held. Inspect the temporary scratch folder before starting another run."
            case .cancelled: return "Host batch cancelled at a safe stop."
            case .invalidManifest: return "The host helper rejected the manifest. Export a new manifest."
            }
        }
    }

    struct Progress: Sendable {
        let job: Int
        let phase: String
    }

    private struct Record: Decodable {
        enum Kind: String, Decodable { case hello, root, progress, job, result }
        let v: Int
        let type: Kind
        let mode: String?
        let name: String?
        let job: Int?
        let total: Int?
        let phase: String?
        let state: String?
        let bytes: UInt32?
        let readBytes: UInt64?
        let writeBytes: UInt64?
        let hashBytes: UInt64?
    }

    let jobCount: Int
    let restart: String?
    private(set) var ready = false
    private(set) var scratch: String?
    private(set) var progress: Progress?
    private(set) var jobs: [JobState] = []
    private(set) var terminal: Result?
    private(set) var resultPhase: String?
    private(set) var invalid = false
    private var failedJob: Result?
    private var exit: (status: Int32, signalled: Bool)?

    var verifiedResult: Result? {
        guard !invalid, let terminal, let exit,
              !exit.signalled, exit.status == terminal.status else { return nil }
        return terminal
    }

    mutating func consume(_ data: Data) {
        if invalid {
            if !ready, Self.isHello(data) { ready = true }
            return
        }
        guard terminal == nil, String(data: data, encoding: .utf8) != nil,
              let record = try? JSONDecoder().decode(Record.self, from: data),
              record.v == Self.version, ready || record.type == .hello,
              failedJob == nil || record.type == .result else {
            invalid = true
            return
        }

        switch record.type {
        case .hello:
            guard !ready, record.mode == "host-only" else { return reject() }
            ready = true
        case .root:
            guard scratch == nil, let name = record.name, Self.isScratchName(name),
                  restart == nil || restart == name else { return reject() }
            scratch = name
        case .progress:
            guard scratch != nil, let job = record.job, job > jobs.count, job <= jobCount,
                  record.total == jobCount, let phase = record.phase, Self.phases.contains(phase),
                  record.readBytes != nil, record.writeBytes != nil, record.hashBytes != nil else { return reject() }
            progress = Progress(job: job, phase: phase)
        case .job:
            guard scratch != nil, record.job == jobs.count + 1, jobs.count < jobCount,
                  record.total == jobCount, let phase = record.phase, Self.phases.contains(phase),
                  let bytes = record.bytes, bytes <= Self.maxOutputBytes, let state = record.state else {
                return reject()
            }
            if let outcome = JobState(rawValue: state) {
                jobs.append(outcome)
            } else if state == Result.cancelled.rawValue || state == Result.hold.rawValue {
                failedJob = Result(rawValue: state)
            } else {
                reject()
            }
        case .result:
            guard let state = record.state.flatMap(Result.init(rawValue:)),
                  let phase = record.phase, Self.phases.contains(phase),
                  state != .finished || (scratch != nil && jobs.count == jobCount),
                  state != .invalidManifest || scratch == nil,
                  failedJob == nil || state == failedJob || state == .hold else { return reject() }
            terminal = state
            resultPhase = phase
        }
    }

    mutating func reject() {
        invalid = true
    }

    mutating func exited(status: Int32, signalled: Bool) {
        exit = (status, signalled)
    }

    static func isHello(_ data: Data) -> Bool {
        guard String(data: data, encoding: .utf8) != nil,
              let record = try? JSONDecoder().decode(Record.self, from: data) else { return false }
        return record.v == version && record.type == .hello && record.mode == "host-only"
    }

    static func isScratchName(_ name: String) -> Bool {
        let prefix = "canon-idle-batch."
        guard name.hasPrefix(prefix) else { return false }
        let suffix = name.dropFirst(prefix.count).utf8
        return suffix.count == 6 && suffix.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
        }
    }

}
