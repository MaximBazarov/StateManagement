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

final class MyState: StateContainer {
    var myInt = 7
    var myString = "Hello"
    var myValue = MyValue(x: 66, y: 77)
    var storage: [Int: String] = [:]

    struct MyValue {
        let x: Int
        var y: Int
    }
}

struct IncrementMyStateX: SyncOperation {
    func perform(in env: SyncOperationEnvironment) {
        let x = env.read(\MyState.myInt)
        env.write(\MyState.myInt, value: x + 1)
    }
}

struct IncrementMyStateY: SyncOperation {
    func perform(in env: SyncOperationEnvironment) {
        let old = env.read(\MyState.myValue.y)
        env.write(\MyState.myValue.y, value: old + 1)
    }
}

@Test @MainActor func testIncrementOperation() async throws {
    let env = SharedEnvironment()

    let before = env.getValue(keyPath: \MyState.myInt)
    let runCount = 1_000

    for _ in 1...runCount {
        // OPERATION
        env.perform(IncrementMyStateX())
        // END OPERATION
    }

    let after = env.getValue(keyPath: \MyState.myInt)
    #expect(after == before + runCount)
}

/// Performs both increment operations
struct NestedOperation: SyncOperation {
    func perform(in env: SyncOperationEnvironment) {
        env.perform(IncrementMyStateX())
        env.perform(IncrementMyStateY())
    }
}

@Test @MainActor func testNestedOperation() async throws {
    let env = SharedEnvironment()

    let beforeX = env.getValue(keyPath: \MyState.myInt)
    let beforeY = env.getValue(keyPath: \MyState.myValue.y)

    // OPERATION
    env.perform(NestedOperation())
    // END OPERATION

    let afterX = env.getValue(keyPath: \MyState.myInt)
    let afterY = env.getValue(keyPath: \MyState.myValue.y)

    #expect(afterX == beforeX + 1)
    #expect(afterY == beforeY + 1)
}
