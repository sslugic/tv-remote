import Foundation

/// Samsung Tizen TVs (2016+): WebSocket remote API on wss://<tv>:8002.
/// The first connection shows an "Allow" prompt on the TV; the returned token skips it next time.
@MainActor final class SamsungDriver: TVDriver {
    var onStatus: ((DriverStatus) -> Void)?
    var onName: ((String) -> Void)?
    var onMAC: ((String) -> Void)?
    var onKeyboard: ((Bool) -> Void)?

    private let device: TVDevice
    private let store: DeviceStore
    private var task: URLSessionWebSocketTask?
    private var connected = false
    /// Keys pressed while (re)connecting, sent once the TV accepts the connection.
    private var pending: [String] = []
    /// Text waiting to go to the TV keyboard, sent once typing pauses.
    private var typedText: String?
    private var typingDelay: Task<Void, Never>?
    /// The TV only accepts typed text while its own keyboard is open; it tells us with imeStart/imeEnd.
    private var keyboardOpen = false
    private var keyboardWait: Task<Void, Never>?
    private var heartbeat: Task<Void, Never>?
    private var connectTimeout: Task<Void, Never>?
    private var timeoutRetries = 0
    private let clientName = Data("iPhone Remote".utf8).base64EncodedString()

    init(device: TVDevice) {
        self.device = device
        store = DeviceStore(device: device)
    }

