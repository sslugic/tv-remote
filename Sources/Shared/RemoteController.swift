import AVFoundation
import Foundation
import Network

/// Holds the known TVs, the selected one, and the live driver for it.
/// One shared instance serves the app, Siri/Shortcuts, widgets and the watch.
@MainActor final class RemoteController: ObservableObject {
    static let shared = RemoteController()

    @Published private(set) var devices: [TVDevice] = []
    @Published private(set) var current: TVDevice?
    @Published private(set) var status: DriverStatus = .disconnected
    @Published private(set) var scanning = false
    /// Streaming apps installed on the current TV, or nil if the TV can't tell us.
    @Published private(set) var installedApps: Set<StreamingApp>?
    @Published private(set) var sleepAt: Date?
    @Published private(set) var waking = false
    /// Whether the TV's on-screen keyboard is open, or nil if this TV doesn't report it.
    @Published private(set) var tvKeyboardOpen: Bool?

    private var driver: TVDriver?
    private var sleepTask: Task<Void, Never>?
    private let keepAlive = SilentAudio()

    private init() {
        if let data = UserDefaults.standard.data(forKey: "devices"),
           let saved = try? JSONDecoder().decode([TVDevice].self, from: data) {
            devices = saved
        } else if let host = UserDefaults.standard.string(forKey: "host") {
            // Version 1 only knew one Samsung TV by address.
            devices = [TVDevice(brand: .samsung, host: host, name: "Samsung TV")]
            migrateSamsungToken(host: host)
        }
        let currentID = UserDefaults.standard.string(forKey: "currentDevice")
        current = devices.first { $0.id == currentID } ?? devices.first
    }

    var needsCodePrompt: String? {
        if case .needsCode(let prompt) = status { prompt } else { nil }
    }

    func select(_ device: TVDevice) {
        add(device)
        current = devices.first { $0.id == device.id }
        UserDefaults.standard.set(device.id, forKey: "currentDevice")
        connect()
    }

