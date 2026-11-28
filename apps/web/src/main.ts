import './styles.css';
import { api, resolveApiBase, setApiBaseOverride, getApiBaseOverride, enrollDevice, validateCustomServer } from './api';
import type { RecipeInput, ImportFormat } from './api';
import { Store, visible, type SyncEnvelope } from './store';
import {
  acceptInvite,
  ensureE2EIdentity,
  inviteBundleJson,
  loadActive,
  loadMetadata,
  parseInviteBundle,
  resetPullCursor,
  type E2EMetadata,
  type InviteBundle,
} from './e2e';
import { pushOutbox, syncE2E, type PushTransport } from './sync';
import { parsePath, href, navigate, initRouter } from './router';
import { scaleQuantity, formatQuantity } from './scale';
import { aggregateWeekToList, collectPlanIngredients, scaleIngredientsForServings } from './aggregate';
import { sortedRows, toggleItemChecked, shopRowHtml } from './lists';
import { safeHttpUrl, ingredientLabel, recipePhotoKey, formatMinutes, clampMinutes, clampServings, ingredientsToText, textToIngredients, stepsToText, textToSteps, nutritionRows, editorPhotos } from './display';
import { firstNonEmptyLine, parsePastedText, previewToRecipeInput, recipeToPreviewFields } from './ingest';

const store = new Store();
const root = document.getElementById('app')!;

/** Active cook-mode countdown; cleared before starting another timer so two
 *  timers never write to the same #timer element. */
let activeTimer: number | undefined;

/** Selected shopping list; defaults to the most recent list. */
let selectedListId: string | null = null;

/** Plan entry being edited (null = the plan form creates a new entry). */
let editingPlanId: string | null = null;

/** Pantry item being edited (null = the pantry form creates a new item). */
let editingPantryId: string | null = null;

/** Shopping-list item (original index) with its quantity/aisle editor open. */
let editingItemIdx: number | null = null;

/** Nutrition panel open state; viewRecipeDetail re-renders on every ingredient
 *  or step edit, so the user's collapse choice lives here (default expanded). */
let nutritionOpen = true;

/** Live transport: every entity maps to its real contract CRUD endpoint. */
const webTransport: PushTransport = {
  update: (entity, id, input) => {
    switch (entity) {
      case 'recipe': return api.updateRecipe(id, input as unknown as RecipeInput);
      case 'list': return api.updateList(id, input as { name: string });
      case 'pantryItem': return api.updatePantryItem(id, input as { name: string });
      case 'plan': return api.updatePlan(id, input as { date: string; meal: string });
      case 'menu': return api.updateMenu(id, input as { name: string });
    }
  },
  create: (entity, input) => {
    switch (entity) {
      case 'recipe': return api.createRecipe(input as unknown as RecipeInput);
      case 'list': return api.createList(input as { name: string });
      case 'pantryItem': return api.createPantryItem(input as { name: string });
      case 'plan': return api.createPlan(input as { date: string; meal: string });
      case 'menu': return api.createMenu(input as { name: string });
    }
  },
  remove: (entity, id) => {
    switch (entity) {
      case 'recipe': return api.deleteRecipe(id);
      case 'list': return api.deleteList(id);
      case 'pantryItem': return api.deletePantryItem(id);
      case 'plan': return api.deletePlan(id);
      case 'menu': return api.deleteMenu(id);
    }
  },
  list: (entity) => {
    switch (entity) {
      case 'recipe': return api.listRecipes();
      case 'list': return api.listLists();
      case 'pantryItem': return api.listPantry();
      case 'plan': return api.listPlans();
      case 'menu': return api.listMenus();
    }
  },
};

// ---- Settings → Sync UI state (survives render() rebuilds) ----

let syncStatus = '';
let syncingNow = false;
let inviteCode: string | null = null;
let joinResult = '';
let pendingJoin: InviteBundle | null = null;
let joiningCode = false;
let advancedOpen = false;
let healthResult = '';
let hintHealth = '';
let pendingHint: string | null = null;

type ActiveCredential = { metadata: E2EMetadata; syncCode: string };

// Identity creation is shared: concurrent callers (warm-up, Sync now,
// Connect) join the same in-flight creation instead of minting competing
// identities, only one of which would survive.
let identityInflight: Promise<ActiveCredential | null> | null = null;
function getIdentity(household: string): Promise<ActiveCredential | null> {
  identityInflight ??= ensureE2EIdentity(household).finally(() => {
    identityInflight = null;
  });
  return identityInflight;
}

const NAV: [string, string][] = [
  ['/', 'Home'],
  ['/recipes', 'Library'],
  ['/plan', 'Plan'],
  ['/lists', 'Shop'],
  ['/menus', 'Menus'],
  ['/ingest', 'Ingest'],
  ['/settings', 'Settings'],
];

function shell(view: string): void {
  const route = parsePath(location.pathname);
  const here = location.pathname;
  const nav = NAV.map(([p, label]) => {
    const active = (p === '/' && route.name === 'home') || href(p) === here;
    return `<a href="${href(p)}"${active ? ' aria-current="page"' : ''}>${label}</a>`;
  }).join('');
  root.innerHTML = `<header class="topbar"><a class="brand" href="${href('/')}">Keep Cooking</a><nav aria-label="Primary">${nav}</nav></header><div class="view">${view}</div>`;
}

function esc(s: unknown): string {
  return String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]!));
}

function recipeTitle(id: string): string {
  const r = store.state.recipes.find((e) => e.id === id);
  const p = r?.payload as { title?: string } | undefined;
  return p?.title ?? id.slice(0, 8);
}

/** Signed-URL cache: one GET /photos/sign per R2 key per page lifetime.
 *  Absolute http(s) values bypass signing (forward-compat with direct URLs). */
const photoUrlCache = new Map<string, string>();

function photoUrlFor(key: string): Promise<string | null> {
  const cached = photoUrlCache.get(key);
  if (cached) return Promise.resolve(cached);
  const direct = safeHttpUrl(key);
  if (direct) {
    photoUrlCache.set(key, direct);
    return Promise.resolve(direct);
  }
  return api.photoSign(key).then(
    (signed) => {
      photoUrlCache.set(key, signed.url);
      return signed.url;
    },
    () => null,
  );
}

/** Fill every `img[data-photo-key]` in scope: signed R2 URLs load lazily.
 *  The image stays hidden until its bytes actually load; missing objects
 *  (unsigned R2, offline, unconfigured photo serving) remove the `img`
 *  instead of showing a broken icon. List rows keep a styled initial tile
 *  as fallback; hero images collapse their wrapper. */
function hydrateRecipePhotos(scope: ParentNode = document): void {
  for (const node of scope.querySelectorAll('img[data-photo-key]')) {
    const img = node as HTMLImageElement;
    if (img.dataset.hydrated || img.hasAttribute('src')) continue;
    img.dataset.hydrated = '1';
    const key = img.dataset.photoKey ?? '';
    if (!key) {
      img.remove();
      continue;
    }
    void photoUrlFor(key).then((url) => {
      if (!url || !img.isConnected) {
        if (!url) dropRecipePhoto(img);
        return;
      }
      img.addEventListener('load', () => {
        img.hidden = false;
        img.closest('li')?.querySelector('.recipe-thumb--fallback')?.remove();
      }, { once: true });
      img.addEventListener('error', () => dropRecipePhoto(img), { once: true });
      img.src = url;
    });
  }
}

/** Remove a photo that failed to resolve: the list-row fallback tile (if
 *  any) stays; hero images collapse their wrapping paragraph. */
function dropRecipePhoto(img: HTMLImageElement): void {
  if (img.classList.contains('recipe-hero')) {
    img.closest('p')?.remove();
  }
  img.remove();
}

/** Default recipe tile (parity with the iOS list placeholder): a fork-and-knife
 *  glyph in accent orange on a light-orange rounded tile. Rendered under
 *  list-row photos and kept when the photo bytes are missing; removed once
 *  the real image loads. Inline SVG (lucide-style utensils strokes) since
 *  the web has no SF Symbols. */
function fallbackThumb(): string {
  return `<span class="recipe-thumb recipe-thumb--fallback" aria-hidden="true"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M3 2v7c0 1.1.9 2 2 2h4a2 2 0 0 0 2-2V2"/><path d="M7 2v20"/><path d="M21 15V2a5 5 0 0 0-5 5v6c0 1.1.9 2 2 2h3Zm0 0v7"/></svg></span>`;
}

/** Number field helper: blank/invalid -> undefined (field left unset). */
function numVal(v: FormDataEntryValue | null): number | undefined {
  const s = String(v ?? '').trim();
  if (!s) return undefined;
  const n = Number(s);
  return Number.isFinite(n) ? n : undefined;
}

/** Re-read a record's latest payload and upsert a patch (keeps the same id). */
function patchPayload(entity: 'recipe' | 'list' | 'pantryItem' | 'plan' | 'menu', id: string, patch: Record<string, unknown>): void {
  const key = store.collectionKey(entity);
  const env = (store.state[key] as SyncEnvelope[]).find((e) => e.id === id);
  const base = (env?.payload ?? {}) as Record<string, unknown>;
  store.upsert(entity, id, { ...base, ...patch });
}

function render(): void {
  const route = parsePath(location.pathname);
  switch (route.name) {
    case 'recipes': return viewLibrary('');
    case 'recipeNew': return viewRecipeEditor(null);
    case 'recipeDetail': return viewRecipeDetail(route.params.id);
    case 'recipeEdit': return viewRecipeEditor(route.params.id);
    case 'cook': return viewCook(route.params.id);
    case 'plan': return viewPlan();
    case 'lists': return viewLists();
    case 'menus': return viewMenus();
    case 'ingest': return viewIngest();
    case 'settings': return viewSettings();
    default: return viewHome();
  }
}

// ---- Home ----
function viewHome(): void {
  const recipes = visible(store.state.recipes).slice(0, 5);
  shell(`<h1>Keep Cooking</h1>
  <p>Offline-first recipes, planning, shopping and pantry. Your data lives on this device; sync when online.</p>
  <h2>Recent recipes</h2>
  <ul class="cards">${recipes.map((r) => {
    const p = r.payload as { title?: string } & Record<string, unknown>;
    const title = p.title ?? r.id;
    const key = recipePhotoKey(p, 'thumb');
    const thumb = key ? `<img class="recipe-thumb" data-photo-key="${esc(key)}" alt="" loading="lazy" hidden />` : '';
    return `<li class="recipe-card">${fallbackThumb()}${thumb}<a href="${href('/recipes/' + r.id)}">${esc(title)}</a></li>`;
  }).join('') || '<li>No recipes yet.</li>'}</ul>
  <p><a href="${href('/ingest')}">Clip a recipe</a> · <a href="${href('/plan')}">Plan the week</a></p>`);
  hydrateRecipePhotos();
}

// ---- Library ----
function libraryResultsHtml(query: string): string {
  const all = visible(store.state.recipes);
  const q = query.toLowerCase();
  const list = all.filter((r) => {
    const p = r.payload as { title?: string; description?: string };
    return !q || (p.title ?? '').toLowerCase().includes(q) || (p.description ?? '').toLowerCase().includes(q);
  });
  return list.map((r) => {
    const p = r.payload as { title?: string; servings?: number } & Record<string, unknown>;
    const title = p.title ?? r.id;
    const key = recipePhotoKey(p, 'thumb');
    const thumb = key ? `<img class="recipe-thumb" data-photo-key="${esc(key)}" alt="" loading="lazy" hidden />` : '';
    return `<li class="recipe-card">${fallbackThumb()}${thumb}<span><a href="${href('/recipes/' + r.id)}">${esc(title)}</a> <span class="muted">serves ${esc(p.servings ?? 4)}</span> <a href="${href('/cook/' + r.id)}">Cook</a></span></li>`;
  }).join('') || '<li>No matches.</li>';
}

function viewLibrary(q: string): void {
  shell(`<h1>Library</h1>
  <p><a href="${href('/recipes/new')}">New recipe</a></p>
  <form id="search" role="search"><label for="q">Search recipes</label>
  <input id="q" name="q" type="search" value="${esc(q)}" placeholder="Search title or description" /></form>
  <ul class="cards" id="results" aria-live="polite">${libraryResultsHtml(q)}</ul>`);
  const form = document.getElementById('search') as HTMLFormElement;
  const input = document.getElementById('q') as HTMLInputElement;
  // Update only the results list so the input keeps focus, value and caret.
  input.addEventListener('input', () => {
    document.getElementById('results')!.innerHTML = libraryResultsHtml(input.value);
    hydrateRecipePhotos();
  });
  form.addEventListener('submit', (e) => e.preventDefault());
  hydrateRecipePhotos();
}

interface RecipeFormPayload {
  title?: string; description?: string; servings?: number;
  prepMinutes?: number | null; cookMinutes?: number | null; rating?: number | null;
  isFavorite?: boolean; source?: string; sourceUrl?: string; categories?: string[];
  difficulty?: string; photos?: unknown; photo?: unknown; photoUrl?: unknown; imageUrl?: unknown;
  photoKeys?: { original?: string; large1024?: string; thumb?: string };
  cookbooks?: string[]; totalMinutes?: number | null;
  notes?: string; nutritionText?: string;
}

// ---- Recipe editor (sheet) — all metadata editing lives here; the detail
// view is read-only. Used for both "new" (editId null) and "edit" modes.
// (Photo/count/line helpers live in display.ts for unit testing.)

function editorDomain(p: { source?: string; sourceUrl?: string }): string {
  const safe = safeHttpUrl(p.sourceUrl);
  if (safe) {
    try {
      return new URL(safe).hostname;
    } catch {
      return safe;
    }
  }
  return p.source || '';
}


