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
        let current = env.read(\PerformState.count)
        env.write(\PerformState.count, value: current + 1)
    }
}

/// Sync child used by the async operation to land its effect.
struct MarkLoaded: SyncOperation {
    func perform(in env: SyncOperationEnvironment) {
        env.write(\PerformState.loaded, value: true)
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

/// Parks on `gate` so a test can observe `isInProgress` while the Execution is live.
struct HoldThenMarkLoaded: AsyncOperation {
    var reentrancy: ReentrancyDecision { .runAll }
    let gate: HoldGate
    func perform(in env: AsyncOperationEnvironment) async {
        await gate.holdHere()
        env.perform(MarkLoaded())
    }
}

struct HoldFirstWins: AsyncOperation {
    var reentrancy: ReentrancyDecision { .firstWins(.wholeOperation) }
    let gate: HoldGate
    func perform(in env: AsyncOperationEnvironment) async {
        await gate.holdHere()
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

/// Dispatch-only: fire-and-forget with no `isInProgress` read. Body count
/// proves `begin()` / `end()` do not invalidate a view that never asked.
@MainActor
struct PerformDispatchOnlyView: View {
    let counter: RenderCounter
    let operation: HoldThenMarkLoaded
    @Perform var perform
    var body: some View {
        let _ = counter.count += 1
        Color.clear.onAppear {
            perform(operation)
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

/// Copies `perform.isInProgress` onto `probe` so a test can read the public flag
/// without reaching into the wrapper.
@MainActor
final class InProgressProbe {
    var isInProgress = false
}

@MainActor
struct PerformInProgressView<Op: AsyncOperation>: View {
    let operation: Op
    var duplicate: Bool = false
    let probe: InProgressProbe
    @Perform var perform
    var body: some View {
        Color.clear
            .onAppear {
                perform(operation)
                if duplicate {
                    perform(operation)
                }
                probe.isInProgress = perform.isInProgress
            }
            .background {
                let _ = Self.report(probe, perform.isInProgress)
                Color.clear
            }
    }

    private static func report(_ probe: InProgressProbe, _ flag: Bool) {
        probe.isInProgress = flag
    }
}

@MainActor
struct PerformAwaitInProgressView: View {
    let gate: HoldGate
    let probe: InProgressProbe
    @Perform var perform
    var body: some View {
        Color.clear
            .task {
                // Type context picks the async overload; `await perform(op)` can bind the fire-and-forget one.
                let run: @MainActor (HoldThenMarkLoaded, String, UInt) async -> Void = perform.callAsFunction
                await run(HoldThenMarkLoaded(gate: gate), #fileID, #line)
            }
            .background {
                let _ = Self.report(probe, perform.isInProgress)
                Color.clear
            }
    }

    private static func report(_ probe: InProgressProbe, _ flag: Bool) {
        probe.isInProgress = flag
    }
}

@MainActor
struct PerformSyncInProgressView: View {
    let probe: InProgressProbe
    @Perform var perform
    var body: some View {
        Color.clear.onAppear {
            perform(IncrementCount())
            probe.isInProgress = perform.isInProgress
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

    @Test("Dispatch-only Perform does not re-evaluate body on begin or end")
    func dispatchOnlyDoesNotRerenderOnBeginOrEnd() async throws {
        let env = SharedEnvironment()
        let reader = await env.spawnService(StateReader.self)
        let gate = HoldGate()
        let counter = RenderCounter()

        let host = HostedView.mount(
            PerformDispatchOnlyView(
                counter: counter,
                operation: HoldThenMarkLoaded(gate: gate)
            ).sharedEnvironment(env)
        )
        defer { host.teardown() }

        #expect(counter.count >= 1)
        let initial = counter.count

        await gate.waitForArrival()
        host.relayout()
        gate.release()
        host.relayout()

        let landed = await waitUntil { reader.read(\PerformState.loaded) }
        #expect(landed, "gated fire-and-forget never landed")
        #expect(counter.count == initial, "dispatch-only body re-evaluated on begin or end")
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

    @Test("isInProgress is true while the Execution this wrapper started is in flight")
    func isInProgressWhileOwnedExecutionIsInFlight() async throws {
        let env = SharedEnvironment()
        let gate = HoldGate()
        let probe = InProgressProbe()

        let host = HostedView.mount(
            PerformInProgressView(
                operation: HoldThenMarkLoaded(gate: gate),
                probe: probe
            ).sharedEnvironment(env)
        )
        defer { host.teardown() }

        await gate.waitForArrival()
        #expect(probe.isInProgress)

        gate.release()
        let cleared = await waitUntil { !probe.isInProgress }
        #expect(cleared, "isInProgress stayed true after the Execution exited")
    }

    @Test("A fire-and-forget firstWins duplicate does not set isInProgress")
    func firstWinsDuplicateDoesNotSetInProgress() async throws {
        let env = SharedEnvironment()
        let gate = HoldGate()
        let probe = InProgressProbe()

        let host = HostedView.mount(
            PerformInProgressView(
                operation: HoldFirstWins(gate: gate),
                duplicate: true,
                probe: probe
            ).sharedEnvironment(env)
        )
        defer { host.teardown() }

        await gate.waitForArrival()
        #expect(gate.arrivals == 1)
        #expect(probe.isInProgress)

        gate.release()
        let cleared = await waitUntil { !probe.isInProgress }
        #expect(cleared, "duplicate firstWins left isInProgress stuck true")
    }

    @Test("Sync perform does not set isInProgress")
    func syncPerformDoesNotSetInProgress() async throws {
        let env = SharedEnvironment()
        let probe = InProgressProbe()
        let host = HostedView.mount(
            PerformSyncInProgressView(probe: probe).sharedEnvironment(env)
        )
        defer { host.teardown() }

        let reader = await env.spawnService(StateReader.self)
        let landed = await waitUntil { reader.read(\PerformState.count) == 1 }
        #expect(landed)
        #expect(!probe.isInProgress)
    }

    @Test("isInProgress is true while this wrapper awaits a Join or its own Execution")
    func isInProgressWhileAwaiting() async throws {
        let env = SharedEnvironment()
        let gate = HoldGate()
        let probe = InProgressProbe()

        let host = HostedView.mount(
            PerformAwaitInProgressView(gate: gate, probe: probe).sharedEnvironment(env)
        )
        defer { host.teardown() }

        await gate.waitForArrival()
        let seen = await waitUntil { probe.isInProgress }
        #expect(seen, "awaited perform did not set isInProgress")

        gate.release()
        let cleared = await waitUntil { !probe.isInProgress }
        #expect(cleared, "isInProgress stayed true after the await returned")
    }

    @Test("isInProgress stays true after Cancel until the body exits")
    func isInProgressStaysTrueAfterCancelUntilBodyExits() async throws {
        let env = SharedEnvironment()
        let gate = HoldGate()
        let probe = InProgressProbe()

        let host = HostedView.mount(
            PerformInProgressView(
                operation: HoldThenMarkLoaded(gate: gate),
                probe: probe
            ).sharedEnvironment(env)
        )
        defer { host.teardown() }

        await gate.waitForArrival()
        #expect(probe.isInProgress)

        env.perform(ResetAll())
        #expect(probe.isInProgress)

        gate.release()
        let cleared = await waitUntil { !probe.isInProgress }
        #expect(cleared, "isInProgress stayed true after the cancelled body exited")
    }

#endif
}
