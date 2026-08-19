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

/// Per-level recompute counters, so composition tests can assert exactly which
/// levels of a chain re-ran (cache hits vs. misses across composed computeds).
@MainActor
enum CompositionProbe {
    static var a = 0
    static var b = 0
    static var c = 0

    static func reset() {
        a = 0
        b = 0
        c = 0
    }
}

// MARK: - Chain: input → A → B → C

/// A three-level chain where each computed reads the one below it through the
/// environment, exercising `Computed`-reading-`Computed` composition.
final class ChainState: StateContainer {
    var input: Int = 1

    @Computed var levelA = { (env: ComputationEnvironment) -> Int in
        CompositionProbe.a += 1
        return env.getValue(\ChainState.input) + 1
    }

    @Computed var levelB = { (env: ComputationEnvironment) -> Int in
        CompositionProbe.b += 1
        return env.getValue(\ChainState.$levelA) + 1
    }

    @Computed var levelC = { (env: ComputationEnvironment) -> Int in
        CompositionProbe.c += 1
        return env.getValue(\ChainState.$levelB) + 1
    }
}

struct BumpInput: SyncOperation {
    func perform(in env: SyncOperationEnvironment) {
        env.write(env.read(keyPath: \ChainState.input) + 1, keyPath: \ChainState.input)
    }
}

// MARK: - Diamond: X → {A, B} → C

/// A diamond where `dc` reads both `da` and `db`, and both read the same raw
/// input `x`. One change to `x` must recompute `dc` exactly once.
final class DiamondState: StateContainer {
    var x: Int = 1

    @Computed var da = { (env: ComputationEnvironment) -> Int in
        CompositionProbe.a += 1
        return env.getValue(\DiamondState.x) + 1
    }

    @Computed var db = { (env: ComputationEnvironment) -> Int in
        CompositionProbe.b += 1
        return env.getValue(\DiamondState.x) + 2
    }

    @Computed var dc = { (env: ComputationEnvironment) -> Int in
        CompositionProbe.c += 1
        return env.getValue(\DiamondState.$da) + env.getValue(\DiamondState.$db)
    }
}

struct BumpX: SyncOperation {
    func perform(in env: SyncOperationEnvironment) {
        env.write(env.read(keyPath: \DiamondState.x) + 1, keyPath: \DiamondState.x)
    }
}

// MARK: - Selective: C reads A(p) and B(q); bumping p spares B

/// `sc` reads both `sa` (over input `p`) and `sb` (over input `q`). A change to
/// `p` must recompute `sa` and `sc` but leave the memoized `sb` untouched.
final class SelectiveState: StateContainer {
    var p: Int = 1
    var q: Int = 10

    @Computed var sa = { (env: ComputationEnvironment) -> Int in
        CompositionProbe.a += 1
        return env.getValue(\SelectiveState.p) + 1
    }

    @Computed var sb = { (env: ComputationEnvironment) -> Int in
        CompositionProbe.b += 1
        return env.getValue(\SelectiveState.q) + 1
    }

    @Computed var sc = { (env: ComputationEnvironment) -> Int in
        CompositionProbe.c += 1
        return env.getValue(\SelectiveState.$sa) + env.getValue(\SelectiveState.$sb)
    }
}

struct BumpP: SyncOperation {
    func perform(in env: SyncOperationEnvironment) {
        env.write(env.read(keyPath: \SelectiveState.p) + 1, keyPath: \SelectiveState.p)
    }
}

// MARK: - Per-key composition

/// A keyed computed (`outer`) reads another keyed computed (`inner`) at the same
/// key. Invalidating one key must cascade only that key's entries.
final class KeyedCompState: StateContainer {
    var raw: [Int: Int] = [1: 10, 2: 20]

    @Computed var inner = { (env: ComputationEnvironment, key: Int) -> Int in
        CompositionProbe.a += 1
        return (env.getValue(\KeyedCompState.raw, key: key) ?? 0) + 1
    }

    @Computed var outer = { (env: ComputationEnvironment, key: Int) -> Int in
        CompositionProbe.b += 1
        return env.getValue(\KeyedCompState.$inner, key: key) + 100
    }
}

struct BumpRawKey: SyncOperation {
    let key: Int
    func perform(in env: SyncOperationEnvironment) {
        env.write(
            (env.read(keyPath: \KeyedCompState.raw, key: key) ?? 0) + 1,
            keyPath: \KeyedCompState.raw,
            key: key
        )
    }
}

