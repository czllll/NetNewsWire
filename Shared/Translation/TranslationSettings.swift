//
//  TranslationSettings.swift
//  NetNewsWire
//
//  Created by NetNewsWire contributors on 9/29/26.
//

import Foundation
import Security

extension Notification.Name {
	static let translationSettingsDidChange = Notification.Name("TranslationSettingsDidChange")
}

/// Settings for immersive article translation through an OpenAI-compatible chat completions API.
/// The API key lives in the keychain; everything else lives in user defaults.
@MainActor final class TranslationSettings {

	static let shared = TranslationSettings()

	static let defaultBaseURL = "https://api.openai.com/v1"
	static let defaultModel = "gpt-4o-mini"
	static let defaultTargetLanguage = "简体中文"

	static let targetLanguages = ["简体中文", "繁體中文", "English", "日本語", "한국어", "Français", "Deutsch", "Español", "Русский"]

	private struct Key {
		static let isEnabled = "translationEnabled"
		static let baseURL = "translationAPIBaseURL"
		static let model = "translationModel"
		static let targetLanguage = "translationTargetLanguage"
	}

	private let defaults = UserDefaults.standard

	/// When on, every article shown gets translated.
	var isEnabled: Bool {
		get {
			defaults.bool(forKey: Key.isEnabled)
		}
		set {
			guard newValue != isEnabled else {
				return
			}
			defaults.set(newValue, forKey: Key.isEnabled)
			postDidChange()
		}
	}

	var baseURL: String {
		get {
			nonEmptyString(forKey: Key.baseURL) ?? Self.defaultBaseURL
		}
		set {
			defaults.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Key.baseURL)
			postDidChange()
		}
	}

	var model: String {
		get {
			nonEmptyString(forKey: Key.model) ?? Self.defaultModel
		}
		set {
			defaults.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Key.model)
			postDidChange()
		}
	}

	var targetLanguage: String {
		get {
			nonEmptyString(forKey: Key.targetLanguage) ?? Self.defaultTargetLanguage
		}
		set {
			defaults.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Key.targetLanguage)
			postDidChange()
		}
	}

	var apiKey: String {
		get {
			cachedAPIKey
		}
		set {
			cachedAPIKey = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
			TranslationKeychain.apiKey = cachedAPIKey
			postDidChange()
		}
	}

	private lazy var cachedAPIKey = TranslationKeychain.apiKey ?? ""

	/// Local servers such as Ollama don't need a key, so only the URL and model are required.
	var isConfigured: Bool {
		URL(string: baseURL) != nil && !model.isEmpty
	}

	/// Paragraphs already in a CJK script are left alone when translating into a CJK language.
	var skipsCJKText: Bool {
		["中文", "日本語", "한국어"].contains { targetLanguage.contains($0) }
	}

	var configuration: TranslationConfiguration {
		TranslationConfiguration(baseURL: baseURL, apiKey: apiKey, model: model, targetLanguage: targetLanguage)
	}

	private func nonEmptyString(forKey key: String) -> String? {
		guard let value = defaults.string(forKey: key), !value.isEmpty else {
			return nil
		}
		return value
	}

	private func postDidChange() {
		NotificationCenter.default.post(name: .translationSettingsDidChange, object: self)
	}
}

struct TranslationConfiguration: Sendable, Equatable {
	let baseURL: String
	let apiKey: String
	let model: String
	let targetLanguage: String
}

// MARK: - Keychain

private enum TranslationKeychain {

	private static let service = "NetNewsWire Translation"
	private static let account = "apiKey"

	static var apiKey: String? {
		get {
			let query: [String: Any] = [
				kSecClass as String: kSecClassGenericPassword,
				kSecAttrService as String: service,
				kSecAttrAccount as String: account,
				kSecReturnData as String: true,
				kSecMatchLimit as String: kSecMatchLimitOne
			]
			var result: AnyObject?
			guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else {
				return nil
			}
			return String(data: data, encoding: .utf8)
		}
		set {
			let query: [String: Any] = [
				kSecClass as String: kSecClassGenericPassword,
				kSecAttrService as String: service,
				kSecAttrAccount as String: account
			]
			SecItemDelete(query as CFDictionary)

			guard let newValue, !newValue.isEmpty else {
				return
			}
			var attributes = query
			attributes[kSecValueData as String] = Data(newValue.utf8)
			attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
			SecItemAdd(attributes as CFDictionary, nil)
		}
	}
}
