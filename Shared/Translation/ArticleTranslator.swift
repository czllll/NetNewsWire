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

/// Drives translation.js in an article web view. The page reports paragraphs as they come
/// into view, and ones that scroll away before their translation is done; those are dropped,
/// so whatever is on screen is translated first. Each paragraph gets its own streaming request,
/// a few at a time, and translations appear top to bottom: the topmost unfinished paragraph
/// fills in as the model writes, and paragraphs below it wait their turn.
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
	/// Sequence numbers of requests not yet shown, in the order they're to be shown.
	private var displayOrder = [Int]()
	private var nextSequence = 0

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
		displayOrder.removeAll()
		nextSequence = 0
		webView = nil
		configuration = nil
	}

	/// Handles paragraphs that came into view or left it, as posted by translation.js.
	func handleMessage(_ body: Any, webView: WKWebView) {
		guard webView === self.webView,
			  let message = body as? [String: Any],
			  let messageGeneration = message["generation"] as? Int,
			  messageGeneration == generation else {
			return
		}

		if let hiddenIDs = message["hidden"] as? [String], !hiddenIDs.isEmpty {
			dropParagraphs(Set(hiddenIDs))
		}

		let rawItems = message["items"] as? [[String: Any]] ?? []
		let items = rawItems.compactMap { rawItem -> TranslationItem? in
			guard let id = rawItem["id"] as? String, let text = rawItem["text"] as? String else {
				return nil
			}
			return TranslationItem(id: id, text: text)
		}
		pendingItems.append(contentsOf: items)
		// Paragraph ids count up in document order.
		pendingItems.sort { (Int($0.id) ?? 0) < (Int($1.id) ?? 0) }

		showFinishedRequestsInOrder()
		startRequestsIfPossible()
	}
}

private extension ArticleTranslator {

	/// Forgets paragraphs that scrolled out of view: unsent ones are unqueued, and in-flight
	/// requests are cancelled to free their slots. Finished translations are kept.
	func dropParagraphs(_ ids: Set<String>) {
		pendingItems.removeAll { ids.contains($0.id) }

		for (sequence, request) in requests where ids.contains(request.id) && request.finalEvent == nil {
			tasks[sequence]?.cancel()
			tasks[sequence] = nil
			requests[sequence] = nil
			displayOrder.removeAll { $0 == sequence }
		}
	}

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
			insertInDisplayOrder(sequence, id: item.id)

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

	/// Keeps display order the same as document order, even when a paragraph above
	/// was requested later (after scrolling back up).
	func insertInDisplayOrder(_ sequence: Int, id: String) {
		let paragraphIndex = Int(id) ?? 0
		let insertionIndex = displayOrder.firstIndex { existing in
			guard let existingID = requests[existing]?.id else {
				return false
			}
			return (Int(existingID) ?? 0) > paragraphIndex
		} ?? displayOrder.endIndex
		displayOrder.insert(sequence, at: insertionIndex)
	}

	func request(_ sequence: Int, generation requestGeneration: Int, didProduce event: TranslationEvent) {
		guard requestGeneration == generation, requests[sequence] != nil else {
			return
		}

		if case .partial(let text) = event {
			requests[sequence]?.partialText = text
			if sequence == displayOrder.first, let id = requests[sequence]?.id {
				showTranslation(text, id: id, isFinal: false)
			}
			return
		}

		tasks[sequence] = nil
		requests[sequence]?.finalEvent = event
		showFinishedRequestsInOrder()
		startRequestsIfPossible()
	}

	func showFinishedRequestsInOrder() {
		while let sequence = displayOrder.first, let request = requests[sequence], let finalEvent = request.finalEvent {
			displayOrder.removeFirst()
			requests[sequence] = nil

			switch finalEvent {
			case .translated(let text), .partial(let text):
				showTranslation(text, id: request.id, isFinal: true)
			case .failed(let message):
				showFailure(message, id: request.id)
			}
		}

		// The new topmost paragraph may already be partway through its reply.
		if let sequence = displayOrder.first, let request = requests[sequence], let partialText = request.partialText {
			showTranslation(partialText, id: request.id, isFinal: false)
		}
	}

	func showTranslation(_ text: String, id: String, isFinal: Bool) {
		let results = [["id": id, "text": text]]
		webView?.callAsyncJavaScript("nnwTranslation.apply(generation, results, isFinal);", arguments: ["generation": generation, "results": results, "isFinal": isFinal], in: nil, in: .defaultClient) { _ in }
	}

	func showFailure(_ message: String, id: String) {
		let failureText = String(format: NSLocalizedString("Translation failed: %@", comment: "Translation"), message)
		webView?.callAsyncJavaScript("nnwTranslation.fail(generation, ids, message);", arguments: ["generation": generation, "ids": [id], "message": failureText], in: nil, in: .defaultClient) { _ in }
	}
}
