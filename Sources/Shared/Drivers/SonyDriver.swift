import Foundation

/// Sony Bravia: IRCC-IP commands over HTTP, authenticated with a Pre-Shared Key the user sets on the TV
/// (Settings › Network › Home network › IP control › Authentication: Normal and Pre-Shared Key).
@MainActor final class SonyDriver: TVDriver {
    var onStatus: ((DriverStatus) -> Void)?
    var onName: ((String) -> Void)?

    private let device: TVDevice
    private let store: DeviceStore
    private var codes: [String: String] = [:]
    private var playing = true
    /// Lowercased app title → URI from the TV's own app list, fetched on first launch.
    private var appURIs: [String: String] = [:]

    private static let askForKey = DriverStatus.needsCode(
        "Enter the Pre-Shared Key from the TV: Settings › Network › Home network › IP control."
    )

    init(device: TVDevice) {
        self.device = device
        store = DeviceStore(device: device)
    }

    func connect() {
        guard let psk = store["psk"] else { onStatus?(Self.askForKey); return }
        onStatus?(.connecting)
        Task {
            do {
                let (json, status) = try await call("system", method: "getRemoteControllerInfo", psk: psk)
                if status == 401 || status == 403 {
                    store["psk"] = nil
                    onStatus?(.failed("Wrong Pre-Shared Key. Reconnect to enter it again."))
                    return
                }
                let list = ((json["result"] as? [Any])?.last as? [[String: Any]]) ?? []
                for entry in list {
                    if let name = entry["name"] as? String, let value = entry["value"] as? String { codes[name] = value }
                }
                onStatus?(.connected)
                if let (info, _) = try? await call("system", method: "getInterfaceInformation", psk: psk),
                   let model = ((info["result"] as? [Any])?.first as? [String: Any])?["modelName"] as? String {
                    onName?("Sony \(model)")
                }
            } catch {
                onStatus?(.failed(error.localizedDescription))
            }
        }
    }

    func disconnect() {}

    func submitCode(_ code: String) {
        store["psk"] = code.trimmingCharacters(in: .whitespaces)
        connect()
    }

    func send(_ key: RemoteKey) {
        guard let psk = store["psk"] else { onStatus?(Self.askForKey); return }
        if key == .playPause { playing.toggle() }
        let name = codeName(for: key)
        guard let code = codes[name] ?? Self.fallbackCodes[name] else { return }
        var request = URLRequest(url: URL(string: "http://\(device.host)/sony/IRCC")!)
        request.httpMethod = "POST"
        request.setValue("text/xml; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.setValue("\"urn:schemas-sony-com:service:IRCC:1#X_SendIRCC\"", forHTTPHeaderField: "SOAPACTION")
        request.setValue(psk, forHTTPHeaderField: "X-Auth-PSK")
        request.httpBody = Data("""
        <?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" \
        s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body>\
        <u:X_SendIRCC xmlns:u="urn:schemas-sony-com:service:IRCC:1"><IRCCCode>\(code)</IRCCCode></u:X_SendIRCC>\
        </s:Body></s:Envelope>
        """.utf8)
        Task {
            if (try? await LocalTLS.session.data(for: request)) == nil { onStatus?(.disconnected) }
        }
    }

    private func codeName(for key: RemoteKey) -> String {
        switch key {
        case .power: "TvPower"
        case .home: "Home"
        case .back: "Return"
        case .input: "Input"
        case .up: "Up"
        case .down: "Down"
        case .left: "Left"
        case .right: "Right"
        case .ok: "Confirm"
        case .volumeUp: "VolumeUp"
        case .volumeDown: "VolumeDown"
        case .mute: "Mute"
        case .channelUp: "ChannelUp"
        case .channelDown: "ChannelDown"
        case .playPause: playing ? "Play" : "Pause"
        case .tv: "Tv"
        case .nextHDMI: "Input"
        case .hdmi1: "Hdmi1"
        case .hdmi2: "Hdmi2"
        case .hdmi3: "Hdmi3"
        case .hdmi4: "Hdmi4"
        case .settings: "ActionMenu"
        case .search: "Search"
        case .exit: "Exit"
        }
    }

