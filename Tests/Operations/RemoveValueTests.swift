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

@testable import StateManagement

/// State under test for the keyed `remove` primitive.
final class RemoveTestState: StateContainer {
    var items: [String: Int] = ["A": 1, "B": 2, "C": 3]

    /// Reads only keys "A" and "B" — so it must recompute when either is removed,
    /// and must NOT recompute when an unread key (e.g. "C") is removed.
    @Computed var sumOfAB = { (env: ComputationEnvironment) -> Int in
        let a = env.read(\RemoveTestState.items, key: "A") ?? 0
        let b = env.read(\RemoveTestState.items, key: "B") ?? 0
        return a + b
    }
}

struct RemoveItem: SyncOperation {
    let key: String
    func perform(in env: SyncOperationEnvironment) {
        env.remove(\RemoveTestState.items, key: key)
    }
}

/// Reads the `sumOfAB` computation on `serve` and reports completion through a ``Waiter``,
/// mirroring `TracingService` in `Computed.swift`.
final class SumTracingService: EnvironmentService {
    var waiter: Waiter?
    var confirmation: Confirmation?
    var lastValue: Int = -1

    override func serve() async {
        lastValue = self.read(\RemoveTestState.$sumOfAB)
        confirmation?.confirm()
        await waiter?.resume()
    }

    func awaitNextServe() async throws {
        try await waiter?.wait()
    }
}

@Suite
@MainActor
struct RemoveValueTests {

    // MARK: - State-level behaviour

    @Test func removeDeletesKeyAndLeavesOthers() {
        let env = SharedEnvironment()

        #expect(env.getValue(keyPath: \RemoveTestState.items, key: "A") == 1)

        env.perform(RemoveItem(key: "A"))

        #expect(env.getValue(keyPath: \RemoveTestState.items, key: "A") == nil)
        #expect(env.getValue(keyPath: \RemoveTestState.items, key: "B") == 2)
        #expect(env.getValue(keyPath: \RemoveTestState.items, key: "C") == 3)
    }

    @Test func removeMissingKeyIsSafeAndDoesNotTouchOthers() {
        let env = SharedEnvironment()

        env.perform(RemoveItem(key: "Z")) // never present

        #expect(env.getValue(keyPath: \RemoveTestState.items, key: "Z") == nil)
        #expect(env.getValue(keyPath: \RemoveTestState.items, key: "A") == 1)
        #expect(env.getValue(keyPath: \RemoveTestState.items, key: "B") == 2)
        #expect(env.getValue(keyPath: \RemoveTestState.items, key: "C") == 3)
    }

    // MARK: - Observation: removing a key notifies its dependents

    /// Removing a key the computation reads must invalidate that key and re-serve the consumer.
    /// (A whole-dictionary base-path rewrite would NOT reach this keyed dependency.)
    @Test func removingReadKeyTriggersRecompute() async throws {
        let env = SharedEnvironment()
        let waiter = Waiter(expectedCount: 1)
        let service = await env.spawnService(SumTracingService.self)
        service.waiter = waiter

        #expect(service.lastValue == 3) // 1 + 2

        await confirmation("Service re-served after removing a read key", expectedCount: 1) { confirmation in
            service.confirmation = confirmation

            env.perform(RemoveItem(key: "A"))

            do {
                try await service.awaitNextServe()
            }
            catch {
                Issue.record(error)
            }
        }

        #expect(service.lastValue == 2) // (nil -> 0) + 2
    }

    /// Removing a key the computation never read must NOT re-serve the consumer.
    @Test func removingUnreadKeyDoesNotRecompute() async throws {
        let env = SharedEnvironment()
        let waiter = Waiter(expectedCount: 1)
        let service = await env.spawnService(SumTracingService.self)
        service.waiter = waiter

        #expect(service.lastValue == 3)

        await confirmation("Service must NOT re-serve for an unread key", expectedCount: 0) { confirmation in
            service.confirmation = confirmation

            env.perform(RemoveItem(key: "C"))

            do {
                try await service.awaitNextServe()
                Issue.record("Service should not have re-served for an unread key")
            }
            catch {
                _ = error // expected timeout — no notification arrived
            }
        }

        #expect(service.lastValue == 3) // unchanged
    }
}
