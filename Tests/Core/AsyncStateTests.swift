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

enum MockFailure: Error, Equatable {
    case boom
}

@MainActor
final class MockStrategy: AsyncStrategy {
    typealias Failure = MockFailure

    let env: AsyncStrategyEnvironment
    private(set) var onReadCount = 0
    private(set) var keyedOnReadCount = 0
    private(set) var onWriteCount = 0
    private(set) var lastCurrent: Any?
    private(set) var lastWritten: Any?

    init(env: AsyncStrategyEnvironment) {
        self.env = env
    }

    func onRead<Storage: StateContainer, Value, Status>(
        _ keyPath: KeyPath<Storage, AsyncState<MockStrategy, Value, Status>>,
        policy _: Void,
        current: Value
    ) {
        onReadCount += 1
        lastCurrent = current
    }

    func onRead<Storage: StateContainer, Key: Hashable, Value, Status>(
        _ keyPath: KeyPath<Storage, AsyncState<MockStrategy, [Key: Value], Status>>,
        key: Key,
        policy _: Void,
        current: Value?
    ) {
        keyedOnReadCount += 1
        lastCurrent = current
    }

    func onWrite<Storage: StateContainer, Value, Status>(
        _ value: Value,
        _ keyPath: KeyPath<Storage, AsyncState<MockStrategy, Value, Status>>,
        policy _: Void
    ) {
        onWriteCount += 1
        lastWritten = value
    }

    func onWrite<Storage: StateContainer, Key: Hashable, Value, Status>(
        _ value: Value,
        _ keyPath: KeyPath<Storage, AsyncState<MockStrategy, [Key: Value], Status>>,
        key: Key,
        policy _: Void
    ) {
        onWriteCount += 1
        lastWritten = value
    }
}

@MainActor
final class ApplyingStrategy: AsyncStrategy {
    typealias Failure = MockFailure

    let env: AsyncStrategyEnvironment

    init(env: AsyncStrategyEnvironment) {
        self.env = env
    }

    func onRead<Storage: StateContainer, Value, Status>(
        _ keyPath: KeyPath<Storage, AsyncState<ApplyingStrategy, Value, Status>>,
        policy _: Void,
        current: Value
    ) {
        guard let value = "dark" as? Value else { return }
        env.apply(value, keyPath: keyPath)
    }

    func onRead<Storage: StateContainer, Key: Hashable, Value, Status>(
        _ keyPath: KeyPath<Storage, AsyncState<ApplyingStrategy, [Key: Value], Status>>,
        key: Key,
        policy _: Void,
        current: Value?
    ) {
        guard let value = true as? Value else { return }
        env.apply(value, keyPath: keyPath, key: key)
    }
}

final class AsyncBox: StateContainer {
    @AsyncState(MockStrategy.self) var theme: String = "system"
    @AsyncState(MockStrategy.self) var title: String = "untitled"
    @AsyncState(MockStrategy.self) var profile: String? = nil
    @AsyncState(MockStrategy.self) var done: [String: Bool] = [:]
}

final class ApplyingBox: StateContainer {
    @AsyncState(ApplyingStrategy.self) var theme: String = "system"
}

final class NestedWriteBox: StateContainer {
    var count = 0
}

struct WriteNestedCount: SyncOperation {
    func perform(in env: SyncOperationEnvironment) {
        env.write(\NestedWriteBox.count, value: 99)
    }
}

@MainActor
final class NestedPerformStrategy: AsyncStrategy {
    typealias Failure = Never

    let env: AsyncStrategyEnvironment

    init(env: AsyncStrategyEnvironment) {
        self.env = env
    }

    func onRead<Storage: StateContainer, Value, Status>(
        _ keyPath: KeyPath<Storage, AsyncState<NestedPerformStrategy, Value, Status>>,
        policy _: Void,
        current: Value
    ) {
        env.perform(WriteNestedCount())
    }
}

final class NestedPerformBox: StateContainer {
    @AsyncState(NestedPerformStrategy.self) var theme: String = "system"
}

