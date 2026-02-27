import Foundation
import Network
import Security

/// Errors thrown when loading a TLS certificate.
public enum TLSError: Error {
    /// The PKCS#12 data could not be imported. The associated `OSStatus` contains the system error code.
    case pkcs12ImportFailed(OSStatus)
    /// No TLS identity was found in the PKCS#12 data.
    case identityNotFound
    /// The TLS identity could not be created from the imported certificate.
    case identityCreationFailed
}

/// A TLS certificate configuration for starting ``MockWebServer`` with HTTPS.
///
/// Use the built-in factories (``localhost()``, ``expired()``, ``wrongHostname()``)
/// for common test scenarios, or load your own `.p12` file with ``init(p12Data:password:)``.
public struct TLSConfiguration: @unchecked Sendable {
    let secIdentity: sec_identity_t

    // On macOS, SecPKCS12Import adds identities to the system keychain as a
    // side effect. Importing the same .p12 twice (e.g. from parallel test
    // suites) fails with errSecDuplicateItem (-25299). Caching the result
    // ensures each certificate is imported exactly once.
    private static let cacheLock = NSLock()
    private static nonisolated(unsafe) var cache: [String: TLSConfiguration] = [:]

    /// Load a TLS identity from PKCS#12 (`.p12`) data.
    public init(p12Data: Data, password: String) throws {
        let options: NSDictionary = [kSecImportExportPassphrase: password]
        var items: CFArray?
        let status = SecPKCS12Import(p12Data as CFData, options, &items)
        guard status == errSecSuccess else {
            throw TLSError.pkcs12ImportFailed(status)
        }
        guard let itemArray = items as? [[String: Any]],
              let firstItem = itemArray.first,
              let identityRef = firstItem[kSecImportItemIdentity as String]
        else {
            throw TLSError.identityNotFound
        }
        // SecPKCS12Import guarantees this value is a SecIdentity
        let identity = identityRef as! SecIdentity // swiftlint:disable:this force_cast
        guard let secId = sec_identity_create(identity) else {
            throw TLSError.identityCreationFailed
        }
        self.secIdentity = secId
    }

    private static func cachedConfiguration(name: String, password: String) throws -> TLSConfiguration {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let existing = cache[name] {
            return existing
        }
        let data = try CertificateStore.data(for: name)
        let config = try TLSConfiguration(p12Data: data, password: password)
        cache[name] = config
        return config
    }

    /// A self-signed certificate for `localhost`, valid for 10 years.
    ///
    /// Since this is self-signed, `URLSession` will reject it by default.
    /// Use a delegate that trusts the server's certificate, or see the TLS
    /// examples for a `TrustAllDelegate` helper.
    public static func localhost() throws -> TLSConfiguration {
        try cachedConfiguration(name: "localhost-valid", password: "test")
    }

    /// A certificate whose expiry date is in the past.
    ///
    /// Use this to test that your code correctly rejects expired certificates.
    public static func expired() throws -> TLSConfiguration {
        try cachedConfiguration(name: "expired", password: "test")
    }

    /// A certificate issued for `wrong.example.com`, not `127.0.0.1`.
    ///
    /// Use this to test hostname-mismatch validation errors.
    public static func wrongHostname() throws -> TLSConfiguration {
        try cachedConfiguration(name: "wrong-hostname", password: "test")
    }

    internal var parameters: NWParameters {
        let tlsOptions = NWProtocolTLS.Options()
        sec_protocol_options_set_local_identity(
            tlsOptions.securityProtocolOptions,
            secIdentity
        )
        return NWParameters(tls: tlsOptions)
    }
}
