import CryptoKit
import Darwin
import Foundation

/// Pins explicitly selected host JPEGs and publishes a standalone host manifest.
public enum BatchGrainExporter {
    @discardableResult
    public static func export(sourceRoot: URL, sources: [URL], settings: BatchGrainSettings,
                              to destination: URL) throws -> URL {
        try exportPinned(sourceRoot: sourceRoot, sources: sources, settings: settings, to: destination)
            .manifest
    }

    package struct PinnedExport: Sendable {
        package let manifest: URL
        package let sourceRoot: URL
        package let digest: String
        package let jobCount: Int
    }

    package static func exportPinned(sourceRoot: URL, sources: [URL], settings: BatchGrainSettings,
                                     to destination: URL) throws -> PinnedExport {
        guard (1...BatchGrainManifest.maxJobs).contains(sources.count) else {
            throw ProfileError.invalid("Choose 1 through \(BatchGrainManifest.maxJobs) JPEGs for this batch.")
        }
        let (sourceRoot, sourceDirectory) = try openHostDirectory(sourceRoot)
        defer { _ = Darwin.close(sourceDirectory) }
        let sourcePrefix = sourceRoot.path == "/" ? "/" : sourceRoot.path + "/"

        var jobs: [BatchGrainJob] = []
        for selected in sources {
            guard selected.isFileURL, selected.path.hasPrefix(sourcePrefix) else {
                throw ProfileError.invalid("Every JPEG must be inside the selected host source folder.")
            }
            let path = String(selected.path.dropFirst(sourcePrefix.count))
            try BatchGrainManifest.validatePath(path)
            jobs.append(try pin(path, in: sourceDirectory, settings: settings))
        }
        let manifest = try BatchGrainManifest.encode(jobs)
        guard destination.isFileURL, destination.pathExtension.lowercased() == "cbatch",
              !destination.lastPathComponent.utf8.contains(0) else {
            throw ProfileError.invalid("Choose a host .cbatch destination.")
        }
        let (_, outputDirectory) = try openHostDirectory(destination.deletingLastPathComponent())
        defer { _ = Darwin.close(outputDirectory) }
        try publish(manifest, name: destination.lastPathComponent, in: outputDirectory)
        let digest = SHA256.hash(data: manifest).map { String(format: "%02x", $0) }.joined()
        return PinnedExport(manifest: destination, sourceRoot: sourceRoot, digest: digest, jobCount: jobs.count)
    }

    private static func openHostDirectory(_ url: URL) throws -> (URL, Int32) {
        guard url.isFileURL, url.path.hasPrefix("/"), !url.path.utf8.contains(0) else {
            throw ProfileError.invalid("Choose a folder on the internal Mac drive.")
        }
        // Walk the original components so a symlink cannot redirect the operation.
        let components = url.path.split(separator: "/").map(String.init)
        guard !components.contains("."), !components.contains(".."), components.first?.lowercased() != "volumes" else {
            throw ProfileError.invalid("Choose a folder on the internal Mac drive.")
        }
        let directory = try openRelative(components, in: AT_FDCWD, absolute: true)
        do {
            var mount = statfs()
            guard fstatfs(directory, &mount) == 0, mount.f_flags & UInt32(MNT_LOCAL) != 0 else {
                throw ProfileError.invalid("Choose a local internal Mac drive.")
            }
            let values = try url.resourceValues(forKeys: [.volumeIsInternalKey, .volumeIsLocalKey])
            guard values.volumeIsInternal == true, values.volumeIsLocal == true else {
                throw ProfileError.invalid("Choose a local internal Mac drive.")
            }
            var anchored = stat(), current = stat()
            guard fstat(directory, &anchored) == 0, lstat(url.path, &current) == 0, sameFile(anchored, current) else {
                throw ProfileError.invalid("The host folder changed. Select it again.")
            }
            return (url, directory)
        } catch {
            _ = Darwin.close(directory)
            throw error
        }
    }

