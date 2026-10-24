import CryptoKit
import Foundation
import Security

// MARK: - Minimal protobuf

/// Writes the protobuf wire format: varint fields, length-delimited bytes/strings and nested messages.
struct Proto {
    private(set) var data = Data()

    init(_ build: (inout Proto) -> Void = { _ in }) { build(&self) }

    mutating func int(_ field: Int, _ value: Int) {
        Proto.varint(UInt64(field << 3), into: &data)
        Proto.varint(UInt64(value), into: &data)
    }

    mutating func bytes(_ field: Int, _ value: Data) {
        Proto.varint(UInt64(field << 3 | 2), into: &data)
        Proto.varint(UInt64(value.count), into: &data)
        data.append(value)
    }

    mutating func string(_ field: Int, _ value: String) { bytes(field, Data(value.utf8)) }
    mutating func message(_ field: Int, _ build: (inout Proto) -> Void) { bytes(field, Proto(build).data) }

    static func varint(_ value: UInt64, into data: inout Data) {
        var v = value
        while v >= 0x80 {
            data.append(UInt8(v & 0x7f) | 0x80)
            v >>= 7
        }
        data.append(UInt8(v))
    }

    /// Reads a varint at `index`, advancing it. Returns nil if the data ends first.
    static func readVarint(_ data: Data, _ index: inout Int) -> UInt64? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while index < data.endIndex {
            let byte = data[index]
            index += 1
            result |= UInt64(byte & 0x7f) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
        }
        return nil
    }

    /// Prefixes a message with its varint length, as both Android TV Remote ports expect.
    static func framed(_ message: Data) -> Data {
        var out = Data()
        varint(UInt64(message.count), into: &out)
        out.append(message)
        return out
    }
}

/// Decoded protobuf message: field number → varint values and length-delimited payloads.
struct ProtoFields {
    var ints: [Int: UInt64] = [:]
    var bytes: [Int: Data] = [:]

    init(_ data: Data) {
        var i = data.startIndex
        while i < data.endIndex, let key = Proto.readVarint(data, &i) {
            let field = Int(key >> 3)
            switch key & 7 {
            case 0:
                guard let v = Proto.readVarint(data, &i) else { return }
                ints[field] = v
            case 2:
                guard let len = Proto.readVarint(data, &i), i + Int(len) <= data.endIndex else { return }
                bytes[field] = data.subdata(in: i..<i + Int(len))
                i += Int(len)
            case 5: i += 4
            case 1: i += 8
            default: return
            }
        }
    }

    func message(_ field: Int) -> ProtoFields? { bytes[field].map(ProtoFields.init) }
}

/// Splits a TCP byte stream into varint-length-prefixed messages.
struct FrameBuffer {
    private var buffer = Data()

    mutating func append(_ data: Data) -> [Data] {
        buffer.append(data)
        var messages: [Data] = []
        while true {
            var i = buffer.startIndex
            guard let len = Proto.readVarint(buffer, &i), i + Int(len) <= buffer.endIndex else { break }
            messages.append(buffer.subdata(in: i..<i + Int(len)))
            buffer = buffer.subdata(in: (i + Int(len))..<buffer.endIndex)
        }
        return messages
    }
}

// MARK: - Client certificate

/// The self-signed RSA identity this app presents to Android/Google TVs. Created once and kept in the keychain;
/// pairing makes the TV trust it.
enum ClientIdentity {
    private static let tag = Data("co.slaven.tvremote.atv".utf8)
    private static let certKey = "atv-client-cert"

    static func load() throws -> (SecIdentity, publicKey: SecKey) {
        if let der = UserDefaults.standard.data(forKey: certKey), let found = findIdentity(certDER: der) {
            return found
        }
        return try create()
    }

