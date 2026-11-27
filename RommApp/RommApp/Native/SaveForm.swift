import Foundation

/// WHAT EACH CORE'S SAVE IS, AND THE FORM IT TRAVELS IN, the same as
/// CabinetOS's for the same core (frontend/src/savetable.cpp, saveForm,
/// saveFiles; saves.cpp, toOwnForm), so a save made on either app continues
/// on the other. Its own file, apart from GameSaves, because it reads no
/// player and no disk: the lab station runs every core's form and check
/// against it (tools/lab/saves).
///
/// Every extra file a core keeps beside a save travels too, each core read
/// in its pinned source (the step 5 plan, part 3, rule 12):
///   - Game Boy and Game Boy Color (Gambatte): the battery, and its 8-byte
///     clock beside it as one zip of `<game>.srm` and `<game>.rtc`. A clock
///     that only ticked is no new save. RomM's Sigil converts the clock for
///     other apps.
///   - GBA (mGBA): the battery only. At the pinned commit the libretro core
///     keeps no GBA clock file: the cartridge's clock follows the device's
///     own time, as on the TV.
///   - Game Gear (Genesis Plus GX): the battery only.
///   - Neo Geo Pocket Color (Beetle NGP): `<game>.flash`, written as the game
///     closes; its clock reads the device's time.
///   - DS (melonDS): `<game>.sav`. The GBA-slot `.srm` needs a two-cartridge
///     start the phone never makes.
///   - PSP (PPSSPP): every folder under the game's `PSP/SAVEDATA`, one zip,
///     CabinetOS's layout (SaveZip).
///   - Dreamcast VMU (VeMUlator): the game's card, pushed as Flycast's save
///     under `flycast-native`, so the TV takes it as its own.
///   - Game & Watch: no saves and no states (the core has neither).
struct SaveForm: Equatable {
    enum Kind: Equatable {
        /// The core's battery memory (RETRO_MEMORY_SAVE_RAM), read and seated
        /// by the frontend.
        case battery
        /// One file the core writes itself, in the game's save folder, named
        /// after what it was handed with this extension.
        case file(ext: String)
        /// PSP's SAVEDATA folders.
        case folder
    }

    /// The tag this core's saves and states travel under, CabinetOS's for the
    /// same core.
    let tag: String
    /// The core's own name in Sigil's spelling, sent beside the tag so RomM
    /// converts the save for any other app.
    let sigil: String
    let kind: Kind
    /// Gambatte's clock beside the battery.
    let clock: Bool
    /// Sigil names how these emulators' files differ and RomM hands them over
    /// as stored: another app's is used only when this core made it
    /// (SavePick.mayLoad). DS, GBA and Game Gear.
    let sameCoreOnly: Bool
    /// The options Sigil reads where the save lives: Flycast's VMU as the
    /// TV runs it.
    let options: [(key: String, value: String)]
    /// A folder save's place in Sigil's answer, against the phone's root for
    /// the same folder.
    let answerRoot: String

    static func == (a: SaveForm, b: SaveForm) -> Bool {
        a.tag == b.tag && a.sigil == b.sigil && a.kind == b.kind
    }

    /// The form for a core's tag; nil for a core with no saves (Game & Watch)
    /// or one the phone no longer plays.
    static func forTag(_ tag: String) -> SaveForm? {
        switch tag {
        case "gambatte-native":
            return SaveForm(tag: tag, sigil: "gambatte", kind: .battery, clock: true, sameCoreOnly: false,
                            options: [], answerRoot: "")
        case "mgba-native":
            return SaveForm(tag: tag, sigil: "mgba", kind: .battery, clock: false, sameCoreOnly: true,
                            options: [], answerRoot: "")
        case "gpgx-native":
            return SaveForm(tag: tag, sigil: "genesis_plus_gx", kind: .battery, clock: false, sameCoreOnly: true,
                            options: [], answerRoot: "")
        case "ngp-native":
            return SaveForm(tag: tag, sigil: "mednafen_ngp", kind: .file(ext: "flash"), clock: false,
                            sameCoreOnly: false, options: [], answerRoot: "")
        case "melonds-native":
            return SaveForm(tag: tag, sigil: "melonds", kind: .file(ext: "sav"), clock: false, sameCoreOnly: true,
                            options: [], answerRoot: "")
        case "ppsspp-native":
            return SaveForm(tag: tag, sigil: "ppsspp", kind: .folder, clock: false, sameCoreOnly: false,
                            options: [], answerRoot: "PSP/SAVEDATA/")
        case "flycast-native":
            // The VMU card the TV's Flycast writes as `<game>.A1.bin`.
            return SaveForm(tag: tag, sigil: "flycast", kind: .file(ext: "bin"), clock: false, sameCoreOnly: false,
                            options: [("reicast_per_content_vmus", "VMU A1")], answerRoot: "")
        default:
            return nil
        }
    }

    /// The query RomM is asked another app's save with: the core, then each
    /// option as `key:value`.
    var askQuery: [URLQueryItem] {
        [URLQueryItem(name: "core", value: sigil)]
            + options.map { URLQueryItem(name: "option", value: "\($0.key):\($0.value)") }
    }

