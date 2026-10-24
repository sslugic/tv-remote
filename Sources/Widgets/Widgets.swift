import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

@main
struct RemoteWidgets: WidgetBundle {
    var body: some Widget {
        RemoteWidget()
        LockScreenRemoteWidget()
        RemoteLiveActivity()
    }
}

private let purple = Color(red: 0.55, green: 0.38, blue: 1.0)

struct StaticEntry: TimelineEntry {
    let date = Date()
}

struct StaticProvider: TimelineProvider {
    func placeholder(in context: Context) -> StaticEntry { StaticEntry() }
    func getSnapshot(in context: Context, completion: @escaping (StaticEntry) -> Void) { completion(StaticEntry()) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<StaticEntry>) -> Void) {
        completion(Timeline(entries: [StaticEntry()], policy: .never))
    }
}

// MARK: - Home Screen

struct RemoteWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "RemoteWidget", provider: StaticProvider()) { _ in
            RemoteWidgetView()
                .containerBackground(for: .widget) {
                    LinearGradient(colors: [Color(red: 0.13, green: 0.08, blue: 0.28), .black], startPoint: .top, endPoint: .bottom)
                }
        }
        .configurationDisplayName("TV Remote")
        .description("Volume, mute, play/pause and your streaming apps.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct RemoteWidgetView: View {
    @Environment(\.widgetFamily) private var family

    var body: some View {
        if family == .systemMedium {
            HStack(spacing: 12) {
                keys
                VStack(spacing: 10) {
                    HStack(spacing: 10) { appButton(.netflix); appButton(.youtube) }
                    HStack(spacing: 10) { appButton(.prime); appButton(.disney) }
                }
            }
        } else {
            keys
        }
    }

    private var keys: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                keyButton("speaker.wave.1.fill", .volumeDown)
                keyButton("speaker.wave.3.fill", .volumeUp)
            }
            HStack(spacing: 8) {
                keyButton("speaker.slash.fill", .mute)
                keyButton("playpause.fill", .playPause)
            }
        }
    }

    private func keyButton(_ symbol: String, _ key: RemoteKey) -> some View {
        Button(intent: PressButtonIntent(key)) {
            Image(systemName: symbol)
                .font(.title3.weight(.semibold))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white.opacity(0.12)))
    }

    private func appButton(_ app: StreamingApp) -> some View {
        Button(intent: OpenStreamingAppIntent(app)) {
            AppTile(app: app, size: 52)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Lock Screen

struct LockScreenRemoteWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "LockScreenRemote", provider: StaticProvider()) { _ in
            LockScreenRemoteView()
                .containerBackground(for: .widget) { Color.clear }
        }
        .configurationDisplayName("TV Controls")
        .description("Control the TV from the Lock Screen.")
        .supportedFamilies([.accessoryRectangular, .accessoryCircular])
    }
}

struct LockScreenRemoteView: View {
    @Environment(\.widgetFamily) private var family

    var body: some View {
        if family == .accessoryCircular {
            Button(intent: PressButtonIntent(.playPause)) {
                ZStack {
                    AccessoryWidgetBackground()
                    Image(systemName: "playpause.fill").font(.title3)
                }
            }
            .buttonStyle(.plain)
        } else {
            HStack(spacing: 4) {
                ForEach([("speaker.wave.1.fill", RemoteKey.volumeDown), ("speaker.slash.fill", .mute),
                         ("playpause.fill", .playPause), ("speaker.wave.3.fill", .volumeUp)], id: \.0) { symbol, key in
                    Button(intent: PressButtonIntent(key)) {
                        Image(systemName: symbol)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(AccessoryWidgetBackground().clipShape(RoundedRectangle(cornerRadius: 8)))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

// MARK: - Live Activity / Dynamic Island

struct RemoteLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RemoteActivityAttributes.self) { context in
            VStack(alignment: .leading, spacing: 10) {
                header(context.state)
                controls
            }
            .padding(14)
            .activityBackgroundTint(Color(red: 0.08, green: 0.05, blue: 0.16))
            .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(context.state.tvName, systemImage: "tv").font(.caption).lineLimit(1)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if let sleepAt = context.state.sleepAt {
                        Label { Text(sleepAt, style: .timer) } icon: { Image(systemName: "moon.zzz") }
                            .font(.caption).monospacedDigit()
                    }
                }
                DynamicIslandExpandedRegion(.bottom) { controls }
            } compactLeading: {
                Image(systemName: "av.remote.fill").foregroundStyle(purple)
            } compactTrailing: {
                if let sleepAt = context.state.sleepAt {
                    Text(sleepAt, style: .timer).monospacedDigit().frame(width: 44)
                } else {
                    Image(systemName: context.state.connected ? "checkmark.circle.fill" : "wifi.slash")
                        .foregroundStyle(context.state.connected ? .green : .orange)
                }
            } minimal: {
                Image(systemName: "av.remote.fill").foregroundStyle(purple)
            }
        }
    }

    private func header(_ state: RemoteActivityAttributes.ContentState) -> some View {
        HStack {
            Label(state.tvName, systemImage: "tv").font(.subheadline.bold()).lineLimit(1)
            Spacer()
            if let sleepAt = state.sleepAt {
                Label { Text(sleepAt, style: .timer) } icon: { Image(systemName: "moon.zzz") }
                    .font(.caption).monospacedDigit()
            }
        }
        .foregroundStyle(.white)
    }

    private var controls: some View {
        HStack(spacing: 8) {
            ForEach([("speaker.wave.1.fill", RemoteKey.volumeDown), ("speaker.slash.fill", .mute),
                     ("playpause.fill", .playPause), ("speaker.wave.3.fill", .volumeUp), ("house.fill", .home)], id: \.0) { symbol, key in
                Button(intent: PressButtonIntent(key)) {
                    Image(systemName: symbol)
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.14)))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
            }
        }
    }
}
