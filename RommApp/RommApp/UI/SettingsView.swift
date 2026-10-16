import SwiftUI

/// Settings: the pad, the touch controls, the connection, storage, and the
/// way out. Every row does something on a handheld
/// (docs/scope-handheld.md); the TV controller, light gun aim, web player
/// autosave, experimental cores and platform name source left with the
/// features they belonged to. No core options either, the way CabinetOS
/// has none: the app sets the values, and the few worth changing belong
/// in the pause menu where their effect can be seen.
///
/// The destructive actions live here, behind a deliberate navigation, after one
/// of them got fired by a stray tap when it sat inside the library list and
/// shifted position while platforms were still loading.
struct SettingsView: View {
    @EnvironmentObject private var session: Session
    @State private var confirmingUnpair = false
    @State private var confirmingForget = false
    @AppStorage("com.mmagtech.RommApp.controlOpacity") private var controlOpacity = 0.7
    @AppStorage("com.mmagtech.RommApp.rumbleEnabled") private var rumbleEnabled = true
    @AppStorage(RaisedControls.key) private var raisedControls = true
    @AppStorage(ControlTheme.key) private var controlTheme = ControlTheme.system.rawValue
    @ObservedObject private var controllers = GameControllerManager.shared

    var body: some View {
        List {
            Section {
                // The name goes underneath rather than trailing. As a
                // LabeledContent value it was squeezed into whatever width
                // was left after the label, and a real controller name is
                // longer than that: "OhSnap MCON II" wrapped to a stack of
                // clipped lines, which rendered as an empty gap the height
                // of the wrap. Below the title it has the whole row.
                // No "Change buttons": the map is fixed and positional, the
                // same as CabinetOS's (Controls/ControllerBindings.swift).
                ControllerStatusRow()
            } header: {
                Text("Physical controller")
            } footer: {
                Text("On screen controls hide while one is connected.")
            }

            Section {
                Picker("Button colours", selection: $controlTheme) {
                    ForEach(ControlTheme.allCases, id: \.self) { theme in
                        Text(theme.label).tag(theme.rawValue)
                    }
                }
                Text(ControlTheme(rawValue: controlTheme)?.detail ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Touch control visibility")
                        Spacer()
                        Text("\(Int(controlOpacity * 100))%")
                            .foregroundStyle(.secondary)
                            .font(.callout.monospacedDigit())
                    }
                    Slider(value: $controlOpacity, in: 0.25...1.0, step: 0.05)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Raised controls", isOn: $raisedControls)
                    Text("Off draws them flat, which is easier to read.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Toggle("Rumble", isOn: $rumbleEnabled)
            } header: {
                Text("Controls")
            }

            Section {
                LabeledContent("Server", value: session.serverURL?.host ?? "unknown")
                if let version = session.serverVersion {
                    LabeledContent("RomM version", value: version)
                }
                NavigationLink {
                    LocalAddressView()
                } label: {
                    LabeledContent(
                        "Second address",
                        value: session.localServerURL?.host ?? "Not set"
                    )
                }
                if session.localServerURL != nil {
                    LabeledContent(
                        "Using",
                        value: session.isUsingLocalAddress ? "Local network" : "Internet"
                    )
                }
            } header: {
                Text("Connection")
            } footer: {
                Text("If your server has a second address, Cabinet uses whichever one is on this network, and the other when you're away.")
            }

            Section {
                NavigationLink {
                    StorageView()
                } label: {
                    Label("Storage", systemImage: "internaldrive")
                }
            } footer: {
                Text("Games kept on this phone.")
            }

            Section {
                NavigationLink {
                    LicensesView()
                } label: {
                    Label("Licenses", systemImage: "doc.text")
                }
            } footer: {
                Text("The software this app is built from, and the terms it ships under.")
            }

            Section {
                NavigationLink {
                    DebugView()
                } label: {
                    Label("Diagnostics", systemImage: "ladybug")
                }
            } footer: {
                Text("Diagnostics for reporting a problem.")
            }

            Section {
                creditLink("CabinetOS", "https://github.com/MMagTech/cabinetos")
                creditLink("RomM", "https://github.com/rommapp/romm")
                creditLink("romm-ios-app", "https://github.com/ilyas-hallak/romm-ios-app")
            } header: {
                Text("Credits")
            } footer: {
                Text("CabinetOS is the console half: every system, on the TV, with saves that cross to this phone. Cabinet talks to your RomM server, built by the RomM project and team, and was inspired by romm-ios-app, an earlier native client for RomM.")
            }

            Section {
                Button("Unpair this device", role: .destructive) {
                    confirmingUnpair = true
                }
                Button("Use a different server", role: .destructive) {
                    confirmingForget = true
                }
            } footer: {
                Text("Unpairing signs this device out but remembers the server. Switching servers forgets everything.")
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .task { controllers.start() }
        .confirmationDialog(
            "Unpair this device?",
            isPresented: $confirmingUnpair,
            titleVisibility: .visible
        ) {
            Button("Unpair", role: .destructive) {
                // Both outlive the pairing they describe if left alone: a
                // widget still showing the last account's games on a
                // shared home screen, and Spotlight results naming them.
                WidgetWriter.wipe()
                SpotlightIndexer.wipe()
                session.signOut()
            }
        } message: {
            Text("You will need to approve this device again to reconnect.")
        }
        .confirmationDialog(
            "Forget this server?",
            isPresented: $confirmingForget,
            titleVisibility: .visible
        ) {
            Button("Forget server", role: .destructive) {
                // Same hygiene as Unpair above.
                WidgetWriter.wipe()
                SpotlightIndexer.wipe()
                session.forgetServer()
            }
        } message: {
            Text("The saved address and pairing are removed.")
        }
    }

    private func creditLink(_ title: String, _ address: String) -> some View {
        Link(destination: URL(string: address)!) {
            LabeledContent {
                Image(systemName: "arrow.up.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } label: {
                Text(title)
            }
        }
    }
}
