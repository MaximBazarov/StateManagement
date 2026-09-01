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

import Foundation
import Testing
#if canImport(SwiftUI)
import SwiftUI
#endif
@testable import StateManagement

#if canImport(AppKit) || canImport(UIKit)

/// Holds each `Watch.refresh` so the test can call it after the first body, the same
/// path a button in a real view uses.
@MainActor
final class RefreshHooks {
    var renders = 0
    var sourced: (() -> Void)?
    var keyed: (() -> Void)?
    var plain: (() -> Void)?
}

@MainActor
struct WatchRefreshView: View {
    let hooks: RefreshHooks
    @Watch(\AsyncBox.theme) var theme: String
    @Watch(\AsyncBox.done, key: "a") var done: Bool?
    @Watch(\PlainBox.count) var count: Int

    var body: some View {
        let _ = hooks.renders += 1
        let _ = hooks.sourced = { $theme.refresh() }
        let _ = hooks.keyed = { $done.refresh() }
        let _ = hooks.plain = { $count.refresh() }
        Text("\(theme) \(count) \(done == true)")
    }
}

#endif

/// `Watch.$property.refresh()` is the second call site of the refresh Operation: the same
/// dirty-plus-kick as ``AsyncState/refresh()``, addressed by what the body reads and resolved
/// against the SwiftUI `sharedEnvironment`.
@Suite(.serialized) @MainActor
struct WatchRefreshTests {

    #if canImport(AppKit) || canImport(UIKit)

    @Test("Watch $refresh() calls onRead again for the Address the body reads")
    func watchRefreshKicksOnRead() async throws {
        let env = SharedEnvironment()
        let strategy = env.strategyUnderTest(MockStrategy.self)
        let hooks = RefreshHooks()

        let host = HostedView.mount(WatchRefreshView(hooks: hooks).sharedEnvironment(env))
        defer { host.teardown() }

        #expect(await waitUntil { hooks.sourced != nil })
        let atomicReads = strategy.onReadCount
        #expect(atomicReads == 1)

        hooks.sourced?()

        #expect(strategy.onReadCount == atomicReads + 1)
        #expect(env.read(\AsyncBox.$theme.status) == AsyncStateStatus<MockFailure>.pending)
    }

    @Test("A keyed Watch $refresh() refreshes its own key")
    func keyedWatchRefreshUsesItsKey() async throws {
        let env = SharedEnvironment()
        let strategy = env.strategyUnderTest(MockStrategy.self)
        let hooks = RefreshHooks()

        let host = HostedView.mount(WatchRefreshView(hooks: hooks).sharedEnvironment(env))
        defer { host.teardown() }

        #expect(await waitUntil { hooks.keyed != nil })
        let keyedReads = strategy.keyedOnReadCount
        #expect(keyedReads == 1)

        hooks.keyed?()

        #expect(strategy.keyedOnReadCount == keyedReads + 1)
    }

    @Test("Watch $refresh() of a non-sourced Address is a no-op")
    func nonSourcedWatchRefreshIsANoOp() async throws {
        let env = SharedEnvironment()
        let strategy = env.strategyUnderTest(MockStrategy.self)
        let hooks = RefreshHooks()

        let host = HostedView.mount(WatchRefreshView(hooks: hooks).sharedEnvironment(env))
        defer { host.teardown() }

        #expect(await waitUntil { hooks.plain != nil })
        let atomicReads = strategy.onReadCount
        let keyedReads = strategy.keyedOnReadCount

        hooks.plain?()

        #expect(strategy.onReadCount == atomicReads)
        #expect(strategy.keyedOnReadCount == keyedReads)
    }

    #endif
}
