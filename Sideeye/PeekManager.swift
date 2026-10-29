//
//  PeekManager.swift
//  Sideeye
//
//  Created by Medhiko Biraja on 2026.
//  Copyright © 2026 Medhiko Biraja. Licensed under the MIT License.
//

import Cocoa
import CoreGraphics

/// The hold-peek hotkey: hold ⌘⌥ (Command + Option) and the overlay jumps to
/// full opacity; release either and it drops back to the opacity slider's
/// value. (Tap ⌘⌥3 latches the same effect without holding — that latch
/// lives in SystemHotkeys; PeekManager only owns the hold.)
///
/// Implemented as a listen-only CGEventTap on flagsChanged — the only way a
/// menu-bar app can observe keys being HELD while other apps have focus.
/// The tap inspects modifier state only, never keystrokes, and returns every
/// event untouched so ⌘⌥ keeps working normally in every other app.
///
/// Permission: a session tap needs Accessibility. Without it the tap
/// couldn't be created and peek stays dormant — the menu shows a permission
/// hint instead of the hotkey.
final class PeekManager {

    private let onPeek: (Bool) -> Void
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    /// Last state we reported; the handler only fires on real transitions.
    private var isPeekActive = false

    /// False when the tap couldn't be created (no Accessibility grant);
    /// the menu swaps the hotkey hint for a permission hint.
    var isAvailable: Bool { tap != nil }

    init(peekHandler: @escaping (Bool) -> Void) {
        self.onPeek = peekHandler
        startTap()
    }

    deinit {
        if let runLoopSource = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        if let tap = tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
    }

    private func startTap() {
        let mask = CGEventMask(1) << CGEventType.flagsChanged.rawValue

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,    // this login session, not other users
            place: .headInsertEventTap,
            options: .listenOnly,       // observe only; the keystroke passes on
            eventsOfInterest: mask,
            callback: { _, type, event, userData in
                guard let userData else {
                    return Unmanaged.passUnretained(event)
                }
                let manager = Unmanaged<PeekManager>
                    .fromOpaque(userData)
                    .takeUnretainedValue()
                manager.handle(type: type, event: event)
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            // No Accessibility permission — peek stays dormant.
            return
        }

        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        runLoopSource = source
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func handle(type: CGEventType, event: CGEvent) {
        // The system can disable a tap that stalls; revive it so peek
        // comes back on its own instead of dying silently.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }

        guard type == .flagsChanged else { return }

        // Peek = Command + Option held together. Checking the FULL modifier
        // state (not which key just changed) makes left/right variants and
        // any press order work; releasing either ends the peek.
        let active = event.flags.contains(.maskCommand)
                   && event.flags.contains(.maskAlternate)
        guard active != isPeekActive else { return }
        isPeekActive = active
        onPeek(active)
    }
}