function viewRecipeEditor(editId: string | null): void {
  const existing = editId ? store.state.recipes.find((e) => e.id === editId && !e.deleted) : undefined;
  if (editId && !existing) {
    shell(`<h1>Not found</h1><p>This recipe is gone. <a href="${href('/recipes')}">Back to Library</a></p>`);
    return;
  }
  const p = (existing?.payload ?? {}) as RecipeFormPayload & Record<string, unknown>;
  const savedCats = Array.isArray(p.categories) ? (p.categories as string[]).join(', ') : '';
  const savedDifficulty = typeof p.difficulty === 'string' ? p.difficulty : '';
  const savedCookbookList = Array.isArray(p.cookbooks) ? [...(p.cookbooks as string[])] : [];
  const savedCookbook = savedCookbookList[0] ?? '';
  const photos = editorPhotos(p);
  const domain = editorDomain(p);
  const srcLink = safeHttpUrl(p.sourceUrl);
  let rating = typeof p.rating === 'number' && Number.isFinite(p.rating) ? Math.min(5, Math.max(0, p.rating)) : 0;
  let servings = typeof p.servings === 'number' && Number.isFinite(p.servings) ? p.servings : 4;
  let fav = p.isFavorite === true;
  const prevIngredients = [...((p.ingredients as RecipeIngredient[] | undefined) ?? [])]
    .sort((a, b) => (a.position ?? 0) - (b.position ?? 0));
  const prevSteps = [...((p.steps as RecipeStep[] | undefined) ?? [])]
    .sort((a, b) => (a.position ?? 0) - (b.position ?? 0));
  const prepInit = typeof p.prepMinutes === 'number' && Number.isFinite(p.prepMinutes) ? p.prepMinutes : null;
  const cookInit = typeof p.cookMinutes === 'number' && Number.isFinite(p.cookMinutes) ? p.cookMinutes : null;
  const storedTotal = typeof p.totalMinutes === 'number' && Number.isFinite(p.totalMinutes) ? p.totalMinutes : null;
  // Total defaults to the derived prep+cook when the model has no explicit
  // totalMinutes; a single known side counts (missing side is zero).
  const totalInit = storedTotal ?? (prepInit != null || cookInit != null ? (prepInit ?? 0) + (cookInit ?? 0) : null);
  const nutritionInit = typeof p.nutritionText === 'string' ? p.nutritionText : '';
  let nutritionMode: 'text' | 'table' = 'text';

  const DIFF_OPTS = ['', 'Easy', 'Medium', 'Hard'];
  const diffOpts = DIFF_OPTS.includes(savedDifficulty) ? DIFF_OPTS : [...DIFF_OPTS, savedDifficulty];
  const diffLabel = (v: string): string => (v === '' ? 'Not set' : v);

  const starsHtml = (r: number): string =>
    [1, 2, 3, 4, 5].map((i) =>
      `<button type="button" class="star${i <= Math.round(r) ? ' on' : ''}" data-star="${i}" aria-label="Rate ${i} of 5" aria-pressed="${i <= Math.round(r)}">★</button>`).join('');

  const sectionHead = (id: string, icon: string, label: string): string =>
    `<button type="button" id="${id}-toggle" class="sheet-section" aria-expanded="true" aria-controls="${id}"><span><span class="sheet-secicon" aria-hidden="true">${icon}</span> ${label}</span><span class="chev" aria-hidden="true">⌃</span></button>`;

  shell(`<div class="sheet" aria-label="${existing ? 'Edit recipe' : 'New recipe'}">
  <header class="sheet-head">
    <button type="button" id="ed-cancel" class="sheet-x" aria-label="Cancel editing">✕</button>
    <h1 class="sheet-heading">${existing ? 'Edit Recipe' : 'New Recipe'}</h1>
    <button type="button" id="ed-save" class="sheet-check" aria-label="Save recipe">✓</button>
  </header>
  ${sectionHead('ed-info', 'ⓘ', 'Info')}
  <section id="ed-info" class="sheet-card" aria-label="Recipe info">
    <label class="sheet-title-label"><span class="sr">Title</span>
      <input id="ed-title" value="${esc(p.title ?? '')}" placeholder="Recipe title" required maxlength="200" /></label>
    <div class="sheet-row" aria-label="Photos">
      <div class="sheet-row-text"><span class="sheet-label">Photos</span>
        <span class="muted">${esc(photos.count)} photo${photos.count === 1 ? '' : 's'}</span></div>
      ${photos.key
        // Eager (not lazy): hydrate unhides on load, and a lazy+hidden img
        // would never intersect to trigger its own load (deadlock).
        ? `<img class="sheet-thumb" data-photo-key="${esc(photos.key)}" alt="" hidden />`
        : photos.legacyUrl
          ? `<img class="sheet-thumb" src="${esc(photos.legacyUrl)}" alt="" loading="lazy" />`
          : `<span class="sheet-thumb sheet-thumb-empty" aria-hidden="true">📷</span>`}
    </div>
    <div class="sheet-row" aria-label="Rating">
      <span class="sheet-label">Rating</span>
      <div class="stars" role="group" aria-label="Rating (0 to 5 stars)">${starsHtml(rating)}</div>
    </div>
    <div class="sheet-row" aria-label="Favorite">
      <span class="sheet-label">★ Favorite</span>
      <button type="button" id="ed-fav" class="sheet-fav" aria-pressed="${fav}" aria-label="Toggle favorite">${fav ? '★' : '☆'}</button>
    </div>
    <div class="sheet-row" aria-label="Servings">
      <label class="sheet-label" for="ed-servings">Servings</label>
      <div class="stepper">
        <button type="button" id="ed-serv-dec" aria-label="Fewer servings">−</button>
        <input id="ed-servings" type="number" min="0.25" max="100" step="0.25" value="${esc(servings)}" />
        <button type="button" id="ed-serv-inc" aria-label="More servings">+</button>
      </div>
    </div>
    <div class="sheet-row sheet-col" aria-label="Source">
      <div class="sheet-rowline">
        <span class="sheet-label">${esc(domain || 'Source')}</span>
        ${srcLink ? `<a class="sheet-linkicon" href="${esc(srcLink)}" aria-label="Open source link">🔗</a>` : `<span class="sheet-linkicon" aria-hidden="true">🔗</span>`}
      </div>
      <label class="sheet-sublabel">Source name <input id="ed-source" value="${esc(p.source ?? '')}" placeholder="e.g. bettycrocker.com" /></label>
      <label class="sheet-sublabel">Source URL <input id="ed-sourceurl" type="url" value="${esc(p.sourceUrl ?? '')}" placeholder="https://…" inputmode="url" /></label>
    </div>
    <div class="sheet-row" aria-label="Difficulty">
      <label class="sheet-label" for="ed-difficulty">Difficulty</label>
      <select id="ed-difficulty">${diffOpts.map((o) => `<option value="${esc(o)}"${o === savedDifficulty ? ' selected' : ''}>${esc(diffLabel(o))}</option>`).join('')}</select>
    </div>
    <div class="sheet-row sheet-row-last" aria-label="Categories">
      <label class="sheet-label" for="ed-cats">🗂 Categories</label>
      <input id="ed-cats" value="${esc(savedCats)}" placeholder="Uncategorized" />
    </div>
    <div class="sheet-row sheet-row-last" aria-label="Cookbook">
      <label class="sheet-label" for="ed-cookbook">📕 Cookbook</label>
      <input id="ed-cookbook" value="${esc(savedCookbook)}" placeholder="My Cookbook" />
    </div>
  </section>
  ${sectionHead('ed-times', '◔', 'Times')}
  <section id="ed-times" class="sheet-card" aria-label="Times">
    <div class="sheet-row" aria-label="Prep time">
      <span class="sheet-label">🍴 Prep Time</span>
      <span class="sheet-timeval"><span id="ed-prep-fmt" class="sheet-timefmt">${esc(prepInit != null ? formatMinutes(prepInit) : '')}</span>
      <input id="ed-prep" type="number" min="0" step="1" value="${esc(prepInit ?? '')}" placeholder="—" aria-label="Prep time in minutes" /><span aria-hidden="true">🕐</span></span>
    </div>
    <div class="sheet-row" aria-label="Cook time">
      <span class="sheet-label">🔥 Cook Time</span>
      <span class="sheet-timeval"><span id="ed-cook-fmt" class="sheet-timefmt">${esc(cookInit != null ? formatMinutes(cookInit) : '')}</span>
      <input id="ed-cook" type="number" min="0" step="1" value="${esc(cookInit ?? '')}" placeholder="—" aria-label="Cook time in minutes" /><span aria-hidden="true">🕐</span></span>
    </div>
    <div class="sheet-row sheet-row-last" aria-label="Total time">
      <span class="sheet-label">⏱ Total Time</span>
      <span class="sheet-timeval"><span id="ed-total-fmt" class="sheet-timefmt">${esc(totalInit != null ? formatMinutes(totalInit) : '')}</span>
      <input id="ed-total" type="number" min="0" step="1" value="${esc(totalInit ?? '')}" placeholder="—" aria-label="Total time in minutes" /><span aria-hidden="true">🕐</span></span>
    </div>
  </section>
  ${sectionHead('ed-descsec', '❝', 'Description')}
  <section id="ed-descsec" class="sheet-card" aria-label="Description">
    <label class="sheet-sublabel"><span class="sr">Description</span>
      <textarea id="ed-desc" class="sheet-area" rows="5" placeholder="Describe this recipe…">${esc(p.description ?? '')}</textarea></label>
  </section>
  ${sectionHead('ed-ingssec', '☰', 'Ingredients')}
  <section id="ed-ingssec" class="sheet-card" aria-label="Ingredients">
    <label class="sheet-sublabel"><span class="sr">Ingredients, one per line</span>
      <textarea id="ed-ings" class="sheet-area" rows="10" placeholder="One ingredient per line">${esc(ingredientsToText(prevIngredients))}</textarea></label>
  </section>
  ${sectionHead('ed-stepssec', '☰', 'Directions')}
  <section id="ed-stepssec" class="sheet-card" aria-label="Directions">
    <label class="sheet-sublabel"><span class="sr">Directions, blank line between steps</span>
      <textarea id="ed-steps" class="sheet-area" rows="10" placeholder="One step per paragraph — blank line between steps">${esc(stepsToText(prevSteps))}</textarea></label>
  </section>
  ${sectionHead('ed-notessec', '🗒', 'Notes')}
  <section id="ed-notessec" class="sheet-card" aria-label="Notes">
    <label class="sheet-sublabel"><span class="sr">Notes</span>
      <textarea id="ed-notes" class="sheet-area" rows="3" placeholder="">${esc(typeof p.notes === 'string' ? p.notes : '')}</textarea></label>
  </section>
  ${sectionHead('ed-nutsec', '🍴', 'Nutrition')}
  <section id="ed-nutsec" class="sheet-card" aria-label="Nutrition">
    <div class="seg" role="group" aria-label="Nutrition view">
      <button type="button" id="ed-nut-text" class="seg-on" aria-pressed="true">Text</button>
      <button type="button" id="ed-nut-tablebtn" aria-pressed="false">Table</button>
    </div>
    <button type="button" id="ed-nut-extract" class="sheet-linkbtn">▦ Extract to Table</button>
    <label class="sheet-sublabel" id="ed-nut-textwrap"><span class="sr">Nutrition text</span>
      <textarea id="ed-nut" class="sheet-area" rows="8" placeholder="Calories: 130 calories&#10;Serving Size: 1 Cookie">${esc(nutritionInit)}</textarea></label>
    <div id="ed-nut-tablewrap" class="sheet-tablewrap" hidden></div>
  </section>
  <p id="ed-err" class="sheet-err" role="alert" aria-live="assertive"></p>
  </div>`);

  const servingsInput = document.getElementById('ed-servings') as HTMLInputElement;
  const paintStars = (): void => {
    document.querySelector('.stars')!.innerHTML = starsHtml(rating);
    bindStars();
  };
  const bindStars = (): void => {
    document.querySelectorAll<HTMLButtonElement>('[data-star]').forEach((b) => b.addEventListener('click', () => {
      const v = Number(b.dataset.star);
      // Tapping the current rating clears it back to 0 (mobile pattern).
      rating = v === Math.round(rating) ? 0 : Math.min(5, Math.max(0, v));
      paintStars();
    }));
  };
  bindStars();

  const favBtn = document.getElementById('ed-fav') as HTMLButtonElement;
  favBtn.addEventListener('click', () => {
    fav = !fav;
    favBtn.textContent = fav ? '★' : '☆';
    favBtn.setAttribute('aria-pressed', String(fav));
  });

  const setServings = (v: number): void => {
    servings = v;
    servingsInput.value = String(v);
  };
  document.getElementById('ed-serv-dec')!.addEventListener('click', () => {
    const cur = Number(servingsInput.value) || servings || 4;
    setServings(Math.max(0.25, Math.round((cur - 1) * 4) / 4));
  });
  document.getElementById('ed-serv-inc')!.addEventListener('click', () => {
    const cur = Number(servingsInput.value) || servings || 4;
    setServings(Math.min(100, Math.round((cur + 1) * 4) / 4));
  });
  servingsInput.addEventListener('input', () => {
    const n = Number(servingsInput.value);
    if (Number.isFinite(n)) servings = n;
  });

  const bindSection = (id: string): void => {
    const sec = document.getElementById(id)!;
    const btn = document.getElementById(`${id}-toggle`) as HTMLButtonElement;
    let open = true;
    btn.addEventListener('click', () => {
      open = !open;
      sec.hidden = !open;
      btn.setAttribute('aria-expanded', String(open));
      btn.classList.toggle('collapsed', !open);
    });
  };
  for (const id of ['ed-info', 'ed-times', 'ed-descsec', 'ed-ingssec', 'ed-stepssec', 'ed-notessec', 'ed-nutsec']) {
    bindSection(id);
  }

  // Live "25 min / 1 hr 25 min" labels next to the Times minute inputs.
  const bindTimeFmt = (inputId: string, fmtId: string): void => {
    const input = document.getElementById(inputId) as HTMLInputElement;
    const fmt = document.getElementById(fmtId)!;
    input.addEventListener('input', () => {
      const n = Number(input.value);
      fmt.textContent = input.value.trim() === '' || !Number.isFinite(n) ? '' : formatMinutes(n);
    });
  };
  bindTimeFmt('ed-prep', 'ed-prep-fmt');
  bindTimeFmt('ed-cook', 'ed-cook-fmt');
  bindTimeFmt('ed-total', 'ed-total-fmt');

  // Nutrition Text/Table views share one textarea source of truth; Table is a
  // read-only parse ("Extract to Table" jumps to it), Text edits round-trip.
  const paintNutritionTable = (): void => {
    const text = (document.getElementById('ed-nut') as HTMLTextAreaElement).value;
    const rows = nutritionRows(text);
    document.getElementById('ed-nut-tablewrap')!.innerHTML = rows.length
      ? `<table class="sheet-table"><tbody>${rows.map((r) =>
        `<tr><th scope="row">${esc(r.k)}</th><td>${esc(r.v)}</td></tr>`).join('')}</tbody></table>`
      : '<p class="muted">No nutrition lines yet.</p>';
  };
  const setNutritionMode = (mode: 'text' | 'table'): void => {
    nutritionMode = mode;
    if (mode === 'table') paintNutritionTable();
    (document.getElementById('ed-nut-textwrap') as HTMLLabelElement).hidden = mode !== 'text';
    (document.getElementById('ed-nut-tablewrap') as HTMLDivElement).hidden = mode !== 'table';
    const t = document.getElementById('ed-nut-text') as HTMLButtonElement;
    const b = document.getElementById('ed-nut-tablebtn') as HTMLButtonElement;
    t.classList.toggle('seg-on', mode === 'text');
    b.classList.toggle('seg-on', mode === 'table');
    t.setAttribute('aria-pressed', String(mode === 'text'));
    b.setAttribute('aria-pressed', String(mode === 'table'));
  };
  document.getElementById('ed-nut-text')!.addEventListener('click', () => setNutritionMode('text'));
  document.getElementById('ed-nut-tablebtn')!.addEventListener('click', () => setNutritionMode('table'));
  document.getElementById('ed-nut-extract')!.addEventListener('click', () => setNutritionMode('table'));

  document.getElementById('ed-cancel')!.addEventListener('click', () => {
    navigate(existing ? '/recipes/' + existing.id : '/recipes');
  });

  document.getElementById('ed-save')!.addEventListener('click', () => {
    const err = document.getElementById('ed-err')!;
    const title = (document.getElementById('ed-title') as HTMLInputElement).value.trim();
    if (!title) {
      err.textContent = 'Title is required.';
      (document.getElementById('ed-title') as HTMLInputElement).focus();
      return;
    }
    const servingsOut = clampServings((document.getElementById('ed-servings') as HTMLInputElement).value);
    const difficulty = (document.getElementById('ed-difficulty') as HTMLSelectElement).value;
    const cats = (document.getElementById('ed-cats') as HTMLInputElement).value
      .split(',').map((s) => s.trim()).filter(Boolean);
    const cookbook = (document.getElementById('ed-cookbook') as HTMLInputElement).value.trim();
    const prepOut = clampMinutes((document.getElementById('ed-prep') as HTMLInputElement).value);
    const cookOut = clampMinutes((document.getElementById('ed-cook') as HTMLInputElement).value);
    const totalOut = clampMinutes((document.getElementById('ed-total') as HTMLInputElement).value, 20160);
    // Servings init may come from unclamped stored data; normalize the field
    // so a re-save without touching it still enqueues an API-valid value.
    if (servingsOut !== servings) setServings(servingsOut);
    // Minutes are clamped to nonnegative ints (API rejects -1 / 1.5); normalize
    // the visible fields the same way before enqueueing.
    const fields: Record<string, unknown> = {
      title,
      description: (document.getElementById('ed-desc') as HTMLTextAreaElement).value,
      servings: servingsOut,
      isFavorite: fav,
      source: (document.getElementById('ed-source') as HTMLInputElement).value,
      sourceUrl: (document.getElementById('ed-sourceurl') as HTMLInputElement).value,
      categories: cats,
      // Blank clears the server value (null serializes as omitted/null, never
      // a key-drop that would keep the stale value).
      prepMinutes: prepOut ?? null,
      cookMinutes: cookOut ?? null,
      totalMinutes: totalOut ?? null,
      rating: Math.min(5, Math.max(0, rating)),
      notes: (document.getElementById('ed-notes') as HTMLTextAreaElement).value,
      nutritionText: (document.getElementById('ed-nut') as HTMLTextAreaElement).value,
      ingredients: textToIngredients(
        (document.getElementById('ed-ings') as HTMLTextAreaElement).value, prevIngredients),
      steps: textToSteps(
        (document.getElementById('ed-steps') as HTMLTextAreaElement).value, prevSteps),
      ...(difficulty ? { difficulty } : { difficulty: '' }),
      // Clearing the cookbook box leaves the stored cookbooks untouched so a
      // blank row can never wipe the model's array.
      ...(cookbook ? { cookbooks: [cookbook, ...savedCookbookList.slice(1)] } : {}),
    };
    if (existing) {
      patchPayload('recipe', existing.id, fields);
      navigate('/recipes/' + existing.id);
    } else {
      const env = store.upsert('recipe', '', fields);
      navigate('/recipes/' + env.id);
    }
  });
  // Resolve the photoKeys thumbnail (signed R2 URL); failures remove the
  // img and the row falls back to the count + placeholder styling.
  hydrateRecipePhotos();
}

