//
//  MirrorPreferences.swift
//  Sideeye
//
//  Created by Medhiko Biraja on 26/10/26.
//  Copyright © 2026 Medhiko Biraja. Licensed under the MIT License.
//

import Cocoa

// MARK: - The style itself

/// One complete "how the mirror should look" snapshot: size, position,
/// transparency, click-through. Stored in FRACTIONS of the screen's usable
/// area rather than raw points, so the same look carries the same visual
/// weight on any display. Height is the saved scale; center is the position;
/// the saved width fraction is not for sizing (the picture is aspect-locked
/// and never stretches) but the datum that lets `resolvedFrame` pin the
/// mirror's screen-adjacent edge when the source's shape changes — so a
/// corner mirror never drifts toward screen center.
struct MirrorStyle: Codable, Equatable {

    /// Window height ÷ the display's visibleFrame height. 0.27 reproduces the
    /// original 300pt default on a typical laptop's usable area.
    var heightFraction: Double

    /// Window width ÷ the display's visibleFrame width. NOT used to size the
    /// restored window (the content aspect derives that) — it is the datum
    /// that lets `resolvedFrame` pin the saved spot's screen-adjacent edge.
    /// `0` marks a pre-recording legacy style: no hugging edge is known, so
    /// restoring stays plain center-anchored.
    var widthFraction: Double

    /// Window center, as fractions of the display's visibleFrame.
    var centerXFraction: Double
    var centerYFraction: Double

    /// Which display the style was captured on. `nil` means "whatever the main
    /// display is" — that also covers the first-run default and displays whose
    /// UUID couldn't be resolved.
    var displayUUID: String?

    /// 0.05–1.0, matching the menu slider's floor (a 0% mirror is
    /// indistinguishable from a missing one).
    var opacity: Double

    /// Whether clicks pass through the mirror when this style is applied.
    var clickThrough: Bool

    static let defaultHeightFraction = 0.27
    static let minimumHeight: CGFloat = 100
    /// Breathing room so a restored window never kisses the Dock or the menu bar.
    static let screenMargin: CGFloat = 8

    /// The look of a first-time mirror: ~27% of the screen tall, centered,
    /// fully opaque, interactive (click-through OFF, so it can be dragged and
    /// resized before anything gets saved).
    static let `default` = MirrorStyle(
        heightFraction: defaultHeightFraction,
        widthFraction: 0,
        centerXFraction: 0.5,
        centerYFraction: 0.5,
        displayUUID: nil,
        opacity: 1.0,
        clickThrough: false
    )

