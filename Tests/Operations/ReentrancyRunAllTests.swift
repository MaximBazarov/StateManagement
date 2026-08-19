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
import StateManagement

final class RunAllState: StateContainer {
    var total: Int = 0
}

struct AddToTotal: SyncOperation {
    let amount: Int
    func perform(in env: SyncOperationEnvironment) {
        let current = env.read(keyPath: \RunAllState.total)
        env.write(current + amount, keyPath: \RunAllState.total)
    }
}

@MainActor
final class OverlapGate {
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func waitUntilGroup(_ size: Int) async {
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
            if waiters.count == size {
                let pending = waiters
                waiters = []
                for waiter in pending {
                    waiter.resume()
                }
            }
        }
    }
}

struct WaitThenAdd: AsyncOperation {
    var reentrancy: ReentrancyDecision { .runAll }
    let gate: OverlapGate
    let amount: Int

    func perform(in env: AsyncOperationEnvironment) async {
        await gate.waitUntilGroup(2)
        env.perform(AddToTotal(amount: amount))
    }
}

@Suite(.serialized) @MainActor
struct ReentrancyRunAllTests {

    @Test("Two overlapping runAll operations both complete and both writes land")
    func overlappingRunAllBothLand() async {
        let env = SharedEnvironment()
        let gate = OverlapGate()

        async let first: Void = env.perform(WaitThenAdd(gate: gate, amount: 1))
        async let second: Void = env.perform(WaitThenAdd(gate: gate, amount: 10))
        await first
        await second

        #expect(env.read(\RunAllState.total) == 11)
    }
}
