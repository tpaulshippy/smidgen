// Keep Cooking — Lane 3 Capture
// apps/ios/ShareExtension/ShareStore.swift
//
// App Group bridge between ShareExtension and host app.
// Group id: group.com.smidgen.share. Extension writes pending URLs;
// host app (ClipboardMonitor / ClipView) reads + clears them.

import Foundation

public enum ShareStore {
    public static let suiteName = "group.com.smidgen.share"
    public static let pendingKey = "smidgen.pendingShareURLs"
    private static let maxPending = 20

    static var defaults: UserDefaults? {
        UserDefaults(suiteName: suiteName)
    }

    /// Append a shared URL (extension side). No-ops when App Group missing.
    /// Trims input, ignores empty strings, dedupes, caps at maxPending.
    public static func enqueue(url: String) {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let d = defaults else { return }
        var arr = d.stringArray(forKey: pendingKey) ?? []
        if !arr.contains(trimmed) {
            arr.append(trimmed)
            if arr.count > maxPending { arr = Array(arr.suffix(maxPending)) }
            d.set(arr, forKey: pendingKey)
            // Explicit synchronize: extensions may be suspended before
            // the system flushes defaults; host reads on next foreground.
            d.synchronize()
        }
    }

    /// Read + clear pending URLs (host-app side).
    public static func drain() -> [String] {
        guard let d = defaults else { return [] }
        let arr = d.stringArray(forKey: pendingKey) ?? []
        d.removeObject(forKey: pendingKey)
        d.synchronize()
        return arr
    }

    /// Remove one matching URL (deep-link handoff consumed it). Preserves
    /// all other queued URLs. No-op when App Group missing or absent.
    public static func consume(url: String) {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let d = defaults else { return }
        var arr = d.stringArray(forKey: pendingKey) ?? []
        guard let i = arr.firstIndex(of: trimmed) else { return }
        arr.remove(at: i)
        d.set(arr, forKey: pendingKey)
        d.synchronize()
    }

    public static func pending() -> [String] {
        defaults?.stringArray(forKey: pendingKey) ?? []
    }
}
