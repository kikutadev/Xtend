import CryptoKit
import Foundation
import Security

/// Verifies and extracts a CRX3 package.
///
/// The CRX3 signature covers:
/// `"CRX3 SignedData\0" + UInt32LE(signedHeader.count) + signedHeader + ZIP`.
/// We require a valid proof whose public-key hash derives to the expected Chrome
/// extension ID, so a package for a different extension cannot be installed even
/// if it was returned from an otherwise trusted HTTPS endpoint.
enum CRX3Package {
    private static let magic = Data([0x43, 0x72, 0x32, 0x34]) // Cr24
    private static let signatureContext = Data("CRX3 SignedData\0".utf8)
    private static let maximumHeaderLength = 1 << 18

    static func verifiedZIPPayload(from data: Data, expectedExtensionID: String) throws -> Data {
        guard data.count >= 16 else { throw CRX3Error.truncated }
        guard data.prefix(4) == magic else { throw CRX3Error.invalidMagic }

        let version = try littleEndianUInt32(data, offset: 4)
        guard version == 3 else { throw CRX3Error.unsupportedVersion(version) }

        let headerLength = Int(try littleEndianUInt32(data, offset: 8))
        guard (1...maximumHeaderLength).contains(headerLength) else {
            throw CRX3Error.invalidHeaderLength
        }

        let headerStart = 12
        let zipOffset = headerStart + headerLength
        guard zipOffset + 4 <= data.count else { throw CRX3Error.truncated }

        let headerData = data.subdata(in: headerStart..<zipOffset)
        let zipPayload = data.subdata(in: zipOffset..<data.count)
        guard zipPayload.prefix(4).elementsEqual([0x50, 0x4b, 0x03, 0x04]) else {
            throw CRX3Error.invalidZIPPayload
        }

        let header = try parseHeader(headerData)
        let declaredExtensionID = try extensionID(fromSignedHeader: header.signedHeaderData)
        guard declaredExtensionID == expectedExtensionID else {
            throw CRX3Error.extensionIDMismatch(expected: expectedExtensionID, actual: declaredExtensionID)
        }

        var signedMessage = Data()
        signedMessage.reserveCapacity(signatureContext.count + 4 + header.signedHeaderData.count + zipPayload.count)
        signedMessage.append(signatureContext)
        signedMessage.append(contentsOf: littleEndianBytes(UInt32(header.signedHeaderData.count)))
        signedMessage.append(header.signedHeaderData)
        signedMessage.append(zipPayload)

        let developerProofs = header.proofs.filter {
            extensionID(fromPublicKey: $0.publicKey) == expectedExtensionID
        }
        guard !developerProofs.isEmpty else { throw CRX3Error.developerProofMissing }
        guard developerProofs.contains(where: { verify($0, message: signedMessage) }) else {
            throw CRX3Error.signatureInvalid
        }

        return zipPayload
    }

    private static func parseHeader(_ data: Data) throws -> ParsedHeader {
        var reader = ProtobufReader(data: data)
        var proofs: [Proof] = []
        var signedHeaderData: Data?

        while let field = try reader.nextField() {
            switch (field.number, field.value) {
            case (2, .bytes(let proofData)):
                proofs.append(try parseProof(proofData, algorithm: .rsa))
            case (3, .bytes(let proofData)):
                proofs.append(try parseProof(proofData, algorithm: .ecdsa))
            case (10_000, .bytes(let bytes)):
                guard signedHeaderData == nil else { throw CRX3Error.invalidProtobuf }
                signedHeaderData = bytes
            default:
                continue
            }
        }

        guard let signedHeaderData, !signedHeaderData.isEmpty else {
            throw CRX3Error.signedHeaderMissing
        }
        guard !proofs.isEmpty else { throw CRX3Error.developerProofMissing }
        return ParsedHeader(proofs: proofs, signedHeaderData: signedHeaderData)
    }

    private static func parseProof(_ data: Data, algorithm: ProofAlgorithm) throws -> Proof {
        var reader = ProtobufReader(data: data)
        var publicKey: Data?
        var signature: Data?

        while let field = try reader.nextField() {
            switch (field.number, field.value) {
            case (1, .bytes(let bytes)):
                publicKey = bytes
            case (2, .bytes(let bytes)):
                signature = bytes
            default:
                continue
            }
        }

        guard let publicKey, !publicKey.isEmpty, let signature, !signature.isEmpty else {
            throw CRX3Error.invalidProof
        }
        return Proof(algorithm: algorithm, publicKey: publicKey, signature: signature)
    }

    private static func extensionID(fromSignedHeader data: Data) throws -> String {
        var reader = ProtobufReader(data: data)
        var crxID: Data?

        while let field = try reader.nextField() {
            if field.number == 1, case .bytes(let bytes) = field.value {
                crxID = bytes
            }
        }

        guard let crxID, crxID.count == 16 else { throw CRX3Error.invalidSignedHeader }
        return chromeExtensionID(fromFirst16HashBytes: crxID)
    }

    private static func extensionID(fromPublicKey publicKey: Data) -> String {
        let digest = SHA256.hash(data: publicKey)
        return chromeExtensionID(fromFirst16HashBytes: Data(digest.prefix(16)))
    }

    private static func chromeExtensionID(fromFirst16HashBytes bytes: Data) -> String {
        var result = String()
        result.reserveCapacity(32)
        for byte in bytes.prefix(16) {
            result.append(Character(UnicodeScalar(Int(byte >> 4) + 97)!))
            result.append(Character(UnicodeScalar(Int(byte & 0x0f) + 97)!))
        }
        return result
    }

