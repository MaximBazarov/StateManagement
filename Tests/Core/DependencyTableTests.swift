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

/// Direct tests of the generic ``DependencyTable``: register, one-shot take, and
/// key independence. Exercised through ``NotificationReceiver`` as a concrete
/// `@MainActor Hashable` element.
@Suite @MainActor
struct DependencyTableTests {

    /// Registering an element then taking its input returns that element.
    @Test("Register then take returns the element")
    func registerThenTake() {
        var table = DependencyTable<NotificationReceiver>()
        let a = ValueID(keyPath: \OSState.a)
        let element = NotificationReceiver { _ in }

        table.register(element, on: a)

        #expect(table.take(a) == [element])
    }

    /// Take removes: a second take on the same input returns empty.
    @Test("Take is one-shot")
    func takeIsOneShot() {
        var table = DependencyTable<NotificationReceiver>()
        let a = ValueID(keyPath: \OSState.a)
        let element = NotificationReceiver { _ in }

        table.register(element, on: a)
        _ = table.take(a)

        #expect(table.take(a).isEmpty)
    }

    /// Taking an input that was never registered returns empty, no crash.
    @Test("Take on an absent key returns empty")
    func takeAbsentKey() {
        var table = DependencyTable<NotificationReceiver>()
        let a = ValueID(keyPath: \OSState.a)

        #expect(table.take(a).isEmpty)
    }

    /// Registering the same element twice on one input yields a set of one.
    @Test("Register dedups the same element")
    func registerDedups() {
        var table = DependencyTable<NotificationReceiver>()
        let a = ValueID(keyPath: \OSState.a)
        let element = NotificationReceiver { _ in }

        table.register(element, on: a)
        table.register(element, on: a)

        #expect(table.take(a) == [element])
    }

    /// Many elements on one input all come back in the taken set.
    @Test("Many elements per input all return")
    func manyElementsPerInput() {
        var table = DependencyTable<NotificationReceiver>()
        let a = ValueID(keyPath: \OSState.a)
        let first = NotificationReceiver { _ in }
        let second = NotificationReceiver { _ in }

        table.register(first, on: a)
        table.register(second, on: a)

        #expect(table.take(a) == [first, second])
    }

    /// Taking one input leaves another input intact.
    @Test("Keys are independent")
    func keysAreIndependent() {
        var table = DependencyTable<NotificationReceiver>()
        let a = ValueID(keyPath: \OSState.a)
        let b = ValueID(keyPath: \OSState.b)
        let onA = NotificationReceiver { _ in }
        let onB = NotificationReceiver { _ in }

        table.register(onA, on: a)
        table.register(onB, on: b)

        _ = table.take(a)

        #expect(table.take(b) == [onB])
    }
}