final class ApplyingKeyedBox: StateContainer {
    @AsyncState(ApplyingStrategy.self) var done: [String: Bool] = [:]
}

final class ApplyingComputedBox: StateContainer {
    @AsyncState(ApplyingStrategy.self) var theme: String = "system"
    @Computed var labeled = { (env: ComputationEnvironment) -> String in
        env.read(\ApplyingComputedBox.theme)
    }
}

/// `onRead` of any Address applies `theme`, so a first read of `title` notifies an already-subscribed Watch of `theme`.
@MainActor
final class CrossApplyStrategy: AsyncStrategy {
    typealias Failure = Never
    let env: AsyncStrategyEnvironment
    private(set) var onReadCount = 0

    init(env: AsyncStrategyEnvironment) {
        self.env = env
    }

    func onRead<Storage: StateContainer, Value, Status>(
        _ keyPath: KeyPath<Storage, AsyncState<CrossApplyStrategy, Value, Status>>,
        policy _: Void,
        current: Value
    ) {
        onReadCount += 1
        let value = onReadCount == 1 ? "dark" : "light"
        env.apply(value, keyPath: \CrossApplyBox.$theme)
    }
}

final class CrossApplyBox: StateContainer {
    @AsyncState(CrossApplyStrategy.self) var theme: String = "system"
    @AsyncState(CrossApplyStrategy.self) var title: String = "untitled"
}

@MainActor
final class ApplyingThemeService: EnvironmentService {
    private(set) var serveCount = 0
    private(set) var seen: [String] = []

    override func serve() async {
        serveCount += 1
        seen.append(read(\ApplyingBox.theme))
    }
}

@MainActor
final class ApplyingKeyedService: EnvironmentService {
    private(set) var serveCount = 0
    private(set) var seen: [Bool?] = []

    override func serve() async {
        serveCount += 1
        seen.append(read(\ApplyingKeyedBox.done, key: "a"))
    }
}

@MainActor
final class ApplyingComputedService: EnvironmentService {
    private(set) var serveCount = 0
    private(set) var seen: [String] = []

    override func serve() async {
        serveCount += 1
        seen.append(read(\ApplyingComputedBox.$labeled))
    }
}

struct NestedWriteThenApplyThenWrite: SyncOperation {
    let strategyEnv: AsyncStrategyEnvironment
    func perform(in env: SyncOperationEnvironment) {
        env.write(\NestedWriteBox.count, value: 1)
        strategyEnv.apply("dark", keyPath: \AsyncBox.$theme)
        env.write(\NestedWriteBox.count, value: 2)
    }
}

struct SetAsyncTheme: SyncOperation {
    let value: String
    func perform(in env: SyncOperationEnvironment) {
        env.write(\AsyncBox.theme, value: value)
    }
}

struct SetAsyncFlag: SyncOperation {
    func perform(in env: SyncOperationEnvironment) {
        env.write(\AsyncBox.done, key: "a", value: true)
    }
}

extension SharedEnvironment {
    fileprivate func installed<S: AsyncStrategy>(_ type: S.Type) -> S {
        let strategy = S(env: strategyEnvironment())
        install(strategy)
        return strategy
    }
}

@Suite @MainActor
struct AsyncStateStrategyTests {

    @Test("First Watch of the sourced Value calls onRead")
    func firstWatchOfValueReads() {
        let env = SharedEnvironment()
        let strategy = env.installed(MockStrategy.self)

        _ = ValueObserverProbe.watch(\AsyncBox.theme, in: env)

        #expect(strategy.onReadCount == 1)
    }

    @Test("AsyncStrategyEnvironment.environmentID is the Environment the strategy is bound to")
    func environmentIDMatchesTheEnvironment() {
        let envA = SharedEnvironment()
        let envB = SharedEnvironment()
        let strategyA = envA.installed(MockStrategy.self)
        let strategyB = envB.installed(MockStrategy.self)

        envA.preheat(\AsyncBox.theme)
        envB.preheat(\AsyncBox.theme)

        #expect(strategyA.env.environmentID == ObjectIdentifier(envA))
        #expect(strategyB.env.environmentID == ObjectIdentifier(envB))
        #expect(strategyA.env.environmentID != strategyB.env.environmentID)
    }

