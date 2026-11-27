import Foundation

/// WHICH SAVE A START CONTINUES FROM: the one rule, and whether the start
/// says "Continuing from another device". Port of CabinetOS's `savepick`
/// (frontend/src/savepick.h), so the phone and the TV pick alike. A start,
/// the game screen's save line and Resume all go by it (GameSaves). It asks
/// nothing and reads no disk: what it is told is Facts, so its table of cases
/// runs in the lab station with no server (tools/lab/saves).
///
/// THE RULE. The game starts from the newest save RomM holds for this person
/// that the phone can use, in any of their channels, by when the save was
/// made, not when it was uploaded. Nothing is asked: there is no save picker.
/// A save the phone has not sent yet is sent first, when RomM answers
/// (SavePush.settleBeforeStart), and then weighed like any other; one it could
/// not send still wins, whatever RomM holds. When the newest save on RomM is
/// one the phone cannot use, it starts from the newest it can, or its own,
/// and the start says so (`couldNotUseNewest`), so what it saves is kept
/// beside the newer one. RomM's rows from before channels are not read: every
/// CabinetOS console writes channels now, and saves from before may be lost
/// (the step 5 plan, part 3).
///
/// AND NEVER FROM A SAVE MADE BEFORE ONE OF THE PHONE'S OWN THAT RomM KEPT
/// BESIDE A CHANNEL'S CURRENT. A push RomM keeps as a branch is on RomM but
/// is no channel's current, so nothing listed shows it: without this the
/// phone would start next from an older save of its own over the newer one
/// in its own folder. The note of the snapshot held says when it was made.
///
/// WHICH SAVES IT CAN USE. The ones a CabinetOS console or a phone made,
/// pushed under the tag this core's saves travel under (ownForm), are used as
/// stored. ANOTHER EMULATOR'S SAVE IS ASKED OF RomM IN THE PHONE'S OWN FORM
/// AND CHECKED: when the newest is one, the pick names it (`other`) and the
/// start asks for it (GameSaves); one that cannot be used leaves the start to
/// the newest the phone can use, which says so. ONE THAT HOLDS NONE OF THIS
/// GAME'S SAVES IS NO SAVE OF THE GAME (RomM answers NOT_FOUND, as RomM's web
/// player's blank card does): the start goes on as if it were not there and
/// says nothing. ANOTHER APP'S SAVE IN NO CHANNEL IS WEIGHED THE SAME WAY
/// (otherRows): a row another emulator made, from an app that does not use
/// channels or uploaded by hand on RomM's website, and one RomM kept out of
/// a channel's snapshots.
///
/// THE NOTICE IS NEVER A GUESS. "Continuing from another device" shows only
/// when the phone's own note or RomM's says the save was made somewhere else:
///   - The phone holds a note of this game: when the save's content hash is
///     none the phone has had. By the hash and not the snapshot's id,
///     because RomM's website restores an older snapshot as a new one with
///     the same save inside.
///   - No note (a reinstall, or the game's first start from a channel): RomM
///     says which device made the snapshot and which hold it. The notice
///     shows only when a device that is no Cabinet Go made it and no Cabinet
///     Go holds it. A reinstall pairs as a new device, so the phone's own
///     old device cannot be told from another phone's, and gets none.
/// And never when the save is byte for byte what the phone already had.
enum SavePick {
    /// How many of the hashes the phone has had are kept. RomM keeps ten
    /// snapshots a channel behind the current, and the pinned ones for good;
    /// this is far past them.
    static let hashesKept = 256

    /// What a start knows before it picks.
    struct Facts {
        /// The tag this core's saves travel under.
        var tag = ""
        /// RomM's channels for this person and game, as asked or as last
        /// seen; none when RomM has none or they are not known.
        var channels: [SaveChannel] = []
        /// RomM's saves outside channels' snapshots that another emulator
        /// made (otherRows).
        var otherRows: [RommAsset] = []
        /// The phone still owes RomM a save of the game and could not send it
        /// before the start: its own copy stands.
        var owed = false
        /// The snapshot the phone holds of the game; nil for none.
        var held: SaveMirror.Held?
    }

