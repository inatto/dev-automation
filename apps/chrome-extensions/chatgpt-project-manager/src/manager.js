"use strict";

const KEYS = {
  settings: "gpm.settings",
  layout: "gpm.layout",
  cache: "gpm.cache",
  machineSource: "gpm.machineSource",
};

const DEFAULT_SETTINGS = {
  // sourceUrl permanece apenas para migrar instalações da versão 0.1.
  sourceUrl: "",
  hideChatGptSidebar: false,
};

const DEFAULT_MACHINE_SOURCE = {
  mode: "", // "url" | "file"
  sourceUrl: "",
  fileName: "",
};

const DEFAULT_LAYOUT = {
  folders: [],
  placements: {},
  favorites: {},
  links: {}, // legado da v0.1/v0.2
  gptProjects: {},
  contexts: {},
  collapsed: {},
};

const state = {
  settings: { ...DEFAULT_SETTINGS },
  machineSource: { ...DEFAULT_MACHINE_SOURCE },
  layout: structuredClone(DEFAULT_LAYOUT),
  projects: [],
  sourceLabel: "",
  view: "all",
  search: "",
};

const $ = (id) => document.getElementById(id);

function slug(value) {
  return String(value ?? "")
    .trim()
    .toLowerCase()
    .normalize("NFD")
    .replace(/[\u0300-\u036f]/g, "")
    .replace(/[^a-z0-9._/-]+/g, "-")
    .replace(/^-+|-+$/g, "") || crypto.randomUUID();
}

function safeId(prefix, value) {
  return `${prefix}:${slug(value)}`;
}

function projectFromValue(value, fallbackPath = "", index = 0) {
  if (typeof value === "string") {
    const path = value.trim();
    const name = path.split("/").filter(Boolean).at(-1) || path;
    return {
      id: safeId("project", path || `${fallbackPath}/${index}`),
      name,
      path,
      url: "",
      context: "",
      sourceFolder: path.includes("/") ? path.split("/").slice(0, -1).join("/") : "",
    };
  }

  if (!value || typeof value !== "object") return null;

  const path = String(value.path ?? value.projectPath ?? value.slug ?? fallbackPath ?? "").trim();
  const name = String(value.name ?? value.title ?? value.label ?? path.split("/").filter(Boolean).at(-1) ?? `Projeto ${index + 1}`).trim();
  const rawId = value.id ?? value.key ?? value.slug ?? path ?? name;

  return {
    id: safeId("project", rawId),
    name,
    path: path || name,
    url: String(value.gptUrl ?? value.chatgptUrl ?? value.url ?? "").trim(),
    context: String(value.context ?? value.instructions ?? value.notes ?? "").trim(),
    sourceFolder: String(value.parentPath ?? value.folder ?? value.group ?? "").trim()
      || (path.includes("/") ? path.split("/").slice(0, -1).join("/") : ""),
  };
}

function collectNested(input, output = [], parentPath = "") {
  if (Array.isArray(input)) {
    input.forEach((item, index) => collectNested(item, output, parentPath, index));
    return output;
  }

  if (typeof input === "string") {
    const project = projectFromValue(input, parentPath, output.length);
    if (project) output.push(project);
    return output;
  }

  if (!input || typeof input !== "object") return output;

  const knownCollection = input.projects ?? input.items ?? input.data;
  if (Array.isArray(knownCollection)) {
    collectNested(knownCollection, output, parentPath);
    return output;
  }

  const children = input.children ?? input.subprojects;
  if (Array.isArray(children)) {
    const nodeName = String(input.name ?? input.title ?? input.label ?? "").trim();
    const nextParent = [parentPath, nodeName].filter(Boolean).join("/");

    if (input.url || input.gptUrl || input.chatgptUrl || input.path || input.projectPath) {
      const project = projectFromValue(input, nextParent, output.length);
      if (project) output.push(project);
    }

    collectNested(children, output, nextParent);
    return output;
  }

  const objectLooksLikeProject = ["id", "name", "title", "path", "projectPath", "url", "gptUrl", "chatgptUrl"]
    .some((key) => Object.prototype.hasOwnProperty.call(input, key));

  if (objectLooksLikeProject) {
    const project = projectFromValue(input, parentPath, output.length);
    if (project) output.push(project);
    return output;
  }

  // Também aceita mapa JSON: { "orbital-app": {...}, "orbital-mail": {...} }
  Object.entries(input).forEach(([key, value]) => {
    if (value && typeof value === "object" && !Array.isArray(value)) {
      collectNested({ name: key, ...value }, output, parentPath);
    } else if (typeof value === "string") {
      collectNested({ name: key, path: value }, output, parentPath);
    }
  });

  return output;
}

