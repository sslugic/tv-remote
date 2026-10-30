import ActivityKit
import AppIntents
import Foundation

// These intents back Siri, Shortcuts, the Action button, widgets and the Live Activity.
// They conform to LiveActivityIntent so they always run inside the app (which holds the TV
// connection and pairing), even when tapped from a widget.

extension RemoteKey: AppEnum {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Remote Button"
    static let caseDisplayRepresentations: [RemoteKey: DisplayRepresentation] = [
        .power: "Power", .home: "Home", .back: "Back", .input: "Input",
        .up: "Up", .down: "Down", .left: "Left", .right: "Right", .ok: "OK",
        .volumeUp: "Volume Up", .volumeDown: "Volume Down", .mute: "Mute",
        .channelUp: "Channel Up", .channelDown: "Channel Down", .playPause: "Play/Pause",
        .tv: "TV Input", .hdmi1: "HDMI 1", .hdmi2: "HDMI 2", .hdmi3: "HDMI 3", .hdmi4: "HDMI 4", .nextHDMI: "Next HDMI",
        .settings: "TV Settings", .exit: "Exit", .search: "Search",
    ]
}

extension StreamingApp: AppEnum {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Streaming App"
    static let caseDisplayRepresentations: [StreamingApp: DisplayRepresentation] = [
        .netflix: "Netflix", .youtube: "YouTube", .prime: "Prime Video", .disney: "Disney+",
        .hulu: "Hulu", .max: "HBO Max", .peacock: "Peacock", .appleTV: "Apple TV", .paramount: "Paramount+",
    ]
}

struct PressButtonIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Press TV Button"
    static let description = IntentDescription("Presses a button on your TV, such as Mute or Volume Up.")

    @Parameter(title: "Button") var key: RemoteKey

    init() {}
    init(_ key: RemoteKey) { self.key = key }

    @MainActor func perform() async throws -> some IntentResult {
        let key = key
        if key == .power {
            // Power works with the TV off too (it wakes it), so don't wait for a connection.
            RemoteController.shared.send(.power)
        } else {
            try await RemoteController.shared.whenConnected { $0.send(key) }
        }
        return .result()
    }
}

struct OpenStreamingAppIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Open App on TV"
    static let description = IntentDescription("Opens a streaming app such as Netflix on your TV.")

    @Parameter(title: "App") var app: StreamingApp

    init() {}
    init(_ app: StreamingApp) { self.app = app }

    @MainActor func perform() async throws -> some IntentResult {
        let app = app
        try await RemoteController.shared.whenConnected { $0.launch(app) }
        return .result()
    }
}

struct SleepTimerIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Start TV Sleep Timer"
    static let description = IntentDescription("Turns the TV off after a number of minutes.")

    @Parameter(title: "Minutes", default: 30, inclusiveRange: (1, 240)) var minutes: Int

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        RemoteController.shared.startSleepTimer(minutes: minutes)
        return .result(dialog: "The TV will turn off in \(minutes) minutes.")
    }
}

struct RemoteShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenStreamingAppIntent(),
            phrases: [
                "Open \(\.$app) on the TV with \(.applicationName)",
                "Watch \(\.$app) with \(.applicationName)",
            ],
            shortTitle: "Open App on TV",
            systemImageName: "play.tv"
        )
        AppShortcut(
            intent: PressButtonIntent(),
            phrases: [
                "Press \(\.$key) with \(.applicationName)",
                "\(.applicationName) \(\.$key)",
            ],
            shortTitle: "Press TV Button",
            systemImageName: "av.remote"
        )
        AppShortcut(
            intent: PressButtonIntent(.mute),
            phrases: ["Mute the TV with \(.applicationName)"],
            shortTitle: "Mute TV",
            systemImageName: "speaker.slash"
        )
        #if !APP_STORE
        AppShortcut(
            intent: SleepTimerIntent(),
            phrases: ["Start a sleep timer with \(.applicationName)"],
            shortTitle: "TV Sleep Timer",
            systemImageName: "moon.zzz"
        )
        #endif
    }
}

/// Data for the remote's Live Activity on the Lock Screen and in the Dynamic Island.
struct RemoteActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var tvName: String
        var connected: Bool
        var sleepAt: Date?
    }
}
