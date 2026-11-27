import Compression
import Foundation

/// Saves as zips, written and read the way CabinetOS writes and reads them,
/// so a save made on either app crosses to the other
/// (docs/scope-handheld.md, continuity). Two saves on the phone travel as a
/// zip: a PSP game's save folders, and a Game Boy battery with its clock
/// beside it (GameSaves). A save from RomM can be one too: another app's
/// save in the phone's form. RomM's content hash of a zip reads the files
/// inside it (SaveHash).
///
/// A PSP save is a folder, `PSP/SAVEDATA/<GAMEID><NAME>/` with PARAM.SFO,
/// DATA.BIN and the icons. CabinetOS (frontend/src/dirsave.h) roots its zip
/// at SAVEDATA: the first path component is the save folder itself,
/// `ULUS10002LUMINES/PARAM.SFO`, which is what any PSP save download looks
/// like and what opens in any unzip tool.
///
/// Written here rather than through NSFileCoordinator's `.forUploading`,
/// which always makes the folder it is handed the archive's top entry and
/// so cannot write a zip whose root holds several folders. Entries are
/// stored, not compressed: every zip reader accepts the stored method and
/// saves are small. Read with Apple's Compression, a system framework, for
/// the deflated entries other tools write.
enum SaveZip {
    /// One file in a zip: its path inside it and its bytes. `modified` is
    /// the time the zip records; nil records 1980-01-01, so the same files
    /// always zip to the same bytes.
    struct Entry: Equatable {
        let path: String
        let data: Data
        var modified: Date?
    }

    /// A zip's first bytes, as CabinetOS checks them (`cab::looksLikeZip`).
    static func looksLikeZip(_ data: Data) -> Bool {
        data.count >= 4 && data.starts(with: [0x50, 0x4B, 0x03, 0x04])
    }

