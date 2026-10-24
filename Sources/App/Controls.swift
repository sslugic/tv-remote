import AVFoundation
import MediaPlayer
import SwiftUI

/// Swipe to move, tap for OK. Every ~36 points of travel sends one arrow press.
struct Trackpad: View {
    let theme: Theme
    let press: (RemoteKey) -> Void

    @State private var origin: CGPoint?
    @State private var moved = false
    private let step: CGFloat = 36

    var body: some View {
        RoundedRectangle(cornerRadius: 36, style: .continuous)
            .fill(theme.pad)
            .overlay(
                VStack(spacing: 6) {
                    Image(systemName: "hand.draw").font(.title)
                    Text("Swipe to move · tap for OK").font(.footnote)
                }
                .foregroundStyle(.white.opacity(0.35))
            )
            .frame(height: 216)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard let start = origin else {
                            origin = value.location
                            moved = false
                            return
                        }
                        let dx = value.location.x - start.x
                        let dy = value.location.y - start.y
                        if max(abs(dx), abs(dy)) >= step {
                            if abs(dx) > abs(dy) { press(dx > 0 ? .right : .left) } else { press(dy > 0 ? .down : .up) }
                            origin = value.location
                            moved = true
                        }
                    }
                    .onEnded { value in
                        let travel = hypot(value.translation.width, value.translation.height)
                        if !moved && travel < 12 { press(.ok) }
                        origin = nil
                    }
            )
    }
}

/// Sheet for typing into the TV's on-screen keyboard; text is sent as you type.
struct KeyboardSheet: View {
    @EnvironmentObject private var remote: RemoteController
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 14) {
            Text("Type on your TV").font(.headline)
            Text("Open a search box on the TV first, then type here.")
                .font(.footnote).foregroundStyle(.secondary)
            TextField("Search or type", text: $text)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .focused($focused)
                .submitLabel(.search)
                .onSubmit { remote.send(.ok) }
                .onChange(of: text) { previous, newValue in remote.type(newValue, previous: previous) }
            HStack {
                Button("Clear") { text = "" }
                Spacer()
                Button("Enter") { remote.send(.ok) }.buttonStyle(.borderedProminent)
                Button("Done") { dismiss() }.buttonStyle(.bordered)
            }
        }
        .padding(20)
        .presentationDetents([.height(220)])
        .onAppear { focused = true }
    }
}

/// Turns the iPhone's volume buttons into TV volume buttons while the remote is on screen.
/// Watches the system volume and resets it to the middle after each press so both buttons keep working.
@MainActor final class VolumeButtons: ObservableObject {
    private var observation: NSKeyValueObservation?
    private var resetting = false
    private let volumeView = MPVolumeView(frame: CGRect(x: -1000, y: -1000, width: 1, height: 1))
    var onPress: ((RemoteKey) -> Void)?

    func start() {
        guard observation == nil else { return }
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, options: .mixWithOthers)
        try? session.setActive(true)
        // An off-screen volume view hides the system volume HUD.
        if volumeView.superview == nil,
           let window = UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first {
            window.addSubview(volumeView)
        }
        setVolume(0.5)
        observation = session.observe(\.outputVolume, options: [.old, .new]) { [weak self] _, change in
            guard let old = change.oldValue, let new = change.newValue, old != new else { return }
            Task { @MainActor in self?.changed(from: old, to: new) }
        }
    }

    func stop() {
        observation?.invalidate()
        observation = nil
        volumeView.removeFromSuperview()
    }

    private func changed(from old: Float, to new: Float) {
        if resetting {
            resetting = false
            return
        }
        onPress?(new > old ? .volumeUp : .volumeDown)
        if new <= 0.1 || new >= 0.9 { setVolume(0.5) }
    }

    private func setVolume(_ value: Float) {
        guard let slider = volumeView.subviews.compactMap({ $0 as? UISlider }).first else { return }
        resetting = AVAudioSession.sharedInstance().outputVolume != value
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { slider.value = value }
    }
}
