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

// Tests and other modules name this type. The user catalog does not start here.
/// The registrar of change notifications. It does not store values, ``SharedEnvironment`` does that.
/// It wires three parts: the receivers watching each ``ValueID``, the ``ChangeBuffer`` that collects
/// what changed during one operation, and the ``DependencyGraph`` that invalidates derived values.
///
/// ``SharedEnvironment`` reports each write with ``invalidateValue(at:)``. At the end of the
/// operation it calls ``notifyAll()`` once, which drains the buffer and calls every affected
/// receiver. Subscriptions are one-shot: a receiver is dropped when notified, so it re-subscribes by
/// reading again.
@_documentation(visibility: private)
@MainActor public final class ObservationRegistry {

    /// The receivers watching each ``ValueID``.
    /// A receiver joins the set for a value through ``subscribe(receiver:valueID:)``.
    private var receivers = DependencyTable<NotificationReceiver>()

    /// The value IDs changed during the current operation. Drained by ``notifyAll()``.
    private var changes = ChangeBuffer()

    /// Tracks which derived values (``Dependent``) depend on which inputs, and clears their caches
    /// when an input changes. Unlike `receivers`, dependents are invalidated *eagerly* — together
    /// with the value, before notifications are sent. See ``DependencyGraph``.
    private let dependencyGraph = DependencyGraph()

    // MARK: - Subscribe -

    /// Addresses that currently hold at least one receiver. Subscriptions are one-shot, so this
    /// is how a test tells "still subscribed" from "read and let go".
    var subscribedValueIDs: [ValueID] { receivers.keys }

    /// Adds a receiver to be called when the *value* at given *ID* changes.
    public func subscribe(receiver: NotificationReceiver, valueID: ValueID) {
        receivers.register(receiver, on: valueID)
    }

    /// Records that `dependent` reads the value at `input`, so it is invalidated when `input` changes.
    func register(dependent: Dependent, on input: ValueID) {
        dependencyGraph.register(dependent: dependent, on: input)
    }

    // MARK: - Invalidate -

    /// Marks a value as changed for the current operation.
    /// - Parameter valueID: the ``ValueID`` of the value that changed.
    public func invalidateValue(at valueID: ValueID) {
        changes.insert(valueID)

        // Eagerly invalidate every dependent computation (clearing its cache) and mark it changed so
        // its own observers are notified at flush. The next read recomputes and re-registers the edge.
        changes.formUnion(dependencyGraph.invalidate(input: valueID))
    }

    /// Marks every currently subscribed Address changed so live Watchers re-read after a drop.
    func invalidateSubscribed() {
        for valueID in receivers.keys {
            invalidateValue(at: valueID)
        }
    }

    func invalidateSubscribed<Storage: StateContainer>(in type: Storage.Type) {
        for valueID in receivers.keys where valueID.valueKeyPathID is PartialKeyPath<Storage> {
            invalidateValue(at: valueID)
        }
    }

    // MARK: - Notify -

    /// Drains the operation's changed IDs and calls each affected receiver once.
    ///
    /// A receiver is removed as it is notified, so subscriptions stay one-shot. Reading `receivers`
    /// per changed ID is `O(1)`, so the whole call is `O(n*m)` where `n` is the number of changed IDs
    /// and `m` the receivers per ID.
    public func notifyAll() {
        let changedValueIDs = changes.drain()
        var toNotify: Set<NotificationReceiver> = []
        for valueID in changedValueIDs {
            toNotify.formUnion(receivers.take(valueID))
        }
        toNotify.forEach { $0.callback(changedValueIDs) }
    }
}
