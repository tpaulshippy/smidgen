// Keep Cooking — Lane 2 iOS Foundation
// apps/ios/App/KeepCookingApp.swift
//
// Adaptive shell: iPhone = TabView (Recipes / Plan / Lists / More),
// iPad = NavigationSplitView sidebar + detail. iOS 17+.
//
// Rules: views never touch the network directly — they call
// `await syncCoordinator.sync()` (SyncEngine) from .task / .refreshable.
// Features/* stays stub-owned: tabs show Lane 2 list placeholders backed by
// SwiftData @Query so Lane 3+ can swap in real feature views.

import SwiftUI
import SwiftData

@main
struct KeepCookingApp: App {
    /// Model types in the Lane 2 schema (passed as an array — the
    /// Scene `modelContainer(for:)` overload takes `[any PersistentModel.Type]`).
    static var modelTypes: [any PersistentModel.Type] {
        [Recipe.self,
         Ingredient.self,
         Step.self,
         ShoppingList.self,
         ListItem.self,
         PantryItem.self,
         Plan.self,
         Menu.self,
         // Lane 5 models (LibraryModels.swift): Cookbook/SavedSearch must be
         // registered or @Query(Cookbook)/@Query(SavedSearch) traps at runtime.
         Cookbook.self,
         SavedSearch.self]
    }

    var body: some Scene {
        WindowGroup {
            AdaptiveShell()
        }
        // Offline-first store: local SwiftData is the source of truth.
        // CloudKit mirror arrives later via CloudKitMirrorStub (SyncEngine).
        .modelContainer(for: KeepCookingApp.modelTypes)
    }
}

// MARK: - Adaptive shell

struct AdaptiveShell: View {
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.modelContext) private var context
    /// Set when a Files/Mail file tap stages an importable document.
    @State private var showImport = false
    /// Share-extension deep link (smidgen://clip?url=...). Hoisted here so
    /// BOTH idioms (phone drawer + PadSplitView) present the Clip review flow.
    @State private var clipLink = ClipDeepLink.shared
    @State private var clipURL: String? = nil
    @State private var showClip = false

    var body: some View {
        Group {
            #if os(iOS)
            if UIDevice.current.userInterfaceIdiom == .pad || sizeClass == .regular {
                PadSplitView()
            } else {
                PhoneTabView()
            }
            #else
            PhoneTabView()
            #endif
        }
        // Files/Mail taps of .paprikarecipes/.paprikarecipe/.yml/.yaml stage
        // via ImportPendingStore; ImportView consumes the staged file on appear.
        .modifier(ImportURLHandler(onFile: { url in
            if ImportPendingStore.stage(url) { showImport = true }
        }))
        // Share extension "Open in Keep Cooking" (smidgen://clip?url=...).
        // ImportURLHandler ignores non-file URLs; this claims only host `clip`.
        .onOpenURL { url in
            _ = ClipDeepLink.shared.open(url)
        }
        .sheet(isPresented: $showImport) { ImportView() }
        // Deep-link arrivals: present Clip review above whichever idiom
        // is showing (phone drawer or iPad split). The .id() re-creates the
        // ClipView per URL so a second link arriving while the sheet is open
        // replaces the flow instead of being consumed and discarded.
        .sheet(isPresented: $showClip, onDismiss: { clipURL = nil }) {
            ClipView(urlText: clipURL ?? "")
                .id(clipURL ?? "clip-empty")
        }
        .onChange(of: clipLink.pendingURL) { _, newValue in
            guard let newValue else { return }
            clipURL = newValue
            clipLink.pendingURL = nil
            showClip = true
        }
        .task {
            // Airplane-mode demo: seeds load once, then sync when online.
            await SyncCoordinator.shared.seedIfNeeded(context: context)
        }
    }
}

// MARK: - iPhone: Paprika-inspired drawer + pill shell (Lane A)

struct PhoneTabView: View {
    var body: some View {
        DrawerShellView()
    }
}

// MARK: - iPad: NavigationSplitView

struct PadSplitView: View {
    @Query private var recipes: [Recipe]
    @State private var selection: PadSection? = .recipes
    @State private var recipeSelectionId: String?

    var body: some View {
        NavigationSplitView {
            List(PadSection.allCases, selection: $selection) { section in
                NavigationLink(value: section) {
                    Label(section.title, systemImage: section.icon)
                }
            }
            .navigationTitle("Keep Cooking")
        } content: {
            switch selection ?? .recipes {
            case .recipes:
                RecipeListPlaceholder(selectionId: $recipeSelectionId)
            case .plan:
                PlanListPlaceholder()
            case .lists:
                ListsPlaceholder()
            case .more:
                MorePlaceholder()
            }
        } detail: {
            if selection == .recipes,
               let id = recipeSelectionId,
               let recipe = recipes.first(where: { $0.id == id })
            {
                RecipeDetailPlaceholder(recipe: recipe)
            } else {
                ContentUnavailableView("Pick something", systemImage: "frying.pan",
                                       description: Text("Select an item to see details."))
            }
        }
    }
}

enum PadSection: String, Hashable, CaseIterable, Identifiable {
    case recipes, plan, lists, more
    var id: String { rawValue }
    var title: String {
        switch self {
        case .recipes: return "Recipes"
        case .plan: return "Plan"
        case .lists: return "Lists"
        case .more: return "More"
        }
    }
    var icon: String {
        switch self {
        case .recipes: return "book.pages"
        case .plan: return "calendar"
        case .lists: return "cart"
        case .more: return "ellipsis.circle"
        }
    }
}

// MARK: - Placeholders (Lane 2 owns shell; Features/* owns real views)