interface RecipeIngredient { id?: string; name: string; quantity?: number; unit?: string; display?: string; position?: number; }
interface RecipeStep { id?: string; text: string; position?: number; timers?: { seconds: number; label: string }[]; }

function viewRecipeDetail(id: string): void {
  const env = store.state.recipes.find((e) => e.id === id);
  if (!env || env.deleted) {
    shell(`<h1>Not found</h1><p>This recipe is gone. <a href="${href('/recipes')}">Back to Library</a></p>`);
    return;
  }
  const p = env.payload as {
    title?: string; description?: string; servings?: number;
    prepMinutes?: number; cookMinutes?: number; totalMinutes?: number; rating?: number; isFavorite?: boolean;
    source?: string; sourceUrl?: string; categories?: string[];
    difficulty?: string; cookbooks?: string[];
    notes?: string; nutritionText?: string;
    ingredients?: RecipeIngredient[]; steps?: RecipeStep[];
  };
  const meta: string[] = [];
  if (p.prepMinutes != null) meta.push(`prep ${esc(p.prepMinutes)} min`);
  if (p.cookMinutes != null) meta.push(`cook ${esc(p.cookMinutes)} min`);
  if (p.totalMinutes != null) meta.push(`total ${esc(p.totalMinutes)} min`);
  if (p.rating != null) meta.push(`rating ${esc(p.rating)}/5`);
  if (p.isFavorite) meta.push('★ favorite');
  if (typeof p.difficulty === 'string' && p.difficulty) meta.push(`difficulty ${esc(p.difficulty)}`);
  // Non-http(s) source URLs render as plain text, never href (XSS allowlist).
  const srcLink = safeHttpUrl(p.sourceUrl);
  const srcHtml = srcLink
    ? `<p>Source: <a href="${esc(srcLink)}">${esc(p.source || srcLink)}</a></p>`
    : (p.source || p.sourceUrl)
      ? `<p>Source: ${esc([p.source, p.sourceUrl].filter(Boolean).join(' — '))}</p>`
      : '';
  const ings = [...(p.ingredients ?? [])].sort((a, b) => (a.position ?? 0) - (b.position ?? 0));
  const steps = [...(p.steps ?? [])].sort((a, b) => (a.position ?? 0) - (b.position ?? 0));
  const heroKey = recipePhotoKey(p, 'large');
  const heroHtml = heroKey
    ? `<p><img class="recipe-hero" data-photo-key="${esc(heroKey)}" alt="Photo of ${esc(p.title ?? 'recipe')}" loading="lazy" hidden /></p>`
    : '';
  const ratingStars = (r: number): string =>
    [1, 2, 3, 4, 5].map((i) => `<span class="star${i <= Math.round(r) ? ' on' : ''}" aria-hidden="true">★</span>`).join('');
  shell(`<h1>${esc(p.title ?? id)}</h1>
  ${heroHtml}
  <p class="muted">Serves ${esc(p.servings ?? 4)} · updated ${esc(env.updatedAt)}${meta.length ? ' · ' + meta.join(' · ') : ''}</p>
  ${srcHtml}
  ${(p.categories ?? []).length ? `<p class="muted">Categories: ${esc((p.categories ?? []).join(', '))}</p>` : ''}
  ${(p.cookbooks ?? []).length ? `<p class="muted">Cookbook: ${esc((p.cookbooks ?? []).join(', '))}</p>` : ''}
  <p>${esc(p.description ?? '')}</p>
  ${p.rating != null ? `<p aria-label="Rating ${esc(p.rating)} out of 5"><span class="stars stars-ro">${ratingStars(p.rating)}</span></p>` : ''}
  <h2>Ingredients</h2>
  <ul>${ings.map((ing) => `<li>${esc(ingredientLabel(ing))}</li>`).join('') || '<li>No ingredients yet.</li>'}</ul>
  <h2>Steps</h2>
  <ol>${steps.map((s) => `<li>${esc(s.text)}</li>`).join('') || '<li>No steps yet.</li>'}</ol>
  ${typeof p.notes === 'string' && p.notes ? `<h2>Notes</h2><p>${esc(p.notes)}</p>` : ''}
  <details id="nutrition"${nutritionOpen ? ' open' : ''}><summary>Nutrition</summary>${typeof p.nutritionText === 'string' && p.nutritionText.trim() ? `<p>${esc(p.nutritionText)}</p>` : `<p class="muted">No nutrition info yet.</p>`}</details>
  <p><a href="${href('/cook/' + id)}">Start cook mode</a> · <a href="${href('/recipes/' + id + '/edit')}">Edit recipe</a> · <a href="${href('/recipes')}">Back</a></p>
  <button id="del" type="button">Delete recipe</button>`);
  hydrateRecipePhotos();
  document.getElementById('nutrition')?.addEventListener('toggle', (e) => {
    nutritionOpen = (e.target as HTMLDetailsElement).open;
  });
  document.getElementById('del')!.addEventListener('click', () => {
    store.remove('recipe', id);
    navigate('/recipes');
  });
}

// ---- Cook mode ----
function viewCook(id: string): void {
  const env = store.state.recipes.find((e) => e.id === id);
  if (!env || env.deleted) {
    shell(`<h1>Not found</h1><p><a href="${href('/recipes')}">Back to Library</a></p>`);
    return;
  }
  const p = env.payload as { title?: string; servings?: number; ingredients?: { name: string; quantity?: number; unit?: string; display?: string }[]; steps?: { text: string; timers?: { seconds: number; label: string }[] }[] } & Record<string, unknown>;
  const base = p.servings ?? 4;
  const heroKey = recipePhotoKey(p, 'large');
  const heroHtml = heroKey
    ? `<p><img class="recipe-hero" data-photo-key="${esc(heroKey)}" alt="Photo of ${esc(p.title ?? 'recipe')}" loading="lazy" hidden /></p>`
    : '';
  shell(`<h1>Cook: ${esc(p.title ?? id)}</h1>
  ${heroHtml}
  <form id="scale"><label for="serv">Servings (base ${esc(base)})</label>
  <input id="serv" type="number" min="0.25" max="100" step="0.25" value="${esc(base)}" />
  <button type="submit">Scale</button></form>
  <h2>Ingredients</h2><ul id="ings"></ul>
  <h2>Steps</h2><ol id="steps">${(p.steps ?? []).map((s, i) =>
    `<li><label><input type="checkbox" data-step="${i}" /> <span>${esc(s.text)}</span></label>${(s.timers ?? []).map((t) => ` <button type="button" data-timer="${t.seconds}" data-label="${esc(t.label)}">Start ${esc(t.label)} (${t.seconds}s)</button>`).join('')}</li>`).join('')}</ol>
  <p id="timer" role="status" aria-live="polite"></p>
  <p><a href="${href('/recipes/' + id)}">Recipe detail</a></p>`);
  hydrateRecipePhotos();
  const renderIngs = (target: number) => {
    document.getElementById('ings')!.innerHTML = (p.ingredients ?? []).map((ing) => {
      const q = scaleQuantity(ing.quantity, base, target);
      const label = ing.quantity != null ? formatQuantity(q, ing.unit ?? '') + ' ' + ing.name : (ing.display ? `${ing.display} ${ing.name}` : ing.name);
      return `<li><label><input type="checkbox" /> <span>${esc(label.trim())}</span></label></li>`;
    }).join('');
  };
  renderIngs(base);
  (document.getElementById('scale') as HTMLFormElement).addEventListener('submit', (e) => {
    e.preventDefault();
    renderIngs(Number((document.getElementById('serv') as HTMLInputElement).value) || base);
  });
  document.querySelectorAll<HTMLButtonElement>('[data-timer]').forEach((btn) => {
    btn.addEventListener('click', () => {
      const secs = Number(btn.dataset.timer);
      const label = btn.dataset.label ?? 'Timer';
      const status = document.getElementById('timer')!;
      const end = Date.now() + secs * 1000;
      if (activeTimer !== undefined) window.clearInterval(activeTimer);
      status.textContent = `${label}: ${secs}s remaining`;
      const tick = window.setInterval(() => {
        const left = Math.max(0, Math.round((end - Date.now()) / 1000));
        status.textContent = left > 0 ? `${label}: ${left}s remaining` : `${label} done.`;
        if (left <= 0) {
          window.clearInterval(tick);
          if (activeTimer === tick) activeTimer = undefined;
        }
      }, 500);
      activeTimer = tick;
    });
  });
}

// ---- Plan ----
// Monday-first week, built from local y/m/d components (no UTC shift).
function weekDates(): string[] {
  const out: string[] = [];
  const d = new Date();
  const day = (d.getDay() + 6) % 7; // Monday-first
  d.setDate(d.getDate() - day);
  const pad = (n: number) => String(n).padStart(2, '0');
  for (let i = 0; i < 7; i++) {
    const t = new Date(d.getFullYear(), d.getMonth(), d.getDate() + i);
    out.push(`${t.getFullYear()}-${pad(t.getMonth() + 1)}-${pad(t.getDate())}`);
  }
  return out;
}

function planLabel(fp: { recipeId?: string | null; note?: string }): string {
  const title = fp.recipeId ? recipeTitle(fp.recipeId) : null;
  if (title && fp.note) return `${title} — ${fp.note}`;
  return title ?? fp.note ?? '—';
}

function viewPlan(): void {
  const plans = visible(store.state.plans);
  const days = weekDates();
  const meals = ['breakfast', 'lunch', 'dinner', 'snack'];
  const recipes = visible(store.state.recipes);
  const editing = editingPlanId ? plans.find((pl) => pl.id === editingPlanId) : undefined;
  if (editingPlanId && !editing) editingPlanId = null;
  const ep = editing?.payload as { date?: string; meal?: string; recipeId?: string | null; note?: string; servings?: number } | undefined;
  shell(`<h1>Plan — this week</h1>
  ${days.map((date) => `<section aria-label="Plan for ${date}"><h2>${date}</h2><ul>${meals.map((meal) => {
    const found = plans.filter((pl) => (pl.payload as { date?: string; meal?: string }).date === date && (pl.payload as { meal?: string }).meal === meal);
    return `<li><strong>${meal}</strong>: ${found.map((f) =>
      `${esc(planLabel(f.payload as { recipeId?: string | null; note?: string }))} <button type="button" data-plan-edit="${f.id}">Edit</button> <button type="button" data-plan-del="${f.id}">Delete</button>`).join(', ') || '—'} <button type="button" data-date="${date}" data-meal="${meal}">+ Add</button></li>`;
  }).join('')}</ul></section>`).join('')}
  <form id="addplan"><h2>${editing ? 'Edit plan entry' : 'Add plan entry'}</h2>
  <label>Date <input name="date" type="date" required value="${esc(ep?.date ?? days[0])}" /></label>
  <label>Meal <select name="meal">${meals.map((m) => `<option${(ep?.meal ?? 'dinner') === m ? ' selected' : ''}>${m}</option>`).join('')}</select></label>
  <label>Recipe <select name="recipeId"><option value="">— none —</option>${recipes.map((r) => `<option value="${r.id}"${ep?.recipeId === r.id ? ' selected' : ''}>${esc((r.payload as { title?: string }).title ?? r.id)}</option>`).join('')}</select></label>
  <label>Servings <input name="servings" type="number" min="0.25" max="100" step="0.25" value="${esc(ep?.servings ?? 4)}" /></label>
  <label>Note <input name="note" placeholder="Optional note" value="${esc(ep?.note ?? '')}" /></label>
  <button type="submit">Save (offline OK)</button>${editing ? ' <button type="button" id="cancelplan">Cancel</button>' : ''}</form>
  <form id="weeklist"><h2>Week to shopping list</h2><button type="submit">Aggregate week into list</button></form>`);
  (document.getElementById('addplan') as HTMLFormElement).addEventListener('submit', (e) => {
    e.preventDefault();
    const fd = new FormData(e.target as HTMLFormElement);
    const note = String(fd.get('note') || '').trim();
    const fields = {
      date: String(fd.get('date')), meal: String(fd.get('meal')),
      recipeId: String(fd.get('recipeId') || '') || null,
      servings: numVal(fd.get('servings')) ?? 4,
      ...(note ? { note } : { note: '' }),
    };
    if (editing) {
      patchPayload('plan', editing.id, fields);
      editingPlanId = null;
    } else {
      store.upsert('plan', '', fields);
    }
    render();
  });
  document.getElementById('cancelplan')?.addEventListener('click', () => {
    editingPlanId = null;
    render();
  });
  document.querySelectorAll<HTMLButtonElement>('[data-plan-edit]').forEach((b) => b.addEventListener('click', () => {
    editingPlanId = b.dataset.planEdit!;
    render();
    document.getElementById('addplan')!.scrollIntoView();
  }));
  document.querySelectorAll<HTMLButtonElement>('[data-plan-del]').forEach((b) => b.addEventListener('click', () => {
    if (editingPlanId === b.dataset.planDel) editingPlanId = null;
    store.remove('plan', b.dataset.planDel!);
    render();
  }));
  document.querySelectorAll<HTMLButtonElement>('[data-date]').forEach((b) => {
    b.addEventListener('click', () => {
      const form = document.getElementById('addplan') as HTMLFormElement;
      (form.elements.namedItem('date') as HTMLInputElement).value = b.dataset.date!;
      (form.elements.namedItem('meal') as HTMLSelectElement).value = b.dataset.meal!;
      form.scrollIntoView();
    });
  });
  (document.getElementById('weeklist') as HTMLFormElement).addEventListener('submit', (e) => {
    e.preventDefault();
    // Only this week's plans, each recipe scaled by its plan servings first.
    const lookup = (recipeId: string) => {
      const r = recipes.find((x) => x.id === recipeId);
      const payload = r?.payload as { servings?: number; ingredients?: { name: string; quantity?: number; unit?: string; display?: string }[] } | undefined;
      return payload ? { servings: payload.servings, ingredients: payload.ingredients } : undefined;
    };
    const weekPlans = plans.map((pl) => ({ ...(pl.payload as { date: string; servings?: number; recipeId?: string | null }) }));
    const items = aggregateWeekToList(collectPlanIngredients(weekPlans, days, lookup));
    store.upsert('list', '', { name: `Week of ${days[0]}`, items });
    navigate('/lists');
  });
}

// ---- Shop / Pantry ----
interface PantryForm { name?: string; quantity?: string; location?: string; expiresAt?: string | null; lowThreshold?: string; barcode?: string; }
interface ShopRow { id?: string; name: string; quantity?: string; aisle?: string; checked?: boolean; recipeId?: string | null; }

