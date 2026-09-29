//
//  TranslationService.swift
//  NetNewsWire
//
//  Created by NetNewsWire contributors on 9/29/26.
//

import Foundation
import CryptoKit
import RSCore
import os

struct TranslationItem: Sendable {
	let id: String
	let text: String
}

enum TranslationBatchResult: Sendable {
	/// (paragraph id, translated text) pairs.
	case translated([(id: String, text: String)])
	case failed(ids: [String], message: String)
}

enum TranslationError: LocalizedError {
	case invalidURL(String)
	case httpError(status: Int, message: String)
	case unexpectedResponse(String)

	var errorDescription: String? {
		switch self {
		case .invalidURL(let url):
			return String(format: NSLocalizedString("Invalid API URL: %@", comment: "Translation error"), url)
		case .httpError(let status, let message):
			return "HTTP \(status): \(message)"
		case .unexpectedResponse(let detail):
			return String(format: NSLocalizedString("Unexpected response from the model: %@", comment: "Translation error"), detail)
		}
	}
}

/// Translates article paragraphs with an OpenAI-compatible chat completions API.
/// Paragraphs are sent in batches, and results are cached on disk by model, language, and text.
actor TranslationService {

	static let shared = TranslationService()

	private static let logger = Logger(subsystem: Logger.nnwSubsystem, category: "TranslationService")

	private static let maxItemsPerBatch = 20
	private static let maxCharactersPerBatch = 6000
	private static let maxConcurrentRequests = 3

	private let session: URLSession
	private let cacheFolder: URL?
	private var memoryCache = [String: String]()

	init() {
		let configuration = URLSessionConfiguration.ephemeral
		configuration.timeoutIntervalForRequest = 90
		session = URLSession(configuration: configuration)

		if let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
			let folder = caches.appendingPathComponent("Translations", isDirectory: true)
			try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
			cacheFolder = folder
		} else {
			cacheFolder = nil
		}
	}

	/// Yields results as they arrive: cached paragraphs first, then one result per batch.
	nonisolated func translate(_ items: [TranslationItem], configuration: TranslationConfiguration) -> AsyncStream<TranslationBatchResult> {
		AsyncStream { continuation in
			let task = Task {
				await self.run(items, configuration: configuration, continuation: continuation)
				continuation.finish()
			}
			continuation.onTermination = { _ in
				task.cancel()
			}
		}
	}

	/// Translates one string, bypassing the cache. Used to check the settings.
	func testTranslation(_ text: String, configuration: TranslationConfiguration) async throws -> String {
		let results = try await requestTranslations([text], configuration: configuration)
		return results.first ?? ""
	}
}

private extension TranslationService {

	func run(_ items: [TranslationItem], configuration: TranslationConfiguration, continuation: AsyncStream<TranslationBatchResult>.Continuation) async {
		var cached = [(id: String, text: String)]()
		var uncached = [TranslationItem]()

		for item in items {
			if let translation = cachedTranslation(item.text, configuration: configuration) {
				cached.append((item.id, translation))
			} else {
				uncached.append(item)
			}
		}

		if !cached.isEmpty {
			continuation.yield(.translated(cached))
		}

		let batches = Self.makeBatches(uncached)
		guard !batches.isEmpty else {
			return
		}

		await withTaskGroup(of: TranslationBatchResult.self) { group in
			var nextBatchIndex = 0

			func addNextBatch() {
				guard nextBatchIndex < batches.count else {
					return
				}
				let batch = batches[nextBatchIndex]
				nextBatchIndex += 1
				group.addTask {
					await self.translateBatch(batch, configuration: configuration)
				}
			}

			for _ in 0..<Self.maxConcurrentRequests {
				addNextBatch()
			}
			for await result in group {
				continuation.yield(result)
				if Task.isCancelled {
					group.cancelAll()
					return
				}
				addNextBatch()
			}
		}
	}

	func translateBatch(_ batch: [TranslationItem], configuration: TranslationConfiguration) async -> TranslationBatchResult {
		do {
			let translations = try await translateSplittingOnMismatch(batch.map(\.text), configuration: configuration)
			var results = [(id: String, text: String)]()
			for (item, translation) in zip(batch, translations) {
				storeCachedTranslation(translation, for: item.text, configuration: configuration)
				results.append((item.id, translation))
			}
			return .translated(results)
		} catch {
			Self.logger.error("TranslationService: batch failed: \(error.localizedDescription)")
			return .failed(ids: batch.map(\.id), message: error.localizedDescription)
		}
	}

	/// Models sometimes merge or drop entries in a long batch. When the counts don't match, retry each half.
	func translateSplittingOnMismatch(_ texts: [String], configuration: TranslationConfiguration) async throws -> [String] {
		do {
			return try await requestTranslations(texts, configuration: configuration)
		} catch TranslationError.unexpectedResponse(let detail) where texts.count > 1 {
			Self.logger.info("TranslationService: splitting batch of \(texts.count) after unexpected response: \(detail)")
			let middle = texts.count / 2
			let first = try await translateSplittingOnMismatch(Array(texts[..<middle]), configuration: configuration)
			let second = try await translateSplittingOnMismatch(Array(texts[middle...]), configuration: configuration)
			return first + second
		}
	}

