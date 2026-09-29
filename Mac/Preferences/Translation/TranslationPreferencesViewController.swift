//
//  TranslationPreferencesViewController.swift
//  NetNewsWire
//
//  Created by NetNewsWire contributors on 9/29/26.
//

import AppKit
import SwiftUI

final class TranslationPreferencesViewController: NSViewController {

	override func loadView() {
		let hostingView = NSHostingView(rootView: TranslationPreferencesView())
		hostingView.frame = NSRect(x: 0, y: 0, width: 512, height: TranslationPreferencesView.height)
		view = hostingView
	}
}

private struct TranslationProvider: Identifiable, Hashable {
	let name: String
	let baseURL: String
	let suggestedModel: String
	let needsAPIKey: Bool

	var id: String { baseURL }

	static let all = [
		TranslationProvider(name: "OpenAI", baseURL: "https://api.openai.com/v1", suggestedModel: "gpt-4o-mini", needsAPIKey: true),
		TranslationProvider(name: "DeepSeek", baseURL: "https://api.deepseek.com/v1", suggestedModel: "deepseek-chat", needsAPIKey: true),
		TranslationProvider(name: "OpenRouter", baseURL: "https://openrouter.ai/api/v1", suggestedModel: "openai/gpt-4o-mini", needsAPIKey: true),
		TranslationProvider(name: "Ollama", baseURL: "http://localhost:11434/v1", suggestedModel: "qwen2.5:7b", needsAPIKey: false)
	]

	static func matching(_ baseURL: String) -> TranslationProvider? {
		var normalized = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
		if normalized.hasSuffix("/chat/completions") {
			normalized = String(normalized.dropLast("/chat/completions".count))
		}
		return all.first { $0.baseURL == normalized }
	}
}

private struct TranslationPreferencesView: View {

	static let height: CGFloat = 392

	private static let customProviderID = "custom"

	@State private var isEnabled = TranslationSettings.shared.isEnabled
	@State private var baseURL = TranslationSettings.shared.baseURL
	@State private var apiKey = TranslationSettings.shared.apiKey
	@State private var model = TranslationSettings.shared.model
	@State private var targetLanguage = TranslationSettings.shared.targetLanguage

	@State private var testState = TestState.idle

	private enum TestState: Equatable {
		case idle
		case testing
		case succeeded(String)
		case failed(String)
	}

	private var providerID: Binding<String> {
		Binding {
			TranslationProvider.matching(baseURL)?.id ?? Self.customProviderID
		} set: { newID in
			guard let provider = TranslationProvider.all.first(where: { $0.id == newID }) else {
				return
			}
			baseURL = provider.baseURL
			model = provider.suggestedModel
		}
	}

	private var isCustomProvider: Bool {
		TranslationProvider.matching(baseURL) == nil
	}

	private var hasUnsavedChanges: Bool {
		let settings = TranslationSettings.shared
		return baseURL != settings.baseURL || apiKey != settings.apiKey || model != settings.model || targetLanguage != settings.targetLanguage
	}

