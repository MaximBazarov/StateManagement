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

/// A counter part provided into the closure of the the ``Computed`` responsible for connection to the ``SharedEnvironment``.
/// Restricts what ``Computed`` can access from the ``SharedEnvironment`` without drifting from it.
@MainActor public final class ComputationEnvironment {

    /// Reference to the actual environment.
    private unowned var env: SharedEnvironment

    /// Reference to the actual ``NotificationReceiver`` of the consumer created for the ``Computed``,
    /// E.g (``Watch``) or ``EnvironmentService`` that should receive the notification when the value changes.
    private var notificationReceiver: NotificationReceiver

    /// When ``Computed`` reads other values it registers itself as a ``Dependent``.
    /// When those values change, dependent `invalidate` is called before the notifications of ``NotificationReceiver``
    /// So the invalidation of the value is happening before the read.
    private let dependent: Dependent

    /// Dependency cycle protection.
    /// The evaluation chain, storing which values were read so far e.g. `A → B → C` (A reads B, B reads C),
    /// the ``ComputationEnvironment`` `evaluating` of `C` holds `[A, B, C]`.
    ///
    /// That lets each read catch a cycle: if a computed is about to read the value that's already in its own history,
    /// it would be reading itself, hence a loop.
    private let evaluating: [ValueID]

    init(
        env: SharedEnvironment,
        notificationReceiver: NotificationReceiver,
        dependent: Dependent,
        evaluating: [ValueID] = []
    ) {
        self.env = env
        self.notificationReceiver = notificationReceiver
        self.dependent = dependent
        self.evaluating = evaluating
    }

    /// Reads an **atomic state** value, subscribes to its changes and registers as a dependant.
    public func getValue<Storage: StateContainer, Value>(
        _ keyPath: KeyPath<Storage, Value>
    ) -> Value {
        let targetValueID = ValueID(keyPath: keyPath)
        env.observation.register(dependent: dependent, on: targetValueID)
        env.observation.subscribe(
            receiver: notificationReceiver,
            valueID: targetValueID
        )
        return env.getValue(keyPath: keyPath)
    }

    /// Reads a **keyed state** value, subscribes to its changes and registers as a dependant.
    public func getValue<Storage: StateContainer, Key: Hashable, Value>(
        _ keyPath: KeyPath<Storage, [Key: Value]>,
        key: Key
    ) -> Value? {
        let targetValueID = ValueID(keyPath: keyPath, key: key)
        env.observation.register(dependent: dependent, on: targetValueID)
        env.observation.subscribe(
            receiver: notificationReceiver,
            valueID: targetValueID
        )
        return env.getValue(keyPath: keyPath, key: key)
    }

    /// Reads another ``Computed`` **atomic state** value, subscribes to its changes and registers as a dependant.
    public func getValue<Storage: StateContainer, Output>(
        _ keyPath: KeyPath<Storage, Computed<NoKey, Output>>
    ) -> Output {
        let innerID = ValueID(keyPath: keyPath)
        env.observation.register(dependent: dependent, on: innerID)
        let computation = env.getValue(keyPath: keyPath)
        return computation.read(
            env: env,
            valueID: innerID,
            receiver: notificationReceiver,
            key: .noKey,
            evaluating: evaluating
        )
    }

    /// Reads another ``Computed`` **keyed state** value, subscribes to its changes and registers as a dependant.
    public func getValue<Storage: StateContainer, Key: Hashable, Output>(
        _ keyPath: KeyPath<Storage, Computed<Key, Output>>,
        key: Key
    ) -> Output {
        let innerID = ValueID(keyPath: keyPath, key: key)
        env.observation.register(dependent: dependent, on: innerID)
        let computation = env.getValue(keyPath: keyPath)
        return computation.read(
            env: env,
            valueID: innerID,
            receiver: notificationReceiver,
            key: key,
            evaluating: evaluating
        )
    }
}