    @Test("First Watch of status calls onRead")
    func firstWatchOfStatusReads() {
        let env = SharedEnvironment()
        let strategy = env.installed(MockStrategy.self)

        _ = ValueObserverProbe.watch(\AsyncBox.$theme.status, in: env)

        #expect(strategy.onReadCount == 1)
    }

    @Test("Status-first onRead passes the sourced Address so apply writes the Value")
    func statusFirstOnReadPassesSourcedAddress() {
        let env = SharedEnvironment()
        env.install(ApplyingStrategy(env: env.strategyEnvironment()))

        let status = ValueObserverProbe.watch(\ApplyingBox.$theme.status, in: env)
        let value = ValueObserverProbe.watch(\ApplyingBox.theme, in: env)

        value.expect(value: "dark")
        status.expect(value: .settled)
    }

    @Test("Status-first onRead current is the sourced seed, not SourceStatus")
    func statusFirstOnReadCurrentIsSourcedValue() {
        let env = SharedEnvironment()
        let strategy = env.installed(MockStrategy.self)

        _ = ValueObserverProbe.watch(\AsyncBox.$theme.status, in: env)

        #expect(strategy.lastCurrent as? String == "system")
    }

    @Test("Preheat calls onRead with no Watch")
    func preheatReadsWithNoWatch() {
        let env = SharedEnvironment()
        let strategy = env.installed(MockStrategy.self)

        env.preheat(\AsyncBox.theme)

        #expect(strategy.onReadCount == 1)
    }

    @Test("A second Watch of the same Address does not onRead again")
    func secondWatchDoesNotReadAgain() {
        let env = SharedEnvironment()
        let strategy = env.installed(MockStrategy.self)

        _ = ValueObserverProbe.watch(\AsyncBox.theme, in: env)
        _ = ValueObserverProbe.watch(\AsyncBox.theme, in: env)

        #expect(strategy.onReadCount == 1)
    }

    @Test("Empty onRead leaves the seed and pending")
    func emptyOnReadDoesNotWriteSeed() {
        let env = SharedEnvironment()
        env.installed(MockStrategy.self)

        #expect(env.read(\AsyncBox.theme) == "system")
        #expect(env.read(\AsyncBox.$theme.status) == SourceStatus<MockFailure>.pending)
    }
}

@Suite @MainActor
struct AsyncStateApplyTests {

    @Test("Apply writes the Value and settled, and Watch sees both")
    func applyMakesValueAndSettledVisible() {
        let env = SharedEnvironment()
        let strategy = env.installed(MockStrategy.self)

        let value = ValueObserverProbe.watch(\AsyncBox.theme, in: env)
        let status = ValueObserverProbe.watch(\AsyncBox.$theme.status, in: env)
        value.expect(value: "system")
        status.expect(value: .pending)

        strategy.env.apply("dark", keyPath: \AsyncBox.$theme)

        value.expect(value: "dark")
        status.expect(value: .settled)
        value.expect(updates: 1)
        status.expect(updates: 1)
    }

    @Test("Fail writes error, leaves the Value, and clears dirty")
    func failLeavesValueAndSetsError() {
        let env = SharedEnvironment()
        let strategy = env.installed(MockStrategy.self)

        let value = ValueObserverProbe.watch(\AsyncBox.theme, in: env)
        let status = ValueObserverProbe.watch(\AsyncBox.$theme.status, in: env)
        strategy.env.apply("dark", keyPath: \AsyncBox.$theme)

        strategy.env.fail(MockFailure.boom, keyPath: \AsyncBox.$theme)

        value.expect(value: "dark")
        status.expect(value: .error(.boom))
    }