    /// Turns the saved fractions into an actual frame for a source with
    /// `sourceAspect`: height kept from the saved scale, width re-derived
    /// from the source's shape (the picture must not stretch), the change
    /// anchored to the saved spot's screen-adjacent edge, then clamped
    /// inside a visible screen. Nil when there is no screen to resolve against.
    func resolvedFrame(sourceAspect: CGFloat) -> NSRect? {
        guard let aspect = Self.positive(sourceAspect) else { return nil }
        guard let screen = NSScreen.sideyeScreen(withUUID: displayUUID) ?? NSScreen.main else {
            return nil
        }
        let visible = screen.visibleFrame
        guard visible.width > 2 * Self.screenMargin, visible.height > 2 * Self.screenMargin else {
            return nil
        }

        // Screens shorter than the minimum-height floor raise a subtle trap:
        // forcing 100pt there would invert the later clamp (min > max) and
        // misplace the mirror, so the floor itself is capped by the screen.
        let tallestAllowed = visible.height - 2 * Self.screenMargin
        var height = min(max(CGFloat(heightFraction) * visible.height,
                             min(Self.minimumHeight, tallestAllowed)),
                         tallestAllowed)

        var width = height * aspect
        let widestAllowed = visible.width - 2 * Self.screenMargin
        if width > widestAllowed {
            width = widestAllowed
            height = width / aspect
        }

        let center = NSPoint(
            x: visible.minX + CGFloat(centerXFraction) * visible.width,
            y: visible.minY + CGFloat(centerYFraction) * visible.height
        )

        var x = min(max(center.x - width / 2, visible.minX + Self.screenMargin), visible.maxX - Self.screenMargin - width)
        let y = min(max(center.y - height / 2, visible.minY + Self.screenMargin), visible.maxY - Self.screenMargin - height)

        // Edge-hug anchoring: the saved width pins the screen-adjacent edge
        // of the saved spot and shape changes happen on the screen-INTERIOR
        // side — a mirror saved on the right keeps its right edge and
        // reflows leftward. Center-anchoring alone would drift corner
        // mirrors toward screen center on every source change.
        // widthFraction == 0 (legacy) stays plain center-anchored.
        if widthFraction > 0.001 {
            let savedWidth = min(CGFloat(widthFraction) * visible.width, widestAllowed)
            let neutralZone: CGFloat = 0.05
            if CGFloat(centerXFraction) > 0.5 + neutralZone {
                // Right-located: pin the right edge, reflow to the left.
                let huggingRightEdge = center.x + savedWidth / 2
                x = min(max(huggingRightEdge - width, visible.minX + Self.screenMargin), visible.maxX - Self.screenMargin - width)
            } else if CGFloat(centerXFraction) < 0.5 - neutralZone {
                // Left-located: pin the left edge, reflow to the right.
                let huggingLeftEdge = center.x - savedWidth / 2
                x = min(max(huggingLeftEdge, visible.minX + Self.screenMargin), visible.maxX - Self.screenMargin - width)
            }
        }

        return NSRect(x: x, y: y, width: width, height: height)
    }

    /// Snapshots the overlay's current look, bound to the display it mostly
    /// sits on. Fractions round to 4 decimals (≈0.1pt) so capturing at
    /// exactly the applied state compares Equatable-equal — the engine's
    /// echo guard depends on that; legitimate changes below ~0.2pt are
    /// intentionally treated as no change. All capture sites use this
    /// identical function.
    static func captured(from frame: NSRect, opacity: CGFloat, clickThrough: Bool) -> MirrorStyle {
        let screen = bestScreen(for: frame)
        let visible = validVisibleFrame(for: screen, fallback: frame)

        let centerX = visible.width > 0 ? (frame.midX - visible.minX) / visible.width : 0.5
        let centerY = visible.height > 0 ? (frame.midY - visible.minY) / visible.height : 0.5
        let heightFraction = visible.height > 0 ? frame.height / visible.height : Double(defaultHeightFraction)
        let widthFraction = visible.width > 0 ? frame.width / visible.width : 0

        return MirrorStyle(
            // 0.98, not a lower cap: a near-full-sized mirror must come
            // back near-full — otherwise it shrinks slightly on EVERY
            // restore. resolvedFrame clamps against the real screen anyway.
            heightFraction: rounded(min(max(heightFraction, 0.05), 0.98)),
            widthFraction: rounded(min(max(widthFraction, 0.02), 0.98)),
            centerXFraction: rounded(min(max(centerX, 0.0), 1.0)),
            centerYFraction: rounded(min(max(centerY, 0.0), 1.0)),
            displayUUID: screen?.sideyeDisplayUUID,
            opacity: rounded(min(max(Double(opacity), 0.05), 1.0)),
            clickThrough: clickThrough
        )
    }

    /// The screen whose frame contains the window's center — or, if the window
    /// is on none of them (the monitor it sat on was unplugged), whichever is
    /// closest by center distance.
    private static func bestScreen(for frame: NSRect) -> NSScreen? {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return nil }

