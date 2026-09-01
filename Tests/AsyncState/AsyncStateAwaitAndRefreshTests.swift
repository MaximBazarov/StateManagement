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
#if canImport(SwiftUI)
import SwiftUI
#endif
@testable import StateManagement

// MARK: - Fixtures

/// What an Operation's awaitable read produced, so the test can assert from outside the Task.
@MainActor
final class ReadResult<Output> {
    var started = false
    var finished = false
    var value: Output?
}

/// Awaits the sourced Value through the public `AsyncOperationEnvironment` surface.
struct ReadTheme: ThrowingAsyncOperation {
    typealias Failure = MockFailure
    let result: ReadResult<String>
    var reentrancy: ReentrancyDecision { .runAll }

    func perform(in env: AsyncOperationEnvironment) async throws(MockFailure) {
        result.started = true
        let value = try await env.read(\AsyncBox.$theme)
        result.value = value
        result.finished = true
    }
}

/// Awaits one key of a keyed sourced Address.
struct ReadDone: ThrowingAsyncOperation {
    typealias Failure = MockFailure
    let key: String
    let result: ReadResult<Bool>
    var reentrancy: ReentrancyDecision { .runAll }

    func perform(in env: AsyncOperationEnvironment) async throws(MockFailure) {
        result.started = true
        let value = try await env.read(\AsyncBox.$done, key: key)
        result.value = value
        result.finished = true
    }
}

/// The strategy applies inside `onRead`, so the awaitable read never really suspends.
struct ReadApplyingTheme: ThrowingAsyncOperation {
    typealias Failure = MockFailure
    let result: ReadResult<String>
    var reentrancy: ReentrancyDecision { .runAll }

    func perform(in env: AsyncOperationEnvironment) async throws(MockFailure) {
        result.started = true
        result.value = try await env.read(\ApplyingBox.$theme)
        result.finished = true
    }
}

/// Fails inbound on every `onRead`.
@MainActor
final class FailingStrategy: AsyncStrategy {
    typealias Failure = MockFailure
    let env: AsyncStrategyEnvironment
    private(set) var onReadCount = 0

    init(env: AsyncStrategyEnvironment) {
        self.env = env
    }

    func onRead<Storage: StateContainer, Value, Status>(
        _ keyPath: KeyPath<Storage, AsyncState<FailingStrategy, Value, Status>>,
        policy _: Void,
        current _: Value
    ) {
        onReadCount += 1
        env.fail(MockFailure.boom, keyPath: keyPath)
    }
}

final class FailingBox: StateContainer {
    @AsyncState(FailingStrategy.self) var theme: String = "system"
}

struct ReadFailingTheme: ThrowingAsyncOperation {
    typealias Failure = MockFailure
    let result: ReadResult<String>
    var reentrancy: ReentrancyDecision { .runAll }

    func perform(in env: AsyncOperationEnvironment) async throws(MockFailure) {
        result.started = true
        result.value = try await env.read(\FailingBox.$theme)
        result.finished = true
    }
}

/// `onRead` kicks a `firstWins` load Operation, so a second kick Joins instead of starting again.
@MainActor
final class LoadingStrategy: AsyncStrategy {
    typealias Failure = MockFailure
    let env: AsyncStrategyEnvironment
    private(set) var onReadCount = 0
    var executionCount = 0

    init(env: AsyncStrategyEnvironment) {
        self.env = env
    }

    func onRead<Storage: StateContainer, Value, Status>(
        _ keyPath: KeyPath<Storage, AsyncState<LoadingStrategy, Value, Status>>,
        policy _: Void,
        current _: Value
    ) {
        onReadCount += 1
        env.perform(CountedLoad(strategy: self))
    }
}

struct CountedLoad: AsyncOperation {
    let strategy: LoadingStrategy
    var reentrancy: ReentrancyDecision { .firstWins(.wholeOperation) }

    func perform(in env: AsyncOperationEnvironment) async {
        strategy.executionCount += 1
    }
}

final class LoadingBox: StateContainer {
    @AsyncState(LoadingStrategy.self) var theme: String = "system"
}

final class PlainBox: StateContainer {
    var count = 0
}

/// Reads the sourced Address as a Service: subscribes, then awaits.
@MainActor
final class ThemeReadingService: EnvironmentService {
    var serveCount = 0
    var seen: [String] = []

    override func serve() async {
        serveCount += 1
        if let value = try? await read(\AsyncBox.$theme) {
            seen.append(value)
        }
    }
}