    @Test("restoreSeed writes the seed and pending")
    func restoreSeedRestoresSeedAndPending() {
        let env = SharedEnvironment()
        let strategy = env.installed(MockStrategy.self)

        let value = ValueObserverProbe.watch(\AsyncBox.theme, in: env)
        let status = ValueObserverProbe.watch(\AsyncBox.$theme.status, in: env)
        strategy.env.apply("dark", keyPath: \AsyncBox.$theme)

        strategy.env.restoreSeed(keyPath: \AsyncBox.$theme)

        value.expect(value: "system")
        status.expect(value: .pending)
    }

    @Test("Optional seed is nil and pending; settled plus nil is loaded empty")
    func optionalSeedAndLoadedEmpty() {
        let env = SharedEnvironment()
        let strategy = env.installed(MockStrategy.self)

        let value = ValueObserverProbe.watch(\AsyncBox.profile, in: env)
        let status = ValueObserverProbe.watch(\AsyncBox.$profile.status, in: env)
        value.expect(value: nil)
        status.expect(value: .pending)

        strategy.env.apply(Optional<String>.none, keyPath: \AsyncBox.$profile)

        value.expect(value: nil)
        status.expect(value: .settled)
    }

    @Test("restoreSeed does not call onDrop")
    func restoreSeedDoesNotCallOnDrop() {
        let env = SharedEnvironment()
        let strategy = env.installed(MockStrategy.self)

        let probe = ValueObserverProbe.watch(\AsyncBox.theme, in: env)
        strategy.env.apply("dark", keyPath: \AsyncBox.$theme)
        strategy.env.restoreSeed(keyPath: \AsyncBox.$theme)
        #expect(strategy.onReadCount == 1)

        strategy.env.apply("light", keyPath: \AsyncBox.$theme)
        probe.expect(value: "light")
        #expect(strategy.onReadCount == 1)
    }
}

@Suite @MainActor
struct AsyncStateStaleTests {

    @Test("Apply does not pull again; later reads do not onRead")
    func applyDoesNotPullAgain() {
        let env = SharedEnvironment()
        let strategy = env.installed(MockStrategy.self)

        let probe = ValueObserverProbe.watch(\AsyncBox.theme, in: env)
        #expect(strategy.onReadCount == 1)

        strategy.env.apply("dark", keyPath: \AsyncBox.$theme)
        probe.expect(value: "dark")

        _ = env.read(\AsyncBox.theme)
        #expect(strategy.onReadCount == 1)
    }

    @Test("markStale dirties and the next read calls onRead")
    func markStaleDirtiesAndNextReadPulls() {
        let env = SharedEnvironment()
        let strategy = env.installed(MockStrategy.self)

        let probe = ValueObserverProbe.watch(\AsyncBox.theme, in: env)
        strategy.env.apply("dark", keyPath: \AsyncBox.$theme)
        #expect(strategy.onReadCount == 1)

        strategy.env.markStale(keyPath: \AsyncBox.$theme)
        #expect(strategy.onReadCount == 2)
        probe.expect(value: "dark")
    }

    @Test("markStale with no Watchers dirties only")
    func markStaleWithNoWatchersDoesNotWrite() {
        let env = SharedEnvironment()
        let strategy = env.installed(MockStrategy.self)

        env.preheat(\AsyncBox.theme)
        strategy.env.apply("dark", keyPath: \AsyncBox.$theme)
        #expect(strategy.onReadCount == 1)

        strategy.env.markStale(keyPath: \AsyncBox.$theme)
        #expect(strategy.onReadCount == 1)
        #expect(env.read(\AsyncBox.theme) == "dark")
        #expect(strategy.onReadCount == 2)
    }

    @Test("Status stays settled while dirty")
    func statusStaysSettledWhileDirty() {
        let env = SharedEnvironment()
        let strategy = env.installed(MockStrategy.self)

        let status = ValueObserverProbe.watch(\AsyncBox.$theme.status, in: env)
        _ = ValueObserverProbe.watch(\AsyncBox.theme, in: env)
        strategy.env.apply("dark", keyPath: \AsyncBox.$theme)
        status.expect(value: .settled)

        strategy.env.markStale(keyPath: \AsyncBox.$theme)
        status.expect(value: .settled)
    }
}

@Suite @MainActor
struct AsyncStateKeyedTests {

