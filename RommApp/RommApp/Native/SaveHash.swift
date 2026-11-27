import CryptoKit
import Foundation

/// RomM's content hash, the name a snapshot gives every save and state in it
/// (`compute_content_hash` in RomM's code at 5.5.0-beta.1), computed the way
/// CabinetOS computes it (frontend/src/romm_snapshots.cpp, contentHash): a
/// file's MD5; a zip's MD5 of its files' `name:md5` lines, sorted by name and
/// joined by newlines, so the same files in any zip hash alike. A push names
/// its parts by it, and RomM refuses one whose bytes do not hash to the name
/// (422), so it must be RomM's to the byte. Its own file because SavePush,
/// SaveMirror and GameSaves each need it.
enum SaveHash {
    /// A lowercase hex MD5, as RomM writes it.
    static func md5(_ data: Data) -> String {
        Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// RomM's hash of `data`: a zip by its files (when it reads as one), any
    /// other bytes as they are.
    static func content(_ data: Data) -> String {
        if SaveZip.looksLikeZip(data), let files = SaveZip.entries(of: data) {
            // Python's `sorted` on the names: by code point, which is the
            // order of their UTF-8 bytes.
            let lines = files
                .map { (name: Array($0.path.utf8), md5: md5($0.data)) }
                .sorted { $0.name.lexicographicallyPrecedes($1.name) }
                .map { String(decoding: $0.name, as: UTF8.self) + ":" + $0.md5 }
                .joined(separator: "\n")
            return md5(Data(lines.utf8))
        }
        return md5(data)
    }
}
