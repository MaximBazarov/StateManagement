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

final class OSState: StateContainer {
    var a = 0
    var b = 0
}

// MARK: - Tests

/// Direct tests of ``ObservationRegistry``: subscription flushing, dedup, and
/// the once-per-operation notification contract. Everything routes through
/// `env.observation`, the same registrar the whole system uses.
@Suite @MainActor
struct ObservationRegistryTests {

    /// A subscribed receiver is called once with the set of changed IDs.
    @Test func notifiesSubscriberWithChangedIDs() {
        let env = SharedEnvironment()
        let a = ValueID(keyPath: \OSState.a)

        var callCount = 0
        var received: Set<ValueID> = []
        let receiver = NotificationReceiver { ids in
            callCount += 1
            received = ids
        }

        env.observation.subscribe(receiver: receiver, valueID: a)
        env.observation.invalidateValue(at: a)
        env.observation.notifyAll()

        #expect(callCount == 1)
        #expect(received.contains(a))
    }

    /// Subscriptions are one-shot: `notifyAll()` flushes receivers, so a second
    /// operation does not reach a receiver that did not re-subscribe.
    @Test func subscriptionIsOneShot() {
        let env = SharedEnvironment()
        let a = ValueID(keyPath: \OSState.a)

        var callCount = 0
        let receiver = NotificationReceiver { _ in callCount += 1 }

        env.observation.subscribe(receiver: receiver, valueID: a)
        env.observation.invalidateValue(at: a)
        env.observation.notifyAll()
        #expect(callCount == 1)

        // No re-subscribe: the second operation must not notify.
        env.observation.invalidateValue(at: a)
        env.observation.notifyAll()
        #expect(callCount == 1)
    }

    /// Invalidating the same value twice in one operation notifies once.
    @Test func duplicateInvalidationNotifiesOnce() {
        let env = SharedEnvironment()
        let a = ValueID(keyPath: \OSState.a)

        var callCount = 0
        var received: Set<ValueID> = []
        let receiver = NotificationReceiver { ids in
            callCount += 1
            received = ids
        }

        env.observation.subscribe(receiver: receiver, valueID: a)
        env.observation.invalidateValue(at: a)
        env.observation.invalidateValue(at: a)
        env.observation.notifyAll()

        #expect(callCount == 1)
        #expect(received == [a])
    }

    /// An operation with no invalidations notifies nothing.
    @Test func emptyOperationNotifiesNothing() {
        let env = SharedEnvironment()
        let a = ValueID(keyPath: \OSState.a)

        var callCount = 0
        let receiver = NotificationReceiver { _ in callCount += 1 }

        env.observation.subscribe(receiver: receiver, valueID: a)
        env.observation.notifyAll()

        #expect(callCount == 0)
    }

    /// Two receivers on the same value are both notified.
    @Test func multipleReceiversSameValueBothNotified() {
        let env = SharedEnvironment()
        let a = ValueID(keyPath: \OSState.a)

        var first = 0
        var second = 0
        let r1 = NotificationReceiver { _ in first += 1 }
        let r2 = NotificationReceiver { _ in second += 1 }

        env.observation.subscribe(receiver: r1, valueID: a)
        env.observation.subscribe(receiver: r2, valueID: a)
        env.observation.invalidateValue(at: a)
        env.observation.notifyAll()

        #expect(first == 1)
        #expect(second == 1)
    }

    /// A receiver for one value is not notified when a different value changes.
    @Test func unrelatedValueDoesNotNotify() {
        let env = SharedEnvironment()
        let a = ValueID(keyPath: \OSState.a)
        let b = ValueID(keyPath: \OSState.b)

        var callCount = 0
        let receiver = NotificationReceiver { _ in callCount += 1 }

        env.observation.subscribe(receiver: receiver, valueID: a)
        env.observation.invalidateValue(at: b)
        env.observation.notifyAll()

        #expect(callCount == 0)
    }
}
