//
//  CaptureEngine.swift
//  Sideeye
//
//  Created by Medhiko Biraja on 2026.
//  Copyright © 2026 Medhiko Biraja. Licensed under the MIT License.
//

import Cocoa
import AVFoundation
import ScreenCaptureKit

class CaptureEngine: NSObject {

    private var overlayWindow: OverlayWindow?
    private var stream: SCStream?
    private let videoQueue = DispatchQueue(label: "Sideeye.videoQueue")
    private weak var activeMirrorView: MirrorView?

    private var lastMirroredWindow: SCWindow?

    // Mirror preferences, two books in one store: ONE global auto-remembered
    // window look that follows the user across apps, plus per-app named
    // snapshots whose active one governs its app.
    private let preferences = MirrorPreferencesStore()
    private var currentAppKey: String?
    private(set) var currentAppName: String?

    /// Suppresses change-recording while a saved style is being applied, so
    /// our own programmatic frame changes aren't recorded as user edits.
    private var isApplyingStyle = false
    /// Baseline from the last programmatic apply — the equality guard in
    /// recordCurrentStyle uses it to ignore echoes of our own `setFrame`.
    private var lastAppliedStyle: MirrorStyle?
    private var overlayObservers: [NSObjectProtocol] = []
    /// Observers attach once for the overlay's lifetime; keeps startStream
    /// idempotent.
    private var isObservingGeometry = false

    /// Source of truth for the menu's two shapes (idle vs. mirroring).
    var isMirroring: Bool { stream != nil }

    /// Last user-set opacity, so the slider shows the real value even
    /// before/after the overlay exists.
    private(set) var currentOpacity: CGFloat = 1.0

    /// Restored styles come back with their remembered click-through state;
    /// the untouched first-run default starts interactive (off) so a new
    /// mirror can be dragged and resized into place.
    private(set) var isClickThroughEnabled = false

    private var isPeeking = false
    private var peekManager: PeekManager?

    /// Whether the peek hotkey could be installed (Accessibility granted).
    /// The menu uses this to show either the hotkey hint or a permission hint.
    var isPeekAvailable: Bool { peekManager?.isAvailable ?? false }

    // ⌘⌥2 toggles visibility; the stream keeps running while hidden so
    // showing again is instant.
    private(set) var isMirrorHidden = false

    private(set) var isPeekLatched = false
    private var hotkeys: SystemHotkeys?

    /// Peek hold or latch forces full opacity; the slider value is kept so
    /// each release path restores it.
    private var effectiveOpacity: CGFloat {
        (isPeeking || isPeekLatched) ? 1.0 : currentOpacity
    }

    override init() {
        super.init()

        peekManager = PeekManager { [weak self] active in
            self?.setPeeking(active)
        }

        hotkeys = SystemHotkeys(
            mirrorToggleHandler: { [weak self] in
                self?.toggleMirrorHidden()
            },
            peekLatchToggleHandler: { [weak self] in
                self?.togglePeekLatched()
            }
        )
    }
    
