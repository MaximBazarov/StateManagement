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

// MARK: - Containers

/// Not `Equatable`, so a reader of it re-renders once per observation round.
struct FlagTally {
    let count: Int
}

/// The dictionary Address `flags` and each of its entries. Inference resolves Keyed here.
final class ShapeKeyedBox: StateContainer {
    @AsyncState(MockStrategy.self) var flags: [String: Bool] = [:]

    /// Reads two entries, so one observation round over both keys costs this one recompute.
    /// The output is deliberately not `Equatable`, so no diffing hides a second round.
    @Computed var setFlags = { (env: ComputationEnvironment) -> FlagTally in
        let a = env.read(\ShapeKeyedBox.flags, key: "a") ?? false
        let b = env.read(\ShapeKeyedBox.flags, key: "b") ?? false
        return FlagTally(count: (a ? 1 : 0) + (b ? 1 : 0))
    }
}

/// The Design limitation of ADR 0026, spelled out on purpose: an Atomic Address whose Value
/// happens to be a dictionary. Inference never produces it, because the Keyed init outranks the
/// Atomic one, and Swift has no negative constraint that would forbid the spelling.
final class ExplicitAtomicDictionaryBox: StateContainer {
    @AsyncState<MockStrategy, NoKey, [String: Bool], [String: Bool]>(MockStrategy.self)
    var flags: [String: Bool] = [:]
}

/// ``NestedPerformStrategy`` declares only the Atomic `onRead`, so this keyed Address exercises
/// the empty Keyed default.
final class AtomicOnlyStrategyKeyedBox: StateContainer {
    @AsyncState(NestedPerformStrategy.self) var flags: [String: Bool] = [:]
}

/// Counts its own reads, so a test can see how many times the read path walks the key path.
final class CountingPlainBox: StateContainer {
    nonisolated(unsafe) static var reads = 0
    var counted: Int {
        Self.reads += 1
        return 7
    }
}

struct RemoveFlag: SyncOperation {
    let key: String
    func perform(in env: SyncOperationEnvironment) {
        env.remove(\ShapeKeyedBox.flags, key: key)
    }
}

struct SeedFlag: SyncOperation {
    func perform(in env: SyncOperationEnvironment) {
        env.write(\ShapeKeyedBox.flags, key: "a", value: true)
    }
}

extension SharedEnvironment {
    fileprivate func strategyUnderTest<S: AsyncStrategy>(_ type: S.Type) -> S {
        let created = S(env: strategyEnvironment())
        install(created)
        return created
    }
}

// MARK: - The read path split

@Suite @MainActor
struct AsyncStateShapeTests {

    @Test("A dictionary-Address read does not kick; an entry read of the same declaration does")
    func dictionaryReadDoesNotKickButAnEntryReadDoes() {
        let env = SharedEnvironment()
        let strategy = env.strategyUnderTest(MockStrategy.self)

        _ = env.read(\ShapeKeyedBox.flags)

        #expect(strategy.keyedOnReadCount == 0)
        #expect(strategy.onReadCount == 0)
        // The dictionary Address is never a seam Address, so it leaves no record behind either.
        #expect(env.asyncState.record(at: ValueID(keyPath: \ShapeKeyedBox.flags)) == nil)

        _ = env.read(\ShapeKeyedBox.flags, key: "a")

        #expect(strategy.keyedOnReadCount == 1)
        #expect(env.asyncState.record(at: ValueID(keyPath: \ShapeKeyedBox.flags, key: "a")) != nil)
    }

    @Test("A dictionary-typed @AsyncState declaration resolves Keyed")
    func dictionaryDeclarationResolvesKeyed() {
        let env = SharedEnvironment()
        _ = env.strategyUnderTest(MockStrategy.self)

        // Only the Keyed half of the wrapper has a per-key status, so this binds nowhere else.
        let status: [String: AsyncStateStatus<MockFailure>] = env.read(\ShapeKeyedBox.$flags).status

        #expect(status.isEmpty)
        _ = env.read(\ShapeKeyedBox.flags, key: "a")
        #expect(env.read(\ShapeKeyedBox.$flags).status["a"] != nil)
    }

