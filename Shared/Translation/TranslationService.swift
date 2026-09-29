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

enum TranslationEvent: Sendable {
	/// The translation so far, while the model is still writing it.
	case partial(String)
	case translated(String)
	case failed(String)
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

/// Translates article paragraphs, one per request, with an OpenAI-compatible chat completions API.
/// Replies are streamed so text shows up as the model writes it, and finished translations
/// are cached on disk by model, language, and text.
actor TranslationService {

	static let shared = TranslationService()

	private static let logger = Logger(subsystem: Logger.nnwSubsystem, category: "TranslationService")

	private let session: URLSession
	private let cacheFolder: URL?
	private var memoryCache = [String: String]()

	/// Models that answered 400 when asked not to reason — their reasoning can't be turned off.
	private var modelsRequiringReasoning = Set<String>()

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

	/// Yields partial translations while the reply streams in, then exactly one `.translated` or `.failed`.
	/// A cached translation comes back right away as `.translated`.
	nonisolated func translate(_ text: String, configuration: TranslationConfiguration) -> AsyncStream<TranslationEvent> {
		AsyncStream { continuation in
			let task = Task {
				await self.run(text, configuration: configuration, continuation: continuation)
				continuation.finish()
			}
			continuation.onTermination = { _ in
				task.cancel()
			}
		}
	}

	/// Translates one string, bypassing the cache. Used to check the settings.
	func testTranslation(_ text: String, configuration: TranslationConfiguration) async throws -> String {
		try await requestTranslation(text, configuration: configuration) { _ in }
	}
}

private extension TranslationService {

	func run(_ text: String, configuration: TranslationConfiguration, continuation: AsyncStream<TranslationEvent>.Continuation) async {
		if let translation = cachedTranslation(text, configuration: configuration) {
			continuation.yield(.translated(translation))
			return
		}

		do {
			let translation = try await requestTranslation(text, configuration: configuration) { partial in
				continuation.yield(.partial(partial))
			}
			storeCachedTranslation(translation, for: text, configuration: configuration)
			continuation.yield(.translated(translation))
		} catch is CancellationError {
			return
		} catch {
			if Task.isCancelled {
				return
			}
			Self.logger.error("TranslationService: request failed: \(error.localizedDescription)")
			continuation.yield(.failed(error.localizedDescription))
		}
	}