    func connect() {
        disconnect()
        fetchName()
        var comps = URLComponents()
        comps.scheme = "wss"
        comps.host = device.host
        comps.port = 8002
        comps.path = "/api/v2/channels/samsung.remote.control"
        comps.queryItems = [URLQueryItem(name: "name", value: clientName)]
        if let token = store["token"] { comps.queryItems?.append(URLQueryItem(name: "token", value: token)) }

        let waitingForAllow = store["token"] == nil
        onStatus?(waitingForAllow ? .waitingForAllow : .connecting)
        // While the TV shows its Allow prompt it holds the handshake open, so give the person time to answer.
        let task = (waitingForAllow ? LocalTLS.patientSession : LocalTLS.session).webSocketTask(with: comps.url!)
        self.task = task
        task.resume()
        receive(on: task)

        // A TV that is still booting can leave the handshake hanging; retry instead of waiting for iOS.
        guard !waitingForAllow else { return }
        connectTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, let self, self.task === task, !self.connected else { return }
            self.timeoutRetries += 1
            if self.timeoutRetries > 6 {
                self.timeoutRetries = 0
                self.pending = []
                self.disconnect()
                self.onStatus?(.failed("The TV isn't answering. Check that it's on."))
            } else {
                self.reconnect()
            }
        }
    }

    func disconnect() {
        heartbeat?.cancel()
        connectTimeout?.cancel()
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        connected = false
    }

    func send(_ key: RemoteKey) {
        // Samsung's search key does nothing inside apps like YouTube, so go Home first.
        if key == .search {
            sendCode("KEY_HOME")
            Task {
                try? await Task.sleep(for: .milliseconds(2500))
                sendCode("KEY_SEARCH")
            }
            return
        }
        // Enter right after typing: deliver the text first so the search uses all of it.
        if key == .ok, typedText != nil {
            flushTyping()
            Task {
                try? await Task.sleep(for: .milliseconds(400))
                sendCode(code(for: key))
            }
            return
        }
        sendCode(code(for: key))
    }

    private func sendCode(_ code: String) {
        guard connected, let task else {
            // Hold the press; only start connecting if no attempt is already under way.
            if pending.count < 5 { pending.append(code) }
            if task == nil { connect() }
            return
        }
        let payload: [String: Any] = [
            "method": "ms.remote.control",
            "params": ["Cmd": "Click", "DataOfCmd": code, "Option": "false", "TypeOfRemote": "SendRemoteKey"],
        ]
        task.send(.string(payload.jsonString)) { [weak self] error in
            guard error != nil else { return }
            Task { @MainActor in
                guard let self, self.task === task else { return }
                self.pending.append(code)
                self.reconnect()
            }
        }
    }

    /// Drops a dead connection and opens a new one, keeping any held key presses.
    private func reconnect() {
        let held = pending
        connect()
        pending = held
    }

    /// The TV can drop the connection without telling us (for example while it turns on or goes to sleep),
    /// and iOS then takes minutes to notice. A ping every few seconds catches that quickly.
    private func startHeartbeat(on task: URLSessionWebSocketTask) {
        heartbeat?.cancel()
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(4))
                guard !Task.isCancelled, let self, self.task === task, self.connected else { return }
                let answered = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                    var done = false
                    let finish: @Sendable (Bool) -> Void = { ok in
                        Task { @MainActor in
                            guard !done else { return }
                            done = true
                            continuation.resume(returning: ok)
                        }
                    }
                    task.sendPing { error in finish(error == nil) }
                    Task { try? await Task.sleep(for: .seconds(2)); finish(false) }
                }
                guard !Task.isCancelled, self.task === task else { return }
                if !answered {
                    self.onStatus?(.connecting)
                    self.reconnect()
                    return
                }
            }
        }
    }

    func launch(_ app: StreamingApp) {
        Task {
            for id in app.samsungIDs {
                let url = URL(string: "http://\(device.host):8001/api/v2/applications/\(id)")!
                // GET tells us whether this ID is installed on this TV.
                guard let (_, info) = try? await LocalTLS.session.data(from: url),
                      (info as? HTTPURLResponse)?.statusCode == 200 else { continue }
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                if let (_, response) = try? await LocalTLS.session.data(for: request),
                   (response as? HTTPURLResponse)?.statusCode == 200 { return }
                sendLaunchEvent(id)
                return
            }
        }
    }

    /// Samsung replaces the whole text field with each update and tends to keep only the first update per
    /// keyboard session, so wait until typing pauses and send the full text once.
    func type(_ text: String, previous: String) {
        typedText = text
        typingDelay?.cancel()
        typingDelay = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            self?.flushTyping()
        }
    }

    /// Sends the waiting text once the connection is up and the TV's keyboard is open.
    /// Text sent before the keyboard opens is dropped by the TV (it can take several seconds to open).
    /// Some models never report the keyboard, so after a while send anyway.
    private func flushTyping() {
        typingDelay?.cancel()
        guard let text = typedText else { return }
        guard connected, let task else {
            if task == nil { connect() }
            return
        }
        guard keyboardOpen else {
            if keyboardWait == nil {
                keyboardWait = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(12))
                    guard !Task.isCancelled, let self else { return }
                    self.keyboardWait = nil
                    self.keyboardOpen = true
                    self.flushTyping()
                    self.keyboardOpen = false
                }
            }
            return
        }
        typedText = nil
        let payload: [String: Any] = [
            "method": "ms.remote.control",
            "params": [
                "Cmd": Data(text.utf8).base64EncodedString(),
                "DataOfCmd": "base64",
                "TypeOfRemote": "SendInputString",
            ],
        ]
        task.send(.string(payload.jsonString)) { [weak self] error in
            guard error != nil else { return }
            Task { @MainActor in
                guard let self else { return }
                if self.typedText == nil { self.typedText = text }
                self.reconnect()
            }
        }
    }

    func isReachable() async -> Bool {
        var request = URLRequest(url: URL(string: "http://\(device.host):8001/api/v2/")!)
        request.timeoutInterval = 1.5
        return (try? await LocalTLS.session.data(for: request)) != nil
    }

    /// Wake-on-LAN only brings a Samsung to standby (network up, screen off); Power then turns the screen on.
    func finishPowerOn() {
        let url = URL(string: "http://\(device.host):8001/api/v2/")!
        Task {
            guard let (data, _) = try? await LocalTLS.session.data(from: url),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let state = (json["device"] as? [String: Any])?["PowerState"] as? String,
                  state != "on" else { return }
            send(.power)
            // Turning on restarts the TV's remote service and silently kills this connection.
            try? await Task.sleep(for: .seconds(4))
            reconnect()
        }
    }

    /// Samsung reports "visible": true for the app in the foreground.
    func currentApp() async -> CurrentApp {
        for app in StreamingApp.allCases {
            for id in app.samsungIDs {
                let url = URL(string: "http://\(device.host):8001/api/v2/applications/\(id)")!
                guard let (data, _) = try? await LocalTLS.session.data(from: url),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                if json["visible"] as? Bool == true { return .app(app) }
            }
        }
        return .tv
    }

    func installedApps() async -> Set<StreamingApp>? {
        var installed = Set<StreamingApp>()
        for app in StreamingApp.allCases {
            for id in app.samsungIDs {
                let url = URL(string: "http://\(device.host):8001/api/v2/applications/\(id)")!
                if let (_, response) = try? await LocalTLS.session.data(from: url),
                   (response as? HTTPURLResponse)?.statusCode == 200 {
                    installed.insert(app)
                    break
                }
            }
        }
        return installed
    }

    private func sendLaunchEvent(_ appID: String) {
        guard connected, let task else { return }
        let payload: [String: Any] = [
            "method": "ms.channel.emit",
            "params": ["event": "ed.apps.launch", "to": "host", "data": ["appId": appID, "action_type": "DEEP_LINK"]],
        ]
        task.send(.string(payload.jsonString)) { _ in }
    }

    private func code(for key: RemoteKey) -> String {
        switch key {
        case .power: "KEY_POWER"
        case .home: "KEY_HOME"
        case .back: "KEY_RETURN"
        case .input: "KEY_SOURCE"
        case .up: "KEY_UP"
        case .down: "KEY_DOWN"
        case .left: "KEY_LEFT"
        case .right: "KEY_RIGHT"
        case .ok: "KEY_ENTER"
        case .volumeUp: "KEY_VOLUP"
        case .volumeDown: "KEY_VOLDOWN"
        case .mute: "KEY_MUTE"
        case .channelUp: "KEY_CHUP"
        case .channelDown: "KEY_CHDOWN"
        case .playPause: "KEY_PLAY_BACK"
        case .tv: "KEY_TV"
        case .nextHDMI: "KEY_HDMI"
        case .hdmi1: "KEY_HDMI1"
        case .hdmi2: "KEY_HDMI2"
        case .hdmi3: "KEY_HDMI3"
        case .hdmi4: "KEY_HDMI4"
        case .settings: "KEY_MENU"
        case .search: "KEY_SEARCH"
        case .exit: "KEY_EXIT"
        }
    }

    /// Reads the TV's own name (e.g. "Samsung 7 Series (65)") from its info endpoint.
    private func fetchName() {
        let url = URL(string: "http://\(device.host):8001/api/v2/")!
        Task {
            guard let (data, _) = try? await LocalTLS.session.data(from: url),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let raw = (json["device"] as? [String: Any])?["name"] as? String ?? json["name"] as? String
            else { return }
            onName?(raw.replacingOccurrences(of: "[TV] ", with: ""))
            if let mac = (json["device"] as? [String: Any])?["wifiMac"] as? String { onMAC?(mac) }
        }
    }

    private func receive(on task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            Task { @MainActor in
                guard let self, self.task === task else { return }
                switch result {
                case .failure(let error):
                    let wasConnected = self.connected
                    self.connected = false
                    if wasConnected || !self.pending.isEmpty {
                        // Lost a working connection: try again right away rather than showing an error.
                        self.onStatus?(.connecting)
                        self.reconnect()
                    } else {
                        self.task = nil
                        self.onStatus?(.failed(error.localizedDescription))
                    }
                case .success(let message):
                    if case .string(let text) = message { self.handle(text) }
                    self.receive(on: task)
                }
            }
        }
    }

    private func handle(_ text: String) {
        guard let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let event = json["event"] as? String else { return }
        switch event {
        case "ms.channel.connect":
            if let token = (json["data"] as? [String: Any])?["token"] as? String { store["token"] = token }
            connected = true
            timeoutRetries = 0
            flushTyping()
            connectTimeout?.cancel()
            onStatus?(.connected)
            onKeyboard?(keyboardOpen)
            if let task { startHeartbeat(on: task) }
            let held = pending
            pending = []
            held.forEach(sendCode)
        case "ms.remote.imeStart":
            keyboardOpen = true
            keyboardWait?.cancel()
            keyboardWait = nil
            onKeyboard?(true)
            // Give the keyboard a moment to take focus, then send anything typed while it was opening.
            Task {
                try? await Task.sleep(for: .milliseconds(300))
                flushTyping()
            }
        case "ms.remote.imeEnd":
            keyboardOpen = false
            onKeyboard?(false)
        case "ms.channel.unauthorized":
            store["token"] = nil
            onStatus?(.failed("Denied on the TV. Reconnect and choose Allow."))
        case "ms.channel.timeOut":
            onStatus?(.failed("Timed out waiting for Allow on the TV."))
        default:
            break
        }
    }
}