    @Test("Keyed Address watches status per key")
    func keyedStatusWatch() {
        let env = SharedEnvironment()
        let strategy = env.installed(MockStrategy.self)

        let status = ValueObserverProbe.watchKeyed(\AsyncBox.$done.status, key: "a", in: env)
        #expect(strategy.keyedOnReadCount == 1)
        #expect(strategy.onReadCount == 0)
        status.expect(value: .pending)

        strategy.env.apply(true, keyPath: \AsyncBox.$done, key: "a")
        status.expect(value: .settled)

        let value = ValueObserverProbe.watchKeyed(\AsyncBox.done, key: "a", in: env)
        value.expect(value: true)
    }

    @Test("Keyed fail leaves the Value and sets error; keyed restoreSeed restores seed")
    func keyedFailAndRestoreSeed() {
        let env = SharedEnvironment()
        let strategy = env.installed(MockStrategy.self)

        let status = ValueObserverProbe.watchKeyed(\AsyncBox.$done.status, key: "a", in: env)
        strategy.env.apply(true, keyPath: \AsyncBox.$done, key: "a")
        status.expect(value: .settled)

        strategy.env.fail(MockFailure.boom, keyPath: \AsyncBox.$done, key: "a")
        status.expect(value: .error(.boom))
        #expect(env.read(\AsyncBox.done, key: "a") == true)

        strategy.env.restoreSeed(keyPath: \AsyncBox.$done, key: "a")
        status.expect(value: .pending)
        #expect(env.read(\AsyncBox.done, key: "a") == nil)
    }

    @Test("One strategy instance serves two Addresses")
    func oneStrategyTwoAddresses() {
        let env = SharedEnvironment()
        let strategy = env.installed(MockStrategy.self)

        _ = ValueObserverProbe.watch(\AsyncBox.theme, in: env)
        _ = ValueObserverProbe.watch(\AsyncBox.title, in: env)

        #expect(strategy.onReadCount == 2)
        strategy.env.apply("dark", keyPath: \AsyncBox.$theme)
        strategy.env.apply("Hello", keyPath: \AsyncBox.$title)

        #expect(env.read(\AsyncBox.theme) == "dark")
        #expect(env.read(\AsyncBox.title) == "Hello")
    }
}

@Suite @MainActor
struct AsyncStateWriteTests {

    @Test("An app Sync write calls onWrite and settles")
    func appWriteCallsOnWrite() {
        let env = SharedEnvironment()
        let strategy = env.installed(MockStrategy.self)
        env.preheat(\AsyncBox.theme)

        env.perform(SetAsyncTheme(value: "dark"))

        #expect(strategy.onWriteCount == 1)
        #expect(strategy.lastWritten as? String == "dark")
        #expect(env.read(\AsyncBox.theme) == "dark")
        #expect(env.read(\AsyncBox.$theme.status) == SourceStatus<MockFailure>.settled)
    }

    @Test("A keyed app Sync write calls onWrite")
    func keyedAppWriteCallsOnWrite() {
        let env = SharedEnvironment()
        let strategy = env.installed(MockStrategy.self)
        env.preheat(\AsyncBox.done, key: "a")

        env.perform(SetAsyncFlag())

        #expect(strategy.onWriteCount == 1)
        #expect(strategy.lastWritten as? Bool == true)
        #expect(env.read(\AsyncBox.done, key: "a") == true)
    }

    @Test("apply, fail, restoreSeed, and markStale do not call onWrite")
    func inboundVerbsDoNotCallOnWrite() {
        let env = SharedEnvironment()
        let strategy = env.installed(MockStrategy.self)
        env.preheat(\AsyncBox.theme)

        strategy.env.apply("dark", keyPath: \AsyncBox.$theme)
        strategy.env.fail(MockFailure.boom, keyPath: \AsyncBox.$theme)
        strategy.env.restoreSeed(keyPath: \AsyncBox.$theme)
        strategy.env.markStale(keyPath: \AsyncBox.$theme)

        #expect(strategy.onWriteCount == 0)
    }

