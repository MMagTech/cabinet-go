import Foundation

/// RomM 5.5's save channels and snapshots, in RomM's own words: a game's
/// channels as RomM lists them, a channel's history, the manifest of a push
/// (`POST /api/snapshots`) and what RomM answers one, a save or a state as
/// RomM lists a game's (`/api/saves`, `/api/states`), and the files a game's
/// channels can be on. Port of CabinetOS's `romm_snapshots.cpp` and the words
/// in its `romm_types.h`. The requests themselves are RommClient's; this file
/// reads and writes the bodies, so the lab station runs it with no server.
///
/// FOLLOWS RomM'S CODE AT 5.5.0-beta.1, NOT A DOCUMENT. RomM's documentation
/// (rommapp/docs) still describes 5.4's sync by slot, so every field and
/// answer here is read from `endpoints/channels.py`, `endpoints/snapshots.py`
/// and `endpoints/responses/snapshots.py` at that tag, the same shapes
/// CabinetOS recorded from the write-test RomM (its romm_snapshots_test.cpp,
/// whose recordings the lab station replays).
///
/// A CHANNEL is one run through a game, keyed to one of its files, pointing
/// at its current snapshot; most games have one, RomM's "default". A
/// SNAPSHOT is one saved moment in it: the game's save and a bank of states,
/// each named by its content hash (SaveHash). RomM keeps older snapshots
/// behind the current.
///
/// WHAT A PUSH CAN BE ANSWERED (`push_snapshot`, `_respond`):
///   201  made: the snapshot is the channel's new current.
///   200  unchanged: the current already holds exactly these hashes.
///   400  `missing`: RomM holds no bytes for these hashes and the push did
///        not send them; nothing was written. Sent again with them.
///   409  `branch`: the channel's current was not the one the push expected.
///        RomM kept the push beside it as a branch.
///   409  `hardcore_downgrade`: the channel's current was saved in hardcore
///        and the push is not; nothing was written. The phone never approves
///        that downgrade.
///   Anything else (404 for a game or channel this person cannot see, 422
///   for a part whose bytes do not hash to its name) is refused, and nothing
///   was written.
enum RommSnapshots {
    /// What every Cabinet Go pairs as (RommClient.startDeviceAuth), and what
    /// RomM gives back as the `client` of the device: each phone is its own
    /// device on RomM.
    static let phoneClient = "cabinet-go"

    /// RomM's channels for a game, as listed (`GET /api/channels`). Nil when
    /// the body is not a list.
    static func readChannels(_ body: Data) -> [SaveChannel]? {
        guard let list = (try? JSONSerialization.jsonObject(with: body)) as? [Any] else { return nil }
        return list.compactMap { ($0 as? [String: Any]).flatMap(SaveChannel.init(json:)) }
    }

    /// Channels written back in RomM's own form, for the phone's copy of
    /// them (SaveMirror), which readChannels reads as it came.
    static func channelsJSON(_ channels: [SaveChannel]) -> Data {
        (try? JSONSerialization.data(withJSONObject: channels.map(\.json), options: [.sortedKeys])) ?? Data("[]".utf8)
    }

    /// A channel's history, newest first (`GET /api/snapshots?channel_id=`).
    static func readSnapshots(_ body: Data) -> [Snapshot]? {
        guard let list = (try? JSONSerialization.jsonObject(with: body)) as? [Any] else { return nil }
        return list.compactMap { ($0 as? [String: Any]).flatMap(Snapshot.init(json:)) }
    }

    /// A game's saves or states as RomM lists them: a list, or a page's
    /// `items`. Nil when it is neither.
    static func readAssets(_ body: Data) -> [RommAsset]? {
        let root = try? JSONSerialization.jsonObject(with: body)
        guard let list = (root as? [Any]) ?? ((root as? [String: Any])?["items"] as? [Any]) else { return nil }
        return list.compactMap { ($0 as? [String: Any]).flatMap(RommAsset.init(json:)) }
    }

    /// THE FILES A GAME'S SAVE CHANNELS CAN BE ON, from the game's own entry
    /// (`GET /api/roms/<id>`): the one `channel_file_id` names for a new
    /// channel, and every game file (category "game", or none on an older
    /// server), on any of which a channel made before a file was added can
    /// be. Nil when the body names no files.
    static func readChannelFiles(_ body: Data) -> ChannelFiles? {
        guard let root = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let files = root["files"] as? [Any] else { return nil }
        var out = ChannelFiles(channelFile: int(root["channel_file_id"]), files: [])
        for case let f as [String: Any] in files {
            let id = int(f["id"])
            let category = string(f["category"])
            if id != 0, category.isEmpty || category == "game" { out.files.append(id) }
        }
        return out
    }