// MARK: - Tests

@MainActor
struct ComputedCompositionTests {

    /// `input → A → B → C`: one change to the raw input recomputes all three,
    /// top-down and lazily, and the value updates.
    @Test func chainRecomputesTopDown() {
        CompositionProbe.reset()
        let env = SharedEnvironment()
        let probe = ValueObserverProbe.watch(computed: \ChainState.$levelC, in: env)

        #expect(CompositionProbe.a == 1)
        #expect(CompositionProbe.b == 1)
        #expect(CompositionProbe.c == 1)
        probe.expect(value: 4) // (1+1)+1+1

        probe.perform(BumpInput()) // input: 1 -> 2, cascades through A, B, C
        #expect(CompositionProbe.a == 2)
        #expect(CompositionProbe.b == 2)
        #expect(CompositionProbe.c == 2)
        probe.expect(value: 5) // (2+1)+1+1
    }

    /// `X → {A, B} → C`: one change to `X` recomputes the shared outer `C` exactly
    /// once, not once per path — the visited set dedups the diamond.
    @Test func diamondRecomputesOnce() {
        CompositionProbe.reset()
        let env = SharedEnvironment()
        let probe = ValueObserverProbe.watch(computed: \DiamondState.$dc, in: env)
        #expect(CompositionProbe.c == 1)
        probe.expect(value: 5) // (1+1) + (1+2)

        probe.perform(BumpX()) // x: 1 -> 2
        #expect(CompositionProbe.a == 2)
        #expect(CompositionProbe.b == 2)
        #expect(CompositionProbe.c == 2) // recomputed once, not twice
        probe.expect(value: 7) // (2+1) + (2+2)
    }

    /// An input feeding only `A` recomputes `A` and the outer `C`, but the memoized
    /// sibling `B` is not recomputed.
    @Test func memoizedIntermediateNotRecomputed() {
        CompositionProbe.reset()
        let env = SharedEnvironment()
        let probe = ValueObserverProbe.watch(computed: \SelectiveState.$sc, in: env)
        #expect(CompositionProbe.a == 1)
        #expect(CompositionProbe.b == 1)
        #expect(CompositionProbe.c == 1)
        probe.expect(value: 13) // (1+1) + (10+1)

        probe.perform(BumpP()) // p: 1 -> 2, feeds only sa
        #expect(CompositionProbe.a == 2) // sa recomputed
        #expect(CompositionProbe.b == 1) // sb untouched (cache hit)
        #expect(CompositionProbe.c == 2) // sc recomputed
        probe.expect(value: 14) // (2+1) + (10+1)
    }

    /// A deep input change through a two-level chain re-renders the view exactly
    /// once — the cascade reaches the observer, batched at the end of the operation.
    @Test func cascadeReachesView() {
        CompositionProbe.reset()
        let env = SharedEnvironment()
        let probe = ValueObserverProbe.watch(computed: \ChainState.$levelB, in: env)
        probe.expect(value: 3) // (1+1)+1

        probe.perform(BumpInput())
        probe.expect(updates: 1)
        probe.expect(value: 4)
    }

    /// Composed keyed computeds: invalidating one key cascades only that key's
    /// inner and outer entries; the other key's entries stay memoized.
    @Test func perKeyComposition() {
        CompositionProbe.reset()
        let env = SharedEnvironment()
        let k1 = ValueObserverProbe.watch(computedKeyed: \KeyedCompState.$outer, key: 1, in: env)
        let k2 = ValueObserverProbe.watch(computedKeyed: \KeyedCompState.$outer, key: 2, in: env)
        #expect(CompositionProbe.a == 2) // inner for both keys
        #expect(CompositionProbe.b == 2) // outer for both keys
        k1.expect(value: 111) // (10+1)+100
        k2.expect(value: 121) // (20+1)+100

        k1.perform(BumpRawKey(key: 1)) // invalidates key 1 only
        #expect(CompositionProbe.a == 3) // only inner[1] recomputed
        #expect(CompositionProbe.b == 3) // only outer[1] recomputed
        k1.expect(value: 112) // (11+1)+100
        k2.expect(value: 121) // unchanged, no recompute
    }
}
