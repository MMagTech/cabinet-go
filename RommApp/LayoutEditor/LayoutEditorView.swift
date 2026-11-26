import SwiftUI
import UIKit

/// One layout, being edited at the size and in the place the player would
/// actually draw it.
///
/// The geometry here is copied from `NativePlayerView.body` deliberately, and
/// has to stay copied: portrait keeps a canvas above a 330pt control strip
/// and normalises the pad against *the strip, plus its own headroom* when a
/// layout asks for one, landscape overlays the pad on the whole screen and
/// normalises against *the screen*. Get that wrong and every number the
/// editor produces is wrong by the ratio between the two, which is exactly
/// the class of mistake that made editing these files by hand unpleasant in
/// the first place.
struct LayoutEditorView: View {
    @Environment(\.dismiss) private var dismiss

    @State var layout: EditableLayout
    /// The layout exactly as it was when this screen opened. Closing
    /// used to save a working copy UNCONDITIONALLY, so merely LOOKING at
    /// a layout forked a private snapshot of it, and that snapshot then
    /// shadowed every newer bundled version forever. Fifty-two arcade
    /// screens were shadowed that way by one browsing session, and each
    /// looked stale with nothing anywhere saying why. Marcus, 2026-08-25:
    /// "something isn't right with the app that I keep getting confused."
    /// He was right. Now a working copy is written only when the layout
    /// actually changed.
    @State private var opened: String = ""
    /// A working copy from an earlier session is hiding a newer bundled
    /// layout underneath this screen. Offer the way out, visibly, instead
    /// of leaving it to a menu item nobody knows to look for.
    @State private var shadowingNewer = false
    @State private var selection: Set<UUID> = []
    @State private var testing = false
    @State private var showsExtended = true
    @State private var showsWarnings = true
    @State private var showsChrome = true
    @State private var share: ShareItem?
    @State private var note: String?
    @State private var ready = false

    /// The same height `NativePlayerView.controlStripHeight` returns.
    private static let stripHeight: CGFloat = 330

    /// Mirrors the player's `padHeight` exactly: zero headroom reproduces
    /// `stripHeight` unchanged, so every layout that has never asked for
    /// headroom edits at the same size it always has.
    private var padPortraitHeight: CGFloat {
        Self.stripHeight * (1 + (layout.headroom ?? 0))
    }

