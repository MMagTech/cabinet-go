import Foundation

/// Daily-stable cover picks for the library's artwork tiles.
///
/// Covers are chosen at a random offset into each platform or collection
/// rather than from its first page, so a 141 game arcade set shows genuine
/// deep cuts instead of whatever sorts first alphabetically. The pick is
/// seeded by (id, day) rather than actually random: the same tile must
/// resolve to the same covers all day, or `CoverCache`'s disk store buys
/// nothing and the art pops in fresh on every visit. A new day rolls a
/// new pick.
enum LibraryTileArt {
    /// How many covers a finished tile carries. Anything short of this is
    /// treated as an incomplete result: not stored, and refetched next
    /// launch rather than cached as though it were correct.
    static let coversPerTile = 6

    /// Bumped whenever the art selection logic changes. Without it a
    /// stored pick from an earlier build keeps being restored for the rest
    /// of the day and the new logic never runs, which is exactly how a
    /// fixed Atari 7800 tile kept coming back with one cover.
    private static let schema = 3

    /// The day the art was last rolled, as a whole number of days.
    static var today: Int {
        Int(Date().timeIntervalSince1970 / 86_400)
    }

    /// Mosaic dictionary keys, namespaced so a platform can never collide
    /// with a collection that happens to share its integer id.
    static func key(platform: Platform) -> String { "p\(platform.id)" }
    static func key(collection: Collection) -> String { "c\(collection.id)" }

    /// Cover paths chosen on a previous launch, or empty if the stored
    /// pick is from another day. Restored before any network call so tiles
    /// are painted from the disk cache immediately; only a genuinely new
    /// roll has to wait on the server. Paths are short strings, a few KB
    /// for a whole library.
    ///
    /// The namespace keeps each screen on its own storage keys. The
    /// library uses "ios", the key its picks are already stored under.
    static func restore(namespace: String) -> [String: [String]] {
        let defaults = UserDefaults.standard
        guard defaults.integer(forKey: dayKey(namespace)) == today,
              let stored = defaults.dictionary(forKey: artKey(namespace)) as? [String: [String]]
        else { return [:] }
        // A failed request stores nothing (`load` keeps only non-empty
        // picks), so anything stored is settled for the day, including a
        // small collection that only has a cover or two to give.
        return stored.filter { !$0.value.isEmpty }
    }

    static func persist(_ mosaics: [String: [String]], namespace: String) {
        let defaults = UserDefaults.standard
        defaults.set(
            mosaics.filter { !$0.value.isEmpty },
            forKey: artKey(namespace)
        )
        defaults.set(today, forKey: dayKey(namespace))
    }

    /// Fetches covers for every tile not already present in `existing`.
    /// Per tile, not all or nothing: a tile that was restored incomplete,
    /// or a platform never seen, gets its own request without disturbing
    /// the ones already settled. Returns only the new entries; the caller
    /// merges and persists.
    /// `collectionCounts` is each collection's playable count, which is
    /// what the cover offset has to stay inside: RomM's own count includes
    /// games on systems this app does not play, and the app never asks
    /// for those.
    static func load(
        platforms: [Platform],
        collections: [Collection],
        collectionCounts: [Int: Int],
        existing: [String: [String]],
        session: Session
    ) async -> [String: [String]] {
        let day = today
        let wantPlatforms = platforms.filter { existing[key(platform: $0)] == nil }
        let wantCollections = collections.filter { existing[key(collection: $0)] == nil }
        guard !wantPlatforms.isEmpty || !wantCollections.isEmpty else { return [:] }

        var fresh: [String: [String]] = [:]
        await withTaskGroup(of: (String, [String]).self) { group in
            for platform in wantPlatforms {
                group.addTask {
                    let offset = seededOffset(id: platform.id, day: day, count: platform.romCount)
                    let paths = await covers(
                        offset: offset, session: session, platformId: platform.id, collectionId: nil
                    )
                    return (key(platform: platform), paths)
                }
            }
            for collection in wantCollections {
                group.addTask {
                    let count = collectionCounts[collection.id] ?? collection.romCount
                    let offset = seededOffset(id: collection.id, day: day, count: count)
                    let paths = await covers(
                        offset: offset, session: session, platformId: nil, collectionId: collection.id
                    )
                    return (key(collection: collection), paths)
                }
            }
            for await (key, paths) in group where !paths.isEmpty {
                fresh[key] = paths
            }
        }
        return fresh
    }

    /// One tile's covers, from a platform or a collection.
    ///
    /// First the day's window of matched games: matchedOnly returns only
    /// games with art, so the covers asked for are the covers shown. The
    /// offset is chosen from the tile's full count, though, and when some
    /// of its games are unmatched the matched list is shorter, so the
    /// window can fall past its end and come back empty: Beat 'em Ups on
    /// the reference server has 24 games the phone plays and 11 matched,
    /// and drew no art. Then the first matched games. Last, any game with
    /// art at all, for a library of hand-uploaded covers with no metadata
    /// match: Game & Watch's 59 all have art and none had a match.
    private static func covers(
        offset: Int, session: Session, platformId: Int?, collectionId: Int?
    ) async -> [String] {
        func window(_ offset: Int, _ limit: Int, matched: Bool) async -> [String] {
            let page = try? await session.roms(
                platformId: platformId, collectionId: collectionId,
                limit: limit, offset: offset, matchedOnly: matched
            )
            return page?.items.compactMap(\.pathCoverSmall) ?? []
        }
        var paths = await window(offset, coversPerTile, matched: true)
        if paths.isEmpty, offset > 0 {
            paths = await window(0, coversPerTile, matched: true)
        }
        if paths.isEmpty {
            paths = Array(await window(0, 12, matched: false).prefix(coversPerTile))
        }
        return paths
    }

    /// A stable pseudo-random offset. Deliberately not `Int.random`: the
    /// same tile must resolve to the same offset every time it is asked
    /// today, and to a different one tomorrow.
    /// Leaves room for a full tile's covers after the offset.
    static func seededOffset(id: Int, day: Int, count: Int) -> Int {
        guard count > coversPerTile else { return 0 }
        var seed = UInt64(truncatingIfNeeded: id &* 2_654_435_761 &+ day &* 40_503)
        seed ^= seed << 13
        seed ^= seed >> 7
        seed ^= seed << 17
        return Int(seed % UInt64(count - coversPerTile + 1))
    }

    private static func artKey(_ namespace: String) -> String {
        "com.mmagtech.RommApp.\(namespace).tileArt.v\(schema)"
    }

    private static func dayKey(_ namespace: String) -> String {
        "com.mmagtech.RommApp.\(namespace).tileArtDay.v\(schema)"
    }
}
