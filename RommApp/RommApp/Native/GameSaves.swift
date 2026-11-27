import Foundation
import UIKit

/// ONE SITTING'S SAVES, gathered and put back for each kind: the battery
/// (with Gambatte's clock beside it), the one file a core writes (melonDS,
/// Beetle NGP, the VMU card), and PSP's SAVEDATA folders. The phone's half of
/// what CabinetOS's saves.cpp does: the start's pick put in place, the save
/// gathered at pause, at background and at Quit and handed to SavePush, the
/// states written and offered, and the save's picture. The rule is SavePick's
/// and the push SavePush's; each core's form is SaveForm's.
///
/// THE START (start, then seat for a battery). The file cores' files are
/// gathered from the game's save folder first, so a save a core wrote before
/// iOS ended the app is kept and owed, never written over by an older copy.
/// Then, with any push of the game finished (SavePush.oneAtATime): what the
/// phone still owes goes first while RomM answers, RomM's channels and the
/// game's saves are listed (or, with no connection, read as last seen,
/// SaveMirror), the rule picks, another emulator's save is asked of RomM in
/// the phone's form and checked, and the pick's save is put in place: a
/// file or a folder before the core loads, a battery as the first frame
/// runs. A save of the phone's that it replaces is kept aside first, one copy
/// per game. Nothing is asked of the player.
///
/// WHEN IT SAVES. At Quit, and when the app goes to the background, since iOS
/// can end a backgrounded app with no warning (the step 5 plan, part 3, rule
/// 3). The phone's own copy is written first every time; nothing changed,
/// nothing sent. The pause menu writes the phone's copy of a battery and
/// marks it owed, and sends nothing.
///
/// THE SAVE'S PICTURE. Nothing tells the phone that a game saved: a save is
/// bytes that change. So for a battery the sitting looks at the save once a
/// second while the game runs (look), and takes the picture at the first look
/// that agrees with the one before and differs from the save at the last
/// picture: about a second after the game has finished writing it, RomM's
/// own web player's rule, as on the TV. None for DS, NGP and PSP, whose cores
/// write as the game closes or keep nothing to compare.
@MainActor
final class GameSaves {
    /// The TV's words for a start (frontend/src/saves.h).
    static let continuingElsewhere = "Continuing from another device"
    static let couldNotUseNewest = "Couldn't use the newest save"
    /// The TV's words for a state made (the pause menu's notice).
    static let stateSaved = "State saved"

    /// Where a sitting's save lives on the phone.
    enum Place {
        /// In the core's memory; the phone's copy is `<stem>.srm` (and
        /// `<stem>.rtc`) in the game's save folder.
        case battery
        /// One file, where the core reads and writes it.
        case file(URL)
        /// PSP's SAVEDATA folder.
        case folder(URL)
    }

    let romId: Int
    let form: SaveForm
    /// SaveRowNames.stem of the game's file name.
    let stem: String
    /// The game's name, for a PSP save's zip.
    let title: String
    let saveDir: URL
    let place: Place
    private let mirror: SaveMirror

    /// Where what this sitting saves is aimed (SavePush), set by the start.
    private(set) var aim: SavePush.AimFrom
    /// What the start says over the game, once it is in place; nil for
    /// nothing.
    private(set) var notice: String?

    private var listed = false
    private var pick = SavePick.Pick()
    /// The pick's save in the phone's form; nil when the phone's own stands.
    private var picked: Data?
    /// The pick's save is another emulator's, converted by RomM.
    private var converted = false

    /// The battery as the sitting started, or as last gathered; the clock
    /// the same.
    private var saveAtLaunch = Data()
    private var clockAtLaunch = Data()
    /// A save gathered since the last mark, nil while nothing changed.
    private var changed: Data?
    private var changedAt: Int64 = 0

    /// The battery is in the core (seat).
    private(set) var seated = false

    private var lastLook: Data?
    private var pictureSave: Data?
    private var picture: Data?

    private init(romId: Int, form: SaveForm, stem: String, title: String, saveDir: URL, place: Place,
                 mirror: SaveMirror) {
        self.romId = romId
        self.form = form
        self.stem = stem
        self.title = title
        self.saveDir = saveDir
        self.place = place
        self.mirror = mirror
        aim = SavePush.AimFrom(romId: romId, tag: form.tag, core: form.sigil)
    }

    // MARK: The start