    /// The manifest part of a push, as RomM reads it (`ManifestPayload`).
    /// `expected_current_id` is always named, as null for an empty channel:
    /// left out, RomM would take the current it last saw this device read.
    static func manifest(_ push: SnapshotPush) -> Data {
        var m: [String: Any] = [
            "rom_file_id": push.romFileId,
            "expected_current_id": push.expectedCurrentId != 0 ? push.expectedCurrentId : NSNull(),
        ]
        if !push.channelId.isEmpty { m["channel_id"] = push.channelId }
        if !push.label.isEmpty { m["label"] = push.label }
        if push.parentId != 0 { m["parent_snapshot_id"] = push.parentId }
        if push.hasSave {
            // The emulator's own files: the phone converts nothing.
            m["save"] = ["hash": push.save.hash, "shape": push.saveShape, "format": "native"]
        }
        if !push.states.isEmpty {
            var bank: [String: [String: String]] = [:]
            for s in push.states { bank[s.core, default: [:]][s.slot] = s.file.hash }
            m["states"] = bank
        }
        if !push.emulator.isEmpty { m["emulator"] = push.emulator }
        if !push.core.isEmpty { m["core"] = push.core }
        return (try? JSONSerialization.data(withJSONObject: m, options: [.sortedKeys])) ?? Data()
    }

    /// One part of a push's multipart body.
    struct Part {
        let name: String
        let fileName: String
        let contentType: String
        let data: Data
    }

    /// Every part of a push: the manifest; the save's bytes when it has
    /// them, and its picture as `save_screenshot` (RomM's
    /// SAVE_SCREENSHOT_PART); each state's bytes as `state:<core>:<slot>`
    /// and its picture as `state:<core>:<slot>:screenshot`.
    static func parts(_ push: SnapshotPush) -> [Part] {
        var parts = [Part(name: "manifest", fileName: "", contentType: "application/json", data: manifest(push))]
        if push.hasSave, !push.save.bytes.isEmpty {
            parts.append(Part(name: "save", fileName: push.save.fileName,
                              contentType: "application/octet-stream", data: push.save.bytes))
        }
        if push.hasSave, !push.save.picture.isEmpty {
            parts.append(Part(name: "save_screenshot", fileName: push.save.pictureName,
                              contentType: "image/png", data: push.save.picture))
        }
        for s in push.states {
            let name = "state:\(s.core):\(s.slot)"
            if !s.file.bytes.isEmpty {
                parts.append(Part(name: name, fileName: s.file.fileName,
                                  contentType: "application/octet-stream", data: s.file.bytes))
            }
            if !s.file.picture.isEmpty {
                parts.append(Part(name: name + ":screenshot", fileName: s.file.pictureName,
                                  contentType: "image/png", data: s.file.picture))
            }
        }
        return parts
    }

    /// What RomM answered a push (the head of this file).
    static func readPushAnswer(status: Int, body: Data) -> PushAnswer {
        var out = PushAnswer()
        out.status = status
        let root = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        var read = false
        if let root, status == 200 || status == 201 {
            out.kind = status == 201 ? .made : .unchanged
            if let s = Snapshot(json: root) {
                out.snapshot = s
                read = true
            }
        } else if let root, status == 400, let missing = root["missing"] as? [Any] {
            out.kind = .bytesMissing
            out.missing = missing.compactMap { $0 as? String }.filter { !$0.isEmpty }
            read = !out.missing.isEmpty
        } else if let root, status == 409 {
            if (root["hardcore_downgrade"] as? Bool) == true {
                out.kind = .hardcoreChannel
                read = true
            } else if let branch = (root["branch"] as? [String: Any]).flatMap(Snapshot.init(json:)) {
                out.kind = .movedOn
                out.snapshot = branch
                if let current = (root["current"] as? [String: Any]).flatMap(Snapshot.init(json:)) {
                    out.hasCurrent = true
                    out.current = current
                }
                out.fromOlder = string(root["reason"]) == "moved_from_older"
                read = true
            }
        }
        if !read {
            // A part whose bytes RomM could not hash to the manifest's value:
            // {"detail":{"manifest":"<part> does not hash to the manifest's value"}}.
            var unhashed = ""
            let tail = " does not hash to the manifest's value"
            if status == 422, let said = (root?["detail"] as? [String: Any])?["manifest"] as? String,
               said.count > tail.count, said.hasSuffix(tail) {
                unhashed = String(said.dropLast(tail.count))
            }
            out = PushAnswer()
            out.status = status
            out.kind = .refused
            out.detail = String(String(decoding: body.prefix(180), as: UTF8.self))
            out.unhashed = unhashed
        }
        return out
    }

