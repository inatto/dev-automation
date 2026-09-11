(() => {
  "use strict";

  if (globalThis.__GPT_PROJECT_MANAGER_CONTENT_LOADED__) return;
  globalThis.__GPT_PROJECT_MANAGER_CONTENT_LOADED__ = true;

  const STYLE_ID = "gpt-project-manager-sidebar-style";
  const STORAGE_KEY = "gpm.settings";

  const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

  function normalizeText(value) {
    return String(value || "")
      .normalize("NFD")
      .replace(/[\u0300-\u036f]/g, "")
      .toLowerCase()
      .replace(/[-_]+/g, " ")
      .replace(/\s+/g, " ")
      .trim();
  }

  function visible(element) {
    if (!(element instanceof Element)) return false;
    const style = getComputedStyle(element);
    const rect = element.getBoundingClientRect();
    return style.display !== "none" && style.visibility !== "hidden" && rect.width > 0 && rect.height > 0;
  }

  function elementText(element) {
    return normalizeText([
      element.textContent,
      element.getAttribute?.("aria-label"),
      element.getAttribute?.("title"),
    ].filter(Boolean).join(" "));
  }

  function projectUrlFromHref(href) {
    try {
      const url = new URL(href, location.origin);
      if (url.hostname !== "chatgpt.com" || !/\/g\//.test(url.pathname)) return "";
      url.search = "";
      url.hash = "";
      return url.href;
    } catch {
      return "";
    }
  }

  function findProjectAnchor(project) {
    const targetNames = new Set([
      normalizeText(project?.name),
      normalizeText(project?.path?.split("/").filter(Boolean).at(-1)),
    ].filter(Boolean));

    const candidates = [...document.querySelectorAll('a[href*="/g/"]')];
    const exact = candidates.find((anchor) => {
      const text = elementText(anchor);
      return [...targetNames].some((name) => text === name || text.startsWith(`${name} `));
    });
    if (exact) return exact;

    return candidates.find((anchor) => {
      const text = elementText(anchor);
      return [...targetNames].some((name) => name.length >= 4 && text.includes(name));
    }) || null;
  }

  function findClickable(labels, scope = document) {
    const normalizedLabels = labels.map(normalizeText);
    const elements = [...scope.querySelectorAll('button, a[href], [role="button"]')].filter(visible);

    return elements.find((element) => {
      const text = elementText(element);
      return normalizedLabels.some((label) => text === label);
    }) || elements.find((element) => {
      const text = elementText(element);
      return normalizedLabels.some((label) => label.length >= 5 && text.includes(label));
    }) || null;
  }

  async function waitFor(getter, timeoutMs = 6000, intervalMs = 100) {
    const deadline = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
      const value = getter();
      if (value) return value;
      await sleep(intervalMs);
    }
    return null;
  }

  function setNativeValue(input, value) {
    const prototype = Object.getPrototypeOf(input);
    const descriptor = Object.getOwnPropertyDescriptor(prototype, "value");
    descriptor?.set?.call(input, value);
    input.dispatchEvent(new Event("input", { bubbles: true }));
    input.dispatchEvent(new Event("change", { bubbles: true }));
  }

  async function locateProject(project) {
    const anchor = findProjectAnchor(project);
    return anchor ? projectUrlFromHref(anchor.href) : "";
  }

  async function createProject(project) {
    let createButton = findClickable(["Novo projeto", "New project"]);

    if (!createButton) {
      // Em algumas larguras, a área Projects precisa estar expandida primeiro.
      const projectsButton = findClickable(["Projetos", "Projects"]);
      projectsButton?.click();
      await sleep(250);
      createButton = findClickable(["Novo projeto", "New project"]);
    }

    if (!createButton) {
      return { ok: false, error: "Não encontrei o botão Novo projeto na interface do ChatGPT." };
    }

    createButton.click();

    const dialog = await waitFor(() => document.querySelector('[role="dialog"], dialog'), 5000);
    const root = dialog || document;
    const input = await waitFor(() => {
      const inputs = [...root.querySelectorAll('input[type="text"], input:not([type]), textarea')].filter(visible);
      return inputs.find((item) => {
        const hint = normalizeText(`${item.getAttribute("placeholder") || ""} ${item.getAttribute("aria-label") || ""}`);
        return hint.includes("nome") || hint.includes("name") || inputs.length === 1;
      }) || inputs[0] || null;
    }, 5000);

    if (!input) return { ok: false, error: "A janela de criação abriu, mas não encontrei o campo de nome." };

    input.focus();
    setNativeValue(input, project.name);
    await sleep(150);

    const submit = findClickable(["Criar", "Create", "Continuar", "Continue"], root);
    if (!submit) return { ok: false, error: "Não encontrei o botão para concluir a criação do Project." };

    submit.click();
    return { ok: true, started: true };
  }

  function composerExists() {
    const main = document.querySelector("main") || document;
    return Boolean([...main.querySelectorAll('textarea, [contenteditable="true"]')].find(visible));
  }

  async function startNewChat(project) {
    const main = document.querySelector("main") || document;

    // Na UI atual de Projects, "Chat" é o comando para iniciar um chat usando o contexto do Project.
    let button = findClickable(["Novo chat", "New chat", "Chat"], main);
    if (!button && main !== document) {
      button = findClickable(["Novo chat", "New chat"], document);
    }

    if (button) {
      button.click();
      await sleep(250);
      return { ok: true };
    }

    // Alguns layouts já deixam o composer de um novo chat disponível ao abrir o Project.
    if (composerExists()) return { ok: true };

    return {
      ok: false,
      error: `O Project ${project.name} abriu, mas não encontrei o comando Chat/Novo chat.`,
    };
  }

  function ensureStyle() {
    let style = document.getElementById(STYLE_ID);
    if (!style) {
      style = document.createElement("style");
      style.id = STYLE_ID;
      style.textContent = `
        body.gpm-hide-chatgpt-sidebar #stage-slideover-sidebar,
        body.gpm-hide-chatgpt-sidebar [data-testid="sidebar"],
        body.gpm-hide-chatgpt-sidebar nav[aria-label="Chat history"],
        body.gpm-hide-chatgpt-sidebar nav[aria-label="Histórico de chats"] {
          display: none !important;
        }
      `;
      document.documentElement.appendChild(style);
    }
  }

  function applySettings(settings = {}) {
    ensureStyle();
    document.body?.classList.toggle(
      "gpm-hide-chatgpt-sidebar",
      settings.hideChatGptSidebar === true,
    );
  }

  async function loadSettings() {
    const data = await chrome.storage.sync.get(STORAGE_KEY);
    applySettings(data[STORAGE_KEY] || {});
  }

  chrome.storage.onChanged.addListener((changes, area) => {
    if (area === "sync" && changes[STORAGE_KEY]) {
      applySettings(changes[STORAGE_KEY].newValue || {});
    }
  });

  chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
    if (!message?.type?.startsWith("gpm:")) return false;

    if (message.type === "gpm:ping") {
      sendResponse({ ok: true });
      return false;
    }

    (async () => {
      if (message.type === "gpm:locate-project") {
        return { ok: true, projectUrl: await locateProject(message.project) };
      }
      if (message.type === "gpm:create-project") {
        return createProject(message.project);
      }
      if (message.type === "gpm:start-new-chat") {
        return startNewChat(message.project);
      }
      return { ok: false, error: "Comando desconhecido." };
    })().then(sendResponse).catch((error) => sendResponse({ ok: false, error: error.message || String(error) }));

    return true;
  });

  loadSettings();
})();
