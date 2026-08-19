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

/// Counts how many times a computed closure body actually runs, so tests can
/// assert recompute behaviour (cache hits vs. misses) directly.
@MainActor
enum RecomputeProbe {
    static var atomic = 0
    static var keyed = 0
    static var sum = 0

    static func reset() {
        atomic = 0
        keyed = 0
        sum = 0
    }
}

final class CachedState: StateContainer {
    var a: Int = 1
    var b: Int = 100
    var unrelated: Int = 0

    @Computed var doubled = { (env: ComputationEnvironment) -> Int in
        RecomputeProbe.atomic += 1
        return env.getValue(\CachedState.a) * 2
    }

    // Reads two inputs: one operation mutating both must still recompute it only once.
    @Computed var sum = { (env: ComputationEnvironment) -> Int in
        RecomputeProbe.sum += 1
        return env.getValue(\CachedState.a) + env.getValue(\CachedState.b)
    }

    // Reads only the value at its own key; another key's change must not recompute.
    var byKey: [Int: Int] = [1: 10, 2: 20]
    @Computed var fromKey = { (env: ComputationEnvironment, key: Int) -> Int in
        RecomputeProbe.keyed += 1
        return (env.getValue(\CachedState.byKey, key: key) ?? 0) + 1
    }
}

struct BumpA: SyncOperation {
    func perform(in env: SyncOperationEnvironment) {
        env.write(env.read(keyPath: \CachedState.a) + 1, keyPath: \CachedState.a)
    }
}

struct BumpUnrelated: SyncOperation {
    func perform(in env: SyncOperationEnvironment) {
        env.write(env.read(keyPath: \CachedState.unrelated) + 1, keyPath: \CachedState.unrelated)
    }
}

struct BumpKey: SyncOperation {
    let key: Int
    func perform(in env: SyncOperationEnvironment) {
        env.write((env.read(keyPath: \CachedState.byKey, key: key) ?? 0) + 1, keyPath: \CachedState.byKey, key: key)
    }
}

/// One operation mutating both inputs of `sum` — must collapse to a single recompute.
struct BumpAB: SyncOperation {
    func perform(in env: SyncOperationEnvironment) {
        env.write(env.read(keyPath: \CachedState.a) + 1, keyPath: \CachedState.a)
        env.write(env.read(keyPath: \CachedState.b) + 1, keyPath: \CachedState.b)
    }
}

struct RemoveKey: SyncOperation {
    let key: Int
    func perform(in env: SyncOperationEnvironment) {
        env.remove(keyPath: \CachedState.byKey, key: key)
    }
}

@MainActor
struct ComputedCacheTests {

    /// Reading twice without any mutation runs the body once: the second read is a cache hit.
    @Test func repeatedReadHitsCache() {
        RecomputeProbe.reset()
        let env = SharedEnvironment()
        let probe = ValueObserverProbe.watch(computed: \CachedState.$doubled, in: env)

        #expect(RecomputeProbe.atomic == 1)
        probe.render() // manual re-read, no state change
        probe.render()
        #expect(RecomputeProbe.atomic == 1)
        probe.expect(value: 2)
    }

    /// A change to a tracked input clears the cache; the next read recomputes once.
    @Test func invalidationClearsCache() {
        RecomputeProbe.reset()
        let env = SharedEnvironment()
        let probe = ValueObserverProbe.watch(computed: \CachedState.$doubled, in: env)
        #expect(RecomputeProbe.atomic == 1)

        probe.perform(BumpA()) // a: 1 -> 2, invalidates, auto re-renders
        #expect(RecomputeProbe.atomic == 2)
        probe.expect(value: 4)
    }

    /// A change to an untracked input does not clear the cache: no recompute.
    @Test func unrelatedChangeKeepsCache() {
        RecomputeProbe.reset()
        let env = SharedEnvironment()
        let probe = ValueObserverProbe.watch(computed: \CachedState.$doubled, in: env)
        #expect(RecomputeProbe.atomic == 1)

        probe.perform(BumpUnrelated())
        probe.render()
        #expect(RecomputeProbe.atomic == 1)
    }

