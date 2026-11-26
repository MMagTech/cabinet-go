import Foundation

/// Whether touch controls are drawn as moulded objects or flat shapes.
///
/// One switch, on or off, and deliberately nothing in between (decided
/// 2026-08-24): on is everything and off is nothing. In-between
/// combinations would mean a bunch more settings, which breaks the idea
/// of keeping Cabinet simple.
///
/// It is also the whole accessibility answer here. Moulding leans on
/// subtle shading, and shading is exactly what is hard to read for
/// someone who needs more contrast, so off draws precisely what
/// shipped before any of it existed: flat fills with an outline. One
/// row beside the visibility slider a person already knows, rather
/// than Cabinet inspecting half a dozen system switches and guessing
/// which of them should flatten a d-pad.
enum RaisedControls {
    static let key = "com.mmagtech.RommApp.raisedControls"

    static var isOn: Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? true
    }
}