function viewLists(): void {
  const lists = visible(store.state.lists);
  if (selectedListId && !lists.some((l) => l.id === selectedListId)) selectedListId = null;
  const current = lists.find((l) => l.id === selectedListId) ?? lists[lists.length - 1];
  if (current) selectedListId = current.id;
  if (editingItemIdx != null && !(current?.payload as { items?: unknown[] } | undefined)?.items?.[editingItemIdx]) editingItemIdx = null;
  const cp = current?.payload as { name?: string; items?: ShopRow[] } | undefined;
  const rows = sortedRows(cp?.items ?? []);
  const recipes = visible(store.state.recipes);
  const pantryItems = visible(store.state.pantry);
  const editingPantry = editingPantryId ? pantryItems.find((pi) => pi.id === editingPantryId) : undefined;
  if (editingPantryId && !editingPantry) editingPantryId = null;
  const pp = (editingPantry?.payload ?? {}) as PantryForm;
  shell(`<h1>Shopping lists</h1>
  <form id="newlist"><label>Name <input name="name" required value="Weekly shop" /></label><button type="submit">New list</button></form>
  <ul>${lists.map((l) => `<li><button type="button" data-list="${l.id}"${l.id === current?.id ? ' aria-current="true"' : ''}>${esc((l.payload as { name?: string }).name ?? l.id)}</button></li>`).join('') || '<li>No lists yet.</li>'}</ul>
  ${current ? `<form id="renamelist"><label>Rename list <input name="name" required value="${esc(cp?.name ?? '')}" /></label>
  <button type="submit">Rename</button> <button type="button" id="dellist">Delete list</button></form>` : ''}
  <h2>Aisle-sorted pantry</h2>
  <form id="addpantry"><h3>${editingPantry ? 'Edit pantry item' : 'Add pantry item'}</h3>
  <label>Item <input name="name" required value="${esc(pp.name ?? '')}" /></label>
  <label>Qty <input name="quantity" value="${esc(pp.quantity ?? '')}" /></label>
  <label>Location <input name="location" value="${esc(pp.location ?? '')}" /></label>
  <label>Expires <input name="expiresAt" type="date" value="${esc(pp.expiresAt ?? '')}" /></label>
  <label>Low threshold <input name="lowThreshold" value="${esc(pp.lowThreshold ?? '')}" /></label>
  <label>Barcode <input name="barcode" value="${esc(pp.barcode ?? '')}" /></label>
  <button type="submit">${editingPantry ? 'Save (offline OK)' : 'Add to pantry'}</button>${editingPantry ? ' <button type="button" id="cancelpantry">Cancel</button>' : ''}</form>
  <ul>${pantryItems.map((pi) => {
    const q = pi.payload as PantryForm;
    return `<li>${esc(q.name)} <span class="muted">${esc(q.quantity ?? '')}${q.location ? ' · ' + esc(q.location) : ''}${q.expiresAt ? ' · exp ' + esc(q.expiresAt) : ''}</span>
    <button type="button" data-pantry-edit="${pi.id}">Edit</button> <button type="button" data-pantry-del="${pi.id}">Delete</button></li>`;
  }).join('') || '<li>Pantry empty.</li>'}</ul>
  <h2>${esc(cp?.name ?? 'No list yet')}</h2>
  ${current ? `<form id="additem"><h3>Add item</h3>
  <label>Name <input name="name" required /></label>
  <label>Quantity <input name="quantity" /></label>
  <label>Aisle <input name="aisle" /></label>
  <label>Recipe link <select name="recipeId"><option value="">— none —</option>${recipes.map((r) => `<option value="${r.id}">${esc((r.payload as { title?: string }).title ?? r.id)}</option>`).join('')}</select></label>
  <button type="submit">Add item (offline OK)</button></form>` : ''}
  <ul>${rows.map(({ it, i }) => {
    if (editingItemIdx === i) {
      return `<li><form data-itemsave="${i}"><label><input type="checkbox" data-item="${i}"${it.checked ? ' checked' : ''} /> <span class="item-name">${esc(it.name)}</span></label>
      <label>Name <input id="item-n-${i}" value="${esc(it.name)}" required /></label>
      <label>Qty <input id="item-q-${i}" value="${esc(it.quantity ?? '')}" /></label>
      <label>Aisle <input id="item-a-${i}" value="${esc(it.aisle ?? '')}" /></label>
      <label>Recipe link <select id="item-r-${i}"><option value="">— none —</option>${recipes.map((r) => `<option value="${r.id}"${it.recipeId === r.id ? ' selected' : ''}>${esc((r.payload as { title?: string }).title ?? r.id)}</option>`).join('')}</select></label>
      <button type="submit">Save</button> <button type="button" data-itemcancel>Cancel</button></form></li>`;
    }
    // Checkbox row keeps the shared shopRowHtml markup (whole-label
    // line-through styling); per-row Edit/Delete ride alongside it.
    return `${shopRowHtml(it, i, esc).replace(/<\/li>$/, '')} <button type="button" data-itemedit="${i}">Edit</button> <button type="button" data-itemdel="${i}">Delete</button></li>`;
  }).join('') || '<li>No items.</li>'}</ul>`);
  (document.getElementById('newlist') as HTMLFormElement).addEventListener('submit', (e) => {
    e.preventDefault();
    const name = String(new FormData(e.target as HTMLFormElement).get('name'));
    const env = store.upsert('list', '', { name, items: [] });
    selectedListId = env.id;
    editingItemIdx = null;
    render();
  });
  document.querySelectorAll<HTMLButtonElement>('[data-list]').forEach((b) => {
    b.addEventListener('click', () => {
      selectedListId = b.dataset.list!;
      editingItemIdx = null;
      render();
    });
  });
  (document.getElementById('renamelist') as HTMLFormElement | null)?.addEventListener('submit', (e) => {
    e.preventDefault();
    if (!current) return;
    patchPayload('list', current.id, { name: String(new FormData(e.target as HTMLFormElement).get('name')) });
    render();
  });
  document.getElementById('dellist')?.addEventListener('click', () => {
    if (!current) return;
    store.remove('list', current.id);
    selectedListId = null;
    editingItemIdx = null;
    render();
  });
  (document.getElementById('addpantry') as HTMLFormElement).addEventListener('submit', (e) => {
    e.preventDefault();
    const fd = new FormData(e.target as HTMLFormElement);
    const name = String(fd.get('name') || '').trim();
    if (!name) return;
    const fields = {
      name,
      quantity: String(fd.get('quantity') || ''),
      location: String(fd.get('location') || ''),
      // Blank date sends null (never ""): the contract rejects "".
      expiresAt: String(fd.get('expiresAt') || '') || null,
      lowThreshold: String(fd.get('lowThreshold') || ''),
      barcode: String(fd.get('barcode') || ''),
    };
    if (editingPantry) {
      patchPayload('pantryItem', editingPantry.id, fields);
      editingPantryId = null;
    } else {
      store.upsert('pantryItem', '', fields);
    }
    render();
  });
  document.getElementById('cancelpantry')?.addEventListener('click', () => {
    editingPantryId = null;
    render();
  });
  document.querySelectorAll<HTMLButtonElement>('[data-pantry-edit]').forEach((b) => b.addEventListener('click', () => {
    editingPantryId = b.dataset.pantryEdit!;
    render();
    document.getElementById('addpantry')!.scrollIntoView();
  }));
  document.querySelectorAll<HTMLButtonElement>('[data-pantry-del]').forEach((b) => b.addEventListener('click', () => {
    if (editingPantryId === b.dataset.pantryDel) editingPantryId = null;
    store.remove('pantryItem', b.dataset.pantryDel!);
    render();
  }));
  (document.getElementById('additem') as HTMLFormElement | null)?.addEventListener('submit', (e) => {
    e.preventDefault();
    if (!current) return;
    const fd = new FormData(e.target as HTMLFormElement);
    const name = String(fd.get('name') || '').trim();
    if (!name) return;
    const recipeId = String(fd.get('recipeId') || '') || null;
    const latest = store.state.lists.find((l) => l.id === current.id);
    const payload = (latest?.payload ?? cp) as { name?: string; items?: ShopRow[] };
    const nextItems = [...(payload.items ?? []), {
      id: crypto.randomUUID(),
      name,
      quantity: String(fd.get('quantity') || ''),
      aisle: String(fd.get('aisle') || ''),
      checked: false,
      ...(recipeId ? { recipeId } : {}),
    }];
    store.upsert('list', current.id, { ...(payload as object), items: nextItems });
    render();
  });
  document.querySelectorAll<HTMLButtonElement>('[data-itemedit]').forEach((b) => b.addEventListener('click', () => {
    editingItemIdx = Number(b.dataset.itemedit);
    render();
  }));
  document.querySelectorAll<HTMLButtonElement>('[data-itemcancel]').forEach((b) => b.addEventListener('click', () => {
    editingItemIdx = null;
    render();
  }));
  document.querySelectorAll<HTMLButtonElement>('[data-itemdel]').forEach((b) => b.addEventListener('click', () => {
    if (!current) return;
    const idx = Number(b.dataset.itemdel);
    if (editingItemIdx === idx) editingItemIdx = null;
    const latest = store.state.lists.find((l) => l.id === current.id);
    const payload = (latest?.payload ?? cp) as { name?: string; items?: { name: string }[] };
    const nextItems = (payload.items ?? []).filter((_, j) => j !== idx);
    store.upsert('list', current.id, { ...(payload as object), items: nextItems });
    render();
  }));
  document.querySelectorAll<HTMLFormElement>('[data-itemsave]').forEach((form) => form.addEventListener('submit', (ev) => {
    ev.preventDefault();
    if (!current) return;
    const idx = Number(form.dataset.itemsave);
    const n = (document.getElementById(`item-n-${idx}`) as HTMLInputElement).value.trim();
    if (!n) return;
    const q = (document.getElementById(`item-q-${idx}`) as HTMLInputElement).value;
    const a = (document.getElementById(`item-a-${idx}`) as HTMLInputElement).value;
    const r = (document.getElementById(`item-r-${idx}`) as HTMLSelectElement).value || null;
    const latest = store.state.lists.find((l) => l.id === current.id);
    const payload = (latest?.payload ?? cp) as { name?: string; items?: ShopRow[] };
    const nextItems = (payload.items ?? []).map((it, j) =>
      (j === idx ? { ...it, id: it.id || crypto.randomUUID(), name: n, quantity: q, aisle: a, recipeId: r } : it));
    store.upsert('list', current.id, { ...(payload as object), items: nextItems });
    editingItemIdx = null;
    render();
  }));
  if (current) {
    document.querySelectorAll<HTMLInputElement>('[data-item]').forEach((box) => {
      box.addEventListener('change', () => {
        const idx = Number(box.dataset.item);
        // Re-read the latest payload: a previous toggle in this render may
        // already have stored a newer revision than the `cp` closure holds.
        const latest = store.state.lists.find((l) => l.id === current.id);
        const payload = (latest?.payload ?? cp) as { name?: string; items?: { name: string; quantity?: string; aisle?: string; checked?: boolean }[] };
        const nextItems = toggleItemChecked(payload.items ?? [], idx, box.checked);
        store.upsert('list', current.id, { ...(payload as object), items: nextItems });
        render(); // refresh closures so the next toggle reads fresh state
      });
    });
  }
}

interface MenuEntry { dayOffset?: number; meal?: string; recipeId?: string; servings?: number; note?: string; }

// ---- Menus ----
function viewMenus(): void {
  const menus = visible(store.state.menus);
  const recipes = visible(store.state.recipes);
  const meals = ['breakfast', 'lunch', 'dinner', 'snack'];
  shell(`<h1>Menus</h1>
  <p id="menustatus" role="status" aria-live="polite"></p>
  ${menus.map((m) => {
    const mp = m.payload as { name?: string; entries?: MenuEntry[] };
    const entries = mp.entries ?? [];
    return `<section aria-label="Menu ${esc(mp.name ?? m.id)}">
    <h2>${esc(mp.name ?? m.id)} (${entries.length} entries)</h2>
    <form data-renamemenu="${m.id}"><label>Rename <input name="name" required value="${esc(mp.name ?? '')}" /></label>
    <button type="submit">Rename</button> <button type="button" data-delmenu="${m.id}">Delete menu</button></form>
    <ul>${entries.map((en, i) => `<li>Day ${esc(en.dayOffset ?? 0)} · ${esc(en.meal ?? 'dinner')} · ${esc(en.recipeId ? recipeTitle(en.recipeId) : en.note ? `(Note) ${en.note}` : '—')}${en.servings != null ? ` · serves ${esc(en.servings)}` : ''}
      <button type="button" data-delentry="${m.id}:${i}">Remove</button></li>`).join('') || '<li>No entries yet.</li>'}</ul>
    <form data-addentry="${m.id}"><h3>Add entry</h3>
    <label>Day offset (0–6) <input name="dayOffset" type="number" min="0" max="6" step="1" value="0" /></label>
    <label>Meal <select name="meal">${meals.map((meal) => `<option${meal === 'dinner' ? ' selected' : ''}>${meal}</option>`).join('')}</select></label>
    <label>Recipe <select name="recipeId">${recipes.map((r) => `<option value="${r.id}">${esc((r.payload as { title?: string }).title ?? r.id)}</option>`).join('')}</select></label>
    <label>Servings <input name="servings" type="number" min="0.25" max="100" step="0.25" value="4" /></label>
    <button type="submit">Add entry (offline OK)</button></form>
    <p><button type="button" data-apply="${m.id}">Apply to week</button>
    <button type="button" data-tolist="${m.id}">Add week to list</button></p></section>`;
  }).join('') || '<p>No menus yet.</p>'}
  <form id="newmenu"><h2>New menu</h2><label>Name <input name="name" required /></label>
  <button type="submit">Save</button></form>`);
  (document.getElementById('newmenu') as HTMLFormElement).addEventListener('submit', (e) => {
    e.preventDefault();
    const name = String(new FormData(e.target as HTMLFormElement).get('name'));
    store.upsert('menu', '', {
      name,
      entries: recipes.slice(0, 3).map((r, i) => ({ dayOffset: i, meal: 'dinner', recipeId: r.id, servings: 4 })),
    });
    render();
  });
  document.querySelectorAll<HTMLFormElement>('[data-renamemenu]').forEach((form) => form.addEventListener('submit', (e) => {
    e.preventDefault();
    patchPayload('menu', form.dataset.renamemenu!, { name: String(new FormData(form).get('name')) });
    render();
  }));
  document.querySelectorAll<HTMLButtonElement>('[data-delmenu]').forEach((b) => b.addEventListener('click', () => {
    store.remove('menu', b.dataset.delmenu!);
    render();
  }));
  document.querySelectorAll<HTMLButtonElement>('[data-delentry]').forEach((b) => b.addEventListener('click', () => {
    const [menuId, idxStr] = (b.dataset.delentry ?? '').split(':');
    const m = store.state.menus.find((x) => x.id === menuId);
    if (!m) return;
    const entries = [...((m.payload as { entries?: MenuEntry[] }).entries ?? [])];
    entries.splice(Number(idxStr), 1);
    patchPayload('menu', menuId, { entries });
    render();
  }));
  document.querySelectorAll<HTMLFormElement>('[data-addentry]').forEach((form) => form.addEventListener('submit', (e) => {
    e.preventDefault();
    const menuId = form.dataset.addentry!;
    const fd = new FormData(form);
    const off = numVal(fd.get('dayOffset')) ?? 0;
    const m = store.state.menus.find((x) => x.id === menuId);
    if (!m) return;
    const entries = [...((m.payload as { entries?: MenuEntry[] }).entries ?? [])];
    entries.push({
      dayOffset: Math.min(6, Math.max(0, Math.round(off))),
      meal: String(fd.get('meal') || 'dinner'),
      recipeId: String(fd.get('recipeId') || ''),
      servings: numVal(fd.get('servings')) ?? 4,
    });
    patchPayload('menu', menuId, { entries });
    render();
  }));
  const applyMenu = (menuId: string, toList: boolean) => {
    const m = store.state.menus.find((x) => x.id === menuId);
    const mp = m?.payload as { name?: string; entries?: MenuEntry[] };
    const entries = mp?.entries ?? [];
    const days = weekDates();
    if (toList) {
      const ings = entries.flatMap((en) => {
        // This-week entries only, mirroring the apply-to-plan branch.
        const off = en.dayOffset ?? 0;
        if (!Number.isInteger(off) || off < 0 || off > 6) return [];
        const r = recipes.find((x) => x.id === en.recipeId);
        const payload = r?.payload as { servings?: number; ingredients?: { name: string; quantity?: number; unit?: string; display?: string }[] } | undefined;
        if (!payload) return [];
        const recipeServings = payload.servings ?? 4;
        return scaleIngredientsForServings(payload.ingredients ?? [], recipeServings, en.servings ?? recipeServings)
          .map((i) => ({ ...i, recipeId: r?.id }));
      });
      store.upsert('list', '', { name: `${mp?.name ?? 'Menu'} — shopping`, items: aggregateWeekToList(ings) });
      navigate('/lists');
      return;
    }
    let skipped = 0;
    const validMeals = new Set(['breakfast', 'lunch', 'dinner', 'snack']);
    for (const en of entries) {
      const off = en.dayOffset ?? 0;
      // Never collapse out-of-week entries onto Sunday: skip visibly.
      if (!Number.isInteger(off) || off < 0 || off > 6) {
        skipped++;
        continue;
      }
      // Only the plan meal enum is displayable and API-accepted: skip visibly.
      const meal = en.meal ?? 'dinner';
      if (!validMeals.has(meal)) {
        skipped++;
        continue;
      }
      store.upsert('plan', '', {
        date: days[off], meal, recipeId: en.recipeId ?? null,
        servings: en.servings ?? 4, ...(en.note ? { note: en.note } : {}),
      });
    }
    if (skipped > 0) {
      document.getElementById('menustatus')!.textContent =
        `Applied ${entries.length - skipped} of ${entries.length} entries — ${skipped} outside this week or with unknown meal skipped.`;
      return; // stay: the skip count must remain visible
    }
    navigate('/plan');
  };
  document.querySelectorAll<HTMLButtonElement>('[data-apply]').forEach((b) => b.addEventListener('click', () => applyMenu(b.dataset.apply!, false)));
  document.querySelectorAll<HTMLButtonElement>('[data-tolist]').forEach((b) => b.addEventListener('click', () => applyMenu(b.dataset.tolist!, true)));
}