        let center = NSPoint(x: frame.midX, y: frame.midY)
        if let containing = screens.first(where: { $0.frame.contains(center) }) {
            return containing
        }
        return screens.min { a, b in
            squaredDistance(from: center, to: a.frame) < squaredDistance(from: center, to: b.frame)
        }
    }

    private static func validVisibleFrame(for screen: NSScreen?, fallback: NSRect) -> NSRect {
        if let screen, screen.visibleFrame.width > 0, screen.visibleFrame.height > 0 {
            return screen.visibleFrame
        }
        return NSRect(x: 0, y: 0, width: max(fallback.width, 1), height: max(fallback.height, 1))
    }

    private static func rounded(_ value: Double) -> Double {
        (value * 10_000).rounded() / 10_000
    }

    private static func positive(_ value: CGFloat) -> CGFloat? {
        value > 0.001 ? value : nil
    }

    private static func squaredDistance(from point: NSPoint, to rect: NSRect) -> CGFloat {
        let dx = max(max(rect.minX - point.x, 0), point.x - rect.maxX)
        let dy = max(max(rect.minY - point.y, 0), point.y - rect.maxY)
        return dx * dx + dy * dy
    }
}

// MARK: - Display identity

extension NSScreen {

    /// A stable string identity for a physical display. `NSScreen` exposes no
    /// UUID of its own, but its CGDirectDisplayID converts into one, and —
    /// unlike the raw numeric display ID, which is reassigned every boot — the
    /// UUID survives relaunches and cable cycles. That is what lets a saved
    /// style land back on the *same* monitor weeks later.
    var sideyeDisplayUUID: String? {
        guard let number = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let cfUUID = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue() else {
            return nil
        }
        return CFUUIDCreateString(nil, cfUUID) as String?
    }

    static func sideyeScreen(withUUID uuid: String?) -> NSScreen? {
        guard let uuid else { return nil }
        return NSScreen.screens.first { $0.sideyeDisplayUUID == uuid }
    }
}

// MARK: - Persistence

/// The named snapshots for ONE mirrored app, plus which snapshot (if any)
/// currently governs that app.
private struct AppMirrorPreferences: Codable {
    var presets: [String: MirrorStyle] = [:]
    var presetOrder: [String] = []
    var activePresetName: String?
}

private struct MirrorPreferencesDocument: Codable {
    var version = 2

    /// The ONE global auto-baseline: how the mirror WINDOW itself was last
    /// left — size, place, opacity, click-through — no matter which app's
    /// window was mirrored. This is the layer that answers "unshare this
    /// window, mirror another one → same look".
    var lastUsed: MirrorStyle?

    var apps: [String: AppMirrorPreferences] = [:]
}

/// UserDefaults-backed store of mirror preferences, holding two books:
///
/// 1. ONE global auto-remembered look (`lastUsed`), written on every real
///    move/resize/opacity change — the mirror follows the user across apps.
/// 2. Per-app named preferences keyed by bundle identifier (the only
///    identity that survives relaunches); a saved app's active snapshot
///    GOVERNS that app and auto-applies whenever it is mirrored.
///
/// One JSON document under one defaults key keeps the schema evolvable
/// (bump `version`, migrate, write new). Writes are debounced — the memory
/// copy is instant, the disk write coalesces churn, and `flush()` forces it
/// at Stop/quit time so the tail never dies with the process.
final class MirrorPreferencesStore {

    private static let defaultsKey = "MirrorPreferences"
    private static let saveDelay: TimeInterval = 0.4
    /// Hard cap on how long the FIRST pending change may stay unsaved. Pure
    /// trailing debounce lets a continuous multi-second drag push "0.4s from
    /// now" forward forever — a crash mid-drag would then lose the whole
    /// baseline, not just its tail.
    private static let maxSaveLag: TimeInterval = 2.0

    private var document: MirrorPreferencesDocument
    private var pendingSave: DispatchWorkItem?
    private var oldestUnsavedAt: Date?

