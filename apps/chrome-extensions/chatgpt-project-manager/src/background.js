"use strict";

const MANAGER_URL = chrome.runtime.getURL("src/manager.html");
const LAYOUT_KEY = "gpm.layout";

chrome.action.onClicked.addListener(async () => {
  const tabs = await chrome.tabs.query({});
  const existing = tabs.find((tab) => tab.url === MANAGER_URL);

  if (existing?.id) {
    await chrome.tabs.update(existing.id, { active: true });
    if (existing.windowId) await chrome.windows.update(existing.windowId, { focused: true });
    return;
  }

  await chrome.tabs.create({ url: MANAGER_URL });
});

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function getLayout() {
  const data = await chrome.storage.sync.get(LAYOUT_KEY);
  return data[LAYOUT_KEY] || {};
}

async function rememberProject(project, projectUrl) {
  if (!project?.id || !projectUrl) return;
  const layout = await getLayout();
  layout.gptProjects ||= {};
  layout.gptProjects[project.id] = {
    url: projectUrl,
    name: project.name || "",
    updatedAt: new Date().toISOString(),
  };
  await chrome.storage.sync.set({ [LAYOUT_KEY]: layout });
}

async function focusTab(tab) {
  if (!tab?.id) return;
  await chrome.tabs.update(tab.id, { active: true });
  if (tab.windowId) await chrome.windows.update(tab.windowId, { focused: true });
}

async function getOrCreateChatGptTab() {
  const tabs = await chrome.tabs.query({ url: "https://chatgpt.com/*" });
  if (tabs.length) {
    const active = tabs.find((tab) => tab.active) || tabs.sort((a, b) => (b.lastAccessed || 0) - (a.lastAccessed || 0))[0];
    await focusTab(active);
    return active;
  }

  const tab = await chrome.tabs.create({ url: "https://chatgpt.com/", active: true });
  await waitForTabComplete(tab.id, 20000);
  return await chrome.tabs.get(tab.id);
}

function waitForTabComplete(tabId, timeoutMs = 15000) {
  return new Promise((resolve) => {
    let done = false;
    const finish = () => {
      if (done) return;
      done = true;
      clearTimeout(timer);
      chrome.tabs.onUpdated.removeListener(listener);
      resolve();
    };
    const listener = (id, info) => {
      if (id === tabId && info.status === "complete") finish();
    };
    const timer = setTimeout(finish, timeoutMs);
    chrome.tabs.onUpdated.addListener(listener);
    chrome.tabs.get(tabId).then((tab) => {
      if (tab.status === "complete") finish();
    }).catch(() => finish());
  });
}

function isMissingReceiverError(error) {
  const text = String(error?.message || error || "");
  return text.includes("Receiving end does not exist")
    || text.includes("Could not establish connection");
}

async function ensureChatGptContentScript(tabId) {
  const tab = await chrome.tabs.get(tabId);
  if (!tab?.url?.startsWith("https://chatgpt.com/")) {
    throw new Error("A aba selecionada não é do ChatGPT.");
  }

  try {
    await chrome.tabs.sendMessage(tabId, { type: "gpm:ping" });
    return;
  } catch (error) {
    if (!isMissingReceiverError(error)) throw error;
  }

  // Uma extensão recarregada não injeta content scripts retroativamente em abas já abertas.
  // Injeta explicitamente e deixa o próprio content.js impedir registro duplicado.
  await chrome.scripting.executeScript({
    target: { tabId },
    files: ["src/content.js"],
  });

  for (let attempt = 0; attempt < 20; attempt += 1) {
    try {
      await chrome.tabs.sendMessage(tabId, { type: "gpm:ping" });
      return;
    } catch {
      await sleep(100);
    }
  }

  throw new Error("Não consegui ativar a integração na aba do ChatGPT.");
}

async function sendToChatGpt(tabId, message, attempts = 15) {
  let lastError = null;
  for (let i = 0; i < attempts; i += 1) {
    try {
      await ensureChatGptContentScript(tabId);
      return await chrome.tabs.sendMessage(tabId, message);
    } catch (error) {
      lastError = error;
      await sleep(300);
    }
  }
  throw lastError || new Error("A página do ChatGPT não respondeu à extensão.");
}

function isProjectUrl(url) {
  try {
    const parsed = new URL(url);
    return parsed.hostname === "chatgpt.com" && /\/g\//.test(parsed.pathname);
  } catch {
    return false;
  }
}

async function locateExistingProject(tabId, project) {
  const result = await sendToChatGpt(tabId, { type: "gpm:locate-project", project });
  return result?.projectUrl || "";
}

async function resolveOrCreateProject(tab, project, knownProjectUrl = "") {
  const layout = await getLayout();
  const saved = layout.gptProjects?.[project.id]?.url || "";
  let projectUrl = [knownProjectUrl, saved].find(isProjectUrl) || "";

  if (!projectUrl) {
    projectUrl = await locateExistingProject(tab.id, project);
  }

  if (!projectUrl) {
    try {
      await sendToChatGpt(tab.id, { type: "gpm:create-project", project }, 8);
    } catch {
      // A criação pode navegar a SPA e interromper a resposta; a localização abaixo confirma o resultado.
    }

    for (let attempt = 0; attempt < 20 && !projectUrl; attempt += 1) {
      await sleep(400);
      const current = await chrome.tabs.get(tab.id).catch(() => null);
      if (isProjectUrl(current?.url || "")) projectUrl = current.url;
      if (!projectUrl) {
        try {
          projectUrl = await locateExistingProject(tab.id, project);
        } catch {
          // página ainda navegando
        }
      }
    }
  }

  if (!projectUrl) {
    throw new Error(`Não encontrei nem consegui criar o Project "${project.name}" no ChatGPT.`);
  }

  await rememberProject(project, projectUrl);
  return projectUrl;
}

async function navigateToProject(tab, projectUrl) {
  const current = await chrome.tabs.get(tab.id);
  if (current.url !== projectUrl) {
    await chrome.tabs.update(tab.id, { url: projectUrl, active: true });
    await waitForTabComplete(tab.id, 15000);
  }
  await focusTab(await chrome.tabs.get(tab.id));
}

async function handleProjectAction(message) {
  const project = message.project;
  if (!project?.id || !project?.name) throw new Error("Projeto inválido.");

  let tab = await getOrCreateChatGptTab();
  const projectUrl = await resolveOrCreateProject(tab, project, message.knownProjectUrl || "");
  await navigateToProject(tab, projectUrl);
  tab = await chrome.tabs.get(tab.id);

  if (message.type === "gpm:new-chat") {
    const result = await sendToChatGpt(tab.id, { type: "gpm:start-new-chat", project });
    if (!result?.ok) throw new Error(result?.error || "Não consegui iniciar um novo chat dentro do Project.");
  }

  return { ok: true, projectUrl };
}

chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (!message || !["gpm:new-chat", "gpm:open-project"].includes(message.type)) return false;

  handleProjectAction(message)
    .then(sendResponse)
    .catch((error) => sendResponse({ ok: false, error: error.message || String(error) }));
  return true;
});