    private static func findIdentity(certDER: Data) -> (SecIdentity, publicKey: SecKey)? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let identities = result as? [SecIdentity] else { return nil }
        for identity in identities {
            var cert: SecCertificate?
            guard SecIdentityCopyCertificate(identity, &cert) == errSecSuccess, let cert,
                  SecCertificateCopyData(cert) as Data == certDER,
                  let key = SecCertificateCopyKey(cert) else { continue }
            return (identity, key)
        }
        return nil
    }

    private static func create() throws -> (SecIdentity, publicKey: SecKey) {
        SecItemDelete([kSecClass as String: kSecClassKey, kSecAttrApplicationTag as String: tag] as CFDictionary)

        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2048,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: true,
                kSecAttrApplicationTag as String: tag,
            ],
        ]
        var error: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &error),
              let publicKey = SecKeyCopyPublicKey(privateKey),
              let publicDER = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else {
            throw error!.takeRetainedValue() as Error
        }

        let der = try selfSignedCertificate(publicKeyPKCS1: publicDER, privateKey: privateKey)
        guard let cert = SecCertificateCreateWithData(nil, der as CFData) else {
            throw NSError(domain: "TVRemote", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not build certificate"])
        }
        SecItemAdd([kSecClass as String: kSecClassCertificate, kSecValueRef as String: cert] as CFDictionary, nil)
        UserDefaults.standard.set(der, forKey: certKey)

        guard let found = findIdentity(certDER: der) else {
            throw NSError(domain: "TVRemote", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not store certificate"])
        }
        return found
    }

    private static func selfSignedCertificate(publicKeyPKCS1: Data, privateKey: SecKey) throws -> Data {
        let sha256WithRSA = DER.oid([0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x0b])
        let rsaEncryption = DER.oid([0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01])
        let signatureAlgorithm = DER.seq(sha256WithRSA, DER.null)
        let name = DER.seq(DER.set(DER.seq(DER.oid([0x55, 0x04, 0x03]), DER.utf8("atvremote"))))
        var serial = [UInt8](repeating: 0, count: 8)
        _ = SecRandomCopyBytes(kSecRandomDefault, serial.count, &serial)
        serial[0] &= 0x7f

        let tbs = DER.seq(
            DER.tlv(0xa0, DER.int([2])),
            DER.int(serial),
            signatureAlgorithm,
            name,
            DER.seq(DER.tlv(0x17, Data("250101000000Z".utf8)), DER.tlv(0x17, Data("491231235959Z".utf8))),
            name,
            DER.seq(DER.seq(rsaEncryption, DER.null), DER.bitString(publicKeyPKCS1))
        )
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(privateKey, .rsaSignatureMessagePKCS1v15SHA256, tbs as CFData, &error) as Data? else {
            throw error!.takeRetainedValue() as Error
        }
        return DER.seq(tbs, signatureAlgorithm, DER.bitString(signature))
    }

    /// Modulus and exponent of an RSA public key, as unsigned big-endian bytes.
    static func rsaComponents(_ key: SecKey) -> (modulus: Data, exponent: Data)? {
        guard let der = SecKeyCopyExternalRepresentation(key, nil) as Data? else { return nil }
        // PKCS#1 RSAPublicKey: SEQUENCE { INTEGER modulus, INTEGER exponent }
        var i = der.startIndex
        guard DER.readHeader(der, &i, expecting: 0x30) != nil,
              let modLen = DER.readHeader(der, &i, expecting: 0x02) else { return nil }
        let modulus = der.subdata(in: i..<i + modLen)
        i += modLen
        guard let expLen = DER.readHeader(der, &i, expecting: 0x02) else { return nil }
        let exponent = der.subdata(in: i..<i + expLen)
        return (modulus.drop(while: { $0 == 0 }), exponent.drop(while: { $0 == 0 }))
    }
}

private enum DER {
    static func tlv(_ tag: UInt8, _ content: Data) -> Data {
        var out = Data([tag])
        if content.count < 0x80 {
            out.append(UInt8(content.count))
        } else {
            var len = content.count
            var bytes: [UInt8] = []
            while len > 0 {
                bytes.insert(UInt8(len & 0xff), at: 0)
                len >>= 8
            }
            out.append(0x80 | UInt8(bytes.count))
            out.append(contentsOf: bytes)
        }
        out.append(content)
        return out
    }

    static func seq(_ parts: Data...) -> Data { tlv(0x30, parts.reduce(Data(), +)) }
    static func set(_ parts: Data...) -> Data { tlv(0x31, parts.reduce(Data(), +)) }
    static func oid(_ bytes: [UInt8]) -> Data { tlv(0x06, Data(bytes)) }
    static func utf8(_ s: String) -> Data { tlv(0x0c, Data(s.utf8)) }
    static func bitString(_ d: Data) -> Data { tlv(0x03, Data([0]) + d) }
    static let null = Data([0x05, 0x00])

    static func int(_ bytes: [UInt8]) -> Data {
        tlv(0x02, Data((bytes.first ?? 0) & 0x80 != 0 ? [0] + bytes : bytes))
    }

    static func readHeader(_ data: Data, _ i: inout Int, expecting tag: UInt8) -> Int? {
        guard i < data.endIndex, data[i] == tag else { return nil }
        i += 1
        let first = Int(data[i])
        i += 1
        if first < 0x80 { return first }
        var len = 0
        for _ in 0..<(first & 0x7f) {
            len = len << 8 | Int(data[i])
            i += 1
        }
        return len
    }
}

/// The pairing secret: SHA-256 over both RSA keys and the last 4 hex digits of the PIN.
/// The first byte of the hash must equal the first 2 PIN digits, which catches typos.
func pairingSecret(pin: String, client: (modulus: Data, exponent: Data), server: (modulus: Data, exponent: Data)) -> Data? {
    let hex = pin.uppercased().filter(\.isHexDigit)
    guard hex.count == 6,
          let check = UInt8(hex.prefix(2), radix: 16),
          let n1 = UInt8(hex.dropFirst(2).prefix(2), radix: 16),
          let n2 = UInt8(hex.suffix(2), radix: 16) else { return nil }
    var hasher = SHA256()
    hasher.update(data: client.modulus)
    hasher.update(data: client.exponent)
    hasher.update(data: server.modulus)
    hasher.update(data: server.exponent)
    hasher.update(data: Data([n1, n2]))
    let digest = Data(hasher.finalize())
    return digest.first == check ? digest : nil
}
