import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var prefs: Preferences
    @EnvironmentObject private var remote: RemoteController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Theme") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(Theme.all) { theme in
                                Button { prefs.theme = theme } label: { swatch(theme) }
                                    .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 6)
                    }
                }

                Section {
                    Picker("Pad", selection: $prefs.padStyle) {
                        ForEach(PadStyle.allCases) { Text($0.label).tag($0) }
                    }
                    if !AppInfo.isAppStore {
                        Toggle("iPhone volume buttons control the TV", isOn: $prefs.volumeButtons)
                    }
                } header: {
                    Text("Remote")
                } footer: {
                    if !AppInfo.isAppStore {
                        Text("While the remote is open, the side buttons change the TV's volume instead of the phone's.")
                    }
                }

                Section {
                    ForEach(prefs.appOrder) { app in
                        HStack(spacing: 12) {
                            AppTile(app: app, size: 34)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(app.label)
                                if let installed = remote.installedApps, !installed.contains(app) {
                                    Text("Not installed on \(remote.current?.name ?? "this TV")")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Toggle("Show", isOn: Binding(
                                get: { !prefs.hiddenApps.contains(app) },
                                set: { show in
                                    if show { prefs.hiddenApps.remove(app) } else { prefs.hiddenApps.insert(app) }
                                }
                            ))
                            .labelsHidden()
                        }
                    }
                    .onMove { from, to in
                        var order = prefs.appOrder
                        order.move(fromOffsets: from, toOffset: to)
                        prefs.appOrder = order
                    }
                } header: {
                    Text("Streaming apps")
                } footer: {
                    Text("Drag to reorder. Apps that aren't installed on the current TV are hidden automatically.")
                }

                Section {
                    HStack(alignment: .top, spacing: 12) {
                        Image("tmdb-logo-square")
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 44)
                            .accessibilityLabel("The Movie Database (TMDB)")
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Movie and show data").font(.subheadline.weight(.semibold))
                            Text("Trending titles, posters and details come from The Movie Database (TMDB).")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    Text(MovieCredits.tmdbNotice).font(.footnote)
                    Link("themoviedb.org", destination: URL(string: "https://www.themoviedb.org")!).foregroundStyle(Color.accentColor)
                    Text("Streaming availability (where to watch) is provided by JustWatch.").font(.footnote)
                    Link("justwatch.com", destination: URL(string: "https://www.justwatch.com")!).foregroundStyle(Color.accentColor)
                    Text("\(AppInfo.name) is free, has no ads or purchases, and isn't affiliated with any TV maker or streaming service. All trademarks and artwork belong to their owners.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Link("Privacy policy", destination: URL(string: "https://sslugic.github.io/tv-remote/privacy.html")!).foregroundStyle(Color.accentColor)
                } header: {
                    Text("About & Credits")
                }

                Section("Siri & Shortcuts") {
                    Label("\"Watch Netflix with \(AppInfo.name)\"", systemImage: "mic")
                    Label("\"Mute the TV with \(AppInfo.name)\"", systemImage: "mic")
                    if !AppInfo.isAppStore {
                        Label("\"Start a sleep timer with \(AppInfo.name)\"", systemImage: "mic")
                    }
                    Text("These also appear in the Shortcuts app and can be put on the Action button.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Settings")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    private func swatch(_ theme: Theme) -> some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(LinearGradient(colors: theme.background, startPoint: .top, endPoint: .bottom))
                Circle().fill(theme.pad).frame(width: 34, height: 34)
                Circle().fill(theme.okButton).frame(width: 14, height: 14)
            }
            .frame(width: 70, height: 90)
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(prefs.theme == theme ? theme.accent : .white.opacity(0.15), lineWidth: prefs.theme == theme ? 3 : 1)
            )
            Text(theme.name).font(.caption)
        }
    }
}
