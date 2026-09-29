//
//  ReadabilityExtractor.swift
//  NetNewsWire
//
//  Created by NetNewsWire contributors on 9/29/26.
//

import Foundation
import WebKit
import os
import RSCore
import RSWeb

enum ReadabilityExtractorError: LocalizedError {
	case badResponse(Int)
	case notHTML
	case noArticleFound

	var errorDescription: String? {
		switch self {
		case .badResponse(let status):
			return String(format: NSLocalizedString("The page couldn't be downloaded (HTTP %ld).", comment: "Reader View error"), status)
		case .notHTML:
			return NSLocalizedString("The link isn't a web page.", comment: "Reader View error")
		case .noArticleFound:
			return NSLocalizedString("No article text was found on the page.", comment: "Reader View error")
		}
	}
}

/// Downloads a web page and pulls out the article with Mozilla's Readability.js, the library behind
/// Firefox's Reader View. Runs entirely on the Mac — no extraction service or API key needed.
///
/// The page is parsed with DOMParser inside a hidden web view, so none of its scripts run
/// and none of its images or stylesheets load.
@MainActor final class ReadabilityExtractor: NSObject {

	static let shared = ReadabilityExtractor()

	private static let logger = Logger(subsystem: Logger.nnwSubsystem, category: "ReadabilityExtractor")
	private static let maxPageSize = 10_000_000

	private var webView: WKWebView?
	private var webViewLoadWaiters = [CheckedContinuation<Void, Never>]()
	private var isWebViewLoaded = false

	private let session: URLSession = {
		let configuration = URLSessionConfiguration.ephemeral
		configuration.timeoutIntervalForRequest = 30
		return URLSession(configuration: configuration)
	}()

	func extract(from url: URL) async throws -> ExtractedArticle {
		let (html, finalURL) = try await download(url)
		try Task.checkCancellation()

		let webView = try await loadedWebView()
		let result = try await webView.callAsyncJavaScript("return nnwExtractArticle(html, url);", arguments: ["html": html, "url": finalURL.absoluteString], in: nil, contentWorld: .defaultClient)

		guard let article = result as? [String: Any], let content = article["content"] as? String, !content.isEmpty else {
			throw ReadabilityExtractorError.noArticleFound
		}

		return ExtractedArticle(
			title: article["title"] as? String,
			author: article["byline"] as? String,
			datePublished: article["publishedTime"] as? String,
			dek: nil,
			leadImageURL: nil,
			content: content,
			nextPageURL: nil,
			url: finalURL.absoluteString,
			domain: finalURL.host(),
			excerpt: article["excerpt"] as? String,
			wordCount: article["length"] as? Int,
			direction: article["dir"] as? String,
			totalPages: nil,
			renderedPages: nil
		)
	}
}

// MARK: - WKNavigationDelegate

extension ReadabilityExtractor: WKNavigationDelegate {

	func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
		isWebViewLoaded = true
		let waiters = webViewLoadWaiters
		webViewLoadWaiters.removeAll()
		for waiter in waiters {
			waiter.resume()
		}
	}

	func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
		webViewDidFailToLoad(error)
	}

	func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
		webViewDidFailToLoad(error)
	}

	func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
		self.webView = nil
		isWebViewLoaded = false
	}
}

// MARK: - Private

private extension ReadabilityExtractor {

	func webViewDidFailToLoad(_ error: Error) {
		Self.logger.error("ReadabilityExtractor: blank page failed to load: \(error.localizedDescription)")
		webView = nil
		isWebViewLoaded = false
		let waiters = webViewLoadWaiters
		webViewLoadWaiters.removeAll()
		for waiter in waiters {
			waiter.resume()
		}
	}

