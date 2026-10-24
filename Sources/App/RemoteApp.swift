import SwiftUI

@main
struct RemoteApp: App {
    @StateObject private var remote = RemoteController.shared
    @StateObject private var prefs = Preferences()
    @Environment(\.scenePhase) private var phase
    @State private var screen = Screen.splash

    private enum Screen { case splash, home, remote }

    init() {
        WatchBridge.shared.start()
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                switch screen {
                case .splash:
                    SplashView().transition(.opacity)
                case .home:
                    HomeView { withAnimation(.easeInOut(duration: 0.3)) { screen = .remote } }
                        .transition(.move(edge: .leading).combined(with: .opacity))
                case .remote:
                    RemoteView { withAnimation(.easeInOut(duration: 0.3)) { screen = .home } }
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .environmentObject(remote)
            .environmentObject(prefs)
            .preferredColorScheme(.dark)
            .task {
                try? await Task.sleep(for: .seconds(1.4))
                withAnimation(.easeInOut(duration: 0.4)) { screen = .home }
            }
            .onChange(of: phase) { _, newPhase in
                guard newPhase == .active else { return }
                remote.connect()
                remote.scan()
            }
            .onReceive(remote.$status) { _ in LiveActivity.shared.update(remote) }
            .onReceive(remote.$sleepAt) { _ in LiveActivity.shared.update(remote) }
        }
    }
}

struct RemoteView: View {
    @EnvironmentObject private var remote: RemoteController
    @EnvironmentObject private var prefs: Preferences
    @Environment(\.scenePhase) private var phase
    var onHome: () -> Void = {}

    @State private var showingPicker = false
    @State private var showingKeyboard = false
    @State private var showingSleep = false
    @State private var code = ""
    @StateObject private var volumeButtons = VolumeButtons()
    @ObservedObject private var activity = LiveActivity.shared

    private var theme: Theme { prefs.theme }