function normalizeProjects(input) {
  const projects = collectNested(input);
  const unique = new Map();

  projects.forEach((project) => {
    const key = project.id;
    if (!unique.has(key)) unique.set(key, project);
  });

  return [...unique.values()].sort((a, b) => a.path.localeCompare(b.path, "pt-BR"));
}

function parseProjectsText(text) {
  const paths = String(text ?? "")
    .replace(/^\uFEFF/, "")
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter((line) => line && !line.startsWith("#"))
    .map((line) => line.replace(/\\/g, "/").replace(/^\/+|\/+$/g, ""))
    .filter(Boolean);

  return normalizeProjects(paths);
}

function parseSourceText(text) {
  const raw = String(text ?? "");
  const trimmed = raw.trim();
  if (!trimmed) return [];

  try {
    return normalizeProjects(JSON.parse(trimmed));
  } catch {
    return parseProjectsText(raw);
  }
}

function openFileHandleDb() {
  return new Promise((resolve, reject) => {
    const request = indexedDB.open("gpm-local-files", 1);
    request.onupgradeneeded = () => {
      const db = request.result;
      if (!db.objectStoreNames.contains("handles")) db.createObjectStore("handles");
    };
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error);
  });
}

async function storeLocalFileHandle(handle) {
  const db = await openFileHandleDb();
  await new Promise((resolve, reject) => {
    const tx = db.transaction("handles", "readwrite");
    tx.objectStore("handles").put(handle, "projects-source");
    tx.oncomplete = resolve;
    tx.onerror = () => reject(tx.error);
  });
  db.close();
}

async function getLocalFileHandle() {
  const db = await openFileHandleDb();
  const handle = await new Promise((resolve, reject) => {
    const tx = db.transaction("handles", "readonly");
    const request = tx.objectStore("handles").get("projects-source");
    request.onsuccess = () => resolve(request.result || null);
    request.onerror = () => reject(request.error);
  });
  db.close();
  return handle;
}

async function loadState() {
  const [syncData, localData] = await Promise.all([
    chrome.storage.sync.get([KEYS.settings, KEYS.layout]),
    chrome.storage.local.get([KEYS.cache, KEYS.machineSource]),
  ]);

  state.settings = { ...DEFAULT_SETTINGS, ...(syncData[KEYS.settings] || {}) };
  state.layout = { ...structuredClone(DEFAULT_LAYOUT), ...(syncData[KEYS.layout] || {}) };
  state.machineSource = { ...DEFAULT_MACHINE_SOURCE, ...(localData[KEYS.machineSource] || {}) };

  // Migração transparente da versão 0.1, que salvava a URL em storage.sync.
  if (!state.machineSource.mode && state.settings.sourceUrl) {
    state.machineSource = { mode: "url", sourceUrl: state.settings.sourceUrl, fileName: "" };
  }

  const cache = localData[KEYS.cache];
  if (cache?.projects) {
    state.projects = cache.projects;
    state.sourceLabel = cache.sourceLabel || "cache local";
  }

  $("sourceUrlInput").value = state.machineSource.sourceUrl || "";
  $("hideSidebarInput").checked = state.settings.hideChatGptSidebar === true;
  updateSourceUi();
}

async function saveSettings() {
  await chrome.storage.sync.set({ [KEYS.settings]: state.settings });
}

async function saveMachineSource() {
  await chrome.storage.local.set({ [KEYS.machineSource]: state.machineSource });
  updateSourceUi();
}

