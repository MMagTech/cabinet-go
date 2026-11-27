import SwiftUI

/// Collections hidden from this phone's Library, by id.
///
/// Stored on the phone only, the way the Incompatible mark is: RomM, the
/// console and every other device keep the collection exactly as it is.
/// The reason it exists is a collection that is right for the console and
/// thin here, one or two games once the Library keeps only what the phone
/// plays.
enum HiddenCollections {
    private static let key = "com.mmagtech.RommApp.hiddenCollections"

    static func load() -> Set<Int> {
        Set(UserDefaults.standard.array(forKey: key) as? [Int] ?? [])
    }

    static func save(_ ids: Set<Int>) {
        UserDefaults.standard.set(Array(ids), forKey: key)
    }
}

/// The collections someone hid. Each still opens, and Unhide puts it back
/// in the Library.
struct HiddenCollectionsView: View {
    /// Every collection the Library would show, hidden or not.
    let collections: [Collection]
    let counts: [Int: Int]
    @Binding var hiddenIDs: Set<Int>

    private var hidden: [Collection] {
        collections.filter { hiddenIDs.contains($0.id) }
    }

    var body: some View {
        List {
            if hidden.isEmpty {
                Text("Nothing hidden.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(hidden) { collection in
                    NavigationLink {
                        RomListView(source: .collection(collection))
                    } label: {
                        HStack {
                            Text(collection.name)
                            Spacer()
                            Text("\(counts[collection.id] ?? collection.romCount)")
                                .foregroundStyle(.secondary)
                                .font(.callout.monospacedDigit())
                        }
                    }
                    .contextMenu {
                        Button("Unhide", systemImage: "eye") { unhide(collection.id) }
                    }
                    .swipeActions {
                        Button("Unhide") { unhide(collection.id) }
                            .tint(.accentColor)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Hidden")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func unhide(_ id: Int) {
        hiddenIDs.remove(id)
        HiddenCollections.save(hiddenIDs)
    }
}