    init() {
        guard let data = UserDefaults.standard.data(forKey: Self.defaultsKey) else {
            document = MirrorPreferencesDocument()
            return
        }
        do {
            let decoded = try JSONDecoder().decode(MirrorPreferencesDocument.self, from: data)
            guard decoded.version <= MirrorPreferencesDocument().version else {
                // Written by a newer Sideeye — don't half-understand it and
                // then write a mangled copy back on the next save.
                print("Sideeye: mirror preferences were saved by a newer version (\(decoded.version)); starting fresh")
                document = MirrorPreferencesDocument()
                return
            }
            var migrated = decoded
            if decoded.version < MirrorPreferencesDocument().version {
                Self.migrateLegacyBaseline(&migrated, rawData: data)
                print("Sideeye: upgraded saved mirror preferences to version \(MirrorPreferencesDocument().version)")
            }
            document = migrated
        } catch {
            // Corrupt or legacy-unreadable: say so loudly instead of silently
            // pretending nothing was ever saved.
            print("Sideeye: couldn't decode saved mirror preferences (\(error)); starting fresh")
            document = MirrorPreferencesDocument()
        }
    }

    /// v1 kept the auto-remembered look inside each app's entry; v2 keeps ONE
    /// global baseline (the mirror follows the user across apps) and leaves
    /// the per-app snapshots alone. Lift a legacy remembered look into the
    /// global slot so an existing install keeps its carry-over. (v2 decoding
    /// already silently drops the unknown per-app `lastUsed` fields — the
    /// snapshots survive untouched — so only the baseline needs lifting.)
    private static func migrateLegacyBaseline(_ document: inout MirrorPreferencesDocument, rawData data: Data) {
        document.version = MirrorPreferencesDocument().version
        guard document.lastUsed == nil,
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let apps = raw["apps"] as? [String: [String: Any]] else { return }

        let legacyBaseline = apps
            .sorted { $0.key < $1.key }
            .compactMap { $1["lastUsed"] as? [String: Any] }
            .first
        guard let legacyBaseline,
              let legacyData = try? JSONSerialization.data(withJSONObject: legacyBaseline) else { return }
        document.lastUsed = try? JSONDecoder().decode(MirrorStyle.self, from: legacyData)
    }

    // MARK: Global auto-baseline (the mirror itself)

    func lastUsed() -> MirrorStyle? {
        document.lastUsed
    }

    func recordLastUsed(_ style: MirrorStyle) {
        document.lastUsed = style
        scheduleSave()
    }

    // MARK: Per-app saved preferences

    /// The snapshot that currently governs this app, if any — the engine
    /// auto-applies it whenever this app is mirrored.
    func activePresetStyle(for appKey: String) -> MirrorStyle? {
        guard let prefs = document.apps[appKey],
              let name = prefs.activePresetName else { return nil }
        return prefs.presets[name]
    }

    /// Presets in saved order; anything found outside the order array is
    /// appended alphabetically, never silently hidden.
    func presetNames(for appKey: String) -> [String] {
        guard let prefs = document.apps[appKey] else { return [] }
        var names = prefs.presetOrder.filter { prefs.presets[$0] != nil }
        names.append(contentsOf: prefs.presets.keys.filter { !names.contains($0) }.sorted())
        return names
    }

    func preset(named name: String, for appKey: String) -> MirrorStyle? {
        document.apps[appKey]?.presets[name]
    }

    func activePreset(for appKey: String) -> String? {
        document.apps[appKey]?.activePresetName
    }

    func savePreset(named name: String, style: MirrorStyle, for appKey: String) {
        var prefs = document.apps[appKey] ?? AppMirrorPreferences()
        guard !name.isEmpty else { return }
        if prefs.presets[name] == nil { prefs.presetOrder.append(name) }
        prefs.presets[name] = style
        prefs.activePresetName = name
        document.apps[appKey] = prefs
        scheduleSave()
    }

    /// Returns false when the rename collides with another preset or is empty.
    @discardableResult
    func renamePreset(_ name: String, to newName: String, for appKey: String) -> Bool {
        guard var prefs = document.apps[appKey], let style = prefs.presets[name] else { return false }
        guard !newName.isEmpty else { return false }
        if newName != name, prefs.presets[newName] != nil { return false }

        prefs.presets.removeValue(forKey: name)
        prefs.presets[newName] = style
        if let index = prefs.presetOrder.firstIndex(of: name) {
            prefs.presetOrder[index] = newName
        }
        if prefs.activePresetName == name { prefs.activePresetName = newName }

        document.apps[appKey] = prefs
        scheduleSave()
        return true
    }