    /// Many readers of one computed in a single environment share the cache:
    /// the second reader hits the entry stored by the first. One recompute, two readers.
    @Test func manyReadersOneRecompute() {
        RecomputeProbe.reset()
        let env = SharedEnvironment()
        let first = ValueObserverProbe.watch(computed: \CachedState.$doubled, in: env)
        let second = ValueObserverProbe.watch(computed: \CachedState.$doubled, in: env)

        #expect(RecomputeProbe.atomic == 1)
        first.expect(value: 2)
        second.expect(value: 2)
    }

    /// Keyed computed caches per key: invalidating one key recomputes only that key.
    @Test func keyedCacheIsPerKey() {
        RecomputeProbe.reset()
        let env = SharedEnvironment()
        let k1 = ValueObserverProbe.watch(computedKeyed: \CachedState.$fromKey, key: 1, in: env)
        let k2 = ValueObserverProbe.watch(computedKeyed: \CachedState.$fromKey, key: 2, in: env)
        #expect(RecomputeProbe.keyed == 2) // one compute per key
        k1.expect(value: 11)
        k2.expect(value: 21)

        k1.perform(BumpKey(key: 1)) // invalidates key 1 only
        #expect(RecomputeProbe.keyed == 3) // only key 1 recomputed
        k1.expect(value: 12)
        k2.expect(value: 21)
    }

    // MARK: - Follow-up: tracing signal must be cross-pass (in-pass recompute ≤ 1)

    /// One operation that invalidates *both* inputs of `sum` recomputes it once, not twice:
    /// the first invalidation clears the cache and drops the clear hook, the second is a no-op,
    /// and the single re-render recomputes once. Proves an in-pass recompute counter can never
    /// exceed 1 per computed — so a "recomputes many times in one pass" signal can't fire.
    @Test func multipleInputsInOneOperationRecomputeOnce() {
        RecomputeProbe.reset()
        let env = SharedEnvironment()
        let probe = ValueObserverProbe.watch(computed: \CachedState.$sum, in: env)
        #expect(RecomputeProbe.sum == 1) // initial render
        probe.expect(value: 101)

        probe.perform(BumpAB()) // a: 1->2, b: 100->101 in one pass
        #expect(RecomputeProbe.sum == 2) // exactly one more recompute, not two
        probe.expect(value: 103)
    }

    // MARK: - Follow-up: keyed-cache eviction

    /// Atomic cache is a single slot: re-reading after one compute never grows or re-runs.
    /// (Documents that atomic needs no eviction.)
    @Test func atomicCacheIsSingleSlot() {
        RecomputeProbe.reset()
        let env = SharedEnvironment()
        let probe = ValueObserverProbe.watch(computed: \CachedState.$doubled, in: env)
        for _ in 0..<10 { probe.render() }
        #expect(RecomputeProbe.atomic == 1)
    }

    /// Distinct keys accumulate independent entries that persist with no eviction:
    /// once read, each key stays cached and re-reads hit it (no recompute) until invalidated.
    /// Documents the lingering the eviction follow-up would address.
    @Test func keyedEntriesPersistPerKey() {
        RecomputeProbe.reset()
        let env = SharedEnvironment()
        let k1 = ValueObserverProbe.watch(computedKeyed: \CachedState.$fromKey, key: 1, in: env)
        let k2 = ValueObserverProbe.watch(computedKeyed: \CachedState.$fromKey, key: 2, in: env)
        #expect(RecomputeProbe.keyed == 2)

        // Re-read both keys repeatedly, no mutation: every read is a cache hit.
        for _ in 0..<5 { k1.render(); k2.render() }
        #expect(RecomputeProbe.keyed == 2) // entries lingered, nothing recomputed
    }

    /// `removeValue` invalidates the keyed `ValueID`, clearing that key's cache entry:
    /// the next read recomputes. Shows removed data does not linger.
    @Test func removeClearsKeyedEntry() {
        RecomputeProbe.reset()
        let env = SharedEnvironment()
        let k1 = ValueObserverProbe.watch(computedKeyed: \CachedState.$fromKey, key: 1, in: env)
        #expect(RecomputeProbe.keyed == 1)
        k1.expect(value: 11)

        k1.perform(RemoveKey(key: 1)) // invalidates key 1 -> clears its entry, re-renders
        #expect(RecomputeProbe.keyed == 2) // recomputed after removal
        k1.expect(value: 1) // byKey[1] now nil -> 0 + 1
    }
}