    private static func openRelative(_ components: [String], in parent: Int32,
                                     absolute: Bool = false, file: Bool = false) throws -> Int32 {
        let directoryFlags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        var descriptor = absolute ? Darwin.open("/", directoryFlags) : dup(parent)
        guard descriptor >= 0 else { throw ioError("Open host folder") }
        for (index, component) in components.enumerated() {
            let flags = file && index == components.count - 1
                ? O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC : directoryFlags
            let next = openat(descriptor, component, flags)
            let openError = errno
            let closed = Darwin.close(descriptor)
            if next < 0 { throw ioError("Open \(component)", code: openError) }
            if closed != 0 {
                let closeError = errno
                _ = Darwin.close(next)
                throw ioError("Close host folder", code: closeError)
            }
            descriptor = next
        }
        return descriptor
    }

    private static func pin(_ path: String, in directory: Int32,
                            settings: BatchGrainSettings) throws -> BatchGrainJob {
        let components = path.split(separator: "/").map(String.init)
        let descriptor = try openRelative(components, in: directory, file: true)
        let job: BatchGrainJob
        var before = stat()
        do {
            var root = stat()
            guard fstat(directory, &root) == 0, fstat(descriptor, &before) == 0,
                  root.st_dev == before.st_dev, before.st_mode & S_IFMT == S_IFREG, before.st_nlink == 1,
                  (1...Int64(BatchGrainManifest.maxSourceBytes)).contains(before.st_size) else {
                throw ProfileError.invalid("Choose a regular JPEG on the source drive, with one link and a size of 1 byte through 32 MiB: \(path)")
            }
            var hasher = SHA256()
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            var bytes = 0
            while true {
                let read = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
                if read < 0 { throw ioError("Read \(path)") }
                if read == 0 { break }
                bytes += read
                guard bytes <= before.st_size else { throw sourceChanged(path) }
                hasher.update(data: buffer.prefix(read))
            }
            var after = stat()
            guard bytes == before.st_size, fstat(descriptor, &after) == 0, unchanged(before, after) else {
                throw sourceChanged(path)
            }
            job = try BatchGrainJob(path: path, sourceBytes: UInt32(bytes),
                                   sourceSHA256: Data(hasher.finalize()), settings: settings)
        } catch {
            _ = Darwin.close(descriptor)
            throw error
        }
        guard Darwin.close(descriptor) == 0 else { throw ioError("Close \(path)") }
        let current = try openRelative(components, in: directory, file: true)
        var after = stat()
        let matches = fstat(current, &after) == 0 && unchanged(before, after)
        guard Darwin.close(current) == 0 else { throw ioError("Close \(path)") }
        guard matches else { throw sourceChanged(path) }
        return job
    }

    private static func sameFile(_ old: stat, _ new: stat) -> Bool {
        old.st_dev == new.st_dev && old.st_ino == new.st_ino
    }

    private static func unchanged(_ old: stat, _ new: stat) -> Bool {
        sameFile(old, new) && old.st_size == new.st_size && old.st_nlink == new.st_nlink &&
        old.st_mtimespec.tv_sec == new.st_mtimespec.tv_sec && old.st_mtimespec.tv_nsec == new.st_mtimespec.tv_nsec &&
        old.st_ctimespec.tv_sec == new.st_ctimespec.tv_sec && old.st_ctimespec.tv_nsec == new.st_ctimespec.tv_nsec
    }

    private static func publish(_ data: Data, name: String, in directory: Int32) throws {
        let staging = ".canon-idle-batch-" + UUID().uuidString
        let descriptor = openat(directory, staging, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw ioError("Create temporary manifest") }
        var published = false
        defer {
            if !published { _ = unlinkat(directory, staging, 0) }
        }

        let wrote = data.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
        let writeError = wrote < 0 ? errno : EIO
        let synced = wrote == data.count ? fsync(descriptor) : -1
        let syncError = errno
        let closed = Darwin.close(descriptor)
        guard wrote == data.count else { throw ioError("Write manifest", code: writeError) }
        guard synced == 0 else { throw ioError("Sync manifest", code: syncError) }
        guard closed == 0 else { throw ioError("Close manifest") }
        guard renameatx_np(directory, staging, directory, name, UInt32(RENAME_EXCL)) == 0 else {
            throw ioError("Publish manifest")
        }
        published = true
    }

    private static func sourceChanged(_ path: String) -> ProfileError {
        .invalid("The source changed while being pinned: \(path)")
    }

    private static func ioError(_ operation: String, code: Int32 = errno) -> ProfileError {
        .invalid("\(operation): \(String(cString: strerror(code)))")
    }
}