    func updatePreset(named name: String, style: MirrorStyle, for appKey: String) {
        guard var prefs = document.apps[appKey], prefs.presets[name] != nil else { return }
        prefs.presets[name] = style
        prefs.activePresetName = name
        document.apps[appKey] = prefs
        scheduleSave()
    }

    func deletePreset(named name: String, for appKey: String) {
        guard var prefs = document.apps[appKey] else { return }
        prefs.presets.removeValue(forKey: name)
        prefs.presetOrder.removeAll { $0 == name }
        if prefs.activePresetName == name { prefs.activePresetName = nil }
        document.apps[appKey] = prefs
        scheduleSave()
    }

    /// Marks a snapshot as governing this app (the ✓ in the menu). The mark
    /// survives normal tweaks — the snapshot will auto-apply again on the
    /// next share of this app — and drops only through Delete or Reset.
    func setActivePreset(_ name: String?, for appKey: String) {
        var prefs = document.apps[appKey] ?? AppMirrorPreferences()
        if let name, prefs.presets[name] != nil {
            prefs.activePresetName = name
        } else {
            prefs.activePresetName = nil
        }
        document.apps[appKey] = prefs
        scheduleSave()
    }

    /// Stops any snapshot from governing this app; the app then falls back to
    /// the global auto-baseline. Saved snapshots are NOT deleted.
    func clearActivePreset(for appKey: String) {
        guard var prefs = document.apps[appKey] else { return }
        prefs.activePresetName = nil
        document.apps[appKey] = prefs
        scheduleSave()
    }

    /// "Preference" → "Preference 2" → … so saving never silently overwrites.
    func uniqueName(base: String, for appKey: String) -> String {
        let baseName = base.isEmpty ? "Preference" : base
        var candidate = baseName
        var counter = 2
        while document.apps[appKey]?.presets[candidate] != nil {
            candidate = "\(baseName) \(counter)"
            counter += 1
        }
        return candidate
    }

    // MARK: Saving

    /// Coalesces churn into one disk write — 0.4s of quiet OR 2s of total lag,
    /// whichever comes first.
    func scheduleSave() {
        let now = Date()
        if oldestUnsavedAt == nil { oldestUnsavedAt = now }
        if let first = oldestUnsavedAt, now.timeIntervalSince(first) >= Self.maxSaveLag {
            flush()
            return
        }
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.saveDelay, execute: work)
    }

    /// Cancels any pending debounced write and writes immediately — the
    /// Stop/quit path, so the last fractions of a second aren't lost.
    func flush() {
        pendingSave?.cancel()
        pendingSave = nil
        saveNow()
    }

    private func saveNow() {
        pendingSave = nil
        oldestUnsavedAt = nil
        guard let data = try? JSONEncoder().encode(document) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }
}

// MARK: - Backward-compatible decoding

extension MirrorStyle {
    /// Tolerant decode: styles saved before `widthFraction` existed (store
    /// schema v2) come back with `0` — meaning "hugging edge unknown", which
    /// `resolvedFrame` treats as plain center-anchoring — so upgrading never
    /// breaks already-saved looks. Note this lives in an extension ON PURPOSE:
    /// a custom `init` inside the struct's main body would suppress the
    /// memberwise initializer every other call site relies on.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            heightFraction: try container.decode(Double.self, forKey: .heightFraction),
            widthFraction: try container.decodeIfPresent(Double.self, forKey: .widthFraction) ?? 0,
            centerXFraction: try container.decode(Double.self, forKey: .centerXFraction),
            centerYFraction: try container.decode(Double.self, forKey: .centerYFraction),
            displayUUID: try container.decodeIfPresent(String.self, forKey: .displayUUID),
            opacity: try container.decode(Double.self, forKey: .opacity),
            clickThrough: try container.decode(Bool.self, forKey: .clickThrough)
        )
    }
}