/// Drops every Container while an awaitable read is suspended.
struct ResetEverything: SyncOperation {
    func perform(in env: SyncOperationEnvironment) {
        env.reset()
    }
}

extension SharedEnvironment {
    /// Installs the strategy up front so the test can assert on the instance the Environment uses.
    fileprivate func strategyUnderTest<S: AsyncStrategy>(_ type: S.Type) -> S {
        let created = S(env: strategyEnvironment())
        install(created)
        return created
    }
}

// MARK: - Awaitable read

@Suite @MainActor
struct AwaitableSourcedReadTests {

    @Test("Pending $ read waits for apply, then returns the Value and settles")
    func pendingReadWaitsForApply() async throws {
        let env = SharedEnvironment()
        let strategy = env.strategyUnderTest(MockStrategy.self)
        let result = ReadResult<String>()

        let task = Task { @MainActor in try await env.perform(ReadTheme(result: result)) }
        #expect(await waitUntil { strategy.onReadCount == 1 })
        #expect(result.finished == false)

        strategy.env.apply("dark", keyPath: \AsyncBox.$theme)
        try await task.value

        #expect(result.value == "dark")
        #expect(env.read(\AsyncBox.$theme.status) == SourceStatus<MockFailure>.settled)
    }

    @Test("Settled $ read returns without calling onRead again")
    func settledReadIsACacheHit() async throws {
        let env = SharedEnvironment()
        let strategy = env.strategyUnderTest(MockStrategy.self)
        _ = env.read(\AsyncBox.theme)
        strategy.env.apply("dark", keyPath: \AsyncBox.$theme)

        let result = ReadResult<String>()
        try await env.perform(ReadTheme(result: result))

        #expect(result.value == "dark")
        #expect(strategy.onReadCount == 1)
    }

    @Test("After refresh the $ read waits for the reload")
    func dirtyReadWaitsForTheReload() async throws {
        let env = SharedEnvironment()
        let strategy = env.strategyUnderTest(MockStrategy.self)
        _ = env.read(\AsyncBox.theme)
        strategy.env.apply("dark", keyPath: \AsyncBox.$theme)
        env.read(\AsyncBox.$theme).refresh()

        let result = ReadResult<String>()
        let task = Task { @MainActor in try await env.perform(ReadTheme(result: result)) }
        // The kick from `refresh`, then the kick from this dirty read.
        #expect(await waitUntil { strategy.onReadCount == 3 })
        #expect(result.finished == false)

        strategy.env.apply("light", keyPath: \AsyncBox.$theme)
        try await task.value

        #expect(result.value == "light")
    }

    @Test("Error status throws the stored Failure and leaves the Value alone")
    func errorStatusThrows() async throws {
        let env = SharedEnvironment()
        env.strategyUnderTest(FailingStrategy.self)
        let result = ReadResult<String>()

        await #expect(throws: MockFailure.boom) {
            try await env.perform(ReadFailingTheme(result: result))
        }

