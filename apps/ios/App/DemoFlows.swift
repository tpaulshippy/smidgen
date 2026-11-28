// Keep Cooking — PASS 2 demos
// apps/ios/App/DemoFlows.swift
//
// Wires the Lane 3/4 snapshot views (Clip/Caption/OCR, Plan, Shop, Cook)
// to live SwiftData so the three demo videos record the REAL app offline:
//   1. offline-launch — seeded recipes list with no backend configured.
//   2. ingest-save — OCRScanView: paste text → Parse → Save (fully local).
//   3. plan-to-list — PlanView week → "Add week to list" aggregates into an
//      aisle-sorted ShoppingList → check-off; cook mode reachable from detail.
//
// Accessibility identifiers (used by KeepCookingUITests):
//   recipe-list, recipe-detail-title, cook-button, add-to-list-button,
//   added-confirm, plan-view, week-to-list-confirm, lists-view,
//   more-clip, more-caption, more-paste, more-ocr (+ ocr-* ids in OCRScanView).

import SwiftUI
import SwiftData

// MARK: - Aisle guess (local heuristic for demo aggregation)

/// Keyword → canonical aisle (see ShopHelpers.canonicalAisles). Unknown → "".
func guessAisle(for name: String) -> String {
    let n = name.lowercased()
    let table: [(aisle: String, keys: [String])] = [
        ("produce", ["onion", "garlic", "tomato", "lettuce", "spinach", "carrot", "potato",
                     "avocado", "lemon", "lime", "herb", "basil", "cilantro", "parsley",
                     "mushroom", "pepper", "cucumber", "broccoli", "apple", "banana", "berry", "berries"]),
        ("bakery", ["bread", "baguette", "bun", "roll", "tortilla", "pita"]),
        ("dairy", ["milk", "cheese", "butter", "cream", "yogurt", "egg", "parmesan", "mozzarella"]),
        ("meat", ["chicken", "beef", "pork", "bacon", "sausage", "turkey"]),
        ("seafood", ["salmon", "tuna", "shrimp", "cod", "fish"]),
        ("frozen", ["frozen", "ice cream"]),
        ("canned", ["canned", "can ", "beans", "tomato paste", "broth", "stock"]),
        ("pasta", ["pasta", "spaghetti", "ramen", "noodle", "lasagna"]),
        ("baking", ["flour", "sugar", "baking", "yeast", "vanilla", "chocolate", "cocoa"]),
        ("spices", ["salt", "pepper", "cumin", "paprika", "oregano", "gochujang", "pesto",
                    "spice", "cinnamon", "curry", "masala"]),
        ("beverages", ["coffee", "tea", "juice", "wine"]),
        ("dry goods", ["rice", "oat", "cereal", "quinoa", "lentil"]),
    ]
    for (aisle, keys) in table where keys.contains(where: { n.contains($0) }) {
        return aisle
    }
    return ""
}

/// Resolves a stored photo value to a loadable remote URL.
///
/// Stored `photoThumb` values are relative R2 keys (e.g.
/// `photos/<id>/thumb.jpg`) and there is no public-URL resolver wired yet, so
/// those return nil and photos render as placeholders. Absolute http(s) URLs
/// pass through for forward-compat.
private func photoURL(forKey key: String?) -> URL? {
    guard let key, !key.isEmpty,
          let url = URL(string: key),
          let scheme = url.scheme?.lowercased(),
          scheme == "http" || scheme == "https"
    else { return nil }
    return url
}

// MARK: - Recipes tab (live list → detail → cook / add-to-list)

// MARK: - Library sections + sort (bottom-bar revamp, Paprika-inspired)

/// Top-pill filter sections. All/Favorites/Uncategorized/Trash are real
/// SwiftData-backed filters; Most Recent sorts by updatedAt; Top Rated
/// filters rating >= 4. No favorite flag exists on Recipe, so Favorites
/// matches the "Favorites" category (case-insensitive).
enum LibrarySection: String, CaseIterable, Hashable {
    case all, recent, topRated, favorites, uncategorized, trash

    var title: String {
        switch self {
        case .all: return "All Recipes"
        case .recent: return "Most Recent"
        case .topRated: return "Top Rated"
        case .favorites: return "Favorites"
        case .uncategorized: return "Uncategorized"
        case .trash: return "Trash"
        }
    }

    var icon: String {
        switch self {
        case .all: return "tray.full"
        case .recent: return "clock"
        case .topRated: return "star"
        case .favorites: return "heart"
        case .uncategorized: return "tag.slash"
        case .trash: return "trash"
        }
    }
}

enum LibrarySort: String, CaseIterable, Hashable {
    case title, recent, rating

    var title: String {
        switch self {
        case .title: return "Title"
        case .recent: return "Most Recent"
        case .rating: return "Top Rated"
        }
    }

    var icon: String {
        switch self {
        case .title: return "textformat"
        case .recent: return "clock"
        case .rating: return "star"
        }
    }
}

/// Add-menu navigation targets (Menu buttons can't host NavigationLinks).
enum LibraryAddDestination: Hashable {
    case clip, ocr, caption, paste, duplicates
}

struct RecipeLibraryView: View {
    @Environment(\.modelContext) private var context
    /// Shell quick-add "Create New Recipe" trigger: the drawer shell owns
    /// the single + menu, so blank-recipe creation is requested through
    /// this binding and consumed here (insert + navigate to detail).
    @Binding var requestBlankRecipe: Bool
    /// Filter state hoisted to the shell: the top-bar center slot is the
    /// filter pill on Recipes, so section + sheet trigger live above.
    /// `visibleRecipeCount` reports the filtered count back up for the pill.
    @Binding var section: LibrarySection
    @Binding var showFilterSheet: Bool
    @Binding var visibleRecipeCount: Int
    @Query(filter: #Predicate<Recipe> { !$0.tombstoned },
           sort: [SortDescriptor(\Recipe.title)])
    private var recipes: [Recipe]
    @Query(filter: #Predicate<Recipe> { $0.tombstoned },
           sort: [SortDescriptor(\Recipe.updatedAt, order: .reverse)])
    private var trashed: [Recipe]
    @Query(sort: [SortDescriptor(\Cookbook.name)])
    private var cookbooks: [Cookbook]
    @State private var searchText = ""
    @State private var selectedCategory: String? = nil
    @State private var sort: LibrarySort = .title
    @State private var showCategorize = false
    @State private var showCookbookPicker = false
    @State private var showNewCookbook = false
    @State private var newCookbookName = ""
    @State private var newCategoryText = ""
    @State private var pendingCats: Set<String> = []
    @State private var addDestination: LibraryAddDestination?
    @State private var createdRecipe: Recipe?
    @State private var isSelecting = false
    @State private var selection: Set<String> = []
    @State private var notice: String?

    private var allCategories: [String] {
        Array(Set(recipes.flatMap { $0.categories })).sorted()
    }

    private var base: [Recipe] {
        switch section {
        case .all, .recent:
            return recipes
        case .topRated:
            return recipes.filter { ($0.rating ?? 0) >= 4 }
        case .favorites:
            return recipes.filter { $0.categories.contains { $0.lowercased() == "favorites" } }
        case .uncategorized:
            return recipes.filter { $0.categories.isEmpty }
        case .trash:
            return trashed
        }
    }

    private func count(for target: LibrarySection) -> Int {
        switch target {
        case .all, .recent:
            return recipes.count
        case .topRated:
            return recipes.filter { ($0.rating ?? 0) >= 4 }.count
        case .favorites:
            return recipes.filter { $0.categories.contains { $0.lowercased() == "favorites" } }.count
        case .uncategorized:
            return recipes.filter { $0.categories.isEmpty }.count
        case .trash:
            return trashed.count
        }
    }

    private var recipesById: [String: Recipe] {
        Dictionary(uniqueKeysWithValues: (recipes + trashed).map { ($0.id, $0) })
    }

