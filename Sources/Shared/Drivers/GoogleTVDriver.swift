import Foundation
import Network
import Security

/// Google TV / Android TV (including Sony, TCL, Hisense, Philips Google TVs and Chromecast with Google TV):
/// Android TV Remote protocol v2. Pairing on port 6467 shows a 6-digit code on the TV; once paired,
/// keys go over a TLS connection on port 6466 authenticated by this app's client certificate.
@MainActor final class GoogleTVDriver: TVDriver {
    var onStatus: ((DriverStatus) -> Void)?
    var onName: ((String) -> Void)?

    private enum Phase { case idle, pairing, waitingForCode, remote, ready }

    private let device: TVDevice
    private let store: DeviceStore
    private var connection: NWConnection?
    private var frames = FrameBuffer()
    private var phase = Phase.idle
    private var serverKey: SecKey?
    private var clientKey: SecKey?

    init(device: TVDevice) {
        self.device = device
        store = DeviceStore(device: device)
    }

    func connect() {
        disconnect()
        if store["paired"] == nil { startPairing() } else { startRemote() }
    }

    func disconnect() {
        connection?.cancel()
        connection = nil
        frames = FrameBuffer()
        phase = .idle
    }

    func send(_ key: RemoteKey) {
        guard phase == .ready else { connect(); return }
        write(Proto { $0.message(10) { $0.int(1, AndroidKeys.code(for: key)); $0.int(2, 3) } }.data)
    }

    func launch(_ app: StreamingApp) {
        guard phase == .ready else { connect(); return }
        write(Proto { $0.message(90) { $0.string(1, app.androidLink) } }.data)
    }

    /// Android TV has no "insert text" here, so type with key events (lowercase letters, digits, common symbols).
    func type(_ text: String, previous: String) {
        guard phase == .ready else { return }
        let edit = TextEdit(from: previous, to: text)
        var codes = Array(repeating: 67, count: edit.deleteCount) // KEYCODE_DEL
        for char in edit.insert.lowercased() {
            if let code = AndroidKeys.typing[char] { codes.append(code) }
        }
        for code in codes {
            write(Proto { $0.message(10) { $0.int(1, code); $0.int(2, 3) } }.data)
        }
    }


    func finishPowerOn() {
        // KEYCODE_WAKEUP turns the screen on without toggling a TV that's already on.
        write(Proto { $0.message(10) { $0.int(1, 224); $0.int(2, 3) } }.data)
    }

    func submitCode(_ code: String) {
        guard phase == .waitingForCode, let clientKey, let serverKey,
              let client = ClientIdentity.rsaComponents(clientKey),
              let server = ClientIdentity.rsaComponents(serverKey) else { return }
        guard let secret = pairingSecret(pin: code, client: client, server: server) else {
            onStatus?(.needsCode("That code didn't match. Enter the 6-character code shown on the TV."))
            return
        }
        write(pairingMessage { $0.message(40) { $0.bytes(1, secret) } })
    }

    // MARK: - Connection