    var body: some View {
        GeometryReader { geo in
            let landscape = geo.size.width > geo.size.height
            let padSize = landscape
                ? geo.size
                : CGSize(width: geo.size.width, height: padPortraitHeight)

            // Portrait's controls live in the bottom strip only, so a
            // top-pinned toolbar never covers anything. Landscape's controls
            // flank the full screen, shoulders and Menu are routinely
            // anchored right at the top edge, and a top toolbar sits
            // directly on top of them. Anchoring the chrome to whichever
            // edge is actually clear per orientation, rather than a fixed
            // spot, is what keeps it from blocking the thing it's meant to
            // help edit.
            ZStack(alignment: landscape ? .bottom : .top) {
                if landscape {
                    ZStack {
                        ScreenBackdrop(layout: layout.name)
                        EditorGrid(area: CGRect(origin: .zero, size: geo.size))
                        pad(size: padSize, landscape: true)
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                } else {
                    ZStack(alignment: .top) {
                        ScreenBackdrop(layout: layout.name)
                            .frame(height: max(geo.size.height - Self.stripHeight, 0))
                        // Portrait layouts are normalised against the
                        // strip, not the screen, so the grid measures
                        // the strip or it measures nothing useful.
                        EditorGrid(area: CGRect(
                            x: 0, y: geo.size.height - padPortraitHeight,
                            width: geo.size.width, height: padPortraitHeight))
                        pad(size: padSize, landscape: false)
                            .frame(height: padPortraitHeight)
                            .frame(maxHeight: .infinity, alignment: .bottom)
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                }

                if landscape, layout.landscapeItems == nil {
                    missingLandscapeNotice
                }
                if showsChrome {
                    chrome(landscape: landscape, padSize: padSize)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .background(Color.black.ignoresSafeArea())
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .onAppear {
            ready = WorkingCopy.isReady(layout.name)
            detectShadow()
        }
        .sheet(item: $share) { item in
            ActivityView(url: item.url)
        }
        .safeAreaInset(edge: .top) {
            if shadowingNewer {
                shadowBanner
            }
        }
    }

    /// The way out of a stale shadow, in your face rather than in a menu.
    /// "Keep my copy" dismisses for this visit only: the copy stays, and
    /// so does the fact it is hiding something, so the banner returns
    /// next time until one side actually wins.
    private var shadowBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text("An older saved copy is hiding a newer layout.")
                .font(.footnote)
                .foregroundStyle(.white)
            Spacer()
            Button("Use newest") {
                if let bundled = EditableLayout.loadBundled(layout.name) {
                    WorkingCopy.discard(layout.name)
                    layout = bundled
                    selection.removeAll()
                    ready = false
                    detectShadow()
                    flash("Now on the newest layout")
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            Button("Keep my copy") {
                shadowingNewer = false
            }
            .controlSize(.small)
            .tint(.white)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.black.opacity(0.82))
    }

    // MARK: The pad, and the layer that edits it

    private func pad(size: CGSize, landscape: Bool) -> some View {
        let binding = itemsBinding(landscape: landscape)
        return ZStack {
            TouchControlPad(
                items: binding.wrappedValue.map(\.rendered),
                send: { _, _ in },
                system: layout.system,
                // Moulded wherever the app moulds: portrait, whose
                // controls sit on a black strip below the picture rather
                // than over it. Flat in landscape, matching the app
                // exactly, so the editor never flatters a layout the
                // player will draw differently.
                material: !landscape
            )
            // In test mode the real pad takes the touches, so presses light up
            // and haptics fire exactly as they would in a game. In edit mode
            // the canvas above takes them instead.
            .allowsHitTesting(testing)

            if !testing {
                EditCanvas(
                    items: binding,
                    selection: $selection,
                    size: size,
                    showsExtended: showsExtended,
                    showsWarnings: showsWarnings,
                    onCommit: commit
                )
            }

            // A small always present corner button, so hiding the toolbar to
            // see the pad clean is never a one way door. Kept tiny and out of
            // the way rather than a gesture over the whole pad, which would
            // fight the canvas's own drag for every touch.
            if !showsChrome {
                // A plain ZStack centres by default; without an explicit
                // corner alignment this sat dead in the middle of the pad,
                // on top of whatever control happened to be there, instead
                // of tucked out of the way.
                Button { showsChrome = true } label: {
                    Image(systemName: "eye")
                        .font(.system(size: 13))
                        .padding(8)
                        .background(.regularMaterial, in: Circle())
                }
                .padding(10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
    }

    private func itemsBinding(landscape: Bool) -> Binding<[EditableItem]> {
        Binding(
            get: {
                guard landscape else { return layout.items }
                return layout.landscapeItems ?? []
            },
            set: { updated in
                if landscape {
                    layout.landscapeItems = updated
                } else {
                    layout.items = updated
                }
            }
        )
    }

    // MARK: Chrome

    private func chrome(landscape: Bool, padSize: CGSize) -> some View {
        VStack(spacing: 8) {
            toolbar(landscape: landscape)
            if !selection.isEmpty && !testing {
                inspector(landscape: landscape, padSize: padSize)
            }
            if let note {
                Text(note)
                    .font(.caption2)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.regularMaterial, in: Capsule())
            }
        }
        .padding(.horizontal, 12)
        .padding(landscape ? .bottom : .top, 8)
    }

    private func toolbar(landscape: Bool) -> some View {
        HStack(spacing: 14) {
            Button { close() } label: { Image(systemName: "chevron.left") }

            VStack(alignment: .leading, spacing: 1) {
                Text(layout.name).font(.system(size: 13, weight: .semibold, design: .monospaced))
                Text(landscape ? "landscape" : "portrait")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 4)

            Toggle(isOn: $testing) { Image(systemName: "hand.tap") }
                .toggleStyle(.button)
            Button {
                showsExtended.toggle()
            } label: {
                Image(systemName: showsExtended ? "square.dashed" : "square")
            }
            Button {
                showsWarnings.toggle()
            } label: {
                Image(systemName: showsWarnings ? "exclamationmark.triangle.fill" : "exclamationmark.triangle")
            }
            Button { showsChrome = false } label: { Image(systemName: "eye.slash") }

            // The whole "submit" gesture: no network call, no reach into the
            // Mac's filesystem, just a flag on this working copy that says
            // "come get this one." Someone on the Mac side still looks at
            // what changed before it lands anywhere real.
            Button {
                commit()
                ready.toggle()
                WorkingCopy.setReady(layout.name, ready)
                flash(ready ? "Marked ready" : "Unmarked")
            } label: {
                Image(systemName: ready ? "checkmark.seal.fill" : "checkmark.seal")
                    .foregroundStyle(ready ? .green : .primary)
            }

            Menu {
                Button("Share file", systemImage: "square.and.arrow.up") { exportFile() }
                Button("Copy JSON", systemImage: "doc.on.doc") { copyJSON() }
                Button("Snap everything to the grid", systemImage: "grid") { tidy() }
                if selection.count > 1 {
                    Button("Even up the selection", systemImage: "align.horizontal.center") {
                        evenUpSelection()
                    }
                }
                if layout.landscapeItems == nil {
                    Button("Create landscape set from portrait", systemImage: "rectangle.landscape.rotate") {
                        seedLandscape()
                    }
                }
                Divider()
                Button("Revert to bundled", systemImage: "arrow.uturn.backward", role: .destructive) {
                    revert()
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
        .font(.system(size: 15))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func inspector(landscape: Bool, padSize: CGSize) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                Text(selectionTitle)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 2)
                if let single = singleSelected {
                    Text(readout(single.frame))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 12) {
                stepperCluster(
                    icon: "arrow.up.and.down.and.arrow.left.and.right",
                    minus: "minus", plus: "plus",
                    onMinus: { resize(points: -4, landscape: landscape, padSize: padSize) },
                    onPlus: { resize(points: 4, landscape: landscape, padSize: padSize) }
                )
                stepperCluster(
                    icon: "square.dashed",
                    minus: "minus", plus: "plus",
                    onMinus: { repad(points: -4, landscape: landscape, padSize: padSize) },
                    onPlus: { repad(points: 4, landscape: landscape, padSize: padSize) }
                )
                Spacer(minLength: 2)
                nudgePad(landscape: landscape)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func stepperCluster(
        icon: String, minus: String, plus: String,
        onMinus: @escaping () -> Void, onPlus: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 11)).foregroundStyle(.secondary)
            Button(action: onMinus) { Image(systemName: minus) }
            Button(action: onPlus) { Image(systemName: plus) }
        }
        .font(.system(size: 13))
        .buttonStyle(.bordered)
        .controlSize(.mini)
    }

    private func nudgePad(landscape: Bool) -> some View {
        HStack(spacing: 4) {
            Button { nudge(-1, 0, landscape) } label: { Image(systemName: "arrow.left") }
            VStack(spacing: 4) {
                Button { nudge(0, -1, landscape) } label: { Image(systemName: "arrow.up") }
                Button { nudge(0, 1, landscape) } label: { Image(systemName: "arrow.down") }
            }
            Button { nudge(1, 0, landscape) } label: { Image(systemName: "arrow.right") }
        }
        .font(.system(size: 12))
        .buttonStyle(.bordered)
        .controlSize(.mini)
    }

    private var missingLandscapeNotice: some View {
        VStack(spacing: 10) {
            Text("No landscape set")
                .font(.headline)
            Text("The player falls back to the portrait items here, which works but looks wrong.")
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Create one from portrait") {
                seedLandscape()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(20)
        .frame(maxWidth: 320)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        // Centred on its own rather than padded down from the top: the
        // chrome it used to clear now anchors to the bottom in landscape,
        // and a fixed offset tuned for the old position would just as
        // easily land on top of the new one.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Editing actions

    private var singleSelected: EditableItem? {
        guard selection.count == 1 else { return nil }
        return (layout.items + (layout.landscapeItems ?? []))
            .first { selection.contains($0.id) }
    }

    private var selectionTitle: String {
        if let single = singleSelected { return single.displayName }
        return "\(selection.count) selected"
    }

    private func readout(_ rect: EditRect) -> String {
        let n = EditableLayout.number
        return "x \(n(rect.x))  y \(n(rect.y))  w \(n(rect.w))  h \(n(rect.h))"
    }

    /// One grid step in each direction. Nudging translates rather than
    /// snapping each item on its own, so a selected group keeps its shape
    /// even if the file it came from was never on the grid.
    private func nudge(_ sx: Double, _ sy: Double, _ landscape: Bool) {
        let step = EditCanvas.step
        mutate(landscape: landscape) { item in
            item.frame = item.frame.offset(dx: sx * step, dy: sy * step)
            item.extended = item.extended.offset(dx: sx * step, dy: sy * step)
        }
    }

    /// Grows or shrinks about each item's own centre. The step is in points
    /// rather than normalised units on purpose: x and y are normalised
    /// against different pixel dimensions, so a single normalised delta would
    /// squash a round button into an oval.
    private func resize(points: Double, landscape: Bool, padSize: CGSize) {
        let dw = points / Double(padSize.width)
        let dh = points / Double(padSize.height)
        let floorW = EditCanvas.step * 2
        mutate(landscape: landscape) { item in
            let pad = item.padding
            let f = item.frame
            let w = max(f.w + dw, floorW)
            let h = max(f.h + dh, floorW)
            item.frame = EditRect(x: f.midX - w / 2, y: f.midY - h / 2, w: w, h: h)
            item.applyPadding(pad)
        }
    }

    /// Widens or tightens the hit frame around the drawn one, on all sides.
    private func repad(points: Double, landscape: Bool, padSize: CGSize) {
        let dx = points / Double(padSize.width)
        let dy = points / Double(padSize.height)
        mutate(landscape: landscape) { item in
            let pad = item.padding
            item.applyPadding((
                left: max(pad.left + dx, 0), top: max(pad.top + dy, 0),
                right: max(pad.right + dx, 0), bottom: max(pad.bottom + dy, 0)
            ))
        }
    }

    private func mutate(landscape: Bool, _ transform: (inout EditableItem) -> Void) {
        var items = landscape ? (layout.landscapeItems ?? []) : layout.items
        for index in items.indices where selection.contains(items[index].id) {
            transform(&items[index])
        }
        if landscape { layout.landscapeItems = items } else { layout.items = items }
        commit()
    }

    /// Rounds every value in the file onto the grid. Mostly cosmetic, except
    /// where an earlier programmatic pass left float drift behind: psx.json
    /// carries `0.020000000000000004` for what was meant to be 0.02.
    private func tidy() {
        func clean(_ items: [EditableItem]) -> [EditableItem] {
            items.map { item in
                var copy = item
                copy.frame = EditRect(
                    x: EditCanvas.snap(item.frame.x), y: EditCanvas.snap(item.frame.y),
                    w: EditCanvas.snap(item.frame.w), h: EditCanvas.snap(item.frame.h)
                )
                copy.extended = EditRect(
                    x: EditCanvas.snap(item.extended.x), y: EditCanvas.snap(item.extended.y),
                    w: EditCanvas.snap(item.extended.w), h: EditCanvas.snap(item.extended.h)
                )
                return copy
            }
        }
        layout.items = clean(layout.items)
        if let wide = layout.landscapeItems { layout.landscapeItems = clean(wide) }
        commit()
        flash("Snapped to the grid")
    }

    private func seedLandscape() {
        layout.landscapeItems = layout.items
        commit()
        flash("Landscape set seeded from portrait")
    }

    /// Makes a selection symmetric about its own centre.
    ///
    /// Built for a real defect Marcus felt before anyone measured it:
    /// every landscape face-button diamond in the library is off, the
    /// left button sitting 0.005 closer to centre than the right and
    /// the top and bottom pair nudged 0.0025 across. The same error in
    /// PlayStation, SNES and DS, so one hand made it once and it was
    /// copied. About four points on screen, which survives review and
    /// still reads as wrong in the hand.
    ///
    /// Each item is mirrored onto the partner opposite it, and the two
    /// are averaged, so the cluster keeps its size and its position and
    /// only its evenness changes. An item with no partner across the
    /// centre (an odd one out, a lone Z) is left exactly where it is
    /// rather than dragged onto an axis it never belonged to.
    private func evenUpSelection() {
        let binding = itemsBinding(landscape: currentIsLandscape)
        var items = binding.wrappedValue
        let picked = items.indices.filter { selection.contains(items[$0].id) }
        guard picked.count > 1 else { return }

        func centre(_ i: Int) -> CGPoint {
            CGPoint(x: items[i].frame.x + items[i].frame.w / 2,
                    y: items[i].frame.y + items[i].frame.h / 2)
        }
        let cx = picked.map { centre($0).x }.reduce(0, +) / Double(picked.count)
        let cy = picked.map { centre($0).y }.reduce(0, +) / Double(picked.count)

        var moved = 0
        for i in picked {
            let c = centre(i)
            // The partner is whichever selected item sits closest to
            // this one's mirror image through the cluster centre.
            let mirror = CGPoint(x: 2 * cx - c.x, y: 2 * cy - c.y)
            let partner = picked
                .filter { $0 != i }
                .min { a, b in
                    hypot(centre(a).x - mirror.x, centre(a).y - mirror.y)
                        < hypot(centre(b).x - mirror.x, centre(b).y - mirror.y)
                }
            guard let partner,
                  hypot(centre(partner).x - mirror.x, centre(partner).y - mirror.y) < 0.08
            else { continue }
            // Average this item with its partner's mirror, so neither
            // one wins and the cluster does not drift.
            let target = CGPoint(
                x: (c.x + (2 * cx - centre(partner).x)) / 2,
                y: (c.y + (2 * cy - centre(partner).y)) / 2)
            let dx = target.x - c.x, dy = target.y - c.y
            if abs(dx) > 0.0001 || abs(dy) > 0.0001 { moved += 1 }
            items[i].frame = EditRect(
                x: items[i].frame.x + dx, y: items[i].frame.y + dy,
                w: items[i].frame.w, h: items[i].frame.h)
            items[i].extended = EditRect(
                x: items[i].extended.x + dx, y: items[i].extended.y + dy,
                w: items[i].extended.w, h: items[i].extended.h)
        }
        binding.wrappedValue = items
        commit()
        flash(moved == 0 ? "Already even" : "Evened \(moved)")
    }

    /// Which set the toolbar actions apply to, matching what is drawn.
    private var currentIsLandscape: Bool {
        UIDevice.current.orientation.isLandscape
            || (UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }.first?
                .interfaceOrientation.isLandscape ?? false)
    }

    private func revert() {
        guard let bundled = EditableLayout.loadBundled(layout.name) else { return }
        WorkingCopy.discard(layout.name)
        layout = bundled
        selection.removeAll()
        flash("Reverted to the bundled file")
    }

    private func commit() {
        // Only a real edit earns a working copy; see `opened`.
        guard layout.jsonText() != opened else { return }
        WorkingCopy.save(layout)
    }

    private func close() {
        commit()
        dismiss()
    }

    private func detectShadow() {
        opened = layout.jsonText()
        guard WorkingCopy.isEdited(layout.name),
              !WorkingCopy.isReady(layout.name),
              let bundled = EditableLayout.loadBundled(layout.name)
        else { shadowingNewer = false; return }
        shadowingNewer = bundled.jsonText() != opened
    }

    // MARK: Getting the file out

    /// Neither of these touches the working copy on disk: both already read
    /// straight from `layout` in memory, so writing one first would only
    /// leave behind a working copy that looks like a real edit when nothing
    /// was actually changed, which is exactly the false signal that makes a
    /// working copy untrustworthy to read later.
    private func exportFile() {
        guard let url = WorkingCopy.exportFile(layout) else { return }
        share = ShareItem(url: url)
    }

    private func copyJSON() {
        UIPasteboard.general.string = layout.jsonText()
        flash("JSON copied")
    }

    private func flash(_ message: String) {
        note = message
        Task {
            try? await Task.sleep(for: .seconds(2))
            if note == message { note = nil }
        }
    }
}

struct ShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

/// The system share sheet, which is how an edited file gets to the Mac:
/// AirDrop it, or save it to Files. Universal Clipboard covers the other
/// route, since "Copy JSON" lands straight in a paste on the Mac.
struct ActivityView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