    private var filtered: [Recipe] {
        // Single source of truth for search behavior — see LibrarySearch.swift.
        // A selection whose category vanished (e.g. last recipe deleted) is
        // ignored so the list can't strand on an empty "No results" state.
        // Category chips don't apply inside Trash.
        let categories = (section == .trash) ? [] : selectedCategory.flatMap { sel in
            allCategories.contains(sel) ? [sel] : nil
        } ?? []
        let searched = filterRecipes(base, filter: AdvancedFilter(
            query: searchText, categories: categories))
        switch sort {
        case .title:
            return searched.sorted {
                $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
        case .recent:
            return searched.sorted { $0.updatedAt > $1.updatedAt }
        case .rating:
            return searched.sorted { ($0.rating ?? -1) > ($1.rating ?? -1) }
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Category chips stay in content; the filter pill itself
                // lives in the shell top bar (single header).
                if !allCategories.isEmpty && section != .trash {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            categoryChip(title: "All", selected: selectedCategory == nil) {
                                selectedCategory = nil
                            }
                            ForEach(allCategories, id: \.self) { cat in
                                categoryChip(title: cat, selected: selectedCategory == cat) {
                                    selectedCategory = (selectedCategory == cat) ? nil : cat
                                }
                            }
                        }
                        .padding(.horizontal)
                        .padding(.vertical, 8)
                    }
                }
                if let notice {
                    Text(notice)
                        .font(.subheadline)
                        .foregroundStyle(.green)
                        .padding(.vertical, 4)
                        .accessibilityIdentifier("library-notice")
                }
                Group {
                    if section == .trash && trashed.isEmpty {
                        ContentUnavailableView("Trash is empty", systemImage: "trash",
                            description: Text("Deleted recipes move here and sync as tombstones."))
                    } else if section != .trash && recipes.isEmpty {
                        VStack(spacing: 8) {
                            ContentUnavailableView("No recipes yet", systemImage: "book.pages",
                                description: Text("Seeds load on first launch — airplane mode works."))
                            ActionsCTA()
                        }
                    } else if filtered.isEmpty {
                        if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            ContentUnavailableView("No recipes here", systemImage: section.icon,
                                description: Text("Nothing in \(section.title) yet."))
                        } else {
                            ContentUnavailableView.search(text: searchText)
                        }
                    } else {
                        List {
                            ForEach(filtered, id: \.id) { recipe in
                                if isSelecting {
                                    Button {
                                        toggleSelection(recipe)
                                    } label: {
                                        rowContent(for: recipe, showCheck: true)
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityIdentifier("select-row-\(recipe.id)")
                                } else if section == .trash {
                                    HStack {
                                        rowContent(for: recipe, showCheck: false)
                                        Spacer()
                                        Button("Restore") { restore(recipe) }
                                            .buttonStyle(.bordered)
                                            .frame(minHeight: 44)
                                    }
                                } else {
                                    NavigationLink {
                                        RecipeDetailView(recipe: recipe)
                                    } label: {
                                        rowContent(for: recipe, showCheck: false)
                                    }
                                }
                            }
                            .onDelete(perform: section == .trash || isSelecting ? nil : tombstone)
                        }
                        .listStyle(.insetGrouped)
                        .contentMargins(.bottom, 148, for: .scrollContent)
                        .accessibilityIdentifier("recipe-list")
                    }
                }
            }
            // Shell top bar is the only header: hide this stack's root bar.
            // Pushed detail/cook views bring their own bars + back button.
            .toolbar(.hidden, for: .navigationBar)
            .overlay(alignment: .bottom) {
                if isSelecting { selectionBar } else { bottomBar }
            }
            // Shell quick-add "Create New Recipe" lands here: consume the
            // request whether the library was already visible (onChange) or
            // was just switched to (onAppear, same update as the trigger).
            .onAppear {
                if requestBlankRecipe { consumeBlankRequest() }
                visibleRecipeCount = filtered.count
            }
            .onChange(of: filtered.count) {
                visibleRecipeCount = filtered.count
            }
            .onChange(of: requestBlankRecipe) {
                if requestBlankRecipe { consumeBlankRequest() }
            }
            .sheet(isPresented: $showFilterSheet) { filterSheet }
            .sheet(isPresented: $showCategorize) { categorizeSheet }
            .sheet(isPresented: $showCookbookPicker) { cookbookSheet }
            .onChange(of: section) {
                // Filters changed underfoot: drop IDs that are no longer
                // visible so bulk actions can't hit hidden recipes.
                selection.formIntersection(filtered.map { $0.id })
            }
            .onChange(of: selectedCategory) {
                selection.formIntersection(filtered.map { $0.id })
            }
            .alert("New cookbook", isPresented: $showNewCookbook) {
                TextField("Name", text: $newCookbookName)
                Button("Create", action: createCookbook)
                Button("Cancel", role: .cancel) { newCookbookName = "" }
            }
            .navigationDestination(item: $addDestination) { dest in
                switch dest {
                case .clip: ClipView()
                case .ocr: OCRScanView()
                case .caption: CaptionsImportView()
                case .paste: PasteImportView()
                case .duplicates: DuplicateReviewView(recipes: Array(recipes))
                }
            }
            .navigationDestination(isPresented: Binding(
                get: { createdRecipe != nil },
                set: { if !$0 { createdRecipe = nil } }
            )) {
                if let createdRecipe { RecipeDetailView(recipe: createdRecipe) }
            }
        }
    }

    // MARK: - Rows

    private func rowContent(for recipe: Recipe, showCheck: Bool) -> some View {
        HStack(spacing: 12) {
            if showCheck {
                Image(systemName: selection.contains(recipe.id)
                    ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(selection.contains(recipe.id) ? Color.accentColor : .secondary)
                    .frame(minWidth: 44, minHeight: 44)
            }
            recipeThumb(for: recipe)
            VStack(alignment: .leading, spacing: 2) {
                Text(recipe.title).font(.headline)
                Text(librarySubtitle(for: recipe))
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Bottom pill bar (normal mode)

    private var bottomBar: some View {
        HStack(spacing: 8) {
            if section != .trash {
                Button("Edit") { enterSelection() }
                    .font(.subheadline.weight(.semibold))
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("edit-button")
            }
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search", text: $searchText)
                    .accessibilityIdentifier("library-search-field")
                    .submitLabel(.search)
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            .background(Color(.secondarySystemBackground))
            .clipShape(Capsule())
            SwiftUI.Menu {
                Picker("Sort", selection: $sort) {
                    ForEach(LibrarySort.allCases, id: \.self) { s in
                        Label(s.title, systemImage: s.icon).tag(s)
                    }
                }
                Button {
                    addDestination = .duplicates
                } label: {
                    Label("Review duplicates", systemImage: "square.stack.3d.up")
                }
                Button {
                    newCookbookName = ""
                    showNewCookbook = true
                } label: {
                    Label("New cookbook", systemImage: "book.closed")
                }
            } label: {
                Image(systemName: "ellipsis.circle.fill")
                    .font(.title2)
                    .frame(minWidth: 44, minHeight: 44)
                    .accessibilityIdentifier("more-button")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
        .clipShape(Capsule())
        .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .accessibilityIdentifier("bottom-bar")
    }

    // MARK: - Selection toolbar

    private var allVisibleSelected: Bool {
        let visibleIds = Set(filtered.map { $0.id })
        return !visibleIds.isEmpty && selection == visibleIds
    }

    private var selectionBar: some View {
        VStack(spacing: 0) {
            Text("\(selection.count) selected")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.bottom, 2)
            HStack(spacing: 4) {
                Button {
                    if allVisibleSelected {
                        selection = []
                    } else {
                        selection = Set(filtered.map { $0.id })
                    }
                } label: {
                    Image(systemName: allVisibleSelected
                        ? "checkmark.square.fill" : "square")
                        .font(.title3)
                        .frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityIdentifier("select-all-button")
                Button {
                    pendingCats = []
                    newCategoryText = ""
                    showCategorize = true
                } label: {
                    Image(systemName: "tag")
                        .font(.title3)
                        .frame(minWidth: 44, minHeight: 44)
                }
                .disabled(selection.isEmpty)
                .accessibilityIdentifier("categorize-button")
                Button {
                    addSelectedToShoppingList()
                } label: {
                    Image(systemName: "cart.badge.plus")
                        .font(.title3)
                        .frame(minWidth: 44, minHeight: 44)
                }
                .disabled(selection.isEmpty)
                .accessibilityIdentifier("bulk-add-to-list-button")
                SwiftUI.Menu {
                    Button {
                        showCookbookPicker = true
                    } label: {
                        Label("Change cookbook", systemImage: "book.closed")
                    }
                    .disabled(selection.isEmpty)
                    Button {
                        addSelectedToPlanner()
                    } label: {
                        Label("Add to meal planner", systemImage: "calendar.badge.plus")
                    }
                    .disabled(selection.isEmpty)
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.title3)
                        .frame(minWidth: 44, minHeight: 44)
                        .accessibilityIdentifier("bulk-more-button")
                }
                Button(role: .destructive) {
                    deleteSelected()
                } label: {
                    Image(systemName: "trash")
                        .font(.title3)
                        .frame(minWidth: 44, minHeight: 44)
                }
                .disabled(selection.isEmpty)
                .accessibilityIdentifier("bulk-delete-button")
                Spacer(minLength: 0)
                Button("Cancel") { exitSelection() }
                    .font(.subheadline.weight(.semibold))
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("selection-cancel-button")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(.ultraThinMaterial)
            .clipShape(Capsule())
            .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
        .accessibilityIdentifier("selection-bar")
    }

    // MARK: - Filter sheet

    private var filterSheet: some View {
        NavigationStack {
            List {
                ForEach(LibrarySection.allCases, id: \.self) { target in
                    Button {
                        section = target
                        // Sections with an intrinsic order adopt it as the sort.
                        if target == .recent { sort = .recent }
                        else if target == .topRated { sort = .rating }
                        else if sort == .recent || sort == .rating { sort = .title }
                        if target != .trash { /* keep chips */ } else { selectedCategory = nil }
                        showFilterSheet = false
                    } label: {
                        HStack {
                            Image(systemName: target.icon)
                                .foregroundStyle(.secondary)
                                .frame(width: 28)
                            Text(target.title)
                                .foregroundStyle(.primary)
                            Spacer()
                            Text("\(count(for: target))")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            if target == section {
                                Image(systemName: "checkmark")
                                    .font(.subheadline.weight(.semibold))
                            }
                        }
                        .frame(minHeight: 44)
                    }
                    .accessibilityIdentifier("filter-row-\(target.rawValue)")
                }
            }
            .navigationTitle("Filter")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showFilterSheet = false }
                        .frame(minHeight: 44)
                }
            }
            .presentationDetents([.medium])
        }
    }

    // MARK: - Categorize sheet (bulk)

    private var categorizeSheet: some View {
        NavigationStack {
            List {
                Section("Apply to \(selection.count) recipes") {
                    ForEach(allCategories, id: \.self) { cat in
                        Button {
                            if pendingCats.contains(cat) { pendingCats.remove(cat) }
                            else { pendingCats.insert(cat) }
                        } label: {
                            HStack {
                                Text(cat).foregroundStyle(.primary)
                                Spacer()
                                if pendingCats.contains(cat) {
                                    Image(systemName: "checkmark")
                                        .font(.subheadline.weight(.semibold))
                                }
                            }
                        }
                        .frame(minHeight: 44)
                    }
                }
                Section("New category") {
                    HStack {
                        TextField("Category name", text: $newCategoryText)
                            .submitLabel(.done)
                        Button("Add") { applyCategorize() }
                            .disabled(pendingCats.isEmpty
                                && newCategoryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            .navigationTitle("Categorize")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showCategorize = false }
                        .frame(minHeight: 44)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply", action: applyCategorize)
                        .frame(minHeight: 44)
                        .disabled(pendingCats.isEmpty
                            && newCategoryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .presentationDetents([.medium])
        }
    }

    // MARK: - Cookbook picker sheet (bulk)

    private var cookbookSheet: some View {
        NavigationStack {
            List {
                if cookbooks.filter({ !$0.tombstoned }).isEmpty {
                    Text("No cookbooks yet — create one below.")
                        .foregroundStyle(.secondary)
                }
                ForEach(cookbooks.filter { !$0.tombstoned }, id: \.id) { book in
                    Button {
                        toggleCookbookMembership(book)
                    } label: {
                        HStack {
                            Text(book.name).foregroundStyle(.primary)
                            Spacer()
                            Text("\(book.recipeIds.count)")
                                .font(.subheadline).foregroundStyle(.secondary)
                            if selection.allSatisfy({ book.recipeIds.contains($0) }) && !selection.isEmpty {
                                Image(systemName: "checkmark")
                                    .font(.subheadline.weight(.semibold))
                            }
                        }
                    }
                    .frame(minHeight: 44)
                }
                Section("New cookbook") {
                    HStack {
                        TextField("Name", text: $newCookbookName)
                            .submitLabel(.done)
                        Button("Create & add") {
                            let book = Cookbook(householdId: "hh-demo", name: newCookbookName
                                .trimmingCharacters(in: .whitespacesAndNewlines),
                                deviceId: currentDeviceId())
                            context.insert(book)
                            try? context.save()
                            for id in selection {
                                var ids = book.recipeIds
                                if !ids.contains(id) { ids.append(id) }
                                book.recipeIds = ids
                            }
                            book.updatedAt = Date()
                            try? context.save()
                            newCookbookName = ""
                            flash("Added \(selection.count) to \(book.name)")
                        }
                        .disabled(newCookbookName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            .navigationTitle("Change cookbook")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showCookbookPicker = false }
                        .frame(minHeight: 44)
                }
            }
            .presentationDetents([.medium])
        }
    }

    // MARK: - Selection + bulk actions

    private func enterSelection() {
        selection = []
        isSelecting = true
    }

    private func exitSelection() {
        selection = []
        isSelecting = false
    }

    private func toggleSelection(_ recipe: Recipe) {
        if selection.contains(recipe.id) { selection.remove(recipe.id) }
        else { selection.insert(recipe.id) }
    }

    private func flash(_ message: String) {
        notice = message
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.5))
            if notice == message { notice = nil }
        }
    }

    private func createNew() {
        let recipe = Recipe(householdId: "hh-demo", title: "Untitled Recipe",
            deviceId: currentDeviceId())
        context.insert(recipe)
        try? context.save()
        createdRecipe = recipe
    }

    /// Consume the shell's blank-recipe request: reset the trigger first so
    /// a re-appear can't double-insert, then create + navigate to detail.
    private func consumeBlankRequest() {
        requestBlankRecipe = false
        createNew()
    }

    private func restore(_ recipe: Recipe) {
        recipe.tombstoned = false
        recipe.updatedAt = Date()
        try? context.save()
    }

    private func createCookbook() {
        let name = newCookbookName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        context.insert(Cookbook(householdId: "hh-demo", name: name,
            deviceId: currentDeviceId()))
        try? context.save()
        newCookbookName = ""
        flash("Created \(name)")
    }

    private func applyCategorize() {
        var cats = pendingCats
        let typed = newCategoryText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typed.isEmpty { cats.insert(typed) }
        guard !cats.isEmpty else { return }
        var count = 0
        let byId = recipesById
        for id in selection {
            guard let recipe = byId[id], !recipe.tombstoned else { continue }
            var existing = recipe.categories
            for cat in cats where !existing.contains(where: { $0.lowercased() == cat.lowercased() }) {
                existing.append(cat)
            }
            recipe.categories = existing
            recipe.updatedAt = Date()
            count += 1
        }
        try? context.save()
        pendingCats = []
        newCategoryText = ""
        showCategorize = false
        flash("Categorized \(count) recipes")
    }

    private func toggleCookbookMembership(_ book: Cookbook) {
        let ids = Array(selection)
        var members = book.recipeIds
        if ids.allSatisfy({ members.contains($0) }) {
            members.removeAll(where: { selection.contains($0) })
        } else {
            for id in ids where !members.contains(id) { members.append(id) }
        }
        book.recipeIds = members
        book.updatedAt = Date()
        try? context.save()
    }

    /// Aggregates the selected recipes' ingredients into the "Shopping" list
    /// (same aisle-guess + scale pipeline as plan-to-list).
    private func addSelectedToShoppingList() {
        let deviceId = currentDeviceId()
        let byId = recipesById
        let inputs = selection.compactMap { byId[$0] }.flatMap { recipe in
            recipe.ingredients.map { ing in
                PlanGroceryInput(name: ing.name, quantity: ing.quantity, unit: ing.unit,
                    baseServings: recipe.servings, targetServings: recipe.servings,
                    recipeId: recipe.id)
            }
        }
        let lines = aggregateWeekToList(inputs)
        let list: ShoppingList
        if let existing = (try? context.fetch(FetchDescriptor<ShoppingList>()))?.first(where: {
            $0.name == "Shopping" && !$0.tombstoned
        }) {
            list = existing
        } else {
            list = ShoppingList(householdId: "hh-demo", name: "Shopping", deviceId: deviceId)
            context.insert(list)
        }
        for line in lines {
            // Same pipeline as plan-to-list: fraction display with unit, and
            // the relationship set so ListsTabView (which renders list.items)
            // shows the rows.
            let qty = line.totalQuantity.map { scaledDisplay(name: "", quantity: $0, unit: line.unit, factor: 1).trimmingCharacters(in: .whitespaces) } ?? ""
            let item = ListItem(listId: list.id, name: line.name, quantity: qty,
                aisle: guessAisle(for: line.name),
                recipeId: line.recipeIds.first, deviceId: deviceId)
            item.shoppingList = list
            context.insert(item)
        }
        try? context.save()
        flash("Added \(lines.count) items to Shopping")
    }

    /// Plans each selected recipe as dinner today.
    private func addSelectedToPlanner() {
        let deviceId = currentDeviceId()
        let today = Calendar.current.startOfDay(for: Date())
        var count = 0
        let byId = recipesById
        for id in selection {
            guard let recipe = byId[id], !recipe.tombstoned else { continue }
            context.insert(Plan(householdId: "hh-demo", date: today, meal: .dinner,
                recipeId: recipe.id, servings: recipe.servings, deviceId: deviceId))
            count += 1
        }
        try? context.save()
        flash("Planned \(count) meals for today")
    }

    private func deleteSelected() {
        let byId = recipesById
        for id in selection {
            guard let recipe = byId[id] else { continue }
            recipe.tombstoned = true
            recipe.updatedAt = Date()
        }
        try? context.save()
        exitSelection()
    }

    private func categoryChip(title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(selected ? .semibold : .regular))
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(selected ? Color.accentColor : Color(.secondarySystemBackground))
                .foregroundStyle(selected ? .white : .primary)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("category-chip-\(title)")
    }

    private func recipeThumb(for recipe: Recipe) -> some View {
        Group {
            if let url = photoURL(forKey: recipe.photoThumb) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let img): img.resizable().scaledToFill()
                    default:
                        Image(systemName: "fork.knife.circle.fill")
                            .resizable().scaledToFit().padding(8)
                            .foregroundStyle(.orange)
                    }
                }
                .frame(width: 52, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            } else {
                Image(systemName: "fork.knife.circle.fill")
                    .resizable().scaledToFit().padding(8)
                    .frame(width: 52, height: 52)
                    .background(Color.orange.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .foregroundStyle(.orange)
            }
        }
    }

    private func librarySubtitle(for recipe: Recipe) -> String {
        let n = recipe.ingredients.count, m = recipe.steps.count
        var parts = [
            n == 1 ? "1 ingredient" : "\(n) ingredients",
            m == 1 ? "1 step" : "\(m) steps",
        ]
        if let total = totalMinutes(for: recipe) { parts.append("\(total) min") }
        if recipe.servings > 0 {
            parts.append("Serves \(fractionDisplayString(for: recipe.servings))")
        }
        let cats = recipe.categories.prefix(2).joined(separator: " · ")
        if !cats.isEmpty { parts.append(cats) }
        return parts.joined(separator: " · ")
    }

    private func totalMinutes(for recipe: Recipe) -> Int? {
        switch (recipe.prepMinutes, recipe.cookMinutes) {
        case let (p?, c?): return p + c
        case let (p?, nil): return p
        case let (nil, c?): return c
        case (nil, nil): return nil
        }
    }

    private func tombstone(at offsets: IndexSet) {
        for i in offsets {
            filtered[i].tombstoned = true
            // Sync is last-write-wins on updatedAt: bump it so this delete
            // tombstone beats a remote copy (mirrors applyMerge in LibraryViews).
            filtered[i].updatedAt = Date()
        }
        try? context.save()
    }
}

private struct ActionsCTA: View {
    var body: some View {
        VStack(spacing: 8) {
            NavigationLink("Clip a recipe URL") { ClipView() }
                .buttonStyle(.borderedProminent)
            NavigationLink("Paste recipe text") { PasteImportView() }
                .buttonStyle(.bordered)
            NavigationLink("Scan a cookbook") { OCRScanView() }
                .buttonStyle(.bordered)
        }
        .padding(.top, 8)
    }
}

struct RecipeDetailView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    let recipe: Recipe
    @State private var addedMessage: String?
    @State private var checked: Set<String> = []
    @State private var servings: Double
    @State private var pane: DetailPane = .ingredients
    @State private var showEditor = false
    @State private var showDeleteConfirm = false
    @State private var nutritionExpanded = true

    /// Paprika-style segmented pane (custom capsule toggle, no copy).
    private enum DetailPane: String, CaseIterable {
        case ingredients
        case directions
        var title: String {
            switch self {
            case .ingredients: return "Ingredients"
            case .directions: return "Directions"
            }
        }
    }

    init(recipe: Recipe) {
        self.recipe = recipe
        _servings = State(initialValue: recipe.servings)
        _addedMessage = State(initialValue: nil)
    }

    private var sortedIngredients: [Ingredient] {
        recipe.ingredients.sorted(by: { $0.position < $1.position })
    }

    private var sortedSteps: [Step] {
        recipe.steps.sorted(by: { $0.position < $1.position })
    }

    private var totalMinutes: Int? {
        switch (recipe.prepMinutes, recipe.cookMinutes) {
        case let (p?, c?): return p + c
        case let (p?, nil): return p
        case let (nil, c?): return c
        case (nil, nil): return nil
        }
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            ScrollView {
                VStack(spacing: 0) {
                    heroHeader
                    VStack(alignment: .leading, spacing: 14) {
                        titleBlock
                        metaRow
                        if let addedMessage {
                            confirmRow(addedMessage)
                        }
                        paneToggle
                        if pane == .ingredients {
                            ingredientsPane
                        } else {
                            directionsPane
                        }
                    }
                    .padding(.horizontal)
                    .padding(.top, 12)
                    // Clearance so the floating action cluster never
                    // covers the last step / ingredient.
                    .padding(.bottom, 110)
                }
            }
            floatingActions
        }
        .navigationTitle(recipe.title)
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("recipe-detail-title")
        .sheet(isPresented: $showEditor, onDismiss: {
            // The editor may save a different serving count; resync the
            // detail's scaling target so the meta row and ingredient
            // scaling reflect the saved value instead of the stale one.
            servings = recipe.servings
        }) {
            RecipeEditorView(recipe: recipe)
        }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { showEditor = true } label: {
                    Image(systemName: "pencil")
                }
                .accessibilityIdentifier("edit-recipe-button")
                .accessibilityLabel("Edit recipe")
                Button { addToList() } label: {
                    Image(systemName: "cart.badge.plus")
                }
                .accessibilityIdentifier("add-to-list-button")
                .accessibilityLabel("Add to shopping list")
                Button { addToPlan() } label: {
                    Image(systemName: "calendar.badge.plus")
                }
                .accessibilityLabel("Add to tonight's plan")
                Button { toggleFavorite() } label: {
                    Image(systemName: isFavorite ? "heart.fill" : "heart")
                        .foregroundStyle(isFavorite ? .red : .primary)
                }
                .accessibilityLabel(isFavorite ? "Remove from favorites" : "Add to favorites")
                ShareLink(item: shareText) {
                    Image(systemName: "square.and.arrow.up")
                }
                .accessibilityLabel("Share recipe")
                Button(role: .destructive) { showDeleteConfirm = true } label: {
                    Image(systemName: "trash")
                }
                .accessibilityIdentifier("delete-recipe-button")
                .accessibilityLabel("Delete recipe")
            }
        }
        .confirmationDialog("Delete this recipe?", isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete Recipe", role: .destructive) { deleteRecipe() }
                .accessibilityIdentifier("confirm-delete-recipe-button")
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This moves \(recipe.title) to Trash and removes its planned meals. You can restore it from Trash.")
        }
    }

    private var servingsDisplay: String {
        fractionDisplayString(for: servings)
    }

    /// Scale applied to the pane rows (clamped 0.25x–4x, same as cook mode).
    private var scale: Double {
        scaleFactor(baseServings: recipe.servings, targetServings: servings)
    }

    /// One ingredient row: scaled "qty unit name" composed from the stored
    /// fields (same composition CookModeView uses). Seeds carry BOTH a name
    /// ("white miso") and a quantity-only display ("3 tbsp") — rendering
    /// `display` alone drops every name, and the servings stepper then
    /// changes nothing visible. Legacy display-only rows (empty name) fall
    /// back to `display` so nothing renders blank.
    private func ingredientLine(for ing: Ingredient) -> String {
        let composed = scaledDisplay(name: ing.name, quantity: ing.quantity,
            unit: ing.unit, factor: scale).trimmingCharacters(in: .whitespaces)
        if !composed.isEmpty { return composed }
        return ing.display.isEmpty ? ing.name : ing.display
    }

    @ViewBuilder
    private var heroHeader: some View {
        if let url = photoURL(forKey: recipe.photoThumb) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let img):
                    img.resizable().scaledToFill()
                        .frame(height: 180).clipped()
                default:
                    placeholderHero
                }
            }
        } else {
            placeholderHero
        }
    }

    private var placeholderHero: some View {
        ZStack {
            LinearGradient(colors: [.orange, .red.opacity(0.8)], startPoint: .topLeading, endPoint: .bottomTrailing)
                .frame(height: 180)
            Image(systemName: "fork.knife.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.white.opacity(0.9))
        }
    }

    // MARK: - Revamp: header / panes / floating actions

    private var isFavorite: Bool { recipe.isFavorite }

    private var shareText: String {
        [recipe.title, recipe.recipeDescription]
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n\n")
    }

    private var breadcrumb: String {
        "My Cookbook › \(recipe.categories.first ?? "Uncategorized")"
    }

    private var cookDestination: some View {
        CookModeView(
            title: recipe.title,
            baseServings: recipe.servings,
            ingredients: recipe.ingredients.map {
                CookModeView.IngredientSnapshot(id: $0.id, name: $0.name,
                    quantity: $0.quantity, unit: $0.unit)
            },
            steps: recipe.steps.map {
                CookModeView.StepSnapshot(id: $0.id, position: $0.position, text: $0.text)
            },
            initialServings: servings)
    }

    /// Title + static 1–5 star rating display + source link + breadcrumb.
    /// View-only: all metadata edits live in RecipeEditorView (Edit button).
    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(recipe.title)
                .font(.title2.weight(.bold))
            HStack(spacing: 2) {
                ForEach(1...5, id: \.self) { star in
                    let filled = Double(star) <= (recipe.rating ?? 0)
                    Image(systemName: filled ? "star.fill" : "star")
                        .font(.title3)
                        .foregroundStyle(filled ? .yellow : .secondary)
                }
            }
            .accessibilityLabel(recipe.rating.map { "Rated \($0) out of 5" } ?? "Not rated")
            if !recipe.sourceUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               let url = URL(string: recipe.sourceUrl),
               url.scheme != nil {
                Link(destination: url) {
                    Label(recipe.source.isEmpty ? (url.host ?? "Source") : recipe.source,
                        systemImage: "arrow.up.right.square")
                        .font(.subheadline)
                }
            }
            Text(breadcrumb)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Prep / total / servings meta row with icons.
    private var metaRow: some View {
        HStack(spacing: 16) {
            if let prep = recipe.prepMinutes {
                Label("\(prep) min prep", systemImage: "clock")
            }
            if let total = totalMinutes {
                Label("\(total) min total", systemImage: "timer")
            }
            Label("Serves \(servingsDisplay)", systemImage: "person.2.fill")
                .accessibilityLabel("Serves \(servingsDisplay)")
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }

    private func confirmRow(_ message: String) -> some View {
        HStack {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            Text(message).foregroundStyle(.primary)
        }
        .padding(.vertical, 4)
        .accessibilityIdentifier("added-confirm")
    }

    /// Custom capsule Ingredients|Directions toggle (44pt targets).
    private var paneToggle: some View {
        HStack(spacing: 0) {
            ForEach(DetailPane.allCases, id: \.self) { item in
                Button { pane = item } label: {
                    Text(item.title)
                        .font(.subheadline.weight(item == pane ? .semibold : .regular))
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(item == pane ? .isSelected : [])
                .background(item == pane ? Color(.systemBackground) : Color.clear)
                .clipShape(Capsule())
                .foregroundStyle(item == pane ? .primary : .secondary)
            }
        }
        .padding(4)
        .background(Color(.secondarySystemBackground))
        .clipShape(Capsule())
    }

    private var ingredientsPane: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Button("Reset servings") { servings = recipe.servings }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.blue)
                Spacer()
                Text("Serves \(servingsDisplay)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Stepper("", value: $servings, in: 1...24, step: 1)
                    .labelsHidden()
                    .accessibilityLabel("Servings")
            }
            .padding(.vertical, 4)
            ForEach(sortedIngredients) { ing in
                Button {
                    if checked.contains(ing.id) { checked.remove(ing.id) }
                    else { checked.insert(ing.id) }
                } label: {
                    HStack {
                        Image(systemName: checked.contains(ing.id)
                            ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(checked.contains(ing.id) ? .green : .secondary)
                        Text(ingredientLine(for: ing))
                            .strikethrough(checked.contains(ing.id))
                            .foregroundStyle(checked.contains(ing.id) ? .secondary : .primary)
                            .multilineTextAlignment(.leading)
                        Spacer()
                    }
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Divider()
            }
            DisclosureGroup(isExpanded: $nutritionExpanded) {
                let trimmed = (recipe.nutritionText ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                Text(trimmed.isEmpty ? "No nutrition info yet." : trimmed)
                    .font(.body)
                    .foregroundStyle(trimmed.isEmpty ? .secondary : .primary)
            } label: {
                Text("Nutrition")
                    .font(.headline)
            }
            .accessibilityIdentifier("nutrition-panel")
        }
    }

    private var directionsPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("DESCRIPTION")
            Text(recipe.recipeDescription.isEmpty
                ? "No description yet." : recipe.recipeDescription)
                .font(.body)
                .foregroundStyle(recipe.recipeDescription.isEmpty ? .secondary : .primary)
            sectionHeader("DIRECTIONS")
            NavigationLink { cookDestination } label: {
                Label("Start Cooking", systemImage: "play.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 50)
            }
            .buttonStyle(.borderedProminent)
            .clipShape(Capsule())
            .controlSize(.large)
            .accessibilityIdentifier("cook-button")
            ForEach(Array(sortedSteps.enumerated()), id: \.element.id) { idx, step in
                HStack(alignment: .top, spacing: 12) {
                    Text("\(idx + 1)")
                        .font(.headline)
                        .frame(width: 32, height: 32)
                        .background(Color.accentColor.opacity(0.15))
                        .foregroundStyle(Color.accentColor)
                        .clipShape(Circle())
                    VStack(alignment: .leading, spacing: 4) {
                        Text(step.text)
                            .font(.body)
                        if let hint = timerHint(for: step.text) {
                            Label(hint, systemImage: "timer")
                                .font(.caption)
                                .foregroundStyle(.blue)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    /// Bottom-right floating cluster: cook-mode timer + pin/favorite.
    /// Overlay only spans its own buttons, so scrolling stays unblocked.
    private var floatingActions: some View {
        VStack(spacing: 12) {
            NavigationLink { cookDestination } label: {
                Image(systemName: "timer")
                    .font(.title2)
                    .frame(width: 56, height: 56)
                    .background(Color(.systemBackground))
                    .foregroundStyle(Color.accentColor)
                    .clipShape(Circle())
                    .shadow(radius: 4)
            }
            .accessibilityLabel("Open cook mode")
            .accessibilityIdentifier("floating-timer-button")
            Button { toggleFavorite() } label: {
                Image(systemName: isFavorite ? "pin.fill" : "pin")
                    .font(.title2)
                    .frame(width: 56, height: 56)
                    .background(Color(.systemBackground))
                    .foregroundStyle(isFavorite ? .red : .secondary)
                    .clipShape(Circle())
                    .shadow(radius: 4)
            }
            .accessibilityLabel(isFavorite ? "Unpin favorite" : "Pin favorite")
        }
        .padding(.trailing, 16)
        .padding(.bottom, 24)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    /// Detects "N min/minutes" or "N hour(s)" in step text; label only.
    private func timerHint(for text: String) -> String? {
        let pattern = "(\\d+)\\s*(hours?|hrs?|minutes?|mins?)"
        guard let rx = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
        let ns = text as NSString
        guard let match = rx.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let num = ns.substring(with: match.range(at: 1))
        let unit = ns.substring(with: match.range(at: 2)).lowercased()
        let short = (unit.hasPrefix("hour") || unit.hasPrefix("hr")) ? "hr" : "min"
        return "~\(num) \(short)"
    }

    private func toggleFavorite() {
        recipe.isFavorite.toggle()
        recipe.updatedAt = Date()
        try? context.save()
    }

    /// Sync-safe delete: tombstone + updatedAt bump (last-write-wins), then
    /// pop back to the list. Mirrors the library swipe-to-delete path.
    /// Linked plans are tombstoned too so Plan keeps no dangling schedule
    /// that could leak the recipe's ingredients into the weekly shop.
    private func deleteRecipe() {
        recipe.tombstoned = true
        recipe.updatedAt = Date()
        let linked = (try? context.fetch(FetchDescriptor<Plan>()))?.filter {
            $0.recipeId == recipe.id && !$0.tombstoned
        } ?? []
        for plan in linked {
            plan.tombstoned = true
            plan.updatedAt = Date()
        }
        try? context.save()
        dismiss()
    }

    /// Real SwiftData insert: this recipe planned for tonight's dinner.
    /// Skips the insert when a matching non-deleted plan already exists,
    /// so a double tap can't double that recipe's grocery quantities
    /// (addWeekToList aggregates every plan entry).
    private func addToPlan() {
        let tonight = Calendar.current.startOfDay(for: Date())
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: tonight) ?? tonight
        let householdId = recipe.householdId
        let recipeId = recipe.id
        let mealRaw = MealSlot.dinner.rawValue
        let dup = (try? context.fetch(FetchDescriptor<Plan>(predicate: #Predicate<Plan> {
            !$0.tombstoned && $0.householdId == householdId
                && $0.date >= tonight && $0.date < tomorrow && $0.mealRaw == mealRaw
        })))?.contains(where: { $0.recipeId == recipeId }) ?? false
        if !dup {
            context.insert(Plan(householdId: recipe.householdId, date: tonight,
                meal: .dinner, recipeId: recipe.id,
                servings: servings, deviceId: currentDeviceId()))
            try? context.save()
        }
        addedMessage = "Planned \(recipe.title) for tonight"
    }

    private func addToList() {
        let deviceId = currentDeviceId()
        let inputs = recipe.ingredients.map { ing in
            PlanGroceryInput(name: ing.name, quantity: ing.quantity, unit: ing.unit,
                baseServings: recipe.servings, targetServings: servings, recipeId: recipe.id)
        }
        let lines = aggregateWeekToList(inputs)
        let list: ShoppingList
        if let existing = (try? context.fetch(FetchDescriptor<ShoppingList>()))?.first(where: {
            $0.name == "Shopping" && !$0.tombstoned
        }) {
            list = existing
        } else {
            list = ShoppingList(householdId: recipe.householdId, name: "Shopping", deviceId: deviceId)
            context.insert(list)
        }
        for line in lines {
            let qty = line.totalQuantity.map { scaledDisplay(name: "", quantity: $0, unit: line.unit, factor: 1).trimmingCharacters(in: .whitespaces) } ?? ""
            let item = ListItem(listId: list.id, name: line.name, quantity: qty,
                aisle: guessAisle(for: line.name),
                recipeId: line.recipeIds.first, deviceId: deviceId)
            item.shoppingList = list
            context.insert(item)
        }
        try? context.save()
        addedMessage = "Added \(lines.count) items to Shopping"
    }
}

// MARK: - Plan tab (live week → add week to list + meal CRUD)
//
// Wires the full PlanView API: entries/menus/recipeOptions plus
// onAddWeekToList/onApplyMenu/onAddDay/onSelectEntry/onDeleteEntry/
// onSaveMeal/onSearchRecipes. Recipe search filters locally inside
// AddMealSheet already, so onSearchRecipes is a no-op sink.

struct PlanTabView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: [SortDescriptor(\Plan.date)]) private var plans: [Plan]
    @Query(sort: [SortDescriptor(\Menu.name)]) private var menus: [Menu]
    @Query private var recipes: [Recipe]
    @State private var confirm: String?
    @State private var selectedRecipe: Recipe?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let confirm {
                    Text(confirm)
                        .font(.subheadline).foregroundStyle(.green)
                        .padding(.vertical, 6)
                        .accessibilityIdentifier("week-to-list-confirm")
                }
                PlanView(entries: entries, menus: menuSnapshots,
                    recipeOptions: recipeOptions,
                    onAddWeekToList: addWeekToList,
                    onApplyMenu: applyMenu, onAddDay: addDay,
                    onSelectEntry: selectEntry, onDeleteEntry: deleteEntry,
                    onSaveMeal: saveMeal, onSearchRecipes: { _ in })
                    .accessibilityIdentifier("plan-view")
                    .toolbar(.hidden, for: .navigationBar)
            }
            .navigationDestination(isPresented: Binding(
                get: { selectedRecipe != nil },
                set: { if !$0 { selectedRecipe = nil } }
            )) {
                if let selectedRecipe { RecipeDetailView(recipe: selectedRecipe) }
            }
        }
    }

    private var recipesById: [String: Recipe] {
        Dictionary(uniqueKeysWithValues: recipes.map { ($0.id, $0) })
    }

    /// Live (non-tombstoned) recipe lookup. Tombstoned recipes are treated
    /// as missing so deleted recipes never surface in the plan, the picker
    /// confirm copy, or the weekly grocery aggregation.
    private func liveRecipe(id: String?) -> Recipe? {
        guard let id, let recipe = recipesById[id], !recipe.tombstoned else { return nil }
        return recipe
    }

    private var entries: [PlanEntrySnapshot] {
        plans.filter { !$0.tombstoned }.map { plan in
            let recipe = liveRecipe(id: plan.recipeId)
            return PlanEntrySnapshot(id: plan.id, date: plan.date,
                meal: plan.mealRaw, recipeId: plan.recipeId,
                recipeTitle: recipe?.title ?? (plan.note.isEmpty ? nil : plan.note),
                note: recipe == nil ? plan.note : "", servings: plan.servings)
        }
    }

    private var menuSnapshots: [MenuSnapshot] {
        menus.filter { !$0.tombstoned }.map {
            MenuSnapshot(id: $0.id, name: $0.name, entryCount: $0.entries.count)
        }
    }

    /// All non-deleted recipes sorted by title for the PlanView
    /// Add Meal wizard picker.
    private var recipeOptions: [RecipeOptionSnapshot] {
        recipes.filter { !$0.tombstoned }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            .map { recipe in
                RecipeOptionSnapshot(id: recipe.id, title: recipe.title,
                    category: recipe.categories.first ?? "Uncategorized",
                    rating: recipe.rating ?? 0, thumbKey: recipe.photoThumb)
            }
    }

    /// Empty-day "Add" affordance: inserts a blank dinner shell for `day`
    /// (recipe/note filled in later); the day row re-renders with content.
    private func addDay(_ day: Date) {
        context.insert(Plan(householdId: "hh-demo", date: day, meal: .dinner,
            deviceId: currentDeviceId()))
        try? context.save()
    }

    /// Inserts a planned meal. Skips the insert when the same day + meal +
    /// recipe already exists non-deleted (double-tap safe, mirrors
    /// RecipeDetailView.addToPlan). Pass nil recipeId + note for note-only
    /// entries. Wired to PlanView `onSaveMeal`.
    private func saveMeal(date: Date, meal: String, recipeId: String?,
        note: String = "", servings: Double? = nil) {
        let slot = MealSlot(rawValue: meal) ?? .dinner
        let cal = Calendar.current
        let dup: Bool = {
            if let recipeId {
                return plans.contains {
                    !$0.tombstoned && cal.isDate($0.date, inSameDayAs: date)
                        && $0.mealRaw == slot.rawValue && $0.recipeId == recipeId
                }
            }
            let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return false }
            return plans.contains {
                !$0.tombstoned && cal.isDate($0.date, inSameDayAs: date)
                    && $0.mealRaw == slot.rawValue && $0.recipeId == nil
                    && $0.note == trimmed
            }
        }()
        if dup { return }
        let title: String
        if let recipeId, let recipe = liveRecipe(id: recipeId) {
            title = recipe.title
        } else {
            let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
            title = trimmed.isEmpty ? "Meal" : trimmed
        }
        context.insert(Plan(householdId: "hh-demo", date: date, meal: slot,
            recipeId: recipeId, note: note, servings: servings,
            deviceId: currentDeviceId()))
        try? context.save()
        confirm = "Planned \(title) for \(PlanView.dayTitle(date))"
    }

    /// Updates an existing entry in place (tombstone + re-insert NOT needed:
    /// same id, bump updatedAt for last-write-wins sync). Kept for a future
    /// PlanView `onUpdateMeal` (not in the current API).
    private func updateEntry(id: String, date: Date, meal: String,
        recipeId: String? = nil, note: String = "", servings: Double? = nil) {
        guard let plan = plans.first(where: { $0.id == id && !$0.tombstoned }) else { return }
        plan.date = date
        plan.mealRaw = (MealSlot(rawValue: meal) ?? .dinner).rawValue
        plan.recipeId = recipeId
        plan.note = note
        plan.servings = servings
        plan.updatedAt = Date()
        try? context.save()
        confirm = "Updated planned meal for \(PlanView.dayTitle(date))"
    }

    /// Tombstones a plan entry (sync-safe delete). Wired to PlanView
    /// `onDeleteEntry`.
    private func deleteEntry(id: String) {
        let target: Plan?
        do {
            target = try context.fetch(FetchDescriptor<Plan>(predicate: #Predicate { $0.id == id })).first
        } catch { target = plans.first(where: { $0.id == id }) }
        guard let plan = target, !plan.tombstoned else { return }
        plan.tombstoned = true
        plan.updatedAt = Date()
        do { try context.save() } catch { confirm = "Couldn't delete: \(error)"; return }
        confirm = "Removed planned meal"
    }

    /// Row tap: recipe entries navigate to RecipeDetailView; note-only
    /// entries surface their text in the confirm banner. Wired to PlanView
    /// `onSelectEntry`.
    private func selectEntry(id: String) {
        guard let plan = plans.first(where: { $0.id == id && !$0.tombstoned }) else { return }
        if plan.recipeId != nil, let recipe = liveRecipe(id: plan.recipeId) {
            selectedRecipe = recipe
        } else {
            let label = plan.note.trimmingCharacters(in: .whitespacesAndNewlines)
            confirm = label.isEmpty ? "No meal details" : label
        }
    }

    /// Copies a reusable menu's entries into the given week (same logic as
    /// MenusTabView.apply, looked up by id for the PlanView callback).
    private func applyMenu(menuId: String, weekStart: Date) {
        guard let menu = menus.first(where: { $0.id == menuId && !$0.tombstoned }) else { return }
        let cal = Calendar.current
        var count = 0
        for entry in menu.entries {
            guard let day = cal.date(byAdding: .day, value: entry.dayOffset, to: weekStart) else { continue }
            let slot = MealSlot(rawValue: entry.meal) ?? .dinner
            context.insert(Plan(householdId: "hh-demo", date: day, meal: slot,
                recipeId: entry.recipeId.isEmpty ? nil : entry.recipeId,
                servings: entry.servings, deviceId: currentDeviceId()))
            count += 1
        }
        try? context.save()
        confirm = count > 0 ? "Applied \(menu.name): \(count) meals planned" : "\(menu.name) has no entries to apply"
    }

    private func addWeekToList(_ weekStart: Date) {
        let cal = Calendar.current
        let weekEnd = cal.date(byAdding: .day, value: 7, to: weekStart) ?? weekStart
        let weekPlans = plans.filter { !$0.tombstoned && $0.date >= weekStart && $0.date < weekEnd }
        var inputs: [PlanGroceryInput] = []
        for plan in weekPlans {
            guard let rid = plan.recipeId, let recipe = liveRecipe(id: rid) else { continue }
            for ing in recipe.ingredients {
                inputs.append(PlanGroceryInput(name: ing.name, quantity: ing.quantity,
                    unit: ing.unit, baseServings: recipe.servings,
                    targetServings: plan.servings, recipeId: rid))
            }
        }
        let lines = aggregateWeekToList(inputs)
        let deviceId = currentDeviceId()
        let list: ShoppingList
        if let existing = (try? context.fetch(FetchDescriptor<ShoppingList>()))?.first(where: {
            $0.name == "Weekly shop" && !$0.tombstoned
        }) {
            list = existing
            for item in list.items { context.delete(item) }
            list.items.removeAll()
        } else {
            list = ShoppingList(householdId: "hh-demo", name: "Weekly shop", deviceId: deviceId)
            context.insert(list)
        }
        for line in lines {
            let qty = line.totalQuantity.map { scaledDisplay(name: "", quantity: $0, unit: line.unit, factor: 1).trimmingCharacters(in: .whitespaces) } ?? ""
            let item = ListItem(listId: list.id, name: line.name, quantity: qty,
                aisle: guessAisle(for: line.name),
                recipeId: line.recipeIds.first, deviceId: deviceId)
            item.shoppingList = list
            context.insert(item)
        }
        try? context.save()
        confirm = "Added \(lines.count) items to Weekly shop"
    }
}

// MARK: - Lists tab (live aisle-sorted lists + check-off)

struct ListsTabView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: [SortDescriptor(\ShoppingList.updatedAt, order: .reverse)])
    private var lists: [ShoppingList]

    var body: some View {
        NavigationStack {
            Group {
                if lists.filter({ !$0.tombstoned }).isEmpty {
                    ContentUnavailableView("No lists yet", systemImage: "cart",
                        description: Text("Add a week to a list from the Plan tab."))
                } else {
                    ShopListsView(lists: snapshots, onToggle: toggle, onAddItem: addItem)
                        .accessibilityIdentifier("lists-view")
                }
            }
        }
        // Stack-level so BOTH branches (empty + populated) hide the root
        // bar — same pattern as the library root. Pushed views unaffected.
        .toolbar(.hidden, for: .navigationBar)
    }

    private var snapshots: [ShoppingListSnapshot] {
        lists.filter { !$0.tombstoned }.map { list in
            ShoppingListSnapshot(id: list.id, name: list.name, items: list.items.map { item in
                ShopItemSnapshot(id: item.id, name: item.name, quantity: item.quantity,
                    aisle: item.aisle, checked: item.checked, recipeId: item.recipeId)
            })
        }
    }

    private func toggle(listId: String, itemId: String) {
        guard let item = (try? context.fetch(FetchDescriptor<ListItem>()))?.first(where: { $0.id == itemId }) else { return }
        item.checked.toggle()
        try? context.save()
    }

    /// Manually added row: persists a new unchecked `ListItem` on `listId`
    /// with a locally guessed aisle; the list re-renders with the item.
    private func addItem(listId: String, name: String) {
        let text = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard let list = (try? context.fetch(FetchDescriptor<ShoppingList>()))?.first(where: {
            $0.id == listId && !$0.tombstoned
        }) else { return }
        let item = ListItem(listId: listId, name: text, aisle: guessAisle(for: text),
            deviceId: currentDeviceId())
        item.shoppingList = list
        context.insert(item)
        try? context.save()
    }
}