	func requestTranslation(_ text: String, configuration: TranslationConfiguration, onPartial: @Sendable (String) -> Void) async throws -> String {
		var disablesReasoning = Self.canDisableReasoning(configuration) && !modelsRequiringReasoning.contains(configuration.model)

		while true {
			let request = try Self.makeRequest(text, configuration: configuration, disablesReasoning: disablesReasoning)
			let (bytes, response) = try await session.bytes(for: request)
			let httpResponse = response as? HTTPURLResponse

			if let httpResponse, !(200..<300).contains(httpResponse.statusCode) {
				let data = try await Self.collect(bytes, limit: 4096)
				if disablesReasoning && httpResponse.statusCode == 400 {
					Self.logger.info("TranslationService: \(configuration.model) can't turn off reasoning; retrying with it on")
					modelsRequiringReasoning.insert(configuration.model)
					disablesReasoning = false
					continue
				}
				throw TranslationError.httpError(status: httpResponse.statusCode, message: Self.errorMessage(from: data))
			}

			// A server that ignores "stream" answers with a single JSON body.
			let contentType = httpResponse?.value(forHTTPHeaderField: "Content-Type") ?? ""
			guard contentType.contains("text/event-stream") else {
				let data = try await Self.collect(bytes, limit: nil)
				return try Self.checkedTranslation(Self.messageContent(from: data))
			}

			var reply = ""
			for try await line in bytes.lines {
				try Task.checkCancellation()
				guard line.hasPrefix("data:") else {
					continue
				}
				let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
				if payload == "[DONE]" {
					break
				}
				guard let json = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else {
					continue
				}
				if let error = json["error"] {
					throw TranslationError.unexpectedResponse(Self.errorMessage(fromErrorValue: error))
				}
				guard let choices = json["choices"] as? [[String: Any]],
					  let delta = choices.first?["delta"] as? [String: Any],
					  let piece = delta["content"] as? String,
					  !piece.isEmpty else {
					continue
				}
				reply += piece
				let visible = Self.visibleText(ofPartialReply: reply)
				if !visible.isEmpty {
					onPartial(visible)
				}
			}
			return try Self.checkedTranslation(reply)
		}
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

	// MARK: Request

	static func makeRequest(_ text: String, configuration: TranslationConfiguration, disablesReasoning: Bool) throws -> URLRequest {
		let systemPrompt = """
		You are a professional translator. The user sends one paragraph from a news article or blog post. \
		Translate it into \(configuration.targetLanguage). \
		Reply with only the translation. \
		Keep names, code, URLs, and numbers intact. If it's already in \(configuration.targetLanguage), return it unchanged. \
		No explanations, no quotes, no Markdown.
		"""

		var body: [String: Any] = [
			"model": configuration.model,
			"stream": true,
			"messages": [
				["role": "system", "content": systemPrompt],
				["role": "user", "content": text]
			]
		]
		// Translation doesn't need the model to think first, and thinking delays the first word by seconds.
		if disablesReasoning {
			body["reasoning"] = ["effort": "none"]
		}

		var request = URLRequest(url: try completionsURL(configuration.baseURL))
		request.httpMethod = "POST"
		request.setValue("application/json", forHTTPHeaderField: "Content-Type")
		request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
		if !configuration.apiKey.isEmpty {
			request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
		}
		request.httpBody = try JSONSerialization.data(withJSONObject: body)
		return request
	}

	/// Only OpenRouter gets the reasoning parameter; other servers may reject parameters they don't know.
	static func canDisableReasoning(_ configuration: TranslationConfiguration) -> Bool {
		URL(string: configuration.baseURL)?.host?.hasSuffix("openrouter.ai") ?? false
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

	// MARK: Response

	static func collect(_ bytes: URLSession.AsyncBytes, limit: Int?) async throws -> Data {
		var data = Data()
		for try await byte in bytes {
			data.append(byte)
			if let limit, data.count >= limit {
				break
			}
		}
		return data
	}

	static func messageContent(from data: Data) throws -> String {
		guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
			  let choices = json["choices"] as? [[String: Any]],
			  let message = choices.first?["message"] as? [String: Any],
			  let content = message["content"] as? String else {
			throw TranslationError.unexpectedResponse(String(decoding: data.prefix(200), as: UTF8.self))
		}
		return content
	}

	static func checkedTranslation(_ reply: String) throws -> String {
		let translation = cleanedTranslation(reply)
		guard !translation.isEmpty else {
			throw TranslationError.unexpectedResponse(NSLocalizedString("empty translation", comment: "Translation error"))
		}
		return translation
	}

	/// What to show while a reply is still streaming: nothing during a <think> block.
	static func visibleText(ofPartialReply reply: String) -> String {
		let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
		if trimmed.hasPrefix("<think>") && !trimmed.contains("</think>") {
			return ""
		}
		return cleanedTranslation(reply)
	}

	/// Strips reasoning blocks and code fences some models wrap around a plain-text reply.
	static func cleanedTranslation(_ reply: String) -> String {
		var text = reply
		if let thinkEnd = text.range(of: "</think>") {
			text = String(text[thinkEnd.upperBound...])
		}
		text = text.trimmingCharacters(in: .whitespacesAndNewlines)
		if text.hasPrefix("```") {
			text = String(text.dropFirst(3))
			if let firstNewline = text.firstIndex(of: "\n"), !text[..<firstNewline].contains(" ") {
				text = String(text[text.index(after: firstNewline)...])
			}
			if text.hasSuffix("```") {
				text = String(text.dropLast(3))
			}
		}
		return text.trimmingCharacters(in: .whitespacesAndNewlines)
	}

	static func errorMessage(from data: Data) -> String {
		if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let error = json["error"] {
			return errorMessage(fromErrorValue: error)
		}
		return String(decoding: data.prefix(200), as: UTF8.self)
	}

	static func errorMessage(fromErrorValue error: Any) -> String {
		if let error = error as? [String: Any], let message = error["message"] as? String {
			return message
		}
		if let message = error as? String {
			return message
		}
		return String(describing: error)
	}
}
