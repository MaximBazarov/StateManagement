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

@MainActor
final class HoldGate {
    private var held: [CheckedContinuation<Void, Never>] = []
    private var arrivalWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var arrivals = 0

    func holdHere() async {
        arrivals += 1
        let waiting = arrivalWaiters
        arrivalWaiters = []
        for continuation in waiting {
            continuation.resume()
        }
        await withCheckedContinuation { continuation in
            held.append(continuation)
        }
    }

    func waitForArrival() async {
        if arrivals > 0 { return }
        await withCheckedContinuation { continuation in
            arrivalWaiters.append(continuation)
        }
    }

    func waitUntilArrivals(_ count: Int) async {
        while arrivals < count {
            await withCheckedContinuation { continuation in
                arrivalWaiters.append(continuation)
            }
        }
    }

    func release() {
        let pending = held
        held = []
        for continuation in pending {
            continuation.resume()
        }
    }
}

struct HoldThenAdd: AsyncOperation {
    var reentrancy: ReentrancyDecision { .firstWins(.wholeOperation) }
    let gate: HoldGate
    let amount: Int

    func perform(in env: AsyncOperationEnvironment) async {
        await gate.holdHere()
        env.perform(AddToTotal(amount: amount))
    }
}

@Suite(.serialized) @MainActor
struct ReentrancyFirstWinsTests {

    @Test("firstWins joins the live Execution; a second awaited perform does not start another")
    func firstWinsJoinsLiveExecution() async {
        let env = SharedEnvironment()
        let gate = HoldGate()

        async let first: Void = env.perform(HoldThenAdd(gate: gate, amount: 1))
        await gate.waitForArrival()
        async let second: Void = env.perform(HoldThenAdd(gate: gate, amount: 10))
        gate.release()
        await first
        await second

        #expect(gate.arrivals == 1)
        #expect(env.read(\RunAllState.total) == 1)
    }

    @Test("firstWins fire-and-forget duplicate starts nothing and waits for nothing")
    func firstWinsFireAndForgetDuplicateIsNoOp() async {
        let env = SharedEnvironment()
        let gate = HoldGate()

        async let first: Void = env.perform(HoldThenAdd(gate: gate, amount: 1))
        await gate.waitForArrival()
        fireAndForget(env, HoldThenAdd(gate: gate, amount: 10))
        gate.release()
        await first

        #expect(gate.arrivals == 1)
        #expect(env.read(\RunAllState.total) == 1)
    }

    @Test("firstWins groups by Identity; different keys both run")
    func firstWinsDifferentKeysBothRun() async {
        let env = SharedEnvironment()
        let gate = OverlapGate()

        async let first: Void = env.perform(KeyedHoldThenAdd(key: "a", gate: gate, amount: 1))
        async let second: Void = env.perform(KeyedHoldThenAdd(key: "b", gate: gate, amount: 10))
        await first
        await second

        #expect(env.read(\RunAllState.total) == 11)
    }

    @Test("firstWins groups by Operation type plus Identity; two types do not Join")
    func firstWinsDifferentTypesDoNotJoin() async {
        let env = SharedEnvironment()
        let gate = OverlapGate()

        async let first: Void = env.perform(KeyedHoldThenAdd(key: "x", gate: gate, amount: 1))
        async let second: Void = env.perform(OtherKeyedHoldThenAdd(key: "x", gate: gate, amount: 10))
        await first
        await second

        #expect(env.read(\RunAllState.total) == 11)
    }
}

struct KeyedHoldThenAdd: AsyncOperation {
    var reentrancy: ReentrancyDecision { .firstWins(.key(key)) }
    let key: String
    let gate: OverlapGate
    let amount: Int

    func perform(in env: AsyncOperationEnvironment) async {
        await gate.waitUntilGroup(2)
        env.perform(AddToTotal(amount: amount))
    }
}

struct OtherKeyedHoldThenAdd: AsyncOperation {
    var reentrancy: ReentrancyDecision { .firstWins(.key(key)) }
    let key: String
    let gate: OverlapGate
    let amount: Int

    func perform(in env: AsyncOperationEnvironment) async {
        await gate.waitUntilGroup(2)
        env.perform(AddToTotal(amount: amount))
    }
}

@MainActor
private func fireAndForget(_ env: SharedEnvironment, _ operation: AsyncOperation) {
    env.perform(operation)
}

struct NewestWinsHoldThenAdd: AsyncOperation {
    var reentrancy: ReentrancyDecision { .newestWins(.wholeOperation) }
    let gate: HoldGate
    let amount: Int
    let probe: CancelProbe?

    init(gate: HoldGate, amount: Int, probe: CancelProbe? = nil) {
        self.gate = gate
        self.amount = amount
        self.probe = probe
    }

    func perform(in env: AsyncOperationEnvironment) async {
        await gate.holdHere()
        if Task.isCancelled {
            probe?.sawCancel = true
        }
        env.perform(AddToTotal(amount: amount))
        probe?.bodiesFinished += 1
    }
}

@MainActor
final class CancelProbe {
    var sawCancel = false
    var bodiesFinished = 0
}