// MARK: - More tab (ingest entry points + library + sync)

struct MoreTabView: View {
    var body: some View {
        NavigationStack {
            List {
                Section("Add") {
                    NavigationLink("Clip recipe URL") { ClipView() }
                        .accessibilityIdentifier("more-clip")
                    NavigationLink("Import caption") { CaptionsImportView() }
                        .accessibilityIdentifier("more-caption")
                    NavigationLink("Paste text") { PasteImportView() }
                        .accessibilityIdentifier("more-paste")
                    NavigationLink("Scan cookbook (OCR)") { OCRScanView() }
                        .accessibilityIdentifier("more-ocr")
                    NavigationLink("Import file") { ImportView() }
                        .accessibilityIdentifier("more-import-file")
                }
                Section("Library") {
                    NavigationLink("Export") { RecipeExportView() }
                        .accessibilityIdentifier("more-export")
                    NavigationLink {
                        PantryTabView()
                    } label: {
                        Label("Pantry", systemImage: "refrigerator")
                    }
                    .accessibilityIdentifier("more-pantry")
                    NavigationLink {
                        MenusTabView()
                    } label: {
                        Label("Menus", systemImage: "list.bullet.rectangle")
                    }
                    .accessibilityIdentifier("more-menus")
                    NavigationLink {
                        SettingsView()
                    } label: {
                        Label("Settings", systemImage: "gear")
                    }
                    .accessibilityIdentifier("more-settings")
                }
                Section("Sync") {
                    SyncStatusRow()
                }
            }
            .navigationTitle("More")
        }
    }
}

