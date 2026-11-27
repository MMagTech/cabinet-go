// The saves station: the app's real save files (RommSnapshots, SaveZip,
// SaveHash, SaveMirror, SavePick, SavePush, SaveForm) run headless in the
// simulator against CabinetOS's own case tables for the same rules
// (frontend/src/savepick.cpp's table, savepush_test.cpp, romm_snapshots_test.cpp),
// with RomM's answers as the write-test RomM gave them (fixtures/). No
// server, no core, no write anywhere but a scratch folder. Exit 0 when every
// case passes.

import Foundation

setvbuf(stdout, nil, _IONBF, 0)
let fixtures = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "fixtures")
var failures = 0
var passes = 0
func check(_ ok: Bool, _ what: String) {
    print("  \(ok ? "ok  " : "FAIL")  \(what)")
    if ok { passes += 1 } else { failures += 1 }
}
func section(_ title: String) { print("\n" + title) }
func fixture(_ name: String) -> Data { (try? Data(contentsOf: fixtures.appendingPathComponent(name))) ?? Data() }

/// The recorder's bytes, CabinetOS's bytesOf: byte i of a run is
/// (i * seed + seed / 3) & 0xFF.
func bytesOf(_ seed: Int, _ n: Int) -> Data {
    Data((0..<n).map { UInt8(truncatingIfNeeded: ($0 * seed + seed / 3) & 0xFF) })
}

SavePush.log = { _ in }

// MARK: - RomM's content hash

section("RomM's content hash")
check(SaveHash.content(Data()) == "d41d8cd98f00b204e9800998ecf8427e"
      && SaveHash.content(Data("abc".utf8)) == "900150983cd24fb0d6963f7d28e17f72",
      "the MD5 of the bytes (RFC 1321's own examples)")
check(SaveHash.content(bytesOf(7, 8192)) == "520861061656bf5a64eaadc710f5512f"
      && SaveHash.content(bytesOf(11, 8192)) == "a6e8e336ecc7961005b883dfcb728461",
      "a save's, as RomM hashed it")
check(SaveHash.content(bytesOf(13, 3000)) == "088352c0073bf7e95545460e8ca2bec8", "a state's")
check(SaveHash.content(fixture("folder-save.zip")) == "f6c63429ff085394a3077526b010ceea",
      "a zip Python wrote, deflated: each file under its name, sorted, a folder and a name outside ASCII among them")
let phoneZip = SaveZip.zip([SaveZip.Entry(path: "SAVEDATA/DATA.BIN", data: bytesOf(23, 5000)),
                            SaveZip.Entry(path: "SAVEDATA/PARAM.SFO", data: bytesOf(29, 400))])
check(SaveHash.content(phoneZip) == "5c13ff31dfd33f87d3d8caa371c458bb",
      "a zip the phone writes (SaveZip) hashes by RomM's rule, as the TV's does")

/// A stored zip with names as raw bytes, marked UTF-8 or not, as libarchive
/// writes them.
func rawZip(_ files: [(name: [UInt8], utf8: Bool, data: Data)]) -> Data {
    func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
    func le32(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)] }
    var zip: [UInt8] = []
    var central: [UInt8] = []
    for f in files {
        let flag = f.utf8 ? 0x0800 : 0
        var crc: UInt32 = 0xFFFF_FFFF
        for b in f.data {
            crc ^= UInt32(b)
            for _ in 0..<8 { crc = crc & 1 != 0 ? 0xEDB8_8320 ^ (crc >> 1) : crc >> 1 }
        }
        crc ^= 0xFFFF_FFFF
        let offset = zip.count
        zip += le32(0x0403_4B50) + le16(20) + le16(flag) + le16(0) + le16(0) + le16(0x21)
            + le32(Int(crc)) + le32(f.data.count) + le32(f.data.count) + le16(f.name.count) + le16(0) + f.name + [UInt8](f.data)
        central += le32(0x0201_4B50) + le16(20) + le16(20) + le16(flag) + le16(0) + le16(0) + le16(0x21)
            + le32(Int(crc)) + le32(f.data.count) + le32(f.data.count) + le16(f.name.count) + le16(0) + le16(0)
            + le16(0) + le16(0) + le32(0) + le32(offset) + f.name
    }
    let at = zip.count
    zip += central + le32(0x0605_4B50) + le16(0) + le16(0) + le16(files.count) + le16(files.count)
        + le32(central.count) + le32(at) + le16(0)
    return Data(zip)
}
var every: [UInt8] = Array("hi".utf8)
every += (0x80...0xFF).map { UInt8($0) }
every += Array(".bin".utf8)
let unmarked = rawZip([
    ([0x82, 0xA0, 0x82, 0xA2] + Array(".gci".utf8), false, bytesOf(31, 700)),
    (every, false, bytesOf(37, 300)),
    ([0xB0] + Array(".sav".utf8), false, bytesOf(41, 64)),
    ([0xE0] + Array(".sav".utf8), false, bytesOf(43, 64)),
    (Array("caf\u{e9}.bin".utf8), true, bytesOf(47, 200)),
    (Array("MemoryCard/".utf8) + [0x93, 0xFA, 0x96, 0x7B] + Array(".gci".utf8), false, bytesOf(53, 128)),
    (Array("plain.bin".utf8), false, bytesOf(59, 100)),
])
check(SaveHash.content(unmarked) == "97ab67b798fe4a9821eb13dbbe2ec5f7",
      "names not marked UTF-8 read as CP437 and sorted as that text: RomM's own value for this zip")
let notZip = Data([0x50, 0x4B, 3, 4] + Array("not a zip".utf8))
check(SaveHash.content(notZip) == "b293f4d7bb3247fa4e93cd269ee26b9a", "bytes that only begin like a zip are hashed as bytes")

section("Zips, both ways")
let back = SaveZip.entries(of: phoneZip)
check(back?.map(\.path) == ["SAVEDATA/DATA.BIN", "SAVEDATA/PARAM.SFO"] && back?[0].data == bytesOf(23, 5000),
      "the phone's zip reads back as written")
let python = SaveZip.entries(of: fixture("folder-save.zip"))
check(python?.count == 3 && python?.contains { $0.path == "Ma\u{ef}s/ic\u{f4}ne.png" } == true
      && python?.allSatisfy { !$0.path.hasSuffix("/") } == true,
      "a deflated zip from Python: three files inflated, the folder left out, a UTF-8 name read as one")
check(SaveZip.entries(of: notZip) == nil, "bytes that are no zip read as none")

// MARK: - RomM's words

