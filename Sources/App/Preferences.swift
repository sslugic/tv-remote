import SwiftUI

enum PadStyle: String, CaseIterable, Identifiable {
    case dpad, trackpad
    var id: String { rawValue }
    var label: String { self == .dpad ? "Arrow pad" : "Swipe pad" }
}

/// A color scheme for the remote and home screens.
struct Theme: Identifiable, Equatable {
    let id: String
    let name: String
    let background: [Color]
    let accent: Color
    let key: Color
    let pad: Color
    let okButton: Color

    static let midnight = Theme(
        id: "midnight", name: "Midnight",
        background: [Color(red: 0.07, green: 0.05, blue: 0.14), .black],
        accent: Color(red: 0.62, green: 0.45, blue: 1.0),
        key: Color(white: 0.15), pad: Color(white: 0.12), okButton: Color(white: 0.22)
    )
    static let synthwave = Theme(
        id: "synthwave", name: "Synthwave",
        background: [Color(red: 0.25, green: 0.03, blue: 0.30), Color(red: 0.04, green: 0.02, blue: 0.12)],
        accent: Color(red: 1.0, green: 0.25, blue: 0.75),
        key: Color(red: 0.20, green: 0.06, blue: 0.28), pad: Color(red: 0.13, green: 0.04, blue: 0.22),
        okButton: Color(red: 0.0, green: 0.75, blue: 0.85)
    )
    static let ocean = Theme(
        id: "ocean", name: "Ocean",
        background: [Color(red: 0.0, green: 0.16, blue: 0.24), Color(red: 0.0, green: 0.04, blue: 0.08)],
        accent: Color(red: 0.25, green: 0.85, blue: 0.95),
        key: Color(red: 0.05, green: 0.20, blue: 0.27), pad: Color(red: 0.03, green: 0.15, blue: 0.21),
        okButton: Color(red: 0.08, green: 0.32, blue: 0.40)
    )
    static let classic = Theme(
        id: "classic", name: "Classic",
        background: [.black, .black],
        accent: .white,
        key: Color(white: 0.16), pad: Color(white: 0.11), okButton: Color(white: 0.24)
    )

    static let all = [midnight, synthwave, ocean, classic]
}

/// User choices, kept in UserDefaults.
@MainActor final class Preferences: ObservableObject {
    @AppStorage("theme") private var themeID = Theme.midnight.id
    @AppStorage("padStyle") var padStyle = PadStyle.dpad
    @AppStorage("volumeButtons") var volumeButtons = true
    @AppStorage("appOrder") private var appOrderRaw = ""
    @AppStorage("hiddenApps") private var hiddenRaw = ""

    var theme: Theme {
        get { Theme.all.first { $0.id == themeID } ?? .midnight }
        set { themeID = newValue.id }
    }

    /// All streaming apps in the user's order (new apps appended at the end).
    var appOrder: [StreamingApp] {
        get {
            let saved = appOrderRaw.split(separator: ",").compactMap { StreamingApp(rawValue: String($0)) }
            return saved + StreamingApp.allCases.filter { !saved.contains($0) }
        }
        set { appOrderRaw = newValue.map(\.rawValue).joined(separator: ",") }
    }

    var hiddenApps: Set<StreamingApp> {
        get { Set(hiddenRaw.split(separator: ",").compactMap { StreamingApp(rawValue: String($0)) }) }
        set { hiddenRaw = newValue.map(\.rawValue).sorted().joined(separator: ",") }
    }

    /// Apps to show on the remote: in order, not hidden, and installed on the TV when the TV can tell us.
    func visibleApps(installed: Set<StreamingApp>?) -> [StreamingApp] {
        appOrder.filter { !hiddenApps.contains($0) && (installed?.contains($0) ?? true) }
    }
}