struct CommitThenHoldThenAdd: AsyncOperation {
    var reentrancy: ReentrancyDecision { .newestWins(.wholeOperation) }
    let gate: HoldGate
    let committed: Int
    let later: Int

    func perform(in env: AsyncOperationEnvironment) async {
        env.perform(AddToTotal(amount: committed))
        await gate.holdHere()
        env.perform(AddToTotal(amount: later))
    }
}

struct NestedChildAdd: AsyncOperation {
    var reentrancy: ReentrancyDecision { .runAll }
    let amount: Int

    func perform(in env: AsyncOperationEnvironment) async {
        env.perform(AddToTotal(amount: amount))
    }
}

struct NewestWinsThenNest: AsyncOperation {
    var reentrancy: ReentrancyDecision { .newestWins(.wholeOperation) }
    let gate: HoldGate
    let nestedAmount: Int

    func perform(in env: AsyncOperationEnvironment) async {
        await gate.holdHere()
        startWithoutWaiting(NestedChildAdd(amount: nestedAmount), on: env)
    }
}

struct PolicyHoldThenAdd: AsyncOperation {
    var reentrancy: ReentrancyDecision
    let gate: HoldGate
    let amount: Int

    func perform(in env: AsyncOperationEnvironment) async {
        await gate.holdHere()
        env.perform(AddToTotal(amount: amount))
    }
}

@Suite(.serialized) @MainActor
struct ReentrancyNewestWinsTests {

    @Test("newestWins discards the cancelled Execution's Sync write")
    func newestWinsDiscardsCancelledWrite() async {
        let env = SharedEnvironment()
        let gate = HoldGate()

        async let first: Void = env.perform(NewestWinsHoldThenAdd(gate: gate, amount: 1))
        await gate.waitForArrival()
        async let second: Void = env.perform(NewestWinsHoldThenAdd(gate: gate, amount: 10))
        await gate.waitUntilArrivals(2)
        gate.release()
        await first
        await second

        #expect(env.read(\RunAllState.total) == 10)
    }

    @Test("newestWins moves awaiters onto the new live Execution")
    func newestWinsMovesAwaitersToLiveExecution() async {
        let env = SharedEnvironment()
        let firstGate = HoldGate()
        let secondGate = HoldGate()
        let dying = CancelProbe()

        async let first: Void = env.perform(
            NewestWinsHoldThenAdd(gate: firstGate, amount: 1, probe: dying)
        )
        await firstGate.waitForArrival()
        async let second: Void = env.perform(NewestWinsHoldThenAdd(gate: secondGate, amount: 10))
        await secondGate.waitForArrival()
        secondGate.release()
        await first
        await second

        #expect(env.read(\RunAllState.total) == 10)
        #expect(dying.bodiesFinished == 0)

        firstGate.release()
        while dying.bodiesFinished < 1 {
            await Task.yield()
        }
        #expect(env.read(\RunAllState.total) == 10)
        #expect(dying.sawCancel)
    }

    @Test("a committed Sync child of a cancelled Execution stays committed")
    func cancelledExecutionKeepsCommittedChild() async {
        let env = SharedEnvironment()
        let gate = HoldGate()

        async let first: Void = env.perform(
            CommitThenHoldThenAdd(gate: gate, committed: 1, later: 10)
        )
        await gate.waitForArrival()
        #expect(env.read(\RunAllState.total) == 1)

        async let second: Void = env.perform(
            CommitThenHoldThenAdd(gate: gate, committed: 100, later: 1000)
        )
        await gate.waitUntilArrivals(2)
        gate.release()
        await first
        await second

        #expect(env.read(\RunAllState.total) == 1101)
    }

    @Test("incoming reentrancy decides when two instances disagree for one Identity")
    func incomingPolicyDecides() async {
        let env = SharedEnvironment()
        let gate = HoldGate()

        async let first: Void = env.perform(
            PolicyHoldThenAdd(
                reentrancy: .firstWins(.wholeOperation),
                gate: gate,
                amount: 1
            )
        )
        await gate.waitForArrival()
        async let second: Void = env.perform(
            PolicyHoldThenAdd(
                reentrancy: .newestWins(.wholeOperation),
                gate: gate,
                amount: 10
            )
        )
        await gate.waitUntilArrivals(2)
        gate.release()
        await first
        await second

        #expect(env.read(\RunAllState.total) == 10)
    }

    @Test("a cancelled Execution can still start a nested async perform")
    func cancelledExecutionNestedAsyncStillStarts() async {
        let env = SharedEnvironment()
        let gate = HoldGate()

        async let first: Void = env.perform(NewestWinsThenNest(gate: gate, nestedAmount: 5))
        await gate.waitForArrival()
        async let second: Void = env.perform(NewestWinsHoldThenAdd(gate: gate, amount: 10))
        await gate.waitUntilArrivals(2)
        gate.release()
        await first
        await second

        while env.read(\RunAllState.total) < 15 {
            await Task.yield()
        }
        #expect(env.read(\RunAllState.total) == 15)
    }
}
