import Foundation

/// MFi-v3 accessory identity compiled straight into the executable.
///
/// The same bytes also ship as `MFi/certificate.p7b` and `MFi/identity.pk8`
/// resources, but resource folders are the fragile part of the pipeline:
/// `.gitignore` rules, folder-reference copy phases, and sideloading/repack
/// tools can all drop them silently. Compiling the bytes in makes the
/// credential independent of bundle layout, and the loader can then seed
/// Application Support from here so every later launch reads plain files.
enum BundledMFiIdentity {
    /// DER PKCS#7 SignedData container holding the Apple Accessories leaf.
    static let certificateBase64 = ""
        + "MIICWwYJKoZIhvcNAQcCoIICTDCCAkgCAQExADALBgkqhkiG9w0BBwGgggIuMIICKjCCAdGgAwIB"
        + "AgIQJKy7SGRvgHf3RjUjCFtg0jAKBggqhkjOPQQDAjCBiTELMAkGA1UEBhMCVVMxEzARBgNVBAoT"
        + "CkFwcGxlIEluYy4xJjAkBgNVBAsTHUFwcGxlIENlcnRpZmljYXRpb24gQXV0aG9yaXR5MT0wOwYD"
        + "VQQDEzRBcHBsZSBBY2Nlc3NvcmllcyBDZXJ0aWZpY2F0aW9uIEF1dGhvcml0eSAtIDAwMDAwMDAy"
        + "MB4XDTE4MDYxMzA4MzI1OVoXDTQ5MTIzMTIzNTk1OVowbTELMAkGA1UEBhMCVVMxEzARBgNVBAoT"
        + "CkFwcGxlIEluYy4xGjAYBgNVBAsTEUFwcGxlIEFjY2Vzc29yaWVzMS0wKwYDVQQDFCRJUEFfMjRB"
        + "Q0JCNDg2NDZGODA3N0Y3NDYzNTIzMDg1QjYwRDIwWTATBgcqhkjOPQIBBggqhkjOPQMBBwNCAAT0"
        + "mPfItJFateYmSe89Z9Bpf4HwogWewlz3ZfUgQkbuxvuvw9vGmuyMlitYkr7QNJM9/J4shFRgN1Ge"
        + "sptbVnEpozYwNDAyBgkqhkiG92NkBiQBAf8EIgQgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
        + "AAAAAAIwCgYIKoZIzj0EAwIDRwAwRAIgaYL03y8Xje/EKdEqhBoRJLB071JCP69YmNOQXVv+qfkC"
        + "IFngsPKacTAAVavi1E47l28ltIQslTc7ABuQ5c+lt47AoQAxAA=="

    /// Unencrypted DER PKCS#8 P-256 private key matching the leaf above.
    static let privateKeyBase64 =
        "MEECAQAwEwYHKoZIzj0CAQYIKoZIzj0DAQcEJzAlAgEBBCAv4C+7aHy52zIUZMW2bAJVb+f2A+E88wS9ep/vXJi6hg=="

    static var certificateData: Data? {
        Data(base64Encoded: certificateBase64)
    }

    static var privateKeyData: Data? {
        Data(base64Encoded: privateKeyBase64)
    }
}
