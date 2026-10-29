//
//  WindowListManager.swift
//  Sideeye
//
//  Created by Medhiko Biraja on 2026.
//  Copyright © 2026 Medhiko Biraja. Licensed under the MIT License.
//

import Foundation
import ScreenCaptureKit

protocol WindowListManagerDelegate: AnyObject {
    func windowListUpdated(
        current: [SCWindow],
        fullscreenElsewhere: [SCWindow],
        otherWindows: [SCWindow],
    )
}

class WindowListManager {
    
    weak var delegate: WindowListManagerDelegate?
    
    private var isRefreshing = false
    private var lastContent: SCShareableContent?
    private var lastVisibleIDs: Set<CGWindowID> = []
    
    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        
        Task {
            do {
                let all = try await SCShareableContent.excludingDesktopWindows(
                    false,
                    onScreenWindowsOnly: false
                )
                
                let visible = try await SCShareableContent.excludingDesktopWindows(
                    false,
                    onScreenWindowsOnly: true
                )
                
                await MainActor.run {
                    self.isRefreshing = false
                    self.lastContent = all
                    self.lastVisibleIDs = Set(visible.windows.map(\.windowID))
                    
                    let partitioned = self.partitionWindows(
                        all: all.windows,
                        visibleIDs: self.lastVisibleIDs
                    )
                    
                    self.delegate?.windowListUpdated(
                        current: partitioned.current,
                        fullscreenElsewhere: partitioned.fullscreenElsewhere,
                        otherWindows: partitioned.otherWindows,
                    )
                }
            } catch {
                await MainActor.run {
                    self.isRefreshing = false
                }
            }
        }
    }
    
    private func partitionWindows(
        all: [SCWindow],
        visibleIDs: Set<CGWindowID>
    ) -> (current: [SCWindow], fullscreenElsewhere: [SCWindow], otherWindows: [SCWindow]) {
        
        let candidates = all.filter { $0.isMirrorable }
        
        let current = candidates.filter { visibleIDs.contains($0.windowID) }
        let elsewhere = candidates.filter { !visibleIDs.contains($0.windowID) }
        
        let fullscreenElsewhere = elsewhere.filter { $0.isTrueFullscreen }
        // Ordinary windows on OTHER Spaces, filtered to likely-real windows
        // so offscreen helper surfaces don't clutter the menu.
        let otherWindows = elsewhere
            .filter { !$0.isTrueFullscreen && $0.isLikelyRealWindow }
        
        return (current, fullscreenElsewhere, otherWindows)
    }
}
