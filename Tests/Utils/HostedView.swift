//===----------------------------------------------------------------------===//
//
// This source file is part of the StateManagement package open source project
//
// Copyright (c) 2025-2035 Maxim Bazarov and the StateManagement package
// open source project authors
// Licensed under MIT
//
// See LICENSE.txt for license information
//
// SPDX-License-Identifier: MIT
//
//===----------------------------------------------------------------------===//

// Portable headless SwiftUI host for the one integration test. AppKit on macOS,
// UIKit on iOS/tvOS; absent elsewhere (Linux) so the integration test compiles
// out and the headless `ValueObserverProbe` tests still run.
#if canImport(AppKit) || canImport(UIKit)
import SwiftUI

@MainActor
enum HostedView {

    /// A mounted view: `relayout` forces another synchronous layout pass, `teardown`
    /// keeps the host alive until the test is done (release it to drop the view).
    struct Handle {
        let relayout: () -> Void
        let teardown: () -> Void
    }

    /// Mounts `view` in a real platform host and forces a synchronous initial
    /// layout pass — triggering SwiftUI dynamic-property reflection, environment
    /// injection, and the first body evaluation, exactly as a real app would.
    static func mount<V: View>(_ view: V) -> Handle {
        #if canImport(AppKit)
        let host = NSHostingController(rootView: view)
        host.view.frame = CGRect(x: 0, y: 0, width: 100, height: 100)
        host.view.layoutSubtreeIfNeeded()
        return Handle(
            relayout: { host.view.layoutSubtreeIfNeeded() },
            teardown: { _ = host }
        )
        #elseif canImport(UIKit)
        let host = UIHostingController(rootView: view)
        // Unlike AppKit, UIKit only schedules SwiftUI updates for a view in a
        // visible window — a detached `layoutIfNeeded()` never re-renders. Mount
        // in a key window so `objectWillChange` actually drives `body` again.
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        return Handle(
            relayout: {
                host.view.setNeedsLayout()
                host.view.layoutIfNeeded()
            },
            teardown: {
                window.isHidden = true
                _ = host
                _ = window
            }
        )
        #endif
    }
}

/// Polls `condition` until true or `timeout`, yielding to the runloop between
/// checks so SwiftUI can progress. Returns as soon as the condition holds (fast
/// in practice) and fails loud at the deadline — no fixed sleep, no flake.
@MainActor
func waitUntil(
    timeout: Duration = .seconds(2),
    _ condition: () -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}
#endif