// ---- Ingest ----
function viewIngest(): void {
  shell(`<h1>Clip a recipe</h1>
  <div role="tablist" aria-label="Ingest methods">
    <button type="button" role="tab" id="tab-link" aria-controls="panel-link" aria-selected="true">Link</button>
    <button type="button" role="tab" id="tab-text" aria-controls="panel-text" aria-selected="false">Text</button>
    <button type="button" role="tab" id="tab-photo" aria-controls="panel-photo" aria-selected="false">Photo</button>
  </div>
  <section id="panel-link" role="tabpanel" aria-labelledby="tab-link">
  <form id="clip"><label>Source URL <input name="url" type="url" placeholder="https://…" /></label>
  <label>Caption or pasted text <textarea name="caption" rows="4"></textarea></label>
  <label>From clipboard <input name="fromclip" type="checkbox" /></label>
  <button type="submit">Clip</button></form>
  <p id="status" role="status" aria-live="polite"></p>
  <p class="muted">Offline: saves as a local draft recipe. Online: also sends to the API clip endpoint.</p>
  </section>
  <section id="panel-text" role="tabpanel" aria-labelledby="tab-text" hidden>
  <form id="clip-text">
  <label for="pastetext">Paste recipe text</label>
  <textarea id="pastetext" name="pastetext" rows="8" placeholder="Paste the recipe here — title on the first line"></textarea>
  <p class="muted">Title defaults to the first line.</p>
  <button type="submit">Paste &amp; preview</button></form>
  <p id="textstatus" role="status" aria-live="polite"></p>
  <form id="text-preview" hidden>
  <h2>Preview</h2>
  <label for="text-title">Title</label>
  <input id="text-title" name="title" />
  <label for="text-ings">Ingredients (one per line)</label>
  <textarea id="text-ings" name="ingredients" rows="5"></textarea>
  <label for="text-steps">Steps (one per line)</label>
  <textarea id="text-steps" name="steps" rows="5"></textarea>
  <button type="submit">Save</button></form>
  </section>
  <section id="panel-photo" role="tabpanel" aria-labelledby="tab-photo" hidden>
  <form id="clip-photo">
  <label for="photo-file">Recipe photo</label>
  <input id="photo-file" name="photo" type="file" accept="image/*" />
  <p><img id="photo-img" alt="Attached recipe photo preview" hidden style="max-width:100%" /></p>
  <label for="photo-ocr">Transcribed / OCR text (paste or type from photo)</label>
  <textarea id="photo-ocr" name="ocr" rows="8" placeholder="Type or paste the visible text from the photo"></textarea>
  <p class="muted">Web has no on-device OCR yet — attach photo for reference, paste visible text.</p>
  <button type="submit">Parse &amp; preview</button></form>
  <p id="photostatus" role="status" aria-live="polite"></p>
  <form id="photo-preview" hidden>
  <h2>Preview</h2>
  <label for="photo-title">Title</label>
  <input id="photo-title" name="title" />
  <label for="photo-ings">Ingredients (one per line)</label>
  <textarea id="photo-ings" name="ingredients" rows="5"></textarea>
  <label for="photo-steps">Steps (one per line)</label>
  <textarea id="photo-steps" name="steps" rows="5"></textarea>
  <button type="submit">Save</button></form>
  </section>`);
  const tabs = Array.from(document.querySelectorAll<HTMLButtonElement>('[role="tab"]'));
  const selectTab = (id: string) => {
    for (const t of tabs) {
      const selected = t.id === id;
      t.setAttribute('aria-selected', String(selected));
      document.getElementById(t.getAttribute('aria-controls')!)?.toggleAttribute('hidden', !selected);
    }
  };
  tabs.forEach((t) => t.addEventListener('click', () => selectTab(t.id)));
  // --- Link (existing flow, unchanged) ---
  (document.getElementById('clip') as HTMLFormElement).addEventListener('submit', async (e) => {
    e.preventDefault();
    const fd = new FormData(e.target as HTMLFormElement);
    let url = String(fd.get('url') || '');
    let caption = String(fd.get('caption') || '');
    const status = document.getElementById('status')!;
    if (fd.get('fromclip')) {
      try {
        caption = await navigator.clipboard.readText();
      } catch {
        status.textContent = 'Clipboard unavailable; paste manually.';
        return;
      }
    }
    if (!url && !caption) {
      status.textContent = 'Provide a URL or caption.';
      return;
    }
    const source = url ? 'url' : 'clipboard';
    try {
      const report = await api.clip({ url: url || undefined, caption: caption || undefined, source });
      const env = store.upsert('recipe', '', { ...report.recipe, servings: report.recipe.servings ?? 4 });
      status.textContent = `Clipped via ${report.strategy}.`;
      navigate('/recipes/' + env.id);
    } catch {
      // Offline fallback: local draft.
      const env = store.upsert('recipe', '', {
        title: caption.slice(0, 60) || url || 'Clipped draft',
        description: caption,
        servings: 4,
        ingredients: [],
        steps: caption ? [{ text: caption, position: 0 }] : [],
        sourceUrl: url || undefined,
      });
      status.textContent = 'Saved offline as a draft.';
      navigate('/recipes/' + env.id);
    }
  });
  // Photo attachment is reference-only: bytes are never uploaded.
  // Defined before the paste wiring so the photo preview Save handler and
  // the route-teardown listener can release the object URL.
  let photoObjectUrl: string | undefined;
  const revokePhotoObjectUrl = (): void => {
    if (photoObjectUrl === undefined) return;
    try {
      if (typeof URL !== 'undefined' && typeof URL.revokeObjectURL === 'function') {
        URL.revokeObjectURL(photoObjectUrl);
      }
    } catch { /* test/jsdom without revoke: ignore */ }
    photoObjectUrl = undefined;
  };
  // --- Shared paste/OCR preview + save wiring for Text/Photo tabs ---
  // Extract an HTTP status from the api client error shape. req() throws
  // `Error("METHOD path failed: STATUS")` with no .status field; signed
  // transports may attach one. Absent status (TypeError from fetch) means
  // the request never got a response — a genuine offline/network failure.
  const clipHttpStatus = (err: unknown): number | undefined => {
    if (typeof err === 'object' && err !== null && 'status' in err) {
      const s = (err as { status?: unknown }).status;
      if (typeof s === 'number' && Number.isFinite(s)) return s;
      if (typeof s === 'string' && /^\d{3}$/.test(s.trim())) return Number(s.trim());
    }
    const msg = err instanceof Error ? err.message : String(err ?? '');
    const m = msg.match(/\b(\d{3})\b/);
    return m ? Number(m[1]) : undefined;
  };
  const wirePasteTab = (opts: {
    formId: string; inputId: string; statusId: string; previewId: string;
    titleId: string; ingsId: string; stepsId: string; source: 'text' | 'photo';
    emptyMessage: string;
  }) => {
    const form = document.getElementById(opts.formId) as HTMLFormElement;
    const preview = document.getElementById(opts.previewId) as HTMLFormElement;
    const sourceInput = document.getElementById(opts.inputId) as HTMLTextAreaElement | null;
    let pendingDescription = '';
    let pendingReport: RecipeInput | undefined;
    // Generation guard: editing the source invalidates the visible preview
    // and any in-flight clip response captured before the edit.
    let generation = 0;
    sourceInput?.addEventListener('input', () => {
      generation++;
      pendingReport = undefined;
      pendingDescription = '';
      preview.hidden = true;
    });
    form.addEventListener('submit', async (e) => {
      e.preventDefault();
      const fd = new FormData(form);
      const key = opts.source === 'text' ? 'pastetext' : 'ocr';
      const caption = String(fd.get(key) || '').trim();
      const status = document.getElementById(opts.statusId)!;
      if (!caption) {
        status.textContent = opts.emptyMessage;
        return;
      }
      const gen = ++generation;
      // Title hint = first line (shown before the server responds).
      const hint = firstNonEmptyLine(caption);
      status.textContent = hint ? `Parsing “${hint.slice(0, 60)}”…` : 'Parsing…';
      try {
        const report = await api.clip({ caption, source: opts.source });
        if (gen !== generation) return; // stale: source edited mid-flight
        const fields = recipeToPreviewFields(report.recipe);
        (document.getElementById(opts.titleId) as HTMLInputElement).value = fields.title;
        (document.getElementById(opts.ingsId) as HTMLTextAreaElement).value = fields.ingredientsText;
        (document.getElementById(opts.stepsId) as HTMLTextAreaElement).value = fields.stepsText;
        pendingReport = report.recipe;
        pendingDescription =
          typeof report.recipe.description === 'string' ? report.recipe.description.slice(0, 8000) : caption.slice(0, 8000);
        preview.hidden = false;
        status.textContent = `Preview ready via ${report.strategy}. Review and Save.`;
      } catch (err) {
        if (gen !== generation) return; // stale: source edited mid-flight
        // 4xx (esp. 413/422 validation) is a server verdict on this exact
        // text — not an offline signal. Surface it; never save the
        // oversized/invalid draft as if it parsed.
        const httpStatus = clipHttpStatus(err);
        if (httpStatus !== undefined && httpStatus >= 400 && httpStatus < 500) {
          const detail = err instanceof Error ? err.message : String(err);
          status.textContent = `Could not parse (${httpStatus}): ${detail} — edit the text and retry.`;
          return;
        }
        // Offline fallback: local parse, same RecipeInput shape as Link drafts.
        // parsePastedText caps description (8000) and step text (8000) to the
        // recipeInputSchema limits so the draft stays valid.
        const draft = parsePastedText(caption);
        draft.source = 'clip';
        const fields = recipeToPreviewFields(draft);
        (document.getElementById(opts.titleId) as HTMLInputElement).value = fields.title;
        (document.getElementById(opts.ingsId) as HTMLTextAreaElement).value = fields.ingredientsText;
        (document.getElementById(opts.stepsId) as HTMLTextAreaElement).value = fields.stepsText;
        pendingReport = draft;
        pendingDescription = typeof draft.description === 'string' ? draft.description : caption.slice(0, 8000);
        preview.hidden = false;
        status.textContent = 'Offline — parsed locally. Review and Save.';
      }
    });
    preview.addEventListener('submit', (e) => {
      e.preventDefault();
      const status = document.getElementById(opts.statusId)!;
      // Save requires a fresh preview: editing the source hides it and
      // clears pendingReport until the next Parse & preview.
      if (!pendingReport || preview.hidden) {
        status.textContent = 'Preview is stale — re-run Parse & preview.';
        return;
      }
      if (opts.source === 'photo') revokePhotoObjectUrl();
      const input = previewToRecipeInput(
        {
          title: (document.getElementById(opts.titleId) as HTMLInputElement).value,
          ingredientsText: (document.getElementById(opts.ingsId) as HTMLTextAreaElement).value,
          stepsText: (document.getElementById(opts.stepsId) as HTMLTextAreaElement).value,
        },
        pendingReport,
        { description: pendingDescription },
      );
      const env = store.upsert('recipe', '', input);
      navigate('/recipes/' + env.id);
    });
  };
  wirePasteTab({
    formId: 'clip-text', inputId: 'pastetext', statusId: 'textstatus',
    previewId: 'text-preview', titleId: 'text-title', ingsId: 'text-ings',
    stepsId: 'text-steps', source: 'text', emptyMessage: 'Paste recipe text first.',
  });
  wirePasteTab({
    formId: 'clip-photo', inputId: 'photo-ocr', statusId: 'photostatus',
    previewId: 'photo-preview', titleId: 'photo-title', ingsId: 'photo-ings',
    stepsId: 'photo-steps', source: 'photo', emptyMessage: 'Paste the visible text from the photo first.',
  });
  // Photo attachment is reference-only: bytes are never uploaded.
  (document.getElementById('photo-file') as HTMLInputElement).addEventListener('change', (e) => {
    const file = (e.target as HTMLInputElement).files?.[0];
    const img = document.getElementById('photo-img') as HTMLImageElement;
    revokePhotoObjectUrl();
    if (!file) {
      img.hidden = true;
      img.removeAttribute('src');
      return;
    }
    photoObjectUrl = URL.createObjectURL(file);
    img.src = photoObjectUrl;
    img.hidden = false;
  });
  // Release the photo object URL on navigation away (router navigates via
  // pushState + popstate). Once + guarded so jsdom/tests without
  // revokeObjectURL stay safe.
  window.addEventListener('popstate', revokePhotoObjectUrl, { once: true });
}

// ---- Settings ----
function exportJSON(selected?: LocalRecipe[]): string {
  if (selected) return JSON.stringify(selected, null, 2);
  return JSON.stringify(store.state, null, 2);
}

function exportMarkdownFrom(recipes: LocalRecipe[]): string {
  const lines = ['# Keep Cooking export', ''];
  for (const [n, r] of recipes.entries()) {
    if (n > 0) lines.push('---', '');
    lines.push(`## ${r.title}`, '');
    for (const i of r.ingredients ?? []) lines.push(`- ${i.display ? `${i.display} ` : ''}${i.name}`);
    lines.push('');
    (r.steps ?? []).forEach((s, n) => lines.push(`${n + 1}. ${s.text}`));
    lines.push('');
  }
  return lines.join('\n');
}

function exportMarkdown(selected?: LocalRecipe[]): string {
  return exportMarkdownFrom(selected ?? localRecipes());
}

function download(name: string, text: string, type: string): void {
  const a = document.createElement('a');
  a.href = URL.createObjectURL(new Blob([text], { type }));
  a.download = name;
  a.click();
  setTimeout(() => URL.revokeObjectURL(a.href), 1000);
}

