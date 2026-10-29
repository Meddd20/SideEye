//
//  StatusMenuController.swift
//  Sideeye
//
//  Created by Medhiko Biraja on 2026.
//  Copyright © 2026 Medhiko Biraja. Licensed under the MIT License.
//

import Cocoa
import ScreenCaptureKit

class StatusMenuController: NSObject {

    private let captureEngine: CaptureEngine
    private let windowListManager = WindowListManager()

    private var statusItem: NSStatusItem!
    private weak var statusMenu: NSMenu?

    private let mirrorWindowSubmenu = NSMenu()
    private let mirrorWindowItem = NSMenuItem(title: "No Windows Yet", action: nil, keyEquivalent: "")

    // Built once, re-arranged into different combinations per menu shape
    // (idle vs. mirroring).
    private let stopMirroringItem = NSMenuItem(
        title: "Stop Mirroring",
        action: #selector(stopMirroring),
        keyEquivalent: ""
    )
    private let opacityItem = NSMenuItem()
    private let opacitySlider = NSSlider(value: 1.0, minValue: 0.0, maxValue: 1.0, target: nil, action: nil)
    private let opacityPercentLabel = NSTextField(labelWithString: "100%")
    private let clickThroughItem = NSMenuItem(
        title: "Click-Through",
        action: #selector(toggleClickThrough),
        keyEquivalent: ""
    )
    private let clickThroughHintItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let hotkeyHintItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let showMirrorItem = NSMenuItem(
        title: "Show Mirrored Window",
        action: #selector(showMirror),
        keyEquivalent: ""
    )
    private let savedPreferencesItem = NSMenuItem(
        title: "Saved Preferences",
        action: nil,
        keyEquivalent: ""
    )
    private let savedPreferencesMenu = NSMenu()
    private let quitItem = NSMenuItem(
        title: "Quit Sideeye",
        action: #selector(quitApp),
        keyEquivalent: "q"
    )

    init(captureEngine: CaptureEngine) {
        self.captureEngine = captureEngine
        super.init()

        setupStatusItem()
        windowListManager.delegate = self
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem.button {
            if let originalImage = NSImage(named: "Icon") {
                originalImage.size = NSSize(width: 24, height: 24)
                button.image = originalImage
                button.image?.isTemplate = true
            }
        }

        let menu = NSMenu()
        statusMenu = menu
        menu.autoenablesItems = false

        // Wire up the stored controls once.
        stopMirroringItem.target = self
        showMirrorItem.target = self

        opacitySlider.target = self
        opacitySlider.action = #selector(opacityChanged(_:))
        opacityItem.view = createOpacityView()

        clickThroughItem.target = self

        // Disabled caption — explains what Click-Through does; the name
        // alone doesn't.
        clickThroughHintItem.attributedTitle = NSAttributedString(
            string: "Mouse clicks pass through the mirror\nto the windows behind it",
            attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.secondaryLabelColor
            ]
        )
        clickThroughHintItem.isEnabled = false

        // Disabled caption — makes the hotkeys discoverable, or explains
        // why peek is dead (no permission).
        hotkeyHintItem.isEnabled = false

        quitItem.target = self

        savedPreferencesMenu.autoenablesItems = false
        savedPreferencesItem.submenu = savedPreferencesMenu

        mirrorWindowSubmenu.autoenablesItems = false
        mirrorWindowItem.submenu = mirrorWindowSubmenu

        menu.delegate = self
        statusItem.menu = menu

