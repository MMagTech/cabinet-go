import Foundation

/// Whether the player's last session ended on purpose.
///
/// A core crash takes the whole app, so the only witness is a note left behind: set while a native game runs, cleared on
/// every deliberate exit, checked at the next launch. A note alone is not
/// a crash, though. iOS evicts backgrounded apps routinely and that is not
/// the core's fault, so the note also records whether the app ever left
/// the foreground mid-game. Died in the foreground means the core (or the
/// app around it) went down mid-play, and that is what gets counted.
enum NativeSessionMarker {
    private static let runningKey = "com.mmagtech.RommApp.nativeGameInProgress"
    private static let backgroundedKey = "com.mmagtech.RommApp.nativeGameBackgrounded"

    static func recordGameRunning(romId: Int) {
        UserDefaults.standard.set(romId, forKey: runningKey)
        UserDefaults.standard.removeObject(forKey: backgroundedKey)
    }

    static func recordBackgrounded() {
        guard UserDefaults.standard.object(forKey: runningKey) != nil else { return }
        UserDefaults.standard.set(true, forKey: backgroundedKey)
    }

    static func recordCleanExit() {
        UserDefaults.standard.removeObject(forKey: runningKey)
        UserDefaults.standard.removeObject(forKey: backgroundedKey)
    }

    /// Called once at app launch. Counts a native crash only for a session
    /// that died without ever leaving the foreground, then clears the note
    /// either way so one death is never counted twice.
    @MainActor
    static func settleAtLaunch() {
        guard UserDefaults.standard.object(forKey: runningKey) != nil else { return }
        let romId = UserDefaults.standard.integer(forKey: runningKey)
        let wasBackgrounded = UserDefaults.standard.bool(forKey: backgroundedKey)
        if !wasBackgrounded {
            Compatibility.shared.recordCrash(romId: romId)
        }
        recordCleanExit()
    }
}
