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

final class ResetBox: StateContainer {
    var counter: Int = 0
}

final class ResetOtherBox: StateContainer {
    var label: String = "seed"
}

struct SetResetCounter: SyncOperation {
    let value: Int
    func perform(in env: SyncOperationEnvironment) {
        env.write(value, keyPath: \ResetBox.counter)
    }
}

struct SetResetLabel: SyncOperation {
    let value: String
    func perform(in env: SyncOperationEnvironment) {
        env.write(value, keyPath: \ResetOtherBox.label)
    }
}

struct ResetAll: SyncOperation {
    func perform(in env: SyncOperationEnvironment) {
        env.reset()
    }
}

struct ResetCounterBox: SyncOperation {
    func perform(in env: SyncOperationEnvironment) {
        env.reset(ResetBox.self)
    }
}

@Suite @MainActor
struct ResetTests {

    @Test("reset() drops container values so a later read is the seed")
    func resetDropsContainerValues() {
        let env = SharedEnvironment()
        env.perform(SetResetCounter(value: 9))
        #expect(env.read(\ResetBox.counter) == 9)

        env.perform(ResetAll())

        #expect(env.read(\ResetBox.counter) == 0)
    }

    @Test("reset(_:) drops only that Container")
    func resetDropsOnlyNamedContainer() {
        let env = SharedEnvironment()
        env.perform(SetResetCounter(value: 9))
        env.perform(SetResetLabel(value: "kept"))

        env.perform(ResetCounterBox())

        #expect(env.read(\ResetBox.counter) == 0)
        #expect(env.read(\ResetOtherBox.label) == "kept")
    }

    @Test("A Watcher re-reads empty State after reset()")
    func watcherRereadsEmptyState() {
        let env = SharedEnvironment()
        let probe = ValueObserverProbe.watch(\ResetBox.counter, in: env)
        probe.perform(SetResetCounter(value: 9))
        probe.expect(value: 9)

        probe.perform(ResetAll())

        probe.expect(value: 0)
        probe.expect(updates: 2)
    }

    @Test("Writes after reset() in the same Operation land on the new Container")
    func writesAfterResetLand() {
        let env = SharedEnvironment()
        env.perform(SetResetCounter(value: 9))

        env.perform(ResetThenWriteCounter(value: 3))

        #expect(env.read(\ResetBox.counter) == 3)
    }
}

struct ResetThenWriteCounter: SyncOperation {
    let value: Int
    func perform(in env: SyncOperationEnvironment) {
        env.reset()
        env.write(value, keyPath: \ResetBox.counter)
    }
}

@MainActor
final class ResetProbeService: EnvironmentService {
    var serveCount = 0
    var waiter = Waiter(expectedCount: 1)

    override func serve() async {
        _ = getValue(\ResetBox.counter)
        serveCount += 1
        await waiter.resume()
    }
}

@Suite @MainActor
struct ResetServiceTests {

    @Test("reset() drops the Service; the next spawn is a new instance")
    func resetDropsService() async {
        let env = SharedEnvironment()
        let first = await env.spawnService(ResetProbeService.self)
        env.perform(ResetAll())
        let second = await env.spawnService(ResetProbeService.self)
        #expect(first !== second)
    }

    @Test("A dropped Service cannot write State back")
    func droppedServiceWritesAreNoops() async {
        let env = SharedEnvironment()
        let service = await env.spawnService(ResetProbeService.self)
        env.perform(SetResetCounter(value: 9))
        env.perform(ResetAll())

        service.setValue(99, keyPath: \ResetBox.counter)
        service.perform(SetResetCounter(value: 77))

        #expect(env.read(\ResetBox.counter) == 0)
    }

    @Test("reset(_:) keeps Services; they re-read empty State")
    func targetedResetKeepsService() async throws {
        let env = SharedEnvironment()
        let service = await env.spawnService(ResetProbeService.self)
        #expect(service.serveCount == 1)

        service.waiter = Waiter(expectedCount: 1)
        env.perform(SetResetCounter(value: 9))
        try await service.waiter.wait()

        service.waiter = Waiter(expectedCount: 1)
        env.perform(ResetCounterBox())
        try await service.waiter.wait()

        let again = await env.spawnService(ResetProbeService.self)
        #expect(again === service)
        #expect(service.serveCount == 3)
        #expect(env.read(\ResetBox.counter) == 0)
    }
}

