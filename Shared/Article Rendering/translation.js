// Immersive translation: a translation appears under each paragraph of the article.
// Paragraphs are sent for translation as they scroll into view, so the visible part
// of the article is translated first and the rest only when it's read.
// Runs in its own content world, so it works when article JavaScript is disabled
// and article scripts can't call into it.

var nnwTranslation = (function() {

	const looseTextClass = "nnw-loose-text";
	const blockSelector = `p, li, h1, h2, h3, h4, h5, h6, blockquote, dt, dd, figcaption, th, td, span.${looseTextClass}`;
	const wrappedAttribute = "data-nnw-wrapped";
	// Elements that start a new line; text between them is its own paragraph.
	const blockTags = new Set(["ADDRESS", "ARTICLE", "ASIDE", "BLOCKQUOTE", "DD", "DETAILS", "DIV", "DL", "DT", "FIELDSET", "FIGCAPTION", "FIGURE", "FOOTER", "FORM", "H1", "H2", "H3", "H4", "H5", "H6", "HEADER", "HR", "IFRAME", "LI", "MAIN", "NAV", "OL", "P", "PRE", "SECTION", "TABLE", "UL", "VIDEO", "AUDIO"]);
	const skipAncestorSelector = "pre, code, script, style, svg, math, .nnw-translation";
	const translationClass = "nnw-translation";
	const pendingClass = "nnw-translation-pending";
	const errorClass = "nnw-translation-error";
	const idAttribute = "data-nnw-tid";
	const styleID = "nnw-translation-style";
	const minimumTextLength = 2;
	const maximumTextLength = 5000;

	// Start translating a little before a paragraph scrolls into view.
	const lookaheadMargin = "0px 0px 50% 0px";
	// Paragraphs that become visible together are sent together.
	const flushDelay = 80;

	const css = `
		.${translationClass} {
			display: block;
			margin-top: 0.3em;
			color: color-mix(in srgb, currentColor 62%, transparent);
			font-weight: normal;
			font-style: normal;
			-webkit-user-select: text;
		}
		h1 > .${translationClass}, h2 > .${translationClass}, h3 > .${translationClass},
		h4 > .${translationClass}, h5 > .${translationClass}, h6 > .${translationClass} {
			margin-top: 0.2em;
			font-size: 0.72em;
			font-weight: 500;
		}
		/* The translation already ends the line, so the first of the <br>s after it would add an extra blank line. */
		span.${looseTextClass}:has(> .${translationClass}) + br {
			display: none;
		}
		.${pendingClass} {
			width: min(60%, 18em);
			height: 0.7em;
			margin-top: 0.55em;
			border-radius: 0.35em;
			background: color-mix(in srgb, currentColor 12%, transparent);
			animation: nnw-translation-pulse 1.2s ease-in-out infinite;
		}
		@keyframes nnw-translation-pulse {
			50% { opacity: 0.4; }
		}
		.${errorClass} {
			font-size: 0.8em;
			color: color-mix(in srgb, #e5484d 85%, currentColor);
		}
	`;

	let generation = 0;
	let observer = null;
	let queue = [];
	let flushTimer = null;
	const texts = new Map();

	function roots() {
		return document.querySelectorAll(".articleTitle, #bodyContainer");
	}

	function isCJK(text) {
		const cjk = text.match(/[぀-ヿ㐀-鿿가-힯]/g);
		return cjk !== null && cjk.length / text.replace(/\s/g, "").length > 0.3;
	}

	// Only translate the innermost blocks: an <li> that holds <p>s is handled through its <p>s.
	function isLeafBlock(element) {
		return element.querySelector(blockSelector) === null;
	}

	// A short line that's all link text, such as an attribution ("Jeff Johnson:"), doesn't need translating.
	function isShortLinkLine(element, text) {
		if (text.length > 60 || /^H[1-6]$/.test(element.tagName)) {
			return false;
		}
		let linkText = "";
		element.querySelectorAll("a").forEach(anchor => linkText += textOf(anchor));
		const remainder = text.replace(/[\s\p{P}]/gu, "").length - linkText.replace(/[\s\p{P}]/gu, "").length;
		return linkText.length > 0 && remainder <= 0;
	}

	function isBlank(node) {
		return node.nodeType === Node.TEXT_NODE && node.textContent.trim() === "";
	}

	function isBreak(node) {
		return node.nodeName === "BR";
	}

	// Splits an element's children into runs of inline content. A run ends at a block
	// element or at a blank line (two <br>s in a row) — how many feeds separate paragraphs.
	function inlineRuns(element) {
		const runs = [];
		let run = [];
		const children = Array.from(element.childNodes);

		function endRun() {
			if (run.length > 0) {
				runs.push(run);
			}
			run = [];
		}

		for (let i = 0; i < children.length; i++) {
			const node = children[i];
			if (node.nodeType === Node.ELEMENT_NODE && blockTags.has(node.nodeName)) {
				endRun();
				continue;
			}
			if (isBreak(node)) {
				let next = i + 1;
				while (next < children.length && isBlank(children[next])) {
					next++;
				}
				if (next < children.length && isBreak(children[next])) {
					endRun();
					i = next;
					continue;
				}
			}
			run.push(node);
		}
		endRun();

		// Line breaks and whitespace at a run's edges belong outside the wrapper.
		return runs.map(nodes => {
			let start = 0;
			let end = nodes.length;
			while (start < end && (isBlank(nodes[start]) || isBreak(nodes[start]))) {
				start++;
			}
			while (end > start && (isBlank(nodes[end - 1]) || isBreak(nodes[end - 1]))) {
				end--;
			}
			return nodes.slice(start, end);
		}).filter(nodes => nodes.length > 0);
	}

	// Some feeds, such as antirez.com, don't use <p>: paragraphs are bare text separated by <br><br>.
	// Wrap each such paragraph in a span so it can be translated like any other.
	function wrapLooseText(root) {
		const containers = [root, ...root.querySelectorAll("div, blockquote, li, dd, td, th, p, section, article, figure")];
		for (const container of containers) {
			if (container.hasAttribute(wrappedAttribute) || container.closest(skipAncestorSelector)) {
				continue;
			}
			container.setAttribute(wrappedAttribute, "");

			const runs = inlineRuns(container);
			const hasBlockChild = Array.from(container.children).some(child => blockTags.has(child.nodeName));
			// A <p> or <li> that's just one run of text is already a paragraph.
			if (container.matches(blockSelector) && runs.length === 1 && !hasBlockChild) {
				continue;
			}

			for (const nodes of runs) {
				const text = nodes.map(node => node.textContent).join("");
				if (!/\p{L}/u.test(text)) {
					continue;
				}
				const wrapper = document.createElement("span");
				wrapper.className = looseTextClass;
				container.insertBefore(wrapper, nodes[0]);
				for (const node of nodes) {
					wrapper.appendChild(node);
				}
			}
		}
	}

	function textOf(element) {
		return (element.innerText || element.textContent || "").trim();
	}

	function installStyle() {
		if (document.getElementById(styleID)) {
			return;
		}
		const style = document.createElement("style");
		style.id = styleID;
		style.textContent = css;
		document.head.appendChild(style);
	}

	function translationElement(id) {
		const element = document.querySelector(`[${idAttribute}="${id}"]`);
		if (!element) {
			return null;
		}
		return element.querySelector(`:scope > .${translationClass}`);
	}

	function flush() {
		flushTimer = null;
		if (queue.length === 0) {
			return;
		}
		const items = queue;
		queue = [];
		window.webkit.messageHandlers.nnwTranslate.postMessage({ generation: generation, items: items });
	}

	function paragraphDidBecomeVisible(element) {
		const id = element.getAttribute(idAttribute);
		const translation = document.createElement("span");
		translation.className = `${translationClass} ${pendingClass}`;
		element.appendChild(translation);

		queue.push({ id: id, text: texts.get(id) });
		if (flushTimer === null) {
			flushTimer = setTimeout(flush, flushDelay);
		}
	}

	// Marks the paragraphs to translate and starts watching them.
	function start(options) {
		clear();
		installStyle();
		generation = options.generation;
		const skipCJK = options.skipCJK;
		let nextID = 0;

		observer = new IntersectionObserver(entries => {
			for (const entry of entries) {
				if (entry.isIntersecting) {
					observer.unobserve(entry.target);
					paragraphDidBecomeVisible(entry.target);
				}
			}
		}, { rootMargin: lookaheadMargin });

		for (const root of roots()) {
			wrapLooseText(root);
			for (const element of root.querySelectorAll(blockSelector)) {
				if (!isLeafBlock(element) || element.closest(skipAncestorSelector)) {
					continue;
				}
				const text = textOf(element);
				if (text.length < minimumTextLength || text.length > maximumTextLength) {
					continue;
				}
				if (!/\p{L}/u.test(text) || (skipCJK && isCJK(text)) || isShortLinkLine(element, text)) {
					continue;
				}

				const id = String(nextID++);
				element.setAttribute(idAttribute, id);
				texts.set(id, text);
				observer.observe(element);
			}
		}
	}

	// results: [{id, text}]
	function apply(resultGeneration, results) {
		if (resultGeneration !== generation) {
			return;
		}
		for (const result of results) {
			const translation = translationElement(result.id);
			if (!translation) {
				continue;
			}
			translation.classList.remove(pendingClass, errorClass);
			translation.textContent = result.text;
		}
	}

	function fail(resultGeneration, ids, message) {
		if (resultGeneration !== generation) {
			return;
		}
		for (const id of ids) {
			const translation = translationElement(id);
			if (!translation) {
				continue;
			}
			translation.classList.remove(pendingClass);
			translation.classList.add(errorClass);
			translation.textContent = message;
		}
	}

	function clear() {
		generation = 0;
		if (observer !== null) {
			observer.disconnect();
			observer = null;
		}
		if (flushTimer !== null) {
			clearTimeout(flushTimer);
			flushTimer = null;
		}
		queue = [];
		texts.clear();
		document.querySelectorAll(`.${translationClass}`).forEach(element => element.remove());
		document.querySelectorAll(`[${idAttribute}]`).forEach(element => element.removeAttribute(idAttribute));
	}

	return { start: start, apply: apply, fail: fail, clear: clear };
})();
