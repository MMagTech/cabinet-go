import SwiftUI

/// The library's tile for a platform or a collection: a name and a count
/// over a row of covers. Owns everything about how the tile is drawn and
/// nothing about where it navigates or how tall it is; the library wraps
/// it in its own NavigationLink and works out one height for every tile
/// from the screen it is on (`LibraryScreen.tileHeight`).
struct PlatformTile: View {
    let title: String
    let count: Int
    let covers: [String]
    let height: CGFloat

    private static var titleFont: Font {
        .subheadline.weight(.semibold)
    }

    private static var countFont: Font {
        .caption2
    }

    var body: some View {
            ZStack(alignment: .bottomLeading) {
                backdrop(covers: covers)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(Self.titleFont)
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .minimumScaleFactor(0.7)
                        .multilineTextAlignment(.leading)
                        .shadow(color: .black.opacity(0.5), radius: 4, y: 1)
                    Text("\(count) games")
                        .font(Self.countFont)
                        .foregroundStyle(.white.opacity(0.65))
                        .shadow(color: .black.opacity(0.5), radius: 3, y: 1)
                }
                .padding(11)
            }
            .frame(height: height)
            .frame(maxWidth: .infinity)
            .clipShape(.rect(cornerRadius: 12))
            .animation(.easeOut(duration: 0.35), value: covers)
    }

    /// The tile's art: covers at their own 3:4 shape, edge to edge from
    /// the trailing side, as many as the art zone holds, with the label
    /// zone kept a flat opaque panel that fades out over the art. Covers
    /// keep their shape because a full-width tile stretched two of them
    /// into wide crops. Proportional, never fixed points: the label zone
    /// is a fraction of the tile's own width and the cover width follows
    /// its height, so the same tile works on any phone. Fixed widths once
    /// squeezed a long platform name until it hyphenated.
    private func backdrop(covers: [String]) -> some View {
        GeometryReader { geo in
            // Where the covers start, as a fraction of the tile. The
            // label overhangs into the faded region for long names, which
            // is why the gradient's first stretch stays mostly opaque.
            let labelZone = geo.size.width * 0.42
            let coverWidth = max(geo.size.height * 0.75, 1)
            let slots = Int(((geo.size.width - labelZone) / coverWidth).rounded(.up))
            ZStack(alignment: .leading) {
                Self.panel
                if !covers.isEmpty {
                    HStack(spacing: 0) {
                        ForEach(Array(covers.prefix(slots).enumerated()), id: \.offset) { _, path in
                            CoverImage(path: path, title: "", showsPlaceholder: false)
                                .frame(width: coverWidth, height: geo.size.height)
                                .clipped()
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)

                    // A solid fill for the label zone rather than the
                    // gradient's own opaque stop: an interpolated
                    // "opaque" stop once left a per-platform hairline of
                    // art color at the tile's edge, and a plain
                    // Rectangle has no interpolation to get wrong.
                    HStack(spacing: 0) {
                        Rectangle()
                            .fill(Self.panel)
                            .frame(width: labelZone)
                        LinearGradient(
                            stops: [
                                .init(color: Self.panel, location: 0),
                                .init(color: Self.panel.opacity(0.8), location: 0.28),
                                .init(color: Self.panel.opacity(0), location: 0.8),
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
        }
    }

    /// Deliberately darker and less saturated than the approved mockup's
    /// purple: the same sRGB values render far more vividly on a
    /// wide-gamut display, where the mockup's own came out a loud
    /// electric purple.
    private static let panel = Color(red: 0.14, green: 0.10, blue: 0.24)
}
