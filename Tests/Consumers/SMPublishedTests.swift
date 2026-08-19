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

#if canImport(Combine)
import Combine
import Foundation
import Testing
@testable import StateManagement

final class SMPublishedBox: StateContainer, ObservableObject {
    @SMPublished var thisValue = 0
    @SMPublished var items: [String: Int] = [:]
    var localNote = ""

    @Computed var doubled = { (env: ComputationEnvironment) -> Int in
        env.getValue(\SMPublishedBox.thisValue) * 2
    }
}

struct SetSMPublishedValue: SyncOperation {
    let value: Int
    func perform(in env: SyncOperationEnvironment) {
        env.write(value, keyPath: \SMPublishedBox.thisValue)
    }
}

struct SetSMPublishedItem: SyncOperation {
    let key: String
    let value: Int
    func perform(in env: SyncOperationEnvironment) {
        env.write(value, keyPath: \SMPublishedBox.items, key: key)
    }
}

struct RemoveSMPublishedItem: SyncOperation {
    let key: String
    func perform(in env: SyncOperationEnvironment) {
        env.remove(keyPath: \SMPublishedBox.items, key: key)
    }
}

struct ResetSMPublishedBox: SyncOperation {
    func perform(in env: SyncOperationEnvironment) {
        env.reset(SMPublishedBox.self)
    }
}

@Suite(.serialized) @MainActor
struct SMPublishedTests {

    private func resetShared() {
        SharedEnvironment.shared.perform(ResetSMPublishedBox())
    }

    @Test("Leftover get and set use SharedEnvironment.shared")
    func leftoverGetSetUseShared() {
        resetShared()
        let leftover = SMPublishedBox()

        leftover.thisValue = 7

        #expect(leftover.thisValue == 7)
        #expect(SharedEnvironment.shared.read(\SMPublishedBox.thisValue) == 7)
    }

    @Test("Watch on a test Environment stays isolated from leftover Combine")
    func watchOnTestEnvironmentStaysIsolated() {
        resetShared()
        let env = SharedEnvironment()
        let probe = ValueObserverProbe.watch(\SMPublishedBox.thisValue, in: env)
        probe.expect(value: 0)

        let leftover = SMPublishedBox()
        leftover.thisValue = 7

        #expect(leftover.thisValue == 7)
        probe.expect(value: 0)
        probe.expect(updates: 0)

        env.perform(SetSMPublishedValue(value: 4))
        probe.expect(value: 4)
        #expect(leftover.thisValue == 7)
        #expect(SharedEnvironment.shared.read(\SMPublishedBox.thisValue) == 7)
    }

    @Test("Computed and Operations use the Environment they were given")
    func computedAndOperationsUseGivenEnvironment() {
        resetShared()
        let env = SharedEnvironment()
        let probe = ValueObserverProbe.watch(computed: \SMPublishedBox.$doubled, in: env)
        probe.expect(value: 0)

        env.perform(SetSMPublishedValue(value: 3))
        probe.expect(value: 6)

        let leftover = SMPublishedBox()
        leftover.thisValue = 9
        probe.expect(value: 6)
        #expect(env.read(\SMPublishedBox.thisValue) == 3)
    }

    @Test("Leftover $ follows an Operation on SharedEnvironment.shared")
    func leftoverPublisherFollowsSharedOperation() {
        resetShared()
        let leftover = SMPublishedBox()
        var values: [Int] = []
        let cancellable = leftover.$thisValue.sink { values.append($0) }

        #expect(values == [0])

        SharedEnvironment.shared.perform(SetSMPublishedValue(value: 3))

        #expect(values == [0, 3])
        #expect(leftover.thisValue == 3)
        _ = cancellable
    }

    @Test("Leftover $ and leftover set send objectWillChange")
    func leftoverObjectWillChangeFires() {
        resetShared()
        let leftover = SMPublishedBox()
        var willChange = 0
        let willChangeCancellable = leftover.objectWillChange.sink { willChange += 1 }
        var values: [Int] = []
        let valueCancellable = leftover.$thisValue.sink { values.append($0) }

        #expect(willChange == 0)

        leftover.thisValue = 1
        #expect(willChange == 1)
        #expect(values == [0, 1])

        SharedEnvironment.shared.perform(SetSMPublishedValue(value: 2))
        #expect(willChange == 2)
        #expect(values == [0, 1, 2])
        _ = willChangeCancellable
        _ = valueCancellable
    }

    @Test("Leftover whole-dict write diffs and invalidates changed keys")
    func leftoverWholeDictWriteInvalidatesChangedKeys() {
        resetShared()
        let probeA = ValueObserverProbe.watchKeyed(\SMPublishedBox.items, key: "a", in: .shared)
        let probeB = ValueObserverProbe.watchKeyed(\SMPublishedBox.items, key: "b", in: .shared)
        probeA.expect(value: nil)
        probeB.expect(value: nil)

        let leftover = SMPublishedBox()
        leftover.items = ["a": 1]

        probeA.expect(value: 1)
        probeA.expect(updates: 1)
        probeB.expect(value: nil)
        probeB.expect(updates: 0)

        leftover.items = ["a": 1, "b": 2]
        probeA.expect(value: 1)
        probeA.expect(updates: 1)
        probeB.expect(value: 2)
        probeB.expect(updates: 1)
    }

    @Test("Keyed Operation invalidates the atomic dictionary Address so leftover $items emits")
    func keyedOperationEmitsWholeDictPublisher() {
        resetShared()
        let leftover = SMPublishedBox()
        var values: [[String: Int]] = []
        let cancellable = leftover.$items.sink { values.append($0) }

        #expect(values == [[:]])

        SharedEnvironment.shared.perform(SetSMPublishedItem(key: "a", value: 1))
        #expect(values == [[:], ["a": 1]])

        SharedEnvironment.shared.perform(RemoveSMPublishedItem(key: "a"))
        #expect(values == [[:], ["a": 1], [:]])
        _ = cancellable
    }

    @Test("Plain var on the same class stays per-instance")
    func plainVarStaysPerInstance() {
        resetShared()
        let a = SMPublishedBox()
        let b = SMPublishedBox()

        a.localNote = "a"
        b.localNote = "b"

        #expect(a.localNote == "a")
        #expect(b.localNote == "b")

        a.thisValue = 5
        #expect(b.thisValue == 5)
        #expect(b.localNote == "b")
    }

    @Test("read(_:) still snapshots SharedEnvironment.shared without leftover $ emitting")
    func readStillSnapshotsWithoutEmitting() {
        resetShared()
        let leftover = SMPublishedBox()
        leftover.thisValue = 5

        var values: [Int] = []
        let cancellable = leftover.$thisValue.sink { values.append($0) }
        #expect(values == [5])

        let snap = SharedEnvironment.shared.read(\SMPublishedBox.thisValue)
        #expect(snap == 5)
        #expect(values == [5])
        _ = cancellable
    }
}
#endif
