const NATIVE_HOST = "dev.claudechat";
const KEEPALIVE_INTERVAL_MS = 25_000;

let nativePort = null;
let reconnectTimer = null;
let keepaliveTimer = null;

function extensionDebugInfo() {
  const id = browser.runtime.id;
  return {
    runtimeId: id,
    origin: `moz-extension://${id}/`,
    nativeHost: NATIVE_HOST,
  };
}

function logStartupInfo() {
  const info = extensionDebugInfo();
  console.log(
    "Claude Chat: Extension gestartet.",
    "runtime.id:",
    info.runtimeId,
    "origin:",
    info.origin,
    "nativeHost:",
    info.nativeHost
  );
}

function clearNativePort() {
  nativePort = null;
  stopKeepalive();
}

function connectNative(force = false) {
  if (nativePort && !force) {
    return;
  }

  if (force) {
    clearNativePort();
  }

  try {
    nativePort = browser.runtime.connectNative(NATIVE_HOST);
  } catch (error) {
    console.error("Claude Chat: connectNative Exception:", error);
    clearNativePort();
    scheduleReconnect();
    return;
  }

  const connectError = browser.runtime.lastError;
  if (connectError) {
    console.error(
      "Claude Chat: connectNative fehlgeschlagen:",
      connectError.message,
      extensionDebugInfo()
    );
    clearNativePort();
    scheduleReconnect();
    return;
  }

  console.log("Claude Chat: Native Host verbunden.", extensionDebugInfo());

  nativePort.onMessage.addListener(async (message) => {
    if (!message || message.action !== "extract") {
      return;
    }

    try {
      const result = await extractFromActiveTab();
      nativePort.postMessage(result);
    } catch (error) {
      nativePort.postMessage({
        error: error.message || "Extraktion fehlgeschlagen",
      });
    }
  });

  nativePort.onDisconnect.addListener(() => {
    const lastError = browser.runtime.lastError;
    if (lastError) {
      console.warn(
        "Claude Chat: Native Host getrennt:",
        lastError.message,
        extensionDebugInfo()
      );
    } else {
      console.warn("Claude Chat: Native Host getrennt (ohne lastError).", extensionDebugInfo());
    }
    clearNativePort();
    scheduleReconnect();
  });

  startKeepalive();
}

function startKeepalive() {
  stopKeepalive();
  keepaliveTimer = setInterval(() => {
    if (!nativePort) {
      return;
    }
    try {
      nativePort.postMessage({ action: "ping" });
    } catch (error) {
      console.warn("Claude Chat: Keepalive fehlgeschlagen", error);
    }
  }, KEEPALIVE_INTERVAL_MS);
}

function stopKeepalive() {
  if (keepaliveTimer) {
    clearInterval(keepaliveTimer);
    keepaliveTimer = null;
  }
}

function scheduleReconnect() {
  if (reconnectTimer) {
    return;
  }
  reconnectTimer = setTimeout(() => {
    reconnectTimer = null;
    connectNative(true);
  }, 2000);
}

async function extractFromActiveTab() {
  const tabs = await browser.tabs.query({ active: true, currentWindow: true });
  const tab = tabs[0];

  if (!tab || !tab.id) {
    throw new Error("Kein aktiver Tab gefunden.");
  }

  if (tab.url && (tab.url.startsWith("about:") || tab.url.startsWith("moz-extension:"))) {
    throw new Error("Auf dieser Seite kann kein Inhalt extrahiert werden.");
  }

  const response = await browser.tabs.sendMessage(tab.id, { action: "extract" });

  if (!response || response.error) {
    throw new Error(response?.error || "Content-Script hat nicht geantwortet.");
  }

  return {
    title: response.title || tab.title || "",
    url: response.url || tab.url || "",
    text: response.text || "",
  };
}

logStartupInfo();
connectNative();
browser.runtime.onInstalled.addListener(() => connectNative(true));
browser.runtime.onStartup.addListener(() => connectNative(true));
