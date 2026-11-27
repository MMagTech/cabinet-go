import Foundation
import UIKit

/// The VMU minigame player's launch and sync path. Deliberately not
/// NativeLauncher: nothing here downloads a ROM, because the "ROM" is
/// the Dreamcast game's own save card. This opens and writes THE SAME card
/// RomM keeps as that game's save, Flycast's under `flycast-native`, so the
/// TV's Flycast takes it as its own: one save, one rule (GameSaves, SavePick);
/// the minigame is cargo inside the save, never a platform or a library
/// entry.
///
/// The local layer's guarantee: the phone's card is always current. The
/// core commits every flash write into the play file in real time
/// (VeMUlator's enable_flash_write, spike-proven), so nothing is lost
/// locally even to an app kill: a play file changed since it was last sent
/// is owed at the next start, before the pick (GameSaves). The card goes up
/// on quit and on backgrounding.
enum VMULauncher {
    /// The live play file. Its whole directory chain is deliberately
    /// dot-free: VeMUlator identifies the file type by the dot in the
    /// path (patched to the LAST dot in build-core.sh, still worth not
    /// tempting), and anything but ".bin" loads as nothing, no flash
    /// image, no write-through, no error.
    static func playCardURL(romId: Int) -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = support
            .appendingPathComponent("VMUCards", isDirectory: true)
            .appendingPathComponent("rom_\(romId)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("card.bin")
    }

    /// The card that would boot if the VMU row were tapped right now: the
    /// play file, which the start's pick keeps as the newest card the phone
    /// can use. What the launch screen parses for the minigame row, so
    /// detection and boot read the same bytes.
    static func currentCard(romId: Int) -> Data? {
        guard let card = try? Data(contentsOf: playCardURL(romId: romId)), card.count == VMUCard.cardSize
        else { return nil }
        return card
    }

    /// The VMU sitting under way, for its capture.
    @MainActor private static var sitting: GameSaves?

    /// Decides which card plays and places it as the live play file, by the
    /// one rule (GameSaves.startCard): a card owed by the phone stands, else
    /// the newest card RomM holds that the phone can use, else the phone's
    /// own. Returns nil when no card exists anywhere, which the launch
    /// screen's detection has already ruled out on every real path.
    @MainActor
    static func prepare(rom: Rom, session: Session) async -> URL? {
        let target = playCardURL(romId: rom.id)
        sitting = await GameSaves.startCard(rom: rom, cardURL: target, session: session)
        return currentCard(romId: rom.id) != nil ? target : nil
    }

    /// The newest card brought down without playing, for the launch screen's
    /// minigame row: the same start, which is then left at once.
    @MainActor
    static func refresh(rom: Rom, session: Session) async {
        _ = await GameSaves.startCard(rom: rom, cardURL: playCardURL(romId: rom.id), session: session)
    }

    /// The play file gathered and, when it changed, marked and sent. Called
    /// on quit and on backgrounding, with the core paused, so the file is
    /// quiescent when read. No mid-play uploads on purpose: churn without
    /// benefit. Finishes while iOS lets the app.
    @MainActor
    static func capture(rom: Rom, session: Session) async {
        guard let saves = sitting, saves.romId == rom.id else { return }
        saves.gatherFiles()
        guard let sending = saves.leave(session: session) else { return }
        let id = UIApplication.shared.beginBackgroundTask(withName: "Send the VMU card")
        await sending.value
        UIApplication.shared.endBackgroundTask(id)
    }

    /// Boots the core on the placed card. The frontend side of what
    /// NativeLauncher.activate does, minus everything a card does not
    /// need: no firmware, no archive extraction, no controller port
    /// devices. enable_flash_write is the whole point, stated here
    /// rather than defaulted.
    @MainActor
    static func boot(cardURL: URL) -> String? {
        #if targetEnvironment(simulator)
        // Same reasoning as NativeLauncher.activate: no cores link in a
        // simulator build.
        return "Games can't run in the Simulator. Use a real iPhone."
        #else
        LibretroFrontend.shared.activateCore(.vemulator)
        LibretroFrontend.shared.setCoreOptions(["enable_flash_write": "enabled"])
        let dir = cardURL.deletingLastPathComponent().path
        return LibretroFrontend.shared.loadGame(cardURL.path, systemDirectory: dir, saveDirectory: dir)
        #endif
    }
}
