import Foundation
import Network

/// Finds TVs on the local network by probing each address of the phone's /24 subnet for the
/// ports and info endpoints each brand exposes, plus a Bonjour browse for Google TV names.
enum Discovery {
    /// Probes every brand on every address and reports each TV as soon as it answers.
    static func scan(found: @escaping @MainActor (TVDevice) -> Void) async {
        guard let prefix = localSubnetPrefix() else { return }
        async let named: Void = {
            // Bonjour gives Google TVs their real names; reporting again upgrades the generic name.
            for (host, name) in await googleTVNames() {
                await found(TVDevice(brand: .googleTV, host: host, name: name))
            }
        }()
        await withTaskGroup(of: [TVDevice].self) { group in
            // Probe 24 addresses at a time; each opens several sockets and iOS limits open files.
            var hosts = (1...254).map { "\(prefix).\($0)" }.makeIterator()
            for _ in 0..<24 {
                if let host = hosts.next() { group.addTask { await probe(host) } }
            }
            while let result = await group.next() {
                for device in result { await found(device) }
                if let host = hosts.next() { group.addTask { await probe(host) } }
            }
        }
        await named
    }

    private static func probe(_ host: String) async -> [TVDevice] {
        async let samsung = samsungName(host)
        async let roku = rokuName(host)
        async let sony = sonyName(host)
        async let lg = isOpen(host, 3000)
        async let lgSecure = isOpen(host, 3001)
        async let google = isOpen(host, 6466)
        async let vizio = vizioName(host)
        async let fireTV = isOpen(host, 5555)
        async let panasonic = panasonicName(host)

        var devices: [TVDevice] = []
        if let (name, mac) = await samsung { devices.append(TVDevice(brand: .samsung, host: host, name: name, mac: mac)) }
        if let name = await roku { devices.append(TVDevice(brand: .roku, host: host, name: name)) }
        if let name = await sony { devices.append(TVDevice(brand: .sony, host: host, name: name)) }
        if await lg, await lgSecure { devices.append(TVDevice(brand: .lg, host: host, name: "LG TV")) }
        if await google { devices.append(TVDevice(brand: .googleTV, host: host, name: "Google TV (\(host))")) }
        if let name = await vizio { devices.append(TVDevice(brand: .vizio, host: host, name: name)) }
        if await fireTV { devices.append(TVDevice(brand: .fireTV, host: host, name: "Fire TV (\(host))")) }
        if let name = await panasonic { devices.append(TVDevice(brand: .panasonic, host: host, name: name)) }
        return devices
    }

    // MARK: - Per-brand probes

    private static func samsungName(_ host: String) async -> (String, String?)? {
        guard let json = await getJSON("http://\(host):8001/api/v2/"),
              let raw = (json["device"] as? [String: Any])?["name"] as? String ?? json["name"] as? String
        else { return nil }
        return (raw.replacingOccurrences(of: "[TV] ", with: ""), (json["device"] as? [String: Any])?["wifiMac"] as? String)
    }

    private static func rokuName(_ host: String) async -> String? {
        guard let (data, response) = try? await probeSession.data(from: URL(string: "http://\(host):8060/query/device-info")!),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return RokuDriver.name(fromDeviceInfo: data) ?? "Roku"
    }

    private static func sonyName(_ host: String) async -> String? {
        var request = URLRequest(url: URL(string: "http://\(host)/sony/system")!)
        request.httpMethod = "POST"
        request.httpBody = Data(["method": "getInterfaceInformation", "id": 1, "params": [], "version": "1.0"].jsonString.utf8)
        guard let (data, _) = try? await probeSession.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let info = (json["result"] as? [Any])?.first as? [String: Any] else { return nil }
        return "Sony \(info["modelName"] as? String ?? "Bravia")"
    }

    private static func vizioName(_ host: String) async -> String? {
        for port in [7345, 9000] {
            guard let url = URL(string: "https://\(host):\(port)/state/device/deviceinfo"),
                  let (data, _) = try? await probeSession.data(from: url),
                  let json = try? JSONSerialization.jsonObject(with: data) else { continue }
            return "Vizio \(VizioDriver.modelName(in: json) ?? "TV")"
        }
        return nil
    }

