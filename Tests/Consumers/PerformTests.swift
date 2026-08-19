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
import SwiftUI
import Testing
import StateManagementTestingSupport
@testable import StateManagement

// MARK: - State

final class PerformState: StateContainer {
    var count: Int = 0
    var loaded: Bool = false
}

// MARK: - Operations

/// Synchronous mutation: reads the current count and writes it back incremented.
struct IncrementCount: SyncOperation {
    func perform(in env: SyncOperationEnvironment) {
        let current = env.read(keyPath: \PerformState.count)
        env.write(current + 1, keyPath: \PerformState.count)
    }
}

/// Sync child used by the async operation to land its effect.
struct MarkLoaded: SyncOperation {
    func perform(in env: SyncOperationEnvironment) {
        env.write(true, keyPath: \PerformState.loaded)
    }
}

/// Asynchronous operation that flips `loaded` after suspending, so a test can
/// distinguish "awaited to completion" from "fired and not yet landed".
struct LoadInitialState: AsyncOperation {
    var reentrancy: ReentrancyDecision { .runAll }
    func perform(in env: AsyncOperationEnvironment) async {
        await Task.yield()
        env.perform(MarkLoaded())
    }
}

// MARK: - SwiftUI host fixtures

// `Perform` resolves its target through `@Environment(\.sharedEnvironment)`,
// which only binds inside a real SwiftUI host. These fixtures mount a view that
// dispatches through the public `@Perform` handle, exactly as an app would.
#if canImport(AppKit) || canImport(UIKit)

/// A `MainActor` flag a host view flips so a test can observe view-side effects
/// (e.g. a `.task` running to completion) without touching global state.
@MainActor
final class PerformFlag {
    var isSet = false
}

/// Dispatches a synchronous operation from `onAppear`.
@MainActor
struct PerformSyncView: View {
    @Perform var perform
    var body: some View {
        Color.clear.onAppear {
            perform(IncrementCount())
        }
    }
}

/// Fires an async operation fire-and-forget (sync context) from `onAppear`.
@MainActor
struct PerformAsyncFireAndForgetView: View {
    @Perform var perform
    var body: some View {
        Color.clear.onAppear {
            perform(LoadInitialState())
        }
    }
}

/// Awaits an async operation from a `.task` modifier.
@MainActor
struct PerformAsyncAwaitView: View {
    let onFinished: @MainActor () -> Void
    @Perform var perform
    var body: some View {
        Color.clear.task {
            await perform(LoadInitialState())
            onFinished()
        }
    }
}

#endif

// MARK: - Tests

/// ``Perform`` is the write-only dispatch handle a view uses to run operations
/// against the ``SharedEnvironment`` resolved from the SwiftUI environment.
/// These tests drive the public call-site contract through a real host:
/// synchronous dispatch, fire-and-forget async dispatch, awaited async
/// dispatch, and the environment escape hatch.
@Suite(.serialized) @MainActor
struct PerformTests {

    #if canImport(AppKit) || canImport(UIKit)

    @Test("Sync operation dispatches into the resolved environment")
    func syncOperationDispatches() async throws {
        let env = SharedEnvironment()
        let reader = await env.spawnService(StateReader.self)

        let host = HostedView.mount(PerformSyncView().sharedEnvironment(env))
        defer { host.teardown() }

        let landed = await waitUntil { reader.read(\PerformState.count) == 1 }
        #expect(landed, "sync operation did not mutate the resolved environment")
    }

    @Test("Async operation fire-and-forget lands eventually")
    func asyncOperationFireAndForgetDispatches() async throws {
        let env = SharedEnvironment()
        let reader = await env.spawnService(StateReader.self)

        let host = HostedView.mount(PerformAsyncFireAndForgetView().sharedEnvironment(env))
        defer { host.teardown() }

        let landed = await waitUntil { reader.read(\PerformState.loaded) }
        #expect(landed, "fire-and-forget async operation never landed")
    }

    @Test("Awaiting async overload suspends until the effect is visible")
    func asyncOperationAwaitsCompletion() async throws {
        let env = SharedEnvironment()
        let reader = await env.spawnService(StateReader.self)

        let finished = PerformFlag()
        let host = HostedView.mount(
            PerformAsyncAwaitView(onFinished: { finished.isSet = true }).sharedEnvironment(env)
        )
        defer { host.teardown() }

        let done = await waitUntil { finished.isSet }
        #expect(done, "awaiting overload never completed")
        // Once the await returned, the effect must already be visible.
        #expect(reader.read(\PerformState.loaded))
    }

#endif
}
