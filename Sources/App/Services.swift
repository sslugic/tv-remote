import ActivityKit
import Foundation
import WatchConnectivity

/// Starts, updates and ends the remote's Live Activity (Lock Screen and Dynamic Island controls).
@MainActor final class LiveActivity: ObservableObject {
    static let shared = LiveActivity()

    @Published private(set) var isRunning = false
    private var activity: Activity<RemoteActivityAttributes>?

    private init() {
        activity = Activity<RemoteActivityAttributes>.activities.first
        isRunning = activity != nil
    }

    func toggle(_ remote: RemoteController) {
        if isRunning { stop() } else { start(remote) }
    }

    func start(_ remote: RemoteController) {
        guard activity == nil, ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        activity = try? Activity.request(
            attributes: RemoteActivityAttributes(),
            content: .init(state: state(remote), staleDate: nil)
        )
        isRunning = activity != nil
    }

    func update(_ remote: RemoteController) {
        guard let activity else { return }
        let content = ActivityContent(state: state(remote), staleDate: nil)
        Task { await activity.update(content) }
    }

    func stop() {
        guard let activity else { return }
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
        self.activity = nil
        isRunning = false
    }

    private func state(_ remote: RemoteController) -> RemoteActivityAttributes.ContentState {
        .init(tvName: remote.current?.name ?? "TV", connected: remote.status == .connected, sleepAt: remote.sleepAt)
    }
}

/// Receives button presses from the Apple Watch app and runs them on the TV.
/// The watch can't hold the TV connection itself, so the phone does it (iOS wakes the app in the background).
final class WatchBridge: NSObject, WCSessionDelegate {
    static let shared = WatchBridge()

    func start() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        Task { @MainActor in
            let remote = RemoteController.shared
            do {
                if let raw = message["key"] as? String, let key = RemoteKey(rawValue: raw) {
                    if key == .power { remote.send(.power) } else { try await remote.whenConnected { $0.send(key) } }
                } else if let raw = message["app"] as? String, let app = StreamingApp(rawValue: raw) {
                    try await remote.whenConnected { $0.launch(app) }
                }
                replyHandler(["ok": true, "tv": remote.current?.name ?? "TV"])
            } catch {
                replyHandler(["ok": false, "error": error.localizedDescription])
            }
        }
    }

    func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {}
    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) { session.activate() }
}
