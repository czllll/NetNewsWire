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
/// scroll into view; each is translated in its own streaming request, a few at a time.
/// Translations appear strictly top to bottom: the topmost unfinished paragraph fills in
/// as the model writes, and paragraphs below it wait their turn, then appear at once.
@MainActor final class ArticleTranslator {

	/// Message handler name translation.js posts to. Register it in the `.defaultClient` content world.
	static let messageName = "nnwTranslate"

	private static let logger = Logger(subsystem: Logger.nnwSubsystem, category: "ArticleTranslator")
	private static let maxConcurrentRequests = 5

	/// Bumped on every start and cancel, so results for a previous page are dropped.
	private var generation = 0
	private weak var webView: WKWebView?
	private var configuration: TranslationConfiguration?

	/// Paragraphs waiting for a request, in document order.
	private var pendingItems = [TranslationItem]()
	private var tasks = [Int: Task<Void, Never>]()
	/// Requested paragraphs by sequence number, until they're shown.
	private var requests = [Int: Request]()
	private var nextSequence = 0
	private var nextSequenceToShow = 0

	private struct Request {
		let id: String
		var partialText: String?
		var finalEvent: TranslationEvent?
	}

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
		requests.removeAll()
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
		startRequestsIfPossible()
	}
}

private extension ArticleTranslator {

	func startRequestsIfPossible() {
		guard let configuration else {
			return
		}

		while tasks.count < Self.maxConcurrentRequests && !pendingItems.isEmpty {
			let item = pendingItems.removeFirst()
			let sequence = nextSequence
			nextSequence += 1
			let requestGeneration = generation
			requests[sequence] = Request(id: item.id)

			tasks[sequence] = Task { [weak self] in
				for await event in TranslationService.shared.translate(item.text, configuration: configuration) {
					guard !Task.isCancelled else {
						return
					}
					self?.request(sequence, generation: requestGeneration, didProduce: event)
				}
			}
		}
	}

	func request(_ sequence: Int, generation requestGeneration: Int, didProduce event: TranslationEvent) {
		guard requestGeneration == generation, requests[sequence] != nil else {
			return
		}

		if case .partial(let text) = event {
			requests[sequence]?.partialText = text
			if sequence == nextSequenceToShow, let id = requests[sequence]?.id {
				showTranslation(text, id: id)
			}
			return
		}

		tasks[sequence] = nil
		requests[sequence]?.finalEvent = event
		showFinishedRequestsInOrder()
		startRequestsIfPossible()
	}

	func showFinishedRequestsInOrder() {
		while let request = requests[nextSequenceToShow], let finalEvent = request.finalEvent {
			requests[nextSequenceToShow] = nil
			nextSequenceToShow += 1

			switch finalEvent {
			case .translated(let text), .partial(let text):
				showTranslation(text, id: request.id)
			case .failed(let message):
				showFailure(message, id: request.id)
			}
		}

		// The new topmost paragraph may already be partway through its reply.
		if let request = requests[nextSequenceToShow], let partialText = request.partialText {
			showTranslation(partialText, id: request.id)
		}
	}

	func showTranslation(_ text: String, id: String) {
		let results = [["id": id, "text": text]]
		webView?.callAsyncJavaScript("nnwTranslation.apply(generation, results);", arguments: ["generation": generation, "results": results], in: nil, in: .defaultClient) { _ in }
	}

	func showFailure(_ message: String, id: String) {
		let failureText = String(format: NSLocalizedString("Translation failed: %@", comment: "Translation"), message)
		webView?.callAsyncJavaScript("nnwTranslation.fail(generation, ids, message);", arguments: ["generation": generation, "ids": [id], "message": failureText], in: nil, in: .defaultClient) { _ in }
	}
}