    var body: some View {
        // Scrolls so the trending strip fits below the controls on smaller phones.
        ScrollView {
        VStack(spacing: 14) {
            header
            appStrip
            toolRow
            HStack {
                key("power", .power, tint: .red)
                Spacer()
                key("house.fill", .home)
            }
            // Volume and channel sit either side of the pad.
            HStack(spacing: 10) {
                rocker(up: ("speaker.wave.3.fill", .volumeUp), down: ("speaker.wave.1.fill", .volumeDown), label: "VOL")
                Spacer(minLength: 0)
                if prefs.padStyle == .trackpad {
                    Trackpad(theme: theme, press: press)
                } else {
                    dpad
                }
                Spacer(minLength: 0)
                rocker(up: ("chevron.up", .channelUp), down: ("chevron.down", .channelDown), label: "CH")
            }
            HStack {
                key("arrow.uturn.backward", .back)
                Spacer()
                key("playpause.fill", .playPause)
                Spacer()
                key("speaker.slash.fill", .mute)
            }
            sources
            TrendingCarousel()
        }
        .padding(.horizontal, 24)
        .padding(.top, 8)
        .padding(.bottom, 12)
        }
        .scrollIndicators(.hidden)
        .background(LinearGradient(colors: theme.background, startPoint: .top, endPoint: .bottom).ignoresSafeArea())
        .sheet(isPresented: $showingPicker) { TVPicker() }
        .sheet(isPresented: $showingKeyboard) { KeyboardSheet() }
        .confirmationDialog("Sleep timer", isPresented: $showingSleep, titleVisibility: .visible) {
            ForEach([15, 30, 45, 60, 90, 120], id: \.self) { minutes in
                Button("\(minutes) minutes") { remote.startSleepTimer(minutes: minutes) }
            }
            if remote.sleepAt != nil {
                Button("Cancel timer", role: .destructive) { remote.cancelSleepTimer() }
            }
        } message: {
            Text("The TV turns off when the timer ends.")
        }
        .alert("Enter code", isPresented: Binding(
            get: { remote.needsCodePrompt != nil && !showingPicker },
            set: { if !$0 { code = "" } }
        )) {
            TextField("Code", text: $code)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
            Button("OK") {
                remote.submitCode(code)
                code = ""
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(remote.needsCodePrompt ?? "")
        }
        .onAppear {
            volumeButtons.onPress = { remote.send($0) }
            updateVolumeButtons()
        }
        .onDisappear { volumeButtons.stop() }
        .onChange(of: phase) { _, _ in updateVolumeButtons() }
        .onChange(of: prefs.volumeButtons) { _, _ in updateVolumeButtons() }
    }

    private func updateVolumeButtons() {
        if prefs.volumeButtons && phase == .active { volumeButtons.start() } else { volumeButtons.stop() }
    }

    private var header: some View {
        HStack(alignment: .top) {
            Button { showingPicker = true } label: {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(remote.current?.name ?? "Choose a TV").font(.headline).lineLimit(1)
                        Image(systemName: "chevron.down").font(.caption.bold())
                    }
                    HStack(spacing: 6) {
                        Circle().fill(statusColor).frame(width: 8, height: 8)
                        Text(statusText).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
            }
            .foregroundStyle(.white)
            Spacer()
            Button { remote.connect() } label: { Image(systemName: "arrow.clockwise").padding(6) }
            Button(action: onHome) { Image(systemName: "square.grid.2x2").padding(6) }
        }
        .tint(theme.accent)
    }

    /// One-tap shortcuts to streaming apps, scrolling sideways.
    private var appStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(prefs.visibleApps(installed: remote.installedApps)) { app in
                    Button {
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        if remote.current == nil { showingPicker = true } else { remote.launch(app) }
                    } label: {
                        AppTile(app: app)
                    }
                    .accessibilityLabel(app.label)
                }
            }
            .padding(.horizontal, 24)
        }
        .padding(.horizontal, -24)
    }

    /// Keyboard, pad style, sleep timer and Dynamic Island.
    private var toolRow: some View {
        HStack(spacing: 10) {
            tool(prefs.padStyle == .dpad ? "hand.draw" : "dpad", prefs.padStyle == .dpad ? "Swipe" : "Arrows") {
                prefs.padStyle = prefs.padStyle == .dpad ? .trackpad : .dpad
            }
            tool("keyboard", "Type") { showingKeyboard = true }
            tool("moon.zzz", sleepLabel, active: remote.sleepAt != nil) { showingSleep = true }
            tool("platter.filled.top.iphone", "Island", active: activity.isRunning) { activity.toggle(remote) }
        }
    }

    private var sleepLabel: String {
        guard let sleepAt = remote.sleepAt else { return "Sleep" }
        let minutes = max(1, Int(sleepAt.timeIntervalSinceNow / 60))
        return "\(minutes)m"
    }

    private func tool(_ symbol: String, _ label: String, active: Bool = false, action: @escaping () -> Void) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            action()
        } label: {
            VStack(spacing: 4) {
                Image(systemName: symbol).font(.body.weight(.semibold))
                Text(label).font(.caption2.weight(.semibold))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .foregroundStyle(active ? .black : .white)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(active ? theme.accent : theme.key))
        }
    }

    /// Quick input switching plus the TV's own settings menu.
    private var sources: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("SOURCES").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                ForEach((remote.current?.brand ?? .samsung).sourceKeys, id: \.self) { key in
                    pill(sourceSymbol(key), sourceLabel(key), key)
                }
            }
            HStack(spacing: 8) {
                pill("gearshape.fill", "TV Settings", .settings)
                pill("xmark", "Exit", .exit)
            }
        }
    }

    private func sourceLabel(_ key: RemoteKey) -> String {
        switch key {
        case .tv: "TV"
        case .hdmi1: "HDMI 1"
        case .hdmi2: "HDMI 2"
        case .hdmi3: "HDMI 3"
        case .hdmi4: "HDMI 4"
        case .nextHDMI: "Next HDMI"
        default: "All inputs"
        }
    }

    private func sourceSymbol(_ key: RemoteKey) -> String {
        switch key {
        case .tv: "tv"
        case .nextHDMI: "arrow.triangle.2.circlepath"
        case .input: "rectangle.on.rectangle"
        default: "cable.connector"
        }
    }

    private func pill(_ symbol: String, _ label: String, _ key: RemoteKey) -> some View {
        Button { press(key) } label: {
            Label(label, systemImage: symbol)
                .font(.footnote.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity)
                .frame(height: 42)
                .foregroundStyle(.white)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(theme.key))
        }
    }

    private var dpad: some View {
        ZStack {
            Circle().fill(theme.pad).frame(width: 216, height: 216)
            VStack(spacing: 0) {
                arrow("chevron.up", .up)
                HStack(spacing: 0) {
                    arrow("chevron.left", .left)
                    Button { press(.ok) } label: {
                        Text("OK").font(.title2.bold()).frame(width: 80, height: 80)
                            .background(Circle().fill(theme.okButton))
                    }
                    arrow("chevron.right", .right)
                }
                arrow("chevron.down", .down)
            }
        }
        .foregroundStyle(.white)
    }

    private func arrow(_ symbol: String, _ key: RemoteKey) -> some View {
        Button { press(key) } label: {
            Image(systemName: symbol).font(.title2.bold()).frame(width: 68, height: 68).contentShape(Rectangle())
        }
    }

    private func key(_ symbol: String, _ key: RemoteKey, tint: Color = .white) -> some View {
        Button { press(key) } label: {
            Image(systemName: symbol).font(.title2).foregroundStyle(tint)
                .frame(width: 60, height: 60).background(Circle().fill(theme.key))
        }
    }

    private func rocker(up: (String, RemoteKey), down: (String, RemoteKey), label: String) -> some View {
        VStack(spacing: 0) {
            Button { press(up.1) } label: { Image(systemName: up.0).frame(width: 56, height: 86) }
            Text(label).font(.caption.bold()).foregroundStyle(.secondary)
            Button { press(down.1) } label: { Image(systemName: down.0).frame(width: 56, height: 86) }
        }
        .font(.title2).foregroundStyle(.white)
        .background(Capsule().fill(theme.key))
    }

    private func press(_ key: RemoteKey) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        if remote.current == nil { showingPicker = true } else { remote.send(key) }
    }

    private var statusColor: Color {
        if remote.waking { return .yellow }
        switch remote.status {
        case .connected: return .green
        case .connecting, .waitingForAllow, .needsCode: return .yellow
        case .disconnected, .failed: return .red
        }
    }

    private var statusText: String {
        if remote.waking { return "Turning the TV on…" }
        switch remote.status {
        case .connected: return "Connected"
        case .connecting: return "Connecting…"
        case .waitingForAllow: return "Choose Allow on the TV"
        case .needsCode: return "Waiting for code"
        case .disconnected: return remote.current == nil ? "Tap to find your TV" : "Not connected"
        case .failed(let message): return message
        }
    }
}

