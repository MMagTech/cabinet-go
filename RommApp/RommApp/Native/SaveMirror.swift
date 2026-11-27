import Foundation

/// RomM's saves for a game as the phone last saw them, so a start with no
/// connection goes by the same rule as one online (SavePick), and the
/// phone's own note of the snapshot it holds. Port of CabinetOS's
/// `savemirror` (frontend/src/savemirror.h).
///
/// WHAT IT KEEPS, per game: the person's channels as RomM listed them, each
/// with its current snapshot, in RomM's own form (`channels.json`); the
/// game's saves as RomM listed them, for another app's saves outside the
/// channels (`rows.json`); the bytes of the saves in those snapshots, by
/// their content hash (`snapshot-<hash>.bin`), so the same bytes in two
/// channels are kept once; the files the game's channels can be on
/// (`files.json`); and THE SNAPSHOT THE PHONE HOLDS (`held.json`), the one
/// it last started from or pushed, which is the phone's own note and not a
/// copy of RomM's.
///
/// WHY IT CAN NEVER BE OLDER THAN A SAVE THE PHONE SENT: a push that lands
/// forgets the game's copy before anything else and lists again after
/// (SavePush.send), and a start lists only after any push of the game in
/// flight has finished (SavePush.oneAtATime), so nothing lists while the
/// copy is changing.
///
/// Where: Application Support `SaveChannels/<romId>/`, beside the game's owed
/// push and its states (SavePush, GameSaves), out of the Files mirror and
/// the backup. Each file is written whole and atomically, so a kill leaves
/// the one before.
struct SaveMirror {
    let root: URL

    /// The app's own.
    static let shared: SaveMirror = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        var root = support.appendingPathComponent("SaveChannels", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? root.setResourceValues(values)
        return SaveMirror(root: root)
    }()

    /// One game's folder, made when missing.
    func gameDir(_ romId: Int) -> URL {
        let dir = root.appendingPathComponent(String(romId), isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Every game with a folder here.
    func romIds() -> [Int] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return names.compactMap(Int.init).sorted()
    }

    // MARK: RomM's, as last seen

    /// This person's channels for the game as RomM listed them. Bytes kept
    /// for a save that no listed channel's current holds are deleted.
    func putChannels(_ romId: Int, _ channels: [SaveChannel]) {
        write(RommSnapshots.channelsJSON(channels), to: gameDir(romId).appendingPathComponent("channels.json"))
        let keep = Set(channels.compactMap { $0.currentId != 0 ? $0.current.save?.contentHash : nil })
        let dir = gameDir(romId)
        for name in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        where name.hasPrefix("snapshot-") && name.hasSuffix(".bin") {
            let hash = String(name.dropFirst("snapshot-".count).dropLast(".bin".count))
            if !keep.contains(hash) { try? FileManager.default.removeItem(at: dir.appendingPathComponent(name)) }
        }
    }

    /// Nil when there is no copy (never seen, or forgotten).
    func getChannels(_ romId: Int) -> [SaveChannel]? {
        guard let data = try? Data(contentsOf: gameDir(romId).appendingPathComponent("channels.json"))
        else { return nil }
        return RommSnapshots.readChannels(data)
    }

    /// The game's saves as RomM listed them.
    func putRows(_ romId: Int, _ rows: [RommAsset]) {
        let data = (try? JSONSerialization.data(withJSONObject: rows.map(\.json), options: [.sortedKeys])) ?? Data()
        write(data, to: gameDir(romId).appendingPathComponent("rows.json"))
    }

    func getRows(_ romId: Int) -> [RommAsset]? {
        guard let data = try? Data(contentsOf: gameDir(romId).appendingPathComponent("rows.json"))
        else { return nil }
        return RommSnapshots.readAssets(data)
    }

    /// The bytes of a save in a snapshot, kept by its content hash. A save
    /// with no hash is not kept.
    func putSnapshotSave(_ romId: Int, _ save: SnapshotFile, _ bytes: Data) {
        guard let url = snapshotURL(romId, save) else { return }
        write(bytes, to: url)
    }

    /// Nil when the bytes of this save are not kept.
    func getSnapshotSave(_ romId: Int, _ save: SnapshotFile) -> Data? {
        snapshotURL(romId, save).flatMap { try? Data(contentsOf: $0) }
    }

    private func snapshotURL(_ romId: Int, _ save: SnapshotFile) -> URL? {
        let hash = save.contentHash
        guard !hash.isEmpty, hash.allSatisfy({ $0.isHexDigit }) else { return nil }
        return gameDir(romId).appendingPathComponent("snapshot-\(hash).bin")
    }

    /// The files the game's channels can be on, as RomM last said.
    func putFiles(_ romId: Int, _ files: ChannelFiles) {
        if let data = try? JSONEncoder().encode(files) {
            write(data, to: gameDir(romId).appendingPathComponent("files.json"))
        }
    }

    /// Files that are not known come back empty.
    func getFiles(_ romId: Int) -> ChannelFiles {
        guard let data = try? Data(contentsOf: gameDir(romId).appendingPathComponent("files.json")),
              let files = try? JSONDecoder().decode(ChannelFiles.self, from: data)
        else { return ChannelFiles(channelFile: 0, files: []) }
        return files
    }

    /// Deletes the game's copy of RomM's saves: the rows, the channels and
    /// every byte kept. The snapshot the phone holds stays.
    func forget(_ romId: Int) {
        let dir = gameDir(romId)
        for name in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        where name == "channels.json" || name == "rows.json" || (name.hasPrefix("snapshot-") && name.hasSuffix(".bin")) {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        }
    }

    // MARK: The phone's own note

    /// THE SNAPSHOT THE PHONE HOLDS OF A GAME: the one it last started from or
    /// pushed. RomM keeps the same note per device (`held_by`); the phone
    /// keeps its own, as the TV does, because it says more: when the save in
    /// it was made, whether RomM kept it beside a newer current, and every
    /// save of the game the phone has had (SavePick, the pill).
    struct Held: Codable, Equatable {
        var channelId = ""
        var snapshotId = 0
        /// The snapshot's, "sha256:<hex>".
        var digest = ""
        /// Its save's content hash; empty when it has none.
        var saveHash = ""
        /// When the phone took it, seconds since 1970.
        var at: Int64 = 0
        /// When its save was made, seconds since 1970: for one the phone
        /// pushed, when the phone wrote the save; for one it started from,
        /// when RomM took it.
        var madeAt: Int64 = 0
        /// A push of the phone's that RomM kept beside its channel's current,
        /// as a branch, and that stayed there (SavePush). A start then takes
        /// nothing from RomM made before it (SavePick).
        var beside = false
        /// The content hash of every save of this game the phone has held,
        /// oldest first, `saveHash` last: what tells a save another device
        /// made from one of the phone's own that RomM's website put back on
        /// top (SavePick).
        var hashesHad: [String] = []
    }

    func putHeld(_ romId: Int, _ held: Held) {
        if let data = try? JSONEncoder().encode(held) {
            write(data, to: gameDir(romId).appendingPathComponent("held.json"))
        }
    }

    /// Nil when the phone holds none of this game (never, or since a
    /// reinstall).
    func getHeld(_ romId: Int) -> Held? {
        guard let data = try? Data(contentsOf: gameDir(romId).appendingPathComponent("held.json")) else { return nil }
        return try? JSONDecoder().decode(Held.self, from: data)
    }

    // MARK: Writing

    /// The folder made when missing, then the file replaced whole.
    func write(_ data: Data, to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