    // MARK: Reading RomM's JSON

    static func int(_ v: Any?) -> Int {
        if let n = v as? Int { return n }
        if let n = v as? NSNumber { return n.intValue }
        if let s = v as? String { return Int(s) ?? 0 }
        return 0
    }

    static func string(_ v: Any?) -> String { v as? String ?? "" }
}

/// The files a game's save channels can be on (RommSnapshots.readChannelFiles).
/// A push into a channel names that channel's own file (RomM refuses any
/// other, 422); `channelFile` is only for a channel the push makes.
struct ChannelFiles: Codable, Equatable {
    /// 0: RomM names none, or a RomM before 5.5.
    var channelFile: Int
    /// Empty: not known.
    var files: [Int]
}

/// A save or a state inside a snapshot. Its bytes come down by `id`, from
/// `/api/saves/<id>/content` or `/api/states/<id>/content`.
struct SnapshotFile: Equatable {
    var id = 0
    var fileName = ""
    var sizeBytes: Int64 = 0
    /// Empty on a row RomM never hashed.
    var contentHash = ""
    /// Its picture on RomM (`screenshot.download_path`); empty for none.
    var picturePath = ""
    /// A save's only. `shape` is how it travels, Sigil's word: "SINGLE" (one
    /// file, as it is) or "MULTI" or "FOLDER" (a zip). `format` is "native"
    /// or "neutral". The emulator and the core are those named on the row
    /// RomM filed it under.
    var shape = ""
    var format = ""
    var emulator = ""
    var core = ""

    init() {}

    init(json o: [String: Any]) {
        id = RommSnapshots.int(o["id"])
        fileName = RommSnapshots.string(o["file_name"])
        sizeBytes = Int64(RommSnapshots.int(o["file_size_bytes"]))
        contentHash = RommSnapshots.string(o["content_hash"])
        picturePath = RommSnapshots.string((o["screenshot"] as? [String: Any])?["download_path"])
        shape = RommSnapshots.string(o["shape"])
        format = RommSnapshots.string(o["format"])
        emulator = RommSnapshots.string(o["emulator"])
        core = RommSnapshots.string(o["core"])
    }

    var json: [String: Any] {
        var o: [String: Any] = [
            "id": id, "file_name": fileName, "file_size_bytes": sizeBytes, "content_hash": contentHash,
            "shape": shape, "format": format, "emulator": emulator, "core": core,
        ]
        if !picturePath.isEmpty { o["screenshot"] = ["download_path": picturePath] }
        return o
    }
}

/// A device RomM says holds a snapshot (`held_by`): the snapshot it last took
/// or pushed in that channel. Only this person's own devices are listed.
struct SnapshotHolder: Equatable {
    var deviceId = ""
    var client = ""
    var syncedAt = ""
}

/// One slot of a snapshot's bank: the core RomM files it under, the slot's
/// name, and the state.
struct SnapshotState: Equatable {
    var core = ""
    var slot = ""
    var file = SnapshotFile()
}

struct Snapshot: Equatable {
    var id = 0
    /// "sha256:<hex>", over the save's and states' hashes.
    var digest = ""
    /// "channel", "branch" or "archival".
    var kind = ""
    var parentId = 0
    var channelId = ""
    var hardcore = false
    /// When the snapshot was pushed, ISO 8601 in UTC.
    var createdAt = ""
    /// WHEN ITS SAVE FIRST REACHED RomM: the `created_at` of the save's own
    /// row among the game's saves (SavePick.dateSaves fills it; empty until
    /// then). A snapshot that changed only its states is later than its save.
    var saveAt = ""
    /// The device that pushed it, named only when it is this person's own.
    var deviceOwn = false
    var deviceId = ""
    var deviceClient = ""
    /// The emulator the device that pushed it named in its manifest, whose
    /// form its save is in (SavePick.ownForm).
    var emulator = ""
    var heldBy: [SnapshotHolder] = []
    var save: SnapshotFile?
    var states: [SnapshotState] = []

    var hasSave: Bool { save != nil }

    init() {}

