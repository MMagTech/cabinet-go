import Foundation
import os

/// LEAVING A GAME: what a session left goes up to RomM as one snapshot, and
/// RomM's answer is settled here. Port of CabinetOS's `savepush`
/// (frontend/src/savepush.h), so the phone saves where and as the TV does.
/// GameSaves gathers each kind of save and hands it here; this marks it owed,
/// aims it, sends it and settles what RomM says. The words are RomM's
/// (RommSnapshots).
///
/// WHAT GOES UP. One save in the form a start reads a snapshot's save
/// (SaveForm), under the tag the core's saves travel under, with the core's
/// own name in Sigil's spelling beside it, from which RomM converts the save
/// for any other app, named after the game. Nothing changed means nothing
/// sent. WITH ITS PICTURE, the game the moment it saved, when the sitting
/// took one: RomM's `save_screenshot` part.
///
/// AND THE STATES. A state is written on the phone as it is made and marked
/// owed in the game's push at once (markState), so no connection and no kill
/// can lose it; it goes up inside the snapshot when the game is left. THE GAME
/// OFFERS THE THREE NEWEST OF ITS OWN STATES, WHEREVER THEY ARE ON RomM
/// (offeredStates): of RomM's list of the game's states, the ones under the
/// core's tag, with the ones made here and still owed. A push names those
/// same three, so the snapshot on top holds what the game screen shows, in
/// slots "1", "2" and "3", newest first. A state made since is always among
/// them, so none made on the phone is let go before RomM has it. The phone
/// and the TV use the same tags, so a state made on either is among the
/// other's three. A state RomM already holds is named by its content hash and
/// its bytes are not sent again. The phone deletes no state on RomM: RomM's
/// own history keeps the older ones.
///
/// WHERE IT GOES. Into the channel the save it was made from is in, naming
/// that snapshot as the current it builds on: the snapshot the phone holds of
/// the game (SaveMirror.Held), which a start from a channel sets and every
/// push that lands moves on. A phone that holds none saves into the person's
/// channel named "default", RomM's own, made when there is none. A push into
/// a channel names that channel's own file (RomM refuses any other, 422), so
/// the person's channels are listed on every game file of the game.
///
/// WHEN RomM SAYS THE CHANNEL MOVED ON (409), it has already kept the push
/// beside the channel's current, as a branch. If the phone's save was made
/// later than that current, a second push names the branch and puts it on
/// top with no bytes; if not, it is left where RomM kept it, and the next
/// start takes the newer one. A SESSION THAT COULD NOT USE THE NEWEST SAVE IS
/// ALWAYS LEFT AS RomM KEPT IT. A PUSH OF STATES ALONE GOES ONTO THE
/// CHANNEL'S CURRENT AS RomM LISTS IT, carrying that snapshot's save, but not
/// for a session that could not use the newest, nor onto another emulator's
/// save. A SAVE GOES ONTO A CURRENT THAT HOLDS NONE.
///
/// A HARDCORE CHANNEL IS NEVER SAVED INTO: the person's channel named
/// "softcore" takes its place, made from the snapshot the session started
/// from.
///
/// A RomM TOO OLD FOR SAVE CHANNELS IS NEITHER READ NOR WRITTEN: a push waits,
/// owed, with nothing asked (`waits`), and goes once the server says it has
/// them (its heartbeat's `SAVE_SYNC`).
///
/// THE ORDER THAT KEEPS A SAVE. The save's bytes and the marker are written
/// before anything is sent, and the marker is cleared only by the push that
/// sent it, after the note of the snapshot held is written, so a kill at any
/// point leaves the save owed and it goes again; RomM answers a push it
/// already has with "unchanged". While a save is owed a start takes nothing
/// from RomM (SavePick).
///
/// Left out from the TV's, by the step 5 plan: RomM's saves from before
/// channels are neither read nor brought in.
@MainActor
enum SavePush {
    /// RomM's own name for a game's ordinary channel.
    static let defaultChannel = "default"
    /// The phone's channel beside a hardcore one, RomM's word for a save that
    /// is not hardcore.
    static let softcoreChannel = "softcore"
    /// How many states a game offers and a push names.
    static let statesKept = 3
    /// How many pushes one send makes at most: one ordinarily; two for a
    /// channel that moved on; more when it moved again while the phone
    /// answered. Past that RomM and the phone are not converging and the push
    /// waits, still owed.
    static let mostPushes = 5

    // MARK: The marker

    /// A state the game's push carries, a file in the game's `states/`.
    struct OwedState: Codable, Equatable {
        var core: String
        var fileName: String
        var pictureName: String
        /// When it was made, milliseconds since 1970.
        var madeMs: Int64
    }

    /// WHAT A GAME OWES RomM: one push. Its save's bytes are the game's
    /// `owed/save` (and its picture `owed/save.png`), copied when it was
    /// marked, so what goes is what the newest session left whatever the
    /// core writes after; its states are in `states/`. No path is kept, only
    /// names: an app's folder moves when it is updated.
    struct OwedPush: Codable, Equatable {
        var romId: Int
        var emulator: String
        var core: String
        var hasSave = false
        /// The name it goes up under.
        var saveName = ""
        var saveShape = "SINGLE"
        /// Its picture's name; empty for none.
        var savePictureName = ""
        /// When the phone wrote the save, seconds since 1970.
        var madeAt: Int64 = 0
        var channelId = ""
        var label = ""
        var expectedCurrentId = 0
        var parentId = 0
        var couldNotUseNewest = false
        var states: [OwedState] = []
        /// Which marking this is, so a send clears only the one it sent.
        var stamp = ""
    }

