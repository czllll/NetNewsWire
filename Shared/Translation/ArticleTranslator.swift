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
/// scroll into view; each is translated in its own request, a few at a time,
/// and results are shown strictly top to bottom — a later batch that finishes first
/// waits for the ones above it.
@MainActor final class ArticleTranslator {

	/// Message handler name translation.js posts to. Register it in the `.defaultClient` content world.
	static let messageName = "nnwTranslate"

	private static let logger = Logger(subsystem: Logger.nnwSubsystem, category: "ArticleTranslator")
	private static let maxItemsPerBatch = 1
	private static let maxConcurrentBatches = 5

	/// Bumped on every start and cancel, so results for a previous page are dropped.
	private var generation = 0
	private weak var webView: WKWebView?
	private var configuration: TranslationConfiguration?

	/// Paragraphs waiting for a request, in document order.
	private var pendingItems = [TranslationItem]()
	private var tasks = [Int: Task<Void, Never>]()
	private var nextSequence = 0
	private var nextSequenceToShow = 0
	private var finishedBatches = [Int: [TranslationBatchResult]]()

	func start(_ webView: WKWebView) {
		cancel()
		self.webView = webView
		configuration = TranslationSettings.shared.configuration

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
		pendingItems.removeAll()
		finishedBatches.removeAll()
		nextSequence = 0
		nextSequenceToShow = 0
		webView = nil
		configuration = nil
	}

	/// Handles newly visible paragraphs posted by translation.js.
	func handleMessage(_ body: Any, webView: WKWebView) {
		guard webView === self.webView,
			  let message = body as? [String: Any],
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

		pendingItems.append(contentsOf: items)
		// Paragraph ids count up in document order. After scrolling back up, earlier paragraphs go first.
		pendingItems.sort { (Int($0.id) ?? 0) < (Int($1.id) ?? 0) }
		startBatchesIfPossible()
	}
}

private extension ArticleTranslator {

	func startBatchesIfPossible() {
		guard let configuration else {
			return
		}

		while tasks.count < Self.maxConcurrentBatches && !pendingItems.isEmpty {
			let batch = Array(pendingItems.prefix(Self.maxItemsPerBatch))
			pendingItems.removeFirst(batch.count)

			let sequence = nextSequence
			nextSequence += 1
			let batchGeneration = generation

			tasks[sequence] = Task { [weak self] in
				var results = [TranslationBatchResult]()
				for await result in TranslationService.shared.translate(batch, configuration: configuration, maxItemsPerBatch: batch.count) {
					results.append(result)
				}
				guard !Task.isCancelled else {
					return
				}
				self?.batchDidFinish(sequence: sequence, generation: batchGeneration, results: results)
			}
		}
	}

	func batchDidFinish(sequence: Int, generation batchGeneration: Int, results: [TranslationBatchResult]) {
		guard batchGeneration == generation else {
			return
		}
		tasks[sequence] = nil
		finishedBatches[sequence] = results
		showFinishedBatchesInOrder()
		startBatchesIfPossible()
	}

	func showFinishedBatchesInOrder() {
		while let results = finishedBatches.removeValue(forKey: nextSequenceToShow) {
			nextSequenceToShow += 1
			for result in results {
				show(result)
			}
		}
	}

	func show(_ result: TranslationBatchResult) {
		guard let webView else {
			return
		}

		switch result {
		case .translated(let translations):
			let results = translations.map { ["id": $0.id, "text": $0.text] }
			webView.callAsyncJavaScript("nnwTranslation.apply(generation, results);", arguments: ["generation": generation, "results": results], in: nil, in: .defaultClient) { _ in }
		case .failed(let ids, let message):
			let failureText = String(format: NSLocalizedString("Translation failed: %@", comment: "Translation"), message)
			webView.callAsyncJavaScript("nnwTranslation.fail(generation, ids, message);", arguments: ["generation": generation, "ids": ids, "message": failureText], in: nil, in: .defaultClient) { _ in }
		}
	}
}
