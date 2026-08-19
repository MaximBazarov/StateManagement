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

enum ThrowAsyncError: Error, Equatable {
    case boom
}

final class ThrowAsyncState: StateContainer {
    var count = 0
}

struct ThrowAsyncWrite: SyncOperation {
    func perform(in env: SyncOperationEnvironment) {
        env.write(1, keyPath: \ThrowAsyncState.count)
    }
}

struct ThrowAsyncWriteThenThrow: ThrowingSyncOperation {
    func perform(in env: SyncOperationEnvironment) throws(ThrowAsyncError) {
        env.write(1, keyPath: \ThrowAsyncState.count)
        throw .boom
    }
}

struct ThrowThenStop: ThrowingAsyncOperation {
    var reentrancy: ReentrancyDecision { .runAll }
    func perform(in env: AsyncOperationEnvironment) async throws(ThrowAsyncError) {
        throw .boom
    }
}

struct WriteThenThrowAsync: ThrowingAsyncOperation {
    var reentrancy: ReentrancyDecision { .runAll }
    func perform(in env: AsyncOperationEnvironment) async throws(ThrowAsyncError) {
        env.perform(ThrowAsyncWrite())
        throw .boom
    }
}

struct ThrowSyncChildAsync: ThrowingAsyncOperation {
    var reentrancy: ReentrancyDecision { .runAll }
    func perform(in env: AsyncOperationEnvironment) async throws(ThrowAsyncError) {
        try env.perform(ThrowAsyncWriteThenThrow())
    }
}

@Suite @MainActor
struct ThrowingAsyncOperationTests {

    @Test("An awaited async throw surfaces to the caller")
    func awaitedThrowSurfaces() async {
        let env = SharedEnvironment()

        await #expect(throws: ThrowAsyncError.boom) {
            try await env.perform(ThrowThenStop())
        }
    }

    @Test("A throwing Async operation keeps successful Sync children")
    func keepsSuccessfulSyncChildren() async {
        let env = SharedEnvironment()

        await #expect(throws: ThrowAsyncError.boom) {
            try await env.perform(WriteThenThrowAsync())
        }
        #expect(env.read(\ThrowAsyncState.count) == 1)
    }

    @Test("A throwing Sync child of Async keeps its writes and surfaces")
    func throwingSyncChildSurfaces() async {
        let env = SharedEnvironment()
        let probe = ValueObserverProbe.watch(\ThrowAsyncState.count, in: env)

        await #expect(throws: ThrowAsyncError.boom) {
            try await env.perform(ThrowSyncChildAsync())
        }
        #expect(env.read(\ThrowAsyncState.count) == 1)
        probe.expect(updates: 1)
        probe.expect(value: 1)
    }

    @Test("Joiners of a throwing Execution get the same error")
    func joinersGetTheError() async {
        let env = SharedEnvironment()
        let gate = HoldGate()

        let first = Task { @MainActor in
            try await env.perform(FirstWinsThenThrow(gate: gate))
        }
        await gate.waitForArrival()
        let second = Task { @MainActor in
            try await env.perform(FirstWinsThenThrow(gate: gate))
        }
        gate.release()

        await #expect(throws: ThrowAsyncError.boom) {
            try await first.value
        }
        await #expect(throws: ThrowAsyncError.boom) {
            try await second.value
        }
        #expect(gate.arrivals == 1)
    }
}

struct FirstWinsThenThrow: ThrowingAsyncOperation {
    var reentrancy: ReentrancyDecision { .firstWins(.wholeOperation) }
    let gate: HoldGate
    func perform(in env: AsyncOperationEnvironment) async throws(ThrowAsyncError) {
        await gate.holdHere()
        throw .boom
    }
}