    private static func panasonicName(_ host: String) async -> String? {
        guard let (data, _) = try? await probeSession.data(from: URL(string: "http://\(host):55000/nrc/ddd.xml")!),
              String(decoding: data, as: UTF8.self).contains("Panasonic") else { return nil }
        return xmlValue("friendlyName", in: data) ?? "Panasonic TV"
    }

    /// The text of the first <tag>…</tag> in an XML document.
    static func xmlValue(_ tag: String, in data: Data) -> String? {
        let xml = String(decoding: data, as: UTF8.self)
        guard let start = xml.range(of: "<\(tag)>"),
              let end = xml.range(of: "</\(tag)>", range: start.upperBound..<xml.endIndex) else { return nil }
        let value = xml[start.upperBound..<end.lowerBound].trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }

    private static func getJSON(_ url: String) async -> [String: Any]? {
        guard let (data, _) = try? await probeSession.data(from: URL(string: url)!) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static let probeSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 2
        config.timeoutIntervalForResource = 3
        config.httpMaximumConnectionsPerHost = 3
        // Vizio answers over HTTPS with a self-signed certificate.
        return URLSession(configuration: config, delegate: LocalTLS(), delegateQueue: nil)
    }()

    /// TCP connect check with a short timeout.
    private static func isOpen(_ host: String, _ port: UInt16) async -> Bool {
        await withCheckedContinuation { continuation in
            let connection = NWConnection(host: .init(host), port: .init(rawValue: port)!, using: .tcp)
            let queue = DispatchQueue(label: "probe")
            var finished = false
            func finish(_ open: Bool) {
                guard !finished else { return }
                finished = true
                connection.cancel()
                continuation.resume(returning: open)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: finish(true)
                case .failed, .waiting: finish(false)
                default: break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 1.5) { finish(false) }
        }
    }

    // MARK: - Google TV names over Bonjour

    /// Maps IPv4 address → advertised name for `_androidtvremote2._tcp` services.
    private static func googleTVNames() async -> [String: String] {
        let services: [NWEndpoint] = await withCheckedContinuation { continuation in
            let browser = NWBrowser(for: .bonjour(type: "_androidtvremote2._tcp", domain: nil), using: .tcp)
            var results: [NWEndpoint] = []
            browser.browseResultsChangedHandler = { found, _ in results = found.map(\.endpoint) }
            browser.start(queue: .main)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                browser.cancel()
                continuation.resume(returning: results)
            }
        }
        var names: [String: String] = [:]
        for endpoint in services {
            guard case .service(let name, _, _, _) = endpoint, let ip = await resolveIPv4(endpoint) else { continue }
            names[ip] = name
        }
        return names
    }

    private static func resolveIPv4(_ endpoint: NWEndpoint) async -> String? {
        await withCheckedContinuation { continuation in
            let params = NWParameters.tcp
            (params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options)?.version = .v4
            let connection = NWConnection(to: endpoint, using: params)
            let queue = DispatchQueue(label: "resolve")
            var finished = false
            func finish(_ ip: String?) {
                guard !finished else { return }
                finished = true
                connection.cancel()
                continuation.resume(returning: ip)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if case .hostPort(let host, _) = connection.currentPath?.remoteEndpoint {
                        finish("\(host)".components(separatedBy: "%").first)
                    } else {
                        finish(nil)
                    }
                case .failed: finish(nil)
                default: break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 2) { finish(nil) }
        }
    }

    // MARK: - Local address

    /// "192.168.1" for a phone at 192.168.1.42 on Wi-Fi (en0), else the first private IPv4 found.
    static func localSubnetPrefix() -> String? {
        var addrs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addrs) == 0, let first = addrs else { return nil }
        defer { freeifaddrs(addrs) }
        var candidates: [(name: String, ip: String)] = []
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let addr = ptr.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            let ip = String(cString: host)
            let isPrivate = ip.hasPrefix("192.168.") || ip.hasPrefix("10.") ||
                (ip.hasPrefix("172.") && (16...31).contains(Int(ip.split(separator: ".")[1]) ?? 0))
            if isPrivate { candidates.append((String(cString: ptr.pointee.ifa_name), ip)) }
        }
        guard let ip = (candidates.first { $0.name == "en0" } ?? candidates.first)?.ip else { return nil }
        return ip.split(separator: ".").prefix(3).joined(separator: ".")
    }
}