    // MARK: Names

    /// The name a save goes up under, named after the game as CabinetOS names
    /// it: `<stem>.srm` for a battery, `<stem>.zip` for one with its clock,
    /// `<stem>.<ext>` for a core's file, `<title>.zip` for PSP's folders.
    /// `stem` is SaveRowNames.stem, `title` the game's name.
    func upName(stem: String, title: String, zipped: Bool) -> String {
        switch kind {
        case .battery: return stem + (zipped ? ".zip" : ".srm")
        case .file(let ext): return "\(stem).\(ext)"
        case .folder: return SaveRowNames.sanitisedStem(title) + ".zip"
        }
    }

    /// How a save travels, RomM's word: one file as it is, else a zip of
    /// several files or of a folder.
    func shape(zipped: Bool) -> String {
        switch kind {
        case .folder: return "FOLDER"
        default: return zipped ? "MULTI" : "SINGLE"
        }
    }

    // MARK: A battery and its clock

    /// A battery save as a snapshot holds it: as it is, or zipped with its
    /// clock as `<game>.srm` and `<game>.rtc`. Nil when a zip will not unpack.
    static func batteryParts(_ save: Data) -> (battery: Data, clock: Data?, zipped: Bool)? {
        guard SaveZip.looksLikeZip(save) else { return (save, nil, false) }
        guard let files = SaveZip.entries(of: save) else { return nil }
        let battery = files.last { $0.path.hasSuffix(".srm") }?.data ?? Data()
        let clock = files.last { $0.path.hasSuffix(".rtc") }?.data
        return (battery, clock, true)
    }

    /// The battery with its clock as one zip, the clock beside it only when
    /// there is one.
    static func batteryZip(battery: Data, clock: Data, stem: String) -> Data {
        SaveZip.zip([SaveZip.Entry(path: stem + ".srm", data: battery),
                     SaveZip.Entry(path: stem + ".rtc", data: clock)])
    }

    /// THE SAME SAVE IN TWO LENGTHS (CabinetOS's sameBattery): mGBA's battery
    /// is 128 KiB until the game first touches its save chip and then the
    /// chip's size, and Genesis Plus GX's 64 KiB and then trimmed. The
    /// shorter one's missing end is blank (0xFF), as Sigil counts it.
    static func sameBattery(_ a: Data, _ b: Data) -> Bool {
        let (shorter, longer) = a.count <= b.count ? (a, b) : (b, a)
        return longer.prefix(shorter.count) == shorter && longer.dropFirst(shorter.count).allSatisfy { $0 == 0xFF }
    }

    /// A CORE'S BATTERY AS A GAME STARTS IS THE MOST IT READS (CabinetOS's
    /// coreReadsBattery): another emulator's battery no longer than it, the
    /// rest left blank.
    static func coreReadsBattery(_ bytes: Int, coreBytes: Int) -> Bool {
        bytes > 0 && bytes <= coreBytes
    }

    // MARK: What holds a save

    /// A save with something in it: any byte that is neither 0x00 nor 0xFF.
    /// What an untouched battery or file is not (CabinetOS's holdsASave,
    /// Untouched::Blank).
    static func holdsASave(_ d: Data) -> Bool {
        d.contains { $0 != 0x00 && $0 != 0xFF }
    }

    /// A VMU card holding a game file or a data file: 128 KB, the root
    /// block's sixteen 0x55 bytes, an entry in its directory (CabinetOS's
    /// vmuHoldsAFile).
    static func vmuHoldsAFile(_ d: Data) -> Bool {
        let block = 512
        guard d.count == 256 * block else { return false }
        let b = [UInt8](d)
        let root = 255 * block
        guard (0..<16).allSatisfy({ b[root + $0] == 0x55 }) else { return false }
        for blk in 241...253 {
            for e in 0..<16 where b[blk * block + e * 32] == 0x33 || b[blk * block + e * 32] == 0xCC {
                return true
            }
        }
        return false
    }

    /// Whether the bytes of this core's one file are a save it reads, with
    /// why not: CabinetOS's checks for the same files.
    func fileFits(_ d: Data) -> String? {
        guard case .file(let ext) = kind else { return nil }
        switch ext {
        case "flash":
            // NeoPop's flash file starts with its id, 0x0053 (FlashFileHeader).
            if !(d.count >= 2 && d[d.startIndex] == 0x53 && d[d.startIndex + 1] == 0x00) {
                return "it does not carry its format's mark"
            }
        case "sav":
            // A cartridge's memory is a power of two, 512 bytes to 32 MB.
            // DeSmuME's is 122 bytes longer (Sigil's nds page).
            if !(d.count >= 512 && d.count <= 32 << 20 && d.count & (d.count - 1) == 0) {
                return "\(d.count) bytes is no size this emulator's file has"
            }
        case "bin":
            return SaveForm.vmuHoldsAFile(d) ? nil : "it is no VMU card with a file on it"
        default:
            break
        }
        return SaveForm.holdsASave(d) ? nil : "it holds no save"
    }

