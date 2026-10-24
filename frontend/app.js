import { PagedFeed } from "./feed.mjs";
import {
  priceText,
  currentOffer,
  offerLink,
  sourceLink,
  exploreKey,
  EXPLORE_EMPTY,
  validateImage,
} from "./presentation.mjs";
import { CommonThreadClient, newMutationKey } from "./lib/client.js?v=2";
import {
  SOURCE_NAMES,
  sourceHost,
  safeLink,
  visibleSaves,
  loadSavedLibrary,
} from "./library.mjs";

const $ = (selector, root = document) => root.querySelector(selector);
const escape = (value = "") =>
  String(value).replace(
    /[&<>"']/g,
    (char) =>
      ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[
        char
      ],
  );
const store = {
  get(key) {
    try {
      return sessionStorage.getItem(key);
    } catch {
      return null;
    }
  },
  set(key, value) {
    try {
      sessionStorage.setItem(key, value);
    } catch {}
  },
  remove(key) {
    try {
      sessionStorage.removeItem(key);
    } catch {}
  },
};
let token =
  store.get("mymah-finds-token") ??
  store.get("common-thread-token") ??
  "demo-alex";
let view = ["library", "explore", "profile"].includes(location.hash.slice(1))
  ? location.hash.slice(1)
  : "library";
let items = [],
  account = null,
  query = "",
  source = "all",
  sort = "newest",
  layout = "grid";
let loading = true,
  loadError = "",
  toastTimer,
  connectionRevision = 0,
  accountIntent = 0,
  refreshPromise,
  refreshController,
  captureAttempt = null,
  captureFlight = null,
  removeAttempt = null;
const removalAttempts = new Map();
const client = () =>
  new CommonThreadClient({ baseURL: location.origin, token });
const paths = {
  plus: '<path d="M12 5v14M5 12h14"/>',
  search: '<circle cx="10.5" cy="10.5" r="6.5"/><path d="m16 16 5 5"/>',
  arrow: '<path d="M5 12h14m-6-6 6 6-6 6"/>',
  chevron: '<path d="m9 5 7 7-7 7"/>',
  link: '<path d="m10 13 4-4M9 15l-2 2a3.5 3.5 0 0 1-5-5l4-4a3.5 3.5 0 0 1 5 0m2 1 2-2a3.5 3.5 0 0 1 5 5l-4 4a3.5 3.5 0 0 1-5 0"/>',
  article:
    '<rect x="5" y="3" width="14" height="18" rx="2"/><path d="M8 8h8M8 12h8M8 16h5"/>',
  product: '<path d="M4 7h16l-1 14H5L4 7Z"/><path d="M8 8V6a4 4 0 0 1 8 0v2"/>',
  grid: '<rect x="3" y="3" width="7" height="7" rx="1.5"/><rect x="14" y="3" width="7" height="7" rx="1.5"/><rect x="3" y="14" width="7" height="7" rx="1.5"/><rect x="14" y="14" width="7" height="7" rx="1.5"/>',
  list: '<path d="M9 5h12M9 12h12M9 19h12M3 5h1M3 12h1M3 19h1"/>',
  person: '<circle cx="12" cy="8" r="4"/><path d="M4 21v-2a8 8 0 0 1 16 0v2"/>',
  bookmark: '<path d="M6 3h12v18l-6-4-6 4V3Z"/>',
  logout: '<path d="M10 4H4v16h6M9 12h12m-5-5 5 5-5 5"/>',
  help: '<circle cx="12" cy="12" r="9"/><path d="M9 9a3 3 0 1 1 5 2c-1 1-2 1-2 3M12 17v1"/>',
  trash: '<path d="M3 6h18M9 6V3h6v3M5 6l1 15h12l1-15M10 10v7M14 10v7"/>',
};
const icon = (name) =>
  `<svg class="inline-icon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${paths[name] || paths.link}</svg>`;
const name = () =>
  account
    ? account.user_id
        .replace(/[-_]/g, " ")
        .replace(/\b\w/g, (c) => c.toUpperCase())
    : "Your space";
const date = (value) =>
  new Date(value * 1000).toLocaleDateString(undefined, {
    month: "short",
    day: "numeric",
  });
const kind = (item) =>
  ["article", "product"].includes(item.source) ? item.source : "link";
const sourceLabel = (item) =>
  ({
    web: "Web link",
    article: "Article",
    product: "Product link",
    pinterest: "Pinterest",
    instagram: "Instagram",
  })[item.source] || "Link";
function toast(message) {
  clearTimeout(toastTimer);
  $("#toast").textContent = message;
  $("#toast").hidden = false;
  toastTimer = setTimeout(() => ($("#toast").hidden = true), 4200);
}
function errorMessage(error) {
  if (error.status === 401)
    return "Your library needs an access key. Connect from Profile to continue.";
  if (error.status === 410)
    return "This save was removed. Close this sheet and refresh your library before starting a new save.";
  if (error.code === "network_error" || error.code === "request_timeout")
    return "Couldn’t connect. Your details are kept here; try again when you’re back online.";
  if (error.code === "invalid_response" || error.status >= 500)
    return "We couldn’t confirm the result. Your details are kept here; please retry the same save.";
  if (error.code === "idempotency_conflict")
    return "These details changed while saving. Close this sheet, refresh your library, and review the find before trying again.";
  return error.message || "Something went wrong. Please try again.";
}

const prefs = {
  get(key, fallback) {
    try {
      return localStorage.getItem(`mynah.${key}`) || fallback;
    } catch {
      return fallback;
    }
  },
  set(key, value) {
    try {
      localStorage.setItem(`mynah.${key}`, value);
    } catch {
      toast("This browser could not remember that preference.");
    }
  },
};
layout = prefs.get("layout", store.get("mymah-finds-layout") || "grid");
sort = prefs.get("sort", "newest");
let appearance = prefs.get("appearance", "system"),
  exploreQuery = "",
  searchTimer,
  exploreTimer,
  capabilities = null;
const searchFeed = new PagedFeed({ onChange: renderLibraryResults });
const exploreFeed = new PagedFeed({
  key: exploreKey,
  onChange: renderExploreResults,
});
const imageCache = new Map(),
  detailAttempts = new Map();
let mediaController = new AbortController(),
  detailGeneration = 0;
Object.assign(paths, {
  photo:
    '<rect x="3" y="3" width="18" height="18" rx="3"/><circle cx="8" cy="8" r="1.5"/><path d="m3 17 5-5 4 4 4-6 5 7"/>',
  appearance: '<circle cx="12" cy="12" r="9"/><path d="M12 3v18"/>',
  sort: '<path d="M8 4v16m-4-4 4 4 4-4M16 20V4m-4 4 4-4 4 4"/>',
  refresh:
    '<path d="M20 7v5h-5M4 17v-5h5M6 7a7 7 0 0 1 12-1l2 3M4 15l2 3a7 7 0 0 0 12-1"/>',
  shield:
    '<path d="m12 3 8 3v6c0 5-8 9-8 9s-8-4-8-9V6l8-3Z"/><path d="m8 12 3 3 5-6"/>',
  play: '<rect x="3" y="5" width="18" height="14" rx="3"/><path d="m10 9 5 3-5 3V9Z"/>',
});

function mascot(size = 90) {
  return `<img class="mascot" src="/assets/mynah.png" width="${size}" height="${size}" alt="">`;
}
function header(title, subtitle) {
  return `<div class="page-header"><div><h1>${title}</h1><p class="subtitle">${subtitle}</p></div>${view === "library" ? `<div class="header-actions"><button class="primary" data-action="add">${icon("plus")} Save a find</button></div>` : ""}</div>`;
}
function empty(title, text, add = false) {
  return `<div class="empty-state">${mascot()}<h2>${escape(title)}</h2><p>${escape(text)}</p>${add ? `<button class="primary" data-action="${account ? "add" : "account"}">${account ? "Save your first find" : "Connect your library"}</button>` : ""}</div>`;
}
function media(item, detail = false) {
  return `<div class="${detail ? "detail-cover " : ""}cover source-${Object.hasOwn(SOURCE_NAMES, item.source) ? item.source : "web"}">${item.has_image ? `<img data-saved-image="${escape(item.id)}" alt="${escape(item.title)}" hidden><span class="image-placeholder">${icon("photo")}</span>` : icon(kind(item))}</div>`;
}
function card(item) {
  return `<button class="save-card" data-action="detail" data-id="${escape(item.id)}" aria-label="Open ${escape(item.title)}">${media(item)}<div class="card-body"><span class="source-line">${escape(item.has_image && !safeLink(item.original_url) ? "Photo" : sourceHost(item))}</span><h3>${escape(item.title)}</h3>${item.note || item.selected_text ? `<p class="card-note">${escape(item.note || item.selected_text)}</p>` : ""}<div class="card-meta"><span>${date(item.captured_at)}</span>${icon("chevron")}</div></div></button>`;
}
function banner() {
  return loadError
    ? `<div class="error-banner" role="status">${escape(loadError)}<button class="text-button" data-action="${account ? "refresh" : "account"}">${account ? "Try again" : "Connect"}</button></div>`
    : loading
      ? '<p class="status-banner" role="status">Updating your library…</p>'
      : "";
}
function searchField(id, value, placeholder, max) {
  return `<div class="search-field">${icon("search")}<label class="sr-only" for="${id}">${placeholder}</label><input id="${id}" type="search" value="${escape(value)}" placeholder="${placeholder}" maxlength="${max}" autocomplete="off"><button class="icon-button" data-action="clear-search" data-field="${id}" aria-label="Clear search" ${value ? "" : "hidden"}>×</button></div>`;
}
function filters() {
  return `<div class="filters" aria-label="Filter saved content">${[["all", "All finds"], ...Object.entries(SOURCE_NAMES).filter(([key]) => items.some((item) => item.source === key))].map(([key, label]) => `<button class="filter ${source === key ? "active" : ""}" data-source="${key}" aria-pressed="${source === key}">${label}</button>`).join("")}</div>`;
}
function sortOptions() {
  return [
    ["newest", "Newest first"],
    ["oldest", "Oldest first"],
    ["title", "Title A–Z"],
  ]
    .map(
      ([value, label]) =>
        `<option value="${value}" ${sort === value ? "selected" : ""}>${label}</option>`,
    )
    .join("");
}
function library() {
  return (
    header(
      "Library",
      items.length
        ? "Your little collection of good finds."
        : "Keep what catches your eye.",
    ) +
    searchField("search-input", query, "Search finds, notes, categories", 200) +
    banner() +
    `<div class="library-toolbar">${filters()}<div class="view-tools"><label class="sr-only" for="sort">Sort finds</label><select id="sort">${sortOptions()}</select><div class="segmented" aria-label="Library layout">${["grid", "list"].map((value) => `<button data-layout="${value}" class="${layout === value ? "active" : ""}" aria-label="${value === "grid" ? "Grid" : "List"} view" aria-pressed="${layout === value}">${icon(value)}</button>`).join("")}</div></div></div><div id="library-results"></div>`
  );
}
function skeleton() {
  return `<div class="library-grid" aria-hidden="true">${'<div class="skeleton"></div>'.repeat(3)}</div>`;
}
function renderLibraryResults() {
  const root = $("#library-results");
  if (!root) return;
  const searching = Boolean(query.trim()),
    feed = searchFeed;
  const saved = visibleSaves(searching ? feed.items : items, { source, sort });
  const busy = searching ? feed.loading : loading;
  let html = "";
  if (searching && feed.error)
    html += `<div class="error-banner" role="alert">${escape(errorMessage(feed.error))}<button class="text-button" data-action="retry-search">Retry search</button></div>`;
  if (busy && !saved.length)
    html +=
      `<p class="status-banner" role="status">${searching ? "Searching your library…" : "Loading your finds…"}</p>` +
      skeleton();
  else if (saved.length)
    html += `<div class="section-heading"><h2>${searching ? "Search results" : "Your finds"}</h2><span class="count" role="status">${saved.length}${searching && source === "all" && feed.page?.total > saved.length ? ` of ${feed.page.total}` : ""} ${saved.length === 1 ? "find" : "finds"}</span></div><div class="library-grid ${layout === "list" ? "list" : ""}">${saved.map(card).join("")}</div>`;
  else if (!feed.error || !searching)
    html +=
      searching || source !== "all"
        ? empty(
            "No matches yet.",
            "Try another word, or clear your filters to see more finds.",
          ) +
          `<div class="load-more"><button class="text-button" data-action="reset-filters">Clear search and filters</button></div>`
        : empty(
            "A home for your finds.",
            "A photo. A lovely object. Something for later. Add your first find and make it yours.",
            true,
          );
  if (searching && feed.page?.next_offset != null)
    html += `<div class="load-more"><button class="secondary" data-action="more-search" ${busy ? "disabled" : ""}>${busy ? "Loading…" : "Load more search results"}</button></div>`;
  root.innerHTML = html;
  hydrateImages();
}
function loadSearch(append = false) {
  clearTimeout(searchTimer);
  if (!query.trim() || !account) return;
  const term = query.trim(),
    api = client();
  return searchFeed.load(
    (options) => api.searchLibrary({ query: term, limit: 40, ...options }),
    { append },
  );
}
function explore() {
  return (
    header("Explore", "Ideas shaped by what you’ve saved.") +
    searchField(
      "explore-input",
      exploreQuery,
      "Search products, styles, ideas",
      100,
    ) +
    '<div id="explore-results"></div>'
  );
}
function ideaCard(item, index) {
  const p = item.product,
    o = p.offer;
  return `<button class="idea-card" data-action="idea" data-index="${index}"><div class="idea-top">${icon("product")}<div><span class="source-line">${escape(p.category || "An idea for you")}</span><h3>${escape(p.title)}</h3></div></div>${item.reasons[0] ? `<p class="reason">${escape(item.reasons[0].text)}</p>` : ""}<div class="idea-bottom"><strong>${escape(priceText(o.price_minor, o.currency))}</strong><span>Why this? ↗</span></div><small>${o.price_minor != null && !currentOffer(item) ? "Recorded price · not a current offer<br>" : ""}${p.data_kind === "synthetic" ? "Illustrative catalog idea" : `Source: ${escape(item.catalog_citation.title || p.source_id)}`}</small></button>`;
}
function renderExploreResults() {
  const root = $("#explore-results");
  if (!root) return;
  const feed = exploreFeed;
  if (!account) {
    root.innerHTML =
      empty(
        "A little inspiration, connected.",
        "Connect your shared library to explore ideas based on your finds.",
      ) +
      '<div class="load-more"><button class="primary" data-action="account">Connect your library</button></div>';
    return;
  }
  let html = "";
  if (feed.error) {
    const missing = feed.error.code === "catalog_not_configured";
    html += `<div class="error-banner" role="alert"><span>${missing ? "The product catalog isn’t connected yet. Your saved finds are still in Library." : escape(errorMessage(feed.error))}</span><button class="text-button" data-action="retry-explore">Try again</button></div>`;
  }
  if (feed.items.length)
    html += `<div class="section-heading"><h2>${exploreQuery ? "Possibilities for you" : "Inspired by your finds"}</h2><span class="count">${feed.items.length} ${feed.items.length === 1 ? "idea" : "ideas"}</span></div><div class="explore-grid">${feed.items.map(ideaCard).join("")}</div><p class="catalog-note">Catalog records can help you explore. Prices and availability may have changed; check the source for current details.</p>`;
  else if (!feed.loading && !feed.error) {
    const [title, detail] =
      EXPLORE_EMPTY[feed.page?.status] || EXPLORE_EMPTY.no_matches;
    html += empty(title, detail, feed.page?.status === "needs_saves");
  }
  if (feed.loading)
    html +=
      '<p class="status-banner" role="status">Finding possibilities…</p>' +
      (feed.items.length ? "" : skeleton());
  if (feed.page?.next_offset != null)
    html += `<div class="load-more"><button class="secondary" data-action="more-explore" ${feed.loading ? "disabled" : ""}>Show more ideas</button></div>`;
  root.innerHTML = html;
}
function loadExplore(append = false) {
  clearTimeout(exploreTimer);
  if (!account) return;
  const term = exploreQuery.trim(),
    api = client();
  return exploreFeed.load(
    (options) => api.explore({ query: term, limit: 20, ...options }),
    { append },
  );
}
function setting(action, label, description, glyph, extra = "") {
  return `<button class="settings-row ${extra}" data-action="${action}">${icon(glyph)}<span class="row-copy"><strong>${label}</strong>${description ? `<small>${description}</small>` : ""}</span>${icon("chevron")}</button>`;
}
function preference(id, label, glyph, options) {
  return `<label class="settings-row" for="${id}">${icon(glyph)}<span class="row-copy"><strong>${label}</strong></span><select id="${id}" aria-label="${label}">${options}</select></label>`;
}
function profile() {
  return (
    header("Profile", "A space that’s yours.") +
    `<div class="profile-layout"><div><section class="profile-card">${mascot(76)}<div class="profile-name"><h2>Mynah Finds</h2><p>${account ? `Shared library · ${escape(name())}` : "Your finds, kept close."}</p></div><div class="profile-stats"><div><strong>${items.length}</strong><span>Saved finds</span></div><div><strong>${items.filter((item) => item.has_image).length}</strong><span>With images</span></div></div></section><p class="profile-note">Your shared library follows you across connected devices. Finds saved only on your iPhone stay on that iPhone.</p></div><div><section class="settings-section"><h2>Make it yours</h2><div class="settings-group">${preference(
      "appearance",
      "Appearance",
      "appearance",
      [
        ["system", "System"],
        ["light", "Light"],
        ["dark", "Dark"],
      ]
        .map(
          ([v, l]) =>
            `<option value="${v}" ${appearance === v ? "selected" : ""}>${l}</option>`,
        )
        .join(""),
    )}${preference("profile-layout", "Library layout", "grid", ["grid", "list"].map((v) => `<option value="${v}" ${layout === v ? "selected" : ""}>${v === "grid" ? "Grid" : "List"}</option>`).join(""))}${preference("profile-sort", "Sort finds", "sort", sortOptions())}</div></section><section class="settings-section"><h2>Your library</h2><div class="settings-group">${setting("account", account ? "Switch account" : "Connect your library", account ? "Use another shared library" : "Use your library’s access key", "person")}${setting("refresh", "Refresh library", "Bring your latest saves into view", "refresh")}${setting("privacy", "Your data & privacy", "", "shield")}</div></section><section class="settings-section"><h2>A little help</h2><div class="settings-group">${setting("help", "Save from other apps", "", "link")}${setting("intro", "See the introduction again", "", "play")}</div></section>${account ? `<div class="settings-group">${setting("signout", "Sign out", "Remove access from this browser session", "logout", "danger")}</div>` : ""}</div></div>${banner()}<p class="profile-footer">Mynah Finds<span>Keep what catches your eye.</span></p>`
  );
}
function applyAppearance() {
  const dark =
    appearance === "dark" ||
    (appearance === "system" &&
      matchMedia("(prefers-color-scheme: dark)").matches);
  document.documentElement.dataset.theme = dark ? "dark" : "light";
  $('meta[name="theme-color"]').content = dark ? "#101012" : "#ffffff";
}
function render() {
  document.querySelectorAll(".nav-item").forEach((button) => {
    const active = button.dataset.view === view;
    button.classList.toggle("active", active);
    active
      ? button.setAttribute("aria-current", "page")
      : button.removeAttribute("aria-current");
  });
  $("#main").innerHTML =
    view === "explore" ? explore() : view === "profile" ? profile() : library();
  if (view === "library") renderLibraryResults();
  if (view === "explore") renderExploreResults();
  document.title = `Mynah Finds — ${view[0].toUpperCase() + view.slice(1)}`;
}
function go(next, focus = true) {
  if (next === "search") next = "library";
  if (!["library", "explore", "profile"].includes(next)) return;
  view = next;
  history.replaceState(null, "", `#${view}`);
  render();
  window.scrollTo({ top: 0 });
  if (view === "explore" && !exploreFeed.page && !exploreFeed.loading)
    loadExplore();
  if (focus) $("#main").focus({ preventScroll: true });
}
async function hydrateImages() {
  const revision = connectionRevision,
    api = client();
  for (const image of document.querySelectorAll("[data-saved-image]")) {
    if (image.dataset.loading) return;
    image.dataset.loading = "true";
    const id = image.dataset.savedImage;
    if (!imageCache.has(id))
      imageCache.set(
        id,
        (async () => {
          const response = await fetch(
            new URL(`/v1/saves/${encodeURIComponent(id)}/image`, api.baseURL),
            {
              headers: { Authorization: `Bearer ${token}` },
              cache: "no-store",
              redirect: "error",
              signal: mediaController.signal,
            },
          );
          if (
            !response.ok ||
            !/^image\/(jpeg|png|webp)(;|$)/i.test(
              response.headers.get("content-type") || "",
            )
          )
            throw new Error("Image unavailable");
          const blob = await response.blob();
          const data = await new Promise((resolve, reject) => {
            const reader = new FileReader();
            reader.onload = () => resolve(reader.result);
            reader.onerror = () => reject(new Error("Image unavailable"));
            reader.readAsDataURL(blob);
          });
          if (revision !== connectionRevision)
            throw new Error("Account changed");
          return data;
        })(),
      );
    imageCache
      .get(id)
      .then((url) => {
        if (revision !== connectionRevision || !image.isConnected) return;
        image.src = url;
        image.hidden = false;
        image.nextElementSibling?.remove();
      })
      .catch(() => {
        imageCache.delete(id);
        if (image.isConnected && revision === connectionRevision) {
          image.nextElementSibling?.setAttribute(
            "title",
            "Image unavailable. Reopen this find to retry.",
          );
        }
      });
  }
}
async function refresh({ fresh = false } = {}) {
  if (fresh && refreshPromise) await refreshPromise;
  if (!token) {
    loading = false;
    render();
    return;
  }
  if (refreshPromise) return refreshPromise;
  const revision = connectionRevision,
    api = client(),
    controller = new AbortController();
  refreshController = controller;
  const promise = (async () => {
    try {
      const [identity, saves, features] = await Promise.all([
        api.me({ signal: controller.signal }),
        loadSavedLibrary(api, { signal: controller.signal }),
        api.capabilities({ signal: controller.signal }),
      ]);
      if (revision !== connectionRevision) return;
      account = identity;
      items = saves;
      capabilities = features;
      loading = false;
      loadError = "";
      if (!items.some((i) => i.source === source)) source = "all";
    } catch (error) {
      if (revision !== connectionRevision || controller.signal.aborted) return;
      loading = false;
      loadError = errorMessage(error);
      if (error.status === 401) {
        resetConnection();
        render();
      }
    }
    if (revision === connectionRevision) {
      const active = $("#search-input") === document.activeElement,
        selection = active ? $("#search-input").selectionStart : null;
      render();
      if (view === "explore" && !exploreFeed.loading) loadExplore();
      if (query.trim()) loadSearch();
      if (active) {
        $("#search-input").focus({ preventScroll: true });
        try {
          $("#search-input").setSelectionRange(selection, selection);
        } catch {}
      }
    }
  })();
  refreshPromise = promise;
  try {
    await promise;
  } finally {
    if (refreshPromise === promise) refreshPromise = null;
  }
}
function resetConnection({ preserveCaptureFor = null } = {}) {
  searchFeed.clear();
  exploreFeed.clear();
  clearTimeout(searchTimer);
  clearTimeout(exploreTimer);
  exploreQuery = "";
  capabilities = null;
  detailGeneration++;
  detailAttempts.clear();
  mediaController.abort();
  mediaController = new AbortController();
  imageCache.clear();
  document.querySelectorAll("dialog[open]").forEach((dialog) => dialog.close());
  let pending = captureAttempt;
  if (!pending) {
    try {
      pending = JSON.parse(store.get("mymah-finds-capture"));
    } catch {}
  }
  connectionRevision++;
  accountIntent++;
  refreshController?.abort();
  refreshPromise = null;
  captureAttempt = null;
  captureFlight = null;
  removeAttempt = null;
  removalAttempts.clear();
  items = [];
  account = null;
  query = "";
  source = "all";
  $("#capture-form").reset();
  $("#capture-form")
    .querySelectorAll("input,textarea,select")
    .forEach((field) => (field.disabled = false));
  store.remove("mymah-finds-capture");
  if (preserveCaptureFor && pending?.accountId === preserveCaptureFor) {
    captureAttempt = pending;
    store.set("mymah-finds-capture", JSON.stringify(pending));
  }
}
function rememberCapture(payload) {
  const fingerprint = JSON.stringify([
    location.origin,
    account?.user_id,
    payload,
  ]);
  if (!captureAttempt || captureAttempt.fingerprint !== fingerprint)
    captureAttempt = {
      fingerprint,
      payload,
      key: newMutationKey(),
      accountId: account.user_id,
    };
  store.set("mymah-finds-capture", JSON.stringify(captureAttempt));
  return captureAttempt;
}
function openCapture() {
  if (!account) {
    $("#account-dialog").showModal();
    return;
  }
  if ($("#help-dialog").open) $("#help-dialog").close();
  if (!captureAttempt) {
    try {
      const saved = JSON.parse(store.get("mymah-finds-capture"));
      if (saved?.accountId === account.user_id && saved.key)
        captureAttempt = saved;
    } catch {}
  }
  if (captureAttempt)
    for (const [key, value] of Object.entries(captureAttempt.payload)) {
      const field = $(`#capture-form [name="${key}"]`);
      if (field) field.value = value;
    }
  $("#capture-status").textContent = captureFlight
    ? "Saving to your library…"
    : captureAttempt?.expired
      ? "This earlier save was removed. Start a new save only if you want to keep this link again."
      : "";
  $("#new-save").hidden = !captureAttempt?.expired;
  $('#capture-form [type="submit"]').disabled = Boolean(
    captureAttempt?.expired || captureFlight,
  );
  $("#capture-dialog").showModal();
}
function detailTop(label) {
  return `<div class="detail-header"><div class="sheet-handle" aria-hidden="true"></div><div class="dialog-top"><span class="eyebrow">${escape(label)}</span><button class="icon-button" data-close aria-label="Close">×</button></div></div>`;
}
function detailMarkup(item) {
  const href = safeLink(item.original_url),
    analysis = item.analysis;
  return (
    detailTop(sourceLabel(item)) +
    media(item, true) +
    `<h2 id="detail-title">${escape(item.title)}</h2><p class="detail-meta">Saved ${date(item.captured_at)} · ${escape(item.has_image && !href ? "Photo" : sourceHost(item))}</p>${item.note ? `<section class="detail-note"><h3>Your note</h3><p>${escape(item.note)}</p></section>` : ""}${item.selected_text ? `<section class="detail-note"><h3>Saved text</h3><p>${escape(item.selected_text)}</p></section>` : ""}<section class="detail-note"><h3>Based on your find</h3>${analysis ? `<p>${escape(analysis.summary)}</p>${analysis.uncertainties?.length ? `<details><summary>A few things to check</summary><ul>${analysis.uncertainties.map((text) => `<li>${escape(text)}</li>`).join("")}</ul></details>` : ""}` : `<p>${item.analysis_status === "pending" ? "Your find is saved. Taking a closer look…" : item.analysis_status === "failed" ? "Your find is saved. We couldn’t finish looking at it yet." : "Your original and note are here. Add a little context to make this find yours."}</p>`}${capabilities?.features?.product_analysis ? `<button class="text-button" data-action="analyze" data-id="${escape(item.id)}">${analysis ? "Refresh ideas" : "Take a closer look"}</button>` : ""}<button class="text-button" data-action="detail-refresh" data-id="${escape(item.id)}">Refresh this find</button></section>${item.suggestions?.length ? `<section class="detail-note"><h3>What caught your eye?</h3><p>Add a little context, in your own words.</p>${item.suggestions.map((suggestion) => `<button class="intent-choice" data-action="annotate" data-id="${escape(item.id)}" data-suggestion="${escape(suggestion.id)}">${icon("plus")} ${escape(suggestion.text)}</button>`).join("")}<button class="text-button" data-action="skip-intent" data-id="${escape(item.id)}">Skip for now</button><p class="field-help">These choices save your intent. They don’t schedule reminders, monitor prices or make purchases.</p></section>` : ""}<p id="detail-status" role="status"></p>${href ? `<a class="primary wide" href="${escape(href)}" target="_blank" rel="noopener noreferrer">Open original ${icon("arrow")}</a>` : ""}<button class="text-button danger wide" data-action="remove" data-id="${escape(item.id)}">${icon("trash")} Remove from Library</button>`
  );
}
function showDetail(id) {
  const item = [...items, ...searchFeed.items].find((item) => item.id === id);
  const generation = ++detailGeneration,
    revision = connectionRevision;
  $("#detail-content").innerHTML = item
    ? detailMarkup(item)
    : detailTop("Your find") +
      '<h2 id="detail-title">Your find</h2><p role="status">Loading your find…</p>';
  if (!$("#detail-dialog").open) $("#detail-dialog").showModal();
  hydrateImages();
  client()
    .getSave(id)
    .then((updated) => {
      if (
        generation !== detailGeneration ||
        revision !== connectionRevision ||
        !$("#detail-dialog").open
      )
        return;
      items = items.map((item) => (item.id === id ? updated : item));
      searchFeed.items = searchFeed.items.map((item) =>
        item.id === id ? updated : item,
      );
      $("#detail-content").innerHTML = detailMarkup(updated);
      hydrateImages();
    })
    .catch((error) => {
      if (
        generation !== detailGeneration ||
        revision !== connectionRevision ||
        !$("#detail-dialog").open
      )
        return;
      const target = $("#detail-status");
      if (target) target.textContent = errorMessage(error);
      else
        $("#detail-content").innerHTML =
          detailTop("Your find") +
          `<h2 id="detail-title">Find unavailable</h2><p>${escape(errorMessage(error))}</p>`;
    });
}
function showIdea(index) {
  const item = exploreFeed.items[index];
  if (!item) return;
  const p = item.product,
    o = p.offer,
    c = item.catalog_citation,
    url = offerLink(item) || sourceLink(item),
    license = safeLink(c.license_url);
  $("#detail-content").innerHTML =
    detailTop("A possibility") +
    `<h2 id="detail-title">${escape(p.title)}</h2>${p.description ? `<p>${escape(p.description)}</p>` : ""}<section class="detail-note"><h3>From the catalog</h3><p><strong>${currentOffer(item) ? "Price" : "Recorded price"}: ${escape(priceText(o.price_minor, o.currency))}</strong></p><p>Merchant: ${escape(p.merchant.name || "Unknown")}<br>Availability: ${o.availability === "in_stock" ? (currentOffer(item) ? "Reported in stock" : "Previously listed in stock") : o.availability === "out_of_stock" ? "Reported out of stock" : "Unknown"}</p>${o.shipping_minor != null ? `<p>Shipping: ${escape(priceText(o.shipping_minor, o.currency))}</p>` : ""}${!currentOffer(item) ? "<p>This is a source record, not a verified current offer. Confirm details with the seller.</p>" : ""}${url ? `<a class="text-button" data-offer-index="${index}" href="${escape(url)}" target="_blank" rel="noopener noreferrer">${offerLink(item) ? "View offer" : "View source record"} ↗</a>` : ""}</section><section class="detail-note"><h3>Why this?</h3>${item.reasons.map((reason) => `<p>${escape(reason.text)}</p>${reason.saved_item_id ? `<button class="text-button" data-action="detail" data-id="${escape(reason.saved_item_id)}">${icon("bookmark")} ${escape(reason.saved_item_title || "View saved evidence")}</button>` : ""}${reason.catalog_field ? `<p class="field-help">Catalog: ${escape(reason.catalog_field.replaceAll("_", " "))} · ${escape(reason.catalog_value || "")}</p>` : ""}`).join("")}</section><section class="detail-note"><h3>Source</h3><p>${escape(c.title)}</p><p>${escape(c.attribution || c.source_id)}</p>${c.license_id ? `<p>${escape(c.license_id)}</p>` : ""}${license ? `<a href="${escape(license)}" target="_blank" rel="noopener noreferrer">Source license ↗</a>` : ""}</section>`;
  detailGeneration++;
  if (!$("#detail-dialog").open) $("#detail-dialog").showModal();
}
async function mutateDetail(button, action) {
  const id = button.dataset.id,
    revision = connectionRevision,
    generation = detailGeneration,
    api = client();
  const payload =
    action === "analyze"
      ? null
      : action === "skip-intent"
        ? { action: "skip" }
        : { action: "select", suggestion_id: button.dataset.suggestion };
  const fingerprint = JSON.stringify([action, payload]);
  const prior = detailAttempts.get(id);
  if (prior && prior.fingerprint !== fingerprint) {
    $("#detail-status").textContent =
      "An earlier choice could not be confirmed. Retry that choice before changing it.";
    return;
  }
  const attempt = prior || { fingerprint, key: newMutationKey() };
  detailAttempts.set(id, attempt);
  $("#detail-content")
    .querySelectorAll("button[data-action]")
    .forEach((button) => (button.disabled = true));
  $("#detail-status").textContent =
    action === "analyze" ? "Taking a closer look…" : "Saving your intent…";
  try {
    if (action === "analyze")
      await api.analyzeSave(id, { idempotencyKey: attempt.key });
    else await api.respond(id, payload, { idempotencyKey: attempt.key });
    if (revision !== connectionRevision) return;
    detailAttempts.delete(id);
    exploreFeed.clear();
    if (generation === detailGeneration && $("#detail-dialog").open) {
      showDetail(id);
      toast(
        action === "analyze"
          ? "Analysis requested. Refresh this find in a moment."
          : "Intent saved.",
      );
    }
  } catch (error) {
    if (revision !== connectionRevision || generation !== detailGeneration)
      return;
    if ([400, 404, 410, 422].includes(error.status)) detailAttempts.delete(id);
    if ($("#detail-status"))
      $("#detail-status").textContent = errorMessage(error);
  } finally {
    if (revision === connectionRevision && generation === detailGeneration)
      $("#detail-content")
        .querySelectorAll("button[data-action]")
        .forEach((button) => (button.disabled = false));
  }
}
function showInfo(type) {
  const intro = type === "intro";
  $("#info-content").innerHTML =
    detailTop(intro ? "Welcome to Mynah Finds" : "Your data") +
    (intro
      ? `<div class="intro-mark">${mascot(112)}</div><h2 id="info-title">A home for every little find.</h2><p>The links you love, collected in one calm place. Welcome to Mynah Finds.</p><div class="info-step"><h3>Keep the why.</h3><p>Save a link or photo and add a note about what caught your eye.</p></div><div class="info-step"><h3>Find your next possibility.</h3><p>Return to your Library, or Explore ideas with reasons tied to what you saved.</p></div><button class="primary wide" data-close>Make yourself at home</button>`
      : `<h2 id="info-title">Your data & privacy</h2><div class="info-step"><h3>Your shared library</h3><p>Finds saved here go to the connected server. Using the same shared account on iOS lets both apps access that library. Local-only iPhone finds are not automatically uploaded.</p></div><div class="info-step"><h3>Photos & analysis</h3><p>You choose which photo to upload. Content you save may be processed by the AI provider configured on your server to suggest context and understand products.</p></div><div class="info-step"><h3>This browser</h3><p>Your access key is kept in this browser session. Appearance, layout and sorting preferences are saved on this device. Sign out to remove access from this session.</p></div><div class="info-step"><h3>You’re in control</h3><p>Removing a shared find affects that account on all connected devices. Opening an original link or a catalog source takes you to a website with its own privacy practices.</p></div>`);
  $("#info-dialog").showModal();
}
async function captureImage() {
  const file = $("#capture-image").files[0];
  if (!file) return captureAttempt?.payload?.image_data_url || undefined;
  validateImage(file);
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => resolve(reader.result);
    reader.onerror = () =>
      reject(new Error("Couldn’t read that photo. Choose it again."));
    reader.readAsDataURL(file);
  });
}
document.addEventListener("click", async (event) => {
  const offer = event.target.closest("[data-offer-index]");
  if (offer) {
    const item = exploreFeed.items[Number(offer.dataset.offerIndex)];
    const link = item && (offerLink(item) || sourceLink(item));
    if (!link) {
      event.preventDefault();
      toast("This source is no longer available. Refresh Explore.");
      return;
    }
    offer.href = link;
  }
  const close = event.target.closest("[data-close]");
  if (close) {
    close.closest("dialog").close();
    return;
  }
  const nav = event.target.closest("[data-view]");
  if (nav) {
    go(nav.dataset.view);
    return;
  }
  const filter = event.target.closest("[data-source]");
  if (filter) {
    source = filter.dataset.source;
    render();
    return;
  }
  const layoutButton = event.target.closest("[data-layout]");
  if (layoutButton) {
    layout = layoutButton.dataset.layout;
    prefs.set("layout", layout);
    render();
    return;
  }
  const button = event.target.closest("[data-action]");
  if (!button) return;
  const action = button.dataset.action;
  if (action === "add") return openCapture();
  if (action === "new-save") {
    if (captureFlight) return;
    captureAttempt = null;
    store.remove("mymah-finds-capture");
    $("#new-save").hidden = true;
    $("#capture-status").textContent =
      "Review the details, then save this link again.";
    $('#capture-form [type="submit"]').disabled = false;
    return;
  }
  if (action === "account") return $("#account-dialog").showModal();
  if (action === "help") return $("#help-dialog").showModal();
  if (action === "detail" || action === "detail-refresh")
    return showDetail(button.dataset.id);
  if (action === "idea") return showIdea(Number(button.dataset.index));
  if (["annotate", "skip-intent", "analyze"].includes(action))
    return mutateDetail(button, action);
  if (action === "intro" || action === "privacy") return showInfo(action);
  if (action === "retry-search" || action === "more-search")
    return loadSearch(action === "more-search");
  if (action === "retry-explore" || action === "more-explore")
    return loadExplore(action === "more-explore");
  if (action === "reset-filters") {
    query = "";
    source = "all";
    searchFeed.clear();
    render();
    return;
  }
  if (action === "clear-search") {
    const input = $(`#${button.dataset.field}`);
    input.value = "";
    input.dispatchEvent(new Event("input", { bubbles: true }));
    input.focus();
    return;
  }
  if (action === "remove") {
    const id = button.dataset.id;
    if (!removalAttempts.has(id))
      removalAttempts.set(id, { id, key: newMutationKey() });
    removeAttempt = removalAttempts.get(id);
    $("#detail-dialog").close();
    $("#confirm-status").textContent = "";
    $("#confirm-dialog").showModal();
    return;
  }
  if (action === "signout") {
    resetConnection();
    token = "";
    store.set("mymah-finds-token", "");
    store.remove("common-thread-token");
    loadError = "";
    loading = false;
    render();
    toast("Signed out. Your saved finds are still in your library.");
    return;
  }
  if (action === "refresh") {
    button.disabled = true;
    await refresh();
    button.disabled = false;
    if (!loadError) toast("Your library is up to date.");
  }
});
document.addEventListener("input", (event) => {
  const input = event.target;
  if (input.id === "search-input") {
    query = input.value;
    searchFeed.clear();
    clearTimeout(searchTimer);
    if (query.trim() && account) searchFeed.loading = true;
    renderLibraryResults();
    if (query.trim() && account)
      searchTimer = setTimeout(() => loadSearch(), 300);
  }
  if (input.id === "explore-input") {
    exploreQuery = input.value;
    exploreFeed.clear();
    exploreFeed.loading = Boolean(account);
    clearTimeout(exploreTimer);
    exploreTimer = setTimeout(() => loadExplore(), 300);
    renderExploreResults();
  }
  if (input.matches(".search-field input"))
    input.parentElement.querySelector("button").hidden = !input.value;
});
document.addEventListener("change", (event) => {
  const { id, value } = event.target;
  if (id === "sort" || id === "profile-sort") {
    sort = value;
    prefs.set("sort", value);
    render();
  }
  if (id === "profile-layout") {
    layout = value;
    prefs.set("layout", value);
    render();
  }
  if (id === "appearance") {
    appearance = value;
    prefs.set("appearance", value);
    applyAppearance();
    toast("Appearance saved.");
  }
});
document.addEventListener("submit", async (event) => {
  event.preventDefault();
  const form = event.target;
  if (form.id === "capture-form" && (captureFlight || captureAttempt?.expired))
    return;
  const data = Object.fromEntries(new FormData(form)),
    submit = form.querySelector('[type="submit"]'),
    deletion = removeAttempt;
  const revision = connectionRevision,
    intent = form.id === "account-form" ? ++accountIntent : null;
  const flight = form.id === "capture-form" ? { revision } : null;
  if (flight) captureFlight = flight;
  if (submit) submit.disabled = true;
  if (form.id === "capture-form")
    form
      .querySelectorAll("input,textarea,select")
      .forEach((field) => (field.disabled = true));
  try {
    if (form.id === "capture-form") {
      if (!account) throw new Error("Connect your library before saving.");
      const image = await captureImage();
      if (revision !== connectionRevision) return;
      const payload = {
        ...data,
        client: "web",
        ...(image ? { image_data_url: image } : {}),
      };
      payload.url = payload.url.trim();
      if (!payload.url) delete payload.url;
      if (!payload.url && !image)
        throw new Error("Add a link or a photo to save your find.");
      if (payload.source === "web" && payload.url) {
        const host = new URL(payload.url).hostname;
        if (/(^|\.)pinterest\./.test(host)) payload.source = "pinterest";
        else if (/(^|\.)instagram\.com$/.test(host))
          payload.source = "instagram";
      }
      const attempt = rememberCapture(payload);
      $("#capture-status").textContent = "Saving to your library…";
      const saved = await client().capture(attempt.payload, {
        idempotencyKey: attempt.key,
      });
      if (revision !== connectionRevision) return;
      captureAttempt = null;
      store.remove("mymah-finds-capture");
      form.reset();
      $("#capture-dialog").close();
      await refresh({ fresh: true });
      if (revision !== connectionRevision) return;
      query = "";
      source = "all";
      searchFeed.clear();
      exploreFeed.clear();
      go("library", false);
      toast(
        saved.duplicate
          ? "Already in your library. Its existing note and details were kept."
          : "Saved to your library.",
      );
    } else if (form.id === "account-form") {
      const provided = data.token.trim(),
        api = new CommonThreadClient({
          baseURL: location.origin,
          token: provided,
        });
      const identity = await api.me();
      if (revision !== connectionRevision || intent !== accountIntent) return;
      resetConnection({ preserveCaptureFor: identity.user_id });
      token = provided;
      store.set("mymah-finds-token", token);
      store.remove("common-thread-token");
      loadError = "";
      loading = true;
      $("#account-dialog").close();
      form.reset();
      go("library", false);
      await refresh();
    } else if (form.id === "confirm-form" && deletion) {
      await client().deleteSave(deletion.id, { idempotencyKey: deletion.key });
      if (revision !== connectionRevision) return;
      removalAttempts.delete(deletion.id);
      if (removeAttempt === deletion) {
        removeAttempt = null;
        $("#confirm-dialog").close();
      }
      await refresh({ fresh: true });
      if (revision !== connectionRevision) return;
      toast("Removed from your library.");
    }
  } catch (error) {
    if (
      revision !== connectionRevision ||
      (intent !== null && intent !== accountIntent)
    )
      return;
    const message = errorMessage(error);
    if (form.id === "capture-form") {
      $("#capture-status").textContent = message;
      if (error.status === 410 && captureAttempt) {
        captureAttempt.expired = true;
        store.set("mymah-finds-capture", JSON.stringify(captureAttempt));
        $("#new-save").hidden = false;
      }
    } else if (form.id === "account-form")
      $("#account-status").textContent = message;
    else if (form.id === "confirm-form")
      $("#confirm-status").textContent = message;
    else toast(message);
  } finally {
    if (flight && captureFlight === flight) {
      captureFlight = null;
      form
        .querySelectorAll("input,textarea,select")
        .forEach((field) => (field.disabled = false));
      if (submit) submit.disabled = Boolean(captureAttempt?.expired);
    }
    if (submit && !flight) submit.disabled = false;
  }
});
$("#account-dialog").addEventListener("close", () => {
  accountIntent++;
  $("#account-status").textContent = "";
});
window.addEventListener("hashchange", () => go(location.hash.slice(1), false));
document.addEventListener("keydown", (event) => {
  if (
    (event.metaKey || event.ctrlKey) &&
    event.key.toLowerCase() === "k" &&
    !document.querySelector("dialog[open]")
  ) {
    event.preventDefault();
    go("library");
    $("#search-input").focus();
  }
});
document.addEventListener("visibilitychange", () => {
  if (!document.hidden && !document.querySelector("dialog[open]")) refresh();
});
function syncViewport() {
  const viewport = window.visualViewport;
  if (viewport && viewport.scale === 1) {
    document.documentElement.style.setProperty(
      "--visual-height",
      `${viewport.height}px`,
    );
    document.documentElement.style.setProperty(
      "--keyboard-inset",
      `${Math.max(0, window.innerHeight - viewport.height - viewport.offsetTop)}px`,
    );
  }
}
window.visualViewport?.addEventListener("resize", syncViewport);
window.visualViewport?.addEventListener("scroll", syncViewport);
syncViewport();
$("#detail-dialog").addEventListener("close", () => {
  detailGeneration++;
});
matchMedia("(prefers-color-scheme: dark)").addEventListener(
  "change",
  applyAppearance,
);
applyAppearance();
render();
await refresh();
