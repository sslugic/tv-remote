import SwiftUI
import WatchConnectivity
import WatchKit

/// Apple Watch remote. Presses go to the iPhone app, which talks to the TV.
@main
struct WatchRemoteApp: App {
    @StateObject private var link = PhoneLink()

    var body: some Scene {
        WindowGroup {
            TabView {
                PadPage().environmentObject(link)
                AppsPage().environmentObject(link)
            }
            .tabViewStyle(.verticalPage)
        }
    }
}

/// Sends button presses to the phone over WatchConnectivity.
@MainActor final class PhoneLink: NSObject, ObservableObject, WCSessionDelegate {
    @Published var status = "Ready"

    override init() {
        super.init()
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
    }

    func press(_ key: String) { send(["key": key]) }
    func open(_ app: String) { send(["app": app]) }

    private func send(_ message: [String: Any]) {
        WKInterfaceDevice.current().play(.click)
        guard WCSession.default.activationState == .activated else {
            status = "Waiting for iPhone…"
            return
        }
        WCSession.default.sendMessage(message) { reply in
            let ok = reply["ok"] as? Bool ?? false
            let text = ok ? (reply["tv"] as? String ?? "Sent") : (reply["error"] as? String ?? "Failed")
            Task { @MainActor in self.status = text }
        } errorHandler: { error in
            Task { @MainActor in self.status = "iPhone not reachable" }
        }
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {}
}

struct PadPage: View {
    @EnvironmentObject private var link: PhoneLink

    var body: some View {
        VStack(spacing: 4) {
            Text(link.status).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            Grid(horizontalSpacing: 4, verticalSpacing: 4) {
                GridRow {
                    key("arrow.uturn.backward", "back")
                    key("chevron.up", "up")
                    key("house.fill", "home")
                }
                GridRow {
                    key("chevron.left", "left")
                    Button { link.press("ok") } label: { Text("OK").font(.headline).frame(maxWidth: .infinity, minHeight: 38) }
                        .tint(.purple)
                    key("chevron.right", "right")
                }
                GridRow {
                    key("speaker.wave.1.fill", "volumeDown")
                    key("chevron.down", "down")
                    key("speaker.wave.3.fill", "volumeUp")
                }
                GridRow {
                    key("speaker.slash.fill", "mute")
                    key("playpause.fill", "playPause")
                    key("power", "power")
                }
            }
        }
    }

    private func key(_ symbol: String, _ key: String) -> some View {
        Button { link.press(key) } label: {
            Image(systemName: symbol).frame(maxWidth: .infinity, minHeight: 38)
        }
    }
}

struct AppsPage: View {
    @EnvironmentObject private var link: PhoneLink
    private let apps = [
        ("netflix", "Netflix"), ("youtube", "YouTube"), ("prime", "Prime Video"), ("disney", "Disney+"),
        ("hulu", "Hulu"), ("max", "HBO Max"), ("peacock", "Peacock"), ("appleTV", "Apple TV"), ("paramount", "Paramount+"),
    ]

    var body: some View {
        List(apps, id: \.0) { id, name in
            Button(name) { link.open(id) }
        }
        .navigationTitle("Apps")
    }
}