// ---- Import/export parity (Paprika full-parity, offline-capable) ----
type AnyRec = Record<string, unknown>;

const IMPORT_ACCEPT = '.paprikarecipes,.paprikarecipe,.yml,.yaml,.html,.htm,.zip,.xml,.mx2,.mxp,.mz2,.mmf,.mm,.fdx,.fdxz,.txt,.db,.mcb';

function inferImportFormat(name: string): ImportFormat {
  const n = name.toLowerCase();
  if (n.endsWith('.paprikarecipes')) return 'paprika-zip';
  if (n.endsWith('.paprikarecipe')) return 'paprika-recipe';
  if (n.endsWith('.yml') || n.endsWith('.yaml')) return 'yaml';
  if (n.endsWith('.html') || n.endsWith('.htm')) return 'html';
  if (n.endsWith('.mx2')) return 'mx2';
  if (n.endsWith('.mxp')) return 'mxp';
  if (n.endsWith('.mz2')) return 'mz2';
  if (n.endsWith('.mmf') || n.endsWith('.mm')) return 'mmf';
  if (n.endsWith('.fdxz')) return 'fdxz';
  if (n.endsWith('.fdx')) return 'fdx';
  if (n.endsWith('.mcb')) return 'mcb';
  if (n.endsWith('.txt')) return 'recipe-manager-txt';
  if (n.endsWith('.db')) return 'pepperplate-db';
  if (n.endsWith('.xml')) return 'yum-xml';
  if (n.endsWith('.zip')) return 'paprika-zip';
  return 'paprika-json';
}

function bytesToBase64(bytes: Uint8Array): string {
  let s = '';
  const CH = 0x8000;
  for (let i = 0; i < bytes.length; i += CH) {
    s += String.fromCharCode(...bytes.subarray(i, i + CH));
  }
  return btoa(s);
}

interface LocalRecipe {
  title: string;
  description: string;
  servings: number;
  servingsText?: string;
  prepMinutes?: number;
  cookMinutes?: number;
  totalMinutes?: number;
  prepTimeText?: string;
  cookTimeText?: string;
  totalTimeText?: string;
  categories: string[];
  rating: number;
  difficulty?: string;
  notes?: string;
  nutritionText?: string;
  source?: string;
  sourceUrl?: string;
  paprikaUid?: string;
  cookbooks: string[];
  isFavorite?: boolean;
  scaleFactor?: string;
  ingredients: { name: string; quantity?: number; unit?: string; display?: string }[];
  steps: { text: string }[];
  updatedAt: string;
}

function localRecipes(ids?: Set<string> | null): LocalRecipe[] {
  const envs = visible(store.state.recipes).filter((e) => !ids || ids.has(e.id));
  return envs.map((e) => {
    const p = (e.payload ?? {}) as AnyRec;
    const str = (v: unknown, fb = ''): string => (typeof v === 'string' ? v : fb);
    const num = (v: unknown): number | undefined => (typeof v === 'number' && Number.isFinite(v) ? v : undefined);
    const ings = (Array.isArray(p['ingredients']) ? (p['ingredients'] as AnyRec[]) : []).map((i) => ({
      name: str(i['name'] ?? i['display'], 'ingredient'),
      ...(num(i['quantity']) !== undefined ? { quantity: num(i['quantity']) as number } : {}),
      ...(typeof i['unit'] === 'string' ? { unit: i['unit'] as string } : {}),
      ...(typeof i['display'] === 'string' ? { display: i['display'] as string } : {}),
    }));
    const steps = (Array.isArray(p['steps']) ? (p['steps'] as AnyRec[]) : [])
      .map((s) => ({ text: str(s['text']) }))
      .filter((s) => s.text);
    return {
      title: str(p['title'], e.id.slice(0, 8)),
      description: str(p['description']),
      servings: num(p['servings']) ?? 4,
      ...(typeof p['servingsText'] === 'string' ? { servingsText: p['servingsText'] as string } : {}),
      ...(num(p['prepMinutes']) !== undefined ? { prepMinutes: num(p['prepMinutes']) as number } : {}),
      ...(num(p['cookMinutes']) !== undefined ? { cookMinutes: num(p['cookMinutes']) as number } : {}),
      ...(num(p['totalMinutes']) !== undefined ? { totalMinutes: num(p['totalMinutes']) as number } : {}),
      ...(typeof p['prepTimeText'] === 'string' ? { prepTimeText: p['prepTimeText'] as string } : {}),
      ...(typeof p['cookTimeText'] === 'string' ? { cookTimeText: p['cookTimeText'] as string } : {}),
      ...(typeof p['totalTimeText'] === 'string' ? { totalTimeText: p['totalTimeText'] as string } : {}),
      categories: Array.isArray(p['categories']) ? (p['categories'] as unknown[]).filter((c): c is string => typeof c === 'string') : [],
      rating: num(p['rating']) ?? 0,
      ...(typeof p['difficulty'] === 'string' ? { difficulty: p['difficulty'] as string } : {}),
      ...(typeof p['notes'] === 'string' ? { notes: p['notes'] as string } : {}),
      ...(typeof p['nutritionText'] === 'string' ? { nutritionText: p['nutritionText'] as string } : {}),
      ...(typeof p['source'] === 'string' ? { source: p['source'] as string } : {}),
      ...(typeof p['sourceUrl'] === 'string' ? { sourceUrl: p['sourceUrl'] as string } : {}),
      ...(typeof p['paprikaUid'] === 'string' ? { paprikaUid: p['paprikaUid'] as string } : {}),
      cookbooks: Array.isArray(p['cookbooks']) ? (p['cookbooks'] as unknown[]).filter((c): c is string => typeof c === 'string') : [],
      ...(typeof p['isFavorite'] === 'boolean' ? { isFavorite: p['isFavorite'] as boolean } : {}),
      ...(typeof p['scaleFactor'] === 'string' ? { scaleFactor: p['scaleFactor'] as string } : {}),
      ingredients: ings,
      steps,
      updatedAt: e.updatedAt,
    };
  });
}

function paprikaDate(iso: string): string {
  const d = new Date(iso);
  return Number.isNaN(d.getTime()) ? '' : d.toISOString().slice(0, 19).replace('T', ' ');
}

/** Keep Cooking -> Paprika native JSON (§1.4). Photo bytes live server-side, so
 *  the offline fallback omits photo_data (and its filename). */
function toPaprikaJson(r: LocalRecipe): AnyRec {
  const uid = (r.paprikaUid ?? crypto.randomUUID()).toUpperCase();
  const time = (raw: string | undefined, mins: number | undefined): string =>
    raw ?? (mins != null ? `${mins} minutes` : '');
  return {
    uid,
    hash: '',
    name: r.title,
    description: r.description,
    ingredients: r.ingredients.map((i) => (i.display ? `${i.display} ${i.name}` : i.name).trim()).join('\n'),
    directions: r.steps.map((s) => s.text).join('\n'),
    notes: r.notes ?? '',
    categories: r.categories,
    servings: r.servingsText ?? String(r.servings),
    prep_time: time(r.prepTimeText, r.prepMinutes),
    cook_time: time(r.cookTimeText, r.cookMinutes),
    total_time: time(r.totalTimeText, r.totalMinutes),
    difficulty: r.difficulty ?? null,
    rating: r.rating,
    nutritional_info: r.nutritionText ?? '',
    source: r.source ?? '',
    source_url: r.sourceUrl ?? null,
    image_url: null,
    photo: null,
    photo_large: null,
    photo_hash: '',
    photo_data: null,
    photos: [],
    photo_url: null,
    created: paprikaDate(r.updatedAt),
    on_favorites: !!r.isFavorite,
    scale: r.scaleFactor ?? null,
    cookbook: r.cookbooks[0] ?? '',
    in_trash: false,
    deleted: false,
  };
}

/** Keep Cooking -> Paprika YAML keys, emitted as JSON-as-YAML (valid YAML, §2). */
function toPaprikaYaml(r: LocalRecipe): AnyRec {
  const full = toPaprikaJson(r);
  return {
    name: full['name'],
    servings: full['servings'],
    source: full['source'],
    source_url: full['source_url'],
    prep_time: full['prep_time'],
    cook_time: full['cook_time'],
    on_favorites: full['on_favorites'] ? 'yes' : 'no',
    categories: full['categories'],
    nutritional_info: full['nutritional_info'],
    difficulty: full['difficulty'],
    rating: full['rating'],
    notes: full['notes'],
    ingredients: full['ingredients'],
    directions: full['directions'],
  };
}

function exportHtmlLocal(selected?: LocalRecipe[]): string {
  const recipes = selected ?? localRecipes();
  const bodies = recipes.map((r) => {
    const ld = {
      '@context': 'https://schema.org',
      '@type': 'Recipe',
      name: r.title,
      description: r.description,
      recipeYield: String(r.servings),
      recipeIngredient: r.ingredients.map((i) => (i.display ? `${i.display} ${i.name}` : i.name).trim()),
      recipeInstructions: r.steps.map((s) => ({ '@type': 'HowToStep', text: s.text })),
      ...(r.prepMinutes != null ? { prepTime: `PT${r.prepMinutes}M` } : {}),
      ...(r.cookMinutes != null ? { cookTime: `PT${r.cookMinutes}M` } : {}),
      ...(r.sourceUrl ? { url: r.sourceUrl } : {}),
    };
    return `<article itemscope itemtype="https://schema.org/Recipe">
<h2 itemprop="name">${esc(r.title)}</h2>
<script type="application/ld+json">${esc(JSON.stringify(ld))}</script>
<p>${esc(r.description)}</p>
<h3>Ingredients</h3>
<ul>${r.ingredients.map((i) => `<li itemprop="recipeIngredient">${esc((i.display ? `${i.display} ${i.name}` : i.name).trim())}</li>`).join('')}</ul>
<h3>Directions</h3>
<ol>${r.steps.map((s) => `<li itemprop="recipeInstructions">${esc(s.text)}</li>`).join('')}</ol>
</article>`;
  }).join('\n<hr/>\n');
  return `<!DOCTYPE html><html lang="en"><head><meta charset="utf-8"><title>Keep Cooking export</title></head><body><h1>Keep Cooking export</h1>\n${bodies}\n</body></html>`;
}

function parseServingsNumber(raw: string): number {
  const m = raw.match(/(\d+\s+\d+\s*\/\s*\d+|\d+\s*\/\s*\d+|\d+(?:\.\d+)?)/);
  if (!m) return 4;
  const t = m[1].replace(/\s+/g, ' ').trim();
  if (t.includes('/')) {
    const parts = t.split(' ');
    const frac = (parts[parts.length - 1] ?? '').split('/');
    const n = Number(frac[0]);
    const d = Number(frac[1]);
    const whole = parts.length > 1 ? Number(parts[0]) : 0;
    if (Number.isFinite(n) && Number.isFinite(d) && d !== 0) return whole + n / d;
    return 4;
  }
  const v = Number.parseFloat(t);
  return Number.isFinite(v) && v > 0 ? v : 4;
}

function parseMinutes(raw: string): number | undefined {
  const s = raw.toLowerCase().trim();
  if (!s) return undefined;
  const colon = s.match(/(\d+)\s*:\s*(\d+)/);
  if (colon) return Number(colon[1]) * 60 + Number(colon[2]);
  let mins = 0;
  let found = false;
  const h = s.match(/(\d+(?:\.\d+)?)\s*h(?:ours?|rs?)?/);
  if (h) {
    mins += Number(h[1]) * 60;
    found = true;
  }
  const m = s.match(/(\d+(?:\.\d+)?)\s*m(?:in(?:utes?)?)?/);
  if (m) {
    mins += Number(m[1]);
    found = true;
  }
  if (found) return Math.round(mins);
  const plain = s.match(/(\d+(?:\.\d+)?)/);
  return plain ? Number(plain[1]) : undefined;
}

/** Paprika native JSON -> Keep Cooking RecipeInput (§1.3). Never drops the
 *  line text: every ingredient keeps display = original line. */
function paprikaToRecipeInput(p: AnyRec, importCookbooks: boolean): RecipeInput {
  const str = (v: unknown): string | undefined => (typeof v === 'string' && v ? v : undefined);
  const servingsRaw = str(p['servings']) ?? '';
  const prepRaw = str(p['prep_time']);
  const cookRaw = str(p['cook_time']);
  const totalRaw = str(p['total_time']);
  const ings = str(p['ingredients']) ?? '';
  const dirs = str(p['directions']) ?? '';
  const steps = dirs
    .split(/\n\s*\n|\r\n\s*\r\n/)
    .flatMap((b) => b.split('\n'))
    .map((t) => t.replace(/^\s*\d+[.)]\s*/, '').trim())
    .filter(Boolean)
    .map((text, i) => ({ text, position: i }));
  const cookbook = str(p['cookbook']);
  const categories = (Array.isArray(p['categories']) ? p['categories'] : []).filter((c): c is string => typeof c === 'string');
  const rating = typeof p['rating'] === 'number' ? p['rating'] : 0;
  const fav = p['on_favorites'];
  return {
    title: str(p['name']) ?? 'Untitled import',
    description: str(p['description']) ?? '',
    servings: servingsRaw ? parseServingsNumber(servingsRaw) : 4,
    ...(servingsRaw ? { servingsText: servingsRaw } : {}),
    ...(prepRaw ? { prepTimeText: prepRaw, ...(parseMinutes(prepRaw) !== undefined ? { prepMinutes: parseMinutes(prepRaw) as number } : {}) } : {}),
    ...(cookRaw ? { cookTimeText: cookRaw, ...(parseMinutes(cookRaw) !== undefined ? { cookMinutes: parseMinutes(cookRaw) as number } : {}) } : {}),
    ...(totalRaw ? { totalTimeText: totalRaw, ...(parseMinutes(totalRaw) !== undefined ? { totalMinutes: parseMinutes(totalRaw) as number } : {}) } : {}),
    rating,
    ...(typeof p['difficulty'] === 'string' && p['difficulty'] ? { difficulty: p['difficulty'] as string } : {}),
    ...(str(p['notes']) ? { notes: str(p['notes']) as string } : {}),
    ...(str(p['nutritional_info']) ? { nutritionText: str(p['nutritional_info']) as string } : {}),
    ...(str(p['source']) ? { source: str(p['source']) as string } : {}),
    ...(str(p['source_url']) ?? (str(p['source'])?.startsWith('http') ? str(p['source']) : undefined)
      ? { sourceUrl: (str(p['source_url']) ?? str(p['source'])) as string }
      : {}),
    ...(typeof p['uid'] === 'string' && p['uid'] ? { paprikaUid: (p['uid'] as string).toUpperCase() } : {}),
    ...(typeof p['scale'] === 'string' && p['scale'] ? { scaleFactor: p['scale'] as string } : {}),
    categories: importCookbooks || !cookbook ? categories : [...categories, cookbook],
    ...(importCookbooks && cookbook ? { cookbooks: [cookbook] } : {}),
    ...(fav === true || fav === 1 || fav === '1' || fav === 'yes' ? { isFavorite: true } : {}),
    ingredients: ings.split('\n').map((l) => l.trim()).filter(Boolean).map((line, i) => ({ name: line, display: line, position: i })),
    steps,
  };
}

