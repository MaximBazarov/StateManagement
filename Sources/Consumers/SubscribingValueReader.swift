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
/// Reads the value subscribing for its next update.
/// When value is `Equitable`, suppresses the notifications if it's equal to the most recent value.
///
/// Change is reported through the single `onChange()` so it can be wired up to any publisher.
///
@_documentation(visibility: private)
@MainActor public final class SubscribingValueReader<Storage: StateContainer, Value> {

    let valueID: ValueID

    /// Called when an observed change should re-render the consumer. Installed by
    /// the owner (`Watch` forwards it to `objectWillChange`; a probe re-renders).
    public var onChange: (() -> Void)?

    /// Encapsulates the per-flavour read: take the Value, then subscribe to the
    /// `ValueID` (and, for computeds, register dependencies).
    private let readValue: (SharedEnvironment, NotificationReceiver) -> Value

    /// Gets the current value from the environment.
    /// Is built when ``read(in:)`` is called, capturing the environment,
    /// so the lazy `receiver` does not reference itself.
    private var getValue: (() -> Value)?

    // MARK: - Diffing
    /// Output-diffing equality, when the watched value is `Equatable`. `nil`
    /// means "always notify on dependency change" (non-Equatable values).
    private let areEqual: ((Value, Value) -> Bool)?

    /// Last value produced by `read(in:)`, used as the diffing baseline.
    private(set) var mostRecentValue: Value?

    lazy var receiver = NotificationReceiver { [weak self] updatedValueIDs in
        guard let self else { return }
        guard updatedValueIDs.contains(self.valueID) else { return }

        // Output diffing for `Equitable` values, if the value is not equitable the `areEqual` is `nil`.
        if let areEqual = self.areEqual, let getValue {
            let newValue = getValue()
            if let last = self.mostRecentValue, areEqual(last, newValue) {
                return // unchanged output: suppress notification
            }
            self.mostRecentValue = newValue
        }

        self.onChange?()
    }

    // Base initialiser that is used by more specific state type initialisers.
    private init(
        valueID: ValueID,
        areEqual: ((Value, Value) -> Bool)? = nil,
        readValue: @escaping (SharedEnvironment, NotificationReceiver) -> Value
    ) {
        self.valueID = valueID
        self.areEqual = areEqual
        self.readValue = readValue
    }

    /// Reads the value directly from the provided environment.
    /// Computes the value, then subscribes, caches it as the diffing baseline, and returns it.
    func read(in environment: SharedEnvironment) -> Value {
        // TODO: This looks like a good place to centralise a single way of reading the value subscribing etc. research if it's possible.
        // later this can be used in computation as well so we don't produce a separate cache? so basically making keyed and non keyed value cache the same way like in the computed?
        let receiver = self.receiver
        let read = self.readValue

        getValue = { read(environment, receiver) }

        let value = read(environment, receiver)

        // if self.areEqual != nil {
            mostRecentValue = value
        // }

        return value
    }
}

// MARK: - Factories (single source of truth for Watch and tests)

extension SubscribingValueReader {

    private static func makeObservingValue(
        _ statePath: KeyPath<Storage, Value>,
        areEqual: ((Value, Value) -> Bool)?
    ) -> SubscribingValueReader {
        let valueID = ValueID(keyPath: statePath)
        return SubscribingValueReader(valueID: valueID, areEqual: areEqual) { env, receiver in
            let value = env.getValue(keyPath: statePath)
            env.observation.subscribe(receiver: receiver, valueID: valueID)
            return value
        }
    }

    /// Atomic state at a key path. Equatable values diff; non-Equatable always notify.
    static func observingValue(_ statePath: KeyPath<Storage, Value>) -> SubscribingValueReader
        where Value: Equatable {
        makeObservingValue(statePath, areEqual: { $0 == $1 })
    }

