import Foundation
import Security

protocol LegacyProviderCredentialCleaning {
    func removeLegacyCredential() throws
}

struct KeychainLegacyProviderCredentialCleaner:
    LegacyProviderCredentialCleaning
{
    typealias DeleteItem = (CFDictionary) -> OSStatus

    private let deleteItem: DeleteItem

    init(deleteItem: @escaping DeleteItem = SecItemDelete) {
        self.deleteItem = deleteItem
    }

    func removeLegacyCredential() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.rajjoshi.MojiPond",
            kSecAttrAccount as String: "giphy-api-key"
        ]
        let status = deleteItem(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw LegacyProviderCredentialCleanupError(status: status)
        }
    }
}

struct LegacyProviderCredentialCleanupError: Error, Equatable {
    let status: OSStatus
}