	var body: some View {
		VStack(spacing: 0) {
			Form {
				Section {
					Toggle(isOn: $isEnabled) {
						Text(NSLocalizedString("Translate Articles", comment: "Translation preferences"))
						Text(NSLocalizedString("Shows a translation under each paragraph. Toggle with ⇧⌘T.", comment: "Translation preferences"))
					}
					.onChange(of: isEnabled) { _, newValue in
						TranslationSettings.shared.isEnabled = newValue
					}

					Picker(NSLocalizedString("Translate Into", comment: "Translation preferences"), selection: $targetLanguage) {
						ForEach(languageChoices, id: \.self) { language in
							Text(language).tag(language)
						}
					}
				}

				Section {
					Picker(NSLocalizedString("Service", comment: "Translation preferences"), selection: providerID) {
						ForEach(TranslationProvider.all) { provider in
							Text(provider.name).tag(provider.id)
						}
						Divider()
						Text(NSLocalizedString("Custom", comment: "Translation preferences")).tag(Self.customProviderID)
					}

					if isCustomProvider {
						TextField(NSLocalizedString("API URL", comment: "Translation preferences"), text: $baseURL, prompt: Text("https://example.com/v1"))
					}

					SecureField(NSLocalizedString("API Key", comment: "Translation preferences"), text: $apiKey, prompt: Text(apiKeyPrompt))

					TextField(NSLocalizedString("Model", comment: "Translation preferences"), text: $model, prompt: Text(TranslationProvider.matching(baseURL)?.suggestedModel ?? TranslationSettings.defaultModel))
				} header: {
					Text(NSLocalizedString("Model Service", comment: "Translation preferences"))
				} footer: {
					Text(NSLocalizedString("Any OpenAI-compatible chat completions API works. The key is stored in your keychain.", comment: "Translation preferences"))
						.font(.caption)
						.foregroundStyle(.secondary)
				}
			}
			.formStyle(.grouped)
			.scrollDisabled(true)

			HStack(spacing: 8) {
				testStatusView
				Spacer()
				Button(NSLocalizedString("Test", comment: "Translation preferences")) {
					test()
				}
				.disabled(testState == .testing)

				Button(NSLocalizedString("Save", comment: "Translation preferences")) {
					save()
				}
				.keyboardShortcut(.defaultAction)
				.disabled(!hasUnsavedChanges)
			}
			.padding(.horizontal, 20)
			.padding(.bottom, 16)
		}
		.frame(width: 512, height: Self.height)
		.onReceive(NotificationCenter.default.publisher(for: .translationSettingsDidChange)) { _ in
			isEnabled = TranslationSettings.shared.isEnabled
		}
	}

	@ViewBuilder private var testStatusView: some View {
		switch testState {
		case .idle:
			EmptyView()
		case .testing:
			ProgressView()
				.controlSize(.small)
		case .succeeded(let translation):
			Label(translation, systemImage: "checkmark.circle.fill")
				.foregroundStyle(.green)
				.lineLimit(1)
				.truncationMode(.tail)
				.help(translation)
		case .failed(let message):
			Label(message, systemImage: "exclamationmark.triangle.fill")
				.foregroundStyle(.red)
				.lineLimit(2)
				.truncationMode(.tail)
				.help(message)
		}
	}

	private var apiKeyPrompt: String {
		if let provider = TranslationProvider.matching(baseURL), !provider.needsAPIKey {
			return NSLocalizedString("Not needed", comment: "Translation preferences")
		}
		return NSLocalizedString("Required", comment: "Translation preferences")
	}

	private var languageChoices: [String] {
		var languages = TranslationSettings.targetLanguages
		if !languages.contains(targetLanguage) {
			languages.append(targetLanguage)
		}
		return languages
	}

	private func save() {
		let settings = TranslationSettings.shared
		if baseURL != settings.baseURL {
			settings.baseURL = baseURL
		}
		if apiKey != settings.apiKey {
			settings.apiKey = apiKey
		}
		if model != settings.model {
			settings.model = model
		}
		if targetLanguage != settings.targetLanguage {
			settings.targetLanguage = targetLanguage
		}
		baseURL = settings.baseURL
		model = settings.model
	}

	private func test() {
		let configuration = TranslationConfiguration(
			baseURL: baseURL.isEmpty ? TranslationSettings.defaultBaseURL : baseURL,
			apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
			model: model.isEmpty ? (TranslationProvider.matching(baseURL)?.suggestedModel ?? TranslationSettings.defaultModel) : model,
			targetLanguage: targetLanguage
		)
		testState = .testing
		Task {
			do {
				let translation = try await TranslationService.shared.testTranslation("The quick brown fox jumps over the lazy dog.", configuration: configuration)
				testState = .succeeded(translation)
			} catch {
				testState = .failed(error.localizedDescription)
			}
		}
	}
}