        #expect(result.finished == false)
        #expect(env.read(\FailingBox.theme) == "system")
    }

    @Test("fail while the read is suspended throws to the waiter")
    func failResumesTheWaiterByThrowing() async throws {
        let env = SharedEnvironment()
        let strategy = env.strategyUnderTest(MockStrategy.self)
        let result = ReadResult<String>()

        let task = Task { @MainActor in try await env.perform(ReadTheme(result: result)) }
        #expect(await waitUntil { strategy.onReadCount == 1 })

        strategy.env.fail(MockFailure.boom, keyPath: \AsyncBox.$theme)

        await #expect(throws: MockFailure.boom) { try await task.value }
        #expect(result.finished == false)
    }

    @Test("Two $ reads of one Address Join one onRead and both resume from one apply")
    func concurrentReadsJoinOneLoad() async throws {
        let env = SharedEnvironment()
        let strategy = env.strategyUnderTest(MockStrategy.self)
        let first = ReadResult<String>()
        let second = ReadResult<String>()

        let taskA = Task { @MainActor in try await env.perform(ReadTheme(result: first)) }
        #expect(await waitUntil { strategy.onReadCount == 1 })
        let taskB = Task { @MainActor in try await env.perform(ReadTheme(result: second)) }
        #expect(await waitUntil { second.started })

        strategy.env.apply("dark", keyPath: \AsyncBox.$theme)
        try await taskA.value
        try await taskB.value

        #expect(first.value == "dark")
        #expect(second.value == "dark")
        #expect(strategy.onReadCount == 1)
    }

    @Test("Sync read returns the seed while the $ read of the same Address still waits")
    func syncReadDoesNotEndTheWait() async throws {
        let env = SharedEnvironment()
        let strategy = env.strategyUnderTest(MockStrategy.self)
        let result = ReadResult<String>()

        let task = Task { @MainActor in try await env.perform(ReadTheme(result: result)) }
        #expect(await waitUntil { strategy.onReadCount == 1 })

        #expect(env.read(\AsyncBox.theme) == "system")
        #expect(result.finished == false)
        #expect(strategy.onReadCount == 1)

        strategy.env.apply("dark", keyPath: \AsyncBox.$theme)
        try await task.value
        #expect(result.value == "dark")
    }

    @Test("The apply that ends the wait notifies Watches of the Value and the status")
    func applyNotifiesWatches() async throws {
        let env = SharedEnvironment()
        let strategy = env.strategyUnderTest(MockStrategy.self)
        let value = ValueObserverProbe.watch(\AsyncBox.theme, in: env)
        let status = ValueObserverProbe.watch(\AsyncBox.$theme.status, in: env)

        let result = ReadResult<String>()
        let task = Task { @MainActor in try await env.perform(ReadTheme(result: result)) }
        #expect(await waitUntil { result.started })

        strategy.env.apply("dark", keyPath: \AsyncBox.$theme)
        try await task.value

        value.expect(value: "dark")
        status.expect(value: SourceStatus<MockFailure>.settled)
    }

    @Test("An Operation $ read leaves no receiver behind")
    func operationReadLeavesNoReceiver() async throws {
        let env = SharedEnvironment()
        let strategy = env.strategyUnderTest(MockStrategy.self)
        let result = ReadResult<String>()

        let task = Task { @MainActor in try await env.perform(ReadTheme(result: result)) }
        #expect(await waitUntil { strategy.onReadCount == 1 })
        strategy.env.apply("dark", keyPath: \AsyncBox.$theme)
        try await task.value

        let subscribed = env.observation.subscribedValueIDs
        #expect(!subscribed.contains(ValueID(keyPath: \AsyncBox.$theme)))
        #expect(!subscribed.contains(ValueID(keyPath: \AsyncBox.$theme)))
    }

    @Test("A Service $ read stays subscribed, so the apply that resumes it also serves again")
    func serviceReadSubscribesAndFollows() async throws {
        let env = SharedEnvironment()
        let strategy = env.strategyUnderTest(MockStrategy.self)
        let service = ThemeReadingService(env: env)

        service.startServing()
        #expect(await waitUntil { strategy.onReadCount == 1 })
        #expect(service.serveCount == 1)
        #expect(service.seen.isEmpty)

        strategy.env.apply("dark", keyPath: \AsyncBox.$theme)

        #expect(await waitUntil { service.serveCount == 2 })
        #expect(await waitUntil { service.seen == ["dark", "dark"] })
    }

    @Test("A sync apply inside onRead returns from the $ read with no real suspend")
    func syncApplyInsideOnReadNeedsNoWait() async throws {
        let env = SharedEnvironment()
        env.install(ApplyingStrategy(env: env.strategyEnvironment()))
        let result = ReadResult<String>()

        try await env.perform(ReadApplyingTheme(result: result))

        #expect(result.value == "dark")
    }

    @Test("reset while the $ read is suspended resumes it with the current Value and does not throw")
    func resetReleasesTheWaiter() async throws {
        let env = SharedEnvironment()
        let strategy = env.strategyUnderTest(MockStrategy.self)
        let result = ReadResult<String>()

        let task = Task { @MainActor in try await env.perform(ReadTheme(result: result)) }
        #expect(await waitUntil { strategy.onReadCount == 1 })

        env.perform(ResetEverything())
        try await task.value

        #expect(result.value == "system")
        #expect(result.finished)
    }

    @Test("SharedEnvironment reads the $ Address synchronously and offers no awaitable overload")
    func sharedEnvironmentHasNoAwaitableRead() {
        let env = SharedEnvironment()
        env.strategyUnderTest(MockStrategy.self)

        // The only `read` of a `$` Address here is this synchronous one, which hands back the
        // wrapper. The awaitable read lives on `AsyncOperationEnvironment` and `EnvironmentService`.
        let wrapper = env.read(\AsyncBox.$theme)

        #expect(wrapper.status == SourceStatus<MockFailure>.pending)
    }
}

// MARK: - Keyed

