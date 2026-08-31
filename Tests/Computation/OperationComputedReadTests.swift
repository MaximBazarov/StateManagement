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

/// Counts closure runs so a test can tell a cache hit from a recompute.
@MainActor
enum OpReadProbe {
    static var atomic = 0
    static var keyed = 0

    static func reset() {
        atomic = 0
        keyed = 0
    }
}

final class OpReadState: StateContainer {
    var count: Int = 1
    var byKey: [String: Int] = ["a": 10]

    @Computed var doubled = { (env: ComputationEnvironment) -> Int in
        OpReadProbe.atomic += 1
        return env.read(\OpReadState.count) * 2
    }

    @Computed var fromKey = { (env: ComputationEnvironment, key: String) -> Int in
        OpReadProbe.keyed += 1
        return (env.read(\OpReadState.byKey, key: key) ?? 0) + 1
    }
}

// MARK: - Operations under test

@MainActor final class OpReadSink {
    static var atomic = -1
    static var keyed = -1
}

struct ReadAtomicComputed: SyncOperation {
    func perform(in env: SyncOperationEnvironment) {
        OpReadSink.atomic = env.read(\OpReadState.$doubled)
    }
}

struct ReadKeyedComputed: SyncOperation {
    let key: String
    func perform(in env: SyncOperationEnvironment) {
        OpReadSink.keyed = env.read(\OpReadState.$fromKey, key: key)
    }
}

/// Writes an input, then reads the Computed that derives from it in the same Operation.
struct BumpThenReadComputed: SyncOperation {
    func perform(in env: SyncOperationEnvironment) {
        env.write(\OpReadState.count, value: env.read(\OpReadState.count) + 1)
        OpReadSink.atomic = env.read(\OpReadState.$doubled)
    }
}

struct ReadComputedTwice: SyncOperation {
    func perform(in env: SyncOperationEnvironment) {
        _ = env.read(\OpReadState.$doubled)
        OpReadSink.atomic = env.read(\OpReadState.$doubled)
    }
}

struct AsyncReadComputed: AsyncOperation {
    var reentrancy: ReentrancyDecision { .runAll }

    func perform(in env: AsyncOperationEnvironment) async {
        OpReadSink.atomic = env.read(\OpReadState.$doubled)
    }
}

// MARK: - Tests

@Suite("An Operation reads a Computed") @MainActor
struct OperationComputedReadTests {

    @Test("A Sync operation reads an atomic Computed")
    func syncReadsAtomic() {
        OpReadProbe.reset()
        let env = SharedEnvironment()

        env.perform(ReadAtomicComputed())

        #expect(OpReadSink.atomic == 2)
        #expect(OpReadProbe.atomic == 1)
    }

    @Test("A Sync operation reads a keyed Computed")
    func syncReadsKeyed() {
        OpReadProbe.reset()
        let env = SharedEnvironment()

        env.perform(ReadKeyedComputed(key: "a"))

        #expect(OpReadSink.keyed == 11)
        #expect(OpReadProbe.keyed == 1)
    }

    @Test("An Async operation reads a Computed")
    func asyncReadsAtomic() async {
        OpReadProbe.reset()
        let env = SharedEnvironment()

        await env.perform(AsyncReadComputed())

        #expect(OpReadSink.atomic == 2)
    }

    /// The distinguishing behaviour: an Operation reads and lets go, so it leaves no receiver
    /// behind on the Computed or on any input the derivation touched.
    @Test("An Operation read subscribes nothing")
    func operationReadLeavesNoSubscription() {
        OpReadProbe.reset()
        let env = SharedEnvironment()

        env.perform(ReadAtomicComputed())

        #expect(env.observation.subscribedValueIDs.isEmpty)
    }

    /// Everything except the subscription is an ordinary read, so the second read in one
    /// Operation hits the cache rather than recomputing.
    @Test("An Operation read fills the cache like any other reader")
    func operationReadFillsCache() {
        OpReadProbe.reset()
        let env = SharedEnvironment()

        env.perform(ReadComputedTwice())

        #expect(OpReadProbe.atomic == 1)
        #expect(OpReadSink.atomic == 2)
    }

    /// Invalidation is eager at write, so a read after a write in the same Operation sees the
    /// value derived from current State rather than a stale cache entry.
    @Test("A Computed read after a write in the same Operation is not stale")
    func readAfterWriteInSameOperation() {
        OpReadProbe.reset()
        let env = SharedEnvironment()

        env.perform(ReadAtomicComputed())
        #expect(OpReadSink.atomic == 2) // count 1

        env.perform(BumpThenReadComputed())

        #expect(OpReadSink.atomic == 4) // count 2, recomputed inside the Operation
    }

    /// A Watch-style reader still subscribes, so the Operation read does not change the
    /// behaviour of consumers that do want notifying.
    @Test("A subscribing reader is unaffected by Operation reads")
    func subscribingReaderStillSubscribes() {
        OpReadProbe.reset()
        let env = SharedEnvironment()
        let probe = ValueObserverProbe.watch(computed: \OpReadState.$doubled, in: env)

        env.perform(ReadAtomicComputed())

        probe.expect(value: 2)
        #expect(env.observation.subscribedValueIDs.isEmpty == false)
    }
}