async function saveLayout() {
  await chrome.storage.sync.set({ [KEYS.layout]: state.layout });
}

async function saveCache(projects, sourceLabel) {
  await chrome.storage.local.set({
    [KEYS.cache]: {
      projects,
      sourceLabel,
      updatedAt: new Date().toISOString(),
    },
  });
}

function updateSourceUi() {
  const status = $("localFileStatus");
  if (!status) return;

  if (state.machineSource.mode === "file" && state.machineSource.fileName) {
    status.textContent = `Arquivo local: ${state.machineSource.fileName}`;
  } else if (state.machineSource.mode === "url" && state.machineSource.sourceUrl) {
    status.textContent = `URL: ${state.machineSource.sourceUrl}`;
  } else {
    status.textContent = "Nenhuma fonte configurada nesta máquina.";
  }
}

function permissionPattern(urlString) {
  const url = new URL(urlString);
  return `${url.protocol}//${url.host}/*`;
}

async function ensureUrlPermission(urlString) {
  const origin = permissionPattern(urlString);
  const hasPermission = await chrome.permissions.contains({ origins: [origin] });
  if (hasPermission) return true;
  return chrome.permissions.request({ origins: [origin] });
}

async function refreshFromUrl() {
  const sourceUrl = state.machineSource.sourceUrl?.trim();
  if (!sourceUrl) {
    setStatus("Configure uma URL ou selecione um arquivo local.", true);
    return;
  }

  let parsedUrl;
  try {
    parsedUrl = new URL(sourceUrl);
    if (!['http:', 'https:'].includes(parsedUrl.protocol)) throw new Error("protocol");
  } catch {
    setStatus("A fonte por URL precisa ser http:// ou https://.", true);
    return;
  }

  setStatus("Carregando fonte...");

  try {
    const granted = await ensureUrlPermission(sourceUrl);
    if (!granted) {
      setStatus("Permissão para acessar a URL não foi concedida.", true);
      return;
    }

    const response = await fetch(sourceUrl, { cache: "no-store" });
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    const projects = parseSourceText(await response.text());
    state.projects = projects;
    state.sourceLabel = sourceUrl;
    await saveCache(projects, sourceUrl);
    setStatus(`${projects.length} projeto(s) carregado(s) da URL.`);
    render();
  } catch (error) {
    setStatus(`Falha ao carregar a URL: ${error.message}. Mantendo cache.`, true);
  }
}

async function loadProjectsFromFile(file, sourceLabel = file?.name || "arquivo local") {
  if (!file) return;
  const projects = parseSourceText(await file.text());
  state.projects = projects;
  state.sourceLabel = sourceLabel;
  await saveCache(projects, sourceLabel);
  setStatus(`${projects.length} projeto(s) carregado(s) de ${file.name}.`);
  render();
}

async function chooseLocalSourceFile() {
  if (!("showOpenFilePicker" in window)) {
    $("fileInput").click();
    return;
  }

  try {
    const [handle] = await window.showOpenFilePicker({
      multiple: false,
      types: [
        {
          description: "Projetos ou JSON",
          accept: {
            "text/plain": [".projects", ".txt"],
            "application/json": [".json"],
          },
        },
      ],
    });
    if (!handle) return;

    await storeLocalFileHandle(handle);
    state.machineSource = { mode: "file", sourceUrl: "", fileName: handle.name };
    await saveMachineSource();
    await loadProjectsFromFile(await handle.getFile(), `arquivo:${handle.name}`);
  } catch (error) {
    if (error?.name !== "AbortError") setStatus(`Não foi possível abrir o arquivo: ${error.message}`, true);
  }
}

async function importLocalFileFallback(file) {
  if (!file) return;
  try {
    state.machineSource = { mode: "file", sourceUrl: "", fileName: file.name };
    await saveMachineSource();
    await loadProjectsFromFile(file, `arquivo:${file.name}`);
    setStatus(`${state.projects.length} projeto(s) carregado(s). Este navegador não permite manter o vínculo automático; selecione o arquivo novamente para atualizar.`);
  } catch (error) {
    setStatus(`Arquivo inválido: ${error.message}`, true);
  } finally {
    $("fileInput").value = "";
  }
}

