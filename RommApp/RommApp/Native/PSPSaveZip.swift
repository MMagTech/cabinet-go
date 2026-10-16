import Foundation

/// PSP saves as CabinetOS writes them, so a save made on either crosses to
/// the other (docs/scope-handheld.md, continuity).
///
/// A PSP save is a folder, `PSP/SAVEDATA/<GAMEID><NAME>/` with PARAM.SFO,
/// DATA.BIN and the icons, and RomM stores one file per save, so it
/// travels as a zip. CabinetOS (frontend/src/dirsave.h) roots that zip at
/// SAVEDATA: the first path component is the save folder itself,
/// `ULUS10002LUMINES/PARAM.SFO`, which is what any PSP save download looks
/// like and what opens in any unzip tool. The row is named after the game,
/// `<title>.zip`, with the title cleaned the way CabinetOS cleans it
/// (SaveRowNames.sanitisedStem), so both apps write the same row. RomM 5.4
/// matches an overwrite on emulator tag and file name together, and a
/// different name on each side would leave two rows forever.
///
/// Written here rather than through NSFileCoordinator's `.forUploading`,
/// which always makes the folder it is handed the archive's top entry and
/// so cannot write a zip whose root holds several folders. Entries are
/// stored, not compressed: every zip reader accepts the stored method,
/// PSP saves are small, and it needs nothing beyond Foundation.
enum PSPSaveZip {
    /// The server row's file name for a game's PSP save.
    static func rowName(title: String) -> String {
        SaveRowNames.sanitisedStem(title) + ".zip"
    }

    /// Every file under `saveData`, zipped with paths relative to it.
    /// Sorted, with each file's own modification time, so an unchanged
    /// folder zips to identical bytes and is not uploaded again.
    static func archive(saveData: URL) -> Data? {
        let fm = FileManager.default
        guard let walker = fm.enumerator(
            at: saveData, includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey]
        ) else { return nil }
        var files: [(path: String, url: URL)] = []
        let base = saveData.standardizedFileURL.path + "/"
        for case let url as URL in walker {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
            else { continue }
            let full = url.standardizedFileURL.path
            guard full.hasPrefix(base) else { continue }
            files.append((String(full.dropFirst(base.count)), url))
        }
        guard !files.isEmpty else { return nil }
        files.sort { $0.path < $1.path }

        var zip = Data()
        var central = Data()
        for file in files {
            guard let contents = try? Data(contentsOf: file.url) else { return nil }
            let name = Data(file.path.utf8)
            let modified = (try? file.url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? Date(timeIntervalSince1970: 315_532_800)
            let (dosTime, dosDate) = dosDateTime(modified)
            let crc = crc32(contents)
            let offset = UInt32(zip.count)

            zip.append(le32(0x0403_4B50))       // local file header
            zip.append(le16(20))                 // version needed
            zip.append(le16(0x0800))             // names are UTF-8
            zip.append(le16(0))                  // stored
            zip.append(le16(dosTime))
            zip.append(le16(dosDate))
            zip.append(le32(crc))
            zip.append(le32(UInt32(contents.count)))
            zip.append(le32(UInt32(contents.count)))
            zip.append(le16(UInt16(name.count)))
            zip.append(le16(0))
            zip.append(name)
            zip.append(contents)

            central.append(le32(0x0201_4B50))   // central directory entry
            central.append(le16(20))             // made by
            central.append(le16(20))             // version needed
            central.append(le16(0x0800))
            central.append(le16(0))
            central.append(le16(dosTime))
            central.append(le16(dosDate))
            central.append(le32(crc))
            central.append(le32(UInt32(contents.count)))
            central.append(le32(UInt32(contents.count)))
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
        zip.append(le16(UInt16(files.count)))
        zip.append(le16(UInt16(files.count)))
        zip.append(le32(UInt32(central.count)))
        zip.append(le32(centralOffset))
        zip.append(le16(0))
        return zip
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