/// Recipes tab / iPad content column. Live SwiftData, zero network.
struct RecipeListPlaceholder: View {
    @Query(filter: #Predicate<Recipe> { !$0.tombstoned },
           sort: [SortDescriptor(\Recipe.updatedAt, order: .reverse)])
    private var recipes: [Recipe]
    @Binding private var selectionId: String?

    init(selectionId: Binding<String?> = .constant(nil)) {
        _selectionId = selectionId
    }

    var body: some View {
        Group {
            if recipes.isEmpty {
                ContentUnavailableView("No recipes yet", systemImage: "book.pages",
                    description: Text("Seeds load on first launch — airplane mode works."))
            } else {
                List(recipes, id: \.id, selection: $selectionId) { recipe in
                    VStack(alignment: .leading) {
                        Text(recipe.title).font(.headline)
                        Text("\(recipe.ingredients.count) ingredients · \(recipe.steps.count) steps")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Recipes")
        .refreshable { await SyncCoordinator.shared.sync() }
    }
}

struct RecipeDetailPlaceholder: View {
    let recipe: Recipe
    var body: some View {
        List {
            Section("Ingredients") {
                ForEach(recipe.ingredients.sorted(by: { $0.position < $1.position })) { ing in
                    Text(ing.display.isEmpty ? ing.name : ing.display)
                }
            }
            Section("Steps") {
                ForEach(recipe.steps.sorted(by: { $0.position < $1.position })) { step in
                    Text(step.text)
                }
            }
        }
        .navigationTitle(recipe.title)
    }
}

struct PlanListPlaceholder: View {
    @Query(filter: #Predicate<Plan> { !$0.tombstoned },
           sort: [SortDescriptor(\Plan.date)])
    private var plans: [Plan]
    var body: some View {
        Group {
            if plans.isEmpty {
                ContentUnavailableView("No plans yet", systemImage: "calendar",
                    description: Text("Meal plans you add will appear here, offline-first."))
            } else {
                List(plans) { plan in
                    HStack {
                        Text(plan.mealRaw.capitalized).font(.headline)
                        Spacer()
                        Text(plan.date, style: .date).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Plan")
        .refreshable { await SyncCoordinator.shared.sync() }
    }
}

struct ListsPlaceholder: View {
    @Query(filter: #Predicate<ShoppingList> { !$0.tombstoned },
           sort: [SortDescriptor(\ShoppingList.updatedAt, order: .reverse)])
    private var lists: [ShoppingList]
    var body: some View {
        Group {
            if lists.isEmpty {
                ContentUnavailableView("No lists yet", systemImage: "cart",
                    description: Text("Shopping lists sync across devices when online."))
            } else {
                List(lists) { list in
                    VStack(alignment: .leading) {
                        Text(list.name).font(.headline)
                        Text("\(list.items.count) items").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Lists")
        .refreshable { await SyncCoordinator.shared.sync() }
    }
}

struct MorePlaceholder: View {
    var body: some View {
        List {
            Section("Add") {
                NavigationLink("Import file") { ImportView() }
                    .accessibilityIdentifier("more-import-file")
            }
            Section("Library") {
                NavigationLink("Export") { RecipeExportView() }
                    .accessibilityIdentifier("more-export")
                NavigationLink {
                    LibraryHomeView()
                } label: {
                    Label("Search, categories & cookbooks", systemImage: "square.stack.3d.up")
                }
                NavigationLink {
                    PantryTabView()
                } label: {
                    Label("Pantry", systemImage: "refrigerator")
                }
                NavigationLink {
                    MenusTabView()
                } label: {
                    Label("Menus", systemImage: "list.bullet.rectangle")
                }
                NavigationLink {
                    SettingsView()
                } label: {
                    Label("Settings", systemImage: "gear")
                }
            }
            Section("Sync") {
                SyncStatusRow()
            }
        }
        .navigationTitle("More")
    }
}

// MARK: - Sync status + coordinator (views talk ONLY to this)

struct SyncStatusRow: View {
    // Reads the coordinator's result directly (no local snapshot): the row
    // refreshes on every sync instead of freezing the first value it saw.
    var body: some View {
        HStack {
            Text("Status")
            Spacer()
            Text(SyncCoordinator.shared.lastResult).foregroundStyle(.secondary)
        }
    }
}

/// @MainActor bridge between SwiftUI views and the SyncEngine actor.
/// Owns deviceId, transport base URL + beta token, and one-shot seeding.
/// `sync()` is real: collects local SwiftData rows as envelopes, pulls
/// remote changes (LWW in SyncEngine), applies winners to SwiftData.
/// Beta scale note: pushes the full local set each run (idempotent LWW);
/// fine for households, revisited if volumes ever demand deltas.
@MainActor
@Observable
final class SyncCoordinator {
    static let shared = SyncCoordinator()
    private(set) var lastResult: String = "never synced"
    private var seeded = false
    private var modelContext: ModelContext?

    func seedIfNeeded(context: ModelContext) async {
        modelContext = context
        guard !seeded else { return }
        seeded = true
        let count = (try? context.fetchCount(FetchDescriptor<Recipe>())) ?? 0
        if count == 0 {
            let loader = SeedLoader(deviceId: currentDeviceId())
            let res = loader.loadBundledSeeds(into: context)
            lastResult = "seeded \(res.loaded) recipes (offline demo)"
        }
        // Demo week plans (idempotent) so Plan → list records deterministically.
        DemoSeeds.seedDemoPlans(context: context, deviceId: currentDeviceId())
        // E2E identity is auto-generated on first launch so there is always a
        // key to share — the user never sees key setup, only Devices sharing.
        let household = E2EKeyStore.loadMetadata()?.householdId ?? "hh-demo"
        _ = e2eEnsureIdentity(householdId: household)
    }

    func sync() async {
        guard let ctx = modelContext else {
            lastResult = "sync not ready — reopen the app"
            return
        }
        guard let base = SyncConfig.baseURL else {
            lastResult = "sync unavailable — check connection"
            return
        }
        // Device identity: persisted UUIDv4 + Ed25519 key (DeviceAuth.swift).
        // identifierForVendor is a display hint only — the device key is the
        // identity. Enrollment is idempotent and best-effort (offline safe).
        // Re-read the id afterwards: 409 recovery rotates it.
        let did = DeviceAuth.currentDeviceId()
        await DeviceAuth.enrollIfNeeded(baseURL: base, deviceId: did)
        let enrolledId = DeviceAuth.currentDeviceId()
        let signer = DeviceAuth.requestSigner(deviceId: enrolledId)
        let auth = SyncAuth(betaToken: nil,
                            userId: SyncConfig.userId, deviceId: enrolledId)
        let transport = APISyncTransport(baseURL: base, auth: auth, signer: signer)
        let engine = SyncEngine(deviceId: enrolledId, transport: transport)
        do {
            for env in try collectEnvelopes(ctx: ctx) {
                await engine.enqueue(env)
            }
            let box = SyncEnvelopeBox()
            // E2E by default: an auto-generated per-install identity routes
            // sync to this install's opaque hash bucket (blind server), so
            // installs never share a plaintext household. Falls back to
            // legacy v1 only when no identity exists (Keychain unavailable).
            let household = E2EKeyStore.loadMetadata()?.householdId ?? "hh-demo"
            _ = e2eEnsureIdentity(householdId: household)
            let res = try await engine.syncRouted(
                route: resolveSyncRoute(),
                e2eTransport: APIE2ETransport(baseURL: base, auth: auth, signer: signer),
                applyRemote: { box.append($0) })
            for env in box.all { applyEnvelope(env, ctx: ctx) }
            try? ctx.save()
            if res.conflicts > 0 {
                lastResult = "synced \(box.all.count) down · \(res.pushed) up · \(res.conflicts) server-won"
            } else {
                lastResult = "synced \(box.all.count) down · \(res.pushed) up"
            }
        } catch let e as SyncTransportError {
            switch e {
            case .httpStatus(401):
                lastResult = "unauthorized — sync failed"
            case .httpStatus(let code):
                lastResult = "sync failed (HTTP \(code))"
            default:
                lastResult = "sync failed (transport)"
            }
        } catch {
            lastResult = "sync failed (\(error.localizedDescription))"
        }
    }

    func describe() async -> String { lastResult }

    /// Persisted UUIDv4 device id (DeviceAuth). identifierForVendor is a
    /// display hint only (see DeviceAuth.displayHint) — the device key is
    /// the identity.
    private func currentDeviceId() -> String {
        DeviceAuth.currentDeviceId()
    }
}

// MARK: - Sync endpoint (out of the box; Advanced override only)

enum SyncConfig {
    static let prodBaseURL = "https://keepcooking.app/api"

    static var baseURL: URL? {
        if let o = UserDefaults.standard.string(forKey: "smidgen.apiBaseURL"),
           !o.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(string: o.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if let s = Bundle.main.object(forInfoDictionaryKey: "SMIDGEN_API_BASE_URL") as? String,
           !s.isEmpty {
            return URL(string: s)
        }
        return URL(string: prodBaseURL)
    }

    static var baseURLString: String { baseURL?.absoluteString ?? prodBaseURL }

    /// Shared household identity (beta default beta-user; no login).
    static var userId: String {
        let s = UserDefaults.standard.string(forKey: "smidgen.userId") ?? ""
        return s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "beta-user" : s
    }
}

extension String {
    /// Empty/blank strings become nil (so "no token" never sends `Bearer `).
    var nilIfEmpty: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}

/// Day-precision formatter for plan dates / pantry expiry (server TEXT 'YYYY-MM-DD', UTC).
private let syncDayFormatter: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(secondsFromGMT: 0)
    f.dateFormat = "yyyy-MM-dd"
    return f
}()

/// Sendable collector so the @Sendable applyRemote closure can hand winning
/// remote envelopes back to the @MainActor coordinator for SwiftData apply.
final class SyncEnvelopeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [SyncEnvelope] = []
    func append(_ envelope: SyncEnvelope) {
        lock.withLock { values.append(envelope) }
    }
    var all: [SyncEnvelope] {
        lock.withLock { values }
    }
}

// MARK: - SwiftData <-> SyncEnvelope mapping (MainActor: touches models)

extension SyncCoordinator {
    func collectEnvelopes(ctx: ModelContext) throws -> [SyncEnvelope] {
        var out: [SyncEnvelope] = []
        out += try ctx.fetch(FetchDescriptor<Recipe>()).map(recipeEnvelope)
        out += try ctx.fetch(FetchDescriptor<ShoppingList>()).map(listEnvelope)
        out += try ctx.fetch(FetchDescriptor<PantryItem>()).map(pantryEnvelope)
        out += try ctx.fetch(FetchDescriptor<Plan>()).map(planEnvelope)
        out += try ctx.fetch(FetchDescriptor<Menu>()).map(menuEnvelope)
        return out
    }

    func recipeEnvelope(_ r: Recipe) -> SyncEnvelope {
        var payload: [String: JSONValue] = [
            "householdId": .string(r.householdId),
            "title": .string(r.title),
            "description": .string(r.recipeDescription),
            "servings": .double(r.servings),
            "source": .string(r.source),
            "sourceUrl": .string(r.sourceUrl),
            "categories": .from(r.categories),
            "photoKeys": .object([
                "original": .string(r.photoOriginal ?? ""),
                "large1024": .string(r.photoLarge1024 ?? ""),
                "thumb": .string(r.photoThumb ?? ""),
            ]),
        ]
        if let v = r.prepMinutes { payload["prepMinutes"] = .int(v) }
        if let v = r.cookMinutes { payload["cookMinutes"] = .int(v) }
        if let v = r.totalMinutes { payload["totalMinutes"] = .int(v) }
        if let v = r.rating { payload["rating"] = .double(v) }
        if let v = r.difficulty, !v.isEmpty { payload["difficulty"] = .string(v) }
        if let v = r.notes, !v.isEmpty { payload["notes"] = .string(v) }
        if let v = r.nutritionText, !v.isEmpty { payload["nutritionText"] = .string(v) }
        payload["isFavorite"] = .bool(r.isFavorite)
        payload["ingredients"] = .array(r.ingredients.map { ing in
            .object([
                "id": .string(ing.id),
                "name": .string(ing.name),
                "quantity": ing.quantity.map { JSONValue.double($0) } ?? .null,
                "unit": .string(ing.unit),
                "display": .string(ing.display),
                "position": .int(ing.position),
                "recipeId": .string(r.id),
            ])
        })
        payload["steps"] = .array(r.steps.map { st in
            .object([
                "id": .string(st.id),
                "position": .int(st.position),
                "text": .string(st.text),
                "timers": .array(st.timers.map { t in
                    .object(["seconds": .int(t.seconds), "label": .string(t.label)])
                }),
                "recipeId": .string(r.id),
            ])
        })
        return SyncEnvelope(id: r.id, updatedAt: r.updatedAt, deviceId: r.deviceId,
                            deleted: r.tombstoned, entity: .recipe, payload: payload)
    }

    func listEnvelope(_ l: ShoppingList) -> SyncEnvelope {
        let payload: [String: JSONValue] = [
            "householdId": .string(l.householdId),
            "name": .string(l.name),
            "items": .array(l.items.map { it in
                .object([
                    "id": .string(it.id),
                    "name": .string(it.name),
                    "quantity": .string(it.quantity),
                    "aisle": .string(it.aisle),
                    "checked": .bool(it.checked),
                    "recipeId": it.recipeId.map { JSONValue.string($0) } ?? .null,
                ])
            }),
        ]
        return SyncEnvelope(id: l.id, updatedAt: l.updatedAt, deviceId: l.deviceId,
                            deleted: l.tombstoned, entity: .list, payload: payload)
    }

    func pantryEnvelope(_ p: PantryItem) -> SyncEnvelope {
        let payload: [String: JSONValue] = [
            "householdId": .string(p.householdId),
            "name": .string(p.name),
            "quantity": .string(p.quantity),
            "location": .string(p.location),
            "expiresAt": p.expiresAt.map { JSONValue.string(syncDayFormatter.string(from: $0)) } ?? .null,
            "lowThreshold": .string(p.lowThreshold),
            "barcode": .string(p.barcode),
        ]
        return SyncEnvelope(id: p.id, updatedAt: p.updatedAt, deviceId: p.deviceId,
                            deleted: p.tombstoned, entity: .pantryItem, payload: payload)
    }

    func planEnvelope(_ p: Plan) -> SyncEnvelope {
        let payload: [String: JSONValue] = [
            "householdId": .string(p.householdId),
            "date": .string(syncDayFormatter.string(from: p.date)),
            "meal": .string(p.mealRaw),
            "recipeId": p.recipeId.map { JSONValue.string($0) } ?? .null,
            "note": .string(p.note),
            "servings": p.servings.map { JSONValue.double($0) } ?? .null,
        ]
        return SyncEnvelope(id: p.id, updatedAt: p.updatedAt, deviceId: p.deviceId,
                            deleted: p.tombstoned, entity: .plan, payload: payload)
    }

    func menuEnvelope(_ m: Menu) -> SyncEnvelope {
        let payload: [String: JSONValue] = [
            "householdId": .string(m.householdId),
            "name": .string(m.name),
            "entries": .array(m.entries.map { e in
                .object([
                    "dayOffset": .int(e.dayOffset),
                    "meal": .string(e.meal),
                    "recipeId": .string(e.recipeId),
                    "servings": .double(e.servings),
                ])
            }),
        ]
        return SyncEnvelope(id: m.id, updatedAt: m.updatedAt, deviceId: m.deviceId,
                            deleted: m.tombstoned, entity: .menu, payload: payload)
    }

    // MARK: Apply (remote-won envelopes land in SwiftData; upsert by id)

    func applyEnvelope(_ env: SyncEnvelope, ctx: ModelContext) {
        switch env.entity {
        case .recipe: applyRecipe(env, ctx: ctx)
        case .list: applyList(env, ctx: ctx)
        case .pantryItem: applyPantry(env, ctx: ctx)
        case .plan: applyPlan(env, ctx: ctx)
        case .menu: applyMenu(env, ctx: ctx)
        case .ingredient, .step:
            break // children ride inside recipe envelopes (see applyRecipe)
        }
    }

    func applyRecipe(_ env: SyncEnvelope, ctx: ModelContext) {
        let p = env.payload
        let str = { (k: String) in p[k]?.stringValue }
        if let r = (try? ctx.fetch(FetchDescriptor<Recipe>()))?.first(where: { $0.id == env.id }) {
            if let v = str("title"), !v.isEmpty { r.title = v }
            if let v = p["description"]?.stringValue { r.recipeDescription = v }
            if let v = p["servings"]?.doubleValue { r.servings = v }
            if let v = p["prepMinutes"]?.intValue { r.prepMinutes = v }
            if let v = p["cookMinutes"]?.intValue { r.cookMinutes = v }
            if let v = p["totalMinutes"]?.intValue { r.totalMinutes = v }
            if let v = p["rating"]?.doubleValue { r.rating = v }
            // Editor metadata: key-present (not just non-nil) distinguishes
            // "leave alone" from "cleared"; empty difficulty means unspecified.
            if p.keys.contains("difficulty") {
                r.difficulty = str("difficulty").flatMap { $0.isEmpty ? nil : $0 }
            }
            if p.keys.contains("notes") { r.notes = str("notes") }
            if p.keys.contains("nutritionText") { r.nutritionText = str("nutritionText") }
            if let v = p["isFavorite"]?.boolValue { r.isFavorite = v }
            if let v = str("source") { r.source = v }
            if let v = str("sourceUrl") { r.sourceUrl = v }
            if let v = p["categories"]?.arrayValue { r.categories = v.compactMap { $0.stringValue } }
            if let keys = p["photoKeys"]?.objectValue {
                r.photoOriginal = keys["original"]?.stringValue
                r.photoLarge1024 = keys["large1024"]?.stringValue
                r.photoThumb = keys["thumb"]?.stringValue
            }
            if let ings = p["ingredients"]?.arrayValue {
                for old in r.ingredients { ctx.delete(old) }
                r.ingredients.removeAll()
                for (i, j) in ings.enumerated() {
                    guard let o = j.objectValue else { continue }
                    let ing = Ingredient(recipeId: r.id,
                        name: o["name"]?.stringValue ?? "",
                        quantity: o["quantity"]?.doubleValue,
                        unit: o["unit"]?.stringValue ?? "",
                        display: o["display"]?.stringValue ?? "",
                        position: o["position"]?.intValue ?? i,
                        updatedAt: env.updatedAt, deviceId: env.deviceId)
                    ing.recipe = r
                    ctx.insert(ing)
                }
            }
            if let steps = p["steps"]?.arrayValue {
                for old in r.steps { ctx.delete(old) }
                r.steps.removeAll()
                for (i, j) in steps.enumerated() {
                    guard let o = j.objectValue else { continue }
                    let timers = o["timers"]?.arrayValue?.compactMap { t -> StepTimer? in
                        guard let to = t.objectValue, let s = to["seconds"]?.intValue else { return nil }
                        return StepTimer(seconds: s, label: to["label"]?.stringValue ?? "")
                    } ?? []
                    let st = Step(recipeId: r.id, position: o["position"]?.intValue ?? i,
                        text: o["text"]?.stringValue ?? "", timers: timers,
                        updatedAt: env.updatedAt, deviceId: env.deviceId)
                    st.recipe = r
                    ctx.insert(st)
                }
            }
            r.updatedAt = env.updatedAt
            r.deviceId = env.deviceId
            r.tombstoned = env.deleted
        } else {
            let r = Recipe(id: env.id, householdId: str("householdId") ?? "hh-demo",
                title: str("title") ?? "Untitled",
                recipeDescription: p["description"]?.stringValue ?? "",
                servings: p["servings"]?.doubleValue ?? 4,
                prepMinutes: p["prepMinutes"]?.intValue,
                cookMinutes: p["cookMinutes"]?.intValue,
                rating: p["rating"]?.doubleValue,
                isFavorite: p["isFavorite"]?.boolValue ?? false,
                source: str("source") ?? "", sourceUrl: str("sourceUrl") ?? "",
                categories: p["categories"]?.arrayValue?.compactMap { $0.stringValue } ?? [],
                photoOriginal: p["photoKeys"]?.objectValue?["original"]?.stringValue,
                photoLarge1024: p["photoKeys"]?.objectValue?["large1024"]?.stringValue,
                photoThumb: p["photoKeys"]?.objectValue?["thumb"]?.stringValue,
                difficulty: str("difficulty"),
                notes: str("notes"),
                nutritionText: str("nutritionText"),
                totalMinutes: p["totalMinutes"]?.intValue,
                updatedAt: env.updatedAt, deviceId: env.deviceId, tombstoned: env.deleted)
            ctx.insert(r)
            for (i, j) in (p["ingredients"]?.arrayValue ?? []).enumerated() {
                guard let o = j.objectValue else { continue }
                let ing = Ingredient(id: o["id"]?.stringValue ?? UUID().uuidString,
                    recipeId: r.id, name: o["name"]?.stringValue ?? "",
                    quantity: o["quantity"]?.doubleValue,
                    unit: o["unit"]?.stringValue ?? "",
                    display: o["display"]?.stringValue ?? "",
                    position: o["position"]?.intValue ?? i,
                    updatedAt: env.updatedAt, deviceId: env.deviceId)
                ing.recipe = r
                ctx.insert(ing)
            }
            for (i, j) in (p["steps"]?.arrayValue ?? []).enumerated() {
                guard let o = j.objectValue else { continue }
                let st = Step(id: o["id"]?.stringValue ?? UUID().uuidString,
                    recipeId: r.id, position: o["position"]?.intValue ?? i,
                    text: o["text"]?.stringValue ?? "", updatedAt: env.updatedAt,
                    deviceId: env.deviceId)
                st.recipe = r
                ctx.insert(st)
            }
        }
    }

    func applyList(_ env: SyncEnvelope, ctx: ModelContext) {
        let p = env.payload
        if let l = (try? ctx.fetch(FetchDescriptor<ShoppingList>()))?.first(where: { $0.id == env.id }) {
            if let v = p["name"]?.stringValue, !v.isEmpty { l.name = v }
            if let items = p["items"]?.arrayValue {
                for old in l.items { ctx.delete(old) }
                l.items.removeAll()
                for j in items {
                    guard let o = j.objectValue else { continue }
                    let it = ListItem(id: o["id"]?.stringValue ?? UUID().uuidString,
                        listId: l.id, name: o["name"]?.stringValue ?? "",
                        quantity: o["quantity"]?.stringValue ?? "",
                        aisle: o["aisle"]?.stringValue ?? "",
                        checked: o["checked"]?.boolValue ?? false,
                        recipeId: o["recipeId"]?.stringValue,
                        updatedAt: env.updatedAt, deviceId: env.deviceId)
                    it.shoppingList = l
                    ctx.insert(it)
                }
            }
            l.updatedAt = env.updatedAt
            l.deviceId = env.deviceId
            l.tombstoned = env.deleted
        } else {
            let l = ShoppingList(id: env.id,
                householdId: p["householdId"]?.stringValue ?? "hh-demo",
                name: p["name"]?.stringValue ?? "List",
                updatedAt: env.updatedAt, deviceId: env.deviceId, tombstoned: env.deleted)
            ctx.insert(l)
            for j in p["items"]?.arrayValue ?? [] {
                guard let o = j.objectValue else { continue }
                let it = ListItem(id: o["id"]?.stringValue ?? UUID().uuidString,
                    listId: l.id, name: o["name"]?.stringValue ?? "",
                    quantity: o["quantity"]?.stringValue ?? "",
                    aisle: o["aisle"]?.stringValue ?? "",
                    checked: o["checked"]?.boolValue ?? false,
                    recipeId: o["recipeId"]?.stringValue,
                    updatedAt: env.updatedAt, deviceId: env.deviceId)
                it.shoppingList = l
                ctx.insert(it)
            }
        }
    }

    func applyPantry(_ env: SyncEnvelope, ctx: ModelContext) {
        let p = env.payload
        let day: Date? = p["expiresAt"]?.stringValue.flatMap { syncDayFormatter.date(from: $0) }
        if let item = (try? ctx.fetch(FetchDescriptor<PantryItem>()))?.first(where: { $0.id == env.id }) {
            if let v = p["name"]?.stringValue, !v.isEmpty { item.name = v }
            if let v = p["quantity"]?.stringValue { item.quantity = v }
            if let v = p["location"]?.stringValue { item.location = v }
            if p["expiresAt"] != nil { item.expiresAt = day }
            if let v = p["lowThreshold"]?.stringValue { item.lowThreshold = v }
            if let v = p["barcode"]?.stringValue { item.barcode = v }
            item.updatedAt = env.updatedAt
            item.deviceId = env.deviceId
            item.tombstoned = env.deleted
        } else {
            ctx.insert(PantryItem(id: env.id,
                householdId: p["householdId"]?.stringValue ?? "hh-demo",
                name: p["name"]?.stringValue ?? "",
                quantity: p["quantity"]?.stringValue ?? "",
                location: p["location"]?.stringValue ?? "",
                expiresAt: day,
                lowThreshold: p["lowThreshold"]?.stringValue ?? "",
                barcode: p["barcode"]?.stringValue ?? "",
                updatedAt: env.updatedAt, deviceId: env.deviceId, tombstoned: env.deleted))
        }
    }

    func applyPlan(_ env: SyncEnvelope, ctx: ModelContext) {
        let p = env.payload
        let date = p["date"]?.stringValue.flatMap { syncDayFormatter.date(from: $0) } ?? Date()
        let meal = MealSlot(rawValue: p["meal"]?.stringValue ?? "") ?? .dinner
        if let plan = (try? ctx.fetch(FetchDescriptor<Plan>()))?.first(where: { $0.id == env.id }) {
            plan.date = date
            plan.meal = meal
            if p["recipeId"] != nil { plan.recipeId = p["recipeId"]?.stringValue }
            if let v = p["note"]?.stringValue { plan.note = v }
            if p["servings"] != nil { plan.servings = p["servings"]?.doubleValue }
            plan.updatedAt = env.updatedAt
            plan.deviceId = env.deviceId
            plan.tombstoned = env.deleted
        } else {
            ctx.insert(Plan(id: env.id,
                householdId: p["householdId"]?.stringValue ?? "hh-demo",
                date: date, meal: meal,
                recipeId: p["recipeId"]?.stringValue,
                note: p["note"]?.stringValue ?? "",
                servings: p["servings"]?.doubleValue,
                updatedAt: env.updatedAt, deviceId: env.deviceId, tombstoned: env.deleted))
        }
    }

    func applyMenu(_ env: SyncEnvelope, ctx: ModelContext) {
        let p = env.payload
        let entries: [MenuEntry] = (p["entries"]?.arrayValue ?? []).compactMap { j in
            guard let o = j.objectValue else { return nil }
            return MenuEntry(dayOffset: o["dayOffset"]?.intValue ?? 0,
                meal: o["meal"]?.stringValue ?? "dinner",
                recipeId: o["recipeId"]?.stringValue ?? "",
                servings: o["servings"]?.doubleValue ?? 4)
        }
        if let m = (try? ctx.fetch(FetchDescriptor<Menu>()))?.first(where: { $0.id == env.id }) {
            if let v = p["name"]?.stringValue, !v.isEmpty { m.name = v }
            if p["entries"] != nil { m.entries = entries }
            m.updatedAt = env.updatedAt
            m.deviceId = env.deviceId
            m.tombstoned = env.deleted
        } else {
            ctx.insert(Menu(id: env.id,
                householdId: p["householdId"]?.stringValue ?? "hh-demo",
                name: p["name"]?.stringValue ?? "Menu", entries: entries,
                updatedAt: env.updatedAt, deviceId: env.deviceId, tombstoned: env.deleted))
        }
    }
}
// MARK: - Clip deep link (Share extension "Open in Keep Cooking")

/// Tiny router for `smidgen://clip?url=<pct-encoded>` (Share extension
/// "Open in Keep Cooking"). The extension also enqueues into ShareStore
/// (App Group group.com.smidgen.share); the URL query param is the primary
/// path, ShareStore.drain() stays the fallback when it is absent/undecodable.
/// Only host `clip` is claimed — `smidgen://invite/<code>` (LibraryModels/
/// Library README stub) and everything else is ignored here.
@MainActor
@Observable
final class ClipDeepLink {
    static let shared = ClipDeepLink()
    /// Set when a clip link arrives; DrawerShellView consumes + clears it.
    var pendingURL: String? = nil

    @discardableResult
    func open(_ url: URL) -> Bool {
        guard let clipped = Self.clippedURL(from: url) else { return false }
        // The extension already enqueued this URL into ShareStore; consume
        // the matching entry so a later manual Clip visit can't replay it.
        // Other queued URLs are preserved.
        ShareStore.consume(url: clipped)
        pendingURL = clipped
        return true
    }

    /// Validate + extract the recipe URL. Accepts only scheme `smidgen`,
    /// host `clip`, empty/`/` path, and a non-empty `url` query item
    /// (URLComponents already percent-decodes it).
    static func clippedURL(from url: URL) -> String? {
        guard url.scheme?.lowercased() == "smidgen",
              url.host?.lowercased() == "clip" else { return nil }
        let path = url.path
        guard path.isEmpty || path == "/" else { return nil }
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let raw = comps.queryItems?.first(where: { $0.name == "url" })?.value
        else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: - Drawer destinations (phone)

enum DrawerSection: String, CaseIterable, Identifiable {
    case recipes
    case plan
    case menus
    case lists
    case pantry
    case library
    case export
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .recipes: return "Recipes"
        case .plan: return "Plan"
        case .menus: return "Menus"
        case .lists: return "Shopping"
        case .pantry: return "Pantry"
        case .library: return "Library"
        case .export: return "Export"
        case .settings: return "Settings"
        }
    }

    var icon: String {
        switch self {
        case .recipes: return "book.pages"
        case .plan: return "calendar"
        case .menus: return "list.bullet.rectangle"
        case .lists: return "cart"
        case .pantry: return "refrigerator"
        case .library: return "square.stack.3d.up"
        case .export: return "square.and.arrow.up"
        case .settings: return "gear"
        }
    }

    /// Group label shown in the drawer above this row.
    var group: String? {
        switch self {
        case .recipes: return nil
        case .plan, .menus: return "Planner"
        case .lists, .pantry: return "Shopping"
        case .library: return "Organize"
        case .export: return "Organize"
        case .settings: return nil
        }
    }
}

enum QuickAddKind: String, Identifiable {
    case clip
    case scan
    case caption
    case importFile
    case paste

    var id: String { rawValue }
    var title: String {
        switch self {
        case .clip: return "Clip recipe URL"
        case .scan: return "Scan cookbook"
        case .caption: return "Import caption"
        case .importFile: return "Import file"
        case .paste: return "Paste text"
        }
    }
}

// MARK: - Phone drawer shell

struct DrawerShellView: View {
    @State private var selection: DrawerSection = .recipes
    @State private var drawerOpen = false
    @State private var quickAdd: QuickAddKind? = nil
    /// Blank-recipe request forwarded to the library (single + menu entry).
    @State private var requestBlankRecipe = false
    /// Recipe filter state (section + sheet + visible count): the top-bar
    /// center slot is the filter pill on Recipes, so it lives in the shell
    /// and is passed down. Filter SHEET UI stays in the library.
    @State private var librarySection: LibrarySection = .all
    @State private var showFilterSheet = false
    @State private var visibleRecipeCount = 0

    var body: some View {
        ZStack(alignment: .leading) {
            VStack(spacing: 0) {
                if selection != .menus {
                    topBar
                    Divider()
                }
                content
            }
            .background(Color(.systemBackground))
            // Swipe right from the leading edge opens the drawer;
            // swipe left on open drawer dismisses it.
            .gesture(drawerOpen ? nil : edgeOpenGesture)
            // While the drawer is open VoiceOver must not reach the
            // content dimmed behind the backdrop.
            .accessibilityHidden(drawerOpen)

            if drawerOpen {
                // Dimmed backdrop — tap to dismiss.
                Color.black.opacity(0.35)
                    .ignoresSafeArea()
                    .onTapGesture { closeDrawer() }
                    .accessibilityAddTraits(.isButton)
                    .accessibilityLabel("Dismiss navigation menu")
                drawerPanel
                    .transition(.move(edge: .leading))
                    .gesture(swipeToDismiss)
            }
        }
        .animation(.easeInOut(duration: 0.22), value: drawerOpen)
        // Each quick-add destination owns its own NavigationStack —
        // no outer stack here (avoids nested navigation chrome).
        .sheet(item: $quickAdd) { kind in
            switch kind {
            case .clip: ClipView()
            case .scan: OCRScanView()
            case .caption: CaptionsImportView()
            case .importFile: ImportView()
            case .paste: PasteImportView()
            }
        }
    }

    // MARK: Top bar — hamburger | pill | quick-add

    private var topBar: some View {
        HStack(spacing: 8) {
            Button {
                withAnimation { drawerOpen = true }
            } label: {
                Image(systemName: "line.3.horizontal")
                    .font(.body.weight(.semibold))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Open navigation menu")
            .accessibilityIdentifier("drawer-hamburger")

            Spacer(minLength: 0)

            // Center slot — contextual, single header. On Recipes it is the
            // FILTER pill (opens the filter sheet); everywhere else a plain
            // non-interactive section title. The drawer is the sole switcher.
            centerSlot

            Spacer(minLength: 0)

            SwiftUI.Menu {
                Button {
                    // Blank recipe lives in the library: switch there first
                    // (no-op if already visible) then trigger creation.
                    selection = .recipes
                    requestBlankRecipe = true
                } label: {
                    Label("Create New Recipe", systemImage: "square.and.pencil")
                }
                Button {
                    quickAdd = .clip
                } label: {
                    Label("Clip URL", systemImage: "link")
                }
                Button {
                    quickAdd = .scan
                } label: {
                    Label("Scan cookbook", systemImage: "text.viewfinder")
                }
                Button {
                    quickAdd = .caption
                } label: {
                    Label("Import caption", systemImage: "captions.bubble")
                }
                Button {
                    quickAdd = .importFile
                } label: {
                    Label("Import file", systemImage: "tray.and.arrow.down")
                }
                Button {
                    quickAdd = .paste
                } label: {
                    Label("Paste text", systemImage: "doc.on.clipboard")
                }
            } label: {
                Image(systemName: "plus")
                    .font(.body.weight(.semibold))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Quick add recipe")
            .accessibilityIdentifier("quick-add-button")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color(.systemBackground))
    }

    // MARK: Center slot — contextual single header

    /// "1 recipe" vs "N recipes" for the pill + VoiceOver.
    private var recipeCountText: String {
        visibleRecipeCount == 1 ? "1 recipe" : "\(visibleRecipeCount) recipes"
    }

    @ViewBuilder
    private var centerSlot: some View {
        if selection == .recipes {
            Button {
                showFilterSheet = true
            } label: {
                HStack(spacing: 4) {
                    Text(librarySection.title)
                        .font(.headline)
                        .lineLimit(1)
                    Text(recipeCountText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 8)
                .background(Color(.secondarySystemBackground))
                .clipShape(Capsule())
                .contentShape(Capsule())
                .frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityLabel("Recipe filter: \(librarySection.title), \(recipeCountText). Activate to change filter.")
            .accessibilityIdentifier("filter-pill")
        } else {
            Text(selection.title)
                .font(.headline)
                .lineLimit(1)
                .padding(.horizontal, 18)
                .padding(.vertical, 8)
                .background(Color(.secondarySystemBackground))
                .clipShape(Capsule())
                .frame(minWidth: 44, minHeight: 44)
                .accessibilityIdentifier("section-pill")
        }
    }

    // MARK: Content — existing feature views, unchanged behavior

    @ViewBuilder
    private var content: some View {
        Group {
            switch selection {
            case .recipes:
                RecipeLibraryView(
                    requestBlankRecipe: $requestBlankRecipe,
                    section: $librarySection,
                    showFilterSheet: $showFilterSheet,
                    visibleRecipeCount: $visibleRecipeCount
                )
            case .plan:
                PlanTabView()
            case .menus:
                MenusTabView(onOpenDrawer: { withAnimation { drawerOpen = true } })
            case .lists:
                ListsTabView()
            case .pantry:
                PantryTabView()
            case .library:
                LibraryHomeView()
            case .export:
                RecipeExportView()
            case .settings:
                SettingsView()
            }
        }
        // Content views own their own NavigationStacks; this id helps
        // SwiftUI reset scroll/search state on section switch.
        .id(selection)
    }

    // MARK: Drawer panel

    private var drawerPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            // App mark.
            HStack(spacing: 10) {
                Image(systemName: "fork.knife.circle.fill")
                    .font(.title)
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                Text("Keep Cooking")
                    .font(.title3.weight(.bold))
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 12)
            .safeAreaPadding(.top, 8)
            .accessibilityAddTraits(.isHeader)

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    drawerRow(.recipes)
                    drawerGroupHeader("Planner")
                    drawerRow(.plan)
                    drawerRow(.menus)
                    drawerGroupHeader("Shopping")
                    drawerRow(.lists)
                    drawerRow(.pantry)
                    drawerGroupHeader("Organize")
                    drawerRow(.library)
                    drawerRow(.export)
                    Divider().padding(.vertical, 8)
                    drawerRow(.settings)
                }
                .padding(.horizontal, 12)
            }

            Divider()
            // Sync status row at the bottom.
            SyncStatusRow()
                .font(.footnote)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
        }
        .frame(width: min(320, UIScreen.main.bounds.width * 0.84))
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 0))
        .overlay(alignment: .trailing) {
            // Vertical edge rule. NOTE: a bare Divider() here would be a
            // *horizontal* line vertically centered in the panel (Divider's
            // long axis is horizontal; `trailing` only pins the x-axis) —
            // that was the stray hairline across the Library row.
            Rectangle()
                .fill(Color(.separator))
                .frame(width: 1)
        }
        .ignoresSafeArea(edges: .bottom)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Navigation menu")
    }

    private func drawerGroupHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 4)
            .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder
    private func drawerRow(_ section: DrawerSection) -> some View {
        let active = selection == section
        Button {
            selection = section
            closeDrawer()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: section.icon)
                    .font(.body)
                    .frame(width: 24)
                    .accessibilityHidden(true)
                Text(section.title)
                    .font(.body)
                    .fontWeight(active ? .semibold : .regular)
                Spacer(minLength: 4)
                if active {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Color.accentColor)
                        .accessibilityHidden(true)
                }
            }
            .foregroundStyle(active ? Color.primary : Color.primary)
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(
                active
                    ? Color.accentColor.opacity(0.15)
                    : Color.clear,
                in: RoundedRectangle(cornerRadius: 12)
            )
        }
        .accessibilityLabel("\(section.title) section")
        .accessibilityAddTraits(active ? .isSelected : [])
        .accessibilityIdentifier("drawer-\(section.rawValue)")
    }

    // MARK: Gestures

    private var edgeOpenGesture: some Gesture {
        DragGesture(minimumDistance: 20, coordinateSpace: .local)
            .onEnded { value in
                // Rightward swipe starting near the leading edge opens.
                if value.startLocation.x < 24,
                   value.translation.width > 60,
                   abs(value.translation.height) < 60 {
                    withAnimation { drawerOpen = true }
                }
            }
    }

    private var swipeToDismiss: some Gesture {
        DragGesture(minimumDistance: 24, coordinateSpace: .local)
            .onEnded { value in
                if value.translation.width < -60,
                   abs(value.translation.height) < 80 {
                    closeDrawer()
                }
            }
    }

    private func closeDrawer() {
        withAnimation { drawerOpen = false }
    }
}
