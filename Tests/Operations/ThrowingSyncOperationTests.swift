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

enum ThrowSyncError: Error, Equatable {
    case boom
}

final class ThrowSyncState: StateContainer {
    var count = 0
    var other = 0
}

struct WriteThenThrow: ThrowingSyncOperation {
    func perform(in env: SyncOperationEnvironment) throws(ThrowSyncError) {
        env.write(1, keyPath: \ThrowSyncState.count)
        throw .boom
    }
}

struct WriteOther: SyncOperation {
    func perform(in env: SyncOperationEnvironment) {
        env.write(1, keyPath: \ThrowSyncState.other)
    }
}

struct NestedThenThrow: ThrowingSyncOperation {
    func perform(in env: SyncOperationEnvironment) throws(ThrowSyncError) {
        env.write(1, keyPath: \ThrowSyncState.count)
        env.perform(WriteOther())
        throw .boom
    }
}

struct WriteCount: SyncOperation {
    let value: Int
    func perform(in env: SyncOperationEnvironment) {
        env.write(value, keyPath: \ThrowSyncState.count)
    }
}

struct NestedSameAddressWrites: SyncOperation {
    func perform(in env: SyncOperationEnvironment) {
        env.perform(WriteCount(value: 1))
        env.perform(WriteCount(value: 2))
    }
}

struct AsyncParentSyncChildren: AsyncOperation {
    var reentrancy: ReentrancyDecision { .runAll }
    func perform(in env: AsyncOperationEnvironment) async {
        env.perform(WriteCount(value: 1))
        env.perform(WriteCount(value: 2))
    }
}

@Suite @MainActor
struct ThrowingSyncOperationTests {

    @Test("A throwing Sync operation surfaces the error")
    func surfacesError() {
        let env = SharedEnvironment()

        #expect(throws: ThrowSyncError.boom) {
            try env.perform(WriteThenThrow())
        }
    }

    @Test("A throwing Sync operation keeps its writes")
    func keepsWrites() {
        let env = SharedEnvironment()

        #expect(throws: ThrowSyncError.boom) {
            try env.perform(WriteThenThrow())
        }
        #expect(env.read(\ThrowSyncState.count) == 1)
    }

    @Test("A throwing Sync operation notifies observers")
    func notifiesObservers() {
        let env = SharedEnvironment()
        let probe = ValueObserverProbe.watch(\ThrowSyncState.count, in: env)

        #expect(throws: ThrowSyncError.boom) {
            try env.perform(WriteThenThrow())
        }
        probe.expect(updates: 1)
        probe.expect(value: 1)
    }

    @Test("A non-throwing Sync operation still writes and notifies")
    func nonThrowingStillWritesAndNotifies() {
        let env = SharedEnvironment()
        let probe = ValueObserverProbe.watch(\ThrowSyncState.other, in: env)

        env.perform(WriteOther())

        #expect(env.read(\ThrowSyncState.other) == 1)
        probe.expect(updates: 1)
        probe.expect(value: 1)
    }

    @Test("Nested perform still writes and notifies")
    func nestedStillWritesAndNotifies() {
        let env = SharedEnvironment()
        let count = ValueObserverProbe.watch(\ThrowSyncState.count, in: env)
        let other = ValueObserverProbe.watch(\ThrowSyncState.other, in: env)

        #expect(throws: ThrowSyncError.boom) {
            try env.perform(NestedThenThrow())
        }
        #expect(env.read(\ThrowSyncState.count) == 1)
        #expect(env.read(\ThrowSyncState.other) == 1)
        count.expect(updates: 1)
        count.expect(value: 1)
        other.expect(updates: 1)
        other.expect(value: 1)
    }

    @Test("Nested perform on the same Address notifies once with the final Value")
    func nestedSameAddressNotifiesOnce() {
        let env = SharedEnvironment()
        let probe = ValueObserverProbe.watch(\ThrowSyncState.count, in: env)

        env.perform(NestedSameAddressWrites())

        #expect(env.read(\ThrowSyncState.count) == 2)
        probe.expect(updates: 1)
        probe.expect(value: 2)
    }

    @Test("An Async parent's Sync children stay separate originals")
    func asyncParentSyncChildrenStaySeparateOriginals() async {
        let env = SharedEnvironment()
        let probe = ValueObserverProbe.watch(\ThrowSyncState.count, in: env)

        await env.perform(AsyncParentSyncChildren())

        #expect(env.read(\ThrowSyncState.count) == 2)
        probe.expect(updates: 2)
        probe.expect(value: 2)
    }
}