    struct Pick {
        enum From: Equatable {
            /// Nothing from RomM: what is on the phone stands.
            case own
            /// `channel`'s current snapshot.
            case channel
            /// `row`, another app's save in no channel.
            case otherRow
        }
        var from = From.own
        var channel = SaveChannel()
        var row = RommAsset()
        /// The save named is another emulator's, to be asked of RomM in the
        /// phone's form and checked before it is used.
        var other = false
        /// The notes say the save was made somewhere else.
        var madeElsewhere = false
        /// The newest save on RomM is one the phone cannot use.
        var couldNotUseNewest = false
        /// Why, for the log.
        var why = ""
    }

    /// What a start does with another emulator's save when it is the newest.
    enum Others {
        /// Named (`other`), to be asked of RomM in the phone's form.
        case ask
        /// Never named: the start after one could not be used, which says
        /// so, or a start with RomM away.
        case unusable
        /// Never named: the start after RomM said it holds none of this
        /// game's saves, which says nothing.
        case holdsNone
    }

    static func pick(_ f: Facts, others: Others = .ask) -> Pick {
        var p = Pick()
        // The newest save in a channel the phone uses as stored, and the
        // newest another emulator made; and the newest of another app's in
        // no channel.
        var usable: SaveChannel?
        var otherCh: SaveChannel?
        for c in f.channels where holdsSave(c) {
            if ownForm(c.current, tag: f.tag) {
                if usable.map({ madeAt(c) > madeAt($0) }) ?? true { usable = c }
            } else if otherCh.map({ madeAt(c) > madeAt($0) }) ?? true {
                otherCh = c
            }
        }
        var otherRow: RommAsset?
        for a in f.otherRows where otherRow.map({ isoMicros(rowMadeAt(a)) > isoMicros(rowMadeAt($0)) }) ?? true {
            otherRow = a
        }
        let none = Int64.min
        let ownNewest = usable.map(madeAt) ?? none
        let channelAt = otherCh.map(madeAt) ?? none
        let rowAt = otherRow.map { isoMicros(rowMadeAt($0)) } ?? none
        // ANOTHER EMULATOR'S SAVE IS THE NEWEST: a channel's on a tie with a
        // row, which is the row copied in; the phone's own form on a tie
        // with it.
        let otherNewest = max(channelAt, rowAt) != none && max(channelAt, rowAt) > ownNewest
        let otherInChannel = otherNewest && channelAt >= rowAt
        let otherWords: String
        if !otherNewest {
            otherWords = ""
        } else if otherInChannel, let c = otherCh {
            otherWords = "snapshot \(c.current.id) (\(c.current.save?.emulator ?? ""))"
        } else if let r = otherRow {
            otherWords = "save \(r.id) (\(r.emulator)" + (r.channelId.isEmpty ? "), in no channel" : "), kept out of its channel")
        } else {
            otherWords = ""
        }
        if f.owed {
            p.why = "a save of this game has not reached RomM yet; the phone's stands"
            return p
        }
        // THE NEWEST IS THE SNAPSHOT THE PHONE HOLDS, filed under another
        // emulator's name: RomM files a snapshot's save under the first of the
        // person's rows with those bytes, which can be another app's, and a
        // start from another app's save was converted on the way in. Either
        // way the phone's own copy is that save in its own form, or what it
        // played on from it.
        if otherNewest, otherInChannel, let c = otherCh, let held = f.held, !held.beside,
           c.id == held.channelId, c.current.id == held.snapshotId {
            p.why = otherWords + " is the newest save on RomM and the snapshot the phone holds: its own copy stands"
            return p
        }
        // A save made before one of the phone's own that RomM kept beside a
        // channel's current is never started from.
        let ownAt: Int64 = f.held.map { $0.beside ? $0.madeAt * 1_000_000 : 0 } ?? 0
        let older = "; RomM kept the phone's own save beside a channel's current, and the newest it could use was made before it"
        if others == .ask, otherNewest {
            if max(channelAt, rowAt) < ownAt {
                p.why = "the phone's own save stands" + older
                return p
            }
            p.other = true
            if otherInChannel, let c = otherCh {
                p.from = .channel
                p.channel = c
                p.madeElsewhere = notesSayElsewhere(f, c.current)
            } else if let r = otherRow {
                p.from = .otherRow
                p.row = r
                // Never a Cabinet app's: each files its saves under the tag.
                p.madeElsewhere = true
            }
            p.why = otherWords + " is the newest save on RomM, another emulator's: asked in the phone's own form"
            return p
        }
        // Left out: the newest was another emulator's and could not be used,
        // or held none of this game's saves, which goes unsaid.
        p.couldNotUseNewest = otherNewest && others != .holdsNone
        let unusable = !otherNewest ? ""
            : others == .holdsNone ? "; the newest on RomM, \(otherWords), holds none of this game's saves"
            : "; the newest on RomM, \(otherWords), could not be used"
        if let c = usable {
            if madeAt(c) < ownAt {
                p.why = "the phone's own save stands" + older + unusable
                return p
            }
            p.from = .channel
            p.channel = c
            p.madeElsewhere = notesSayElsewhere(f, c.current)
            p.why = "snapshot \(c.current.id) in channel \"\(c.label)\"" + (c.hardcore ? " (hardcore)" : "")
                + " is the newest save on RomM the phone can use" + unusable
            return p
        }
        p.why = "RomM holds no save of this game the phone can use" + unusable
        return p
    }

