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

/// Drives translation.js in an article web view: collects paragraphs, translates them, and fills in the results.
@MainActor final class ArticleTranslator {

	private static let logger = Logger(subsystem: Logger.nnwSubsystem, category: "ArticleTranslator")

	private var task: Task<Void, Never>?

	func translate(_ webView: WKWebView) {
		cancel()

		let settings = TranslationSettings.shared
		let configuration = settings.configuration
		let options: [String: Any] = ["skipCJK": settings.skipsCJKText]

		task = Task { [weak webView] in
			guard let webView else {
				return
			}

			let items: [TranslationItem]
			do {
				let result = try await webView.callAsyncJavaScript("return nnwTranslation.collect(options);", arguments: ["options": options], contentWorld: .defaultClient)
				let rawItems = result as? [[String: Any]] ?? []
				items = rawItems.compactMap { rawItem in
					guard let id = rawItem["id"] as? String, let text = rawItem["text"] as? String else {
						return nil
					}
					return TranslationItem(id: id, text: text)
				}
			} catch {
				Self.logger.error("ArticleTranslator: couldn't collect paragraphs: \(error.localizedDescription)")
				return
			}

			guard !items.isEmpty else {
				return
			}

			for await result in TranslationService.shared.translate(items, configuration: configuration) {
				if Task.isCancelled {
					return
				}
				switch result {
				case .translated(let translations):
					let results = translations.map { ["id": $0.id, "text": $0.text] }
					_ = try? await webView.callAsyncJavaScript("nnwTranslation.apply(results);", arguments: ["results": results], contentWorld: .defaultClient)
				case .failed(let ids, let message):
					let failureText = String(format: NSLocalizedString("Translation failed: %@", comment: "Translation"), message)
					_ = try? await webView.callAsyncJavaScript("nnwTranslation.fail(ids, message);", arguments: ["ids": ids, "message": failureText], contentWorld: .defaultClient)
				}
			}
		}
	}

	func clear(_ webView: WKWebView) {
		cancel()
		webView.evaluateJavaScript("nnwTranslation.clear();", in: nil, in: .defaultClient) { _ in }
	}

	func cancel() {
		task?.cancel()
		task = nil
	}
}
