#if DEBUG
import AppKit
import Foundation
import Security

/// Opt-in, synthetic, and destructive of nothing: re-runs the calls behind the client-certificate
/// finding in ARCHITECTURE.md, whose answers depend entirely on how the app is signed. No real
/// credential material is involved — the key is generated here and the PKCS#12 is a throwaway the
/// script builds — and anything added to a keychain is deleted again before it reports.
@MainActor enum KeychainProbe {
    static var isEnabled: Bool { directory != nil }
    static let label = "kubix-keychain-probe"

    private static var directory: String? {
        ProcessInfo.processInfo.environment["KUBIX_KEYCHAIN_PROBE_DIRECTORY"]
    }

    static func run() {
        guard let directory else { return }
        var results: [String: String] = [:]
        results["signature"] = signature()
        let key = SecKeyCreateRandomKey([
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom, kSecAttrKeySizeInBits: 256,
        ] as CFDictionary, nil)
        results["generate key in memory"] = key == nil ? "failed" : "ok"

        if let key {
            results["add private key, default keychain"] = status(SecItemAdd([
                kSecClass: kSecClassKey, kSecValueRef: key, kSecAttrLabel: label,
            ] as CFDictionary, nil))
            results["add private key, data protection keychain"] = status(SecItemAdd([
                kSecClass: kSecClassKey, kSecValueRef: key, kSecAttrLabel: label,
                kSecUseDataProtectionKeychain: true,
            ] as CFDictionary, nil))
        }
        results["generate key directly into the keychain"] = status(permanentKey())
        results["import PKCS#12 to memory only"] = importPKCS12(memoryOnly: true)
        results["import PKCS#12 to the keychain"] = importPKCS12(memoryOnly: false)
        remove()
        let destination = URL(fileURLWithPath: directory).appendingPathComponent("result.json")
        if let data = try? JSONEncoder().encode(results) { try? data.write(to: destination, options: .atomic) }
        NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0)
    }

    /// What the running bundle is signed with, so a result is never read against the wrong signature.
    private static func signature() -> String {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return "unknown" }
        var flags = SecCSFlags(rawValue: kSecCSSigningInformation | kSecCSDynamicInformation)
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(unsafeBitCast(code, to: SecStaticCode.self), flags, &information) == errSecSuccess,
              let details = information as? [String: Any] else { return "unknown" }
        let team = details["teamid"] as? String ?? "no team"
        let entitlements = details["entitlements-dict"] as? [String: Any] ?? [:]
        let identifier = entitlements["application-identifier"] as? String ?? "no application-identifier"
        let groups = (entitlements["keychain-access-groups"] as? [String])?.joined(separator: ",") ?? "none"
        return "team \(team); \(identifier); keychain-access-groups \(groups)"
    }

    private static func permanentKey() -> OSStatus {
        var error: Unmanaged<CFError>?
        let created = SecKeyCreateRandomKey([
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom, kSecAttrKeySizeInBits: 256,
            kSecAttrIsPermanent: true, kSecAttrLabel: label,
        ] as CFDictionary, &error)
        if created != nil { return errSecSuccess }
        let failure = error?.takeRetainedValue()
        return OSStatus(truncatingIfNeeded: failure.map { CFErrorGetCode($0) } ?? -1)
    }

    /// The route the recorded finding did not try. If an identity can be had without storing
    /// anything, the feature needs neither an entitlement nor a deprecated API.
    private static func importPKCS12(memoryOnly: Bool) -> String {
        guard let directory, let data = FileManager.default.contents(atPath: directory + "/probe.p12") else {
            return "no synthetic PKCS#12 supplied"
        }
        var options: [CFString: Any] = [kSecImportExportPassphrase: "probe"]
        if memoryOnly {
            // The in-memory import is macOS 15+; below that there is nothing to try here.
            guard #available(macOS 15.0, *) else { return "unavailable below macOS 15" }
            options[kSecImportToMemoryOnly] = true
        }
        var items: CFArray?
        let result = SecPKCS12Import(data as CFData, options as CFDictionary, &items)
        guard result == errSecSuccess else { return status(result) }
        let identities = ((items as? [[String: Any]]) ?? []).compactMap { $0[kSecImportItemIdentity as String] }
        return identities.isEmpty ? "ok, but no identity returned" : "ok — \(identities.count) SecIdentity"
    }

    private static func remove() {
        for keychain in [true, false] {
            var query: [CFString: Any] = [kSecClass: kSecClassKey, kSecAttrLabel: label]
            if keychain { query[kSecUseDataProtectionKeychain] = true }
            SecItemDelete(query as CFDictionary)
        }
        var identities: [CFString: Any] = [kSecClass: kSecClassIdentity, kSecAttrLabel: "kubix-probe"]
        SecItemDelete(identities as CFDictionary)
        identities[kSecClass] = kSecClassCertificate
        SecItemDelete(identities as CFDictionary)
    }

    private static func status(_ result: OSStatus) -> String {
        result == errSecSuccess ? "ok" : "\(result) \(SecCopyErrorMessageString(result, nil) as String? ?? "")"
    }
}
#endif
