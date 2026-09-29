//
//  ArticleTranslator.swift
//  NetNewsWire
//
//  Created by NetNewsWire contributors on 9/29/26.
//

import Foundation
import WebKit
import os
import RSCore

/// Drives translation.js in an article web view. The page reports paragraphs as they
/// scroll into view; they're translated in small batches so each one shows up quickly.
@MainActor final class ArticleTranslator {

	/// Message handler name translation.js posts to. Register it in the `.defaultClient` content world.
	static let messageName = "nnwTranslate"

	private static let logger = Logger(subsystem: Logger.nnwSubsystem, category: "ArticleTranslator")
	private static let maxItemsPerBatch = 3

	/// Bumped on every start and cancel, so results for a previous page are dropped.
	private var generation = 0
	private var tasks = [UUID: Task<Void, Never>]()

	func start(_ webView: WKWebView) {
		cancel()
		let options: [String: Any] = ["generation": generation, "skipCJK": TranslationSettings.shared.skipsCJKText]
		webView.callAsyncJavaScript("nnwTranslation.start(options);", arguments: ["options": options], in: nil, in: .defaultClient) { result in
			if case .failure(let error) = result {
				Self.logger.error("ArticleTranslator: couldn't start: \(error.localizedDescription)")
			}
		}
	}

	func clear(_ webView: WKWebView) {
		cancel()
		webView.evaluateJavaScript("nnwTranslation.clear();", in: nil, in: .defaultClient) { _ in }
	}

	func cancel() {
		generation += 1
		for task in tasks.values {
			task.cancel()
		}
		tasks.removeAll()
	}

	/// Handles a batch of newly visible paragraphs posted by translation.js.
	func handleMessage(_ body: Any, webView: WKWebView) {
		guard let message = body as? [String: Any],
			  let messageGeneration = message["generation"] as? Int,
			  messageGeneration == generation,
			  let rawItems = message["items"] as? [[String: Any]] else {
			return
		}

		let items = rawItems.compactMap { rawItem -> TranslationItem? in
			guard let id = rawItem["id"] as? String, let text = rawItem["text"] as? String else {
				return nil
			}
			return TranslationItem(id: id, text: text)
		}
		guard !items.isEmpty else {
			return
		}

		let configuration = TranslationSettings.shared.configuration
		let taskID = UUID()

		tasks[taskID] = Task { [weak self, weak webView] in
			defer {
				self?.tasks[taskID] = nil
			}
			let stream = TranslationService.shared.translate(items, configuration: configuration, maxItemsPerBatch: Self.maxItemsPerBatch)
			for await result in stream {
				guard !Task.isCancelled, let webView else {
					return
				}
				switch result {
				case .translated(let translations):
					let results = translations.map { ["id": $0.id, "text": $0.text] }
					_ = try? await webView.callAsyncJavaScript("nnwTranslation.apply(generation, results);", arguments: ["generation": messageGeneration, "results": results], contentWorld: .defaultClient)
				case .failed(let ids, let message):
					let failureText = String(format: NSLocalizedString("Translation failed: %@", comment: "Translation"), message)
					_ = try? await webView.callAsyncJavaScript("nnwTranslation.fail(generation, ids, message);", arguments: ["generation": messageGeneration, "ids": ids, "message": failureText], contentWorld: .defaultClient)
				}
			}
		}
	}
}