    /// A game's sitting, its pick put in place where a file or a folder is
    /// the save; a battery is seated by `seat` once the core has loaded. Nil
    /// for a core with no saves (Game & Watch). Run before the core loads.
    static func start(rom: Rom, core: NativeCore, loadURL: URL, saveDir: URL, session: Session) async -> GameSaves? {
        guard let form = SaveForm.forTag(core.emulatorTag) else { return nil }
        let place: Place
        switch form.kind {
        case .battery:
            place = .battery
        case .file(let ext):
            place = .file(saveDir.appendingPathComponent(loadURL.deletingPathExtension().lastPathComponent + "." + ext))
        case .folder:
            place = .folder(NativeLauncher.pspSaveDataDirectory(saveDir: saveDir))
        }
        let saves = GameSaves(romId: rom.id, form: form, stem: SaveRowNames.stem(fsName: rom.fsName),
                              title: rom.name ?? rom.fsName, saveDir: saveDir, place: place, mirror: .shared)
        await saves.begin(session: session)
        return saves
    }

    /// The Dreamcast game's VMU card as a sitting of the VMU player: Flycast's
    /// save under `flycast-native`, the card being the file.
    static func startCard(rom: Rom, cardURL: URL, session: Session) async -> GameSaves? {
        guard let form = SaveForm.forTag(NativeCore.flycast.emulatorTag) else { return nil }
        let saves = GameSaves(romId: rom.id, form: form, stem: SaveRowNames.stem(fsName: rom.fsName),
                              title: rom.name ?? rom.fsName, saveDir: cardURL.deletingLastPathComponent(),
                              place: .file(cardURL), mirror: .shared)
        await saves.begin(session: session)
        return saves
    }

    private func begin(session: Session) async {
        // A save a core wrote that never reached a mark: the sitting before
        // ended with the app (fault 2 of the plan's part 2).
        gatherLeftover()
        let online = await Self.askOnline(session)
        let server = Self.server(session)
        await SavePush.oneAtATime(romId) {
            await listAndPick(server: server, online: online)
        }
        switch place {
        case .battery:
            break
        case .file(let url):
            putFile(url)
        case .folder(let url):
            putFolder(url)
        }
        writeBaseline()
    }

    private func listAndPick(server: SavePush.Server, online: Bool) async {
        if online, SavePush.saveOwed(romId, mirror: mirror) {
            _ = await SavePush.settleBeforeStart(server, romId: romId, mirror: mirror)
        }
        var facts = SavePick.Facts()
        facts.tag = form.tag
        var rows: [RommAsset] = []
        if online {
            do {
                var files = mirror.getFiles(romId)
                if files.files.isEmpty { files = try await server.files(romId, true) }
                var channels: [SaveChannel]
                do {
                    channels = files.files.isEmpty ? [] : try await server.channels(files.files)
                } catch SaveServerError.notFound {
                    files = try await server.files(romId, true)
                    channels = files.files.isEmpty ? [] : try await server.channels(files.files)
                }
                rows = try await server.saves(romId)
                mirror.putChannels(romId, channels)
                mirror.putRows(romId, rows)
                facts.channels = channels
                listed = true
            } catch {
                let e = error as? SaveServerError ?? .unanswered(error.localizedDescription)
                // A server that is there and answered wrong: nothing is known
                // for sure, and half a view could put an older save over a
                // newer one. One that did not answer is away: as offline.
                guard case .unanswered = e, let channels = mirror.getChannels(romId) else {
                    Self.log("game \(romId): RomM's saves could not be listed (\(e.words)); the phone's own stands")
                    return
                }
                facts.channels = channels
                rows = mirror.getRows(romId) ?? []
                listed = true
                Self.log("game \(romId): RomM did not answer (\(e.words)); its saves as last seen")
            }
        } else if let channels = mirror.getChannels(romId) {
            facts.channels = channels
            rows = mirror.getRows(romId) ?? []
            listed = true
            Self.log("game \(romId): no connection or no save channels; RomM's saves as last seen")
        } else {
            Self.log("game \(romId): no connection, and RomM's saves were never seen here; the phone's own stands")
            return
        }
        SavePick.dateSaves(&facts.channels, rows: rows)
        facts.otherRows = SavePick.otherRows(rows, tag: form.tag, channels: facts.channels)
        facts.owed = SavePush.saveOwed(romId, mirror: mirror)
        facts.held = mirror.getHeld(romId)
        pick = SavePick.pick(facts)
        Self.log("game \(romId): \(pick.why)")
        if pick.other {
            var why = online ? "" : "no connection"
            var holdsNone = false
            if online, let mine = await askOther(server: server, why: &why, holdsNone: &holdsNone) {
                picked = mine
                converted = true
            } else {
                Self.log("game \(romId): \(holdsNone ? "no save of this game in" : "could not use") the newest: \(why)")
                pick = SavePick.pick(facts, others: holdsNone ? .holdsNone : .unusable)
                Self.log("game \(romId): \(pick.why)")
            }
        }
        if pick.from == .channel, !converted, let save = pick.channel.current.save {
            if let kept = mirror.getSnapshotSave(romId, save), SaveHash.content(kept) == save.contentHash {
                picked = kept
            } else if online, let bytes = try? await server.content(save.id), !bytes.isEmpty {
                mirror.putSnapshotSave(romId, save, bytes)
                picked = bytes
            }
            if picked == nil { Self.log("game \(romId): snapshot \(pick.channel.current.id)'s save did not come") }
        }
    }

