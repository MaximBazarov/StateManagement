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

// MARK: - Cyclic containers (each read triggers the runtime cycle guard)
//
// A computed that reads its own (or a mutually-referencing) projected value in a
// stored-property *default* is a compile-time circular reference. Assigning the
// cyclic closure in `init()` — after the property types are established by the
// placeholder defaults — sidesteps that while still forming the cycle at runtime.

/// `A → A`: a computed reads itself.
final class DirectCycleState: StateContainer {
    @Computed var loop = { (_: ComputationEnvironment) -> Int in 0 }

    init() {
        _loop = Computed(wrappedValue: { (env: ComputationEnvironment) -> Int in
            env.read(\DirectCycleState.$loop)
        })
    }
}

/// `A → B → A`: two computeds read each other.
final class TransitiveCycleState: StateContainer {
    @Computed var alpha = { (_: ComputationEnvironment) -> Int in 0 }
    @Computed var beta = { (_: ComputationEnvironment) -> Int in 0 }

    init() {
        _alpha = Computed(wrappedValue: { (env: ComputationEnvironment) -> Int in
            env.read(\TransitiveCycleState.$beta)
        })
        _beta = Computed(wrappedValue: { (env: ComputationEnvironment) -> Int in
            env.read(\TransitiveCycleState.$alpha)
        })
    }
}

/// A per-key chain: node `k` reads node `next[k]`. `1 → 2 → 1` forms a per-key
/// cycle, while `3 → 0` terminates (a `0` link is the base case). So a cycle
/// exists at key 1 but not at key 3, in the same container.
final class PerKeyCycleState: StateContainer {
    var next: [Int: Int] = [1: 2, 2: 1, 3: 0]

    @Computed var chain = { (_: ComputationEnvironment, _: Int) -> Int in 0 }

    init() {
        _chain = Computed(wrappedValue: { (env: ComputationEnvironment, key: Int) -> Int in
            let nxt = env.read(\PerKeyCycleState.next, key: key) ?? 0
            if nxt == 0 { return 0 }
            return env.read(\PerKeyCycleState.$chain, key: nxt) + 1
        })
    }
}

// MARK: - Exit tests

/// Reading a cyclic computed must trap. Each closure runs in a fresh subprocess
/// (exit test), builds its own environment, and reads the offending computed;
/// the guard reports the full chain through the telemetry channel and then
/// `fatalError`s with the same message. We observe stderr to confirm the report.
///
/// Exit tests spawn a subprocess. Swift Testing does not provide that API on
/// iOS, so the three trap tests compile out there. `nonCyclicKeyDoesNotTrap`
/// still runs on every declared platform.
@MainActor
struct ComputedCycleGuardTests {

    #if os(macOS)
    /// `A → A` crashes; the message names the cycle.
    @Test func directCycleTraps() async {
        let result = await #expect(
            processExitsWith: .failure,
            observing: [\.standardErrorContent]
        ) {
            await MainActor.run {
                let env = SharedEnvironment()
                _ = ValueObserverProbe<DirectCycleState, Int>.watch(computed: \DirectCycleState.$loop, in: env)
            }
        }
        // Unconditional: a clean trap must leave the report on stderr. If capture yields
        // nothing (e.g. a stack overflow from a broken guard, which also exits with failure),
        // this fails loudly instead of silently degrading to the exit-status check alone.
        let text = result.map { String(decoding: $0.standardErrorContent, as: UTF8.self) } ?? ""
        #expect(
            text.contains("Computed dependency cycle: "),
            "expected the cycle report on stderr, got: \(text.isEmpty ? "<empty>" : text)"
        )
    }

    /// `A → B → A` crashes; the message names the full chain (two arrows).
    @Test func transitiveCycleTraps() async {
        let result = await #expect(
            processExitsWith: .failure,
            observing: [\.standardErrorContent]
        ) {
            await MainActor.run {
                let env = SharedEnvironment()
                _ = ValueObserverProbe<TransitiveCycleState, Int>.watch(computed: \TransitiveCycleState.$alpha, in: env)
            }
        }
        let text = result.map { String(decoding: $0.standardErrorContent, as: UTF8.self) } ?? ""
        #expect(
            text.contains("Computed dependency cycle: "),
            "expected the cycle report on stderr, got: \(text.isEmpty ? "<empty>" : text)"
        )
        // A → B → A: the chain has two arrows, so at least three components.
        #expect(text.components(separatedBy: "→").count >= 3)
    }

    /// A per-key cycle at key 1 crashes.
    @Test func perKeyCycleTraps() async {
        let result = await #expect(
            processExitsWith: .failure,
            observing: [\.standardErrorContent]
        ) {
            await MainActor.run {
                let env = SharedEnvironment()
                _ = ValueObserverProbe<PerKeyCycleState, Int>.watch(computedKeyed: \PerKeyCycleState.$chain, key: 1, in: env)
            }
        }
        let text = result.map { String(decoding: $0.standardErrorContent, as: UTF8.self) } ?? ""
        #expect(
            text.contains("Computed dependency cycle: "),
            "expected the cycle report on stderr, got: \(text.isEmpty ? "<empty>" : text)"
        )
    }
    #endif

    /// A non-cyclic key in the same container does not crash and returns its value.
    @Test func nonCyclicKeyDoesNotTrap() {
        let env = SharedEnvironment()
        let probe = ValueObserverProbe<PerKeyCycleState, Int>.watch(computedKeyed: \PerKeyCycleState.$chain, key: 3, in: env)
        probe.expect(value: 0) // next[3] == 0 -> base case, no recursion
    }
}