	func requestTranslations(_ texts: [String], configuration: TranslationConfiguration) async throws -> [String] {
		let url = try Self.completionsURL(configuration.baseURL)

		let systemPrompt = """
		You are a professional translator. The user sends a JSON array of strings taken from a news article or blog post. \
		Translate each string into \(configuration.targetLanguage). \
		Reply with only a JSON array of strings: exactly \(texts.count) elements, in the same order, one translation per input string. \
		Keep names, code, URLs, and numbers intact. If a string is already in \(configuration.targetLanguage), return it unchanged. \
		No explanations, no Markdown.
		"""
		let userContent = String(decoding: try JSONEncoder().encode(texts), as: UTF8.self)

		let body: [String: Any] = [
			"model": configuration.model,
			"stream": false,
			"messages": [
				["role": "system", "content": systemPrompt],
				["role": "user", "content": userContent]
			]
		]

		var request = URLRequest(url: url)
		request.httpMethod = "POST"
		request.setValue("application/json", forHTTPHeaderField: "Content-Type")
		if !configuration.apiKey.isEmpty {
			request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
		}
		request.httpBody = try JSONSerialization.data(withJSONObject: body)

		let (data, response) = try await session.data(for: request)

		if let httpResponse = response as? HTTPURLResponse, !(200..<300).contains(httpResponse.statusCode) {
			throw TranslationError.httpError(status: httpResponse.statusCode, message: Self.errorMessage(from: data))
		}

		guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
			  let choices = json["choices"] as? [[String: Any]],
			  let message = choices.first?["message"] as? [String: Any],
			  let content = message["content"] as? String else {
			throw TranslationError.unexpectedResponse(String(decoding: data.prefix(200), as: UTF8.self))
		}

		let translations = try Self.parseTranslations(content)
		guard translations.count == texts.count else {
			throw TranslationError.unexpectedResponse("expected \(texts.count) translations, got \(translations.count)")
		}
		return translations
	}

	// MARK: Cache

	func cacheKey(_ text: String, configuration: TranslationConfiguration) -> String {
		let digest = SHA256.hash(data: Data("\(configuration.model)\n\(configuration.targetLanguage)\n\(text)".utf8))
		return digest.map { String(format: "%02x", $0) }.joined()
	}

	func cachedTranslation(_ text: String, configuration: TranslationConfiguration) -> String? {
		let key = cacheKey(text, configuration: configuration)
		if let translation = memoryCache[key] {
			return translation
		}
		guard let cacheFolder, let data = try? Data(contentsOf: cacheFolder.appendingPathComponent(key)) else {
			return nil
		}
		let translation = String(decoding: data, as: UTF8.self)
		memoryCache[key] = translation
		return translation
	}

	func storeCachedTranslation(_ translation: String, for text: String, configuration: TranslationConfiguration) {
		let key = cacheKey(text, configuration: configuration)
		memoryCache[key] = translation
		guard let cacheFolder else {
			return
		}
		try? Data(translation.utf8).write(to: cacheFolder.appendingPathComponent(key), options: .atomic)
	}

	// MARK: Helpers

	static func makeBatches(_ items: [TranslationItem]) -> [[TranslationItem]] {
		var batches = [[TranslationItem]]()
		var current = [TranslationItem]()
		var characterCount = 0

		for item in items {
			if !current.isEmpty && (current.count >= maxItemsPerBatch || characterCount + item.text.count > maxCharactersPerBatch) {
				batches.append(current)
				current = []
				characterCount = 0
			}
			current.append(item)
			characterCount += item.text.count
		}
		if !current.isEmpty {
			batches.append(current)
		}
		return batches
	}

	static func completionsURL(_ baseURL: String) throws -> URL {
		var urlString = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
		while urlString.hasSuffix("/") {
			urlString.removeLast()
		}
		if !urlString.hasSuffix("/chat/completions") {
			urlString += "/chat/completions"
		}
		guard let url = URL(string: urlString), url.scheme == "https" || url.scheme == "http" else {
			throw TranslationError.invalidURL(baseURL)
		}
		return url
	}

	/// Pulls the JSON array out of the reply, tolerating code fences, reasoning blocks, and surrounding text.
	static func parseTranslations(_ content: String) throws -> [String] {
		var text = content
		if let thinkEnd = text.range(of: "</think>") {
			text = String(text[thinkEnd.upperBound...])
		}
		guard let start = text.firstIndex(of: "["), let end = text.lastIndex(of: "]"), start < end else {
			throw TranslationError.unexpectedResponse(String(content.prefix(200)))
		}
		let arrayText = text[start...end]
		guard let translations = try? JSONDecoder().decode([String].self, from: Data(arrayText.utf8)) else {
			throw TranslationError.unexpectedResponse(String(content.prefix(200)))
		}
		return translations.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
	}

	static func errorMessage(from data: Data) -> String {
		if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
			if let error = json["error"] as? [String: Any], let message = error["message"] as? String {
				return message
			}
			if let message = json["error"] as? String {
				return message
			}
		}
		return String(decoding: data.prefix(200), as: UTF8.self)
	}
}
