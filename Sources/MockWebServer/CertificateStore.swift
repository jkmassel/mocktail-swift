import Foundation

/// Errors thrown by ``CertificateStore``.
public enum CertificateStoreError: Error {
    /// The named certificate file was not found in the bundle.
    case certificateNotFound(String)
}

/// Provides access to bundled `.p12` certificate files.
///
/// You typically don't need this directly. Use ``TLSConfiguration/localhost()``,
/// ``TLSConfiguration/expired()``, or ``TLSConfiguration/wrongHostname()`` instead.
public enum CertificateStore {
    /// Loads the raw bytes of a `.p12` certificate file from the package bundle.
    ///
    /// - Throws: ``CertificateStoreError/certificateNotFound(_:)`` if no matching file exists.
    public static func data(for name: String) throws -> Data {
        guard let url = Bundle.module.url(
            forResource: name,
            withExtension: "p12",
            subdirectory: "Certificates"
        ) else {
            throw CertificateStoreError.certificateNotFound(name)
        }
        return try Data(contentsOf: url)
    }
}
