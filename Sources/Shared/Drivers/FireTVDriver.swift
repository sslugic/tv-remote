import Foundation
import Network
import Security

/// Amazon Fire TV (sticks, Cube and Fire TV Edition TVs) over ADB on port 5555.
/// Needs Settings › My Fire TV › Developer options › ADB debugging turned on once; the first
/// connection shows "Allow USB debugging?" on the TV, and this app's key is remembered after that.
@MainActor final class FireTVDriver: TVDriver {
    var onStatus: ((DriverStatus) -> Void)?
    var onName: ((String) -> Void)?

    private let device: TVDevice
    private var connection: NWConnection?
    private var buffer = Data()
    private var connected = false
    private var sentSignature = false
    private var nextLocalID: UInt32 = 1
    /// Output collected per shell stream, delivered when the stream closes.
    private var streams: [UInt32: (output: Data, done: ((String) -> Void)?)] = [:]

    init(device: TVDevice) { self.device = device }

    func connect() {
        disconnect()
        onStatus?(.connecting)
        let connection = NWConnection(host: .init(device.host), port: 5555, using: .tcp)
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self, self.connection === connection else { return }
                switch state {
                case .ready:
                    self.write(ADB.cnxn, 0x0100_0000, 4096, Data("host::\0".utf8))
                case .failed, .waiting:
                    self.connected = false
                    self.onStatus?(.failed("Couldn't reach the Fire TV. Turn on ADB debugging in its Developer options."))
                default:
                    break
                }
            }
        }
        connection.start(queue: .main)
        receive(on: connection)
    }

    func disconnect() {
        connection?.cancel()
        connection = nil
        buffer = Data()
        connected = false
        sentSignature = false
        streams.removeAll()
    }

    func send(_ key: RemoteKey) {
        shell("input keyevent \(AndroidKeys.code(for: key))")
    }

    func launch(_ app: StreamingApp) {
        // Try each known package name; monkey starts the app's launcher activity.
        let launches = Self.packages[app, default: []].map { "monkey -p \($0) -c android.intent.category.LAUNCHER 1" }
        guard !launches.isEmpty else { return }
        shell(launches.joined(separator: " || "))
    }

    func type(_ text: String, previous: String) {
        let edit = TextEdit(from: previous, to: text)
        var commands: [String] = []
        if edit.deleteCount > 0 {
            commands.append("input keyevent " + Array(repeating: "67", count: edit.deleteCount).joined(separator: " "))
        }
        if !edit.insert.isEmpty {
            let escaped = edit.insert.replacingOccurrences(of: "'", with: "'\\''").replacingOccurrences(of: " ", with: "%s")
            commands.append("input text '\(escaped)'")
        }
        if !commands.isEmpty { shell(commands.joined(separator: "; ")) }
    }

    func finishPowerOn() { shell("input keyevent 224") }

    func installedApps() async -> Set<StreamingApp>? {
        let output = await withCheckedContinuation { continuation in
            shell("pm list packages") { continuation.resume(returning: $0) }
        }
        guard !output.isEmpty else { return nil }
        return Set(Self.packages.filter { _, names in names.contains { output.contains("package:\($0)") } }.keys)
    }

    // MARK: - ADB protocol

    private func shell(_ command: String, done: ((String) -> Void)? = nil) {
        guard connected else {
            done?("")
            connect()
            return
        }
        let id = nextLocalID
        nextLocalID += 1
        streams[id] = (Data(), done)
        write(ADB.open, id, 0, Data("shell:\(command)\0".utf8))
    }

    private func write(_ command: UInt32, _ arg0: UInt32, _ arg1: UInt32, _ payload: Data = Data()) {
        var header = Data()
        for value in [command, arg0, arg1, UInt32(payload.count), payload.reduce(UInt32(0)) { $0 &+ UInt32($1) }, ~command] {
            withUnsafeBytes(of: value.littleEndian) { header.append(contentsOf: $0) }
        }
        connection?.send(content: header + payload, completion: .contentProcessed { _ in })
    }

    private func receive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                guard let self, connection === self.connection else { return }
                if let data { self.buffer.append(data); self.drain() }
                if error != nil || isComplete {
                    self.connected = false
                    self.connection = nil
                    self.onStatus?(.disconnected)
                } else {
                    self.receive(on: connection)
                }
            }
        }
    }

    private func drain() {
        while buffer.count >= 24 {
            func word(_ i: Int) -> UInt32 {
                buffer.subdata(in: buffer.startIndex + i * 4 ..< buffer.startIndex + i * 4 + 4)
                    .withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian
            }
            let command = word(0), arg0 = word(1), arg1 = word(2), length = Int(word(3))
            guard buffer.count >= 24 + length else { return }
            let payload = buffer.subdata(in: buffer.startIndex + 24 ..< buffer.startIndex + 24 + length)
            buffer = buffer.subdata(in: buffer.startIndex + 24 + length ..< buffer.endIndex)
            handle(command, arg0, arg1, payload)
        }
    }

    private func handle(_ command: UInt32, _ arg0: UInt32, _ arg1: UInt32, _ payload: Data) {
        switch command {
        case ADB.auth where arg0 == 1: // TOKEN
            if !sentSignature, let signature = ADBKey.sign(payload) {
                sentSignature = true
                write(ADB.auth, 2, 0, signature)
            } else if let publicKey = ADBKey.publicKey() {
                // The TV doesn't know this key yet: offer it, which shows the Allow prompt.
                write(ADB.auth, 3, 0, Data((publicKey + " tvremote@iphone\0").utf8))
                onStatus?(.waitingForAllow)
            }
        case ADB.cnxn:
            connected = true
            onStatus?(.connected)
            shell("getprop ro.product.model") { [weak self] model in
                let name = model.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty, self?.device.name.hasPrefix("Fire TV (") == true { self?.onName?(name) }
            }
        case ADB.wrte:
            streams[arg1]?.output.append(payload)
            write(ADB.okay, arg1, arg0)
        case ADB.clse:
            if let stream = streams.removeValue(forKey: arg1) {
                write(ADB.clse, arg1, arg0)
                stream.done?(String(decoding: stream.output, as: UTF8.self))
            }
        default:
            break
        }
    }

    private static let packages: [StreamingApp: [String]] = [
        .netflix: ["com.netflix.ninja"],
        .youtube: ["com.amazon.firetv.youtube", "com.google.android.youtube.tv"],
        .prime: ["com.amazon.firebat", "com.amazon.avod"],
        .disney: ["com.disney.disneyplus"],
        .hulu: ["com.hulu.plus"],
        .max: ["com.wbd.stream", "com.hbo.hbonow"],
        .peacock: ["com.peacocktv.peacockandroid"],
        .appleTV: ["com.apple.atve.amazon.appletv"],
        .paramount: ["com.cbs.ott"],
    ]
}

