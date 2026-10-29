//
//  OverlayWindow.swift
//  Sideeye
//
//  Created by Medhiko Biraja on 03/08/26.
//  Copyright © 2026 Medhiko Biraja. Licensed under the MIT License.
//

import Cocoa
import AVFoundation

/// A window that floats above other apps, can be made semi-transparent, and
/// can toggle whether it swallows mouse clicks or lets them pass through to
/// whatever is underneath. Hosts the frame sink that the ScreenCaptureKit
/// pipeline feeds with mirrored frames.
class OverlayWindow: NSWindow {

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.borderless],   // no chrome — not meant to look like a normal window
            backing: .buffered,
            defer: false
        )

        // .floating = above normal app windows, but below system-level UI.
        self.level = .floating

        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = false

        // Show on every Space, including fullscreen apps.
        self.collectionBehavior = [.canJoinAllSpaces, .stationary]

        // Start click-through so the mirror never intercepts clicks; the
        // engine flips this per restored style or menu toggle.
        self.ignoresMouseEvents = true

        // Without chrome, background-drag (move) and the invisible edge hit
        // zones from .resizable are the only ways to reshape the mirror —
        // both only while click-through is off.
        self.isMovableByWindowBackground = true
        self.styleMask.insert(.resizable)
        // Floor so the mirror can't be shrunk into nothing.
        self.contentMinSize = NSSize(width: 160, height: 100)

        setupMirrorContent()

        self.alphaValue = 1.0
    }

    private func setupMirrorContent() {
        let mirrorView = MirrorView(
            frame: self.contentView?.bounds ?? NSRect(x: 0, y: 0, width: 400, height: 300)
        )
        mirrorView.autoresizingMask = [.width, .height]
        self.contentView = mirrorView
    }

    /// The frame sink the capture pipeline enqueues into.
    var mirrorView: MirrorView? {
        contentView as? MirrorView
    }

    /// Sets whether clicks pass through this window to whatever is behind it.
    func setClickThrough(_ enabled: Bool) {
        ignoresMouseEvents = enabled
    }

    /// 0 = invisible, 1 = fully opaque.
    func setOpacity(_ value: CGFloat) {
        alphaValue = value
    }
}

/// An NSView whose backing layer is an AVSampleBufferDisplayLayer — the
/// GPU-composited layer type for coded video sample buffers, handed to
/// AppKit via makeBackingLayer().
class MirrorView: NSView {

    private let displayLayer = AVSampleBufferDisplayLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        // Letterbox/pillarbox the mirror — never stretch the picture.
        displayLayer.videoGravity = .resizeAspect
    }

    required init?(coder: NSCoder) {
        fatalError("MirrorView is built in code, never from a nib/storyboard")
    }

    override var wantsLayer: Bool {
        get { true }
        set { /* intentionally fixed: a MirrorView is always layer-backed */ }
    }

    override func makeBackingLayer() -> CALayer {
        displayLayer
    }

    /// Feeds one captured frame. Called on the stream's output queue —
    /// enqueue is documented thread-safe, so no main-queue hop is needed.
    func enqueue(_ sampleBuffer: CMSampleBuffer) {
        displayLayer.enqueue(sampleBuffer)
    }

    /// Drops every queued/presented frame — so a stopped stream leaves no
    /// stale image frozen on screen.
    func flush() {
        displayLayer.flush()
    }
}