// MARK: - Pantry tab (live SwiftData → PantryView snapshots)

struct PantryTabView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: [SortDescriptor(\PantryItem.name)]) private var items: [PantryItem]
    @State private var name = ""
    @State private var location = ""
    @State private var quantity = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Add pantry item", text: $name)
                    .textInputAutocapitalization(.words)
                    .submitLabel(.done)
                    .onSubmit(addItem)
                Button("Add", action: addItem)
                    .buttonStyle(.bordered)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            Divider()
            PantryView(items: snapshots, onBarcode: insertBarcode)
        }
    }

    private var snapshots: [PantrySnapshot] {
        items.filter { !$0.tombstoned }.map {
            PantrySnapshot(id: $0.id, name: $0.name, quantity: $0.quantity,
                location: $0.location, expiresAt: $0.expiresAt,
                lowThreshold: $0.lowThreshold, barcode: $0.barcode)
        }
    }

    private func addItem() {
        let text = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        context.insert(PantryItem(householdId: "hh-demo", name: text,
            quantity: quantity, location: location,
            deviceId: currentDeviceId()))
        try? context.save()
        name = ""; location = ""; quantity = ""
    }

    private func insertBarcode(_ code: String) {
        let text = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if let existing = items.first(where: { $0.barcode == text && !$0.tombstoned }) {
            existing.updatedAt = Date()
        } else {
            context.insert(PantryItem(householdId: "hh-demo", name: text,
                barcode: text, deviceId: currentDeviceId()))
        }
        try? context.save()
    }
}

