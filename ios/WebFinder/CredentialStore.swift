import Foundation
import Security

enum CredentialStore {
    private static let service = "com.zeul.webfinder.ios"
    private static let secretAccount = "tailscale-oauth-secret"

    static var clientID: String {
        get { UserDefaults.standard.string(forKey: "tsClientID") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "tsClientID") }
    }

    static var publisherURL: String {
        get { UserDefaults.standard.string(forKey: "publisherURL") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "publisherURL") }
    }

    static var clientSecret: String {
        get {
            migrateLegacySecretIfNeeded()
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: secretAccount,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]
            var result: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
                  let data = result as? Data,
                  let value = String(data: data, encoding: .utf8) else { return "" }
            return value
        }
        set {
            let key: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: secretAccount,
            ]
            guard !newValue.isEmpty else {
                SecItemDelete(key as CFDictionary)
                return
            }
            let values: [String: Any] = [
                kSecValueData as String: Data(newValue.utf8),
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            ]
            if SecItemUpdate(key as CFDictionary, values as CFDictionary) == errSecItemNotFound {
                var item = key
                values.forEach { item[$0.key] = $0.value }
                SecItemAdd(item as CFDictionary, nil)
            }
        }
    }

    static var hasOAuthCredentials: Bool {
        !clientID.isEmpty && !clientSecret.isEmpty
    }

    static var isConfigured: Bool {
        hasOAuthCredentials || !publisherURL.isEmpty
    }

    static func clear() {
        clientID = ""
        clientSecret = ""
        publisherURL = ""
        UserDefaults.standard.removeObject(forKey: "tsClientSecret")
    }

    private static func migrateLegacySecretIfNeeded() {
        guard let legacy = UserDefaults.standard.string(forKey: "tsClientSecret"), !legacy.isEmpty else { return }
        UserDefaults.standard.removeObject(forKey: "tsClientSecret")
        clientSecret = legacy
    }
}
