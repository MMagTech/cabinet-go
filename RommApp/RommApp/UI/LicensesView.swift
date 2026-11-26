import SwiftUI

/// Every piece of software this app ships, with its license readable in
/// full. Entries are data, not views, so adding the next native core is
/// one line here plus its bundled text file.
///
/// Only what the app binary actually contains belongs in this list.
struct LicensesView: View {
    struct Entry: Identifiable {
        let id: String
        let name: String
        let role: String
        /// The one fact worth reading, above the legal text nobody does.
        let summary: String
        /// Bundled text file in Resources/Licenses, without extension.
        let file: String
    }

    static let entries: [Entry] = [
        Entry(
            id: "cabinet",
            name: "Cabinet Go",
            role: "This app",
            summary: "Cabinet Go itself is free software under the MIT license.",
            file: "cabinet-mit"
        ),
        Entry(
            id: "gambatte",
            name: "Gambatte",
            role: "Native Game Boy and Game Boy Color core",
            summary: "GPL version 2.",
            file: "gambatte"
        ),
        Entry(
            id: "mgba",
            name: "mGBA",
            role: "Native Game Boy Advance core",
            summary: "Mozilla Public License 2.0.",
            file: "mgba"
        ),
        Entry(
            id: "genesis-plus-gx",
            name: "Genesis Plus GX",
            role: "Native Game Gear core",
            summary: "Free for non-commercial use. Cabinet Go is free and is never sold, which is what these terms ask.",
            file: "genesis-plus-gx"
        ),
        Entry(
            id: "beetle-ngp",
            name: "Beetle NeoPop",
            role: "Native Neo Geo Pocket Color core",
            summary: "GPL version 2, from the Mednafen project.",
            file: "beetle-ngp"
        ),
        Entry(
            id: "melonds",
            name: "melonDS",
            role: "Native Nintendo DS core",
            summary: "GPL version 3, the libretro fork.",
            file: "melonds"
        ),
        Entry(
            id: "drastic-freebios",
            name: "DraStic FreeBIOS",
            role: "DS BIOS replacement compiled into melonDS",
            summary: "BSD 2-clause, by Gilead Kutnick. This notice is the reproduction its binary redistribution terms require.",
            file: "drastic-freebios"
        ),
        Entry(
            id: "ppsspp",
            name: "PPSSPP",
            role: "Native PSP core",
            summary: "GPL version 2 or later.",
            file: "ppsspp"
        ),
        Entry(
            id: "gw-libretro",
            name: "gw-libretro",
            role: "Native Game & Watch core",
            summary: "zlib license, by Andre Leiradella.",
            file: "gw-libretro"
        ),
        Entry(
            id: "vemulator",
            name: "VeMUlator",
            role: "Dreamcast VMU minigame player",
            summary: "GPL version 3.",
            file: "vemulator"
        ),
        Entry(
            id: "libretro-common",
            name: "libretro-common",
            role: "Emulator interface",
            summary: "The libretro API and utility code the cores are built against, MIT licensed.",
            file: "libretro-common"
        ),
        Entry(
            id: "zlib",
            name: "zlib",
            role: "ROM decompression",
            summary: "Compression library by Jean-loup Gailly and Mark Adler, zlib license.",
            file: "zlib"
        ),
        Entry(
            id: "libchdr",
            name: "libchdr",
            role: "CHD disc image reading",
            summary: "Reads CHD compressed disc images, built into PPSSPP and Genesis Plus GX, BSD licensed.",
            file: "libchdr"
        ),
        Entry(
            id: "zstd",
            name: "Zstandard",
            role: "Disc image decompression",
            summary: "Compression library by Meta, BSD licensed.",
            file: "zstd"
        ),
        Entry(
            id: "lzma",
            name: "LZMA SDK",
            role: "Archive decompression",
            summary: "Igor Pavlov's compression code, placed in the public domain.",
            file: "lzma"
        ),
        Entry(
            id: "tremor",
            name: "Tremor",
            role: "CD audio decoding",
            summary: "Xiph.Org's integer Ogg Vorbis decoder, used for CD audio tracks, BSD licensed.",
            file: "tremor"
        ),
        Entry(
            id: "inih",
            name: "inih",
            role: "Config parsing",
            summary: "Ben Hoyt's INI parser, built into mGBA, BSD licensed.",
            file: "inih"
        ),
        Entry(
            id: "ffmpeg",
            name: "FFmpeg",
            role: "PSP video and audio decoding",
            summary: "LGPL version 2.1 or later. The prebuilt build PPSSPP carries for iOS, built without FFmpeg's GPL parts.",
            file: "ffmpeg"
        ),
        Entry(
            id: "lua",
            name: "Lua",
            role: "Script interpreter",
            summary: "MIT licensed, by Lua.org, PUC-Rio. Built into PPSSPP and into gw-libretro, which runs the Game & Watch simulations as Lua programs.",
            file: "lua"
        ),
        Entry(
            id: "bzip2",
            name: "bzip2",
            role: "Decompression inside gw-libretro",
            summary: "BSD-style license, by Julian Seward.",
            file: "bzip2"
        ),
    ]

    var body: some View {
        List(Self.entries) { entry in
            NavigationLink {
                LicenseTextView(entry: entry)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name)
                    Text(entry.role)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Licenses")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

private struct LicenseTextView: View {
    let entry: LicensesView.Entry

    private var licenseText: String {
        guard let url = Bundle.main.url(forResource: entry.file, withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else {
            return "The license text is missing from this build. The canonical text ships with the project's source."
        }
        return text
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(entry.summary)
                    .font(.callout)
                Text(licenseText)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    #if os(iOS)
                    .textSelection(.enabled)
                    #endif
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
        .navigationTitle(entry.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}