// MARK: - Menus tab (live SwiftData menus + editor + apply to week)

/// Reusable menu templates (Paprika-style). The list supports create (alert
/// via the + button), rename (long-press menu), duplicate ("name copy"),
/// and sync-safe tombstone delete, plus quick "Apply to week" from the
/// row context menu. Tapping a row pushes PaprikaMenuDetailView
/// (MenusPaprikaViews.swift): DAY sections, Add Meal flow, and the "..."
/// sheet with days stepper, slot renames, and Apply (week start +
/// skip-filled). Apply copies entries into the chosen week with skip-filled
/// (default) or overwrite (tombstone conflicts first) semantics.
struct MenusTabView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: [SortDescriptor(\Menu.name)]) private var menus: [Menu]
    @Query private var plans: [Plan]
    @Query private var recipes: [Recipe]
    @State private var confirm: String?
    @State private var weekStart = DemoSeeds.weekStart(containing: Date())
    @State private var skipFilled = true
    @State private var sort = MenusPaprikaSort.name
    @State private var editMode: EditMode = .inactive
    /// Opens the drawer when hosted in the drawer shell (the Paprika
    /// header is the sole top bar there — the shell hides its own).
    /// Defaults to no-op for the More-tab push context.
    var onOpenDrawer: () -> Void = {}

    var body: some View {
        NavigationStack {
            PaprikaMenusScreen(
                menus: liveMenus,
                confirm: confirm,
                sort: $sort,
                editMode: $editMode,
                onCreate: createMenu,
                onRename: rename,
                onDuplicate: duplicate,
                onDelete: tombstone,
                onApply: apply,
                onOpenDrawer: onOpenDrawer
            ) { menu in
                PaprikaMenuDetailView(
                    menu: menu,
                    recipes: liveRecipes,
                    weekStart: $weekStart,
                    skipFilled: $skipFilled,
                    onApply: apply
                )
            }
        }
        .accessibilityIdentifier("menus-view")
    }

    private var liveMenus: [Menu] { menus.filter { !$0.tombstoned } }

    private var liveRecipes: [Recipe] {
        recipes.filter { !$0.tombstoned }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    private func createMenu(named rawName: String) {
        let text = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        context.insert(Menu(householdId: "hh-demo", name: text, deviceId: currentDeviceId()))
        try? context.save()
        confirm = "Created \(text)"
    }

    private func rename(_ menu: Menu, to newName: String) {
        let text = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text != menu.name else { return }
        menu.name = text
        menu.updatedAt = Date()
        try? context.save()
    }

    /// Copies entries into a new menu ("<name> copy") with a fresh id.
    private func duplicate(_ menu: Menu) {
        let copy = Menu(householdId: menu.householdId, name: menu.name + " copy",
            entries: menu.entries, deviceId: currentDeviceId())
        context.insert(copy)
        try? context.save()
        confirm = "Duplicated \(menu.name)"
    }

    private func tombstone(_ menu: Menu) {
        menu.tombstoned = true
        menu.updatedAt = Date()
        try? context.save()
        confirm = "Deleted \(menu.name)"
    }

    /// Copies a menu's entries into `weekStart`. Skip-filled (default) leaves
    /// occupied day+meal slots alone; overwrite tombstones conflicting plans
    /// on those keys first, then inserts everything. Every written meal goes
    /// through planMealForMenuSlot (plans allow only the 4 canonical meals);
    /// empty/out-of-range entries are dropped by expandMenuEntries and
    /// reported in the confirm banner.
    private func apply(_ menu: Menu) {
        let rawExpanded = expandMenuEntries(entries: menu.entries, weekStart: weekStart,
            householdId: "hh-demo", deviceId: currentDeviceId())
        let droppedCount = menu.entries.count - rawExpanded.count
        let droppedNote = droppedCount > 0 ? " (\(droppedCount) ignored: empty or out of range)" : ""
        let expanded: [ExpandedMenuEntry] = rawExpanded.map {
            (dayOffset: $0.dayOffset, date: $0.date, meal: planMealForMenuSlot($0.meal),
             recipeId: $0.recipeId, servings: $0.servings)
        }
        guard !expanded.isEmpty else {
            confirm = "\(menu.name) has no entries to apply" + droppedNote
            return
        }
        let livePlans = plans.filter { !$0.tombstoned }
        let occupied = occupiedKeys(plans: livePlans.map { (date: $0.date, meal: planMealForMenuSlot($0.mealRaw)) })
        if !skipFilled {
            let keys = Set(expanded.map { OccupiedMealKey(day: $0.date, meal: planMealForMenuSlot($0.meal)) })
            for plan in livePlans
                where keys.contains(OccupiedMealKey(day: plan.date, meal: planMealForMenuSlot(plan.mealRaw))) {
                plan.tombstoned = true
                plan.updatedAt = Date()
            }
        }
        let result = filterSkipped(expanded: expanded, occupied: occupied, skipFilled: skipFilled)
        var count = 0
        for entry in result.toInsert {
            let plan = Plan(householdId: "hh-demo", date: entry.date,
                meal: MealSlot(rawValue: planMealForMenuSlot(entry.meal)) ?? .dinner,
                recipeId: entry.recipeId.isEmpty ? nil : entry.recipeId,
                servings: entry.servings, deviceId: currentDeviceId())
            context.insert(plan)
            count += 1
        }
        try? context.save()
        if count > 0 {
            confirm = "Applied \(menu.name): \(count) meals planned"
                + (result.skippedCount > 0 ? " (\(result.skippedCount) filled skipped)" : "")
                + droppedNote
        } else {
            confirm = "\(menu.name): all \(result.skippedCount) slots already filled" + droppedNote
        }
    }
}

