import Foundation

/// The names this app gives its rows on RomM, built exactly the way
/// CabinetOS builds them, so a save made on either app lands in the same
/// row (docs/scope-handheld.md, continuity). RomM 5.4 matches an
/// overwrite on emulator tag and file name together, so a name that
/// differs by one character keeps a second row forever.
enum SaveRowNames {
    /// The stem of a battery, card or clock row, `<stem> (Cabinet).srm`:
    /// RomM's `fs_name` with everything from its last dot removed, then
    /// cleaned by `sanitisedStem`. CabinetOS's `fsStem` (frontend/src/
    /// main.cpp, where a launch job is built) and its `saveRowName`.
    /// Deliberately not RomM's own `fs_name_no_ext`, which can strip a
    /// different amount, or nothing.
    static func stem(fsName: String) -> String {
        var name = fsName
        if let dot = name.lastIndex(of: ".") { name = String(name[..<dot]) }
        return sanitisedStem(name)
    }

    /// CabinetOS's `sanitisedStem` (frontend/src/main.cpp), byte for byte:
    /// ASCII letters, digits and `- _().,'` and space are kept, any byte
    /// above ASCII is kept so UTF-8 names survive, everything else becomes
    /// an underscore, trailing spaces and dots are dropped, and an empty
    /// result is "game".
    static func sanitisedStem(_ text: String) -> String {
        let kept: Set<UInt8> = [0x2D, 0x20, 0x5F, 0x28, 0x29, 0x2E, 0x2C, 0x27]
        var out: [UInt8] = []
        for byte in Array(text.utf8) {
            let isAlnum = (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A)
                || (byte >= 0x61 && byte <= 0x7A)
            out.append(byte >= 0x80 || isAlnum || kept.contains(byte) ? byte : 0x5F)
        }
        while let last = out.last, last == 0x20 || last == 0x2E { out.removeLast() }
        return out.isEmpty ? "game" : String(decoding: out, as: UTF8.self)
    }
}
