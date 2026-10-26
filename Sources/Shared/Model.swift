import Foundation

enum AppInfo {
    /// "TV Remote" in personal builds, "Simply Remote" in the App Store build.
    static var name: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "TV Remote"
    }

    /// The App Store build leaves out the background-audio sleep timer and the side volume button takeover,
    /// which App Review doesn't allow (guidelines 2.5.4 and 2.5.9).
    static var isAppStore: Bool {
        #if APP_STORE
        true
        #else
        false
        #endif
    }
}

enum RemoteKey: String, CaseIterable {
    case power, home, back, input
    case up, down, left, right, ok
    case volumeUp, volumeDown, mute
    case channelUp, channelDown
    case playPause
    case tv, hdmi1, hdmi2, hdmi3, hdmi4, nextHDMI
    case settings, exit
}

enum TVBrand: String, Codable, CaseIterable, Identifiable {
    case samsung, lg, roku, sony, googleTV, vizio, fireTV, panasonic

    var id: String { rawValue }

    var label: String {
        switch self {
        case .samsung: "Samsung"
        case .lg: "LG"
        case .roku: "Roku"
        case .sony: "Sony Bravia"
        case .googleTV: "Google TV / Android TV"
        case .vizio: "Vizio"
        case .fireTV: "Amazon Fire TV"
        case .panasonic: "Panasonic"
        }
    }

    /// The source buttons this brand supports. Samsung TVs from about 2018 ignore "go to HDMI n"
    /// but accept "next HDMI input", so they get one cycling button instead of four.
    var sourceKeys: [RemoteKey] {
        switch self {
        case .samsung: [.tv, .nextHDMI, .input]
        default: [.tv, .hdmi1, .hdmi2, .hdmi3, .hdmi4, .input]
        }
    }

    @MainActor func makeDriver(for device: TVDevice) -> TVDriver {
        switch self {
        case .samsung: SamsungDriver(device: device)
        case .lg: LGDriver(device: device)
        case .roku: RokuDriver(device: device)
        case .sony: SonyDriver(device: device)
        case .googleTV: GoogleTVDriver(device: device)
        case .vizio: VizioDriver(device: device)
        case .fireTV: FireTVDriver(device: device)
        case .panasonic: PanasonicDriver(device: device)
        }
    }
}

struct TVDevice: Codable, Hashable, Identifiable {
    var brand: TVBrand
    var host: String
    var name: String
    /// Learned from the TV when it reports one; used to wake it with Wake-on-LAN.
    var mac: String?

    var id: String { "\(brand.rawValue)@\(host)" }
}

enum DriverStatus: Equatable {
    case disconnected
    case connecting
    case waitingForAllow
    case needsCode(String)
    case connected
    case failed(String)
}

/// One TV protocol. Drivers report progress through the callbacks and are driven on the main actor.
@MainActor protocol TVDriver: AnyObject {
    var onStatus: ((DriverStatus) -> Void)? { get set }
    /// Called when the driver learns a better display name for the TV.
    var onName: ((String) -> Void)? { get set }
    /// Called when the driver learns the TV's MAC address.
    var onMAC: ((String) -> Void)? { get set }
    func connect()
    func disconnect()
    func send(_ key: RemoteKey)
    /// Opens a streaming app on the TV.
    func launch(_ app: StreamingApp)
    /// A PIN or pre-shared key the user typed after `.needsCode`.
    func submitCode(_ code: String)
    /// Updates the text in the TV's on-screen keyboard from `previous` to `text`.
    func type(_ text: String, previous: String)
    /// Which of the streaming apps are installed, or nil if the TV can't say.
    func installedApps() async -> Set<StreamingApp>?
    /// Called once the driver connects after a wake-up, to finish turning the screen on.
    /// Must never turn a TV that's already on back off.
    func finishPowerOn()
    /// Whether the TV still answers right now (false once it has gone to sleep).
    func isReachable() async -> Bool
}

extension TVDriver {
    func submitCode(_ code: String) {}
    func installedApps() async -> Set<StreamingApp>? { nil }
    func finishPowerOn() {}
    func isReachable() async -> Bool { true }
    var onMAC: ((String) -> Void)? {
        get { nil }
        set {}
    }
}

/// What changed between two versions of typed text: characters to delete from the end, then to add.
struct TextEdit {
    let deleteCount: Int
    let insert: String

    init(from previous: String, to text: String) {
        let common = zip(previous, text).prefix { $0 == $1 }.count
        deleteCount = previous.count - common
        insert = String(text.dropFirst(common))
    }
}

/// Per-TV values (pairing tokens, keys) kept in UserDefaults.
struct DeviceStore {
    let device: TVDevice

    subscript(key: String) -> String? {
        get { UserDefaults.standard.string(forKey: "\(key)-\(device.id)") }
        nonmutating set { UserDefaults.standard.set(newValue, forKey: "\(key)-\(device.id)") }
    }
}

/// URLSession that accepts the self-signed certificates TVs use on the local network.
final class LocalTLS: NSObject, URLSessionDelegate {
    static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 5
        return URLSession(configuration: config, delegate: LocalTLS(), delegateQueue: nil)
    }()

    /// For connections that wait on the person at the TV (pairing prompts), so they aren't cut off after 5 seconds.
    static let patientSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        return URLSession(configuration: config, delegate: LocalTLS(), delegateQueue: nil)
    }()

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

extension Dictionary where Key == String, Value == Any {
    var jsonString: String {
        String(data: (try? JSONSerialization.data(withJSONObject: self)) ?? Data(), encoding: .utf8) ?? "{}"
    }
}