    /// Every file under `saveData`, zipped with paths relative to it,
    /// sorted, with each file's own modification time. Nil when the folder
    /// holds no file.
    static func archive(saveData: URL) -> Data? {
        let fm = FileManager.default
        guard let walker = fm.enumerator(
            at: saveData, includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey]
        ) else { return nil }
        var files: [Entry] = []
        let base = saveData.standardizedFileURL.path + "/"
        for case let url as URL in walker {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
            else { continue }
            let full = url.standardizedFileURL.path
            guard full.hasPrefix(base), let contents = try? Data(contentsOf: url) else { continue }
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            files.append(Entry(path: String(full.dropFirst(base.count)), data: contents, modified: modified))
        }
        guard !files.isEmpty else { return nil }
        files.sort { $0.path < $1.path }
        return zip(files)
    }

    /// The entries, in the order given, as one zip.
    static func zip(_ entries: [Entry]) -> Data {
        var zip = Data()
        var central = Data()
        for file in entries {
            let name = Data(file.path.utf8)
            let (dosTime, dosDate) = dosDateTime(file.modified ?? Date(timeIntervalSince1970: 315_532_800))
            let crc = crc32(file.data)
            let offset = UInt32(zip.count)

            zip.append(le32(0x0403_4B50))       // local file header
            zip.append(le16(20))                 // version needed
            zip.append(le16(0x0800))             // names are UTF-8
            zip.append(le16(0))                  // stored
            zip.append(le16(dosTime))
            zip.append(le16(dosDate))
            zip.append(le32(crc))
            zip.append(le32(UInt32(file.data.count)))
            zip.append(le32(UInt32(file.data.count)))
            zip.append(le16(UInt16(name.count)))
            zip.append(le16(0))
            zip.append(name)
            zip.append(file.data)

            central.append(le32(0x0201_4B50))   // central directory entry
            central.append(le16(20))             // made by
            central.append(le16(20))             // version needed
            central.append(le16(0x0800))
            central.append(le16(0))
            central.append(le16(dosTime))
            central.append(le16(dosDate))
            central.append(le32(crc))
            central.append(le32(UInt32(file.data.count)))
            central.append(le32(UInt32(file.data.count)))
            central.append(le16(UInt16(name.count)))
            central.append(le16(0))              // extra
            central.append(le16(0))              // comment
            central.append(le16(0))              // disk
            central.append(le16(0))              // internal attributes
            central.append(le32(0))              // external attributes
            central.append(le32(offset))
            central.append(name)
        }
        let centralOffset = UInt32(zip.count)
        zip.append(central)
        zip.append(le32(0x0605_4B50))            // end of central directory
        zip.append(le16(0))
        zip.append(le16(0))
        zip.append(le16(UInt16(entries.count)))
        zip.append(le16(UInt16(entries.count)))
        zip.append(le32(UInt32(central.count)))
        zip.append(le32(centralOffset))
        zip.append(le16(0))
        return zip
    }

    /// The files in a zip, folders left out, each named as RomM's Python
    /// reads the name: as UTF-8 when the zip marks it so, else as CP437 (a
    /// Shift-JIS name, say). Nil when it is no zip this can read: no end
    /// record, a part out of bounds, a method other than stored or deflate,
    /// or bytes that do not inflate to their size.
    static func entries(of zip: Data) -> [Entry]? {
        let bytes = [UInt8](zip)
        guard bytes.count >= 22 else { return nil }
        var end = -1
        var at = bytes.count - 22
        let floor = max(0, bytes.count - 65_557)
        while at >= floor {
            if bytes[at] == 0x50, bytes[at + 1] == 0x4B, bytes[at + 2] == 0x05, bytes[at + 3] == 0x06 {
                end = at
                break
            }
            at -= 1
        }
        guard end >= 0 else { return nil }
        let count = Int(u16(bytes, end + 10))
        var entry = Int(u32(bytes, end + 16))
        var out: [Entry] = []
        for _ in 0..<count {
            guard entry + 46 <= bytes.count, u32(bytes, entry) == 0x0201_4B50 else { return nil }
            let flags = u16(bytes, entry + 8)
            let method = u16(bytes, entry + 10)
            let packed = Int(u32(bytes, entry + 20))
            let size = Int(u32(bytes, entry + 24))
            let nameLength = Int(u16(bytes, entry + 28))
            let extraLength = Int(u16(bytes, entry + 30))
            let commentLength = Int(u16(bytes, entry + 32))
            let local = Int(u32(bytes, entry + 42))
            guard entry + 46 + nameLength <= bytes.count else { return nil }
            let rawName = Array(bytes[(entry + 46)..<(entry + 46 + nameLength)])
            entry += 46 + nameLength + extraLength + commentLength
            let name = flags & 0x0800 != 0
                ? String(decoding: rawName, as: UTF8.self) : fromCP437(rawName)
            if name.isEmpty || name.hasSuffix("/") { continue }

            guard local + 30 <= bytes.count, u32(bytes, local) == 0x0403_4B50 else { return nil }
            let start = local + 30 + Int(u16(bytes, local + 26)) + Int(u16(bytes, local + 28))
            guard start + packed <= bytes.count else { return nil }
            let stored = Data(bytes[start..<(start + packed)])
            switch method {
            case 0:
                guard stored.count == size else { return nil }
                out.append(Entry(path: name, data: stored))
            case 8:
                guard let inflated = inflate(stored, size: size) else { return nil }
                out.append(Entry(path: name, data: inflated))
            default:
                return nil
            }
        }
        return out
    }

    /// Raw DEFLATE (RFC 1951), which is what Compression calls ZLIB.
    private static func inflate(_ packed: Data, size: Int) -> Data? {
        if size == 0 { return Data() }
        var out = Data(count: size)
        let written = out.withUnsafeMutableBytes { dst -> Int in
            packed.withUnsafeBytes { src -> Int in
                guard let d = dst.bindMemory(to: UInt8.self).baseAddress,
                      let s = src.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(d, size, s, packed.count, nil, COMPRESSION_ZLIB)
            }
        }
        return written == size ? out : nil
    }

    private static func u16(_ b: [UInt8], _ at: Int) -> UInt16 {
        UInt16(b[at]) | UInt16(b[at + 1]) << 8
    }

    private static func u32(_ b: [UInt8], _ at: Int) -> UInt32 {
        UInt32(b[at]) | UInt32(b[at + 1]) << 8 | UInt32(b[at + 2]) << 16 | UInt32(b[at + 3]) << 24
    }

    /// Python's CP437 for the bytes from 0x80 up (those below are ASCII):
    /// what RomM's zipfile makes of a name a zip does not mark as UTF-8.
    /// CabinetOS's table (frontend/src/romm_snapshots.cpp, kCp437High).
    private static let cp437High: [UInt16] = [
        0x00C7, 0x00FC, 0x00E9, 0x00E2, 0x00E4, 0x00E0, 0x00E5, 0x00E7,
        0x00EA, 0x00EB, 0x00E8, 0x00EF, 0x00EE, 0x00EC, 0x00C4, 0x00C5,
        0x00C9, 0x00E6, 0x00C6, 0x00F4, 0x00F6, 0x00F2, 0x00FB, 0x00F9,
        0x00FF, 0x00D6, 0x00DC, 0x00A2, 0x00A3, 0x00A5, 0x20A7, 0x0192,
        0x00E1, 0x00ED, 0x00F3, 0x00FA, 0x00F1, 0x00D1, 0x00AA, 0x00BA,
        0x00BF, 0x2310, 0x00AC, 0x00BD, 0x00BC, 0x00A1, 0x00AB, 0x00BB,
        0x2591, 0x2592, 0x2593, 0x2502, 0x2524, 0x2561, 0x2562, 0x2556,
        0x2555, 0x2563, 0x2551, 0x2557, 0x255D, 0x255C, 0x255B, 0x2510,
        0x2514, 0x2534, 0x252C, 0x251C, 0x2500, 0x253C, 0x255E, 0x255F,
        0x255A, 0x2554, 0x2569, 0x2566, 0x2560, 0x2550, 0x256C, 0x2567,
        0x2568, 0x2564, 0x2565, 0x2559, 0x2558, 0x2552, 0x2553, 0x256B,
        0x256A, 0x2518, 0x250C, 0x2588, 0x2584, 0x258C, 0x2590, 0x2580,
        0x03B1, 0x00DF, 0x0393, 0x03C0, 0x03A3, 0x03C3, 0x00B5, 0x03C4,
        0x03A6, 0x0398, 0x03A9, 0x03B4, 0x221E, 0x03C6, 0x03B5, 0x2229,
        0x2261, 0x00B1, 0x2265, 0x2264, 0x2320, 0x2321, 0x00F7, 0x2248,
        0x00B0, 0x2219, 0x00B7, 0x221A, 0x207F, 0x00B2, 0x25A0, 0x00A0,
    ]

    private static func fromCP437(_ raw: [UInt8]) -> String {
        var scalars = String.UnicodeScalarView()
        for b in raw {
            let code = b < 0x80 ? UInt32(b) : UInt32(cp437High[Int(b) - 0x80])
            if let s = Unicode.Scalar(code) { scalars.append(s) }
        }
        return String(scalars)
    }

    private static func le16(_ v: UInt16) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
    private static func le32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }

    private static func dosDateTime(_ date: Date) -> (UInt16, UInt16) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year = max((c.year ?? 1980) - 1980, 0)
        let time = UInt16(((c.hour ?? 0) << 11) | ((c.minute ?? 0) << 5) | ((c.second ?? 0) / 2))
        let day = UInt16((year << 9) | ((c.month ?? 1) << 5) | (c.day ?? 1))
        return (time, day)
    }

    private static let crcTable: [UInt32] = (0..<256).map { n in
        var c = UInt32(n)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data { crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFF_FFFF
    }
}
