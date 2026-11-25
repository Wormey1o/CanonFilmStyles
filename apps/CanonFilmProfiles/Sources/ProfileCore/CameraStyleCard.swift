import Foundation
import Darwin
import DiskArbitration
import IOKit

/// Finds the 450D's camera card among mounted volumes for "Copy to card".
/// A camera card is a removable or ejectable, non-internal FAT volume with AUTOEXEC.BIN in its root.
/// Only the camera extensions that read CFPSTYLE.BIN are accepted as copy targets.
public enum CameraStyleCard {
    public enum InstallTrigger: Equatable, Sendable {
        /// v3: installs at the first User Def. selection after the file changes.
        case firstUserDefSelection
        /// v1 and v2: Standard, Standard, then User Def. 3 after power-on.
        case gesture
    }

    public struct KnownExtension: Equatable, Sendable {
        public let name: String
        public let trigger: InstallTrigger
    }

    /// AUTOEXEC.BIN builds that read CFPSTYLE.BIN (pinned by SHA-256).
    public static let knownExtensions: [String: KnownExtension] = [
        "9ec66f5ee38d8f74bf415b67231532f1cd14d7209cfaf45234b5d771de407fda": KnownExtension(name: "style extension v3", trigger: .firstUserDefSelection),
        "eff33121e1b7cc58a18c2b7e999e86bbdda76144dcc20afe7f694c9e2ea39266": KnownExtension(name: "style extension v2", trigger: .gesture),
        "56884c0b04ad477285df3cc712c926503462f52e60781fce680a159f5c4843fd": KnownExtension(name: "style extension v1", trigger: .gesture),
    ]

    public struct Card: Equatable, Sendable {
        public let root: URL
        public let volumeName: String
        public let extensionSHA256: String
        public let knownExtension: KnownExtension?
        fileprivate let identity: DirectoryIdentity
        fileprivate let mediaID: UInt64?
    }