    /// Atomic state at a key path, non-Equatable: always notify.
    static func observingValue(_ statePath: KeyPath<Storage, Value>) -> SubscribingValueReader {
        makeObservingValue(statePath, areEqual: nil)
    }


    /// A single key inside a dictionary state. Equatable output diffs.
    static func buildKeyedValueReader<Key: Hashable, Output: Equatable>(
        _ statePath: KeyPath<Storage, [Key: Output]>,
        key: Key
    ) -> SubscribingValueReader where Value == Output? {
        makeObservingKeyedValue(statePath, key: key, areEqual: { $0 == $1 })
    }

    /// A single key inside a dictionary state, non-Equatable output: always notify.
    static func buildKeyedValueReader<Key: Hashable, Output>(
        _ statePath: KeyPath<Storage, [Key: Output]>,
        key: Key
    ) -> SubscribingValueReader where Value == Output? {
        makeObservingKeyedValue(statePath, key: key, areEqual: nil)
    }

    private static func makeObservingKeyedValue<Key: Hashable, Output>(
        _ statePath: KeyPath<Storage, [Key: Output]>,
        key: Key,
        areEqual: ((Value, Value) -> Bool)?
    ) -> SubscribingValueReader where Value == Output? {
        let valueID = ValueID(keyPath: statePath, key: AnyHashable(key))
        return SubscribingValueReader(valueID: valueID, areEqual: areEqual) { env, receiver in
            let value = env.getValue(keyPath: statePath, key: key)
            env.observation.subscribe(receiver: receiver, valueID: valueID)
            return value
        }
    }

    /// A computed value. Equatable output diffs; non-Equatable always notify.
    static func observingComputed(_ statePath: KeyPath<Storage, Computed<NoKey, Value>>) -> SubscribingValueReader
        where Value: Equatable {
        makeObservingComputed(statePath, areEqual: { $0 == $1 })
    }

    /// A computed value, non-Equatable: always notify.
    static func observingComputed(_ statePath: KeyPath<Storage, Computed<NoKey, Value>>) -> SubscribingValueReader {
        makeObservingComputed(statePath, areEqual: nil)
    }

    private static func makeObservingComputed(
        _ statePath: KeyPath<Storage, Computed<NoKey, Value>>,
        areEqual: ((Value, Value) -> Bool)?
    ) -> SubscribingValueReader {
        let valueID = ValueID(keyPath: statePath)
        return SubscribingValueReader(valueID: valueID, areEqual: areEqual) { env, receiver in
            let computation = env.getValue(keyPath: statePath)
            return computation.read(env: env, valueID: valueID, receiver: receiver, key: .noKey)
        }
    }

    /// A keyed computed value. Equatable output diffs; non-Equatable always notify.
    static func observingComputedKeyed<Key: Hashable>(
        _ statePath: KeyPath<Storage, Computed<Key, Value>>,
        key: Key
    ) -> SubscribingValueReader where Value: Equatable {
        makeObservingComputedKeyed(statePath, key: key, areEqual: { $0 == $1 })
    }

    /// A keyed computed value, non-Equatable: always notify.
    static func observingComputedKeyed<Key: Hashable>(
        _ statePath: KeyPath<Storage, Computed<Key, Value>>,
        key: Key
    ) -> SubscribingValueReader {
        makeObservingComputedKeyed(statePath, key: key, areEqual: nil)
    }

    private static func makeObservingComputedKeyed<Key: Hashable>(
        _ statePath: KeyPath<Storage, Computed<Key, Value>>,
        key: Key,
        areEqual: ((Value, Value) -> Bool)?
    ) -> SubscribingValueReader {
        let valueID = ValueID(keyPath: statePath, key: AnyHashable(key))
        return SubscribingValueReader(valueID: valueID, areEqual: areEqual) { env, receiver in
            let computation = env.getValue(keyPath: statePath)
            return computation.read(env: env, valueID: valueID, receiver: receiver, key: key)
        }
    }
}
