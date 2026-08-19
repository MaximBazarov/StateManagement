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

// MARK: - State

final class VIDState: StateContainer {
    var a = 0
    var b = 0
    var dict: [String: Int] = [:]
}

// MARK: - Tests

/// ``ValueID`` identity. This is the addressing key the whole system hashes on,
/// so value-based key-path equality is load-bearing: reference identity would
/// miss updates. See the type's implementation note.
@Suite @MainActor
struct ValueIDTests {

    /// Same atomic key path produces equal IDs with equal hashes.
    @Test func atomicSameKeyPathIsEqual() {
        let x = ValueID(keyPath: \VIDState.a)
        let y = ValueID(keyPath: \VIDState.a)
        #expect(x == y)
        #expect(x.hashValue == y.hashValue)
    }

    /// Different atomic key paths produce different IDs.
    @Test func atomicDifferentKeyPathsAreNotEqual() {
        let x = ValueID(keyPath: \VIDState.a)
        let y = ValueID(keyPath: \VIDState.b)
        #expect(x != y)
    }

    /// Same dictionary key path and key produce equal IDs.
    @Test func keyedSameKeyAndPathIsEqual() {
        let path: KeyPath<VIDState, [String: Int]> = \VIDState.dict
        let x = ValueID(keyPath: path, key: AnyHashable("k"))
        let y = ValueID(keyPath: path, key: AnyHashable("k"))
        #expect(x == y)
        #expect(x.hashValue == y.hashValue)
    }

    /// Same dictionary key path but different keys are not equal.
    @Test func keyedDifferentKeysAreNotEqual() {
        let path: KeyPath<VIDState, [String: Int]> = \VIDState.dict
        let x = ValueID(keyPath: path, key: AnyHashable("k1"))
        let y = ValueID(keyPath: path, key: AnyHashable("k2"))
        #expect(x != y)
    }

    /// An atomic ID and a keyed ID on the same key path are distinct.
    /// The atomic dictionary (whole map) is a different value than one key in it.
    @Test func atomicAndKeyedOnSamePathAreNotEqual() {
        let path: KeyPath<VIDState, [String: Int]> = \VIDState.dict
        let atomic = ValueID(keyPath: path)
        let keyed = ValueID(keyPath: path, key: AnyHashable("k"))
        #expect(atomic != keyed)
    }
}