    /// Pins ADR 0026's Design limitation rather than the behaviour anyone should want: the
    /// scalar half works, and the Value read takes the dictionary path, so it never loads.
    @Test("An explicit Atomic dictionary Address preheats but never kicks on a Value read")
    func explicitAtomicDictionaryHalfWorks() {
        let env = SharedEnvironment()
        let strategy = env.strategyUnderTest(MockStrategy.self)

        _ = env.read(\ExplicitAtomicDictionaryBox.flags)
        #expect(strategy.onReadCount == 0)

        env.preheat(\ExplicitAtomicDictionaryBox.$flags)
        #expect(strategy.onReadCount == 1)
    }

    @Test("An Atomic-only strategy still gets the empty Keyed default")
    func atomicOnlyStrategyGetsTheEmptyKeyedDefault() {
        let env = SharedEnvironment()
        _ = env.strategyUnderTest(NestedPerformStrategy.self)

        let entry = env.read(\AtomicOnlyStrategyKeyedBox.flags, key: "a")

        #expect(entry == nil)
        // The Atomic onRead performs a write; the empty Keyed default performs nothing.
        #expect(env.read(\NestedWriteBox.count) == 0)
    }

    @Test("A non-sourced Address is read once after its first read")
    func plainAddressIsWalkedOnlyOnce() {
        let env = SharedEnvironment()
        CountingPlainBox.reads = 0

        _ = env.read(\CountingPlainBox.counted)
        let firstRead = CountingPlainBox.reads

        _ = env.read(\CountingPlainBox.counted)

        // The first read walks twice, once to look for a wrapper and once for the Value.
        #expect(firstRead == 2)
        #expect(CountingPlainBox.reads == 3)
    }
}

// MARK: - Evict, seed, and markStale

@Suite @MainActor
struct AsyncStateEvictionTests {

    @Test("remove of a sourced keyed entry evicts: pending, no kick, and the next read reloads")
    func removeEvictsASourcedEntry() {
        let env = SharedEnvironment()
        let strategy = env.strategyUnderTest(MockStrategy.self)
        env.perform(SeedFlag())
        #expect(env.read(\ShapeKeyedBox.$flags).status["a"] == .settled)
        let kicksBeforeRemove = strategy.keyedOnReadCount
        let writesBeforeRemove = strategy.onWriteCount

        env.perform(RemoveFlag(key: "a"))

        #expect(env.read(\ShapeKeyedBox.$flags).status["a"] == .pending)
        // A removal is a change to the Value, and it must not escape to the strategy.
        #expect(strategy.onWriteCount == writesBeforeRemove)
        #expect(strategy.keyedOnReadCount == kicksBeforeRemove)

        #expect(env.read(\ShapeKeyedBox.flags, key: "a") == nil)
        #expect(strategy.keyedOnReadCount == kicksBeforeRemove + 1)
    }

    @Test("A seeded write to a sourced Address calls onWrite and settles")
    func seededWriteIsAnOrdinarySyncWrite() {
        let env = SharedEnvironment()
        let strategy = env.strategyUnderTest(MockStrategy.self)

        env.seed { SeedFlag() }

        #expect(strategy.onWriteCount == 1)
        #expect(env.read(\ShapeKeyedBox.$flags).status["a"] == .settled)
    }

    /// Inbound is not a read. A strategy that applies from a push reaches an Address nobody has
    /// read, and opening its record must not turn into a load.
    @Test("Inbound on an Address nobody has read does not call onRead")
    func inboundOnAnUnreadAddressDoesNotKick() {
        let env = SharedEnvironment()
        let strategy = env.strategyUnderTest(MockStrategy.self)

        strategy.env.apply(\ShapeKeyedBox.$flags, key: "a", value: true)

        #expect(strategy.keyedOnReadCount == 0)
        #expect(env.read(\ShapeKeyedBox.$flags).status["a"] == .settled)

        // Still the first read of that Address, so it kicks now.
        #expect(env.read(\ShapeKeyedBox.flags, key: "a") == true)
        #expect(strategy.keyedOnReadCount == 1)
    }

    @Test("markStale(keys:) fires one observation round")
    func markStaleOfManyKeysFiresOneRound() {
        let env = SharedEnvironment()
        let strategy = env.strategyUnderTest(MockStrategy.self)
        let probe = ValueObserverProbe<ShapeKeyedBox, FlagTally>
            .watchComputedRaw(\ShapeKeyedBox.$setFlags, in: env)
        #expect(probe.updates == 0)

        strategy.env.markStale(\ShapeKeyedBox.$flags, keys: ["a", "b"])

        // One Operation, so both dirtied keys land in the same flush.
        probe.expect(updates: 1)
    }
}