    /// SnapshotSchema. Nil when it carries no id.
    init?(json o: [String: Any]) {
        id = RommSnapshots.int(o["id"])
        guard id != 0 else { return nil }
        digest = RommSnapshots.string(o["digest"])
        kind = RommSnapshots.string(o["kind"])
        parentId = RommSnapshots.int(o["parent_snapshot_id"])
        channelId = RommSnapshots.string(o["channel_id"])
        hardcore = (o["is_hardcore"] as? Bool) ?? false
        createdAt = RommSnapshots.string(o["created_at"])
        if let d = o["device"] as? [String: Any] {
            deviceOwn = (d["is_own"] as? Bool) ?? false
            deviceId = RommSnapshots.string(d["id"])
            deviceClient = RommSnapshots.string(d["client"])
        }
        emulator = RommSnapshots.string(o["emulator"])
        for case let h as [String: Any] in (o["held_by"] as? [Any]) ?? [] {
            let d = h["device"] as? [String: Any]
            heldBy.append(SnapshotHolder(deviceId: RommSnapshots.string(d?["id"]),
                                         client: RommSnapshots.string(d?["client"]),
                                         syncedAt: RommSnapshots.string(h["synced_at"])))
        }
        if let s = o["save"] as? [String: Any] { save = SnapshotFile(json: s) }
        if let bank = o["states"] as? [String: Any] {
            for core in bank.keys.sorted() {
                guard let slots = bank[core] as? [String: Any] else { continue }
                for slot in slots.keys.sorted() {
                    guard let state = slots[slot] as? [String: Any] else { continue }
                    states.append(SnapshotState(core: core, slot: slot, file: SnapshotFile(json: state)))
                }
            }
        }
    }

    var json: [String: Any] {
        var o: [String: Any] = [
            "id": id, "digest": digest, "kind": kind,
            "parent_snapshot_id": parentId != 0 ? parentId : NSNull(),
            "channel_id": channelId, "is_hardcore": hardcore, "created_at": createdAt,
            "device": ["id": deviceId, "client": deviceClient, "is_own": deviceOwn],
            "emulator": emulator,
            "held_by": heldBy.map { ["device": ["id": $0.deviceId, "client": $0.client], "synced_at": $0.syncedAt] },
        ]
        if let save { o["save"] = save.json }
        var bank: [String: [String: Any]] = [:]
        for s in states { bank[s.core, default: [:]][s.slot] = s.file.json }
        o["states"] = bank
        return o
    }
}

struct SaveChannel: Equatable {
    /// A UUID, RomM's or the device's that made it.
    var id = ""
    /// RomM's own is "default".
    var label = ""
    /// Its current was saved in hardcore.
    var hardcore = false
    var romId = 0
    /// The file it is keyed to, which a push into it names.
    var romFileId = 0
    var snapshotCount = 0
    var updatedAt = ""
    /// The current snapshot; `currentId` 0 while the channel is empty.
    var currentId = 0
    var current = Snapshot()

    init() {}

    /// ChannelSchema. Nil when it carries no id.
    init?(json o: [String: Any]) {
        id = RommSnapshots.string(o["id"])
        guard !id.isEmpty else { return nil }
        label = RommSnapshots.string(o["label"])
        hardcore = (o["is_hardcore"] as? Bool) ?? false
        romId = RommSnapshots.int(o["rom_id"])
        romFileId = RommSnapshots.int(o["rom_file_id"])
        snapshotCount = RommSnapshots.int(o["snapshot_count"])
        updatedAt = RommSnapshots.string(o["updated_at"])
        currentId = RommSnapshots.int(o["current_snapshot_id"])
        if currentId != 0, let c = (o["current"] as? [String: Any]).flatMap(Snapshot.init(json:)) {
            current = c
        }
    }

    var json: [String: Any] {
        var o: [String: Any] = [
            "id": id, "label": label, "is_hardcore": hardcore, "rom_id": romId, "rom_file_id": romFileId,
            "snapshot_count": snapshotCount, "updated_at": updatedAt,
            "current_snapshot_id": currentId != 0 ? currentId : NSNull(),
        ]
        if currentId != 0 { o["current"] = current.json }
        return o
    }
}

/// A save or a state as RomM lists a game's (`/api/saves`, `/api/states`).
struct RommAsset: Equatable, Identifiable {
    var id = 0
    var romId = 0
    var fileName = ""
    var sizeBytes: Int64 = 0
    /// Which emulator wrote it.
    var emulator = ""
    /// A STATE'S NAME IN ITS SNAPSHOT'S BANK: the core a push filed it under,
    /// which for the phone and CabinetOS is the state tag. Empty for a state
    /// from before channels, and for a save.
    var core = ""
    var updatedAt = ""
    /// When RomM first stored these bytes. For a save in a snapshot, when
    /// that save first reached RomM, however many snapshots carried it since.
    var createdAt = ""
    /// Its picture on RomM (`screenshot.download_path`); empty for none.
    var picturePath = ""
    /// A SAVE IN A SNAPSHOT IS LISTED AMONG A GAME'S SAVES TOO, with its
    /// channel here, whether it is that channel's current or an older
    /// snapshot's. Empty for a save from before channels.
    var channelId = ""
    /// The slot an app that saves the old way filed it under; empty for a
    /// save a snapshot brought and for one with none (SavePick.otherRows).
    var slot = ""

