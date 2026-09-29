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
		hostingView.frame = NSRect(x: 0, y: 0, width: 512, height: hostingView.fittingSize.height)
		view = hostingView
	}
}

private struct TranslationPreferencesView: View {

	@State private var isEnabled = TranslationSettings.shared.isEnabled
	@State private var baseURL = TranslationSettings.shared.baseURL
	@State private var apiKey = TranslationSettings.shared.apiKey
	@State private var model = TranslationSettings.shared.model
	@State private var targetLanguage = TranslationSettings.shared.targetLanguage

	@State private var isTesting = false
	@State private var testResult: String?

	private var hasUnsavedChanges: Bool {
		let settings = TranslationSettings.shared
		return baseURL != settings.baseURL || apiKey != settings.apiKey || model != settings.model || targetLanguage != settings.targetLanguage
	}

	var body: some View {
		Form {
			Toggle(NSLocalizedString("Translate articles (⇧⌘T)", comment: "Translation preferences"), isOn: $isEnabled)
				.onChange(of: isEnabled) { _, newValue in
					TranslationSettings.shared.isEnabled = newValue
				}

			TextField(NSLocalizedString("API Base URL:", comment: "Translation preferences"), text: $baseURL, prompt: Text(TranslationSettings.defaultBaseURL))
			SecureField(NSLocalizedString("API Key:", comment: "Translation preferences"), text: $apiKey, prompt: Text("sk-"))
			TextField(NSLocalizedString("Model:", comment: "Translation preferences"), text: $model, prompt: Text(TranslationSettings.defaultModel))

			Picker(NSLocalizedString("Translate Into:", comment: "Translation preferences"), selection: $targetLanguage) {
				ForEach(languageChoices, id: \.self) { language in
					Text(language).tag(language)
				}
			}

			Text(NSLocalizedString("Works with any OpenAI-compatible API — OpenAI, DeepSeek, OpenRouter, a local Ollama (http://localhost:11434/v1), and more. The key is stored in the keychain.", comment: "Translation preferences"))
				.font(.caption)
				.foregroundStyle(.secondary)
				.fixedSize(horizontal: false, vertical: true)

			HStack {
				Button(NSLocalizedString("Test", comment: "Translation preferences")) {
					test()
				}
				.disabled(isTesting)

				if isTesting {
					ProgressView().controlSize(.small)
				} else if let testResult {
					Text(testResult)
						.lineLimit(2)
						.textSelection(.enabled)
				}

				Spacer()

				Button(NSLocalizedString("Save", comment: "Translation preferences")) {
					save()
				}
				.keyboardShortcut(.defaultAction)
				.disabled(!hasUnsavedChanges)
			}
		}
		.padding(20)
		.frame(width: 512)
		.onReceive(NotificationCenter.default.publisher(for: .translationSettingsDidChange)) { _ in
			isEnabled = TranslationSettings.shared.isEnabled
		}
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
			model: model.isEmpty ? TranslationSettings.defaultModel : model,
			targetLanguage: targetLanguage
		)
		isTesting = true
		testResult = nil
		Task {
			do {
				let translation = try await TranslationService.shared.testTranslation("The quick brown fox jumps over the lazy dog.", configuration: configuration)
				testResult = "✅ " + translation
			} catch {
				testResult = "❌ " + error.localizedDescription
			}
			isTesting = false
		}
	}
}
