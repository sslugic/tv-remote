import Foundation

/// LG webOS TVs: SSAP over WebSocket (wss port 3001, falling back to ws port 3000).
/// The first connection shows a pairing prompt on the TV; the returned client key skips it next time.
/// Navigation buttons go through a second "pointer input" socket the TV hands out.
@MainActor final class LGDriver: TVDriver {
    var onStatus: ((DriverStatus) -> Void)?
    var onName: ((String) -> Void)?

    private let device: TVDevice
    private let store: DeviceStore
    private var task: URLSessionWebSocketTask?
    private var pointer: URLSessionWebSocketTask?
    private var registered = false
    private var useSecure = true
    private var nextID = 0
    private var handlers: [String: ([String: Any]) -> Void] = [:]
    private var playing = true

    init(device: TVDevice) {
        self.device = device
        store = DeviceStore(device: device)
    }

    func connect() {
        disconnect()
        let url = URL(string: useSecure ? "wss://\(device.host):3001" : "ws://\(device.host):3000")!
        onStatus?(store["clientKey"] == nil ? .waitingForAllow : .connecting)
        let task = LocalTLS.session.webSocketTask(with: url)
        self.task = task
        task.resume()
        receive(on: task)
        register()
    }

    func disconnect() {
        task?.cancel(with: .goingAway, reason: nil)
        pointer?.cancel(with: .goingAway, reason: nil)
        task = nil
        pointer = nil
        registered = false
        handlers.removeAll()
    }

    func send(_ key: RemoteKey) {
        guard registered else { connect(); return }
        switch key {
        case .power: request("ssap://system/turnOff")
        case .input: request("ssap://system.launcher/launch", payload: ["id": "com.webos.app.inputpicker"])
        case .tv: request("ssap://tv/switchInput", payload: ["inputId": "ATV"])
        case .nextHDMI: request("ssap://system.launcher/launch", payload: ["id": "com.webos.app.inputpicker"])
        case .hdmi1: request("ssap://tv/switchInput", payload: ["inputId": "HDMI_1"])
        case .hdmi2: request("ssap://tv/switchInput", payload: ["inputId": "HDMI_2"])
        case .hdmi3: request("ssap://tv/switchInput", payload: ["inputId": "HDMI_3"])
        case .hdmi4: request("ssap://tv/switchInput", payload: ["inputId": "HDMI_4"])
        case .settings: pointerButton("MENU")
        case .exit: pointerButton("EXIT")
        case .playPause:
            playing.toggle()
            request(playing ? "ssap://media.controls/play" : "ssap://media.controls/pause")
        case .volumeUp: pointerButton("VOLUMEUP", fallback: "ssap://audio/volumeUp")
        case .volumeDown: pointerButton("VOLUMEDOWN", fallback: "ssap://audio/volumeDown")
        case .channelUp: pointerButton("CHANNELUP", fallback: "ssap://tv/channelUp")
        case .channelDown: pointerButton("CHANNELDOWN", fallback: "ssap://tv/channelDown")
        case .mute: pointerButton("MUTE")
        case .home: pointerButton("HOME")
        case .back: pointerButton("BACK")
        case .up: pointerButton("UP")
        case .down: pointerButton("DOWN")
        case .left: pointerButton("LEFT")
        case .right: pointerButton("RIGHT")
        case .ok: pointerButton("ENTER")
        }
    }

    func launch(_ app: StreamingApp) {
        guard registered else { connect(); return }
        request("ssap://system.launcher/launch", payload: ["id": app.lgID])
    }

    func type(_ text: String, previous: String) {
        guard registered else { return }
        let edit = TextEdit(from: previous, to: text)
        if edit.deleteCount > 0 { request("ssap://com.webos.service.ime/deleteCharacters", payload: ["count": edit.deleteCount]) }
        if !edit.insert.isEmpty { request("ssap://com.webos.service.ime/insertText", payload: ["text": edit.insert, "replace": 0]) }
    }

