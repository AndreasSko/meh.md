import CryptoKit
import Foundation
import Security

enum ChatGPTIDTokenValidator {
    struct Identity: Sendable {
        let subject: String
        let name: String?
        let email: String?
    }

    static func validate(
        _ token: String, clientID: String, nonce: String?,
        jwks: Data, now: Date = Date()
    ) throws -> Identity {
        let pieces = token.split(separator: ".", omittingEmptySubsequences: false)
        guard pieces.count == 3,
              let headerData = decode(String(pieces[0])),
              let payload = decode(String(pieces[1])),
              let signature = decode(String(pieces[2])),
              let header = (try? JSONSerialization.jsonObject(with: headerData)) as? [String: Any],
              let algorithm = header["alg"] as? String,
              ["RS256", "ES256"].contains(algorithm),
              let kid = header["kid"] as? String, !kid.isEmpty,
              header["crit"] == nil,
              let set = (try? JSONSerialization.jsonObject(with: jwks)) as? [String: Any],
              let keys = set["keys"] as? [[String: Any]] else {
            throw ChatGPTAuthenticationError.invalidIDToken
        }
        let matching = keys.filter {
            $0["kid"] as? String == kid &&
            ($0["use"] == nil || $0["use"] as? String == "sig") &&
            ($0["alg"] == nil || $0["alg"] as? String == algorithm) &&
            ($0["key_ops"] == nil || ($0["key_ops"] as? [String])?.contains("verify") == true)
        }
        guard matching.count == 1 else { throw ChatGPTAuthenticationError.invalidIDToken }
        let key = matching[0]
        let message = Data("\(pieces[0]).\(pieces[1])".utf8)
        guard verify(signature, message: message, key: key, algorithm: algorithm),
              let claims = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any],
              claims["iss"] as? String == "https://auth.openai.com",
              let subject = claims["sub"] as? String, !subject.isEmpty,
              let expiry = claims["exp"] as? NSNumber,
              CFGetTypeID(expiry) != CFBooleanGetTypeID(),
              expiry.doubleValue > now.timeIntervalSince1970 else {
            throw ChatGPTAuthenticationError.invalidIDToken
        }
        let audiences = (claims["aud"] as? [String]) ??
            (claims["aud"] as? String).map { [$0] } ?? []
        guard audiences.contains(clientID),
              audiences.count == 1 || claims["azp"] as? String == clientID,
              nonce == nil || claims["nonce"] as? String == nonce else {
            throw ChatGPTAuthenticationError.invalidIDToken
        }
        if claims["azp"] != nil, claims["azp"] as? String != clientID {
            throw ChatGPTAuthenticationError.invalidIDToken
        }
        if claims["nbf"] != nil {
            guard let notBefore = claims["nbf"] as? NSNumber,
                  CFGetTypeID(notBefore) != CFBooleanGetTypeID(),
                  notBefore.doubleValue <= now.timeIntervalSince1970 else {
                throw ChatGPTAuthenticationError.invalidIDToken
            }
        }
        return Identity(subject: subject, name: claims["name"] as? String,
                        email: claims["email"] as? String)
    }

    static func decode(_ value: String) -> Data? {
        guard value.unicodeScalars.allSatisfy({
            CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
                .contains($0)
        }) else { return nil }
        let encoded = value.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        return Data(base64Encoded: encoded + String(repeating: "=", count: (4 - encoded.count % 4) % 4))
    }

    static func encode(_ value: Data) -> String {
        value.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    private static func verify(
        _ signature: Data, message: Data, key: [String: Any], algorithm: String
    ) -> Bool {
        if algorithm == "ES256" {
            guard key["kty"] as? String == "EC", key["crv"] as? String == "P-256",
                  let x = (key["x"] as? String).flatMap(decode), x.count == 32,
                  let y = (key["y"] as? String).flatMap(decode), y.count == 32,
                  let publicKey = try? P256.Signing.PublicKey(x963Representation: Data([4]) + x + y),
                  let signed = try? P256.Signing.ECDSASignature(rawRepresentation: signature) else { return false }
            return publicKey.isValidSignature(signed, for: message)
        }
        guard key["kty"] as? String == "RSA",
              let modulus = (key["n"] as? String).flatMap(decode), (256...1024).contains(modulus.count),
              let exponent = (key["e"] as? String).flatMap(decode), (1...8).contains(exponent.count) else { return false }
        let encoded = der(0x30, integer(modulus) + integer(exponent))
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
        ]
        guard let publicKey = SecKeyCreateWithData(encoded as CFData, attributes as CFDictionary, nil) else {
            return false
        }
        return SecKeyVerifySignature(publicKey, .rsaSignatureMessagePKCS1v15SHA256,
                                     message as CFData, signature as CFData, nil)
    }

    private static func integer(_ bytes: Data) -> Data {
        var value = Data(bytes.drop(while: { $0 == 0 }))
        if value.isEmpty { value = Data([0]) }
        if value[0] & 0x80 != 0 { value.insert(0, at: 0) }
        return der(0x02, value)
    }

    private static func der(_ tag: UInt8, _ bytes: Data) -> Data {
        var length = Data()
        if bytes.count < 128 { length.append(UInt8(bytes.count)) }
        else {
            var count = bytes.count
            var digits = [UInt8]()
            while count > 0 { digits.insert(UInt8(count & 0xff), at: 0); count >>= 8 }
            length.append(0x80 | UInt8(digits.count)); length.append(contentsOf: digits)
        }
        return Data([tag]) + length + bytes
    }
}
