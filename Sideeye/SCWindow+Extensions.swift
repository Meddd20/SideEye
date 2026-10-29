//
//  SCWindow+Extensions.swift
//  Sideeye
//
//  Created by Medhiko Biraja on 2026.
//  Copyright © 2026 Medhiko Biraja. Licensed under the MIT License.
//

import ScreenCaptureKit
import Cocoa

extension SCWindow {
    
    var displayName: String {
        let appName = owningApplication?.applicationName ?? "Unknown App"
        guard let title = title, !title.isEmpty else { return appName }
        return "\(appName) — \(title)"
    }
    
    var isMirrorable: Bool {
        guard windowLayer == 0,
              let app = owningApplication,
              app.bundleIdentifier != "com.apple.dock",
              !isOwnWindow else {
            return false
        }
        
        if let running = NSRunningApplication(processIdentifier: app.processID) {
            return running.activationPolicy == .regular
        }
        return true
    }
    
    private var isOwnWindow: Bool {
        guard let app = owningApplication else { return false }
        
        let appBundle = app.bundleIdentifier
        let mainBundle = Bundle.main.bundleIdentifier
        
        if appBundle == mainBundle {
            return true
        }
        
        if let mainName = Bundle.main.infoDictionary?["CFBundleName"] as? String {
            let appName = app.applicationName
            if appName == mainName {
                return true
            }
        }
        
        return false
    }
    
    /// TRUE macOS fullscreen only: a fullscreen Space's window frame equals
    /// the display bounds exactly. No gradient-gap tolerances — loose ones
    /// also match merely maximized (zoomed) windows, which misgroups
    /// ordinary windows under "Full-Screen Workspaces".
    var isTrueFullscreen: Bool {
        guard frame.width >= 100, frame.height >= 100 else { return false }
        
        // Anchor to the one screen the window lives on; comparing all
        // screens misreads mixed-display setups.
        let center = NSPoint(x: frame.midX, y: frame.midY)
        guard let homeScreen = NSScreen.screens.first(where: { $0.frame.contains(center) }) else {
            return false
        }
        
        let screenFrame = homeScreen.frame
        return abs(frame.width - screenFrame.width) < 5
            && abs(frame.height - screenFrame.height) < 5
    }
    
    /// Heuristic for "a real window a human would recognize", applied only
    /// to the Other Workspaces group, where every app's offscreen helper and
    /// backing surfaces ride along. A non-empty title is the strongest
    /// signal — offscreen internals come through blank or app-name-only —
    /// plus a sensible minimum footprint. Deliberately NOT applied to the
    /// visible and true-fullscreen groups: those are real by construction.
    var isLikelyRealWindow: Bool {
        guard let title = title,
              !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        guard frame.width >= 120, frame.height >= 80 else {
            return false
        }
        return true
    }
}

extension String {
    
    func truncated(to limit: Int) -> String {
        guard count > limit else { return self }
        return String(prefix(limit - 1)) + "…"
    }
}