    fileprivate struct DirectoryIdentity: Equatable, Sendable {
        let device: dev_t
        let inode: ino_t
        let fileSystem: Data
        let source: String
        let format: String

        init?(_ fd: Int32) {
            var info = stat()
            var volume = statfs()
            guard fstat(fd, &info) == 0, fstatfs(fd, &volume) == 0 else { return nil }
            device = info.st_dev
            inode = info.st_ino
            fileSystem = withUnsafeBytes(of: volume.f_fsid) { Data($0) }
            source = withUnsafeBytes(of: volume.f_mntfromname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            format = withUnsafeBytes(of: volume.f_fstypename) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        }
    }

    static let extensionFile = "AUTOEXEC.BIN"
    static let maximumExtensionBytes = 262_144

    private static func openDirectory(_ root: URL) -> Int32 {
        open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    }

    /// Reads a bounded regular file relative to an already selected directory.
    static func readFile(_ name: String, in fd: Int32, maximum: Int) throws -> Data {
        let file = openat(fd, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard file >= 0 else { throw failure("open \(name)") }
        let handle = FileHandle(fileDescriptor: file, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(file, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size >= 0, info.st_size <= maximum else {
            throw ProfileError.invalid("Unexpected type or size for \(name).")
        }
        let data = try handle.read(upToCount: maximum + 1) ?? Data()
        guard data.count == Int(info.st_size) else { throw ProfileError.invalid("\(name) changed while reading.") }
        return data
    }

    static func failure(_ operation: String) -> ProfileError {
        .invalid("Could not \(operation): \(String(cString: strerror(errno))).")
    }

    /// Inspect one folder as a possible camera card. The non-FAT mode is for owned fixtures only.
    public static func inspect(_ root: URL, requireRemovableFAT: Bool = true) -> Card? {
        let fd = openDirectory(root)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        guard let identity = DirectoryIdentity(fd) else { return nil }
        var mediaID: UInt64?
        if requireRemovableFAT {
            guard identity.format == "msdos" else { return nil }
            let keys: Set<URLResourceKey> = [.volumeIsInternalKey, .volumeIsRemovableKey, .volumeIsEjectableKey]
            guard let v = try? root.resourceValues(forKeys: keys), v.volumeIsInternal != true,
                  v.volumeIsRemovable == true || v.volumeIsEjectable == true,
                  let session = DASessionCreate(nil),
                  let disk = diskAtMountSource(identity, session: session),
                  let id = registryID(of: disk) else { return nil }
            mediaID = id
        }
        guard let data = try? readFile(extensionFile, in: fd, maximum: maximumExtensionBytes),
              !data.isEmpty else { return nil }
        let digest = sha256(data)
        let name = (try? root.resourceValues(forKeys: [.volumeNameKey]).volumeName) ?? nil
        let current = openDirectory(root)
        guard current >= 0 else { return nil }
        defer { close(current) }
        guard DirectoryIdentity(current) == identity else { return nil }
        return Card(root: root, volumeName: name ?? root.lastPathComponent, extensionSHA256: digest,
                    knownExtension: knownExtensions[digest], identity: identity, mediaID: mediaID)
    }

    private static var changedCard: ProfileError {
        .invalid("The selected camera card changed or left the reader. Check the card before trying again.")
    }

    private static func diskAtMountSource(_ identity: DirectoryIdentity, session: DASession) -> DADisk? {
        guard identity.source.hasPrefix("/dev/disk") else { return nil }
        return identity.source.withCString { DADiskCreateFromBSDName(nil, session, $0) }
    }

    private static func registryID(of disk: DADisk) -> UInt64? {
        let media = DADiskCopyIOMedia(disk)
        guard media != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(media) }
        var id: UInt64 = 0
        return IORegistryEntryGetRegistryEntryID(media, &id) == KERN_SUCCESS ? id : nil
    }

    /// The mount path is only an entry point. All writes use the returned, identity-checked descriptor.
    static func withSelectedDirectory<T>(_ card: Card, _ body: (Int32) throws -> T) throws -> T {
        let fd = openDirectory(card.root)
        guard fd >= 0 else { throw changedCard }
        defer { close(fd) }
        guard card.knownExtension != nil, DirectoryIdentity(fd) == card.identity else { throw changedCard }
        try requireCurrent(card, runtimeIn: fd)
        return try body(fd)
    }

    static func requireCurrent(_ card: Card, runtimeIn fd: Int32? = nil) throws {
        let current = openDirectory(card.root)
        guard current >= 0 else { throw changedCard }
        defer { close(current) }
        guard DirectoryIdentity(current) == card.identity else { throw changedCard }
        if let mediaID = card.mediaID {
            guard let session = DASessionCreate(nil), let disk = diskAtMountSource(card.identity, session: session),
                  registryID(of: disk) == mediaID else { throw changedCard }
        }
        if let fd {
            guard let image = try? readFile(extensionFile, in: fd, maximum: maximumExtensionBytes),
                  sha256(image) == card.extensionSHA256 else { throw changedCard }
        }
    }

    /// Ejects the selected IOKit media through Disk Arbitration, rather than resolving the mount path again.
    package static func eject(_ card: Card) async throws {
        guard let mediaID = card.mediaID, let session = DASessionCreate(nil) else { throw changedCard }
        try withSelectedDirectory(card) { _ in }
        guard let volume = diskAtMountSource(card.identity, session: session), registryID(of: volume) == mediaID,
              let whole = DADiskCopyWholeDisk(volume), let wholeID = registryID(of: whole),
              let wholeName = DADiskGetBSDName(whole).map({ String(cString: $0) }) else { throw changedCard }

        DASessionSetDispatchQueue(session, DispatchQueue.global(qos: .utility))
        defer { DASessionSetDispatchQueue(session, nil) }
        try await performDiskOperation(volume, eject: false)
        let currentWhole = wholeName.withCString { DADiskCreateFromBSDName(nil, session, $0) }
        guard let currentWhole, registryID(of: currentWhole) == wholeID else { throw changedCard }
        try await performDiskOperation(whole, eject: true)
    }

    private static func performDiskOperation(_ disk: DADisk, eject: Bool) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let context = Unmanaged.passRetained(DiskCompletion(continuation)).toOpaque()
            let callback: DADiskUnmountCallback = { _, dissenter, context in
                guard let context else { return }
                let completion = Unmanaged<DiskCompletion>.fromOpaque(context).takeRetainedValue()
                if let dissenter {
                    let detail = DADissenterGetStatusString(dissenter).map { $0 as String }
                    completion.continuation.resume(throwing: ProfileError.invalid(detail ?? "macOS declined the card operation (\(DADissenterGetStatus(dissenter)))."))
                } else {
                    completion.continuation.resume()
                }
            }
            if eject {
                DADiskEject(disk, DADiskEjectOptions(kDADiskEjectOptionDefault), callback, context)
            } else {
                DADiskUnmount(disk, DADiskUnmountOptions(kDADiskUnmountOptionDefault), callback, context)
            }
        }
    }

    private final class DiskCompletion {
        let continuation: CheckedContinuation<Void, Error>
        init(_ continuation: CheckedContinuation<Void, Error>) { self.continuation = continuation }
    }

    /// All mounted camera cards.
    public static func find() -> [Card] {
        let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]) ?? []
        return volumes.compactMap { inspect($0) }
    }

    public enum Choice: Equatable, Sendable {
        case card(Card)
        case problem(String)
    }

    /// The single card to copy to, or the reason there is none.
    public static func choose(_ cards: [Card]) -> Choice {
        let usable = cards.filter { $0.knownExtension != nil }
        if usable.count == 1 { return .card(usable[0]) }
        if usable.count > 1 {
            return .problem("More than one camera card is mounted (\(usable.map(\.volumeName).joined(separator: ", "))). Leave only the one you want in the reader.")
        }
        if let other = cards.first {
            return .problem("\(other.volumeName) has a camera extension (AUTOEXEC.BIN \(other.extensionSHA256.prefix(8))…) that does not read CFPSTYLE.BIN. Nothing was copied. Use “Export extension card file…” if you really want the file there.")
        }
        return .problem("No camera card found. Insert the 450D card (a FAT card with AUTOEXEC.BIN on it) in the reader, wait for it to appear in Finder, then try again.")
    }

    /// What to do on the camera after a copy.
    public static func cameraSteps(_ ext: KnownExtension) -> String {
        switch ext.trigger {
        case .firstUserDefSelection:
            return "On the camera: switch on in P or Av outside Live View and select a User Def. slot. If already selected, select Standard first. One long pulse then three long pulses confirms an install. If it stays silent, check the style and white balance on the camera."
        case .gesture:
            return "On the camera: insert the card, switch on, then select Standard twice and User Def. 3 to install. Three long pulses means the styles are installed."
        }
    }
}
