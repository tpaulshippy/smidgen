// Keep Cooking — Lane 3 Capture
// apps/ios/Features/Ingest/ClipView.swift
//
// Paprika-parity ingest: URL → preview → save in <3 taps.
// Tap 1: paste URL + "Clip". Tap 2: review editable preview. Tap 3: "Save".
// POST /clip (ClipClient); saves into Lane 2 SwiftData models (Recipe + Ingredient + Step).

import SwiftUI
import SwiftData

public struct ClipView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase

    @State private var urlText: String = ""
    @State private var report: ClipReport?
    @State private var isLoading = false
    @State private var error: String?
    @State private var saveError: String?
    /// True when the visible preview predates a failed refresh — Save stays
    /// disabled so a stale recipe can't be persisted as if it were fresh.
    @State private var reportStale = false
    @State private var savedMessage: String?

    // Editable preview state
    @State private var title: String = ""
    @State private var ingredientLines: String = ""
    @State private var stepLines: String = ""

    @FocusState private var focused: Field?
    private enum Field { case url, title, ings, steps }

    var baseURL: URL

    private static func defaultBaseURL() -> URL {
        if let s = Bundle.main.object(forInfoDictionaryKey: "SMIDGEN_API_BASE_URL") as? String,
           !s.isEmpty, let url = URL(string: s) {
            return url
        }
        return URL(string: SyncConfig.prodBaseURL)!
    }

    public init(baseURL: URL? = nil, urlText: String = "") {
        self.baseURL = baseURL ?? Self.defaultBaseURL()
        _urlText = State(initialValue: urlText)
    }

    private func authedClient() -> ClipClient {
        let did = DeviceAuth.currentDeviceId()
        return ClipClient(baseURL: baseURL,
            betaToken: nil,
            userId: SyncConfig.userId, deviceId: did,
            signer: DeviceAuth.requestSigner(deviceId: did))
    }

    private var stepIndex: Int {
        if savedMessage != nil { return 2 }
        if report != nil { return 1 }
        return 0
    }

    private var canSave: Bool {
        isSavableTitle(title)
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    IngestStepsHeader(current: stepIndex)
                        .padding(.top, 8)

                    VStack(alignment: .leading, spacing: 10) {
                        Text("1 · Add a link")
                            .font(.headline)
                        Text("Paste a recipe link below and we'll pull in the details.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        TextField("Recipe link", text: $urlText)
                            .textFieldStyle(.roundedBorder)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .focused($focused, equals: .url)
                            .disabled(isLoading)
                            #if os(iOS)
                            .keyboardType(.URL)
                            #endif
                        Button(isLoading ? "Clipping…" : "Clip recipe") {
                            Task { await runClip() }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isLoading || urlText.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 14))

                    if let error {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.circle")
                            Text(error)
                        }
                        .font(.caption)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .background(Color(.secondarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                    }

                    if report != nil {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("2 · Review and save")
                                .font(.headline)
                            Text("Check the details — edit anything before saving.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Text("Ready to review.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if let warnings = report?.warnings, !warnings.isEmpty {
                                VStack(alignment: .leading, spacing: 4) {
                                    ForEach(warnings, id: \.self) { warning in
                                        HStack(spacing: 6) {
                                            Image(systemName: "exclamationmark.triangle")
                                            Text(clipWarningText(for: warning))
                                        }
                                        .font(.caption)
                                        .foregroundStyle(.orange)
                                    }
                                }
                            }
                            TextField("Title", text: $title)
                                .textFieldStyle(.roundedBorder)
                                .focused($focused, equals: .title)
                            Text("Ingredients")
                                .font(.caption).foregroundStyle(.secondary)
                            TextEditor(text: $ingredientLines)
                                .frame(minHeight: 80, maxHeight: 130)
                                .padding(6)
                                .background(Color(.tertiarySystemBackground))
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                                .focused($focused, equals: .ings)
                                .accessibilityLabel("Ingredients")
                            Text("Steps")
                                .font(.caption).foregroundStyle(.secondary)
                            TextEditor(text: $stepLines)
                                .frame(minHeight: 80, maxHeight: 130)
                                .padding(6)
                                .background(Color(.tertiarySystemBackground))
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                                .focused($focused, equals: .steps)
                                .accessibilityLabel("Steps")
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .background(Color(.secondarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 14))

                        VStack(alignment: .leading, spacing: 10) {
                            Text("3 · Save")
                                .font(.headline)
                            if let saveError {
                                HStack(spacing: 6) {
                                    Image(systemName: "exclamationmark.circle")
                                    Text(saveError)
                                }
                                .font(.caption)
                                .foregroundStyle(.red)
                            }
                            Button("Save recipe") { save() }
                                .buttonStyle(.borderedProminent)
                                .disabled(!canSave || savedMessage != nil || isLoading || reportStale)
                            if !canSave {
                                Text("Add a title to save.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .background(Color(.secondarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                    }

                    if let savedMessage {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text(savedMessage)
                                .foregroundStyle(.green)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .background(Color(.secondarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                }
                .padding()
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Save a recipe link")
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { focused = nil }
                }
            }
        }
        .onAppear { drainShareExtension() }
        .onChange(of: scenePhase, initial: false) { _, newPhase in
            if newPhase == .active { drainShareExtension() }
        }
    }

    // MARK: - Actions

    /// Host drain for the Share extension bridge (ShareStore.enqueue → App Group).
    /// Prefills the URL field when the user arrives via Share sheet.
    private func drainShareExtension() {
        // Never steal the queue while the user is typing: draining clears it.
        guard urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let pending = ShareStore.drain()
        guard let first = pending.first?.trimmingCharacters(in: .whitespacesAndNewlines),
              !first.isEmpty else { return }
        urlText = first
        // Preserve the rest for subsequent visits instead of dropping them.
        for rest in pending.dropFirst() {
            ShareStore.enqueue(url: rest)
        }
    }

    private func runClip() async {
        isLoading = true; error = nil; saveError = nil; savedMessage = nil; reportStale = false
        defer { isLoading = false }
        focused = nil
        let req = ClipRequest(url: urlText.trimmingCharacters(in: .whitespaces), source: .url)
        do {
            // Enroll before the first signed POST: on a fresh install the
            // server does not know this key yet and prod rejects the clip
            // with 401. Re-reads the id afterwards (409 recovery rotates it).
            await DeviceAuth.enrollIfNeeded(baseURL: baseURL, deviceId: DeviceAuth.currentDeviceId())
            let client = authedClient()
            let rep = try await client.clip(req)
            // PII-safe log: strategy + host + confidence only.
            print(client.logEvent(for: rep, requestURL: req.url).description)
            report = rep
            title = rep.recipe.title
            ingredientLines = (rep.recipe.ingredients ?? []).map {
                $0.display ?? "\($0.name)"
            }.joined(separator: "\n")
            stepLines = (rep.recipe.steps ?? []).map { $0.text }.joined(separator: "\n")
        } catch {
            print("Clip failed: \(error)")
            // Keep the previous preview (with the user's edits) but mark it
            // stale so Save stays disabled — a retry must succeed first.
            reportStale = report != nil
            self.error = clipServerErrorMessage(for: error)
                ?? "Couldn't clip that link. Check the address and try again."
        }
    }

    private func save() {
        let deviceId = currentDeviceId()
        let trimmed = cleanTitle(title)
        let recipe = Recipe(
            householdId: "hh-demo",
            title: trimmed.isEmpty ? (report?.recipe.title ?? trimmed) : trimmed,
            recipeDescription: report?.recipe.description ?? "",
            servings: report?.recipe.servings ?? 4,
            prepMinutes: report?.recipe.prepMinutes,
            cookMinutes: report?.recipe.cookMinutes,
            source: report?.recipe.source ?? "clip",
            sourceUrl: report?.recipe.sourceUrl ?? urlText,
            deviceId: deviceId
        )
        context.insert(recipe)
        // Track this attempt's inserts so a failed save can delete exactly
        // these objects — rollback() would also discard other views'
        // unsaved changes in the shared context.
        var inserted: [any PersistentModel] = [recipe]
        let parsed = IngredientParser.parseLines(ingredientLines)
        for (i, p) in parsed.enumerated() {
            let m = Ingredient(
                recipeId: recipe.id, name: p.name.isEmpty ? p.display : p.name,
                quantity: p.quantity, unit: p.unit, display: p.display,
                position: i, updatedAt: Date(), deviceId: deviceId
            )
            m.recipe = recipe
            context.insert(m)
            inserted.append(m)
        }
        let steps = stepLines.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        for (i, text) in steps.enumerated() {
            let m = Step(recipeId: recipe.id, position: i, text: text,
                         updatedAt: Date(), deviceId: deviceId)
            m.recipe = recipe
            context.insert(m)
            inserted.append(m)
        }
        do {
            try context.save()
            saveError = nil
            savedMessage = "Saved “\(recipe.title)” (\(parsed.count) ingredients, \(steps.count) steps)"
        } catch {
            inserted.forEach { context.delete($0) }
            print("Clip save failed: \(error)")
            saveError = "Couldn't save that recipe. Try again."
        }
        focused = nil
    }

    private func currentDeviceId() -> String {
        // Persisted UUIDv4 (DeviceAuth); identifierForVendor is display-only.
        DeviceAuth.currentDeviceId()
    }
}
