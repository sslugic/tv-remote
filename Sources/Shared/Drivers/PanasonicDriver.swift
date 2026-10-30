import Foundation

/// Panasonic VIERA TVs (about 2011–2018): SOAP remote-control service on port 55000, no pairing.
/// Newer models that require encrypted pairing answer with an error, which we report.
@MainActor final class PanasonicDriver: TVDriver {
    var onStatus: ((DriverStatus) -> Void)?
    var onName: ((String) -> Void)?

    private let device: TVDevice
    private var playing = true

    init(device: TVDevice) { self.device = device }

    func connect() {
        onStatus?(.connecting)
        Task {
            let url = URL(string: "http://\(device.host):55000/nrc/ddd.xml")!
            guard let (data, _) = try? await LocalTLS.session.data(from: url) else {
                onStatus?(.failed("Couldn't reach the Panasonic TV."))
                return
            }
            if let name = Discovery.xmlValue("friendlyName", in: data) { onName?(name) }
            onStatus?(.connected)
        }
    }

    func disconnect() {}

    func send(_ key: RemoteKey) {
        if key == .playPause { playing.toggle() }
        Task {
            let status = await soap("X_SendKey", args: "<X_KeyEvent>\(code(for: key))</X_KeyEvent>")
            if status == 400 || status == 401 || status == 403 || status == 500 {
                onStatus?(.failed("This Panasonic needs encrypted pairing, which \(AppInfo.name) doesn't support yet."))
            }
        }
    }

    func launch(_ app: StreamingApp) {
        let ids: [StreamingApp: String] = [
            .netflix: "0010000200000001", .youtube: "0070000200180001", .prime: "0010000100180001",
        ]
        guard let id = ids[app] else { return }
        Task { _ = await soap("X_LaunchApp", args: "<X_AppType>vc_app</X_AppType><X_LaunchKeyword>product_id=\(id)</X_LaunchKeyword>") }
    }

    func type(_ text: String, previous: String) {}

    private func soap(_ action: String, args: String) async -> Int {
        var request = URLRequest(url: URL(string: "http://\(device.host):55000/nrc/control_0")!)
        request.httpMethod = "POST"
        request.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        request.setValue("\"urn:panasonic-com:service:p00NetworkControl:1#\(action)\"", forHTTPHeaderField: "SOAPACTION")
        request.httpBody = Data("""
        <?xml version="1.0" encoding="utf-8"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" \
        s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body>\
        <u:\(action) xmlns:u="urn:panasonic-com:service:p00NetworkControl:1">\(args)</u:\(action)>\
        </s:Body></s:Envelope>
        """.utf8)
        guard let (_, response) = try? await LocalTLS.session.data(for: request) else { return 0 }
        return (response as? HTTPURLResponse)?.statusCode ?? 0
    }

    private func code(for key: RemoteKey) -> String {
        switch key {
        case .power: "NRC_POWER-ONOFF"
        case .home: "NRC_HOME-ONOFF"
        case .back: "NRC_RETURN-ONOFF"
        case .input, .nextHDMI: "NRC_CHG_INPUT-ONOFF"
        case .up: "NRC_UP-ONOFF"
        case .down: "NRC_DOWN-ONOFF"
        case .left: "NRC_LEFT-ONOFF"
        case .right: "NRC_RIGHT-ONOFF"
        case .ok: "NRC_ENTER-ONOFF"
        case .volumeUp: "NRC_VOLUP-ONOFF"
        case .volumeDown: "NRC_VOLDOWN-ONOFF"
        case .mute: "NRC_MUTE-ONOFF"
        case .channelUp: "NRC_CH_UP-ONOFF"
        case .channelDown: "NRC_CH_DOWN-ONOFF"
        case .playPause: playing ? "NRC_PLAY-ONOFF" : "NRC_PAUSE-ONOFF"
        case .tv: "NRC_TV-ONOFF"
        case .hdmi1: "NRC_HDMI1"
        case .hdmi2: "NRC_HDMI2"
        case .hdmi3: "NRC_HDMI3"
        case .hdmi4: "NRC_HDMI4"
        case .settings: "NRC_MENU-ONOFF"
        case .search: "NRC_HOME-ONOFF" // no search key; Home has the search bar
        case .exit: "NRC_CANCEL-ONOFF"
        }
    }
}