    func add(_ device: TVDevice) {
        if let i = devices.firstIndex(where: { $0.id == device.id }) {
            // Keep a name the driver already learned over a generic one from a scan.
            if devices[i].name.hasPrefix("Google TV (") || devices[i].name == "LG TV" { devices[i].name = device.name }
            if devices[i].mac == nil { devices[i].mac = device.mac }
            if current?.id == device.id { current = devices[i] }
        } else if let mac = device.mac,
                  let i = devices.firstIndex(where: { $0.brand == device.brand && $0.mac?.lowercased() == mac.lowercased() }) {
            // Same TV at a new address (the router gave it a new IP): move it instead of listing it twice.
            let old = devices[i]
            moveStoredValues(from: old, to: device)
            devices[i].host = device.host
            if current?.id == old.id {
                current = devices[i]
                UserDefaults.standard.set(devices[i].id, forKey: "currentDevice")
                connect()
            }
        } else {
            devices.append(device)
            devices.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
        save()
    }

    func remove(_ device: TVDevice) {
        devices.removeAll { $0.id == device.id }
        if current?.id == device.id {
            driver?.disconnect()
            driver = nil
            current = devices.first
            status = .disconnected
        }
        save()
    }

    func connect() {
        driver?.disconnect()
        installedApps = nil
        guard let device = current else { driver = nil; status = .disconnected; return }
        let driver = device.brand.makeDriver(for: device)
        driver.onStatus = { [weak self, weak driver] status in
            guard let self, let driver, driver === self.driver else { return }
            self.status = status
            if status == .connected {
                if self.waking {
                    self.waking = false
                    driver.finishPowerOn()
                }
                Task { self.installedApps = await driver.installedApps() }
            }
        }
        driver.onName = { [weak self] name in self?.update(device) { $0.name = name } }
        driver.onMAC = { [weak self] mac in self?.update(device) { $0.mac = mac } }
        driver.onKeyboard = { [weak self] open in self?.tvKeyboardOpen = open }
        tvKeyboardOpen = nil
        self.driver = driver
        driver.connect()
    }

    func send(_ key: RemoteKey) {
        if key == .power, let device = current, let driver {
            guard status == .connected else { return wake(device) }
            // A TV that went to sleep can leave the connection looking alive, so check first.
            Task {
                if await driver.isReachable() { driver.send(.power) } else { wake(device) }
            }
            return
        }
        driver?.send(key)
    }

    func launch(_ app: StreamingApp) { driver?.launch(app) }
    func submitCode(_ code: String) { driver?.submitCode(code) }
    func type(_ text: String, previous: String) { driver?.type(text, previous: previous) }

    /// Opens YouTube on the TV with search results for `query`. False if the TV doesn't offer YouTube over DIAL.
    func searchYouTube(_ query: String) async -> Bool {
        guard let host = current?.host else { return false }
        return await YouTubeSearch.search(query, host: host)
    }

    func currentApp() async -> CurrentApp { await driver?.currentApp() ?? .unknown }

    /// Searches wherever the TV is: YouTube opens straight on its results (its own keyboard can't take typing),
    /// other apps get the text typed into their search box, and with no app open the TV's own search is used.
    /// Returns a note for the user when they still need to do something, or nil when it's done.
    func search(_ query: String) async -> String? {
        switch await currentApp() {
        case .app(.youtube):
            if await searchYouTube(query) { return nil }
            type(query, previous: "")
            return "Open YouTube's search box. Your text goes in when its keyboard opens."
        case .app(let app):
            type(query, previous: "")
            if tvKeyboardOpen == true { return nil }
            return "Open \(app.label)'s search box on the TV. Your text goes in as soon as its keyboard opens, then tap Enter."
        case .tv, .unknown:
            searchOnTV(query)
            return nil
        }
    }

    /// Opens the TV's own search and types `query` into it once its keyboard is open.
    func searchOnTV(_ query: String) {
        send(.search)
        driver?.type(query, previous: "")
    }

    /// Runs `action` once the TV is connected, connecting first if needed. Used by Siri, widgets and the watch.
    func whenConnected(_ action: @escaping (RemoteController) -> Void) async throws {
        if status != .connected { connect() }
        for _ in 0..<40 where status != .connected {
            if case .failed(let message) = status { throw RemoteError(message) }
            try await Task.sleep(for: .milliseconds(150))
        }
        guard status == .connected else { throw RemoteError("Couldn't reach the TV. Open \(AppInfo.name) to check it.") }
        action(self)
    }

    func scan() {
        guard !scanning else { return }
        scanning = true
        seenInScan = []
        Task {
            await Discovery.scan { [weak self] device in
                self?.seenInScan.insert(device.id)
                self?.add(device)
            }
            pruneUnseen()
            scanning = false
            if current == nil, let first = devices.first { select(first) }
        }
    }

    private var seenInScan: Set<String> = []

    /// After a scan, forget TVs that didn't answer so the list shows only what's on the network now.
    /// The selected TV stays even if it's off, so it can still be woken. Skipped when the scan found
    /// nothing at all (off Wi-Fi or a network hiccup) so the list isn't wiped by mistake.
    private func pruneUnseen() {
        guard !seenInScan.isEmpty else { return }
        let stale = devices.filter { !seenInScan.contains($0.id) && $0.id != current?.id }
        guard !stale.isEmpty else { return }
        devices.removeAll { stale.contains($0) }
        save()
    }

    // MARK: - Power on

    /// The TV is off: send Wake-on-LAN (when we know its MAC), reconnect while it boots,
    /// and let the driver finish turning the screen on once connected.
    private func wake(_ device: TVDevice) {
        waking = true
        if let mac = device.mac { WakeOnLAN.send(mac: mac, host: device.host) }
        connect()
        Task {
            for delay in [2, 3, 3, 4, 4, 5] {
                try? await Task.sleep(for: .seconds(delay))
                guard waking, current?.id == device.id, status != .connected else { return }
                if let mac = device.mac { WakeOnLAN.send(mac: mac, host: device.host) }
                connect()
            }
            waking = false
        }
    }

    // MARK: - Sleep timer

    /// Turns the TV off after `minutes`. The app stays alive in the background until then.
    func startSleepTimer(minutes: Int) {
        sleepTask?.cancel()
        let fireAt = Date().addingTimeInterval(TimeInterval(minutes * 60))
        sleepAt = fireAt
        keepAlive.start()
        sleepTask = Task {
            try? await Task.sleep(until: .now + .seconds(minutes * 60))
            guard !Task.isCancelled else { return }
            try? await whenConnected { $0.driver?.send(.power) }
            sleepAt = nil
            keepAlive.stop()
        }
    }

    func cancelSleepTimer() {
        sleepTask?.cancel()
        sleepTask = nil
        sleepAt = nil
        keepAlive.stop()
    }

    // MARK: - Storage

    private func update(_ device: TVDevice, _ change: (inout TVDevice) -> Void) {
        guard let i = devices.firstIndex(where: { $0.id == device.id }) else { return }
        var updated = devices[i]
        change(&updated)
        guard updated != devices[i] else { return }
        devices[i] = updated
        if current?.id == device.id { current = updated }
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(devices) { UserDefaults.standard.set(data, forKey: "devices") }
    }

    /// Carries pairing tokens and other per-TV values over when a TV's address changes.
    private func moveStoredValues(from old: TVDevice, to new: TVDevice) {
        let defaults = UserDefaults.standard
        let suffix = "-\(old.id)"
        for key in defaults.dictionaryRepresentation().keys where key.hasSuffix(suffix) {
            let base = String(key.dropLast(suffix.count))
            defaults.set(defaults.object(forKey: key), forKey: "\(base)-\(new.id)")
            defaults.removeObject(forKey: key)
        }
    }

    private func migrateSamsungToken(host: String) {
        guard let token = UserDefaults.standard.string(forKey: "token-\(host)") else { return }
        DeviceStore(device: TVDevice(brand: .samsung, host: host, name: ""))["token"] = token
    }
}

struct RemoteError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Wake-on-LAN magic packet: 6 × 0xFF then the MAC 16 times, sent to the TV and the subnet broadcast.
enum WakeOnLAN {
    static func send(mac: String, host: String) {
        let bytes = mac.split(whereSeparator: { $0 == ":" || $0 == "-" }).compactMap { UInt8($0, radix: 16) }
        guard bytes.count == 6 else { return }
        var packet = Data(repeating: 0xff, count: 6)
        for _ in 0..<16 { packet.append(contentsOf: bytes) }

        let broadcast = host.split(separator: ".").prefix(3).joined(separator: ".") + ".255"
        for target in [host, broadcast] {
            let connection = NWConnection(host: .init(target), port: 9, using: .udp)
            connection.stateUpdateHandler = { state in
                if case .ready = state {
                    connection.send(content: packet, completion: .contentProcessed { _ in connection.cancel() })
                }
            }
            connection.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) { connection.cancel() }
        }
    }
}

/// Plays silence so iOS keeps the app running in the background while a sleep timer is pending.
final class SilentAudio {
    private var player: AVAudioPlayer?

    func start() {
        guard player == nil else { return }
        try? AVAudioSession.sharedInstance().setCategory(.playback, options: .mixWithOthers)
        try? AVAudioSession.sharedInstance().setActive(true)
        // One second of 8 kHz, 16-bit mono silence as a WAV file.
        var wav = Data("RIFF".utf8)
        let samples = 8000
        func le32(_ v: Int) -> Data { withUnsafeBytes(of: UInt32(v).littleEndian) { Data($0) } }
        func le16(_ v: Int) -> Data { withUnsafeBytes(of: UInt16(v).littleEndian) { Data($0) } }
        wav += le32(36 + samples * 2) + Data("WAVEfmt ".utf8) + le32(16) + le16(1) + le16(1)
        wav += le32(8000) + le32(16000) + le16(2) + le16(16) + Data("data".utf8) + le32(samples * 2)
        wav += Data(count: samples * 2)
        player = try? AVAudioPlayer(data: wav)
        player?.numberOfLoops = -1
        player?.volume = 0
        player?.play()
    }

    func stop() {
        player?.stop()
        player = nil
    }
}
