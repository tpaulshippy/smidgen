// Keep Cooking — Lane 3 Capture
// apps/ios/ShareExtension/ShareViewController.swift
//
// Share Sheet: imports URL from Safari / IG / TikTok → host app via App Group.
// Extension target links ShareStore; host app drains on foreground.
//
// Xcode setup (manual, one time):
//  1. Add "Share Extension" target named KeepCookingShare, link this file + ShareStore.swift.
//  2. Enable App Groups capability on BOTH targets: group.com.smidgen.share.
//  3. NSExtensionActivationRule: NSExtensionActivationSupportsWebURLWithMaxCount = 1
//     (+ NSExtensionActivationSupportsText for caption shares).
//
// NOTE: UIKit only — no SwiftUI, no host-app imports. This file must stay
// extension-safe (it compiles into the Share Extension target only).

#if canImport(UIKit)
import UIKit
import UniformTypeIdentifiers

public final class ShareViewController: UIViewController {
    // MARK: - Theme (dark-mode + light-mode safe)

    /// Warm cooking accent that reads on both light and dark backgrounds.
    private let accent: UIColor = .systemOrange
    private var didFinish = false
    /// State lock: set when loading resolves to success/failure (or cancel).
    /// Distinct from didFinish (request completed) so success/failure buttons
    /// can still call completeRequest after the status is shown.
    private var didSettle = false
    /// Saved URL for the success-state "Open in Keep Cooking" deep link.
    private var savedURLString: String?

    // MARK: - UI

    private let card = UIView()
    private let iconWrap = UIView()
    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let statusLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let hintLabel = UILabel()
    private let cancelButton = UIButton(type: .system)
    private let openAppButton = UIButton(type: .system)
    private let doneButton = UIButton(type: .system)

    // MARK: - Lifecycle

    public override func viewDidLoad() {
        super.viewDidLoad()
        buildUI()
        setState(.loading)
        extractAndStore()
    }

    // MARK: - Layout

