import Foundation

/// Vizio SmartCast TVs (2016+): HTTPS API on port 7345 (older firmware: 9000).
/// Pairing shows a 4-digit PIN on the TV; the returned auth token is sent with every command.
@MainActor final class VizioDriver: TVDriver {
    var onStatus: ((DriverStatus) -> Void)?
    var onName: ((String) -> Void)?

    private let device: TVDevice
    private let store: DeviceStore
    private var port = 7345
    private var pairingToken: Int?
    private var playing = true
    private let deviceID = "tvremote-iphone"

    init(device: TVDevice) {
        self.device = device
        store = DeviceStore(device: device)
    }

    func connect() {
        onStatus?(.connecting)
        Task {
            guard let info = await findPort() else {
                onStatus?(.failed("Couldn't reach the Vizio TV."))
                return
            }
            if let model = Self.modelName(in: info) { onName?("Vizio \(model)") }
            if store["auth"] != nil {
                onStatus?(.connected)
            } else {
                await startPairing()
            }
        }
    }

    func disconnect() {}

    func submitCode(_ code: String) {
        guard let pairingToken else { return }
        Task {
            let body: [String: Any] = [
                "DEVICE_ID": deviceID, "CHALLENGE_TYPE": 1,
                "RESPONSE_VALUE": code.trimmingCharacters(in: .whitespaces), "PAIRING_REQ_TOKEN": pairingToken,
            ]
            let json = await request("PUT", "/pairing/pair", body: body, auth: false)
            if let token = (json?["ITEM"] as? [String: Any])?["AUTH_TOKEN"] as? String {
                store["auth"] = token
                onStatus?(.connected)
            } else {
                onStatus?(.needsCode("That PIN didn't work. Enter the 4-digit PIN shown on the TV."))
            }
        }
    }

    func send(_ key: RemoteKey) {
        guard store["auth"] != nil else { connect(); return }
        if key == .playPause { playing.toggle() }
        if let input = inputName(for: key) {
            Task { await switchInput(input) }
            return
        }
        guard let (codeset, code) = codes(for: key) else { return }
        let body: [String: Any] = ["KEYLIST": [["CODESET": codeset, "CODE": code, "ACTION": "KEYPRESS"]]]
        Task { _ = await request("PUT", "/key_command/", body: body) }
    }

    func launch(_ app: StreamingApp) {
        // Apps with a known SmartCast namespace/ID; others aren't supported yet.
        let ids: [StreamingApp: (Int, String)] = [
            .netflix: (3, "1"), .youtube: (5, "1"), .prime: (3, "3"), .hulu: (2, "3"),
        ]
        guard let (space, id) = ids[app] else { return }
        let body: [String: Any] = ["VALUE": ["NAME_SPACE": space, "APP_ID": id, "MESSAGE": NSNull()]]
        Task { _ = await request("PUT", "/app/launch", body: body) }
    }

    func type(_ text: String, previous: String) {}

    /// Power On only works when the TV's power mode is Quick Start.
    func finishPowerOn() { sendCodes(11, 1) }

    // MARK: - Helpers

    private func findPort() async -> [String: Any]? {
        for candidate in [7345, 9000] {
            port = candidate
            if let info = await request("GET", "/state/device/deviceinfo", auth: false) { return info }
        }
        return nil
    }

    private func startPairing() async {
        let body: [String: Any] = ["DEVICE_ID": deviceID, "DEVICE_NAME": AppInfo.name]
        let json = await request("PUT", "/pairing/start", body: body, auth: false)
        if let token = (json?["ITEM"] as? [String: Any])?["PAIRING_REQ_TOKEN"] as? Int {
            pairingToken = token
            onStatus?(.needsCode("Enter the 4-digit PIN shown on the Vizio TV."))
        } else {
            onStatus?(.failed("The Vizio TV didn't start pairing. Make sure it's on."))
        }
    }

    private func switchInput(_ name: String) async {
        let path = "/menu_native/dynamic/tv_settings/devices/current_input"
        guard let current = await request("GET", path),
              let hash = ((current["ITEMS"] as? [[String: Any]])?.first)?["HASHVAL"] else { return }
        _ = await request("PUT", path, body: ["REQUEST": "MODIFY", "VALUE": name, "HASHVAL": hash])
    }

    private func sendCodes(_ codeset: Int, _ code: Int) {
        let body: [String: Any] = ["KEYLIST": [["CODESET": codeset, "CODE": code, "ACTION": "KEYPRESS"]]]
        Task { _ = await request("PUT", "/key_command/", body: body) }
    }

    private func request(_ method: String, _ path: String, body: [String: Any]? = nil, auth: Bool = true) async -> [String: Any]? {
        var request = URLRequest(url: URL(string: "https://\(device.host):\(port)\(path)")!)
        request.httpMethod = method
        request.timeoutInterval = 4
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if auth, let token = store["auth"] { request.setValue(token, forHTTPHeaderField: "AUTH") }
        if let body { request.httpBody = Data(body.jsonString.utf8) }
        guard let (data, response) = try? await LocalTLS.session.data(for: request) else { return nil }
        if (response as? HTTPURLResponse)?.statusCode == 403 || (response as? HTTPURLResponse)?.statusCode == 401 {
            store["auth"] = nil
            onStatus?(.failed("The Vizio TV forgot this phone. Reconnect to pair again."))
            return nil
        }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private func inputName(for key: RemoteKey) -> String? {
        switch key {
        case .hdmi1: "HDMI-1"
        case .hdmi2: "HDMI-2"
        case .hdmi3: "HDMI-3"
        case .hdmi4: "HDMI-4"
        case .tv: "TV"
        default: nil
        }
    }

    private func codes(for key: RemoteKey) -> (Int, Int)? {
        switch key {
        case .power: (11, 2)
        case .home: (4, 15)
        case .back: (4, 0)
        case .input, .nextHDMI: (7, 1)
        case .up: (3, 8)
        case .down: (3, 0)
        case .left: (3, 1)
        case .right: (3, 7)
        case .ok: (3, 2)
        case .volumeUp: (5, 1)
        case .volumeDown: (5, 0)
        case .mute: (5, 4)
        case .channelUp: (8, 1)
        case .channelDown: (8, 0)
        case .playPause: playing ? (2, 3) : (2, 2)
        case .settings: (4, 8)
        case .search: (4, 15) // no search key; Home has the search bar
        case .exit: (9, 0)
        case .tv, .hdmi1, .hdmi2, .hdmi3, .hdmi4: nil
        }
    }

    /// Finds MODEL_NAME anywhere in the device-info response.
    nonisolated static func modelName(in json: Any) -> String? {
        if let dict = json as? [String: Any] {
            if let name = dict["MODEL_NAME"] as? String { return name }
            for value in dict.values { if let found = modelName(in: value) { return found } }
        } else if let array = json as? [Any] {
            for value in array { if let found = modelName(in: value) { return found } }
        }
        return nil
    }
}
