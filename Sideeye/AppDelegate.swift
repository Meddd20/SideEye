//
//  AppDelegate.swift
//  Sideeye
//
//  Created by Medhiko Biraja on 2026.
//  Copyright © 2026 Medhiko Biraja. Licensed under the MIT License.
//

import Cocoa

class AppDelegate: NSObject, NSApplicationDelegate {
    
    private var statusMenuController: StatusMenuController!
    private var captureEngine: CaptureEngine!
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        
        captureEngine = CaptureEngine()
        statusMenuController = StatusMenuController(captureEngine: captureEngine)
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Quit time is flush time — the debounced preference writes must not
        // die with the process.
        captureEngine?.flushPreferences()
    }
}
