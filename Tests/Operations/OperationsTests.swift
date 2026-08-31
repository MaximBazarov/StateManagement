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

final class OpTestState: StateContainer {
    var counter: Int = 0
    var items: [String: Int] = [:]
}

// MARK: - Operations

struct IncrementOp: SyncOperation {
    func perform(in env: SyncOperationEnvironment) {
        let c = env.read(\OpTestState.counter)
        env.write(\OpTestState.counter, value: c + 1)
    }
}

struct SetItemOp: SyncOperation {
    let key: String
    let value: Int
    func perform(in env: SyncOperationEnvironment) {
        env.write(\OpTestState.items, key: key, value: value)
    }
}

struct AsyncIncrementOp: AsyncOperation {
    var reentrancy: ReentrancyDecision { .runAll }
    func perform(in env: AsyncOperationEnvironment) async {
        env.perform(IncrementOp())
    }
}

/// Reads atomic and keyed state, then performs a sync child and a fire-and-forget async child.
struct CompositeAsyncOp: AsyncOperation {
    var reentrancy: ReentrancyDecision { .runAll }
    func perform(in env: AsyncOperationEnvironment) async {
        // Exercise both read overloads to prove they compile and return current state.
        let _ = env.read(\OpTestState.counter)
        let _ = env.read(\OpTestState.items, key: "x")

        // Sync child: immediate mutation.
        env.perform(SetItemOp(key: "x", value: 42))

        // Async child: fire-and-forget inside AsyncOperationEnvironment.
        startWithoutWaiting(AsyncIncrementOp(), on: env)
    }
}

/// A sync op that kicks off an async op (fire-and-forget).
struct SyncKicksAsyncOp: SyncOperation {
    func perform(in env: SyncOperationEnvironment) {
        env.perform(AsyncIncrementOp())
    }
}

/// Marks that an async op resolved a service via ``AsyncOperationEnvironment/getService``.
final class AsyncOpServiceProbe: EnvironmentService {
    var touched = false
}

struct TouchServiceViaGetService: AsyncOperation {
    var reentrancy: ReentrancyDecision { .runAll }
    func perform(in env: AsyncOperationEnvironment) async {
        let service = await env.getService(AsyncOpServiceProbe.self)
        service.touched = true
    }
}

// MARK: - Tests

@Suite(.serialized) @MainActor struct OperationsTests {

    // MARK: - 1. Async op reads state and performs children

    /// An async operation can read atomic/keyed state and perform both sync
    /// and async children. The sync child mutates immediately; the async
    /// child fires and lands shortly after.
    @Test func asyncOpReadsStateAndPerformsChildren() async throws {
        let env = SharedEnvironment()
        let reader = await env.spawnService(StateReader.self)

        // Seed keyed state so the read inside CompositeAsyncOp has something.
        env.perform(SetItemOp(key: "x", value: 0))

        await env.perform(CompositeAsyncOp())

        // Sync child (SetItemOp) should have landed immediately.
        let item = reader.read(\OpTestState.items, key: "x")
        #expect(item == 42)

        // Async child (AsyncIncrementOp) is fire-and-forget; give it time.
        try await Task.sleep(for: .milliseconds(100))

        let counter = reader.read(\OpTestState.counter)
        #expect(counter == 1)
    }

    // MARK: - 2. Sync op performs an async op (fire-and-forget)

    /// `SyncOperationEnvironment.perform(_: AsyncOperation)` dispatches
    /// the async op via a detached Task. The effect lands asynchronously.
    @Test func syncOpPerformsAsyncOp() async throws {
        let env = SharedEnvironment()
        let reader = await env.spawnService(StateReader.self)

        env.perform(SyncKicksAsyncOp())

        // The async child hasn't necessarily run yet.
        try await Task.sleep(for: .milliseconds(100))

        let counter = reader.read(\OpTestState.counter)
        #expect(counter == 1)
    }

    // MARK: - 3. SharedEnvironment fire-and-forget perform

    /// The non-async `SharedEnvironment.perform(_: AsyncOperation)` overload
    /// wraps execution in a `Task`. The effect lands asynchronously.
    @Test func fireAndForgetPerformAsync() async throws {
        let env = SharedEnvironment()
        let reader = await env.spawnService(StateReader.self)

        // Force the non-async overload by calling from a sync helper.
        performFireAndForget(env: env, operation: AsyncIncrementOp())

        try await Task.sleep(for: .milliseconds(100))

        let counter = reader.read(\OpTestState.counter)
        #expect(counter == 1)
    }

    /// Calls `SharedEnvironment.perform(_: AsyncOperation)` in a synchronous
    /// context so Swift resolves to the non-async (fire-and-forget) overload.
    private func performFireAndForget(env: SharedEnvironment, operation: AsyncOperation) {
        env.perform(operation)
    }

    // MARK: - 4. Async op getService

    @Test("Async op getService returns the same spawned EnvironmentService")
    func asyncOpGetServiceReturnsCachedInstance() async throws {
        let env = SharedEnvironment()
        let spawned = await env.spawnService(AsyncOpServiceProbe.self)

        await env.perform(TouchServiceViaGetService())

        let again = await env.getService(AsyncOpServiceProbe.self)
        #expect(again === spawned)
        #expect(spawned.touched)
    }
}

/// Sync hop so `perform` resolves to fire-and-forget inside an async Operation body.
@MainActor
func startWithoutWaiting<Op: AsyncOperation>(
    _ operation: Op,
    on env: AsyncOperationEnvironment,
    file: String = #fileID,
    line: UInt = #line
) {
    env.perform(operation, file: file, line: line)
}