function htmlToRecipeInputs(doc: Document, importCookbooks: boolean): { recipes: RecipeInput[]; warnings: string[] } {
  const warnings: string[] = [];
  const recipes: RecipeInput[] = [];
  // Prefer JSON-LD Recipe blocks, fall back to hRecipe, then headings (§3).
  const ldBlocks: AnyRec[] = [];
  for (const el of Array.from(doc.querySelectorAll('script[type="application/ld+json"]'))) {
    try {
      const parsed: unknown = JSON.parse(el.textContent ?? '');
      const items = Array.isArray(parsed) ? parsed : [(parsed ?? {}) as AnyRec];
      for (const it of items) {
        const rec = it as AnyRec;
        const graph = rec['@graph'];
        const pool = Array.isArray(graph) ? (graph as AnyRec[]) : [rec];
        for (const g of pool) {
          const t = g['@type'];
          if (t === 'Recipe' || (Array.isArray(t) && (t as unknown[]).includes('Recipe'))) ldBlocks.push(g);
        }
      }
    } catch {
      warnings.push('Skipped an unreadable JSON-LD block.');
    }
  }
  for (const g of ldBlocks) {
    const str = (v: unknown): string => (typeof v === 'string' ? v : '');
    const ings = (Array.isArray(g['recipeIngredient']) ? (g['recipeIngredient'] as unknown[]) : [])
      .filter((x): x is string => typeof x === 'string');
    const instr = g['recipeInstructions'];
    const steps: string[] = Array.isArray(instr)
      ? (instr as unknown[]).map((s) => (typeof s === 'string' ? s : str((s as AnyRec)['text']))).filter(Boolean)
      : (typeof instr === 'string' ? instr.split('\n').filter(Boolean) : []);
    recipes.push({
      title: str(g['name']) || 'Untitled import',
      description: str(g['description']),
      servings: 4,
      ingredients: ings.map((line, i) => ({ name: line, display: line, position: i })),
      steps: steps.map((text, i) => ({ text, position: i })),
      ...(str(g['url']) ? { sourceUrl: str(g['url']) } : {}),
    });
  }
  if (recipes.length) return { recipes, warnings };
  const hrecipes = Array.from(doc.querySelectorAll('.hrecipe, .h-recipe'));
  for (const h of hrecipes) {
    const title = h.querySelector('.fn')?.textContent?.trim() || doc.querySelector('h1')?.textContent?.trim() || 'Untitled import';
    const ings = Array.from(h.querySelectorAll('.ingredient')).map((e) => e.textContent?.trim() ?? '').filter(Boolean);
    const steps = Array.from(h.querySelectorAll('.instructions')).map((e) => e.textContent?.trim() ?? '').filter(Boolean);
    recipes.push({
      title,
      description: h.querySelector('.summary')?.textContent?.trim() ?? '',
      servings: 4,
      ingredients: ings.map((line, i) => ({ name: line, display: line, position: i })),
      steps: steps.map((text, i) => ({ text, position: i })),
    });
  }
  if (recipes.length) {
    warnings.push('No JSON-LD found; parsed hRecipe markup.');
    return { recipes, warnings };
  }
  // Last resort: first h1 + visible lists under Ingredients/Directions headings.
  const title = doc.querySelector('h1')?.textContent?.trim() || 'Untitled import';
  const collect = (names: string[]): string[] => {
    const out: string[] = [];
    for (const h of Array.from(doc.querySelectorAll('h1,h2,h3'))) {
      if (names.some((n) => (h.textContent ?? '').toLowerCase().includes(n))) {
        let sib = h.nextElementSibling;
        while (sib && !/^h[1-3]$/i.test(sib.tagName)) {
          out.push(...Array.from(sib.querySelectorAll('li')).map((li) => li.textContent?.trim() ?? '').filter(Boolean));
          if (/^(ul|ol)$/i.test(sib.tagName)) break;
          sib = sib.nextElementSibling;
        }
      }
    }
    return out;
  };
  warnings.push('No structured metadata found; parsed visible headings (JSON-LD → hRecipe → headings).');
  void importCookbooks;
  return {
    recipes: [{
      title,
      servings: 4,
      ingredients: collect(['ingredient']).map((line, i) => ({ name: line, display: line, position: i })),
      steps: collect(['direction', 'instruction', 'step', 'method']).map((text, i) => ({ text, position: i })),
    }],
    warnings,
  };
}

async function gunzipIfNeeded(buf: Uint8Array): Promise<Uint8Array> {
  const gzipMagic = buf.length > 2 && buf[0] === 0x1f && buf[1] === 0x8b;
  const DS = (globalThis as AnyRec)['DecompressionStream'] as
    | (new (format: string) => { readable: ReadableStream; writable: WritableStream })
    | undefined;
  if (gzipMagic && typeof DS !== 'undefined') {
    try {
      const ds = new DS('gzip');
      const stream = new Blob([buf as unknown as BlobPart]).stream().pipeThrough(ds);
      const out = await new Response(stream).arrayBuffer();
      return new Uint8Array(out);
    } catch {
      return buf; // fall through to plain-text parse
    }
  }
  return buf;
}

/** Offline fallback for text-based imports (JSON / JSON-as-YAML / plain-text
 *  Paprika JSON / HTML). Binary bundles (ZIP/gzip members, SQLite, XML
 *  third-party formats) need the server. */
async function parseOfflineImport(
  buf: Uint8Array,
  fileName: string,
  importCookbooks: boolean,
): Promise<{ recipes: RecipeInput[]; warnings: string[] }> {
  const lower = fileName.toLowerCase();
  const isZip = buf.length > 2 && buf[0] === 0x50 && buf[1] === 0x4b;
  if (isZip || lower.endsWith('.zip') || lower.endsWith('.paprikarecipes') || lower.endsWith('.mz2') || lower.endsWith('.mcb')) {
    throw new Error('ZIP bundles cannot be read offline — reconnect and retry for server-side import.');
  }
  if (lower.endsWith('.db') || lower.endsWith('.sqlite')) {
    throw new Error('SQLite imports need a server connection — reconnect and retry.');
  }
  if (/\.(xml|mx2|mxp|fdx|fdxz|mmf|mm)$/.test(lower)) {
    throw new Error('This format needs server-side parsing — reconnect and retry.');
  }
  const bytes = await gunzipIfNeeded(buf);
  const text = new TextDecoder().decode(bytes);
  const trimmed = text.trim();
  if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
    const parsed: unknown = JSON.parse(trimmed);
    const items = Array.isArray(parsed) ? parsed : [parsed];
    const recipes: RecipeInput[] = (items as AnyRec[]).map((it) => {
      if (typeof it['name'] === 'string' || typeof it['ingredients'] === 'string') {
        return paprikaToRecipeInput(it, importCookbooks);
      }
      const rawIngs: unknown[] = Array.isArray(it['ingredients']) ? (it['ingredients'] as unknown[]) : [];
      const rawSteps: unknown[] = Array.isArray(it['steps']) ? (it['steps'] as unknown[]) : [];
      return {
        title: typeof it['title'] === 'string' ? (it['title'] as string) : 'Untitled import',
        servings: typeof it['servings'] === 'number' ? (it['servings'] as number) : 4,
        description: typeof it['description'] === 'string' ? (it['description'] as string) : '',
        ingredients: rawIngs.map((l, i) => {
          const o = l as AnyRec;
          const line = typeof l === 'string' ? l : String(o['display'] ?? o['name'] ?? l);
          return { name: typeof o['name'] === 'string' ? (o['name'] as string) : line, display: line, position: i };
        }),
        steps: rawSteps.map((s, i) => {
          const o = s as AnyRec;
          return { text: typeof s === 'string' ? s : String(o['text'] ?? ''), position: i };
        }),
      };
    });
    return {
      recipes,
      warnings: ['Offline fallback: parsed as JSON (photo binaries and cookbook recreation need the server).'],
    };
  }
  if (/<html|<!doctype/i.test(text.slice(0, 500)) || lower.endsWith('.html') || lower.endsWith('.htm')) {
    if (typeof DOMParser === 'undefined') throw new Error('HTML import needs a browser DOM or a server connection.');
    const doc = new DOMParser().parseFromString(text, 'text/html');
    const { recipes, warnings } = htmlToRecipeInputs(doc, importCookbooks);
    return { recipes, warnings: [...warnings, 'Offline fallback: images resolved from the file are skipped.'] };
  }
  throw new Error('Unrecognized file: expected Paprika/JSON/YAML/HTML text or a server connection for binary bundles.');
}

/** One-tap sync — parity with the native Sync now buttons. E2E when this
 * browser holds a household key, legacy plaintext REST otherwise. */
async function doSyncNow(): Promise<void> {
  if (syncingNow) return;
  syncingNow = true;
  render();
  try {
    // No WebCrypto (plain-http contexts) means no E2E: fall back before
    // touching identity creation, which needs crypto.subtle.
    const hasWebCrypto = typeof crypto !== 'undefined' && !!crypto.subtle;
    const cred = hasWebCrypto ? await getIdentity(loadMetadata()?.householdId ?? 'hh-demo') : null;
    if (cred) {
      // Best-effort device enrollment for signed writes (parity with native:
      // enrollment runs first on every sync and never blocks reads).
      try {
        await enrollDevice('web');
      } catch { /* offline: reads may still work */ }
      const res = await syncE2E(store, cred.metadata, cred.syncCode);
      syncStatus = res.conflicts > 0
        ? `Synced ${res.pulled} down · ${res.pushed} up · ${res.conflicts} server-won`
        : `Synced ${res.pulled} down · ${res.pushed} up`;
    } else {
      syncStatus = await doLegacySync();
    }
  } catch (err) {
    syncStatus = `Sync failed (${err instanceof Error ? err.message : 'unknown error'})`;
  } finally {
    syncingNow = false;
    render();
  }
}

/** Legacy plaintext REST sync (pre-E2E fallback: no WebCrypto / no key). */
async function doLegacySync(): Promise<string> {
  try {
    await enrollDevice('web');
  } catch { /* offline: reads may still work */ }
  const pushResult = await pushOutbox(store, webTransport);
  if (pushResult.failed && store.state.outbox.length > 0) {
    return `Pushed ${pushResult.pushed} envelope(s); ${store.state.outbox.length} retained offline — will retry.`;
  }
  try {
    const [recipes, lists, pantry, plans, menus] = await Promise.all([
      api.listRecipes(), api.listLists(), api.listPantry(), api.listPlans(), api.listMenus(),
    ]);
    const now = new Date().toISOString();
    for (const r of recipes) {
      store.applyRemote({ id: r.id, updatedAt: r.updatedAt ?? now, deviceId: r.deviceId ?? 'server', entity: 'recipe', payload: r } as SyncEnvelope);
    }
    for (const l of lists) {
      store.applyRemote({ id: l.id, updatedAt: l.updatedAt ?? now, deviceId: (l.deviceId as string | undefined) ?? 'server', entity: 'list', payload: l } as SyncEnvelope);
    }
    for (const pi of pantry) {
      store.applyRemote({ id: pi.id, updatedAt: pi.updatedAt ?? now, deviceId: (pi.deviceId as string | undefined) ?? 'server', entity: 'pantryItem', payload: pi } as SyncEnvelope);
    }
    for (const pl of plans) {
      store.applyRemote({ id: pl.id, updatedAt: pl.updatedAt ?? now, deviceId: (pl.deviceId as string | undefined) ?? 'server', entity: 'plan', payload: pl } as SyncEnvelope);
    }
    for (const m of menus) {
      store.applyRemote({ id: m.id, updatedAt: m.updatedAt ?? now, deviceId: (m.deviceId as string | undefined) ?? 'server', entity: 'menu', payload: m } as SyncEnvelope);
    }
    return `Synced ${recipes.length + lists.length + pantry.length + plans.length + menus.length} down · ${pushResult.pushed} up`;
  } catch (err) {
    return `Sync failed (offline?): ${err instanceof Error ? err.message : err}`;
  }
}

/** Builds the invite code for the active household (creating a fresh
 * household identity on first run). */
async function doConnectDevice(): Promise<void> {
  try {
    const household = loadMetadata()?.householdId ?? 'hh-demo';
    const cred = await getIdentity(household);
    if (!cred) {
      joinResult = 'Could not access secure storage — code unavailable.';
      render();
      return;
    }
    // Custom-server invites carry the server URL so the joining device lands
    // on the same backend; built-in installs omit it (nothing to review).
    const hint = (getApiBaseOverride() ?? '').trim() || undefined;
    inviteCode = inviteBundleJson({
      householdId: cred.metadata.householdId,
      syncCode: cred.syncCode,
      kid: cred.metadata.kid,
      hash: cred.metadata.hash,
      endpointHint: hint,
    });
    joinResult = '';
  } catch {
    joinResult = 'Could not access secure storage — code unavailable.';
  }
  render();
}

async function copyText(text: string): Promise<boolean> {
  try {
    await navigator.clipboard.writeText(text);
    return true;
  } catch {
    try {
      const ta = document.createElement('textarea');
      ta.value = text;
      document.body.appendChild(ta);
      ta.select();
      const ok = document.execCommand('copy');
      ta.remove();
      return ok;
    } catch {
      return false;
    }
  }
}

async function doCopyInvite(): Promise<void> {
  if (!inviteCode) return;
  joinResult = (await copyText(inviteCode)) ? 'Code copied.' : 'Clipboard unavailable.';
  render();
}

async function doShareInvite(): Promise<void> {
  if (!inviteCode) return;
  try {
    const nav = navigator as Navigator & { share?: (data: { text: string }) => Promise<void> };
    if (nav.share) {
      await nav.share({ text: inviteCode });
      return;
    }
  } catch { /* user dismissed: fall through to copy */ }
  await doCopyInvite();
}

async function doJoin(): Promise<void> {
  if (joiningCode) return;
  joiningCode = true;
  try {
    const pasted = (document.getElementById('pastecode') as HTMLTextAreaElement).value;
    const bundle = await parseInviteBundle(pasted);
    const active = await loadActive();
    if (active && active.metadata.hash !== bundle.hash) {
      // This browser already has a key that may hold synced data — require
      // explicit confirmation before switching households.
      pendingJoin = bundle;
      joinResult = `This device is •${active.metadata.hash.slice(0, 8)}. Joining switches to •${bundle.hash.slice(0, 8)} and replaces this device's key.`;
    } else {
      await finishJoin(bundle);
    }
  } catch (e) {
    joinResult = e instanceof Error ? e.message : 'That text is not a Keep Cooking invite code.';
  } finally {
    joiningCode = false;
    render();
  }
}

async function doJoinAnyway(): Promise<void> {
  const staged = pendingJoin;
  pendingJoin = null;
  if (!staged) {
    render();
    return;
  }
  await finishJoin(staged);
}

/** Persists a verified bundle; the endpoint hint is NEVER auto-applied. */
async function finishJoin(bundle: InviteBundle): Promise<void> {
  joiningCode = true;
  try {
    const prev = await loadActive();
    const ok = await acceptInvite(bundle);
    if (!ok) {
      joinResult = 'Code does not match — it was mistyped or tampered with.';
      return;
    }
    pendingJoin = null;
    // Never display (or share) a stale credential: the visible code
    // belonged to the previous household.
    inviteCode = null;
    if (!prev || prev.metadata.hash !== bundle.hash) {
      // New household, new local state: old records and queued edits must
      // neither show under nor upload into the joined household.
      store.clearAll();
      resetPullCursor();
    }
    pendingHint = null;
    hintHealth = '';
    const current = resolveApiBase();
    const hint = bundle.endpointHint?.trim();
    if (hint && hint !== current) {
      pendingHint = hint;
      advancedOpen = true;
      joinResult = `Joined •${bundle.hash.slice(0, 8)}. The code suggests a custom server — review it under Advanced before switching.`;
    } else if ((getApiBaseOverride() ?? '').trim()) {
      // A built-in invite names no server: staying on a stale custom
      // override would sync the joined household against the wrong backend
      // (appearing empty), so fall back to built-in explicitly.
      setApiBaseOverride(null);
      resetPullCursor();
      joinResult = `Joined •${bundle.hash.slice(0, 8)}. Switched to the built-in server (the code names no custom server).`;
    } else {
      joinResult = `Joined •${bundle.hash.slice(0, 8)}.`;
    }
  } finally {
    joiningCode = false;
    render();
  }
}