    /// Whether a start that put the pick's save in place says "Continuing
    /// from another device": only for a channel's save the notes say was made
    /// elsewhere, or another app's save in no channel, and never when it was
    /// what the phone already had.
    static func continuingElsewhere(_ pick: Pick, sameAsOwn: Bool) -> Bool {
        (pick.from == .channel || pick.from == .otherRow) && pick.madeElsewhere && !sameAsOwn
    }

    /// The saves of `rows` outside channels' snapshots that another emulator
    /// made (not under `tag`): in no channel, or KEPT OUT OF ONE, a save an
    /// app filed the old way under a slot, which RomM put in the slot's
    /// channel but did not make its current (RomM's `hold_legacy_upload`).
    /// Such a row was made after its channel's current and is not that
    /// current's save.
    static func otherRows(_ rows: [RommAsset], tag: String, channels: [SaveChannel]) -> [RommAsset] {
        rows.filter { a in
            if a.emulator == tag { return false }
            if a.channelId.isEmpty { return true }
            if a.slot.isEmpty { return false }   // a snapshot's: weighed through its channel
            return channels.contains { c in
                c.id == a.channelId && c.currentId != 0 && c.current.save?.id != a.id
                    && isoMicros(rowMadeAt(a)) > isoMicros(c.current.createdAt)
            }
        }
    }

    /// RomM'S OWN RULE FOR WHO MAY LOAD A SAVE AS STORED (`may_load` in its
    /// handler/snapshots/legacy.py): the save's core against the phone's
    /// (`sigil`), else, when it names none, its emulator against the phone's
    /// names for the core (`tag` or `sigil`), else yes.
    static func mayLoad(emulator: String, core: String, tag: String, sigil: String) -> Bool {
        if !core.isEmpty, !sigil.isEmpty { return core.lowercased() == sigil.lowercased() }
        if !emulator.isEmpty, !tag.isEmpty || !sigil.isEmpty {
            return emulator.lowercased() == tag.lowercased() || emulator.lowercased() == sigil.lowercased()
        }
        return true
    }

    /// The note of the snapshot the phone holds, after it took `taken` in
    /// `channelId`, at a start or as RomM's answer to a push: `before` with
    /// the snapshot, and its save's hash added to the hashes the phone has
    /// had. Its save is dated by RomM's time for it, and it is no longer
    /// beside a current; a push says otherwise itself (SavePush).
    static func heldAfter(_ before: SaveMirror.Held?, channelId: String, taken: Snapshot, now: Int64) -> SaveMirror.Held {
        var h = before ?? SaveMirror.Held()
        func had(_ hash: String) {
            guard !hash.isEmpty else { return }
            h.hashesHad.removeAll { $0 == hash }
            h.hashesHad.append(hash)
        }
        had(before?.saveHash ?? "")
        h.channelId = channelId
        h.snapshotId = taken.id
        h.digest = taken.digest
        h.saveHash = taken.save?.contentHash ?? ""
        h.at = now
        h.madeAt = isoMicros(savedAt(taken)) / 1_000_000
        h.beside = false
        had(h.saveHash)
        if h.hashesHad.count > hashesKept { h.hashesHad.removeFirst(h.hashesHad.count - hashesKept) }
        return h
    }

    /// When a save a start would continue from was stored, as RomM wrote it;
    /// empty for a start from the phone's own.
    static func pickedAt(_ pick: Pick) -> String {
        switch pick.from {
        case .channel: return savedAt(pick.channel.current)
        case .otherRow: return rowMadeAt(pick.row)
        case .own: return ""
        }
    }

