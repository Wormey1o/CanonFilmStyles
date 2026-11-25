import Darwin
import Foundation

/// Card writes stay relative to the selected mount's open descriptor, including staging and cleanup.
enum CameraStyleCardFiles {
    static func publish(_ outputs: [(name: String, data: Data)], to card: CameraStyleCard.Card) throws -> [String] {
        try CameraStyleCard.withSelectedDirectory(card) { root in
            guard flock(root, LOCK_EX | LOCK_NB) == 0 else { throw CameraStyleCard.failure("lock the camera card") }
            for output in outputs { try checkDestination(output.name, in: root) }

            let folder = ".canon-style-export-" + UUID().uuidString
            guard mkdirat(root, folder, 0o700) == 0 else { throw CameraStyleCard.failure("create card staging directory") }
            defer { _ = unlinkat(root, folder, AT_REMOVEDIR) }
            let staging = openat(root, folder, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard staging >= 0 else { throw CameraStyleCard.failure("open card staging directory") }
            defer {
                for output in outputs {
                    _ = unlinkat(staging, output.name, 0)
                    _ = unlinkat(staging, "._" + output.name, 0)
                }
                close(staging)
                _ = unlinkat(root, "._" + folder, 0)
            }
            for output in outputs {
                try write(output.data, as: output.name, in: staging)
                try removeGeneratedSidecar(output.name, in: staging)
            }

            var published: [String] = []
            do {
                try CameraStyleCard.requireCurrent(card, runtimeIn: root)
                for output in outputs { try checkDestination(output.name, in: root) }
                for output in outputs {
                    try CameraStyleCard.requireCurrent(card)
                    try checkDestination(output.name, in: root)
                    guard renameat(staging, output.name, root, output.name) == 0 else {
                        throw CameraStyleCard.failure("replace \(output.name) on the card")
                    }
                    published.append(output.name)
                    try verify(output, in: root)
                    // FAT may create provenance metadata during rename. The immediately
                    // preceding preflight established that this exact sidecar was absent.
                    try removeGeneratedSidecar(output.name, in: root)
                }
                try CameraStyleCard.requireCurrent(card)
                return published
            } catch {
                throw CameraStyleCardExporter.ExportFailure(publishedFiles: published, cause: error)
            }
        }
    }

    private static func inspect(_ name: String, in directory: Int32) throws -> mode_t? {
        var info = stat()
        if fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0 { return info.st_mode }
        guard errno == ENOENT else { throw CameraStyleCard.failure("inspect \(name) on the card") }
        return nil
    }

    private static func checkDestination(_ name: String, in directory: Int32) throws {
        if let mode = try inspect(name, in: directory), mode & S_IFMT != S_IFREG {
            throw ProfileError.invalid("\(name) on the card is not a regular file.")
        }
        try checkSidecar(name, in: directory)
    }

    private static func checkSidecar(_ name: String, in directory: Int32) throws {
        let sidecar = "._" + name
        if try inspect(sidecar, in: directory) != nil {
            throw ProfileError.invalid("Found \(sidecar) on the card. Check or back it up before removing it.")
        }
    }

    private static func removeGeneratedSidecar(_ name: String, in directory: Int32) throws {
        let sidecar = "._" + name
        guard unlinkat(directory, sidecar, 0) == 0 || errno == ENOENT else {
            throw CameraStyleCard.failure("remove generated \(sidecar) on the card")
        }
        try checkSidecar(name, in: directory)
    }

    private static func write(_ data: Data, as name: String, in directory: Int32) throws {
        let fd = openat(directory, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw CameraStyleCard.failure("stage \(name) on the card") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        try handle.write(contentsOf: data)
        try handle.synchronize()
        try handle.close()
        try verify((name, data), in: directory)
    }

    private static func verify(_ output: (name: String, data: Data), in directory: Int32) throws {
        guard try CameraStyleCard.readFile(output.name, in: directory, maximum: output.data.count) == output.data else {
            throw ProfileError.invalid("\(output.name) did not read back identically.")
        }
    }
}