    private static func verify(_ proof: Proof, message: Data) -> Bool {
        let attributes: [CFString: Any]
        let verificationAlgorithm: SecKeyAlgorithm

        switch proof.algorithm {
        case .rsa:
            attributes = [
                kSecAttrKeyType: kSecAttrKeyTypeRSA,
                kSecAttrKeyClass: kSecAttrKeyClassPublic
            ]
            verificationAlgorithm = .rsaSignatureMessagePKCS1v15SHA256
        case .ecdsa:
            attributes = [
                kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
                kSecAttrKeyClass: kSecAttrKeyClassPublic,
                kSecAttrKeySizeInBits: 256
            ]
            verificationAlgorithm = .ecdsaSignatureMessageX962SHA256
        }

        var keyError: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(
            proof.publicKey as CFData,
            attributes as CFDictionary,
            &keyError
        ), SecKeyIsAlgorithmSupported(key, .verify, verificationAlgorithm) else {
            return false
        }

        var verificationError: Unmanaged<CFError>?
        return SecKeyVerifySignature(
            key,
            verificationAlgorithm,
            message as CFData,
            proof.signature as CFData,
            &verificationError
        )
    }

    private static func littleEndianUInt32(_ data: Data, offset: Int) throws -> UInt32 {
        guard offset >= 0, offset + 4 <= data.count else { throw CRX3Error.truncated }
        return data[offset..<(offset + 4)].enumerated().reduce(UInt32(0)) { partial, element in
            partial | (UInt32(element.element) << UInt32(element.offset * 8))
        }
    }

    private static func littleEndianBytes(_ value: UInt32) -> [UInt8] {
        [
            UInt8(truncatingIfNeeded: value),
            UInt8(truncatingIfNeeded: value >> 8),
            UInt8(truncatingIfNeeded: value >> 16),
            UInt8(truncatingIfNeeded: value >> 24)
        ]
    }
}

private struct ParsedHeader {
    let proofs: [Proof]
    let signedHeaderData: Data
}

private struct Proof {
    let algorithm: ProofAlgorithm
    let publicKey: Data
    let signature: Data
}

private enum ProofAlgorithm {
    case rsa
    case ecdsa
}

private struct ProtobufField {
    let number: Int
    let value: ProtobufValue
}

private enum ProtobufValue {
    case varint(UInt64)
    case fixed64(Data)
    case bytes(Data)
    case fixed32(Data)
}

/// Small fail-closed protobuf reader for the CRX3 messages we need.
private struct ProtobufReader {
    let data: Data
    private(set) var offset = 0

    mutating func nextField() throws -> ProtobufField? {
        guard offset < data.count else { return nil }
        let tag = try readVarint()
        let number = Int(tag >> 3)
        let wireType = Int(tag & 0x07)
        guard number > 0 else { throw CRX3Error.invalidProtobuf }

        let value: ProtobufValue
        switch wireType {
        case 0:
            value = .varint(try readVarint())
        case 1:
            value = .fixed64(try readBytes(count: 8))
        case 2:
            let length = try readVarint()
            guard length <= UInt64(Int.max) else { throw CRX3Error.invalidProtobuf }
            value = .bytes(try readBytes(count: Int(length)))
        case 5:
            value = .fixed32(try readBytes(count: 4))
        default:
            throw CRX3Error.invalidProtobuf
        }

        return ProtobufField(number: number, value: value)
    }

    private mutating func readVarint() throws -> UInt64 {
        var value: UInt64 = 0
        for shift in stride(from: 0, through: 63, by: 7) {
            guard offset < data.count else { throw CRX3Error.invalidProtobuf }
            let byte = data[offset]
            offset += 1
            value |= UInt64(byte & 0x7f) << UInt64(shift)
            if byte & 0x80 == 0 { return value }
        }
        throw CRX3Error.invalidProtobuf
    }

    private mutating func readBytes(count: Int) throws -> Data {
        guard count >= 0, offset <= data.count, count <= data.count - offset else {
            throw CRX3Error.invalidProtobuf
        }
        defer { offset += count }
        return data.subdata(in: offset..<(offset + count))
    }
}

enum CRX3Error: LocalizedError {
    case truncated
    case invalidMagic
    case unsupportedVersion(UInt32)
    case invalidHeaderLength
    case invalidZIPPayload
    case invalidProtobuf
    case signedHeaderMissing
    case invalidSignedHeader
    case invalidProof
    case extensionIDMismatch(expected: String, actual: String)
    case developerProofMissing
    case signatureInvalid

    var errorDescription: String? {
        switch self {
        case .truncated:
            "CRX3パッケージが途中で切れています。"
        case .invalidMagic:
            "Chrome拡張機能パッケージではありません。"
        case .unsupportedVersion(let version):
            "CRXバージョン\(version)には対応していません。"
        case .invalidHeaderLength:
            "CRX3ヘッダー長が不正です。"
        case .invalidZIPPayload:
            "CRX3内のZIPペイロードが不正です。"
        case .invalidProtobuf, .signedHeaderMissing, .invalidSignedHeader, .invalidProof:
            "CRX3署名ヘッダーが不正です。"
        case .extensionIDMismatch(let expected, let actual):
            "CRX3の拡張機能IDが一致しません（期待: \(expected)、実際: \(actual)）。"
        case .developerProofMissing:
            "対象拡張機能のCRX3署名鍵が見つかりません。"
        case .signatureInvalid:
            "CRX3の署名検証に失敗しました。"
        }
    }
}