    @Test("Same-stack apply joins the original Operation's observation round")
    func sameStackApplyJoinsObservationRound() {
        let env = SharedEnvironment()
        let strategy = env.installed(MockStrategy.self)
        env.preheat(\AsyncBox.theme)
        let probe = ValueObserverProbe.watch(\NestedWriteBox.count, in: env)

        env.perform(NestedWriteThenApplyThenWrite(strategyEnv: strategy.env))

        #expect(env.read(\NestedWriteBox.count) == 2)
        #expect(env.read(\AsyncBox.theme) == "dark")
        probe.expect(updates: 1)
        probe.expect(value: 2)
    }

    @Test("Nested strategy perform has no write")
    func nestedPerformHasNoWrite() {
        let env = SharedEnvironment()
        env.install(NestedPerformStrategy(env: env.strategyEnvironment()))

        env.preheat(\NestedPerformBox.theme)

        #expect(env.read(\NestedWriteBox.count) == 0)
    }

    @Test("Inbound verbs no-op after the Environment dies")
    func deadEnvironmentInboundIsNoop() {
        var env: SharedEnvironment? = SharedEnvironment()
        guard let strategyEnv = env?.strategyEnvironment() else {
            Issue.record("Environment should exist before drop")
            return
        }
        env = nil

        strategyEnv.apply("dark", keyPath: \AsyncBox.$theme)
        strategyEnv.fail(MockFailure.boom, keyPath: \AsyncBox.$theme)
        strategyEnv.restoreSeed(keyPath: \AsyncBox.$theme)
        strategyEnv.markStale(keyPath: \AsyncBox.$theme)
    }
}

struct ProbePolicy: Sendable, Equatable {
    let id: String
}

@MainActor
final class PolicyStrategy: AsyncStrategy {
    typealias Failure = Never
    typealias Policy = ProbePolicy

    let env: AsyncStrategyEnvironment
    private(set) var lastOnReadPolicy: ProbePolicy?
    private(set) var lastOnDropPolicy: ProbePolicy?
    private(set) var lastKeyedOnReadPolicy: ProbePolicy?
    private(set) var lastKeyedOnDropPolicy: ProbePolicy?

    init(env: AsyncStrategyEnvironment) {
        self.env = env
    }

    func onRead<Storage: StateContainer, Value, Status>(
        _ keyPath: KeyPath<Storage, AsyncState<PolicyStrategy, Value, Status>>,
        policy: ProbePolicy,
        current: Value
    ) {
        lastOnReadPolicy = policy
    }

    func onRead<Storage: StateContainer, Key: Hashable, Value, Status>(
        _ keyPath: KeyPath<Storage, AsyncState<PolicyStrategy, [Key: Value], Status>>,
        key: Key,
        policy: ProbePolicy,
        current: Value?
    ) {
        lastKeyedOnReadPolicy = policy
    }

    func onDrop<Storage: StateContainer, Value, Status>(
        _ keyPath: KeyPath<Storage, AsyncState<PolicyStrategy, Value, Status>>,
        policy: ProbePolicy
    ) {
        lastOnDropPolicy = policy
    }

    func onDrop<Storage: StateContainer, Key: Hashable, Value, Status>(
        _ keyPath: KeyPath<Storage, AsyncState<PolicyStrategy, [Key: Value], Status>>,
        key: Key,
        policy: ProbePolicy
    ) {
        lastKeyedOnDropPolicy = policy
    }
}

extension AsyncState where S == PolicyStrategy {
    convenience init(wrappedValue: Value, _ policy: ProbePolicy)
        where Status == SourceStatus<PolicyStrategy.Failure> {
        self.init(wrappedValue: wrappedValue, policy: policy)
    }

    convenience init<Key: Hashable, Output>(
        wrappedValue: [Key: Output],
        _ policy: ProbePolicy
    ) where Value == [Key: Output], Status == [Key: SourceStatus<PolicyStrategy.Failure>] {
        self.init(wrappedValue: wrappedValue, policy: policy)
    }
}

