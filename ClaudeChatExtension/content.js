(function () {
  const MAX_TEXT_LENGTH = 50000;

  function cloneDocument() {
    return document.cloneNode(true);
  }

  function removeNoise(root) {
    const selectors = [
      "script",
      "style",
      "noscript",
      "iframe",
      "svg",
      "nav",
      "footer",
      "header",
      "aside",
      "[role='navigation']",
      "[role='banner']",
      "[role='contentinfo']",
      "[aria-hidden='true']",
      ".ad",
      ".ads",
      ".advertisement",
      ".cookie-banner",
      ".newsletter",
    ];

    for (const selector of selectors) {
      root.querySelectorAll(selector).forEach((node) => node.remove());
    }
  }

  function pickMainElement(root) {
    return (
      root.querySelector("main") ||
      root.querySelector("article") ||
      root.querySelector("[role='main']") ||
      root.body
    );
  }

  function normalizeText(text) {
    return text
      .replace(/\u00a0/g, " ")
      .replace(/[ \t]+\n/g, "\n")
      .replace(/\n{3,}/g, "\n\n")
      .replace(/[ \t]{2,}/g, " ")
      .trim();
  }

  function extractPageContent() {
    const clone = cloneDocument();
    removeNoise(clone);
    const main = pickMainElement(clone);
    const text = normalizeText(main?.innerText || clone.body?.innerText || "");
    const limited = text.length > MAX_TEXT_LENGTH ? text.slice(0, MAX_TEXT_LENGTH) + "\n\n[… gekürzt]" : text;

    return {
      title: document.title || "",
      url: document.URL || location.href,
      text: limited,
    };
  }

  browser.runtime.onMessage.addListener((message, _sender, sendResponse) => {
    if (!message || message.action !== "extract") {
      return false;
    }

    try {
      const result = extractPageContent();
      if (!result.text) {
        sendResponse({ error: "Kein lesbarer Text auf dieser Seite." });
      } else {
        sendResponse(result);
      }
    } catch (error) {
      sendResponse({ error: error.message || "Extraktion fehlgeschlagen." });
    }

    return true;
  });
})();