    /// ANOTHER EMULATOR'S SAVE, ASKED OF RomM IN THE PHONE'S FORM AND
    /// CHECKED (SaveForm.ownForm). RomM says it converts no save of a system
    /// as "can't be converted"; then it is asked as stored, checked the same.
    private func askOther(server: SavePush.Server, why: inout String, holdsNone: inout Bool) async -> Data? {
        let row = pick.from == .otherRow
        let saveId = row ? pick.row.id : pick.channel.current.save?.id ?? 0
        let madeBy = row ? pick.row.emulator : pick.channel.current.save?.emulator ?? ""
        let madeByCore = row ? "" : pick.channel.current.save?.core ?? ""
        var answer = await server.saveAs(saveId, form.askQuery)
        let plain = answer.status == 400 && answer.error.contains("can't be converted")
        if plain { answer = await server.saveAs(saveId, []) }
        guard answer.status == 200 else {
            why = answer.status == 0 ? "RomM did not answer: \(answer.error)" : "RomM answered \(answer.status) (\(answer.error))"
            holdsNone = SaveForm.holdsNoneOfTheGame(answer)
            return nil
        }
        switch form.ownForm(of: answer, plain: plain, madeBy: madeBy, madeByCore: madeByCore, stem: stem) {
        case .success(let mine):
            Self.log("game \(romId): another emulator's save from RomM in the phone's form (\(form.sigil), \(mine.count) bytes)")
            return mine
        case .failure(let refusal):
            why = refusal.why
            return nil
        }
    }

    /// One file put in place before the core loads: the pick's, the file
    /// there kept aside first when it differs.
    private func putFile(_ url: URL) {
        guard let incoming = picked, !incoming.isEmpty else { return noteStart(took: false, changedOwn: false) }
        let local = try? Data(contentsOf: url)
        let changedOwn = local != incoming
        if changedOwn {
            if let local, !local.isEmpty { keepAside(url.lastPathComponent, local) }
            mirror.write(incoming, to: url)
        }
        Self.log("game \(romId): \(url.lastPathComponent) from RomM (\(incoming.count) bytes)")
        noteStart(took: true, changedOwn: changedOwn)
    }

    /// PSP's folders put in place before the core loads: each save folder in
    /// the pick's zip replaces the one of that name, whole; a folder the zip
    /// does not hold stays. What was there is kept aside first, as one zip.
    private func putFolder(_ dir: URL) {
        guard let incoming = picked, let files = SaveZip.entries(of: incoming), !files.isEmpty else {
            return noteStart(took: false, changedOwn: false)
        }
        let local = SaveZip.archive(saveData: dir)
        let changedOwn = local.map { SaveHash.content($0) != SaveHash.content(incoming) } ?? true
        if changedOwn {
            if let local { keepAside("SAVEDATA.zip", local) }
            let fm = FileManager.default
            let tops = Set(files.compactMap { $0.path.split(separator: "/").first.map(String.init) })
            for top in tops where top != "." && top != ".." { try? fm.removeItem(at: dir.appendingPathComponent(top)) }
            for f in files where !f.path.split(separator: "/").contains(where: { $0 == ".." }) {
                mirror.write(f.data, to: dir.appendingPathComponent(f.path))
            }
        }
        Self.log("game \(romId): PSP save folders from RomM (\(files.count) files)")
        noteStart(took: true, changedOwn: changedOwn)
    }

