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
import StateManagementTestingSupport

@testable import StateManagement

// MARK: - State

final class AAState: StateContainer {
    var x = 0
}

// MARK: - Operations

struct AASetX: SyncOperation {
    let value: Int
    func perform(in env: SyncOperationEnvironment) {
        env.write(\AAState.x, value: value)
    }
}

/// Async op that mutates through a sync child, the only legal write path.
struct AAAsyncSet: AsyncOperation {
    var reentrancy: ReentrancyDecision { .runAll }
    let value: Int
    func perform(in env: AsyncOperationEnvironment) async {
        env.perform(AASetX(value: value))
    }
}

/// Async op that suspends first, then mutates through a sync child.
struct AAAsyncSuspendThenSet: AsyncOperation {
    var reentrancy: ReentrancyDecision { .runAll }
    let value: Int
    func perform(in env: AsyncOperationEnvironment) async {
        await Task.yield()
        env.perform(AASetX(value: value))
    }
}

/// Holds, then writes through a sync child. Its own Execution.
struct AAHoldThenSet: AsyncOperation {
    var reentrancy: ReentrancyDecision { .runAll }
    let gate: HoldGate
    let value: Int
    func perform(in env: AsyncOperationEnvironment) async {
        await gate.holdHere()
        env.perform(AASetX(value: value))
    }
}

/// Awaits a non-throwing child, then writes one more than the child's Value.
struct AAAwaitChildThenIncrement: AsyncOperation {
    var reentrancy: ReentrancyDecision { .runAll }
    let gate: HoldGate
    let childValue: Int
    func perform(in env: AsyncOperationEnvironment) async {
        await env.perform(AAHoldThenSet(gate: gate, value: childValue))
        let current = env.read(\AAState.x)
        env.perform(AASetX(value: current + 1))
    }
}

/// Starts a held child without waiting, then writes.
struct AAFireChildThenSet: AsyncOperation {
    var reentrancy: ReentrancyDecision { .runAll }
    let gate: HoldGate
    let childValue: Int
    let parentValue: Int
    func perform(in env: AsyncOperationEnvironment) async {
        func startChild() {
            env.perform(AAHoldThenSet(gate: gate, value: childValue))
        }
        startChild()
        env.perform(AASetX(value: parentValue))
    }
}

// MARK: - Tests

/// The awaited `perform(_: AsyncOperation) async` overload must finish all of
/// the operation's work, including nested sync children and their
/// notifications, before it returns. No `Task.sleep` needed to see the effect.
@Suite(.serialized) @MainActor
struct AsyncOperationAwaitTests {

    /// After awaiting, the sync child's write is already committed.
    @Test func awaitedOpCommitsSyncChildBeforeReturning() async {
        let env = SharedEnvironment()

        await env.perform(AAAsyncSet(value: 5))

        #expect(env.getValue(keyPath: \AAState.x) == 5)
    }

    /// After awaiting, the sync child's notification has already fired: a
    /// receiver subscribed before the operation was called synchronously.
    @Test func awaitedOpNotifiesObserverBeforeReturning() async {
        let env = SharedEnvironment()
        let x = ValueID(keyPath: \AAState.x)

        var callCount = 0
        var received: Set<ValueID> = []
        let receiver = NotificationReceiver { ids in
            callCount += 1
            received = ids
        }
        env.observation.subscribe(receiver: receiver, valueID: x)

        await env.perform(AAAsyncSet(value: 7))

        #expect(callCount == 1)
        #expect(received.contains(x))
    }

    /// A suspension inside the operation still commits before the await returns.
    @Test func awaitedOpSequencesAfterSuspension() async {
        let env = SharedEnvironment()

        await env.perform(AAAsyncSuspendThenSet(value: 9))

        #expect(env.getValue(keyPath: \AAState.x) == 9)
    }
}

@Suite(.serialized) @MainActor
struct NestedAsyncOperationAwaitTests {

    @Test("A parent AsyncOperation awaits a non-throwing child before it continues")
    func parentAwaitsNonThrowingChild() async {
        let env = SharedEnvironment()
        let gate = HoldGate()

        async let parent: Void = env.perform(AAAwaitChildThenIncrement(gate: gate, childValue: 5))
        await gate.waitForArrival()
        #expect(env.read(\AAState.x) == 0)

        gate.release()
        await parent

        #expect(env.read(\AAState.x) == 6)
    }

    @Test("reset() Cancels an awaited nested AsyncOperation so later writes do not land")
    func resetCancelsAwaitedNestedChild() async {
        let env = SharedEnvironment()
        let gate = HoldGate()

        async let parent: Void = env.perform(AAAwaitChildThenIncrement(gate: gate, childValue: 9))
        await gate.waitForArrival()
        #expect(env.read(\AAState.x) == 0)

        env.perform(ResetAll())
        gate.release()
        await parent

        #expect(env.read(\AAState.x) == 0)
    }

    @Test("A parent starts a non-throwing child without await and continues before the child writes")
    func parentFireAndForgetChildDoesNotWait() async throws {
        let env = SharedEnvironment()
        let gate = HoldGate()

        async let parent: Void = env.perform(
            AAFireChildThenSet(gate: gate, childValue: 5, parentValue: 1)
        )
        await gate.waitForArrival()
        await parent

        #expect(env.read(\AAState.x) == 1)

        gate.release()
        try await Task.sleep(for: .milliseconds(100))
        #expect(env.read(\AAState.x) == 5)
    }
}
