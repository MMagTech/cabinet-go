import Foundation

/// The URL that opens Cabinet at a particular game.
///
/// `cabinet://play?rom=123` boots the game, `cabinet://game?rom=123` opens
/// its launch screen. Two URLs rather than one carrying a flag, so a link
/// is readable on sight in a log or a crash report.
///
/// The widget writes it, Spotlight results carry it, and the app's deep
/// link handler reads it, and the widget extension does not compile the
/// app's files. One definition, compiled into both, so a change cannot
/// reach one and miss the other.
enum CabinetLink {
    static let scheme = "cabinetgo"

    static func play(romId: Int) -> URL? { url(host: "play", romId: romId) }
    static func game(romId: Int) -> URL? { url(host: "game", romId: romId) }

    private static func url(host: String, romId: Int) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.queryItems = [URLQueryItem(name: "rom", value: String(romId))]
        return components.url
    }

    /// What the app got handed. Nil for anything that is not one of ours,
    /// including a well-formed URL carrying a rom id that is not a number.
    static func parse(_ url: URL) -> (romId: Int, startsPlaying: Bool)? {
        guard url.scheme == scheme,
              let host = url.host,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let raw = components.queryItems?.first(where: { $0.name == "rom" })?.value,
              let romId = Int(raw)
        else { return nil }

        switch host {
        case "play": return (romId, true)
        case "game": return (romId, false)
        default: return nil
        }
    }
}