    func type(_ text: String, previous: String) {
        guard let psk = store["psk"] else { return }
        Task { _ = try? await call("appControl", method: "setTextForm", psk: psk, params: [text]) }
    }

    func installedApps() async -> Set<StreamingApp>? {
        guard let psk = store["psk"] else { return nil }
        await loadAppList(psk: psk)
        guard !appURIs.isEmpty else { return nil }
        return Set(StreamingApp.allCases.filter { app in appURIs.keys.contains { title in app.titleMatch.contains { title.contains($0) } } })
    }

    private func loadAppList(psk: String) async {
        guard appURIs.isEmpty, let (json, _) = try? await call("appControl", method: "getApplicationList", psk: psk) else { return }
        for entry in ((json["result"] as? [Any])?.first as? [[String: Any]]) ?? [] {
            if let title = entry["title"] as? String, let uri = entry["uri"] as? String { appURIs[title.lowercased()] = uri }
        }
    }

    func launch(_ app: StreamingApp) {
        guard let psk = store["psk"] else { onStatus?(Self.askForKey); return }
        Task {
            await loadAppList(psk: psk)
            guard let uri = appURIs.first(where: { title, _ in app.titleMatch.contains { title.contains($0) } })?.value else { return }
            _ = try? await call("appControl", method: "setActiveApp", psk: psk, params: [["uri": uri]])
        }
    }

    private func call(
        _ service: String, method: String, psk: String, params: [Any] = []
    ) async throws -> ([String: Any], Int) {
        var request = URLRequest(url: URL(string: "http://\(device.host)/sony/\(service)")!)
        request.httpMethod = "POST"
        request.setValue(psk, forHTTPHeaderField: "X-Auth-PSK")
        request.httpBody = Data(["method": method, "id": 1, "params": params, "version": "1.0"].jsonString.utf8)
        let (data, response) = try await LocalTLS.session.data(for: request)
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        return (json, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    /// Standard Bravia IRCC codes, used if the TV doesn't list its own.
    private static let fallbackCodes = [
        "TvPower": "AAAAAQAAAAEAAAAVAw==", "Home": "AAAAAQAAAAEAAABgAw==", "Return": "AAAAAgAAAJcAAAAjAw==",
        "Input": "AAAAAQAAAAEAAAAlAw==", "Up": "AAAAAQAAAAEAAAB0Aw==", "Down": "AAAAAQAAAAEAAAB1Aw==",
        "Left": "AAAAAQAAAAEAAAA0Aw==", "Right": "AAAAAQAAAAEAAAAzAw==", "Confirm": "AAAAAQAAAAEAAABlAw==",
        "VolumeUp": "AAAAAQAAAAEAAAASAw==", "VolumeDown": "AAAAAQAAAAEAAAATAw==", "Mute": "AAAAAQAAAAEAAAAUAw==",
        "ChannelUp": "AAAAAQAAAAEAAAAQAw==", "ChannelDown": "AAAAAQAAAAEAAAARAw==",
        "Play": "AAAAAgAAAJcAAAAaAw==", "Pause": "AAAAAgAAAJcAAAAZAw==",
        "Tv": "AAAAAQAAAAEAAAAkAw==", "Hdmi1": "AAAAAgAAABoAAABaAw==", "Hdmi2": "AAAAAgAAABoAAABbAw==",
        "Hdmi3": "AAAAAgAAABoAAABcAw==", "Hdmi4": "AAAAAgAAABoAAABdAw==",
        "ActionMenu": "AAAAAgAAAMQAAABLAw==", "Exit": "AAAAAQAAAAEAAABjAw==",
    ]
}
