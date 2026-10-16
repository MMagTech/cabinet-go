import SwiftUI

/// Everything this app keeps on disk: the games kept on the phone, the
/// offline promise. The web player's cache that used to share this screen
/// left with the web player (docs/scope-handheld.md). Formerly CacheView,
/// renamed when kept games arrived, since Storage is what iOS itself calls
/// this job.
struct StorageView: View {
    @ObservedObject private var keptStore = KeptGameStore.shared
    @State private var searchText = ""

    /// A kept library can run long enough that scrolling to find one game
    /// stops being reasonable, even though the list itself renders fine at
    /// any size, `List` is already lazy.
    private var filteredKeptGames: [KeptGame] {
        guard !searchText.isEmpty else { return keptStore.games }
        return keptStore.games.filter { $0.displayName.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        List {
            // The total first, before the itemized list, matching iOS's own
            // iPhone Storage screen. A plain number, never a bar: kept games
            // have no ceiling to show progress against, that is the design.
            if keptStore.totalBytes > 0 {
                Section {
                    HStack {
                        Text("Kept")
                        Spacer()
                        Text(byteCount(keptStore.totalBytes)).foregroundStyle(.secondary)
                    }
                }
            }

            // A platform coming down, with its cancel, above the
            // games it has landed so far.
            if keptStore.bulk != nil {
                Section { DownloadAllStatusContent() }
            }
            if keptStore.games.isEmpty {
                Section {
                    Text("Nothing kept yet. Turn on Download on a game's page to copy it in and play it without a download next time.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else if !filteredKeptGames.isEmpty {
                Section {
                    ForEach(filteredKeptGames) { game in
                        HStack(spacing: 12) {
                            Image(systemName: "internaldrive")
                                .foregroundStyle(.secondary)
                                .frame(width: 22)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(game.displayName)
                                    .lineLimit(1)
                                Text(byteCount(game.totalBytes))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                let pending = keptStore.pendingStateCount(for: game.romId)
                                if pending > 0 {
                                    Text("\(pending) save\(pending == 1 ? "" : "s") waiting to upload")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                if MemoryCardStore.shared.anyPendingUpload(romId: game.romId) {
                                    Text("In-game save waiting to upload")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .swipeActions {
                            Button("Remove", role: .destructive) {
                                keptStore.remove(romId: game.romId)
                            }
                        }
                    }
                } header: {
                    Text("Kept games")
                } footer: {
                    Text("These files also appear in the Files app, laid out like your RomM library; copy them to other apps from there. Deleting one there removes it here too. Nothing clears on its own.")
                }
            }
        }
        .navigationTitle("Storage")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "Find a kept game")
        .task { keptStore.reconcileFilesFolder() }
    }

    private func byteCount(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