    func startMirroring(_ window: SCWindow) {
        Task { @MainActor in
            if self.stream != nil {
                try? await self.stream?.stopCapture()
                self.stream = nil
            }
            
            if self.overlayWindow == nil {
                self.overlayWindow = OverlayWindow()
            }
            
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(
                    false,
                    onScreenWindowsOnly: false
                )
                
                guard let freshWindow = content.windows.first(where: { $0.windowID == window.windowID }) else {
                    return
                }
                
                await self.startStream(freshWindow)
            } catch {
                print("Failed to start mirroring: \(error)")
            }
        }
    }
    
    @MainActor
    private func startStream(_ window: SCWindow) async {
        // The overlay exists both here and in startMirroring, so a nil
        // window can never gate observer installation — attach
        // unconditionally and idempotently on every start.
        if overlayWindow == nil {
            overlayWindow = OverlayWindow()
        }
        if let overlay = overlayWindow {
            observeOverlayGeometry(in: overlay)
        }
        
        activeMirrorView = overlayWindow?.mirrorView
        lastMirroredWindow = window
        overlayWindow?.mirrorView?.flush()

        // Preferences are keyed by the source app's bundle identifier — the
        // only identity that survives relaunches (window IDs and titles
        // churn); the auto-baseline is global regardless.
        currentAppKey = window.owningApplication?.bundleIdentifier
            ?? window.owningApplication.map { "name:\($0.applicationName)" }
        currentAppName = window.owningApplication?.applicationName

        // Which look applies, in order of authority:
        //   1. The app's own governing saved preference.
        //   2. The GLOBAL last-used look — the mirror reopens wherever the
        //      user left it, whichever app's window it now mirrors.
        //   3. The untouched first-run default, interactive so it can be
        //      positioned. A resolved style carries its own click-through.
        var restored = currentAppKey.flatMap { preferences.activePresetStyle(for: $0) }
        if restored == nil {
            restored = preferences.lastUsed()
        }
        applyStyle(restored ?? .default,
                   clickThrough: restored?.clickThrough ?? false,
                   to: window)

        // A new session always starts visible, even if the previous one
        // ended hidden via ⌘⌥2.
        isMirrorHidden = false
        
        let config = SCStreamConfiguration()
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        config.width = Int(window.frame.width * scale)
        config.height = Int(window.frame.height * scale)
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.queueDepth = 3
        config.showsCursor = false
        
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        
        do {
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoQueue)
            self.stream = stream

            overlayWindow?.orderFront(nil)
            
            try await stream.startCapture()
        } catch {
            print("Failed to start stream: \(error)")
        }
    }
    
    func stopMirroring() {
        isMirrorHidden = false
        // User-visible boundary: clear the state, take the window down, and
        // flush the debounced write synchronously so the menu never shows
        // stale mirroring controls for a beat.
        let stream = self.stream
        self.stream = nil
        preferences.flush()
        overlayWindow?.orderOut(nil)
        overlayWindow?.mirrorView?.flush()
        if let stream {
            Task {
                try? await stream.stopCapture()
            }
        }
    }
    
    func toggleClickThrough() {
        isClickThroughEnabled.toggle()
        overlayWindow?.setClickThrough(isClickThroughEnabled)
        recordCurrentStyle()
    }

    func setOpacity(_ value: CGFloat) {
        currentOpacity = value
        overlayWindow?.setOpacity(effectiveOpacity)
        recordCurrentStyle()
    }

    /// Called by PeekManager while ⌘⌥ is held / released.
    func setPeeking(_ active: Bool) {
        isPeeking = active
        overlayWindow?.setOpacity(effectiveOpacity)
    }

    /// Called by SystemHotkeys on ⌘⌥3: latch the peek — full opacity
    /// WITHOUT holding any keys. Tap again to release back to the slider.
    func togglePeekLatched() {
        isPeekLatched.toggle()
        overlayWindow?.setOpacity(effectiveOpacity)
    }

    /// Called on ⌘⌥2 press: hide the mirror if visible, bring it back if
    /// hidden. The stream keeps running either way, so showing again is instant.
    func toggleMirrorHidden() {
        guard overlayWindow != nil else { return }
        if isMirrorHidden {
            showMirror()
        } else {
            hideMirror()
        }
    }

    func hideMirror() {
        isMirrorHidden = true
        overlayWindow?.orderOut(nil)
    }

    func showMirror() {
        isMirrorHidden = false
        overlayWindow?.orderFront(nil)
    }

    // MARK: - Saved mirror preferences

    /// Applies a complete style to the overlay: frame resolved against this
    /// source's aspect ratio, plus opacity and click-through — all in one
    /// guarded block so the notifications it fires can't be mistaken for
    /// user edits.
    private func applyStyle(_ style: MirrorStyle, clickThrough: Bool, to window: SCWindow) {
        guard let overlay = overlayWindow else { return }

        let sourceWidth = max(window.frame.width, 1)
        let sourceHeight = max(window.frame.height, 1)
        let aspect = sourceWidth / sourceHeight

        isApplyingStyle = true
        overlay.contentAspectRatio = NSSize(width: sourceWidth, height: sourceHeight)
        if let frame = style.resolvedFrame(sourceAspect: aspect) {
            overlay.setFrame(frame, display: false)
        } else {
            // No screen to resolve against — fall back to the centered
            // 300pt-height behavior.
            overlay.setContentSize(NSSize(width: 300 * aspect, height: 300))
            overlay.center()
        }
        currentOpacity = min(max(CGFloat(style.opacity), 0.05), 1.0)
        overlay.setOpacity(effectiveOpacity)
        isClickThroughEnabled = clickThrough
        overlay.setClickThrough(clickThrough)
        isApplyingStyle = false

        // The baseline captures the style's REAL click-through state — it is
        // exactly what gets remembered and restored next share; the echo
        // guard compares captures made the same way.
        lastAppliedStyle = MirrorStyle.captured(
            from: overlay.frame,
            opacity: currentOpacity,
            clickThrough: clickThrough
        )
    }

    /// Records the overlay's current look as the GLOBAL last-used style. Fires
    /// on every real move/resize/opacity/click-through change; the store keeps
    /// an instant in-memory copy and debounces the disk write.
    private func recordCurrentStyle() {
        guard !isApplyingStyle, let overlay = overlayWindow else { return }

        // Global on purpose: the next share of ANY app's window reopens in
        // this look unless that app has a governing saved preference.
        // Equality with lastAppliedStyle is the real echo suppression.
        let style = MirrorStyle.captured(
            from: overlay.frame,
            opacity: currentOpacity,
            clickThrough: isClickThroughEnabled
        )
        guard style != lastAppliedStyle else { return }
        preferences.recordLastUsed(style)
    }

    /// Watches the long-lived overlay window for every way the user can
    /// reshape it: dragging, live resize (fires continuously), the instant
    /// a resize settles, and moving to another display.
    private func observeOverlayGeometry(in window: OverlayWindow) {
        guard !isObservingGeometry else { return }
        isObservingGeometry = true

        let names: [Notification.Name] = [
            NSWindow.didMoveNotification,
            NSWindow.didResizeNotification,
            NSWindow.didEndLiveResizeNotification,
            NSWindow.didChangeScreenNotification
        ]
        for name in names {
            let observer = NotificationCenter.default.addObserver(
                forName: name,
                object: window,
                // nil queue = synchronous on the posting thread (main for
                // geometry notifications), so echoes inside our own setFrame
                // hit the isApplyingStyle guard rather than arriving after
                // it is cleared.
                queue: nil
            ) { [weak self] _ in
                self?.recordCurrentStyle()
            }
            overlayObservers.append(observer)
        }
    }

    /// Forces the debounced preference write now. Called at Stop and at quit.
    func flushPreferences() {
        preferences.flush()
    }

    // MARK: Preference actions (menu-facing)

    /// Whether "Save Current as Preference…" can actually save — it needs an
    /// identified source app; otherwise the menu items disable instead of
    /// silently no-oping.
    var canSavePreferences: Bool {
        currentAppKey != nil && overlayWindow != nil
    }

    var savedPreferenceNames: [String] {
        guard let key = currentAppKey else { return [] }
        return preferences.presetNames(for: key)
    }

    /// The saved preset currently governing this app's look, shown with a
    /// checkmark in the menu; drops only via Delete or Reset.
    var activeSavedPreferenceName: String? {
        guard let key = currentAppKey else { return nil }
        return preferences.activePreset(for: key)
    }

    func suggestedPreferenceName() -> String {
        guard let key = currentAppKey else { return "Preference" }
        return preferences.uniqueName(base: "Preference", for: key)
    }

    /// Saves the mirror's current look as a named preset for this app, and
    /// makes it that app's governing default from now on.
    func saveCurrentAsPreference(named name: String) {
        guard let key = currentAppKey, let overlay = overlayWindow else { return }
        let style = MirrorStyle.captured(
            from: overlay.frame,
            opacity: currentOpacity,
            clickThrough: isClickThroughEnabled
        )
        preferences.savePreset(named: name, style: style, for: key)
        // By definition this is the mirror's current state — it becomes the
        // global baseline too.
        preferences.recordLastUsed(style)
    }

    /// Applies a named preset exactly as saved, click-through included,
    /// marks it as governing this app, and makes it the global baseline.
    func applyPreference(named name: String) {
        guard let key = currentAppKey,
              let window = lastMirroredWindow,
              let style = preferences.preset(named: name, for: key) else { return }

        applyStyle(style, clickThrough: style.clickThrough, to: window)

        // The applied look becomes the global baseline too, so an app with
        // NO saved preference of its own still inherits it next share.
        // (lastAppliedStyle is exactly that state, captured post-clamp.)
        if let baseline = lastAppliedStyle {
            preferences.recordLastUsed(baseline)
        }
        preferences.setActivePreset(name, for: key)
    }

    /// Returns false when the new name collides with another preset or is empty.
    func renamePreference(_ name: String, to newName: String) -> Bool {
        guard let key = currentAppKey else { return false }
        return preferences.renamePreset(name, to: newName, for: key)
    }

    /// Marks a saved snapshot as this app's governing default WITHOUT touching
    /// the live mirror — it takes over on the next share of this app (unlike
    /// Apply, which reshapes the mirror right now).
    func makePreferenceDefault(named name: String) {
        guard let key = currentAppKey else { return }
        preferences.setActivePreset(name, for: key)
    }

    func updatePreferenceWithCurrent(named name: String) {
        guard let key = currentAppKey, let overlay = overlayWindow else { return }
        let style = MirrorStyle.captured(
            from: overlay.frame,
            opacity: currentOpacity,
            clickThrough: isClickThroughEnabled
        )
        preferences.updatePreset(named: name, style: style, for: key)
        // The snapshot now IS the mirror's state — keep the global baseline
        // in lockstep.
        preferences.recordLastUsed(style)
    }

    func deletePreference(named name: String) {
        guard let key = currentAppKey else { return }
        preferences.deletePreset(named: name, for: key)
    }

    /// Escape hatch: stop this app's saved preference from governing it and
    /// wipe the global auto-baseline back to "never set" — the mirror, and
    /// the next share, land on the first-run default. Named snapshots are
    /// NOT deleted; re-apply one to govern this app again.
    func resetStyleToDefault() {
        guard let key = currentAppKey, let window = lastMirroredWindow else { return }
        preferences.clearActivePreset(for: key)
        preferences.recordLastUsed(.default)
        applyStyle(.default, clickThrough: false, to: window)
    }
}

extension CaptureEngine: SCStreamOutput {

    // Runs on the non-main videoQueue and hands frames straight to
    // AVSampleBufferDisplayLayer.enqueue — documented thread-safe; skipping
    // the main-queue hop is the point of the zero-copy pipeline. Keep that
    // invariant if this is ever refactored.
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              sampleBuffer.isValid,
              sampleBuffer.formatDescription != nil else {
            return
        }
        
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
           let statusRaw = attachments.first?[SCStreamFrameInfo.status] as? Int,
           let status = SCFrameStatus(rawValue: statusRaw),
           status != .complete {
            return
        }
        
        activeMirrorView?.enqueue(sampleBuffer)
    }
}

extension CaptureEngine: SCStreamDelegate {
    
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in
            guard self.stream === stream else { return }

            self.stream = nil
            self.isMirrorHidden = false
            self.overlayWindow?.mirrorView?.flush()
            self.overlayWindow?.orderOut(nil)
            self.preferences.flush()
        }
    }
}