@Suite @MainActor
struct KeyedSourcedAwaitTests {

    @Test("Keyed $ read waits for the apply of its own key")
    func keyedReadWaitsForItsKey() async throws {
        let env = SharedEnvironment()
        let strategy = env.strategyUnderTest(MockStrategy.self)
        let result = ReadResult<Bool>()

        let task = Task { @MainActor in try await env.perform(ReadDone(key: "a", result: result)) }
        #expect(await waitUntil { strategy.keyedOnReadCount == 1 })

        strategy.env.apply(true, keyPath: \AsyncBox.$done, key: "a")
        try await task.value

        #expect(result.value == true)
    }

    @Test("Another key's apply does not resume a waiter")
    func keyedWaitersAreIsolated() async throws {
        let env = SharedEnvironment()
        let strategy = env.strategyUnderTest(MockStrategy.self)
        let result = ReadResult<Bool>()

        let task = Task { @MainActor in try await env.perform(ReadDone(key: "a", result: result)) }
        #expect(await waitUntil { strategy.keyedOnReadCount == 1 })

        strategy.env.apply(true, keyPath: \AsyncBox.$done, key: "b")
        // Bounded poll: the waiter must still be suspended, so this must time out.
        #expect(await waitUntil(timeout: .milliseconds(100)) { result.finished } == false)

        strategy.env.apply(false, keyPath: \AsyncBox.$done, key: "a")
        try await task.value

        #expect(result.value == false)
    }

    @Test("refresh(key:) kicks onRead for that key only")
    func keyedRefreshKicksItsKey() {
        let env = SharedEnvironment()
        let strategy = env.strategyUnderTest(MockStrategy.self)
        _ = env.read(\AsyncBox.done, key: "a")
        #expect(strategy.keyedOnReadCount == 1)

        env.read(\AsyncBox.$done).refresh(key: "a")

        #expect(strategy.keyedOnReadCount == 2)
    }

    @Test("refresh() with no key on a keyed Address is a no-op")
    func keyedRefreshWithoutKeyIsANoOp() {
        let env = SharedEnvironment()
        let strategy = env.strategyUnderTest(MockStrategy.self)
        _ = env.read(\AsyncBox.done, key: "a")

        env.read(\AsyncBox.$done).refresh()

        #expect(strategy.keyedOnReadCount == 1)
    }
}

// MARK: - Refresh

@Suite @MainActor
struct SourcedRefreshTests {

    @Test("AsyncState.refresh() calls onRead again and leaves the status alone")
    func refreshKicksAndKeepsStatus() {
        let env = SharedEnvironment()
        let strategy = env.strategyUnderTest(MockStrategy.self)
        _ = env.read(\AsyncBox.theme)
        strategy.env.apply("dark", keyPath: \AsyncBox.$theme)

        env.read(\AsyncBox.$theme).refresh()

        #expect(strategy.onReadCount == 2)
        #expect(env.read(\AsyncBox.$theme.status) == SourceStatus<MockFailure>.settled)
        #expect(env.read(\AsyncBox.theme) == "dark")
    }

    @Test("refresh() before the Address was read is a no-op")
    func refreshBeforeBindIsANoOp() {
        let env = SharedEnvironment()
        let strategy = env.strategyUnderTest(MockStrategy.self)

        let unbound = AsyncState(wrappedValue: "system", MockStrategy.self)
        unbound.refresh()

        #expect(strategy.onReadCount == 0)
    }

    @Test("refresh() of an Address with no AsyncStrategy is a no-op")
    func refreshOfPlainAddressIsANoOp() {
        let env = SharedEnvironment()
        let strategy = env.strategyUnderTest(MockStrategy.self)
        _ = env.read(\PlainBox.count)

        env.refreshAddress(valueID: ValueID(keyPath: \PlainBox.count))

        #expect(strategy.onReadCount == 0)
    }

    @Test("Two refreshes call onRead twice and a firstWins load starts one Execution")
    func doubleRefreshCoalescesInTheStrategy() async throws {
        let env = SharedEnvironment()
        let strategy = env.strategyUnderTest(LoadingStrategy.self)
        let wrapper = env.read(\LoadingBox.$theme)
        #expect(strategy.onReadCount == 1)

        wrapper.refresh()
        wrapper.refresh()

        #expect(strategy.onReadCount == 3)
        #expect(await waitUntil { strategy.executionCount == 1 })
        // The three kicks share one Identity, so the later ones Join instead of starting.
        #expect(strategy.executionCount == 1)
    }
}
