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

enum MockFailure: Error, Equatable {
    case boom
}

@MainActor
final class MockSource: Source {
    typealias Failure = MockFailure

    let sourceUpdate: SourceUpdate
    private(set) var provideCount = 0
    private(set) var keyedProvideCount = 0
    private(set) var lastEnvironment: SourceEnvironment?

    init() {
        self.sourceUpdate = .write
    }

    init(sourceUpdate: SourceUpdate) {
        self.sourceUpdate = sourceUpdate
    }

    func provide<Storage: StateContainer, Value>(
        _ keyPath: KeyPath<Storage, Value>,
        policy _: Void,
        in env: SourceEnvironment
    ) {
        provideCount += 1
        lastEnvironment = env
    }

    func provide<Storage: StateContainer, Key: Hashable, Value>(
        _ keyPath: KeyPath<Storage, [Key: Value]>,
        key: Key,
        policy _: Void,
        in env: SourceEnvironment
    ) {
        keyedProvideCount += 1
        lastEnvironment = env
    }
}

@MainActor
final class DeliveringSource: Source {
    typealias Failure = MockFailure

    let sourceUpdate = SourceUpdate.write

    init() {}

    func provide<Storage: StateContainer, Value>(
        _ keyPath: KeyPath<Storage, Value>,
        policy _: Void,
        in env: SourceEnvironment
    ) {
        guard let path = keyPath as? WritableKeyPath<Storage, Value> else { return }
        guard let value = "dark" as? Value else { return }
        env.deliver(value, keyPath: path)
    }
}

final class AsyncBox: StateContainer {
    @AsyncState(MockSource.self) var theme: String = "system"
    @AsyncState(MockSource.self) var title: String = "untitled"
    @AsyncState(MockSource.self) var profile: String? = nil
    @AsyncState(MockSource.self) var done: [String: Bool] = [:]
}

final class DeliveringBox: StateContainer {
    @AsyncState(DeliveringSource.self) var theme: String = "system"
}

@Suite @MainActor
struct AsyncStateSourceTests {

    @Test("First Watch of the sourced Value calls provide")
    func firstWatchOfValueProvides() {
        let env = SharedEnvironment()
        let source = MockSource()
        env.install(source)

        _ = ValueObserverProbe.watch(\AsyncBox.theme, in: env)

        #expect(source.provideCount == 1)
    }

    @Test("First Watch of status calls provide")
    func firstWatchOfStatusProvides() {
        let env = SharedEnvironment()
        let source = MockSource()
        env.install(source)

        _ = ValueObserverProbe.watch(\AsyncBox.$theme.status, in: env)

        #expect(source.provideCount == 1)
    }

    @Test("Status-first provide passes the sourced Address so deliver writes the Value")
    func statusFirstProvidePassesSourcedAddress() {
        let env = SharedEnvironment()
        let source = DeliveringSource()
        env.install(source)

        let status = ValueObserverProbe.watch(\DeliveringBox.$theme.status, in: env)
        let value = ValueObserverProbe.watch(\DeliveringBox.theme, in: env)

        value.expect(value: "dark")
        status.expect(value: .settled)
    }

    @Test("Preheat calls provide with no Watch")
    func preheatProvidesWithNoWatch() {
        let env = SharedEnvironment()
        let source = MockSource()
        env.install(source)

        env.preheat(\AsyncBox.theme)

        #expect(source.provideCount == 1)
    }

    @Test("A second Watch of the same Address does not provide again")
    func secondWatchDoesNotProvideAgain() {
        let env = SharedEnvironment()
        let source = MockSource()
        env.install(source)

        _ = ValueObserverProbe.watch(\AsyncBox.theme, in: env)
        _ = ValueObserverProbe.watch(\AsyncBox.theme, in: env)

        #expect(source.provideCount == 1)
    }
}

@Suite @MainActor
struct AsyncStateDeliverTests {

    @Test("Deliver writes the Value and settled, and Watch sees both")
    func deliverMakesValueAndSettledVisible() {
        let env = SharedEnvironment()
        let source = MockSource()
        env.install(source)

        let value = ValueObserverProbe.watch(\AsyncBox.theme, in: env)
        let status = ValueObserverProbe.watch(\AsyncBox.$theme.status, in: env)
        value.expect(value: "system")
        status.expect(value: .pending)

        source.lastEnvironment?.deliver("dark", keyPath: \AsyncBox.theme)

        value.expect(value: "dark")
        status.expect(value: .settled)
        value.expect(updates: 1)
        status.expect(updates: 1)
    }

    @Test("Fail writes error, leaves the Value, and clears dirty")
    func failLeavesValueAndSetsError() {
        let env = SharedEnvironment()
        let source = MockSource()
        env.install(source)

        let value = ValueObserverProbe.watch(\AsyncBox.theme, in: env)
        let status = ValueObserverProbe.watch(\AsyncBox.$theme.status, in: env)
        source.lastEnvironment?.deliver("dark", keyPath: \AsyncBox.theme)

        source.lastEnvironment?.fail(MockFailure.boom, keyPath: \AsyncBox.theme)

        value.expect(value: "dark")
        status.expect(value: .error(.boom))
    }