async function doTestServer(): Promise<void> {
  const raw = (document.getElementById('customurl') as HTMLInputElement).value;
  const err = validateCustomServer(raw);
  if (err) {
    healthResult = err;
    render();
    return;
  }
  healthResult = 'Testing…';
  render();
  const base = raw.trim() || resolveApiBase();
  try {
    await api.health(raw.trim() ? base : undefined);
    healthResult = `Healthy — ${base}`;
  } catch (err) {
    healthResult = `Unreachable: ${err instanceof Error ? err.message : 'unknown error'}`;
  }
  render();
}

async function doSaveServer(): Promise<void> {
  const raw = (document.getElementById('customurl') as HTMLInputElement).value;
  const err = validateCustomServer(raw);
  if (err) {
    healthResult = err;
    render();
    return;
  }
  setApiBaseOverride(raw.trim() ? raw.trim() : null);
  // New server, new history: a stale cursor would skip envelopes older than
  // the old server's last sync. LWW handles replay.
  resetPullCursor();
  healthResult = 'Server saved — tap Sync now.';
  render();
}

async function doUseHint(): Promise<void> {
  const hint = pendingHint;
  if (!hint) return;
  const err = validateCustomServer(hint);
  if (err) {
    hintHealth = `${err} — keeping current server.`;
    render();
    return;
  }
  hintHealth = 'Checking…';
  render();
  try {
    await api.health(hint);
    setApiBaseOverride(hint);
    resetPullCursor();
    pendingHint = null;
    hintHealth = '';
    healthResult = 'Server saved — tap Sync now.';
  } catch (err) {
    hintHealth = `Unreachable: ${err instanceof Error ? err.message : 'unknown error'} — keeping current server.`;
  }
  render();
}

function viewSettings(): void {
  const override = getApiBaseOverride();
  const hasCustomServer = !!override?.trim();
  const household = loadMetadata()?.householdId ?? 'hh-demo';
  // Warm the E2E identity in the background so there is always a key to
  // share — the user never sees key setup, only Devices sharing. A join in
  // progress owns identity creation; the warm-up must not mint (or commit)
  // a competing identity underneath it.
  if (!joiningCode && !pendingJoin) void getIdentity(household).catch(() => undefined);
  const devicePrefix = loadMetadata()?.hash?.slice(0, 8);
  const devicePrefixBlock = devicePrefix ? `<p class="muted">This device •${esc(devicePrefix)}</p>` : '';
  const inviteBlock = inviteCode
    ? `<p><code style="word-break:break-all">${esc(inviteCode)}</code></p>` +
      `<p><button type="button" id="copycode">Copy code</button> ` +
      `<button type="button" id="sharecode">Share</button></p>` +
      `<p class="muted">Enter it on your second device under Devices → Join with code.</p>`
    : '';
  const pendingJoinBlock = pendingJoin
    ? `<p><button type="button" id="joinanyway">Join anyway</button> ` +
      `<button type="button" id="joincancel">Cancel</button></p>`
    : '';
  const joinResultBlock = joinResult
    ? `<p role="status" aria-live="polite">${esc(joinResult)}</p>`
    : '';
  const hintBlock = pendingHint
    ? `<p><strong>Suggested server (from code)</strong></p>` +
      `<p><code style="word-break:break-all">${esc(pendingHint)}</code></p>` +
      `<p class="muted">This came from the invite code — it is not your server until you confirm it. Confirming checks GET /health first.</p>` +
      `<p><button type="button" id="usethint">Test &amp; use this server</button> ` +
      `<button type="button" id="keephint">Keep current server</button></p>` +
      (hintHealth ? `<p>${esc(hintHealth)}</p>` : '')
    : '';
  const advancedBlock = advancedOpen
    ? `<p class="muted">Only set this if you run your own backend. Most users should leave it blank.</p>` +
      `<p><label>Server URL (blank = built-in)<br /><input id="customurl" type="url" style="width:100%" value="${esc(override ?? '')}" placeholder="${esc(resolveApiBase())}" /></label></p>` +
      `<p><button type="button" id="testserver">Test</button> ` +
      `<button type="button" id="saveserver">Save</button>` +
      (hasCustomServer ? ` <button type="button" id="usebuiltin">Use built-in</button>` : '') +
      `</p>` +
      (healthResult ? `<p role="status" aria-live="polite">${esc(healthResult)}</p>` : '') +
      hintBlock
    : '';
  const exportRecipes = visible(store.state.recipes);
  shell(`<h1>Settings</h1>
  <h2>Sync</h2>
  <p id="syncstatus" role="status" aria-live="polite">${esc(syncStatus || 'Offline-ready')}</p>
  <p>Outbox: ${store.state.outbox.length} pending envelope(s).</p>
  <p><button type="button" id="syncnow"${syncingNow ? ' disabled' : ''}>${syncingNow ? 'Syncing…' : 'Sync now'}</button></p>
  <p class="muted">${hasCustomServer ? 'Using a custom server (see Advanced).' : 'Using the built-in server.'}</p>
  <h2>Devices</h2>
  ${devicePrefixBlock}
  <p><button type="button" id="connect">Connect a new device</button></p>
  ${inviteBlock}
  <p><label>Paste code to join<br /><textarea id="pastecode" rows="3" style="width:100%"></textarea></label></p>
  <p><button type="button" id="join"${joiningCode ? ' disabled' : ''}>Join with code</button></p>
  ${pendingJoinBlock}
  ${joinResultBlock}
  <p class="muted">Keep Cooking can't see or recover your data. Lose all devices = permanent loss. Add a new phone while you still have this one — open Settings here on both devices.</p>
  <h2>Advanced</h2>
  <p><button type="button" id="advancedtoggle" aria-expanded="${advancedOpen ? 'true' : 'false'}">${advancedOpen ? 'Custom server ▾' : 'Custom server ▸'}</button></p>
  ${advancedBlock}
  <h2>Export</h2>
  <p id="exportcount" role="status" aria-live="polite"></p>
  <p><label class="checkrow"><input type="checkbox" id="exportselectall" checked /> Select all</label></p>
  <div>${exportRecipes.map((r) => `<label class="checkrow"><input type="checkbox" data-export-id="${esc(r.id)}" checked /> ${esc((r.payload as { title?: string }).title ?? r.id)}</label>`).join('') || '<p>No recipes to export.</p>'}</div>
  <p><label>Format <select id="exportformat"><option value="json">JSON</option><option value="md">Markdown</option><option value="html">HTML</option><option value="paprikarecipes">Paprika (.paprikarecipes)</option><option value="yaml">YAML</option></select></label>
  <button type="button" id="doexport">Export</button></p>
  <p id="exportstatus" role="status" aria-live="polite"></p>
  <h2>Import</h2>
  <form id="importform">
  <label>File <input id="importfile" name="file" type="file" accept="${IMPORT_ACCEPT}" required /></label>
  <label>Format <select id="importformat" name="format">
  <option value="auto">Auto (from extension)</option>
  <option value="paprika-zip">Paprika bulk (.paprikarecipes / .zip)</option>
  <option value="paprika-recipe">Paprika single (.paprikarecipe)</option>
  <option value="paprika-json">Paprika JSON</option>
  <option value="yaml">Paprika YAML (.yml/.yaml)</option>
  <option value="html">HTML export</option>
  <option value="mx2">MasterCook MX2</option>
  <option value="mxp">MasterCook MXP</option>
  <option value="mz2">MasterCook MZ2</option>
  <option value="mmf">MealMaster (.mmf)</option>
  <option value="fdx">Living Cookbook FDX</option>
  <option value="fdxz">Living Cookbook FDXZ</option>
  <option value="pepperplate-zip">Pepperplate ZIP</option>
  <option value="pepperplate-db">Pepperplate DB</option>
  <option value="copymethat-zip">Copy Me That ZIP</option>
  <option value="yum-xml">Yum XML</option>
  <option value="mcb">My CookBook (.mcb)</option>
  <option value="recipe-manager-txt">Recipe Manager TXT</option>
  </select></label>
  <label class="checkrow"><input id="importcookbooks" type="checkbox" checked /> Import cookbooks from file</label>
  <label class="checkrow"><input id="importdryrun" type="checkbox" /> Dry run (preview only)</label>
  <button type="submit">Import</button></form>
  <p id="importstatus" role="status" aria-live="polite"></p>
  <p class="muted">Accepts .paprikarecipes, .paprikarecipe, .yml/.yaml, .html, .zip, .xml and P1 formats (.mx2, .mxp, .mz2, .mmf, .fdx/.fdxz, Pepperplate, Copy Me That, Yum). Offline: text imports (JSON/YAML/HTML) are parsed locally; binary bundles need a server connection.</p>`);
  document.getElementById('syncnow')!.addEventListener('click', () => void doSyncNow());
  document.getElementById('connect')!.addEventListener('click', () => void doConnectDevice());
  document.getElementById('copycode')?.addEventListener('click', () => void doCopyInvite());
  document.getElementById('sharecode')?.addEventListener('click', () => void doShareInvite());
  document.getElementById('join')!.addEventListener('click', () => void doJoin());
  document.getElementById('joinanyway')?.addEventListener('click', () => void doJoinAnyway());
  document.getElementById('joincancel')?.addEventListener('click', () => {
    pendingJoin = null;
    joinResult = 'Kept current household.';
    render();
  });
  document.getElementById('advancedtoggle')!.addEventListener('click', () => {
    advancedOpen = !advancedOpen;
    render();
  });
  document.getElementById('testserver')?.addEventListener('click', () => void doTestServer());
  document.getElementById('saveserver')?.addEventListener('click', () => void doSaveServer());
  document.getElementById('usebuiltin')?.addEventListener('click', () => {
    setApiBaseOverride(null);
    resetPullCursor();
    healthResult = 'Using the built-in server.';
    render();
  });
  document.getElementById('usethint')?.addEventListener('click', () => void doUseHint());
  document.getElementById('keephint')?.addEventListener('click', () => {
    pendingHint = null;
    hintHealth = '';
    render();
  });
  const exportBoxes = (): HTMLInputElement[] => Array.from(document.querySelectorAll<HTMLInputElement>('[data-export-id]'));
  const selectedExportIds = (): string[] => exportBoxes().filter((b) => b.checked).map((b) => b.dataset.exportId!).filter(Boolean);
  const updateExportCount = (): void => {
    const boxes = exportBoxes();
    const sel = boxes.filter((b) => b.checked).length;
    document.getElementById('exportcount')!.textContent = `${sel} of ${boxes.length} selected`;
    const all = document.getElementById('exportselectall') as HTMLInputElement | null;
    if (all) all.checked = boxes.length > 0 && sel === boxes.length;
    (document.getElementById('doexport') as HTMLButtonElement).disabled = sel === 0;
  };
  exportBoxes().forEach((b) => b.addEventListener('change', updateExportCount));
  document.getElementById('exportselectall')?.addEventListener('change', (e) => {
    const checked = (e.target as HTMLInputElement).checked;
    exportBoxes().forEach((b) => { b.checked = checked; });
    updateExportCount();
  });
  updateExportCount();
  const exportMime: Record<string, string> = {
    json: 'application/json',
    md: 'text/markdown',
    html: 'text/html',
    paprikarecipes: 'application/json',
    yaml: 'text/yaml',
  };
  document.getElementById('doexport')!.addEventListener('click', () => void (async () => {
    const st = () => document.getElementById('exportstatus')!;
    const format = (document.getElementById('exportformat') as HTMLSelectElement).value as 'json' | 'md' | 'html' | 'paprikarecipes' | 'yaml';
    const ids = selectedExportIds();
    const total = exportBoxes().length;
    if (!ids.length) {
      st().textContent = 'Select at least one recipe to export.';
      return;
    }
    const fileName = `keep-cooking.export.${format}`;
    const useAll = ids.length === total;
    try {
      const blob = await api.fetchExportBlob(api.exportBulkUrl(useAll ? { format, all: true } : { format, ids }));
      const a = document.createElement('a');
      a.href = URL.createObjectURL(blob);
      a.download = fileName;
      a.click();
      setTimeout(() => URL.revokeObjectURL(a.href), 1000);
      st().textContent = `Exported ${ids.length} recipe(s) via the server (${format}).`;
    } catch {
      const selected = localRecipes(new Set(ids));
      // Offline fallback mirrors the server's per-format bodies. Paprika has
      // no ZIP writer in the browser, so it falls back to a JSON-named file
      // (valid Paprika JSON the app can re-import) instead of claiming the
      // .paprikarecipes ZIP extension.
      let name = fileName;
      let type = exportMime[format];
      let text = '';
      if (format === 'json') text = exportJSON(selected);
      else if (format === 'md') text = exportMarkdown(selected);
      else if (format === 'html') text = exportHtmlLocal(selected);
      else if (format === 'paprikarecipes') {
        text = JSON.stringify(selected.map(toPaprikaJson), null, 2);
        name = `${fileName}.json`;
        type = 'application/json';
      } else text = JSON.stringify(selected.map(toPaprikaYaml), null, 2);
      download(name, text, type);
      st().textContent = 'Server unreachable — saved an offline-generated fallback instead.';
    }
  })());
  (document.getElementById('importform') as HTMLFormElement).addEventListener('submit', (e) => {
    e.preventDefault();
    const statusEl = () => document.getElementById('importstatus')!;
    const file = (document.getElementById('importfile') as HTMLInputElement).files?.[0];
    if (!file) {
      statusEl().textContent = 'Choose a file to import.';
      return;
    }
    const sel = (document.getElementById('importformat') as HTMLSelectElement).value;
    const format: ImportFormat = sel === 'auto' ? inferImportFormat(file.name) : (sel as ImportFormat);
    const importCookbooks = (document.getElementById('importcookbooks') as HTMLInputElement).checked;
    const dryRun = (document.getElementById('importdryrun') as HTMLInputElement).checked;
    statusEl().textContent = `Importing ${file.name} (${format})…`;
    void (async () => {
      const buf = new Uint8Array(await file.arrayBuffer());
      try {
        const report = await api.importReport({ format, payload: bytesToBase64(buf), importCookbooks, dryRun });
        if (!dryRun) {
          const now = new Date().toISOString();
          for (const r of report.imported ?? []) {
            store.applyRemote({
              id: r.id, updatedAt: r.updatedAt ?? now, deviceId: (r.deviceId as string | undefined) ?? 'server',
              entity: 'recipe', payload: r,
            } as SyncEnvelope);
          }
          render();
        }
        const warns = report.warnings?.length ? ` Warnings: ${report.warnings.join('; ')}` : '';
        const preview = dryRun && report.imported?.length
          ? ` Preview: ${report.imported.map((r) => r.title).slice(0, 5).join(', ')}${report.imported.length > 5 ? '…' : ''}.`
          : '';
        const cooks = report.cookbooksCreated?.length ? ` Cookbooks: ${report.cookbooksCreated.join(', ')}.` : '';
        statusEl().textContent = `${dryRun ? 'Dry run — ' : ''}imported ${report.imported?.length ?? 0}, updated ${report.updated ?? 0}.${preview}${cooks}${warns}`;
      } catch (err) {
        // Offline fallback: parse text-based formats locally, save via upsert.
        try {
          const { recipes, warnings } = await parseOfflineImport(buf, file.name, importCookbooks);
          if (!dryRun) {
            for (const input of recipes) store.upsert('recipe', '', { ...input, servings: input.servings ?? 4 });
            render();
          }
          const names = recipes.map((r) => r.title).slice(0, 5).join(', ') + (recipes.length > 5 ? '…' : '');
          const warnStr = warnings.length ? ` Warnings: ${warnings.join('; ')}` : '';
          statusEl().textContent = `${dryRun ? 'Dry run (offline) — ' : 'Saved offline — '}parsed ${recipes.length} recipe(s)${recipes.length ? `: ${names}.` : '.'} Server unreachable (${err instanceof Error ? err.message : err}).${warnStr}`;
        } catch (fallbackErr) {
          statusEl().textContent = `Import failed: ${fallbackErr instanceof Error ? fallbackErr.message : fallbackErr}`;
        }
      }
    })();
  });
}

initRouter(render);
render();