    /// The game's owed push; nil when it owes none.
    static func owed(_ romId: Int, mirror: SaveMirror = .shared) -> OwedPush? {
        guard let data = try? Data(contentsOf: markerURL(romId, mirror)) else { return nil }
        return try? JSONDecoder().decode(OwedPush.self, from: data)
    }

    /// Whether the game owes RomM a save of its own (not states alone).
    static func saveOwed(_ romId: Int, mirror: SaveMirror = .shared) -> Bool {
        owed(romId, mirror: mirror)?.hasSave ?? false
    }

    static func statesDir(_ romId: Int, mirror: SaveMirror = .shared) -> URL {
        let dir = mirror.gameDir(romId).appendingPathComponent("states", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func markerURL(_ romId: Int, _ mirror: SaveMirror) -> URL {
        mirror.gameDir(romId).appendingPathComponent("owed.json")
    }

    private static func owedSaveURL(_ romId: Int, _ mirror: SaveMirror) -> URL {
        mirror.gameDir(romId).appendingPathComponent("owed", isDirectory: true).appendingPathComponent("save")
    }

    private static func owedPictureURL(_ romId: Int, _ mirror: SaveMirror) -> URL {
        mirror.gameDir(romId).appendingPathComponent("owed", isDirectory: true).appendingPathComponent("save.png")
    }

    private static func putOwed(_ p: OwedPush, _ mirror: SaveMirror) -> Bool {
        guard let data = try? JSONEncoder().encode(p) else { return false }
        mirror.write(data, to: markerURL(p.romId, mirror))
        return owed(p.romId, mirror: mirror)?.stamp == p.stamp
    }

    /// Clears the marker when it is still the one `stamp` names, and its
    /// save's files with it.
    private static func clearOwed(_ romId: Int, stamp: String, _ mirror: SaveMirror) {
        guard let now = owed(romId, mirror: mirror), now.stamp == stamp else { return }
        try? FileManager.default.removeItem(at: markerURL(romId, mirror))
        try? FileManager.default.removeItem(at: owedSaveURL(romId, mirror))
        try? FileManager.default.removeItem(at: owedPictureURL(romId, mirror))
    }

    // MARK: Marking

    /// What of a session a mark is aimed by.
    struct AimFrom: Equatable {
        var romId = 0
        /// The core's tag, which its saves and its states travel under.
        var tag = ""
        /// The core's own name, in Sigil's spelling.
        var core = ""
        var startChannelId = ""
        var startSnapshotId = 0
        var startHardcore = false
        var couldNotUseNewest = false
    }

    /// A save a session left, as GameSaves gathered it.
    struct Gathered: Equatable {
        var bytes: Data
        var name: String
        var shape: String
        /// The game the moment it saved; nil for none.
        var picture: Data?
        /// When the phone wrote it, seconds since 1970.
        var madeAt: Int64
    }

    /// WHAT THE SESSION LEFT, MARKED AS OWED: the save's bytes copied beside
    /// the marker, the marker written aimed (the head of this file), carrying
    /// the states an earlier marker of the game still owes. False when it
    /// could not be written. Asks nothing of the network.
    @discardableResult
    static func mark(_ g: Gathered, from: AimFrom, mirror: SaveMirror = .shared) -> Bool {
        guard from.romId > 0, !from.tag.isEmpty, !g.bytes.isEmpty else { return false }
        let earlier = owed(from.romId, mirror: mirror)
        var p = OwedPush(romId: from.romId, emulator: from.tag, core: from.core)
        p.hasSave = true
        p.saveName = g.name
        p.saveShape = g.shape
        p.madeAt = g.madeAt
        mirror.write(g.bytes, to: owedSaveURL(from.romId, mirror))
        if let picture = g.picture, !picture.isEmpty {
            mirror.write(picture, to: owedPictureURL(from.romId, mirror))
            let dot = g.name.lastIndex(of: ".") ?? g.name.endIndex
            p.savePictureName = String(g.name[..<dot]) + ".png"
        } else {
            try? FileManager.default.removeItem(at: owedPictureURL(from.romId, mirror))
        }
        aim(from, into: &p, earlier: earlier, mirror: mirror)
        p.states = earlier?.states ?? []
        p.stamp = UUID().uuidString
        guard putOwed(p, mirror) else { return false }
        log("game \(from.romId): \(g.name) (\(g.bytes.count) bytes)\(p.savePictureName.isEmpty ? "" : " with its picture")"
            + (p.states.isEmpty ? "" : " and \(p.states.count) state(s)") + " owed to RomM as a snapshot, "
            + (p.channelId.isEmpty ? "into the channel named \"\(p.label)\"" : "on snapshot \(p.expectedCurrentId) of channel \"\(p.label)\"")
            + (p.couldNotUseNewest ? ", never on top of the save it could not use" : ""))
        return true
    }

    /// A state just made and written to the game's `states/`.
    struct StateMade: Equatable {
        var fileName: String
        var pictureName: String
        var madeMs: Int64
    }

    /// A STATE JUST MADE, MARKED AS OWED: the game's owed push gains it,
    /// newest first, and keeps the newest three; one pushed out of them is
    /// never sent. A push already owed keeps where it was aimed when it
    /// carries a save, and is aimed again from this session when it carries
    /// states alone. Asks nothing of the network.
    @discardableResult
    static func markState(_ made: StateMade, from: AimFrom, mirror: SaveMirror = .shared) -> Bool {
        guard from.romId > 0, !from.tag.isEmpty else { return false }
        let earlier = owed(from.romId, mirror: mirror)
        var p = earlier ?? OwedPush(romId: from.romId, emulator: from.tag, core: from.core)
        if !p.hasSave {
            var aimed = OwedPush(romId: from.romId, emulator: from.tag, core: from.core)
            aim(from, into: &aimed, earlier: earlier, mirror: mirror)
            p.channelId = aimed.channelId
            p.label = aimed.label
            p.expectedCurrentId = aimed.expectedCurrentId
            p.parentId = aimed.parentId
            p.couldNotUseNewest = aimed.couldNotUseNewest
        }
        p.states.insert(OwedState(core: from.tag, fileName: made.fileName, pictureName: made.pictureName,
                                  madeMs: made.madeMs), at: 0)
        p.states = keepNewest(p.states)
        p.stamp = UUID().uuidString
        guard putOwed(p, mirror) else { return false }
        log("game \(from.romId): \(made.fileName) owed to RomM in the game's snapshot, \(p.states.count) state(s) in it"
            + (p.hasSave ? ", with its save" : ""))
        return true
    }

    /// WHERE THE PUSH GOES, from what the phone knows without asking: onto
    /// the snapshot the phone holds, or the one the session started from when
    /// the note of it was never written; else into the person's "default".
    /// What an earlier push of the game still unsent could not go on top of,
    /// this one cannot either: it is the save this session started from.
    private static func aim(_ from: AimFrom, into p: inout OwedPush, earlier: OwedPush?, mirror: SaveMirror) {
        p.couldNotUseNewest = from.couldNotUseNewest || (earlier?.couldNotUseNewest ?? false)
        var channel = from.startChannelId
        var base = from.startSnapshotId
        if let held = mirror.getHeld(from.romId) {
            channel = held.channelId
            base = held.snapshotId
        }
        if base != 0, from.startHardcore, channel == from.startChannelId {
            p.label = softcoreChannel
            p.parentId = base
        } else if base != 0 {
            p.channelId = channel
            p.label = labelOf(from.romId, channelId: channel, mirror)
            p.expectedCurrentId = base
        } else {
            p.label = defaultChannel
        }
    }

    /// The name the phone last saw a channel under, for a push that has to
    /// make it again; RomM's own when it never saw it.
    private static func labelOf(_ romId: Int, channelId: String, _ mirror: SaveMirror) -> String {
        let seen = mirror.getChannels(romId) ?? []
        return seen.first { $0.id == channelId && !$0.label.isEmpty }?.label ?? defaultChannel
    }

    /// A marker's states, newest first, one per name, the newest three.
    private static func keepNewest(_ states: [OwedState]) -> [OwedState] {
        var kept: [OwedState] = []
        for s in states.enumerated().sorted(by: { $0.element.madeMs != $1.element.madeMs
                ? $0.element.madeMs > $1.element.madeMs : $0.offset < $1.offset }).map(\.element) {
            if kept.count == statesKept { break }
            if !kept.contains(where: { $0.fileName == s.fileName }) { kept.append(s) }
        }
        return kept
    }

    // MARK: The states the game offers

    /// One state the game offers: RomM's (`id`), the phone's own copy
    /// (`file`), or both.
    struct OfferedState: Equatable, Identifiable {
        /// RomM's; 0 for one only on the phone.
        var rommId = 0
        var fileName = ""
        /// The phone's copy; nil when it has none.
        var file: URL?
        /// The phone's copy of its picture, else RomM's path; empty for none.
        var picture = ""
        var pictureIsLocal = false
        /// 0 when not known.
        var madeMs: Int64 = 0

        /// One per name in what the game offers.
        var id: String { fileName }
    }

    /// THE STATES THE PHONE OFFERS FOR A GAME, newest first, at most three
    /// (the head of this file): of `rows`, RomM's list of the game's states,
    /// the ones filed under `tag`, with the ones its owed push carries; one
    /// per name, RomM's own time taken off it. Nil `rows` (RomM away, not
    /// answering, or too old for channels): the phone's own files, the owed
    /// ones and every state in the game's `states/`. Reads the disk only.
    static func offeredStates(_ romId: Int, tag: String, rows: [RommAsset]?, mirror: SaveMirror = .shared) -> [OfferedState] {
        let dir = statesDir(romId, mirror: mirror)
        var out: [OfferedState] = []
        var names = Set<String>()
        if !tag.isEmpty, let p = owed(romId, mirror: mirror) {
            for s in p.states where s.core == tag {
                let file = dir.appendingPathComponent(s.fileName)
                guard isFile(file), names.insert(s.fileName).inserted else { continue }
                let png = dir.appendingPathComponent(s.pictureName)
                out.append(OfferedState(rommId: 0, fileName: s.fileName, file: file,
                                        picture: !s.pictureName.isEmpty && isFile(png) ? png.path : "",
                                        pictureIsLocal: true, madeMs: s.madeMs))
            }
        }
        if let rows, !tag.isEmpty {
            for r in rows where filedUnder(r) == tag && names.insert(ownName(r.fileName)).inserted {
                var o = OfferedState(rommId: r.id, fileName: r.fileName, file: ownCopy(dir, r.fileName),
                                     picture: r.picturePath, madeMs: rowMadeMs(r))
                if let file = o.file, let png = pictureOf(file) {
                    o.picture = png.path
                    o.pictureIsLocal = true
                }
                out.append(o)
            }
        } else if rows == nil {
            let files = (try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for f in files where f.pathExtension == "state" && names.insert(f.lastPathComponent).inserted {
                var ms = stateNameMs(f.lastPathComponent)
                if ms == 0 {
                    let date = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                    ms = Int64((date?.timeIntervalSince1970 ?? 0) * 1000)
                }
                let png = pictureOf(f)
                out.append(OfferedState(rommId: 0, fileName: f.lastPathComponent, file: f, picture: png?.path ?? "",
                                        pictureIsLocal: png != nil, madeMs: ms))
            }
        }
        let ordered = out.enumerated().sorted {
            $0.element.madeMs != $1.element.madeMs ? $0.element.madeMs > $1.element.madeMs : $0.offset < $1.offset
        }.map(\.element)
        return Array(ordered.prefix(statesKept))
    }

    // MARK: Sending

    /// What a push asks of RomM, so the lab answers in its place. Every
    /// closure throws a SaveServerError.
    struct Server {
        /// Whether the server has save channels (its heartbeat's SAVE_SYNC).
        var hasChannels: () -> Bool
        /// The files a game's channels can be on: as the phone remembers
        /// them (`ask` false; empty when it never learned them) or asked of
        /// RomM, which the phone then remembers.
        var files: (_ romId: Int, _ ask: Bool) async throws -> ChannelFiles
        /// This person's channels on those files; `.notFound` when RomM no
        /// longer knows one of the files.
        var channels: (_ fileIds: [Int]) async throws -> [SaveChannel]
        var push: (_ push: SnapshotPush) async throws -> PushAnswer
        /// A game's saves, and its states, as RomM lists them.
        var saves: (_ romId: Int) async throws -> [RommAsset]
        var states: (_ romId: Int) async throws -> [RommAsset]
        /// A channel's history.
        var history: (_ channelId: String) async throws -> [Snapshot]
        /// A save's bytes as stored (`/api/saves/<id>/content`), for a start.
        var content: (_ saveId: Int) async throws -> Data
        /// A save in an emulator's form (`?core=`), for a start; status 0
        /// when RomM did not answer.
        var saveAs: (_ saveId: Int, _ query: [URLQueryItem]) async -> SaveAnswer
    }

    enum Sent: Equatable {
        /// RomM holds it as its channel's current.
        case landed
        /// RomM holds it beside the current, where it stays.
        case beside
        /// No marker, or its files are gone: nothing to send.
        case nothingOwed
        /// No answer: still owed, tried again later.
        case notSent
        /// RomM answered and will not take it: still owed, tried at the next
        /// start or the next save of the game.
        case refused
        /// RomM is too old for save channels: still owed, nothing asked.
        case waits
    }

    /// RomM holds it, or nothing is owed: the push is done with.
    static func settled(_ sent: Sent) -> Bool {
        sent == .landed || sent == .beside || sent == .nothingOwed
    }

    // MARK: One push of a game at a time

    private static var busy = Set<Int>()
    private static var waiting: [Int: [CheckedContinuation<Void, Never>]] = [:]

    /// ONE PUSH OF A GAME AT A TIME, and a start's list and pick never while
    /// one is in flight (GameSaves): the second finds what the first left.
    static func oneAtATime<T>(_ romId: Int, _ body: () async -> T) async -> T {
        while busy.contains(romId) {
            await withCheckedContinuation { waiting[romId, default: []].append($0) }
        }
        busy.insert(romId)
        let result = await body()
        busy.remove(romId)
        for w in waiting.removeValue(forKey: romId) ?? [] { w.resume() }
        return result
    }

    /// ONE GAME'S OWED PUSH, SENT AND SETTLED (the head of this file). Reads
    /// the marker and the save's bytes off the disk, so what goes is what the
    /// newest session left. When RomM holds it: the game's copy of RomM's
    /// saves is forgotten first, the snapshot becomes the one the phone
    /// holds, the marker is cleared, and the copy is listed again for
    /// offline. `why` says what happened when it did not land.
    static func send(_ server: Server, romId: Int, mirror: SaveMirror = .shared) async -> (sent: Sent, why: String) {
        await oneAtATime(romId) { await sendOne(server, romId: romId, mirror: mirror) }
    }

    /// Every game's owed push, one game after another: the foreground with a
    /// connection, so a save made offline goes without the game being started.
    static func sendAllOwed(_ server: Server, mirror: SaveMirror = .shared) async -> Int {
        var landed = 0
        for romId in mirror.romIds() where owed(romId, mirror: mirror) != nil {
            let (sent, why) = await send(server, romId: romId, mirror: mirror)
            if sent == .landed || sent == .beside { landed += 1 }
            if !settled(sent) { log("game \(romId): still owed (\(why))") }
        }
        return landed
    }

    /// A START SENDS WHAT THE PHONE STILL OWES OF THE GAME BEFORE IT PICKS,
    /// when RomM answers: a phone back from a trip, its save made there still
    /// owed, while another device saved the game since. Sent, the push
    /// settles the usual way, on top when the phone's save was made later,
    /// else kept beside, and the start lists again and picks by the one rule.
    /// True when nothing is owed any more. Called inside oneAtATime.
    static func settleBeforeStart(_ server: Server, romId: Int, mirror: SaveMirror = .shared) async -> Bool {
        let (sent, why) = await sendOne(server, romId: romId, mirror: mirror)
        if !settled(sent) {
            log("game \(romId): its save waiting on the phone could not go to RomM before the start (\(why)); the phone's stands")
            return false
        }
        log("game \(romId): its save waiting on the phone went to RomM before the start picked")
        return true
    }

    private static func sendOne(_ server: Server, romId: Int, mirror: SaveMirror) async -> (sent: Sent, why: String) {
        guard var owed = owed(romId, mirror: mirror) else { return (.nothingOwed, "nothing is owed") }
        let bytes = owed.hasSave ? (try? Data(contentsOf: owedSaveURL(romId, mirror))) ?? Data() : Data()
        let picture = owed.savePictureName.isEmpty ? Data() : (try? Data(contentsOf: owedPictureURL(romId, mirror))) ?? Data()
        let stateDir = statesDir(romId, mirror: mirror)
        // The states it carries, off the disk with their pictures. One whose
        // file is gone is not sent.
        var made: [(state: OwedState, bytes: Data, picture: Data)] = []
        for s in owed.states {
            guard let b = try? Data(contentsOf: stateDir.appendingPathComponent(s.fileName)), !b.isEmpty else { continue }
            let pic = s.pictureName.isEmpty ? Data() : (try? Data(contentsOf: stateDir.appendingPathComponent(s.pictureName))) ?? Data()
            made.append((s, b, pic))
        }
        if owed.hasSave, bytes.isEmpty, !made.isEmpty {
            log("game \(romId)'s owed save has no file left; its states go alone")
            owed.hasSave = false
        }
        if bytes.isEmpty, made.isEmpty {
            clearOwed(romId, stamp: owed.stamp, mirror)
            log("game \(romId)'s owed snapshot has no file left; nothing to send")
            return (.nothingOwed, "its files are gone")
        }
        guard server.hasChannels() else { return (.waits, "RomM has not said it has save channels") }

        // What RomM is asked could not be had: refused for good when it
        // answered so (the game is gone, or hidden from this person), else
        // tried again.
        func unasked(_ error: Error) -> (sent: Sent, why: String) {
            let e = error as? SaveServerError ?? .unanswered(error.localizedDescription)
            return (e.forGood ? .refused : .notSent, e.words)
        }

        // THE FILES THE GAME'S CHANNELS CAN BE ON, AND THIS PERSON'S CHANNELS
        // ON THEM: the files as the phone remembers them, asked of RomM when
        // it has none, and once more when RomM no longer knows one of them.
        var files = (try? await server.files(romId, false)) ?? ChannelFiles(channelFile: 0, files: [])
        var askedFiles = false
        var channels: [SaveChannel] = []
        while true {
            if files.files.isEmpty {
                do { files = try await server.files(romId, true) } catch { return unasked(error) }
                askedFiles = true
                if files.files.isEmpty { return (.refused, "RomM lists no file of this game for its channels") }
            }
            do {
                channels = try await server.channels(files.files)
                break
            } catch SaveServerError.notFound(let words) {
                if askedFiles { return (.refused, words) }
                files = ChannelFiles(channelFile: 0, files: [])
            } catch {
                return unasked(error)
            }
        }
        func fileFor(_ channelId: String) -> Int {
            let c = channelId.isEmpty ? nil : channels.first { $0.id == channelId }
            if let c, c.romFileId != 0 { return c.romFileId }
            return files.channelFile
        }
        func named(_ label: String) -> SaveChannel? {
            channels.filter { $0.label == label }.max { $0.updatedAt < $1.updatedAt }
        }
        func target(_ push: SnapshotPush) -> SaveChannel? {
            push.channelId.isEmpty ? named(push.label) : channels.first { $0.id == push.channelId }
        }

        // WHERE IT GOES, now that RomM's channels are known: the channel the
        // marker names, or the person's own under the marker's name; and
        // never a hardcore one, whose place "softcore" takes.
        var push = SnapshotPush()
        push.channelId = owed.channelId
        push.label = owed.label.isEmpty ? defaultChannel : owed.label
        push.expectedCurrentId = owed.expectedCurrentId
        push.parentId = owed.parentId
        push.emulator = owed.emulator
        push.core = owed.core
        func intoSoftcore(madeFrom: Int) {
            push.channelId = named(softcoreChannel)?.id ?? ""
            push.label = softcoreChannel
            push.expectedCurrentId = 0
            push.parentId = madeFrom
        }
        if let t = target(push) {
            if t.hardcore { intoSoftcore(madeFrom: push.parentId != 0 ? push.parentId : push.expectedCurrentId) }
            else { push.channelId = t.id }
        }
        // THE SNAPSHOT THE PHONE HOLDS IN THAT CHANNEL NOW IS WHAT THE PUSH
        // BUILDS ON, whatever the marker named: an older push of this game
        // landed after the marker was written.
        if let holds = mirror.getHeld(romId), !push.channelId.isEmpty, holds.channelId == push.channelId {
            push.expectedCurrentId = holds.snapshotId
            push.parentId = 0
        }
        // A PUSH OF STATES ALONE GOES ONTO THE CHANNEL'S CURRENT, and A SAVE
        // ONTO A CURRENT THAT HOLDS NONE (the head of this file).
        func onTopOf(_ current: Snapshot) -> Bool {
            !owed.couldNotUseNewest && !current.hardcore
                && (!current.hasSave || (!owed.hasSave && SavePick.ownForm(current, tag: owed.emulator)))
        }
        if !owed.hasSave || push.parentId == 0, let t = target(push), !t.hardcore, t.currentId != 0, onTopOf(t.current) {
            push.channelId = t.id
            push.expectedCurrentId = t.currentId
            push.parentId = 0
        }
        func withSave() {
            push.hasSave = true
            push.save.hash = SaveHash.content(bytes)
            push.save.fileName = owed.saveName
            push.save.bytes = bytes
            if !picture.isEmpty {
                push.save.pictureName = owed.savePictureName
                push.save.picture = picture
            }
            push.saveShape = !SaveZip.looksLikeZip(bytes) ? "SINGLE" : owed.saveShape == "FOLDER" ? "FOLDER" : "MULTI"
        }
        if owed.hasSave { withSave() }

        // THE STATES IT NAMES: the ones made since, with their bytes and
        // pictures, and the newest of RomM's under the core's tag, by hash;
        // three, one per hash, in slots "1" to "3", newest first.
        let core = made.first?.state.core ?? ""
        if !made.isEmpty {
            let rows: [RommAsset]
            do { rows = try await server.states(romId) } catch { return unasked(error) }
            var picked: [(ms: Int64, state: PushState)] = []
            var hashes = Set<String>()
            var names = Set<String>()
            func add(_ ms: Int64, _ s: PushState) {
                guard picked.count < statesKept, hashes.insert(s.file.hash).inserted else { return }
                var s = s
                s.core = core
                picked.append((ms, s))
            }
            for m in made {
                var s = PushState()
                s.file.hash = SaveHash.content(m.bytes)
                s.file.fileName = m.state.fileName
                s.file.bytes = m.bytes
                if !m.picture.isEmpty {
                    s.file.pictureName = m.state.pictureName
                    s.file.picture = m.picture
                }
                names.insert(m.state.fileName)
                add(m.state.madeMs, s)
            }
            let theirs = rows.filter { filedUnder($0) == core && names.insert(ownName($0.fileName)).inserted }
                .enumerated().sorted { rowMadeMs($0.element) != rowMadeMs($1.element)
                    ? rowMadeMs($0.element) > rowMadeMs($1.element) : $0.offset < $1.offset }.map(\.element)
            // A STATE'S HASH, which RomM's list does not carry: off the
            // phone's copy, else as the channels' currents list it, else as
            // the history of the channel it was pushed into does, asked once.
            var known: [Int: String] = [:]
            for c in channels { for s in c.current.states where !s.file.contentHash.isEmpty { known[s.file.id] = s.file.contentHash } }
            var asked = Set<String>()
            for r in theirs {
                if picked.count == statesKept { break }
                var hash = ""
                if let mine = ownCopy(stateDir, r.fileName), let b = try? Data(contentsOf: mine), !b.isEmpty {
                    hash = SaveHash.content(b)
                } else {
                    if known[r.id] == nil, !r.channelId.isEmpty, asked.insert(r.channelId).inserted {
                        if let past = try? await server.history(r.channelId) {
                            for p in past { for s in p.states where !s.file.contentHash.isEmpty { known[s.file.id] = s.file.contentHash } }
                        }
                    }
                    hash = known[r.id] ?? ""
                }
                if hash.isEmpty {
                    log("game \(romId): \(r.fileName) is left out of the game's states: RomM gives no hash for it and the phone has no copy")
                    continue
                }
                var s = PushState()
                s.file.hash = hash
                s.file.fileName = r.fileName
                add(rowMadeMs(r), s)
            }
            picked = picked.enumerated().sorted { $0.element.ms != $1.element.ms
                ? $0.element.ms > $1.element.ms : $0.offset < $1.offset }.map(\.element)
            for (i, p) in picked.enumerated() {
                var s = p.state
                s.slot = String(i + 1)
                push.states.append(s)
            }
        }
        var namedHashes = Set(push.states.map(\.file.hash))
        var namedNames = Set(push.states.map { ownName($0.file.fileName) })

        // RomM LACKS SOME BYTES IT WAS NOT SENT: a state named by hash goes
        // up from the phone's copy, or leaves the bank when there is none;
        // the save from the owed file.
        func supply(_ missing: [String]) -> Bool {
            var any = false
            for key in missing {
                if key == "save" {
                    if !owed.hasSave || push.hasSave { return false }
                    withSave()
                    any = true
                    continue
                }
                guard let at = push.states.firstIndex(where: { key == "state:\($0.core):\($0.slot)" }),
                      push.states[at].file.bytes.isEmpty else { return false }
                if let copy = ownCopy(stateDir, push.states[at].file.fileName),
                   let mine = try? Data(contentsOf: copy), SaveHash.content(mine) == push.states[at].file.hash {
                    push.states[at].file.fileName = copy.lastPathComponent
                    push.states[at].file.bytes = mine
                    if let png = pictureOf(copy), let pic = try? Data(contentsOf: png) {
                        push.states[at].file.pictureName = png.lastPathComponent
                        push.states[at].file.picture = pic
                    }
                } else {
                    log("game \(romId): RomM no longer holds \(push.states[at].file.fileName), and the phone has no copy; it leaves the game's states")
                    push.states[at].file.hash = ""
                }
                any = true
            }
            push.states.removeAll { $0.file.hash.isEmpty }
            for i in push.states.indices { push.states[i].slot = String(i + 1) }
            return any
        }

        var beside = false
        var retargeted = false
        var held = Snapshot()
        var leftOut = 0
        var pushes = 0
        while true {
            pushes += 1
            if pushes > mostPushes + leftOut { return (.notSent, "RomM's channel kept changing while this was sent") }
            push.romFileId = fileFor(push.channelId)
            if push.romFileId == 0 { return (.refused, "RomM names no file of this game for a new channel") }
            let answer: PushAnswer
            do { answer = try await server.push(push) } catch { return unasked(error) }
            switch answer.kind {
            case .made, .unchanged:
                held = answer.snapshot
                beside = false
            case .movedOn:
                // RomM has it, beside the current.
                held = answer.snapshot
                beside = true
                if !owed.hasSave {
                    let again = answer.hasCurrent && onTopOf(answer.current)
                    log("game \(romId): RomM's channel had moved on; the phone's states kept beside its current as snapshot \(held.id)"
                        + (again ? ", and they go again onto that current" : ", where they stay"))
                    guard again else { break }
                    push.channelId = held.channelId.isEmpty ? push.channelId : held.channelId
                    push.expectedCurrentId = answer.current.id
                    push.parentId = 0
                    for i in push.states.indices {
                        push.states[i].file.bytes = Data()
                        push.states[i].file.pictureName = ""
                        push.states[i].file.picture = Data()
                    }
                    continue
                }
                if push.hasSave, answer.hasCurrent, onTopOf(answer.current) {
                    log("game \(romId): RomM's channel had moved on to snapshot \(answer.current.id), which holds no save; it goes again onto that one")
                    push.channelId = held.channelId.isEmpty ? push.channelId : held.channelId
                    push.expectedCurrentId = answer.current.id
                    push.parentId = 0
                    continue
                }
                // The current's save dated by its own row: a current that
                // changed only its states is newer than its save.
                var current = answer.current
                if answer.hasCurrent, let rows = try? await server.saves(romId) {
                    var one = [SaveChannel()]
                    one[0].currentId = current.id
                    one[0].current = current
                    SavePick.dateSaves(&one, rows: rows)
                    current = one[0].current
                }
                let theirs = answer.hasCurrent ? SavePick.isoMicros(SavePick.savedAt(current)) : 0
                let later = !answer.hasCurrent || owed.madeAt * 1_000_000 > theirs
                log("game \(romId): RomM's channel had moved on; the phone's save is kept beside its current as snapshot \(held.id)"
                    + (owed.couldNotUseNewest ? ", where it stays: the newest was a save the phone could not use"
                        : later ? ", and was made later, so it goes on top" : ", where it stays: the other was made later"))
                guard !owed.couldNotUseNewest, later else { break }
                // The same snapshot again as the channel's new current: the
                // branch named as what it is made from, so RomM carries its
                // save and states and no byte is sent.
                push.channelId = held.channelId.isEmpty ? push.channelId : held.channelId
                push.expectedCurrentId = answer.hasCurrent ? answer.current.id : 0
                push.parentId = held.id
                push.hasSave = false
                push.save = PushFile()
                push.states = []
                continue
            case .hardcoreChannel:
                if push.label == softcoreChannel { return (.refused, "RomM calls the softcore channel hardcore") }
                let madeFrom = beside ? held.id : push.parentId != 0 ? push.parentId : push.expectedCurrentId
                intoSoftcore(madeFrom: madeFrom)
                if beside { push.states = [] } else if owed.hasSave { withSave() }
                continue
            case .bytesMissing:
                if supply(answer.missing) { continue }
                return (.refused, "HTTP \(answer.status): \(answer.detail)")
            case .refused:
                // A STATE RomM COULD NOT HASH goes no further, and the push
                // goes again without it; it stays on the phone. A save RomM
                // cannot hash is never left out: it stays owed.
                if answer.status == 422, answer.unhashed.hasPrefix("state:"),
                   let at = push.states.firstIndex(where: { answer.unhashed == "state:\($0.core):\($0.slot)" }) {
                    log("game \(romId): RomM could not store \(push.states[at].file.fileName), so it stays on the phone and the game's snapshot goes without it")
                    push.states.remove(at: at)
                    for i in push.states.indices { push.states[i].slot = String(i + 1) }
                    leftOut += 1
                    continue
                }
                // A channel or a snapshot the marker names that RomM no longer
                // has (404) is asked once more as a save of its own, into the
                // person's channel of that name.
                if answer.status == 404, !retargeted, !beside {
                    retargeted = true
                    let again = named(push.label)
                    push.channelId = again.map { $0.hardcore ? "" : $0.id } ?? ""
                    push.expectedCurrentId = 0
                    push.parentId = 0
                    if again?.hardcore == true { intoSoftcore(madeFrom: 0) }
                    continue
                }
                return (.refused, "HTTP \(answer.status): \(answer.detail)")
            }
            break
        }
        namedHashes.formUnion(push.states.map(\.file.hash))
        namedNames.formUnion(push.states.map { ownName($0.file.fileName) })

        // RomM HOLDS IT. In this order: the copy of RomM's saves forgotten,
        // the snapshot noted as the one held, the marker cleared, the copy
        // listed again.
        let channelId = held.channelId.isEmpty ? push.channelId : held.channelId
        mirror.forget(romId)
        let before = mirror.getHeld(romId)
        var now = SavePick.heldAfter(before, channelId: channelId, taken: held, now: Int64(Date().timeIntervalSince1970))
        // When its save was made: the phone's note of it for a save it sent,
        // and for states alone the save's own time. STATES ALONE THAT WENT
        // ONTO ANOTHER SAVE leave the note's save as the one the phone last
        // had: the next start still says "Continuing from another device".
        if owed.hasSave {
            now.madeAt = owed.madeAt
        } else if let before, before.saveHash != now.saveHash {
            now.saveHash = before.saveHash
            now.hashesHad = before.hashesHad
            now.madeAt = before.madeAt
        } else if let before, before.madeAt != 0, before.saveHash == now.saveHash {
            now.madeAt = before.madeAt
        }
        now.beside = beside
        mirror.putHeld(romId, now)
        clearOwed(romId, stamp: owed.stamp, mirror)
        log("game \(romId): snapshot \(held.id) \(beside ? "is kept beside the current of" : "is the current of") channel \"\(push.label)\" on RomM ("
            + (owed.hasSave ? owed.saveName : "its states alone") + ", \(bytes.count) bytes; \(namedHashes.count) state(s) named)")
        // The phone's copies of states it no longer offers: kept are the ones
        // this push named and the ones in a push owed since.
        if !made.isEmpty {
            var keep = namedNames
            if let since = self.owed(romId, mirror: mirror) {
                for s in since.states { keep.insert(s.fileName) }
            }
            trimStates(stateDir, keepNames: keep, keepHashes: namedHashes, romId: romId)
        }
        // The copy for offline: RomM's lists as they are now, and the bytes
        // just sent kept as that snapshot's save. Should the asking fail there
        // is no copy, and offline uses the phone's own save, which is this one.
        if let rows = try? await server.saves(romId) { mirror.putRows(romId, rows) }
        if let listed = try? await server.channels(files.files) {
            mirror.putChannels(romId, listed)
            if owed.hasSave, let save = held.save, !bytes.isEmpty {
                mirror.putSnapshotSave(romId, save, bytes)
            }
        }
        return (beside ? .beside : .landed, "")
    }

    // MARK: Names

    /// THE NAME THE PHONE GAVE A FILE RomM STORED. RomM adds its own time to
    /// every file it keeps, " [2026-11-19_13-02-02-848]" before the
    /// extension, its milliseconds optional; taken off, what is left is the
    /// name the phone sent, and so the name of its own copy.
    static func ownName(_ stored: String) -> String {
        let u = Array(stored.utf8)
        let end = u.lastIndex(of: 0x2E) ?? u.count
        guard end > 0, u[end - 1] == 0x5D else { return stored }
        var open = end - 1
        while open > 0, !(u[open - 1] == 0x20 && u[open] == 0x5B) { open -= 1 }
        guard open > 0 else { return stored }
        let tag = Array(u[(open + 1)..<(end - 1)])
        let shape = Array("dddd-dd-dd_dd-dd-dd".utf8)
        guard tag.count == 19 || tag.count == 23 else { return stored }
        for (i, c) in tag.enumerated() {
            let want: UInt8 = i < 19 ? shape[i] : (i == 19 ? 0x2D : 0x64)
            let ok = want == 0x64 ? (c >= 0x30 && c <= 0x39) : c == want
            if !ok { return stored }
        }
        return String(decoding: u[..<(open - 1)] + u[end...], as: UTF8.self)
    }

    /// When a state was made, by the time the phone put in its name,
    /// "[2026-11-26 20-17-03-123]" (RomM's web player's form, which the TV
    /// writes too); 0 when it carries none.
    static func stateNameMs(_ fileName: String) -> Int64 {
        let u = Array(fileName.utf8)
        var i = 0
        while i < u.count {
            if u[i] == 0x5B, i + 25 <= u.count, u[i + 24] == 0x5D, u[i + 11] == 0x20 {
                let s = String(decoding: u[(i + 1)..<(i + 24)], as: UTF8.self)
                let parts = s.split(whereSeparator: { $0 == "-" || $0 == " " }).compactMap { Int($0) }
                if parts.count == 7 {
                    var c = DateComponents()
                    c.year = parts[0]; c.month = parts[1]; c.day = parts[2]
                    c.hour = parts[3]; c.minute = parts[4]; c.second = parts[5]
                    var calendar = Calendar(identifier: .gregorian)
                    calendar.timeZone = TimeZone(identifier: "UTC")!
                    if let date = calendar.date(from: c) {
                        return Int64(date.timeIntervalSince1970) * 1000 + Int64(parts[6])
                    }
                }
            }
            i += 1
        }
        return 0
    }

    /// THE NAME A STATE OF RomM'S LIST IS FILED UNDER: its bank's, or for one
    /// from before channels its emulator's.
    private static func filedUnder(_ row: RommAsset) -> String { row.core.isEmpty ? row.emulator : row.core }

    /// WHEN A STATE OF RomM'S LIST WAS MADE: the time in its name, else when
    /// RomM first stored it.
    private static func rowMadeMs(_ row: RommAsset) -> Int64 {
        let ms = stateNameMs(row.fileName)
        return ms != 0 ? ms : SavePick.isoMicros(row.createdAt) / 1000
    }

    private static func isFile(_ url: URL) -> Bool {
        var dir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &dir) && !dir.boolValue
    }

    /// The phone's copy of a state RomM stored, by the name the phone gave it.
    private static func ownCopy(_ dir: URL, _ stored: String) -> URL? {
        let mine = ownName(stored)
        guard !mine.isEmpty, mine != ".", mine != "..", !mine.contains("/") else { return nil }
        let url = dir.appendingPathComponent(mine)
        return isFile(url) ? url : nil
    }

    private static func pictureOf(_ state: URL) -> URL? {
        let png = state.deletingPathExtension().appendingPathExtension("png")
        return isFile(png) ? png : nil
    }

    /// The phone's copies of states it no longer offers: every state file
    /// whose name is none of `keepNames` and whose bytes are none of
    /// `keepHashes`, with its picture. RomM keeps them in the game's history.
    private static func trimStates(_ dir: URL, keepNames: Set<String>, keepHashes: Set<String>, romId: Int) {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for f in files where f.pathExtension == "state" && !keepNames.contains(f.lastPathComponent) {
            if let b = try? Data(contentsOf: f), keepHashes.contains(SaveHash.content(b)) { continue }
            try? FileManager.default.removeItem(at: f)
            try? FileManager.default.removeItem(at: f.deletingPathExtension().appendingPathExtension("png"))
            log("game \(romId): \(f.lastPathComponent) is no longer among its three; RomM keeps it in the game's history")
        }
    }

    /// Where the save lines go: the system log (category "saves"), read
    /// with Console; the lab prints them.
    static var log: (String) -> Void = { line in saveLog.info("\(line, privacy: .public)") }
    private static let saveLog = Logger(subsystem: "com.mmagtech.cabinet-go", category: "saves")
}

/// Why RomM could not be asked, as a push and a start tell it apart.
enum SaveServerError: Error, Equatable {
    /// 404: the game, a file or a channel RomM no longer knows.
    case notFound(String)
    /// Any other answer that will not change by asking again (4xx but 408
    /// and 429, CabinetOS's refusedForGood).
    case refused(String)
    /// No answer, or one worth asking again.
    case unanswered(String)

    var forGood: Bool {
        switch self {
        case .notFound, .refused: return true
        case .unanswered: return false
        }
    }

    var words: String {
        switch self {
        case .notFound(let w), .refused(let w), .unanswered(let w): return w
        }
    }
}