// MARK: - Settings (sync status, devices sharing, advanced BYO backend)

struct SettingsView: View {
    @State private var syncing = false
    // Devices sharing (E2E invite; the syncCode itself
    // lives only in the Keychain and never surfaces here)
    @State private var householdName: String = E2EKeyStore.loadMetadata()?.householdId ?? "hh-demo"
    @State private var inviteBundle: String = ""
    @State private var pasteInput: String = ""
    @State private var joinResult: String = ""
    @State private var showQR = false
    @State private var devicePrefix: String? = E2EKeyStore.loadMetadata().map { String($0.hash.prefix(8)) }
    /// Join staged for explicit confirmation when this device already has a
    /// key that may hold synced data — joining replaces it.
    @State private var pendingJoin: SyncInviteBundle? = nil
    // Advanced BYO backend (hidden by default — the app works out of the
    // box against the built-in server).
    @State private var showAdvanced = false
    @State private var customURLString: String = UserDefaults.standard.string(forKey: "smidgen.apiBaseURL") ?? ""
    @State private var healthResult: String = ""
    @State private var testing = false
    // Pending endpoint hint from the last joined invite bundle. NEVER
    // auto-applied: the user must explicitly confirm AND the hint must pass
    // GET /health before it becomes the backend URL.
    @State private var pendingEndpointHint: String? = nil
    @State private var hintHealthResult: String = ""
    @State private var hintTesting = false

