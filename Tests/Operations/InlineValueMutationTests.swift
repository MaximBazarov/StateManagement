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

// MARK: - State

final class IVMState: StateContainer {
    var x = 0
}

// MARK: - Operations

/// Writes `\IVMState.x` twice in one operation to prove notifications batch.
struct DoubleWrite: SyncOperation {
    func perform(in env: SyncOperationEnvironment) {
        env.write(\IVMState.x, value: 1)
        env.write(\IVMState.x, value: 2)
    }
}

// MARK: - Tests

@Suite @MainActor
struct InlineValueMutationTests {

    /// The closure receives the value and a working environment, and its writes
    /// land. This is the path SwiftUI bindings use.
    @Test func mutationAppliesValue() {
        let env = SharedEnvironment()

        let op = InlineValueMutation(value: 42) { amount, env in
            let current = env.read(\IVMState.x)
            env.write(\IVMState.x, value: current + amount)
        }
        env.perform(op)

        #expect(env.getValue(keyPath: \IVMState.x) == 42)
    }

    /// Reads inside the mutation see current state, so it can read-modify-write.
    @Test func mutationCanReadThenWrite() {
        let env = SharedEnvironment()
        env.perform(IsoInlineSeed(value: 10))

        let op = InlineValueMutation(value: 5) { amount, env in
            let current = env.read(\IVMState.x)
            env.write(\IVMState.x, value: current + amount)
        }
        env.perform(op)

        #expect(env.getValue(keyPath: \IVMState.x) == 15)
    }

    /// Two writes to the same value in one operation notify the subscriber once.
    /// This is the "notify once per operation" invariant.
    @Test func multipleWritesBatchIntoSingleNotification() {
        let env = SharedEnvironment()
        let x = ValueID(keyPath: \IVMState.x)

        var callCount = 0
        let receiver = NotificationReceiver { _ in callCount += 1 }
        env.observation.subscribe(receiver: receiver, valueID: x)

        env.perform(DoubleWrite())

        #expect(callCount == 1)
        #expect(env.getValue(keyPath: \IVMState.x) == 2)
    }
}

/// Seeds `\IVMState.x` so a later read-modify-write has a base value.
struct IsoInlineSeed: SyncOperation {
    let value: Int
    func perform(in env: SyncOperationEnvironment) {
        env.write(\IVMState.x, value: value)
    }
}