async function refreshFromLocalFile(interactive = false) {
  try {
    const handle = await getLocalFileHandle();
    if (!handle) {
      setStatus("Selecione o arquivo local nesta máquina.", true);
      if (interactive) await chooseLocalSourceFile();
      return;
    }

    let permission = await handle.queryPermission({ mode: "read" });
    if (permission !== "granted" && interactive) {
      permission = await handle.requestPermission({ mode: "read" });
    }
    if (permission !== "granted") {
      setStatus(`Clique em Atualizar fonte para liberar a leitura de ${handle.name}.`, true);
      return;
    }

    state.machineSource.fileName = handle.name;
    await saveMachineSource();
    await loadProjectsFromFile(await handle.getFile(), `arquivo:${handle.name}`);
  } catch (error) {
    setStatus(`Falha ao ler o arquivo local: ${error.message}. Mantendo cache.`, true);
  }
}

async function refreshSource(interactive = true) {
  if (state.machineSource.mode === "file") {
    await refreshFromLocalFile(interactive);
  } else if (state.machineSource.mode === "url") {
    await refreshFromUrl();
  } else {
    setStatus("Selecione um arquivo local ou configure uma URL.", true);
    $("settingsPanel").classList.remove("hidden");
  }
}

function folderIdFromPath(path) {
  return safeId("folder", path);
}

function ensureFolderPath(path, source = "custom") {
  const parts = String(path || "").split("/").map((part) => part.trim()).filter(Boolean);
  let parentId = null;
  let currentPath = "";

  for (const part of parts) {
    currentPath = currentPath ? `${currentPath}/${part}` : part;
    const id = folderIdFromPath(currentPath);
    if (!state.layout.folders.some((folder) => folder.id === id)) {
      state.layout.folders.push({ id, name: part, parentId, source });
    }
    parentId = id;
  }

  return parentId;
}

function ensureSourceFolders() {
  state.projects.forEach((project) => {
    if (!state.layout.placements[project.id] && project.sourceFolder) {
      const folderId = ensureFolderPath(project.sourceFolder, "source");
      if (folderId) state.layout.placements[project.id] = folderId;
    }
  });
}

function visibleProject(project) {
  if (state.view === "favorites" && !state.layout.favorites[project.id]) return false;
  if (state.view === "unorganized" && state.layout.placements[project.id]) return false;

  const query = state.search.trim().toLocaleLowerCase("pt-BR");
  if (!query) return true;

  const haystack = [
    project.name,
    project.path,
    project.context,
    state.layout.contexts[project.id],
  ].filter(Boolean).join(" ").toLocaleLowerCase("pt-BR");

  return haystack.includes(query);
}

function buildTree() {
  ensureSourceFolders();

  const folders = new Map(state.layout.folders.map((folder) => [folder.id, { ...folder, children: [], projects: [] }]));
  const roots = [];

  folders.forEach((folder) => {
    if (folder.parentId && folders.has(folder.parentId)) {
      folders.get(folder.parentId).children.push(folder);
    } else {
      roots.push(folder);
    }
  });

  state.projects.filter(visibleProject).forEach((project) => {
    const folderId = state.layout.placements[project.id];
    const sourceParentId = project.sourceFolder ? folderIdFromPath(project.sourceFolder) : "";
    const fullPathFolderId = folderIdFromPath(project.path);

    // Quando um projeto também é pai de outro caminho, ele vira o próprio nó expansível.
    // Ex.: infra/amazon-infra + infra/amazon-infra/apps/monitor-app.
    if (folderId === sourceParentId && folders.has(fullPathFolderId)) {
      folders.get(fullPathFolderId).project = project;
    } else if (folderId && folders.has(folderId)) {
      folders.get(folderId).projects.push(project);
    } else {
      roots.push({ type: "project", project });
    }
  });

  const sortNode = (node) => {
    if (node.children) {
      node.children.sort((a, b) => a.name.localeCompare(b.name, "pt-BR"));
      node.projects.sort((a, b) => a.name.localeCompare(b.name, "pt-BR"));
      node.children.forEach(sortNode);
    }
  };
  roots.filter((node) => node.children).sort((a, b) => a.name.localeCompare(b.name, "pt-BR")).forEach(sortNode);

  return roots;
}

