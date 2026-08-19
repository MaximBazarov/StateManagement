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

final class SIDStateA: StateContainer {
    var a = 0
}

final class SIDStateB: StateContainer {
    var b = 0
}

// MARK: - Tests

/// ``StorageID`` identity. It keys the environment's container warehouse, so
/// two IDs must be equal exactly when they name the same container *type* and
/// distinct otherwise. Identity is derived from the type's `ObjectIdentifier`,
/// never from an instance.
@Suite("StorageID identity") @MainActor
struct StorageIDTests {

    @Test("Same container type produces equal IDs and hashes")
    func sameTypeIsEqual() {
        let x = StorageID(SIDStateA.self)
        let y = StorageID(SIDStateA.self)
        #expect(x == y)
        #expect(x.hashValue == y.hashValue)
    }

    @Test("Different container types produce different IDs")
    func differentTypesAreNotEqual() {
        let x = StorageID(SIDStateA.self)
        let y = StorageID(SIDStateB.self)
        #expect(x != y)
    }

    @Test("Identity is per-type, stable across constructions")
    func identityIsPerTypeNotInstance() {
        let ids = (0..<100).map { _ in StorageID(SIDStateA.self) }
        #expect(Set(ids).count == 1)
    }

    @Test("Usable as a dictionary key: same type collapses to one slot")
    func usableAsDictionaryKey() {
        var warehouse: [StorageID: String] = [:]
        warehouse[StorageID(SIDStateA.self)] = "a"
        warehouse[StorageID(SIDStateB.self)] = "b"
        warehouse[StorageID(SIDStateA.self)] = "a2" // overwrites the A slot

        #expect(warehouse.count == 2)
        #expect(warehouse[StorageID(SIDStateA.self)] == "a2")
        #expect(warehouse[StorageID(SIDStateB.self)] == "b")
    }

    @Test("A Set of IDs dedupes down to one member per type")
    func setDedupesByType() {
        let set: Set<StorageID> = [
            StorageID(SIDStateA.self),
            StorageID(SIDStateA.self),
            StorageID(SIDStateB.self),
            StorageID(SIDStateB.self),
        ]
        #expect(set.count == 2)
    }
}
