import Foundation
import Security

/// Handles Google Service Account authentication for Calendar API.
/// Creates a JWT signed with the service account's private key,
/// exchanges it for an access token.
final class CalendarAuth {
    static let shared = CalendarAuth()

    private(set) var serviceAccountEmail = ""
    private var privateKeyData: Data?
    private var tokenUri = "https://oauth2.googleapis.com/token"
    private var accessToken = ""
    private var tokenExpiry: Date = .distantPast

    private init() {}

    /// Load credentials from a service account JSON file.
    func load(from path: String) -> Bool {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            print("[CalendarAuth] Failed to read JSON file")
            return false
        }

        guard let email = json["client_email"] as? String,
              let pkPem = json["private_key"] as? String
        else {
            print("[CalendarAuth] Missing client_email or private_key")
            return false
        }

        serviceAccountEmail = email
        if let uri = json["token_uri"] as? String { tokenUri = uri }

        // Parse PEM to DER
        let stripped = pkPem
            .replacingOccurrences(of: "-----BEGIN PRIVATE KEY-----", with: "")
            .replacingOccurrences(of: "-----END PRIVATE KEY-----", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")

        guard let keyData = Data(base64Encoded: stripped) else {
            print("[CalendarAuth] Failed to decode private key")
            return false
        }
        privateKeyData = keyData

        print("[CalendarAuth] Loaded service account: \(email)")
        return true
    }

    /// Get a valid access token, refreshing if needed. Blocks until done.
    func getAccessToken() -> String? {
        if !accessToken.isEmpty && Date() < tokenExpiry {
            return accessToken
        }

        guard let keyData = privateKeyData else { return nil }

        // Create JWT
        guard let jwt = createJWT(keyData: keyData) else {
            print("[CalendarAuth] Failed to create JWT")
            return nil
        }

        // Exchange JWT for access token
        let sem = DispatchSemaphore(value: 0)
        var result: String?

        let body = "grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer&assertion=\(jwt)"
        var request = URLRequest(url: URL(string: tokenUri)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = body.data(using: .utf8)

        URLSession.shared.dataTask(with: request) { data, response, error in
            defer { sem.signal() }

            if let error {
                print("[CalendarAuth] Token request failed: \(error.localizedDescription)")
                return
            }

            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let token = json["access_token"] as? String
            else {
                let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                print("[CalendarAuth] Bad token response: \(body.prefix(300))")
                return
            }

            let expiresIn = json["expires_in"] as? Int ?? 3600
            self.accessToken = token
            self.tokenExpiry = Date().addingTimeInterval(Double(expiresIn - 60))
            result = token
        }.resume()

        sem.wait()
        return result
    }

    // MARK: - JWT

    private func createJWT(keyData: Data) -> String? {
        let now = Int(Date().timeIntervalSince1970)

        // Header
        let header: [String: Any] = ["alg": "RS256", "typ": "JWT"]
        // Claims
        let claims: [String: Any] = [
            "iss": serviceAccountEmail,
            "scope": "https://www.googleapis.com/auth/calendar",
            "aud": tokenUri,
            "iat": now,
            "exp": now + 3600,
        ]

        guard let headerData = try? JSONSerialization.data(withJSONObject: header),
              let claimsData = try? JSONSerialization.data(withJSONObject: claims)
        else { return nil }

        let headerB64 = base64url(headerData)
        let claimsB64 = base64url(claimsData)
        let toSign = "\(headerB64).\(claimsB64)"

        guard let signatureData = sign(data: toSign.data(using: .utf8)!, with: keyData) else {
            return nil
        }

        let signatureB64 = base64url(signatureData)
        return "\(toSign).\(signatureB64)"
    }

    /// Strip PKCS#8 header to get PKCS#1 RSA key data.
    /// PKCS#8 wraps PKCS#1 in: SEQUENCE { version, AlgorithmIdentifier, OCTET STRING { pkcs1 } }
    /// We find the NULL terminator of AlgorithmIdentifier (05 00) followed by OCTET STRING tag (04).
    private func stripPKCS8Header(_ data: Data) -> Data? {
        for i in 0..<(data.count - 4) {
            if data[i] == 0x05 && data[i + 1] == 0x00 && data[i + 2] == 0x04 {
                let tagIdx = i + 2
                // Parse OCTET STRING length
                if data[tagIdx + 1] == 0x82 && tagIdx + 4 < data.count {
                    let len = Int(data[tagIdx + 2]) << 8 | Int(data[tagIdx + 3])
                    let start = tagIdx + 4
                    guard start + len <= data.count else { return nil }
                    return data.subdata(in: start..<(start + len))
                } else if data[tagIdx + 1] == 0x81 && tagIdx + 3 < data.count {
                    let len = Int(data[tagIdx + 2])
                    let start = tagIdx + 3
                    guard start + len <= data.count else { return nil }
                    return data.subdata(in: start..<(start + len))
                }
            }
        }
        return nil
    }

    private func sign(data: Data, with pkcs8Der: Data) -> Data? {
        // SecKeyCreateWithData needs PKCS#1, but Google provides PKCS#8
        guard let pkcs1 = stripPKCS8Header(pkcs8Der) else {
            print("[CalendarAuth] Failed to strip PKCS#8 header")
            return nil
        }

        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
        ]

        var error: Unmanaged<CFError>?
        guard let secKey = SecKeyCreateWithData(pkcs1 as CFData, attributes as CFDictionary, &error) else {
            print("[CalendarAuth] SecKey creation failed: \(error?.takeRetainedValue().localizedDescription ?? "unknown")")
            return nil
        }

        guard SecKeyIsAlgorithmSupported(secKey, .sign, .rsaSignatureMessagePKCS1v15SHA256) else {
            print("[CalendarAuth] RSA-SHA256 not supported")
            return nil
        }

        guard let signature = SecKeyCreateSignature(secKey, .rsaSignatureMessagePKCS1v15SHA256,
                                                     data as CFData, &error) else {
            print("[CalendarAuth] Signing failed: \(error?.takeRetainedValue().localizedDescription ?? "unknown")")
            return nil
        }

        return signature as Data
    }

    private func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
