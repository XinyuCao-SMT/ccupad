//
//  Keychain.swift
//  CCUPad
//
//  CCU 的网页密码只放 Keychain，不写进 UserDefaults、不进日志。
//  这一点与 ccu-studio 的「密码不落盘」是同样的取舍 —— 只是 iOS 侧有 Keychain，
//  可以真正做到「记住密码但不明文存」。
//

import Foundation
import Security

enum Keychain {
    private static let service = "com.smt.ccupad.password"

    static func setPassword(_ password: String, for id: UUID) -> Bool {
        // 先删再写，避免 duplicate item
        deletePassword(for: id)

        guard let data = password.data(using: .utf8) else { return false }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    static func password(for id: UUID) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef? = nil
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        return text
    }

    static func deletePassword(for id: UUID) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - 管理密码（「锁定其他项目」用）

    /// 管理密码按固定账号存，与每台设备的密码分开。
    private static let adminAccount = "admin.lock"

    static func setAdminPassword(_ password: String) -> Bool {
        deleteAdminPassword()
        guard let data = password.data(using: .utf8) else { return false }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: adminAccount,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    static func adminPassword() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: adminAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef? = nil
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        return text
    }

    static func deleteAdminPassword() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: adminAccount,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
