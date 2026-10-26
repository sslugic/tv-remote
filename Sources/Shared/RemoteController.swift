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
        Task {
            await Discovery.scan { [weak self] device in self?.add(device) }
            scanning = false
            if current == nil, let first = devices.first { select(first) }
        }
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