    /// A BATTERY SEATED as the first frame runs: the pick's, else the phone's
    /// own copy, with the clock beside it where it travels. Another
    /// emulator's battery must fit the loaded core's (coreReadsBattery). The
    /// phone's copy follows the save it started from. Run once the core has
    /// loaded, before the draw loop is let go.
    func seat(_ renderer: NativePlayerRenderer) {
        guard case .battery = place, !seated else { return }
        seated = true
        let srm = saveDir.appendingPathComponent(stem + ".srm")
        let rtc = saveDir.appendingPathComponent(stem + ".rtc")
        let local = (try? Data(contentsOf: srm)) ?? Data()
        let localClock = (try? Data(contentsOf: rtc)) ?? Data()
        var incoming: Data?
        var incomingClock: Data?
        if let bytes = picked {
            if let parts = SaveForm.batteryParts(bytes), !parts.battery.isEmpty {
                if converted, !SaveForm.coreReadsBattery(parts.battery.count, coreBytes: LibretroFrontend.shared.saveRAMSize()) {
                    Self.log("game \(romId): another emulator's battery is \(parts.battery.count) bytes, longer than this core's \(LibretroFrontend.shared.saveRAMSize()); the phone's stands")
                } else {
                    incoming = parts.battery
                    incomingClock = parts.clock
                }
            } else {
                Self.log("game \(romId): the pick's save holds no battery; the phone's stands")
            }
        }
        var tookNewBattery = false
        if let incoming {
            let changedOwn = local != incoming
            if changedOwn {
                if !local.isEmpty { keepAside(srm.lastPathComponent, local) }
                mirror.write(incoming, to: srm)
            }
            renderer.pendingSaveRAM = incoming
            saveAtLaunch = incoming
            tookNewBattery = changedOwn
            noteStart(took: true, changedOwn: changedOwn)
        } else {
            if !local.isEmpty {
                renderer.pendingSaveRAM = local
                saveAtLaunch = local
            } else {
                saveAtLaunch = renderer.snapshotSaveRAM() ?? Data()
            }
            noteStart(took: false, changedOwn: false)
        }
        // The clock: RomM's when it came with RomM's battery and is the
        // core's size, else the phone's own when that is.
        if form.clock {
            let size = renderer.snapshotRTC()?.count ?? 0
            let incomingFits = size > 0 && incomingClock?.count == size
            let localFits = size > 0 && localClock.count == size
            if let clock = incomingClock, incomingFits, tookNewBattery || !localFits {
                if clock != localClock {
                    if !localClock.isEmpty { keepAside(rtc.lastPathComponent, localClock) }
                    mirror.write(clock, to: rtc)
                }
                renderer.pendingRTC = clock
                clockAtLaunch = clock
            } else if localFits {
                renderer.pendingRTC = localClock
                clockAtLaunch = localClock
            } else {
                clockAtLaunch = renderer.snapshotRTC() ?? Data()
            }
        }
        pictureSave = saveAtLaunch
    }

    /// WHAT A START LEAVES IN THE NOTES: where the sitting started from, for
    /// where what it saves is aimed, and the snapshot held when one was put
    /// in place; the notice over the game.
    private func noteStart(took: Bool, changedOwn: Bool) {
        guard listed else { return }
        let fromRomM = pick.from == .channel || pick.from == .otherRow
        aim.couldNotUseNewest = pick.couldNotUseNewest || (fromRomM && !took)
        if took, pick.from == .channel {
            aim.startChannelId = pick.channel.id
            aim.startSnapshotId = pick.channel.current.id
            aim.startHardcore = pick.channel.hardcore
            mirror.putHeld(romId, SavePick.heldAfter(mirror.getHeld(romId), channelId: pick.channel.id,
                                                     taken: pick.channel.current, now: Int64(Date().timeIntervalSince1970)))
        }
        if took, SavePick.continuingElsewhere(pick, sameAsOwn: !changedOwn) {
            notice = Self.continuingElsewhere
        } else if aim.couldNotUseNewest {
            notice = Self.couldNotUseNewest
        }
        if took { Self.log("game \(romId): started from \(pick.from == .channel ? "snapshot \(pick.channel.current.id)" : "save \(pick.row.id)")"
            + (changedOwn ? "" : ", which the phone already had") + (notice.map { "; \($0)" } ?? "")) }
    }

