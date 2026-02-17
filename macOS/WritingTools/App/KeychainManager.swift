//
//  KeychainManager.swift
//  WritingTools
//
//  Created by Arya Mirsepasi on 04.11.25.
//

import Foundation
import Security

final class KeychainManager: @unchecked Sendable {
    static let shared = KeychainManager()
    private let serviceName = "com.aryamirsepasi.writing-tools"
    private let customProviderKeyPrefix = "custom_provider_api_key_"

    /// Serializes all keychain operations so that delete+add sequences are atomic.
    /// Uses a serial DispatchQueue instead of NSLock to avoid potential deadlocks
    /// when called from async contexts (e.g. Task.detached in AppSettings).
    private let queue = DispatchQueue(label: "com.aryamirsepasi.writing-tools.keychain")
    private let queueSpecificKey = DispatchSpecificKey<Bool>()

    private init() {
        queue.setSpecific(key: queueSpecificKey, value: true)
    }
    
    enum KeychainError: LocalizedError {
        case failedToSave(OSStatus)
        case failedToRead(OSStatus)
        case failedToDelete(OSStatus)
        case noDataFound
        
        var errorDescription: String? {
            switch self {
            case .failedToSave(let status):
                return "Failed to save to Keychain: \(status)"
            case .failedToRead(let status):
                return "Failed to read from Keychain: \(status)"
            case .failedToDelete(let status):
                return "Failed to delete from Keychain: \(status)"
            case .noDataFound:
                return "No data found in Keychain"
            }
        }
    }
    
    // MARK: - Save
    
    func save(_ value: String, forKey key: String) throws {
        guard !value.isEmpty else {
            try delete(forKey: key)
            return
        }
        
        guard let data = value.data(using: .utf8) else {
            throw KeychainError.failedToSave(-1)
        }
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrService as String: serviceName,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked
        ]
        
        // Dispatch synchronously to make delete+add atomic
        debugAssertNotOnQueue(function: #function)
        try queue.sync {
            // Try to delete existing first
            SecItemDelete(query as CFDictionary)
            
            let status = SecItemAdd(query as CFDictionary, nil)
            guard status == errSecSuccess else {
                throw KeychainError.failedToSave(status)
            }
        }
    }
    
    // MARK: - Read
    
    func retrieve(forKey key: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrService as String: serviceName,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        
        debugAssertNotOnQueue(function: #function)
        return try queue.sync { () throws -> String? in
            var result: AnyObject?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            
            if status == errSecItemNotFound {
                return nil
            }
            
            guard status == errSecSuccess else {
                throw KeychainError.failedToRead(status)
            }
            
            guard let data = result as? Data else {
                throw KeychainError.noDataFound
            }
            
            return String(data: data, encoding: .utf8)
        }
    }
    
    // MARK: - Delete
    
    func delete(forKey key: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrService as String: serviceName
        ]
        
        debugAssertNotOnQueue(function: #function)
        try queue.sync {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw KeychainError.failedToDelete(status)
            }
        }
    }
    
    // MARK: - Clear All
    
    func clearAllApiKeys() throws {
        let apiKeyNames = [
            "gemini_api_key",
            "openai_api_key",
            "mistral_api_key",
            "anthropic_api_key",
            "openrouter_api_key"
        ]
        
        for keyName in apiKeyNames {
            try? delete(forKey: keyName)
        }
    }
    
    func hasMigratedKey(forKey key: String) -> Bool {
        do {
            let value = try retrieve(forKey: key)
            return value != nil
        } catch {
            return false
        }
    }

    func verifyMigration() -> [String: Bool] {
        let keysToCheck = [
            "gemini_api_key",
            "openai_api_key",
            "mistral_api_key",
            "anthropic_api_key",
            "openrouter_api_key"
        ]
        
        var results: [String: Bool] = [:]
        for key in keysToCheck {
            results[key] = hasMigratedKey(forKey: key)
        }
        return results
    }

    // MARK: - Synchronizable Keychain (iCloud Keychain)

    func saveSynchronizable(_ value: String, forKey key: String) throws {
        guard !value.isEmpty else {
            try deleteSynchronizable(forKey: key)
            return
        }

        guard let data = value.data(using: .utf8) else {
            throw KeychainError.failedToSave(-1)
        }

        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrService as String: serviceName,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
        ]

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrService as String: serviceName,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
            kSecAttrSynchronizable as String: kCFBooleanTrue as Any
        ]

        // Dispatch synchronously to make delete+add atomic
        debugAssertNotOnQueue(function: #function)
        try queue.sync {
            let deleteStatus = SecItemDelete(deleteQuery as CFDictionary)
            guard deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound else {
                throw KeychainError.failedToDelete(deleteStatus)
            }

            let status = SecItemAdd(addQuery as CFDictionary, nil)
            guard status == errSecSuccess else {
                throw KeychainError.failedToSave(status)
            }
        }
    }

    func retrieveSynchronizable(forKey key: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrService as String: serviceName,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
        ]

        debugAssertNotOnQueue(function: #function)
        return try queue.sync { () throws -> String? in
            var result: AnyObject?
            let status = SecItemCopyMatching(query as CFDictionary, &result)

            if status == errSecItemNotFound {
                return nil
            }

            guard status == errSecSuccess else {
                throw KeychainError.failedToRead(status)
            }

            guard let data = result as? Data else {
                throw KeychainError.noDataFound
            }

            return String(data: data, encoding: .utf8)
        }
    }

    func deleteSynchronizable(forKey key: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrService as String: serviceName,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
        ]

        debugAssertNotOnQueue(function: #function)
        try queue.sync {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw KeychainError.failedToDelete(status)
            }
        }
    }

    // MARK: - Custom Provider API Keys (Synchronizable)

    func saveCustomProviderApiKey(_ value: String?, for commandId: UUID) {
        let key = customProviderKeyPrefix + commandId.uuidString
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            try? deleteSynchronizable(forKey: key)
        } else {
            try? saveSynchronizable(trimmed, forKey: key)
        }
    }

    func retrieveCustomProviderApiKey(for commandId: UUID) -> String? {
        let key = customProviderKeyPrefix + commandId.uuidString
        return try? retrieveSynchronizable(forKey: key)
    }

    func deleteCustomProviderApiKey(for commandId: UUID) {
        let key = customProviderKeyPrefix + commandId.uuidString
        try? deleteSynchronizable(forKey: key)
    }

    private func debugAssertNotOnQueue(function: StaticString = #function) {
        #if DEBUG
        if DispatchQueue.getSpecific(key: queueSpecificKey) == true {
            assertionFailure("KeychainManager.\(function) called from keychain queue; queue.sync would deadlock.")
        }
        #endif
    }
}