        rebuildMenuItems()
    }

    /// The menu has two shapes:
    ///
    /// Idle (nothing mirrored):
    ///   Mirror a Window… ›
    ///   ─────────────
    ///   Quit Sideeye
    ///
    /// Mirroring:
    ///   Mirror a Window… ›
    ///   Stop Mirroring
    ///   Show Mirrored Window        (only while hidden via ⌘⌥2)
    ///   ─────────────
    ///   Opacity            80%
    ///   [─────●─────]
    ///   Hold ⌘⌥ to peek · Tap ⌘⌥3 to keep peek at 100%
    ///   Tap ⌘⌥2 to hide / show the mirror
    ///   ─────────────
    ///   Click-Through    ✓
    ///   Mouse clicks pass through…
    ///   ─────────────
    ///   Saved Preferences ›      (per mirrored app: save / apply / edit / delete)
    ///   ─────────────
    ///   Quit Sideeye
    ///
    /// The opacity/click-through controls only exist once there is something
    /// to tune — before that they'd be knobs attached to nothing.
    private func rebuildMenuItems() {
        guard let menu = statusMenu else { return }

        menu.removeAllItems()
        menu.addItem(mirrorWindowItem)

        if captureEngine.isMirroring {
            menu.addItem(stopMirroringItem)
            // Only offered while the mirror is actually hidden.
            if captureEngine.isMirrorHidden {
                menu.addItem(showMirrorItem)
            }
            menu.addItem(NSMenuItem.separator())
            menu.addItem(opacityItem)
            menu.addItem(hotkeyHintItem)
            menu.addItem(NSMenuItem.separator())
            menu.addItem(clickThroughItem)
            menu.addItem(clickThroughHintItem)
            menu.addItem(NSMenuItem.separator())
            menu.addItem(savedPreferencesItem)
            rebuildSavedPreferencesMenu()
        }

        menu.addItem(NSMenuItem.separator())
        menu.addItem(quitItem)

        // Set here, not in validateMenuItem: with autoenablesItems = false,
        // NSMenu skips item validation entirely.
        clickThroughItem.state = captureEngine.isClickThroughEnabled ? .on : .off

        updateHotkeyHint()
        syncOpacityControls()
    }

    /// The hotkey hint doubles as permission status: without the
    /// Accessibility grant, the peek-hold line is replaced with what to do
    /// about it. ⌘⌥2/⌘⌥3 are pure Carbon, so their lines are always shown.
    private func updateHotkeyHint() {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        let carbonLine = "Tap ⌘⌥3 to keep peek at 100%  ·  Tap ⌘⌥2 to hide / show"
        if captureEngine.isPeekAvailable {
            hotkeyHintItem.attributedTitle = NSAttributedString(
                string: "Hold ⌘⌥ to peek at full opacity\n" + carbonLine,
                attributes: attributes
            )
        } else {
            hotkeyHintItem.attributedTitle = NSAttributedString(
                string: "Peek (hold ⌘⌥): allow Sideeye in Accessibility settings\n" + carbonLine,
                attributes: attributes
            )
        }
    }

    // MARK: Opacity control

    /// Heading row ("Opacity" + live percentage) with the slider underneath.
    /// Tick marks at 25 / 50 / 75 give the eye anchors while dragging.
    private func createOpacityView() -> NSView {
        let width: CGFloat = 240
        let containerView = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 52))

        // Stretch the container with the menu width; otherwise the 240pt
        // view sits left-aligned and the percentage label strands far from
        // the right edge.
        containerView.autoresizingMask = [.width]

        let headingLabel = NSTextField(labelWithString: "Opacity")
        headingLabel.font = NSFont.systemFont(ofSize: 13)
        headingLabel.frame = NSRect(x: 16, y: 30, width: 120, height: 17)
        containerView.addSubview(headingLabel)

        opacityPercentLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        opacityPercentLabel.alignment = .right
        opacityPercentLabel.frame = NSRect(x: width - 66, y: 30, width: 50, height: 17)
        // Flexible left margin keeps the label glued to the container's
        // right edge as the menu stretches it.
        opacityPercentLabel.autoresizingMask = [.minXMargin]
        containerView.addSubview(opacityPercentLabel)

        // Range 0–1 with 5 tick marks puts the guides exactly at
        // 0 / 25 / 50 / 75 / 100%.
        opacitySlider.frame = NSRect(x: 14, y: 5, width: width - 28, height: 22)
        opacitySlider.numberOfTickMarks = 5
        opacitySlider.tickMarkPosition = .below
        opacitySlider.autoresizingMask = [.width]
        containerView.addSubview(opacitySlider)

        return containerView
    }

    private func syncOpacityControls() {
        let opacity = captureEngine.currentOpacity
        opacitySlider.doubleValue = opacity
        opacityPercentLabel.stringValue = percentText(opacity)
    }

    private func percentText(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }

    // MARK: Actions

    @objc private func toggleClickThrough() {
        captureEngine.toggleClickThrough()
    }

    @objc private func stopMirroring() {
        captureEngine.stopMirroring()
    }

    @objc private func showMirror() {
        captureEngine.showMirror()
    }

    // MARK: Saved preferences UI

    /// The "Saved Preferences" submenu — only exists while mirroring, because
    /// snapshots are stored per mirrored app and only make sense against a
    /// live mirror:
    ///
    ///   Saved for Brave Browser
    ///   Save Current as Preference…      ← the call to action, always on top
    ///   ─────────────
    ///   YouTube Corner ›                 Apply / Rename… / Update / Delete
    ///   Corner Cam ›
    ///   ─────────────
    ///   Reset to Default Style
    private func rebuildSavedPreferencesMenu() {
        savedPreferencesMenu.removeAllItems()

        let appName = captureEngine.currentAppName ?? "This App"
        savedPreferencesMenu.addItem(hintItem("Saved for \(appName)"))

        let saveItem = NSMenuItem(
            title: "Save Current as Preference…",
            action: #selector(saveCurrentPreference),
            keyEquivalent: ""
        )
        saveItem.target = self
        // Nothing to key the preference on without an identified source
        // app — disable rather than silently no-op.
        saveItem.isEnabled = captureEngine.canSavePreferences
        savedPreferencesMenu.addItem(saveItem)

        let names = captureEngine.savedPreferenceNames

        if names.isEmpty {
            savedPreferencesMenu.addItem(
                hintItem("No saved preferences yet\nSet up the mirror, then save it")
            )
        } else {
            savedPreferencesMenu.addItem(NSMenuItem.separator())
            let activeName = captureEngine.activeSavedPreferenceName
            for name in names {
                let item = NSMenuItem(title: name.truncated(to: 40), action: nil, keyEquivalent: "")
                item.representedObject = name
                item.submenu = savedPreferenceActions(for: name)
                item.toolTip = name
                if name == activeName {
                    item.state = .on
                }
                savedPreferencesMenu.addItem(item)
            }
        }

        savedPreferencesMenu.addItem(NSMenuItem.separator())

        let resetItem = NSMenuItem(
            title: "Reset to Default Style",
            action: #selector(resetStyleToDefault),
            keyEquivalent: ""
        )
        resetItem.target = self
        savedPreferencesMenu.addItem(resetItem)
    }

    /// Per-preset submenu: apply, rename, overwrite with the current look,
    /// delete — destructive actions sit below a separator.
    private func savedPreferenceActions(for name: String) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        menu.addItem(item("Apply", #selector(applyPreference(_:)), name))

        // "Set as Default" governs this app's future mirrors without
        // touching the live mirror. Its ✓ (and the parent row's ✓) is the
        // indicator of which snapshot governs; no ✓ anywhere means the
        // global remembered look applies.
        let makeDefault = item("Set as Default", #selector(setDefaultPreference(_:)), name)
        if name == captureEngine.activeSavedPreferenceName {
            makeDefault.state = .on
        }
        menu.addItem(makeDefault)

        menu.addItem(item("Rename…", #selector(renamePreference(_:)), name))
        menu.addItem(item("Update with Current", #selector(updatePreference(_:)), name))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(item("Delete", #selector(deletePreference(_:)), name))
        return menu
    }

    private func item(_ title: String, _ action: Selector, _ name: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = name
        return item
    }

    private func hintItem(_ text: String) -> NSMenuItem {
        let hint = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        hint.attributedTitle = NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.secondaryLabelColor
            ]
        )
        hint.isEnabled = false
        return hint
    }

    // MARK: Preference actions

    @objc private func saveCurrentPreference() {
        let appName = captureEngine.currentAppName ?? "This App"
        let fallbackName = captureEngine.suggestedPreferenceName()
        guard let name = prompt(
            title: "Save Mirror Preference",
            message: "Name this look for \(appName): window size, position, opacity and click-through, exactly as set right now.",
            initial: fallbackName
        ) else { return }
        captureEngine.saveCurrentAsPreference(named: name)
    }

    @objc private func applyPreference(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        captureEngine.applyPreference(named: name)
    }

    @objc private func setDefaultPreference(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        captureEngine.makePreferenceDefault(named: name)
    }

    @objc private func renamePreference(_ sender: NSMenuItem) {
        guard let oldName = sender.representedObject as? String else { return }
        guard let newName = prompt(
            title: "Rename Preference",
            message: "A new name for \"\(oldName)\".",
            buttonTitle: "Rename",
            initial: oldName
        ), newName != oldName else { return }
        if !captureEngine.renamePreference(oldName, to: newName) {
            inform(title: "Name Already Used", message: "\"\(newName)\" is already a saved preference for this app.")
        }
    }

    @objc private func updatePreference(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        captureEngine.updatePreferenceWithCurrent(named: name)
    }

    @objc private func deletePreference(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        if !confirm(title: "Delete Preference", message: "Delete \"\(name)\"? This can't be undone.") { return }
        captureEngine.deletePreference(named: name)
    }

    @objc private func resetStyleToDefault() {
        captureEngine.resetStyleToDefault()
    }

    /// Small modal name prompt. Returns nil on cancel or when left empty.
    private func prompt(title: String, message: String, buttonTitle: String = "Save", initial: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: buttonTitle)
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 22))
        field.stringValue = initial
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    private func confirm(title: String, message: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")

        NSApp.activate()
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func inform(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message

        NSApp.activate()
        alert.runModal()
    }

    @objc private func opacityChanged(_ sender: NSSlider) {
        // Keep a sliver of visibility — 0% is indistinguishable from missing.
        let value = max(0.05, sender.doubleValue)
        if value != sender.doubleValue {
            sender.doubleValue = value
        }
        opacityPercentLabel.stringValue = percentText(value)
        captureEngine.setOpacity(CGFloat(value))
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}

extension StatusMenuController: NSMenuDelegate {

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === statusMenu else { return }
        rebuildMenuItems()
        windowListManager.refresh()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleClickThrough) {
            menuItem.state = captureEngine.isClickThroughEnabled ? .on : .off
        }
        return true
    }
}

extension StatusMenuController: WindowListManagerDelegate {

    func windowListUpdated(
        current: [SCWindow],
        fullscreenElsewhere: [SCWindow],
        otherWindows: [SCWindow],
    ) {
        let allWindows = current + fullscreenElsewhere + otherWindows

        if allWindows.isEmpty {
            mirrorWindowItem.title = "No Windows to Mirror"
            mirrorWindowItem.submenu = nil
            mirrorWindowItem.action = nil
            mirrorWindowItem.isEnabled = false
        } else if allWindows.count == 1 {
            let window = allWindows[0]
            mirrorWindowItem.title = "Mirror \"\(window.displayName)\""
            mirrorWindowItem.submenu = nil
            mirrorWindowItem.action = #selector(mirrorSingleWindow)
            mirrorWindowItem.representedObject = window
            mirrorWindowItem.isEnabled = true
        } else {
            mirrorWindowItem.title = "Mirror a Window…"
            mirrorWindowItem.action = nil
            mirrorWindowItem.representedObject = nil
            mirrorWindowItem.submenu = mirrorWindowSubmenu
            mirrorWindowItem.isEnabled = true

            rebuildSubmenu(
                current: current,
                fullscreenElsewhere: fullscreenElsewhere,
                otherWindows: otherWindows,
            )
        }

        mirrorWindowSubmenu.update()
        statusMenu?.update()
    }

    private func rebuildSubmenu(
        current: [SCWindow],
        fullscreenElsewhere: [SCWindow],
        otherWindows: [SCWindow],
    ) {
        mirrorWindowSubmenu.removeAllItems()

        addSection(title: "This Workspace", windows: current, isFirst: true)
        addSection(title: "Full-Screen Workspaces", windows: fullscreenElsewhere, isFirst: false)
        if !otherWindows.isEmpty {
            addSection(title: "Other Workspaces", windows: otherWindows, isFirst: false)
        }
    }

    private func addSection(title: String, windows: [SCWindow], isFirst: Bool) {
        if !isFirst {
            mirrorWindowSubmenu.addItem(NSMenuItem.separator())
        }

        if (windows.count >= 1) {
            let header = NSMenuItem(title: "\(title) — \(windows.count) windows", action: nil, keyEquivalent: "")
            header.attributedTitle = NSAttributedString(
                string: "\(title) — \(windows.count) windows",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                    .foregroundColor: NSColor.secondaryLabelColor
                ]
            )
            header.isEnabled = false
            mirrorWindowSubmenu.addItem(header)
        }

        for window in windows.sorted(by: { $0.displayName < $1.displayName }) {
            let item = NSMenuItem(
                title: window.displayName.truncated(to: 70),
                action: #selector(selectWindow(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = window
            item.toolTip = window.displayName
            mirrorWindowSubmenu.addItem(item)
        }
    }

    @objc private func mirrorSingleWindow() {
        guard let window = mirrorWindowItem.representedObject as? SCWindow else { return }
        captureEngine.startMirroring(window)
    }

    @objc private func selectWindow(_ sender: NSMenuItem) {
        guard let window = sender.representedObject as? SCWindow else { return }
        captureEngine.startMirroring(window)
    }
}
