//
//  ArticleSummaryDetector.swift
//  NetNewsWire
//
//  Created by NetNewsWire contributors on 9/29/26.
//

import Foundation
import Articles

extension Notification.Name {
	static let fullTextSettingsDidChange = Notification.Name("FullTextSettingsDidChange")
}

@MainActor enum FullTextSettings {

	private static let automaticallyLoadsFullTextKey = "automaticallyLoadsFullTextForSummaries"

	/// When on, articles whose feed looks like it carries only a summary open in Reader View.
	static var automaticallyLoadsFullText: Bool {
		get {
			UserDefaults.standard.object(forKey: automaticallyLoadsFullTextKey) as? Bool ?? true
		}
		set {
			UserDefaults.standard.set(newValue, forKey: automaticallyLoadsFullTextKey)
			NotificationCenter.default.post(name: .fullTextSettingsDidChange, object: nil)
		}
	}
}

/// Guesses whether a feed gave only a summary of an article, not the whole thing.
/// Errs toward "no": opening a full article in Reader View is slower and can lose formatting.
@MainActor enum ArticleSummaryDetector {

	private static let shortTextLength = 300
	private static let shortCJKTextLength = 120

	private static let truncationEndings = ["…", "...", "[…]", "[...]", "(more…)", "(more...)"]
	private static let readMorePhrases = ["read more", "continue reading", "read the full", "read the rest", "keep reading", "full story", "full article", "阅读全文", "继续阅读", "查看全文", "阅读更多", "閱讀全文", "繼續閱讀", "続きを読む"]

	static func isLikelySummary(_ article: Article, homePageURL: String?) -> Bool {
		guard let link = article.link, let linkURL = URL(string: link) else {
			return false
		}

		// A link-blog post points at someone else's article; its own text is the point, however short.
		if let externalLink = article.externalLink, !externalLink.isEmpty, externalLink != link {
			return false
		}
		if let homePageURL, let homeHost = URL(string: homePageURL)?.host(), let linkHost = linkURL.host(), !isSameSite(homeHost, linkHost) {
			return false
		}

		let html = article.contentHTML ?? article.contentText ?? ""
		if html.isEmpty {
			return true
		}

		let lowercasedHTML = html.lowercased()
		// Videos, podcasts, and photo posts are short on text by nature.
		if ["<iframe", "<video", "<audio"].contains(where: lowercasedHTML.contains) {
			return false
		}

		let text = plainText(html)
		if text.isEmpty {
			return true
		}

		if truncationEndings.contains(where: text.hasSuffix) {
			return true
		}
		let ending = String(text.suffix(40)).lowercased()
		if readMorePhrases.contains(where: ending.contains) {
			return true
		}

		let paragraphCount = lowercasedHTML.matches(of: /<p[\s>]/).count
		let length = text.filter { !$0.isWhitespace }.count
		let threshold = isMostlyCJK(text) ? shortCJKTextLength : shortTextLength
		return length < threshold && paragraphCount <= 1
	}
}

private extension ArticleSummaryDetector {

	static func plainText(_ html: String) -> String {
		var text = html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
		for (entity, character) in ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&hellip;": "…", "&#8230;": "…"] {
			text = text.replacingOccurrences(of: entity, with: character)
		}
		return text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
	}

	static func isMostlyCJK(_ text: String) -> Bool {
		let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }
		guard !letters.isEmpty else {
			return false
		}
		let cjk = letters.filter { (0x3040...0x30FF).contains($0.value) || (0x3400...0x9FFF).contains($0.value) || (0xAC00...0xD7AF).contains($0.value) }
		return Double(cjk.count) / Double(letters.count) > 0.3
	}

	static func isSameSite(_ host1: String, _ host2: String) -> Bool {
		let a = host1.lowercased().replacingOccurrences(of: "www.", with: "")
		let b = host2.lowercased().replacingOccurrences(of: "www.", with: "")
		return a == b || a.hasSuffix("." + b) || b.hasSuffix("." + a)
	}
}