    private func buildUI() {
        // Explicit background so the sheet is never black-on-black.
        view.backgroundColor = .systemBackground

        card.backgroundColor = .secondarySystemBackground
        card.layer.cornerRadius = 20
        card.layer.masksToBounds = true
        card.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(card)

        let stack = UIStackView()
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 12
        stack.isLayoutMarginsRelativeArrangement = true
        stack.layoutMargins = UIEdgeInsets(top: 28, left: 24, bottom: 24, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)

        // App mark: tinted disc + SF Symbol, visible in both modes.
        iconWrap.backgroundColor = accent.withAlphaComponent(0.16)
        iconWrap.layer.cornerRadius = 32
        iconWrap.layer.masksToBounds = true
        iconWrap.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            iconWrap.widthAnchor.constraint(equalToConstant: 64),
            iconWrap.heightAnchor.constraint(equalToConstant: 64),
        ])
        iconView.image = UIImage(systemName: "book.closed.fill")
        iconView.tintColor = accent
        iconView.contentMode = .scaleAspectFit
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconWrap.addSubview(iconView)
        NSLayoutConstraint.activate([
            iconView.centerXAnchor.constraint(equalTo: iconWrap.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: iconWrap.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 30),
            iconView.heightAnchor.constraint(equalToConstant: 30),
        ])

        titleLabel.text = "Keep Cooking"
        titleLabel.font = UIFont.preferredFont(forTextStyle: .headline)
        titleLabel.textColor = .label // explicit: never black-on-black
        titleLabel.textAlignment = .center
        titleLabel.adjustsFontForContentSizeCategory = true

        statusLabel.text = "Clipping to Keep Cooking…"
        statusLabel.font = UIFont.preferredFont(forTextStyle: .body)
        statusLabel.textColor = .label // explicit primary text
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.adjustsFontForContentSizeCategory = true
        statusLabel.accessibilityIdentifier = "ShareStatusLabel"

        spinner.hidesWhenStopped = true
        spinner.color = .secondaryLabel
        spinner.accessibilityIdentifier = "ShareSpinner"

        hintLabel.text = "Open the app to review"
        hintLabel.font = UIFont.preferredFont(forTextStyle: .footnote)
        hintLabel.textColor = .secondaryLabel // explicit secondary text
        hintLabel.textAlignment = .center
        hintLabel.numberOfLines = 0
        hintLabel.adjustsFontForContentSizeCategory = true

        cancelButton.setTitle("Cancel", for: .normal)
        cancelButton.titleLabel?.font = UIFont.preferredFont(forTextStyle: .body)
        cancelButton.tintColor = accent
        cancelButton.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)

        // PRIMARY success action: accent-filled, opens host app clip flow.
        openAppButton.setTitle("Open in Keep Cooking", for: .normal)
        openAppButton.titleLabel?.font = UIFont.preferredFont(forTextStyle: .headline)
        openAppButton.backgroundColor = accent
        openAppButton.setTitleColor(.white, for: .normal)
        openAppButton.layer.cornerRadius = 12
        openAppButton.layer.masksToBounds = true
        openAppButton.contentEdgeInsets = UIEdgeInsets(top: 12, left: 20, bottom: 12, right: 20)
        openAppButton.accessibilityIdentifier = "ShareOpenAppButton"
        openAppButton.addTarget(self, action: #selector(openAppTapped), for: .touchUpInside)
        openAppButton.isHidden = true

        // Secondary success action + failure dismissal: plain Done.
        doneButton.setTitle("Done", for: .normal)
        doneButton.titleLabel?.font = UIFont.preferredFont(forTextStyle: .body)
        doneButton.tintColor = accent
        doneButton.accessibilityIdentifier = "ShareDoneButton"
        doneButton.addTarget(self, action: #selector(doneTapped), for: .touchUpInside)
        doneButton.isHidden = true

        [iconWrap, titleLabel, statusLabel, spinner, hintLabel, cancelButton, openAppButton, doneButton].forEach(stack.addArrangedSubview)

        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            card.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            card.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            card.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24),
            card.widthAnchor.constraint(lessThanOrEqualToConstant: 340),
            stack.topAnchor.constraint(equalTo: card.topAnchor),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor),
        ])
    }

    // MARK: - States (always on main thread)

    private enum SheetState {
        case loading
        case success(String)
        case failure(String)
    }

    private func setState(_ state: SheetState) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.setState(state) }
            return
        }
        switch state {
        case .loading:
            iconView.image = UIImage(systemName: "book.closed.fill")
            iconView.tintColor = accent
            iconWrap.backgroundColor = accent.withAlphaComponent(0.16)
            statusLabel.text = "Clipping to Keep Cooking…"
            hintLabel.text = "Hang tight…"
            spinner.startAnimating()
            // Loading: work in flight → Cancel only.
            cancelButton.isHidden = false
            openAppButton.isHidden = true
            doneButton.isHidden = true
        case .success(let message):
            iconView.image = UIImage(systemName: "checkmark.circle.fill")
            iconView.tintColor = .systemGreen
            iconWrap.backgroundColor = UIColor.systemGreen.withAlphaComponent(0.15)
            statusLabel.text = message
            hintLabel.text = "Open the app to review"
            spinner.stopAnimating()
            // Success: PRIMARY open-app + secondary Done.
            cancelButton.isHidden = true
            openAppButton.isHidden = false
            doneButton.isHidden = false
        case .failure(let message):
            iconView.image = UIImage(systemName: "exclamationmark.circle.fill")
            iconView.tintColor = .systemRed
            iconWrap.backgroundColor = UIColor.systemRed.withAlphaComponent(0.12)
            statusLabel.text = message
            hintLabel.text = "Try sharing a link from Safari."
            spinner.stopAnimating()
            // Failure: Done replaces Cancel (same Done behavior).
            cancelButton.isHidden = true
            openAppButton.isHidden = true
            doneButton.isHidden = false
        }
    }

    @objc private func cancelTapped() {
        complete(with: NSError(domain: NSCocoaErrorDomain,
                               code: NSUserCancelledError,
                               userInfo: [NSLocalizedDescriptionKey: "Share cancelled"]))
    }

    /// PRIMARY success action: open host app straight into Clip review flow,
    /// then completeRequest in the open-completion (single-shot, on main).
    /// Any failure/unavailable open falls back to completing (never strands).
    @objc private func openAppTapped() {
        guard let context = extensionContext else {
            finishCompletion()
            return
        }
        guard let saved = savedURLString,
              // Strict encoding: recipe URLs often carry their own ?query
              // (& would split this value into separate query items).
              let encoded = saved.addingPercentEncoding(withAllowedCharacters: .shareURLQueryValueAllowed),
              let url = URL(string: "smidgen://clip?url=\(encoded)") else {
            finishCompletion()
            return
        }
        context.open(url, completionHandler: { [weak self] _ in
            DispatchQueue.main.async {
                self?.finishCompletion()
            }
        })
    }

    /// Secondary success action + failure dismissal: just completes.
    @objc private func doneTapped() {
        finishCompletion()
    }

    /// Single-shot completeRequest wrapper (main thread).
    private func finishCompletion() {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in self?.finishCompletion() }
            return
        }
        guard !didFinish else { return }
        didFinish = true
        didSettle = true
        spinner.stopAnimating()
        extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
    }

    // MARK: - Extraction (robust, never leaves the sheet blank)

    private func extractAndStore() {
        guard let context = extensionContext else {
            finish(message: "Nothing to share", success: false)
            return
        }
        let items = context.inputItems.compactMap { $0 as? NSExtensionItem }
        let providers = items.flatMap { $0.attachments ?? [] }
        // Also accept a shared URL via attributed text when no attachments exist.
        let attributedFallback = items.compactMap { $0.attributedContentText?.string }.first
        guard !providers.isEmpty || (attributedFallback?.isEmpty == false) else {
            finish(message: "Nothing to share", success: false)
            return
        }

        // Safety net: if a host never calls our loadItem completion back, the
        // sheet must still show a final status (never linger blank / spinner forever).
        // No-op when any finish/cancel already ran (didSettle/didFinish single-shot).
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self, !self.didSettle, !self.didFinish else { return }
            self.finish(message: "Couldn't read that share", success: false)
        }

        // Priority order: URL → webURL fallback → plain text.
        // UTType.url.identifier == "public.url"; the legacy "public.url" string is
        // the on-disk form Safari/Chrome hand us (the UTType.webURL fallback path).
        let urlTypeIDs = [UTType.url.identifier, "public.url"]
        let webURLFallbackTypeIDs = ["public.url"]
        let textTypeIDs = [
            UTType.plainText.identifier,   // "public.plain-text"
            UTType.text.identifier,        // "public.text"
            "public.plain-text",
            "public.text",
            "public.utf8-plain-text",
        ]

        if let provider = firstProvider(in: providers, claiming: urlTypeIDs) {
            loadString(from: provider, typeIDs: urlTypeIDs) { [weak self] raw in
                guard let self else { return }
                if let s = self.firstURLString(from: raw) {
                    self.store(s)
                } else {
                    // URL slot claimed but unusable — fall through to text.
                    self.tryTextProviders(providers, textTypeIDs: textTypeIDs, attributedFallback: attributedFallback)
                }
            }
            return
        }
        if let provider = firstProvider(in: providers, claiming: webURLFallbackTypeIDs) {
            loadString(from: provider, typeIDs: webURLFallbackTypeIDs) { [weak self] raw in
                guard let self else { return }
                if let s = self.firstURLString(from: raw) {
                    self.store(s)
                } else {
                    self.tryTextProviders(providers, textTypeIDs: textTypeIDs, attributedFallback: attributedFallback)
                }
            }
            return
        }
        tryTextProviders(providers, textTypeIDs: textTypeIDs, attributedFallback: attributedFallback)
    }

    private func tryTextProviders(_ providers: [NSItemProvider],
                                  textTypeIDs: [String],
                                  attributedFallback: String?) {
        guard let provider = firstProvider(in: providers, claiming: textTypeIDs) else {
            // Last resort: attributed text or a plain-text description of the payload.
            if let s = firstURLString(from: attributedFallback) {
                store(s)
            } else {
                finish(message: "Nothing to share", success: false)
            }
            return
        }
        loadString(from: provider, typeIDs: textTypeIDs) { [weak self] raw in
            guard let self else { return }
            // Accept a pasted URL inside longer caption text; otherwise keep the text itself.
            if let text = self.coercedString(raw)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !text.isEmpty {
                self.store(ClipboardDetectorShim.firstURL(in: text) ?? text)
            } else if let s = self.firstURLString(from: attributedFallback) {
                self.store(s)
            } else {
                self.finish(message: "Nothing to share", success: false)
            }
        }
    }

    private func firstProvider(in providers: [NSItemProvider], claiming typeIDs: [String]) -> NSItemProvider? {
        for id in typeIDs {
            if let match = providers.first(where: { $0.hasItemConformingToTypeIdentifier(id) }) {
                return match
            }
        }
        return nil
    }

    /// Loads the first type ID the provider supports and coerces URL / String / Data.
    private func loadString(from provider: NSItemProvider,
                            typeIDs: [String],
                            completion: @escaping (Any?) -> Void) {
        let supported = typeIDs.first(where: { provider.hasItemConformingToTypeIdentifier($0) })
            ?? typeIDs.first
            ?? UTType.plainText.identifier
        provider.loadItem(forTypeIdentifier: supported, options: nil) { value, error in
            // Hop to main HERE so everything downstream (status text, enqueue,
            // completeRequest) runs on main inside the load completion — no
            // fixed-timer race: we dismiss only after the load actually finishes.
            DispatchQueue.main.async {
                if error != nil && value == nil {
                    completion(nil)
                } else {
                    completion(value)
                }
            }
        }
    }

    /// Accepts URL, String, and Data payloads; trims; extracts the first URL when embedded.
    private func firstURLString(from value: Any?) -> String? {
        guard let s = coercedString(value)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !s.isEmpty else { return nil }
        return ClipboardDetectorShim.firstURL(in: s) ?? s
    }

    private func coercedString(_ value: Any?) -> String? {
        switch value {
        case let url as URL:
            return url.absoluteString
        case let s as String:
            return s
        case let data as Data:
            return String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .utf16)
        case .none:
            return nil
        case let other?:
            // Defensive: some hosts hand us NSURL-bridged or opaque objects.
            let described = String(describing: other).trimmingCharacters(in: .whitespacesAndNewlines)
            return described.isEmpty ? nil : described
        }
    }

    private func store(_ s: String) {
        // Late loadItem callbacks after cancel/timeout must not save.
        guard !didFinish, !didSettle else { return }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            finish(message: "Nothing to share", success: false)
            return
        }
        savedURLString = trimmed
        ShareStore.enqueue(url: trimmed)
        finish(message: "Saved to Keep Cooking ✓", success: true)
    }

    private func finish(message: String, success: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.didSettle, !self.didFinish else { return }
            self.didSettle = true // single-shot: status locks; dismissal is via buttons
            self.setState(success ? .success(message) : .failure(message))
            // No auto-dismiss timer: user taps Open/Done to dismiss.
            // completeRequest runs in openAppTapped/doneTapped via finishCompletion.
        }
    }

    private func complete(with error: Error) {
        guard !didFinish else { return }
        didFinish = true
        didSettle = true
        spinner.stopAnimating()
        extensionContext?.cancelRequest(withError: error)
    }
}

/// Percent-encoding for a full URL embedded as a single query value:
/// unreserved marks only (RFC 3986 §2.3), so embedded `?&=` never split it.
private extension CharacterSet {
    static var shareURLQueryValueAllowed: CharacterSet {
        CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~")
    }
}

/// Minimal URL finder (mirrors ClipboardDetector; ShareExtension target
/// cannot import Features/Ingest, so this shim is intentional).
private enum ClipboardDetectorShim {
    static func firstURL(in text: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: #"https?://[^\s]+"#) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let m = re.firstMatch(in: text, range: range),
              let r = Range(m.range, in: text) else { return nil }
        // Trim trailing punctuation unlikely to be part of the URL.
        return String(text[r]).trimmingCharacters(in: CharacterSet(charactersIn: ".,);]}!\"'"))
    }
}
#endif