	func download(_ url: URL) async throws -> (String, URL) {
		var request = URLRequest(url: url)
		request.setValue(UserAgent.browserUserAgent, forHTTPHeaderField: "User-Agent")
		request.setValue("text/html,application/xhtml+xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")

		let (data, response) = try await session.data(for: request)

		guard let httpResponse = response as? HTTPURLResponse else {
			throw ReadabilityExtractorError.notHTML
		}
		guard (200..<300).contains(httpResponse.statusCode) else {
			throw ReadabilityExtractorError.badResponse(httpResponse.statusCode)
		}
		if let mimeType = httpResponse.mimeType, !mimeType.contains("html") {
			throw ReadabilityExtractorError.notHTML
		}
		guard data.count <= Self.maxPageSize else {
			throw ReadabilityExtractorError.notHTML
		}

		return (Self.decode(data, textEncodingName: httpResponse.textEncodingName), httpResponse.url ?? url)
	}

	/// Uses the charset from the HTTP header, then from a <meta> tag, then UTF-8, then Latin-1.
	static func decode(_ data: Data, textEncodingName: String?) -> String {
		if let encoding = encoding(named: textEncodingName), let string = String(data: data, encoding: encoding) {
			return string
		}

		let head = String(decoding: data.prefix(4096), as: UTF8.self)
		if let range = head.range(of: #"charset\s*=\s*["']?([A-Za-z0-9_\-]+)"#, options: [.regularExpression, .caseInsensitive]) {
			let name = head[range].replacingOccurrences(of: #"charset\s*=\s*["']?"#, with: "", options: [.regularExpression, .caseInsensitive])
			if let encoding = encoding(named: name), let string = String(data: data, encoding: encoding) {
				return string
			}
		}

		return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
	}

	static func encoding(named name: String?) -> String.Encoding? {
		guard let name, !name.isEmpty else {
			return nil
		}
		let cfEncoding = CFStringConvertIANACharSetNameToEncoding(name as CFString)
		guard cfEncoding != kCFStringEncodingInvalidId else {
			return nil
		}
		return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEncoding))
	}

	func loadedWebView() async throws -> WKWebView {
		if let webView, isWebViewLoaded {
			return webView
		}

		if webView == nil {
			let configuration = WKWebViewConfiguration()
			configuration.websiteDataStore = .nonPersistent()
			configuration.defaultWebpagePreferences.allowsContentJavaScript = false
			configuration.userContentController.addUserScript(Self.extractionScript)

			let webView = WKWebView(frame: .zero, configuration: configuration)
			webView.navigationDelegate = self
			self.webView = webView
			isWebViewLoaded = false
			webView.loadHTMLString("<!doctype html><html><head></head><body></body></html>", baseURL: nil)
		}

		await withCheckedContinuation { continuation in
			webViewLoadWaiters.append(continuation)
		}

		guard let webView else {
			throw ReadabilityExtractorError.noArticleFound
		}
		return webView
	}

	static let extractionScript: WKUserScript = {
		guard let url = Bundle.main.url(forResource: "Readability", withExtension: "js"),
			  let readability = try? String(contentsOf: url, encoding: .utf8) else {
			logger.error("ReadabilityExtractor: Readability.js is missing from the app bundle")
			return WKUserScript(source: "", injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient)
		}

		let extract = """
		function nnwExtractArticle(html, url) {
			const doc = new DOMParser().parseFromString(html, "text/html");

			// DOMParser documents have no URL, so give it one for resolving relative links and images.
			const existingBase = doc.querySelector("base[href]");
			if (existingBase) {
				existingBase.setAttribute("href", new URL(existingBase.getAttribute("href"), url).href);
			} else {
				const base = doc.createElement("base");
				base.setAttribute("href", url);
				doc.head.prepend(base);
			}

			const article = new Readability(doc).parse();
			if (!article || !article.content) {
				return null;
			}
			return {
				title: article.title,
				byline: article.byline,
				content: article.content,
				excerpt: article.excerpt,
				length: article.length,
				dir: article.dir,
				publishedTime: article.publishedTime
			};
		}
		"""
		return WKUserScript(source: readability + "\n" + extract, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient)
	}()
}