struct TVPicker: View {
    @EnvironmentObject private var remote: RemoteController
    @Environment(\.dismiss) private var dismiss
    @State private var manualBrand = TVBrand.samsung
    @State private var manualHost = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(remote.devices) { device in
                        Button {
                            remote.select(device)
                            dismiss()
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(device.name).foregroundStyle(.primary)
                                    Text("\(device.brand.label) · \(device.host)").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if device.id == remote.current?.id { Image(systemName: "checkmark") }
                            }
                        }
                    }
                    .onDelete { offsets in offsets.map { remote.devices[$0] }.forEach(remote.remove) }

                    if remote.devices.isEmpty && !remote.scanning {
                        Text("No TVs found yet. Make sure the TV is on.").foregroundStyle(.secondary)
                    }
                } header: {
                    HStack {
                        Text("TVs on your Wi-Fi")
                        Spacer()
                        if remote.scanning {
                            ProgressView().controlSize(.small)
                            Text("Searching…")
                        } else {
                            Button("Search again") { remote.scan() }.font(.footnote)
                        }
                    }
                } footer: {
                    Text("Finds Samsung, LG, Roku, Sony, Vizio, Panasonic, Fire TV and Google TV / Android TV sets (including TCL, Hisense and Philips) on the same Wi-Fi as this phone. Fire TV needs ADB debugging turned on in its Developer options.")
                }

                Section {
                    DisclosureGroup("Add a TV by address") {
                        Picker("Brand", selection: $manualBrand) {
                            ForEach(TVBrand.allCases) { Text($0.label).tag($0) }
                        }
                        TextField("192.168.1.20", text: $manualHost).keyboardType(.decimalPad)
                        Button("Add and connect") {
                            let host = manualHost.trimmingCharacters(in: .whitespaces)
                            remote.select(TVDevice(brand: manualBrand, host: host, name: "\(manualBrand.label) (\(host))"))
                            dismiss()
                        }
                        .disabled(manualHost.isEmpty)
                    }
                } footer: {
                    Text("Only needed if a TV doesn't show up above.")
                }
            }
            .navigationTitle("Choose TV")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .onAppear { remote.scan() }
    }
}
