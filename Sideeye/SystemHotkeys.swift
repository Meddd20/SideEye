//
//  SystemHotkeys.swift
//  Sideeye
//
//  Created by Medhiko Biraja on 26/10/26.
//  Copyright © 2026 Medhiko Biraja. Licensed under the MIT License.
//

import Carbon.HIToolbox

/// System-wide Carbon hotkeys — chords that must SWALLOW their keystroke so
/// the digit never leaks into whatever app has focus:
///
///   ⌘⌥2   toggle the mirrored window hidden/shown
///   ⌘⌥3   latch peek at full opacity on/off — the held-peek experience
///          (hold ⌘⌥, see PeekManager) without keeping keys pressed
///
/// RegisterEventHotKey needs NO Accessibility permission, and consuming the
/// chord is built in. The hotkeys stay live even while idle — pressing one
/// when nothing is mirrored still consumes the keystroke.
///
/// Recorded lesson from a first attempt: these were once bare backtick+digit
/// pairs, which mechanically can't be a "sequence" and misfire on every
/// keystroke of the digit. Modifiers make a chord a chord; ⌘⌥+digit also
/// lands on almost nothing else in standard macOS keybindings.
final class SystemHotkeys {

    private let onMirrorToggle: () -> Void
    private let onPeekLatchToggle: () -> Void

    private var handlerRef: EventHandlerRef?
    private var registrations: [(hotKeyRef: EventHotKeyRef?, id: UInt32)] = []

    private var isMirrorKeyDown = false
    private var isLatchKeyDown = false

    /// True when registration succeeded; a failure (the exact combo already
    /// claimed elsewhere) is at least detectable rather than silent.
    private(set) var isAvailable = false

    // Chord definitions. Virtual keycodes from Events.h: digits 2/3 = 19/20.
    // Modifiers Command+Option; bare keycodes with modifiers 0 are not
    // usable as chords — see the header lesson.
    private static let chordModifiers = UInt32(cmdKey | optionKey)
    private static let mirrorCombo = (keyCode: UInt32(kVK_ANSI_2), id: UInt32(2))
    private static let latchCombo = (keyCode: UInt32(kVK_ANSI_3), id: UInt32(3))

    init(
        mirrorToggleHandler: @escaping () -> Void,
        peekLatchToggleHandler: @escaping () -> Void
    ) {
        self.onMirrorToggle = mirrorToggleHandler
        self.onPeekLatchToggle = peekLatchToggleHandler
        register()
    }

    deinit {
        registrations.forEach { registration in
            if let hotKeyRef = registration.hotKeyRef {
                UnregisterEventHotKey(hotKeyRef)
            }
        }
        if let handlerRef = handlerRef {
            RemoveEventHandler(handlerRef)
        }
    }

    private func register() {
        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                          eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                          eventKind: UInt32(kEventHotKeyReleased)),
        ]

        let userData = Unmanaged.passUnretained(self).toOpaque()
        var handlerRef: EventHandlerRef?
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let userData = userData else { return noErr }
                var hotKeyID = EventHotKeyID()
                GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                Unmanaged<SystemHotkeys>
                    .fromOpaque(userData)
                    .takeUnretainedValue()
                    .handle(id: hotKeyID.id, kind: EventKind(GetEventKind(event)))
                return noErr
            },
            2, &eventTypes, userData, &handlerRef
        )
        self.handlerRef = handlerRef

        var allRegistered = installStatus == noErr
        for combo in [Self.mirrorCombo, Self.latchCombo] {
            var hotKeyRef: EventHotKeyRef?
            let status = RegisterEventHotKey(
                combo.keyCode,
                Self.chordModifiers,
                EventHotKeyID(signature: OSType(0x5349_4445), id: combo.id),
                GetApplicationEventTarget(),
                0,
                &hotKeyRef
            )
            registrations.append((hotKeyRef: hotKeyRef, id: combo.id))
            allRegistered = allRegistered && status == noErr
        }

        isAvailable = allRegistered
    }

    fileprivate func handle(id: UInt32, kind: EventKind) {
        let keyDown = kind == EventKind(kEventHotKeyPressed)
        let keyUp = kind == EventKind(kEventHotKeyReleased)

        if id == Self.mirrorCombo.id {
            // Toggle once per physical press — key auto-repeat must not
            // flip it a dozen times in a row.
            if keyDown {
                guard !isMirrorKeyDown else { return }
                isMirrorKeyDown = true
                onMirrorToggle()
            } else if keyUp {
                isMirrorKeyDown = false
            }
        } else if id == Self.latchCombo.id {
            if keyDown {
                guard !isLatchKeyDown else { return }
                isLatchKeyDown = true
                onPeekLatchToggle()
            } else if keyUp {
                isLatchKeyDown = false
            }
        }
    }
}