section("What the heartbeat says")
let beat55 = try? JSONDecoder().decode(Heartbeat.self, from: fixture("heartbeat-5.5.0-alpha.2.json"))
let beat54 = try? JSONDecoder().decode(Heartbeat.self, from: fixture("heartbeat-5.4.1.json"))
let beatNull = try? JSONDecoder().decode(Heartbeat.self, from: Data(#"{"SYSTEM":{"VERSION":"5.5.0"},"SAVE_SYNC":null}"#.utf8))
check(beat55?.system.version == "5.5.0-alpha.2" && beat55?.saveSync != nil, "RomM 5.5's says it has save channels")
check(beat54?.system.version == "5.4.1" && beat54?.saveSync == nil, "RomM 5.4.1's says it has none")
check(beatNull != nil && beatNull?.saveSync == nil, "a SAVE_SYNC that is not a block is none")

section("A game's channels")
check(RommSnapshots.readChannels(fixture("channels-empty.json"))?.isEmpty == true, "none is an empty list")
let channels = RommSnapshots.readChannels(fixture("channels.json")) ?? []
check(channels.count == 3, "three, read whole")
let def = channels.first { $0.label == "default" }
check(def?.hardcore == false && def?.romId == 9 && def?.romFileId == 8 && def?.snapshotCount == 4
      && def?.currentId == 122 && def?.current.id == 122, "RomM's \"default\": its file, its four snapshots and its current")
check(def?.current.save?.contentHash == SaveHash.content(bytesOf(11, 8192)) && def?.current.save?.shape == "SINGLE"
      && def?.current.save?.emulator == "snes9x-native" && def?.current.save?.core == "snes9x"
      && def?.current.emulator == "snes9x-native", "its current's save, by hash, with the names it was pushed with")
check(def?.current.states.count == 1 && def?.current.states.first?.core == "snes9x-native"
      && def?.current.states.first?.slot == "1" && def?.current.states.first?.file.picturePath.isEmpty == false,
      "and its state, with its picture")
check(def?.current.deviceOwn == true && def?.current.deviceClient == "cabinetos" && def?.current.heldBy.isEmpty == true,
      "pushed from this person's own device, which no longer holds it")
let hard = channels.first { $0.label == "hardcore test" }
check(hard?.hardcore == true && hard?.current.hardcore == true && hard?.current.heldBy.first?.client == "cabinetos",
      "a hardcore channel says so")
check(channels.first { $0.label == "zip test" }?.current.save?.shape == "FOLDER", "a zip travels as a FOLDER")
check(RommSnapshots.readChannels(Data(#"{"detail":"Not found"}"#.utf8)) == nil, "an answer that is not a list is refused")
let again = RommSnapshots.readChannels(RommSnapshots.channelsJSON(channels))
check(again == channels, "the phone's copy of them reads back as they came (SaveMirror)")

section("What RomM answers a push")
var a = RommSnapshots.readPushAnswer(status: 400, body: fixture("push-400-missing.json"))
check(a.kind == .bytesMissing && a.missing == ["save"], "400: the bytes it lacks, by part")
a = RommSnapshots.readPushAnswer(status: 201, body: fixture("push-201-made.json"))
check(a.kind == .made && a.snapshot.id == 121 && a.snapshot.kind == "channel" && a.snapshot.parentId == 0
      && a.snapshot.save?.contentHash == SaveHash.content(bytesOf(7, 8192)) && !a.snapshot.channelId.isEmpty,
      "201: made, the channel's new current")
a = RommSnapshots.readPushAnswer(status: 200, body: fixture("push-200-unchanged.json"))
check(a.kind == .unchanged && a.snapshot.id == 121, "200: unchanged, the current it already was")
a = RommSnapshots.readPushAnswer(status: 201, body: fixture("push-201-made-with-state.json"))
check(a.kind == .made && a.snapshot.id == 122 && a.snapshot.parentId == 121 && a.snapshot.states.count == 1,
      "201 for a save with a state, made from the one before")
a = RommSnapshots.readPushAnswer(status: 409, body: fixture("push-409-moved.json"))
check(a.kind == .movedOn && a.snapshot.id == 123 && a.snapshot.kind == "branch" && a.hasCurrent
      && a.current.id == 122 && !a.fromOlder, "409, moved on: kept as a branch, with the current it missed")
a = RommSnapshots.readPushAnswer(status: 409, body: fixture("push-409-moved-from-older.json"))
check(a.kind == .movedOn && a.snapshot.id == 124 && a.current.id == 122 && a.fromOlder,
      "409, moved on from an older snapshot than the one expected")
a = RommSnapshots.readPushAnswer(status: 201, body: fixture("push-201-made-zip.json"))
check(a.kind == .made && a.snapshot.save?.shape == "FOLDER"
      && a.snapshot.save?.contentHash == SaveHash.content(fixture("folder-save.zip")), "201 for a zip, which RomM hashed as the phone does")
a = RommSnapshots.readPushAnswer(status: 201, body: fixture("push-201-made-hardcore.json"))
check(a.kind == .made && a.snapshot.hardcore, "201 for a hardcore save")
a = RommSnapshots.readPushAnswer(status: 409, body: fixture("push-409-hardcore.json"))
check(a.kind == .hardcoreChannel, "409: a softcore save refused over a hardcore current")
a = RommSnapshots.readPushAnswer(status: 422, body: fixture("push-422-wrong-hash.json"))
check(a.kind == .refused && a.status == 422 && a.unhashed == "save", "422: a hash the bytes do not match, naming the part")
a = RommSnapshots.readPushAnswer(status: 422, body: Data(#"{"detail":{"manifest":"state:gambatte-native:1 does not hash to the manifest's value"}}"#.utf8))
check(a.kind == .refused && a.unhashed == "state:gambatte-native:1", "and a state's, by its core and slot")
a = RommSnapshots.readPushAnswer(status: 404, body: fixture("push-404-no-file.json"))
check(a.kind == .refused && a.status == 404 && a.unhashed.isEmpty, "404: a file RomM does not have")
a = RommSnapshots.readPushAnswer(status: 201, body: Data("<html>proxy</html>".utf8))
check(a.kind == .refused && a.snapshot.id == 0, "a 201 that is not a snapshot is not taken for one")
a = RommSnapshots.readPushAnswer(status: 409, body: Data("{}".utf8))
check(a.kind == .refused, "a 409 RomM never sends is refused")

section("The manifest a push sends")
func manifest(_ p: SnapshotPush) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: RommSnapshots.manifest(p))) as? [String: Any] ?? [:]
}
var first = SnapshotPush()
first.romFileId = 8
first.label = "default"
first.hasSave = true
first.save.hash = SaveHash.content(bytesOf(7, 8192))
first.emulator = "gambatte-native"
first.core = "gambatte"
let m1 = manifest(first)
check(m1["rom_file_id"] as? Int == 8 && m1["label"] as? String == "default" && m1["channel_id"] == nil
      && m1["parent_snapshot_id"] == nil, "a new channel: its file and its name, no id and no parent")
check(m1["expected_current_id"] is NSNull, "an empty channel expected, said as null and never left out")
let save1 = m1["save"] as? [String: Any]
check(save1?["hash"] as? String == "520861061656bf5a64eaadc710f5512f" && save1?["shape"] as? String == "SINGLE"
      && save1?["format"] as? String == "native" && m1["emulator"] as? String == "gambatte-native"
      && m1["core"] as? String == "gambatte", "the save by hash, shape and format, with the emulator's and the core's names")
var next = SnapshotPush()
next.romFileId = 8
next.channelId = "01a1f0d3-b303-75e3-86f9-d56256d5e32f"
next.expectedCurrentId = 122
next.parentId = 121
next.states = [PushState(core: "gambatte-native", slot: "1", file: PushFile(hash: "aa")),
               PushState(core: "other", slot: "1", file: PushFile(hash: "bb")),
               PushState(core: "gambatte-native", slot: "2", file: PushFile(hash: "cc"))]
let m2 = manifest(next)
let bank = m2["states"] as? [String: [String: String]]
check(m2["expected_current_id"] as? Int == 122 && m2["parent_snapshot_id"] as? Int == 121 && m2["save"] == nil
      && bank?["gambatte-native"] == ["1": "aa", "2": "cc"] && bank?["other"] == ["1": "bb"],
      "into a channel: the current expected, an older parent, no save, the states a core at a time")
check(RommSnapshots.parts(next).map(\.name) == ["manifest"], "states RomM holds go by hash alone, no bytes")
var withBytes = first
withBytes.save.bytes = bytesOf(7, 8192)
withBytes.save.fileName = "Pokemon.srm"
withBytes.save.picture = Data([1, 2, 3])
withBytes.save.pictureName = "Pokemon.png"
withBytes.states = [PushState(core: "gambatte-native", slot: "1",
                              file: PushFile(hash: "dd", fileName: "a.state", bytes: Data([9]), pictureName: "a.png", picture: Data([8])))]
check(RommSnapshots.parts(withBytes).map(\.name) == ["manifest", "save", "save_screenshot", "state:gambatte-native:1", "state:gambatte-native:1:screenshot"],
      "and the parts a push with bytes sends, RomM's names for each")

section("The files a game's channels can be on")
let files = RommSnapshots.readChannelFiles(Data(#"{"id":9,"channel_file_id":8,"files":[{"id":8,"category":"game"},{"id":12,"category":"manual"},{"id":13}]}"#.utf8))
check(files == ChannelFiles(channelFile: 8, files: [8, 13]), "the one RomM names for new channels, and every game file")

// MARK: - The rule

section("The rule (CabinetOS's savepick table, its old-row cases left out)")
let tag = "gambatte-native"
let phoneTag = "retroarch-mgba"
let me = RommSnapshots.phoneClient
let t1 = "2026-11-18T20:00:00.000000+00:00"
let t2 = "2026-11-18T21:00:00.500000+00:00"
let t3 = "2026-11-18T22:00:00+00:00"

func channelWith(_ label: String, _ id: Int, _ at: String, _ tag: String, _ hash: String, _ client: String?,
                 _ holders: [String] = []) -> SaveChannel {
    var c = SaveChannel()
    c.id = "channel-" + label
    c.label = label
    c.currentId = id
    c.current.id = id
    c.current.digest = "sha256:" + hash
    c.current.channelId = c.id
    c.current.createdAt = at
    c.current.deviceOwn = client != nil
    c.current.deviceClient = client ?? ""
    c.current.heldBy = holders.map { SnapshotHolder(deviceId: "device", client: $0, syncedAt: at) }
    var s = SnapshotFile()
    s.id = id * 10
    s.fileName = "Game.srm"
    s.sizeBytes = 32768
    s.contentHash = hash
    s.emulator = tag
    c.current.save = s
    return c
}
func holding(_ hash: String, _ had: [String] = []) -> SaveMirror.Held {
    var h = SaveMirror.Held()
    h.channelId = "channel-default"
    h.snapshotId = 1
    h.saveHash = hash
    h.at = 1
    h.hashesHad = had + [hash]
    return h
}
func facts(_ channels: [SaveChannel] = [], held: SaveMirror.Held? = nil, owed: Bool = false, others: [RommAsset] = []) -> SavePick.Facts {
    var f = SavePick.Facts()
    f.tag = tag
    f.channels = channels
    f.held = held
    f.owed = owed
    f.otherRows = others
    return f
}
do {
    let p = SavePick.pick(facts([channelWith("default", 12, t2, tag, "aaaa", me, [me])], held: holding("aaaa")))
    check(p.from == .channel && p.channel.current.id == 12 && !p.madeElsewhere && !p.couldNotUseNewest
          && !SavePick.continuingElsewhere(p, sameAsOwn: false), "own save newest: started from it, no notice")
}
do {
    let p = SavePick.pick(facts([channelWith("default", 13, t3, tag, "bbbb", "cabinetos", ["cabinetos"])], held: holding("aaaa")))
    check(p.from == .channel && p.channel.current.id == 13 && p.madeElsewhere && SavePick.continuingElsewhere(p, sameAsOwn: false),
          "the TV saved later: started from its save, with the notice")
    check(!SavePick.continuingElsewhere(p, sameAsOwn: true), "the same bytes the phone already had: never the notice")
}
do {
    var f = facts([channelWith("default", 12, t1, tag, "aaaa", me, [me]), channelWith("second run", 20, t2, tag, "cccc", me, [me])])
    check(SavePick.pick(f).channel.label == "second run", "two channels: the newer save's channel")
    f.channels[0].current.createdAt = t3
    check(SavePick.pick(f).channel.label == "default", "two channels: and the other when it is newer")
    f.channels[0].current.createdAt = "2026-11-18T21:00:00.400000+00:00"
    check(SavePick.pick(f).channel.label == "second run", "two channels a tenth of a second apart: still the later")
}
do {
    var hardCh = channelWith("default", 30, t3, tag, "dddd", me, [me])
    hardCh.hardcore = true
    hardCh.current.hardcore = true
    let p = SavePick.pick(facts([channelWith("softcore", 12, t1, tag, "aaaa", me, [me]), hardCh]))
    check(p.from == .channel && p.channel.current.id == 30 && p.channel.hardcore, "a hardcore one newest: started from it, marked hardcore")
}
do {
    check(SavePick.pick(facts([channelWith("default", 13, t3, tag, "bbbb", me, [me])], owed: true)).from == .own,
          "a save on the phone still owed: the phone's stands")
    let p = SavePick.pick(facts([channelWith("default", 40, t3, phoneTag, "ffff", "argosy", ["argosy"])], owed: true))
    check(p.from == .own && !p.other && !p.couldNotUseNewest,
          "a save still owed, another emulator's the newest: the phone's stands, and nothing was turned down")
}
do {
    var held = holding("bbbb", ["aaaa"])
    held.beside = true
    held.madeAt = SavePick.isoMicros(t2) / 1_000_000
    var f = facts([channelWith("default", 12, t1, tag, "aaaa", me, [me])], held: held)
    check(SavePick.pick(f).from == .own, "a save of its own kept beside the current, an older one still listed: its own stands")
    f.channels = [channelWith("default", 13, t3, tag, "cccc", "cabinetos", ["cabinetos"])]
    let newer = SavePick.pick(f)
    check(newer.from == .channel && newer.channel.current.id == 13 && newer.madeElsewhere,
          "kept beside, the current made later: the current, with the notice")
    f.channels = [channelWith("default", 40, t3, phoneTag, "ffff", "argosy", ["argosy"]),
                  channelWith("softcore", 12, t1, tag, "aaaa", me, [me])]
    let asks = SavePick.pick(f)
    check(asks.other && asks.from == .channel && asks.channel.current.id == 40, "kept beside, another emulator's made later: that one is asked for")
    f.channels[0].current.createdAt = "2026-11-18T20:30:00+00:00"
    check(!SavePick.pick(f).other && SavePick.pick(f).from == .own,
          "kept beside, another emulator's made before its own: its own stands, nothing asked")
    f.channels[0].current.createdAt = t3
    let stays = SavePick.pick(f, others: .unusable)
    check(stays.from == .own && stays.couldNotUseNewest && !stays.other,
          "and when it could not be used: its own stands, never the older one it could use")
    f.held?.beside = false
    let unusable = SavePick.pick(f, others: .unusable)
    check(unusable.from == .channel && unusable.channel.current.id == 12 && unusable.couldNotUseNewest,
          "the same lists for a phone whose save is not beside anything: the newest it can use")
}
do {
    var empty = channelWith("default", 14, t3, tag, "eeee", me)
    empty.current.save?.sizeBytes = 0
    var statesOnly = channelWith("states", 15, t3, tag, "", me)
    statesOnly.current.save = nil
    var none = SaveChannel()
    none.id = "channel-new"
    none.label = "new"
    var f = facts([empty, statesOnly, none])
    let alone = SavePick.pick(f)
    check(alone.from == .own && !alone.couldNotUseNewest, "an empty save on RomM, alone: the phone's stands")
    f.channels.append(channelWith("older", 9, t1, tag, "aaaa", me, [me]))
    check(SavePick.pick(f).from == .channel && SavePick.pick(f).channel.current.id == 9, "an empty save, newer than a real one: the real one")
}
do {
    check(SavePick.pick(facts()).from == .own, "nothing ever seen: the phone's stands")
    check(SavePick.pick(facts([channelWith("default", 13, t3, tag, "bbbb", me, [me])])).from == .channel,
          "offline: RomM's channels as last seen decide as they would online")
}
do {
    var f = facts([channelWith("default", 40, t3, phoneTag, "ffff", "argosy", ["argosy"])])
    let asked = SavePick.pick(f)
    check(asked.other && asked.from == .channel && asked.channel.current.id == 40 && asked.madeElsewhere && !asked.couldNotUseNewest,
          "another emulator's save, the newest: asked for in the phone's form, made elsewhere")
    let alone = SavePick.pick(f, others: .unusable)
    check(alone.from == .own && alone.couldNotUseNewest && !alone.other, "and when it could not be used, alone: the phone's stands, and it says so")
    f.channels.append(channelWith("softcore", 12, t2, tag, "aaaa", me, [me]))
    let withOwn = SavePick.pick(f, others: .unusable)
    check(withOwn.from == .channel && withOwn.channel.current.id == 12 && withOwn.couldNotUseNewest,
          "could not be used: the newest the phone can use")
    f.channels[0].current.createdAt = t1
    check(!SavePick.pick(f).other && !SavePick.pick(f).couldNotUseNewest && SavePick.pick(f).channel.current.id == 12,
          "another emulator's save, older: nothing asked, nothing to say")
    f.channels[0].current.createdAt = t2
    check(!SavePick.pick(f).other && SavePick.pick(f).channel.current.id == 12, "made at the same moment: the phone's form, no asking")
}
do {
    var f = facts([channelWith("default", 1, t3, phoneTag, "ffff", me, [me])], held: holding("ffff"))
    let held = SavePick.pick(f)
    check(held.from == .own && !held.other && !held.couldNotUseNewest && !held.madeElsewhere,
          "the newest is the snapshot the phone holds, under another emulator's name: its own copy stands")
    check(SavePick.pick(f, others: .unusable).from == .own && !SavePick.pick(f, others: .unusable).couldNotUseNewest,
          "and with RomM away: the same, so what it saves can go on top")
    f.held?.snapshotId = 2
    let other = SavePick.pick(f)
    check(other.other && other.from == .channel && other.channel.current.id == 1, "a newer snapshot than the one it holds: asked for")
}
do {
    var f = facts([channelWith("default", 5, t3, phoneTag, "ffff", "cabinetos", ["cabinetos"])], held: holding("aaaa"))
    f.channels[0].current.emulator = tag
    let away = SavePick.pick(f, others: .unusable)
    check(away.from == .channel && away.channel.current.id == 5 && !away.other && !away.couldNotUseNewest,
          "a snapshot the TV pushed, its save filed under an app's row: used as stored")
    f.channels[0].current.emulator = phoneTag
    check(SavePick.pick(f).other && SavePick.pick(f, others: .unusable).couldNotUseNewest, "an app's own push: another emulator's")
    f.channels[0].current.save?.emulator = tag
    check(!SavePick.pick(f).other && SavePick.pick(f).from == .channel, "an app's push filed under the phone's tag: used as stored")
}
do {
    func row(_ id: Int, _ emulator: String, _ at: String, channel: String = "") -> RommAsset {
        var a = RommAsset()
        a.id = id
        a.fileName = "Game.srm"
        a.emulator = emulator
        a.updatedAt = at
        a.channelId = channel
        return a
    }
    let others = SavePick.otherRows([row(70, "sameboy", t3), row(71, tag, t1), row(72, "gambatte", t3, channel: "channel-x")], tag: tag, channels: [])
    check(others.map(\.id) == [70], "another app's saves in no channel: not the phone's tag, and not a snapshot's")
    let p = SavePick.pick(facts(others: others))
    check(p.other && p.from == .otherRow && p.row.id == 70 && p.madeElsewhere && SavePick.pickedAt(p) == t3,
          "another app's save in no channel, the newest: asked for, made elsewhere")
    check(SavePick.continuingElsewhere(p, sameAsOwn: false) && !SavePick.continuingElsewhere(p, sameAsOwn: true),
          "its notice, never when it is what the phone already had")
    check(SavePick.pick(facts([channelWith("default", 40, t3, phoneTag, "ffff", "argosy", ["argosy"])], others: others)).from == .channel,
          "a channel's and a row's made at the same moment: the channel's")
}
do {
    var f = facts([channelWith("default", 50, t2, tag, "aaaa", me, [me])])
    func row(_ id: Int, _ at: String, _ slot: String) -> RommAsset {
        var a = RommAsset()
        a.id = id
        a.romId = 1
        a.emulator = "sameboy"
        a.updatedAt = at
        a.channelId = "channel-default"
        a.slot = slot
        return a
    }
    f.channels[0].current.save?.id = 500
    f.otherRows = SavePick.otherRows([row(80, t3, "autosave"), row(81, t1, "autosave"), row(82, t3, ""), row(500, t3, "autosave")],
                                     tag: tag, channels: f.channels)
    check(f.otherRows.map(\.id) == [80], "an app's save under a slot, newer than its channel's current: weighed; older, a snapshot's, and the current's own are not")
    check(SavePick.pick(f).other && SavePick.pick(f).from == .otherRow && SavePick.pick(f).row.id == 80, "and when it is the newest, it is asked for")
    f.owed = true
    check(SavePick.pick(f).from == .own, "one still owed stands")
}
do {
    var f = facts([channelWith("default", 50, t2, tag, "aaaa", me, [me])])
    var r = RommAsset()
    r.id = 215
    r.emulator = "snes9x"
    r.createdAt = "2026-10-30T09:00:00+00:00"
    r.updatedAt = t3
    r.channelId = "channel-default"
    r.slot = "autosave"
    f.otherRows = SavePick.otherRows([r], tag: tag, channels: f.channels)
    check(f.otherRows.isEmpty && SavePick.pick(f).from == .channel, "a kept-out save stored weeks before and re-dated since: not weighed")
    r.channelId = ""
    r.slot = ""
    f.otherRows = SavePick.otherRows([r], tag: tag, channels: f.channels)
    check(f.otherRows.count == 1 && SavePick.pick(f).row.id == 215, "one in no channel written again in place: by its updated_at")
}
do {
    let f = facts([channelWith("default", 60, t3, phoneTag, "ffff", "web", ["web"])])
    let none = SavePick.pick(f, others: .holdsNone)
    check(none.from == .own && !none.other && !none.couldNotUseNewest && !SavePick.continuingElsewhere(none, sameAsOwn: false),
          "RomM says the newest holds none of this game's saves: the phone's stands and nothing is said")
    check(SavePick.pick(f, others: .unusable).couldNotUseNewest, "one it could not use is still said")
}
check(SavePick.mayLoad(emulator: "melonds-native", core: "melonds", tag: "melonds-native", sigil: "melonds")
      && !SavePick.mayLoad(emulator: "desmume", core: "desmume", tag: "melonds-native", sigil: "melonds")
      && SavePick.mayLoad(emulator: "MELONDS-NATIVE", core: "", tag: "melonds-native", sigil: "melonds")
      && !SavePick.mayLoad(emulator: "nds", core: "", tag: "melonds-native", sigil: "melonds")
      && SavePick.mayLoad(emulator: "", core: "", tag: "melonds-native", sigil: "melonds"),
      "RomM's own rule for who may load a save as stored")
do {
    var held = holding("bbbb", ["aaaa"])
    held.beside = true
    held.madeAt = SavePick.isoMicros(t2) / 1_000_000
    var f = facts([channelWith("default", 12, t3, tag, "aaaa", me, [me])], held: held)
    var own = RommAsset()
    own.id = 120
    own.createdAt = t1
    SavePick.dateSaves(&f.channels, rows: [own])
    check(f.channels[0].current.saveAt == t1 && SavePick.pick(f).from == .own,
          "a current that changed only its states, its save first stored before the phone's own kept beside: dated by the save's row, its own stands")
}
section("The notice")
do {
    var f = facts([channelWith("default", 77, t3, tag, "aaaa", me)], held: holding("bbbb", ["aaaa"]))
    check(!SavePick.pick(f).madeElsewhere, "a save of the phone's restored on RomM's website: no notice")
    f.held = nil
    f.channels = [channelWith("default", 13, t3, tag, "bbbb", me, [me])]
    check(!SavePick.pick(f).madeElsewhere, "after a reinstall, held by a phone: no notice")
    f.channels = [channelWith("default", 13, t3, tag, "bbbb", "cabinetos", ["cabinetos"])]
    check(SavePick.pick(f).madeElsewhere, "after a reinstall, the TV's and held by it: the notice")
    f.channels = [channelWith("default", 13, t3, tag, "bbbb", "cabinetos", ["cabinetos", me])]
    check(!SavePick.pick(f).madeElsewhere, "after a reinstall, the TV's that a phone also holds: no notice")
    f.channels = [channelWith("default", 13, t3, tag, "bbbb", nil)]
    check(!SavePick.pick(f).madeElsewhere, "after a reinstall, RomM names no device: no notice")
}
section("The note a start leaves")
do {
    let c = channelWith("default", 13, t3, tag, "bbbb", me)
    var h = SavePick.heldAfter(nil, channelId: c.id, taken: c.current, now: 1700)
    check(h.channelId == c.id && h.snapshotId == 13 && h.digest == "sha256:bbbb" && h.saveHash == "bbbb" && h.at == 1700
          && h.hashesHad == ["bbbb"] && h.madeAt == SavePick.isoMicros(t3) / 1_000_000 && !h.beside,
          "the first: the snapshot, its save's hash, when it was taken, and when RomM took its save")
    let nextC = channelWith("default", 14, t3, tag, "cccc", me)
    h = SavePick.heldAfter(h, channelId: nextC.id, taken: nextC.current, now: 1800)
    h = SavePick.heldAfter(h, channelId: c.id, taken: c.current, now: 1900)
    check(h.snapshotId == 13 && h.hashesHad == ["cccc", "bbbb"], "later ones: every hash it has had, once each, the held one last")
    var many = SaveMirror.Held()
    many.hashesHad = (0..<400).map { "h\($0)" }
    h = SavePick.heldAfter(many, channelId: c.id, taken: c.current, now: 2100)
    check(h.hashesHad.count == SavePick.hashesKept && h.hashesHad.last == "bbbb", "the list is cut from its oldest end")
}
check(SavePick.isoMicros(t2) - SavePick.isoMicros(t1) == 3_600_500_000 && SavePick.isoMicros("2026-11-18T22:00:00Z") == SavePick.isoMicros(t3)
      && SavePick.isoMicros("soon") == 0, "RomM's times read to the microsecond, with or without a fraction")

// MARK: - Each core's form

section("Each core's save, and the form it travels in")
let gb = SaveForm.forTag("gambatte-native")!
let gba = SaveForm.forTag("mgba-native")!
let gg = SaveForm.forTag("gpgx-native")!
let ngp = SaveForm.forTag("ngp-native")!
let nds = SaveForm.forTag("melonds-native")!
let psp = SaveForm.forTag("ppsspp-native")!
let vmu = SaveForm.forTag("flycast-native")!
check(gb.sigil == "gambatte" && gba.sigil == "mgba" && gg.sigil == "genesis_plus_gx" && ngp.sigil == "mednafen_ngp"
      && nds.sigil == "melonds" && psp.sigil == "ppsspp" && vmu.sigil == "flycast", "Sigil's name for each core")
check(SaveForm.forTag("gw-native") == nil, "Game & Watch has no save")
check(gb.clock && !gba.clock && !gg.clock && gba.sameCoreOnly && gg.sameCoreOnly && nds.sameCoreOnly && !gb.sameCoreOnly,
      "the clock beside Gambatte's battery; GBA, Game Gear and DS only from the same emulator")
check(gb.upName(stem: "Pokemon Gold", title: "", zipped: true) == "Pokemon Gold.zip" && gb.shape(zipped: true) == "MULTI"
      && gba.upName(stem: "Minish Cap", title: "", zipped: false) == "Minish Cap.srm" && gba.shape(zipped: false) == "SINGLE"
      && nds.upName(stem: "Contra 4", title: "", zipped: false) == "Contra 4.sav" && ngp.upName(stem: "SNK vs Capcom", title: "", zipped: false) == "SNK vs Capcom.flash"
      && psp.upName(stem: "x", title: "Lumines: Puzzle Fusion", zipped: true) == "Lumines_ Puzzle Fusion.zip" && psp.shape(zipped: true) == "FOLDER"
      && vmu.upName(stem: "Sonic Adventure", title: "", zipped: false) == "Sonic Adventure.bin",
      "the name each save goes up under, the TV's for the same save")
check(vmu.askQuery.map { "\($0.name)=\($0.value ?? "")" } == ["core=flycast", "option=reicast_per_content_vmus:VMU A1"],
      "the VMU asked for as the TV's Flycast keeps it")
let clockZip = SaveForm.batteryZip(battery: bytesOf(3, 32768), clock: bytesOf(5, 8), stem: "Gold")
let parts = SaveForm.batteryParts(clockZip)
check(SaveZip.entries(of: clockZip)?.map(\.path) == ["Gold.srm", "Gold.rtc"] && parts?.battery == bytesOf(3, 32768)
      && parts?.clock == bytesOf(5, 8) && parts?.zipped == true, "a battery with its clock: one zip of `<game>.srm` and `<game>.rtc`, read back")
check(SaveForm.batteryParts(bytesOf(3, 8192))?.zipped == false, "a battery alone travels as it is")
check(SaveForm.sameBattery(bytesOf(3, 8192), bytesOf(3, 8192) + Data(repeating: 0xFF, count: 8192))
      && !SaveForm.sameBattery(bytesOf(3, 8192), bytesOf(3, 8192) + Data(repeating: 0x00, count: 8192)),
      "the same battery in two lengths, the missing end blank (mGBA, Genesis Plus GX)")
check(SaveForm.coreReadsBattery(8192, coreBytes: 131072) && !SaveForm.coreReadsBattery(262144, coreBytes: 131072),
      "another emulator's battery no longer than the core's")

func answer(_ bytes: Data, path: String = "") -> SaveAnswer { SaveAnswer(status: 200, bytes: bytes, savePath: path) }
let blank = Data(repeating: 0xFF, count: 8192)
check(gba.ownForm(of: answer(bytesOf(3, 8192), path: "game.srm"), plain: false, madeBy: "retroarch-mgba", madeByCore: "mgba", stem: "g") == .success(bytesOf(3, 8192)),
      "a GBA battery RomM handed in mGBA's form: used")
if case .failure = gba.ownForm(of: answer(bytesOf(3, 8192)), plain: false, madeBy: "vba-m", madeByCore: "vbam", stem: "g") {
    check(true, "a GBA battery from another emulator, as stored: refused (Sigil names how they differ)")
} else { check(false, "a GBA battery from another emulator, as stored: refused") }
if case .failure = gb.ownForm(of: answer(blank), plain: false, madeBy: "sameboy", madeByCore: "", stem: "g") {
    check(true, "a blank battery is no save")
} else { check(false, "a blank battery is no save") }
let rtcAnswer = SaveZip.zip([SaveZip.Entry(path: "saves/Gold.srm", data: bytesOf(3, 32768)), SaveZip.Entry(path: "saves/Gold.rtc", data: bytesOf(5, 8))])
check(gb.ownForm(of: answer(rtcAnswer), plain: false, madeBy: "sameboy", madeByCore: "", stem: "Gold")
      == .success(SaveForm.batteryZip(battery: bytesOf(3, 32768), clock: bytesOf(5, 8), stem: "Gold")),
      "a Game Boy battery with its clock converted by RomM: the phone's own zip of the two")
var flash = Data([0x53, 0x00]) + bytesOf(9, 1000)
check(ngp.ownForm(of: answer(flash, path: "SNK.flash"), plain: false, madeBy: "mednafen", madeByCore: "", stem: "SNK") == .success(flash),
      "Neo Geo Pocket's flash with its mark: used")
flash[0] = 0x00
if case .failure = ngp.ownForm(of: answer(flash), plain: false, madeBy: "mednafen", madeByCore: "", stem: "SNK") {
    check(true, "a flash file without NeoPop's mark: refused")
} else { check(false, "a flash file without NeoPop's mark: refused") }
check(nds.ownForm(of: answer(bytesOf(3, 524288), path: "Contra 4.sav"), plain: false, madeBy: "melonDS", madeByCore: "melonds", stem: "c") == .success(bytesOf(3, 524288)),
      "a DS save of a cartridge's size: used")
if case .failure = nds.ownForm(of: answer(bytesOf(3, 524288 + 122), path: "Contra 4.dsv"), plain: false, madeBy: "melonDS", madeByCore: "melonds", stem: "c") {
    check(true, "DeSmuME's longer file: refused")
} else { check(false, "DeSmuME's longer file: refused") }
let sfo = Data([0x00, 0x50, 0x53, 0x46]) + bytesOf(29, 400)
let pspAnswer = SaveZip.zip([SaveZip.Entry(path: "PSP/SAVEDATA/ULUS10002LUMINES/PARAM.SFO", data: sfo),
                             SaveZip.Entry(path: "PSP/SAVEDATA/ULUS10002LUMINES/DATA.BIN", data: bytesOf(23, 5000))])
if case .success(let mine) = psp.ownForm(of: answer(pspAnswer), plain: false, madeBy: "ppsspp", madeByCore: "ppsspp", stem: "l") {
    check(SaveZip.entries(of: mine)?.map(\.path) == ["ULUS10002LUMINES/PARAM.SFO", "ULUS10002LUMINES/DATA.BIN"],
          "PSP save folders RomM handed under `PSP/SAVEDATA/`: re-rooted at SAVEDATA, the TV's layout")
} else { check(false, "PSP save folders RomM handed under `PSP/SAVEDATA/`") }
let stray = SaveZip.zip([SaveZip.Entry(path: "PSP/SAVEDATA/ULUS10002LUMINES/DATA.BIN", data: bytesOf(23, 5000))])
if case .failure = psp.ownForm(of: answer(stray), plain: false, madeBy: "ppsspp", madeByCore: "ppsspp", stem: "l") {
    check(true, "a PSP save folder with no PARAM.SFO: refused")
} else { check(false, "a PSP save folder with no PARAM.SFO: refused") }
var card = Data(count: 131072)
for i in 0..<16 { card[255 * 512 + i] = 0x55 }
if case .failure = vmu.ownForm(of: answer(card), plain: false, madeBy: "flycast", madeByCore: "flycast", stem: "s") {
    check(true, "a VMU card with no file on it is no save")
} else { check(false, "a VMU card with no file on it is no save") }
card[241 * 512] = 0xCC
check(vmu.ownForm(of: answer(card), plain: false, madeBy: "flycast", madeByCore: "flycast", stem: "s") == .success(card),
      "a VMU card holding a game: used")
check(SaveForm.holdsNoneOfTheGame(SaveAnswer(status: 422, error: "NOT_FOUND")) && !SaveForm.holdsNoneOfTheGame(SaveAnswer(status: 404, error: "NOT_FOUND")),
      "RomM saying the save holds none of this game's saves")

// MARK: - Leaving a game

section("Leaving a game (CabinetOS's savepush cases, against a stand-in RomM)")
let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("cabinet-go-saves-\(UUID().uuidString)", isDirectory: true)
try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
let mirror = SaveMirror(root: scratch)
let kChannel = "01937a3c-0000-7000-8000-00000000000a"
let kFile = 4410
func romTime(_ seconds: Int) -> String { SavePick.isoUTC(seconds: Int64(Date().timeIntervalSince1970) + Int64(seconds)) }
func snap(_ id: Int, _ channelId: String, _ hash: String, _ at: String) -> Snapshot {
    var s = Snapshot()
    s.id = id
    s.digest = "sha256:\(id)"
    s.kind = "channel"
    s.channelId = channelId
    s.createdAt = at
    s.deviceOwn = true
    s.deviceClient = me
    var f = SnapshotFile()
    f.id = id * 10
    f.fileName = "save"
    f.sizeBytes = 64
    f.contentHash = hash
    f.emulator = tag
    s.save = f
    return s
}
func chan(_ id: String, _ label: String, _ current: Snapshot, hardcore: Bool = false) -> SaveChannel {
    var c = SaveChannel()
    c.id = id
    c.label = label
    c.hardcore = hardcore
    c.romFileId = kFile
    c.updatedAt = current.createdAt
    c.currentId = current.id
    c.current = current
    c.current.channelId = id
    c.current.hardcore = hardcore
    return c
}
func made(_ s: Snapshot, unchanged: Bool = false) -> PushAnswer {
    var a = PushAnswer()
    a.kind = unchanged ? .unchanged : .made
    a.status = unchanged ? 200 : 201
    a.snapshot = s
    return a
}
func movedOn(_ branch: Snapshot, _ current: Snapshot?) -> PushAnswer {
    var a = PushAnswer()
    a.kind = .movedOn
    a.status = 409
    a.snapshot = branch
    a.snapshot.kind = "branch"
    a.hasCurrent = current != nil
    if let current { a.current = current }
    return a
}
func answerOf(_ kind: PushAnswer.Kind, _ status: Int, missing: [String] = []) -> PushAnswer {
    var a = PushAnswer()
    a.kind = kind
    a.status = status
    a.missing = missing
    return a
}

/// RomM, standing in: each push answered with the next scripted answer (none
/// at all once they run out), every push kept.
@MainActor final class Stand {
    var heard = true
    var files = ChannelFiles(channelFile: kFile, files: [kFile])
    var known = ChannelFiles(channelFile: 0, files: [])
    var channels: [SaveChannel] = []
    var answers: [PushAnswer] = []
    var pushes: [SnapshotPush] = []
    var rows: [RommAsset] = []
    var stateRows: [RommAsset] = []
    var history: [String: [Snapshot]] = [:]
    var duringPush: (() -> Void)?
    var server: SavePush.Server {
        SavePush.Server(
            hasChannels: { self.heard },
            files: { _, ask in
                if !ask { return self.known }
                self.known = self.files
                return self.files
            },
            channels: { ids in self.channels.filter { ids.contains($0.romFileId) } },
            push: { push in
                self.pushes.append(push)
                if let c = self.channels.first(where: { $0.id == push.channelId }), c.romFileId != push.romFileId {
                    return answerOf(.refused, 422)
                }
                self.duringPush?()
                guard !self.answers.isEmpty else { throw SaveServerError.unanswered("could not reach the server") }
                return self.answers.removeFirst()
            },
            saves: { _ in self.rows },
            states: { _ in self.stateRows },
            history: { id in
                guard let h = self.history[id] else { throw SaveServerError.notFound("HTTP 404") }
                return h
            },
            content: { _ in Data() },
            saveAs: { _, _ in SaveAnswer() }
        )
    }
}

let one = bytesOf(61, 64)
let older = bytesOf(67, 64)
let hashOne = SaveHash.content(one)
let hashOlder = SaveHash.content(older)
var game = 100
func aimFrom(_ romId: Int) -> SavePush.AimFrom { SavePush.AimFrom(romId: romId, tag: tag, core: "gambatte") }
func gathered(_ bytes: Data = one, picture: Data? = nil, madeAt: Int64 = Int64(Date().timeIntervalSince1970)) -> SavePush.Gathered {
    SavePush.Gathered(bytes: bytes, name: "Game (USA).srm", shape: "SINGLE", picture: picture, madeAt: madeAt)
}
func hold(_ romId: Int, _ id: Int) {
    mirror.putHeld(romId, SavePick.heldAfter(nil, channelId: kChannel, taken: snap(id, kChannel, hashOlder, romTime(-3600)),
                                              now: Int64(Date().timeIntervalSince1970) - 3600))
}

section("where a push is aimed")
do {
    game += 1
    hold(game, 40)
    mirror.putChannels(game, [chan(kChannel, "second run", snap(40, kChannel, hashOlder, romTime(-3600)))])
    var from = aimFrom(game)
    from.startChannelId = kChannel
    from.startSnapshotId = 40
    check(SavePush.mark(gathered(), from: from, mirror: mirror), "a session's save marked owed")
    let p = SavePush.owed(game, mirror: mirror)
    check(p?.channelId == kChannel && p?.label == "second run" && p?.expectedCurrentId == 40 && p?.parentId == 0,
          "started from a channel's snapshot: into that channel, on that snapshot, under the channel's own name")
    var later = from
    later.couldNotUseNewest = true
    SavePush.mark(gathered(older), from: later, mirror: mirror)
    let q = SavePush.owed(game, mirror: mirror)
    check(q?.stamp != p?.stamp && q?.couldNotUseNewest == true && q?.expectedCurrentId == 40,
          "a later session while that is unsent: the newer save, on the same snapshot")
    SavePush.mark(gathered(), from: from, mirror: mirror)
    check(SavePush.owed(game, mirror: mirror)?.couldNotUseNewest == true, "and what an unsent one could not go on top of, the next cannot either")
}
do {
    game += 1
    hold(game, 41)
    SavePush.mark(gathered(), from: aimFrom(game), mirror: mirror)
    let p = SavePush.owed(game, mirror: mirror)
    check(p?.channelId == kChannel && p?.expectedCurrentId == 41 && p?.label == "default",
          "started from the phone's own save: on the snapshot the phone holds")
}
do {
    game += 1
    hold(game, 42)
    var from = aimFrom(game)
    from.startChannelId = kChannel
    from.startSnapshotId = 42
    from.startHardcore = true
    SavePush.mark(gathered(), from: from, mirror: mirror)
    let p = SavePush.owed(game, mirror: mirror)
    check(p?.channelId == "" && p?.label == "softcore" && p?.expectedCurrentId == 0 && p?.parentId == 42,
          "started from a hardcore channel: never into it, into \"softcore\", made from the snapshot it started from")
}

section("RomM's answers")
do {
    game += 1
    let g = game
    SavePush.mark(gathered(), from: aimFrom(g), mirror: mirror)
    let madeAt = SavePush.owed(g, mirror: mirror)?.madeAt ?? 0
    let romm = Stand()
    romm.answers = [made(snap(50, kChannel, hashOne, romTime(1)))]
    let (sent, _) = await SavePush.send(romm.server, romId: g, mirror: mirror)
    let p = romm.pushes.first
    check(sent == .landed && romm.pushes.count == 1 && p?.romFileId == kFile && p?.channelId == "" && p?.label == "default"
          && p?.expectedCurrentId == 0 && p?.hasSave == true && p?.save.bytes == one && p?.save.hash == hashOne
          && p?.save.fileName == "Game (USA).srm" && p?.saveShape == "SINGLE" && p?.emulator == tag && p?.core == "gambatte"
          && p?.states.isEmpty == true,
          "no channel yet: one push, the save's bytes named by RomM's hash, under the core's tag, into \"default\" for RomM to make")
    let held = mirror.getHeld(g)
    check(SavePush.owed(g, mirror: mirror) == nil && held?.channelId == kChannel && held?.snapshotId == 50
          && held?.saveHash == hashOne && held?.beside == false && held?.madeAt == madeAt,
          "it landed: no longer owed, and the snapshot is the one the phone holds, dated when the phone wrote the save")
    let (again, _) = await SavePush.send(romm.server, romId: g, mirror: mirror)
    check(again == .nothingOwed && romm.pushes.count == 1, "asked again with nothing owed: nothing is sent")
}
do {
    game += 1
    let g = game
    hold(g, 60)
    SavePush.mark(gathered(picture: Data([7, 7, 7])), from: aimFrom(g), mirror: mirror)
    let romm = Stand()
    let top = snap(61, kChannel, hashOne, romTime(1))
    romm.channels = [chan(kChannel, "default", snap(60, kChannel, hashOlder, romTime(-3600)))]
    romm.answers = [made(top)]
    romm.duringPush = { romm.channels = [chan(kChannel, "default", top)] }
    let (sent, _) = await SavePush.send(romm.server, romId: g, mirror: mirror)
    let p = romm.pushes.first
    check(sent == .landed && p?.channelId == kChannel && p?.expectedCurrentId == 60 && p?.parentId == 0
          && mirror.getHeld(g)?.snapshotId == 61 && mirror.getHeld(g)?.hashesHad.first == hashOlder,
          "on the snapshot the phone holds: that channel, that current expected, and the hash it held kept among those it has had")
    check(p?.save.picture == Data([7, 7, 7]) && p?.save.pictureName == "Game (USA).png", "the save's picture goes in the same push, named after the save")
    var keptSave = SnapshotFile()
    keptSave.contentHash = hashOne
    check(mirror.getChannels(g)?.first?.currentId == 61 && mirror.getSnapshotSave(g, keptSave) == one,
          "the copy for offline is RomM's channels as they are now, with the bytes just sent")
}
do {
    game += 1
    let g = game
    hold(g, 62)
    SavePush.mark(gathered(), from: aimFrom(g), mirror: mirror)
    let romm = Stand()
    romm.answers = [made(snap(63, kChannel, hashOne, romTime(-5)), unchanged: true)]
    let (sent, _) = await SavePush.send(romm.server, romId: g, mirror: mirror)
    check(sent == .landed && SavePush.owed(g, mirror: mirror) == nil && mirror.getHeld(g)?.snapshotId == 63,
          "RomM already holds exactly this (200): landed, and that current is the one held")
}
do {
    game += 1
    let g = game
    hold(g, 70)
    SavePush.mark(gathered(), from: aimFrom(g), mirror: mirror)
    let romm = Stand()
    let theirs = snap(71, kChannel, "ffff", romTime(-600))
    romm.answers = [movedOn(snap(72, kChannel, hashOne, romTime(0)), theirs), made(snap(73, kChannel, hashOne, romTime(1)))]
    let (sent, _) = await SavePush.send(romm.server, romId: g, mirror: mirror)
    let second = romm.pushes.count == 2 ? romm.pushes[1] : nil
    check(sent == .landed && romm.pushes.first?.expectedCurrentId == 70 && second?.channelId == kChannel
          && second?.expectedCurrentId == 71 && second?.parentId == 72 && second?.hasSave == false
          && second?.save.bytes.isEmpty == true && second?.states.isEmpty == true,
          "the channel moved on and the phone's save was made later: a second push puts the kept one on top, with no bytes")
    check(mirror.getHeld(g)?.snapshotId == 73 && mirror.getHeld(g)?.beside == false, "and the one on top is the one held")
}
do {
    game += 1
    let g = game
    hold(g, 74)
    SavePush.mark(gathered(), from: aimFrom(g), mirror: mirror)
    let romm = Stand()
    let theirs = snap(75, kChannel, "ffff", romTime(600))
    romm.answers = [movedOn(snap(76, kChannel, hashOne, romTime(601)), theirs)]
    let (sent, _) = await SavePush.send(romm.server, romId: g, mirror: mirror)
    let held = mirror.getHeld(g)
    check(sent == .beside && romm.pushes.count == 1 && SavePush.owed(g, mirror: mirror) == nil && held?.snapshotId == 76 && held?.beside == true,
          "the channel moved on and the other save was made later: left as RomM kept it, and noted as kept beside")
    var f = facts([chan(kChannel, "default", theirs)], held: held)
    check(SavePick.pick(f).from == .channel, "and the next start takes the one made later")
    f.channels = [chan(kChannel, "default", snap(75, kChannel, "ffff", romTime(-600)))]
    check(SavePick.pick(f).from == .own, "but never a save made before the phone's own, kept beside")
}
do {
    game += 1
    let g = game
    hold(g, 2100)
    SavePush.mark(gathered(), from: aimFrom(g), mirror: mirror)
    let romm = Stand()
    let theirs = snap(2101, kChannel, "ffff", romTime(600))
    var f = facts([chan(kChannel, "default", theirs)], held: mirror.getHeld(g), owed: SavePush.saveOwed(g, mirror: mirror))
    check(f.owed && SavePick.pick(f).from == .own, "back from a trip, its save still owed: as listed, the phone's own would stand")
    romm.answers = [movedOn(snap(2102, kChannel, hashOne, romTime(601)), theirs)]
    let settledFirst = await SavePush.oneAtATime(g) { await SavePush.settleBeforeStart(romm.server, romId: g, mirror: mirror) }
    check(settledFirst && !SavePush.saveOwed(g, mirror: mirror), "so the start sends it first, and it is owed no longer")
    f.owed = false
    f.held = mirror.getHeld(g)
    let after = SavePick.pick(f)
    check(after.from == .channel && after.channel.current.id == 2101, "and the start continues from the newer save, the trip's kept beside it")
}
do {
    game += 1
    let g = game
    hold(g, 80)
    var from = aimFrom(g)
    from.couldNotUseNewest = true
    SavePush.mark(gathered(), from: from, mirror: mirror)
    let romm = Stand()
    romm.answers = [movedOn(snap(82, kChannel, hashOne, romTime(1)), snap(81, kChannel, "ffff", romTime(-600)))]
    let (sent, _) = await SavePush.send(romm.server, romId: g, mirror: mirror)
    check(sent == .beside && romm.pushes.count == 1, "a session that could not use the newest save: always left as RomM kept it")
}
do {
    game += 1
    let g = game
    hold(g, 90)
    SavePush.mark(gathered(), from: aimFrom(g), mirror: mirror)
    let romm = Stand()
    romm.channels = [chan(kChannel, "default", snap(90, kChannel, hashOlder, romTime(-60)))]
    romm.answers = [answerOf(.hardcoreChannel, 409), made(snap(91, "soft", hashOne, romTime(1)))]
    let (sent, _) = await SavePush.send(romm.server, romId: g, mirror: mirror)
    let second = romm.pushes.count == 2 ? romm.pushes[1] : nil
    check(sent == .landed && second?.label == "softcore" && second?.channelId == "" && second?.parentId == 90 && second?.hasSave == true,
          "RomM says the channel turned hardcore: the save goes into \"softcore\", made from what it was made from")
}
do {
    game += 1
    let g = game
    hold(g, 95)
    SavePush.mark(gathered(), from: aimFrom(g), mirror: mirror)
    let romm = Stand()
    romm.channels = [chan(kChannel, "default", snap(95, kChannel, hashOlder, romTime(-60)))]
    romm.answers = [answerOf(.refused, 404), made(snap(96, "new", hashOne, romTime(1)))]
    let (sent, _) = await SavePush.send(romm.server, romId: g, mirror: mirror)
    let second = romm.pushes.count == 2 ? romm.pushes[1] : nil
    check(sent == .landed && second?.channelId == kChannel && second?.expectedCurrentId == 0,
          "a snapshot RomM no longer has (404): asked once more as a save of its own, into the channel of that name")
}
do {
    game += 1
    let g = game
    SavePush.mark(gathered(), from: aimFrom(g), mirror: mirror)
    let romm = Stand()
    romm.heard = false
    let (sent, _) = await SavePush.send(romm.server, romId: g, mirror: mirror)
    check(sent == .waits && romm.pushes.isEmpty && SavePush.saveOwed(g, mirror: mirror),
          "a RomM too old for save channels: nothing asked, still owed")
    romm.heard = true
    let (later, _) = await SavePush.send(romm.server, romId: g, mirror: mirror)
    check(later == .notSent && SavePush.saveOwed(g, mirror: mirror), "no answer: still owed, tried again later")
    romm.answers = [made(snap(97, kChannel, hashOne, romTime(1)))]
    let (finally, _) = await SavePush.send(romm.server, romId: g, mirror: mirror)
    check(finally == .landed, "and sent once RomM answers")
}

section("states, inside the snapshot")
@MainActor func makeState(_ g: Int, _ name: String, _ bytes: Data) {
    let dir = SavePush.statesDir(g, mirror: mirror)
    try? bytes.write(to: dir.appendingPathComponent(name + ".state"))
    try? Data([1]).write(to: dir.appendingPathComponent(name + ".png"))
    SavePush.markState(SavePush.StateMade(fileName: name + ".state", pictureName: name + ".png",
                                          madeMs: SavePush.stateNameMs(name + ".state")), from: aimFrom(g), mirror: mirror)
}
do {
    game += 1
    let g = game
    makeState(g, "Game [2026-11-26 20-00-00-001]", bytesOf(71, 100))
    makeState(g, "Game [2026-11-26 20-00-00-002]", bytesOf(73, 100))
    makeState(g, "Game [2026-11-26 20-00-00-003]", bytesOf(79, 100))
    makeState(g, "Game [2026-11-26 20-00-00-004]", bytesOf(83, 100))
    let p = SavePush.owed(g, mirror: mirror)
    check(p?.hasSave == false && p?.states.map(\.fileName) == ["Game [2026-11-26 20-00-00-004].state",
          "Game [2026-11-26 20-00-00-003].state", "Game [2026-11-26 20-00-00-002].state"] && p?.label == "default",
          "states made with no connection: written on the phone first, marked owed, the newest three")
    let offline = SavePush.offeredStates(g, tag: tag, rows: nil, mirror: mirror)
    check(offline.count == 3 && offline.first?.fileName == "Game [2026-11-26 20-00-00-004].state" && offline.first?.file != nil,
          "offered with RomM away: the phone's own, newest first, three")
    let romm = Stand()
    let current = snap(100, kChannel, hashOlder, romTime(-60))
    romm.channels = [chan(kChannel, "default", current)]
    romm.answers = [made(snap(101, kChannel, hashOlder, romTime(1)))]
    let (sent, _) = await SavePush.send(romm.server, romId: g, mirror: mirror)
    let push = romm.pushes.first
    check(sent == .landed && push?.hasSave == false && push?.channelId == kChannel && push?.expectedCurrentId == 100
          && push?.states.map(\.slot) == ["1", "2", "3"] && push?.states.allSatisfy({ !$0.file.bytes.isEmpty && $0.core == tag }) == true,
          "states alone go onto the channel's current as RomM lists it, with their bytes, in slots 1 to 3, newest first")
    let left = (try? FileManager.default.contentsOfDirectory(atPath: SavePush.statesDir(g, mirror: mirror).path)) ?? []
    check(left.filter { $0.hasSuffix(".state") }.count == 3 && !left.contains("Game [2026-11-26 20-00-00-001].state"),
          "the phone's copies of states it no longer offers go once RomM holds a push that did not name them")
    var r = RommAsset()
    r.id = 900
    r.fileName = "Game [2026-11-26 21-00-00-000] [2026-11-26_21-00-01-123].state"
    r.core = tag
    r.createdAt = "2026-11-26T21:00:01+00:00"
    r.picturePath = "/api/screenshots/9/content"
    var tv = RommAsset()
    tv.id = 901
    tv.fileName = "Other [2026-11-26 19-00-00-000].state"
    tv.core = "mgba-native"
    let online = SavePush.offeredStates(g, tag: tag, rows: [r, tv], mirror: mirror)
    check(online.first?.rommId == 900 && online.first?.file == nil && online.first?.picture == "/api/screenshots/9/content"
          && !online.contains { $0.rommId == 901 },
          "offered online: RomM's newest under the core's tag, wherever it was made; another core's never")
}
do {
    game += 1
    let g = game
    makeState(g, "Game [2026-11-26 20-10-00-000]", bytesOf(89, 100))
    let romm = Stand()
    var theirs = snap(110, kChannel, "ffff", romTime(-60))
    theirs.save?.emulator = phoneTag
    theirs.emulator = phoneTag
    romm.channels = [chan(kChannel, "default", theirs)]
    romm.answers = [made(snap(111, "new", "", romTime(1)))]
    _ = await SavePush.send(romm.server, romId: g, mirror: mirror)
    check(romm.pushes.first?.channelId == kChannel && romm.pushes.first?.expectedCurrentId == 0,
          "states alone never go onto another emulator's save: aimed as a save is")
}
do {
    game += 1
    let g = game
    makeState(g, "Game [2026-11-26 20-20-00-000]", bytesOf(97, 100))
    let romm = Stand()
    romm.answers = [answerOf(.refused, 422), made(snap(120, kChannel, "", romTime(1)))]
    romm.answers[0].unhashed = "state:\(tag):1"
    let (sent, _) = await SavePush.send(romm.server, romId: g, mirror: mirror)
    check(sent == .landed && romm.pushes.count == 2 && romm.pushes[1].states.isEmpty,
          "a state RomM could not hash goes no further, and the push goes again without it")
}
do {
    game += 1
    let g = game
    SavePush.mark(gathered(), from: aimFrom(g), mirror: mirror)
    let romm = Stand()
    romm.answers = [answerOf(.bytesMissing, 400, missing: ["save"])]
    let (sent, _) = await SavePush.send(romm.server, romId: g, mirror: mirror)
    check(sent == .refused && SavePush.saveOwed(g, mirror: mirror),
          "RomM asks for the save's bytes a push already sent: refused, still owed")
}

section("names")
check(SavePush.ownName("Game [2026-11-26 20-17-03-123] [2026-11-26_20-17-04-848].state") == "Game [2026-11-26 20-17-03-123].state"
      && SavePush.ownName("Game [2026-11-26_20-17-04].srm") == "Game.srm" && SavePush.ownName("Game [x].srm") == "Game [x].srm",
      "RomM's own time taken off a name it stored, its milliseconds optional")
check(SavePush.stateNameMs("Game [2026-11-26 20-17-03-123].state") == 1_795_724_223_123
      && SavePush.stateNameMs("Game.state") == 0, "when a state was made, by the time in its name")

try? FileManager.default.removeItem(at: scratch)
print("\n\(passes) passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)