    // MARK: Another emulator's save, in the phone's form

    /// THE ANSWER RomM GAVE FOR ANOTHER EMULATOR'S SAVE, IN THE PHONE'S FORM,
    /// CHECKED (CabinetOS's toOwnForm, for the phone's kinds): the bytes the
    /// phone uses, or why not. `plain` is RomM saying it converts no save of
    /// this system, so it was asked as stored. `madeBy` and `madeByCore` name
    /// the emulator that made it. A battery's length is the loaded core's to
    /// check (coreReadsBattery).
    func ownForm(of answer: SaveAnswer, plain: Bool, madeBy: String, madeByCore: String,
                 stem: String) -> Result<Data, SaveFormRefusal> {
        let zipped = SaveZip.looksLikeZip(answer.bytes)
        let asStored = plain || (answer.savePath.isEmpty && !zipped)
        if asStored, sameCoreOnly || kind == .folder,
           !SavePick.mayLoad(emulator: madeBy, core: madeByCore, tag: tag, sigil: sigil) {
            return .failure(SaveFormRefusal(
                "RomM hands it over as stored, and \(madeBy.isEmpty ? "another" : madeBy) made it, not this emulator"))
        }
        var sent: [SaveZip.Entry]
        if zipped {
            guard let files = SaveZip.entries(of: answer.bytes) else {
                return .failure(SaveFormRefusal("RomM's answer would not unpack"))
            }
            sent = files
        } else if !answer.bytes.isEmpty {
            sent = [SaveZip.Entry(path: answer.savePath, data: answer.bytes)]
        } else {
            sent = []
        }
        guard !sent.isEmpty else { return .failure(SaveFormRefusal("RomM's answer is empty")) }
        func base(_ p: String) -> String { String(p.split(separator: "/", omittingEmptySubsequences: false).last ?? "") }

        switch kind {
        case .folder:
            // Each file under the phone's root for it, each in a save folder
            // holding a PARAM.SFO that starts with `\0PSF`.
            var mine: [SaveZip.Entry] = []
            for f in sent {
                var rel = f.path
                if !asStored, !answerRoot.isEmpty {
                    guard rel.hasPrefix(answerRoot), rel.count > answerRoot.count else {
                        return .failure(SaveFormRefusal("\(f.path) is outside where this emulator keeps its saves"))
                    }
                    rel = String(rel.dropFirst(answerRoot.count))
                }
                mine.append(SaveZip.Entry(path: rel, data: f.data))
            }
            for f in mine {
                guard let slash = f.path.firstIndex(of: "/"), slash != f.path.startIndex else {
                    return .failure(SaveFormRefusal("\(f.path) is in no save folder"))
                }
                let top = String(f.path[..<slash])
                let sfo = mine.first { $0.path == top + "/PARAM.SFO" }
                guard let sfo, sfo.data.count >= 4, sfo.data.prefix(4) == Data([0x00, 0x50, 0x53, 0x46]) else {
                    return .failure(SaveFormRefusal("\(top) holds no PARAM.SFO with its mark"))
                }
            }
            return .success(SaveZip.zip(mine))

        case .battery:
            if asStored, zipped { return .failure(SaveFormRefusal("it is a zip, and RomM converted nothing")) }
            var battery: SaveZip.Entry? = sent.count == 1 ? sent[0] : nil
            var clockFile: SaveZip.Entry?
            for f in sent where sent.count > 1 {
                if f.path.hasSuffix(".srm") { battery = f }
                if f.path.hasSuffix(".rtc") { clockFile = f }
            }
            guard let battery else { return .failure(SaveFormRefusal("RomM's answer holds no battery save")) }
            guard SaveForm.holdsASave(battery.data) else { return .failure(SaveFormRefusal("it holds no save")) }
            guard clock, let clockFile, !clockFile.data.isEmpty else { return .success(battery.data) }
            return .success(SaveForm.batteryZip(battery: battery.data, clock: clockFile.data, stem: stem))

        case .file(let ext):
            // The one file, found by the end of its name; a file handed over
            // as stored is it.
            let found = asStored && !zipped ? sent.first : sent.first { base($0.path).hasSuffix("." + ext) }
            guard let found else { return .failure(SaveFormRefusal("nothing in RomM's answer is a file this emulator reads")) }
            if let why = fileFits(found.data) { return .failure(SaveFormRefusal("\(base(found.path)): \(why)")) }
            return .success(found.data)
        }
    }

    /// RomM's answer, a refusal: the save holds none of this game's saves
    /// (Sigil's NOT_FOUND, sent as 422), which is no save of the game.
    static func holdsNoneOfTheGame(_ answer: SaveAnswer) -> Bool {
        answer.status == 422 && answer.error == "NOT_FOUND"
    }
}

/// Why another emulator's save cannot be used, for the log.
struct SaveFormRefusal: Error, Equatable {
    let why: String
    init(_ why: String) { self.why = why }
}