final class PolicyBox: StateContainer {
    @AsyncState(ProbePolicy(id: "atomic")) var theme: String = "system"
}

final class PolicyKeyedBox: StateContainer {
    @AsyncState(ProbePolicy(id: "keyed")) var flags: [String: Bool] = [:]
}

struct ResetPolicyBox: SyncOperation {
    func perform(in env: SyncOperationEnvironment) {
        env.reset(PolicyBox.self)
    }
}

struct ResetPolicyKeyedBox: SyncOperation {
    func perform(in env: SyncOperationEnvironment) {
        env.reset(PolicyKeyedBox.self)
    }
}

@Suite @MainActor
struct AsyncStatePolicyTests {

    @Test("A non-Void Policy reaches Atomic onRead and onDrop")
    func atomicPolicyReachesOnReadAndOnDrop() {
        let env = SharedEnvironment()
        let strategy = env.installed(PolicyStrategy.self)

        env.preheat(\PolicyBox.theme)

        #expect(strategy.lastOnReadPolicy == ProbePolicy(id: "atomic"))
        #expect(strategy.lastOnDropPolicy == nil)

        env.perform(ResetPolicyBox())

        #expect(strategy.lastOnDropPolicy == ProbePolicy(id: "atomic"))
    }

    @Test("A non-Void Policy reaches Keyed onRead and onDrop")
    func keyedPolicyReachesOnReadAndOnDrop() {
        let env = SharedEnvironment()
        let strategy = env.installed(PolicyStrategy.self)

        env.preheat(\PolicyKeyedBox.flags, key: "a")

        #expect(strategy.lastKeyedOnReadPolicy == ProbePolicy(id: "keyed"))
        #expect(strategy.lastKeyedOnDropPolicy == nil)

        env.perform(ResetPolicyKeyedBox())

        #expect(strategy.lastKeyedOnDropPolicy == ProbePolicy(id: "keyed"))
    }
}

// MARK: - First-read nested inbound

@Suite @MainActor
struct AsyncStateFirstReadTests {

    @Test("First Watch of an apply-inside-onRead Address has one body and the applied Value")
    func firstWatchOfApplyInsideOnReadHasOneBody() {
        let env = SharedEnvironment()
        let strategy = ApplyingStrategy(env: env.strategyEnvironment())
        env.install(strategy)

        let probe = ValueObserverProbe.watch(\ApplyingBox.theme, in: env)

        probe.expect(value: "dark")
        #expect(probe.renderCount == 1)
        probe.expect(updates: 0)
    }

    @Test("First Watch of a keyed apply-inside-onRead Address has one body and the applied Value")
    func firstWatchOfKeyedApplyInsideOnReadHasOneBody() {
        let env = SharedEnvironment()
        env.install(ApplyingStrategy(env: env.strategyEnvironment()))

        let probe = ValueObserverProbe.watchKeyed(\ApplyingKeyedBox.done, key: "a", in: env)

        probe.expect(value: true)
        #expect(probe.renderCount == 1)
        probe.expect(updates: 0)
    }

    @Test("First Watch of a Computed that reads apply-inside-onRead has one body and the applied Value")
    func firstWatchOfComputedApplyInsideOnReadHasOneBody() {
        let env = SharedEnvironment()
        env.install(ApplyingStrategy(env: env.strategyEnvironment()))

        let probe = ValueObserverProbe.watch(computed: \ApplyingComputedBox.$labeled, in: env)

        probe.expect(value: "dark")
        #expect(probe.renderCount == 1)
        probe.expect(updates: 0)
    }

    @Test("First Watch of a fail-inside-onRead status Address has one body and the error")
    func firstWatchOfFailInsideOnReadHasOneBody() {
        let env = SharedEnvironment()
        env.install(FailingStrategy(env: env.strategyEnvironment()))

        let probe = ValueObserverProbe.watch(\FailingBox.$theme.status, in: env)

        probe.expect(value: SourceStatus<MockFailure>.error(.boom))
        #expect(probe.renderCount == 1)
        probe.expect(updates: 0)
    }

