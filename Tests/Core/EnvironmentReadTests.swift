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

final class ReadTestState: StateContainer {
    var label: String = ""
    var items: [String: Int] = [:]
}

struct SetReadLabel: SyncOperation {
    let value: String
    func perform(in env: SyncOperationEnvironment) {
        env.write(value, keyPath: \ReadTestState.label)
    }
}

struct SetReadItem: SyncOperation {
    let key: String
    let value: Int
    func perform(in env: SyncOperationEnvironment) {
        env.write(value, keyPath: \ReadTestState.items, key: key)
    }
}

/// A stand-in for a Combine object: it is not a Container and it only snapshots.
@MainActor
final class SnapshotCaller {
    func snapshotLabel(from env: SharedEnvironment) -> String {
        env.read(\ReadTestState.label)
    }

    func snapshotItem(_ key: String, from env: SharedEnvironment) -> Int? {
        env.read(\ReadTestState.items, key: key)
    }
}

@Suite @MainActor
struct EnvironmentReadTests {

    @Test("A caller outside a Container can snapshot an atomic Value")
    func outsideCallerSnapshotsAtomicValue() {
        let env = SharedEnvironment()
        env.perform(SetReadLabel(value: "hi"))

        let caller = SnapshotCaller()
        #expect(caller.snapshotLabel(from: env) == "hi")
    }

    @Test("A caller outside a Container can snapshot a keyed Value")
    func outsideCallerSnapshotsKeyedValue() {
        let env = SharedEnvironment()
        env.perform(SetReadItem(key: "a", value: 7))

        let caller = SnapshotCaller()
        #expect(caller.snapshotItem("a", from: env) == 7)
    }
}