    /// THE SAVE A START REPLACES IS KEPT ASIDE FIRST, one copy per game,
    /// replaced by the next start that replaces one. Never sent anywhere.
    private func keepAside(_ name: String, _ bytes: Data) {
        let dir = mirror.gameDir(romId).appendingPathComponent("aside", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        mirror.write(bytes, to: dir.appendingPathComponent(name))
        Self.log("game \(romId): a save from RomM replaces the phone's; its own (\(bytes.count) bytes) is kept aside")
    }

    // MARK: Gathering

    /// The bytes of a file or folder save as they are on the phone now.
    private func onDisk() -> Data? {
        switch place {
        case .battery: return nil
        case .file(let url): return try? Data(contentsOf: url)
        case .folder(let dir): return SaveZip.archive(saveData: dir)
        }
    }

    /// The hash of a file or folder save as it was put in place or last
    /// marked, so a change made since, by a sitting the app's end cut off,
    /// is found at the next start.
    private var baselineURL: URL { mirror.gameDir(romId).appendingPathComponent("baseline.json") }

    private func writeBaseline() {
        guard let bytes = onDisk() else { return }
        mirror.write(Data(SaveHash.content(bytes).utf8), to: baselineURL)
    }

    private func gatherLeftover() {
        guard let bytes = onDisk(), !bytes.isEmpty,
              let baseline = (try? Data(contentsOf: baselineURL)).map({ String(decoding: $0, as: UTF8.self) }),
              SaveHash.content(bytes) != baseline, holdsSave(bytes)
        else { return }
        Self.log("game \(romId): a save the core wrote last time never went up; owed now")
        changed = bytes
        changedAt = newestFileTime()
        markChanged()
    }

    private func holdsSave(_ bytes: Data) -> Bool {
        switch form.kind {
        case .battery: return SaveForm.holdsASave(bytes)
        case .file: return form.fileFits(bytes) == nil
        case .folder: return true
        }
    }

    /// When the save's files were last written, seconds since 1970; now
    /// when not known.
    private func newestFileTime() -> Int64 {
        let now = Int64(Date().timeIntervalSince1970)
        var urls: [URL] = []
        switch place {
        case .battery: return now
        case .file(let url): urls = [url]
        case .folder(let dir):
            let walker = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])
            while let u = walker?.nextObject() as? URL { urls.append(u) }
        }
        let newest = urls.compactMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
            .map { Int64($0.timeIntervalSince1970) }.max() ?? now
        return min(newest, now)
    }

    /// THE BATTERY, AND ITS CLOCK, READ OUT OF THE CORE: the phone's copy
    /// written when it changed. A clock that only ticked is written and is no
    /// new save: it goes up with the game's next save. With the core loaded:
    /// at the pause menu, at background, and before Quit unloads it.
    func gatherBattery(_ renderer: NativePlayerRenderer) {
        guard case .battery = place, let ram = renderer.snapshotSaveRAM(), !ram.isEmpty else { return }
        if form.clock, let clock = renderer.snapshotRTC(), !clock.isEmpty, clock != clockAtLaunch {
            mirror.write(clock, to: saveDir.appendingPathComponent(stem + ".rtc"))
            clockAtLaunch = clock
        }
        guard !SaveForm.sameBattery(ram, saveAtLaunch) else { return }
        mirror.write(ram, to: saveDir.appendingPathComponent(stem + ".srm"))
        saveAtLaunch = ram
        changed = ram
        changedAt = Int64(Date().timeIntervalSince1970)
        // The game is still on screen: a save not pictured since it changed
        // takes its picture now, as RomM's web player does on leaving.
        if !SaveForm.sameBattery(ram, pictureSave ?? Data()) {
            picture = renderer.screenshotPNG()
            pictureSave = ram
        }
    }

    /// What the pause menu gathered, marked owed and sent nothing: iOS can
    /// end an app paused in the foreground too.
    func keepOwed() {
        markChanged()
    }

    /// A file or folder save read off the disk: at background, and after
    /// Quit has unloaded the core and made it write.
    func gatherFiles() {
        guard let bytes = onDisk(), !bytes.isEmpty, holdsSave(bytes) else { return }
        let baseline = (try? Data(contentsOf: baselineURL)).map { String(decoding: $0, as: UTF8.self) }
        guard SaveHash.content(bytes) != baseline else { return }
        changed = bytes
        changedAt = newestFileTime()
    }

    /// LEAVING: what changed marked as owed, then sent. The task finishes
    /// when RomM has answered or could not be reached; the marker stays
    /// either way until a push lands. Nil when nothing is owed.
    @discardableResult
    func leave(session: Session) -> Task<Void, Never>? {
        markChanged()
        guard SavePush.owed(romId, mirror: mirror) != nil else { return nil }
        let server = Self.server(session)
        let romId = romId
        let mirror = mirror
        return Task { @MainActor in
            let (sent, why) = await SavePush.send(server, romId: romId, mirror: mirror)
            if !SavePush.settled(sent) { Self.log("game \(romId): still owed (\(why))") }
        }
    }

    private func markChanged() {
        guard let bytes = changed else { return }
        var up = bytes
        var zipped = false
        if case .battery = place, form.clock,
           let clock = try? Data(contentsOf: saveDir.appendingPathComponent(stem + ".rtc")), !clock.isEmpty {
            up = SaveForm.batteryZip(battery: bytes, clock: clock, stem: stem)
            zipped = true
        }
        if case .folder = place { zipped = true }
        var pic: Data?
        if case .battery = place { pic = picture }
        let g = SavePush.Gathered(bytes: up, name: form.upName(stem: stem, title: title, zipped: zipped),
                                  shape: form.shape(zipped: zipped), picture: pic, madeAt: changedAt)
        if SavePush.mark(g, from: aim, mirror: mirror) {
            changed = nil
            picture = nil
            if case .battery = place {} else {
                mirror.write(Data(SaveHash.content(bytes).utf8), to: baselineURL)
            }
        }
    }

    /// THE SAVE'S PICTURE, looked for once a second while the game runs (the
    /// head of this file). A battery only.
    func look(_ renderer: NativePlayerRenderer) {
        guard case .battery = place, !renderer.paused, let ram = renderer.snapshotSaveRAM() else { return }
        defer { lastLook = ram }
        guard let last = lastLook, SaveForm.sameBattery(ram, last),
              !SaveForm.sameBattery(ram, pictureSave ?? saveAtLaunch) else { return }
        picture = renderer.screenshotPNG()
        pictureSave = ram
    }

    // MARK: States

    /// A STATE JUST MADE, written to the phone first and marked owed in the
    /// game's push (SavePush.markState). `stem` names it, the time in it.
    func keepState(_ state: Data, picture: Data?, stem: String) -> Bool {
        let dir = SavePush.statesDir(romId, mirror: mirror)
        let name = stem + ".state"
        guard (try? state.write(to: dir.appendingPathComponent(name), options: .atomic)) != nil else { return false }
        var pictureName = ""
        if let picture, (try? picture.write(to: dir.appendingPathComponent(stem + ".png"), options: .atomic)) != nil {
            pictureName = stem + ".png"
        }
        let ms = SavePush.stateNameMs(name)
        return SavePush.markState(
            SavePush.StateMade(fileName: name, pictureName: pictureName,
                               madeMs: ms != 0 ? ms : Int64(Date().timeIntervalSince1970 * 1000)),
            from: aim, mirror: mirror)
    }

    /// Sends what the game owes, its states included, in the background.
    func sendOwed(session: Session) {
        let server = Self.server(session)
        let romId = romId
        Task { @MainActor in _ = await SavePush.send(server, romId: romId) }
    }

    /// THE THREE STATES THE GAME OFFERS (SavePush.offeredStates): RomM's list
    /// with a connection and channels, else the phone's own files.
    static func offeredStates(romId: Int, tag: String, session: Session) async -> [SavePush.OfferedState] {
        var rows: [RommAsset]?
        if await askOnline(session) { rows = try? await server(session).states(romId) }
        return SavePush.offeredStates(romId, tag: tag, rows: rows)
    }

    /// A state's bytes: the phone's copy, else RomM's.
    static func stateBytes(_ state: SavePush.OfferedState, session: Session) async -> Data? {
        if let file = state.file, let data = try? Data(contentsOf: file) { return data }
        guard state.rommId != 0 else { return nil }
        return try? await session.assetContent(kind: "states", id: state.rommId)
    }

    /// THE KEEP-TIME FETCH: RomM's channels and the game's saves into the
    /// phone's copy, the bytes of the save a start would continue from, and
    /// the three states the game offers into its `states/`, so a kept game
    /// played with no connection starts as it would online.
    static func fetchForOffline(romId: Int, tag: String, session: Session) async {
        guard await askOnline(session) else { return }
        let s = server(session)
        let mirror = SaveMirror.shared
        await SavePush.oneAtATime(romId) {
            var files = mirror.getFiles(romId)
            if files.files.isEmpty { files = (try? await s.files(romId, true)) ?? files }
            let listed: [SaveChannel]? = files.files.isEmpty ? [] : try? await s.channels(files.files)
            guard let channels = listed, let rows = try? await s.saves(romId) else { return }
            mirror.putChannels(romId, channels)
            mirror.putRows(romId, rows)
            var facts = SavePick.Facts()
            facts.tag = tag
            facts.channels = channels
            SavePick.dateSaves(&facts.channels, rows: rows)
            facts.owed = SavePush.saveOwed(romId)
            facts.held = mirror.getHeld(romId)
            let pick = SavePick.pick(facts, others: .unusable)
            if pick.from == .channel, let save = pick.channel.current.save,
               mirror.getSnapshotSave(romId, save) == nil,
               let bytes = try? await s.content(save.id), !bytes.isEmpty {
                mirror.putSnapshotSave(romId, save, bytes)
            }
        }
        guard let rows = try? await s.states(romId) else { return }
        let dir = SavePush.statesDir(romId)
        for o in SavePush.offeredStates(romId, tag: tag, rows: rows) where o.file == nil && o.rommId != 0 {
            let name = SavePush.ownName(o.fileName)
            guard !name.contains("/"), let bytes = try? await session.assetContent(kind: "states", id: o.rommId) else { continue }
            mirror.write(bytes, to: dir.appendingPathComponent(name))
            if !o.picture.isEmpty, let png = try? await session.screenshotData(path: o.picture) {
                mirror.write(png, to: dir.appendingPathComponent(name).deletingPathExtension().appendingPathExtension("png"))
            }
        }
    }

    // MARK: The game screen

    /// THE GAME'S OWN SAVE, the one a start would continue from, by the
    /// start's own rule: "Saved today, 8:17 PM". RomM's, or its copy as last
    /// seen; or the phone's own when that is newer and still owed. Nil when
    /// there is none to say.
    static func savedLine(romId: Int, tag: String, session: Session) async -> String? {
        let mirror = SaveMirror.shared
        var facts = SavePick.Facts()
        facts.tag = tag
        var rows: [RommAsset] = []
        var known = false
        if await askOnline(session) {
            let s = server(session)
            var files = mirror.getFiles(romId)
            if files.files.isEmpty { files = (try? await s.files(romId, true)) ?? files }
            let channels: [SaveChannel]? = files.files.isEmpty ? [] : try? await s.channels(files.files)
            let listed = try? await s.saves(romId)
            if let channels, let listed {
                facts.channels = channels
                rows = listed
                known = true
            }
        }
        if !known, let channels = mirror.getChannels(romId) {
            facts.channels = channels
            rows = mirror.getRows(romId) ?? []
        }
        SavePick.dateSaves(&facts.channels, rows: rows)
        facts.otherRows = SavePick.otherRows(rows, tag: tag, channels: facts.channels)
        facts.owed = SavePush.saveOwed(romId)
        facts.held = mirror.getHeld(romId)
        var at = SavePick.isoMicros(SavePick.pickedAt(SavePick.pick(facts)))
        if let owed = SavePush.owed(romId), owed.hasSave, owed.madeAt * 1_000_000 > at { at = owed.madeAt * 1_000_000 }
        guard at > 0 else { return nil }
        var words = when(Date(timeIntervalSince1970: TimeInterval(at) / 1_000_000))
        if words.hasPrefix("Today") || words.hasPrefix("Yesterday") {
            words = words.prefix(1).lowercased() + words.dropFirst()
        }
        return "Saved " + words
    }

    /// The TV's words for a moment (frontend/src/timewords.cpp, stateWhen):
    /// "Today, 8:17 PM", "Yesterday, 8:17 PM", "Nov 26, 8:17 PM", and the
    /// year when it is not this one, in the phone's own time.
    static func when(_ date: Date) -> String {
        let calendar = Calendar.current
        let clock = DateFormatter()
        clock.locale = Locale(identifier: "en_US_POSIX")
        clock.dateFormat = "h:mm a"
        let day: String
        if calendar.isDateInToday(date) {
            day = "Today"
        } else if calendar.isDateInYesterday(date) {
            day = "Yesterday"
        } else {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = calendar.component(.year, from: date) == calendar.component(.year, from: Date())
                ? "MMM d" : "MMM d yyyy"
            day = f.string(from: date)
        }
        return day + ", " + clock.string(from: date)
    }

    // MARK: RomM

    /// RomM is asked about saves: a connection, and a server that has save
    /// channels. On a RomM too old for them the phone neither reads nor
    /// writes saves, and says nothing.
    static func online(_ session: Session) -> Bool {
        !NetworkMonitor.shared.isOffline && session.serverHasChannels
    }

    /// The same, asking the server's heartbeat first when the phone does not
    /// know yet whether it has save channels: right after an install, or a
    /// new server, the first screens would otherwise read saves as offline
    /// until the heartbeat came back.
    static func askOnline(_ session: Session) async -> Bool {
        if !session.serverHasChannels, !NetworkMonitor.shared.isOffline {
            await session.refreshServerVersion()
        }
        return online(session)
    }

    /// The real one: RomM, through the session's client.
    static func server(_ session: Session) -> SavePush.Server {
        SavePush.Server(
            hasChannels: { session.serverHasChannels },
            files: { romId, ask in
                if !ask { return SaveMirror.shared.getFiles(romId) }
                do {
                    let files = try await session.channelFiles(romId: romId)
                    SaveMirror.shared.putFiles(romId, files)
                    return files
                } catch { throw serverError(error) }
            },
            channels: { ids in
                do { return try await session.channels(fileIds: ids) } catch { throw serverError(error) }
            },
            push: { push in
                do { return try await session.pushSnapshot(push) } catch { throw serverError(error) }
            },
            saves: { romId in
                do { return try await session.saveRows(romId: romId) } catch { throw serverError(error) }
            },
            states: { romId in
                do { return try await session.stateRows(romId: romId) } catch { throw serverError(error) }
            },
            history: { channelId in
                do { return try await session.channelHistory(channelId: channelId) } catch { throw serverError(error) }
            },
            content: { saveId in
                do { return try await session.assetContent(kind: "saves", id: saveId) } catch { throw serverError(error) }
            },
            saveAs: { saveId, query in await session.saveAs(saveId: saveId, query: query) }
        )
    }

    /// RomM's error as a push tells it apart: not found, refused for good,
    /// or worth asking again (CabinetOS's refusedForGood).
    static func serverError(_ error: Error) -> SaveServerError {
        guard let e = error as? RommError else { return .unanswered(error.localizedDescription) }
        switch e {
        case .notFound: return .notFound("HTTP 404")
        case .offline, .transport, .decoding: return .unanswered(e.localizedDescription)
        case .http(let code):
            return code == 408 || code == 429 || code >= 500 ? .unanswered("HTTP \(code)") : .refused("HTTP \(code)")
        default: return .refused(e.localizedDescription)
        }
    }

    /// The save lines (SavePush.log).
    static func log(_ line: String) {
        SavePush.log(line)
    }

    // MARK: The old stores

    /// SAVES ALREADY ON PHONES ARE NOT MIGRATED (the plan's part 5, his
    /// word): the first start of this build deletes the old slot model's
    /// stores, `MemoryCards/` with its `meta.json`, and each kept game's
    /// `pending-states` folder and cached `state.dat`, anything owed in them
    /// included. The per-game `CoreSaves/` folders stay: they are what the
    /// cores read. Once.
    static func removeOldStores() {
        let key = "com.mmagtech.RommApp.saveChannelsStoresCleared"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? fm.removeItem(at: support.appendingPathComponent("MemoryCards", isDirectory: true))
        let kept = support.appendingPathComponent("KeptGames", isDirectory: true)
        for game in (try? fm.contentsOfDirectory(at: kept, includingPropertiesForKeys: nil)) ?? [] {
            try? fm.removeItem(at: game.appendingPathComponent("pending-states", isDirectory: true))
            try? fm.removeItem(at: game.appendingPathComponent("state.dat"))
        }
        UserDefaults.standard.set(true, forKey: key)
    }
}