    func installedApps() async -> Set<StreamingApp>? {
        guard registered else { return nil }
        return await withCheckedContinuation { continuation in
            request("ssap://com.webos.applicationManager/listLaunchPoints") { payload in
                let ids = Set(((payload["launchPoints"] as? [[String: Any]]) ?? []).compactMap { $0["id"] as? String })
                continuation.resume(returning: Set(StreamingApp.allCases.filter { ids.contains($0.lgID) }))
            }
        }
    }

    // MARK: - SSAP

    private func register() {
        var payload: [String: Any] = [
            "forcePairing": false,
            "pairingType": "PROMPT",
            "manifest": [
                "manifestVersion": 1,
                "appVersion": "1.0",
                "permissions": Self.permissions,
            ],
        ]
        if let key = store["clientKey"] { payload["client-key"] = key }
        nextID += 1
        let message: [String: Any] = ["type": "register", "id": "register_\(nextID)", "payload": payload]
        task?.send(.string(message.jsonString)) { _ in }
    }

    private func request(_ uri: String, payload: [String: Any] = [:], reply: (([String: Any]) -> Void)? = nil) {
        nextID += 1
        let id = "req_\(nextID)"
        if let reply { handlers[id] = reply }
        let message: [String: Any] = ["type": "request", "id": id, "uri": uri, "payload": payload]
        task?.send(.string(message.jsonString)) { _ in }
    }

    private func receive(on task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            Task { @MainActor in
                guard let self, self.task === task else { return }
                switch result {
                case .failure(let error):
                    if self.useSecure && !self.registered {
                        // Older webOS only listens on the plain port.
                        self.useSecure = false
                        self.connect()
                    } else {
                        self.registered = false
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
        guard let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return }
        let type = json["type"] as? String
        let payload = json["payload"] as? [String: Any] ?? [:]
        if type == "registered" {
            if let key = payload["client-key"] as? String { store["clientKey"] = key }
            registered = true
            onStatus?(.connected)
            openPointerSocket()
            request("ssap://system/getSystemInfo") { [weak self] info in
                if let model = info["modelName"] as? String { self?.onName?("LG \(model)") }
            }
        } else if type == "error", !registered {
            store["clientKey"] = nil
            onStatus?(.failed((json["error"] as? String) ?? "The TV refused pairing."))
        } else if let id = json["id"] as? String, let handler = handlers.removeValue(forKey: id) {
            handler(payload)
        }
    }

    // MARK: - Pointer input socket (buttons)

    private func openPointerSocket() {
        request("ssap://com.webos.service.networkinput/getPointerInputSocket") { [weak self] payload in
            guard let self, let path = payload["socketPath"] as? String, let url = URL(string: path) else { return }
            let pointer = LocalTLS.session.webSocketTask(with: url)
            self.pointer = pointer
            pointer.resume()
        }
    }

    private func pointerButton(_ name: String, fallback: String? = nil) {
        guard let pointer else {
            if let fallback { request(fallback) } else { openPointerSocket() }
            return
        }
        pointer.send(.string("type:button\nname:\(name)\n\n")) { [weak self] error in
            guard error != nil else { return }
            Task { @MainActor in self?.pointer = nil }
        }
    }

    private static let permissions = [
        "LAUNCH", "LAUNCH_WEBAPP", "APP_TO_APP", "CONTROL_AUDIO", "CONTROL_DISPLAY",
        "CONTROL_INPUT_JOYSTICK", "CONTROL_INPUT_MEDIA_RECORDING", "CONTROL_INPUT_MEDIA_PLAYBACK",
        "CONTROL_INPUT_TV", "CONTROL_POWER", "CONTROL_MOUSE_AND_KEYBOARD", "CONTROL_INPUT_TEXT",
        "CONTROL_TV_SCREEN", "READ_APP_STATUS", "READ_CURRENT_CHANNEL", "READ_INPUT_DEVICE_LIST",
        "READ_NETWORK_STATE", "READ_RUNNING_APPS", "READ_TV_CHANNEL_LIST", "READ_INSTALLED_APPS",
        "READ_POWER_STATE", "READ_COUNTRY_INFO", "READ_LGE_TV_INPUT_EVENTS", "READ_TV_CURRENT_TIME",
        "WRITE_NOTIFICATION_TOAST",
    ]
}