    /// Effective base URL: Advanced override (blank = skip) -> Bundle
    /// SMIDGEN_API_BASE_URL -> built-in prod server.
    private var effectiveBaseURL: String { SyncConfig.baseURLString }

    /// True when an Advanced custom-server override is stored.
    private var hasCustomServer: Bool {
        !(UserDefaults.standard.string(forKey: "smidgen.apiBaseURL") ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        List {
            Section {
                SyncStatusRow()
                Button(syncing ? "Syncing…" : "Sync now") {
                    Task { await syncNow() }
                }
                .disabled(syncing)
            } header: {
                Text("Sync")
            } footer: {
                Text(hasCustomServer ? "Using a custom server (see Advanced)." : "Using the built-in server.")
            }
            Section {
                if let prefix = devicePrefix {
                    Text("This device •\(prefix)").font(.caption).foregroundStyle(.secondary)
                }
                Button("Connect a new device") {
                    if let json = e2eInviteBundleJSON(householdId: householdName, endpointHint: hasCustomServer ? effectiveBaseURL : nil) {
                        inviteBundle = json
                        refreshE2EState()
                        showQR = true
                    } else {
                        joinResult = "Could not access the Keychain — invite unavailable."
                    }
                }
                .sheet(isPresented: $showQR) {
                    NavigationStack {
                        List {
                            InviteQRImage(payload: inviteBundle)
                                .frame(maxWidth: .infinity, minHeight: 220)
                            Section("Manual copy") {
                                Text(inviteBundle)
                                    .font(.caption.monospaced())
                                    .textSelection(.enabled)
                                Button("Copy code") {
                                    #if os(iOS)
                                    UIPasteboard.general.string = inviteBundle
                                    #endif
                                }
                            }
                            Section {
                                Text("Send this to your second device out-of-band (Messages, Mail, AirDrop). Enter it there under Devices → Join with code.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .navigationTitle("Connect a new device")
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") { showQR = false }
                            }
                        }
                    }
                }
                TextField("Paste code to join", text: $pasteInput, axis: .vertical)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.caption.monospaced())
                Button("Join with code") { joinWithBundle() }
                    .disabled(pasteInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if pendingJoin != nil {
                    HStack {
                        Button("Join anyway") { confirmPendingJoin() }
                        Spacer()
                        Button("Cancel") {
                            pendingJoin = nil
                            joinResult = "Kept current household."
                        }
                    }
                }
                if !joinResult.isEmpty {
                    Text(joinResult).font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("Devices")
            } footer: {
                Text("Keep Cooking can't see or recover your data. Lose all devices = permanent loss. Add a new phone or iPad while you still have this one — open Settings here on both devices.")
            }
            Section {
                DisclosureGroup("Custom server (advanced)", isExpanded: $showAdvanced) {
                    TextField("Server URL (blank = built-in)", text: $customURLString)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .keyboardType(.URL)
                        #endif
                    HStack {
                        Button(testing ? "Testing…" : "Test") {
                            Task { await testHealth() }
                        }
                        .disabled(testing)
                        Spacer()
                        Button("Save") { saveServer() }
                        .disabled(syncing)
                        if hasCustomServer {
                            Button("Use built-in") { useBuiltInServer() }
                        }
                    }
                    if !healthResult.isEmpty {
                        Text(healthResult).font(.caption).foregroundStyle(.secondary)
                    }
                    if let hint = pendingEndpointHint {
                        Text("Suggested server (from invite)")
                            .font(.caption.weight(.semibold))
                        Text(hint)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .lineLimit(2).truncationMode(.middle)
                        Text("This came from the invite bundle — it is not your server until you confirm it. Confirming checks GET /health first.")
                            .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button(hintTesting ? "Checking…" : "Test & use this server") {
                                Task { await confirmEndpointHint() }
                            }
                            .disabled(hintTesting)
                            Spacer()
                            Button("Keep current server") { dismissEndpointHint() }
                                .disabled(hintTesting)
                        }
                        if !hintHealthResult.isEmpty {
                            Text(hintHealthResult).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("Advanced")
            } footer: {
                Text("Only set this if you run your own backend. Most users should leave it blank.")
            }
            Section("About") {
                Text("Keep Cooking \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0") — offline-first, MIT.")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Settings")
    }

    private func syncNow() async {
        syncing = true
        defer { syncing = false }
        await SyncCoordinator.shared.sync()
        // The Status row reads the coordinator's lastResult live — nothing
        // to copy here (a stale copy is what froze "unauthorized" on screen).
    }

    /// Persists the Advanced custom-server URL only. Deliberately does NOT
    /// sync: on a fresh device the auto-generated identity is still a
    /// throwaway until the user joins their household, so syncing here
    /// would push local data to the custom server under the wrong bucket.
    /// The user taps Sync now after joining.
    private func saveServer() {
        let trimmed = customURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        if let error = validateCustomServer(trimmed) {
            healthResult = error
            return
        }
        UserDefaults.standard.set(trimmed, forKey: "smidgen.apiBaseURL")
        healthResult = "Server saved — tap Sync now after joining your household."
    }

    /// Acceptable custom-server values: blank (built-in) or an http(s) URL;
    /// http:// only for local dev hosts. Returns an error message, else nil.
    private func validateCustomServer(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        guard let url = URL(string: trimmed),
              let host = url.host?.lowercased(),
              !host.isEmpty
        else {
            return "That server URL does not look valid — keeping current server."
        }
        let scheme = url.scheme?.lowercased() ?? ""
        let isLocalDev = host == "localhost" || host == "127.0.0.1" || host.hasSuffix(".local")
        guard scheme == "https" || (scheme == "http" && isLocalDev) else {
            return "Server must use HTTPS (http:// is only allowed for localhost / 127.0.0.1 / *.local dev servers)."
        }
        return nil
    }

    private func joinWithBundle() {
        do {
            let bundle = try e2eParseInvite(pasteInput)
            if let active = E2EKeyStore.loadActive(), active.metadata.hash != bundle.hash {
                // This device already has a key that may hold synced data —
                // require explicit confirmation before switching households.
                pendingJoin = bundle
                joinResult = "This device is •\(String(active.metadata.hash.prefix(8))). Joining switches to •\(String(bundle.hash.prefix(8))) and replaces this device's key."
                return
            }
            finishJoin(try e2eJoin(bundle: bundle))
        } catch {
            joinResult = error.localizedDescription
        }
    }

    private func confirmPendingJoin() {
        guard let bundle = pendingJoin else { return }
        do {
            finishJoin(try e2eJoin(bundle: bundle))
        } catch {
            joinResult = error.localizedDescription
        }
    }

    private func finishJoin(_ res: E2EJoinResult) {
        householdName = res.householdId
        devicePrefix = res.hashPrefix8.isEmpty ? nil : res.hashPrefix8
        pendingJoin = nil
        // SECURITY: never auto-apply the invite's endpointHint. An
        // attacker-controlled bundle must not silently redirect this
        // device's backend. Stage it for explicit user confirmation +
        // GET /health validation instead (see pendingEndpointHint UI).
        if let hint = res.endpointHint?.trimmingCharacters(in: .whitespacesAndNewlines),
           !hint.isEmpty, hint != customURLString, hint != effectiveBaseURL {
            pendingEndpointHint = hint
            hintHealthResult = ""
            showAdvanced = true
            joinResult = "Joined •\(res.hashPrefix8). The invite suggests a custom server below — review it before switching."
        } else {
            pendingEndpointHint = nil
            hintHealthResult = ""
            joinResult = "Joined •\(res.hashPrefix8)."
        }
        pasteInput = ""
    }

    private func useBuiltInServer() {
        UserDefaults.standard.removeObject(forKey: "smidgen.apiBaseURL")
        customURLString = ""
        healthResult = "Using the built-in server."
    }

    /// GET <base>/health against the typed URL (blank = built-in default).
    private func testHealth() async {
        testing = true
        defer { testing = false }
        let typed = customURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = typed.isEmpty ? effectiveBaseURL : typed
        guard let url = URL(string: base + "/health") else {
            healthResult = "Bad URL — check the server field."
            return
        }
        do {
            let (data, resp) = try await URLSession.shared.data(from: url)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            let body = String(data: data, encoding: .utf8) ?? ""
            healthResult = code == 200 ? "Healthy (\(code)): \(body.prefix(120))"
                : "Unhealthy (HTTP \(code)): \(body.prefix(120))"
        } catch {
            healthResult = "Unreachable: \(error.localizedDescription)"
        }
    }


    /// Confirmed adoption of the staged endpoint hint: validates
    /// GET <hint>/health, then — and only then — persists the hint as the
    /// backend URL. Requires explicit user action; never called implicitly.
    private func confirmEndpointHint() async {
        let rawHint = pendingEndpointHint?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !rawHint.isEmpty else {
            hintHealthResult = "Invalid server URL — keeping current server."
            return
        }
        // Normalize: a hint ending in "/" would otherwise probe "<hint>//health".
        var hint = rawHint
        while hint.hasSuffix("/") && hint.count > 1 { hint = String(hint.dropLast()) }
        guard let hintURL = URL(string: hint),
              let scheme = hintURL.scheme?.lowercased(),
              let host = hintURL.host?.lowercased(),
              URL(string: hint + "/health") != nil
        else {
            hintHealthResult = "Invalid server URL — keeping current server."
            return
        }
        // SECURITY: only accept HTTPS hints, except explicitly local dev
        // targets (localhost / 127.0.0.1 / *.local). Require HTTPS so a
        // cleartext http:// hint can't leak household data on the wire.
        let isLocalDev = host == "localhost" || host == "127.0.0.1" || host.hasSuffix(".local")
        guard scheme == "https" || (scheme == "http" && isLocalDev) else {
            hintHealthResult = "Invite server must use HTTPS (http:// is only allowed for localhost / 127.0.0.1 / *.local dev servers) — keeping current server."
            return
        }
        let healthURL = URL(string: hint + "/health")!
        hintTesting = true
        defer { hintTesting = false }
        do {
            let (data, resp) = try await URLSession.shared.data(from: healthURL)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            guard code == 200 else {
                let body = String(data: data, encoding: .utf8) ?? ""
                hintHealthResult = "Server rejected (HTTP \(code)): \(body.prefix(120)) — keeping current server."
                return
            }
            // A second invite may have been joined while the health check was
            // in flight: only apply when the staged hint is still the one probed.
            let current: String? = pendingEndpointHint.map { pending in
                var normalized = pending.trimmingCharacters(in: .whitespacesAndNewlines)
                while normalized.hasSuffix("/") && normalized.count > 1 { normalized = String(normalized.dropLast()) }
                return normalized
            }
            guard current == hint else {
                hintHealthResult = "A newer invite arrived — review the suggested server again before switching."
                return
            }
            customURLString = hint
            UserDefaults.standard.set(hint, forKey: "smidgen.apiBaseURL")
            pendingEndpointHint = nil
            hintHealthResult = ""
            joinResult = "Server updated — now using \(hint)."
        } catch {
            hintHealthResult = "Unreachable: \(error.localizedDescription) — keeping current server."
        }
    }

    private func dismissEndpointHint() {
        pendingEndpointHint = nil
        hintHealthResult = ""
    }

    /// Re-reads Keychain/UserDefaults identifiers into the displayed state.
    private func refreshE2EState() {
        if let meta = E2EKeyStore.loadMetadata() {
            householdName = meta.householdId
            devicePrefix = String(meta.hash.prefix(8))
        } else {
            householdName = "hh-demo"
            devicePrefix = nil
        }
    }
}

// MARK: - Demo plan seeding (current week, idempotent)

enum DemoSeeds {
    static func weekStart(containing date: Date) -> Date {
        let cal = Calendar.current
        let comps = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        return cal.date(from: comps) ?? cal.startOfDay(for: date)
    }

    /// Ensures Mon/Wed/Fri dinner plans exist for the current week so the
    /// plan→list video is deterministic. Skips entries already present.
    static func seedDemoPlans(context: ModelContext, deviceId: String) {
        let recipes = ((try? context.fetch(
            FetchDescriptor<Recipe>(sortBy: [SortDescriptor(\Recipe.title)]))) ?? [])
            .filter { !$0.tombstoned }
        guard recipes.count >= 3 else { return }
        let cal = Calendar.current
        let start = weekStart(containing: Date())
        let picks: [(dayOffset: Int, meal: MealSlot)] = [
            (0, .dinner), (2, .dinner), (4, .dinner),
        ]
        let existing = (try? context.fetch(FetchDescriptor<Plan>())) ?? []
        var allPlans = existing
        for (i, pick) in picks.enumerated() {
            guard let day = cal.date(byAdding: .day, value: pick.dayOffset, to: start) else { continue }
            let recipe = recipes[i % recipes.count]
            let dayStart = cal.startOfDay(for: day)
            let dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart) ?? day
            // Resurrection guard: consider BOTH live and tombstoned plans. If
            // the user deleted this seeded slot (deleted=true tombstone), a
            // live-only check would see no match and insert a fresh duplicate,
            // resurrecting the deleted row. Only seed when zero plans match.
            let alreadyPresent = allPlans.contains {
                $0.date >= dayStart && $0.date < dayEnd
                    && $0.mealRaw == pick.meal.rawValue && $0.recipeId == recipe.id
            }
            if alreadyPresent { continue }
            let plan = Plan(householdId: "hh-demo", date: day, meal: pick.meal,
                recipeId: recipe.id, servings: recipe.servings, deviceId: deviceId)
            context.insert(plan)
            allPlans.append(plan)
        }
        collapseExactDuplicatePlans(allPlans, calendar: cal)
        try? context.save()
    }

    /// One-time cleanup for legacy exact duplicates left by the old seeding
    /// bug: groups LIVE plans by calendar-day + mealRaw + recipeId + note and
    /// tombstones all but the earliest-updated member of groups with > 1.
    /// Exact-match only — groups of size 1 and plans differing in any key are
    /// never touched.
    private static func collapseExactDuplicatePlans(_ plans: [Plan], calendar: Calendar) {
        var groups: [PlanDedupeKey: [Plan]] = [:]
        for plan in plans where !plan.tombstoned {
            let key = PlanDedupeKey(
                day: calendar.startOfDay(for: plan.date),
                mealRaw: plan.mealRaw,
                recipeId: plan.recipeId,
                note: plan.note)
            groups[key, default: []].append(plan)
        }
        let now = Date()
        for (_, dupes) in groups where dupes.count > 1 {
            let ordered = dupes.sorted { $0.updatedAt < $1.updatedAt }
            for extra in ordered.dropFirst() {
                extra.tombstoned = true
                extra.updatedAt = now
            }
        }
    }
}

private struct PlanDedupeKey: Hashable {
    let day: Date
    let mealRaw: String
    let recipeId: String?
    let note: String
}

private func currentDeviceId() -> String {
    // Persisted UUIDv4 (DeviceAuth); identifierForVendor is display-only.
    DeviceAuth.currentDeviceId()
}