    @Test("An already-subscribed Watch still hears nested inbound from another Address's first onRead")
    func alreadySubscribedWatchHearsNestedInbound() {
        let env = SharedEnvironment()
        env.install(CrossApplyStrategy(env: env.strategyEnvironment()))

        let theme = ValueObserverProbe.watch(\CrossApplyBox.theme, in: env)
        theme.expect(value: "dark")
        theme.expect(updates: 0)

        let title = ValueObserverProbe.watch(\CrossApplyBox.title, in: env)

        title.expect(value: "untitled")
        title.expect(updates: 0)
        theme.expect(value: "light")
        theme.expect(updates: 1)
    }

    @Test("A later apply still notifies the Watch that skipped nested inbound")
    func laterApplyStillNotifiesAfterFirstRead() {
        let env = SharedEnvironment()
        let strategy = ApplyingStrategy(env: env.strategyEnvironment())
        env.install(strategy)

        let probe = ValueObserverProbe.watch(\ApplyingBox.theme, in: env)
        probe.expect(value: "dark")
        probe.expect(updates: 0)

        strategy.env.apply("light", keyPath: \ApplyingBox.$theme)

        probe.expect(value: "light")
        probe.expect(updates: 1)
    }

    @Test("EnvironmentService read of apply-inside-onRead serves once with the applied Value")
    func serviceReadOfApplyInsideOnReadServesOnce() async {
        let env = SharedEnvironment()
        env.install(ApplyingStrategy(env: env.strategyEnvironment()))

        let service = await env.spawnService(ApplyingThemeService.self)

        #expect(service.seen == ["dark"])
        #expect(service.serveCount == 1)
        #expect(await waitUntil(timeout: .milliseconds(150)) { service.serveCount > 1 } == false)
    }

    @Test("EnvironmentService read of a keyed apply-inside-onRead serves once with the applied Value")
    func serviceKeyedReadOfApplyInsideOnReadServesOnce() async {
        let env = SharedEnvironment()
        env.install(ApplyingStrategy(env: env.strategyEnvironment()))

        let service = await env.spawnService(ApplyingKeyedService.self)

        #expect(service.seen == [true])
        #expect(service.serveCount == 1)
        #expect(await waitUntil(timeout: .milliseconds(150)) { service.serveCount > 1 } == false)
    }

    @Test("EnvironmentService read of a Computed that reads apply-inside-onRead serves once with the applied Value")
    func serviceComputedReadOfApplyInsideOnReadServesOnce() async {
        let env = SharedEnvironment()
        env.install(ApplyingStrategy(env: env.strategyEnvironment()))

        let service = await env.spawnService(ApplyingComputedService.self)

        #expect(service.seen == ["dark"])
        #expect(service.serveCount == 1)
        #expect(await waitUntil(timeout: .milliseconds(150)) { service.serveCount > 1 } == false)
    }

    #if canImport(AppKit) || canImport(UIKit)
    @Test("First HostedView Watch of apply-inside-onRead shows the applied Value and does not re-evaluate after")
    func firstHostedWatchOfApplyInsideOnReadStaysOnOneFrame() async {
        let env = SharedEnvironment()
        env.install(ApplyingStrategy(env: env.strategyEnvironment()))
        let counter = ApplyingRenderCounter()

        let host = HostedView.mount(ApplyingWatchView(counter: counter).sharedEnvironment(env))
        defer { host.teardown() }

        #expect(await waitUntil { counter.last == "dark" })
        let settled = counter.count
        #expect(await waitUntil(timeout: .milliseconds(200)) { counter.count > settled } == false)
        #expect(counter.last == "dark")
    }
    #endif
}

#if canImport(AppKit) || canImport(UIKit)
@MainActor
final class ApplyingRenderCounter {
    var count = 0
    var last: String?
}

@MainActor
struct ApplyingWatchView: View {
    let counter: ApplyingRenderCounter
    @Watch(\ApplyingBox.theme) var theme

    var body: some View {
        let _ = counter.count += 1
        let _ = counter.last = theme
        Text(theme)
    }
}
#endif