function folderContainsVisible(folder) {
  return Boolean(folder.project) || folder.projects.length > 0 || folder.children.some(folderContainsVisible);
}

function render() {
  const tree = $("tree");
  tree.replaceChildren();
  const roots = buildTree();
  let rendered = 0;

  for (const root of roots) {
    if (root.type === "project") {
      renderProject(root.project, 0, tree);
      rendered += 1;
    } else if (folderContainsVisible(root)) {
      rendered += renderFolder(root, 0, tree);
    }
  }

  $("emptyState").classList.toggle("hidden", rendered > 0);
}

function gptProjectUrl(project) {
  const automatic = state.layout.gptProjects?.[project.id]?.url;
  if (automatic) return automatic;

  // Migração suave: um vínculo antigo que já era URL de Project pode ser reaproveitado.
  const legacy = state.layout.links?.[project.id] || project.url || "";
  if (/^https:\/\/chatgpt\.com\/g\//i.test(legacy)) return legacy;
  return "";
}

async function runChatGptProjectAction(project, action) {
  const label = action === "new-chat" ? "Abrindo novo chat" : "Abrindo Project";
  setStatus(`${label} para ${project.name}...`);

  try {
    const response = await chrome.runtime.sendMessage({
      type: action === "new-chat" ? "gpm:new-chat" : "gpm:open-project",
      project: { id: project.id, name: project.name, path: project.path },
      knownProjectUrl: gptProjectUrl(project),
    });

    if (!response?.ok) throw new Error(response?.error || "Não foi possível concluir a ação no ChatGPT.");

    if (response.projectUrl) {
      state.layout.gptProjects ||= {};
      state.layout.gptProjects[project.id] = {
        url: response.projectUrl,
        name: project.name,
        updatedAt: new Date().toISOString(),
      };
      render();
    }

    setStatus(action === "new-chat"
      ? `Novo chat aberto dentro de ${project.name}.`
      : `Project ${project.name} aberto no ChatGPT.`);
  } catch (error) {
    setStatus(`Falha no ChatGPT: ${error.message}`, true);
  }
}

function makeProjectActions(project) {
  const actions = document.createElement("div");
  actions.className = "row-actions";
  const linkedUrl = gptProjectUrl(project);

  const favorite = document.createElement("button");
  favorite.className = `star ${state.layout.favorites[project.id] ? "on" : ""}`;
  favorite.textContent = state.layout.favorites[project.id] ? "★" : "☆";
  favorite.title = "Favorito";
  favorite.addEventListener("click", async () => {
    state.layout.favorites[project.id] = !state.layout.favorites[project.id];
    await saveLayout();
    render();
  });

  const newChat = document.createElement("button");
  newChat.textContent = "+ Novo chat";
  newChat.className = "primary";
  newChat.title = "Criar um novo chat dentro do Project correspondente no ChatGPT";
  newChat.addEventListener("click", () => runChatGptProjectAction(project, "new-chat"));

  const open = document.createElement("button");
  open.textContent = linkedUrl ? "Abrir GPT" : "Abrir/Criar GPT";
  open.title = linkedUrl
    ? "Abrir o Project correspondente no ChatGPT"
    : "Localizar ou criar automaticamente o Project correspondente no ChatGPT";
  open.addEventListener("click", () => runChatGptProjectAction(project, "open-project"));

  const edit = document.createElement("button");
  edit.textContent = "Editar";
  edit.addEventListener("click", () => openProjectDialog(project));

  actions.append(favorite, newChat, open, edit);
  return actions;
}
function renderFolder(folder, depth, container) {
  const row = document.createElement("div");
  row.className = "tree-row";
  row.style.setProperty("--depth", depth);

  const main = document.createElement("div");
  main.className = "tree-main";
  main.innerHTML = `<span class="indent"></span>`;

  const toggle = document.createElement("button");
  const collapsed = state.layout.collapsed[folder.id] === true;
  toggle.textContent = collapsed ? "▸" : "▾";
  toggle.title = collapsed ? "Expandir" : "Recolher";
  toggle.addEventListener("click", async () => {
    state.layout.collapsed[folder.id] = !collapsed;
    await saveLayout();
    render();
  });

  const name = document.createElement("span");
  name.className = "folder-name";
  name.textContent = folder.name;

  main.append(toggle, name);

  if (folder.project) {
    const badge = document.createElement("span");
    badge.className = "badge";
    badge.textContent = "projeto";
    main.append(badge);

    const linkedUrl = gptProjectUrl(folder.project);
    if (linkedUrl) {
      const gptBadge = document.createElement("span");
      gptBadge.className = "badge";
      gptBadge.textContent = "GPT";
      main.append(gptBadge);
    }
  }

  row.append(main);

  const actions = folder.project ? makeProjectActions(folder.project) : document.createElement("div");
  actions.classList.add("row-actions");
  const add = document.createElement("button");
  add.textContent = "+ Subpasta";
  add.addEventListener("click", () => createFolder(folder.id));
  actions.prepend(add);
  row.append(actions);
  container.append(row);

  let count = 1;
  if (!collapsed) {
    folder.children.forEach((child) => { count += renderFolder(child, depth + 1, container); });
    folder.projects.forEach((project) => { renderProject(project, depth + 1, container); count += 1; });
  }
  return count;
}

function renderProject(project, depth, container) {
  const row = document.createElement("div");
  row.className = "tree-row";
  row.style.setProperty("--depth", depth);

  const main = document.createElement("div");
  main.className = "tree-main";
  const linkedUrl = gptProjectUrl(project);
  const context = state.layout.contexts[project.id] || project.context;
  main.innerHTML = `<span class="indent"></span><span>▣</span>`;

  const text = document.createElement("div");
  text.className = "row-text";
  const name = document.createElement("div");
  name.className = "project-name";
  name.textContent = project.name;
  const path = document.createElement("div");
  path.className = "project-path";
  path.textContent = project.path;
  text.append(name, path);
  main.append(text);

  if (linkedUrl) {
    const badge = document.createElement("span");
    badge.className = "badge";
    badge.textContent = "GPT";
    main.append(badge);
  }
  if (context) {
    const badge = document.createElement("span");
    badge.className = "badge";
    badge.textContent = "contexto";
    main.append(badge);
  }

  const actions = makeProjectActions(project);
  row.append(main, actions);
  container.append(row);
}

async function openLinkedUrl(url) {
  if (!url) return;
  const tabs = await chrome.tabs.query({});
  const normalized = new URL(url).href.replace(/\/$/, "");
  const existing = tabs.find((tab) => {
    try {
      return new URL(tab.url).href.replace(/\/$/, "") === normalized;
    } catch {
      return false;
    }
  });

  if (existing?.id) {
    await chrome.tabs.update(existing.id, { active: true });
    if (existing.windowId) await chrome.windows.update(existing.windowId, { focused: true });
  } else {
    await chrome.tabs.create({ url });
  }
}

function folderPath(folderId) {
  const map = new Map(state.layout.folders.map((folder) => [folder.id, folder]));
  const parts = [];
  let current = map.get(folderId);
  const visited = new Set();
  while (current && !visited.has(current.id)) {
    visited.add(current.id);
    parts.unshift(current.name);
    current = current.parentId ? map.get(current.parentId) : null;
  }
  return parts.join("/");
}

function fillFolderSelect(selectedId = "") {
  const select = $("folderSelect");
  select.replaceChildren();
  const empty = document.createElement("option");
  empty.value = "";
  empty.textContent = "— Não organizado —";
  select.append(empty);

  state.layout.folders
    .slice()
    .sort((a, b) => folderPath(a.id).localeCompare(folderPath(b.id), "pt-BR"))
    .forEach((folder) => {
      const option = document.createElement("option");
      option.value = folder.id;
      option.textContent = folderPath(folder.id);
      select.append(option);
    });
  select.value = selectedId || "";
}

function openProjectDialog(project) {
  $("projectIdInput").value = project.id;
  $("projectDialogTitle").textContent = project.name;
  $("contextInput").value = state.layout.contexts[project.id] || project.context || "";
  fillFolderSelect(state.layout.placements[project.id] || "");
  $("projectDialog").showModal();
}

async function saveProjectDialog(event) {
  event.preventDefault();
  const projectId = $("projectIdInput").value;
  const context = $("contextInput").value.trim();
  const folderId = $("folderSelect").value;

  if (context) state.layout.contexts[projectId] = context;
  else delete state.layout.contexts[projectId];

  if (folderId) state.layout.placements[projectId] = folderId;
  else delete state.layout.placements[projectId];

  await saveLayout();
  $("projectDialog").close();
  render();
  setStatus("Projeto atualizado.");
}

async function createFolder(parentId = null) {
  const name = prompt(parentId ? "Nome da subpasta:" : "Nome da pasta:");
  if (!name?.trim()) return;

  const parentPath = parentId ? folderPath(parentId) : "";
  const fullPath = [parentPath, name.trim()].filter(Boolean).join("/");
  ensureFolderPath(fullPath, "custom");
  await saveLayout();
  render();
}

function setStatus(message, error = false) {
  const status = $("status");
  status.textContent = message;
  status.style.color = error ? "#c2410c" : "";
}

function wireEvents() {
  $("settingsButton").addEventListener("click", () => $("settingsPanel").classList.toggle("hidden"));
  $("refreshButton").addEventListener("click", () => refreshSource(true));
  $("newFolderButton").addEventListener("click", () => createFolder(null));

  $("saveSourceButton").addEventListener("click", async () => {
    const sourceUrl = $("sourceUrlInput").value.trim();
    state.machineSource = { mode: "url", sourceUrl, fileName: "" };
    await saveMachineSource();
    setStatus("URL salva para esta máquina.");
    if (sourceUrl) refreshFromUrl();
  });

  $("selectLocalFileButton").addEventListener("click", chooseLocalSourceFile);
  $("fileInput").addEventListener("change", (event) => importLocalFileFallback(event.target.files?.[0]));

  $("hideSidebarInput").addEventListener("change", async (event) => {
    state.settings.hideChatGptSidebar = event.target.checked;
    await saveSettings();
    setStatus(event.target.checked ? "Barra original será ocultada nas abas do ChatGPT." : "Barra original será exibida.");
  });

  $("searchInput").addEventListener("input", (event) => {
    state.search = event.target.value;
    render();
  });

  document.querySelectorAll(".nav-item").forEach((button) => {
    button.addEventListener("click", () => {
      document.querySelectorAll(".nav-item").forEach((item) => item.classList.remove("active"));
      button.classList.add("active");
      state.view = button.dataset.view;
      render();
    });
  });

  $("projectForm").addEventListener("submit", saveProjectDialog);

  chrome.storage.onChanged.addListener((changes, area) => {
    if (area !== "sync" || !changes[KEYS.layout]) return;
    state.layout = {
      ...structuredClone(DEFAULT_LAYOUT),
      ...(changes[KEYS.layout].newValue || {}),
    };
    render();
  });
}

(async () => {
  wireEvents();
  await loadState();
  render();

  if (state.machineSource.mode === "file") {
    await refreshFromLocalFile(false);
    if (!state.projects.length) $("settingsPanel").classList.remove("hidden");
  } else if (state.machineSource.mode === "url" && state.machineSource.sourceUrl) {
    await refreshFromUrl();
  } else if (state.projects.length) {
    setStatus(`${state.projects.length} projeto(s) no cache.`);
  } else {
    setStatus("Selecione auto-code-manager.projects ou configure uma URL.");
    $("settingsPanel").classList.remove("hidden");
  }
})();