    init() {}

    init?(json o: [String: Any]) {
        id = RommSnapshots.int(o["id"])
        guard id != 0 else { return nil }
        romId = RommSnapshots.int(o["rom_id"])
        fileName = RommSnapshots.string(o["file_name"])
        sizeBytes = Int64(RommSnapshots.int(o["file_size_bytes"]))
        emulator = RommSnapshots.string(o["emulator"])
        core = RommSnapshots.string(o["core"])
        updatedAt = RommSnapshots.string(o["updated_at"])
        createdAt = RommSnapshots.string(o["created_at"])
        picturePath = RommSnapshots.string((o["screenshot"] as? [String: Any])?["download_path"])
        channelId = RommSnapshots.string(o["channel_id"])
        slot = RommSnapshots.string(o["slot"])
    }

    var json: [String: Any] {
        var o: [String: Any] = [
            "id": id, "rom_id": romId, "file_name": fileName, "file_size_bytes": sizeBytes,
            "emulator": emulator, "core": core, "updated_at": updatedAt, "created_at": createdAt,
            "channel_id": channelId, "slot": slot,
        ]
        if !picturePath.isEmpty { o["screenshot"] = ["download_path": picturePath] }
        return o
    }
}

/// WHAT RomM ANSWERED A REQUEST FOR A SAVE IN AN EMULATOR'S FORM
/// (`GET /api/saves/<id>/content?core=`).
struct SaveAnswer {
    /// 0: no answer from the server.
    var status = 0
    /// With 200.
    var bytes = Data()
    /// One file RomM converted: its path in the emulator's save folder
    /// (`X-Save-Path`, unescaped). Empty for a zip of several, and for a save
    /// handed over as stored.
    var savePath = ""
    /// A refusal's code (`detail.error`, Sigil's: NOT_FOUND, NO_TARGET...)
    /// or RomM's words (`detail`), for the log.
    var error = ""
}

/// One file a push names: by its content hash, and by its bytes when RomM
/// may not hold them. A state and the save may carry their picture (PNG).
struct PushFile: Equatable {
    var hash = ""
    var fileName = ""
    var bytes = Data()
    var pictureName = ""
    var picture = Data()
}

/// One state a push puts in the bank, in `core`'s slots. A core the push
/// names replaces the parent's slots for that core; a core it does not name
/// is carried from the parent as it is.
struct PushState: Equatable {
    var core = ""
    var slot = ""
    var file = PushFile()
}

/// ONE PUSH INTO A CHANNEL (`POST /api/snapshots`). It always says which
/// current it builds on, so RomM never works that out from what it last saw
/// of the device.
struct SnapshotPush: Equatable {
    /// The channel's own file; for a channel it makes, the file RomM names
    /// for new ones.
    var romFileId = 0
    /// The channel; empty makes one named `label`.
    var channelId = ""
    var label = ""
    /// The channel's current it builds on; 0 expects an empty channel.
    var expectedCurrentId = 0
    /// The snapshot it was made from, when not the expected current.
    var parentId = 0
    /// The names it was made with: the emulator's tag and the core's own in
    /// Sigil's spelling.
    var emulator = ""
    var core = ""
    /// The save; with `hasSave` false the parent's is carried.
    var hasSave = false
    var save = PushFile()
    /// "SINGLE", "MULTI" or "FOLDER".
    var saveShape = "SINGLE"
    var states: [PushState] = []
}

/// WHAT RomM ANSWERED A PUSH (the head of RommSnapshots).
struct PushAnswer {
    enum Kind {
        case made, unchanged, bytesMissing, movedOn, hardcoreChannel, refused
    }
    var kind = Kind.refused
    var status = 0
    /// Made and unchanged: the channel's current. Moved on: the branch RomM
    /// kept, which this device now holds.
    var snapshot = Snapshot()
    /// Moved on: the current it missed (`hasCurrent` false when RomM names
    /// none), and whether the push was made from an older snapshot than the
    /// one it expected (`moved_from_older`).
    var hasCurrent = false
    var current = Snapshot()
    var fromOlder = false
    /// Bytes missing: the parts RomM needs, "save" or "state:<core>:<slot>".
    var missing: [String] = []
    /// Refused: what RomM said, cut short.
    var detail = ""
    /// Refused with 422 because a part's bytes do not hash to its name: that
    /// part, "save" or "state:<core>:<slot>".
    var unhashed = ""
}