    /// WHEN A SNAPSHOT'S SAVE WAS MADE, as RomM can say it: when the save
    /// first reached RomM, else when the snapshot did. A snapshot that
    /// changed only its states carries the save of the one before it.
    static func savedAt(_ s: Snapshot) -> String { s.saveAt.isEmpty ? s.createdAt : s.saveAt }

    /// Each channel's current dated by its save's own row in `rows`, the
    /// game's saves as RomM listed them.
    static func dateSaves(_ channels: inout [SaveChannel], rows: [RommAsset]) {
        for i in channels.indices {
            guard channels[i].currentId != 0, let save = channels[i].current.save else { continue }
            if let row = rows.first(where: { $0.id == save.id && !$0.createdAt.isEmpty }) {
                channels[i].current.saveAt = row.createdAt
            }
        }
    }

    /// WHEN ANOTHER APP'S SAVE OUTSIDE CHANNELS' SNAPSHOTS WAS MADE. A row in
    /// no channel: its `updated_at`, which an old-style upload over that row
    /// moves. A row RomM kept in a channel with no snapshot: its `created_at`,
    /// as a channel's save is dated. Never its `updated_at` there: RomM moves
    /// it when a push prunes a snapshot that held the row.
    static func rowMadeAt(_ a: RommAsset) -> String {
        a.channelId.isEmpty || a.createdAt.isEmpty ? a.updatedAt : a.createdAt
    }

    /// A SNAPSHOT'S SAVE IS IN THE FORM `tag` NAMES when the device that
    /// pushed it named that emulator, or when the row RomM filed its save
    /// under carries that name. Never by the row's name alone.
    static func ownForm(_ s: Snapshot, tag: String) -> Bool {
        !tag.isEmpty && (s.emulator == tag || s.save?.emulator == tag)
    }

    /// RomM's times to the microsecond, with or without a fraction, as
    /// CabinetOS reads them (timewords.cpp, isoMicros): RomM writes UTC. 0
    /// for anything that is not one.
    static func isoMicros(_ iso: String) -> Int64 {
        let u = Array(iso.utf8)
        var at = 0
        func number(_ maxDigits: Int) -> Int? {
            var n = 0, digits = 0
            while at < u.count, digits < maxDigits, u[at] >= 0x30, u[at] <= 0x39 {
                n = n * 10 + Int(u[at] - 0x30)
                at += 1
                digits += 1
            }
            return digits > 0 ? n : nil
        }
        func skip(_ c: UInt8) -> Bool {
            guard at < u.count, u[at] == c else { return false }
            at += 1
            return true
        }
        guard let y = number(4), skip(0x2D), let mo = number(2), skip(0x2D), let d = number(2), skip(0x54),
              let h = number(2), skip(0x3A), let mi = number(2), skip(0x3A), let s = number(2)
        else { return 0 }
        var c = DateComponents()
        c.year = y; c.month = mo; c.day = d; c.hour = h; c.minute = mi; c.second = s
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        guard let date = calendar.date(from: c) else { return 0 }
        var micros = Int64(date.timeIntervalSince1970) * 1_000_000
        if skip(0x2E) {
            var unit: Int64 = 100_000
            while at < u.count, u[at] >= 0x30, u[at] <= 0x39, unit > 0 {
                micros += Int64(u[at] - 0x30) * unit
                unit /= 10
                at += 1
            }
        }
        return micros
    }

    /// A time the way RomM writes one, so the two sort and read alike.
    static func isoUTC(seconds: Int64) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'+00:00'"
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(seconds)))
    }

    // MARK: Private

    private static func madeAt(_ c: SaveChannel) -> Int64 { isoMicros(savedAt(c.current)) }

    /// A channel whose current holds a save with something in it. An empty
    /// channel, or a snapshot of states alone, is no save to start from.
    private static func holdsSave(_ c: SaveChannel) -> Bool {
        c.currentId != 0 && (c.current.save?.sizeBytes ?? 0) > 0
    }

    /// The head of this file: the phone's own note first, RomM's when it has
    /// none.
    private static func notesSayElsewhere(_ f: Facts, _ s: Snapshot) -> Bool {
        if let held = f.held {
            let hash = s.save?.contentHash ?? ""
            if hash.isEmpty || hash == held.saveHash { return false }
            return !held.hashesHad.contains(hash)
        }
        if s.heldBy.contains(where: { $0.client == RommSnapshots.phoneClient }) { return false }
        return s.deviceOwn && !s.deviceClient.isEmpty && s.deviceClient != RommSnapshots.phoneClient
    }
}
