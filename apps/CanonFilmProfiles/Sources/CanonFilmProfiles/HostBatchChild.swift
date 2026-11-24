import Darwin
import Foundation

/// Owns a single direct child and drains both pipes before announcing completion.
@MainActor
final class HostBatchChild {
    enum Event: Sendable {
        case record(Data, acknowledgement: DispatchSemaphore)
        case invalidOutput
        case diagnostic(String)
        case exit(status: Int32, signalled: Bool)
    }

    private let process: Process
    let events: AsyncStream<Event>

    init(executable: URL, arguments: [String]) throws {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        let (events, stream) = AsyncStream<Event>.makeStream()
        let work = DispatchGroup()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
        process.environment = ["LC_ALL": "C"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdout
        process.standardError = stderr
        work.enter()
        process.terminationHandler = { @Sendable child in
            stream.yield(.exit(status: child.terminationStatus, signalled: child.terminationReason == .uncaughtSignal))
            work.leave()
        }

        try process.run()
        self.process = process
        self.events = events

        work.enter()
        DispatchQueue.global(qos: .userInitiated).async { @Sendable in
            let pipe = stdout.fileHandleForReading
            drainRecords(pipe, into: stream)
            try? pipe.close()
            work.leave()
        }
        work.enter()
        DispatchQueue.global(qos: .utility).async { @Sendable in
            let pipe = stderr.fileHandleForReading
            drainDiagnostic(read: { try readPipeChunk(pipe) }, into: stream)
            try? pipe.close()
            work.leave()
        }
        work.notify(queue: .global(qos: .utility)) { @Sendable in stream.finish() }
    }

    func interrupt() {
        if process.isRunning { process.interrupt() }
    }
}

private func drainRecords(_ pipe: FileHandle, into stream: AsyncStream<HostBatchChild.Event>.Continuation) {
    let maxLine = 8 * 1024
    let maxTotal = 16 * 1024 * 1024
    var line = Data()
    var total = 0
    let acknowledgement = DispatchSemaphore(value: 0)
    var invalid = false
    var skipLine = false
    var readySeen = false

    func markInvalid() {
        if !invalid {
            invalid = true
            stream.yield(.invalidOutput)
        }
    }

    do {
        while let chunk = try readPipeChunk(pipe), !chunk.isEmpty {
            if invalid && readySeen { continue }
            for byte in chunk {
                if !invalid {
                    total += 1
                    if total > maxTotal { markInvalid() }
                }
                if byte != 10 {
                    if skipLine { continue }
                    if line.count == maxLine {
                        markInvalid()
                        line.removeAll(keepingCapacity: true)
                        skipLine = true
                    } else {
                        line.append(byte)
                    }
                    continue
                }

                if skipLine {
                    skipLine = false
                    continue
                }
                if line.isEmpty {
                    markInvalid()
                    continue
                }
                let isHello = !readySeen && HostBatchProtocol.isHello(line)
                if !invalid || isHello {
                    // Keep at most one queued stdout record while stderr drains independently.
                    if case .terminated = stream.yield(.record(line, acknowledgement: acknowledgement)) {
                        return
                    }
                    acknowledgement.wait()
                }
                line.removeAll(keepingCapacity: true)
                readySeen = readySeen || isHello
                if invalid && readySeen { break }
            }
        }
        if !line.isEmpty { markInvalid() }
    } catch {
        markInvalid()
    }
}

func drainDiagnostic(read: () throws -> Data?, into stream: AsyncStream<HostBatchChild.Event>.Continuation) {
    let limit = 64 * 1024
    var captured = Data()
    var truncated = false
    do {
        while let chunk = try read(), !chunk.isEmpty {
            let remaining = limit - captured.count
            captured.append(contentsOf: chunk.prefix(remaining))
            truncated = truncated || chunk.count > remaining
        }
    } catch {
        stream.yield(.invalidOutput)
        truncated = true
    }
    if !captured.isEmpty || truncated {
        let suffix = truncated ? "\n[Helper diagnostics truncated]" : ""
        stream.yield(.diagnostic(String(decoding: captured, as: UTF8.self) + suffix))
    }
}

private func readPipeChunk(_ pipe: FileHandle) throws -> Data? {
    // A single blocking read returns available bytes immediately, even for a short hello record.
    var buffer = [UInt8](repeating: 0, count: 4_096)
    let descriptor = pipe.fileDescriptor
    while true {
        let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
        if count > 0 { return Data(buffer.prefix(count)) }
        if count == 0 { return nil }
        if errno != EINTR { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
}