    @Test("Clear writes the seed and pending")
    func clearRestoresSeedAndPending() {
        let env = SharedEnvironment()
        let source = MockSource()
        env.install(source)

        let value = ValueObserverProbe.watch(\AsyncBox.theme, in: env)
        let status = ValueObserverProbe.watch(\AsyncBox.$theme.status, in: env)
        source.lastEnvironment?.deliver("dark", keyPath: \AsyncBox.theme)

        source.lastEnvironment?.clear(keyPath: \AsyncBox.theme)

        value.expect(value: "system")
        status.expect(value: .pending)
    }

    @Test("Optional seed is nil and pending; settled plus nil is loaded empty")
    func optionalSeedAndLoadedEmpty() {
        let env = SharedEnvironment()
        let source = MockSource()
        env.install(source)

        let value = ValueObserverProbe.watch(\AsyncBox.profile, in: env)
        let status = ValueObserverProbe.watch(\AsyncBox.$profile.status, in: env)
        value.expect(value: nil)
        status.expect(value: .pending)

        source.lastEnvironment?.deliver(Optional<String>.none, keyPath: \AsyncBox.profile)

        value.expect(value: nil)
        status.expect(value: .settled)
    }

    @Test("Clear does not call dropped")
    func clearDoesNotCallDropped() {
        let env = SharedEnvironment()
        let source = MockSource()
        env.install(source)

        let probe = ValueObserverProbe.watch(\AsyncBox.theme, in: env)
        source.lastEnvironment?.deliver("dark", keyPath: \AsyncBox.theme)
        source.lastEnvironment?.clear(keyPath: \AsyncBox.theme)
        #expect(source.provideCount == 1)

        source.lastEnvironment?.deliver("light", keyPath: \AsyncBox.theme)
        probe.expect(value: "light")
        #expect(source.provideCount == 1)
    }
}

@Suite @MainActor
struct AsyncStateUpdateTests {

    @Test("Write delivers on update; later reads do not pull")
    func writeDeliversOnUpdateWithoutPull() {
        let env = SharedEnvironment()
        let source = MockSource(sourceUpdate: .write)
        env.install(source)

        let probe = ValueObserverProbe.watch(\AsyncBox.theme, in: env)
        #expect(source.provideCount == 1)

        source.lastEnvironment?.deliver("dark", keyPath: \AsyncBox.theme)
        probe.expect(value: "dark")

        _ = env.read(\AsyncBox.theme)
        #expect(source.provideCount == 1)
    }

    @Test("Invalidate dirties and the next read pulls")
    func invalidateDirtiesAndNextReadPulls() {
        let env = SharedEnvironment()
        let source = MockSource(sourceUpdate: .invalidate)
        env.install(source)

        let probe = ValueObserverProbe.watch(\AsyncBox.theme, in: env)
        source.lastEnvironment?.deliver("dark", keyPath: \AsyncBox.theme)
        #expect(source.provideCount == 1)

        source.lastEnvironment?.invalidate(keyPath: \AsyncBox.theme)
        #expect(source.provideCount == 2)
        probe.expect(value: "dark")
    }

    @Test("Invalidate with no Watchers dirties only")
    func invalidateWithNoWatchersDoesNotWrite() {
        let env = SharedEnvironment()
        let source = MockSource(sourceUpdate: .invalidate)
        env.install(source)

        env.preheat(\AsyncBox.theme)
        source.lastEnvironment?.deliver("dark", keyPath: \AsyncBox.theme)
        #expect(source.provideCount == 1)

        source.lastEnvironment?.invalidate(keyPath: \AsyncBox.theme)
        #expect(source.provideCount == 1)
        #expect(env.read(\AsyncBox.theme) == "dark")
        #expect(source.provideCount == 2)
    }

    @Test("Status stays settled while dirty")
    func statusStaysSettledWhileDirty() {
        let env = SharedEnvironment()
        let source = MockSource(sourceUpdate: .invalidate)
        env.install(source)

        let status = ValueObserverProbe.watch(\AsyncBox.$theme.status, in: env)
        _ = ValueObserverProbe.watch(\AsyncBox.theme, in: env)
        source.lastEnvironment?.deliver("dark", keyPath: \AsyncBox.theme)
        status.expect(value: .settled)

        source.lastEnvironment?.invalidate(keyPath: \AsyncBox.theme)
        status.expect(value: .settled)
    }
}

@Suite @MainActor
struct AsyncStateKeyedTests {

    @Test("Keyed Address watches status per key")
    func keyedStatusWatch() {
        let env = SharedEnvironment()
        let source = MockSource()
        env.install(source)

        let status = ValueObserverProbe.watchKeyed(\AsyncBox.$done.status, key: "a", in: env)
        #expect(source.keyedProvideCount == 1)
        #expect(source.provideCount == 0)
        status.expect(value: .pending)

        source.lastEnvironment?.deliver(true, keyPath: \AsyncBox.done, key: "a")
        status.expect(value: .settled)

        let value = ValueObserverProbe.watchKeyed(\AsyncBox.done, key: "a", in: env)
        value.expect(value: true)
    }