@Suite @MainActor
struct ResetExecutionTests {

    @Test("reset() Cancels an in-flight Execution so its later write does not land")
    func resetCancelsInFlightExecution() async {
        let env = SharedEnvironment()
        let gate = HoldGate()
        async let hung: Void = env.perform(HoldThenSetResetCounter(gate: gate, value: 9))
        await gate.waitForArrival()

        env.perform(ResetAll())
        gate.release()
        await hung

        #expect(env.read(\ResetBox.counter) == 0)
    }

    @Test("reset(_:) Cancels in-flight Executions even when that Container is not the write target")
    func targetedResetCancelsExecutions() async {
        let env = SharedEnvironment()
        let gate = HoldGate()
        async let hung: Void = env.perform(HoldThenSetResetCounter(gate: gate, value: 9))
        await gate.waitForArrival()

        env.perform(ResetCounterBox())
        gate.release()
        await hung

        #expect(env.read(\ResetBox.counter) == 0)
    }

    @Test("A cancelled awaiter resumes success after the body exits")
    func cancelledAwaiterResumesSuccessWhenBodyExits() async {
        let env = SharedEnvironment()
        let gate = HoldGate()
        let task = Task { @MainActor in
            await env.perform(HoldThenSetResetCounter(gate: gate, value: 9))
        }
        await gate.waitForArrival()

        env.perform(ResetAll())
        gate.release()
        await task.value

        #expect(env.read(\ResetBox.counter) == 0)
    }

    @Test("A Sync child after reset() in the same Async Operation is discarded")
    func resetCancelsParentExecution() async {
        let env = SharedEnvironment()
        await env.perform(ResetThenSetResetCounter(value: 9))
        #expect(env.read(\ResetBox.counter) == 0)
    }
}

struct HoldThenSetResetCounter: AsyncOperation {
    var reentrancy: ReentrancyDecision { .firstWins(.wholeOperation) }
    let gate: HoldGate
    let value: Int

    func perform(in env: AsyncOperationEnvironment) async {
        await gate.holdHere()
        env.perform(SetResetCounter(value: value))
    }
}

struct ResetThenSetResetCounter: AsyncOperation {
    var reentrancy: ReentrancyDecision { .runAll }
    let value: Int

    func perform(in env: AsyncOperationEnvironment) async {
        env.perform(ResetAll())
        env.perform(SetResetCounter(value: value))
    }
}

final class ResetSourcedBox: StateContainer {
    @AsyncState(ResetSource.self) var theme: String = "system"
}

@MainActor
final class ResetSource: Source {
    typealias Failure = Never
    let sourceUpdate = SourceUpdate.write
    private(set) var droppedCount = 0

    init() {}

    func provide<Storage: StateContainer, Value>(
        _ keyPath: KeyPath<Storage, Value>,
        policy _: Void,
        in env: SourceEnvironment
    ) {}

    func dropped<Storage: StateContainer, Value>(
        _ keyPath: KeyPath<Storage, Value>,
        policy _: Void
    ) {
        droppedCount += 1
    }
}

struct ResetSourced: SyncOperation {
    func perform(in env: SyncOperationEnvironment) {
        env.reset(ResetSourcedBox.self)
    }
}

@Suite @MainActor
struct ResetSourceTests {

    @Test("reset(_:) calls dropped on the bound Address and keeps the Source")
    func targetedResetCallsDropped() {
        let env = SharedEnvironment()
        let source = ResetSource()
        env.install(source)
        env.preheat(\ResetSourcedBox.theme)
        #expect(source.droppedCount == 0)

        env.perform(ResetSourced())

        #expect(source.droppedCount == 1)
        #expect(env.sourceInstance(ResetSource.self) === source)
    }

    @Test("reset() calls dropped and drops the Source instance")
    func fullResetDropsSourceInstance() {
        let env = SharedEnvironment()
        let source = ResetSource()
        env.install(source)
        env.preheat(\ResetSourcedBox.theme)

        env.perform(ResetAll())

        #expect(source.droppedCount == 1)
        #expect(env.sourceInstance(ResetSource.self) !== source)
    }
}