    private func open(port: UInt16) -> Bool {
        let identity: SecIdentity
        do {
            let loaded = try ClientIdentity.load()
            identity = loaded.0
            clientKey = loaded.publicKey
        } catch {
            onStatus?(.failed("Could not create a certificate: \(error.localizedDescription)"))
            return false
        }

        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, sec_identity_create(identity)!)
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { [weak self] _, trust, complete in
            // The TV's certificate is self-signed; keep its key for the pairing secret.
            let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
            let key = (SecTrustCopyCertificateChain(secTrust) as? [SecCertificate])?.first.flatMap(SecCertificateCopyKey)
            Task { @MainActor in self?.serverKey = key }
            complete(true)
        }, .main)

        let connection = NWConnection(host: NWEndpoint.Host(device.host), port: NWEndpoint.Port(rawValue: port)!, using: NWParameters(tls: tls))
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in self?.handle(state, on: connection) }
        }
        connection.start(queue: .main)
        receive(on: connection)
        return true
    }

    private func handle(_ state: NWConnection.State, on connection: NWConnection) {
        guard connection === self.connection else { return }
        switch state {
        case .ready:
            if phase == .pairing {
                write(pairingMessage { $0.message(10) { $0.string(1, "atvremote"); $0.string(2, "TV Remote") } })
            }
        case .failed(let error), .waiting(let error):
            fail(error.localizedDescription)
        default:
            break
        }
    }

    private func fail(_ message: String) {
        let wasRemote = phase == .remote
        disconnect()
        if wasRemote {
            // The TV rejected our certificate: it no longer trusts this phone, so pair again next time.
            store["paired"] = nil
            onStatus?(.failed("The TV needs to pair again. Tap reconnect."))
        } else {
            onStatus?(.failed(message))
        }
    }

    private func receive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                guard let self, connection === self.connection else { return }
                if let data {
                    for message in self.frames.append(data) { self.handle(message) }
                }
                if let error {
                    self.fail(error.localizedDescription)
                } else if isComplete {
                    self.fail("The TV closed the connection.")
                } else {
                    self.receive(on: connection)
                }
            }
        }
    }

    private func write(_ message: Data) {
        connection?.send(content: Proto.framed(message), completion: .contentProcessed { _ in })
    }

    private func handle(_ message: Data) {
        let fields = ProtoFields(message)
        switch phase {
        case .pairing, .waitingForCode: handlePairing(fields)
        case .remote, .ready: handleRemote(fields)
        case .idle: break
        }
    }

    // MARK: - Pairing (port 6467)

    private func startPairing() {
        phase = .pairing
        onStatus?(.connecting)
        _ = open(port: 6467)
    }

    private func pairingMessage(_ build: (inout Proto) -> Void) -> Data {
        Proto {
            $0.int(1, 2) // protocol version
            $0.int(2, 200) // status OK
            build(&$0)
        }.data
    }

    private func handlePairing(_ fields: ProtoFields) {
        if let status = fields.ints[2], status != 200 {
            if phase == .waitingForCode {
                onStatus?(.needsCode("The TV rejected that code. Enter the code shown on the TV."))
            } else {
                fail("Pairing failed (status \(status)).")
            }
            return
        }
        let hexEncoding: (inout Proto) -> Void = { $0.int(1, 3); $0.int(2, 6) }
        if fields.bytes[11] != nil {
            // Pairing request acknowledged → offer a 6-digit hex code, us as the input side.
            write(pairingMessage { $0.message(20) { $0.message(1, hexEncoding); $0.int(3, 1) } })
        } else if fields.bytes[20] != nil {
            write(pairingMessage { $0.message(30) { $0.message(1, hexEncoding); $0.int(2, 1) } })
        } else if fields.bytes[31] != nil {
            phase = .waitingForCode
            onStatus?(.needsCode("Enter the code shown on the TV."))
        } else if fields.bytes[41] != nil {
            store["paired"] = "1"
            disconnect()
            startRemote()
        }
    }

    // MARK: - Remote (port 6466)

    private func startRemote() {
        phase = .remote
        onStatus?(.connecting)
        _ = open(port: 6466)
    }

    private func handleRemote(_ fields: ProtoFields) {
        if let configure = fields.message(1) {
            if let info = configure.message(2), let vendor = info.bytes[2].flatMap({ String(data: $0, encoding: .utf8) }),
               let model = info.bytes[1].flatMap({ String(data: $0, encoding: .utf8) }), device.name.hasPrefix("Google TV") {
                onName?("\(vendor) \(model)")
            }
            write(Proto {
                $0.message(1) {
                    $0.int(1, 622)
                    $0.message(2) {
                        $0.string(1, "iPhone")
                        $0.string(2, "Apple")
                        $0.int(3, 1)
                        $0.string(4, "1")
                        $0.string(5, "atvremote")
                        $0.string(6, "1.0.0")
                    }
                }
            }.data)
        } else if fields.bytes[2] != nil {
            write(Proto { $0.message(2) { $0.int(1, 622) } }.data)
            phase = .ready
            onStatus?(.connected)
        } else if let ping = fields.message(8) {
            write(Proto { $0.message(9) { $0.int(1, Int(ping.ints[1] ?? 0)) } }.data)
        } else if fields.bytes[3] != nil {
            fail("The TV reported a remote error.")
        }
    }
}