    @Test("Keyed fail leaves the Value and sets error; keyed clear restores seed")
    func keyedFailAndClear() {
        let env = SharedEnvironment()
        let source = MockSource()
        env.install(source)

        let status = ValueObserverProbe.watchKeyed(\AsyncBox.$done.status, key: "a", in: env)
        source.lastEnvironment?.deliver(true, keyPath: \AsyncBox.done, key: "a")
        status.expect(value: .settled)

        source.lastEnvironment?.fail(MockFailure.boom, keyPath: \AsyncBox.done, key: "a")
        status.expect(value: .error(.boom))
        #expect(env.read(\AsyncBox.done, key: "a") == true)

        source.lastEnvironment?.clear(keyPath: \AsyncBox.done, key: "a")
        status.expect(value: .pending)
        #expect(env.read(\AsyncBox.done, key: "a") == nil)
    }

    @Test("One Source instance serves two Addresses")
    func oneSourceTwoAddresses() {
        let env = SharedEnvironment()
        let source = MockSource()
        env.install(source)

        _ = ValueObserverProbe.watch(\AsyncBox.theme, in: env)
        _ = ValueObserverProbe.watch(\AsyncBox.title, in: env)

        #expect(source.provideCount == 2)
        source.lastEnvironment?.deliver("dark", keyPath: \AsyncBox.theme)
        source.lastEnvironment?.deliver("Hello", keyPath: \AsyncBox.title)

        #expect(env.read(\AsyncBox.theme) == "dark")
        #expect(env.read(\AsyncBox.title) == "Hello")
    }
}

struct ProbePolicy: Sendable, Equatable {
    let id: String
}

@MainActor
final class PolicySource: Source {
    typealias Failure = Never
    typealias Policy = ProbePolicy

    let sourceUpdate = SourceUpdate.write
    private(set) var lastProvidePolicy: ProbePolicy?
    private(set) var lastDroppedPolicy: ProbePolicy?
    private(set) var lastKeyedProvidePolicy: ProbePolicy?
    private(set) var lastKeyedDroppedPolicy: ProbePolicy?

    init() {}

    func provide<Storage: StateContainer, Value>(
        _ keyPath: KeyPath<Storage, Value>,
        policy: ProbePolicy,
        in env: SourceEnvironment
    ) {
        lastProvidePolicy = policy
    }

    func provide<Storage: StateContainer, Key: Hashable, Value>(
        _ keyPath: KeyPath<Storage, [Key: Value]>,
        key: Key,
        policy: ProbePolicy,
        in env: SourceEnvironment
    ) {
        lastKeyedProvidePolicy = policy
    }

    func dropped<Storage: StateContainer, Value>(
        _ keyPath: KeyPath<Storage, Value>,
        policy: ProbePolicy
    ) {
        lastDroppedPolicy = policy
    }

    func dropped<Storage: StateContainer, Key: Hashable, Value>(
        _ keyPath: KeyPath<Storage, [Key: Value]>,
        key: Key,
        policy: ProbePolicy
    ) {
        lastKeyedDroppedPolicy = policy
    }
}

extension AsyncState where S == PolicySource {
    convenience init(wrappedValue: Value, _ policy: ProbePolicy)
        where Status == SourceStatus<PolicySource.Failure> {
        self.init(wrappedValue: wrappedValue, policy: policy)
    }

    convenience init<Key: Hashable, Output>(
        wrappedValue: [Key: Output],
        _ policy: ProbePolicy
    ) where Value == [Key: Output], Status == [Key: SourceStatus<PolicySource.Failure>] {
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

    @Test("A non-Void Policy reaches Atomic provide and dropped")
    func atomicPolicyReachesProvideAndDropped() {
        let env = SharedEnvironment()
        let source = PolicySource()
        env.install(source)

        env.preheat(\PolicyBox.theme)

        #expect(source.lastProvidePolicy == ProbePolicy(id: "atomic"))
        #expect(source.lastDroppedPolicy == nil)

        env.perform(ResetPolicyBox())

        #expect(source.lastDroppedPolicy == ProbePolicy(id: "atomic"))
    }

    @Test("A non-Void Policy reaches Keyed provide and dropped")
    func keyedPolicyReachesProvideAndDropped() {
        let env = SharedEnvironment()
        let source = PolicySource()
        env.install(source)

        env.preheat(\PolicyKeyedBox.flags, key: "a")

        #expect(source.lastKeyedProvidePolicy == ProbePolicy(id: "keyed"))
        #expect(source.lastKeyedDroppedPolicy == nil)

        env.perform(ResetPolicyKeyedBox())

        #expect(source.lastKeyedDroppedPolicy == ProbePolicy(id: "keyed"))
    }
}
