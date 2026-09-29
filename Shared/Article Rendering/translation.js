// Immersive translation: a translation appears under each paragraph of the article.
// Paragraphs are sent for translation as they scroll into view, so the visible part
// of the article is translated first and the rest only when it's read.
// Runs in its own content world, so it works when article JavaScript is disabled
// and article scripts can't call into it.

var nnwTranslation = (function() {

	const blockSelector = "p, li, h1, h2, h3, h4, h5, h6, blockquote, dt, dd, figcaption, th, td";
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
