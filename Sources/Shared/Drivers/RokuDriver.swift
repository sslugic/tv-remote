import Foundation

/// Roku players and Roku TVs: External Control Protocol, plain HTTP on port 8060. No pairing.
@MainActor final class RokuDriver: TVDriver {
    var onStatus: ((DriverStatus) -> Void)?
    var onName: ((String) -> Void)?
    var onMAC: ((String) -> Void)?

    private let device: TVDevice
    private var inputIndex = 0
    private let inputs = ["InputHDMI1", "InputHDMI2", "InputHDMI3", "InputHDMI4", "InputTuner"]

    init(device: TVDevice) { self.device = device }

    func connect() {
        onStatus?(.connecting)
        Task {
            let url = URL(string: "http://\(device.host):8060/query/device-info")!
            do {
                let (data, response) = try await LocalTLS.session.data(from: url)
                if (response as? HTTPURLResponse)?.statusCode == 403 {
                    onStatus?(.failed("On the Roku, set Settings › System › Advanced system settings › Control by mobile apps to Default."))
                    return
                }
                if let name = Self.name(fromDeviceInfo: data) { onName?(name) }
                if let mac = Self.value("wifi-mac", in: data) ?? Self.value("ethernet-mac", in: data) { onMAC?(mac) }
                onStatus?(.connected)
            } catch {
                onStatus?(.failed(error.localizedDescription))
            }
        }
    }

    func disconnect() {}

    func send(_ key: RemoteKey) {
        let url = URL(string: "http://\(device.host):8060/keypress/\(code(for: key))")!
        // Roku has no input menu key, so Input steps through the inputs.
        if key == .input || key == .nextHDMI { inputIndex = (inputIndex + 1) % inputs.count }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        Task {
            if (try? await LocalTLS.session.data(for: request)) == nil { onStatus?(.disconnected) }
        }
    }

    func launch(_ app: StreamingApp) {
        var request = URLRequest(url: URL(string: "http://\(device.host):8060/launch/\(app.rokuID)")!)
        request.httpMethod = "POST"
        Task { _ = try? await LocalTLS.session.data(for: request) }
    }

    func type(_ text: String, previous: String) {
        let edit = TextEdit(from: previous, to: text)
        let keys = Array(repeating: "Backspace", count: edit.deleteCount) + edit.insert.map { char in
            "Lit_" + (String(char).addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")
        }
        Task {
            // One at a time so the characters arrive in order.
            for key in keys {
                var request = URLRequest(url: URL(string: "http://\(device.host):8060/keypress/\(key)")!)
                request.httpMethod = "POST"
                _ = try? await LocalTLS.session.data(for: request)
            }
        }
    }

    func finishPowerOn() {
        var request = URLRequest(url: URL(string: "http://\(device.host):8060/keypress/PowerOn")!)
        request.httpMethod = "POST"
        Task { _ = try? await LocalTLS.session.data(for: request) }
    }

    func installedApps() async -> Set<StreamingApp>? {
        guard let (data, _) = try? await LocalTLS.session.data(from: URL(string: "http://\(device.host):8060/query/apps")!),
              let xml = String(data: data, encoding: .utf8) else { return nil }
        return Set(StreamingApp.allCases.filter { xml.contains("id=\"\($0.rokuID)\"") })
    }

    private func code(for key: RemoteKey) -> String {
        switch key {
        case .power: "Power"
        case .home: "Home"
        case .back: "Back"
        case .input: inputs[inputIndex]
        case .up: "Up"
        case .down: "Down"
        case .left: "Left"
        case .right: "Right"
        case .ok: "Select"
        case .volumeUp: "VolumeUp"
        case .volumeDown: "VolumeDown"
        case .mute: "VolumeMute"
        case .channelUp: "ChannelUp"
        case .channelDown: "ChannelDown"
        case .playPause: "Play"
        case .tv: "InputTuner"
        case .nextHDMI: inputs[inputIndex]
        case .hdmi1: "InputHDMI1"
        case .hdmi2: "InputHDMI2"
        case .hdmi3: "InputHDMI3"
        case .hdmi4: "InputHDMI4"
        case .settings: "Info" // Roku has no settings key; * opens the options menu
        case .exit: "Home"
        }
    }

    /// Picks the most human name out of /query/device-info XML.
    nonisolated static func name(fromDeviceInfo data: Data) -> String? {
        for tag in ["user-device-name", "friendly-device-name", "friendly-model-name", "model-name"] {
            if let value = value(tag, in: data) { return value }
        }
        return nil
    }

    nonisolated static func value(_ tag: String, in data: Data) -> String? {
        guard let xml = String(data: data, encoding: .utf8),
              let start = xml.range(of: "<\(tag)>"),
              let end = xml.range(of: "</\(tag)>", range: start.upperBound..<xml.endIndex) else { return nil }
        let value = xml[start.upperBound..<end.lowerBound].trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }
}
