import Foundation

/// The nested object RomM attaches to a save or a state: a nullable
/// `screenshot` whose `download_path` resolves like any other asset path.
/// Confirmed against the live server's OpenAPI schema.
private struct AssetScreenshot: Decodable {
    let downloadPath: String
    enum CodingKeys: String, CodingKey { case downloadPath = "download_path" }
}

/// A saved game, the cartridge battery kind. Survives changing cores.
struct GameSave: Decodable, Identifiable, Hashable {
    let id: Int
    let fileName: String
    let updatedAt: String?
    let emulator: String?
    let screenshotPath: String?

    enum CodingKeys: String, CodingKey {
        case id
        case fileName = "file_name"
        case updatedAt = "updated_at"
        case emulator
        case screenshot
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        fileName = try container.decode(String.self, forKey: .fileName)
        updatedAt = try container.decodeIfPresent(String.self, forKey: .updatedAt)
        emulator = try container.decodeIfPresent(String.self, forKey: .emulator)
        screenshotPath = try container.decodeIfPresent(AssetScreenshot.self, forKey: .screenshot)?.downloadPath
    }
}

/// A save state, a snapshot of memory. Tied to the core that wrote it, which
/// is why the launch screen greys out states from a different emulator rather
/// than letting someone load one that cannot work. Its screenshot is a real
/// frame from the moment saved.
struct GameState: Decodable, Identifiable, Hashable {
    let id: Int
    let fileName: String
    let updatedAt: String?
    let emulator: String?
    let screenshotPath: String?

    enum CodingKeys: String, CodingKey {
        case id
        case fileName = "file_name"
        case updatedAt = "updated_at"
        case emulator
        case screenshot
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        fileName = try container.decode(String.self, forKey: .fileName)
        updatedAt = try container.decodeIfPresent(String.self, forKey: .updatedAt)
        emulator = try container.decodeIfPresent(String.self, forKey: .emulator)
        screenshotPath = try container.decodeIfPresent(AssetScreenshot.self, forKey: .screenshot)?.downloadPath
    }

    /// A state that exists on this screen because `KeptGameStore`
    /// downloaded it, not because the server was just asked. Built
    /// straight from the kept game's manifest so the Resume-from list
    /// carries a real, selectable row with zero network, whether that is
    /// the only state available (offline) or one already covered by a
    /// fresher live fetch (online, where it is filtered out instead, see
    /// `GameLaunchView.load`). No filename or screenshot: nothing local
    /// stores either, and the row degrades to a plain date-only entry
    /// with no Screenshot option, which the row menu already handles.
    init(localStateId: Int, updatedAt: String?, emulator: String) {
        id = localStateId
        fileName = ""
        self.updatedAt = updatedAt
        self.emulator = emulator
        screenshotPath = nil
    }
}

/// A BIOS file the platform may require. The app never manages these, it only
/// picks among what the server reports.
struct Firmware: Decodable, Identifiable, Hashable {
    let id: Int
    let fileName: String
    let isVerified: Bool
    let missingFromFS: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case fileName = "file_name"
        case isVerified = "is_verified"
        case missingFromFS = "missing_from_fs"
    }
}
