import Foundation
import Security

/// Stores API keys in the macOS Keychain, one entry per provider account.
/// Never written to disk in plaintext or committed to git.
enum KeychainStore {
    private static let service = "build.ecoblox.MeetingMinutes"

    /// Returns nil on success, or a human-readable error if the write failed.
    @discardableResult
    static func save(_ value: String, account: String) -> String? {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let deleteStatus = SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else {
            NSLog("KeychainStore: save failed for \(account): add=\(status) delete=\(deleteStatus)")
            return describe(status)
        }
        return nil
    }

    private static func describe(_ status: OSStatus) -> String {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown error"
        return "\(message) (OSStatus \(status))"
    }

    static func load(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else {
            if status != errSecSuccess && status != errSecItemNotFound {
                NSLog("KeychainStore: load failed for \(account): \(describe(status))")
            }
            return nil
        }
        return value
    }

    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }

    static func hasKey(account: String) -> Bool {
        guard let value = load(account: account) else { return false }
        return !value.isEmpty
    }
}
