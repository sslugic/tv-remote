import ActivityKit
import Foundation

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