private enum ADB {
    static let cnxn: UInt32 = 0x4E58_4E43
    static let auth: UInt32 = 0x4854_5541
    static let open: UInt32 = 0x4E45_504F
    static let okay: UInt32 = 0x5941_4B4F
    static let clse: UInt32 = 0x4553_4C43
    static let wrte: UInt32 = 0x4554_5257
}

/// This app's ADB RSA key, kept in the keychain.
private enum ADBKey {
    private static let tag = Data("co.slaven.tvremote.adb".utf8)

    static func privateKey() -> SecKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: tag,
            kSecReturnRef as String: true,
        ]
        var result: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let result {
            return (result as! SecKey)
        }
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2048,
            kSecPrivateKeyAttrs as String: [kSecAttrIsPermanent as String: true, kSecAttrApplicationTag as String: tag],
        ]
        return SecKeyCreateRandomKey(attributes as CFDictionary, nil)
    }

    /// ADB signs the 20-byte token as if it were a SHA-1 digest.
    static func sign(_ token: Data) -> Data? {
        guard let key = privateKey() else { return nil }
        return SecKeyCreateSignature(key, .rsaSignatureDigestPKCS1v15SHA1, token as CFData, nil) as Data?
    }

    /// The public key in Android's own format: word count, n0inv, modulus and R² mod n as
    /// little-endian 32-bit words, then the exponent — base64 encoded.
    static func publicKey() -> String? {
        guard let key = privateKey(), let publicKey = SecKeyCopyPublicKey(key),
              let (modulus, _) = ClientIdentity.rsaComponents(publicKey) else { return nil }
        let words = 64
        let bytes = [UInt8](repeating: 0, count: words * 4 - modulus.count) + [UInt8](modulus)
        // Little-endian words, least significant first.
        var n = [UInt32](repeating: 0, count: words)
        for i in 0..<words {
            let o = bytes.count - (i + 1) * 4
            n[i] = UInt32(bytes[o]) << 24 | UInt32(bytes[o + 1]) << 16 | UInt32(bytes[o + 2]) << 8 | UInt32(bytes[o + 3])
        }
        // n0inv = -1 / n[0] mod 2^32 (Newton's method).
        var inverse = n[0]
        for _ in 0..<5 { inverse = inverse &* (2 &- n[0] &* inverse) }
        let n0inv = 0 &- inverse
        // rr = (2^(32*words))^2 mod n, by doubling 1 that many times.
        var r = [UInt32](repeating: 0, count: words)
        r[0] = 1
        for _ in 0..<(words * 32 * 2) {
            var carry: UInt32 = 0
            for i in 0..<words {
                let next = r[i] >> 31
                r[i] = r[i] << 1 | carry
                carry = next
            }
            if carry == 1 || !less(r, n) { subtract(&r, n) }
        }
        var out = Data()
        func append(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { out.append(contentsOf: $0) } }
        append(UInt32(words))
        append(n0inv)
        n.forEach(append)
        r.forEach(append)
        append(65537)
        return out.base64EncodedString()
    }

    private static func less(_ a: [UInt32], _ b: [UInt32]) -> Bool {
        for i in stride(from: a.count - 1, through: 0, by: -1) where a[i] != b[i] { return a[i] < b[i] }
        return false
    }

    private static func subtract(_ a: inout [UInt32], _ b: [UInt32]) {
        var borrow: UInt64 = 0
        for i in 0..<a.count {
            let d = UInt64(a[i]) &- UInt64(b[i]) &- borrow
            a[i] = UInt32(truncatingIfNeeded: d)
            borrow = (d >> 63) & 1
        }
    }
}
